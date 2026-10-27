-- ============================================================================
-- Regression test for migration 0308: City to City for drivers.
--   * c2c_driver_requests: open requests in reach, soonest first, the
--     rider's own left out; whether the driver may take each and what is
--     missing; a locked one without its addresses or points; the commission
--     now; the rider as "Rider S." with their rating; the driver's own open
--     offer; the header (approved, service area, years);
--   * c2c_driver_cancel: only the booked driver, before the time to leave
--     and never on the trip; the request back to open, the driver's offer
--     withdrawn, the commission lock cleared; offered and booked again;
--   * c2c_set_driving_since: once, only while no date is known; a date in
--     the past; the driver's own writes to the column refused;
--   * one rating: city ride ratings and City to City stars averaged onto
--     partners.rating by rate_ride and c2c_rate_driver;
--   * the grants.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/city_to_city_driver_0308.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000308b1'),  -- driver: 10 years, in reach by state
  ('00000000-0000-0000-0000-0000000308b2'),  -- driver: 1 year, in reach
  ('00000000-0000-0000-0000-0000000308b3'),  -- driver: 10 years, another state only
  ('00000000-0000-0000-0000-0000000308b4'),  -- driver: no date known, in reach by country
  ('00000000-0000-0000-0000-0000000308c1'),  -- rider
  ('00000000-0000-0000-0000-0000000308c2')   -- another rider
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test 308' from auth.users
 where id::text like '00000000-0000-0000-0000-0000000308%'
on conflict do nothing;
update public.profiles set name = 'Rider  Satu Contoh', rider_rating = 4.6, phone = '+60100030899'
 where id = '00000000-0000-0000-0000-0000000308c1';

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
-- The Requests list as [p_user].
create or replace function pg_temp.feed(p_user uuid) returns jsonb language plpgsql as $$
begin
  return pg_temp.value_as(p_user, 'select public.c2c_driver_requests()::text')::jsonb;
end $$;
-- One request of [p_user]'s list.
create or replace function pg_temp.req(p_user uuid, p_id uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.feed(p_user)->'requests') e where e->>'id' = p_id::text;
$$;

-- ---- Places, the service, the rules, permits ----------------------------------------------------------
create or replace function pg_temp.kl() returns jsonb language sql as $$
  select '{"country": "Semenanjung 308", "state": "Kuala Lumpur 308", "city": "Kuala Lumpur 308", "suburb": "Ampang 308"}'::jsonb;
$$;
create or replace function pg_temp.ipoh() returns jsonb language sql as $$
  select '{"country": "Semenanjung 308", "state": "Perak 308", "city": "Ipoh 308"}'::jsonb;
$$;
create or replace function pg_temp.seberang() returns jsonb language sql as $$
  select '{"country": "Seberang 308", "state": "Pusat 308", "city": "Bandar 308"}'::jsonb;
$$;
update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
insert into public.countries (name, values) values ('Semenanjung 308', '{}');
update public.city_to_city_settings
   set cancel_fee_on = true, cancel_fee_amount = 20, cancel_free_hours = 24, pay_in_app = true, pay_cash = true,
       min_years_on = true, min_years = 3, default_book_ahead_days = 14
 where id = 1;
insert into public.c2c_route_rules (id, from_places, to_places, fare_mode, add_on_amount, range_mode, range_low,
                                    range_high, book_ahead_days, position) values
  ('00000000-0000-0000-0000-0000000308f1',
   '[{"level": "city", "country": "Semenanjung 308", "state": "Kuala Lumpur 308", "city": "Kuala Lumpur 308"}]',
   '[{"level": "state", "country": "Semenanjung 308", "state": "Perak 308"}]', 'card', 20, 'set', 130, 150, 14, 1);
insert into public.commission_service_rates (service_id, service_name, rate)
select id::text, 'City to City', 0.12 from public.settings_entries
 where category = 'vehicle-services' and values->>'name' = 'City to City'
on conflict (service_id) do update set rate = 0.12, active = true;
-- Into Seberang 308 a vehicle permit is needed, which no driver here holds.
insert into public.permit_types (id, country, key, name, short_name, applies_to) values
  ('00000000-0000-0000-0000-0000000308a1', 'Seberang 308', 'cross-308', 'Permit Seberang 308', 'PS 308', 'vehicle');
insert into public.c2c_country_permits (country, permit_type_id, position) values
  ('Seberang 308', '00000000-0000-0000-0000-0000000308a1', 0);

-- ---- Drivers ---------------------------------------------------------------------------------------------
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states,
                             rating, total_rides, make, model, plate) values
  ('00000000-0000-0000-0000-0000000308e1', '00000000-0000-0000-0000-0000000308b1', 'Driver Satu 308', '+60100030801',
   'approved', '{eHailing}', '{Semenanjung 308}', '{Semenanjung 308|Kuala Lumpur 308}', 4.9, 312, 'Proton', 'X50', 'VKA 3081'),
  ('00000000-0000-0000-0000-0000000308e2', '00000000-0000-0000-0000-0000000308b2', 'Driver Dua 308', '+60100030802',
   'approved', '{eHailing}', '{Semenanjung 308}', '{Semenanjung 308|Kuala Lumpur 308}', 4.5, 10, null, null, null),
  ('00000000-0000-0000-0000-0000000308e3', '00000000-0000-0000-0000-0000000308b3', 'Driver Tiga 308', '+60100030803',
   'approved', '{eHailing}', '{Semenanjung 308}', '{Semenanjung 308|Perak 308}', 4.7, 50, null, null, null),
  ('00000000-0000-0000-0000-0000000308e4', '00000000-0000-0000-0000-0000000308b4', 'Driver Empat 308', '+60100030804',
   'approved', '{eHailing}', '{Semenanjung 308}', '{}', 0, 0, null, null, null);
update public.partners set driving_since = current_date - interval '10 years'
 where id in ('00000000-0000-0000-0000-0000000308e1', '00000000-0000-0000-0000-0000000308e3');
update public.partners set driving_since = current_date - interval '1 year' where id = '00000000-0000-0000-0000-0000000308e2';

-- ---- Two requests from Kuala Lumpur 308 -----------------------------------------------------------------
-- T1 to Ipoh 308 (RM 140, in 3 days); T2 to Seberang 308 (its suggested fare, in 2 days).
insert into public.c2c_bookings (rider_id, pickup_name, pickup_address, pickup_lat, pickup_lng, pickup_place, drop_name,
                                 drop_lat, drop_lng, drop_place, distance_km, duration_min, leave_at, passengers,
                                 luggage, fare, payment)
values ('00000000-0000-0000-0000-0000000308c1', '12 Jalan Contoh', '12 Jalan Contoh, Ampang 308', 3.15, 101.70, pg_temp.kl(),
        '21 Jalan Sampel', 4.60, 101.08, pg_temp.ipoh(), 205, 160, now() + interval '3 days', 2, 'suitcases', 140, 'cash');
insert into public.c2c_bookings (rider_id, pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
                                 drop_lng, drop_place, distance_km, duration_min, leave_at, passengers, luggage, fare, payment)
select '00000000-0000-0000-0000-0000000308c1', '12 Jalan Contoh', 3.15, 101.70, pg_temp.kl(), '9 Jalan Seberang', 1.35,
       103.80, pg_temp.seberang(), 350, 300, now() + interval '2 days', 1, 'small',
       (public.c2c_quote(3.15, 101.70, pg_temp.kl(), pg_temp.seberang(), 350, 300, 'City to City')->>'suggested')::numeric,
       'cash';
create temp table t (k text primary key, id uuid);
insert into t values
  ('t1', (select id from public.c2c_bookings where rider_id = '00000000-0000-0000-0000-0000000308c1'
                                               and drop_place->>'city' = 'Ipoh 308')),
  ('t2', (select id from public.c2c_bookings where rider_id = '00000000-0000-0000-0000-0000000308c1'
                                               and drop_place->>'city' = 'Bandar 308'));
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;

-- ---- 1. The Requests list ---------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as(null, 'select public.c2c_driver_requests()::text') = 'not_authorized',
  'requests: signed out, refused');
select pg_temp.check((select (f->>'approved')::boolean and (f->>'hasArea')::boolean and (f->>'years')::int = 10
                             and not (f->>'canSetDrivingSince')::boolean
                             and jsonb_array_length(f->'requests') = 2
                             and f->'requests'->0->>'id' = pg_temp.id('t2')::text
                        from pg_temp.feed('00000000-0000-0000-0000-0000000308b1') f),
  'requests: the header; both requests in reach, the sooner first');
select pg_temp.check((select (r->'eligibility'->>'ok')::boolean and r->>'pickup_name' = '12 Jalan Contoh'
                             and r->>'pickup_address' = '12 Jalan Contoh, Ampang 308'
                             and (r->>'pickup_lat')::numeric = 3.15
                             and (r->>'commission_rate_now')::numeric = 0.12
                             and r->>'rider_name' = 'Rider S.' and (r->>'rider_rating')::numeric = 4.6
                             and r->'my_offer' = 'null'::jsonb and not r ? 'rider_id' and not r ? 'commission_rate'
                             and (r->'quote'->>'low')::numeric = 130
                        from pg_temp.req('00000000-0000-0000-0000-0000000308b1', pg_temp.id('t1')) r),
  'requests: one the driver may take, in full, with the commission now and the rider as "Rider S."');
select pg_temp.check((select not (r->'eligibility'->>'ok')::boolean
                             and (r->'eligibility'->>'experienceOk')::boolean
                             and r->'eligibility'->'needs'->0->>'name' = 'Permit Seberang 308'
                             and r->>'pickup_name' = 'Ampang 308, Kuala Lumpur 308'
                             and r->>'drop_name' = 'Bandar 308'
                             and r->'pickup_address' = 'null'::jsonb and r->'pickup_lat' = 'null'::jsonb
                             and r->'drop_lat' = 'null'::jsonb and r->'commission_rate_now' = 'null'::jsonb
                        from pg_temp.req('00000000-0000-0000-0000-0000000308b1', pg_temp.id('t2')) r),
  'requests: one needing a permit, locked, the areas only');
select pg_temp.check((select not (r->'eligibility'->>'experienceOk')::boolean and (r->'eligibility'->>'minYears')::int = 3
                             and (r->'eligibility'->>'years')::int = 1 and r->'pickup_lat' = 'null'::jsonb
                        from pg_temp.req('00000000-0000-0000-0000-0000000308b2', pg_temp.id('t1')) r),
  'requests: 1 year of 3: locked, with the years');
select pg_temp.check(jsonb_array_length(pg_temp.feed('00000000-0000-0000-0000-0000000308b3')->'requests') = 0,
  'requests: a driver serving another state sees none');
select pg_temp.check((select jsonb_array_length(f->'requests') = 0 and not (f->>'approved')::boolean
                             and not (f->>'canSetDrivingSince')::boolean
                        from pg_temp.feed('00000000-0000-0000-0000-0000000308c1') f),
  'requests: the rider (no partner) sees none, not even their own');
select pg_temp.check((select jsonb_array_length(f->'requests') = 2 and (f->>'canSetDrivingSince')::boolean
                             and f->'years' = 'null'::jsonb
                        from pg_temp.feed('00000000-0000-0000-0000-0000000308b4') f),
  'requests: in reach by country; no date known, so the driver may give one');

select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_make_offer(%L, 145, null)', pg_temp.id('t1'))) = 'ok 1', 'driver 1 offers RM 145');
select pg_temp.check((select (r->'my_offer'->>'price')::numeric = 145 and r->>'status' = 'offered'
                        from pg_temp.req('00000000-0000-0000-0000-0000000308b1', pg_temp.id('t1')) r),
  'requests: the driver''s own open offer');
select pg_temp.check((select r->'my_offer' = 'null'::jsonb
                        from pg_temp.req('00000000-0000-0000-0000-0000000308b4', pg_temp.id('t1')) r),
  'requests: not another driver''s offer');

-- ---- 3. Driving since ---------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    $q$update public.partners set driving_since = date '2000-01-01' where auth_user_id = auth.uid()$q$)
    = 'PARTNERS_PROTECTED_COLUMN:driving_since',
  'driving since: the driver''s own table write is refused');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    $q$update public.partners set phone = '+60100030814' where auth_user_id = auth.uid()$q$) = 'ok 1',
  'driving since: other writes of the driver''s go on as before');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_set_driving_since(%L)::text', current_date + 1)) = 'C2C_BAD_DATE',
  'driving since: not in the future');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_set_driving_since(%L)::text', current_date - interval '6 years')) =
    (current_date - interval '6 years')::date::text,
  'driving since: set once');
select pg_temp.check((select driving_since = (current_date - interval '6 years')::date from public.partners
                       where id = '00000000-0000-0000-0000-0000000308e4'), 'driving since: kept');
select pg_temp.check((select (f->>'years')::int = 6 and not (f->>'canSetDrivingSince')::boolean
                        from pg_temp.feed('00000000-0000-0000-0000-0000000308b4') f),
  'driving since: the list counts it, and asks no more');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_set_driving_since(%L)::text', current_date - interval '20 years')) = 'C2C_DRIVING_SINCE_SET',
  'driving since: not changed by the driver again');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_set_driving_since(%L)::text', current_date - interval '20 years')) = 'C2C_DRIVING_SINCE_SET',
  'driving since: not by a driver whose date is known');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308c1',
    format('select public.c2c_set_driving_since(%L)::text', current_date - interval '20 years')) = 'not_authorized',
  'driving since: not by someone with no partner');

-- ---- 2. The driver gives a trip up ---------------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c1',
    format('select public.c2c_accept_offer(%L)', (select id from public.c2c_offers
                                                   where booking_id = pg_temp.id('t1') and status = 'open'))) = 'ok 1',
  'the rider books driver 1');
select pg_temp.check((select status = 'booked' and commission_locked_at is not null and commission_rate = 0.12
                        from public.c2c_bookings where id = pg_temp.id('t1')), 'booked, commission locked');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b2',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('t1'))) = 'not_authorized',
  'cancel: not by another driver');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c1',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('t1'))) = 'not_authorized',
  'cancel: not by the rider (c2c_cancel is theirs)');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_driver_progress(%L, %L)', pg_temp.id('t1'), 'driver_arriving')) = 'ok 1',
  'driver 1 on the way');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_driver_cancel(%L, %L)', pg_temp.id('t1'), '  Car broke down  ')) = 'ok 1',
  'cancel: the booked driver, on the way, before the time to leave');
select pg_temp.check((select status = 'open' and driver_id is null and offer_id is null and agreed_fare is null
                             and driver_leave_at is null and booked_at is null and arriving_at is null
                             and commission_locked_at is null and commission_rate is null
                             and driver_dropped_at is not null and driver_drop_reason = 'Car broke down'
                             and cancelled_at is null and cancel_fee is null and expires_at = leave_at
                        from public.c2c_bookings where id = pg_temp.id('t1')),
  'cancel: back to open as before an offer was picked, no fee, why kept');
select pg_temp.check((select status = 'withdrawn' from public.c2c_offers
                       where booking_id = pg_temp.id('t1') and driver_id = '00000000-0000-0000-0000-0000000308b1'),
  'cancel: the driver''s offer withdrawn');
select pg_temp.check((select r->>'status' = 'open' and r->'my_offer' = 'null'::jsonb
                        from pg_temp.req('00000000-0000-0000-0000-0000000308b4', pg_temp.id('t1')) r),
  'cancel: drivers in reach see it again');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_make_offer(%L, 140, null)', pg_temp.id('t1'))) = 'ok 1', 'driver 4 offers');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c1',
    format('select public.c2c_accept_offer(%L)', (select id from public.c2c_offers
                                                   where booking_id = pg_temp.id('t1') and status = 'open'))) = 'ok 1',
  'the rider books driver 4');
select pg_temp.check((select status = 'booked' and driver_id = '00000000-0000-0000-0000-0000000308b4'
                             and commission_locked_at is not null and agreed_fare = 140
                        from public.c2c_bookings where id = pg_temp.id('t1')), 'booked again, the lock taken again');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_driver_progress(%L, %L)', pg_temp.id('t1'), 'on_trip')) = 'ok 1', 'picked up');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('t1'))) = 'C2C_ON_TRIP',
  'cancel: not once the rider is on board');

-- A booked trip whose time to leave has passed.
insert into public.c2c_bookings (rider_id, pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
                                 drop_lng, drop_place, distance_km, duration_min, leave_at, passengers, luggage, fare, payment)
values ('00000000-0000-0000-0000-0000000308c2', '1 Jalan Lain', 3.15, 101.70, pg_temp.kl(), '2 Jalan Lain', 4.60, 101.08,
        pg_temp.ipoh(), 205, 160, now() + interval '2 hours', 1, 'small', 135, 'cash');
insert into t values ('t3', (select id from public.c2c_bookings where rider_id = '00000000-0000-0000-0000-0000000308c2'));
update public.c2c_bookings set status = 'booked', driver_id = '00000000-0000-0000-0000-0000000308b1', agreed_fare = 135,
                                booked_at = now(), leave_at = now() - interval '5 minutes'
 where id = pg_temp.id('t3');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('t3'))) = 'C2C_TOO_LATE',
  'cancel: not after the time to leave');
update public.c2c_bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin' where id = pg_temp.id('t3');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('t3'))) = 'C2C_NOT_OPEN',
  'cancel: not once ended');

-- ---- 4. One rating ---------------------------------------------------------------------------------------------
insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, currency, completed_at)
values ('00000000-0000-0000-0000-0000000308d1', '00000000-0000-0000-0000-0000000308c2',
        '00000000-0000-0000-0000-0000000308b4', 'completed', 'Car', 20, 'MYR', now());
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308c2',
    $q$select public.rate_ride('00000000-0000-0000-0000-0000000308d1', 4)->>'ratings'$q$) = '1',
  'rating: a city ride rated 4');
select pg_temp.check((select rating = 4 from public.partners where id = '00000000-0000-0000-0000-0000000308e4'),
  'rating: 4 on the partner');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_driver_progress(%L, %L)', pg_temp.id('t1'), 'completed')) = 'ok 1', 'trip completed');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c1',
    format('select public.c2c_rate_driver(%L, 5)', pg_temp.id('t1'))) = 'ok 1', 'rating: the City to City trip rated 5');
select pg_temp.check((select rating = 4.5 from public.partners where id = '00000000-0000-0000-0000-0000000308e4'),
  'rating: both count, 4.5 on the partner');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308c2',
    $q$select (public.rate_ride('00000000-0000-0000-0000-0000000308d1', 5))::text$q$)::jsonb
    @> '{"partner_rating": 5, "ratings": 2}'::jsonb,
  'rating: rating the city ride again keeps the City to City stars in the average');
select pg_temp.check((select rating = 4.9 from public.partners where id = '00000000-0000-0000-0000-0000000308e1'),
  'rating: a driver with no ratings keeps theirs');

-- ---- 5. Chat in the app -----------------------------------------------------------------------------------
-- T5: rider 2 books driver 1.
insert into public.c2c_bookings (rider_id, pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
                                 drop_lng, drop_place, distance_km, duration_min, leave_at, passengers, luggage, fare, payment)
values ('00000000-0000-0000-0000-0000000308c2', '5 Jalan Bual', 3.15, 101.70, pg_temp.kl(), '6 Jalan Bual', 4.60, 101.08,
        pg_temp.ipoh(), 205, 160, now() + interval '4 days', 1, 'small', 140, 'cash');
insert into t values ('t5', (select id from public.c2c_bookings where pickup_name = '5 Jalan Bual'));
create or replace function pg_temp.say(p_user uuid, p_role text, p_body text, p_booking uuid default null,
                                       p_extra text default '') returns text language sql as $$
  select pg_temp.run_as(p_user, format(
    'insert into public.ride_messages (c2c_booking_id, sender_role, type, body%s) values (%L, %L, %L, %L%s)',
    case when p_extra = '' then '' else ', request_id' end, coalesce(p_booking, pg_temp.id('t5')), p_role, 'text', p_body,
    case when p_extra = '' then '' else ', ' || quote_literal(p_extra) end));
$$;
create or replace function pg_temp.seen(p_user uuid, p_booking uuid default null) returns integer language sql as $$
  select pg_temp.value_as(p_user, format('select count(*) from public.ride_messages where c2c_booking_id = %L',
                                         coalesce(p_booking, pg_temp.id('t5'))))::integer;
$$;

select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308c2', 'rider', 'Hello') like 'new row violates%',
  'chat: no messages before a driver is booked');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_make_offer(%L, 140, null)', pg_temp.id('t5'))) = 'ok 1', 'driver 1 offers on T5');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    format('select public.c2c_accept_offer(%L)', (select id from public.c2c_offers
                                                   where booking_id = pg_temp.id('t5') and status = 'open'))) = 'ok 1',
  'rider 2 books driver 1');
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308c2', 'rider', '  At the lobby  ') = 'ok 1',
  'chat: the rider writes to the booked driver');
select pg_temp.check((select body = 'At the lobby' and status = 'sent' and request_id is null
                        from public.ride_messages where c2c_booking_id = pg_temp.id('t5')),
  'chat: trimmed, sent, no ride');
select pg_temp.check((select count(*) = 1 and bool_and(kind = 'ride_message' and title = 'Test 308'
                                                        and data->>'type' = 'ride_message'
                                                        and data->>'c2c_booking_id' = pg_temp.id('t5')::text
                                                        and data->>'role' = 'partner' and not data ? 'request_id'
                                                        and request_id is null)
                        from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000308b1' and event_id like 'msg:%'),
  'chat: the driver is pushed through the outbox, with the booking');
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308b1', 'partner', 'On my way soon') = 'ok 1',
  'chat: the booked driver answers');
select pg_temp.check((select bool_and(title = 'Driver Satu 308' and data->>'role' = 'rider')
                        from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000308c2' and event_id like 'msg:%'),
  'chat: the rider is pushed, named by the driver''s partner name');
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308c2', 'partner', 'Pretending') like 'new row violates%',
  'chat: the rider can''t write as the driver');
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308b2', 'partner', 'Hi') like 'new row violates%',
  'chat: another driver can''t write');
select pg_temp.check(pg_temp.seen('00000000-0000-0000-0000-0000000308b2') = 0
                     and pg_temp.seen('00000000-0000-0000-0000-0000000308c1') = 0,
  'chat: another driver or rider reads nothing');
select pg_temp.check(pg_temp.seen('00000000-0000-0000-0000-0000000308c2') = 2
                     and pg_temp.seen('00000000-0000-0000-0000-0000000308b1') = 2,
  'chat: both sides read the thread');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    format('insert into public.ride_messages (request_id, c2c_booking_id, sender_role, type, body) values (%L, %L, %L, %L, %L)',
           '00000000-0000-0000-0000-0000000308d1', pg_temp.id('t5'), 'rider', 'text', 'Both')) not like 'ok%',
  'chat: a message is in one thread only');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    format('update public.ride_messages set status = %L where c2c_booking_id = %L and sender_role = %L',
           'read', pg_temp.id('t5'), 'rider')) like '%only the receiver%',
  'chat: the sender can''t tick their own message');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('update public.ride_messages set status = %L where c2c_booking_id = %L and sender_role = %L',
           'delivered', pg_temp.id('t5'), 'rider')) = 'ok 1',
  'chat: the driver ticks it delivered');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('update public.ride_messages set body = %L where c2c_booking_id = %L', 'x', pg_temp.id('t5')))
    like 'permission denied%', 'chat: nothing but the tick changes');
-- Photos: in the booking's folder, while it takes messages.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    format('insert into public.ride_messages (c2c_booking_id, sender_role, type, media_path) values (%L, %L, %L, %L)',
           pg_temp.id('t5'), 'rider', 'image', pg_temp.id('t5') || '/image-1.jpg')) = 'ok 1',
  'chat: a photo in the booking''s folder');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    format('insert into public.ride_messages (c2c_booking_id, sender_role, type, media_path) values (%L, %L, %L, %L)',
           pg_temp.id('t5'), 'rider', 'image', pg_temp.id('t1') || '/image-1.jpg')) not like 'ok%',
  'chat: not a photo in another folder');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.ride_chat_media_allowed(%L, true)::text', pg_temp.id('t5') || '/a.jpg')) = 'true'
  and pg_temp.value_as('00000000-0000-0000-0000-0000000308c2',
    format('select public.ride_chat_media_allowed(%L, true)::text', pg_temp.id('t5') || '/a.jpg')) = 'true'
  and pg_temp.value_as('00000000-0000-0000-0000-0000000308b2',
    format('select public.ride_chat_media_allowed(%L, false)::text', pg_temp.id('t5') || '/a.jpg')) = 'false',
  'chat files: the booking''s two sides, nobody else');

-- Driver 1 gives the trip up; driver 4 is booked after.
alter table public.ride_messages disable trigger trg_ride_messages_guard_update;
update public.ride_messages set created_at = created_at - interval '1 minute' where c2c_booking_id = pg_temp.id('t5');
alter table public.ride_messages enable trigger trg_ride_messages_guard_update;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b1',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('t5'))) = 'ok 1', 'driver 1 gives T5 up');
select pg_temp.check(pg_temp.seen('00000000-0000-0000-0000-0000000308b1') = 0,
  'chat: the driver who gave it up no longer reads it');
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308c2', 'rider', 'Anyone?') like 'new row violates%',
  'chat: closed while no driver is booked');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308b4',
    format('select public.c2c_make_offer(%L, 140, null)', pg_temp.id('t5'))) = 'ok 1', 'driver 4 offers on T5');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    format('select public.c2c_accept_offer(%L)', (select id from public.c2c_offers
                                                   where booking_id = pg_temp.id('t5') and status = 'open'))) = 'ok 1',
  'rider 2 books driver 4');
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308b4', 'partner', 'I am your new driver') = 'ok 1',
  'chat: the new driver writes');
select pg_temp.check(pg_temp.seen('00000000-0000-0000-0000-0000000308b4') = 1,
  'chat: the new driver reads from their booking on, not the thread before');
select pg_temp.check(pg_temp.seen('00000000-0000-0000-0000-0000000308c2') = 4, 'chat: the rider reads all of it');
-- After the trip: read-only.
select pg_temp.check(pg_temp.say('00000000-0000-0000-0000-0000000308c1', 'rider', 'Thanks', pg_temp.id('t1'))
    like 'new row violates%', 'chat: a completed trip takes no messages');
select pg_temp.check(pg_temp.seen('00000000-0000-0000-0000-0000000308c1', pg_temp.id('t1')) = 0
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000308c1',
                           format('select count(*) from public.c2c_bookings where id = %L', pg_temp.id('t1'))) = '1',
  'chat: a completed trip''s thread is still readable (empty here)');
-- Ride chat is as it was: a ride's message still needs its ride.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000308c2',
    $q$insert into public.ride_messages (request_id, sender_role, type, body)
       values ('00000000-0000-0000-0000-0000000308d1', 'rider', 'text', 'Late reply')$q$) like 'new row violates%',
  'ride chat: a completed ride still takes no messages');

-- ---- Grants -------------------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.partner_rating_refresh(uuid)', 'execute'),
  'grants: the rating refresh is the server''s');
select pg_temp.check(not has_function_privilege('authenticated',
    'public.c2c_commission_now(uuid, public.c2c_bookings)', 'execute'), 'grants: commission now is the server''s');
select pg_temp.check(not has_function_privilege('anon', 'public.c2c_driver_requests()', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_driver_requests()', 'execute'),
  'grants: the list for the signed in');
select pg_temp.check(not has_function_privilege('anon', 'public.c2c_driver_cancel(uuid, text)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_driver_cancel(uuid, text)', 'execute'),
  'grants: driver cancel for the signed in');
select pg_temp.check(not has_function_privilege('anon', 'public.c2c_set_driving_since(date)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_set_driving_since(date)', 'execute'),
  'grants: driving since for the signed in');

select 'city_to_city_driver_0308: all passed';
rollback;
