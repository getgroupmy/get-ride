-- ============================================================================
-- Regression test for migration 0271: Freight (0267) and the city ride rules
-- (0269) together.
--   1. ride_offer_make: a car driver's offer on a freight request is refused
--      (FREIGHT_DRIVER_NO_FREIGHT), so is a van driver's without the
--      goods-vehicle permit the size asks for (FREIGHT_GOODS_PERMIT_REQUIRED);
--      a larger lorry's goes through, the van's too once its permit is
--      approved, and a car driver's on a car ride;
--   2. a sender cancelling a freight trip after the driver arrived pays only
--      the freight fee: no city fee, nothing from GET.wallet, no city due;
--      the terms the app reads say so; a freight no-show has no fee; a city
--      ride still pays its city fee;
--   3. my_owed_fees counts the city fees left due (rider_fee_dues) beside
--      the freight ones.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/freight_city_overlap_0271.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000271c1'),  -- rider with money in GET.wallet
  ('00000000-0000-0000-0000-0000000271c2'),  -- rider with an empty wallet
  ('00000000-0000-0000-0000-0000000271c3'),  -- rider of a city ride, with money in GET.wallet
  ('00000000-0000-0000-0000-0000000271d1'),  -- driver with a van (freight, asks for a goods permit)
  ('00000000-0000-0000-0000-0000000271d2'),  -- driver with a car
  ('00000000-0000-0000-0000-0000000271d3')   -- driver with a lorry (freight, larger, no permit asked)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000271%'
on conflict do nothing;

insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000027151', 'vehicle-services',
   '{"name": "Van 271", "serviceTypes": ["Freight"], "goodsPermitKey": "goods-271"}', 9201),
  ('00000000-0000-0000-0000-000000027152', 'vehicle-services',
   '{"name": "Lorry 271", "serviceTypes": ["Freight"]}', 9202),
  ('00000000-0000-0000-0000-000000027153', 'vehicle-services', '{"name": "Car 271", "serviceTypes": ["Car"]}', 9203);
insert into public.vehicle_service_order (service_id, rank) values
  ('00000000-0000-0000-0000-000000027151', 911),
  ('00000000-0000-0000-0000-000000027152', 912)
on conflict do nothing;

insert into public.partners (auth_user_id, name, phone, status)
select u.id, 'Driver ' || right(u.id::text, 2), '6013200' || right(u.id::text, 4), 'approved'
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000271d%';
insert into public.vehicle (id, auth_user_id, plate, make, model, color, status, service_id, service_approved_id,
                            service_countries) values
  ('00000000-0000-0000-0000-0000000271f1', '00000000-0000-0000-0000-0000000271d1', 'TST 2711', 'Testmake', 'Van',
   'White', 'approved', '00000000-0000-0000-0000-000000027151', '00000000-0000-0000-0000-000000027151',
   '{Freightland 271}'),
  ('00000000-0000-0000-0000-0000000271f2', '00000000-0000-0000-0000-0000000271d2', 'TST 2712', 'Testmake', 'Car',
   'Blue', 'approved', '00000000-0000-0000-0000-000000027153', '00000000-0000-0000-0000-000000027153',
   '{Freightland 271}'),
  ('00000000-0000-0000-0000-0000000271f3', '00000000-0000-0000-0000-0000000271d3', 'TST 2713', 'Testmake', 'Lorry',
   'Red', 'approved', '00000000-0000-0000-0000-000000027152', '00000000-0000-0000-0000-000000027152',
   '{Freightland 271}');
update public.vehicle set service_approved_id = service_id where id::text like '00000000-0000-0000-0000-0000000271f%';
insert into public.permit_types (id, country, key, name, applies_to, active) values
  ('00000000-0000-0000-0000-0000000271e1', 'Freightland 271', 'goods-271', 'Goods vehicle 271', 'vehicle', true);

-- The pickup's country: the freight cancel fee after arrival is 15 there;
-- the city rules are Default's (arrived 5, late 3, no-show 5).
insert into public.countries (name, values, geofence) values
  ('Freightland 271', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":28,"south":24,"east":118,"west":114}}'));
insert into public.ride_option_places (level, country, charges) values
  ('country', 'Freightland 271', '{"freight-cancel-arrived": {"kind": "fixed", "value": 15}}');

insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
values ('00000000-0000-0000-0000-0000000271c1', 'get_wallet', 'topup', 50, 'test'),
       ('00000000-0000-0000-0000-0000000271c3', 'get_wallet', 'topup', 50, 'test');

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
create or replace function pg_temp.wallet(p uuid) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = 'get_wallet'), 0);
$$;
-- An app booking at the pickup (26, 116) by [p_rider]; freight with [p_cargo].
create or replace function pg_temp.book(p_rider uuid, p_service text, p_cargo text default null)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, offer_me, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, cargo_description, prohibited_ack, declared_value)
  values (v, p_rider, 'open', p_service, 150, 150, true, 26.0, 116.0, 26.1, 116.1, p_cargo,
          case when p_cargo is not null then true end, case when p_cargo is not null then 100 end);
  return v;
end $$;
-- Taken by [p_driver] and arrived a minute ago (written by the server).
create or replace function pg_temp.arrived(p_rider uuid, p_driver uuid, p_service text, p_cargo text default null)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, cargo_description, partner_id, accepted_at, arrived_at)
  values (v, p_rider, 'arrived', p_service, 150, 150, 26.0, 116.0, 26.1, 116.1, p_cargo, p_driver,
          now() - interval '10 minutes', now() - interval '8 minutes');
  return v;
end $$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused_with(text, text, text),
  pg_temp.wallet(uuid), pg_temp.book(uuid, text, text) to authenticated;

select pg_temp.check(not has_function_privilege('authenticated', 'public.ride_request_is_freight(public.ride_requests)',
                                                'execute'), 'ride_request_is_freight is the server''s');

-- ---- 1. Offers only from drivers who may take the request --------------------------------------------
set local role authenticated;
insert into rides values ('van', pg_temp.book('00000000-0000-0000-0000-0000000271c1', 'Van 271', 'Two armchairs'));
insert into rides values ('car', pg_temp.book('00000000-0000-0000-0000-0000000271c3', 'Car 271'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d2');
select pg_temp.refused_with(format('select public.ride_offer_make(%L, 160)', (select id from rides where k = 'van')),
  'FREIGHT_DRIVER_NO_FREIGHT', 'a car driver''s offer on a freight request');
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d1');
select pg_temp.refused_with(format('select public.ride_offer_make(%L, 160)', (select id from rides where k = 'van')),
  'FREIGHT_GOODS_PERMIT_REQUIRED', 'a van driver''s offer without the goods-vehicle permit');
reset role;
select pg_temp.check(not exists (select 1 from public.ride_offers where request_id = (select id from rides where k = 'van')),
  'no offer was written for them');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d3');
insert into rides select 'lorry-offer', (public.ride_offer_make((select id from rides where k = 'van'), 170)->>'id')::uuid;
reset role;
select pg_temp.check((select status = 'open' and amount = 170 and partner_id = '00000000-0000-0000-0000-0000000271d3'
                        from public.ride_offers where id = (select id from rides where k = 'lorry-offer')),
  'a larger freight vehicle''s offer goes through');
insert into public.vehicle_documents (vehicle_id, permit_type_id, status, doc_id, doc_name)
values ('00000000-0000-0000-0000-0000000271f1', '00000000-0000-0000-0000-0000000271e1', 'Approved', 'goods-271',
        'Goods vehicle 271');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d1');
select pg_temp.check((public.ride_offer_make((select id from rides where k = 'van'), 165)->>'status') = 'open',
  'with the permit approved, the van driver''s offer goes through');
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d2');
insert into rides select 'car-offer', (public.ride_offer_make((select id from rides where k = 'car'), 150)->>'id')::uuid;
select pg_temp.check((select id from rides where k = 'car-offer') is not null, 'a car driver''s offer on a car ride');

-- ---- 2. A freight cancel after arrival pays only the freight fee ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c1');
select public.ride_offer_accept((select id from rides where k = 'lorry-offer'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c3');
select public.ride_offer_accept((select id from rides where k = 'car-offer'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d3');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'van');
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d2');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'car');
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c1');
select pg_temp.check((select (t->>'arrivedFee')::numeric = 0 and (t->>'lateFee')::numeric = 0
                             and (t->>'noShowFee')::numeric = 0 and (t->>'freight')::boolean
                             and (t->>'freightArrivedFee')::numeric = 15
                        from (select public.ride_cancel_terms((select id from rides where k = 'van')) t) x),
  'the terms of a freight trip: no city fee, the freight one: '
  || public.ride_cancel_terms((select id from rides where k = 'van'))::text);
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'van');
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c3');
select pg_temp.check((select (t->>'arrivedFee')::numeric = 5 and not (t->>'freight')::boolean
                             and (t->>'freightArrivedFee')::numeric = 0
                        from (select public.ride_cancel_terms((select id from rides where k = 'car')) t) x),
  'a city ride''s terms are the city''s');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'car');
reset role;
select pg_temp.check((select freight_cancel_fee = 15 and freight_cancel_fee_status = 'due'
                             and cancel_fee is null and cancel_fee_status is null
                        from public.ride_requests where id = (select id from rides where k = 'van')),
  'freight after arrival: only the freight fee: '
  || (select format('freight %s %s, city %s %s', freight_cancel_fee, freight_cancel_fee_status, cancel_fee,
                    cancel_fee_status)
        from public.ride_requests where id = (select id from rides where k = 'van')));
select pg_temp.check(not exists (select 1 from public.rider_fee_dues where ride_id = (select id from rides where k = 'van')),
  'no city fee left due for it');
select pg_temp.check((select cancel_fee = 5 and cancel_fee_status = 'charged' and freight_cancel_fee is null
                        from public.ride_requests where id = (select id from rides where k = 'car')),
  'a city ride still pays the city fee');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000271c1') = 50,
  'nothing taken from the sender''s GET.wallet: ' || pg_temp.wallet('00000000-0000-0000-0000-0000000271c1'));
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000271c3') = 45,
  'the city rider''s paid the 5: ' || pg_temp.wallet('00000000-0000-0000-0000-0000000271c3'));

-- A freight no-show: ended, with no fee.
insert into rides values ('noshow', pg_temp.arrived('00000000-0000-0000-0000-0000000271c2',
  '00000000-0000-0000-0000-0000000271d3', 'Van 271', 'Bookshelf'));
-- Two trips the empty-wallet sender cancels after the driver arrived.
insert into rides values ('c2-van', pg_temp.arrived('00000000-0000-0000-0000-0000000271c2',
  '00000000-0000-0000-0000-0000000271d3', 'Van 271', 'Fridge'));
insert into rides values ('c2-car', pg_temp.arrived('00000000-0000-0000-0000-0000000271c2',
  '00000000-0000-0000-0000-0000000271d2', 'Car 271'));
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000271d3');
select public.ride_no_show((select id from rides where k = 'noshow'));
reset role;
select pg_temp.check((select status = 'cancelled' and cancel_fee = 0 and cancel_fee_status = 'none'
                             and freight_cancel_fee is null
                        from public.ride_requests where id = (select id from rides where k = 'noshow')),
  'a freight no-show has no fee');
select pg_temp.check(not exists (select 1 from public.rider_fee_dues where ride_id = (select id from rides where k = 'noshow')),
  'and leaves nothing due');

-- ---- 3. my_owed_fees counts every fee due --------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c2');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'c2-van');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'c2-car');
reset role;
select pg_temp.check((select amount = 5 and status = 'due' and kind = 'arrived_cancel' from public.rider_fee_dues
                       where ride_id = (select id from rides where k = 'c2-car')),
  'the city fee an empty wallet couldn''t pay is due');
select pg_temp.check((select freight_cancel_fee = 15 and freight_cancel_fee_status = 'due' and cancel_fee is null
                        from public.ride_requests where id = (select id from rides where k = 'c2-van')),
  'the freight fee is due, with no city fee');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c2');
select pg_temp.check(public.my_owed_fees() = 20,
  'owed: the freight 15 and the city 5: ' || public.my_owed_fees());
select pg_temp.as_user('00000000-0000-0000-0000-0000000271c1');
select pg_temp.check(public.my_owed_fees() = 15, 'the first sender owes the freight 15: ' || public.my_owed_fees());
reset role;

select 'freight_city_overlap_0271: all passed';
rollback;
