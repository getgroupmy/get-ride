-- ============================================================================
-- Regression test for migration 0405: continuous live tracking during a trip.
--   * trip_live_kick wakes a participant whose active-trip fix is stale/missing
--     and may background-report; it throttles to one wake a minute a phone and
--     leaves a fresh fix (or an off-trip profile) alone.
--   * push_live_location keeps answering "live" (trip) while the poster is on an
--     active ride, with no God View session, and goes back to not-live once the
--     ride ends.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trip_live_sessions_0405.sql
--
-- Runs in one transaction and is rolled back. Made-up people only. The key is
-- 33 chars (push_live_location needs 32..128).
-- ============================================================================
begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000405b1') on conflict do nothing;
insert into public.profiles (id) select id from auth.users where id = '00000000-0000-0000-0000-0000000405b1' on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000405d1', '00000000-0000-0000-0000-0000000405b1', 'Test Driver 0405', '+60100004051',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;
-- The driver's active ride, with no live fix yet (stale).
insert into public.ride_requests (id, partner_id, status, partner_live_at) values
  ('00000000-0000-0000-0000-00000040bd01', '00000000-0000-0000-0000-0000000405d1', 'accepted', null)
on conflict (id) do nothing;
insert into public.push_tokens (id, profile_id, token, location_always, platform, bg_key_hash, ping_sent_at, updated_at) values
  ('00000000-0000-0000-0000-00000040f001', '00000000-0000-0000-0000-0000000405b1', 'tok-drv-0405', true, 'android',
   encode(extensions.digest(convert_to('drv-key-0405-drv-key-0405-drvxxxx', 'UTF8'), 'sha256'), 'hex'), null, now())
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;

-- 1. A stale active-trip fix wakes the driver's phone (and throttles after) -----------------------
select pg_temp.check(public.trip_live_kick() >= 1, 'a stale active-trip fix wakes the phone');
select pg_temp.check((select ping_sent_at is not null from public.push_tokens
                        where id = '00000000-0000-0000-0000-00000040f001'),
  'the woken phone is stamped so it is not re-woken at once');
select pg_temp.check(public.trip_live_kick() = 0, 'a phone woken seconds ago is not woken again');

-- 2. A fresh fix is left alone ---------------------------------------------------------------------
update public.push_tokens set ping_sent_at = null where id = '00000000-0000-0000-0000-00000040f001';
update public.ride_requests set partner_live_at = now() where id = '00000000-0000-0000-0000-00000040bd01';
select pg_temp.check(public.trip_live_kick() = 0, 'a trip with a fresh fix is not kicked');

-- 3. push_live_location keeps the stream alive during the trip (no God View session) --------------
update public.ride_requests set partner_live_at = null where id = '00000000-0000-0000-0000-00000040bd01';
select pg_temp.check(
  (public.push_live_location('drv-key-0405-drv-key-0405-drvxxxx', 3.33, 101.44)) @> '{"live":true,"trip":true}'::jsonb,
  'on an active trip, the live answer keeps the stream running');
select pg_temp.check((select partner_live_lat = 3.33 and partner_live_lng = 101.44
                        from public.ride_requests where id = '00000000-0000-0000-0000-00000040bd01'),
  'and the fix still reaches the trip dot (the 0404 bridge)');

-- 4. once the ride ends, the stream is told to stop -----------------------------------------------
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-00000040bd01';
select pg_temp.check(
  (public.push_live_location('drv-key-0405-drv-key-0405-drvxxxx', 3.33, 101.44) ->> 'live') = 'false',
  'off an active trip, the live answer is false so the phone stops');

rollback;
