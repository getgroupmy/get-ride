-- ============================================================================
-- Regression test for migration 0404: the trip live bridge.
--   * trip_live_bridge updates the rider's live columns on a ride they booked,
--     and the driver's on a ride they run, only while it is active, and never
--     a ride the profile is not on.
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

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000404d1', '00000000-0000-0000-0000-0000000404b1', 'Test Driver 0404', '+60100004041',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;

-- Rides: A the rider's active trip, B the driver's active trip, C the rider's
-- finished trip (must never move), D the driver's cancelled trip.
insert into public.ride_requests (id, rider_id, partner_id, status) values
  ('00000000-0000-0000-0000-00000040ac01', '00000000-0000-0000-0000-0000000404a1', null, 'on_trip'),
  ('00000000-0000-0000-0000-00000040ac02', null, '00000000-0000-0000-0000-0000000404d1', 'accepted'),
  ('00000000-0000-0000-0000-00000040ac03', '00000000-0000-0000-0000-0000000404a1', null, 'completed'),
  ('00000000-0000-0000-0000-00000040ac04', null, '00000000-0000-0000-0000-0000000404d1', 'cancelled')
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

-- 1. trip_live_bridge as the rider: only the active booked ride moves ------------------------------
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404a1', 3.10, 101.60, null);
select pg_temp.check((select user_live_lat = 3.10 and user_live_lng = 101.60 and user_live_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac01'),
  'rider active ride gets the rider live columns');
select pg_temp.check((select user_live_lat is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac03'),
  'the rider''s finished ride is never moved');

-- 2. trip_live_bridge as the driver: heading kept, only the active ride moves ----------------------
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404b1', 3.20, 101.70, 88.0);
select pg_temp.check((select partner_live_lat = 3.20 and partner_live_lng = 101.70
                         and partner_live_heading = 88.0 and partner_live_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'driver active ride gets the partner live columns and heading');
select pg_temp.check((select partner_live_lat is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac04'),
  'the driver''s cancelled ride is never moved');

-- 3. A profile on no active ride does nothing (and does not error) ---------------------------------
select public.trip_live_bridge('00000000-0000-0000-0000-0000000404ff', 1.0, 2.0, null);

-- 4. push_live_location feeds the trip even with no God View session open --------------------------
select pg_temp.check((public.push_live_location('rider-key-0404-rider-key-0404-rr', 4.11, 101.99) ->> 'live') = 'false',
  'no God View session, so the live answer is false');
select pg_temp.check((select user_live_lat = 4.11 and user_live_lng = 101.99
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac01'),
  'but the rider''s active ride still got the fix through the bridge');

-- 5. push_background_location feeds the trip for a driver (allowed to background-report) -----------
select pg_temp.check(public.push_background_location('driver-key-0404-driver-key-0404-d', 5.22, 102.88) >= 1,
  'the driver''s background fix is taken');
select pg_temp.check((select partner_live_lat = 5.22 and partner_live_lng = 102.88
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040ac02'),
  'the driver''s active ride got the background fix through the bridge');

rollback;
