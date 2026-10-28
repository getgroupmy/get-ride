-- ============================================================================
-- Regression test for migration 0312: Freight and Courier add-ons.
--   * the rules: validated values, Default plus a region rule that keeps
--     only what it sets, admins only write them;
--   * bookings: each add-on's line must be the region's rule; stairs (max
--     floors, a helper from N floors), the cold truck (a known level, a
--     refrigerated vehicle), parcel cover (up to its highest value, past the
--     place's declared cap), cash on delivery (Courier only, up to its max,
--     the fee the server's); the add-ons stay as booked, the server's columns
--     are its own;
--   * drivers: only refrigerated vehicles read or offer on a cold-truck
--     request; a COD request needs room within the carry limit and the
--     driver's GET.wallet;
--   * the trip: COD settled from the driver's GET.wallet to the sender less
--     the fee; "won't pay" brings it back at the return rate (or free on a
--     round trip) without the recipient's code; a round trip ends only after
--     the return leg, its wait charged past the free minutes;
--   * the cover premium is the platform's, never commissioned; claims within
--     the claim days, up to the declared value, decided by an admin and paid
--     to the sender's GET.wallet; a booking for later keeps the add-ons.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/freight_addons_0312.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's.
do $$
begin
  if to_regclass('public.permit_country_settings') is not null then
    execute 'update public.permit_country_settings set enforce = false';
  end if;
  if to_regclass('public.service_order_settings') is not null then
    execute 'update public.service_order_settings set enforce_all = false';
  end if;
end $$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000312a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000312c1'),  -- senders
  ('00000000-0000-0000-0000-0000000312c2'),
  ('00000000-0000-0000-0000-0000000312c3'),
  ('00000000-0000-0000-0000-0000000312c4'),
  ('00000000-0000-0000-0000-0000000312c5'),
  ('00000000-0000-0000-0000-0000000312c6'),
  ('00000000-0000-0000-0000-0000000312d1'),  -- refrigerated lorry
  ('00000000-0000-0000-0000-0000000312d2'),  -- plain lorry
  ('00000000-0000-0000-0000-0000000312d3')   -- courier motorcycle
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000312%'
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000312a1', '*', 'edit')
on conflict do nothing;

insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000031251', 'vehicle-services',
   '{"name": "Lorry 312", "serviceTypes": ["Freight"], "maxLoadKg": 1000}', 9311),
  ('00000000-0000-0000-0000-000000031252', 'vehicle-services',
   '{"name": "Cold 312", "serviceTypes": ["Freight"], "maxLoadKg": 1000, "refrigerated": true}', 9312),
  ('00000000-0000-0000-0000-000000031253', 'vehicle-services',
   '{"name": "Moto 312", "serviceTypes": ["Courier"], "maxLoadKg": 10}', 9313);

-- The drivers' vehicles (a stand-in table where the full schema isn't there).
do $$
begin
  if to_regclass('public.vehicle') is not null then
    insert into public.partners (auth_user_id, name, phone, status)
    select u.id, 'Driver ' || right(u.id::text, 2), '6013312' || right(u.id::text, 4), 'approved'
      from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000312d%';
    insert into public.vehicle (id, auth_user_id, plate, make, model, color, status, service_id, service_approved_id) values
      ('00000000-0000-0000-0000-0000000312f1', '00000000-0000-0000-0000-0000000312d1', 'TST 3121', 'Testmake', 'Cold',
       'White', 'approved', '00000000-0000-0000-0000-000000031252', '00000000-0000-0000-0000-000000031252'),
      ('00000000-0000-0000-0000-0000000312f2', '00000000-0000-0000-0000-0000000312d2', 'TST 3122', 'Testmake', 'Lorry',
       'Blue', 'approved', '00000000-0000-0000-0000-000000031251', '00000000-0000-0000-0000-000000031251'),
      ('00000000-0000-0000-0000-0000000312f3', '00000000-0000-0000-0000-0000000312d3', 'TST 3123', 'Testmake', 'Moto',
       'Red', 'approved', '00000000-0000-0000-0000-000000031253', '00000000-0000-0000-0000-000000031253');
    update public.vehicle set service_approved_id = service_id where id::text like '00000000-0000-0000-0000-0000000312f%';
  else
    execute $s$insert into public.driver_service (uid, service_id) values
      ('00000000-0000-0000-0000-0000000312d1', '00000000-0000-0000-0000-000000031252'),
      ('00000000-0000-0000-0000-0000000312d2', '00000000-0000-0000-0000-000000031251'),
      ('00000000-0000-0000-0000-0000000312d3', '00000000-0000-0000-0000-000000031253')$s$;
  end if;
  if to_regclass('public.countries') is not null then
    insert into public.countries (name, values, geofence) values
      ('Addonland 312', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
        '{"bbox":{"north":32,"south":28,"east":122,"west":118}}'));
  end if;
end $$;

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
-- A booking at the pickup (30, 120) by [p_rider] of [p_service]; [p_extra]
-- sets the fare, the lines, the add-ons and the parcel.
create or replace function pg_temp.book(p_rider uuid, p_service text, p_extra jsonb default '{}')
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, offer_me, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, option_names, option_charges, cargo_description, parcel_size,
                                    payment_mode, prohibited_ack, declared_value, recipient_name, recipient_phone,
                                    rider_name, currency, country, parcel_cover, round_trip, stairs_pickup, stairs_drop,
                                    cold_level, cod_amount)
  values (v, p_rider, 'open', p_service, coalesce((p_extra->>'fare')::numeric, 10),
          coalesce((p_extra->>'fare')::numeric, 10), true, 30.0, 120.0, 30.05, 120.05,
          p_extra->'option_names', p_extra->'lines', coalesce(p_extra->>'cargo', 'Boxes'),
          p_extra->>'size', 'Cash', true, coalesce((p_extra->>'declared')::numeric, 100),
          'Mei', '+60123456789', 'Aisyah', 'RM',
          case when to_regclass('public.countries') is null then 'Addonland 312' end,
          (p_extra->>'cover')::boolean, (p_extra->>'round')::boolean, (p_extra->>'sp')::int, (p_extra->>'sd')::int,
          p_extra->>'cold', (p_extra->>'cod')::numeric);
  return v;
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
create or replace function pg_temp.balance(p uuid, p_type text) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = p_type), 0);
$$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused_with(text, text[], text),
  pg_temp.book(uuid, text, jsonb), pg_temp.sees(uuid), pg_temp.balance(uuid, text) to authenticated;

-- ---- 1. The rules ---------------------------------------------------------------------------------------------
select pg_temp.check((select values->'cover'->>'on' = 'false' and (values->'stairs'->>'perFloor')::numeric = 15
                        from public.delivery_addon_rules where level = 'default'),
  'the Default rule is seeded with the built-in values, switched off');
select pg_temp.refused_with($q$insert into public.delivery_addon_rules (level, country, values)
  values ('country', 'Nowhere 312', '{"cover": {"pct": 200}}')$q$, array['delivery_addon_rules_valid'], 'a 200% premium');
select pg_temp.refused_with($q$insert into public.delivery_addon_rules (level, country, values)
  values ('country', 'Nowhere 312', '{"tips": {"on": true}}')$q$, array['delivery_addon_rules_valid'], 'an unknown add-on');
select pg_temp.refused_with($q$insert into public.delivery_addon_rules (level, country, values)
  values ('country', 'Nowhere 312', '{"cold": {"levels": [{"id": "a", "name": "A", "charge": 1}, {"id": "a", "name": "B", "charge": 2}]}}')$q$,
  array['delivery_addon_rules_valid'], 'two levels with one id');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c1');
select pg_temp.refused_with($q$insert into public.delivery_addon_rules (level, country, values)
  values ('country', 'Addonland 312', '{}')$q$, array['row-level security', 'permission denied'], 'a sender writing a rule');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312a1');
update public.delivery_addon_rules
   set values = public.delivery_addons_merge(values, '{"cover": {"on": true}, "roundTrip": {"on": true},
                  "stairs": {"on": true}, "cold": {"on": true}, "cod": {"on": true}}')
 where level = 'default';
insert into public.delivery_addon_rules (level, country, values)
values ('country', 'Addonland 312', '{"stairs": {"perFloor": 10}, "cod": {"max": 500, "carry": 500}}');
reset role;
select pg_temp.check((select (a->'stairs'->>'perFloor')::numeric = 10 and (a->'stairs'->>'maxFloors')::numeric = 10
                             and (a->'cod'->>'max')::numeric = 500 and (a->'cod'->>'pct')::numeric = 2
                             and a->'cover'->>'on' = 'true'
                        from (select public.delivery_addons_at('Addonland 312', '', '', '') a) x),
  'the region rule keeps only what it sets, the rest is Default''s');
select pg_temp.check((public.delivery_addons_at('Elsewhere 312', '', '', '')->'stairs'->>'perFloor')::numeric = 15,
  'another country follows Default');
select pg_temp.check(public.delivery_cover_premium(800, '{"pct": 1, "min": 2}') = 8
                     and public.delivery_cover_premium(50, '{"pct": 1, "min": 2}') = 2
                     and public.delivery_cod_fee(250, '{"pct": 2, "min": 1}') = 5
                     and public.delivery_cod_fee(20, '{"pct": 2, "min": 1}') = 1
                     and public.delivery_return_charge(180, '{"returnPct": 80}') = 144
                     and public.delivery_return_wait_fee(20, '{"freeWait": 15, "waitPerMin": 0.5, "maxWait": 120}') = 2.5
                     and public.delivery_return_wait_fee(500, '{"freeWait": 15, "waitPerMin": 0.5, "maxWait": 120}') = 52.5,
  'the amounts: premium with its minimum, COD fee, return leg, wait past the free minutes up to the longest');

-- ---- 2. Freight bookings: stairs and the cold truck --------------------------------------------------------------
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Lorry 312',
  '{"fare": 120, "sp": 2, "lines": [{"kind": "stairs", "name": "Stairs", "amount": 30}]}')$q$,
  array['ADDON_CHARGE_CHANGED'], 'stairs at Default''s 15 a floor, not the region''s 10');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Lorry 312',
  '{"fare": 100, "sp": 2}')$q$, array['ADDON_CHARGE_CHANGED'], 'stairs without their line');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Lorry 312',
  '{"fare": 140, "sp": 4, "lines": [{"kind": "stairs", "name": "Stairs", "amount": 40}]}')$q$,
  array['STAIRS_HELPER_REQUIRED'], '4 floors without a helper');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Lorry 312',
  '{"fare": 210, "sd": 11, "option_names": {"helper-1": "1 helper"}, "lines": [{"kind": "stairs", "name": "Stairs", "amount": 110}]}')$q$,
  array['STAIRS_TOO_MANY'], '11 floors');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Moto 312',
  '{"size": "S", "fare": 30, "sp": 2, "lines": [{"kind": "stairs", "name": "Stairs", "amount": 20}]}')$q$,
  array['ADDON_FREIGHT_ONLY'], 'stairs on a courier');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Lorry 312',
  '{"fare": 160, "cold": "chilled", "lines": [{"kind": "cold-truck", "name": "Cold truck", "amount": 60}]}')$q$,
  array['COLD_TRUCK_NOT_REFRIGERATED'], 'a cold truck on a plain lorry');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Cold 312',
  '{"fare": 160, "cold": "deep", "lines": [{"kind": "cold-truck", "name": "Cold truck", "amount": 60}]}')$q$,
  array['COLD_LEVEL_UNKNOWN'], 'an unknown temperature');
insert into rides values ('stairs', pg_temp.book('00000000-0000-0000-0000-0000000312c1', 'Lorry 312',
  '{"fare": 140, "sp": 4, "option_names": {"helper-1": "1 helper"}, "lines": [{"kind": "stairs", "name": "Stairs", "amount": 40}]}'));
select pg_temp.refused_with($q$update public.ride_requests set stairs_pickup = 1 where id = (select id from rides where k = 'stairs')$q$,
  array['ADDONS_FIXED'], 'the sender changing the floors');
insert into rides values ('cold', pg_temp.book('00000000-0000-0000-0000-0000000312c2', 'Cold 312',
  '{"fare": 160, "cold": "chilled", "lines": [{"kind": "cold-truck", "name": "Cold truck", "amount": 60}]}'));
reset role;
select pg_temp.check((select stairs_pickup = 4 and stairs_drop is null and addon_terms ? 'stairs'
                        from public.ride_requests where id = (select id from rides where k = 'stairs')),
  'the stairs booked, with the terms kept');
update public.ride_requests set status = 'expired' where id = (select id from rides where k = 'stairs');

-- Only a refrigerated vehicle reads or offers on the cold-truck request.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'cold')) = 1, 'the refrigerated lorry sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'cold')) = 0, 'the plain lorry doesn''t');
select pg_temp.refused_with(format('select public.ride_offer_make(%L, 160)', (select id from rides where k = 'cold')),
  array['COLD_TRUCK_DRIVER', 'FREIGHT_DRIVER_NO_FREIGHT'], 'the plain lorry''s offer');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d1');
insert into rides select 'cold-offer', (public.ride_offer_make((select id from rides where k = 'cold'), 160)->>'id')::uuid;
reset role;
select pg_temp.check((select count(*) = 1 from public.ride_offers where id = (select id from rides where k = 'cold-offer')),
  'the refrigerated lorry''s offer is in');

-- ---- 3. Courier bookings: cover and cash on delivery -------------------------------------------------------------
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Moto 312',
  '{"size": "S", "declared": 800}')$q$, array['COURIER_DECLARED_VALUE_CAP'], '800 uncovered, over the courier cap');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Moto 312',
  '{"size": "S", "declared": 6000, "cover": true, "fare": 70, "lines": [{"kind": "parcel-cover", "name": "Parcel cover", "amount": 60}]}')$q$,
  array['COVER_VALUE_MAX'], 'over the cover''s 5,000');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Moto 312',
  '{"size": "S", "declared": 800, "cover": true, "fare": 12, "lines": [{"kind": "parcel-cover", "name": "Parcel cover", "amount": 2}]}')$q$,
  array['ADDON_CHARGE_CHANGED'], 'the cover''s minimum instead of 1% of 800');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Moto 312',
  '{"size": "S", "cod": 600}')$q$, array['COD_TOO_HIGH'], 'COD over the region''s 500');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Lorry 312',
  '{"fare": 100, "cod": 50}')$q$, array['COD_COURIER_ONLY'], 'COD on freight');
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Moto 312',
  '{"size": "S", "fare": 18, "lines": [{"kind": "round-trip", "name": "Return leg", "amount": 8}]}')$q$,
  array['ADDON_CHARGE_CHANGED'], 'a return line without the round trip');
insert into rides values ('cover', pg_temp.book('00000000-0000-0000-0000-0000000312c3', 'Moto 312',
  '{"size": "S", "declared": 800, "cover": true, "fare": 18, "lines": [{"kind": "parcel-cover", "name": "Parcel cover", "amount": 8}]}'));
insert into rides values ('cod', pg_temp.book('00000000-0000-0000-0000-0000000312c4', 'Moto 312', '{"size": "S", "cod": 250}'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c4');
select pg_temp.refused_with($q$update public.ride_requests set cod_fee = 0 where id = (select id from rides where k = 'cod')$q$,
  array['ADDONS_SERVER_ONLY'], 'the sender setting the COD fee');
reset role;
select pg_temp.check((select cod_fee = 5 and cod_status = 'pending' and (addon_terms->'cod'->>'carry')::numeric = 500
                        from public.ride_requests where id = (select id from rides where k = 'cod')),
  'COD 250: the server''s 5 fee, pending, the terms kept');
update public.ride_requests set status = 'expired' where id = (select id from rides where k = 'cover');

-- The courier takes it only with room in the carry limit and the GET.wallet.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
select pg_temp.refused_with(format('select public.ride_offer_make(%L, 10)', (select id from rides where k = 'cod')),
  array['COD_WALLET_SHORT'], 'an empty GET.wallet');
reset role;
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
values ('00000000-0000-0000-0000-0000000312d3', 'get_wallet', 'topup', 300, 'Test top-up');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
insert into rides select 'cod-offer', (public.ride_offer_make((select id from rides where k = 'cod'), 10)->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c4');
select public.ride_offer_accept((select id from rides where k = 'cod-offer'));
insert into rides values ('cod2', pg_temp.book('00000000-0000-0000-0000-0000000312c5', 'Moto 312', '{"size": "S", "cod": 300}'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
select pg_temp.refused_with(format('select public.ride_offer_make(%L, 10)', (select id from rides where k = 'cod2')),
  array['COD_CARRY_LIMIT'], 'holding 250, a 300 COD over the 500 carry limit');
reset role;
update public.ride_requests set status = 'expired' where id = (select id from rides where k = 'cod2');

-- ---- 4. The COD trip ------------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'cod');
update public.ride_requests set pickup_proof_path = '00000000-0000-0000-0000-0000000312d3/proof-pickup.jpg'
 where id = (select id from rides where k = 'cod');
update public.ride_requests set status = 'on_trip' where id = (select id from rides where k = 'cod');
update public.ride_requests set dropoff_proof_path = '00000000-0000-0000-0000-0000000312d3/proof-dropoff.jpg'
 where id = (select id from rides where k = 'cod');
select pg_temp.refused_with($q$update public.ride_requests set cod_status = 'collected' where id = (select id from rides where k = 'cod')$q$,
  array['ADDONS_SERVER_ONLY'], 'the courier stamping the COD');
select pg_temp.refused_with($q$update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'cod')$q$,
  array['COD_NOT_SETTLED'], 'finishing with the COD unsettled');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c4');
select pg_temp.refused_with(format('select public.cod_collected(%L)', (select id from rides where k = 'cod')),
  array['not_authorized'], 'the sender settling it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
select pg_temp.check((public.cod_collected((select id from rides where k = 'cod'))->>'paid')::numeric = 245, 'settled: 245 paid');
select pg_temp.check((public.cod_collected((select id from rides where k = 'cod'))->>'already')::boolean, 'twice is once');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000312d3', 'get_wallet') = 50
                     and pg_temp.balance('00000000-0000-0000-0000-0000000312c4', 'get_wallet') = 245
                     and (select cod_status = 'collected' from public.ride_requests where id = (select id from rides where k = 'cod')),
  'the courier''s GET.wallet paid 250, the sender got 245');

-- "Recipient won't pay": back at the return rate, no code needed.
insert into rides values ('ref', gen_random_uuid());
insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                  drop_lat, drop_lng, cargo_description, parcel_size, recipient_phone, cod_amount,
                                  declared_value, prohibited_ack, currency)
values ((select id from rides where k = 'ref'), '00000000-0000-0000-0000-0000000312c6', '00000000-0000-0000-0000-0000000312d3',
        'on_trip', 'Moto 312', 10, 10, 30, 120, 30.1, 120.1, 'Shoes', 'S', '+60123456780', 50, 100, true, 'RM');
select pg_temp.check((select cod_status = 'pending' and cod_fee = 1 and addon_terms is not null
                        from public.ride_requests where id = (select id from rides where k = 'ref')),
  'a server booking gets the COD fee and the terms too');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
select pg_temp.check((public.cod_refused((select id from rides where k = 'ref'))->>'return_fare')::numeric = 8,
  'won''t pay: 80% of the outward 10 to come back');
update public.ride_requests set dropoff_proof_path = '00000000-0000-0000-0000-0000000312d3/proof-back.jpg'
 where id = (select id from rides where k = 'ref');
update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'ref');
reset role;
select pg_temp.check((select status = 'completed' and fare = 18 and cod_status = 'refused' and delivery_code_ok_at is null
                        from public.ride_requests where id = (select id from rides where k = 'ref')),
  'returned to the sender at 18, without the recipient''s code');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000312c6'
                                and event_id = 'cod-refused:' || (select id from rides where k = 'ref')),
  'the sender is told');

-- ---- 5. A round trip ----------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000312c5', 'Lorry 312',
  '{"fare": 200, "round": true, "lines": [{"kind": "round-trip", "name": "Return leg", "amount": 100}]}')$q$,
  array['ADDON_CHARGE_CHANGED'], 'a return leg at 50%');
insert into rides values ('rt', pg_temp.book('00000000-0000-0000-0000-0000000312c5', 'Lorry 312',
  '{"fare": 180, "round": true, "lines": [{"kind": "round-trip", "name": "Return leg", "amount": 80}]}'));
reset role;
select pg_temp.check((select return_leg_fare = 80 from public.ride_requests where id = (select id from rides where k = 'rt')),
  'the return leg is 80% of the outward 100');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d2');
insert into rides select 'rt-offer', (public.ride_offer_make((select id from rides where k = 'rt'), 180)->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c5');
select public.ride_offer_accept((select id from rides where k = 'rt-offer'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d2');
update public.ride_requests set status = 'arrived' where id = (select id from rides where k = 'rt');
update public.ride_requests set pickup_proof_path = '00000000-0000-0000-0000-0000000312d2/proof-pickup.jpg'
 where id = (select id from rides where k = 'rt');
update public.ride_requests set status = 'on_trip' where id = (select id from rides where k = 'rt');
select pg_temp.refused_with(format('select public.delivery_return_arrived(%L)', (select id from rides where k = 'rt')),
  array['ROUND_TRIP_DROP_FIRST'], 'at the drop-off without its photo');
update public.ride_requests set dropoff_proof_path = '00000000-0000-0000-0000-0000000312d2/proof-dropoff.jpg'
 where id = (select id from rides where k = 'rt');
select pg_temp.refused_with($q$update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'rt')$q$,
  array['ROUND_TRIP_RETURN_FIRST'], 'ending before the return leg');
select pg_temp.refused_with(format('select public.delivery_return_start(%L)', (select id from rides where k = 'rt')),
  array['ROUND_TRIP_ARRIVE_FIRST'], 'heading back before saying they are at the drop-off');
select public.delivery_return_arrived((select id from rides where k = 'rt'));
reset role;
update public.ride_requests set return_arrived_at = now() - interval '20 minutes 10 seconds'
 where id = (select id from rides where k = 'rt');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d2');
select pg_temp.check((public.delivery_return_start((select id from rides where k = 'rt'))->>'wait_fee')::numeric = 2.5,
  '20 minutes waited, 15 free, 0.50 a minute');
update public.ride_requests set status = 'completed' where id = (select id from rides where k = 'rt');
reset role;
select pg_temp.check((select status = 'completed' and fare = 182.5 and return_wait_minutes = 20
                        from public.ride_requests where id = (select id from rides where k = 'rt')),
  'back at the pickup: 182.50 for both legs and the wait');

-- ---- 6. The cover premium and claims ---------------------------------------------------------------------------------
select pg_temp.check(public.ride_option_charges_off(
  '[{"kind": "parcel-cover", "name": "Parcel cover", "amount": 8}, {"kind": "round-trip", "name": "Return leg", "amount": 5}]',
  'commission') = 8, 'commission: the premium left out, the return leg in');
insert into rides values ('claim', gen_random_uuid()), ('late', gen_random_uuid());
insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                  drop_lat, drop_lng, cargo_description, parcel_size, recipient_phone, declared_value,
                                  prohibited_ack, currency, parcel_cover, option_charges, delivery_code_ok_at)
select r.id, '00000000-0000-0000-0000-0000000312c3', '00000000-0000-0000-0000-0000000312d3', 'on_trip', 'Moto 312',
       18, 18, 30, 120, 30.1, 120.1, 'Phone', 'S', '+60123456780', 800, true, 'RM', true,
       '[{"kind": "parcel-cover", "name": "Parcel cover", "amount": 8}]', now()
  from rides r where r.k in ('claim', 'late');
update public.ride_requests set status = 'completed' where id in (select id from rides where k in ('claim', 'late'));
select pg_temp.check((select count(*) = 1 and sum(amount) = -8 from public.wallet_transactions
                       where ride_id = (select id from rides where k = 'claim') and kind = 'cover_premium'
                         and user_id = '00000000-0000-0000-0000-0000000312d3' and wallet_type = 'get_credit'),
  'the premium is taken from the courier''s GET.credit');
update public.ride_requests set completed_at = now() - interval '8 days' where id = (select id from rides where k = 'late');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c3');
select pg_temp.refused_with(format('select public.cover_claim_file(%L, 300, %L)', (select id from rides where k = 'late'),
  'The screen arrived cracked'), array['COVER_CLAIM_LATE'], 'past the 7 claim days');
select pg_temp.refused_with(format('select public.cover_claim_file(%L, 900, %L)', (select id from rides where k = 'claim'),
  'The screen arrived cracked'), array['COVER_CLAIM_AMOUNT'], 'over the declared 800');
insert into rides select 'claim-row', (public.cover_claim_file((select id from rides where k = 'claim'), 300,
  'The screen arrived cracked')->>'id')::uuid;
select pg_temp.refused_with(format('select public.cover_claim_file(%L, 100, %L)', (select id from rides where k = 'claim'),
  'And the box was wet'), array['COVER_CLAIM_EXISTS'], 'a second claim');
select pg_temp.check((select count(*) = 1 from public.cover_claims where status = 'open'
                       and id = (select id from rides where k = 'claim-row')), 'the sender reads their claim');
select pg_temp.refused_with(format('select public.cover_claim_decide(%L, true)', (select id from rides where k = 'claim-row')),
  array['NOT_ALLOWED'], 'the sender approving it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312d3');
select pg_temp.check((select count(*) = 0 from public.cover_claims), 'the courier reads no claim');
select pg_temp.as_user('00000000-0000-0000-0000-0000000312a1');
select public.cover_claim_decide((select id from rides where k = 'claim-row'), true, 250, 'Paid on the photos');
select pg_temp.refused_with(format('select public.cover_claim_decide(%L, false)', (select id from rides where k = 'claim-row')),
  array['COVER_CLAIM_DECIDED'], 'deciding twice');
reset role;
select pg_temp.check((select status = 'approved' and paid_amount = 250 from public.cover_claims
                       where id = (select id from rides where k = 'claim-row'))
                     and pg_temp.balance('00000000-0000-0000-0000-0000000312c3', 'get_wallet') = 250,
  'approved: 250 in the sender''s GET.wallet');
select pg_temp.check(exists (select 1 from public.admin_audit_log where action = 'cover_claim.approved'
                              and target_profile_id = '00000000-0000-0000-0000-0000000312c3'), 'in the audit log');

-- ---- 7. A booking for later ------------------------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.set_scheduled_rides_config(jsonb)') is not null then
    perform set_config('request.jwt.claims', '', true);
    perform public.set_scheduled_rides_config('{"enabled": true, "mode": "advance"}');
  end if;
end $$;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000312c6');
select pg_temp.refused_with($q$select public.schedule_ride('{"service": "Lorry 312", "pickup_lat": 30.0, "pickup_lng": 120.0,
  "drop_lat": 30.1, "drop_lng": 120.1, "fare": 100, "cargo_description": "Boxes", "prohibited_ack": true,
  "declared_value": 50, "stairs_pickup": 2, "country": "Addonland 312"}'::jsonb, now() + interval '3 hours')$q$,
  array['ADDON_CHARGE_CHANGED'], 'for later: stairs without their line');
select public.schedule_ride('{"service": "Lorry 312", "pickup_lat": 30.0, "pickup_lng": 120.0,
  "drop_lat": 30.1, "drop_lng": 120.1, "fare": 200, "cargo_description": "Boxes", "prohibited_ack": true,
  "declared_value": 50, "stairs_pickup": 2, "round_trip": true, "country": "Addonland 312",
  "option_charges": [{"kind": "stairs", "name": "Stairs", "amount": 20}, {"kind": "round-trip", "name": "Return leg", "amount": 80}]}'::jsonb,
  now() + interval '3 hours');
reset role;
select pg_temp.check((select (request->>'stairs_pickup')::int = 2 and request->'round_trip' = 'true'::jsonb
                        from public.scheduled_rides where rider_id = '00000000-0000-0000-0000-0000000312c6'
                       order by created_at desc limit 1), 'the booking keeps the add-ons');

select pg_temp.check(not has_function_privilege('authenticated', 'public.driver_takes_cold(uuid)', 'execute')
                     and not has_function_privilege('authenticated',
                       'public.delivery_driver_problem(uuid, public.ride_requests)', 'execute')
                     and has_function_privilege('authenticated', 'public.cod_collected(uuid)', 'execute'),
  'the eligibility is the server''s; the driver''s steps are RPCs');

select 'freight_addons_0312: all passed';
rollback;
