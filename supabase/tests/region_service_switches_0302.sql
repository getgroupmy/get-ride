-- ============================================================================
-- Regression test for migration 0302: region service switches (Inherit / On
-- / Off) and the check that a booking's service is offered at its pickup.
--   * the resolver: the most specific region that says something decides
--     (country on, state inherit, city off); an explicit Off beats a list
--     above; a list from before switches offers only those; an unknown
--     place or service, and Service hours rules, are allowed (null);
--   * the check: off lets everything through, record keeps a log row and
--     lets it through, refuse raises SERVICE_NOT_OFFERED_HERE with the
--     reason (bookings for later too);
--   * the log is read by admins only; the setting is changed by an admin
--     with EDIT on Regions only.
-- The same resolver cases are in test/region_service_switches_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_service_switches_0302.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000302a1'),  -- admin, EDIT on Regions
  ('00000000-0000-0000-0000-0000000302a2'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000302c1'),  -- riders
  ('00000000-0000-0000-0000-0000000302c2')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000302%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000302a1', 'admin-settings-country-states-cities', 'edit'),
  ('00000000-0000-0000-0000-0000000302a2', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

-- Two master services and the services under them:
--   Car 302:  Ride 302, Premium 302 (and XL 302 under Premium 302)
--   Food 302: Courier 302
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000030201', 'service-settings', '{"name": "Car 302"}', 901),
  ('00000000-0000-0000-0000-000000030202', 'service-settings', '{"name": "Food 302"}', 902),
  ('00000000-0000-0000-0000-000000030211', 'vehicle-services', '{"name": "Ride 302", "serviceTypes": ["Car 302"]}', 911),
  ('00000000-0000-0000-0000-000000030212', 'vehicle-services', '{"name": "Premium 302", "serviceTypes": ["Car 302"]}', 912),
  ('00000000-0000-0000-0000-000000030213', 'vehicle-services',
   '{"name": "XL 302", "parentServices": ["00000000-0000-0000-0000-000000030212"]}', 913),
  ('00000000-0000-0000-0000-000000030214', 'vehicle-services', '{"name": "Courier 302", "serviceTypes": ["Food 302"]}', 914);

-- Switchland: Car on in the country, the state inherits, Premium off in the
-- city (whose outline holds the pickup at -40, -135), XL on again in a suburb.
insert into public.countries (name, values, geofence) values
  ('Switchland 302', '{"serviceSwitches": {"00000000-0000-0000-0000-000000030201": "on"},
                       "services": "{\"00000000-0000-0000-0000-000000030201\":true}"}',
   jsonb_build_object('boundary', '{"bbox":{"north":-30,"south":-50,"east":-125,"west":-145}}'));
insert into public.states (country, name, values, geofence) values
  ('Switchland 302', 'Midstate 302', '{}',
   jsonb_build_object('boundary', '{"bbox":{"north":-35,"south":-45,"east":-130,"west":-140}}'));
insert into public.cities (country, state, name, values, geofence) values
  ('Switchland 302', 'Midstate 302', 'Offtown 302', '{"subServices": {"00000000-0000-0000-0000-000000030212": false}}',
   jsonb_build_object('boundary', '{"bbox":{"north":-38,"south":-42,"east":-133,"west":-137}}'));
insert into public.suburbs (country, state, city, name, values) values
  ('Switchland 302', 'Midstate 302', 'Offtown 302', 'Backon 302',
   '{"subServices": {"00000000-0000-0000-0000-000000030212": true}}');
-- Listland: a list from before switches (Car and Food), a state that sets
-- Food off with a switch.
insert into public.countries (name, values) values
  ('Listland 302', '{"services": "{\"00000000-0000-0000-0000-000000030201\":true,\"00000000-0000-0000-0000-000000030202\":true}"}');
insert into public.states (country, name, values) values
  ('Listland 302', 'Nofood 302', '{"serviceSwitches": {"00000000-0000-0000-0000-000000030202": "off"}}');
-- Oldland: only lists, as before (Car in the country, Food in a city).
insert into public.countries (name, values) values
  ('Oldland 302', '{"services": "{\"00000000-0000-0000-0000-000000030201\":true,\"00000000-0000-0000-0000-000000030202\":false}"}');
insert into public.states (country, name, values) values ('Oldland 302', 'Oldstate 302', '{"services": "{}"}');
insert into public.cities (country, state, name, values) values
  ('Oldland 302', 'Oldstate 302', 'Foodtown 302', '{"services": "{\"00000000-0000-0000-0000-000000030202\":true}"}');
-- Openland: nothing set. Hourland: a Service hours rule.
insert into public.countries (name, values) values
  ('Openland 302', '{}'),
  ('Hourland 302', '{"serviceSwitches": {"00000000-0000-0000-0000-000000030201": "off"},
                     "rules": [{"kind": "availability", "on": true}]}');

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
-- The error and hint a statement raises as [p_user], or 'ok'.
create or replace function pg_temp.error_of(p_user uuid, p_sql text) returns text language plpgsql as $$
declare h text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
-- A booking now by [p_rider] for [p_service] at the pickup in Offtown; it
-- is cancelled straight away, so the rider can book again. 'ok' or the error.
create or replace function pg_temp.book(p_rider uuid, p_service text) returns text language plpgsql as $$
declare
  v uuid := gen_random_uuid();
  r text;
begin
  r := pg_temp.error_of(p_rider, format(
    $q$insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                         drop_lat, drop_lng, country, state, city)
       values (%L, %L, 'open', %L, 30, 30, -40.0, -135.0, -40.1, -135.1, 'Switchland 302', 'Midstate 302', 'Offtown 302')$q$,
    v, p_rider, p_service));
  update public.ride_requests set status = 'cancelled' where id = v;
  return r;
end $$;
create or replace function pg_temp.logged(p_service text) returns integer language sql as $$
  select count(*)::int from public.region_service_check_log where service = p_service;
$$;

-- ---- 1. The resolver ---------------------------------------------------------------------------
-- Country on, state inherit, city off.
select pg_temp.check(public.service_offered_at('Premium 302', 'Switchland 302', 'Midstate 302', '', ''),
  'Premium in the state: Car is on in the country, the state inherits');
select pg_temp.check(public.service_offered_at('Premium 302', 'Switchland 302', 'Midstate 302', 'Offtown 302', '') = false,
  'Premium off in the city');
select pg_temp.check(public.service_offered_at('XL 302', 'Switchland 302', 'Midstate 302', 'Offtown 302', '') = false,
  'XL is under Premium, which is off in the city');
select pg_temp.check(public.service_offered_at('Ride 302', 'switchland 302', 'MIDSTATE 302', 'Offtown 302', ''),
  'Ride is still on in the city (names in any case)');
select pg_temp.check(public.service_offered_at('XL 302', 'Switchland 302', 'Midstate 302', 'Offtown 302', 'Backon 302'),
  'Premium on again in the suburb: XL with it');
select pg_temp.check(public.service_offered_at('Courier 302', 'Switchland 302', '', '', ''),
  'Food is set nowhere in Switchland: On (the country default)');
-- An explicit Off beats the list above it.
select pg_temp.check(public.service_offered_at('Courier 302', 'Listland 302', '', '', ''),
  'Food is in Listland''s list');
select pg_temp.check(public.service_offered_at('Courier 302', 'Listland 302', 'Nofood 302', '', '') = false,
  'Food switched off in the state beats the country''s list');
select pg_temp.check(public.service_offered_at('Ride 302', 'Listland 302', 'Nofood 302', '', ''),
  'Car is left to the country''s list there');
-- A list from before switches offers only those.
select pg_temp.check(public.service_offered_at('Ride 302', 'Oldland 302', 'Oldstate 302', '', ''),
  'Car in Oldland''s list (the state''s empty list follows it)');
select pg_temp.check(public.service_offered_at('Courier 302', 'Oldland 302', '', '', '') = false,
  'Food not in the list: off');
select pg_temp.check(public.service_offered_at('Courier 302', 'Oldland 302', 'Oldstate 302', 'Foodtown 302', ''),
  'the city''s own list wins inside it');
select pg_temp.check(public.service_offered_at('Ride 302', 'Oldland 302', 'Oldstate 302', 'Foodtown 302', '') = false,
  'and offers only Food there');
-- Nothing set; unknown place or service; Service hours rules.
select pg_temp.check(public.service_offered_at('Premium 302', 'Openland 302', '', '', ''), 'nothing set: On');
select pg_temp.check(public.service_offered_at('Premium 302', 'Nowhere 302', '', '', '') is null, 'an unknown place: null');
select pg_temp.check(public.service_offered_at('Nothing 302', 'Switchland 302', '', '', '') is null, 'an unknown service: null');
select pg_temp.check(public.service_offered_at('', 'Switchland 302', '', '', '') is null, 'no service: null');
select pg_temp.check(public.service_offered_at('hail:meter', 'Switchland 302', '', '', '') is null, 'street hail: null');
select pg_temp.check(public.service_offered_at('Ride 302', 'Hourland 302', '', '', '') is null,
  'a Service hours rule around: the app decides by the clock');
select pg_temp.check(public.service_offered_at('00000000-0000-0000-0000-000000030212', 'Switchland 302', 'Midstate 302',
                                               'Offtown 302', '') = false, 'a service by its id');
-- One region at a time, as the app's resolver.
select pg_temp.check(public.region_service_resolve(array['{"subServices": {"x": false}}', '{"subServices": {"x": true}}']::jsonb[],
                                                   'x', false) = false, 'the most specific region decides');
select pg_temp.check(public.region_service_resolve(array['{}', '{"serviceSwitches": {"m": "off"}}']::jsonb[], 'm', true) = false,
  'an Off further up holds when nothing below says anything');
select pg_temp.check(public.region_service_resolve(array['{"services": "{\"m\":true}", "serviceSwitches": {"n": "on"}}']::jsonb[],
                                                   'o', true),
  'a region with switches: its list is for older apps only');
select pg_temp.check(public.region_service_resolve(array['{"services": "{\"m\":true}"}']::jsonb[], 'm', false),
  'a list says nothing about sub-services');
select pg_temp.check(public.region_service_resolve(array['{"serviceSwitches": "not json"}']::jsonb[], 'm', true),
  'bad values: nothing said');
select pg_temp.check(public.region_service_resolve('{}'::jsonb[], 'm', true), 'no regions: On');

-- ---- 2. The setting: who changes it -------------------------------------------------------------
select pg_temp.check(public.region_service_check_mode() = 'record', 'record by default');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302c1',
  $q$select public.set_region_service_check('off')$q$) like 'Only an admin%', 'a rider can''t change it');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a2',
  $q$select public.set_region_service_check('off')$q$) like 'Only an admin%', 'another page''s admin can''t');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a1',
  $q$select public.set_region_service_check('sometimes')$q$) like 'The service check is%', 'only off, record or refuse');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302c1',
  $q$insert into public.region_service_check_log (service, mode) values ('x', 'record')$q$) <> 'ok',
  'nobody writes the log from the app');

-- ---- 3. Off -------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a1',
  $q$select public.set_region_service_check('off')$q$) = 'ok', 'the Regions admin turns it off');
select pg_temp.check(public.region_service_check_mode() = 'off', 'off');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000302c1', 'Premium 302') = 'ok', 'off: booked');
select pg_temp.check(pg_temp.logged('Premium 302') = 0, 'off: nothing logged');

-- ---- 4. Record only -----------------------------------------------------------------------------
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a1',
  $q$select public.set_region_service_check('record')$q$) = 'ok', 'record');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000302c1', 'Premium 302') = 'ok', 'record: booked');
select pg_temp.check(pg_temp.logged('Premium 302') = 1, 'record: one row kept');
select pg_temp.check((select l.mode = 'record' and not l.refused and l.country = 'Switchland 302' and l.city = 'Offtown 302'
                             and l.rider_id = '00000000-0000-0000-0000-0000000302c1' and l.source = 'ride'
                        from public.region_service_check_log l where l.service = 'Premium 302'),
  'the row: who, what and where');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000302c2', 'Ride 302') = 'ok', 'Ride: booked');
select pg_temp.check(pg_temp.logged('Ride 302') = 0, 'a service offered there: nothing kept');

-- Who reads the log.
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302c1',
  $q$do $d$ begin if (select count(*) from public.region_service_check_log) <> 0 then raise exception 'seen'; end if; end $d$$q$)
  = 'ok', 'a rider reads no log rows');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a2',
  $q$do $d$ begin if (select count(*) from public.region_service_check_log where service = 'Premium 302') <> 1
                  then raise exception 'not seen'; end if; end $d$$q$) = 'ok', 'admins read them');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a1',
  $q$do $d$ declare v jsonb := public.admin_region_service_check(5);
     begin
       if v->>'mode' <> 'record' or (v->>'canEdit')::boolean is not true or (v->>'week')::int < 1
          or v->'recent'->0->>'service' <> 'Premium 302' then
         raise exception 'wrong: %', v;
       end if;
     end $d$$q$) = 'ok', 'the page''s read: mode, counts, latest rows');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a2',
  $q$do $d$ begin if (public.admin_region_service_check()->>'canEdit')::boolean then raise exception 'can edit'; end if;
     end $d$$q$) = 'ok', 'another page''s admin reads it but can''t change it');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302c1',
  $q$select public.admin_region_service_check()$q$) like 'Only an admin%', 'a rider can''t read it');

-- ---- 5. Refuse ----------------------------------------------------------------------------------
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302a1',
  $q$select public.set_region_service_check('refuse')$q$) = 'ok', 'refuse');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000302c1', 'Premium 302')
                     = 'SERVICE_NOT_OFFERED_HERE: Premium 302 isn''t offered for pickups in Offtown 302. '
                       'Choose another service for this trip.', 'refuse: refused with the reason');
select pg_temp.check(pg_temp.logged('Premium 302') = 1, 'a refusal rolls back with the booking: not logged');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000302c1', 'Ride 302') = 'ok', 'refuse: Ride still books');
-- The server's own writes are not held.
insert into public.ride_requests (rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                  country, state, city)
values ('00000000-0000-0000-0000-0000000302c2', 'cancelled', 'Premium 302', 30, 30, -40.0, -135.0, -40.1, -135.1,
        'Switchland 302', 'Midstate 302', 'Offtown 302');

-- A booking for later is checked when it is booked.
select set_config('request.jwt.claims', '', true);
select public.set_scheduled_rides_config('{"enabled": true, "mode": "advance"}');
select pg_temp.check(pg_temp.error_of('00000000-0000-0000-0000-0000000302c1',
  $q$select public.schedule_ride('{"service": "Premium 302", "pickup_lat": -40.0, "pickup_lng": -135.0,
     "drop_lat": -40.1, "drop_lng": -135.1, "fare": 30, "country": "Switchland 302", "state": "Midstate 302",
     "city": "Offtown 302"}'::jsonb, now() + interval '3 hours')$q$) like 'SERVICE_NOT_OFFERED_HERE: Premium 302 isn''t offered%',
  'a booking for later where the service is off: refused');

rollback;
select 'region_service_switches_0302: all passed';
