-- ============================================================================
-- Regression test for migration 0264: place types -- the starting types,
-- the guess from a place's name and OpenStreetMap type (the backfill and
-- every save), a place inside an airport always an airport, who writes the
-- types, removing a type in use (refused, or its places moved), and the
-- place type stamped on a ride's pickup and drop-off.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/place_types_0264.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000264a1'),  -- admin, EDIT on Place types
  ('00000000-0000-0000-0000-0000000264a2'),  -- admin, READ on Place types
  ('00000000-0000-0000-0000-0000000264a3'),  -- admin, EDIT on Multi-Gate Places
  ('00000000-0000-0000-0000-0000000264a4'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000264c1'),  -- riders
  ('00000000-0000-0000-0000-0000000264c2'),
  ('00000000-0000-0000-0000-0000000264c3')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000264%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000264a1', 'admin-settings-place-types', 'edit'),
  ('00000000-0000-0000-0000-0000000264a2', 'admin-settings-place-types', 'read'),
  ('00000000-0000-0000-0000-0000000264a3', 'admin-settings-multi-gate-places', 'edit'),
  ('00000000-0000-0000-0000-0000000264a4', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

-- A country (lat 40..50, lng 130..140) the rides are booked in, and an
-- airport 45.0..45.2 / 135.0..135.2.
insert into public.countries (name, values, geofence) values
  ('Typeland 264', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":50,"south":40,"east":140,"west":130}}'));
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000264e0', jsonb_build_object('name', 'Airport 264', 'code', 'TPA',
    'boundary', '{"bbox":{"north":45.2,"south":45.0,"east":135.2,"west":135.0}}'));

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
create or replace function pg_temp.type_of(p uuid) returns text language sql as $$
  select values->>'placeType' from public.multi_gate where id = p;
$$;
create or replace function pg_temp.book(p_rider uuid, p_plat float8, p_plng float8, p_dlat float8, p_dlng float8,
                                        p_pick_door uuid default null)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, distance_km,
                                    pickup_lat, pickup_lng, drop_lat, drop_lng, pickup_door_id,
                                    pickup_place_type, drop_place_type)
  values (v, p_rider, 'open', 'Ride', 20, 20, 6, p_plat, p_plng, p_dlat, p_dlng, p_pick_door,
          'lodging', 'lodging');
  return v;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text), pg_temp.type_of(uuid),
  pg_temp.book(uuid, float8, float8, float8, float8, uuid) to authenticated;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;

-- ---- 0. The starting types -------------------------------------------------------------------------
select pg_temp.check((select count(*) from public.place_types
                       where key in ('shopping_mall', 'airport', 'train_station', 'subway_station', 'bus_station',
                                     'ferry_terminal', 'hospital', 'lodging', 'university', 'corporate_office', 'stadium',
                                     'convention_center', 'mosque', 'market', 'local_government_office',
                                     'tourist_attraction', 'park', 'point_of_interest')) = 18,
  'the eighteen starting types, keyed by Google place type');
select pg_temp.check((select name = 'MRT / LRT station' and icon = 'subway' and color = '#10bdff' and color_dark ~ '^#'
                        from public.place_types where key = 'subway_station'),
  'a type has its name, icon and Google Maps'' category colour');
select pg_temp.check((select name = 'Other' from public.place_types where key = 'point_of_interest'), 'Other is point_of_interest');
select pg_temp.check(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                               and schemaname = 'public' and tablename = 'place_types'), 'followed live');
select pg_temp.check((select array_agg(page order by page) from public.admin_table_pages where target = 'place_types')
                       = array['admin-settings-multi-gate-places', 'admin-settings-place-types'],
  'written from Place types or Multi-Gate Places');

-- ---- 1. The guess ----------------------------------------------------------------------------------
-- The same examples as test/place_types_test.dart.
select pg_temp.check(public.place_type_guess(n) = k, format('%s guessed %s, not %s', n, public.place_type_guess(n), k))
  from (values
    ('KLCC', 'shopping_mall'), ('Mid Valley Megamall', 'shopping_mall'), ('Plaza Low Yat', 'shopping_mall'),
    ('Times Square', 'shopping_mall'), ('Lrtx Plaza', 'shopping_mall'),
    ('Sunway Pyramid', 'shopping_mall'), ('Pavilion KL', 'shopping_mall'), ('ION Orchard', 'shopping_mall'),
    ('The Gardens Mall', 'shopping_mall'), ('Mitsui Shopping Park LaLaport Bukit Bintang City Centre', 'shopping_mall'),
    ('Changi City Point', 'shopping_mall'), ('Somewhere 264', 'point_of_interest'), ('', 'point_of_interest'),
    ('Supermarket Giant', 'point_of_interest'),
    ('KLIA Terminal 1', 'airport'), ('klia2', 'airport'), ('Senai International Airport', 'airport'),
    ('KL Sentral', 'train_station'), ('KTM Rawang', 'train_station'), ('Stesen Keretapi Ipoh', 'train_station'),
    ('MRT Bukit Bintang', 'subway_station'), ('LRT Station Ampang', 'subway_station'),
    ('Terminal Bersepadu Selatan', 'bus_station'), ('Bus terminal Larkin', 'bus_station'),
    ('Hospital Kuala Lumpur', 'hospital'), ('Sunway Medical Centre', 'hospital'), ('Klinik Kesihatan', 'hospital'),
    ('Hilton Hotel', 'lodging'), ('Genting Resort', 'lodging'),
    ('Universiti Malaya', 'university'), ('Taylor''s College', 'university'), ('Kolej Komuniti', 'university'),
    ('Menara KL', 'corporate_office'), ('Petronas Tower 3', 'corporate_office'),
    ('Stadium Bukit Jalil', 'stadium'), ('Axiata Arena', 'stadium'), ('KL Convention Centre', 'convention_center'),
    ('Terminal Feri Kuah', 'ferry_terminal'), ('Jetty Point', 'ferry_terminal'),
    ('Masjid Negara', 'mosque'), ('Sri Mahamariamman Temple', 'mosque'), ('Kuil Batu Caves', 'mosque'),
    ('Pasar Seni', 'market'), ('Central Market', 'market'),
    ('Jabatan Imigresen Putrajaya', 'local_government_office'),
    ('Muzium Negara', 'tourist_attraction'), ('Zoo Negara', 'tourist_attraction'),
    ('KLCC Park', 'park'), ('Taman Tasik Perdana', 'park')
  ) as t(n, k);
select pg_temp.check(public.place_type_guess('Somewhere', 'aerodrome') = 'airport', 'OpenStreetMap''s aerodrome');
select pg_temp.check(public.place_type_guess('Plaza 264', 'hospital') = 'hospital', 'OpenStreetMap''s type before the name');
select pg_temp.check(public.place_type_guess('Plaza 264', 'yes') = 'shopping_mall', 'an unknown OpenStreetMap type: the name');
select pg_temp.check(public.place_type_guess('Plaza 264', 'hospital', 'lodging') = 'lodging',
  'Google''s main type before OpenStreetMap''s and the name');
select pg_temp.check(public.place_type_guess('Hotel 264', null, 'light_rail_station') = 'subway_station',
  'a Google type that means a starting type');
select pg_temp.check(public.place_type_guess('Hotel 264', null, 'car_wash') = 'lodging',
  'a Google type that is no place type: the name');
-- A Google type the admin added as a type of its own is taken by the pick.
insert into public.place_types (key, name, icon) values ('car_rental', 'Car rental', 'car_rental');
select pg_temp.check(public.place_type_pick('Hotel 264', null, 'car_rental') = 'car_rental',
  'a Google type added as a place type is taken');
update public.place_types set active = false where key = 'market';
select pg_temp.check(public.place_type_pick('Pasar Seni') = 'point_of_interest', 'a switched-off type is not guessed');
update public.place_types set active = true where key = 'market';

-- The backfill: places added before 0264 (no type) get the guess; a place
-- inside an airport is an airport; one the admin set keeps it.
alter table public.multi_gate disable trigger trg_multi_gate_place_type;
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000264f1', 'place', '{"name":"Mid Valley Megamall","lat":"41.0","lon":"131.0"}'),
  ('00000000-0000-0000-0000-0000000264f2', 'place', '{"name":"KL Sentral","lat":"41.1","lon":"131.1"}'),
  ('00000000-0000-0000-0000-0000000264f3', 'place', '{"name":"Grand Hotel 264","lat":"45.1","lon":"135.1"}'),
  ('00000000-0000-0000-0000-0000000264f4', 'place', '{"name":"Somewhere 264","lat":"41.2","lon":"131.2"}'),
  ('00000000-0000-0000-0000-0000000264f5', 'place', '{"name":"Hospital 264","lat":"41.3","lon":"131.3","placeType":"stadium","placeTypeSet":true}'),
  ('00000000-0000-0000-0000-0000000264f6', 'place', '{"name":"Somewhere 264","osmType":"bus_station","lat":"41.4","lon":"131.4"}'),
  ('00000000-0000-0000-0000-0000000264f8', 'place', '{"name":"Hotel Plaza 264","primaryType":"shopping_mall","iconBackgroundColor":"#4B96F3","lat":"41.6","lon":"131.6"}');
alter table public.multi_gate enable trigger trg_multi_gate_place_type;
-- 0264's backfill, as written there.
update public.multi_gate g
   set values = g.values || jsonb_build_object('placeType', public.place_type_for(g.values), 'placeTypeSet', false)
 where g.kind = 'place'
   and jsonb_typeof(g.values) = 'object'
   and lower(coalesce(g.values->>'placeTypeSet', 'false')) not in ('true', '1', 'yes', 'on');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f1') = 'shopping_mall', 'backfill: a mall');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f2') = 'train_station', 'backfill: a station');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f3') = 'airport',
  'backfill: a place inside an airport is an airport, whatever its name');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f4') = 'point_of_interest', 'backfill: nothing matches: Other');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f5') = 'stadium', 'backfill: the admin''s choice stays');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f6') = 'bus_station', 'backfill: OpenStreetMap''s type');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f8') = 'shopping_mall',
  'backfill: Google''s main type before the name');
select pg_temp.check((select values->>'placeTypeSet' = 'false' from public.multi_gate
                       where id = '00000000-0000-0000-0000-0000000264f1'), 'a guess is not set by the admin');
select pg_temp.check(not exists (select 1 from public.multi_gate where kind = 'place' and not (values ? 'placeType')),
  'every place has a type');
select pg_temp.check(not exists (select 1 from public.multi_gate where kind = 'gate' and values ? 'placeType'),
  'gates have none');

-- ---- 2. Every save keeps a place typed ---------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a3');
-- A new place: the guess.
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000264f7', 'place', '{"name":"Masjid 264","lat":"41.5","lon":"131.5"}');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f7') = 'mosque', 'a new place is guessed');
-- Renamed while it is the guess: guessed again.
update public.multi_gate set values = values || '{"name":"Pasar 264"}' where id = '00000000-0000-0000-0000-0000000264f7';
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f7') = 'market', 'a rename moves the guess');
-- The admin chooses: kept, also through a rename.
update public.multi_gate set values = values || '{"placeType":"lodging","placeTypeSet":true}'
 where id = '00000000-0000-0000-0000-0000000264f7';
update public.multi_gate set values = values || '{"name":"Masjid 264"}' where id = '00000000-0000-0000-0000-0000000264f7';
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f7') = 'lodging', 'the admin''s choice stays');
-- An older app saves the whole values without the type: the type stays.
update public.multi_gate set values = '{"name":"Masjid 264","lat":"41.5","lon":"131.5","gates":2}'
 where id = '00000000-0000-0000-0000-0000000264f7';
select pg_temp.check((select values->>'placeType' = 'lodging' and values->>'placeTypeSet' = 'true'
                        from public.multi_gate where id = '00000000-0000-0000-0000-0000000264f7'),
  'a save without the type keeps the admin''s choice');
-- A key that doesn't exist: the guess.
update public.multi_gate set values = values || '{"placeType":"spaceport","placeTypeSet":true}'
 where id = '00000000-0000-0000-0000-0000000264f7';
select pg_temp.check((select values->>'placeType' = 'mosque' and values->>'placeTypeSet' = 'false'
                        from public.multi_gate where id = '00000000-0000-0000-0000-0000000264f7'),
  'an unknown type falls back to the guess');
reset role;

-- ---- 3. Who writes the types -------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000264c1');
select pg_temp.check((select count(*) from public.place_types) >= 18, 'a rider reads the types');
select pg_temp.refused($q$insert into public.place_types (key, name) values ('rider264', 'Rider')$q$, 'a rider adding a type');
select pg_temp.refused($q$update public.place_types set name = 'Shops' where key = 'shopping_mall'$q$, 'a rider renaming one');
select pg_temp.refused($q$delete from public.place_types where key = 'ferry_terminal'$q$, 'a rider removing one');
select pg_temp.refused_with($q$select public.place_type_remove('ferry_terminal')$q$, 'NOT_ALLOWED', 'a rider removing one by the function');

select pg_temp.as_user('00000000-0000-0000-0000-0000000264a2');
select pg_temp.refused($q$update public.place_types set name = 'Shops' where key = 'shopping_mall'$q$,
  'an admin with READ on the page changing a type');
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a4');
select pg_temp.refused($q$insert into public.place_types (key, name) values ('other264', 'Other page')$q$,
  'another page''s admin adding a type');

select pg_temp.as_user('00000000-0000-0000-0000-0000000264a1');
insert into public.place_types (key, name, icon, color, color_dark, sort_order)
values ('park264', 'Park 264', 'park', '#15803d', '#86efac', 140);
update public.place_types set name = 'Shopping mall', updated_at = '2000-01-01', updated_by = null where key = 'shopping_mall';
select pg_temp.check((select name = 'Shopping mall' and updated_at > now() - interval '1 minute'
                             and updated_by = '00000000-0000-0000-0000-0000000264a1'
                        from public.place_types where key = 'shopping_mall'), 'the page''s EDIT grant writes; the server stamps it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a3');
update public.place_types set sort_order = 145 where key = 'park264';
select pg_temp.check((select sort_order = 145 from public.place_types where key = 'park264'),
  'Multi-Gate Places'' EDIT grant writes the types too');
select pg_temp.refused($q$insert into public.place_types (key, name, color) values ('bad264', 'Bad', 'red')$q$,
  'a colour that isn''t #RRGGBB');
select pg_temp.refused_with($q$update public.place_types set key = 'park265' where key = 'park264'$q$,
  'PLACE_TYPE_KEY_FIXED', 'changing a type''s key');
select pg_temp.refused($q$update public.place_types set active = false where key = 'point_of_interest'$q$, 'switching Other off');

-- ---- 4. Removing a type ------------------------------------------------------------------------------
-- Two places of the new type (Multi-Gate Places writes the places).
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a3');
update public.multi_gate set values = values || '{"placeType":"park264","placeTypeSet":true}'
 where id in ('00000000-0000-0000-0000-0000000264f1', '00000000-0000-0000-0000-0000000264f2');
select pg_temp.check((select count(*) = 2 from public.multi_gate where values->>'placeType' = 'park264'),
  'two places use it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a1');
select pg_temp.refused_with($q$delete from public.place_types where key = 'park264'$q$, 'PLACE_TYPE_IN_USE',
  'a type in use is not removed');
select pg_temp.refused_with($q$delete from public.place_types where key = 'point_of_interest'$q$, 'PLACE_TYPE_REQUIRED',
  'Other is not removed');
select pg_temp.refused_with($q$select public.place_type_remove('park264', 'park264')$q$, 'PLACE_TYPE_MOVE_TO',
  'moving its places to itself');
select pg_temp.check(public.place_type_remove('park264', 'stadium') = 2, 'its two places are moved');
select pg_temp.check(not exists (select 1 from public.place_types where key = 'park264'), 'and the type is gone');
select pg_temp.check((select bool_and(values->>'placeType' = 'stadium' and values->>'placeTypeSet' = 'true')
                        from public.multi_gate
                       where id in ('00000000-0000-0000-0000-0000000264f1', '00000000-0000-0000-0000-0000000264f2')),
  'its places are now the chosen type');
insert into public.place_types (key, name, sort_order) values ('kiosk264', 'Kiosk 264', 150);
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a3');
update public.multi_gate set values = values || '{"placeType":"kiosk264","placeTypeSet":true}'
 where id = '00000000-0000-0000-0000-0000000264f1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000264a1');
select pg_temp.check(public.place_type_remove('kiosk264') = 1, 'removed with its place moved to Other');
select pg_temp.check(pg_temp.type_of('00000000-0000-0000-0000-0000000264f1') = 'point_of_interest', 'by default to Other');
insert into public.place_types (key, name, sort_order) values ('empty264', 'Empty 264', 160);
delete from public.place_types where key = 'empty264';
select pg_temp.check(not exists (select 1 from public.place_types where key = 'empty264'), 'a type no place uses is removed');
reset role;

-- ---- 5. The ride's place types -----------------------------------------------------------------------
-- f2 (KL Sentral, now a stadium) has a gate at 41.105 / 131.105 and no boundary.
update public.multi_gate set values = values || '{"placeType":"train_station","placeTypeSet":true}'
 where id = '00000000-0000-0000-0000-0000000264f2';
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000264b1', 'gate',
   '{"placeId":"00000000-0000-0000-0000-0000000264f2","name":"Exit B","mode":"both","lat":"41.105","lon":"131.105"}');

set local role authenticated;
-- At the place's gate, to the airport.
insert into rides select 'gate', pg_temp.book('00000000-0000-0000-0000-0000000264c1', 41.1050003, 131.1050003, 45.1, 135.15);
-- At the place's own point, to nowhere in particular.
insert into rides select 'point', pg_temp.book('00000000-0000-0000-0000-0000000264c2', 41.1003, 131.1003, 42.0, 132.0);
-- Far from every place.
insert into rides select 'none', pg_temp.book('00000000-0000-0000-0000-0000000264c3', 43.0, 133.0, 42.0, 132.0);
reset role;

select pg_temp.check((select pickup_place_type = 'train_station' and drop_place_type = 'airport'
                        from public.ride_requests where id = (select id from rides where k = 'gate')),
  'a pickup at a place''s gate has its type; a drop-off at the airport is an airport');
select pg_temp.check((select pickup_place_type = 'train_station' and drop_place_type is null
                        from public.ride_requests where id = (select id from rides where k = 'point')),
  'a pickup at the place''s point has its type; nowhere is no type');
select pg_temp.check(public.place_type_at(null, '00000000-0000-0000-0000-0000000264b1', 43.0, 133.0) = 'train_station',
  'a place''s door gives its type');
select pg_temp.check((select pickup_place_type is null and drop_place_type is null from public.ride_requests
                       where id = (select id from rides where k = 'none')),
  'what the app sent is dropped: the server stamps it');

-- The rider can't change it afterwards.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000264c1');
update public.ride_requests set pickup_place_type = 'lodging', drop_place_type = 'lodging'
 where id = (select id from rides where k = 'gate');
reset role;
select pg_temp.check((select pickup_place_type = 'train_station' and drop_place_type = 'airport'
                        from public.ride_requests where id = (select id from rides where k = 'gate')),
  'a client''s change to the stamp is undone');

-- place_type_at straight: an airport area, a place area, an airport gate.
select pg_temp.check(public.place_type_at('00000000-0000-0000-0000-0000000264e0', null, null, null) = 'airport',
  'an airport area');
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000264b2', 'gate',
   '{"placeId":"00000000-0000-0000-0000-0000000264e0","parentKey":"airport-areas","name":"Door 1","lat":"45.1","lon":"135.1"}');
select pg_temp.check(public.place_type_at(null, '00000000-0000-0000-0000-0000000264b2', null, null) = 'airport',
  'an airport''s door');
update public.multi_gate set values = values || jsonb_build_object('areaOn', true, 'boundary',
  '{"coords":[{"latitude":41.31,"longitude":131.29},{"latitude":41.31,"longitude":131.31},{"latitude":41.29,"longitude":131.31},{"latitude":41.29,"longitude":131.29}],"bbox":{"north":41.31,"south":41.29,"east":131.31,"west":131.29}}')
 where id = '00000000-0000-0000-0000-0000000264f5';
select pg_temp.check(public.place_type_at(public.area_at(41.3, 131.3), null, 41.3, 131.3) = 'stadium',
  'a place with its boundary on: its type');

-- ---- 6. Grants -----------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.place_type_remove(text, text)', 'execute'),
  'anon can''t remove types');
select pg_temp.check(not has_function_privilege('authenticated', 'public.place_type_at(uuid, uuid, float8, float8)', 'execute'),
  'the stamp helper is the server''s');
select pg_temp.check(not has_table_privilege('anon', 'public.place_types', 'select'), 'anon doesn''t read the types');

rollback;

select 'place_types_0264: all passed';
