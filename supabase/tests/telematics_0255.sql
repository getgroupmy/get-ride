-- ============================================================================
-- Regression test for migration 0255: telematics. A driver reports only
-- their own rides and online km, each capped; the reports add the fixtures
-- up as expected; a driver sees only their own, an admin with the page
-- everyone, a fleet owner their fleet's vehicles, a stand person with
-- reports their stand's orders.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/telematics_0255.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('authenticated', 'public.telematics_trips(timestamptz, timestamptz, uuid, uuid, uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.telematics_access(uuid, uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.telematics_online(timestamptz, timestamptz, uuid, uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.telematics_summary(timestamptz, timestamptz, text, uuid, uuid, uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.telematics_report_online(numeric, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.telematics_ride_checkpoint(uuid, text, numeric, numeric, numeric)', 'execute') then
    raise exception 'FAILED: telematics function grants';
  end if;
  if has_table_privilege('authenticated', 'public.ride_telematics', 'insert')
     or has_table_privilege('authenticated', 'public.telematics_online_km', 'update')
     or has_table_privilege('authenticated', 'public.telematics_driver_state', 'select') then
    raise exception 'FAILED: the app writes telematics tables only through the RPCs';
  end if;
end
$$;

-- The pure helpers.
do $$
begin
  if public.telematics_plate_key(' wxy-1234 ') <> 'WXY1234' or public.telematics_plate_key('  ') is not null then
    raise exception 'FAILED: telematics_plate_key';
  end if;
  if public.telematics_trip_kind('call_centre', gen_random_uuid(), null, null, null, null, null, 'Ride') <> 'call_centre'
     or public.telematics_trip_kind('mall', gen_random_uuid(), gen_random_uuid(), null, null, null, null, 'Ride') <> 'stand'
     or public.telematics_trip_kind(null, null, gen_random_uuid(), gen_random_uuid(), null, null, null, 'Ride') <> 'airport'
     or public.telematics_trip_kind(null, null, null, gen_random_uuid(), null, null, null, 'Ride') <> 'scheduled'
     or public.telematics_trip_kind(null, null, null, null, array[gen_random_uuid()], null, null, 'Ride') <> 'my_ride'
     or public.telematics_trip_kind(null, null, null, null, '{}', null, 'tok', 'Ride') <> 'my_ride'
     or public.telematics_trip_kind(null, null, null, null, '{}', null, null, 'Comfort') <> 'service:Comfort'
     or public.telematics_trip_kind(null, null, null, null, null, null, null, ' ') <> 'service:Ride' then
    raise exception 'FAILED: telematics_trip_kind';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000255a1', '60125500001'),  -- full admin
  ('00000000-0000-0000-0000-0000000255a2', '60125500002'),  -- sub-admin: read on Telematics
  ('00000000-0000-0000-0000-0000000255a3', '60125500003'),  -- sub-admin: another page
  ('00000000-0000-0000-0000-0000000255d1', '60125500011'),  -- driver, drives the fleet's car
  ('00000000-0000-0000-0000-0000000255d2', '60125500012'),  -- driver, own car
  ('00000000-0000-0000-0000-0000000255f1', '60125500021'),  -- fleet owner
  ('00000000-0000-0000-0000-0000000255a5', '60125500031'),  -- stand admin
  ('00000000-0000-0000-0000-0000000255a6', '60125500032'),  -- stand staff, no reports
  ('00000000-0000-0000-0000-0000000255b1', '60125500041')   -- a rider
on conflict do nothing;
insert into public.profiles (id, name) select id, 'P' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000255%'
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000255a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000255a2', 'admin-telematics', 'read'),
  ('00000000-0000-0000-0000-0000000255a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status, plate, display_id) values
  ('00000000-0000-0000-0000-0000000255e1', '00000000-0000-0000-0000-0000000255d1', 'Ahmad', '60125500011', 'approved', 'WXY 1234', 'D-2551'),
  ('00000000-0000-0000-0000-0000000255e2', '00000000-0000-0000-0000-0000000255d2', 'Siti', '60125500012', 'approved', 'VBN 5521', 'D-2552'),
  ('00000000-0000-0000-0000-0000000255e3', '00000000-0000-0000-0000-0000000255f1', 'Sunlight Taxi', '60125500021', 'approved', null, 'D-2553');
insert into public.dispatch_groups (id, name, kind, fleet_owner_partner_id) values
  ('00000000-0000-0000-0000-0000000255c1', 'Sunlight Taxi', 'fleet', '00000000-0000-0000-0000-0000000255e3');
insert into public.dispatch_fleet_owners (group_id, user_id, name) values
  ('00000000-0000-0000-0000-0000000255c1', '00000000-0000-0000-0000-0000000255f1', 'Sunlight Taxi');
insert into public.vehicle (id, plate, make, model, auth_user_id, owner_partner_id, status) values
  ('00000000-0000-0000-0000-0000000255b6', 'WXY 1234', 'Perodua', 'Bezza', '00000000-0000-0000-0000-0000000255f1',
   '00000000-0000-0000-0000-0000000255e3', 'approved'),
  ('00000000-0000-0000-0000-0000000255b7', 'VBN 5521', 'Proton', 'Saga', '00000000-0000-0000-0000-0000000255d2',
   '00000000-0000-0000-0000-0000000255e2', 'approved');
insert into public.vehicle_active_session (vehicle_id, user_id, partner_id) values
  ('00000000-0000-0000-0000-0000000255b6', '00000000-0000-0000-0000-0000000255d1', '00000000-0000-0000-0000-0000000255e1');
insert into public.dispatch_stands (id, name, kind, code, lat, lng) values
  ('00000000-0000-0000-0000-0000000255c2', 'Pavilion 255', 'mall', 'PV255', 3.149, 101.713);
insert into public.dispatch_stand_people (stand_id, user_id, role, can_reports) values
  ('00000000-0000-0000-0000-0000000255c2', '00000000-0000-0000-0000-0000000255a5', 'admin', false),
  ('00000000-0000-0000-0000-0000000255c2', '00000000-0000-0000-0000-0000000255a6', 'staff', false);

-- The rides, all done in the last hour:
--   r1 Ahmad, Comfort: GPS checkpoints;          r2 Ahmad, a stand order: odometer;
--   r3 Siti, Ride: an older trip, estimate only; r4 Ahmad, Comfort: GPS beyond the cap;
--   r5 Ahmad, still on the way to the pickup.
insert into public.ride_requests (id, status, service, partner_id, partner_plate, distance_km,
    partner_accept_lat, partner_accept_lng, pickup_lat, pickup_lng, drop_lat, drop_lng,
    accepted_at, arrived_at, started_at, completed_at, stand_id, ticket_no, dispatch_mode) values
  ('00000000-0000-0000-0000-000000025501', 'completed', 'Comfort', '00000000-0000-0000-0000-0000000255d1', 'WXY 1234', 7,
   3.16, 101.70, 3.15, 101.70, 3.20, 101.70,
   now() - interval '50 minutes', now() - interval '40 minutes', now() - interval '38 minutes', now() - interval '10 minutes',
   null, null, null),
  ('00000000-0000-0000-0000-000000025502', 'completed', 'Ride', '00000000-0000-0000-0000-0000000255d1', 'WXY 1234', 9,
   3.16, 101.70, 3.15, 101.70, 3.22, 101.70,
   now() - interval '50 minutes', now() - interval '40 minutes', now() - interval '38 minutes', now() - interval '10 minutes',
   '00000000-0000-0000-0000-0000000255c2', 'PV255-0001', 'assign'),
  ('00000000-0000-0000-0000-000000025503', 'completed', 'Ride', '00000000-0000-0000-0000-0000000255d2', 'vbn5521', 5,
   null, null, 3.15, 101.70, 3.19, 101.70,
   now() - interval '50 minutes', now() - interval '40 minutes', now() - interval '38 minutes', now() - interval '10 minutes',
   null, null, null),
  ('00000000-0000-0000-0000-000000025504', 'completed', 'Comfort', '00000000-0000-0000-0000-0000000255d1', 'WXY 1234', 4,
   3.16, 101.70, 3.15, 101.70, 3.18, 101.70,
   now() - interval '50 minutes', now() - interval '40 minutes', now() - interval '38 minutes', now() - interval '10 minutes',
   null, null, null),
  ('00000000-0000-0000-0000-000000025505', 'accepted', 'Ride', '00000000-0000-0000-0000-0000000255d1', 'WXY 1234', 4,
   3.16, 101.70, 3.15, 101.70, 3.18, 101.70,
   now() - interval '5 minutes', null, null, null, null, null, null);
insert into public.meter_trips (id, partner_id, started_at, ended_at, distance_km, fare, total, plate) values
  ('00000000-0000-0000-0000-000000025511', '00000000-0000-0000-0000-0000000255d1',
   now() - interval '30 minutes', now() - interval '20 minutes', 6.5, 12, 12, 'WXY-1234');

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
-- The last two hours and the next one, by day.
create or replace function pg_temp.summary(p_driver uuid, p_vehicle uuid default null, p_fleet uuid default null,
                                           p_stand uuid default null) returns jsonb language sql as $$
  select public.telematics_summary(now() - interval '2 hours', now() + interval '1 hour', 'day',
                                   p_driver, p_vehicle, p_fleet, p_stand);
$$;
create or replace function pg_temp.list(p_group text, p_fleet uuid default null, p_stand uuid default null)
returns jsonb language sql as $$
  select public.telematics_list(now() - interval '2 hours', now() + interval '1 hour', p_group, p_fleet, p_stand);
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.summary(uuid, uuid, uuid, uuid), pg_temp.list(text, uuid, uuid) to authenticated;

set local role authenticated;

-- 1. Checkpoints: the ride's own driver, once each, capped ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000255d2');
select pg_temp.refused($q$select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'accept', null, null, 1.8)$q$,
  'another driver reporting a ride');

select pg_temp.as_user('00000000-0000-0000-0000-0000000255d1');
select pg_temp.check((select count(*) = 0 from public.ride_telematics), 'nothing written by the refused call');
select pg_temp.refused($q$select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025505', 'arrive', 1)$q$,
  'arriving on a ride still on its way');
select pg_temp.refused($q$select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'lunch', 1)$q$,
  'a stage that is not one');

-- r1: route estimate 1.8 km (the line is 1.11 km), GPS 2.0 to the pickup, 7.4 on the trip.
select pg_temp.check((public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'accept', null, null, 1.8)
                      ->>'est_pickup_km')::numeric = 1.80, 'the route estimate is kept');
select pg_temp.check((public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'arrive', 2.0)
                      ->>'actual_pickup_km')::numeric = 2.00, 'the GPS km to the pickup');
select pg_temp.check((public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'arrive', 9.0)
                      ->>'actual_pickup_km')::numeric = 2.00, 'reported once: a second arrive changes nothing');
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'start');
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025501', 'complete', 7.4);
select pg_temp.check((select actual_trip_km = 7.40 and trip_source = 'gps' and pickup_source = 'gps'
                        and vehicle_id = '00000000-0000-0000-0000-0000000255b6' and est_pickup_source = 'route'
                        and capped = '{}'
                        from public.ride_telematics where ride_id = '00000000-0000-0000-0000-000000025501'),
  'r1 on the active vehicle, GPS, nothing capped');

-- r2: the odometer wins over the GPS at both ends.
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025502', 'accept', null, 1000.0, null);
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025502', 'arrive', 3.1, 1002.5);
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025502', 'start', null, 1002.6);
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025502', 'complete', 7.0, 1010.6);
select pg_temp.check((select actual_pickup_km = 2.5 and pickup_source = 'obd' and actual_trip_km = 8.0
                        and trip_source = 'obd' and est_pickup_source = 'line' and est_pickup_km = 1.45
                        from public.ride_telematics where ride_id = '00000000-0000-0000-0000-000000025502'),
  'r2 by the odometer; no route came, so the line x 1.3');

-- r4: an estimate and a trip too long to be true are cut.
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025504', 'accept', null, null, 50);
select public.telematics_ride_checkpoint('00000000-0000-0000-0000-000000025504', 'complete', 500);
select pg_temp.check((select est_pickup_km = 8.34 and actual_trip_km = 17.00 and actual_pickup_km is null
                        and capped = '{est_pickup,actual_trip}'
                        from public.ride_telematics where ride_id = '00000000-0000-0000-0000-000000025504'),
  'r4: estimate cut to 3 x the line + 5, trip to 3 x the booking + 5');

-- The table is read-only to the app.
select pg_temp.refused($q$update public.ride_telematics set actual_trip_km = 1 where ride_id = '00000000-0000-0000-0000-000000025501'$q$,
  'the driver editing their km');

-- 2. Online km ------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000255d2');
select pg_temp.check(public.telematics_report_online(3)->>'reason' = 'offline', 'not online nor on a trip, nothing counted');
reset role;
insert into public.driver_presence (profile_id, online, updated_at)
values ('00000000-0000-0000-0000-0000000255d1', true, now());
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000255d1');
select pg_temp.check((public.telematics_report_online(3)->>'km')::numeric = 3, 'the first report');
select pg_temp.check((public.telematics_report_online(100)->>'km')::numeric = 0, 'no time since: nothing more');
reset role;
update public.telematics_driver_state set last_report_at = now() - interval '5 minutes'
 where driver_id = '00000000-0000-0000-0000-0000000255d1';
set local role authenticated;
select pg_temp.check((public.telematics_report_online(10, 'obd')->>'km')::numeric = 10, 'five minutes later, 10 km');
select pg_temp.check((select sum(km) = 13 and sum(obd_km) = 10 and sum(capped_km) = 100
                        and bool_and(vehicle_id = '00000000-0000-0000-0000-0000000255b6')
                        from public.telematics_online_km where driver_id = '00000000-0000-0000-0000-0000000255d1'),
  'online km on the active vehicle, the cut part apart');
select pg_temp.refused($q$select public.telematics_report_online(-1)$q$, 'negative km');
select pg_temp.as_user('00000000-0000-0000-0000-0000000255b1');
select pg_temp.refused($q$select public.telematics_report_online(1)$q$, 'a rider reporting km');

-- 3. The driver's own report --------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000255d1');
select pg_temp.check((select (s->>'trips')::int = 4 and (s->>'online_km')::numeric = 13
                        and (s->>'online_obd_km')::numeric = 10 and (s->>'mode') = 'self'
                        and (s->'km'->>'est_pickup')::numeric = 1.80 + 1.45 + 8.34
                        and (s->'km'->>'est_trip')::numeric = 7 + 9 + 4
                        and (s->'km'->>'act_pickup')::numeric = 4.5
                        and (s->'km'->>'act_trip')::numeric = 7.4 + 8.0 + 17.0 + 6.5
                        and (s->'km'->>'trip_pairs')::int = 3
                        and (s->'km'->>'est_trip_paired')::numeric = 20
                        and (s->'km'->>'act_trip_paired')::numeric = 32.4
                        and (s->'km'->>'obd')::int = 1
                        and s->'types' = '[{"kind": "service:Comfort", "trips": 2}, {"kind": "meter", "trips": 1},
                                            {"kind": "stand", "trips": 1}]'::jsonb
                        from pg_temp.summary('00000000-0000-0000-0000-0000000255d1') s),
  'Ahmad''s totals');
select pg_temp.check((select sum((b->>'trips')::int) = 4 and sum((b->>'online_km')::numeric) = 13
                        and sum((b->>'trip_km')::numeric) = 38.9
                        and sum((b->>'pickup_km')::numeric) = 2.0 + 2.5 + 8.34
                        and bool_and((b->>'other_km')::numeric >= 0) and sum((b->>'other_km')::numeric) <= 13
                        from jsonb_array_elements(pg_temp.summary('00000000-0000-0000-0000-0000000255d1')->'buckets') b),
  'the buckets add up; other is never below zero');
select pg_temp.check((select jsonb_array_length(public.telematics_summary('2026-10-19 16:00Z', '2026-10-20 16:00Z', 'hour')->'buckets') = 24),
  'a day by the hour is 24 buckets');
select pg_temp.check(jsonb_array_length(pg_temp.summary(null)->'buckets') between 1 and 2, 'the driver''s own, without naming them');
select pg_temp.check((pg_temp.summary(null, '00000000-0000-0000-0000-0000000255b7')->>'trips')::int = 0,
  'a driver filtering by a car they did not drive');
select pg_temp.refused($q$select pg_temp.summary('00000000-0000-0000-0000-0000000255d2')$q$, 'a driver reading another');
select pg_temp.refused($q$select public.telematics_summary(now() - interval '400 days', now(), 'day')$q$, 'more than a year');
select pg_temp.refused($q$select public.telematics_summary(now() - interval '30 days', now(), 'hour')$q$, 'a month by the hour');
select pg_temp.check((select count(*) = 1 and bool_and(r->>'plate' = 'WXY 1234') and bool_and((r->>'trips')::int = 4)
                        from jsonb_array_elements(pg_temp.list('vehicle')) r),
  'the driver''s own vehicles');
select pg_temp.check((select count(*) = 3 from public.ride_telematics), 'the driver reads their own rows');

-- 4. Admins ------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000255a2');
select pg_temp.check((select (s->>'trips')::int = 1 and s->'km'->>'act_trip' is null and (s->'km'->>'est_trip')::numeric = 5
                        and s->>'mode' = 'admin'
                        from pg_temp.summary('00000000-0000-0000-0000-0000000255d2') s),
  'an older trip: the estimate, no actual');
select pg_temp.check((pg_temp.summary(null, '00000000-0000-0000-0000-0000000255b7')->>'trips')::int = 1,
  'a ride with no telematics finds its vehicle by plate');
select pg_temp.check((pg_temp.summary(null, '00000000-0000-0000-0000-0000000255b6')->>'trips')::int = 4,
  'the fleet car: its rides and the meter hire by plate');
select pg_temp.check((select (s->>'trips')::int = 4 and (s->>'online_km')::numeric = 13
                        from pg_temp.summary('00000000-0000-0000-0000-0000000255d1', '00000000-0000-0000-0000-0000000255b6') s),
  'a driver in a vehicle');
select pg_temp.check((select count(*) = 2 from jsonb_array_elements(pg_temp.list('driver')) r
                       where r->>'driver_code' in ('D-2551', 'D-2552')),
  'the drivers in the period');
select pg_temp.check((select (r->>'online_km')::numeric = 13 and r->>'driver_name' = 'Ahmad'
                        from jsonb_array_elements(pg_temp.list('pair')) r where r->>'plate' = 'WXY 1234'),
  'the pair row');
select pg_temp.as_user('00000000-0000-0000-0000-0000000255a3');
select pg_temp.refused($q$select pg_temp.summary('00000000-0000-0000-0000-0000000255d2')$q$, 'an admin without the page');

-- 5. The fleet owner: their fleet's car only -----------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000255f1');
select pg_temp.check((select (s->>'trips')::int = 4 and (s->>'online_km')::numeric = 13 and s->>'mode' = 'fleet'
                        from pg_temp.summary(null, null, '00000000-0000-0000-0000-0000000255c1') s),
  'the fleet''s totals');
select pg_temp.check((pg_temp.summary('00000000-0000-0000-0000-0000000255d2', null, '00000000-0000-0000-0000-0000000255c1')->>'trips')::int = 0,
  'a driver outside the fleet''s cars shows nothing');
select pg_temp.check((select count(*) = 1 and bool_and(r->>'plate' = 'WXY 1234')
                        from jsonb_array_elements(pg_temp.list('vehicle', '00000000-0000-0000-0000-0000000255c1')) r),
  'the fleet''s vehicles in the period');
select pg_temp.refused($q$select pg_temp.summary('00000000-0000-0000-0000-0000000255d1')$q$, 'a fleet owner outside their fleet view');
select pg_temp.as_user('00000000-0000-0000-0000-0000000255d2');
select pg_temp.refused($q$select pg_temp.summary(null, null, '00000000-0000-0000-0000-0000000255c1')$q$, 'a driver reading a fleet');

-- 6. The stand: its orders, no online km -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000255a5');
select pg_temp.check((select (s->>'trips')::int = 1 and not (s->>'online_recorded')::boolean
                        and (s->'km'->>'act_trip')::numeric = 8.0 and s->'types' = '[{"kind": "stand", "trips": 1}]'::jsonb
                        from pg_temp.summary(null, null, null, '00000000-0000-0000-0000-0000000255c2') s),
  'the stand admin sees their stand''s order');
select pg_temp.check((select count(*) = 1 and bool_and((r->>'online_km')::numeric = 0)
                        from jsonb_array_elements(pg_temp.list('driver', null, '00000000-0000-0000-0000-0000000255c2')) r),
  'the stand''s drivers, no online km');
select pg_temp.as_user('00000000-0000-0000-0000-0000000255a6');
select pg_temp.refused($q$select pg_temp.summary(null, null, null, '00000000-0000-0000-0000-0000000255c2')$q$,
  'stand staff without reports');
select pg_temp.as_user('00000000-0000-0000-0000-0000000255b1');
select pg_temp.check(jsonb_array_length(pg_temp.list('driver')) = 0, 'a rider lists only themself: nobody');
select pg_temp.check((select count(*) = 0 from public.ride_telematics), 'a rider reads no telematics rows');

reset role;
select 'telematics_0255: all passed';
rollback;
