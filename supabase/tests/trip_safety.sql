-- ============================================================================
-- Regression test for migration 0154: trip safety signals.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trip_safety.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000154a1'),  -- rider
  ('00000000-0000-0000-0000-0000000154b1'),  -- driver
  ('00000000-0000-0000-0000-0000000154c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000154%'
on conflict do nothing;

delete from public.settings_entries where id = '72656c69-6162-4c69-8000-000000000001';

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

create or replace function pg_temp.switches(p jsonb) returns void language sql as $$
  insert into public.settings_entries (id, category, values)
  values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging', p)
  on conflict (id) do update set values = excluded.values;
$$;

-- A ride waiting at the kerb, with both phones' live fixes [p_apart_m] metres apart (north-south).
create or replace function pg_temp.ride(p_id uuid, p_apart_m double precision) returns void language sql as $$
  insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                    partner_live_lat, partner_live_lng, partner_live_at,
                                    user_live_lat, user_live_lng, user_live_at)
  values (p_id, '00000000-0000-0000-0000-0000000154a1', '00000000-0000-0000-0000-0000000154b1',
          'arrived', 20, 20, 'KLCC',
          3.1579, 101.7116, now(), 3.1579 + p_apart_m / 111320.0, 101.7116, now());
$$;

-- 1. Turned off: a trip starting 2 km from the passenger isn't flagged (on by default
-- since 0269, city_ride_0269.sql) ---------------------------------------------------------
select pg_temp.switches('{"safety_start_check": false, "safety_separation": false}');
select pg_temp.ride('00000000-0000-0000-0000-0000000154e1', 2000);
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000154e1';
select pg_temp.check((select start_flag is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e1'),
                     'off: nothing is flagged');

-- 2. Start check on: far apart is flagged and the passenger asked; close by is not ----------
select pg_temp.switches('{"safety_start_check": true}');
select pg_temp.ride('00000000-0000-0000-0000-0000000154e2', 2000);
select pg_temp.ride('00000000-0000-0000-0000-0000000154e3', 20);
update public.ride_requests set status = 'on_trip'
 where id in ('00000000-0000-0000-0000-0000000154e2', '00000000-0000-0000-0000-0000000154e3');
select pg_temp.check((select start_flag = 'far_apart' and start_flag_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e2'),
                     'a trip started 2 km from the passenger is flagged');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where event_id = '00000000-0000-0000-0000-0000000154e2:start_check'
                                and profile_id = '00000000-0000-0000-0000-0000000154a1' and priority = 'critical'),
                     'the passenger is asked');
select pg_temp.check((select start_flag is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e3'),
                     'a trip started 20 m away is not');

-- 3. Both phones in the handshake but the passenger's never saw the car ----------------------
select pg_temp.switches('{"safety_start_check": true, "ble_enabled": true}');
select pg_temp.ride('00000000-0000-0000-0000-0000000154e4', 20);
select pg_temp.ride('00000000-0000-0000-0000-0000000154e5', 20);
insert into public.ride_ble_secrets (request_id, secret, rider_seen_at, driver_seen_at) values
  ('00000000-0000-0000-0000-0000000154e4', '\x00', now(), now()),
  ('00000000-0000-0000-0000-0000000154e5', '\x00', now(), now());
insert into public.ride_proximity_events (request_id, profile_id, side, matched, rssi, seen_ms, lat, lng) values
  ('00000000-0000-0000-0000-0000000154e5', '00000000-0000-0000-0000-0000000154a1', 'rider', true, -60, 6000, 3.1579, 101.7116);
update public.ride_requests set status = 'on_trip'
 where id in ('00000000-0000-0000-0000-0000000154e4', '00000000-0000-0000-0000-0000000154e5');
select pg_temp.check((select start_flag = 'no_proximity' from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e4'),
                     'the passenger''s phone never saw the car: flagged');
select pg_temp.check((select start_flag is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e5'),
                     'the passenger''s phone saw the car: not flagged');

-- 4. Mid-trip separation --------------------------------------------------------------------
select pg_temp.check(public.check_trip_separation() = 0, 'separation off: nothing checked');
select pg_temp.switches('{"safety_separation": true, "safety_separation_min": 3}');
-- e3 started 20 m apart; now the passenger's phone is 2 km away.
update public.ride_requests set user_live_lat = 3.1579 + 2000 / 111320.0, user_live_at = now(), partner_live_at = now()
 where id = '00000000-0000-0000-0000-0000000154e3';
select public.check_trip_separation();
select pg_temp.check((select apart_since is not null and separated_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e3'),
                     'apart: the clock starts, nobody is asked yet');
update public.ride_requests set apart_since = now() - interval '4 minutes'
 where id = '00000000-0000-0000-0000-0000000154e3';
select public.check_trip_separation();
select pg_temp.check((select separated_at is not null from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e3'),
                     'apart for 4 minutes: separated');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where event_id = '00000000-0000-0000-0000-0000000154e3:separated'),
                     'the passenger is asked if they''re still on the trip');

-- A Bluetooth sighting says they're together; coming back close stops the clock.
update public.ride_requests set user_live_lat = 3.1579 + 2000 / 111320.0, user_live_at = now(),
                                partner_live_at = now(), apart_since = now() - interval '10 minutes'
 where id = '00000000-0000-0000-0000-0000000154e2';
insert into public.ride_proximity_events (request_id, profile_id, side, matched, rssi, seen_ms) values
  ('00000000-0000-0000-0000-0000000154e2', '00000000-0000-0000-0000-0000000154b1', 'driver', true, -60, 6000);
select public.check_trip_separation();
select pg_temp.check((select separated_at is null and apart_since is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e2'),
                     'seen over Bluetooth: not separated');

-- 5. Only the passenger answers -------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000154b1');
select pg_temp.refused($q$select public.trip_safety_ok('00000000-0000-0000-0000-0000000154e3')$q$, 'the driver answering for the passenger');
select pg_temp.as_user('00000000-0000-0000-0000-0000000154a1');
select public.trip_safety_ok('00000000-0000-0000-0000-0000000154e3');
reset role;
select pg_temp.check((select safety_ack_at is not null from public.ride_requests where id = '00000000-0000-0000-0000-0000000154e3'),
                     'the passenger said they''re OK');

-- 6. Lost items ------------------------------------------------------------------------------------
update public.ride_requests set status = 'completed', completed_at = now()
 where id = '00000000-0000-0000-0000-0000000154e3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000154a1');
select pg_temp.refused($q$select public.report_lost_item('00000000-0000-0000-0000-0000000154e3', 'Black umbrella')$q$,
                       'reporting with the switch off');
reset role;
select pg_temp.switches('{"safety_lost_items": true}');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000154c1');
select pg_temp.refused($q$select public.report_lost_item('00000000-0000-0000-0000-0000000154e3', 'Black umbrella')$q$,
                       'a stranger reporting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000154a1');
select pg_temp.refused($q$select public.report_lost_item('00000000-0000-0000-0000-0000000154e2', 'Black umbrella')$q$,
                       'reporting on a trip that isn''t over');
select pg_temp.refused($q$select public.report_lost_item('00000000-0000-0000-0000-0000000154e3', ' ')$q$,
                       'reporting nothing');
do $$
declare
  v_item uuid := public.report_lost_item('00000000-0000-0000-0000-0000000154e3', 'Black umbrella');
begin
  perform pg_temp.check(v_item is not null, 'the passenger reports');
  perform public.report_lost_item('00000000-0000-0000-0000-0000000154e3', 'Phone charger');
  perform public.report_lost_item('00000000-0000-0000-0000-0000000154e3', 'Blue scarf');
  perform pg_temp.refused($q$select public.report_lost_item('00000000-0000-0000-0000-0000000154e3', 'Fourth thing')$q$,
                          'a fourth report the same day');
  perform pg_temp.refused(format($q$select public.respond_lost_item(%L, 'found')$q$, v_item),
                          'the passenger answering for the driver');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000154c1');
  perform pg_temp.check((select count(*) = 0 from public.ride_lost_items), 'a stranger reads no reports');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000154b1');
  perform pg_temp.check((select count(*) = 3 from public.ride_lost_items), 'the driver reads them');
  perform public.respond_lost_item(v_item, 'found', 'In the back seat');
end $$;
reset role;
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000154b1' and kind = 'lost_item'),
                     'the driver is told');
select pg_temp.check((select count(*) = 1 from public.ride_lost_items where status = 'found' and driver_note = 'In the back seat'),
                     'the driver''s answer is kept');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000154a1' and kind = 'lost_item'
                                and title = 'Your driver found it'),
                     'the passenger is told the answer');

-- 7. Only admins read the summary; clients can't run the checks ------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000154a1');
select pg_temp.refused($q$select * from public.trip_safety_summary(7)$q$, 'a passenger reading the summary');
reset role;
select pg_temp.check(not has_function_privilege('authenticated', 'public.check_trip_separation(timestamptz)', 'execute'),
                     'no client runs the separation check');

rollback;

select 'trip_safety: all passed';
