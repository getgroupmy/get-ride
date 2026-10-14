-- ============================================================================
-- Regression test for migration 0182: open rides are for approved drivers,
-- the driver card on a ride comes from the server, each side writes only its
-- own live data, and a trip under way is not the rider's to cancel.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_privacy_identity.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000182a1'),  -- rider
  ('00000000-0000-0000-0000-0000000182b1'),  -- approved driver
  ('00000000-0000-0000-0000-0000000182b2'),  -- driver still waiting for approval
  ('00000000-0000-0000-0000-0000000182c1')   -- another passenger
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000182%'
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, avatar_url, rating, status) values
  ('00000000-0000-0000-0000-0000000182d1', '00000000-0000-0000-0000-0000000182b1', 'Dina', '+60110000182',
   'https://cdn.example/dina.jpg', 4.8, 'approved'),
  ('00000000-0000-0000-0000-0000000182d2', '00000000-0000-0000-0000-0000000182b2', 'Uda', '+60110000183',
   null, 0, 'unapproved');
insert into public.vehicle (id, plate, make, model, color, auth_user_id, owner_partner_id, status) values
  ('00000000-0000-0000-0000-0000000182f1', 'ABC1234', 'Perodua', 'Myvi', 'White',
   '00000000-0000-0000-0000-0000000182b1', '00000000-0000-0000-0000-0000000182d1', 'approved');
insert into public.vehicle_active_session (vehicle_id, user_id)
values ('00000000-0000-0000-0000-0000000182f1', '00000000-0000-0000-0000-0000000182b1');

-- e1: open, to be taken. e2: on trip with the driver.
insert into public.ride_requests (id, rider_id, rider_name, rider_phone, partner_id, status, fare, ride_fare, otp) values
  ('00000000-0000-0000-0000-0000000182e1', '00000000-0000-0000-0000-0000000182a1', 'Rina', '+60120000182',
   null, 'open', 20, 20, '4321'),
  ('00000000-0000-0000-0000-0000000182e2', '00000000-0000-0000-0000-0000000182a1', 'Rina', '+60120000182',
   '00000000-0000-0000-0000-0000000182b1', 'on_trip', 20, 20, '8765');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to anon, authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to anon, authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;

-- 1. Who reads an open request ------------------------------------------------------
select set_config('request.jwt.claims', '{"role": "anon"}', true), set_config('request.jwt.claim.sub', '', true);
set local role anon;
select pg_temp.refused($q$select 1 from public.ride_requests limit 1$q$, 'a signed-out caller reading rides');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000182c1');
select pg_temp.check(not exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'another passenger can''t see an open request');
select pg_temp.as_user('00000000-0000-0000-0000-0000000182b2');
select pg_temp.check(not exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'an unapproved driver can''t see an open request');
select pg_temp.as_user('00000000-0000-0000-0000-0000000182b1');
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'an approved driver sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000182a1');
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'its rider sees it');

-- 2. The driver's card is the server's ----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000182b1');
update public.ride_requests
   set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000182b1',
       partner_name = 'Someone Else', partner_phone = '+60999999999', partner_photo = 'https://evil.example/x.jpg',
       partner_rating = 5, partner_plate = 'FAKE123', partner_vehicle = 'Ferrari'
 where id = '00000000-0000-0000-0000-0000000182e1' and status = 'open';
select pg_temp.check((select partner_name = 'Dina' and partner_phone = '+60110000182'
                             and partner_photo = 'https://cdn.example/dina.jpg' and partner_rating = 4.8
                             and partner_plate = 'ABC1234' and partner_vehicle = 'White Perodua Myvi'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'the card comes from the approved partner and the car being driven');
-- ...and stays as it is.
update public.ride_requests set partner_name = 'Someone Else', partner_plate = 'FAKE123'
 where id = '00000000-0000-0000-0000-0000000182e1';
select pg_temp.check((select partner_name = 'Dina' and partner_plate = 'ABC1234'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'the card is fixed once filled');
select pg_temp.check(not exists (select 1 from public.ride_partner_card('00000000-0000-0000-0000-0000000182b2')),
                     'nobody reads another driver''s card');

-- 3. Each side writes only its own -----------------------------------------------------
select pg_temp.refused(
  $q$update public.ride_requests set user_live_lat = 3.1, user_live_lng = 101.6, user_live_at = now()
      where id = '00000000-0000-0000-0000-0000000182e1'$q$,
  'the driver moving the rider''s shared location');
select pg_temp.refused(
  $q$update public.ride_requests set rider_phone = '+60100000000' where id = '00000000-0000-0000-0000-0000000182e1'$q$,
  'the driver rewriting the rider''s phone');
select pg_temp.refused(
  $q$update public.ride_requests set safety_ack_at = now() where id = '00000000-0000-0000-0000-0000000182e2'$q$,
  'the driver answering the rider''s safety check');
update public.ride_requests set partner_live_lat = 3.1, partner_live_lng = 101.6, partner_live_at = now()
 where id = '00000000-0000-0000-0000-0000000182e1';

select pg_temp.as_user('00000000-0000-0000-0000-0000000182a1');
select pg_temp.refused(
  $q$update public.ride_requests set partner_live_lat = 1, partner_live_lng = 1 where id = '00000000-0000-0000-0000-0000000182e1'$q$,
  'the rider moving the driver''s position');
update public.ride_requests set user_live_lat = 3.2, user_live_lng = 101.7, user_live_at = now()
 where id = '00000000-0000-0000-0000-0000000182e1';

-- 4. A trip under way isn't the rider's to cancel ------------------------------------------
select pg_temp.refused(
  $q$update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000182e2'$q$,
  'the rider cancelling a trip under way');
-- Before pickup it still is.
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000182e1';

reset role;
select pg_temp.check((select status = 'on_trip' from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e2'),
                     'the trip under way is still on');
select pg_temp.check((select status = 'cancelled' and user_live_lat = 3.2 and partner_live_lat = 3.1
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000182e1'),
                     'each side''s own writes went through');

select 'ride_privacy_identity: all passed';
rollback;
