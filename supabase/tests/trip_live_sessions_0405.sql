-- ============================================================================
-- Regression test for migration 0405: continuous live tracking during a trip
-- (driver match corrected in 0429).
--   * trip_live_kick wakes a participant whose active-trip fix is stale/missing
--     and may background-report; it throttles to one wake a minute a phone and
--     leaves a fresh fix (or an off-trip profile) alone.
--   * push_live_location keeps answering "live" (trip) while the poster is on an
--     active ride, with no God View session, and goes back to not-live once the
--     ride ends.
--   * The driver of a ride is ride_requests.partner_id = the driver's own
--     account id (their auth uid), as the app writes it when a ride is taken.
--     It is never a partners.id: 0405 matched on that, which no real ride
--     holds, and this test hid it by putting one there (0429).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trip_live_sessions_0405.sql
--
-- Runs in one transaction and is rolled back. Made-up people only. The keys are
-- 33 chars (push_live_location needs 32..128).
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000405a1'),  -- rider
  ('00000000-0000-0000-0000-0000000405b1'),  -- driver, on the ride
  ('00000000-0000-0000-0000-0000000405b2')   -- another driver, on no ride
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000405%'
on conflict do nothing;
-- Each driver's partner row. Its id (…0405d1, …0405d2) is not the driver's
-- account id, as for every real partner.
insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000405d1', '00000000-0000-0000-0000-0000000405b1', 'Test Driver 0405', '+60100004051',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000405d2', '00000000-0000-0000-0000-0000000405b2', 'Other Driver 0405', '+60100004052',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;
-- The driver's active ride, with no live fix yet (stale): partner_id is the
-- driver's account id, as on a ride the app has taken. The second ride is
-- nobody's: its partner_id is the other driver's partners.id, the id 0405
-- looked for. That driver is on no ride and must never be woken or kept live.
insert into public.ride_requests (id, rider_id, partner_id, status, partner_live_at) values
  ('00000000-0000-0000-0000-00000040bd01', '00000000-0000-0000-0000-0000000405a1',
   '00000000-0000-0000-0000-0000000405b1', 'accepted', null),
  ('00000000-0000-0000-0000-00000040bd02', null,
   '00000000-0000-0000-0000-0000000405d2', 'accepted', null)
on conflict (id) do nothing;
insert into public.push_tokens (id, profile_id, token, location_always, platform, bg_key_hash, ping_sent_at, updated_at) values
  ('00000000-0000-0000-0000-00000040f001', '00000000-0000-0000-0000-0000000405b1', 'tok-drv-0405', true, 'android',
   encode(extensions.digest(convert_to('drv-key-0405-drv-key-0405-drvxxxx', 'UTF8'), 'sha256'), 'hex'), null, now()),
  ('00000000-0000-0000-0000-00000040f002', '00000000-0000-0000-0000-0000000405b2', 'tok-oth-0405', true, 'android',
   encode(extensions.digest(convert_to('oth-key-0405-oth-key-0405-othxxxx', 'UTF8'), 'sha256'), 'hex'), null, now())
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;

-- The signed-in app, and the phone's native stream (no session, the anon key).
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

-- 0. The ride above is the driver's as the app itself sees it --------------------------------------
-- Signed in, the driver reads the ride that carries their account id; the other
-- driver does not read the ride that carries their partners.id. A fixture with
-- the wrong id in partner_id fails here, whatever the functions under test do.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000405b1');
select pg_temp.check((select count(*) = 1 from public.ride_requests
                       where id = '00000000-0000-0000-0000-00000040bd01'),
  'signed in, the driver reads the ride that carries their account id');
select pg_temp.as_user('00000000-0000-0000-0000-0000000405b2');
select pg_temp.check((select count(*) = 0 from public.ride_requests
                       where id = '00000000-0000-0000-0000-00000040bd02'),
  'the other driver does not read the ride that carries their partners.id: to the app it is not theirs');
reset role;

-- 1. Who is on an active ride ----------------------------------------------------------------------
-- On 0405's match (partner_id = a partners.id) the driver was not on their own
-- ride, and the other driver was on a ride they had never taken.
select pg_temp.check(public.profile_on_active_trip('00000000-0000-0000-0000-0000000405b1'),
  'the driver is on their active ride');
select pg_temp.check(public.profile_on_active_trip('00000000-0000-0000-0000-0000000405a1'),
  'the rider is on their active ride');
select pg_temp.check(not public.profile_on_active_trip('00000000-0000-0000-0000-0000000405b2'),
  'a driver whose partners.id is on a ride is not on that ride');
select pg_temp.check(not public.profile_on_active_trip('00000000-0000-0000-0000-0000000405d1')
                     and not public.profile_on_active_trip(null),
  'a partners.id, or nobody, is on no ride');

-- 2. A stale active-trip fix wakes the driver's phone (and throttles after) -----------------------
select pg_temp.check(public.trip_live_kick() >= 1, 'a stale active-trip fix wakes the phone');
select pg_temp.check((select ping_sent_at is not null from public.push_tokens
                        where id = '00000000-0000-0000-0000-00000040f001'),
  'the woken phone is the driver''s, stamped so it is not re-woken at once');
select pg_temp.check((select ping_sent_at is null from public.push_tokens
                        where id = '00000000-0000-0000-0000-00000040f002'),
  'the other driver, on no ride, is not woken');
select pg_temp.check(public.trip_live_kick() = 0, 'a phone woken seconds ago is not woken again');

-- 3. A fresh fix is left alone ---------------------------------------------------------------------
update public.push_tokens set ping_sent_at = null where id = '00000000-0000-0000-0000-00000040f001';
update public.ride_requests set partner_live_at = now() where id = '00000000-0000-0000-0000-00000040bd01';
select pg_temp.check(public.trip_live_kick() = 0, 'a trip with a fresh fix is not kicked');
-- A fix gone stale again (older than 45 s) wakes the phone again; its last wake
-- was cleared above, as the minute's throttle running out would.
update public.ride_requests set partner_live_at = now() - interval '46 seconds'
 where id = '00000000-0000-0000-0000-00000040bd01';
select pg_temp.check(public.trip_live_kick() >= 1, 'a fix older than 45 seconds wakes the driver''s phone');
select pg_temp.check((select ping_sent_at is not null from public.push_tokens
                        where id = '00000000-0000-0000-0000-00000040f001')
                     and (select ping_sent_at is null from public.push_tokens
                           where id = '00000000-0000-0000-0000-00000040f002'),
  'again the driver''s phone, and only theirs');

-- 4. push_live_location keeps the stream alive during the trip (no God View session) --------------
-- Called as the phone calls it: no session, the anon key, the install's key.
update public.ride_requests set partner_live_at = null where id = '00000000-0000-0000-0000-00000040bd01';
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(
  (public.push_live_location('drv-key-0405-drv-key-0405-drvxxxx', 3.33, 101.44)) @> '{"live":true,"trip":true}'::jsonb,
  'on an active trip, the live answer keeps the stream running');
select pg_temp.check(
  (public.push_live_location('oth-key-0405-oth-key-0405-othxxxx', 9.99, 109.99) ->> 'live') = 'false',
  'a driver on no ride is told to stop, though a ride carries their partners.id');
reset role;
select pg_temp.check((select partner_live_lat = 3.33 and partner_live_lng = 101.44
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040bd01'),
  'and the fix still reaches the trip dot (the 0404 bridge)');
select pg_temp.check((select partner_live_lat is null and partner_live_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040bd02'),
  'the other driver''s fix reaches no ride');

-- 5. once the ride ends, the stream is told to stop -----------------------------------------------
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-00000040bd01';
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(
  (public.push_live_location('drv-key-0405-drv-key-0405-drvxxxx', 3.34, 101.45) ->> 'live') = 'false',
  'off an active trip, the live answer is false so the phone stops');
reset role;
select pg_temp.check((select partner_live_lat = 3.33 from public.ride_requests
                       where id = '00000000-0000-0000-0000-00000040bd01'),
  'and a finished ride is not moved by a late fix');
select pg_temp.check(not public.profile_on_active_trip('00000000-0000-0000-0000-0000000405b1'),
  'the driver is on no active ride any more');
update public.push_tokens set ping_sent_at = null where id = '00000000-0000-0000-0000-00000040f001';
select public.trip_live_kick();
select pg_temp.check((select ping_sent_at is null from public.push_tokens
                        where id = '00000000-0000-0000-0000-00000040f001'),
  'nor is their phone woken once the ride has ended');

-- 6. These are the server's own: not callable through the API --------------------------------------
select pg_temp.check(
  not has_function_privilege('anon', 'public.profile_on_active_trip(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.profile_on_active_trip(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.trip_live_kick()', 'execute')
  and not has_function_privilege('authenticated', 'public.trip_live_kick()', 'execute'),
  'profile_on_active_trip and trip_live_kick are not open to anon or authenticated');
select pg_temp.check(
  has_function_privilege('anon', 'public.push_live_location(text, double precision, double precision, double precision, double precision)', 'execute'),
  'push_live_location stays open to the phone''s keyed call');

rollback;
