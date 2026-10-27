-- ============================================================================
-- Regression test for migration 0300.
--   * a service needs a vehicle for a driver unless one of their partner
--     types that takes it has "Vehicle required" off (H3);
--   * a bid, take or offer on such a service with no vehicle in session is
--     refused with the reason, and goes through once one is taken;
--   * the airport fare's rate per km with no tariff is the service's own
--     Cost per km, a metered taxi's the built-in rate (H4).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/type_services_vehicle_fares_0300.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's: nobody is held up by them.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000300b1'),  -- driver: a car type and a walking type
  ('00000000-0000-0000-0000-0000000300b2'),  -- driver: no type
  ('00000000-0000-0000-0000-0000000300c1')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000300%'
on conflict do nothing;

insert into public.settings_entries (category, values, position) values
  ('partner-type', '{"name": "Test300 Car", "vehicleRequired": true}', 9301),
  ('partner-type', '{"name": "Test300 Walker", "vehicleRequired": false}', 9302);
insert into public.partner_type_services (type_key, type_name, all_services, services) values
  ('test300car', 'Test300 Car', false, array['Car 300', 'Both 300']),
  ('test300walker', 'Test300 Walker', false, array['Walk 300', 'Both 300'])
on conflict (type_key) do update set all_services = excluded.all_services, services = excluded.services;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries) values
  ('00000000-0000-0000-0000-0000000300e1', '00000000-0000-0000-0000-0000000300b1', 'Test Driver One', '+60100003001',
   'approved', '{Test300 Car,Test300 Walker}', '{Malaysia}'),
  ('00000000-0000-0000-0000-0000000300e2', '00000000-0000-0000-0000-0000000300b2', 'Test Driver Two', '+60100003002',
   'approved', '{}', '{Malaysia}');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
-- The error and hint a statement raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.error_of(text)
  to authenticated;

-- 1. Which services need a vehicle --------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.driver_service_needs_vehicle(uuid, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.driver_vehicle_missing(uuid, text)', 'execute'),
  'the server''s own');
select pg_temp.check(public.driver_service_needs_vehicle('00000000-0000-0000-0000-0000000300b1', 'Car 300'),
  'only the car type takes Car 300: it needs a vehicle');
select pg_temp.check(not public.driver_service_needs_vehicle('00000000-0000-0000-0000-0000000300b1', 'walk-300'),
  'the walking type takes Walk 300 (name or key): no vehicle');
select pg_temp.check(not public.driver_service_needs_vehicle('00000000-0000-0000-0000-0000000300b1', 'Both 300'),
  'both types take it, one without a vehicle: no vehicle');
select pg_temp.check(not public.driver_service_needs_vehicle('00000000-0000-0000-0000-0000000300b1', 'hail:meter')
                     and not public.driver_service_needs_vehicle('00000000-0000-0000-0000-0000000300b1', ''),
  'street hail and no service: not held');
select pg_temp.check(not public.driver_service_needs_vehicle('00000000-0000-0000-0000-0000000300b2', 'Car 300'),
  'no type: not held');
select pg_temp.check(public.driver_vehicle_missing('00000000-0000-0000-0000-0000000300b1', 'Car 300')
                     = 'Car 300 requests need a vehicle. Pick the vehicle you''re driving in Partner, then you can offer on these jobs.',
  'the reason: ' || coalesce(public.driver_vehicle_missing('00000000-0000-0000-0000-0000000300b1', 'Car 300'), 'none'));

-- 2. Bids, takes and offers without a vehicle ----------------------------------------------------------
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-000000030001', '00000000-0000-0000-0000-0000000300c1', 'open', 'Car 300', 20, 20,
        3.1, 101.6, 3.2, 101.7),
       ('00000000-0000-0000-0000-000000030002', '00000000-0000-0000-0000-0000000300c1', 'open', 'Walk 300', 20, 20,
        3.1, 101.6, 3.2, 101.7);

-- The read rules set aside in this transaction only, so the guard alone answers.
drop policy if exists "ride_requests partner type services" on public.ride_requests;
drop policy if exists "ride_requests driver services" on public.ride_requests;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000300b1');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000300b1', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000030001'$q$) like 'VEHICLE_REQUIRED: Car 300 requests need a vehicle.%',
  'a bid on a car job with no vehicle is refused');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000300b1', status = 'accepted', accepted_at = now()
  where id = '00000000-0000-0000-0000-000000030001'$q$) like 'VEHICLE_REQUIRED:%',
  'and a take');
select pg_temp.check(pg_temp.error_of($q$select public.ride_offer_make('00000000-0000-0000-0000-000000030001', 22)$q$)
                     like 'VEHICLE_REQUIRED:%',
  'and an offer: ' || pg_temp.error_of($q$select public.ride_offer_make('00000000-0000-0000-0000-000000030001', 22)$q$));
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000300b1', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000030002'$q$) not like '%VEHICLE_REQUIRED%',
  'a walking job needs no vehicle');
reset role;

-- With a vehicle in session, nothing is missing.
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status) values
  ('00000000-0000-0000-0000-0000000300f1', '00000000-0000-0000-0000-0000000300b1', '00000000-0000-0000-0000-0000000300e1',
   'TST 3001', 'Testmake', 'Alpha', 'White', 'approved');
insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000300f1', '00000000-0000-0000-0000-0000000300b1');
select pg_temp.check(public.driver_vehicle_missing('00000000-0000-0000-0000-0000000300b1', 'Car 300') is null,
  'driving a vehicle: nothing missing');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000300b1');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000300b1', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000030001'$q$) not like '%VEHICLE_REQUIRED%',
  'a bid with a vehicle is not held for one');
reset role;

-- 3. H4: the airport rate per km without a tariff --------------------------------------------------------
insert into public.settings_entries (category, values, position) values
  ('vehicle-services', '{"name": "Courier 300", "serviceTypes": ["Courier"], "costPerKm": 1.2}', 9311),
  ('vehicle-services', '{"name": "Teksi 300", "serviceTypes": ["Car"], "costPerKm": 3}', 9312);
-- Only where no tariff covers the place (a master card for every service would).
select pg_temp.check(exists (select 1 from public.fare_tariffs f
                              where f.active and f.service_type is null and f.vehicle_service is null and f.level = 'master')
                     or (public.airport_per_km('Courier 300', 'Nowhere300', null, null, null) = 1.2
                         and public.airport_per_km('Teksi 300', 'Nowhere300', null, null, null) = 3.5),
  'the service''s own Cost per km; a taxi''s built-in rate × its multiplier: '
  || public.airport_per_km('Courier 300', 'Nowhere300', null, null, null) || ', '
  || public.airport_per_km('Teksi 300', 'Nowhere300', null, null, null));

rollback;

select 'type_services_vehicle_fares_0300: all passed';
