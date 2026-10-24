-- ============================================================================
-- Regression test for migration 0288, part 8: a service paused for a vehicle
-- (over its age limit, or waiting for the vehicle permit GET.ride uploads)
-- is off for that vehicle on the server.
--   * an open request for a paused service is hidden from the driver of that
--     vehicle, and a bid or a take is refused with the reason;
--   * a Vehicle Service another of the vehicle's types allows is unaffected,
--     and so are other drivers;
--   * an approved vehicle permit turns the waiting service back on;
--   * the Services page says why.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/vehicle_service_pause_0288.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's: nobody is held up by them.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into public.partner_type_services (type_key, type_name, all_services, services) values
  ('ehailing', 'eHailing', false, array['Ride', 'Premium']),
  ('teksi', 'Teksi', false, array['Teksi', 'Ride'])
on conflict (type_key) do update set all_services = excluded.all_services, services = excluded.services;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000002880c1'),  -- rider
  ('00000000-0000-0000-0000-0000002880d1'),  -- driver: a taxi registered for eHailing and Teksi
  ('00000000-0000-0000-0000-0000002880d2'),  -- driver: an eHailing car over its age limit
  ('00000000-0000-0000-0000-0000002880d3')   -- driver: nothing paused
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000002880%'
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states) values
  ('00000000-0000-0000-0000-0000002880e1', '00000000-0000-0000-0000-0000002880d1', 'Test Driver One', '+60100028801',
   'approved', '{eHailing,Teksi}', '{Malaysia}', '{Selangor}'),
  ('00000000-0000-0000-0000-0000002880e2', '00000000-0000-0000-0000-0000002880d2', 'Test Driver Two', '+60100028802',
   'approved', '{eHailing}', '{Malaysia}', '{Selangor}'),
  ('00000000-0000-0000-0000-0000002880e3', '00000000-0000-0000-0000-0000002880d3', 'Test Driver Three', '+60100028803',
   'approved', '{eHailing}', '{Malaysia}', '{Selangor}');

insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status,
                            service_countries, service_states, partner_types, energy_type) values
  ('00000000-0000-0000-0000-0000002880f1', '00000000-0000-0000-0000-0000002880d1', '00000000-0000-0000-0000-0000002880e1',
   'TST 2881', 'Testmake', 'Alpha', 'White', 'approved', '{Malaysia}', '{Selangor}', '{eHailing,Teksi}', 'Petrol'),
  ('00000000-0000-0000-0000-0000002880f2', '00000000-0000-0000-0000-0000002880d2', '00000000-0000-0000-0000-0000002880e2',
   'TST 2882', 'Testmake', 'Beta', 'Grey', 'approved', '{Malaysia}', '{Selangor}', '{eHailing}', 'Petrol'),
  ('00000000-0000-0000-0000-0000002880f3', '00000000-0000-0000-0000-0000002880d3', '00000000-0000-0000-0000-0000002880e3',
   'TST 2883', 'Testmake', 'Gamma', 'Blue', 'approved', '{Malaysia}', '{Selangor}', '{eHailing}', 'Petrol');

insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000002880f1', '00000000-0000-0000-0000-0000002880d1'),
  ('00000000-0000-0000-0000-0000002880f2', '00000000-0000-0000-0000-0000002880d2'),
  ('00000000-0000-0000-0000-0000002880f3', '00000000-0000-0000-0000-0000002880d3');

insert into public.settings_entries (category, values, position) values
  ('vehicle-services', '{"name": "Ride", "serviceTypes": ["Car"]}', 9101),
  ('vehicle-services', '{"name": "Premium", "serviceTypes": ["Car"]}', 9102);

-- The taxi waits for its eHailing permit (Teksi active); the car is over
-- eHailing's 15 years.
insert into public.vehicle_service_status (vehicle_id, service, status, max_age_years, permit_name) values
  ('00000000-0000-0000-0000-0000002880f1', 'eHailing', 'waiting_permit', 20, 'EVP'),
  ('00000000-0000-0000-0000-0000002880f1', 'Teksi', 'active', 20, null),
  ('00000000-0000-0000-0000-0000002880f2', 'eHailing', 'paused_age', 15, null);

insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng) values
  ('00000000-0000-0000-0000-000000288001', '00000000-0000-0000-0000-0000002880c1', 'open', 'Premium', 30, 30, 3.1, 101.6, 3.2, 101.7),
  ('00000000-0000-0000-0000-000000288002', '00000000-0000-0000-0000-0000002880c1', 'open', 'Ride', 20, 20, 3.1, 101.6, 3.2, 101.7);

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
-- The hint a statement raises, or 'ok'.
create or replace function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text),
  pg_temp.hint_of(text), pg_temp.sees(uuid) to authenticated;

-- ---- 1. The rule -----------------------------------------------------------------------------------
select pg_temp.check(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f1', 'Premium') ->> 'status' = 'waiting_permit',
  'Premium only through eHailing: waiting for the permit');
select pg_temp.check(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f1', 'Ride') is null,
  'Ride through Teksi: not paused');
select pg_temp.check(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f2', 'ride') ->> 'status' = 'paused_age',
  'the old car: Ride paused (key form too)');
select pg_temp.check(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f3', 'Ride') is null, 'nothing paused');
select pg_temp.check(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f2', 'hail:meter') is null,
  'street hail is the app''s');
select pg_temp.check(public.vehicle_service_block_text(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f2', 'Ride'))
                     = 'eHailing paused: vehicle over the 15-year limit', 'in words (age)');
select pg_temp.check(public.vehicle_service_block_text(public.vehicle_service_block('00000000-0000-0000-0000-0000002880f1', 'Premium'))
                     = 'eHailing waiting for the vehicle permit', 'in words (permit)');
select pg_temp.check(not public.driver_service_effective('00000000-0000-0000-0000-0000002880d2', '00000000-0000-0000-0000-0000002880f2', 'Ride'),
  'off for that vehicle, whatever the switch');
select pg_temp.check('ride' = any (public.driver_services_off('00000000-0000-0000-0000-0000002880d2')), 'in the off list');
select pg_temp.check(not public.driver_takes_service('00000000-0000-0000-0000-0000002880d2', 'Ride'), 'the driver doesn''t take it');
select pg_temp.check(public.driver_takes_service('00000000-0000-0000-0000-0000002880d3', 'Ride'), 'another driver does');

-- ---- 2. Who reads an open request ------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000288001') = 0, 'the taxi does not see Premium (waiting permit)');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000288002') = 1, 'the taxi still sees Ride (Teksi)');
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d2');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000288002') = 0, 'the old car does not see Ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d3');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000288001') = 1
                     and pg_temp.sees('00000000-0000-0000-0000-000000288002') = 1, 'nothing paused: sees both');
select pg_temp.as_user('00000000-0000-0000-0000-0000002880c1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-000000288002') = 1, 'the rider sees their own');

-- ---- 3. Bids and takes ------------------------------------------------------------------------------
-- The old car doesn't read the request, so its update finds nothing.
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d2');
select pg_temp.check(pg_temp.hint_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000002880d2', status = 'accepted', accepted_at = now()
  where id = '00000000-0000-0000-0000-000000288002'$q$) = 'ok'
  and (select partner_id from public.ride_requests where id = '00000000-0000-0000-0000-000000288002') is null,
  'a take by the old car changes nothing');
reset role;
-- And were it read (the read rule set aside, in this transaction only), the
-- take itself is refused with the reason.
drop policy "ride_requests driver services" on public.ride_requests;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d2');
select pg_temp.check(pg_temp.hint_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000002880d2', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000288002'$q$)
  = 'VEHICLE_SERVICE_PAUSED: eHailing paused: vehicle over the 15-year limit', 'a bid by the old car is refused');
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d1');
select pg_temp.check(pg_temp.hint_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000002880d1', offered_fare = 31
  where id = '00000000-0000-0000-0000-000000288001'$q$)
  = 'VEHICLE_SERVICE_PAUSED: eHailing waiting for the vehicle permit', 'a bid by the taxi on Premium is refused');
select pg_temp.check(pg_temp.hint_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000002880d1', offered_fare = 21
  where id = '00000000-0000-0000-0000-000000288002'$q$) = 'ok', 'the taxi bids on Ride');
reset role;
-- Back as it was for the rest.
create policy "ride_requests driver services" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or not (public.driver_service_key(service) = any ((select public.caller_services_off())::text[])));
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d1');

-- ---- 4. The Services page --------------------------------------------------------------------------
select pg_temp.check((
  select (s ->> 'on')::boolean = false and s -> 'vehicle_block' ->> 'status' = 'waiting_permit'
    from jsonb_array_elements(public.driver_services_for() -> 'services') s where s ->> 'name' = 'Premium' limit 1),
  'Premium off with its reason');
select pg_temp.check((
  select s -> 'vehicle_block' = 'null'::jsonb and (s ->> 'on')::boolean
    from jsonb_array_elements(public.driver_services_for() -> 'services') s where s ->> 'name' = 'Ride' limit 1),
  'Ride on');
reset role;

-- ---- 5. The permit is approved: eHailing turns on for the taxi -------------------------------------
insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, status, permit_type_id, expiry_date)
select '00000000-0000-0000-0000-0000002880f1', 'permit', 'EVP', 'Approved', t.id, current_date + 300
  from public.permit_types t order by t.id limit 1;
select pg_temp.check(
  not exists (select 1 from public.permit_types)
  or (select status = 'active' from public.vehicle_service_status
       where vehicle_id = '00000000-0000-0000-0000-0000002880f1' and service = 'eHailing'),
  'the approved permit turns eHailing on');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000002880d1');
select pg_temp.check(not exists (select 1 from public.permit_types) or pg_temp.sees('00000000-0000-0000-0000-000000288001') = 1,
  'the taxi now sees Premium');
reset role;

select 'vehicle_service_pause_0288: all passed';
rollback;
