-- ============================================================================
-- Regression test for migration 0267: Freight.
--   * a Vehicle Service is freight when its Service types name Freight; one
--     may be flagged closed body;
--   * the cargo (description, photo in the rider's folder) is checked and
--     stays as booked; a booking for later keeps it;
--   * the four freight options are Ride Options by place: offered / blocked
--     per place (0253's check), freight only, one helper choice, a closed
--     body only on a size flagged so, and their fixed charges as the pickup
--     sets them;
--   * an open freight request is read by, and pushed to, drivers with a
--     freight vehicle that may take it (whatever the Service order switch),
--     its rider and admins, never other drivers; a ride stays everybody's;
--     My Ride favourites without a freight vehicle are left out;
--   * the cargo photos: the rider's folder, the driver who took the ride and
--     admins.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/freight_0267.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's: off, as freight ignores it.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000267a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000267c1'),  -- riders
  ('00000000-0000-0000-0000-0000000267c2'),
  ('00000000-0000-0000-0000-0000000267d1'),  -- driver with a van (freight)
  ('00000000-0000-0000-0000-0000000267d2'),  -- driver with a car
  ('00000000-0000-0000-0000-0000000267d3')   -- driver with a 3-tonne lorry (freight, closed body)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000267%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000267a1', '*', 'edit')
on conflict do nothing;

insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000026751', 'vehicle-services',
   '{"name": "Van 267", "serviceTypes": ["Freight"], "maxLoadKg": 500, "loadLengthM": 2, "loadWidthM": 1.4, "loadHeightM": 1.3}', 9101),
  ('00000000-0000-0000-0000-000000026752', 'vehicle-services',
   '{"name": "Lorry 267", "serviceTypes": [" freight "], "maxLoadKg": 3000, "closedBody": true}', 9102),
  ('00000000-0000-0000-0000-000000026753', 'vehicle-services', '{"name": "Car 267", "serviceTypes": ["Car"]}', 9103);
insert into public.vehicle_service_order (service_id, rank) values
  ('00000000-0000-0000-0000-000000026751', 901),
  ('00000000-0000-0000-0000-000000026752', 902)
on conflict do nothing;

insert into public.partners (auth_user_id, name, phone, status)
select u.id, 'Driver ' || right(u.id::text, 2), '6013100' || right(u.id::text, 4), 'approved'
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000267d%';
insert into public.vehicle (id, auth_user_id, plate, make, model, color, status, service_id, service_approved_id) values
  ('00000000-0000-0000-0000-0000000267f1', '00000000-0000-0000-0000-0000000267d1', 'TST 2671', 'Testmake', 'Van',
   'White', 'approved', '00000000-0000-0000-0000-000000026751', '00000000-0000-0000-0000-000000026751'),
  ('00000000-0000-0000-0000-0000000267f2', '00000000-0000-0000-0000-0000000267d2', 'TST 2672', 'Testmake', 'Car',
   'Blue', 'approved', '00000000-0000-0000-0000-000000026753', '00000000-0000-0000-0000-000000026753'),
  ('00000000-0000-0000-0000-0000000267f3', '00000000-0000-0000-0000-0000000267d3', 'TST 2673', 'Testmake', 'Lorry',
   'Red', 'approved', '00000000-0000-0000-0000-000000026752', '00000000-0000-0000-0000-000000026752');
update public.vehicle set service_approved_id = service_id where id::text like '00000000-0000-0000-0000-0000000267f%';
insert into public.driver_presence (profile_id, online, lat, lng)
select id, true, 26.0, 116.0 from auth.users where id::text like '00000000-0000-0000-0000-0000000267d%'
on conflict (profile_id) do update set online = true, lat = 26.0, lng = 116.0, updated_at = now();

insert into public.favourite_drivers (rider_id, driver_id) values
  ('00000000-0000-0000-0000-0000000267c2', '00000000-0000-0000-0000-0000000267d2'),
  ('00000000-0000-0000-0000-0000000267c2', '00000000-0000-0000-0000-0000000267d3');

-- The pickup's country, with charges set there.
insert into public.countries (name, values, geofence) values
  ('Freightland 267', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":28,"south":24,"east":118,"west":114}}'));
insert into public.ride_option_places (level, country, charges, offered) values
  ('country', 'Freightland 267',
   '{"helper-1": {"kind": "fixed", "value": 30}, "helper-2": {"kind": "fixed", "value": 60},
     "ride-along": {"kind": "fixed", "value": 10}}',
   '{"helper-2": true}');

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
-- A booking at the pickup (26, 116) by [p_rider], with [p_extra]'s option
-- names, charges, cargo and favourites.
create or replace function pg_temp.book(p_rider uuid, p_service text, p_extra jsonb default '{}')
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, offer_me, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, option_names, option_charges, cargo_description,
                                    cargo_photo_path, target_driver_ids, prohibited_ack, declared_value,
                                    recipient_name, recipient_phone)
  values (v, p_rider, 'open', p_service, coalesce((p_extra->>'fare')::numeric, 150),
          coalesce((p_extra->>'fare')::numeric, 150), true, 26.0, 116.0, 26.1, 116.1,
          p_extra->'option_names', p_extra->'option_charges', p_extra->>'cargo', p_extra->>'photo',
          case when p_extra ? 'targets' then array(select jsonb_array_elements_text(p_extra->'targets'))::uuid[] end,
          coalesce((p_extra->>'ack')::boolean, true), coalesce((p_extra->>'declared')::numeric, 100),
          p_extra->>'recipient', p_extra->>'recipient_phone');
  return v;
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text), pg_temp.book(uuid, text, jsonb), pg_temp.sees(uuid) to authenticated;

-- ---- 1. Freight vehicle services ---------------------------------------------------------------------
select pg_temp.check(public.vehicle_service_values_freight('{"serviceTypes": ["Car", "FREIGHT"]}')
                     and not public.vehicle_service_values_freight('{"serviceTypes": "Freight"}')
                     and not public.vehicle_service_values_freight('{}'), 'Freight among the Service types');
select pg_temp.check(public.vehicle_service_is_freight('van 267') and public.vehicle_service_is_freight('Lorry 267')
                     and not public.vehicle_service_is_freight('Car 267') and not public.vehicle_service_is_freight(null),
  'which services are freight');
select pg_temp.check(public.vehicle_service_closed_body('Lorry 267') and not public.vehicle_service_closed_body('Van 267'),
  'the closed body flag');
select pg_temp.check(public.freight_service_keys() @> array['van267', 'lorry267']
                     and not ('car267' = any (public.freight_service_keys())), 'the freight keys');
select pg_temp.check(public.driver_takes_freight('00000000-0000-0000-0000-0000000267d1', 'Van 267')
                     and not public.driver_takes_freight('00000000-0000-0000-0000-0000000267d1', 'Lorry 267')
                     and public.driver_takes_freight('00000000-0000-0000-0000-0000000267d3', 'Van 267')
                     and not public.driver_takes_freight('00000000-0000-0000-0000-0000000267d2', 'Van 267')
                     and public.driver_takes_freight('00000000-0000-0000-0000-0000000267d2', 'Car 267'),
  'a van takes vans, a larger lorry takes vans, a car takes no freight; anyone takes a ride');
select pg_temp.check(not has_function_privilege('authenticated', 'public.driver_takes_freight(uuid, text)', 'execute'),
  'driver_takes_freight is the server''s');

-- ---- 2. Options by place -----------------------------------------------------------------------------
select pg_temp.check(public.ride_option_ids() @> array['helper-1', 'helper-2', 'closed-body', 'ride-along'],
  'the freight options are Ride Options');
select pg_temp.check(public.ride_option_kinds(null, null, '{"helper-2": "2 helpers", "child-seat": "Seat"}', 1)
                     = array['child-seat', 'helper-2'], 'a booking''s options, freight ones last');
select pg_temp.check(public.ride_option_name('ride-along', null) = 'I''ll ride along'
                     and public.ride_option_name('helper-1', '{"helper-1": "One mover"}') = 'One mover', 'their names');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267a1');
insert into public.ride_option_places (level, country, offered, blocked) values
  ('country', 'Elsewhere 267', '{"closed-body": false}', '{"helper-1": ["00000000-0000-0000-0000-000000026751"]}');
select pg_temp.refused_with($q$insert into public.ride_option_places (level, country, offered) values ('country', 'X 267', '{"helpers": false}')$q$,
  'ride_option_places_valid', 'an option id that isn''t one');
reset role;

-- ---- 3. Bookings ---------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267')$q$,
  'FREIGHT_CARGO_REQUIRED', 'freight without a description of the cargo');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Car 267',
  '{"option_names": {"ride-along": "I''ll ride along"}, "option_charges": [{"kind": "ride-along", "name": "I''ll ride along", "amount": 10}]}')$q$,
  'FREIGHT_OPTION_NOT_FREIGHT', 'a freight option on a ride');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Boxes", "option_names": {"helper-1": "1 helper", "helper-2": "2 helpers"},
    "option_charges": [{"kind": "helper-1", "name": "1 helper", "amount": 30}, {"kind": "helper-2", "name": "2 helpers", "amount": 60}]}')$q$,
  'FREIGHT_HELPERS_ONE', '1 helper and 2 helpers');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Boxes", "option_names": {"closed-body": "Closed body"}}')$q$,
  'RIDE_OPTION_NOT_OFFERED', 'a closed body on a van that isn''t one');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Boxes", "option_names": {"helper-1": "1 helper"}, "option_charges": [{"kind": "helper-1", "name": "1 helper", "amount": 20}]}')$q$,
  'RIDE_OPTION_CHARGE_CHANGED', 'a helper charged other than the pickup''s amount');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Boxes", "option_names": {"helper-1": "1 helper"}}')$q$,
  'RIDE_OPTION_CHARGE_CHANGED', 'a helper without its charge');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Boxes", "option_charges": [{"kind": "ride-along", "name": "I''ll ride along", "amount": 10}]}')$q$,
  'RIDE_OPTION_CHARGE_CHANGED', 'a charge for an option not booked');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Boxes", "photo": "00000000-0000-0000-0000-0000000267c2/cargo-x.jpg"}')$q$,
  'ride_requests_cargo_valid', 'a photo from somebody else''s folder');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  jsonb_build_object('cargo', repeat('x', 501)))$q$, 'ride_requests_cargo_valid', 'a description over 500 characters');
-- As the pickup sets them: 1 helper 30, closed body free (nothing set).
insert into rides values ('van', pg_temp.book('00000000-0000-0000-0000-0000000267c1', 'Van 267',
  '{"cargo": "Single-door fridge and 6 boxes", "photo": "00000000-0000-0000-0000-0000000267c1/cargo-a.jpg",
    "fare": 180, "option_names": {"helper-1": "1 helper", "ride-along": "I''ll ride along"},
    "option_charges": [{"kind": "helper-1", "name": "1 helper", "amount": 30},
                       {"kind": "ride-along", "name": "I''ll ride along", "amount": 10}]}'));
insert into rides values ('lorry', pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Lorry 267',
  '{"cargo": "House moving", "option_names": {"closed-body": "Closed body"},
    "targets": ["00000000-0000-0000-0000-0000000267d2", "00000000-0000-0000-0000-0000000267d3"]}'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'van')) = 1, 'the rider sees their freight request');
-- The cargo stays as booked.
select pg_temp.refused_with($q$update public.ride_requests set cargo_description = 'Other' where id = (select id from rides where k = 'van')$q$,
  'RIDE_CARGO_FIXED', 'the rider changing the cargo');
reset role;
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000267d3']::uuid[]
                        from public.ride_requests where id = (select id from rides where k = 'lorry')),
  'My Ride: the favourite without a freight vehicle is left out');

-- ---- 4. Who reads an open freight request --------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'van')) = 1, 'a van driver sees the van request');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'lorry')) = 0, 'not the lorry one');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d3');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'van')) = 1
                     and pg_temp.sees((select id from rides where k = 'lorry')) = 1, 'the lorry driver sees both');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'van')) = 0, 'a car driver doesn''t');
select pg_temp.refused($q$update public.ride_requests set offered_fare = 170, partner_id = '00000000-0000-0000-0000-0000000267d2'
  where id = (select id from rides where k = 'van')$q$, 'a car driver bidding on it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267a1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'van')) = 1, 'admins see it');
reset role;
select pg_temp.check(exists (select 1 from public.ride_request_pushes where request_id = (select id from rides where k = 'van')
                               and profile_id = '00000000-0000-0000-0000-0000000267d1'), 'the van driver is pushed');
select pg_temp.check(not exists (select 1 from public.ride_request_pushes where request_id = (select id from rides where k = 'van')
                                   and profile_id = '00000000-0000-0000-0000-0000000267d2'), 'the car driver is not');
-- A ride stays everybody's.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'lorry');
insert into rides values ('car', pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Car 267'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'car')) = 1, 'a car driver sees a ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'car')) = 1, 'and so does a van driver');
reset role;

-- ---- 5. The cargo photo ----------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check(not public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267c1/cargo-a.jpg'),
  'a driver bidding doesn''t read the photo yet');
update public.ride_requests set offered_fare = 190, partner_id = '00000000-0000-0000-0000-0000000267d1'
 where id = (select id from rides where k = 'van');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c1');
update public.ride_requests set status = 'accepted', fare = 190, ride_fare = 190
 where id = (select id from rides where k = 'van') and partner_id = '00000000-0000-0000-0000-0000000267d1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check(public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267c1/cargo-a.jpg'),
  'the driver who took it does: ' || (select status from public.ride_requests where id = (select id from rides where k = 'van')));
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d3');
select pg_temp.check(not public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267c1/cargo-a.jpg'),
  'another driver doesn''t');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267a1');
select pg_temp.check(public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267c1/cargo-a.jpg'), 'admins do');
reset role;
select pg_temp.check(exists (select 1 from storage.buckets where id = 'ride-cargo' and not public), 'the bucket is private');
select pg_temp.check(exists (select 1 from public.admin_table_pages where target = 'storage:ride-cargo' and page = 'admin-rides'),
  'Admin > Rides may remove the photos');

-- ---- 6. A booking for later ---------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);
select public.set_scheduled_rides_config('{"enabled": true, "mode": "advance"}');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
select pg_temp.refused_with($q$select public.schedule_ride('{"service": "Van 267", "pickup_lat": 26.0, "pickup_lng": 116.0,
  "drop_lat": 26.1, "drop_lng": 116.1, "fare": 150, "prohibited_ack": true, "declared_value": 50}'::jsonb,
  now() + interval '3 hours')$q$,
  'FREIGHT_CARGO_REQUIRED', 'for later: freight without a description');
select pg_temp.refused_with($q$select public.schedule_ride('{"service": "Van 267", "pickup_lat": 26.0, "pickup_lng": 116.0,
  "drop_lat": 26.1, "drop_lng": 116.1, "fare": 150, "cargo_description": "Boxes",
  "prohibited_ack": true, "declared_value": 50,
  "option_names": {"helper-2": "2 helpers"}}'::jsonb, now() + interval '3 hours')$q$,
  'RIDE_OPTION_CHARGE_CHANGED', 'for later: 2 helpers without their charge');
select public.schedule_ride('{"service": "Van 267", "pickup_lat": 26.0, "pickup_lng": 116.0,
  "drop_lat": 26.1, "drop_lng": 116.1, "fare": 210, "cargo_description": "Sofa",
  "prohibited_ack": true, "declared_value": 300, "recipient_name": "Mei", "recipient_phone": "+60123456789",
  "cargo_photo_path": "00000000-0000-0000-0000-0000000267c2/cargo-b.jpg",
  "option_names": {"helper-2": "2 helpers"},
  "option_charges": [{"kind": "helper-2", "name": "2 helpers", "amount": 60}]}'::jsonb, now() + interval '3 hours');
select pg_temp.check((select request->>'cargo_description' = 'Sofa'
                             and request->>'cargo_photo_path' = '00000000-0000-0000-0000-0000000267c2/cargo-b.jpg'
                             and request->>'recipient_phone' = '+60123456789' and request->>'declared_value' = '300'
                        from public.scheduled_rides where rider_id = '00000000-0000-0000-0000-0000000267c2'
                       order by created_at desc limit 1), 'the booking keeps the cargo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d2');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_open() where service = 'Van 267'),
  'a car driver''s list of rides ahead leaves it out');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check(exists (select 1 from public.scheduled_rides_open() where service = 'Van 267'),
  'a van driver''s has it');
reset role;

-- ---- 7. Freight settings --------------------------------------------------------------------------------
select pg_temp.check((public.freight_config()->>'cancelApproveMinutes')::int = 5
                     and public.freight_config()->'recipientChannels' = '["sms"]'::jsonb
                     and jsonb_array_length(public.freight_config()->'prohibitedItems') > 0, 'the defaults');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c1');
select pg_temp.refused_with($q$select public.set_freight_config('{"cancelApproveMinutes": 9}')$q$, 'NOT_ALLOWED',
  'a rider changing the Freight settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267a1');
select pg_temp.check((public.set_freight_config('{"cancelApproveMinutes": 500, "recipientChannels": ["whatsapp", "fax", "sms"],
                       "prohibitedItems": ["Explosives", " ", "Live animals"]}')
                      = '{"cancelApproveMinutes": 60, "recipientChannels": ["sms", "whatsapp"],
                          "prohibitedItems": ["Explosives", "Live animals"]}'::jsonb), 'kept within bounds');
select public.set_freight_config('{"cancelApproveMinutes": 5, "recipientChannels": ["sms", "whatsapp"], "prohibitedItems": ["Explosives"]}');
-- Waiting, cancel fee and the cap in the pickup's country.
update public.ride_option_places
   set charges = charges || '{"freight-wait-free-min": {"kind": "fixed", "value": 20},
                              "freight-wait-per-min": {"kind": "fixed", "value": 2},
                              "freight-cancel-arrived": {"kind": "fixed", "value": 15},
                              "freight-declared-cap": {"kind": "fixed", "value": 50000}}'
 where level = 'country' and country = 'Freightland 267';
select pg_temp.refused_with($q$update public.ride_option_places set charges = '{"freight-wait-per-min": {"value": 20000}}'
  where level = 'country' and country = 'Freightland 267'$q$, 'ride_option_places_valid', 'a fee over 10,000');
reset role;
select pg_temp.check(public.freight_place_value('{}', 'freight-wait-free-min') = 20
                     and public.freight_place_value('{}', 'freight-declared-cap') = 500
                     and public.freight_place_value('{}', 'freight-cancel-arrived') = 0, 'nothing set: 20 free minutes, a cap of 500');

-- ---- 8. Prohibited items and the declared value --------------------------------------------------------
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'car');
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Van 267',
  '{"cargo": "Boxes", "ack": false}')$q$, 'FREIGHT_PROHIBITED_ACK', 'without confirming the prohibited items');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Van 267',
  '{"cargo": "Boxes", "declared": 60000}')$q$, 'FREIGHT_DECLARED_VALUE_CAP', 'over the place''s cap');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Van 267',
  '{"cargo": "Boxes", "declared": -1}')$q$, 'FREIGHT_DECLARED_VALUE', 'a negative value');
reset role;

-- ---- 9. Proof of delivery, waiting and the recipient's link ---------------------------------------------
set local role authenticated;
insert into rides values ('trip', pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Van 267',
  '{"cargo": "Washing machine", "declared": 900, "recipient": "Mei", "recipient_phone": "+60123456789"}'));
-- Open: a driver bidding reads the request, not the recipient or the value.
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check((select recipient_phone is null and recipient_name is null and declared_value is null
                             and cargo_description = 'Washing machine'
                        from public.ride_requests where id = (select id from rides where k = 'trip')),
  'a bidding driver can''t read the recipient''s phone or the declared value');
select pg_temp.check(not exists (select 1 from public.ride_request_private
                                  where request_id = (select id from rides where k = 'trip')),
  'nor what is kept aside');
update public.ride_requests set offered_fare = 150, partner_id = '00000000-0000-0000-0000-0000000267d1'
 where id = (select id from rides where k = 'trip');
select pg_temp.check((select recipient_phone is null from public.ride_requests where id = (select id from rides where k = 'trip')),
  'not even once their offer stands on it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
select pg_temp.check((select recipient_phone = '+60123456789' and recipient_name = 'Mei' and declared_value = 900
                        from public.ride_request_private where request_id = (select id from rides where k = 'trip')),
  'the sender reads them aside');
update public.ride_requests set status = 'accepted' where id = (select id from rides where k = 'trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check((select recipient_phone = '+60123456789' and recipient_name = 'Mei' and declared_value = 900
                        from public.ride_requests where id = (select id from rides where k = 'trip')),
  'the assigned driver reads the recipient and the value');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d3');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'trip')) = 0, 'another driver no longer sees the request');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267a1');
select pg_temp.check((select recipient_phone = '+60123456789' from public.ride_requests
                       where id = (select id from rides where k = 'trip')), 'admins read it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'trip');
reset role;
-- The driver waited 30 minutes.
update public.ride_requests set arrived_at = now() - interval '30 minutes 10 seconds'
 where id = (select id from rides where k = 'trip');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.refused_with($q$update public.ride_requests set status = 'on_trip' where id = (select id from rides where k = 'trip')$q$,
  'FREIGHT_PICKUP_PROOF', 'starting without the pickup photo');
select pg_temp.refused_with($q$update public.ride_requests set pickup_proof_path = '00000000-0000-0000-0000-0000000267c2/proof.jpg'
  where id = (select id from rides where k = 'trip')$q$, 'ride_requests_freight_proof_valid', 'a photo from the rider''s folder');
update public.ride_requests set pickup_proof_path = '00000000-0000-0000-0000-0000000267d1/proof-pickup.jpg'
 where id = (select id from rides where k = 'trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
select pg_temp.refused_with($q$update public.ride_requests set dropoff_proof_path = null, pickup_proof_path = null
  where id = (select id from rides where k = 'trip')$q$, 'FREIGHT_PROOF_NOT_YOURS', 'the sender changing the driver''s photo');
select pg_temp.check(public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267d1/proof-pickup.jpg'),
  'the sender reads the driver''s photo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d3');
select pg_temp.check(not public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267d1/proof-pickup.jpg'),
  'another driver doesn''t');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
update public.ride_requests set status = 'on_trip' where id = (select id from rides where k = 'trip');
reset role;
select pg_temp.check((select freight_waiting_minutes = 30 and freight_waiting_fee = 20 and fare = 170 and ride_fare = 170
                        from public.ride_requests where id = (select id from rides where k = 'trip')),
  'started: 10 minutes past the free 20, at 2 a minute, added to the fare: '
  || (select format('%s min, fee %s, fare %s', freight_waiting_minutes, freight_waiting_fee, fare)
        from public.ride_requests where id = (select id from rides where k = 'trip')));
select pg_temp.check((select count(*) = 2 and bool_and(to_phone = '+60123456789' and status = 'queued')
                        from public.freight_recipient_notices where ride_id = (select id from rides where k = 'trip')),
  'the recipient''s link waits for SMS and WhatsApp');
select pg_temp.check((select share_token is not null from public.ride_request_private
                       where request_id = (select id from rides where k = 'trip')),
  'with the ride''s share link, kept aside');
select pg_temp.check((select count(*) = 2 and bool_and(share_token is not null)
                        from public.freight_notices_claim((select id from rides where k = 'trip'))),
  'the Edge Function claims them, with the link');
select pg_temp.check(not exists (select 1 from public.freight_notices_claim((select id from rides where k = 'trip'))),
  'once');
select pg_temp.check(not has_function_privilege('authenticated', 'public.freight_notices_kick()', 'execute')
                     and not has_function_privilege('authenticated', 'public.freight_notices_claim(uuid)', 'execute'),
  'the sending is the server''s');
-- The sender signs; the driver can't finish without the drop-off photo.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
update public.ride_requests set delivery_signature_path = '00000000-0000-0000-0000-0000000267c2/signature-1.png'
 where id = (select id from rides where k = 'trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d1');
select pg_temp.check(public.ride_cargo_photo_readable('00000000-0000-0000-0000-0000000267c2/signature-1.png'),
  'the driver reads the signature');
select pg_temp.refused_with($q$update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'trip')$q$,
  'FREIGHT_DROPOFF_PROOF', 'finishing without the drop-off photo');
-- After pickup the driver can only ask the sender to cancel.
select pg_temp.refused_with($q$update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'trip')$q$,
  'RIDE_DRIVER_CANCEL_AFTER_PICKUP', 'the driver cancelling alone after pickup');
update public.ride_requests set cancel_requested_at = now(), cancel_requested_by = 'partner', cancel_reason = 'Flat tyre'
 where id = (select id from rides where k = 'trip');
reset role;
select public.ride_cancel_requests_lapse();
select pg_temp.check((select status = 'on_trip' from public.ride_requests where id = (select id from rides where k = 'trip')),
  'not yet: the sender has 5 minutes');
update public.ride_requests set cancel_requested_at = now() - interval '6 minutes' where id = (select id from rides where k = 'trip');
select public.ride_cancel_requests_lapse();
select pg_temp.check((select status = 'cancelled' and freight_cancel_fee is null
                        from public.ride_requests where id = (select id from rides where k = 'trip')),
  'unanswered, approved; no fee for the sender');

-- ---- 10. The sender cancels after the driver arrived ------------------------------------------------------
set local role authenticated;
insert into rides values ('late', pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Van 267', '{"cargo": "Desk"}'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d3');
update public.ride_requests set offered_fare = 150, partner_id = '00000000-0000-0000-0000-0000000267d3'
 where id = (select id from rides where k = 'late');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
update public.ride_requests set status = 'accepted' where id = (select id from rides where k = 'late');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267d3');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'late');
select pg_temp.as_user('00000000-0000-0000-0000-0000000267c2');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'late');
select pg_temp.check((select freight_cancel_fee = 15 and freight_cancel_fee_status = 'due'
                        from public.ride_requests where id = (select id from rides where k = 'late')), 'the cancel fee is owed');
select pg_temp.check(public.my_owed_fees() = 15, 'and counted as owed');
insert into rides values ('next', pg_temp.book('00000000-0000-0000-0000-0000000267c2', 'Car 267'));
reset role;
select pg_temp.check((select charges @> '[{"name": "Freight cancellation fee (earlier request)", "value": 15}]'::jsonb
                        from public.ride_requests where id = (select id from rides where k = 'next')),
  'billed on the next request');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'next');
select pg_temp.check((select freight_cancel_fee_status = 'due' from public.ride_requests where id = (select id from rides where k = 'late')),
  'that one never ran: owed again');

-- ---- 11. The goods-vehicle permit ---------------------------------------------------------------------------
update public.settings_entries set values = values || '{"goodsPermitKey": "goods-267"}'
 where id = '00000000-0000-0000-0000-000000026751';
insert into public.permit_types (id, country, key, name, applies_to, active) values
  ('00000000-0000-0000-0000-0000000267e1', 'Freightland 267', 'goods-267', 'Goods vehicle 267', 'vehicle', true);
update public.vehicle set service_countries = '{Freightland 267}' where id = '00000000-0000-0000-0000-0000000267f1';
select pg_temp.check(not public.driver_takes_freight('00000000-0000-0000-0000-0000000267d1', 'Van 267'),
  'a van without the goods-vehicle permit takes no freight');
insert into public.vehicle_documents (vehicle_id, permit_type_id, status, doc_id, doc_name)
values ('00000000-0000-0000-0000-0000000267f1', '00000000-0000-0000-0000-0000000267e1', 'Approved', 'goods-267', 'Goods vehicle 267');
select pg_temp.check(public.driver_takes_freight('00000000-0000-0000-0000-0000000267d1', 'Van 267'),
  'with it approved, it does');
select pg_temp.check(public.driver_takes_freight('00000000-0000-0000-0000-0000000267d3', 'Van 267'),
  'the lorry asks for none');

select 'freight_0267: all passed';
rollback;
