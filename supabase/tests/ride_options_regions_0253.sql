-- ============================================================================
-- Regression test for migration 0253: Ride Options by place (charges, offered
-- here, blocked services; the smallest place wins, nothing set is free), the
-- blob's amounts as Default, a booking with an option not offered refused,
-- and the extras each driver takes (their own row, the read rule, the
-- pushes, My Ride, scheduled rides, the "not shown" count).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_options_regions_0253.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000253a1'),  -- admin, EDIT on Display Settings
  ('00000000-0000-0000-0000-0000000253a2'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000253c1'),  -- riders
  ('00000000-0000-0000-0000-0000000253c2'),
  ('00000000-0000-0000-0000-0000000253d1'),  -- driver who takes everything
  ('00000000-0000-0000-0000-0000000253d2')   -- driver who turns dogs off
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000253%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000253a1', 'admin-settings-display', 'edit'),
  ('00000000-0000-0000-0000-0000000253a2', 'admin-settings-ip-access', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status)
select u.id, 'Driver ' || right(u.id::text, 2), '6013000' || right(u.id::text, 4), 'approved'
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000253d%';
insert into public.driver_presence (profile_id, online, lat, lng)
select id, true, 25.0, 115.0 from auth.users where id::text like '00000000-0000-0000-0000-0000000253d%'
on conflict (profile_id) do update set online = true, lat = 25.0, lng = 115.0, updated_at = now();

-- A country holding the pickup, and a state inside it holding it too.
insert into public.countries (name, values, geofence) values
  ('Optland 253', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":30,"south":20,"east":120,"west":110}}'));
insert into public.states (country, name, values, geofence) values
  ('Optland 253', 'Optstate 253', '{}', jsonb_build_object('boundary',
    '{"bbox":{"north":26,"south":24,"east":116,"west":114}}'));
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000025351', 'vehicle-services', '{"name":"Ride 253"}', 1),
  ('00000000-0000-0000-0000-000000025352', 'vehicle-services', '{"name":"Premium 253"}', 2);

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
-- A booking at the pickup (25, 115) with the options in [p_extra].
create or replace function pg_temp.book(p_rider uuid, p_service text, p_extra jsonb default '{}',
                                        p_targets uuid[] default null)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, passengers, pets, assistance, option_names, target_driver_ids)
  values (v, p_rider, 'open', p_service, 30, 30, 25.0, 115.0, 25.1, 115.1,
          coalesce((p_extra->>'passengers')::int, 1), p_extra->'pets', p_extra->'assistance', p_extra->'option_names',
          p_targets);
  return v;
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text), pg_temp.book(uuid, text, jsonb, uuid[]), pg_temp.sees(uuid) to authenticated;

-- ---- 1. The blob's amounts as Default -------------------------------------------------------------
select pg_temp.check(public.ride_option_charges_from_blob(
  '{"petCharges": {"Dog": {"kind": "fixed", "value": 10, "per": "pet"}, "Cat": {"kind": "percent", "value": 5, "per": "ride"},
                   "Bird": {"kind": "fixed", "value": 0}},
    "petSizeExtras": {"L": 2.5, "S": 0},
    "assistanceCatalogue": [{"id": "wheelchair", "charge": {"kind": "fixed", "value": 5}},
                            {"id": "guide-dog", "charge": {"kind": "fixed", "value": 3}},
                            {"id": "quiet"}]}')
  = '{"pet:Dog": {"kind": "fixed", "value": 10, "per": "pet"}, "pet:Cat": {"kind": "percent", "value": 5, "per": "ride"},
      "pet-size:L": {"kind": "fixed", "value": 2.5}, "assist:wheelchair": {"kind": "fixed", "value": 5}}'::jsonb,
  'each pet type, size extra and help item charge moves over; zero ones and the guide dog do not');
select pg_temp.check(public.ride_option_charges_from_blob('{}') = '{}'::jsonb, 'an empty blob: nothing set');
select pg_temp.check(exists (select 1 from public.ride_option_places where level = 'default'),
  'the Default row is there');

-- ---- 2. Who writes the places -------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000253c1');
select pg_temp.refused($q$insert into public.ride_option_places (level, country) values ('country', 'Optland 253')$q$,
  'a rider writing a place');
select pg_temp.check((select count(*) from public.ride_option_places where level = 'default') = 1,
  'riders read the places');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253a2');
select pg_temp.refused($q$insert into public.ride_option_places (level, country) values ('country', 'Optland 253')$q$,
  'another page''s admin writing a place');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253a1');
update public.ride_option_places
   set charges = '{"pet:Dog": {"kind": "fixed", "value": 8, "per": "pet"}, "pet-size:L": {"kind": "fixed", "value": 3},
                   "child-seat": {"kind": "fixed", "value": 5}}',
       blocked = '{"pet": ["00000000-0000-0000-0000-000000025352"]}'
 where level = 'default';
insert into public.ride_option_places (level, country, charges) values
  ('country', 'Optland 253', '{"pet:Dog": {"kind": "fixed", "value": 9, "per": "pet"}}');
insert into public.ride_option_places (level, country, state, charges, offered) values
  ('state', 'OPTLAND 253', 'Optstate 253', '{"assist:luggage": {"kind": "fixed", "value": 4}, "child-seat": {"kind": "fixed", "value": 0}}',
   '{"assistance": false}');
select pg_temp.refused_with($q$insert into public.ride_option_places (level, country) values ('country', 'optland 253')$q$,
  'ride_option_places_key_uidx', 'one row per place, whatever the case');
select pg_temp.refused_with($q$insert into public.ride_option_places (level, country, charges) values ('country', 'X', '{"pet:Dog": {"value": -1}}')$q$,
  'ride_option_places_valid', 'a negative charge');
select pg_temp.refused_with($q$insert into public.ride_option_places (level, country, offered) values ('country', 'X', '{"comments": false}')$q$,
  'ride_option_places_valid', 'Comments can''t be switched off');
select pg_temp.refused_with($q$insert into public.ride_option_places (level, state) values ('state', 'X')$q$,
  'ride_option_places_names', 'a state without its country');
reset role;

-- ---- 3. What holds at a place --------------------------------------------------------------------
select pg_temp.check((select public.ride_option_place_at(25.0, 115.0)) = '{"country": "Optland 253", "state": "Optstate 253", "city": "", "suburb": ""}'::jsonb,
  'the pickup''s place: the smallest outline at each level');
select pg_temp.check((select public.ride_option_place_at(21.0, 111.0)) = '{"country": "Optland 253", "state": "", "city": "", "suburb": ""}'::jsonb,
  'outside the state''s outline: the country');
select pg_temp.check((select public.ride_option_place_at(null, null, 'Nowhere', 'Somestate', 'Town')) =
                     '{"country": "Nowhere", "state": "Somestate", "city": "Town", "suburb": ""}'::jsonb,
  'no outline: the geocoder''s names (never a suburb)');
create temp table here as select public.ride_option_settings_at('Optland 253', 'Optstate 253', '', '') s;
select pg_temp.check((select s->'charges'->'pet:Dog'->>'value' from here) = '9', 'the country''s own amount beats Default''s');
select pg_temp.check((select s->'charges'->'pet-size:L'->>'value' from here) = '3', 'nothing set below: Default''s');
select pg_temp.check((select s->'charges'->'child-seat'->>'value' from here) = '0', 'set to 0 in the state: free there');
select pg_temp.check((select not (s->'charges' ? 'pet:Cat') from here), 'nothing set anywhere: no charge');
select pg_temp.check((select s->'offered'->>'assistance' from here) = 'false', 'Assistance is off in the state');
select pg_temp.check((select public.ride_option_settings_at('Optland 253', '', '', '')->'offered' = '{}'::jsonb),
  'and on in the rest of the country');
select pg_temp.check((select public.ride_option_settings_at('Elsewhere', '', '', '')->'charges'->'pet:Dog'->>'value') = '8',
  'another country: Default''s');

-- ---- 4. A booking with an option not offered ----------------------------------------------------
select set_config('request.jwt.claims', '', true);
select public.set_scheduled_rides_config('{"enabled": true, "mode": "advance"}');
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000253c1', 'Ride 253',
  '{"assistance": {"items": [{"id": "luggage", "name": "Help with luggage"}]}, "option_names": {"assistance": "Assistance required"}}')$q$,
  'RIDE_OPTION_NOT_OFFERED', 'Assistance where it is off');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000253c1', 'Premium 253',
  '{"pets": [{"type": "Dog", "size": "L"}], "option_names": {"pet": "Pet with me"}}')$q$,
  'RIDE_OPTION_NOT_OFFERED', 'a pet on Premium, where pets are blocked');
insert into rides values ('dog', pg_temp.book('00000000-0000-0000-0000-0000000253c1', 'Ride 253',
  '{"pets": [{"type": "Dog", "size": "L"}], "option_names": {"pet": "Pet with me"}}'));
insert into rides values ('plain', pg_temp.book('00000000-0000-0000-0000-0000000253c2', 'Premium 253'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000253c1');
select pg_temp.refused_with($q$select public.schedule_ride('{"service": "Premium 253", "pickup_lat": 25.0, "pickup_lng": 115.0,
  "drop_lat": 25.1, "drop_lng": 115.1, "fare": 30, "pets": [{"type": "Cat"}], "option_names": {"pet": "Pet with me"}}'::jsonb,
  now() + interval '3 hours')$q$, 'RIDE_OPTION_NOT_OFFERED', 'a booking for later, checked when it is booked');
reset role;

-- ---- 5. The extras a driver takes: their own row ------------------------------------------------
select pg_temp.check(public.ride_extra_keys('[{"type": "Dog"}, {"type": " dog "}, {"type": "Cat"}]',
                                            '{"items": [{"id": "wheelchair", "name": "W"}, {"id": "guide-dog", "name": "G"}]}',
                                            '{"child-seat": "Child safety seat"}', 5)
                     = array['assist:guide-dog', 'assist:wheelchair', 'child-seat', 'more-passengers', 'pet:cat', 'pet:dog'],
  'a request''s extras: each pet type, each help item (the guide dog too), a child seat, more passengers');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d2');
insert into public.driver_ride_extras (driver_id, off) values
  ('00000000-0000-0000-0000-0000000253d2', array['Pet:Dog ', 'assist:guide-dog', 'pet:dog']);
select pg_temp.check((select off from public.driver_ride_extras where driver_id = '00000000-0000-0000-0000-0000000253d2')
                     = array['pet:dog'], 'kept in lower case, once; the guide dog is always taken (0263)');
select pg_temp.refused($q$insert into public.driver_ride_extras (driver_id, off) values ('00000000-0000-0000-0000-0000000253d1', array['pet:cat'])$q$,
  'a driver writing another''s');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d1');
select pg_temp.check((select count(*) from public.driver_ride_extras) = 0, 'a driver reads only their own');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253a1');
select pg_temp.check((select count(*) from public.driver_ride_extras
                       where driver_id = '00000000-0000-0000-0000-0000000253d2') = 1, 'admins read them');

-- ---- 6. Who reads the open request --------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'dog')) = 1, 'a driver taking dogs sees the dog ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'dog')) = 0, 'the driver who turned dogs off doesn''t');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'plain')) = 1, 'but sees a ride without extras');
select pg_temp.check(public.ride_extras_hidden_count(now() - interval '1 hour') = 1, 'the feed''s "1 request not shown"');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d1');
select pg_temp.check(public.ride_extras_hidden_count(now() - interval '1 hour') = 0, 'none hidden for the other driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253c1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'dog')) = 1, 'the rider sees their own');
reset role;

-- ---- 7. Who is pushed ----------------------------------------------------------------------------
-- Booked after the driver turned dogs off.
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'dog');
set local role authenticated;
insert into rides values ('dog2', pg_temp.book('00000000-0000-0000-0000-0000000253c1', 'Ride 253',
  '{"pets": [{"type": "Dog"}], "option_names": {"pet": "Pet with me"}}'));
reset role;
select pg_temp.check(exists (select 1 from public.ride_request_pushes
                              where request_id = (select id from rides where k = 'dog2')
                                and profile_id = '00000000-0000-0000-0000-0000000253d1'),
  'the dog ride is pushed to the driver taking dogs');
select pg_temp.check(not exists (select 1 from public.ride_request_pushes
                                  where request_id = (select id from rides where k = 'dog2')
                                    and profile_id = '00000000-0000-0000-0000-0000000253d2'),
  'never to the driver who turned dogs off');
select pg_temp.check(exists (select 1 from public.ride_request_pushes
                              where request_id = (select id from rides where k = 'plain')
                                and profile_id = '00000000-0000-0000-0000-0000000253d2'),
  'a ride without extras is pushed to both');
update public.ride_requests set status = 'cancelled' where id in (select id from rides);

-- ---- 8. My Ride favourites -------------------------------------------------------------------------
insert into public.favourite_drivers (rider_id, driver_id) values
  ('00000000-0000-0000-0000-0000000253c2', '00000000-0000-0000-0000-0000000253d1'),
  ('00000000-0000-0000-0000-0000000253c2', '00000000-0000-0000-0000-0000000253d2');
set local role authenticated;
insert into rides values ('fav', pg_temp.book('00000000-0000-0000-0000-0000000253c2', 'Ride 253',
  '{"pets": [{"type": "Dog"}], "option_names": {"pet": "Pet with me"}}',
  array['00000000-0000-0000-0000-0000000253d1', '00000000-0000-0000-0000-0000000253d2']::uuid[]));
reset role;
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000253d1']::uuid[]
                        from public.ride_requests where id = (select id from rides where k = 'fav')),
  'My Ride: the favourite who turned dogs off is left out');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'fav');

-- ---- 9. Scheduled rides -------------------------------------------------------------------------------
insert into public.scheduled_rides (id, rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng, fare)
values ('00000000-0000-0000-0000-0000000253f1', '00000000-0000-0000-0000-0000000253c1', now() + interval '2 hours',
        '{"service": "Ride 253", "pets": [{"type": "Dog"}], "option_names": {"pet": "Pet with me"}}',
        'Ride 253', 25.0, 115.0, 25.1, 115.1, 30);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d2');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_open() where id = '00000000-0000-0000-0000-0000000253f1'),
  'the driver who turned dogs off doesn''t see the dog booking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d1');
select pg_temp.check(exists (select 1 from public.scheduled_rides_open() where id = '00000000-0000-0000-0000-0000000253f1'),
  'the other driver does');

-- ---- 10. Turned back on --------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000253d2');
update public.driver_ride_extras set off = '{}' where driver_id = '00000000-0000-0000-0000-0000000253d2';
select pg_temp.check(exists (select 1 from public.scheduled_rides_open() where id = '00000000-0000-0000-0000-0000000253f1'),
  'dogs back on: the booking shows again');
reset role;

rollback;
select 'ride_options_regions_0253: all passed';
