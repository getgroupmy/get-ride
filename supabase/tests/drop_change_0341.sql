-- ============================================================================
-- Regression test for migration 0341: the mid-ride drop-off change (driver
-- check corrected in 0428, the fare priced by the server in 0431).
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
--   * The fare of a change is the server's (0431): the ride's fare card over
--     the route the server measured. The fare sent with the change is only
--     the fare the rider was shown, and a change is refused when the server's
--     fare is higher. A lower fare applies at once only when the trip got
--     shorter to match. With no route of the server's own, or on a ride the
--     fare card does not price, the fare stays and the driver decides.
--     ride_drop_change_quote says the same before the rider confirms.
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

-- The fare card the rides are priced on (0431), for a made-up country so no
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

-- Three rides under way, booked to Mid Valley at 20.00. Each carries the
-- driver's account id in partner_id, as a ride the app has taken does. They
-- were picked up at KLCC, in the made-up country.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  drop_name, drop_address, drop_lat, drop_lng, distance_km, duration_min,
                                  pickup_lat, pickup_lng, country) values
  ('00000000-0000-0000-0000-0000000341e1', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e2', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341'),
  ('00000000-0000-0000-0000-0000000341e3', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341')
on conflict (id) do nothing;

-- The routes the route service measured from KLCC a moment ago (0431), as it
-- logs every route the app asks it for: to Bangsar Village 9.5 km in 24
-- minutes (22.00 on the card), to Sunway Pyramid 21.5 km in 38 (35.00), to
-- Mid Valley 8.0 km in 20 (19.25) and to Pavilion 1.6 km in 6 (9.05).
insert into public.fare_ai_responses (provider, origin_lat, origin_lng, dest_lat, dest_lng, success,
                                      distance_km, duration_min) values
  ('waze', 3.1579, 101.7116, 3.1302, 101.6712, true, 9.5, 24),
  ('waze', 3.1579, 101.7116, 3.0733, 101.6078, true, 21.5, 38),
  ('waze', 3.1579, 101.7116, 3.1177, 101.6774, true, 8.0, 20),
  ('waze', 3.1579, 101.7116, 3.1488, 101.7133, true, 1.6, 6);

-- The rides of the 0431 sections, each booked like the three above unless it
-- says otherwise.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  drop_name, drop_address, drop_lat, drop_lng, distance_km, duration_min,
                                  pickup_lat, pickup_lng, country, whole_fare, stops, cargo_description,
                                  airport_fare, mygig, fare_mode) values
  ('00000000-0000-0000-0000-0000000431e1', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  ('00000000-0000-0000-0000-0000000431e2', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  ('00000000-0000-0000-0000-0000000431e3', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  ('00000000-0000-0000-0000-0000000431e4', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  -- Agreed at 30.00 and at 40.00: more than the card's 19.25 for the trip.
  ('00000000-0000-0000-0000-0000000431e5', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 30, 30, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  ('00000000-0000-0000-0000-0000000431e6', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 40, 40, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  ('00000000-0000-0000-0000-0000000431e7', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, null),
  -- Where fares are whole amounts.
  ('00000000-0000-0000-0000-0000000431e8', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', true, '[]', null, null, null, null),
  -- With a stop on the way.
  ('00000000-0000-0000-0000-0000000431e9', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false,
   '[{"name": "Pavilion", "address": "Jalan Bukit Bintang, Kuala Lumpur", "lat": 3.1488, "lng": 101.7133}]', null, null, null, null),
  -- Rides the fare card does not price, at 50.00: Freight, an airport fare,
  -- myGiG and an operator's booking.
  ('00000000-0000-0000-0000-0000000431ea', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', 'Boxes of books', null, null, null),
  ('00000000-0000-0000-0000-0000000431eb', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, '{"total": 50}', null, null),
  ('00000000-0000-0000-0000-0000000431ec', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, '{}', null),
  ('00000000-0000-0000-0000-0000000431ed', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 50, 50, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', false, '[]', null, null, null, 'fixed')
on conflict (id) do nothing;
-- And one still waiting for a driver.
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_name, drop_name, drop_lat, drop_lng,
                                  distance_km, duration_min, pickup_lat, pickup_lng, country) values
  ('00000000-0000-0000-0000-0000000431ee', '00000000-0000-0000-0000-0000000341a1', 'open', 20, 20, 'KLCC',
   'Mid Valley', 3.1177, 101.6774, 8.0, 20, 3.1579, 101.7116, 'Testland 0341')
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
select pg_temp.check((select count(*) = 3 from public.ride_requests
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
  'RM 2 more on a RM 20 ride is within the threshold: applied at once');
reset role;
select pg_temp.check((select drop_name = 'Bangsar Village' and drop_address = 'Jalan Telawi 1, Kuala Lumpur'
                         and drop_lat = 3.1302 and drop_lng = 101.6712
                         and distance_km = 9.5 and duration_min = 24
                         and ride_fare = 22 and fare = 20
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
  'RM 15 more is over the threshold: held for the driver');
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
                         and ride_fare = 20 and fare = 20
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
                         and ride_fare = 35 and fare = 20
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
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 20 and drop_change_count = 0
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
                         and ride_fare = 20 and fare = 20
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
                          or (id = '00000000-0000-0000-0000-0000000341e3' and ride_fare = 20 and drop_change_count = 0)),
  'and the rides are left as they were');

-- 7. Still for signed-in callers only, as 0341 granted it -------------------------------------------
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_resolve(uuid, boolean)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_resolve(uuid, boolean)', 'execute'),
  'ride_drop_change_resolve is open to signed-in callers and not to anon');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=""']
                        from pg_proc p
                       where p.oid = 'public.ride_drop_change_resolve(uuid, boolean)'::regprocedure),
  'ride_drop_change_resolve is security definer with an empty search_path');

-- ======================================================================================================
-- 0431: the fare of a change is the server's.
-- ======================================================================================================

-- 8. What a change would come to, before the rider confirms ------------------------------------------
-- The fare is the ride's fare card (5.25 + 0.50 a km + 0.50 a minute) over the
-- route the server measured. Asking changes nothing.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.1302, 101.6712, 9.5, 24) = '{"fare": 22, "instant": true}'::jsonb,
  'to Bangsar Village: 22.00, RM 2 more, applied at once');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.0733, 101.6078, 21.5, 38) = '{"fare": 35, "instant": false}'::jsonb,
  'to Sunway Pyramid: 35.00, RM 15 more, for the driver to accept');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.0733, 101.6078, 1, 2) = '{"fare": 35, "instant": false}'::jsonb,
  'the route is the one the server measured (21.5 km in 38 minutes), whatever distance and time are sent');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e1', 3.0733, 101.6078, null, null) = '{"fare": 35, "instant": false}'::jsonb,
  'and with none sent');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431ff', 3.1302, 101.6712, 9.5, 24)$q$,
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
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 20 and distance_km = 8.0 and duration_min = 20
                         and drop_change_count = 0 and drop_change_requested_at is null and drop_change_fare is null
                         and drop_change_outcome is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e1'),
  'asking changed nothing on the ride');

-- 9. The fare sent with a change is the fare the rider was shown --------------------------------------
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
                         and distance_km = 8.0 and duration_min = 20 and ride_fare = 20 and fare = 20
                         and drop_change_count = 0 and drop_change_requested_at is null
                         and drop_change_fare is null and drop_change_outcome is null),
  'the refused changes left both rides as booked, with nothing waiting');

-- Sent at the server's fare, or above it, the change goes on at the server's
-- fare. A lower fare for the trip the ride is making already is not a
-- shorter trip: the driver decides. So does a dearer one over the threshold.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e1', 'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 19.25)
    = '{"applied": false, "pending": true, "fare": 19.25}'::jsonb,
  'a lower fare for the same drop-off waits for the driver');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e2', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 1, 2, 99)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'a drop-off 21.5 km away is held at the server''s fare, whatever fare and distance are sent');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 20 and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
                         and drop_change_fare = 19.25 and drop_change_distance_km = 8.0 and drop_change_duration_min = 20
                         and drop_change_outcome is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e1'),
  'the ride keeps its fare of 20.00 while the driver is asked about 19.25');
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 20 and distance_km = 8.0 and duration_min = 20
                         and drop_change_name = 'Sunway Pyramid' and drop_change_fare = 35
                         and drop_change_distance_km = 21.5 and drop_change_duration_min = 38
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e2'),
  'the held change carries the server''s fare and the route it measured, not the 1 km and the 99.00 sent');
-- The driver turns the lower fare down: the ride stays at 20.00.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431e1', false) = '{"accepted": false}'::jsonb,
  'the driver declines the lower fare for the same drop-off');
reset role;
select pg_temp.check((select ride_fare = 20 and drop_name = 'Mid Valley' and drop_change_count = 0
                         and drop_change_outcome = 'declined' and drop_change_outcome_by = 'partner'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e1'),
  'and the fare is still 20.00');

-- 10. Without a route of the server's own the fare stays --------------------------------------------
-- To Bukit Bintang the route service has measured nothing that counts: one
-- answer is 20 minutes old, one is a phone's own, one went through a stop
-- and one failed. There is nothing to price the change on, so the fare stays
-- as it is, whatever distance and time are sent, and the driver is asked
-- about the new drop-off.
insert into public.fare_ai_responses (provider, origin_lat, origin_lng, dest_lat, dest_lng, success,
                                      distance_km, duration_min, extra, created_at) values
  ('waze', 3.1579, 101.7116, 3.1466, 101.7108, true, 2.4, 9, null, now() - interval '20 minutes'),
  ('apple_device', 3.1579, 101.7116, 3.1466, 101.7108, true, 2.4, 9, null, now()),
  ('waze', 3.1579, 101.7116, 3.1466, 101.7108, true, 4.0, 15, '{"stops": [{"lat": 3.14, "lng": 101.69}]}', now()),
  ('waze', 3.1579, 101.7116, 3.1466, 101.7108, false, 2.4, 9, null, now());
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e3', 3.1466, 101.7108, 0.2, 1) = '{"fare": 20, "instant": false}'::jsonb,
  'the quote without a measured route: the fare the ride has, for the driver to accept');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e3', 'Bukit Bintang', 'Jalan Sultan Ismail, Kuala Lumpur', 3.1466, 101.7108, 0.2, 1, 6)$q$,
                       'DROP_CHANGE_FARE', 'a drop-off with no measured route, sent at a lower fare');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e3', 'Bukit Bintang', 'Jalan Sultan Ismail, Kuala Lumpur', 3.1466, 101.7108, 0.2, 1, 20)
    = '{"applied": false, "pending": true, "fare": 20}'::jsonb,
  'without a route of the server''s own the change waits for the driver, at the fare the ride has');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 20 and distance_km = 8.0 and duration_min = 20
                         and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_name = 'Bukit Bintang'
                         and drop_change_distance_km = 0.2 and drop_change_duration_min = 1
                         and drop_change_fare = 20
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e3'),
  'the fare asked of the driver is the 20.00 the ride has: the 0.2 km sent prices nothing');
-- The rider takes the request back; the route service then measures the
-- route (2.4 km in 9 minutes, 10.95) and the same change applies at once: a
-- lower fare for a trip that is shorter to match.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_withdraw('00000000-0000-0000-0000-0000000431e3') = '{"withdrawn": true}'::jsonb,
  'the rider withdraws the held change');
reset role;
insert into public.fare_ai_responses (provider, origin_lat, origin_lng, dest_lat, dest_lng, success,
                                      distance_km, duration_min) values
  ('gmap', 3.1579, 101.7116, 3.1466, 101.7108, true, 2.4, 9);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e3', 3.1466, 101.7108, 0.2, 1) = '{"fare": 10.95, "instant": true}'::jsonb,
  'the quote once the route is measured: the card over it, applied at once');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e3', 'Bukit Bintang', 'Jalan Sultan Ismail, Kuala Lumpur', 3.1466, 101.7108, 0.2, 1, 20)
    = '{"applied": true, "pending": false, "fare": 10.95}'::jsonb,
  'with the route measured by the server the change applies at once, at the server''s fare');
reset role;
select pg_temp.check((select drop_name = 'Bukit Bintang' and drop_lat = 3.1466 and drop_lng = 101.7108
                         and distance_km = 2.4 and duration_min = 9 and ride_fare = 10.95 and fare = 20
                         and drop_change_count = 1 and drop_change_requested_at is null
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'auto'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e3'),
  'the ride goes to Bukit Bintang over the measured 2.4 km at 10.95, not the 0.2 km sent');

-- 11. A lower fare applies at once when the trip got shorter to match ---------------------------------
-- Pavilion is 1.03 km from the pickup in a straight line, Mid Valley 5.87:
-- the trip is under a fifth as long, and the fare falls from 20.00 to 9.05.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e4', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur', 3.1488, 101.7133, 1.6, 6, 9.05)
    = '{"applied": true, "pending": false, "fare": 9.05}'::jsonb,
  'a nearer drop-off at a lower fare applies at once');
-- Where fares are whole amounts the fare is rounded up, as a booking is.
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e8', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur', 3.1488, 101.7133, 1.6, 6, 10)
    = '{"applied": true, "pending": false, "fare": 10}'::jsonb,
  'where fares are whole amounts 9.05 is 10');
reset role;
select pg_temp.check((select count(*) = 2 from public.ride_requests
                       where ((id = '00000000-0000-0000-0000-0000000431e4' and ride_fare = 9.05) or (id = '00000000-0000-0000-0000-0000000431e8' and ride_fare = 10))
                         and drop_name = 'Pavilion' and distance_km = 1.6 and duration_min = 6 and fare = 20
                         and drop_change_count = 1 and drop_change_outcome = 'accepted'
                         and drop_change_outcome_by = 'auto'),
  'both rides go to Pavilion at the lower fare');

-- 12. A lower fare for a trip that is not shorter to match waits for the driver -----------------------
-- A ride agreed at 30.00, above its card's 19.25. Bangsar Village is 5.44 km
-- from the pickup against Mid Valley's 5.87, so the trip is 7 % shorter;
-- the card's 22.00 there is 27 % less. And a ride agreed at 40.00 moved to
-- Sunway Pyramid: a longer trip at a lower fare (35.00).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e5', 3.1302, 101.6712, 9.5, 24) = '{"fare": 22, "instant": false}'::jsonb,
  'the quote says the driver will be asked');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e5', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 9.5, 24, 22)
    = '{"applied": false, "pending": true, "fare": 22}'::jsonb,
  'a fare that falls further than the trip shortens waits for the driver');
-- (Sent a cent under the server's fare, as an app's own rounding may be: it
-- goes on, at the server's fare.)
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e6', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 34.99)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'a lower fare for a longer trip waits for the driver');
reset role;
select pg_temp.check((select count(*) = 2 from public.ride_requests
                       where ((id = '00000000-0000-0000-0000-0000000431e5' and ride_fare = 30 and drop_change_fare = 22)
                           or (id = '00000000-0000-0000-0000-0000000431e6' and ride_fare = 40 and drop_change_fare = 35))
                         and drop_name = 'Mid Valley' and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_outcome is null),
  'both rides keep the fare agreed while the driver is asked');
-- The driver may take it: the answer is theirs.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431e5', true) = '{"accepted": true}'::jsonb,
  'the driver accepts the lower fare');
reset role;
select pg_temp.check((select drop_name = 'Bangsar Village' and ride_fare = 22 and fare = 30
                         and distance_km = 9.5 and duration_min = 24 and drop_change_count = 1
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'partner'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e5'),
  'accepted by the driver, the ride goes to Bangsar Village at 22.00');

-- 13. The admin's rules still decide (0341) ----------------------------------------------------------
-- "Auto-approve when it is cheaper" off: a lower fare waits for the driver
-- even for a trip that is shorter to match.
update public.app_settings set value = value || '{"autoApproveCheaper": false}' where key = 'drop_change_rules';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e7', 'Pavilion', 'Jalan Bukit Bintang, Kuala Lumpur', 3.1488, 101.7133, 1.6, 6, 9.05)
    = '{"applied": false, "pending": true, "fare": 9.05}'::jsonb,
  'with auto-approve when cheaper off, the nearer drop-off waits for the driver');
reset role;
-- One change a ride: a ride that has had one takes no more, and says so
-- before the rider confirms too.
update public.app_settings set value = value || '{"autoApproveCheaper": true, "maxChangesPerRide": 1}'
 where key = 'drop_change_rules';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e4', 'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20, 20)$q$,
                       'drop_change_limit', 'a second change on a ride allowed one');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e4', 3.1177, 101.6774, 8.0, 20)$q$,
                       'drop_change_limit', 'a quote for a second change on a ride allowed one');
reset role;
-- Changes switched off.
update public.app_settings set value = value || '{"allow": false, "maxChangesPerRide": 2}'
 where key = 'drop_change_rules';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e9', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 9.5, 24, 22)$q$,
                       'drop_change_off', 'a change while changes are switched off');
select pg_temp.refused($q$select public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431e9', 3.1302, 101.6712, 9.5, 24)$q$,
                       'drop_change_off', 'a quote while changes are switched off');
reset role;
update public.app_settings set value = value || '{"allow": true}' where key = 'drop_change_rules';

-- 14. A ride with stops ------------------------------------------------------------------------------
-- Its route goes through the stop, so the route measured straight from the
-- pickup to Bangsar Village is not its route: the fare stays, and the driver
-- is asked. (The same change on a ride without stops was priced at 22.00 and
-- applied at once, section 1.)
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431e9', 'Bangsar Village', 'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 10.5, 25, 23)
    = '{"applied": false, "pending": true, "fare": 20}'::jsonb,
  'a change on a ride with a stop waits for the driver, at the fare the ride has');
reset role;
select pg_temp.check((select ride_fare = 20 and drop_name = 'Mid Valley' and drop_change_count = 0
                         and drop_change_fare = 20 and drop_change_distance_km = 10.5
                         and drop_change_duration_min = 25 and drop_change_requested_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431e9'),
  'it is kept with the 10.5 km and 25 minutes sent for the trip through the stop');

-- 15. A ride the fare card does not price keeps its fare ---------------------------------------------
-- Freight, an airport fare, myGiG and an operator's booking are priced
-- another way. Their fare stays, and the driver is asked about the new
-- drop-off.
select pg_temp.check(
  (select count(*) = 4
     from public.ride_requests r,
          lateral public.ride_drop_change_terms(r, 3.0733, 101.6078, 21.5, 38) t
    where r.id in ('00000000-0000-0000-0000-0000000431ea', '00000000-0000-0000-0000-0000000431eb', '00000000-0000-0000-0000-0000000431ec', '00000000-0000-0000-0000-0000000431ed')
      and t = '{"fare": 50, "distance_km": 21.5, "duration_min": 38, "instant": false, "priced": false, "measured": false}'::jsonb),
  'Freight, an airport fare, myGiG and an operator''s booking keep their fare of 50.00 and wait for the driver');
select pg_temp.check(
  (select t = '{"fare": 35, "distance_km": 21.5, "duration_min": 38, "instant": false, "priced": true, "measured": true}'::jsonb
     from public.ride_requests r,
          lateral public.ride_drop_change_terms(r, 3.0733, 101.6078, 1, 2) t
    where r.id = '00000000-0000-0000-0000-0000000431e2'),
  'where a plain ride is priced on the card over the measured route');
select pg_temp.check(
  (select t = '{"fare": 20, "distance_km": 1, "duration_min": 2, "instant": false, "priced": true, "measured": false}'::jsonb
     from public.ride_requests r,
          lateral public.ride_drop_change_terms(r, 2.9264, 101.6964, 1, 2) t
    where r.id = '00000000-0000-0000-0000-0000000431e2'),
  'and keeps its fare to a place the server has no route to');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ea', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)$q$,
                       'DROP_CHANGE_FARE', 'a Freight ride''s drop-off moved at the card''s fare, under its own');
select pg_temp.check(
  public.ride_drop_change_quote('00000000-0000-0000-0000-0000000431ea', 3.0733, 101.6078, 21.5, 38) = '{"fare": 50, "instant": false}'::jsonb,
  'the quote for a Freight ride: the fare it has, for the driver to accept');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000431ea', 'Sunway Pyramid', 'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 50)
    = '{"applied": false, "pending": true, "fare": 50}'::jsonb,
  'a Freight ride''s new drop-off waits for the driver at the fare it has');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000431ea', true) = '{"accepted": true}'::jsonb,
  'the driver accepts the Freight ride''s new drop-off');
reset role;
select pg_temp.check((select drop_name = 'Sunway Pyramid' and ride_fare = 50 and fare = 50
                         and distance_km = 21.5 and duration_min = 38 and drop_change_count = 1
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'partner'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000431ea'),
  'the Freight ride goes to the new drop-off at the fare it had');

-- 16. The fare card's price (ride_card_fare) ---------------------------------------------------------
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

-- 17. Who may do what --------------------------------------------------------------------------------
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
update public.fare_ai_responses set distance_km = 1, duration_min = 2
 where origin_lat = 3.1579 and dest_lat = 3.0733;
reset role;
select pg_temp.check(
  (select count(*) = 1 from public.fare_ai_responses
    where origin_lat = 3.1579 and origin_lng = 101.7116 and dest_lat = 3.0733 and dest_lng = 101.6078
      and distance_km = 21.5 and duration_min = 38),
  'and the measured route to Sunway Pyramid is as the route service wrote it');

-- 18. The held change and the service are the server's (0431) ----------------------------------------
-- A participant may update their own ride row directly, but the drop_change_*
-- columns and the service can't be written that way: only the drop-change
-- RPCs, which run as the owner, do. The held change and the service a ride is
-- priced on are the server's.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  drop_name, drop_address, drop_lat, drop_lng, distance_km, duration_min,
                                  pickup_lat, pickup_lng, country, stops) values
  ('00000000-0000-0000-0000-0000000431ef', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20,
   3.1579, 101.7116, 'Testland 0341', '[]')
on conflict (id) do nothing;
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
select pg_temp.check((select service is not distinct from null and ride_fare = 20 and drop_change_count = 0
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
