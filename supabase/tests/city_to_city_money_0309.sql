-- ============================================================================
-- Regression test for migration 0309: City to City money and reminders.
--   * rules by region: the default always there, the most specific region
--     wins, inactive ones skipped, only admins with EDIT write;
--   * a driver giving a booked trip up: no fee by default; the rule's fee
--     inside its hours, to the rider, get.ride or split; a short wallet
--     going below zero (on GET.credit) or the rest owed and taken from the
--     next earnings, the rider's part paid as it comes in;
--   * in-app payment held at accept (wallet, coins, mix; short refused with
--     nothing taken; the amount the rider saw), paid to the driver less
--     commission at completion and never charged twice; back to the rider
--     on a cancel (less the fee) or a give-up; paid after the trip with
--     c2c_pay (idempotent); switching to cash;
--   * cancel fees owed: added to the next in-app payment, taken from a
--     top-up, collected by the next cash trip's driver, Pay now, and the
--     block on new bookings;
--   * trip reminders: due once per booking, reminder and person; skipped
--     when their time had passed at booking or are late; push through the
--     outbox, the Notifications page without push, SMS when the push wasn't
--     confirmed; none after a cancel;
--   * the grants.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/city_to_city_money_0309.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000309a1'),  -- admin, EDIT on City to City
  ('00000000-0000-0000-0000-0000000309b1'),  -- driver 1
  ('00000000-0000-0000-0000-0000000309b2'),  -- driver 2
  ('00000000-0000-0000-0000-0000000309c1'),  -- rider 1
  ('00000000-0000-0000-0000-0000000309c2')   -- rider 2
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test 309' from auth.users
 where id::text like '00000000-0000-0000-0000-0000000309%'
on conflict (id) do update set name = excluded.name;  -- the sign-up trigger may have made the row
update public.profiles set name = 'Farah Tan Contoh', phone = '+60100030991' where id = '00000000-0000-0000-0000-0000000309c1';
update public.profiles set name = 'Rider Dua', phone = '+60100030992' where id = '00000000-0000-0000-0000-0000000309c2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000309a1', 'admin-settings-city-to-city', 'edit')
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
-- [p_user]'s [p_type] balance.
create or replace function pg_temp.bal(p_user uuid, p_type text default 'get_wallet') returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = p_type), 0);
$$;
-- Moves [p_user]'s [p_type] balance to [p_to] through the ledger.
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric, p_type text default 'get_wallet') returns void
language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user, p_type) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, p_type, 'test_adjust', p_to - pg_temp.bal(p_user, p_type), 'test 0309');
  end if;
end $$;

-- ---- Places, the service, drivers ----------------------------------------------------------------------
create or replace function pg_temp.kl() returns jsonb language sql as $$
  select '{"country": "Semenanjung 309", "state": "Kuala Lumpur 309", "city": "Kuala Lumpur 309", "suburb": "Ampang 309"}'::jsonb;
$$;
create or replace function pg_temp.ipoh() returns jsonb language sql as $$
  select '{"country": "Semenanjung 309", "state": "Perak 309", "city": "Ipoh 309"}'::jsonb;
$$;
update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
insert into public.countries (name, values) values ('Semenanjung 309', '{}');
update public.city_to_city_settings
   set cancel_fee_on = true, cancel_fee_amount = 20, cancel_free_hours = 24, pay_in_app = true, pay_cash = true,
       min_years_on = true, min_years = 3, default_book_ahead_days = 14,
       owed_from_topup = false, owed_next_in_app = false, owed_cash_collect = false, owed_block = false,
       reminders_on = true, reminder_push = true, reminder_inbox = true, reminder_sms = false,
       reminders = '[{"minutes": 1440, "to": "both"}, {"minutes": 120, "to": "both"}, {"minutes": 30, "to": "driver"}]'
 where id = 1;
insert into public.c2c_route_rules (from_places, to_places, fare_mode, add_on_amount, range_mode, range_low, range_high,
                                    book_ahead_days, position) values
  ('[{"level": "city", "country": "Semenanjung 309", "state": "Kuala Lumpur 309", "city": "Kuala Lumpur 309"}]',
   '[{"level": "state", "country": "Semenanjung 309", "state": "Perak 309"}]', 'card', 20, 'set', 100, 200, 14, 1);
insert into public.commission_service_rates (service_id, service_name, rate)
select id::text, 'City to City', 0.12 from public.settings_entries
 where category = 'vehicle-services' and values->>'name' = 'City to City'
on conflict (service_id) do update set rate = 0.12, active = true;
update public.get_coin_settings set coins_per_currency = 100 where id = 'master';
insert into public.get_coin_settings (id, coins_per_currency) select 'master', 100
 where not exists (select 1 from public.get_coin_settings where id = 'master');

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states,
                             rating, total_rides, make, model, plate) values
  ('00000000-0000-0000-0000-0000000309e1', '00000000-0000-0000-0000-0000000309b1', 'Hafiz Rahman', '+60100030901',
   'approved', '{eHailing}', '{Semenanjung 309}', '{Semenanjung 309|Kuala Lumpur 309}', 4.9, 300, 'Toyota', 'Vios', 'WXY 1234'),
  ('00000000-0000-0000-0000-0000000309e2', '00000000-0000-0000-0000-0000000309b2', 'Driver Dua 309', '+60100030902',
   'approved', '{eHailing}', '{Semenanjung 309}', '{Semenanjung 309|Kuala Lumpur 309}', 4.5, 10, null, null, null);
update public.partners set driving_since = current_date - interval '10 years'
 where id in ('00000000-0000-0000-0000-0000000309e1', '00000000-0000-0000-0000-0000000309e2');

create temp table t (k text primary key, id uuid);
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
-- A request from Kuala Lumpur 309 to Ipoh 309 by [p_rider], leaving in [p_leave], paid [p_payment], kept as [p_k].
create or replace function pg_temp.request(p_k text, p_rider uuid, p_leave interval, p_payment text default 'cash')
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.c2c_bookings (rider_id, pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
                                   drop_lng, drop_place, distance_km, duration_min, leave_at, passengers, luggage, fare,
                                   payment)
  values (p_rider, '12 Jalan Ampang', 3.15, 101.70, pg_temp.kl(), '21 Jalan Sampel', 4.60, 101.08, pg_temp.ipoh(),
          205, 160, now() + p_leave, 1, 'small', 140, p_payment)
  returning id into v;
  insert into t values (p_k, v);
  return v;
end $$;
-- [p_driver] offers RM 140 on [p_k]; the offer's id.
create or replace function pg_temp.offer(p_k text, p_driver uuid default '00000000-0000-0000-0000-0000000309b1')
returns uuid language plpgsql as $$
begin
  perform pg_temp.check(pg_temp.run_as(p_driver, format('select public.c2c_make_offer(%L, 140)', pg_temp.id(p_k))) = 'ok 1',
    'offered on ' || p_k);
  return (select id from public.c2c_offers where booking_id = pg_temp.id(p_k) and driver_id = p_driver and status = 'open');
end $$;
-- [p_rider] accepts [p_driver]'s offer on [p_k] (cash, or the rule's first way): the result.
create or replace function pg_temp.accept(p_k text, p_rider uuid, p_method text default null, p_expected numeric default null,
                                          p_driver uuid default '00000000-0000-0000-0000-0000000309b1')
returns text language plpgsql as $$
begin
  return pg_temp.run_as(p_rider, format('select public.c2c_accept_offer_pay(%L, %L, %L)', pg_temp.offer(p_k, p_driver),
                                        p_method, p_expected));
end $$;
create or replace function pg_temp.step(p_k text, p_to text, p_driver uuid default '00000000-0000-0000-0000-0000000309b1')
returns text language sql as $$
  select pg_temp.run_as(p_driver, format('select public.c2c_driver_progress(%L, %L)', pg_temp.id(p_k), p_to));
$$;

-- ---- Rules by region -----------------------------------------------------------------------------------------
select pg_temp.check((select count(*) = 1 from public.c2c_giveup_rules where place is null)
                     and (select count(*) = 1 from public.c2c_pay_rules where place is null),
  'rules: one default each');
select pg_temp.check((select not charge and when_mode = 'within' and free_hours = 24 and amount = 30
                        from public.c2c_giveup_rule_for(pg_temp.kl())),
  'give up: the default applies, its charge off');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c1',
    $q$insert into public.c2c_giveup_rules (place) values ('{"level": "country", "country": "Semenanjung 309"}')$q$)
    like 'new row violates%', 'rules: not written by a rider');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309a1',
    $q$insert into public.c2c_giveup_rules (place, charge, amount, when_mode, dest, short_mode)
       values ('{"level": "country", "country": "Semenanjung 309"}', true, 10, 'always', 'platform', 'negative')$q$) = 'ok 1',
  'rules: an admin with EDIT adds a country rule');
insert into public.c2c_giveup_rules (place, charge, amount, when_mode, free_hours, dest, split_mode, split_percent, short_mode)
values ('{"level": "state", "country": "Semenanjung 309", "state": "Kuala Lumpur 309"}', true, 30, 'within', 24, 'split',
        'percent', 70, 'owed');
select pg_temp.check((select dest = 'split' and short_mode = 'owed' from public.c2c_giveup_rule_for(pg_temp.kl())),
  'rules: the state beats the country');
select pg_temp.check((select dest = 'platform' from public.c2c_giveup_rule_for(pg_temp.ipoh())),
  'rules: the country for a pickup in another state');
update public.c2c_giveup_rules set active = false where place->>'level' = 'state';
select pg_temp.check((select dest = 'platform' from public.c2c_giveup_rule_for(pg_temp.kl())),
  'rules: an inactive rule is skipped');
select pg_temp.check((select place is null from public.c2c_giveup_rule_for('{"country": "Elsewhere 309"}')),
  'rules: no region matches: the default');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309a1',
    'delete from public.c2c_giveup_rules where place is null') = 'C2C_DEFAULT_RULE',
  'rules: the default can''t be deleted');
select pg_temp.check((select f.fee = 30 and f.to_rider = 21 and f.to_platform = 9
                        from public.c2c_giveup_rules r, public.c2c_giveup_fee(r, now() + interval '3 hours', now()) f
                       where r.place->>'level' = 'state'),
  'give up: RM 30 inside 24 h, 70 % to the rider');
select pg_temp.check((select f.fee = 0
                        from public.c2c_giveup_rules r, public.c2c_giveup_fee(r, now() + interval '30 hours', now()) f
                       where r.place->>'level' = 'state'),
  'give up: free before the 24 h');
update public.c2c_giveup_rules set split_mode = 'fixed', split_fixed = 20 where place->>'level' = 'state';
select pg_temp.check((select f.to_rider = 20 and f.to_platform = 10
                        from public.c2c_giveup_rules r, public.c2c_giveup_fee(r, now() + interval '3 hours', now()) f
                       where r.place->>'level' = 'state'),
  'give up: a fixed RM 20 to the rider, the rest to get.ride');
delete from public.c2c_giveup_rules where place is not null;

-- ---- 1. A driver gives a trip up --------------------------------------------------------------------------
-- The default, charge off: no fee.
select pg_temp.request('g0', '00000000-0000-0000-0000-0000000309c1', '3 hours');
select pg_temp.check(pg_temp.accept('g0', '00000000-0000-0000-0000-0000000309c1') = 'ok 1', 'g0 booked');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    format($q$select public.c2c_driver_cancel(%L)->>'fee'$q$, pg_temp.id('g0')))::numeric = 0,
  'give up: the default is free');
select pg_temp.check(not exists (select 1 from public.c2c_driver_fees where driver_id = '00000000-0000-0000-0000-0000000309b1'),
  'give up: nothing recorded when free');

-- The default charging RM 30 to the rider, may go negative; the driver has RM 12.
update public.c2c_giveup_rules set charge = true, amount = 30, when_mode = 'within', free_hours = 24, dest = 'rider',
                                   short_mode = 'negative' where place is null;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b1', 12);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 0);
select pg_temp.check(pg_temp.accept('g0', '00000000-0000-0000-0000-0000000309c1') = 'ok 1', 'g0 booked again');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    format($q$select public.c2c_driver_cancel(%L)->>'fee'$q$, pg_temp.id('g0')))::numeric = 30,
  'give up: RM 30 inside 24 h');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309b1') = 0
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b1', 'get_credit') = -18
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 30,
  'give up, may go negative: RM 12 from the wallet, RM 18 below zero on GET.credit, RM 30 to the rider');
select pg_temp.check((select fee = 30 and taken = 12 and from_credit = 18 and owed = 0 and status = 'paid'
                        from public.c2c_driver_fees where booking_id = pg_temp.id('g0')),
  'give up: recorded, nothing owed');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    'select count(*) from public.c2c_driver_fees') = '1'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000309b2',
    'select count(*) from public.c2c_driver_fees') = '0',
  'give up: the driver reads their own fees only');

-- The rest owed, split 70 % to the rider: RM 12 now (all to the rider), RM 18 owed (RM 9 the rider's).
update public.c2c_giveup_rules set dest = 'split', split_mode = 'percent', split_percent = 70, short_mode = 'owed'
 where place is null;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b1', 12);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 0);
select pg_temp.check(pg_temp.accept('g0', '00000000-0000-0000-0000-0000000309c1') = 'ok 1', 'g0 booked a third time');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309b1',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('g0'))) = 'ok 1', 'given up again');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309b1') = 0
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 12
                     and (select owed = 18 and owed_rider = 9 and status = 'owed' and to_rider = 21 and to_platform = 9
                            from public.c2c_driver_fees where booking_id = pg_temp.id('g0') and short_mode = 'owed'),
  'give up, record as owed: RM 12 now to the rider, RM 18 owed (RM 9 of it the rider''s)');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309b1', 'select public.c2c_my_owed()::text')::jsonb
                        ->'driver'->0->>'owed')::numeric = 18,
  'give up: the driver sees what they owe');
-- The next earnings pay it first.
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
values ('00000000-0000-0000-0000-0000000309b1', 'get_wallet', 'ride_earning', 50, 'ride', 'Ride fare received');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309b1') = 32
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 21
                     and (select owed = 0 and owed_rider = 0 and status = 'paid' and paid_at is not null
                            from public.c2c_driver_fees where booking_id = pg_temp.id('g0') and short_mode = 'owed'),
  'give up: the next earnings pay the RM 18; the rider gets their RM 9');
-- Days ahead: free.
select pg_temp.request('g1', '00000000-0000-0000-0000-0000000309c1', '3 days');
select pg_temp.check(pg_temp.accept('g1', '00000000-0000-0000-0000-0000000309c1') = 'ok 1', 'g1 booked');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    format($q$select public.c2c_driver_cancel(%L)->>'fee'$q$, pg_temp.id('g1')))::numeric = 0,
  'give up: free before the 24 hours');
update public.c2c_giveup_rules set charge = false where place is null;
update public.c2c_bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin'
 where id in (pg_temp.id('g0'), pg_temp.id('g1'));

-- ---- 2. In-app payment, held ------------------------------------------------------------------------------
-- RM 140; the rider has RM 100 and 500 coins (100 coins = RM 1).
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 100);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 500, 'get_coin');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b1', 0);
select pg_temp.check((select wallet_part = 135 and coin_value = 5 and coins = 500 and short = 35
                        from public.c2c_pay_split(140, 'mix', 100, 500, 100))
                     and (select short = 40 from public.c2c_pay_split(140, 'get_wallet', 100, 500, 100))
                     and (select short = 135 and coins = 14000 from public.c2c_pay_split(140, 'get_coin', 100, 500, 100)),
  'split: the board''s example, each way');
select pg_temp.request('h1', '00000000-0000-0000-0000-0000000309c1', '3 days', 'in_app');
select pg_temp.check(pg_temp.accept('h1', '00000000-0000-0000-0000-0000000309c1', 'mix') = 'C2C_WALLET_SHORT',
  'hold: RM 35 short, refused');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_accept_offer_pay(%L, 'mix')::text$q$,
           (select id from public.c2c_offers where booking_id = pg_temp.id('h1') and status = 'open')))
    = 'C2C_WALLET_SHORT', 'hold: still short');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 100
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c1', 'get_coin') = 500
                     and (select status = 'offered' and pay_status is null from public.c2c_bookings where id = pg_temp.id('h1')),
  'hold: nothing taken, still waiting');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309c1',
    format('select public.c2c_pay_info(%L)::text', pg_temp.id('h1')))::jsonb
    @> '{"when": "hold", "walletBalance": 100, "coinBalance": 500, "coinRate": 100, "offerTopup": true, "offerCash": true}'),
  'pay info: the rule and the balances');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 200);
select pg_temp.check(pg_temp.accept('h1', '00000000-0000-0000-0000-0000000309c1', 'mix', 150) = 'C2C_AMOUNT_CHANGED',
  'hold: not another amount than the rider saw');
select pg_temp.check(pg_temp.accept('h1', '00000000-0000-0000-0000-0000000309c1', 'mix', 140) = 'ok 1',
  'hold: RM 140, coins first');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 65
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c1', 'get_coin') = 0
                     and (select status = 'booked' and pay_mode = 'hold' and pay_status = 'held' and paid_amount = 140
                                 and paid_method = 'mix'
                            from public.c2c_bookings where id = pg_temp.id('h1'))
                     and (select status = 'held' and wallet_amount = 135 and coin_value = 5 and coins = 500
                                 and driver_id = '00000000-0000-0000-0000-0000000309b1'
                            from public.c2c_payments where booking_id = pg_temp.id('h1')),
  'hold: RM 135 from the wallet, 500 coins, held');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    format('select count(*) from public.c2c_payments where booking_id = %L', pg_temp.id('h1'))) = '1'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000309c2',
    format('select count(*) from public.c2c_payments where booking_id = %L', pg_temp.id('h1'))) = '0',
  'hold: the driver sees it held; another rider doesn''t');
select pg_temp.check(pg_temp.step('h1', 'on_trip') = 'ok 1' and pg_temp.step('h1', 'completed') = 'ok 1', 'h1 completed');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309b1') = 123.20
                     and (select count(*) = 0 from public.wallet_transactions
                           where user_id = '00000000-0000-0000-0000-0000000309b1' and wallet_type = 'get_credit'
                             and kind = 'commission')
                     and (select pay_status = 'paid' and commission_amount = 16.80 and commission_charged_at is not null
                            from public.c2c_bookings where id = pg_temp.id('h1'))
                     and (select status = 'released' and commission = 16.80
                            from public.c2c_payments where booking_id = pg_temp.id('h1')),
  'complete: RM 140 to the driver less 12 % (RM 16.80), not on GET.credit');
select public.c2c_charge_commission(pg_temp.id('h1'));
select pg_temp.check((select count(*) = 1 from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000309b1' and kind = 'commission'),
  'complete: the commission is taken once');

-- Cancelled by the rider inside 24 hours: RM 120 back, RM 20 fee to the driver less 12 %.
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 140);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b1', 0);
select pg_temp.request('h2', '00000000-0000-0000-0000-0000000309c1', '5 hours', 'in_app');
select pg_temp.check(pg_temp.accept('h2', '00000000-0000-0000-0000-0000000309c1', 'get_wallet') = 'ok 1', 'h2 held');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 0, 'h2: RM 140 held');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309c1',
    format('select public.c2c_cancel(%L)::text', pg_temp.id('h2')))::jsonb
    @> '{"fee": 20, "feeStatus": "charged", "refunded": true}'),
  'cancel a held trip: the fee from the held fare');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 120
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b1') = 17.60
                     and (select pay_status = 'refunded' and cancel_fee_status = 'charged'
                            from public.c2c_bookings where id = pg_temp.id('h2'))
                     and (select status = 'refunded' and fee_kept = 20 and refund_wallet = 120
                            from public.c2c_payments where booking_id = pg_temp.id('h2')),
  'cancel a held trip: RM 120 back, RM 17.60 to the driver');

-- Paid with coins, then the driver gives up: everything back.
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 14000, 'get_coin');
select pg_temp.request('h3', '00000000-0000-0000-0000-0000000309c1', '2 days', 'in_app');
select pg_temp.check(pg_temp.accept('h3', '00000000-0000-0000-0000-0000000309c1', 'get_coin') = 'ok 1', 'h3 held in coins');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1', 'get_coin') = 0, 'h3: 14000 coins held');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309b1',
    format('select public.c2c_driver_cancel(%L)', pg_temp.id('h3'))) = 'ok 1', 'h3 given up');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1', 'get_coin') = 14000
                     and (select status = 'open' and pay_status is null and pay_mode is null
                            from public.c2c_bookings where id = pg_temp.id('h3'))
                     and (select status = 'refunded' and refund_coins = 14000
                            from public.c2c_payments where booking_id = pg_temp.id('h3')),
  'give up a held trip: the coins back, the request open again');
-- A way the rule doesn't offer.
update public.c2c_pay_rules set pay_coin = false, pay_mix = false where place is null;
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_accept_offer_pay(%L, 'get_coin')::text$q$,
           (select id from public.c2c_offers where booking_id = pg_temp.id('h3') and status = 'open' limit 1)))
    in ('C2C_PAY_WAY', 'C2C_OFFER_GONE'), 'hold: a way the rule doesn''t offer is refused');
update public.c2c_pay_rules set pay_coin = true, pay_mix = true where place is null;
-- Switching to cash before a driver is picked.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c1',
    format('select public.c2c_switch_to_cash(%L)', pg_temp.id('h3'))) = 'ok 1', 'switch to cash: before a driver is picked');
select pg_temp.check((select payment = 'cash' from public.c2c_bookings where id = pg_temp.id('h3')), 'switch to cash: switched');
update public.c2c_bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin' where id = pg_temp.id('h3');

-- ---- 2. Paid after the trip --------------------------------------------------------------------------------
insert into public.c2c_pay_rules (place, when_mode)
values ('{"level": "city", "country": "Semenanjung 309", "state": "Kuala Lumpur 309", "city": "Kuala Lumpur 309"}', 'after');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b1', 0);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 0);
select pg_temp.request('a1', '00000000-0000-0000-0000-0000000309c1', '3 days', 'in_app');
select pg_temp.check(pg_temp.accept('a1', '00000000-0000-0000-0000-0000000309c1') = 'ok 1', 'pay after: booked with an empty wallet');
select pg_temp.check((select pay_mode = 'after' and pay_status is null from public.c2c_bookings where id = pg_temp.id('a1')),
  'pay after: nothing taken at accept');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_pay(%L, 'get_wallet')$q$, pg_temp.id('a1'))) = 'C2C_NOT_DONE', 'pay after: not before the trip');
select pg_temp.check(pg_temp.step('a1', 'on_trip') = 'ok 1' and pg_temp.step('a1', 'completed') = 'ok 1', 'a1 completed');
select pg_temp.check((select pay_status = 'unpaid' and commission_amount = 16.80 from public.c2c_bookings where id = pg_temp.id('a1'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b1', 'get_credit') = -18 - 16.80
                     and exists (select 1 from public.notification_outbox
                                  where profile_id = '00000000-0000-0000-0000-0000000309c1' and event_id = 'c2c-pay:' || pg_temp.id('a1')),
  'pay after: unpaid, the commission on GET.credit as 0307, the rider told');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_pay(%L, 'get_wallet', 140)$q$, pg_temp.id('a1'))) = 'C2C_WALLET_SHORT',
  'pay after: short');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c1', 150);
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_pay(%L, 'get_wallet', 141)$q$, pg_temp.id('a1'))) = 'C2C_AMOUNT_CHANGED',
  'pay after: the amount the rider saw');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309c2',
    format($q$select public.c2c_pay(%L, 'get_wallet')::text$q$, pg_temp.id('a1'))) = 'not_authorized',
  'pay after: only the rider');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_pay(%L, 'get_wallet', 140)::text$q$, pg_temp.id('a1')))::jsonb ->> 'paid')::numeric = 140,
  'pay after: paid');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 10
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b1') = 140
                     and (select pay_status = 'paid' and paid_method = 'get_wallet' from public.c2c_bookings where id = pg_temp.id('a1')),
  'pay after: RM 140 to the driver (the commission was taken at completion)');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309c1',
    format($q$select public.c2c_pay(%L, 'get_wallet')::text$q$, pg_temp.id('a1')))::jsonb ->> 'already')::boolean
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c1') = 10,
  'pay after: paying again takes nothing');
delete from public.c2c_pay_rules where place is not null;

-- ---- 3. Cancel fees owed --------------------------------------------------------------------------------------
-- Rider 2 cancels a cash trip inside 24 hours with an empty wallet: RM 20 owed.
create or replace function pg_temp.owe(p_k text) returns void language plpgsql as $$
begin
  perform pg_temp.request(p_k, '00000000-0000-0000-0000-0000000309c2', '5 hours');
  perform pg_temp.check(pg_temp.accept(p_k, '00000000-0000-0000-0000-0000000309c2', null, null,
                                       '00000000-0000-0000-0000-0000000309b2') = 'ok 1', p_k || ' booked');
  perform pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309c2',
      format($q$select public.c2c_cancel(%L)->>'feeStatus'$q$, pg_temp.id(p_k))) = 'due', p_k || ': RM 20 owed');
end $$;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c2', 0);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b2', 0);
select pg_temp.owe('d1');
select pg_temp.check((select (o->'rider'->0->>'fee')::numeric = 20 and o->'rider'->0->>'route' = 'Kuala Lumpur 309 to Ipoh 309'
                        from (select pg_temp.value_as('00000000-0000-0000-0000-0000000309c2',
                                                      'select public.c2c_my_owed()::text')::jsonb o) x),
  'owed: the rider sees what and why');
-- The block.
update public.city_to_city_settings set owed_block = true where id = 1;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c2',
    format($q$insert into public.c2c_bookings (pickup_name, pickup_lat, pickup_lng, pickup_place, drop_name, drop_lat,
              drop_lng, drop_place, distance_km, duration_min, leave_at, fare, payment)
              values ('1 Jalan', 3.15, 101.70, %L, '2 Jalan', 4.60, 101.08, %L, 205, 160, now() + interval '2 days', 140,
                      'cash')$q$, pg_temp.kl(), pg_temp.ipoh())) = 'C2C_FEES_OWED',
  'owed: no new booking until paid');
update public.city_to_city_settings set owed_block = false where id = 1;
-- Pay now: short, then paid.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309c2', 'select public.c2c_pay_owed()::text')
    = 'C2C_WALLET_SHORT', 'pay now: short');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c2', 25);
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000309c2', 'select public.c2c_pay_owed()::text')::jsonb
                      @> '{"paid": 20, "left": 0}', 'pay now: paid');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c2') = 5
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b2') = 17.60
                     and (select cancel_fee_status = 'charged' and cancel_fee_paid_via = 'pay_now'
                            from public.c2c_bookings where id = pg_temp.id('d1')),
  'pay now: RM 20 paid, RM 17.60 to the driver it was owed to');
-- From the next top-up.
update public.city_to_city_settings set owed_from_topup = true where id = 1;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c2', 0);
select pg_temp.owe('d2');
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
values ('00000000-0000-0000-0000-0000000309c2', 'get_wallet', 'topup', 50, 'fpx', 'Top up GET.wallet');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c2') = 30
                     and (select cancel_fee_status = 'charged' and cancel_fee_paid_via = 'topup'
                            from public.c2c_bookings where id = pg_temp.id('d2')),
  'owed: taken from the next top-up');
update public.city_to_city_settings set owed_from_topup = false where id = 1;
-- Added to the next in-app payment.
update public.city_to_city_settings set owed_next_in_app = true where id = 1;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c2', 0);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b2', 0);
select pg_temp.owe('d3');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c2', 200);
select pg_temp.request('d3pay', '00000000-0000-0000-0000-0000000309c2', '3 days', 'in_app');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309c2',
    format('select public.c2c_pay_info(%L)::text', pg_temp.id('d3pay')))::jsonb->'dues'->0->>'fee')::numeric = 20,
  'owed: the pay sheet adds it');
select pg_temp.check(pg_temp.accept('d3pay', '00000000-0000-0000-0000-0000000309c2', 'get_wallet', 140, '00000000-0000-0000-0000-0000000309b2')
    = 'C2C_AMOUNT_CHANGED', 'owed: the total includes it');
select pg_temp.check(pg_temp.accept('d3pay', '00000000-0000-0000-0000-0000000309c2', 'get_wallet', 160,
                                    '00000000-0000-0000-0000-0000000309b2') = 'ok 1', 'owed: paid with the next hold');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309c2') = 40
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b2') = 17.60
                     and (select cancel_fee_status = 'charged' and cancel_fee_paid_via = 'in_app'
                            from public.c2c_bookings where id = pg_temp.id('d3'))
                     and (select amount = 140 and dues_amount = 20 from public.c2c_payments
                           where booking_id = pg_temp.id('d3pay') and status = 'held'),
  'owed: RM 160 taken, RM 140 held, RM 20 to the driver it was owed to (less 12 %)');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309a1',
    format('select public.c2c_cancel(%L)', pg_temp.id('d3pay'))) = 'ok 1'
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309c2') = 180,
  'an admin''s cancel gives the whole held fare back');
update public.city_to_city_settings set owed_next_in_app = false where id = 1;
-- The driver of the next cash trip collects it.
update public.city_to_city_settings set owed_cash_collect = true where id = 1;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309c2', 0);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000309b2', 0);
select pg_temp.owe('d4');
select pg_temp.request('d4cash', '00000000-0000-0000-0000-0000000309c2', '4 days');
select pg_temp.check(pg_temp.accept('d4cash', '00000000-0000-0000-0000-0000000309c2') = 'ok 1', 'owed: a cash trip booked');
select pg_temp.check((select collect_amount = 20 and collect_fee_ids = array[pg_temp.id('d4')] and collected_at is null
                        from public.c2c_bookings where id = pg_temp.id('d4cash')),
  'owed: the cash trip carries it for its driver');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309c2',
    format('select public.c2c_mark_collected(%L)', pg_temp.id('d4cash'))) = 'not_authorized',
  'owed: only the trip''s driver marks it collected');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    format('select public.c2c_mark_collected(%L)::text', pg_temp.id('d4cash')))::jsonb->>'collected')::numeric = 20,
  'owed: the driver collected RM 20 in cash');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000309b1', 'get_credit') = -18 - 16.80 - 20
                     and pg_temp.bal('00000000-0000-0000-0000-0000000309b2') = 17.60
                     and (select cancel_fee_status = 'charged' and cancel_fee_paid_via = 'cash'
                            from public.c2c_bookings where id = pg_temp.id('d4'))
                     and (select collected_at is not null from public.c2c_bookings where id = pg_temp.id('d4cash')),
  'owed: the collector''s GET.credit charged RM 20, RM 17.60 to the driver it was owed to');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000309b1',
    format('select public.c2c_mark_collected(%L)::text', pg_temp.id('d4cash')))::jsonb->>'already')::boolean,
  'owed: marked once');
update public.city_to_city_settings set owed_cash_collect = false where id = 1;

-- ---- 4. Trip reminders -----------------------------------------------------------------------------------
-- d4cash leaves in 4 days: nothing due.
select public.c2c_send_reminders();
select pg_temp.check(not exists (select 1 from public.c2c_reminder_log where booking_id = pg_temp.id('d4cash')),
  'reminders: nothing due 4 days ahead');
-- Leaving in 1 h 55 min, booked a day ago: the 2 h reminder to both; the 1 day one is late, skipped.
update public.c2c_bookings set leave_at = now() + interval '115 minutes', driver_leave_at = now() + interval '115 minutes',
                                booked_at = now() - interval '1 day', timezone = 'Asia/Kuala_Lumpur'
 where id = pg_temp.id('d4cash');
select pg_temp.check(public.c2c_send_reminders() = 2, 'reminders: two sent');
select pg_temp.check((select count(*) = 2 and bool_and(kind = 'c2c_reminder' and data->>'type' = 'c2c_reminder'
                                                       and data->>'c2c_booking_id' = pg_temp.id('d4cash')::text)
                        from public.notification_outbox where event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':120'),
  'reminders: the 2 h one, through the outbox');
select pg_temp.check((select title = 'Your trip to Ipoh 309 is in 2 h'
                             and body like 'Hafiz R. picks you up at % from 12 Jalan Ampang. Toyota Vios, WXY 1234. Tap to see the trip or chat.'
                             and data->>'role' = 'rider'
                        from public.notification_outbox
                       where event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':120'
                         and profile_id = '00000000-0000-0000-0000-0000000309c2'),
  'reminders: the rider''s words');
select pg_temp.check((select title = 'City to City trip in 2 h'
                             and body like 'Pick up Rider D. at %, 12 Jalan Ampang, to Ipoh 309. RM 140, cash. Tap to start On my way.'
                             and data->>'role' = 'partner'
                        from public.notification_outbox
                       where event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':120'
                         and profile_id = '00000000-0000-0000-0000-0000000309b1'),
  'reminders: the driver''s words');
select pg_temp.check((select count(*) = 2 and bool_and(skipped) from public.c2c_reminder_log
                       where booking_id = pg_temp.id('d4cash') and minutes = 1440),
  'reminders: the late 1 day one skipped');
select pg_temp.check(public.c2c_send_reminders() = 0
                     and (select count(*) = 2 from public.notification_outbox where event_id like 'c2c-rem:%'),
  'reminders: once');
-- The 30 min one goes to the driver only; booked 10 minutes ago, leaving in 25: the 2 h one had passed at booking.
update public.c2c_bookings set leave_at = now() + interval '25 minutes', driver_leave_at = now() + interval '25 minutes',
                                booked_at = now() - interval '10 minutes'
 where id = pg_temp.id('d4cash');
delete from public.c2c_reminder_log where booking_id = pg_temp.id('d4cash');
delete from public.notification_outbox where event_id like 'c2c-rem:%';
select pg_temp.check(public.c2c_send_reminders() = 1, 'reminders: one due');
select pg_temp.check((select profile_id = '00000000-0000-0000-0000-0000000309b1' from public.notification_outbox
                           where event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':30')
                     and (select bool_and(skipped) from public.c2c_reminder_log
                           where booking_id = pg_temp.id('d4cash') and minutes in (120, 1440)),
  'reminders: 30 min to the driver; those whose time passed at booking skipped');
-- Push off, the Notifications page on: kept there.
update public.city_to_city_settings set reminder_push = false,
       reminders = '[{"minutes": 15, "to": "rider"}]' where id = 1;
update public.c2c_bookings set leave_at = now() + interval '14 minutes', driver_leave_at = now() + interval '14 minutes'
 where id = pg_temp.id('d4cash');
select pg_temp.check(public.c2c_send_reminders() = 1, 'reminders: the 15 min one');
select pg_temp.check((select title = 'Your trip to Ipoh 309 is in 15 min' and kind = 'c2c_reminder' and mode = 'rider'
                            from public.user_notifications
                           where profile_id = '00000000-0000-0000-0000-0000000309c2'
                             and event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':15')
                     and not exists (select 1 from public.notification_outbox
                                      where event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':15'),
  'reminders: without push, on the Notifications page');
-- SMS when the push isn't confirmed.
update public.city_to_city_settings set reminder_push = true, reminder_sms = true, reminders = '[{"minutes": 10, "to": "rider"}]'
 where id = 1;
update public.c2c_bookings set leave_at = now() + interval '8 minutes', driver_leave_at = now() + interval '8 minutes'
 where id = pg_temp.id('d4cash');
select pg_temp.check(public.c2c_send_reminders() = 1, 'reminders: the 10 min one pushed');
update public.notification_outbox set created_at = now() - interval '3 minutes'
 where event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':10';
insert into public.messaging_devices (id, user_id, device_id, kind, last_seen_at)
values ('00000000-0000-0000-0000-0000000309f1', '00000000-0000-0000-0000-0000000309a1', 'gw-309', 'gateway', now());
insert into public.messaging_routes (channel, direction, transport, device_ids, enabled)
values ('otp', 'outbound', 'sms', array['00000000-0000-0000-0000-0000000309f1'::uuid], true)
on conflict (channel, direction) do update set transport = 'sms', device_ids = excluded.device_ids, enabled = true;
update public.sms_settings set allowed_prefixes = '{+60}', blocked_numbers = '{}' where id = 1;
select public.c2c_send_reminders();
select pg_temp.check((select o.sms_status = 'queued' and o.sms_phone = '+60100030992'
                             and s.to_phone = '+60100030992'
                             -- (an 'otp' route's digits are masked in the queue, 0183)
                             and s.body like 'GET.ride: Your trip to Ipoh % is in % min. %'
                        from public.notification_outbox o join public.sms_outbox s on s.id = o.sms_outbox_id
                       where o.event_id = 'c2c-rem:' || pg_temp.id('d4cash') || ':10'),
  'reminders: an SMS when the push wasn''t confirmed');
-- None after a cancel.
update public.city_to_city_settings set reminder_sms = false, reminders = '[{"minutes": 5, "to": "both"}]' where id = 1;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309a1',
    format('select public.c2c_cancel(%L)', pg_temp.id('d4cash'))) = 'ok 1', 'd4cash cancelled');
update public.c2c_bookings set leave_at = now() + interval '4 minutes' where id = pg_temp.id('d4cash');
select pg_temp.check(public.c2c_send_reminders() = 0, 'reminders: none after a cancel');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000309a1',
    $q$update public.city_to_city_settings set reminders = '[{"minutes": 2, "to": "both"}]' where id = 1$q$)
    like '%city_to_city_settings_reminders%', 'reminders: 5 minutes at the least');
select pg_temp.check(not public.c2c_reminders_valid('[{"minutes": 60, "to": "both"}, {"minutes": 60, "to": "rider"}]')
                     and not public.c2c_reminders_valid('[{"minutes": 60, "to": "nobody"}]')
                     and public.c2c_reminders_valid('[]'),
  'reminders: each time once, to someone');
select pg_temp.check(public.c2c_reminder_when(1440) = '1 day' and public.c2c_reminder_when(2880) = '2 days'
                     and public.c2c_reminder_when(120) = '2 h' and public.c2c_reminder_when(90) = '1 h 30 min'
                     and public.c2c_reminder_when(30) = '30 min',
  'reminders: how long before, in words');

-- ---- Grants ---------------------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.c2c_pay(uuid, text, numeric)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_pay(uuid, text, numeric)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_accept_offer_pay(uuid, text, numeric)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_accept_offer(uuid)', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_pay_owed()', 'execute')
                     and has_function_privilege('authenticated', 'public.c2c_mark_collected(uuid)', 'execute'),
  'grants: the apps'' functions for the signed in');
select pg_temp.check(not has_function_privilege('authenticated', 'public.c2c_send_reminders()', 'execute')
                     and not has_function_privilege('authenticated',
                           'public.c2c_settle_due(public.c2c_bookings, text, boolean, uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'public.c2c_collect_driver_fees(uuid, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.c2c_hold_release(uuid)', 'execute'),
  'grants: the money and the reminders are the server''s');

select 'city_to_city_money_0309: all passed';
rollback;
