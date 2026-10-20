-- ============================================================================
-- Regression test for migration 0248: "Assistance required" and the option
-- charges. The help is saved on the ride; approved drivers see what help an
-- open request needs, but the rider's note waits aside until a driver takes
-- the ride, when that driver reads it and other drivers don't. The option
-- charges are saved and fixed. A custom pet type books.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_options_0248.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('authenticated', 'public.ride_assistance_public(jsonb)', 'execute') then
    raise exception 'FAILED: ride_assistance_public is the trigger''s own';
  end if;
  if has_function_privilege('authenticated', 'public.ride_requests_assistance()', 'execute') then
    raise exception 'FAILED: ride_requests_assistance is a trigger';
  end if;
end
$$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000248a1'),  -- rider
  ('00000000-0000-0000-0000-0000000248b1'),  -- the driver who takes the ride
  ('00000000-0000-0000-0000-0000000248b2')   -- another approved driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000248%'
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000248b1', 'Aiman', '+60110000248', 'approved'),
  ('00000000-0000-0000-0000-0000000248b2', 'Badrul', '+60110000249', 'approved');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
-- Runs [p_sql] and ignores a refusal: what is left is checked after.
create or replace function pg_temp.try(p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
exception when others then
  null;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.try(text) to authenticated;

-- 1. The help, the charges and a custom pet type are saved; an open request keeps the note aside ---
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_name, drop_name, note,
                                  pets, assistance, option_charges) values
  ('00000000-0000-0000-0000-0000000248d1', '00000000-0000-0000-0000-0000000248a1', 'open', 40, 40,
   'KLCC', 'Mid Valley',
   'Pet with me: 1 iguana (M) · Assistance: Wheelchair user (Electric / heavy), Sign language',
   '[{"type": "Iguana", "size": "M"}]',
   '{"items": [{"id": "wheelchair", "name": "Wheelchair user", "emoji": "♿", "choice": "Electric / heavy"},
               {"id": "custom-1", "name": "Sign language", "emoji": "🤟"}],
     "note": "Ring the bell twice"}',
   '[{"kind": "pet", "name": "Pet charge", "amount": 10}, {"kind": "assistance", "name": "Assistance charge", "amount": 5}]');

select pg_temp.check(
  (select assistance = '{"items": [{"id": "wheelchair", "name": "Wheelchair user", "emoji": "♿", "choice": "Electric / heavy"},
                                   {"id": "custom-1", "name": "Sign language", "emoji": "🤟"}]}'::jsonb
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'an open request shows drivers the help, not the note');
select pg_temp.check(
  (select assistance->>'note' = 'Ring the bell twice' and jsonb_array_length(assistance->'items') = 2
     from public.ride_request_private where request_id = '00000000-0000-0000-0000-0000000248d1'),
  'the note waits aside, for the rider');
select pg_temp.check(
  (select option_charges->1->>'name' = 'Assistance charge' and public.ride_option_charges_total(option_charges) = 15
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'the option charges are saved');
select pg_temp.check(
  (select pets->0->>'type' = 'Iguana' from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'a custom pet type is accepted');

select pg_temp.refused(
  $q$insert into public.ride_requests (id, rider_id, status, assistance) values
     ('00000000-0000-0000-0000-0000000248d2', '00000000-0000-0000-0000-0000000248a1', 'open', '{"items": []}')$q$,
  'help with nothing picked');
select pg_temp.refused(
  $q$insert into public.ride_requests (id, rider_id, status, assistance) values
     ('00000000-0000-0000-0000-0000000248d3', '00000000-0000-0000-0000-0000000248a1', 'open',
      '{"items": [{"emoji": "♿"}]}')$q$,
  'help without a name');
select pg_temp.refused(
  $q$insert into public.ride_requests (id, rider_id, status, option_charges) values
     ('00000000-0000-0000-0000-0000000248d4', '00000000-0000-0000-0000-0000000248a1', 'open',
      '[{"name": "Pet charge", "amount": -3}]')$q$,
  'a negative option charge');

-- 2. Another approved driver sees the help on the open request, never the note -----------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000248b2');
select pg_temp.check(
  (select jsonb_array_length(assistance->'items') = 2 and not assistance ? 'note'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'an approved driver sees what help an open request needs, without the note');
select pg_temp.check(
  (select count(*) = 0 from public.ride_request_private where request_id = '00000000-0000-0000-0000-0000000248d1'),
  'a driver cannot read the note aside');
reset role;

-- 3. The driver takes the ride: the note comes back, and only that driver reads it ---------------
update public.ride_requests
   set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000248b1', accepted_at = now()
 where id = '00000000-0000-0000-0000-0000000248d1';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000248b1');
select pg_temp.check(
  (select assistance->>'note' = 'Ring the bell twice' and assistance->'items'->0->>'choice' = 'Electric / heavy'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'the assigned driver reads the help and the note');
-- Neither the help nor the charges are the driver's to change.
select pg_temp.try($q$update public.ride_requests set assistance = null
                     where id = '00000000-0000-0000-0000-0000000248d1'$q$);
select pg_temp.try($q$update public.ride_requests set option_charges = '[]'
                     where id = '00000000-0000-0000-0000-0000000248d1'$q$);
select pg_temp.check(
  (select assistance->>'note' = 'Ring the bell twice' and public.ride_option_charges_total(option_charges) = 15
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'the driver cannot change the rider''s help or the option charges');

select pg_temp.as_user('00000000-0000-0000-0000-0000000248b2');
select pg_temp.check(
  (select count(*) = 0 from public.ride_requests
    where id = '00000000-0000-0000-0000-0000000248d1' and assistance ? 'note'),
  'another driver never reads the note');

-- The rider can't change the charges after booking either.
select pg_temp.as_user('00000000-0000-0000-0000-0000000248a1');
select pg_temp.try($q$update public.ride_requests set option_charges = '[{"name": "Pet charge", "amount": 1}]'
                     where id = '00000000-0000-0000-0000-0000000248d1'$q$);
select pg_temp.check(
  (select public.ride_option_charges_total(option_charges) = 15
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'the option charges are fixed at booking');
reset role;

-- 4. Reopened, the note moves aside again ---------------------------------------------------------
update public.ride_requests set status = 'open', partner_id = null, accepted_at = null
 where id = '00000000-0000-0000-0000-0000000248d1';
select pg_temp.check(
  (select not assistance ? 'note' and jsonb_array_length(assistance->'items') = 2
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000248d1'),
  'a reopened request keeps the note aside again');
select pg_temp.check(
  (select assistance->>'note' = 'Ring the bell twice'
     from public.ride_request_private where request_id = '00000000-0000-0000-0000-0000000248d1'),
  'the note is still the rider''s');

-- 5. A scheduled booking keeps the help and the charges --------------------------------------------
select pg_temp.check(
  public.scheduled_request_clean(
    '{"assistance": {"items": [{"name": "Pregnant"}], "note": "x"}, "option_charges": [{"name": "Pet charge", "amount": 2}],
      "status": "accepted"}'::jsonb)
    = '{"assistance": {"items": [{"name": "Pregnant"}], "note": "x"}, "option_charges": [{"name": "Pet charge", "amount": 2}]}'::jsonb,
  'a scheduled booking keeps the help and the option charges');

select 'ride_options_0248: all passed';
rollback;
