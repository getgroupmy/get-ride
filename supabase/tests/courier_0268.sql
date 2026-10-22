-- ============================================================================
-- Regression test for migration 0268: Courier.
--   * the four courier vehicles are seeded inactive under a "Courier"
--     service type; a Vehicle Service is courier when its Service types name
--     Courier;
--   * a driver takes a courier request only with a courier vehicle that
--     carries it (the same one, or one with at least its load); not with a
--     car for rides or a freight van; reads, pushes and offers follow it;
--   * an app booking needs a parcel size the vehicle carries, what is sent,
--     the prohibited items confirmed, a declared value within the place's
--     courier cap and the recipient's phone; the recipient pays in cash
--     only; a parcel size or recipient-pays on a ride is refused; both stay
--     as booked;
--   * the confirmation code: nobody reads the table; the sender sees it as
--     the Courier settings say (or once every message failed), admins
--     always, the courier never; the recipient's notice carries it only
--     through freight_notices_claim; the courier enters it (wrong codes and
--     the rate limit answered) and only then can finish;
--   * courier place values (waiting, cancel fee, cap), the Courier settings
--     and their bounds, the cancel after pickup timeout, the city fee
--     exemption and a booking for later.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/courier_0268.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000268a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000268c1'),  -- senders
  ('00000000-0000-0000-0000-0000000268c2'),
  ('00000000-0000-0000-0000-0000000268d1'),  -- courier on a motorcycle (10 kg)
  ('00000000-0000-0000-0000-0000000268d2'),  -- driver with a car for rides
  ('00000000-0000-0000-0000-0000000268d3'),  -- courier with a car (20 kg)
  ('00000000-0000-0000-0000-0000000268d4')   -- freight van driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000268%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000268a1', '*', 'edit')
on conflict do nothing;

insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000026851', 'vehicle-services',
   '{"name": "Moto 268", "serviceTypes": ["Courier"], "maxLoadKg": 10}', 9301),
  ('00000000-0000-0000-0000-000000026852', 'vehicle-services',
   '{"name": "CCar 268", "serviceTypes": [" courier "], "maxLoadKg": 20}', 9302),
  ('00000000-0000-0000-0000-000000026853', 'vehicle-services', '{"name": "Car 268", "serviceTypes": ["Car"]}', 9303),
  ('00000000-0000-0000-0000-000000026854', 'vehicle-services',
   '{"name": "Van 268", "serviceTypes": ["Freight"], "maxLoadKg": 500}', 9304),
  ('00000000-0000-0000-0000-000000026855', 'vehicle-services',
   '{"name": "Walk 268", "serviceTypes": ["Courier"], "maxLoadKg": 5}', 9305);

insert into public.partners (auth_user_id, name, phone, status)
select u.id, 'Driver ' || right(u.id::text, 2), '6013300' || right(u.id::text, 4), 'approved'
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000268d%';
insert into public.vehicle (id, auth_user_id, plate, make, model, color, status, service_id, service_approved_id) values
  ('00000000-0000-0000-0000-0000000268f1', '00000000-0000-0000-0000-0000000268d1', 'TST 2681', 'Testmake', 'Moto',
   'Black', 'approved', '00000000-0000-0000-0000-000000026851', '00000000-0000-0000-0000-000000026851'),
  ('00000000-0000-0000-0000-0000000268f2', '00000000-0000-0000-0000-0000000268d2', 'TST 2682', 'Testmake', 'Car',
   'Blue', 'approved', '00000000-0000-0000-0000-000000026853', '00000000-0000-0000-0000-000000026853'),
  ('00000000-0000-0000-0000-0000000268f3', '00000000-0000-0000-0000-0000000268d3', 'TST 2683', 'Testmake', 'Car',
   'Red', 'approved', '00000000-0000-0000-0000-000000026852', '00000000-0000-0000-0000-000000026852'),
  ('00000000-0000-0000-0000-0000000268f4', '00000000-0000-0000-0000-0000000268d4', 'TST 2684', 'Testmake', 'Van',
   'White', 'approved', '00000000-0000-0000-0000-000000026854', '00000000-0000-0000-0000-000000026854');
update public.vehicle set service_approved_id = service_id where id::text like '00000000-0000-0000-0000-0000000268f%';
insert into public.driver_presence (profile_id, online, lat, lng)
select id, true, 30.0, 120.0 from auth.users where id::text like '00000000-0000-0000-0000-0000000268d%'
on conflict (profile_id) do update set online = true, lat = 30.0, lng = 120.0, updated_at = now();

insert into public.favourite_drivers (rider_id, driver_id) values
  ('00000000-0000-0000-0000-0000000268c2', '00000000-0000-0000-0000-0000000268d2'),
  ('00000000-0000-0000-0000-0000000268c2', '00000000-0000-0000-0000-0000000268d3');

-- The pickup's country, with the courier values set there.
insert into public.countries (name, values, geofence) values
  ('Courierland 268', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":32,"south":28,"east":122,"west":118}}'));
insert into public.ride_option_places (level, country, charges) values
  ('country', 'Courierland 268',
   '{"courier-wait-free-min": {"kind": "fixed", "value": 5}, "courier-wait-per-min": {"kind": "fixed", "value": 1},
     "courier-cancel-arrived": {"kind": "fixed", "value": 4}, "courier-declared-cap": {"kind": "fixed", "value": 300}}');

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
-- Refused with one of [p_codes] (0268's own, or a later migration's
-- version of the same function when replayed in file order).
create or replace function pg_temp.refused_with(p_sql text, p_codes text[], p_what text) returns void language plpgsql as $$
declare c text;
begin
  begin
    execute p_sql;
  exception when others then
    foreach c in array p_codes loop
      if position(c in sqlerrm) > 0 then
        return;
      end if;
    end loop;
    raise exception 'FAILED: % refused with "%", not %', p_what, sqlerrm, p_codes;
  end;
  raise exception 'FAILED (not refused): %', p_what;
end $$;
-- A courier booking at the pickup (30, 120) by [p_rider]; [p_extra] sets the
-- parcel, the payer, the payment, the recipient and the rest.
create or replace function pg_temp.book(p_rider uuid, p_service text, p_extra jsonb default '{}')
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, offer_me, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, option_names, cargo_description, parcel_size, payer,
                                    payment_mode, target_driver_ids, prohibited_ack, declared_value,
                                    recipient_name, recipient_phone, rider_name, currency)
  values (v, p_rider, 'open', p_service, coalesce((p_extra->>'fare')::numeric, 10),
          coalesce((p_extra->>'fare')::numeric, 10), true, 30.0, 120.0, 30.05, 120.05,
          p_extra->'option_names',
          case when p_extra ? 'cargo' then p_extra->>'cargo' else 'Documents' end,
          case when p_extra ? 'size' then p_extra->>'size' else 'S' end,
          p_extra->>'payer', coalesce(p_extra->>'payment', 'Cash'),
          case when p_extra ? 'targets' then array(select jsonb_array_elements_text(p_extra->'targets'))::uuid[] end,
          coalesce((p_extra->>'ack')::boolean, true), coalesce((p_extra->>'declared')::numeric, 100),
          'Mei', case when p_extra ? 'phone' then p_extra->>'phone' else '+60123456789' end, 'Aisyah', 'RM');
  return v;
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text),
  pg_temp.refused_with(text, text[], text), pg_temp.book(uuid, text, jsonb), pg_temp.sees(uuid) to authenticated;

-- ---- 1. The seeds and the courier vehicle services ------------------------------------------------------------
select pg_temp.check((select count(*) = 4 and bool_and(values->'status' = 'false'::jsonb)
                             and bool_and(public.vehicle_service_values_courier(values))
                        from public.settings_entries
                       where category = 'vehicle-services'
                         and values->>'name' in ('Courier Walker', 'Courier Bicycle', 'Courier Motorcycle', 'Courier Car')),
  'the four courier vehicles are seeded, inactive');
select pg_temp.check((select (values->>'maxLoadKg')::numeric = 20 and (values->>'loadLengthM')::numeric = 0.7
                        from public.settings_entries where id = '636f7572-6965-4000-8000-000000000004'),
  'the car carries 20 kg, 70 cm long');
-- (A replay's seed.sql sets Service Settings again after the migrations.)
select pg_temp.check(exists (select 1 from public.settings_entries
                              where category = 'service-settings' and lower(values->>'name') = 'courier')
                     or exists (select 1 from public.settings_entries
                                 where category = 'service-settings' and values->>'description' = 'Parcel & courier delivery'),
  'the Courier service type is there');
select pg_temp.check(public.vehicle_service_values_courier('{"serviceTypes": ["Car", "COURIER"]}')
                     and not public.vehicle_service_values_courier('{"serviceTypes": ["Freight"]}')
                     and not public.vehicle_service_values_courier('{}'), 'Courier among the Service types');
select pg_temp.check(public.vehicle_service_is_courier('moto 268') and public.vehicle_service_is_courier('CCar 268')
                     and not public.vehicle_service_is_courier('Car 268') and not public.vehicle_service_is_courier('Van 268'),
  'which services are courier');
select pg_temp.check(public.driver_takes_freight('00000000-0000-0000-0000-0000000268d1', 'Moto 268')
                     and public.driver_takes_freight('00000000-0000-0000-0000-0000000268d1', 'Walk 268')
                     and not public.driver_takes_freight('00000000-0000-0000-0000-0000000268d1', 'CCar 268')
                     and public.driver_takes_freight('00000000-0000-0000-0000-0000000268d3', 'Moto 268')
                     and not public.driver_takes_freight('00000000-0000-0000-0000-0000000268d2', 'Moto 268')
                     and not public.driver_takes_freight('00000000-0000-0000-0000-0000000268d4', 'Moto 268')
                     and not public.driver_takes_freight('00000000-0000-0000-0000-0000000268d1', 'Van 268')
                     and public.driver_takes_freight('00000000-0000-0000-0000-0000000268d2', 'Car 268'),
  'a motorcycle takes motorcycle and walker parcels, a courier car all; a ride car or a van none; anyone a ride');

-- ---- 2. Bookings -----------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268', '{"size": null}')$q$,
  array['COURIER_PARCEL_SIZE'], 'courier without a parcel size');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268', '{"size": "M"}')$q$,
  array['COURIER_TOO_HEAVY'], 'a 15 kg parcel on a 10 kg motorcycle');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268', '{"cargo": null}')$q$,
  array['COURIER_ITEM_REQUIRED'], 'without what is sent');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268', '{"ack": false}')$q$,
  array['COURIER_PROHIBITED_ACK'], 'without confirming the prohibited items');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268', '{"declared": 400}')$q$,
  array['COURIER_DECLARED_VALUE_CAP'], 'over the place''s courier cap of 300');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268', '{"phone": null}')$q$,
  array['COURIER_RECIPIENT_REQUIRED'], 'without the recipient''s phone');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268',
  '{"payer": "recipient", "payment": "Get Pay"}')$q$, array['COURIER_RECIPIENT_PAYS_CASH'], 'the recipient paying by wallet');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Car 268')$q$,
  array['COURIER_SIZE_NOT_COURIER'], 'a parcel size on a ride');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Car 268',
  '{"size": null, "cargo": null, "payer": "recipient"}')$q$, array['COURIER_RECIPIENT_PAYS_ONLY'], 'recipient-pays on a ride');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268',
  '{"option_names": {"helper-1": "1 helper"}}')$q$, array['FREIGHT_OPTION_NOT_FREIGHT'], 'a freight option on a courier request');
insert into rides values ('moto', pg_temp.book('00000000-0000-0000-0000-0000000268c1', 'Moto 268',
  '{"payer": "recipient", "cargo": "Documents, keys"}'));
insert into rides values ('favs', pg_temp.book('00000000-0000-0000-0000-0000000268c2', 'Moto 268',
  '{"targets": ["00000000-0000-0000-0000-0000000268d2", "00000000-0000-0000-0000-0000000268d3"]}'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select pg_temp.refused_with($q$update public.ride_requests set parcel_size = 'L' where id = (select id from rides where k = 'moto')$q$,
  array['COURIER_FIXED'], 'the sender changing the parcel size');
select pg_temp.refused_with($q$update public.ride_requests set payer = 'sender' where id = (select id from rides where k = 'moto')$q$,
  array['COURIER_FIXED'], 'the sender changing who pays');
reset role;
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000268d3']::uuid[]
                        from public.ride_requests where id = (select id from rides where k = 'favs')),
  'My Ride: the favourite without a courier vehicle is left out');
select pg_temp.check((select count(*) = 1 from public.ride_delivery_codes d where d.request_id = (select id from rides where k = 'moto')
                         and d.code ~ '^[0-9]{4}$'), 'a courier request gets its 4-digit code');
select pg_temp.check(public.ride_request_is_freight((select r from public.ride_requests r where r.id = (select id from rides where k = 'moto'))),
  'a courier request is spared the city fees as freight is');

-- ---- 3. Who reads, is pushed and offers ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'moto')) = 1, 'the motorcycle courier sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d3');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'moto')) = 1, 'the courier car sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'moto')) = 0, 'a ride car doesn''t');
select pg_temp.refused_with(format('select public.ride_offer_make(%L, 12)', (select id from rides where k = 'moto')),
  array['COURIER_DRIVER_NO_COURIER', 'FREIGHT_DRIVER_NO_FREIGHT'], 'a ride car''s offer on a courier request');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d4');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'moto')) = 0, 'a freight van doesn''t');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268a1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'moto')) = 1, 'admins do');
reset role;
select pg_temp.check(exists (select 1 from public.ride_request_pushes where request_id = (select id from rides where k = 'moto')
                               and profile_id = '00000000-0000-0000-0000-0000000268d1'), 'the motorcycle courier is pushed');
select pg_temp.check(not exists (select 1 from public.ride_request_pushes where request_id = (select id from rides where k = 'moto')
                                   and profile_id = '00000000-0000-0000-0000-0000000268d2'), 'the ride car is not');

-- ---- 4. The code ------------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select pg_temp.refused_with($q$select code from public.ride_delivery_codes$q$, array['permission denied'],
  'nobody reads the codes table');
reset role;
create temp table codes as
  select r.k, d.code from rides r join public.ride_delivery_codes d on d.request_id = r.id;
grant select on codes to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select pg_temp.check(public.courier_delivery_code((select id from rides where k = 'moto')) = (select code from codes where k = 'moto'),
  'the sender sees the code (shown to the sender by default)');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
select pg_temp.check(public.courier_delivery_code((select id from rides where k = 'moto')) is null, 'a courier never does');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268a1');
select pg_temp.check(public.courier_delivery_code((select id from rides where k = 'moto')) = (select code from codes where k = 'moto'),
  'admins do');

-- ---- 5. The trip --------------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
insert into rides select 'moto-offer', (public.ride_offer_make((select id from rides where k = 'moto'), 10)->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select public.ride_offer_accept((select id from rides where k = 'moto-offer'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000268d1'
                             and recipient_phone = '+60123456789'
                        from public.ride_requests where id = (select id from rides where k = 'moto')),
  'the courier who took it reads the recipient');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'moto');
reset role;
update public.ride_requests set arrived_at = now() - interval '8 minutes 10 seconds' where id = (select id from rides where k = 'moto');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
select pg_temp.refused_with($q$select public.courier_code_check((select id from rides where k = 'moto'), '0000')$q$,
  array['wrong_status'], 'the code before the trip');
update public.ride_requests set pickup_proof_path = '00000000-0000-0000-0000-0000000268d1/proof-pickup.jpg'
 where id = (select id from rides where k = 'moto');
update public.ride_requests set status = 'on_trip' where id = (select id from rides where k = 'moto');
reset role;
select pg_temp.check((select freight_waiting_minutes = 8 and freight_waiting_fee = 3 and fare = 13
                        from public.ride_requests where id = (select id from rides where k = 'moto')),
  'started: 3 minutes past the courier''s free 5, at 1 a minute: '
  || (select format('%s min, fee %s, fare %s', freight_waiting_minutes, freight_waiting_fee, fare)
        from public.ride_requests where id = (select id from rides where k = 'moto')));
select pg_temp.check((select count(*) = 1 and bool_and(channel = 'sms' and with_code
                                                       and position('pay the courier RM 13.00 in cash' in body) > 0
                                                       and position((select code from codes where k = 'moto') in body) = 0)
                        from public.freight_recipient_notices where ride_id = (select id from rides where k = 'moto')),
  'the recipient''s SMS waits, says what to pay, and doesn''t hold the code');
select pg_temp.check((select count(*) = 1 and bool_and(delivery_code = (select code from codes where k = 'moto')
                                                       and share_token is not null)
                        from public.freight_notices_claim((select id from rides where k = 'moto'))),
  'freight-notify claims it with the code and the link');
-- Finishing.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
update public.ride_requests set dropoff_proof_path = '00000000-0000-0000-0000-0000000268d1/proof-dropoff.jpg'
 where id = (select id from rides where k = 'moto');
select pg_temp.refused_with($q$update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'moto')$q$,
  array['COURIER_CODE_REQUIRED'], 'finishing without the code');
select pg_temp.refused_with($q$update public.ride_requests set delivery_code_ok_at = now() where id = (select id from rides where k = 'moto')$q$,
  array['COURIER_CODE_NOT_YOURS'], 'the courier stamping the code themselves');
select pg_temp.check(public.courier_code_check((select id from rides where k = 'moto'),
                       case when (select code from codes where k = 'moto') = '1111' then '2222' else '1111' end) = 'wrong_code',
  'a wrong code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select pg_temp.refused_with(format('select public.courier_code_check(%L, %L)', (select id from rides where k = 'moto'),
                                   (select code from codes where k = 'moto')), array['not_authorized'], 'the sender typing it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d1');
select pg_temp.check(public.courier_code_check((select id from rides where k = 'moto'), (select code from codes where k = 'moto')) = 'ok',
  'the right code');
update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'moto');
reset role;
select pg_temp.check((select status = 'completed' and delivery_code_ok_at is not null
                        from public.ride_requests where id = (select id from rides where k = 'moto')), 'delivered');
-- Five tries per 10 minutes.
insert into rides values ('tries', gen_random_uuid());
insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                  cargo_description, parcel_size, recipient_phone)
values ((select id from rides where k = 'tries'), '00000000-0000-0000-0000-0000000268c2', '00000000-0000-0000-0000-0000000268d3',
        'on_trip', 'CCar 268', 10, 30, 120, 30.1, 120.1, 'Box', 'M', '+60123456780');
insert into codes select 'tries', code from public.ride_delivery_codes where request_id = (select id from rides where k = 'tries');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268d3');
select public.courier_code_check((select id from rides where k = 'tries'), 'abcd') from generate_series(1, 5);
select pg_temp.check(public.courier_code_check((select id from rides where k = 'tries'), (select code from codes where k = 'tries'))
                       like 'rate_limited:%', 'the sixth try waits');
reset role;

-- ---- 6. Courier settings ---------------------------------------------------------------------------------------------
select pg_temp.check(public.courier_config() = '{"codeChannels": ["sms", "sender"], "cancelApproveMinutes": 5,
                       "parcelSizes": {"S": 5, "M": 15, "L": 20}, "prohibitedItems": ["Explosives and fireworks",
                       "Flammable liquids and gas cylinders", "Weapons and ammunition", "Illegal drugs", "Live animals",
                       "Cash, jewellery and other valuables", "Hazardous chemicals"]}'::jsonb, 'the defaults');
select pg_temp.check(public.courier_parcel_kg('M') = 15 and public.courier_parcel_kg(null) is null, 'the kilos per size');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select pg_temp.refused_with($q$select public.set_courier_config('{"cancelApproveMinutes": 9}')$q$, array['NOT_ALLOWED'],
  'a sender changing the Courier settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000268a1');
select pg_temp.check(public.set_courier_config('{"codeChannels": ["fax"], "cancelApproveMinutes": 0,
                       "parcelSizes": {"S": 2000, "M": 12}, "prohibitedItems": ["Explosives", " "]}')
                     = '{"codeChannels": ["sender"], "cancelApproveMinutes": 1, "parcelSizes": {"S": 5, "M": 12, "L": 20},
                         "prohibitedItems": ["Explosives"]}'::jsonb, 'kept within bounds');
select public.set_courier_config('{"codeChannels": ["whatsapp", "sms"], "cancelApproveMinutes": 2}');
reset role;
select pg_temp.check(public.courier_config()->'codeChannels' = '["sms", "whatsapp"]'::jsonb, 'channels in their order');
select pg_temp.check(public.freight_place_value('{}', 'courier-wait-free-min') = 10
                     and public.freight_place_value('{}', 'courier-declared-cap') = 500
                     and public.freight_place_value('{}', 'freight-wait-free-min') = 20, 'nothing set: 10 courier minutes');
-- Messages only: the sender sees the code once every message failed.
insert into rides values ('msg', pg_temp.book('00000000-0000-0000-0000-0000000268c2', 'CCar 268'));
reset role;
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000268d3'
 where id = (select id from rides where k = 'msg');
update public.ride_requests set status = 'on_trip' where id = (select id from rides where k = 'msg');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c2');
select pg_temp.check(public.courier_delivery_code((select id from rides where k = 'msg')) is null,
  'by SMS and WhatsApp only, the sender doesn''t see it');
reset role;
update public.freight_recipient_notices set status = 'failed', attempts = 3 where ride_id = (select id from rides where k = 'msg');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c2');
select pg_temp.check(public.courier_delivery_code((select id from rides where k = 'msg')) is not null,
  'every message failed: the sender sees it');
reset role;
-- A courier's cancel after pickup waits the Courier settings' 2 minutes.
update public.ride_requests set cancel_requested_at = now() - interval '3 minutes', cancel_requested_by = 'partner'
 where id = (select id from rides where k = 'msg');
select public.ride_cancel_requests_lapse();
select pg_temp.check((select status = 'cancelled' from public.ride_requests where id = (select id from rides where k = 'msg')),
  'approved after the courier minutes');

-- ---- 7. The sender cancels after the courier arrived -----------------------------------------------------------------
insert into rides values ('late', pg_temp.book('00000000-0000-0000-0000-0000000268c2', 'Moto 268'));
reset role;
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000268d1'
 where id = (select id from rides where k = 'late');
update public.ride_requests set status = 'arrived', arrived_at = now() where id = (select id from rides where k = 'late');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c2');
select pg_temp.check((public.ride_cancel_terms((select id from rides where k = 'late'))->>'freight')::boolean,
  'no city fee: the terms say freight');
select pg_temp.check(not (public.ride_cancel_terms((select id from rides where k = 'late')) ? 'courier')
                     or (public.ride_cancel_terms((select id from rides where k = 'late'))->>'freightArrivedFee')::numeric = 4,
  'with 0268 last (as live), the courier fee: '
  || (public.ride_cancel_terms((select id from rides where k = 'late')))::text);
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'late');
reset role;
select pg_temp.check((select freight_cancel_fee = 4 and freight_cancel_fee_status = 'due' and cancel_fee_status is distinct from 'taken'
                        from public.ride_requests where id = (select id from rides where k = 'late')),
  'the courier cancel fee is owed, no city fee');

-- ---- 8. A booking for later ----------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);
select public.set_scheduled_rides_config('{"enabled": true, "mode": "advance"}');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000268c1');
select pg_temp.refused_with($q$select public.schedule_ride('{"service": "Moto 268", "pickup_lat": 30.0, "pickup_lng": 120.0,
  "drop_lat": 30.1, "drop_lng": 120.1, "fare": 10, "cargo_description": "Box", "prohibited_ack": true,
  "declared_value": 50, "recipient_phone": "+60123456789"}'::jsonb, now() + interval '3 hours')$q$,
  array['COURIER_PARCEL_SIZE'], 'for later: courier without a size');
select public.schedule_ride('{"service": "Moto 268", "pickup_lat": 30.0, "pickup_lng": 120.0,
  "drop_lat": 30.1, "drop_lng": 120.1, "fare": 10, "cargo_description": "Box", "prohibited_ack": true,
  "declared_value": 50, "recipient_phone": "+60123456789", "parcel_size": "S", "payer": "recipient",
  "payment_mode": "Cash"}'::jsonb, now() + interval '3 hours');
reset role;
select pg_temp.check((select request->>'parcel_size' = 'S' and request->>'payer' = 'recipient'
                        from public.scheduled_rides where rider_id = '00000000-0000-0000-0000-0000000268c1'
                       order by created_at desc limit 1), 'the booking keeps the parcel and who pays');

select pg_temp.check(not has_function_privilege('authenticated', 'public.freight_notices_claim(uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'public.courier_vehicle_carries(text, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.driver_takes_freight(uuid, text)', 'execute'),
  'the sending and the eligibility are the server''s');

select 'courier_0268: all passed';
rollback;
