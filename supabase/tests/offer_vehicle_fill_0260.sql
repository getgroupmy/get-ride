-- ============================================================================
-- Regression test for migration 0260: an offer shows the driver's plate and
-- car once they have taken a vehicle.
--   * a bid made before the driver's vehicle session has no plate or car;
--   * the session starting (claim_vehicle, as the driver) fills the open bid
--     and the driver's ride under way: plate, car and partner_vehicle_id;
--   * a later write on the row fills it too, whoever writes it;
--   * a plate already on the card is never replaced;
--   * another driver's rides, and cancelled or completed ones, are untouched;
--   * the new functions are the server's own.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/offer_vehicle_fill_0260.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('authenticated', 'public.ride_requests_fill_vehicle(uuid)', 'execute')
     or has_function_privilege('anon', 'public.ride_requests_fill_vehicle(uuid)', 'execute') then
    raise exception 'FAILED: ride_requests_fill_vehicle is the server''s own';
  end if;
  if has_function_privilege('authenticated', 'public.vehicle_active_session_fill_rides()', 'execute') then
    raise exception 'FAILED: vehicle_active_session_fill_rides is the server''s own';
  end if;
  if has_function_privilege('authenticated', 'public.ride_requests_stamp_vehicle()', 'execute') then
    raise exception 'FAILED: ride_requests_stamp_vehicle is the server''s own';
  end if;
end
$$;

-- Permits are 0254's test; here nobody is held up by one.
update public.permit_country_settings set enforce = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000260a1'),  -- rider of the open request
  ('00000000-0000-0000-0000-0000000260a2'),  -- rider of a ride under way, plate already on it
  ('00000000-0000-0000-0000-0000000260a3'),  -- rider of a cancelled and a completed ride
  ('00000000-0000-0000-0000-0000000260a4'),  -- rider of another driver's bid
  ('00000000-0000-0000-0000-0000000260b1'),  -- driver who bids before taking their vehicle
  ('00000000-0000-0000-0000-0000000260b2')   -- another driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000260%'
on conflict do nothing;

-- No plate or car on either driver's profile: the card has only the vehicle.
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, plate, vehicle) values
  ('00000000-0000-0000-0000-0000000260e1', '00000000-0000-0000-0000-0000000260b1', 'Test Driver One', '+60100002601',
   'approved', '{eHailing}', '{Malaysia}', null, ''),
  ('00000000-0000-0000-0000-0000000260e2', '00000000-0000-0000-0000-0000000260b2', 'Test Driver Two', '+60100002602',
   'approved', '{eHailing}', '{Malaysia}', '', null);

insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status,
                            service_countries, partner_types, energy_type, joined_at) values
  ('00000000-0000-0000-0000-0000000260f1', '00000000-0000-0000-0000-0000000260b1', '00000000-0000-0000-0000-0000000260e1',
   'TST 2601', 'Testmake', 'Alpha', 'Silver', 'approved', '{Malaysia}', '{eHailing}', 'Petrol', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000260f2', '00000000-0000-0000-0000-0000000260b2', '00000000-0000-0000-0000-0000000260e2',
   'TST 2602', 'Testmake', 'Beta', 'Blue', 'approved', '{Malaysia}', '{eHailing}', 'Petrol', now() - interval '3 days');

insert into public.driver_presence (profile_id, online, lat, lng) values
  ('00000000-0000-0000-0000-0000000260b1', true, 3.1, 101.6),
  ('00000000-0000-0000-0000-0000000260b2', true, 3.1, 101.6)
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng;

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
-- The car on a ride: plate | car | vehicle id.
create or replace function pg_temp.car(p uuid) returns text language sql as $$
  select concat_ws(' | ', coalesce(partner_plate, '-'), coalesce(partner_vehicle, '-'),
                   coalesce(partner_vehicle_id::text, '-'))
    from public.ride_requests where id = p;
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.car(uuid) to authenticated;

-- 1. A bid before the session: a name, no car ----------------------------------------------
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare) values
  ('00000000-0000-0000-0000-000000026001', '00000000-0000-0000-0000-0000000260a1', 'open', 3.1, 101.6, 20),
  ('00000000-0000-0000-0000-000000026004', '00000000-0000-0000-0000-0000000260a4', 'open', 3.1, 101.6, 20);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000260b1');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000260b1', offered_fare = 20
 where id = '00000000-0000-0000-0000-000000026001';
select pg_temp.as_user('00000000-0000-0000-0000-0000000260b2');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000260b2', offered_fare = 20
 where id = '00000000-0000-0000-0000-000000026004';
reset role;

select pg_temp.check(
  (select partner_id = '00000000-0000-0000-0000-0000000260b1' and partner_name = 'Test Driver One'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026001'),
  'the bid went through with the driver''s name');
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026001') = '- | - | -',
  'a bid before the session has no plate, car or vehicle: ' || pg_temp.car('00000000-0000-0000-0000-000000026001'));
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026004') = '- | - | -',
  'the other driver''s bid has no car either');

-- The driver's other rides, written by the server: one under way with a plate
-- already on its card, one cancelled, one completed.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, partner_id,
                                  partner_name, partner_plate, partner_vehicle) values
  ('00000000-0000-0000-0000-000000026002', '00000000-0000-0000-0000-0000000260a2', 'accepted', 3.1, 101.6, 20,
   '00000000-0000-0000-0000-0000000260b1', 'Test Driver One', 'KEEP 1', null),
  ('00000000-0000-0000-0000-000000026003', '00000000-0000-0000-0000-0000000260a3', 'cancelled', 3.1, 101.6, 20,
   '00000000-0000-0000-0000-0000000260b1', 'Test Driver One', null, null),
  ('00000000-0000-0000-0000-000000026005', '00000000-0000-0000-0000-0000000260a3', 'completed', 3.1, 101.6, 20,
   '00000000-0000-0000-0000-0000000260b1', 'Test Driver One', null, '  ');
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026002') = 'KEEP 1 | - | -',
  'the ride under way starts with its plate and no vehicle');

-- 2. The session starts: the live rides fill at once -----------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000260b1');
select public.claim_vehicle('00000000-0000-0000-0000-0000000260f1', '00000000-0000-0000-0000-0000000260b1');
reset role;

select pg_temp.check(
  pg_temp.car('00000000-0000-0000-0000-000000026001')
    = 'TST 2601 | Silver Testmake Alpha | 00000000-0000-0000-0000-0000000260f1',
  'the open bid gets the plate, the car and the vehicle when the session starts: '
    || pg_temp.car('00000000-0000-0000-0000-000000026001'));
select pg_temp.check(
  (select partner_energy = 'Petrol' and partner_plate_colours is not null and status = 'open'
          and partner_id = '00000000-0000-0000-0000-0000000260b1'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026001'),
  'the bid is stamped with the vehicle''s energy and plate colours, and stays an open bid');
select pg_temp.check(
  pg_temp.car('00000000-0000-0000-0000-000000026002')
    = 'KEEP 1 | Silver Testmake Alpha | 00000000-0000-0000-0000-0000000260f1',
  'a plate already on the card is kept; the car and vehicle are filled: '
    || pg_temp.car('00000000-0000-0000-0000-000000026002'));
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026003') = '- | - | -',
  'a cancelled ride is untouched: ' || pg_temp.car('00000000-0000-0000-0000-000000026003'));
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026005') = '- |    | -',
  'a completed ride is untouched: ' || pg_temp.car('00000000-0000-0000-0000-000000026005'));
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026004') = '- | - | -',
  'another driver''s bid is untouched: ' || pg_temp.car('00000000-0000-0000-0000-000000026004'));

-- What the rider reads.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000260a1');
select pg_temp.check(
  (select partner_plate = 'TST 2601' and partner_vehicle = 'Silver Testmake Alpha'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000026001'),
  'the rider sees the plate and car on the offer');
reset role;

-- Taking the same vehicle again (or the heartbeat) changes nothing.
update public.ride_requests set partner_plate = 'EDITED 1' where id = '00000000-0000-0000-0000-000000026001';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000260b1');
select public.claim_vehicle('00000000-0000-0000-0000-0000000260f1', '00000000-0000-0000-0000-0000000260b1');
select public.touch_vehicle_session('00000000-0000-0000-0000-0000000260b1');
reset role;
select pg_temp.check(
  (select partner_plate = 'EDITED 1' from public.ride_requests where id = '00000000-0000-0000-0000-000000026001'),
  'a plate on the card is never replaced');

-- 3. A later write fills the row too ---------------------------------------------------------
-- The other driver's session starts with the fill held back (as if the bid
-- arrived just after it, or the fill was refused), so only a later write on
-- the row can bring the car.
set local getride.vehicle_fill = 'on';
insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000260f2', '00000000-0000-0000-0000-0000000260b2');
set local getride.vehicle_fill = 'off';
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026004') = '- | - | -',
  'with the fill held back the bid is still without a car');

-- The driver's own write: their live position on the bid.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000260b2');
update public.ride_requests set partner_live_lat = 3.1, partner_live_lng = 101.6, partner_live_at = now()
 where id = '00000000-0000-0000-0000-000000026004';
reset role;
select pg_temp.check(
  pg_temp.car('00000000-0000-0000-0000-000000026004')
    = 'TST 2602 | Blue Testmake Beta | 00000000-0000-0000-0000-0000000260f2',
  'the driver''s next write on the bid fills the plate, car and vehicle: '
    || pg_temp.car('00000000-0000-0000-0000-000000026004'));

-- A blank card on a ride with its vehicle already stamped: the rider's write fills it.
update public.ride_requests set partner_plate = ' ', partner_vehicle = null
 where id = '00000000-0000-0000-0000-000000026004';
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026004') = 'TST 2602 | Blue Testmake Beta | 00000000-0000-0000-0000-0000000260f2',
  'a server write that blanks the card is filled back at once');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000260a4');
update public.ride_requests set user_live_lat = 3.1, user_live_lng = 101.6, user_live_at = now()
 where id = '00000000-0000-0000-0000-000000026004';
reset role;
select pg_temp.check(
  pg_temp.car('00000000-0000-0000-0000-000000026004')
    = 'TST 2602 | Blue Testmake Beta | 00000000-0000-0000-0000-0000000260f2',
  'the rider''s write keeps the filled card: ' || pg_temp.car('00000000-0000-0000-0000-000000026004'));

-- The completed ride is still untouched by a later write.
update public.ride_requests set updated_at = now() where id = '00000000-0000-0000-0000-000000026005';
select pg_temp.check(pg_temp.car('00000000-0000-0000-0000-000000026005') = '- |    | -',
  'a later write on a completed ride brings no car');

select 'offer_vehicle_fill_0260: all passed';

rollback;
