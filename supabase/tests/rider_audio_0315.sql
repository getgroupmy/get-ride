-- ============================================================================
-- Regression test for migration 0315: rider audio protection.
--   * the settings by place: Default on, 24 hours; the smallest place that
--     sets a part decides it; who writes them; Default stays;
--   * ride_requests.rider_audio: a booking where it is off is booked with it
--     off; only the rider changes it, on only while the ride is under way
--     and where it is on (ride_set_rider_audio);
--   * a rider's recording: their own ride with it on, kept for the hours at
--     the pickup; recorded_by is the server's; a driver's row as before.
-- The app's twin of the place rule is in test/rider_audio_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rider_audio_0315.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000315a1'),  -- admin, EDIT on Rider audio protection
  ('00000000-0000-0000-0000-0000000315a2'),  -- admin, READ on it
  ('00000000-0000-0000-0000-0000000315c1'),  -- riders
  ('00000000-0000-0000-0000-0000000315c2'),
  ('00000000-0000-0000-0000-0000000315c3'),
  ('00000000-0000-0000-0000-0000000315c4'),
  ('00000000-0000-0000-0000-0000000315d1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000315%'
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000315a1', 'admin-settings-rider-audio', 'edit'),
  ('00000000-0000-0000-0000-0000000315a2', 'admin-settings-rider-audio', 'read')
on conflict do nothing;

-- Audioland 315 holds the pickups; Hushstate 315 inside it turns audio off,
-- and its city Loudtown 315 turns it back on. Quiettown 315, Hushstate's other
-- city, has no rule of its own: a state with cities serves only inside them
-- (the coverage guard, 0125/0212), so Hushstate's bookings are made there.
insert into public.countries (name, values, geofence) values
  ('Audioland 315', '{}', jsonb_build_object('boundary', '{"bbox":{"north":-20,"south":-30,"east":-20,"west":-30}}'));
insert into public.states (country, name, values, geofence) values
  ('Audioland 315', 'Hushstate 315', '{}', jsonb_build_object('boundary',
    '{"bbox":{"north":-24,"south":-26,"east":-24,"west":-26}}')),
  ('Audioland 315', 'Openstate 315', '{}', jsonb_build_object('boundary',
    '{"bbox":{"north":-21,"south":-23,"east":-21,"west":-23}}'));
insert into public.cities (country, state, name, values, geofence) values
  ('Audioland 315', 'Hushstate 315', 'Loudtown 315', '{}', jsonb_build_object('boundary',
    '{"bbox":{"north":-24.9,"south":-25.1,"east":-24.9,"west":-25.1}}')),
  ('Audioland 315', 'Hushstate 315', 'Quiettown 315', '{}', jsonb_build_object('boundary',
    '{"bbox":{"north":-25.3,"south":-25.8,"east":-25.3,"west":-25.8}}'));
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000031551', 'vehicle-services', '{"name":"Ride 315"}', 1);

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
create or replace function pg_temp.place(p_state text, p_city text default null) returns jsonb language sql as $$
  select public.rider_audio_settings_at('Audioland 315', p_state, p_city, null);
$$;

-- ---- 1. The settings by place -------------------------------------------------------------------
select pg_temp.check(
  (select enabled and keep_hours = 24 from public.rider_audio_rules where level = 'default'),
  'Default: on, 24 hours');
select pg_temp.check(pg_temp.place('Nowhere 315') = '{"enabled": true, "keepHours": 24}'::jsonb,
  'a place with no rule of its own: Default');

-- Who writes them.
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c1',
    $q$insert into public.rider_audio_rules (level, country, enabled) values ('country', 'Audioland 315', false)$q$)
  not like 'ok%', 'a rider can''t write a rule');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a2',
    $q$insert into public.rider_audio_rules (level, country, enabled) values ('country', 'Audioland 315', false)$q$)
  not like 'ok%', 'an admin with READ can''t write a rule');
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315c1',
    $q$select count(*) from public.rider_audio_rules where level = 'default'$q$) = '1',
  'everyone signed in reads the rules');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1', $q$
    insert into public.rider_audio_rules (level, country, keep_hours) values ('country', 'Audioland 315', 48);
    insert into public.rider_audio_rules (level, country, state, enabled) values ('state', 'Audioland 315', 'Hushstate 315', false);
    insert into public.rider_audio_rules (level, country, state, city, enabled, keep_hours)
      values ('city', 'Audioland 315', 'Hushstate 315', 'Loudtown 315', true, 6)$q$) like 'ok%',
  'an admin with EDIT writes rules');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1',
    $q$insert into public.rider_audio_rules (level, country, keep_hours) values ('country', 'AUDIOLAND 315', 12)$q$)
  not like 'ok%', 'one rule per place');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1',
    $q$insert into public.rider_audio_rules (level, country, keep_hours) values ('country', 'Elsewhere 315', 169)$q$)
  not like 'ok%', 'at most 168 hours');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1',
    $q$insert into public.rider_audio_rules (level, state, enabled) values ('state', 'Hushstate 315', false)$q$)
  not like 'ok%', 'a state names its country');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1',
    $q$update public.rider_audio_rules set enabled = null where level = 'default'$q$)
  not like 'ok%', 'Default sets both parts');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1',
    $q$delete from public.rider_audio_rules where level = 'default'$q$) like '%RIDER_AUDIO_DEFAULT_STAYS%',
  'Default can''t be deleted');

-- The smallest place that sets a part decides it.
select pg_temp.check(pg_temp.place('Openstate 315') = '{"enabled": true, "keepHours": 48}'::jsonb,
  'the country''s hours, Default''s on');
select pg_temp.check(pg_temp.place('Hushstate 315') = '{"enabled": false, "keepHours": 48}'::jsonb,
  'the state turns it off and keeps the country''s hours');
select pg_temp.check(pg_temp.place('Hushstate 315', 'Loudtown 315') = '{"enabled": true, "keepHours": 6}'::jsonb,
  'the city turns it back on, with its own hours');
select pg_temp.check(public.rider_audio_settings_at(' audioland 315 ', 'HUSHSTATE 315', null, null)
  = '{"enabled": false, "keepHours": 48}'::jsonb, 'names match whatever their case and spaces');
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315c1',
    $q$select public.rider_audio_at(-25.5, -25.5, 'Audioland 315', 'Hushstate 315', null)->>'enabled'$q$) = 'false',
  'the app reads it at a pickup');
select pg_temp.check(
  not has_function_privilege('authenticated', 'public.rider_audio_settings_at(text, text, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.rider_audio_at(double precision, double precision, text, text, text)', 'execute')
  and has_function_privilege('authenticated', 'public.ride_set_rider_audio(uuid, boolean)', 'execute')
  and not has_function_privilege('anon', 'public.ride_set_rider_audio(uuid, boolean)', 'execute'),
  'the grants');

-- ---- 2. The ride says whether the rider has it on -----------------------------------------------
-- Bookings by the app: on where it is on, booked with it off where it isn't.
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c1', $q$
    insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                      drop_lat, drop_lng, country, state, rider_audio)
    values ('00000000-0000-0000-0000-000000031501', '00000000-0000-0000-0000-0000000315c1', 'open', 'Ride 315',
            30, 30, -22, -22, -22.1, -22.1, 'Audioland 315', 'Openstate 315', true)$q$) = 'ok 1',
  'a booking in Openstate');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c2', $q$
    insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                      drop_lat, drop_lng, country, state, rider_audio)
    values ('00000000-0000-0000-0000-000000031502', '00000000-0000-0000-0000-0000000315c2', 'open', 'Ride 315',
            30, 30, -25.5, -25.5, -25.6, -25.6, 'Audioland 315', 'Hushstate 315', true)$q$) = 'ok 1',
  'a booking in Hushstate is not refused');
select pg_temp.check((select rider_audio from public.ride_requests where id = '00000000-0000-0000-0000-000000031501'),
  'on where it is on');
select pg_temp.check(not (select rider_audio from public.ride_requests where id = '00000000-0000-0000-0000-000000031502'),
  'booked with it off where it is off');

-- Rides the server writes: one under way (in Loudtown), one that ended.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, country, state, city, fare)
values
  ('00000000-0000-0000-0000-000000031503', '00000000-0000-0000-0000-0000000315c3',
   'open', -25, -25, 'Audioland 315', 'Hushstate 315', 'Loudtown 315', 20),
  ('00000000-0000-0000-0000-000000031504', '00000000-0000-0000-0000-0000000315c4', 'cancelled', -22, -22,
   'Audioland 315', 'Openstate 315', null, 20);

select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315d1',
    $q$select public.ride_set_rider_audio('00000000-0000-0000-0000-000000031503', true)$q$)
  like '%RIDER_AUDIO_RIDER_ONLY%', 'somebody else can''t turn the rider''s on');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315d1',
    $q$update public.ride_requests set rider_audio = true where id = '00000000-0000-0000-0000-000000031503'$q$)
  not like 'ok 1', 'nor by writing the ride');
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315c3',
    $q$select public.ride_set_rider_audio('00000000-0000-0000-0000-000000031503', true)$q$) = 'true',
  'the rider turns it on for their ride under way');
select pg_temp.check((select rider_audio from public.ride_requests where id = '00000000-0000-0000-0000-000000031503'),
  'the ride says so (the driver sees it)');
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315c4',
    $q$select public.ride_set_rider_audio('00000000-0000-0000-0000-000000031504', true)$q$)
  like '%RIDER_AUDIO_OFF_HERE%', 'not on a ride that has ended');
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315c2',
    $q$select public.ride_set_rider_audio('00000000-0000-0000-0000-000000031502', true)$q$)
  like '%RIDER_AUDIO_OFF_HERE%', 'not where it is off');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c2',
    $q$update public.ride_requests set rider_audio = true where id = '00000000-0000-0000-0000-000000031502'$q$)
  not like 'ok 1', 'nor by writing the ride where it is off');
select pg_temp.check(
  pg_temp.value_as('00000000-0000-0000-0000-0000000315c1',
    $q$select public.ride_set_rider_audio('00000000-0000-0000-0000-000000031501', false)$q$) = 'false',
  'off any time');
select pg_temp.check(not (select rider_audio from public.ride_requests where id = '00000000-0000-0000-0000-000000031501'),
  'and the ride says so');

-- ---- 3. A rider's recording ---------------------------------------------------------------------
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c3', $q$
    insert into public.voice_protection_recordings (id, profile_id, ride_id, recorded_at, expires_at, recorded_by,
                                                     duration_sec)
    values ('00000000-0000-0000-0000-0000000315e1', '00000000-0000-0000-0000-0000000315c3',
            '00000000-0000-0000-0000-000000031503', now() - interval '10 minutes', now() + interval '30 days',
            'rider', 600)$q$) = 'ok 1',
  'the rider files the recording of their ride');
select pg_temp.check(
  (select expires_at = recorded_at + interval '6 hours' and recorded_by = 'rider'
     from public.voice_protection_recordings where id = '00000000-0000-0000-0000-0000000315e1'),
  'kept for the hours at the pickup, whatever the phone sent');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c3', $q$
    update public.voice_protection_recordings set recorded_by = 'driver'
     where id = '00000000-0000-0000-0000-0000000315e1'$q$) like '%VOICE_RECORDING_SERVER_ONLY%',
  'recorded_by is the server''s');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c1', $q$
    insert into public.voice_protection_recordings (profile_id, ride_id, recorded_by)
    values ('00000000-0000-0000-0000-0000000315c1', '00000000-0000-0000-0000-000000031501', 'rider')$q$)
  like '%RIDER_AUDIO_NOT_ALLOWED%', 'not of a ride with it off');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c1', $q$
    insert into public.voice_protection_recordings (profile_id, ride_id, recorded_by)
    values ('00000000-0000-0000-0000-0000000315c1', '00000000-0000-0000-0000-000000031503', 'rider')$q$)
  like '%RIDER_AUDIO_NOT_ALLOWED%', 'not of somebody else''s ride');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c1', $q$
    insert into public.voice_protection_recordings (profile_id, ride_id, recorded_by)
    values ('00000000-0000-0000-0000-0000000315c1', 'not-a-ride', 'rider')$q$)
  like '%RIDER_AUDIO_NOT_ALLOWED%', 'not without a ride');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315a1', $q$
    update public.rider_audio_rules set enabled = false
     where place_key = 'audioland 315|hushstate 315|loudtown 315'$q$) = 'ok 1',
  'the admin turns it off in Loudtown');
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315c3', $q$
    insert into public.voice_protection_recordings (profile_id, ride_id, recorded_by)
    values ('00000000-0000-0000-0000-0000000315c3', '00000000-0000-0000-0000-000000031503', 'rider')$q$)
  like '%RIDER_AUDIO_NOT_ALLOWED%', 'not once it is off at the pickup');

-- The driver's VoiceProtection is as before.
select pg_temp.check(
  pg_temp.run_as('00000000-0000-0000-0000-0000000315d1', $q$
    insert into public.voice_protection_recordings (id, profile_id, ride_id)
    values ('00000000-0000-0000-0000-0000000315e2', '00000000-0000-0000-0000-0000000315d1',
            '00000000-0000-0000-0000-000000031503')$q$) = 'ok 1',
  'the driver files their own recording');
select pg_temp.check(
  (select recorded_by = 'driver' from public.voice_protection_recordings
    where id = '00000000-0000-0000-0000-0000000315e2'),
  'a driver''s recording is the driver''s');

rollback;
