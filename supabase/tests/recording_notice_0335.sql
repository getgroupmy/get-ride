-- ============================================================================
-- Regression test for migration 0335, part 6: the passenger is told while
-- the driver's VoiceProtection records their trip.
--   * ride_requests.driver_audio starts off; only the trip's driver turns it
--     on (ride_set_driver_audio), and only while the trip is under way; off
--     any time;
--   * the passenger can't fake it or hide it, nor can another driver, nor an
--     admin's app session;
--   * it goes off by itself when the trip ends, is cancelled or changes
--     driver, so a phone that never says "stopped" leaves nothing behind;
--   * family_live and mygig_link_view carry it (driverAudio).
-- The app's half is in test/driver_recording_notice_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/recording_notice_0335.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- What [p_sql] does as [p_user]: 'ok <rows>', or the error.
create or replace function pg_temp.run_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare n integer;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
-- A value [p_sql] gives [p_user], as text.
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return v;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.audio(p_ride uuid) returns boolean language sql as $$
  select driver_audio from public.ride_requests where id = p_ride;
$$;
create or replace function pg_temp.set_audio(p_user uuid, p_ride uuid, p_on boolean) returns text language sql as $$
  select pg_temp.value_as(p_user, format('select public.ride_set_driver_audio(%L, %L)', p_ride, p_on));
$$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000335f1'),  -- passenger
  ('00000000-0000-0000-0000-0000000335f2'),  -- driver
  ('00000000-0000-0000-0000-0000000335f3'),  -- another driver
  ('00000000-0000-0000-0000-0000000335f4')   -- full admin
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000335f1', 'Pat Passenger', '+60100335001'),
  ('00000000-0000-0000-0000-0000000335f2', 'Dan Driver', '+60100335002'),
  ('00000000-0000-0000-0000-0000000335f3', 'Ola Other', '+60100335003'),
  ('00000000-0000-0000-0000-0000000335f4', 'Ada Admin', '+60100335004')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000335f4', '*', 'edit')
on conflict do nothing;

-- A ride the server writes: booked, taken, then under way.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, country)
values ('00000000-0000-0000-0000-0000000335d1', '00000000-0000-0000-0000-0000000335f1', 'open', 3.1, 101.6, 15, 15,
        'Malaysia');
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'a new ride starts with it off');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000335f2', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000335d1';

-- ---- Before the trip starts ----------------------------------------------------------------------
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', true)
  like '%DRIVER_AUDIO_NOT_ON_TRIP%', 'not on before the trip is under way');

update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000335d1';

-- ---- Who turns it on -----------------------------------------------------------------------------
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f1', '00000000-0000-0000-0000-0000000335d1', true)
  like '%DRIVER_AUDIO_DRIVER_ONLY%', 'the passenger can''t fake it');
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f3', '00000000-0000-0000-0000-0000000335d1', true)
  like '%DRIVER_AUDIO_DRIVER_ONLY%', 'nor another driver');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000335f1',
    $q$update public.ride_requests set driver_audio = true where id = '00000000-0000-0000-0000-0000000335d1'$q$)
  not like 'ok 1', 'nor the passenger by writing the ride');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000335f4',
    $q$update public.ride_requests set driver_audio = true where id = '00000000-0000-0000-0000-0000000335d1'$q$)
  not like 'ok 1', 'nor an admin''s app session');
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'still off');

select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', true) = 'true',
  'the driver''s phone says it is recording');
select pg_temp.check(pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'the ride says so');
select pg_temp.check(public.ride_driver_audio_now(r), 'the passenger is shown it')
  from public.ride_requests r where id = '00000000-0000-0000-0000-0000000335d1';
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000335f1',
    $q$select driver_audio from public.ride_requests where id = '00000000-0000-0000-0000-0000000335d1'$q$) = 'true',
  'the passenger reads it on their ride');
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', true) = 'true',
  'saying it again changes nothing');

-- ---- Hiding it -----------------------------------------------------------------------------------
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f1', '00000000-0000-0000-0000-0000000335d1', false)
  like '%DRIVER_AUDIO_DRIVER_ONLY%', 'the passenger can''t hide it');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000335f1',
    $q$update public.ride_requests set driver_audio = false where id = '00000000-0000-0000-0000-0000000335d1'$q$)
  not like 'ok 1', 'nor by writing the ride');
select pg_temp.check(pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'still on');

-- ---- Off -----------------------------------------------------------------------------------------
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', false) = 'false',
  'the driver''s phone says it stopped');
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'off');
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', true) = 'true',
  'recording again (the driver came back to the trip screen)');
select pg_temp.check(pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'on again');

-- ---- Tied to the trip ----------------------------------------------------------------------------
-- The trip ends while the phone still says "recording" (it never said stop).
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000335d1';
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'the end of the trip turns it off');
select pg_temp.check(not public.ride_driver_audio_now(r), 'nothing is shown after the trip')
  from public.ride_requests r where id = '00000000-0000-0000-0000-0000000335d1';
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', true)
  like '%DRIVER_AUDIO_NOT_ON_TRIP%', 'not on after the trip');
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d1', false) = 'false',
  'off after the trip is no error (the phone files on its way out)');
-- Even the server can't leave it on a trip that is not under way.
update public.ride_requests set driver_audio = true where id = '00000000-0000-0000-0000-0000000335d1';
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d1'), 'not on a finished trip, whoever writes');

-- A second ride: handed to another driver mid-trip, then cancelled.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, country)
values ('00000000-0000-0000-0000-0000000335d2', '00000000-0000-0000-0000-0000000335f1', 'open', 3.1, 101.6, 15, 15,
        'Malaysia');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000335f2', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000335d2';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000335d2';
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d2', true) = 'true',
  'recording the second ride');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000335f3'
 where id = '00000000-0000-0000-0000-0000000335d2';
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d2'), 'a new driver: off');
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f2', '00000000-0000-0000-0000-0000000335d2', true)
  like '%DRIVER_AUDIO_DRIVER_ONLY%', 'the first driver no longer says');
select pg_temp.check(
  pg_temp.set_audio('00000000-0000-0000-0000-0000000335f3', '00000000-0000-0000-0000-0000000335d2', true) = 'true',
  'the new driver''s phone says it records');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000335d2';
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d2'), 'a cancelled trip: off');

-- A booking that sends it on: booked with it off (whoever writes it).
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, country, driver_audio)
values ('00000000-0000-0000-0000-0000000335d3', '00000000-0000-0000-0000-0000000335f1', 'open', 3.1, 101.6, 15, 15,
        'Malaysia', true);
select pg_temp.check(not pg_temp.audio('00000000-0000-0000-0000-0000000335d3'), 'booked with it off');

-- ---- Family and myGiG carry it ---------------------------------------------------------------------
select pg_temp.check(pg_get_functiondef('public.family_live()'::regprocedure) like '%''driverAudio''%',
  'family_live says whether the driver records');
select pg_temp.check(pg_get_functiondef('public.mygig_link_view(text)'::regprocedure) like '%''driverAudio''%',
  'mygig_link_view says whether the driver records');
select pg_temp.check(
  not has_function_privilege('anon', 'public.ride_set_driver_audio(uuid, boolean)', 'execute'),
  'no signed-out caller');

rollback;
