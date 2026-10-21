-- ============================================================================
-- Regression test for migration 0262: a driver who is also an admin gets
-- the server's card (plate, car, name, rating, trips) on a bid or a take.
--   * the driver has taken a vehicle; their partner profile has no plate or
--     car, and their app sends a stale plate, an empty car, its own name and
--     a 0 rating, exactly as ride_repository submitOffer / accept do;
--   * a bid on an airport pickup opened to nearby drivers, and a plain one;
--   * an accept at the rider's fare;
--   * the card stays as stamped through the driver's later writes;
--   * the rider reads the plate and car;
--   * an admin editing another driver's card, and a plain driver, are as before.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/offer_card_vehicle_0262.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test; here nobody is held up by one.
update public.permit_country_settings set enforce = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000262a1'),  -- rider of the airport pickup
  ('00000000-0000-0000-0000-0000000262a2'),  -- rider of a plain request
  ('00000000-0000-0000-0000-0000000262a3'),  -- rider of a request taken at their fare
  ('00000000-0000-0000-0000-0000000262a4'),  -- rider of a plain driver's bid
  ('00000000-0000-0000-0000-0000000262b1'),  -- driver who is also an admin
  ('00000000-0000-0000-0000-0000000262b2'),  -- plain driver
  ('00000000-0000-0000-0000-0000000262c1')   -- admin who does not drive
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000262%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000262b1', 'admin-settings-airport-areas', 'read'),
  ('00000000-0000-0000-0000-0000000262c1', '*', 'edit')
on conflict do nothing;

-- No plate or car on either driver's profile: the card has the vehicle only.
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries,
                             plate, vehicle, rating, total_rides) values
  ('00000000-0000-0000-0000-0000000262e1', '00000000-0000-0000-0000-0000000262b1', 'Admin Driver', '+60100002621',
   'approved', '{Teksi,eHailing,Delivery}', '{Malaysia}', '', '', 4.80, 7),
  ('00000000-0000-0000-0000-0000000262e2', '00000000-0000-0000-0000-0000000262b2', 'Plain Driver', '+60100002622',
   'approved', '{eHailing}', '{Malaysia}', '', '', 4.50, 3);

insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status,
                            service_countries, partner_types, energy_type, joined_at) values
  ('00000000-0000-0000-0000-0000000262f1', '00000000-0000-0000-0000-0000000262b1', '00000000-0000-0000-0000-0000000262e1',
   'TST 2621', 'Testmake', 'Alpha', 'Blue', 'approved', '{Malaysia}', '{eHailing}', 'Petrol', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000262f2', '00000000-0000-0000-0000-0000000262b2', '00000000-0000-0000-0000-0000000262e2',
   'TST 2622', 'Testmake', 'Beta', 'Grey', 'approved', '{Malaysia}', '{eHailing}', 'Petrol', now() - interval '3 days');

-- Both have taken their vehicle well before bidding.
insert into public.vehicle_active_session (vehicle_id, user_id, partner_id, started_at) values
  ('00000000-0000-0000-0000-0000000262f1', '00000000-0000-0000-0000-0000000262b1',
   '00000000-0000-0000-0000-0000000262e1', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000262f2', '00000000-0000-0000-0000-0000000262b2',
   '00000000-0000-0000-0000-0000000262e2', now() - interval '1 hour');

insert into public.driver_presence (profile_id, online, lat, lng) values
  ('00000000-0000-0000-0000-0000000262b1', true, 12.0, 112.0),
  ('00000000-0000-0000-0000-0000000262b2', true, 12.0, 112.0)
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng;

-- An airport whose pickups go to its queue first, then to nearby drivers.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000262d0', jsonb_build_object('name', 'Test Airport 262', 'code', 'TQX',
    'boundary', '{"coords":[{"latitude":12.1,"longitude":111.9},{"latitude":12.1,"longitude":112.1},{"latitude":11.9,"longitude":112.1},{"latitude":11.9,"longitude":111.9}],"bbox":{"north":12.1,"south":11.9,"east":112.1,"west":111.9}}'));
insert into public.airport_settings (airport_id) values ('00000000-0000-0000-0000-0000000262d0')
on conflict (airport_id) do nothing;
update public.airport_settings
   set restrict_pickups = true, pickup_from = '{queue}', empty_action = 'nearby', nearby_after_min = 5,
       pick_door_required = false, drop_door_required = false
 where airport_id = '00000000-0000-0000-0000-0000000262d0';

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
-- The card on a ride: name | plate | car | rating | trips.
create or replace function pg_temp.card(p uuid) returns text language sql as $$
  select concat_ws(' | ', coalesce(partner_name, '-'), coalesce(nullif(partner_plate, ''), '-'),
                   coalesce(nullif(partner_vehicle, ''), '-'), coalesce(partner_rating::text, '-'),
                   coalesce(partner_trips::text, '-'))
    from public.ride_requests where id = p;
$$;
-- What the driver app sends with a bid (submitOffer) or a take (accept):
-- its own copy of the partner profile, here stale.
create or replace function pg_temp.bid(p_ride uuid, p_fare numeric) returns integer language plpgsql as $$
declare n integer;
begin
  update public.ride_requests
     set offered_fare = p_fare, partner_id = auth.uid(), partner_name = 'Name In App',
         partner_phone = '+60100000000', partner_photo = null, partner_vehicle = '', partner_plate = 'OLD 1',
         partner_rating = 0, partner_accept_lat = 12.0, partner_accept_lng = 112.0
   where id = p_ride and status = 'open';
  get diagnostics n = row_count;
  return n;
end $$;
create or replace function pg_temp.take(p_ride uuid) returns integer language plpgsql as $$
declare n integer;
begin
  update public.ride_requests
     set status = 'accepted', accepted_at = now(), partner_id = auth.uid(), partner_name = 'Name In App',
         partner_phone = '+60100000000', partner_photo = null, partner_vehicle = '', partner_plate = 'OLD 1',
         partner_rating = 0, partner_accept_lat = 12.0, partner_accept_lng = 112.0, offered_fare = null
   where id = p_ride and status = 'open';
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.card(uuid),
  pg_temp.bid(uuid, numeric), pg_temp.take(uuid) to authenticated;

-- The rides: an airport pickup (held for the queue, then opened to nearby
-- drivers when nobody was waiting), two plain requests and one more for the
-- plain driver.
insert into public.ride_requests (id, rider_id, status, service, pickup_lat, pickup_lng, drop_lat, drop_lng, fare) values
  ('00000000-0000-0000-0000-000000026201', '00000000-0000-0000-0000-0000000262a1', 'open', 'Ride', 12.0, 112.0, 12.5, 112.5, 290),
  ('00000000-0000-0000-0000-000000026202', '00000000-0000-0000-0000-0000000262a2', 'open', 'Ride', 13.0, 113.0, 13.5, 113.5, 20),
  ('00000000-0000-0000-0000-000000026203', '00000000-0000-0000-0000-0000000262a3', 'open', 'Ride', 13.0, 113.0, 13.5, 113.5, 20),
  ('00000000-0000-0000-0000-000000026204', '00000000-0000-0000-0000-0000000262a4', 'open', 'Ride', 13.0, 113.0, 13.5, 113.5, 20);
select pg_temp.check(
  (select airport_pickup_id = '00000000-0000-0000-0000-0000000262d0' and airport_hold
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026201'),
  'the airport pickup is held for the queue');
select public.airport_open_to_nearby('00000000-0000-0000-0000-000000026201');
select pg_temp.check(
  (select not airport_hold from public.ride_requests where id = '00000000-0000-0000-0000-000000026201'),
  'the airport pickup is open to nearby drivers');

-- 1. The admin driver bids on the airport pickup and a plain request ------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000262b1');
select pg_temp.check(public.caller_is_admin(), 'the driver counts as an admin');
select pg_temp.check(pg_temp.bid('00000000-0000-0000-0000-000000026201', 290) = 1, 'the airport bid went through');
select pg_temp.check(pg_temp.bid('00000000-0000-0000-0000-000000026202', 25) = 1, 'the plain bid went through');
reset role;

select pg_temp.check(
  pg_temp.card('00000000-0000-0000-0000-000000026201') = 'Admin Driver | TST 2621 | Blue Testmake Alpha | 4.80 | 7',
  'the airport bid carries the server''s card, not the app''s: ' || pg_temp.card('00000000-0000-0000-0000-000000026201'));
select pg_temp.check(
  pg_temp.card('00000000-0000-0000-0000-000000026202') = 'Admin Driver | TST 2621 | Blue Testmake Alpha | 4.80 | 7',
  'the plain bid carries the server''s card: ' || pg_temp.card('00000000-0000-0000-0000-000000026202'));
select pg_temp.check(
  (select offered_fare = 290 and status = 'open' and partner_vehicle_id = '00000000-0000-0000-0000-0000000262f1'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026201'),
  'the airport bid is an open bid on the driver''s vehicle');

-- What the rider reads on the offer card.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000262a1');
select pg_temp.check(
  (select partner_plate = 'TST 2621' and partner_vehicle = 'Blue Testmake Alpha'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026201'),
  'the rider sees the plate and car on the offer');
reset role;

-- 2. The driver's later writes leave the card as stamped ------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000262b1');
update public.ride_requests
   set partner_live_lat = 12.0, partner_live_lng = 112.0, partner_live_at = now(),
       partner_plate = '', partner_vehicle = '', partner_name = 'Name In App'
 where id = '00000000-0000-0000-0000-000000026202';
reset role;
select pg_temp.check(
  pg_temp.card('00000000-0000-0000-0000-000000026202') = 'Admin Driver | TST 2621 | Blue Testmake Alpha | 4.80 | 7',
  'the driver''s later write keeps the card: ' || pg_temp.card('00000000-0000-0000-0000-000000026202'));

-- 3. A take at the rider's fare -------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000262b1');
select pg_temp.check(pg_temp.take('00000000-0000-0000-0000-000000026203') = 1, 'the take went through');
reset role;
select pg_temp.check(
  pg_temp.card('00000000-0000-0000-0000-000000026203') = 'Admin Driver | TST 2621 | Blue Testmake Alpha | 4.80 | 7',
  'the take carries the server''s card: ' || pg_temp.card('00000000-0000-0000-0000-000000026203'));

-- 4. A plain driver, as before --------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000262b2');
select pg_temp.check(pg_temp.bid('00000000-0000-0000-0000-000000026204', 22) = 1, 'the plain driver''s bid went through');
reset role;
select pg_temp.check(
  pg_temp.card('00000000-0000-0000-0000-000000026204') = 'Plain Driver | TST 2622 | Grey Testmake Beta | 4.50 | 3',
  'a plain driver''s bid carries the server''s card: ' || pg_temp.card('00000000-0000-0000-0000-000000026204'));

-- 5. An admin who is not the driver still edits the card as they wrote it -----------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000262c1');
update public.ride_requests set partner_plate = 'ADM 1', partner_name = 'Edited By Admin'
 where id = '00000000-0000-0000-0000-000000026204';
reset role;
select pg_temp.check(
  (select partner_plate = 'ADM 1' and partner_name = 'Edited By Admin'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026204'),
  'an admin edits another driver''s card as before');

-- The guard is still the server's own.
select pg_temp.check(
  not has_function_privilege('authenticated', 'public.ride_requests_guard_sides()', 'execute'),
  'ride_requests_guard_sides is the server''s own');

select 'offer_card_vehicle_0262: all passed';

rollback;
