-- ============================================================================
-- Regression test for migration 0341: the mid-ride drop-off change (driver
-- check corrected in 0428; answered only while the ride is under way, 0431;
-- the ride read under its row lock, 0434 and 0435; the fare priced by the
-- server, 0437).
--   * A change within the admin's threshold applies at once; a dearer one is
--     held for the driver.
--   * The ride's driver accepts a held change (the drop and the fare change)
--     or declines it (the ride stays as booked), and nobody else answers for
--     them: not the rider, not a stranger, not another driver.
--   * The driver of a ride is ride_requests.partner_id = the driver's own
--     account id (their auth uid), as the app writes it when a ride is taken.
--     It is never a partners.id: 0341 looked the driver up by that, which no
--     real ride holds, so the driver's own answer was refused (0428).
--   * With nothing held there is nothing to answer.
--   * A held change is answered only while the ride is under way, the rule the
--     request already has: once the ride is completed or cancelled, its
--     driver's accept and decline are refused with not_ongoing and the ride is
--     left as it is (0431).
--   * The rider can withdraw a held change: the ride stays as booked and the
--     change is recorded as expired, by the rider. Nobody else withdraws it
--     for them, and with nothing held a withdraw changes nothing.
--   * The request and the answer both read the ride under its row lock, so its
--     status cannot change between the check and the write (0434). The
--     withdraw reads it the same way, so the held change it checks is the one
--     it writes to (0435). One transaction cannot show two calls overlapping,
--     so this file checks that each function reads the ride for update.
--   * The fare of a change is the server's (0437): the ride's fare card over
--     the route the server measured, with the ride's option charges kept. The
--     fare sent with the change is only the fare the rider was shown, and a
--     change is refused when the server's fare is higher. A cheaper change
--     applies at once only before the ride starts; a bid ride, a ride with no
--     route of the server's own, and a ride the fare card does not price all
--     wait for the driver. ride_drop_change_quote says the same beforehand.
--   * The drop_change_* columns and the service are server-only: a client
--     can't write them on a direct update.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/drop_change_0341.sql
--
-- Runs in one transaction and is rolled back. Made-up people only. A failed
-- assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000341a1'),  -- rider
  ('00000000-0000-0000-0000-0000000341b1'),  -- driver, on the rides
  ('00000000-0000-0000-0000-0000000341b2'),  -- another driver, on none of them
  ('00000000-0000-0000-0000-0000000341c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000341%'
on conflict do nothing;

-- The driver's partner row. Its id (…0341d1) is not the driver's account id
-- (…0341b1), as for every real partner. The other driver's partner row has the
-- rides' partner_id as its id, the id 0341 looked up: on 0341's check that made
-- them the rides' driver. They are on none of these rides.
insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000341d1', '00000000-0000-0000-0000-0000000341b1', 'Test Driver 0341', '+60100003411',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000341b1', '00000000-0000-0000-0000-0000000341b2', 'Other Driver 0341', '+60100003412',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;

-- The admin's rules, as shipped: a dearer drop applies at once when it adds no
-- more than RM 3 or 15 % of the fare, whichever is more.
insert into public.app_settings (key, value) values
  ('drop_change_rules', '{"allow": true, "autoApproveCheaper": true, "autoApproveRm": 3, "autoApprovePct": 15,
                          "responseWindowSec": 30, "maxChangesPerRide": 2}')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The fare card the rides are priced on (0437), for a made-up country so no
-- real card is in its way: 5.25 + 0.50 a km + 0.50 a minute, for every
-- service. Inside it one city has its own card, with a minimum fare and a
-- booking fee; one service type has a card, and one vehicle its own.
insert into public.settings_entries (id, category, position, values) values
  ('00000000-0000-0000-0000-0000000431a1', 'service-settings', 9001, '{"name": "Test Type 0431"}'),
  -- Cost per km 3.00: a multiplier of 2 (over the base 1.50), and its own
  -- rates where no card covers the trip.
  ('00000000-0000-0000-0000-0000000431a2', 'vehicle-services', 9002,
   '{"name": "Test Premium 0431", "costPerKm": 3, "costPerMin": 0.2, "minFareAmount": 12, "serviceTypes": ["Test Type 0431"]}'),
  ('00000000-0000-0000-0000-0000000431a3', 'vehicle-services', 9003,
   '{"name": "Test Bike 0431", "costPerKm": 0.75, "serviceTypes": ["Test Type 0431"]}'),
  ('00000000-0000-0000-0000-0000000431a4', 'vehicle-services', 9004, '{"name": "Test Van 0431", "costPerKm": 3}'),
  -- A metered taxi has no rates of its own: the built-in tariff prices it.
  ('00000000-0000-0000-0000-0000000431a5', 'vehicle-services', 9005, '{"name": "Test Teksi 0431", "costPerKm": 1.8}')
on conflict (id) do nothing;
insert into public.fare_tariffs (id, level, country, state, city, label, base_fare, per_km, per_minute,
                                 minimum_fare, booking_fee, service_type, vehicle_service) values
  ('00000000-0000-0000-0000-0000000431f1', 'country', 'Testland 0341', null, null, 'Every service', 5.25, 0.5, 0.5,
   0, 0, null, null),
  ('00000000-0000-0000-0000-0000000431f2', 'country', 'Testland 0341', null, null, 'The type', 2, 1, 0,
   0, 0, '00000000-0000-0000-0000-0000000431a1', null),
  ('00000000-0000-0000-0000-0000000431f3', 'country', 'Testland 0341', null, null, 'The vehicle''s own', 8, 2, 0,
   0, 0, null, '00000000-0000-0000-0000-0000000431a2'),
  ('00000000-0000-0000-0000-0000000431f4', 'city', 'Testland 0341', 'Teststate 0431', 'Testcity 0431', 'The city', 10, 1, 0,
   25, 1, null, null)
on conflict (id) do nothing;

-- Six rides under way, booked to Mid Valley. Each carries the driver's
-- account id in partner_id, as a ride the app has taken does, and is booked at
-- the card's price of its 8 km / 20 min trip (19.25), so none reads as a bid.
-- They were picked up at KLCC, in the made-up country. The first three stay on
-- the trip. The next two end with a change still held (section 7): one is on
-- the trip and is completed, the other is cancelled with the driver still on
-- the way. On the last one the rider withdraws a held change (section 8).
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  drop_name, drop_address, drop_lat, drop_lng, distance_km, duration_min,
                                  pickup_lat, pickup_lng, country) values
  ('00000000-0000-0000-0000-0000000341e1', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e2', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e3', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e4', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e5', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'accepted', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e6', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341')
on conflict (id) do nothing;

-- The routes the route service measured from KLCC a moment ago (0437), as it
-- logs every route the app asks it for: to Bangsar Village 9.5 km in 24
-- minutes (22.00 on the card), to Sunway Pyramid 21.5 km in 38 (35.00) and to
-- Pavilion 1.6 km in 6 (9.05). Bukit Bintang is not here (section 15).
insert into public.fare_ai_responses (provider, origin_lat, origin_lng, dest_lat, dest_lng, success,
                                      distance_km, duration_min) values
  ('waze', 3.1579, 101.7116, 3.1302, 101.6712, true, 9.5, 24),
  ('waze', 3.1579, 101.7116, 3.0733, 101.6078, true, 21.5, 38),
  ('waze', 3.1579, 101.7116, 3.1177, 101.6774, true, 8.0, 20),
  ('waze', 3.1579, 101.7116, 3.1488, 101.7133, true, 1.6, 6);

-- The rides of the 0431 sections. Each is picked up at KLCC and booked to Mid
-- Valley over 8 km / 20 min, at the card's 19.25 unless it says otherwise, and
-- carries the driver's account id. "arr" is arrived (not yet driving), "trip"
-- is on trip.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  drop_name, drop_address, drop_lat, drop_lng, distance_km, duration_min,
                                  pickup_lat, pickup_lng, country, whole_fare, stops, option_charges,
                                  cargo_description, airport_fare, mygig, fare_mode) values
  ('00000000-0000-0000-0000-0000000431e1', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null),
  ('00000000-0000-0000-0000-0000000431e2', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null),
  -- Arrived, not yet driving: a cheaper change applies at once.
  ('00000000-0000-0000-0000-0000000431e3', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'arrived', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null),
  -- On trip: the same cheaper change waits for the driver.
  ('00000000-0000-0000-0000-0000000431e4', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null),
  -- A bid: booked at 30, above the card's 19.25 for the trip.
  ('00000000-0000-0000-0000-0000000431e5', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 30, 30, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null),
  -- A bid, and arrived: still the driver's call, though cheaper and pre-trip.
  ('00000000-0000-0000-0000-0000000431e6', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'arrived', 30, 30, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null),
  -- A pet charge of 10, in the fare (29.25): kept when the drop moves.
  ('00000000-0000-0000-0000-0000000431e7', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 29.25, 29.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]',
   '[{"kind": "pet", "name": "Pet charge", "amount": 10}]', null, null, null, null),
  -- Arrived, where fares are whole amounts (booked 20 = ceil of 19.25).
  ('00000000-0000-0000-0000-0000000431e8', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'arrived', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', true, '[]', null, null, null, null, null),
  -- With a stop on the way: its route is not pickup → drop.
  ('00000000-0000-0000-0000-0000000431e9', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false,
   '[{"name": "Pavilion", "address": "Jalan Bukit Bintang, Kuala Lumpur", "lat": 3.1488, "lng": 101.7133}]',
   null, null, null, null, null),
  -- Rides the fare card does not price, at 50.00: Freight, an airport fare,
  -- myGiG and an operator's booking.
  ('00000000-0000-0000-0000-0000000431ea', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, 'Boxes of books', null, null, null),
  ('00000000-0000-0000-0000-0000000431eb', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, '{"total": 50}', null, null),
  ('00000000-0000-0000-0000-0000000431ec', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, '{}', null),
  ('00000000-0000-0000-0000-0000000431ed', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, 'fixed'),
  -- Arrived, for the no-route-then-route check (section 15).
  ('00000000-0000-0000-0000-0000000431e0'::uuid, '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'arrived', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null, null)
on conflict (id) do nothing;
-- And one still waiting for a driver, and one for the guard test (section 22).
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name, drop_name,
                                  drop_address, drop_lat, drop_lng, distance_km, duration_min, pickup_lat, pickup_lng,
                                  country, stops) values
  ('00000000-0000-0000-0000-0000000431ee', '00000000-0000-0000-0000-0000000341a1', null, 'open', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 3.1579, 101.7116, 'Testland 0341', '[]'),
  ('00000000-0000-0000-0000-0000000431ef', '00000000-0000-0000-0000-0000000341a1', '00000000-0000-0000-0000-0000000341b1',
   'on_trip', 19.25, 19.25, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 3.1579, 101.7116, 'Testland 0341', '[]')
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- The call must be refused, and with this error.
create or replace function pg_temp.refused(p_sql text, p_error text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm = p_error then
      return;
    end if;
    raise exception 'FAILED: % raised "%", not "%"', p_what, sqlerrm, p_error;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text, text) to authenticated;

-- 0. The rides above are the driver's as the app itself sees them -----------------------------------
-- Signed in, the driver reads the rides that carry their account id; the other
-- driver reads none of them. A fixture with the wrong id in partner_id fails
-- here, whatever the functions under test do with it.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check((select count(*) = 6 from public.ride_requests
                       where id::text like '00000000-0000-0000-0000-0000000341e%'),
  'signed in, the driver reads the rides that carry their account id');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b2');
select pg_temp.check((select count(*) = 0 from public.ride_requests
                       where id::text like '00000000-0000-0000-0000-0000000341e%'),
  'the other driver reads none of them: to the app they are not theirs');

-- 1. A change within the threshold applies at once --------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e1', 'Bangsar Village',
                                  'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 9.5, 24, 22)
    = '{"applied": true, "pending": false, "fare": 22}'::jsonb,
  'the card''s 22.00, RM 2.75 more, is within the threshold: applied at once');
reset role;
select pg_temp.check((select drop_name = 'Bangsar Village' and drop_address = 'Jalan Telawi 1, Kuala Lumpur'
                         and drop_lat = 3.1302 and drop_lng = 101.6712
                         and distance_km = 9.5 and duration_min = 24
                         and ride_fare = 22 and fare = 19.25
                         and drop_change_count = 1
                         and drop_change_requested_at is null and drop_change_fare is null
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'auto'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e1'),
  'the ride goes to the new drop at the new fare, accepted by the rules, with nothing left waiting');

-- 2. A dearer one is held for the driver ------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e2', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'the card''s 35.00 is over the threshold: held for the driver');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e3', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'and held on the other ride');
reset role;
select pg_temp.check((select count(*) = 2 from public.ride_requests
                       where id in ('00000000-0000-0000-0000-0000000341e2', '00000000-0000-0000-0000-0000000341e3')
                         and drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
                         and drop_lat = 3.1177 and drop_lng = 101.6774
                         and distance_km = 8.0 and duration_min = 20
                         and ride_fare = 19.25 and fare = 19.25
                         and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
                         and drop_change_name = 'Sunway Pyramid'
                         and drop_change_address = 'Jalan PJS 11/15, Subang Jaya'
                         and drop_change_lat = 3.0733 and drop_change_lng = 101.6078
                         and drop_change_distance_km = 21.5 and drop_change_duration_min = 38
                         and drop_change_fare = 35
                         and drop_change_outcome is null and drop_change_outcome_by is null
                         and drop_change_outcome_at is null),
  'a held change leaves the ride as booked, with the drop and fare asked for kept beside it');

-- 3. The ride's driver accepts ----------------------------------------------------------------------
-- The driver is the ride's partner_id, their account id (0428). On 0341's check
-- (partner_id = a partners.id) this call was refused with not_authorized.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e2', true) = '{"accepted": true}'::jsonb,
  'the ride''s driver accepts the held change');
reset role;
select pg_temp.check((select drop_name = 'Sunway Pyramid' and drop_address = 'Jalan PJS 11/15, Subang Jaya'
                         and drop_lat = 3.0733 and drop_lng = 101.6078
                         and distance_km = 21.5 and duration_min = 38
                         and ride_fare = 35 and fare = 19.25
                         and drop_change_count = 1
                         and drop_change_requested_at is null and drop_change_requested_by is null
                         and drop_change_name is null and drop_change_address is null
                         and drop_change_lat is null and drop_change_lng is null
                         and drop_change_distance_km is null and drop_change_duration_min is null
                         and drop_change_fare is null
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'partner'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e2'),
  'accepted: the ride goes to the new drop at the new fare, and the answer is recorded as the driver''s');

-- 4. Nobody else answers for the driver -------------------------------------------------------------
-- On the ride still waiting. The other driver's partners.id is the ride's
-- partner_id: 0341's check took them for the ride's driver.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'not_authorized', 'the rider accepting their own change');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false)$q$,
                       'not_authorized', 'the rider declining for the driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'not_authorized', 'a stranger accepting the change');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false)$q$,
                       'not_authorized', 'a stranger declining the change');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b2');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'not_authorized', 'a driver whose partners.id is the ride''s partner_id accepting the change');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false)$q$,
                       'not_authorized', 'a driver whose partners.id is the ride''s partner_id declining the change');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 19.25 and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
                         and drop_change_name = 'Sunway Pyramid' and drop_change_fare = 35
                         and drop_change_outcome is null and drop_change_outcome_by is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e3'),
  'the refused answers changed nothing: the change is still waiting for the driver');

-- 5. The ride's driver declines ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false) = '{"accepted": false}'::jsonb,
  'the ride''s driver declines the held change');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
                         and drop_lat = 3.1177 and drop_lng = 101.6774
                         and distance_km = 8.0 and duration_min = 20
                         and ride_fare = 19.25 and fare = 19.25
                         and drop_change_count = 0
                         and drop_change_requested_at is null and drop_change_requested_by is null
                         and drop_change_name is null and drop_change_address is null
                         and drop_change_lat is null and drop_change_lng is null
                         and drop_change_distance_km is null and drop_change_duration_min is null
                         and drop_change_fare is null
                         and drop_change_outcome = 'declined' and drop_change_outcome_by = 'partner'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e3'),
  'declined: the ride stays as booked, and the answer is recorded as the driver''s');

-- 6. With nothing held there is nothing to answer ---------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e1', true)$q$,
                       'no_pending', 'answering a change that was applied at once');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e2', true)$q$,
                       'no_pending', 'accepting a change a second time');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'no_pending', 'accepting a change that was declined');
reset role;
select pg_temp.check((select count(*) = 3 from public.ride_requests
                       where (id = '00000000-0000-0000-0000-0000000341e1' and ride_fare = 22 and drop_change_count = 1)
                          or (id = '00000000-0000-0000-0000-0000000341e2' and ride_fare = 35 and drop_change_count = 1)
                          or (id = '00000000-0000-0000-0000-0000000341e3' and ride_fare = 19.25 and drop_change_count = 0)),
  'and the rides are left as they were');

-- 7. Once the ride is no longer under way, a held change is not answered ----------------------------
-- The request is taken only while the ride is accepted, arrived or on_trip
-- (ride_drop_change_request, not_ongoing otherwise), and the answer has the
-- same rule (0431). A change is held on each of the last two rides; the ride
-- then ends the way the app ends it, signed in as its driver.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e4', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'a dearer drop is held on a ride that is on the trip');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e5', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'and on a ride whose driver is still on the way');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
update public.ride_requests set status = 'completed', completed_at = now()
 where id = '00000000-0000-0000-0000-0000000341e4';
update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_reason = 'vehicle_issue',
                                cancel_requested_by = 'partner', cancel_requested_at = now()
 where id = '00000000-0000-0000-0000-0000000341e5' and status in ('accepted', 'arrived');
reset role;

-- The two rides once they have ended: as booked, with the drop and fare asked
-- for still held beside them and no answer recorded.
create or replace function pg_temp.ended_with_change_held() returns boolean language sql as $$
  select count(*) = 2 from public.ride_requests
   where ((id = '00000000-0000-0000-0000-0000000341e4' and status = 'completed')
       or (id = '00000000-0000-0000-0000-0000000341e5' and status = 'cancelled'))
     and drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
     and drop_lat = 3.1177 and drop_lng = 101.6774
     and distance_km = 8.0 and duration_min = 20
     and ride_fare = 19.25 and fare = 19.25
     and drop_change_count = 0
     and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
     and drop_change_name = 'Sunway Pyramid'
     and drop_change_address = 'Jalan PJS 11/15, Subang Jaya'
     and drop_change_lat = 3.0733 and drop_change_lng = 101.6078
     and drop_change_distance_km = 21.5 and drop_change_duration_min = 38
     and drop_change_fare = 35
     and drop_change_outcome is null and drop_change_outcome_by is null
     and drop_change_outcome_at is null
$$;
select pg_temp.check(pg_temp.ended_with_change_held(),
  'one ride is completed and one cancelled, each as booked with its change still held');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e4', true)$q$,
                       'not_ongoing', 'the ride''s driver accepting a held change after the ride was completed');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e4', false)$q$,
                       'not_ongoing', 'the ride''s driver declining a held change after the ride was completed');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e5', true)$q$,
                       'not_ongoing', 'the ride''s driver accepting a held change after the ride was cancelled');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e5', false)$q$,
                       'not_ongoing', 'the ride''s driver declining a held change after the ride was cancelled');
-- Anybody else is still told only that the ride is not theirs to answer for.
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e4', true)$q$,
                       'not_authorized', 'the rider accepting their own change after the ride was completed');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e5', false)$q$,
                       'not_authorized', 'a stranger declining the change after the ride was cancelled');
reset role;
select pg_temp.check(pg_temp.ended_with_change_held(),
  'the refused answers changed nothing: the fare, the drop and the held change are as they were');

-- 8. The rider withdraws a held change --------------------------------------------------------------
-- Their own cancel, or the passenger's app when the response window runs out
-- (ride_drop_change_withdraw). A dearer drop is held on the last ride.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e6', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'a dearer drop is held on the last ride');
-- Nobody withdraws it for the rider: not the ride's driver, not a stranger.
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000341e6')$q$,
                       'not_authorized', 'the ride''s driver withdrawing the rider''s change');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000341e6')$q$,
                       'not_authorized', 'a stranger withdrawing the rider''s change');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 19.25 and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
                         and drop_change_name = 'Sunway Pyramid' and drop_change_fare = 35
                         and drop_change_outcome is null and drop_change_outcome_by is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e6'),
  'the refused withdraws changed nothing: the change is still waiting for the driver');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000341e6') = '{"withdrawn": true}'::jsonb,
  'the rider withdraws the held change');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
                         and drop_lat = 3.1177 and drop_lng = 101.6774
                         and distance_km = 8.0 and duration_min = 20
                         and ride_fare = 19.25 and fare = 19.25
                         and drop_change_count = 0
                         and drop_change_requested_at is null and drop_change_requested_by is null
                         and drop_change_name is null and drop_change_address is null
                         and drop_change_lat is null and drop_change_lng is null
                         and drop_change_distance_km is null and drop_change_duration_min is null
                         and drop_change_fare is null
                         and drop_change_outcome = 'expired' and drop_change_outcome_by = 'rider'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e6'),
  'withdrawn: the ride stays as booked, and the change is recorded as expired, by the rider');

-- With nothing held a withdraw changes nothing: not on the ride just
-- withdrawn, and not on the rides whose change the driver has answered.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000341e6') = '{"withdrawn": false}'::jsonb,
  'a second withdraw finds nothing held');
select pg_temp.check(
  public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000341e2') = '{"withdrawn": false}'::jsonb,
  'so does a withdraw after the driver accepted the change');
select pg_temp.check(
  public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000341e3') = '{"withdrawn": false}'::jsonb,
  'and one after the driver declined it');
-- And the driver has nothing to answer on a change that was withdrawn.
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e6', true)$q$,
                       'no_pending', 'the driver accepting a change the rider withdrew');
reset role;
select pg_temp.check((select count(*) = 3 from public.ride_requests
                       where (id = '00000000-0000-0000-0000-0000000341e2' and drop_name = 'Sunway Pyramid'
                              and ride_fare = 35 and drop_change_count = 1
                              and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'partner')
                          or (id = '00000000-0000-0000-0000-0000000341e3' and drop_name = 'Mid Valley'
                              and ride_fare = 19.25 and drop_change_count = 0
                              and drop_change_outcome = 'declined' and drop_change_outcome_by = 'partner')
                          or (id = '00000000-0000-0000-0000-0000000341e6' and drop_name = 'Mid Valley'
                              and ride_fare = 19.25 and drop_change_count = 0
                              and drop_change_outcome = 'expired' and drop_change_outcome_by = 'rider')),
  'the rides are as they were, each with the answer already recorded on it');

-- 9. Still for signed-in callers only, as 0341 granted it -------------------------------------------
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_resolve(uuid, boolean)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_resolve(uuid, boolean)', 'execute'),
  'ride_drop_change_resolve is open to signed-in callers and not to anon');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=""']
                        from pg_proc p
                       where p.oid = 'public.ride_drop_change_resolve(uuid, boolean)'::regprocedure),
  'ride_drop_change_resolve is security definer with an empty search_path');
-- And the request, recreated in 0434.
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)', 'execute'),
  'ride_drop_change_request is open to signed-in callers and not to anon');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=""']
                        from pg_proc p
                       where p.oid = 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)'::regprocedure),
  'ride_drop_change_request is security definer with an empty search_path');
-- And the withdraw, recreated in 0435.
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_withdraw(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_withdraw(uuid)', 'execute'),
  'ride_drop_change_withdraw is open to signed-in callers and not to anon');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=""']
                        from pg_proc p
                       where p.oid = 'public.ride_drop_change_withdraw(uuid)'::regprocedure),
  'ride_drop_change_withdraw is security definer with an empty search_path');

-- 10. All three functions read the ride under its row lock (0434, 0435) -----------------------------
-- The request and the answer each read the ride, check the caller and the
-- ride's status, and then write to the ride. The read is "for update", so the
-- status cannot change between the check and the write (0434). The withdraw
-- reads the ride the same way, so the held change it checks is the one it
-- writes to (0435). One transaction cannot show two calls overlapping, so this
-- looks at the functions as they are stored: a later migration that recreates
-- one of them from its body has to keep the lock.
select pg_temp.check(
  (select p.prosrc ~* 'from\s+public\.ride_requests\s+where\s+id\s*=\s*p_ride\s+for\s+update\s*;'
     from pg_proc p
    where p.oid = 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)'::regprocedure),
  'ride_drop_change_request reads the ride for update');
select pg_temp.check(
  (select p.prosrc ~* 'from\s+public\.ride_requests\s+where\s+id\s*=\s*p_ride\s+for\s+update\s*;'
     from pg_proc p
    where p.oid = 'public.ride_drop_change_resolve(uuid, boolean)'::regprocedure),
  'ride_drop_change_resolve reads the ride for update');
select pg_temp.check(
  (select p.prosrc ~* 'from\s+public\.ride_requests\s+where\s+id\s*=\s*p_ride\s+for\s+update\s*;'
     from pg_proc p
    where p.oid = 'public.ride_drop_change_withdraw(uuid)'::regprocedure),
  'ride_drop_change_withdraw reads the ride for update');

-- ======================================================================================================
-- 0437: the fare of a change is the server's.
-- ======================================================================================================

-- 11. What a change would come to, before the rider confirms ------------------------------------------
-- The fare is the ride's fare card (5.25 + 0.50 a km + 0.50 a minute) over the
-- route the server measured. Asking changes nothing.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.1302, 101.6712, 9.5, 24) = '{"fare": 22, "instant": true}'::jsonb,
  'to Bangsar Village: 22.00, within the threshold, applied at once');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.0733, 101.6078, 21.5, 38) = '{"fare": 35, "instant": false}'::jsonb,
  'to Sunway Pyramid: 35.00, over the threshold, for the driver to accept');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.0733, 101.6078, 1, 2) = '{"fare": 35, "instant": false}'::jsonb,
  'the route is the one the server measured (21.5 km in 38 minutes), whatever distance and time are sent');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.0733, 101.6078, null, null) = '{"fare": 35, "instant": false}'::jsonb,
  'and with none sent');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-000000999999', 3.1302, 101.6712, 9.5, 24)$q$,
                       'not_found', 'a quote for a ride that is not there');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431ee', 3.1302, 101.6712, 9.5, 24)$q$,
                       'not_ongoing', 'a quote for a ride no driver has taken');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 91, 101.6712, 9.5, 24)$q$,
                       'bad_request', 'a quote for a place off the map');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', null, 101.6712, 9.5, 24)$q$,
                       'bad_request', 'a quote for no place');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.1302, 101.6712, -1, 24)$q$,
                       'bad_request', 'a quote over a distance below zero');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.1302, 101.6712, 'NaN', 24)$q$,
                       'bad_request', 'a quote over a distance that is not a number');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.1302, 101.6712, 9.5, 24)$q$,
                       'not_authorized', 'the driver asking for the rider''s quote');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.1302, 101.6712, 9.5, 24)$q$,
                       'not_authorized', 'a stranger asking for the rider''s quote');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 19.25 and distance_km = 8.0 and duration_min = 20
                         and drop_change_count = 0 and drop_change_requested_at is null and drop_change_fare is null
                         and drop_change_outcome is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e1'),
  'asking changed nothing on the ride');

-- 12. The fare sent with a change is the fare the rider was shown --------------------------------------
-- It sets nothing. A change whose fare is higher than the rider was shown is
-- refused, and the ride is left as it is: to Mid Valley, where the ride is
-- going already, the card says 19.25; to Sunway Pyramid, 35.00.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e1', 'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 1)$q$,
                       'DROP_CHANGE_FARE', 'the drop-off the ride has already, sent at 1.00');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e1', 'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 0)$q$,
                       'DROP_CHANGE_FARE', 'the drop-off the ride has already, sent at nothing');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 20)$q$,
                       'DROP_CHANGE_FARE', 'a drop-off 21.5 km away, sent at the fare the ride has');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 1, 2, 1)$q$,
                       'DROP_CHANGE_FARE', 'a drop-off 21.5 km away, sent as 1 km at 1.00');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 34.98)$q$,
                       'DROP_CHANGE_FARE', 'a drop-off sent at two cents under its fare');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 'NaN')$q$,
                       'bad_request', 'a fare that is not a number');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, -1)$q$,
                       'bad_request', 'a fare below zero');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, null)$q$,
                       'bad_request', 'no fare');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Nowhere', null, 3.0733, 181, 21.5, 38, 35)$q$,
                       'bad_request', 'a place off the map');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ee', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)$q$,
                       'not_ongoing', 'a change on a ride no driver has taken');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)$q$,
                       'not_authorized', 'the driver moving the rider''s drop-off');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)$q$,
                       'not_authorized', 'a stranger moving the rider''s drop-off');
reset role;
select pg_temp.check((select count(*) = 2 from public.ride_requests
                       where id in ('00000000-0000-0000-0000-0000000431e1', '00000000-0000-0000-0000-0000000431e2')
                         and drop_name = 'Mid Valley' and drop_lat = 3.1177 and drop_lng = 101.6774
                         and distance_km = 8.0 and duration_min = 20 and ride_fare = 19.25 and fare = 19.25
                         and drop_change_count = 0 and drop_change_requested_at is null
                         and drop_change_fare is null and drop_change_outcome is null),
  'the refused changes left both rides as booked, with nothing waiting');

-- 13. A dearer change within the threshold applies at once --------------------------------------------
-- The ride is on trip; a dearer change is not held back by that.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e1', 'Bangsar Village',
                                  'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 9.5, 24, 22)
    = '{"applied": true, "pending": false, "fare": 22}'::jsonb,
  'sent at the card''s 22.00, the change applies at once');
reset role;
select pg_temp.check((select drop_name = 'Bangsar Village' and ride_fare = 22 and fare = 19.25
                         and distance_km = 9.5 and duration_min = 24 and drop_change_count = 1
                         and drop_change_requested_at is null
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'auto'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e1'),
  'the ride goes to Bangsar Village over the measured 9.5 km at 22.00');

-- 14. A dearer change over the threshold waits for the driver -----------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 1, 2, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'held at the server''s 35.00, over the measured route, whatever distance is sent');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 19.25 and distance_km = 8.0 and duration_min = 20
                         and drop_change_name = 'Sunway Pyramid' and drop_change_fare = 35
                         and drop_change_distance_km = 21.5 and drop_change_duration_min = 38
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e2'),
  'the held change carries the server''s fare and the route it measured, not the 1 km sent');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431e2', true) = '{"accepted": true}'::jsonb,
  'the driver accepts it');
reset role;
select pg_temp.check((select drop_name = 'Sunway Pyramid' and ride_fare = 35 and distance_km = 21.5 and duration_min = 38
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e2'),
  'the ride goes to Sunway Pyramid at 35.00');

-- 15. A cheaper change applies at once before the trip, and waits once on it --------------------------
-- Pavilion is 9.05 on the card, cheaper than the 19.25 booked.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e3', 3.1488, 101.7133, 1.6, 6) = '{"fare": 9.05, "instant": true}'::jsonb,
  'on an arrived ride the quote says it applies at once');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e4', 3.1488, 101.7133, 1.6, 6) = '{"fare": 9.05, "instant": false}'::jsonb,
  'on a ride under way the quote says the driver decides');
-- Arrived (not yet driving): the cheaper drop applies at once.
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e3', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur',
                                  3.1488, 101.7133, 1.6, 6, 9.05)
    = '{"applied": true, "pending": false, "fare": 9.05}'::jsonb,
  'before the ride starts the cheaper drop applies at once');
-- On trip: the same cheaper drop waits for the driver.
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e4', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur',
                                  3.1488, 101.7133, 1.6, 6, 9.05)
    = '{"applied": false, "pending": true, "fare": 9.05}'::jsonb,
  'once the car is driving the cheaper drop waits for the driver');
reset role;
select pg_temp.check((select drop_name = 'Pavilion' and ride_fare = 9.05 and drop_change_count = 1
                         and drop_change_requested_at is null and drop_change_outcome = 'accepted'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e3'),
  'the arrived ride is at Pavilion at 9.05');
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 19.25 and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_fare = 9.05
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e4'),
  'the on-trip ride keeps its fare while the driver is asked about 9.05');

-- Where fares are whole amounts the cheaper fare is rounded up, as a booking is.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e8', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur',
                                  3.1488, 101.7133, 1.6, 6, 10)
    = '{"applied": true, "pending": false, "fare": 10}'::jsonb,
  'where fares are whole amounts 9.05 is 10, applied at once on an arrived ride');
reset role;

-- With no route of the server's own the fare stays and the driver is asked;
-- once the route is measured the cheaper drop applies (the ride is arrived).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e0'::uuid, 3.1466, 101.7108, 0.2, 1) = '{"fare": 19.25, "instant": false}'::jsonb,
  'without a measured route the quote is the fare the ride has, for the driver');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e0', 'Bukit Bintang', 'Jalan Sultan Ismail, Kuala Lumpur', 3.1466, 101.7108, 0.2, 1, 6)$q$,
                       'DROP_CHANGE_FARE', 'a drop with no measured route, sent at a lower fare');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e0', 'Bukit Bintang', 'Jalan Sultan Ismail, Kuala Lumpur',
                                  3.1466, 101.7108, 0.2, 1, 19.25)
    = '{"applied": false, "pending": true, "fare": 19.25}'::jsonb,
  'without a route of the server''s own the change waits for the driver, at the fare the ride has');
select pg_temp.check(
  public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000431e0') = '{"withdrawn": true}'::jsonb,
  'the rider withdraws it');
reset role;
insert into public.fare_ai_responses (provider, origin_lat, origin_lng, dest_lat, dest_lng, success, distance_km, duration_min)
  values ('gmap', 3.1579, 101.7116, 3.1466, 101.7108, true, 2.4, 9);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e0', 'Bukit Bintang', 'Jalan Sultan Ismail, Kuala Lumpur',
                                  3.1466, 101.7108, 0.2, 1, 10.95)
    = '{"applied": true, "pending": false, "fare": 10.95}'::jsonb,
  'with the route measured (2.4 km in 9 minutes) the cheaper drop applies at once on the arrived ride');
reset role;
select pg_temp.check((select drop_name = 'Bukit Bintang' and ride_fare = 10.95 and distance_km = 2.4 and duration_min = 9
                         and drop_change_count = 1
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e0'),
  'the ride goes to Bukit Bintang over the measured 2.4 km at 10.95, not the 0.2 km sent');

-- 16. A bid waits for the driver on any change -------------------------------------------------------
-- e5 and e6 were booked at 30, above the card's 19.25. Repricing to the card
-- would drop the premium, so the driver decides -- even a cheaper drop, even
-- before the trip starts.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e5', 3.1302, 101.6712, 9.5, 24) = '{"fare": 22, "instant": false}'::jsonb,
  'a bid ride under way: the card''s 22.00, for the driver');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e5', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur',
                                  3.1302, 101.6712, 9.5, 24, 22)
    = '{"applied": false, "pending": true, "fare": 22}'::jsonb,
  'the bid ride''s change is held');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e6', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur',
                                  3.1488, 101.7133, 1.6, 6, 9.05)
    = '{"applied": false, "pending": true, "fare": 9.05}'::jsonb,
  'a bid ride, arrived and a cheaper drop, still waits for the driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431e5', true) = '{"accepted": true}'::jsonb,
  'the driver accepts the bid ride''s change');
reset role;
select pg_temp.check((select drop_name = 'Bangsar Village' and ride_fare = 22 and fare = 30
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e5'),
  'accepted, the bid ride goes to Bangsar Village at the card''s 22.00');

-- 17. The ride's option charges are kept -------------------------------------------------------------
-- e7 carries a 10.00 pet charge in its 29.25 fare. Moving the drop keeps it:
-- the fare is the card over the new route plus the 10.00.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e7', 3.1302, 101.6712, 9.5, 24) = '{"fare": 32, "instant": true}'::jsonb,
  'to Bangsar Village: 22.00 on the card plus the 10.00 pet charge, within the threshold');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e7', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur',
                                  3.1302, 101.6712, 9.5, 24, 32)
    = '{"applied": true, "pending": false, "fare": 32}'::jsonb,
  'applied at the card fare plus the pet charge');
reset role;
select pg_temp.check((select ride_fare = 32 and drop_name = 'Bangsar Village'
                         and public.ride_option_charges_total(option_charges) = 10
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e7'),
  'the ride is at 32.00 and keeps its pet charge');

-- 18. A ride with a stop, and rides the fare card does not price, keep their fare --------------------
-- e9's route goes through its stop, so the measurement straight to Bangsar is
-- not its route: the fare stays and the driver is asked. (The same change on a
-- ride without a stop applied at once, section 13.)
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e9', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur',
                                  3.1302, 101.6712, 12.5, 30, 20)
    = '{"applied": false, "pending": true, "fare": 19.25}'::jsonb,
  'a change on a ride with a stop waits for the driver, at the fare the ride has');
reset role;
select pg_temp.check((select ride_fare = 19.25 and drop_change_fare = 19.25 and drop_change_distance_km = 12.5
                         and drop_change_duration_min = 30 and drop_change_requested_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e9'),
  'kept with the 12.5 km and 30 minutes sent for the trip through the stop');

-- Freight, an airport fare, myGiG and an operator's booking are priced another
-- way: their fare stays, and the driver is asked.
select pg_temp.check(
  (select count(*) = 4
     from public.ride_requests r,
          lateral public.ride_drop_change_terms(r, 3.0733, 101.6078, 21.5, 38) t
    where r.id in ('00000000-0000-0000-0000-0000000431ea', '00000000-0000-0000-0000-0000000431eb',
                   '00000000-0000-0000-0000-0000000431ec', '00000000-0000-0000-0000-0000000431ed')
      and t = '{"fare": 50, "distance_km": 21.5, "duration_min": 38, "instant": false, "priced": false, "measured": false}'::jsonb),
  'Freight, an airport fare, myGiG and an operator''s booking keep their 50.00 and wait for the driver');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ea', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)$q$,
                       'DROP_CHANGE_FARE', 'a Freight ride''s drop-off moved at the card''s fare, under its own');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ea', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya',
                                  3.0733, 101.6078, 21.5, 38, 50)
    = '{"applied": false, "pending": true, "fare": 50}'::jsonb,
  'a Freight ride''s new drop-off waits for the driver at the fare it has');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431ea', true) = '{"accepted": true}'::jsonb,
  'the driver accepts the Freight ride''s new drop-off');
reset role;
select pg_temp.check((select drop_name = 'Sunway Pyramid' and ride_fare = 50 and fare = 50 and drop_change_count = 1
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431ea'),
  'the Freight ride goes to the new drop-off at the fare it had');

-- 19. The fare card's price (ride_card_fare) ---------------------------------------------------------
-- 9.5 km in 24 minutes, as the booking sheet quotes it (fare_tariff.dart).
select pg_temp.check(
  public.ride_card_fare(null, 'Testland 0341', null, null, null, 9.5, 24) = 22.00
  and public.ride_card_fare('No such service', 'testland 0341 ', 'Elsewhere', 'Anytown', null, 9.5, 24) = 22.00,
  'the country''s card for every service: 5.25 + 4.75 + 12.00, whatever the letters'' case');
select pg_temp.check(
  public.ride_card_fare('Test Van 0431', 'Testland 0341', null, null, null, 9.5, 24) = 44.00,
  'at the service''s multiplier (Cost per km 3.00 over 1.50): twice the card');
select pg_temp.check(
  public.ride_card_fare('Test Bike 0431', 'Testland 0341', null, null, null, 9.5, 24) = 5.75,
  'its type''s card beats the one for every service: (2.00 + 9.50) at half');
select pg_temp.check(
  public.ride_card_fare('Test Premium 0431', 'Testland 0341', null, null, null, 9.5, 24) = 27.00
  and public.ride_card_fare(' test premium 0431', 'Testland 0341', null, null, null, 9.5, 24) = 27.00,
  'the vehicle''s own card beats its type''s, and is its fare: 8.00 + 19.00, no multiplier on top');
select pg_temp.check(
  public.ride_card_fare(null, 'Testland 0341', 'Teststate 0431', 'Testcity 0431', null, 9.5, 24) = 26.00
  and public.ride_card_fare('Test Premium 0431', 'Testland 0341', 'Teststate 0431', 'Testcity 0431', 'Any', 9.5, 24) = 40.00
  and public.ride_card_fare(null, 'Testland 0341', 'Another state', 'Testcity 0431', null, 9.5, 24) = 22.00,
  'the city''s card decides inside the city (its minimum 25.00, plus the booking fee), and only there');
select pg_temp.check(
  public.ride_card_fare('Test Premium 0431', 'Nowhere 0431', null, null, null, 9.5, 24) = 33.30
  and public.ride_card_fare('Test Premium 0431', 'Nowhere 0431', null, null, null, 1, 1) = 12.00,
  'with no card, the service''s own rates: 28.50 + 4.80, and never under its minimum fare');
select pg_temp.check(
  public.ride_card_fare(null, 'Nowhere 0431', null, null, null, 9.5, 24) = 19.05
  and public.ride_card_fare('Test Teksi 0431', 'Nowhere 0431', null, null, null, 9.5, 24) = 22.86
  and public.ride_card_fare(null, 'Nowhere 0431', null, null, null, 0.8, 3) = 4.00
  and public.ride_card_fare(null, 'Nowhere 0431', null, null, null, -5, -5) = 4.00,
  'with neither, the built-in tariff: 4.00 flag fall + 43 x 0.35, a taxi at its multiplier');

-- 20. The admin's rules still decide (0341) ----------------------------------------------------------
-- "Auto-approve when it is cheaper" off: a cheaper change waits for the driver
-- even before the trip starts.
update public.app_settings set value = value || '{"autoApproveCheaper": false}' where key = 'drop_change_rules';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431ef', 3.1488, 101.7133, 1.6, 6) = '{"fare": 9.05, "instant": false}'::jsonb,
  'with auto-approve-when-cheaper off, a cheaper drop waits for the driver');
reset role;
-- One change a ride.
update public.app_settings set value = value || '{"autoApproveCheaper": true, "maxChangesPerRide": 1}'
 where key = 'drop_change_rules';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e3', 'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 20)$q$,
                       'drop_change_limit', 'a second change on a ride allowed one');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e3', 3.1177, 101.6774, 8.0, 20)$q$,
                       'drop_change_limit', 'a quote for a second change on a ride allowed one');
reset role;
-- Changes switched off.
update public.app_settings set value = value || '{"allow": false, "maxChangesPerRide": 2}'
 where key = 'drop_change_rules';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ef', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 9.5, 24, 22)$q$,
                       'drop_change_off', 'a change while changes are switched off');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431ef', 3.1302, 101.6712, 9.5, 24)$q$,
                       'drop_change_off', 'a quote while changes are switched off');
reset role;
update public.app_settings set value = value || '{"allow": true}' where key = 'drop_change_rules';

-- 21. Who may do what --------------------------------------------------------------------------------
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)', 'execute')
  and has_function_privilege('authenticated', 'public.ride_drop_change_quote(uuid, double precision, double precision, numeric, numeric)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_quote(uuid, double precision, double precision, numeric, numeric)', 'execute'),
  'the request and the quote are open to signed-in callers and not to anon');
select pg_temp.check(
  (select count(*) = 3 from pg_proc p
    where p.oid in ('public.ride_card_fare(text, text, text, text, text, numeric, numeric)'::regprocedure,
                    'public.ride_route_measured(double precision, double precision, double precision, double precision)'::regprocedure,
                    'public.ride_drop_change_terms(public.ride_requests, double precision, double precision, numeric, numeric)'::regprocedure)
      and not has_function_privilege('authenticated', p.oid, 'execute')
      and not has_function_privilege('anon', p.oid, 'execute')),
  'the pricing behind them is not for clients to call');
select pg_temp.check(
  (select count(*) = 5 from pg_proc p
    where p.oid in ('public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)'::regprocedure,
                    'public.ride_drop_change_quote(uuid, double precision, double precision, numeric, numeric)'::regprocedure,
                    'public.ride_card_fare(text, text, text, text, text, numeric, numeric)'::regprocedure,
                    'public.ride_route_measured(double precision, double precision, double precision, double precision)'::regprocedure,
                    'public.ride_drop_change_terms(public.ride_requests, double precision, double precision, numeric, numeric)'::regprocedure)
      and p.prosecdef and p.proconfig @> array['search_path=""']),
  'all five are security definer with an empty search_path');
-- The routes a change is priced on are the server's own: a signed-in caller
-- adds none and alters none.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused(
  $q$insert into public.fare_ai_responses (provider, origin_lat, origin_lng, dest_lat, dest_lng, success, distance_km, duration_min)
     values ('waze', 3.1579, 101.7116, 3.0733, 101.6078, true, 1, 2)$q$,
  'new row violates row-level security policy for table "fare_ai_responses"',
  'a signed-in caller adding a measured route');
reset role;

-- 22. The held change and the service are the server's (0437) ----------------------------------------
-- A participant may update their own ride row directly, but the drop_change_*
-- columns and the service can't be written that way: only the drop-change
-- RPCs, which run as the owner, do. The held change and the service a ride is
-- priced on are the server's.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
-- A client writing the held-change columns directly.
select pg_temp.refused($q$update public.ride_requests
                            set drop_change_fare = 1, drop_change_requested_at = now(),
                                drop_change_requested_by = 'rider', drop_change_name = 'Anywhere',
                                drop_change_lat = 3.1, drop_change_lng = 101.6
                          where id = '00000000-0000-0000-0000-0000000431ef'$q$,
                       'RIDE_DROP_CHANGE_SERVER_ONLY', 'a client writing the held-change columns directly');
select pg_temp.refused($q$update public.ride_requests set drop_change_count = 9
                          where id = '00000000-0000-0000-0000-0000000431ef'$q$,
                       'RIDE_DROP_CHANGE_SERVER_ONLY', 'a client writing the per-ride change count');
select pg_temp.refused($q$update public.ride_requests set drop_change_outcome = 'accepted', drop_change_outcome_by = 'auto'
                          where id = '00000000-0000-0000-0000-0000000431ef'$q$,
                       'RIDE_DROP_CHANGE_SERVER_ONLY', 'a client writing a change outcome');
-- A client changing the service.
select pg_temp.refused($q$update public.ride_requests set service = 'Test Bike 0431'
                          where id = '00000000-0000-0000-0000-0000000431ef'$q$,
                       'RIDE_SERVICE_LOCKED', 'a client changing the service a ride is priced on');
reset role;
select pg_temp.check((select service is not distinct from null and ride_fare = 19.25 and drop_change_count = 0
                         and drop_change_requested_at is null and drop_change_fare is null
                         and drop_change_outcome is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431ef'),
  'the refused writes changed nothing: no held change, the service and fare as booked');

-- The Change button still works: the RPC runs as the owner and passes the
-- guard, prices the change on the server's card and route, and the driver
-- accepts it.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ef', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'the Change button stages the held change through the guard, at the server''s fare');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431ef', true) = '{"accepted": true}'::jsonb,
  'the driver accepts it');
reset role;
select pg_temp.check((select drop_name = 'Sunway Pyramid' and ride_fare = 35 and drop_change_count = 1
                         and drop_change_requested_at is null and drop_change_outcome = 'accepted'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431ef'),
  'the ride goes to Sunway Pyramid at the server''s 35.00');

-- The guard is not a client's to call.
select pg_temp.check(
  not has_function_privilege('authenticated', 'public.ride_requests_guard_drop_change()', 'execute')
  and not has_function_privilege('anon', 'public.ride_requests_guard_drop_change()', 'execute'),
  'ride_requests_guard_drop_change is not open to clients');

rollback;

select 'drop_change_0341: all passed';
