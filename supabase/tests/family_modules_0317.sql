-- ============================================================================
-- Regression test for migration 0317, section 9: Family in the modules that
-- landed after it was first written (0309 to 0316).
--   1. City to City, a whole car paid 'family': the fare held from the
--      host's GET.wallet (never the member's), released to the driver less
--      commission at completion; a cancel inside the fee hours: the fee kept,
--      the rest back to the host; the pay sheet shows the host's wallet.
--   2. A seat on a posted trip (0310): off until the admin turns 'seat_trip'
--      on; the member's seat held from the host's wallet; the host books a
--      seat for the member (p_family), and can't make the family pay for it.
--   3. A tip (0314) on a family-paid ride: from the host's GET.wallet.
--   4. A business trip (0313) can't be family-paid too (FAMILY_BUSINESS).
--   5. Money that is the member's own (cash on delivery) stays theirs.
--   6. A held fare refunded after the member left the family goes back to
--      the host, who paid it.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/family_modules_0317.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000317f0a1'),  -- host
  ('00000000-0000-0000-0000-00000317f0a2'),  -- member
  ('00000000-0000-0000-0000-00000317f0b1')   -- driver
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-00000317f0a1', 'Karim Contoh', '+60100031771'),
  ('00000000-0000-0000-0000-00000317f0a2', 'Lina Contoh', '+60100031772'),
  ('00000000-0000-0000-0000-00000317f0b1', 'Hafiz Sample', '+60100031779')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

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
-- [p_sql] as [p_user]: its value as text, or the error.
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return coalesce(nullif(v, ''), 'ok');
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.bal(p_user uuid) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = 'get_wallet'), 0);
$$;
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric) returns void language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, 'get_wallet', 'test_adjust', p_to - pg_temp.bal(p_user), 'test 0317 modules');
  end if;
end $$;
create or replace function pg_temp.spent(p_trip uuid) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.family_spend where trip_id = p_trip;
$$;
create temp table t (k text primary key, id uuid);
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;

-- ---- The family -------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-00000317f0a1',
  $q$select public.family_invite('{"country": "Semenanjung 317"}', '+60100031772', 'Lina', 'daughter')->>'id'$q$)
  ~ '^[0-9a-f-]{36}$', 'the host invites the member');
insert into t select 'm', id from public.family_members
 where family_id = (select id from public.families where host_id = '00000000-0000-0000-0000-00000317f0a1');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
  format('select public.family_respond(%L, true, ''{"shown": ["payments"]}'')', pg_temp.id('m'))) not like '%FAMILY%',
  'the member joins');
select pg_temp.check((select status = 'active' from public.family_members where id = pg_temp.id('m')), 'joined');

-- ---- City to City: places, the service, the driver (as 0309's and 0310's tests) ------------------------
create or replace function pg_temp.kl() returns jsonb language sql as $$
  select '{"country": "Semenanjung 317", "state": "Kuala Lumpur 317", "city": "Kuala Lumpur 317", "suburb": "Ampang 317"}'::jsonb;
$$;
create or replace function pg_temp.ipoh() returns jsonb language sql as $$
  select '{"country": "Semenanjung 317", "state": "Perak 317", "city": "Ipoh 317"}'::jsonb;
$$;
update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
insert into public.countries (name, values) values ('Semenanjung 317', '{}');
update public.city_to_city_settings
   set cancel_fee_on = true, cancel_fee_amount = 20, cancel_free_hours = 24, pay_in_app = true, pay_cash = true,
       min_years_on = true, min_years = 3, default_book_ahead_days = 14,
       owed_from_topup = false, owed_next_in_app = false, owed_cash_collect = false, owed_block = false,
       reminders_on = false
 where id = 1;
insert into public.c2c_route_rules (from_places, to_places, fare_mode, fixed_fare, range_mode, book_ahead_days, position)
values ('[{"level": "city", "country": "Semenanjung 317", "state": "Kuala Lumpur 317", "city": "Kuala Lumpur 317"}]',
        '[{"level": "state", "country": "Semenanjung 317", "state": "Perak 317"}]', 'fixed', 140, 'auto', 14, 1);
insert into public.commission_service_rates (service_id, service_name, rate)
select id::text, 'City to City', 0.12 from public.settings_entries
 where category = 'vehicle-services' and values->>'name' = 'City to City'
on conflict (service_id) do update set rate = 0.12, active = true;
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states,
                             rating, total_rides, make, model, plate) values
  ('00000000-0000-0000-0000-00000317f0e1', '00000000-0000-0000-0000-00000317f0b1', 'Hafiz Sample', '+60100031779',
   'approved', '{eHailing}', '{Semenanjung 317}', '{Semenanjung 317|Kuala Lumpur 317}', 4.9, 300, 'Honda', 'City', 'VKB 317');
update public.partners set driving_since = current_date - interval '10 years'
 where id = '00000000-0000-0000-0000-00000317f0e1';

-- A whole-car request by the member, paid [p_payment], leaving in [p_leave], kept as [p_k].
create or replace function pg_temp.request(p_k text, p_leave interval, p_payment text default 'family')
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.c2c_bookings (rider_id, pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
                                   drop_lng, drop_place, distance_km, duration_min, leave_at, passengers, luggage, fare,
                                   payment)
  values ('00000000-0000-0000-0000-00000317f0a2', '12 Jalan Ampang', 3.15, 101.70, pg_temp.kl(), '21 Jalan Sampel',
          4.60, 101.08, pg_temp.ipoh(), 205, 160, now() + p_leave, 1, 'small', 140, p_payment)
  returning id into v;
  insert into t values (p_k, v);
  return v;
end $$;
-- The driver offers RM 140 on [p_k] and the member accepts it (the rule's way): the result.
create or replace function pg_temp.offer_accept(p_k text) returns text language plpgsql as $$
declare v_offer uuid;
begin
  perform pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-00000317f0b1',
    format('select public.c2c_make_offer(%L, 140)::text', pg_temp.id(p_k))) not like '%C2C_%', 'offered on ' || p_k);
  select id into v_offer from public.c2c_offers where booking_id = pg_temp.id(p_k) and status = 'open';
  return pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
                          format('select public.c2c_accept_offer_pay(%L, null, 140)::text', v_offer));
end $$;
create or replace function pg_temp.step(p_k text, p_to text) returns text language sql as $$
  select pg_temp.value_as('00000000-0000-0000-0000-00000317f0b1',
                          format('select public.c2c_driver_progress(%L, %L)::text', pg_temp.id(p_k), p_to));
$$;

select pg_temp.set_bal('00000000-0000-0000-0000-00000317f0a1', 500);
select pg_temp.set_bal('00000000-0000-0000-0000-00000317f0a2', 0);
select pg_temp.set_bal('00000000-0000-0000-0000-00000317f0b1', 0);

-- ---- 1. A whole car paid 'family' -------------------------------------------------------------------------
select pg_temp.request('A', interval '3 days');
select pg_temp.check((select family_pays and module_key = 'city_to_city'
                             and payer_id = '00000000-0000-0000-0000-00000317f0a1'
                        from public.family_trips where trip_id = pg_temp.id('A')), 'A: registered as family-paid');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
                        format('select public.c2c_pay_info(%L)::text', pg_temp.id('A')))::jsonb->>'walletBalance')::numeric = 500
                     and not (pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
                        format('select public.c2c_pay_info(%L)::text', pg_temp.id('A')))::jsonb->>'coin')::boolean,
  'A: the pay sheet shows the host''s GET.wallet, no coins');
select pg_temp.check(pg_temp.offer_accept('A')::jsonb->>'payStatus' = 'held', 'A: accepted, the fare held');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 360
                     and pg_temp.bal('00000000-0000-0000-0000-00000317f0a2') = 0,
  'A: held from the host''s wallet, not the member''s: ' || pg_temp.bal('00000000-0000-0000-0000-00000317f0a1'));
select pg_temp.check(pg_temp.spent(pg_temp.id('A')) = 140, 'A: counted on the member''s limit');
select pg_temp.check((select method = 'get_wallet' and wallet_amount = 140 and coins = 0
                        from public.c2c_payments where booking_id = pg_temp.id('A') and status = 'held'),
  'A: the payment is GET.wallet only');
select pg_temp.check((select bool_and(ride_id = pg_temp.id('A')) from public.wallet_transactions
                       where note like '%' || (select ref from public.c2c_bookings where id = pg_temp.id('A')) || '%'),
  'A: every row names the trip');
select pg_temp.check(pg_temp.step('A', 'on_trip') = 'ok' and pg_temp.step('A', 'completed') = 'ok', 'A: driven');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0b1') = 123.20
                     and (select pay_status = 'paid' from public.c2c_bookings where id = pg_temp.id('A')),
  'A: released to the driver less 12% commission: ' || pg_temp.bal('00000000-0000-0000-0000-00000317f0b1'));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 360, 'A: nothing more from the host');

-- A cancel inside the fee hours: the fee kept, the rest back to the host.
select pg_temp.request('B', interval '5 hours');
select pg_temp.check(pg_temp.offer_accept('B')::jsonb->>'payStatus' = 'held', 'B: held');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 220, 'B: held from the host');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
                        format('select public.c2c_cancel(%L)::text', pg_temp.id('B')))::jsonb->>'fee')::numeric = 20,
  'B: the member cancels, a RM 20 fee');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 340
                     and pg_temp.bal('00000000-0000-0000-0000-00000317f0a2') = 0,
  'B: RM 120 back to the host, nothing to the member: ' || pg_temp.bal('00000000-0000-0000-0000-00000317f0a1'));
select pg_temp.check(pg_temp.spent(pg_temp.id('B')) = 20, 'B: the family spent the fee only');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0b1') = 123.20 + 17.60,
  'B: the fee to the driver less commission');

-- ---- 2. A seat on a posted trip ----------------------------------------------------------------------------
update public.c2c_seat_rules set seats_on = true, women_on = false where place is null;
insert into t select 'trip', (pg_temp.value_as('00000000-0000-0000-0000-00000317f0b1', format(
  'select public.c2c_post_trip(%L::jsonb, %L::jsonb, 205, 150, now() + interval ''3 days'', %L::jsonb, 3, 45, ''instant'')::text',
  jsonb_build_object('name', 'Kuala Lumpur 317', 'lat', 3.15, 'lng', 101.71, 'place', pg_temp.kl()),
  jsonb_build_object('name', 'Ipoh 317', 'lat', 4.60, 'lng', 101.09, 'place', pg_temp.ipoh()),
  '[{"name": "Petrol station 317", "lat": 3.13, "lng": 101.72, "minutes": 0}]'))::jsonb->'ids'->>0)::uuid;
select pg_temp.check(pg_temp.id('trip') is not null, 'the driver posts a trip');
create or replace function pg_temp.book(p_user uuid, p_args text) returns text language sql as $$
  select pg_temp.value_as(p_user, format('select public.c2c_book_seat(%L::uuid, %s)::text', pg_temp.id('trip'), p_args));
$$;
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-00000317f0a2',
  '1, ''{"kind": "meeting", "index": 0}'', ''family''') like 'FAMILY_MODULE_OFF%',
  'seats: off until the admin turns seat_trip on');
insert into public.family_module_rules (level, module_key, family_pays, book_for_member, child_allowed, live_share)
values ('default', 'seat_trip', true, true, false, true)
on conflict (place_key, module_key) do update set family_pays = true, book_for_member = true;
insert into t select 'seat', (pg_temp.book('00000000-0000-0000-0000-00000317f0a2',
  '1, ''{"kind": "meeting", "index": 0}'', ''family'', null, null, 45')::jsonb->>'id')::uuid;
select pg_temp.check((select status = 'booked' and payment = 'family' and pay_status = 'held'
                        from public.c2c_bookings where id = pg_temp.id('seat')), 'seats: the member''s seat, held');
select pg_temp.check((select family_pays and module_key = 'seat_trip' from public.family_trips
                       where trip_id = pg_temp.id('seat')), 'seats: registered as a family-paid seat trip');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 295
                     and pg_temp.bal('00000000-0000-0000-0000-00000317f0a2') = 0,
  'seats: held from the host''s wallet: ' || pg_temp.bal('00000000-0000-0000-0000-00000317f0a1'));
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-00000317f0a1',
  format('1, ''{"kind": "meeting", "index": 0}'', ''family'', p_family => %L::jsonb',
         jsonb_build_object('passenger', pg_temp.id('m')))) like 'FAMILY_ONLY_FOR_MEMBER%',
  'seats: the host can''t make the family pay for a seat they book');
insert into t select 'hostseat', (pg_temp.book('00000000-0000-0000-0000-00000317f0a1',
  format('1, ''{"kind": "meeting", "index": 0}'', ''cash'', p_family => %L::jsonb',
         jsonb_build_object('passenger', pg_temp.id('m'), 'withAdult', false, 'other', 1)))::jsonb->>'id')::uuid;
select pg_temp.check((select family = jsonb_build_object('passenger', pg_temp.id('m'))
                        from public.c2c_bookings where id = pg_temp.id('hostseat')), 'seats: who it is for is kept, nothing else');
select pg_temp.check((select not family_pays and module_key = 'seat_trip'
                             and booked_by = '00000000-0000-0000-0000-00000317f0a1'
                        from public.family_trips where trip_id = pg_temp.id('hostseat')),
  'seats: the host books a seat for the member');

-- ---- 3. A tip on a family-paid ride ---------------------------------------------------------------------------
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country)
values ('00000000-0000-0000-0000-00000317f0d1', '00000000-0000-0000-0000-00000317f0a2', 'open', 3.1, 101.6, 15, 15,
        'Family', 'Semenanjung 317');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-00000317f0b1', status = 'accepted'
 where id = '00000000-0000-0000-0000-00000317f0d1';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-00000317f0d1';
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-00000317f0d1';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
  $q$select public.ride_pay('00000000-0000-0000-0000-00000317f0d1', 'family')::text$q$) like '{%',
  'tip: the ride is paid with Family');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 280, 'tip: the fare from the host');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
  $q$select public.ride_tip('00000000-0000-0000-0000-00000317f0d1', 5, 'get_wallet')::text$q$)::jsonb->>'family')::boolean,
  'tip: the member tips RM 5');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 275
                     and pg_temp.bal('00000000-0000-0000-0000-00000317f0a2') = 0,
  'tip: from the host''s GET.wallet: ' || pg_temp.bal('00000000-0000-0000-0000-00000317f0a1'));
select pg_temp.check(pg_temp.spent('00000000-0000-0000-0000-00000317f0d1') = 20, 'tip: counted on the member''s limit');

-- ---- 4. Business and Family, never both -----------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2', $q$
  insert into public.ride_requests (rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode,
                                    business_account_id, country)
  values ('00000000-0000-0000-0000-00000317f0a2', 'open', 3.1, 101.6, 15, 15, 'Family',
          '00000000-0000-0000-0000-00000317f0ff', 'Semenanjung 317') returning 'inserted'$q$) like 'FAMILY_BUSINESS%',
  'a business trip can''t be family-paid');

-- ---- 5. The member's own money stays theirs -------------------------------------------------------------------
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
values ('00000000-0000-0000-0000-00000317f0a2', 'get_wallet', 'cod_payout', 5, 'cod', 'test 0317 modules',
        '00000000-0000-0000-0000-00000317f0d1');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a2') = 5
                     and pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 275,
  'cash on delivery for the member''s item is not a refund to the host');

-- ---- 6. A refund after the member left goes back to the host -------------------------------------------------
select pg_temp.request('C', interval '6 days');  -- the driver's seat trip is in 3 days
select pg_temp.check(pg_temp.offer_accept('C')::jsonb->>'payStatus' = 'held', 'C: held');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 135, 'C: held from the host');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2', 'select public.family_leave()::text') = 'ok',
  'C: the member leaves the family');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-00000317f0a2',
                        format('select public.c2c_cancel(%L)::text', pg_temp.id('C')))::jsonb->>'fee')::numeric = 0,
  'C: the member cancels, no fee');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-00000317f0a1') = 275
                     and pg_temp.bal('00000000-0000-0000-0000-00000317f0a2') = 5,
  'C: the fare back to the host who paid it: ' || pg_temp.bal('00000000-0000-0000-0000-00000317f0a1'));
select pg_temp.check(pg_temp.spent(pg_temp.id('C')) = 0, 'C: nothing spent');

rollback;
