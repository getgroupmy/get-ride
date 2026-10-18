-- ============================================================================
-- Regression test for migration 0221: a ride's driver is only the driver who
-- took it, and a scheduled booking keeps only what the booking sheet sends.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_sides.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000221a1'),  -- rider (also an approved driver)
  ('00000000-0000-0000-0000-0000000221b1'),  -- driver
  ('00000000-0000-0000-0000-0000000221b2'),  -- another driver (the victim)
  ('00000000-0000-0000-0000-0000000221c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000221%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000221c1', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000221a1', 'Ali', '+60110000221', 'approved'),
  ('00000000-0000-0000-0000-0000000221b1', 'Badrul', '+60110000222', 'approved'),
  ('00000000-0000-0000-0000-0000000221b2', 'Bella', '+60110000223', 'approved');

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
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;

-- 1. A new request names no driver and no bid -------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000221a1');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, partner_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values ('00000000-0000-0000-0000-0000000221a1', '00000000-0000-0000-0000-0000000221a1', 'open', 500, 500, 'KLCC', 3.15, 101.71)$q$,
  'a rider booking themselves as the driver');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, partner_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values ('00000000-0000-0000-0000-0000000221a1', '00000000-0000-0000-0000-0000000221b2', 'open', 5, 5, 'KLCC', 3.15, 101.71)$q$,
  'a rider naming another driver');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, offered_fare, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values ('00000000-0000-0000-0000-0000000221a1', 5, 'open', 5, 5, 'KLCC', 3.15, 101.71)$q$,
  'a rider writing a bid');
with r as (
  insert into public.ride_requests (rider_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values ('00000000-0000-0000-0000-0000000221a1', 'open', 20, 20, 'KLCC', 3.15, 101.71)
  returning id)
insert into ids select 'ride', id from r;

-- 2. Only the driver themselves, never on their own booking ----------------------------------
select pg_temp.refused($q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000221a1'
  where id = (select id from ids where k = 'ride')$q$, 'an approved driver taking the ride they booked');
select pg_temp.refused($q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000221b2'
  where id = (select id from ids where k = 'ride')$q$, 'the rider putting a driver on their ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000000221b1');
select pg_temp.refused($q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000221b2'
  where id = (select id from ids where k = 'ride')$q$, 'a driver putting another driver on a ride');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000221b1', offered_fare = 22
 where id = (select id from ids where k = 'ride');
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000221b1' and offered_fare = 22
                        from public.ride_requests where id = (select id from ids where k = 'ride')),
  'a driver bids for themselves');

-- 3. Never the same person on both sides, whoever writes it ----------------------------------
select pg_temp.refused($q$insert into public.ride_requests (rider_id, partner_id, status, fare, ride_fare)
  values ('00000000-0000-0000-0000-0000000221b1', '00000000-0000-0000-0000-0000000221b1', 'accepted', 5, 5)$q$,
  'a ride with the same rider and driver');
select pg_temp.check(exists (select 1 from pg_constraint where conname = 'ride_requests_sides_differ' and convalidated),
  'the check holds for every row');

-- 4. A scheduled booking keeps only what the booking sheet sends ------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000221c1');
select public.set_scheduled_rides_config(jsonb_build_object(
  'enabled', true, 'minLeadMinutes', 30, 'maxDaysAhead', 7, 'feeFixed', 2, 'feePercent', 10,
  'feeTo', 'platform', 'mode', 'release'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000221a1');
insert into ids select 'booking', id from public.schedule_ride(
  jsonb_build_object('service', 'car', 'fare', 20, 'ride_fare', 20, 'pickup_lat', 3.15, 'pickup_lng', 101.71,
    'pickup_address', 'KLCC', 'currency', 'RM', 'note', 'Gate B',
    'fare_coins_value', 100000, 'fare_coins_used', 100000, 'toll_charges', 5000, 'other_charges', 5000,
    'commission_locked_at', now(), 'handed_over_at', now(), 'partner_live_lat', 1,
    'charges', jsonb_build_array(
      jsonb_build_object('kind', 'surcharge', 'name', 'Airport', 'charge', 'fixed', 'value', 100000, 'platform', true))),
  now() + interval '3 hours');
reset role;
select pg_temp.check((select not (request ?| array['fare_coins_value', 'fare_coins_used', 'toll_charges', 'other_charges',
                                                   'commission_locked_at', 'handed_over_at', 'partner_live_lat'])
                             and request->>'note' = 'Gate B' and request->>'pickup_address' = 'KLCC'
                        from public.scheduled_rides where id = (select id from ids where k = 'booking')),
  'only the booking sheet''s columns are kept');
select pg_temp.check((select request->'charges' @> '[{"name":"Airport"}]'
                             and not request->'charges' @> '[{"name":"Airport","platform":true}]'
                             and request->'charges' @> '[{"name":"Scheduling fee","value":4,"platform":true}]'
                        from public.scheduled_rides where id = (select id from ids where k = 'booking')),
  'no charge the app sends is the platform''s; the server''s fee is');

-- A booking made before 0221 is cleaned the same way, its own fee kept.
select pg_temp.check(public.scheduled_request_clean(
    '{"fare":20,"fare_coins_value":9,"charges":[{"kind":"surcharge","name":"Scheduling fee","charge":"fixed","value":4,"platform":true},{"name":"x","value":4,"platform":true}]}',
    4)
  = '{"fare":20,"charges":[{"kind":"surcharge","name":"Scheduling fee","charge":"fixed","value":4,"platform":true},{"name":"x","value":4}]}'::jsonb,
  'the old booking keeps its fee and loses the rest');

select 'ride_sides: all passed';
rollback;
