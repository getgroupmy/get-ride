-- ============================================================================
-- Regression test for migration 0263: driver services.
--   * a driver's switches are kept per vehicle, and only for vehicles they
--     may drive, in their own name;
--   * a lock wins over the switch, the most specific one first (driver,
--     fleet, region city / state / country, partner type, everyone); one
--     past its end counts for nothing;
--   * only the page's EDIT admins write locks; every change is logged with
--     who made it; drivers read only the locks that apply to them;
--   * an open request whose service is off is hidden from that driver, not
--     from its rider or admins; a bid on one is refused;
--   * add-on locks reach the 0253 extras (the guide dog is an add-on like any other);
--   * the Services page's read.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_services_0263.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's: nobody is held up by them.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000263a1'),  -- admin, EDIT on Driver service locks
  ('00000000-0000-0000-0000-0000000263a2'),  -- admin, READ on Driver service locks
  ('00000000-0000-0000-0000-0000000263c1'),  -- rider
  ('00000000-0000-0000-0000-0000000263d1'),  -- driver: eHailing, two cars, a fleet, Selangor
  ('00000000-0000-0000-0000-0000000263d2'),  -- driver: eHailing, Penang
  ('00000000-0000-0000-0000-0000000263d3')   -- driver: Teksi
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000263%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000263a1', 'admin-settings-driver-service-locks', 'edit'),
  ('00000000-0000-0000-0000-0000000263a2', 'admin-settings-driver-service-locks', 'read')
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states) values
  ('00000000-0000-0000-0000-0000000263e1', '00000000-0000-0000-0000-0000000263d1', 'Test Driver One', '+60100002631',
   'approved', '{eHailing}', '{Malaysia}', '{Selangor}'),
  ('00000000-0000-0000-0000-0000000263e2', '00000000-0000-0000-0000-0000000263d2', 'Test Driver Two', '+60100002632',
   'approved', '{eHailing}', '{Malaysia}', '{Penang}'),
  ('00000000-0000-0000-0000-0000000263e3', '00000000-0000-0000-0000-0000000263d3', 'Test Driver Three', '+60100002633',
   'approved', '{Teksi}', '{Malaysia}', '{Selangor}');

insert into public.dispatch_groups (id, name, kind) values
  ('00000000-0000-0000-0000-0000000263f0', 'Test Fleet 263', 'fleet');

insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status,
                            service_countries, service_states, partner_types, energy_type, dispatch_fleet_id) values
  ('00000000-0000-0000-0000-0000000263f1', '00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263e1',
   'TST 2631', 'Testmake', 'Alpha', 'Silver', 'approved', '{Malaysia}', '{Selangor}', '{eHailing}', 'Petrol',
   '00000000-0000-0000-0000-0000000263f0'),
  ('00000000-0000-0000-0000-0000000263f2', '00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263e1',
   'TST 2632', 'Testmake', 'Beta', 'Blue', 'approved', '{Malaysia}', '{Selangor}', '{eHailing}', 'Petrol', null),
  ('00000000-0000-0000-0000-0000000263f3', '00000000-0000-0000-0000-0000000263d2', '00000000-0000-0000-0000-0000000263e2',
   'TST 2633', 'Testmake', 'Gamma', 'Red', 'approved', '{Malaysia}', '{Penang}', '{eHailing}', 'Petrol', null);

insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000263f1', '00000000-0000-0000-0000-0000000263d1'),
  ('00000000-0000-0000-0000-0000000263f3', '00000000-0000-0000-0000-0000000263d2');

insert into public.settings_entries (category, values, position) values
  ('vehicle-services', '{"name": "Ride 263", "serviceTypes": ["Car"], "maxPax": 4}', 9001),
  ('vehicle-services', '{"name": "Mart 263", "serviceTypes": ["Mart"], "status": false}', 9002);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
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
    raise exception 'FAILED (not refused): %', p_what;
  end if;
end $$;
-- The error a statement raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create or replace function pg_temp.on_for(p_driver uuid, p_vehicle uuid, p_service text) returns boolean
language sql as $$ select public.driver_service_effective(p_driver, p_vehicle, p_service); $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.error_of(text), pg_temp.sees(uuid) to authenticated;

-- ---- 0. In place ---------------------------------------------------------------------------------
select pg_temp.check((select count(*) = 3 from pg_publication_tables where pubname = 'supabase_realtime'
                       and schemaname = 'public'
                       and tablename in ('driver_service_prefs', 'driver_service_locks', 'driver_service_lock_events')),
  'the three tables are followed live');
select pg_temp.check(exists (select 1 from public.admin_table_pages
                              where target = 'driver_service_locks' and page = 'admin-settings-driver-service-locks'),
  'the locks are the page''s to write');
select pg_temp.check(not has_function_privilege('authenticated', 'public.driver_service_effective(uuid, uuid, text)', 'execute'),
  'driver_service_effective is the server''s');
select pg_temp.check(not has_function_privilege('authenticated', 'public.driver_services_off(uuid)', 'execute'),
  'driver_services_off is the server''s');
select pg_temp.check(public.driver_service_key(' 6-Seater ') = '6seater' and public.driver_service_key('Extra:Pet:Dog') = 'extra:pet:dog'
                     and public.driver_service_key('HAIL:meter') = 'hail:meter', 'keys');

-- ---- 1. A switch is kept per car ------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
insert into public.driver_service_prefs (driver_id, vehicle_id, service_key, enabled) values
  ('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Ride', false),
  ('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'hail:METER', false),
  ('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f2', 'Comfort', false);
select pg_temp.refused($q$insert into public.driver_service_prefs (driver_id, vehicle_id, service_key, enabled)
  values ('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f3', 'ride', false)$q$,
  'a switch for somebody else''s car');
select pg_temp.refused($q$insert into public.driver_service_prefs (driver_id, vehicle_id, service_key, enabled)
  values ('00000000-0000-0000-0000-0000000263d2', '00000000-0000-0000-0000-0000000263f3', 'ride', false)$q$,
  'a switch in another driver''s name');
select pg_temp.check((select count(*) from public.driver_service_prefs) = 3, 'a driver reads their own switches');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d2');
select pg_temp.check((select count(*) from public.driver_service_prefs) = 0, 'not another driver''s');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a2');
select pg_temp.check((select count(*) from public.driver_service_prefs
                       where driver_id = '00000000-0000-0000-0000-0000000263d1') = 3, 'admins read every switch');
reset role;

select pg_temp.check((select array_agg(service_key order by service_key) from public.driver_service_prefs
                       where driver_id = '00000000-0000-0000-0000-0000000263d1') = array['comfort', 'hail:meter', 'ride'],
  'keys are stored normalised');
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Ride'),
  'Ride is off with car 1');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f2', 'Ride'),
  'Ride is on with car 2');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'Comfort is on with car 1');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d2', '00000000-0000-0000-0000-0000000263f3', 'Ride'),
  'no switch: on');
select pg_temp.check(public.driver_services_off('00000000-0000-0000-0000-0000000263d1') = array['ride'],
  'off now, driving car 1 (street hail left out): ' || public.driver_services_off('00000000-0000-0000-0000-0000000263d1')::text);
update public.vehicle_active_session set vehicle_id = '00000000-0000-0000-0000-0000000263f2'
 where user_id = '00000000-0000-0000-0000-0000000263d1';
select pg_temp.check(public.driver_services_off('00000000-0000-0000-0000-0000000263d1') = array['comfort'],
  'off now, driving car 2');
update public.vehicle_active_session set vehicle_id = '00000000-0000-0000-0000-0000000263f1'
 where user_id = '00000000-0000-0000-0000-0000000263d1';

-- ---- 2. Who writes locks ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
select pg_temp.refused($q$insert into public.driver_service_locks (scope, driver_id, service_key, mode)
  values ('driver', '00000000-0000-0000-0000-0000000263d1', 'ride', 'on')$q$, 'a driver writing their own lock');
select pg_temp.refused($q$select public.driver_service_locks_set('[{"scope": "everyone"}]', '{"ride": "on"}')$q$,
  'a driver saving locks');
select pg_temp.refused($q$insert into public.driver_service_lock_events (action, scope, service_key) values ('added', 'everyone', 'x')$q$,
  'a driver writing the log');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a2');
select pg_temp.refused($q$select public.driver_service_locks_set('[{"scope": "everyone"}]', '{"ride": "on"}')$q$,
  'an admin with READ on the page saving locks');
select pg_temp.refused($q$insert into public.driver_service_locks (scope, service_key, mode) values ('everyone', 'ride', 'on')$q$,
  'an admin with READ on the page adding a lock');

select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
-- Precedence for driver 1 (car 1: fleet, Malaysia / Selangor, eHailing) on Comfort.
select pg_temp.check(public.driver_service_locks_set('[{"scope": "everyone"}]', '{"Comfort": "off", "ride": "driver"}') = 1,
  'the EDIT admin saves a lock for everyone');
select pg_temp.check(pg_temp.error_of($q$select public.driver_service_locks_set('[{"scope": "everyone"}]', '{"ride": "maybe"}')$q$)
                       like '%DRIVER_SERVICE_LOCK_RULES%', 'a setting that is none of the three');
select pg_temp.check(pg_temp.error_of($q$select public.driver_service_locks_set('[{"scope": "everyone"}]', '{"ride": "on"}',
                                        now() - interval '1 day')$q$) like '%DRIVER_SERVICE_LOCK_UNTIL%',
  'an end in the past');
reset role;
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'everyone off');
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d3', null, 'Comfort'),
  'everyone off, even without a car');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
select public.driver_service_locks_set('[{"scope": "partner_type", "partner_type": "E-Hailing"}]', '{"comfort": "on"}');
reset role;
select pg_temp.check((select partner_type from public.driver_service_locks where scope = 'partner_type') = 'ehailing',
  'the partner type is kept as its key');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'partner type beats everyone');
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d3', null, 'Comfort'),
  'a Teksi driver keeps the everyone lock');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
select public.driver_service_locks_set('[{"scope": "region", "country": "malaysia"}]', '{"comfort": "off"}');
reset role;
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'a region beats the partner type');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
select public.driver_service_locks_set('[{"scope": "region", "country": "Malaysia", "state": "Selangor"}]', '{"comfort": "on"}');
reset role;
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'a state beats its country');
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d2', '00000000-0000-0000-0000-0000000263f3', 'Comfort'),
  'Penang keeps the country''s lock');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
select public.driver_service_locks_set('[{"scope": "fleet", "fleet_id": "00000000-0000-0000-0000-0000000263f0"}]', '{"comfort": "off"}');
reset role;
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'the fleet beats the region');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f2', 'Comfort'),
  'the fleet''s lock is for its car only (car 2 follows Selangor)');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
-- Several drivers in one save: one row each, one batch.
select public.driver_service_locks_set(
  '[{"scope": "driver", "driver_id": "00000000-0000-0000-0000-0000000263d1"},
    {"scope": "driver", "driver_id": "00000000-0000-0000-0000-0000000263d2"}]',
  '{"comfort": "on", "extra:pet:dog": "off"}', null, 'Test note 263');
reset role;
select pg_temp.check((select count(distinct batch_id) = 1 and count(*) = 4 from public.driver_service_locks where scope = 'driver'),
  'several drivers: a row each, one batch');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'the driver''s own lock beats the fleet');
select pg_temp.check(pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f2', 'Comfort'),
  'a lock beats the driver''s switch (Comfort off for car 2)');
select pg_temp.check((select (public.driver_service_lock('00000000-0000-0000-0000-0000000263d1',
                       '00000000-0000-0000-0000-0000000263f1', 'comfort')).scope) = 'driver', 'the deciding lock');

-- Expired: the driver's lock past its end counts for nothing.
update public.driver_service_locks set until = now() - interval '1 minute'
 where scope = 'driver' and service_key = 'comfort' and driver_id = '00000000-0000-0000-0000-0000000263d1';
select pg_temp.check(not pg_temp.on_for('00000000-0000-0000-0000-0000000263d1', '00000000-0000-0000-0000-0000000263f1', 'Comfort'),
  'an expired lock is ignored (the fleet decides again)');

-- Who did what.
select pg_temp.check((select count(*) from public.driver_service_lock_events
                       where actor_id = '00000000-0000-0000-0000-0000000263a1' and action = 'added') = 9,
  'every lock added is logged with its admin: '
  || (select count(*) from public.driver_service_lock_events where action = 'added')::text);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a1');
select public.driver_service_locks_set('[{"scope": "everyone"}]', '{"comfort": "driver"}');
select pg_temp.check((select count(*) from public.driver_service_lock_events where action = 'removed' and scope = 'everyone') = 1,
  'a lock given back to drivers is logged as removed');
select pg_temp.check((select count(*) from public.driver_service_off_counts() where service_key in ('comfort', 'ride')) = 2,
  'the off counts');

-- What drivers read.
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d3');
select pg_temp.check(not exists (select 1 from public.driver_service_locks where scope in ('driver', 'fleet', 'partner_type')),
  'a Teksi driver reads no driver, fleet or eHailing lock');
select pg_temp.check((select count(*) from public.driver_service_lock_events) = 0, 'drivers don''t read the log');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d2');
select pg_temp.check((select count(*) from public.driver_service_locks where scope = 'driver') = 2
                     and not exists (select 1 from public.driver_service_locks
                                      where driver_id = '00000000-0000-0000-0000-0000000263d1'),
  'a driver reads their own locks, not another''s');
reset role;

-- ---- 3. Add-ons: locks over the 0253 extras -------------------------------------------------------
insert into public.driver_ride_extras (driver_id, off) values
  ('00000000-0000-0000-0000-0000000263d2', array['child-seat', 'assist:guide-dog']);
select pg_temp.check((select off from public.driver_ride_extras where driver_id = '00000000-0000-0000-0000-0000000263d2')
                       = array['assist:guide-dog', 'child-seat'], 'the guide dog can be turned off, as 0253');
-- (0326: 'hire' is off too for a driver who doesn't take hourly hire.)
select pg_temp.check(array_remove(public.driver_extras_off('00000000-0000-0000-0000-0000000263d2'), 'hire') = array['assist:guide-dog', 'child-seat', 'pet:dog'],
  'an add-on locked off joins the driver''s list');
select pg_temp.check(not public.driver_takes_extras('00000000-0000-0000-0000-0000000263d2', array['pet:dog']),
  'so a dog ride isn''t offered');
insert into public.driver_service_locks (scope, driver_id, service_key, mode) values
  ('driver', '00000000-0000-0000-0000-0000000263d2', 'extra:child-seat', 'on');
select pg_temp.check(array_remove(public.driver_extras_off('00000000-0000-0000-0000-0000000263d2'), 'hire') = array['assist:guide-dog', 'pet:dog'],
  'an add-on locked on is taken whatever the driver chose');

-- ---- 4. Open requests --------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263c1');
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-000000026301', '00000000-0000-0000-0000-0000000263c1', 'open', 'Ride', 20, 20,
        3.1, 101.6, 3.2, 101.7);
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000026301') = 1, 'the rider sees their request');
-- Driver 1 switched Ride off for car 1, the car they drive.
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000026301') = 0, 'hidden from the driver who turned Ride off');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d2');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000026301') = 1, 'another driver sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263a2');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000026301') = 1, 'admins see it');
-- The driver books a Ride for themselves: theirs to see.
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-000000026302', '00000000-0000-0000-0000-0000000263d1', 'open', 'ride', 20, 20,
        3.1, 101.6, 3.2, 101.7);
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000026302') = 1, 'a rider sees their own, services or not');
reset role;
-- Taken: no longer an open request, so the driver on it reads it whatever.
-- Driving car 2 (Ride on), driver 1 sees it again.
update public.vehicle_active_session set vehicle_id = '00000000-0000-0000-0000-0000000263f2'
 where user_id = '00000000-0000-0000-0000-0000000263d1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000026301') = 1, 'shown again with the car that takes Ride');
reset role;
update public.vehicle_active_session set vehicle_id = '00000000-0000-0000-0000-0000000263f1'
 where user_id = '00000000-0000-0000-0000-0000000263d1';

-- ---- 5. The Services page's read ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
select pg_temp.check((public.driver_services_for(null) #>> '{vehicle,plate}') = 'TST 2631', 'the car in use');
select pg_temp.check((public.driver_services_for(null) #>> '{keys,hail:meter,on}')::boolean = false,
  'the meter is off for car 1');
select pg_temp.check((public.driver_services_for('00000000-0000-0000-0000-0000000263f2') #>> '{keys,hail:meter,on}')::boolean,
  'and on for car 2');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.driver_services_for(null)->'services') s
                                  where s->>'name' = 'Mart 263'), 'a service switched off in the catalogue is left out');
select pg_temp.check(exists (select 1 from jsonb_array_elements(public.driver_services_for(null)->'services') s
                              where s->>'name' = 'Ride 263' and s->>'key' = 'ride263' and not (s->>'partner_ok')::boolean),
  'a service of the catalogue, with its key, not one eHailing offers');
select pg_temp.refused($q$select public.driver_services_for('00000000-0000-0000-0000-0000000263f3')$q$,
  'reading another driver''s car');
reset role;

-- ---- 6. A bid on a service that is off is refused -----------------------------------------------------
-- Driver 1 can't see the request; a stale or modified app could still try.
-- Without the read rule, the guard alone refuses it.
drop policy "ride_requests driver services" on public.ride_requests;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d1');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000263d1', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000026301'$q$) like '%DRIVER_SERVICE_OFF%', 'a bid with Ride off');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000263d1', status = 'accepted', accepted_at = now()
  where id = '00000000-0000-0000-0000-000000026301'$q$) like '%DRIVER_SERVICE_OFF%', 'a take with Ride off');
select pg_temp.as_user('00000000-0000-0000-0000-0000000263d2');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000263d2', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000026301'$q$) = 'ok', 'a bid with Ride on goes through');
reset role;

select 'driver_services_0263: all passed';
rollback;
