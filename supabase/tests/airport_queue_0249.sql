-- ============================================================================
-- Regression test for migration 0249: airport doors, guides, fares, charges
-- and the waiting queue — admin-scoped writes, door kinds, the rider's door
-- choice, the fare and its breakdown (zone, band tiers, base, minimum,
-- charge, rounding), drop-offs, joining the queue, its order, offers,
-- declines and misses, zone pickups and what happens with nobody to offer
-- a pickup to; the vehicle's service type, the service lines and their
-- order; scheduled rides' doors.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/airport_queue_0249.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000249a1'),  -- admin, EDIT on Airport Areas
  ('00000000-0000-0000-0000-0000000249a2'),  -- admin, READ on Airport Areas
  ('00000000-0000-0000-0000-0000000249a3'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000249c1'),  -- riders
  ('00000000-0000-0000-0000-0000000249c2'),
  ('00000000-0000-0000-0000-0000000249c3'),
  ('00000000-0000-0000-0000-0000000249c4'),
  ('00000000-0000-0000-0000-0000000249c5'),
  ('00000000-0000-0000-0000-0000000249c6'),
  ('00000000-0000-0000-0000-0000000249d1'),  -- drivers
  ('00000000-0000-0000-0000-0000000249d2'),
  ('00000000-0000-0000-0000-0000000249d3'),
  ('00000000-0000-0000-0000-0000000249d4'),
  ('00000000-0000-0000-0000-0000000249d5'),
  ('00000000-0000-0000-0000-0000000249d6')   -- a driver whose vehicle has no approved service
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000249%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000249a1', 'admin-settings-airport-areas', 'edit'),
  ('00000000-0000-0000-0000-0000000249a2', 'admin-settings-airport-areas', 'read'),
  ('00000000-0000-0000-0000-0000000249a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000249d1', 'Driver One', '60120000491', 'approved'),
  ('00000000-0000-0000-0000-0000000249d2', 'Driver Two', '60120000492', 'approved'),
  ('00000000-0000-0000-0000-0000000249d3', 'Driver Three', '60120000493', 'approved'),
  ('00000000-0000-0000-0000-0000000249d4', 'Driver Four', '60120000494', 'approved'),
  ('00000000-0000-0000-0000-0000000249d5', 'Driver Five', '60120000495', 'approved'),
  ('00000000-0000-0000-0000-0000000249d6', 'Driver Six', '60120000496', 'approved');

-- Vehicle services, lowest to highest: Ride < Comfort < 6-seater < Premium.
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000024951', 'vehicle-services', '{"name":"Ride 249"}', 1),
  ('00000000-0000-0000-0000-000000024952', 'vehicle-services', '{"name":"Comfort"}', 2),
  ('00000000-0000-0000-0000-000000024953', 'vehicle-services', '{"name":"6-seater 249"}', 3),
  ('00000000-0000-0000-0000-000000024954', 'vehicle-services', '{"name":"Premium 249"}', 4)
on conflict (id) do nothing;
-- Another entry named Comfort would make the name ambiguous in this database.
delete from public.settings_entries
 where category = 'vehicle-services' and lower(values->>'name') = 'comfort'
   and id <> '00000000-0000-0000-0000-000000024952';
delete from public.vehicle_service_order;
insert into public.vehicle_service_order (service_id, rank) values
  ('00000000-0000-0000-0000-000000024951', 1), ('00000000-0000-0000-0000-000000024952', 2),
  ('00000000-0000-0000-0000-000000024953', 3), ('00000000-0000-0000-0000-000000024954', 4);
-- Each driver's approved vehicle: Comfort for one, two, three and five, Premium
-- for four; six's has no approved service.
insert into public.vehicle (auth_user_id, plate, make, model, status, service_id, service_approved_id)
select u.id, 'TST' || right(u.id::text, 2), 'Make', 'Model', 'approved',
       case when right(u.id::text, 2) = 'd4' then '00000000-0000-0000-0000-000000024954'
            when right(u.id::text, 2) = 'd6' then '00000000-0000-0000-0000-000000024952'
            else '00000000-0000-0000-0000-000000024952' end,
       case when right(u.id::text, 2) = 'd4' then '00000000-0000-0000-0000-000000024954'
            when right(u.id::text, 2) = 'd6' then null
            else '00000000-0000-0000-0000-000000024952' end
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000249d%';

-- A country (lat 10..20, lng 100..110) the rides are booked in.
insert into public.countries (name, values, geofence) values
  ('Airportland 249', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":20,"south":10,"east":110,"west":100}}'));

-- The airport (14.9..15.1, 104.9..105.1), its waiting zone (15.0..15.05,
-- 105.0..105.05) and a fare zone "City" (11..12, 101..102).
-- Points: AIR 14.95,104.95 (in the airport, outside the zone); ZONE 15.02,105.02;
-- CITY 11.5,101.5; TOWN 13,103.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000249e0', jsonb_build_object('name', 'Test Airport', 'code', 'TST',
    'boundary', '{"coords":[{"latitude":15.1,"longitude":104.9},{"latitude":15.1,"longitude":105.1},{"latitude":14.9,"longitude":105.1},{"latitude":14.9,"longitude":104.9}],"bbox":{"north":15.1,"south":14.9,"east":105.1,"west":104.9}}'));

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
-- Refused: an error, or no row written.
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
-- Refused with this error code in the message.
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
-- Books a ride as [p_rider]; answers its id.
create or replace function pg_temp.book(p_rider uuid, p_plat float8, p_plng float8, p_dlat float8, p_dlng float8,
                                        p_pick_door uuid default null, p_drop_door uuid default null,
                                        p_service text default 'Comfort', p_fare numeric default 30,
                                        p_km numeric default 5, p_charges jsonb default null)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, distance_km,
                                    pickup_lat, pickup_lng, drop_lat, drop_lng, pickup_door_id, drop_door_id, charges)
  values (v, p_rider, 'open', p_service, p_fare, p_fare, p_km, p_plat, p_plng, p_dlat, p_dlng,
          p_pick_door, p_drop_door, p_charges);
  return v;
end $$;
-- How many rows of a ride the caller sees.
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text),
  pg_temp.book(uuid, float8, float8, float8, float8, uuid, uuid, text, numeric, numeric, jsonb),
  pg_temp.sees(uuid) to authenticated;

select pg_temp.check(exists (select 1 from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000249e0'),
  'a new airport gets its settings row');
select pg_temp.check(public.airport_at(14.95, 104.95) = '00000000-0000-0000-0000-0000000249e0', 'a point in the airport');
select pg_temp.check(public.airport_at(13, 103) is null, 'a point outside it');

-- ---- 1. Admin-scoped writes ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249a1');
update public.airport_settings set pick_fee_on = true, pick_fee_name = 'Airport pickup fee', pick_fee_amount = 6
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
insert into public.airport_waiting_zones (airport_id, name, shape) values
  ('00000000-0000-0000-0000-0000000249e0', 'Holding bay',
   '{"coords":[{"latitude":15.05,"longitude":105.0},{"latitude":15.05,"longitude":105.05},{"latitude":15.0,"longitude":105.05},{"latitude":15.0,"longitude":105.0}],"bbox":{"north":15.05,"south":15.0,"east":105.05,"west":105.0},"source":"manual"}');
insert into public.airport_fare_zones (airport_id, name, shape, to_amount, from_amount) values
  ('00000000-0000-0000-0000-0000000249e0', 'City', '{"bbox":{"north":12,"south":11,"east":102,"west":101},"source":"region:city"}', 75, 80);
insert into storage.objects (bucket_id, name) values ('airport-guides', 'test-0249/step1.jpg');
select pg_temp.check((select pick_fee_on from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000249e0'),
  'the Airport Areas editor writes the settings');

select pg_temp.as_user('00000000-0000-0000-0000-0000000249a2');
select pg_temp.refused($q$update public.airport_settings set restrict_pickups = true where true$q$,
  'a read-only admin writing airport settings');
select pg_temp.refused($q$insert into public.airport_waiting_zones (airport_id, shape) values ('00000000-0000-0000-0000-0000000249e0', '{}')$q$,
  'a read-only admin drawing a waiting zone');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249a3');
select pg_temp.refused($q$update public.airport_settings set restrict_pickups = true where true$q$,
  'another page''s admin writing airport settings');
select pg_temp.refused($q$delete from public.airport_fare_zones where true$q$, 'another page''s admin removing a fare zone');
select pg_temp.refused($q$insert into storage.objects (bucket_id, name) values ('airport-guides', 'x-0249.jpg')$q$,
  'another page''s admin uploading a guide photo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249c1');
select pg_temp.refused($q$update public.airport_settings set restrict_pickups = true where true$q$, 'a rider writing airport settings');
select pg_temp.refused($q$insert into storage.objects (bucket_id, name) values ('airport-guides', 'y-0249.jpg')$q$,
  'a rider uploading a guide photo');
select pg_temp.refused($q$insert into public.airport_queue (airport_id, driver_id, place_at) values ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249c1', now())$q$,
  'a client writing the queue');
select pg_temp.check((select count(*) = 1 from storage.objects where bucket_id = 'airport-guides' and name = 'test-0249/step1.jpg'),
  'a signed-in user reads guide photos');
select pg_temp.check((select count(*) = 1 from public.airport_settings where airport_id = '00000000-0000-0000-0000-0000000249e0'),
  'a rider reads the airport settings');

-- ---- 2. Doors: one store with the Multi-Gate page, three kinds -----------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000249a1');
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000249f1', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000249e0","parentKey":"airport-areas","name":"Departures, Door 5","mode":"drop","displayPriority":1,"active":true,"lat":"15.0","lon":"105.0"}'),
  ('00000000-0000-0000-0000-0000000249f2', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000249e0","parentKey":"airport-areas","name":"Arrivals, Door 3","mode":"pickup","displayPriority":2,"active":true,"guide":[{"photo":"https://x/storage/v1/object/public/airport-guides/test-0249/step1.jpg","text":"Turn right"}]}'),
  ('00000000-0000-0000-0000-0000000249f3', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000249e0","parentKey":"airport-areas","name":"Level 2, Door 2","mode":"both","displayPriority":3,"active":true}');
select pg_temp.refused($q$insert into public.multi_gate (kind, values) values ('gate', '{"placeId":"00000000-0000-0000-0000-0000000249e0","parentKey":"airport-areas","name":"Odd","mode":"sideways"}')$q$,
  'a door of an unknown kind');
select pg_temp.check((select string_agg(kind, ',' order by sort_order) from public.airport_doors
                       where airport_id = '00000000-0000-0000-0000-0000000249e0') = 'drop,pick,both',
  'doors read as drop / pick / both, in order');
select pg_temp.check((select jsonb_array_length(guide) from public.airport_doors where id = '00000000-0000-0000-0000-0000000249f2') = 1,
  'a pickup door carries its guide');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249c1');
select pg_temp.refused($q$update public.multi_gate set values = values || '{"mode":"drop"}' where id = '00000000-0000-0000-0000-0000000249f2'$q$,
  'a rider changing a door');
reset role;

-- ---- 3. Fares -----------------------------------------------------------------------------------
update public.airport_settings set fares = '{
  "base": {"comfort": 8, "Ride": 0},
  "minPick": {"on": true, "amount": 35}, "minDrop": {"on": true, "amount": 30},
  "band": {"on": true, "tiers": [{"uptoKm": 20, "flat": 60}, {"uptoKm": 10, "flat": 45}], "extra": "extra", "applies": "both"},
  "roundUp": true}'
 where airport_id = '00000000-0000-0000-0000-0000000249e0';

create or replace function pg_temp.q(p_dir text, p_km numeric, p_lat float8, p_lng float8, p_service text default 'Comfort',
                                     p_normal numeric default 20, p_charges jsonb default '[{"name":"Airport pickup fee","value":6}]')
returns jsonb language sql as $$
  select public.airport_quote('00000000-0000-0000-0000-0000000249e0', p_dir, p_service, p_km, p_normal, 1.5,
                              p_lat, p_lng, p_charges);
$$;
-- Zone: the fixed fare beats the band.
select pg_temp.check((pg_temp.q('from', 30, 11.5, 101.5)->>'total')::numeric = 94, 'zone from the airport: 80 + 8 + 6');
select pg_temp.check((pg_temp.q('from', 30, 11.5, 101.5)->>'fare')::numeric = 88, 'the fare leaves the charge out');
select pg_temp.check((pg_temp.q('to', 30, 11.5, 101.5, 'Comfort', 20, '[]')->>'total')::numeric = 83, 'zone to the airport: 75 + 8');
select pg_temp.check((pg_temp.q('from', 30, 11.5, 101.5)->>'fixed')::boolean, 'a zone fare is fixed');
-- Band tiers, at and past their limits.
select pg_temp.check((pg_temp.q('from', 5, 13, 103)->>'total')::numeric = 59, 'first tier: 45 + 8 + 6');
select pg_temp.check((pg_temp.q('from', 10, 13, 103)->>'total')::numeric = 59, 'exactly 10 km is the first tier');
select pg_temp.check((pg_temp.q('from', 10.5, 13, 103)->>'total')::numeric = 74, 'second tier: 60 + 8 + 6');
select pg_temp.check((pg_temp.q('from', 20, 13, 103)->>'total')::numeric = 74, 'exactly 20 km is the second tier');
select pg_temp.check((pg_temp.q('from', 25, 13, 103)->>'total')::numeric = 82,
  'past the last tier, extra km: 60 + 1.5 x 5 + 8 + 6 = 81.50, rounded up to 82');
select pg_temp.check((pg_temp.q('from', 25, 13, 103)->>'fare')::numeric = 76, 'the rounding goes on the fare');
select pg_temp.check((pg_temp.q('from', 25, 13, 103)->'lines') @> '[{"label":"Rounded up","amount":0.50}]',
  'the rounding is a line of the breakdown');
update public.airport_settings set fares = jsonb_set(fares, '{band,extra}', '"all"')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check((pg_temp.q('from', 25, 13, 103)->>'total')::numeric = 112,
  'past the last tier, whole trip: 60 + 1.5 x 25 + 8 + 6 = 111.50, rounded up to 112');
-- Round up off: the cents stay.
update public.airport_settings set fares = jsonb_set(fares, '{roundUp}', 'false')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check((pg_temp.q('from', 25, 13, 103)->>'total')::numeric = 111.5, 'round-up off keeps the cents');
update public.airport_settings set fares = jsonb_set(jsonb_set(fares, '{roundUp}', 'true'), '{band,extra}', '"extra"')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
-- Applies to drop-offs only: a pickup takes the normal fare, raised to the minimum.
update public.airport_settings set fares = jsonb_set(fares, '{band,applies}', '"drop"')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check((pg_temp.q('from', 5, 13, 103)->>'total')::numeric = 41,
  'band for drop-offs only: normal 20 + 8 = 28, pickup minimum 35, + 6');
select pg_temp.check((pg_temp.q('to', 5, 13, 103, 'Comfort', 20, '[]')->>'total')::numeric = 53, 'and a drop-off takes the band: 45 + 8');
-- Minimum drop-off fare; no base for another service.
update public.airport_settings set fares = jsonb_set(fares, '{band,on}', 'false')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check((pg_temp.q('to', 5, 13, 103, 'Ride', 12.4, '[]')->>'total')::numeric = 30, 'raised to the drop-off minimum');
select pg_temp.check((pg_temp.q('to', 5, 13, 103, 'Ride', 31.2, '[]')->>'total')::numeric = 32,
  'no base for Ride; above the minimum, rounded up');
update public.airport_settings set fares = jsonb_set(fares, '{band,on}', 'true')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
update public.airport_settings set fares = jsonb_set(fares, '{band,applies}', '"both"')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check(public.airport_per_km('Nothing 249', null, null, null, null) > 0, 'a per-km rate without a card');
-- With 0248's option charges: the airport fare on the route fare, then the
-- base, the minimum, the options, the airport charge, the rounding.
select pg_temp.check((public.airport_quote('00000000-0000-0000-0000-0000000249e0', 'from', 'Comfort', 5, 20, 1.5, 13, 103,
                        '[{"name":"Airport pickup fee","value":6}]', '[{"kind":"pet","name":"Pet charge","amount":10}]')
                      @> '{"total": 69, "fare": 63, "charge": 6}'),
  'options after the minimum, before the airport charge: 45 + 8 + 10 + 6');
update public.airport_settings set fares = jsonb_set(fares, '{band,on}', 'false')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check((public.airport_quote('00000000-0000-0000-0000-0000000249e0', 'to', 'Ride', 5, 12.4, 1.5, 13, 103,
                        '[]', '[{"name":"Assistance charge","amount":4.2}]')->>'total')::numeric = 35,
  'the minimum is reached without the options: 30 + 4.20 = 34.20, rounded up to 35');
update public.airport_settings set fares = jsonb_set(fares, '{band,on}', 'true')
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check((public.airport_fare_quote(14.95, 104.95, 13, 103, 'Comfort', 5, 40, null, null, null, null,
                        '[{"name":"Pet charge","amount":10}]')->>'total')::numeric = 69,
  'the app''s quote takes the fare with the options in it, as booking does');

-- ---- 4. The rider's door; fare and charge stamped on the ride -------------------------------------
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000249c1', 14.95, 104.95, 13, 103)$q$,
  'AIRPORT_DOOR_REQUIRED', 'a pickup at the airport without a door');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000249c1', 14.95, 104.95, 13, 103, '00000000-0000-0000-0000-0000000249f1')$q$,
  'AIRPORT_DOOR_INVALID', 'a drop-off door for a pickup');
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
insert into rides values ('door', pg_temp.book('00000000-0000-0000-0000-0000000249c1', 14.95, 104.95, 13, 103,
  '00000000-0000-0000-0000-0000000249f2', null, 'Comfort', 30, 5,
  '[{"kind":"surcharge","name":"Free money","charge":"fixed","value":-50,"airport":"pick"}]'));
select pg_temp.check((select pickup_door_name from public.ride_requests where id = (select id from rides where k = 'door'))
  = 'Arrivals, Door 3', 'the door''s name is stamped by the server');
select pg_temp.check((select charges from public.ride_requests where id = (select id from rides where k = 'door'))
  = '[{"kind":"surcharge","name":"Airport pickup fee","charge":"fixed","value":6.00,"airport":"pick"}]'::jsonb,
  'the airport charge is stamped, and one the app sent is dropped');
select pg_temp.check((select fare = 53 and ride_fare = 53 and (airport_fare->>'total')::numeric = 59
                        from public.ride_requests where id = (select id from rides where k = 'door')),
  'the airport fare is stamped: 45 + 8 = 53, total with the charge 59');
select pg_temp.check((select not offer_me from public.ride_requests where id = (select id from rides where k = 'door')),
  'a fixed airport fare is not bid on');
update public.ride_requests set pickup_door_id = '00000000-0000-0000-0000-0000000249f3' where id = (select id from rides where k = 'door');
select pg_temp.check((select pickup_door_name from public.ride_requests where id = (select id from rides where k = 'door'))
  = 'Level 2, Door 2', 'the rider changes the door');
-- (The fare guard already refuses a change to the charges; the airport breakdown is kept too.)
select pg_temp.refused($q$update public.ride_requests set charges = null where id = (select id from rides where k = 'door')$q$,
  'the rider removing the airport charge');
update public.ride_requests set airport_fare = null where id = (select id from rides where k = 'door');
select pg_temp.check((select charges @> '[{"airport":"pick"}]' and airport_fare is not null
                        from public.ride_requests where id = (select id from rides where k = 'door')),
  'the rider can''t take the airport charge or breakdown off');
-- A driver takes it (pickups not restricted yet), then may not change the door.
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000249d5'
 where id = (select id from rides where k = 'door');
select pg_temp.refused_with($q$update public.ride_requests set pickup_door_id = '00000000-0000-0000-0000-0000000249f2' where id = (select id from rides where k = 'door')$q$,
  'AIRPORT_DOOR_RIDER_ONLY', 'the driver changing the door');
-- Going to the airport: the drop-off door and its charge.
reset role;
update public.airport_settings set drop_fee_on = true, drop_fee_name = 'Airport fee', drop_fee_amount = 2.5
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000249c2', 13, 103, 14.95, 104.95, null, '00000000-0000-0000-0000-0000000249f2')$q$,
  'AIRPORT_DOOR_INVALID', 'a pickup-only door for a drop-off');
insert into rides values ('to', pg_temp.book('00000000-0000-0000-0000-0000000249c2', 13, 103, 14.95, 104.95,
  null, '00000000-0000-0000-0000-0000000249f1'));
select pg_temp.check((select drop_door_name = 'Departures, Door 5'
                             and charges @> '[{"name":"Airport fee","value":2.50,"airport":"drop"}]'
                             and (airport_fare->>'total')::numeric = 56
                        from public.ride_requests where id = (select id from rides where k = 'to')),
  'a drop-off: its door, its charge and its fare (45 + 8 + 2.50 = 55.50, rounded up to 56)');
-- Booked with option charges (0248): they stay in the fare, the airport
-- charge beside it.
select pg_temp.as_user('00000000-0000-0000-0000-0000000249c3');
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, distance_km,
                                  pickup_lat, pickup_lng, drop_lat, drop_lng, pickup_door_id, option_charges)
values ('00000000-0000-0000-0000-0000000249b9', '00000000-0000-0000-0000-0000000249c3', 'open', 'Comfort', 40, 40, 5,
        14.95, 104.95, 13, 103, '00000000-0000-0000-0000-0000000249f2',
        '[{"kind":"pet","name":"Pet charge","amount":10}]');
select pg_temp.check((select fare = 63 and option_charges = '[{"kind":"pet","name":"Pet charge","amount":10}]'
                             and (airport_fare->>'total')::numeric = 69
                             and airport_fare->'lines' @> '[{"label":"Pet charge","amount":10,"option":true}]'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000249b9'),
  'option charges stay in the airport fare: route 30 -> band 45 + base 8 + pet 10 = 63, + 6 airport charge = 69');
reset role;
update public.ride_requests set status = 'cancelled' where id in (select id from rides where k in ('door', 'to'));
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000249b9';

-- ---- 5. A drop-off makes a driver eligible ------------------------------------------------------
insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                  drop_lat, drop_lng, drop_door_id)
values ('00000000-0000-0000-0000-0000000249b1', '00000000-0000-0000-0000-0000000249c3', '00000000-0000-0000-0000-0000000249d1',
        'on_trip', 'Comfort', 30, 30, 13, 103, 14.95, 104.95, '00000000-0000-0000-0000-0000000249f1');
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000249b1';
select pg_temp.check((select count(*) = 1 from public.airport_dropoffs
                       where driver_id = '00000000-0000-0000-0000-0000000249d1' and service = 'Comfort'
                         and airport_id = '00000000-0000-0000-0000-0000000249e0'),
  'a ride completed at the airport records the drop-off');
-- Driver two dropped off earlier; driver three too long ago.
insert into public.airport_dropoffs (airport_id, driver_id, service, dropped_at) values
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d2', 'Comfort', now() - interval '20 minutes'),
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d3', 'Comfort', now() - interval '2 hours');

-- ---- 6. Joining the queue -----------------------------------------------------------------------
insert into public.driver_presence (profile_id, online, lat, lng) values
  ('00000000-0000-0000-0000-0000000249d1', true, 15.02, 105.02),
  ('00000000-0000-0000-0000-0000000249d2', true, 15.02, 105.03),
  ('00000000-0000-0000-0000-0000000249d3', true, 15.03, 105.02),
  ('00000000-0000-0000-0000-0000000249d4', true, 15.04, 105.04),
  ('00000000-0000-0000-0000-0000000249d5', true, 14.95, 104.95)
on conflict (profile_id) do update set online = excluded.online, lat = excluded.lat, lng = excluded.lng, updated_at = now();
select pg_temp.check((select string_agg(driver_id::text, ',' order by place_at) from public.airport_queue)
  = '00000000-0000-0000-0000-0000000249d2,00000000-0000-0000-0000-0000000249d1',
  'drivers who dropped off join in drop-off order; a late or missing drop-off does not');
select pg_temp.check((select used_at is not null from public.airport_dropoffs where driver_id = '00000000-0000-0000-0000-0000000249d1'),
  'one drop-off, one place');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d4');
select pg_temp.check(public.airport_driver_state()->>'state' = 'refused', 'no drop-off: refused');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d3');
select pg_temp.check(public.airport_driver_state()->>'state' = 'refused', 'the window has passed: refused');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d1');
select pg_temp.check(public.airport_driver_state() @> '{"state":"queued","position":2,"total":2,"service":"Comfort"}',
  'second in the Comfort queue');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
select pg_temp.check(public.airport_driver_state()->>'state' = 'outside', 'pickups not restricted: nothing to show');
reset role;

-- ---- 7. Pickups go to the queue, in order --------------------------------------------------------
update public.airport_settings set restrict_pickups = true, pickup_from = '{queue}', empty_action = 'wait',
                                   back_on_decline = true, pick_door_required = false
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
select pg_temp.check(public.airport_driver_state()->>'state' = 'around', 'in the airport, outside the zone: go to the waiting zone');
insert into rides values ('q1', pg_temp.book('00000000-0000-0000-0000-0000000249c4', 14.95, 104.95, 13, 103));
select pg_temp.check((select airport_hold from public.ride_requests where id = (select id from rides where k = 'q1')), 'held for the queue');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'q1')) = 1, 'the first in the queue sees it');
select pg_temp.check(public.airport_driver_state()->>'state' = 'offer', 'and is told');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'q1')) = 0, 'the second does not');
select pg_temp.refused($q$update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000249d1' where id = (select id from rides where k = 'q1')$q$,
  'the second taking it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'q1')) = 0, 'a driver outside the zone does not');

-- ---- 8. A decline sends the driver to the back --------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d2');
select public.airport_decline_offer((select id from rides where k = 'q1'));
select pg_temp.check(pg_temp.sees((select id from rides where k = 'q1')) = 0, 'declined: gone');
reset role;
select pg_temp.check((select string_agg(driver_id::text, ',' order by place_at) from public.airport_queue)
  = '00000000-0000-0000-0000-0000000249d1,00000000-0000-0000-0000-0000000249d2', 'the decliner is now last');
select pg_temp.check(public.airport_ride_offered((select id from rides where k = 'q1'), '00000000-0000-0000-0000-0000000249d1'),
  'offered to the next');

-- ---- 9. A missed offer too ------------------------------------------------------------------------
update public.airport_ride_offers set until = now() - interval '1 second'
 where ride_id = (select id from rides where k = 'q1') and driver_id = '00000000-0000-0000-0000-0000000249d1';
select pg_temp.check(public.airport_dispatch((select id from rides where k = 'q1')) = 'wait',
  'everyone in the queue has had it: it waits');
select pg_temp.check((select outcome from public.airport_ride_offers
                       where ride_id = (select id from rides where k = 'q1') and driver_id = '00000000-0000-0000-0000-0000000249d1') = 'missed',
  'missed');
select pg_temp.check((select string_agg(driver_id::text, ',' order by place_at) from public.airport_queue)
  = '00000000-0000-0000-0000-0000000249d2,00000000-0000-0000-0000-0000000249d1', 'the driver who missed it is now last');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'q1');

-- ---- 10. Taking it uses the place -----------------------------------------------------------------
set local role authenticated;
insert into rides values ('q2', pg_temp.book('00000000-0000-0000-0000-0000000249c5', 14.95, 104.95, 13, 103));
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d2');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000249d2'
 where id = (select id from rides where k = 'q2');
reset role;
select pg_temp.check((select partner_id from public.ride_requests where id = (select id from rides where k = 'q2'))
  = '00000000-0000-0000-0000-0000000249d2', 'the driver offered it takes it');
select pg_temp.check(not exists (select 1 from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d2'),
  'and leaves the queue');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'q2');

-- ---- 11. With "back on decline" off, the place is kept --------------------------------------------
update public.airport_settings set back_on_decline = false where airport_id = '00000000-0000-0000-0000-0000000249e0';
insert into public.airport_dropoffs (airport_id, driver_id, service, dropped_at) values
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d3', 'Comfort', now() - interval '5 minutes');
update public.driver_presence set updated_at = now() where profile_id = '00000000-0000-0000-0000-0000000249d3';
select pg_temp.check((select string_agg(driver_id::text, ',' order by place_at) from public.airport_queue)
  = '00000000-0000-0000-0000-0000000249d3,00000000-0000-0000-0000-0000000249d1', 'a fresh drop-off joins by its time');
create temp table before_decline as select place_at from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d3';
grant all on before_decline to authenticated;
set local role authenticated;
insert into rides values ('q3', pg_temp.book('00000000-0000-0000-0000-0000000249c6', 14.95, 104.95, 13, 103));
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d3');
select public.airport_decline_offer((select id from rides where k = 'q3'));
reset role;
select pg_temp.check((select place_at from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d3')
  = (select place_at from before_decline), 'switch off: the decliner keeps the place');
select pg_temp.check(public.airport_ride_offered((select id from rides where k = 'q3'), '00000000-0000-0000-0000-0000000249d1'),
  'and the next driver is offered it');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'q3');
select pg_temp.check(not exists (select 1 from public.airport_ride_offers
                                  where ride_id = (select id from rides where k = 'q3') and outcome is null),
  'a cancelled request closes its offers');

-- ---- 12. Zone pickups: any driver in a waiting zone ------------------------------------------------
update public.airport_settings set pickup_from = '{zone}' where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
insert into rides values ('z1', pg_temp.book('00000000-0000-0000-0000-0000000249c4', 14.95, 104.95, 13, 103));
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d4');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'z1')) = 1, 'a driver in the zone, without a drop-off, sees a zone pickup');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'z1')) = 0, 'a driver outside the zones does not');
select pg_temp.refused($q$update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000249d5' where id = (select id from rides where k = 'z1')$q$,
  'a driver outside the zones taking it');
reset role;
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'z1');

-- Both: the queue first, then the zone.
update public.airport_settings set pickup_from = '{queue,zone}' where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
insert into rides values ('b1', pg_temp.book('00000000-0000-0000-0000-0000000249c5', 14.95, 104.95, 13, 103));
reset role;
select pg_temp.check((select count(*) = 1 and bool_and(stage = 'queue') from public.airport_ride_offers
                       where ride_id = (select id from rides where k = 'b1') and outcome is null),
  'both: one queue driver first');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d3');
select public.airport_decline_offer((select id from rides where k = 'b1'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d1');
select public.airport_decline_offer((select id from rides where k = 'b1'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d4');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'b1')) = 1, 'both: then the zone drivers');
reset role;
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'b1');

-- ---- 13. Nobody to offer it to: decline ---------------------------------------------------------
update public.airport_settings set pickup_from = '{queue}', empty_action = 'decline'
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
delete from public.airport_queue;
set local role authenticated;
insert into rides values ('e1', pg_temp.book('00000000-0000-0000-0000-0000000249c6', 14.95, 104.95, 13, 103));
reset role;
select pg_temp.check((select status = 'expired' and cancel_reason = 'AIRPORT_NO_DRIVER'
                        from public.ride_requests where id = (select id from rides where k = 'e1')),
  'decline: the request closes and the rider is told why');

-- ---- 14. Nobody to offer it to: nearby drivers after N minutes -------------------------------------
update public.airport_settings set empty_action = 'nearby', nearby_after_min = 5
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
insert into rides values ('n1', pg_temp.book('00000000-0000-0000-0000-0000000249c6', 14.95, 104.95, 13, 103));
reset role;
select pg_temp.check((select airport_hold and airport_open_at between now() + interval '4 minutes' and now() + interval '6 minutes'
                        from public.ride_requests where id = (select id from rides where k = 'n1')),
  'nearby: held for 5 minutes');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'n1')) = 0, 'nearby: nobody else sees it yet');
reset role;
update public.ride_requests set airport_open_at = now() - interval '1 second' where id = (select id from rides where k = 'n1');
select pg_temp.check(public.airport_dispatch((select id from rides where k = 'n1')) = 'opened', 'nearby: the time is up');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d5');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'n1')) = 1, 'nearby: now any driver sees it');
reset role;
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'n1');
update public.airport_settings set nearby_after_min = 0 where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
insert into rides values ('n0', pg_temp.book('00000000-0000-0000-0000-0000000249c6', 14.95, 104.95, 13, 103));
reset role;
select pg_temp.check((select not airport_hold and status = 'open' from public.ride_requests where id = (select id from rides where k = 'n0')),
  'nearby after 0 minutes: straight to nearby drivers');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'n0');

-- ---- 15. Leaving the zone loses the place after the grace minutes ----------------------------------
update public.airport_settings set leave_grace_min = 3 where airport_id = '00000000-0000-0000-0000-0000000249e0';
insert into public.airport_dropoffs (airport_id, driver_id, service, dropped_at) values
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d5', 'Comfort', now() - interval '1 minute');
update public.driver_presence set lat = 15.02, lng = 105.02, updated_at = now() where profile_id = '00000000-0000-0000-0000-0000000249d5';
select pg_temp.check(exists (select 1 from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d5'), 'joined');
update public.driver_presence set lat = 13, lng = 103, updated_at = now() where profile_id = '00000000-0000-0000-0000-0000000249d5';
select pg_temp.check((select outside_since is not null from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d5'),
  'left the zone: the place is kept for now');
update public.airport_queue set outside_since = now() - interval '4 minutes' where driver_id = '00000000-0000-0000-0000-0000000249d5';
select public.airport_tick();
select pg_temp.check(not exists (select 1 from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d5'),
  'away longer than the grace: the place is lost');

-- ---- 16. The app's quote is the server's --------------------------------------------------------
select pg_temp.check((public.airport_fare_quote(14.95, 104.95, 13, 103, 'Comfort', 5, 30)->>'total')::numeric = 59,
  'airport_fare_quote matches what booking stamps');
select pg_temp.check(public.airport_fare_quote(13, 103, 12.5, 102.5, 'Comfort', 5, 30) is null, 'no airport: no quote');

-- ---- 17. A vehicle without an approved service can't join a queue --------------------------------
update public.airport_settings set restrict_pickups = true, pickup_from = '{queue}', empty_action = 'wait',
                                   queue_by_service = true, need_dropoff = true
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
insert into public.airport_dropoffs (airport_id, driver_id, service, dropped_at) values
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d6', 'Comfort', now() - interval '5 minutes');
insert into public.driver_presence (profile_id, online, lat, lng)
values ('00000000-0000-0000-0000-0000000249d6', true, 15.02, 105.02)
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng, updated_at = now();
select pg_temp.check(not exists (select 1 from public.airport_queue where driver_id = '00000000-0000-0000-0000-0000000249d6'),
  'no approved service: not queued');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d6');
select pg_temp.check(public.airport_driver_state() @> '{"state":"refused","reason":"no_service"}', 'told why: no service type');
reset role;

-- ---- 18. The vehicle's service: from its make & model, the driver's choice, the admin's approval ------
insert into public.vehicle_make_models (vehicle_type, energy_type, make, model, service_id) values
  ('Sedan', 'Petrol', 'Mapped249', 'Car', '00000000-0000-0000-0000-000000024953');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d6');
insert into public.vehicle (id, auth_user_id, plate, make, model, vehicle_type, service_approved_id) values
  ('00000000-0000-0000-0000-0000000249b6', '00000000-0000-0000-0000-0000000249d6', 'MAP249', 'Mapped249', 'Car', 'Sedan',
   '00000000-0000-0000-0000-000000024954');
select pg_temp.check((select service_id = '00000000-0000-0000-0000-000000024953' and service_approved_id is null
                        from public.vehicle where id = '00000000-0000-0000-0000-0000000249b6'),
  'a make & model that maps a service gives it; the driver can''t approve it');
reset role;
update public.vehicle set status = 'approved' where id = '00000000-0000-0000-0000-0000000249b6';
select pg_temp.check((select service_approved_id from public.vehicle where id = '00000000-0000-0000-0000-0000000249b6')
  = '00000000-0000-0000-0000-000000024953', 'approving the vehicle approves its service');
update public.vehicle set service_approved_id = '00000000-0000-0000-0000-000000024952'
 where id = '00000000-0000-0000-0000-0000000249b6';
select pg_temp.check(public.driver_vehicle_service('00000000-0000-0000-0000-0000000249d6') = '00000000-0000-0000-0000-000000024952',
  'the admin changes it, and that is the driver''s service');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d6');
update public.vehicle set service_id = '00000000-0000-0000-0000-000000024954' where id = '00000000-0000-0000-0000-0000000249b6';
reset role;
select pg_temp.check((select service_approved_id is null from public.vehicle where id = '00000000-0000-0000-0000-0000000249b6'),
  'the driver choosing another service needs approving again');
delete from public.vehicle where id = '00000000-0000-0000-0000-0000000249b6';

-- ---- 19. Service lines: own line first, then higher ones; never a lower one -------------------------
delete from public.airport_queue;
insert into public.airport_queue (airport_id, driver_id, service, place_at) values
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d1', '00000000-0000-0000-0000-000000024951', now() - interval '30 minutes'),
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d2', '00000000-0000-0000-0000-000000024952', now() - interval '40 minutes'),
  ('00000000-0000-0000-0000-0000000249e0', '00000000-0000-0000-0000-0000000249d3', '00000000-0000-0000-0000-000000024954', now() - interval '50 minutes');
update public.driver_presence set online = true, lat = 15.02, lng = 105.02, updated_at = now()
 where profile_id in ('00000000-0000-0000-0000-0000000249d1', '00000000-0000-0000-0000-0000000249d2',
                      '00000000-0000-0000-0000-0000000249d3');
create or replace function pg_temp.lineup(p_service text, p_by boolean) returns text language sql as $$
  select string_agg(right(driver_id::text, 2), ',' order by n)
    from (select driver_id, row_number() over () n
            from public.airport_queue_lineup('00000000-0000-0000-0000-0000000249e0', p_service, p_by)) x;
$$;
select pg_temp.check(pg_temp.lineup('Ride 249', true) = 'd1,d2,d3', 'a Ride order: the Ride line, then Comfort, then Premium');
select pg_temp.check(pg_temp.lineup('ride 249', false) = 'd3,d2,d1', 'one queue for every service: by place only');
select pg_temp.check(pg_temp.lineup('Comfort', true) = 'd2,d3', 'a Comfort order never goes to a Ride driver');
select pg_temp.check(pg_temp.lineup('Premium 249', true) = 'd3', 'a Premium order only to Premium');
select pg_temp.check(public.airport_line_gap('00000000-0000-0000-0000-000000024954', 'Ride 249') = 3
                     and public.airport_line_gap('00000000-0000-0000-0000-000000024951', 'Premium 249') is null
                     and public.airport_line_gap(null, 'Ride 249') is null,
  'the gap between lines');
set local role authenticated;
insert into rides values ('p1', pg_temp.book('00000000-0000-0000-0000-0000000249c1', 14.95, 104.95, 13, 103,
  '00000000-0000-0000-0000-0000000249f2', null, 'Premium 249'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d3');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'p1')) = 1, 'the Premium driver gets the Premium order');
select pg_temp.as_user('00000000-0000-0000-0000-0000000249d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'p1')) = 0, 'a Comfort driver does not');
reset role;
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'p1');
-- Zone pickups follow the same rule, on the vehicle's approved service.
update public.airport_settings set pickup_from = '{zone}' where airport_id = '00000000-0000-0000-0000-0000000249e0';
set local role authenticated;
insert into rides values ('p2', pg_temp.book('00000000-0000-0000-0000-0000000249c1', 14.95, 104.95, 13, 103,
  '00000000-0000-0000-0000-0000000249f2', null, 'Premium 249'));
reset role;
select pg_temp.check((select string_agg(right(driver_id::text, 2), ',' order by driver_id) from public.airport_ride_offers
                       where ride_id = (select id from rides where k = 'p2')) = 'd4',
  'a Premium zone pickup: only the Premium vehicle in the zone');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'p2');

-- ---- 20. Scheduled rides pick their doors too -------------------------------------------------------
update public.airport_settings set pick_door_required = true, restrict_pickups = false
 where airport_id = '00000000-0000-0000-0000-0000000249e0';
select pg_temp.check(public.scheduled_request_clean('{"pickup_door_id":"x","drop_door_id":"y","nope":1}')
  = '{"pickup_door_id":"x","drop_door_id":"y"}', 'a scheduled booking keeps its doors');
create or replace function pg_temp.schedule(p_door uuid) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng, fare)
  values ('00000000-0000-0000-0000-0000000249c2', now() + interval '2 hours',
          jsonb_build_object('service', 'Comfort', 'pickup_lat', 14.95, 'pickup_lng', 104.95, 'drop_lat', 13, 'drop_lng', 103,
                             'fare', 30, 'distance_km', 5) || coalesce(jsonb_build_object('pickup_door_id', p_door), '{}'),
          'Comfort', 14.95, 104.95, 13, 103, 30)
  returning id into v;
  return v;
end $$;
select pg_temp.refused_with($q$select pg_temp.schedule(null)$q$, 'AIRPORT_DOOR_REQUIRED', 'scheduling an airport pickup without a door');
select pg_temp.refused_with($q$select pg_temp.schedule('00000000-0000-0000-0000-0000000249f1')$q$, 'AIRPORT_DOOR_INVALID',
  'scheduling with a drop-off door for the pickup');
create temp table sched as select pg_temp.schedule('00000000-0000-0000-0000-0000000249f2') as id;
select pg_temp.check((select request->>'pickup_door_id' from public.scheduled_rides where id = (select id from sched))
  = '00000000-0000-0000-0000-0000000249f2', 'scheduled with its door');
create temp table rel as select public.scheduled_ride_release((select id from sched)) as id;
select pg_temp.check((select pickup_door_name from public.ride_requests where id = (select id from rel))
  = 'Arrivals, Door 3', 'released with its door');
-- A booking without one (made before the door was asked for) is refused on release.
alter table public.scheduled_rides disable trigger trg_scheduled_rides_airport_doors;
create temp table sched2 as select pg_temp.schedule(null) as id;
alter table public.scheduled_rides enable trigger trg_scheduled_rides_airport_doors;
update public.ride_requests set status = 'cancelled' where scheduled_ride_id = (select id from sched);
select pg_temp.refused_with($q$select public.scheduled_ride_release((select id from sched2))$q$, 'AIRPORT_DOOR_REQUIRED',
  'releasing a scheduled airport pickup without a door');

rollback;
select 'airport_queue_0249: all passed';
