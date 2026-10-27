-- ============================================================================
-- Regression test for migration 0307: City to City bookings.
--   * on insert: the service on at the pickup, the distance, how far ahead,
--     the fare within the range (or the fixed fare), the payment methods,
--     three trips at most; what the server sets whatever is sent;
--   * who sees an open request: drivers with the years and permits (0306)
--     and in reach (service states, else the country); the rider; admins;
--   * offers: eligibility, the range, the leave window, one open offer per
--     driver; the rider declines, raises the fare, accepts (atomic: the
--     others declined, the commission locked as it is booked);
--   * the cancel fee: free while no driver is picked and until the free
--     hours, then the amount from the GET wallet to the driver less the
--     commission, 'due' when the wallet is short, off when switched off;
--     an admin's cancel is free;
--   * the driver's steps, the commission charged once at completion, the
--     rating, expiry, contact, and the grants.
-- The cancel fee and the fare checks are also in
-- test/city_to_city_booking_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/city_to_city_bookings_0307.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000307a1'),  -- admin, EDIT on City to City
  ('00000000-0000-0000-0000-0000000307a3'),  -- admin, READ on City to City
  ('00000000-0000-0000-0000-0000000307b1'),  -- driver: 10 years, in reach by state
  ('00000000-0000-0000-0000-0000000307b2'),  -- driver: 1 year, in reach
  ('00000000-0000-0000-0000-0000000307b3'),  -- driver: 10 years, another state only
  ('00000000-0000-0000-0000-0000000307b4'),  -- driver: 10 years, in reach by country
  ('00000000-0000-0000-0000-0000000307c1'),  -- rider
  ('00000000-0000-0000-0000-0000000307c2')   -- another rider
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test 307' from auth.users
 where id::text like '00000000-0000-0000-0000-0000000307%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000307a1', 'admin-settings-city-to-city', 'edit'),
  ('00000000-0000-0000-0000-0000000307a3', 'admin-settings-city-to-city', 'read')
on conflict do nothing;

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
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- What [p_sql] does as [p_user]: 'ok' with the rows it touched, or the error.
create or replace function pg_temp.run_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare n integer;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
-- How many rows [p_sql] (a select) gives [p_user].
create or replace function pg_temp.count_as(p_user uuid, p_sql text) returns integer language plpgsql as $$
declare n integer;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute 'select count(*) from (' || p_sql || ') x' into n;
  perform pg_temp.as_server();
  return n;
end $$;
-- A value [p_sql] (a select of one value) gives [p_user], as text.
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return v;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;

-- ---- Places, the service, the rules ---------------------------------------------------------------
-- Semenanjung 307: Kuala Lumpur 307 (a federal territory), Perak 307 (Ipoh
-- 307), Pinang 307, Pahang 307 (City to City Off).
create or replace function pg_temp.kl() returns jsonb language sql as $$
  select '{"country": "Semenanjung 307", "state": "Kuala Lumpur 307", "city": "Kuala Lumpur 307"}'::jsonb;
$$;
create or replace function pg_temp.ipoh() returns jsonb language sql as $$
  select '{"country": "Semenanjung 307", "state": "Perak 307", "city": "Ipoh 307"}'::jsonb;
$$;
create or replace function pg_temp.pinang() returns jsonb language sql as $$
  select '{"country": "Semenanjung 307", "state": "Pinang 307", "city": "George Town 307"}'::jsonb;
$$;
create or replace function pg_temp.kuantan() returns jsonb language sql as $$
  select '{"country": "Semenanjung 307", "state": "Pahang 307", "city": "Kuantan 307"}'::jsonb;
$$;
create or replace function pg_temp.svc() returns text language sql as $$
  select id::text from public.settings_entries where category = 'vehicle-services' and values->>'name' = 'City to City'
   order by position limit 1;
$$;
update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
insert into public.countries (name, values) values ('Semenanjung 307', '{}');
insert into public.states (country, name, values) values
  ('Semenanjung 307', 'Pahang 307', jsonb_build_object('subServices', jsonb_build_object(pg_temp.svc(), false)));
update public.city_to_city_settings
   set cancel_fee_on = true, cancel_fee_amount = 20, cancel_free_hours = 24, pay_in_app = true, pay_cash = true,
       min_years_on = true, min_years = 3, default_book_ahead_days = 14
 where id = 1;
-- No fare card: the service's own rates (0.45 / km, 0.15 / min, at least 50):
-- 205 km and 160 min is 116.25.
insert into public.c2c_route_rules (id, from_places, to_places, fare_mode, add_on_amount, range_mode, range_low,
                                    range_high, book_ahead_days, position) values
  ('00000000-0000-0000-0000-0000000307f1',
   '[{"level": "city", "country": "Semenanjung 307", "state": "Kuala Lumpur 307", "city": "Kuala Lumpur 307"}]',
   '[{"level": "state", "country": "Semenanjung 307", "state": "Perak 307"}]', 'card', 20, 'set', 130, 150, 14, 1);
insert into public.c2c_route_rules (id, from_places, to_places, fare_mode, fixed_fare, range_mode, range_percent,
                                    book_ahead_days, position) values
  ('00000000-0000-0000-0000-0000000307f2',
   '[{"level": "city", "country": "Semenanjung 307", "state": "Kuala Lumpur 307", "city": "Kuala Lumpur 307"}]',
   '[{"level": "state", "country": "Semenanjung 307", "state": "Pinang 307"}]', 'fixed', 190, 'auto', 8, 30, 2);
insert into public.commission_service_rates (service_id, service_name, rate) values (pg_temp.svc(), 'City to City', 0.12);

-- ---- Drivers ---------------------------------------------------------------------------------------
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states,
                             rating, total_rides, make, model, plate) values
  ('00000000-0000-0000-0000-0000000307e1', '00000000-0000-0000-0000-0000000307b1', 'Driver Satu 307', '+60100030701',
   'approved', '{eHailing}', '{Semenanjung 307}', '{Semenanjung 307|Kuala Lumpur 307}', 4.9, 312, 'Proton', 'X50', 'VKA 3071'),
  ('00000000-0000-0000-0000-0000000307e2', '00000000-0000-0000-0000-0000000307b2', 'Driver Dua 307', '+60100030702',
   'approved', '{eHailing}', '{Semenanjung 307}', '{Semenanjung 307|Kuala Lumpur 307}', 4.5, 10, null, null, null),
  ('00000000-0000-0000-0000-0000000307e3', '00000000-0000-0000-0000-0000000307b3', 'Driver Tiga 307', '+60100030703',
   'approved', '{eHailing}', '{Semenanjung 307}', '{Semenanjung 307|Perak 307}', 4.7, 50, null, null, null),
  ('00000000-0000-0000-0000-0000000307e4', '00000000-0000-0000-0000-0000000307b4', 'Driver Empat 307', '+60100030704',
   'approved', '{eHailing}', '{Semenanjung 307}', '{}', 4.8, 198, 'Honda', 'City', 'WQB 3074');
update public.partners set driving_since = current_date - interval '10 years'
 where id in ('00000000-0000-0000-0000-0000000307e1', '00000000-0000-0000-0000-0000000307e3',
              '00000000-0000-0000-0000-0000000307e4');
update public.partners set driving_since = current_date - interval '1 year' where id = '00000000-0000-0000-0000-0000000307e2';
update public.profiles set phone = '+60100030799' where id = '00000000-0000-0000-0000-0000000307c1';

-- 0306's c2c_driver_check answers as before, and still only the driver or an admin.
select pg_temp.check((public.c2c_driver_check('00000000-0000-0000-0000-0000000307b1', pg_temp.kl(), pg_temp.ipoh())->>'ok')::boolean,
  'c2c_driver_check: 10 years is enough');
select pg_temp.check(not (public.c2c_driver_check('00000000-0000-0000-0000-0000000307b2', pg_temp.kl(), pg_temp.ipoh())->>'ok')::boolean,
  'c2c_driver_check: 1 year is not');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c1',
    $q$select public.c2c_driver_check('00000000-0000-0000-0000-0000000307b1', '{}', '{}')::text$q$) = 'not_authorized',
  'c2c_driver_check: still refused to anyone but the driver or an admin');

-- ---- 1. On insert ----------------------------------------------------------------------------------
-- A trip from Kuala Lumpur 307 (3.15, 101.70) as [p_user]; the fields given
-- in [p] over these defaults.
create or replace function pg_temp.book(p_user uuid, p jsonb default '{}') returns text language plpgsql as $$
declare
  d jsonb := jsonb_build_object(
    'pickup_name', '12 Jalan Contoh', 'pickup_lat', 3.15, 'pickup_lng', 101.70, 'pickup_place', pg_temp.kl(),
    'drop_name', '21 Jalan Sampel', 'drop_lat', 4.60, 'drop_lng', 101.08, 'drop_place', pg_temp.ipoh(),
    'distance_km', 205, 'duration_min', 160, 'leave_at', now() + interval '3 days', 'passengers', 2,
    'luggage', 'suitcases', 'fare', 140, 'payment', 'cash') || p;
begin
  return pg_temp.run_as(p_user, format(
    $f$insert into public.c2c_bookings (rider_id, pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
         drop_lng, drop_place, distance_km, duration_min, leave_at, flexible, passengers, luggage, fare, payment, status,
         driver_id) values (%L, %L, %s, %s, %L, %L, %s, %s, %L, %s, %s, %L, true, %s, %L, %s, %L, %L, %L)$f$,
    coalesce(d->>'rider_id', p_user::text), d->>'pickup_name', d->>'pickup_lat', d->>'pickup_lng', d->'pickup_place',
    d->>'drop_name', d->>'drop_lat', d->>'drop_lng', d->'drop_place', d->>'distance_km', d->>'duration_min',
    d->>'leave_at', d->>'passengers', d->>'luggage', d->>'fare', d->>'payment', coalesce(d->>'status', 'open'),
    d->>'driver_id'));
end $$;
create or replace function pg_temp.last_of(p_user uuid) returns uuid language sql as $$
  select id from public.c2c_bookings where rider_id = p_user order by created_at desc, ref desc limit 1;
$$;

update public.settings_entries set values = values || '{"status": false}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1') = 'C2C_NOT_AVAILABLE',
  'the service switched off: not available');
update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1',
    jsonb_build_object('pickup_lat', 3.80, 'pickup_lng', 103.30, 'pickup_place', pg_temp.kuantan())) = 'C2C_NOT_AVAILABLE',
  'a pickup in Pahang 307 (Off there): not available');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1', '{"distance_km": 20}') = 'C2C_BAD_TRIP',
  '20 km between points 175 km apart: refused');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1', '{"fare": 125}') = 'C2C_FARE_OUT_OF_RANGE',
  'below the range: refused');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1', '{"fare": 151}') = 'C2C_FARE_OUT_OF_RANGE',
  'above the range: refused');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1',
    jsonb_build_object('leave_at', now() + interval '30 minutes')) = 'C2C_TOO_SOON',
  'leaving in 30 minutes: too soon');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1',
    jsonb_build_object('leave_at', now() + interval '20 days')) = 'C2C_TOO_FAR_AHEAD',
  '20 days ahead on a 14-day route: refused');
update public.city_to_city_settings set pay_cash = false where id = 1;
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1') = 'C2C_PAYMENT_NOT_ALLOWED',
  'cash switched off: refused');
update public.city_to_city_settings set pay_cash = true where id = 1;
-- The fixed fare to Pinang 307 (George Town 307 at 5.41, 100.33).
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1',
    jsonb_build_object('drop_lat', 5.41, 'drop_lng', 100.33, 'drop_place', pg_temp.pinang(), 'distance_km', 355,
                       'fare', 185)) = 'C2C_FARE_OUT_OF_RANGE',
  'a fixed route: another fare is refused');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1',
    jsonb_build_object('drop_lat', 5.41, 'drop_lng', 100.33, 'drop_place', pg_temp.pinang(), 'distance_km', 355,
                       'fare', 190, 'leave_at', now() + interval '25 days')) = 'ok 1',
  'a fixed route: its fare, 25 days ahead (30 on that rule)');
select pg_temp.check((select quote->>'fareMode' = 'fixed' and rule_id = '00000000-0000-0000-0000-0000000307f2'
                        from public.c2c_bookings where id = pg_temp.last_of('00000000-0000-0000-0000-0000000307c1')),
  'the fixed route''s rule and quote are kept');

-- Sent as another rider, booked, with a driver: kept to what the server sets.
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1',
    jsonb_build_object('rider_id', '00000000-0000-0000-0000-0000000307c2', 'status', 'booked',
                       'driver_id', '00000000-0000-0000-0000-0000000307b1')) = 'ok 1',
  'a trip within the range is taken');
select pg_temp.check((select rider_id = '00000000-0000-0000-0000-0000000307c1' and status = 'open' and driver_id is null
                             and ref like 'CC-%' and expires_at = leave_at and currency = 'MYR'
                             and (quote->>'low')::numeric = 130 and (quote->>'high')::numeric = 150
                             and (quote->>'suggested')::numeric = 136.25
                             and rule_id = '00000000-0000-0000-0000-0000000307f1'
                             and pickup_place->>'city' = 'Kuala Lumpur 307' and not quote ? 'pickup'
                        from public.c2c_bookings where id = pg_temp.last_of('00000000-0000-0000-0000-0000000307c1')),
  'the rider is the caller, the request open, the quote and the rule kept, until the time to leave');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1', '{"fare": 150}') = 'ok 1',
  'a third trip');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c1', '{"fare": 130}') = 'C2C_TOO_MANY',
  'a fourth trip under way: refused');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1',
    $q$update public.c2c_bookings set fare = 1$q$) like 'permission denied%',
  'the rider changes nothing directly');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1',
    $q$delete from public.c2c_bookings$q$) like 'permission denied%',
  'nor removes a trip');

-- The trip to Ipoh 307 at RM 140 (T1) and the one at RM 150 (T2).
create temp table t (k text primary key, id uuid);
insert into t values
  ('t1', (select id from public.c2c_bookings where rider_id = '00000000-0000-0000-0000-0000000307c1' and fare = 140)),
  ('t2', (select id from public.c2c_bookings where rider_id = '00000000-0000-0000-0000-0000000307c1' and fare = 150)),
  ('fixed', (select id from public.c2c_bookings where rider_id = '00000000-0000-0000-0000-0000000307c1' and fare = 190));
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;

-- ---- 2. Who sees an open request -------------------------------------------------------------------
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307c1',
    'select 1 from public.c2c_bookings') = 3, 'the rider sees their three');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307c2',
    'select 1 from public.c2c_bookings') = 0, 'another rider sees none');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b1',
    'select 1 from public.c2c_bookings') = 3, 'a driver with the years, in reach by state, sees them');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b4',
    'select 1 from public.c2c_bookings') = 3, 'a driver in reach by country sees them');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b2',
    'select 1 from public.c2c_bookings') = 0, 'a driver short of the years sees none');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b3',
    'select 1 from public.c2c_bookings') = 0, 'a driver whose area is another state sees none');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307a3',
    'select 1 from public.c2c_bookings') = 3, 'an admin sees them');

-- ---- 3. Offers -------------------------------------------------------------------------------------
create or replace function pg_temp.offer(p_driver uuid, p_k text, p_price numeric, p_leave interval default '0')
returns text language plpgsql as $$
begin
  return pg_temp.run_as(p_driver, format('select public.c2c_make_offer(%L, %s, (select leave_at from public.c2c_bookings where id = %L) + %L::interval)',
                                         pg_temp.id(p_k), p_price, pg_temp.id(p_k), p_leave));
end $$;
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b2', 't1', 140) = 'C2C_DRIVER_NOT_ELIGIBLE',
  'a driver short of the years can''t offer');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b3', 't1', 140) = 'C2C_NOT_FOR_YOU',
  'a driver out of reach can''t offer');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307c1', 't1', 140) = 'C2C_OWN_TRIP',
  'nor the rider on their own trip');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 't1', 160) = 'C2C_FARE_OUT_OF_RANGE',
  'an offer above the range is refused');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 't1', 140, '45 minutes') = 'C2C_LEAVE_OUT_OF_WINDOW',
  'leaving 45 minutes later than a flexible rider''s time: refused');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 'fixed', 200) = 'C2C_FARE_OUT_OF_RANGE',
  'a fixed route: only its fare');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 't1', 140, '15 minutes') = 'ok 1',
  'an offer in range, 15 minutes later');
select pg_temp.check((select status = 'offered' from public.c2c_bookings where id = pg_temp.id('t1')), 'the request is offered');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 't1', 145, '15 minutes') = 'ok 1',
  'offering again');
select pg_temp.check((select count(*) = 1 and min(price) = 145 and min(driver_name) = 'Driver Satu 307'
                             and min(car) = 'Proton X50' and min(plate) = 'VKA 3071' and min(driver_trips) = 312
                        from public.c2c_offers where booking_id = pg_temp.id('t1')),
  'offering again changes the one offer; the driver as the rider sees them');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b4', 't1', 150) = 'ok 1', 'a second driver offers');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b4',
    format($q$insert into public.c2c_offers (booking_id, driver_id, price, leave_at) values (%L, %L, 1, now())$q$,
           pg_temp.id('t1'), '00000000-0000-0000-0000-0000000307b4')) like 'permission denied%',
  'offers are made through c2c_make_offer only');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307c1', 'select 1 from public.c2c_offers') = 2,
  'the rider sees both offers');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b1', 'select 1 from public.c2c_offers') = 1,
  'a driver sees their own');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307c2', 'select 1 from public.c2c_offers') = 0,
  'another rider sees none');

create or replace function pg_temp.offer_of(p_driver uuid, p_k text) returns uuid language sql as $$
  select id from public.c2c_offers where booking_id = pg_temp.id(p_k) and driver_id = p_driver
   order by created_at desc, (status = 'open') desc limit 1;
$$;
-- Declined, and offered again.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format('select public.c2c_decline_offer(%L)',
    pg_temp.offer_of('00000000-0000-0000-0000-0000000307b4', 't1'))) = 'ok 1', 'the rider declines one');
select pg_temp.check((select status = 'declined' and declined_reason = 'rider' from public.c2c_offers
                       where id = pg_temp.offer_of('00000000-0000-0000-0000-0000000307b4', 't1'))
                     and (select status = 'offered' from public.c2c_bookings where id = pg_temp.id('t1')),
  'declined by the rider; another is still open');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b4', 't1', 148, '-10 minutes') = 'ok 1',
  'the declined driver offers again');

-- The fare: raised within the range while no driver is picked.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1',
    format('select public.c2c_set_fare(%L, 155)', pg_temp.id('t2'))) = 'C2C_FARE_OUT_OF_RANGE', 'raised past the range: refused');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1',
    format('select public.c2c_set_fare(%L, 145)', pg_temp.id('t2'))) = 'ok 1', 'lowered within it');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1',
    format('select public.c2c_set_fare(%L, 200)', pg_temp.id('fixed'))) = 'C2C_FARE_OUT_OF_RANGE', 'a fixed fare stays');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c2',
    format('select public.c2c_set_fare(%L, 140)', pg_temp.id('t2'))) = 'not_authorized', 'only by its rider');

-- Accepting: atomic.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c2', format('select public.c2c_accept_offer(%L)',
    pg_temp.offer_of('00000000-0000-0000-0000-0000000307b1', 't1'))) = 'not_authorized',
  'another rider can''t accept it');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format('select public.c2c_accept_offer(%L)',
    pg_temp.offer_of('00000000-0000-0000-0000-0000000307b1', 't1'))) = 'ok 1',
  'the rider accepts');
select pg_temp.check((select status = 'booked' and driver_id = '00000000-0000-0000-0000-0000000307b1' and agreed_fare = 145
                             and booked_at is not null and driver_leave_at = leave_at + interval '15 minutes'
                             and commission_rate = 0.12 and commission_base_rate = 0.12 and commission_locked_at is not null
                        from public.c2c_bookings where id = pg_temp.id('t1')),
  'booked with the driver and the agreed fare; the service''s 12 % is locked');
select pg_temp.check((select status = 'accepted' from public.c2c_offers
                       where id = pg_temp.offer_of('00000000-0000-0000-0000-0000000307b1', 't1'))
                     and (select status = 'declined' and declined_reason = 'taken' from public.c2c_offers
                           where booking_id = pg_temp.id('t1') and driver_id = '00000000-0000-0000-0000-0000000307b4'
                             and price = 148),
  'the offer accepted, the other open one declined');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format('select public.c2c_accept_offer(%L)',
    pg_temp.offer_of('00000000-0000-0000-0000-0000000307b4', 't1'))) = 'C2C_NOT_OPEN',
  'nothing more to accept');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b4',
    format('select 1 from public.c2c_bookings where id = %L', pg_temp.id('t1'))) = 0,
  'once booked, other drivers no longer see it');
select pg_temp.check(pg_temp.count_as('00000000-0000-0000-0000-0000000307b1',
    format('select 1 from public.c2c_bookings where id = %L', pg_temp.id('t1'))) = 1,
  'the booked driver does');
-- The same driver on another trip at the same time: busy.
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 't2', 145) = 'ok 1', 'an offer on T2');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format('select public.c2c_accept_offer(%L)',
    pg_temp.offer_of('00000000-0000-0000-0000-0000000307b1', 't2'))) = 'C2C_DRIVER_BUSY',
  'a driver already booked at that time can''t be booked again');

-- Contact once booked.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c1',
    format($q$select public.c2c_contact(%L)->>'phone'$q$, pg_temp.id('t1'))) = '+60100030701',
  'the rider gets the driver''s phone');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307b1',
    format($q$select public.c2c_contact(%L)->>'phone'$q$, pg_temp.id('t1'))) = '+60100030799',
  'the driver gets the rider''s');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c2',
    format($q$select public.c2c_contact(%L)::text$q$, pg_temp.id('t1'))) = 'not_authorized',
  'nobody else');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c1',
    format($q$select coalesce(public.c2c_contact(%L)::text, 'none')$q$, pg_temp.id('t2'))) = 'none',
  'no driver yet: nothing');

-- ---- 6. The driver's steps, the commission -----------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b4', format($q$select public.c2c_driver_progress(%L, 'on_trip')$q$,
    pg_temp.id('t1'))) = 'not_authorized', 'another driver can''t move it');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b1', format($q$select public.c2c_driver_progress(%L, 'completed')$q$,
    pg_temp.id('t1'))) = 'C2C_BAD_STEP', 'not straight to completed');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b1', format($q$select public.c2c_driver_progress(%L, 'driver_arriving')$q$,
    pg_temp.id('t1'))) = 'ok 1', 'on the way');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format($q$select public.c2c_rate_driver(%L, 5)$q$,
    pg_temp.id('t1'))) = 'C2C_NOT_DONE', 'no rating before the trip');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b1', format($q$select public.c2c_driver_progress(%L, 'on_trip')$q$,
    pg_temp.id('t1'))) = 'ok 1', 'on the trip');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format('select public.c2c_cancel(%L)',
    pg_temp.id('t1'))) = 'C2C_ON_TRIP', 'the rider can''t cancel a trip under way');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b1', format($q$select public.c2c_driver_progress(%L, 'completed')$q$,
    pg_temp.id('t1'))) = 'ok 1', 'completed');
select pg_temp.check((select status = 'completed' and commission_amount = 17.40 and commission_charged_at is not null
                        from public.c2c_bookings where id = pg_temp.id('t1'))
                     and (select count(*) = 1 and sum(amount) = -17.40 from public.wallet_transactions
                           where user_id = '00000000-0000-0000-0000-0000000307b1' and wallet_type = 'get_credit'
                             and kind = 'commission'),
  'the locked 12 % of RM 145 taken from the driver''s GET credit');
-- Charged once.
select public.c2c_charge_commission(pg_temp.id('t1'));
select pg_temp.check((select count(*) = 1 from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000307b1' and kind = 'commission'),
  'the commission is charged once');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format($q$select public.c2c_rate_driver(%L, 6)$q$,
    pg_temp.id('t1'))) = 'C2C_BAD_RATING', '6 stars: refused');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format($q$select public.c2c_rate_driver(%L, 5, 'Smooth trip')$q$,
    pg_temp.id('t1'))) = 'ok 1', 'rated');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format($q$select public.c2c_rate_driver(%L, 4)$q$,
    pg_temp.id('t1'))) = 'C2C_RATED', 'once');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c1', format('select public.c2c_cancel(%L)',
    pg_temp.id('t1'))) = 'C2C_NOT_OPEN', 'a completed trip can''t be cancelled');

-- ---- 5. Cancelling -------------------------------------------------------------------------------------
select pg_temp.check(public.c2c_cancel_fee(now() + interval '25 hours', now()) = 0
                     and public.c2c_cancel_fee(now() + interval '23 hours', now()) = 20
                     and public.c2c_cancel_fee(now() + interval '24 hours', now()) = 20,
  'the fee: free until 24 hours before, then RM 20');
-- T2: open, with an offer: free, the offer declined.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c1',
    format($q$select public.c2c_cancel(%L, 'Plans changed')::text$q$, pg_temp.id('t2'))) like '%"fee": 0%',
  'an open request: free');
select pg_temp.check((select status = 'cancelled' and cancelled_by = 'rider' and cancel_reason = 'Plans changed'
                             and cancel_fee = 0 and cancel_fee_status = 'none'
                        from public.c2c_bookings where id = pg_temp.id('t2'))
                     and not exists (select 1 from public.c2c_offers where booking_id = pg_temp.id('t2') and status = 'open'),
  'cancelled; its offers declined');

-- A booked trip leaving in 5 hours, the rider's GET wallet RM 50: RM 20 charged.
create or replace function pg_temp.booked(p_rider uuid, p_leave interval) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.check(pg_temp.book(p_rider, jsonb_build_object('leave_at', now() + p_leave)) = 'ok 1', 'booked: inserted');
  v := pg_temp.last_of(p_rider);
  perform pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307b4',
    format('select public.c2c_make_offer(%L, 140)', v)) = 'ok 1', 'booked: offered');
  perform pg_temp.check(pg_temp.run_as(p_rider, format('select public.c2c_accept_offer(%L)',
    (select id from public.c2c_offers where booking_id = v and status = 'open'))) = 'ok 1', 'booked: accepted');
  return v;
end $$;
insert into public.wallets (user_id, wallet_type, balance) values ('00000000-0000-0000-0000-0000000307c2', 'get_wallet', 50);
insert into t values ('late', pg_temp.booked('00000000-0000-0000-0000-0000000307c2', '5 hours'));
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c2',
    format($q$select public.c2c_cancel(%L)->>'feeStatus'$q$, pg_temp.id('late'))) = 'charged',
  'within 24 hours: the fee is charged');
select pg_temp.check((select balance = 30 from public.wallets
                       where user_id = '00000000-0000-0000-0000-0000000307c2' and wallet_type = 'get_wallet')
                     and (select sum(amount) = 17.60 from public.wallet_transactions
                           where user_id = '00000000-0000-0000-0000-0000000307b4' and kind = 'cancellation_fee')
                     and (select cancel_fee = 20 from public.c2c_bookings where id = pg_temp.id('late')),
  'RM 20 from the rider; RM 17.60 to the driver (less 12 %)');
-- Short: due.
update public.wallets set balance = 5 where user_id = '00000000-0000-0000-0000-0000000307c2' and wallet_type = 'get_wallet';
insert into t values ('short', pg_temp.booked('00000000-0000-0000-0000-0000000307c2', '5 hours'));
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c2',
    format($q$select public.c2c_cancel(%L)->>'feeStatus'$q$, pg_temp.id('short'))) = 'due',
  'a short wallet: the fee is due');
-- Days ahead: free.
insert into t values ('early', pg_temp.booked('00000000-0000-0000-0000-0000000307c2', '3 days'));
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c2',
    format($q$select public.c2c_cancel(%L)->>'fee'$q$, pg_temp.id('early'))) = '0',
  'three days ahead: free');
-- The fee switched off.
update public.city_to_city_settings set cancel_fee_on = false where id = 1;
insert into t values ('off', pg_temp.booked('00000000-0000-0000-0000-0000000307c2', '5 hours'));
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307c2',
    format($q$select public.c2c_cancel(%L)->>'fee'$q$, pg_temp.id('off'))) = '0',
  'the fee off: free');
update public.city_to_city_settings set cancel_fee_on = true where id = 1;
-- An admin: free; without EDIT: refused.
insert into t values ('admin', pg_temp.booked('00000000-0000-0000-0000-0000000307c2', '5 hours'));
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307a3', format('select public.c2c_cancel(%L)',
    pg_temp.id('admin'))) = 'not_authorized', 'an admin who only reads can''t cancel');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000307a1',
    format($q$select public.c2c_cancel(%L)->>'fee'$q$, pg_temp.id('admin'))) = '0',
  'an admin with EDIT cancels, free');
select pg_temp.check((select cancelled_by = 'admin' from public.c2c_bookings where id = pg_temp.id('admin')),
  'cancelled by the admin');

-- ---- 7. Expiry -----------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000307c2') = 'ok 1', 'one more request');
insert into t values ('old', pg_temp.last_of('00000000-0000-0000-0000-0000000307c2'));
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b4', 'old', 140) = 'ok 1', 'with an offer');
update public.c2c_bookings set expires_at = now() - interval '1 minute' where id = pg_temp.id('old');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000307c2', format('select public.c2c_accept_offer(%L)',
    (select id from public.c2c_offers where booking_id = pg_temp.id('old')))) = 'C2C_EXPIRED',
  'past its time: can''t be accepted');
select pg_temp.check(pg_temp.offer('00000000-0000-0000-0000-0000000307b1', 'old', 140) = 'C2C_NOT_OPEN',
  'nor offered on');
select pg_temp.check(public.c2c_expire_due() >= 1, 'the job closes it');
select pg_temp.check((select status = 'expired' and expired_at is not null from public.c2c_bookings where id = pg_temp.id('old'))
                     and (select status = 'expired' from public.c2c_offers where booking_id = pg_temp.id('old')),
  'expired, with its offers');

-- ---- 8. Grants and live -----------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.c2c_accept_offer(uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'public.c2c_charge_commission(uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'public.c2c_expire_due()', 'execute')
                     and not has_function_privilege('authenticated',
                           'public.c2c_driver_eligibility(uuid, jsonb, jsonb, text[])', 'execute')
                     and not has_function_privilege('authenticated',
                           'public.c2c_fee_take(public.c2c_bookings, numeric)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_cancel(uuid, text)', 'execute')
                     and not has_table_privilege('anon', 'public.c2c_bookings', 'select')
                     and not has_table_privilege('authenticated', 'public.c2c_bookings', 'update'),
  'the grants');
select pg_temp.check((select count(*) = 2 from pg_publication_tables
                       where pubname = 'supabase_realtime' and tablename in ('c2c_bookings', 'c2c_offers')),
  'both tables are live');

select 'city_to_city_bookings_0307: all passed';
rollback;
