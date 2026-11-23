-- ============================================================================
-- Regression test for migration 0404: the trip live bridge (driver match
-- corrected in 0429).
--   * trip_live_bridge updates the rider's live columns on a ride they booked,
--     and the driver's on a ride they run, only while it is active, and never
--     a ride the profile is not on.
--   * The driver of a ride is ride_requests.partner_id = the driver's own
--     account id (their auth uid), as the app writes it when a ride is taken.
--     It is never a partners.id: 0404 matched on that, which no real ride
--     holds, and this test hid it by putting one there (0429).
--   * push_live_location (the 5 s path) feeds the trip even with no God View
--     session open.
--   * push_background_location (the background path) feeds the trip for a phone
--     allowed to background-report (a driver).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trip_live_bridge_0404.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000404a1'),  -- rider
  ('00000000-0000-0000-0000-0000000404b1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000404%'
on conflict do nothing;

-- The driver's partner row. Its id (…0404d1) is not the driver's account id
-- (…0404b1), as for every real partner.
insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000404d1', '00000000-0000-0000-0000-0000000404b1', 'Test Driver 0404', '+60100004041',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;

-- Rides: A the rider's active trip, B the driver's active trip, C the rider's
-- finished trip (must never move), D the driver's cancelled trip. B and D carry
-- the driver's account id in partner_id, as a ride the app has taken does.
-- E is nobody's: its partner_id is the driver's partners.id, the id 0404 looked
-- for. It must never move.
insert into public.ride_requests (id, rider_id, partner_id, status) values
  ('00000000-0000-0000-0000-00000040ac01', '00000000-0000-0000-0000-0000000404a1', null, 'on_trip'),
  ('00000000-0000-0000-0000-00000040ac02', null, '00000000-0000-0000-0000-0000000404b1', 'accepted'),
  ('00000000-0000-0000-0000-00000040ac03', '00000000-0000-0000-0000-0000000404a1', null, 'completed'),
  ('00000000-0000-0000-0000-00000040ac04', null, '00000000-0000-0000-0000-0000000404b1', 'cancelled'),
  ('00000000-0000-0000-0000-00000040ac05', null, '00000000-0000-0000-0000-0000000404d1', 'accepted')
on conflict (id) do nothing;

-- Install tokens: the rider's and the driver's, each "Always" with a bg key.
insert into public.push_tokens (id, profile_id, token, location_always, bg_key_hash, updated_at) values
  ('00000000-0000-0000-0000-00000040e001', '00000000-0000-0000-0000-0000000404a1', 'tok-rider-0404', true,
   encode(extensions.digest(convert_to('rider-key-0404-rider-key-0404-rr', 'UTF8'), 'sha256'), 'hex'), now()),
  ('00000000-0000-0000-0000-00000040e002', '00000000-0000-0000-0000-0000000404b1', 'tok-driver-0404', true,
   encode(extensions.digest(convert_to('driver-key-0404-driver-key-0404-d', 'UTF8'), 'sha256'), 'hex'), now())
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;

-- The signed-in app, and the phone's native reporter (no session, the anon key).
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
grant execute on function pg_temp.as_anon() to anon;

-- 0. The rides above are the driver's as the app itself sees them ----------------------------------
-- Signed in as the driver, the trip screen's own position write
-- (publishPartnerLocation) reaches B, whose partner_id is their account id, and
-- not E, whose partner_id is their partners.id. A fixture with the wrong id in
-- partner_id fails here, whatever the functions under test do with it.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000404b1');
with moved as (
  update public.ride_requests
     set partner_live_lat = 2.50, partner_live_lng = 101.50, partner_live_heading = 10.0, partner_live_at = now()
   where id = '00000000-0000-0000-0000-00000040ac02'
  returning 1)
select pg_temp.check((select count(*) = 1 from moved),
  'signed in as the driver, the app''s own position write reaches the ride that carries their account id');
with moved as (
  update public.ride_requests
     set partner_live_lat = 2.50, partner_live_lng = 101.50, partner_live_heading = 10.0, partner_live_at = now()
   where id = '00000000-0000-0000-0000-00000040ac05'
  returning 1)
select pg_temp.check((select count(*) = 0 from moved),
  'and not a ride that carries their partners.id: to the app that ride is not theirs');
reset role;

-- 1. trip_live_bridge as the rider: only the active booked ride moves ------------------------------
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404a1', 3.10, 101.60, null);
select pg_temp.check((select user_live_lat = 3.10 and user_live_lng = 101.60 and user_live_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac01'),
  'rider active ride gets the rider live columns');
select pg_temp.check((select user_live_lat is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac03'),
  'the rider''s finished ride is never moved');

-- 2. trip_live_bridge as the driver: heading kept, only the active ride moves ----------------------
-- The driver is the ride's partner_id, their account id (0429). On 0404's
-- match (partner_id = a partners.id) B stayed where the app left it and E moved.
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404b1', 3.20, 101.70, 88.0);
select pg_temp.check((select partner_live_lat = 3.20 and partner_live_lng = 101.70
                         and partner_live_heading = 88.0 and partner_live_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'driver active ride gets the partner live columns and heading');
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404b1', 3.21, 101.71, null);
select pg_temp.check((select partner_live_lat = 3.21 and partner_live_lng = 101.71 and partner_live_heading = 88.0
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'a fix with no heading moves the ride and keeps the last heading');
select pg_temp.check((select partner_live_lat is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac04'),
  'the driver''s cancelled ride is never moved');
select pg_temp.check((select partner_live_lat is null and partner_live_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac05'),
  'a ride whose partner_id is the driver''s partners.id is not their ride: never moved');
select pg_temp.check((select user_live_lat is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'the driver''s fix never lands in the rider''s columns');

-- 3. A profile on no active ride does nothing (and does not error) ---------------------------------
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404ff', 1.0, 2.0, null);
select pg_temp.check((select partner_live_lat = 3.21 from public.ride_requests
                       where id = '00000000-0000-0000-0000-00000040ac02')
                     and (select user_live_lat = 3.10 from public.ride_requests
                           where id = '00000000-0000-0000-0000-00000040ac01'),
  'a fix for a profile on no ride moves nothing');

-- 4. push_live_location feeds the trip even with no God View session open --------------------------
select pg_temp.check((public.push_live_location('rider-key-0404-rider-key-0404-rr', 4.11, 101.99) ->> 'live') = 'false',
  'no God View session, so the live answer is false');
select pg_temp.check((select user_live_lat = 4.11 and user_live_lng = 101.99
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac01'),
  'but the rider''s active ride still got the fix through the bridge');

-- 5. push_background_location feeds the trip for a driver (allowed to background-report) -----------
-- Called as the phone calls it: no session, the anon key, the install's key.
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_background_location('driver-key-0404-driver-key-0404-d', 5.22, 102.88) >= 1,
  'the driver''s background fix is taken');
reset role;
select pg_temp.check((select partner_live_lat = 5.22 and partner_live_lng = 102.88
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'the driver''s active ride got the background fix through the bridge');

-- 6. push_live_location feeds the driver's trip too, on every 5-second fix --------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_live_location('driver-key-0404-driver-key-0404-d', 6.33, 103.77) is not null,
  'the driver''s live fix is answered');
reset role;
select pg_temp.check((select partner_live_lat = 6.33 and partner_live_lng = 103.77 and partner_live_heading = 88.0
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'the driver''s active ride got the live fix through the bridge');
select pg_temp.check((select partner_live_lat is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac05'),
  'and the ride that carries their partners.id still has not moved');

-- 7. The bridge is the server's own: not callable through the API ----------------------------------
select pg_temp.check(
  not has_function_privilege('anon', 'public.trip_live_bridge(uuid, double precision, double precision, double precision)', 'execute')
  and not has_function_privilege('authenticated', 'public.trip_live_bridge(uuid, double precision, double precision, double precision)', 'execute'),
  'trip_live_bridge is not open to anon or authenticated');

rollback;
