-- ============================================================================
-- Regression test for migration 0258: places with the airport tools — the
-- place's area kept from its multi_gate row, which area a point is in (an
-- airport before a place, the smallest place first), doors asked for only
-- when switched on, the extra charge and the place's own fares, the fare
-- end of a trip between a place and an airport, a place's waiting queue,
-- places without a boundary unchanged, and who may write what.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/place_areas_0258.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000257a1'),  -- admin, EDIT on Places
  ('00000000-0000-0000-0000-0000000257a2'),  -- admin, EDIT on Airport Areas
  ('00000000-0000-0000-0000-0000000257a3'),  -- full admin
  ('00000000-0000-0000-0000-0000000257c1'),  -- riders
  ('00000000-0000-0000-0000-0000000257c2'),
  ('00000000-0000-0000-0000-0000000257c3'),
  ('00000000-0000-0000-0000-0000000257c4'),
  ('00000000-0000-0000-0000-0000000257c5'),
  ('00000000-0000-0000-0000-0000000257c6'),
  ('00000000-0000-0000-0000-0000000257c7'),
  ('00000000-0000-0000-0000-0000000257c8'),
  ('00000000-0000-0000-0000-0000000257d1')   -- a driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000257%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000257a1', 'admin-settings-multi-gate-places', 'edit'),
  ('00000000-0000-0000-0000-0000000257a2', 'admin-settings-airport-areas', 'edit'),
  ('00000000-0000-0000-0000-0000000257a3', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000257d1', 'Driver 257', '60120002571', 'approved');
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000025751', 'vehicle-services', '{"name":"Ride 257"}', 1)
on conflict (id) do nothing;
insert into public.vehicle (auth_user_id, plate, make, model, status, service_id, service_approved_id) values
  ('00000000-0000-0000-0000-0000000257d1', 'TST257', 'Make', 'Model', 'approved',
   '00000000-0000-0000-0000-000000025751', '00000000-0000-0000-0000-000000025751');

-- A country (lat 30..40, lng 120..130) the rides are booked in.
insert into public.countries (name, values, geofence) values
  ('Placeland 257', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":40,"south":30,"east":130,"west":120}}'));

-- An airport 35.0..35.2 / 125.0..125.2.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000257e0', jsonb_build_object('name', 'Airport 257', 'code', 'APT',
    'boundary', '{"bbox":{"north":35.2,"south":35.0,"east":125.2,"west":125.0}}'));

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
create or replace function pg_temp.refused_with(p_sql text, p_code text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_code in sqlerrm) > 0 then
      return;
    end if;
    raise exception 'FAILED: % refused with "%", not %', p_what, sqlerrm, p_code;
  end;
  raise exception 'FAILED (not refused): %', p_what;
end $$;
create or replace function pg_temp.box(n float8, s float8, e float8, w float8) returns text language sql as $$
  select jsonb_build_object('coords', jsonb_build_array(
           jsonb_build_object('latitude', n, 'longitude', w), jsonb_build_object('latitude', n, 'longitude', e),
           jsonb_build_object('latitude', s, 'longitude', e), jsonb_build_object('latitude', s, 'longitude', w)),
         'bbox', jsonb_build_object('north', n, 'south', s, 'east', e, 'west', w))::text;
$$;
create or replace function pg_temp.book(p_rider uuid, p_plat float8, p_plng float8, p_dlat float8, p_dlng float8,
                                        p_pick_door uuid default null, p_drop_door uuid default null,
                                        p_fare numeric default 18.4)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, distance_km,
                                    pickup_lat, pickup_lng, drop_lat, drop_lng, pickup_door_id, drop_door_id)
  values (v, p_rider, 'open', 'Ride 257', p_fare, p_fare, 6, p_plat, p_plng, p_dlat, p_dlng, p_pick_door, p_drop_door);
  return v;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text), pg_temp.box(float8, float8, float8, float8),
  pg_temp.book(uuid, float8, float8, float8, float8, uuid, uuid, numeric) to authenticated;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;

-- ---- 1. The Places page draws boundaries; the server keeps the areas ---------------------------
-- P1 a big complex 33.0..33.4 / 123.0..123.4; P2 a mall inside it
-- 33.1..33.2 / 123.1..123.2; P3 overlapping the airport 35.1..35.3 /
-- 125.1..125.3; P4 with no boundary at 32.5, 122.5.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000257a1');
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000257f1', 'place', jsonb_build_object('name', 'Complex 257', 'lat', '33.2', 'lon', '123.2',
     'areaOn', true, 'boundary', pg_temp.box(33.4, 33.0, 123.4, 123.0))),
  ('00000000-0000-0000-0000-0000000257f2', 'place', jsonb_build_object('name', 'Mall 257', 'lat', '33.15', 'lon', '123.15',
     'areaOn', true, 'boundary', pg_temp.box(33.2, 33.1, 123.2, 123.1))),
  ('00000000-0000-0000-0000-0000000257f3', 'place', jsonb_build_object('name', 'Hotel 257', 'lat', '35.2', 'lon', '125.2',
     'areaOn', true, 'boundary', pg_temp.box(35.3, 35.1, 125.3, 125.1))),
  ('00000000-0000-0000-0000-0000000257f4', 'place', jsonb_build_object('name', 'Station 257', 'lat', '32.5', 'lon', '122.5'));
-- The mall's gates: G1 pickup, G2 drop-off (no parentKey, as the Gates page writes).
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000257b1', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000257f2","name":"Lobby","mode":"pickup","displayPriority":1,"lat":"33.16","lon":"123.16"}'),
  ('00000000-0000-0000-0000-0000000257b2', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000257f2","parentKey":"multi-gate-places","name":"Car park","mode":"drop","displayPriority":2}'),
  ('00000000-0000-0000-0000-0000000257b4', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000257f4","name":"Exit A","mode":"both"}');
reset role;

select pg_temp.check((select count(*) = 3 from public.airport_areas
                       where kind = 'place' and id = place_id and active
                         and id::text like '00000000-0000-0000-0000-0000000257f%'),
  'a place with its boundary on gets an area; one without does not');
select pg_temp.check((select values->>'name' = 'Mall 257' and size_m2 between 1e8 and 2e8
                        from public.airport_areas where id = '00000000-0000-0000-0000-0000000257f2'),
  'the area carries the name and the boundary''s size');
select pg_temp.check((select not drop_door_required and not pick_door_required and not guide_on and not fares_on
                             and not restrict_pickups and not pick_fee_on and not drop_fee_on
                        from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000257f2'),
  'a place starts with every tool off');
select pg_temp.check((select drop_door_required and pick_door_required and guide_on and fares_on
                        from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000257e0'),
  'an airport keeps the airport defaults');
select pg_temp.check((select string_agg(name || ':' || kind, ',' order by sort_order) from public.airport_doors
                       where airport_id = '00000000-0000-0000-0000-0000000257f2') = 'Lobby:pick,Car park:drop',
  'the place''s gates are its doors');

-- ---- 2. Which area a point is in ---------------------------------------------------------------
select pg_temp.check(public.area_at(33.15, 123.15) = '00000000-0000-0000-0000-0000000257f2',
  'inside two places: the smaller one');
select pg_temp.check(public.area_at(33.3, 123.3) = '00000000-0000-0000-0000-0000000257f1', 'inside the big one only');
select pg_temp.check(public.area_at(35.15, 125.15) = '00000000-0000-0000-0000-0000000257e0',
  'inside an airport and a place: the airport');
select pg_temp.check(public.airport_at(35.25, 125.25) = '00000000-0000-0000-0000-0000000257f3',
  'airport_at answers places too');
select pg_temp.check(public.area_at(32.5, 122.5) is null, 'a place without a boundary is no area');

-- The boundary switched off: no area, the settings kept.
update public.airport_settings set pick_fee_amount = 3 where airport_id = '00000000-0000-0000-0000-0000000257f3';
update public.multi_gate set values = values || '{"areaOn": false}' where id = '00000000-0000-0000-0000-0000000257f3';
select pg_temp.check(public.area_at(35.25, 125.25) is null, 'boundary off: the point is in no area');
select pg_temp.check((select pick_fee_amount = 3 from public.airport_settings
                       where airport_id = '00000000-0000-0000-0000-0000000257f3'), 'boundary off keeps the settings');
update public.multi_gate set values = values || '{"areaOn": true}' where id = '00000000-0000-0000-0000-0000000257f3';
select pg_temp.check(public.area_at(35.25, 125.25) = '00000000-0000-0000-0000-0000000257f3', 'boundary back on');

-- ---- 3. Who writes what ----------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000257a1');
update public.airport_settings set pick_fee_on = true, pick_fee_name = 'Mall entry fee', pick_fee_amount = 2
 where airport_id = '00000000-0000-0000-0000-0000000257f2';
insert into public.airport_waiting_zones (airport_id, name, shape) values
  ('00000000-0000-0000-0000-0000000257f2', 'Taxi rank', pg_temp.box(33.18, 33.15, 123.18, 123.15)::jsonb);
select pg_temp.check((select pick_fee_on from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000257f2'),
  'the Places page writes a place''s settings');
select pg_temp.refused($q$update public.airport_settings set restrict_pickups = true
                           where airport_id = '00000000-0000-0000-0000-0000000257e0'$q$,
  'the Places page writing an airport''s settings');
select pg_temp.refused($q$update public.airport_areas set active = false
                           where id = '00000000-0000-0000-0000-0000000257f2'$q$,
  'the Places page changing a place''s area row');
select pg_temp.as_user('00000000-0000-0000-0000-0000000257a3');
select pg_temp.refused_with($q$update public.airport_areas set active = false
                                where id = '00000000-0000-0000-0000-0000000257f2'$q$, 'PLACE_AREA_MANAGED',
  'even a full admin changing a place''s area row from the app');
select pg_temp.refused_with($q$delete from public.airport_areas
                                where id = '00000000-0000-0000-0000-0000000257f2'$q$, 'PLACE_AREA_MANAGED',
  'or removing it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000257a2');
select pg_temp.refused($q$update public.airport_settings set restrict_pickups = true
                           where airport_id = '00000000-0000-0000-0000-0000000257f2'$q$,
  'Airport Areas writing a place''s settings');
update public.airport_settings set pick_door_required = false where airport_id = '00000000-0000-0000-0000-0000000257e0';
insert into public.airport_areas (id, kind, values) values
  ('00000000-0000-0000-0000-0000000257e9', 'place', '{"name":"Sneaky"}');
reset role;
select pg_temp.check((select kind = 'airport' and place_id is null from public.airport_areas
                       where id = '00000000-0000-0000-0000-0000000257e9'),
  'a row the app adds is an airport');
delete from public.airport_areas where id = '00000000-0000-0000-0000-0000000257e9';

-- ---- 4. Doors only when switched on ------------------------------------------------------------
set local role authenticated;
insert into rides values ('free', pg_temp.book('00000000-0000-0000-0000-0000000257c1', 33.15, 123.15, 32.0, 122.0));
reset role;
select pg_temp.check((select airport_pickup_id = '00000000-0000-0000-0000-0000000257f2' and pickup_door_name is null
                        from public.ride_requests where id = (select id from rides where k = 'free')),
  'switch off: booked at the place without a door');
update public.airport_settings set pick_door_required = true, drop_door_required = true
 where airport_id = '00000000-0000-0000-0000-0000000257f2';
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000257c3', 33.15, 123.15, 32.0, 122.0)$q$,
  'AIRPORT_DOOR_REQUIRED', 'switch on: a pickup without a door');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000257c3', 33.15, 123.15, 32.0, 122.0,
                                                    '00000000-0000-0000-0000-0000000257b2')$q$,
  'AIRPORT_DOOR_INVALID', 'a drop-off gate as the pickup door');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000257c3', 32.0, 122.0, 33.15, 123.15)$q$,
  'AIRPORT_DOOR_REQUIRED', 'switch on: a drop-off without a door');
insert into rides values ('door', pg_temp.book('00000000-0000-0000-0000-0000000257c4', 33.15, 123.15, 32.0, 122.0,
                                               '00000000-0000-0000-0000-0000000257b1'));
reset role;
select pg_temp.check((select pickup_door_name = 'Lobby' from public.ride_requests where id = (select id from rides where k = 'door')),
  'the chosen gate is named on the ride');
select pg_temp.check((select count(*) = 1 from (select public.airport_require_doors(33.15, 123.15, 32.0, 122.0,
                                                  '00000000-0000-0000-0000-0000000257b1', null)) x),
  'a scheduled ride with its door passes');
select pg_temp.refused_with($q$select public.airport_require_doors(33.15, 123.15, 32.0, 122.0, null, null)$q$,
  'AIRPORT_DOOR_REQUIRED', 'a scheduled ride without its door');

-- ---- 5. The extra charge and the place's own fares --------------------------------------------
select pg_temp.check((select charges @> '[{"name":"Mall entry fee","value":2,"airport":"pick"}]'
                             and fare = 18.4 and (airport_fare->>'total')::numeric = 20.4
                             and (airport_fare->>'fare')::numeric = 18.4
                        from public.ride_requests where id = (select id from rides where k = 'door')),
  'the charge is on the fare; no own fares: the normal fare, not rounded');
set local role authenticated;
insert into rides values ('plain', pg_temp.book('00000000-0000-0000-0000-0000000257c2', 33.3, 123.3, 32.0, 122.0));
reset role;
select pg_temp.check((select airport_pickup_id = '00000000-0000-0000-0000-0000000257f1' and airport_fare is null
                             and charges is null and fare = 18.4
                        from public.ride_requests where id = (select id from rides where k = 'plain')),
  'a place with nothing on leaves the fare alone');
update public.airport_settings set fares_on = true, fares = '{"roundUp": true, "minPick": {"on": true, "amount": 25}}'
 where airport_id = '00000000-0000-0000-0000-0000000257f1';
set local role authenticated;
insert into rides values ('own', pg_temp.book('00000000-0000-0000-0000-0000000257c5', 33.3, 123.3, 32.0, 122.0));
insert into rides values ('toair', pg_temp.book('00000000-0000-0000-0000-0000000257c6', 33.3, 123.3, 35.15, 125.15));
reset role;
select pg_temp.check((select fare = 25 and airport_fare->>'dir' = 'from'
                        from public.ride_requests where id = (select id from rides where k = 'own')),
  'the place''s own fares: raised to its pickup minimum');
select pg_temp.check((select airport_fare->>'airport' = '00000000-0000-0000-0000-0000000257e0' and airport_fare->>'dir' = 'to'
                             and fare = 19
                        from public.ride_requests where id = (select id from rides where k = 'toair')),
  'from a place to an airport: the airport''s fare');
select pg_temp.check(public.airport_fare_quote(33.15, 123.15, 32.0, 122.0, 'Ride 257', 6, 18.4) @> '{"total": 20.4, "charge": 2}',
  'the app''s quote shows the charge');
select pg_temp.check(public.airport_fare_quote(32.5, 122.5, 32.0, 122.0, 'Ride 257', 6, 18.4) is null,
  'no quote at a place without a boundary');

-- ---- 6. Places without a boundary are unchanged ------------------------------------------------
set local role authenticated;
insert into rides values ('station', pg_temp.book('00000000-0000-0000-0000-0000000257c7', 32.5, 122.5, 32.0, 122.0));
reset role;
select pg_temp.check((select airport_pickup_id is null and pickup_door_id is null and fare = 18.4 and charges is null
                             and not airport_hold
                        from public.ride_requests where id = (select id from rides where k = 'station')),
  'a place without a boundary books as before');

-- ---- 7. A place's waiting queue ----------------------------------------------------------------
update public.airport_settings set restrict_pickups = true, pickup_from = '{queue}', need_dropoff = false,
                                   empty_action = 'wait'
 where airport_id = '00000000-0000-0000-0000-0000000257f2';
insert into public.driver_presence (profile_id, online, lat, lng) values
  ('00000000-0000-0000-0000-0000000257d1', true, 33.16, 123.16)
on conflict (profile_id) do update set online = excluded.online, lat = excluded.lat, lng = excluded.lng, updated_at = now();
select pg_temp.check((select airport_id = '00000000-0000-0000-0000-0000000257f2' from public.airport_queue
                       where driver_id = '00000000-0000-0000-0000-0000000257d1'),
  'a driver in the place''s waiting zone joins its queue');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000257d1');
select pg_temp.check(public.airport_driver_state() @> '{"state":"queued","kind":"place","airport":"Mall 257"}',
  'the driver sees the place''s queue');
insert into rides values ('q', pg_temp.book('00000000-0000-0000-0000-0000000257c8', 33.15, 123.15, 32.0, 122.0,
                                            '00000000-0000-0000-0000-0000000257b1'));
reset role;
select pg_temp.check((select airport_hold from public.ride_requests where id = (select id from rides where k = 'q')),
  'the pickup is held for the queue');
select pg_temp.check((select stage = 'queue' and outcome is null from public.airport_ride_offers
                       where ride_id = (select id from rides where k = 'q')
                         and driver_id = '00000000-0000-0000-0000-0000000257d1'),
  'and offered to the queued driver');

-- ---- 8. Telematics, deleting a place -----------------------------------------------------------
select pg_temp.check(public.telematics_trip_kind(null, null, '00000000-0000-0000-0000-0000000257f2', null, null, null, null, 'Ride')
                     = 'service:Ride', 'a place pickup is not an airport trip');
select pg_temp.check(public.telematics_trip_kind(null, null, '00000000-0000-0000-0000-0000000257e0', null, null, null, null, 'Ride')
                     = 'airport', 'an airport pickup still is');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000257a1');
delete from public.multi_gate where id = '00000000-0000-0000-0000-0000000257f3';
reset role;
select pg_temp.check(not exists (select 1 from public.airport_areas where id = '00000000-0000-0000-0000-0000000257f3')
                     and not exists (select 1 from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000257f3'),
  'deleting a place removes its area and settings');

select 'place_areas_0258: all passed';
rollback;
