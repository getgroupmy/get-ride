-- ============================================================================
-- Regression test for migration 0174: the money on a ride can't be changed
-- by its participants, commission is charged by the database, and coins are
-- capped and rounded for the house.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payments_hardening.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000174a1'),  -- rider
  ('00000000-0000-0000-0000-0000000174b1'),  -- driver
  ('00000000-0000-0000-0000-0000000174c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000174%'
on conflict do nothing;

-- The driver's own commission rate: 10%.
insert into public.commission_rates (level, user_id, rate, active)
values ('user', '00000000-0000-0000-0000-0000000174b1', 0.10, true);

insert into public.get_coin_settings (id, coins_per_currency, earn_coins_per_currency, max_supply)
values ('master', 10, 0, 0)
on conflict (id) do update set coins_per_currency = 10, earn_coins_per_currency = 0, max_supply = 0;

-- e1: accepted at RM20. e2: on trip at RM20. e3: open, with the driver's
-- offer of RM18 standing. e4: on trip at RM30 (ends early). e5: completed,
-- unpaid, RM10 (cash). e6: completed, unpaid, RM10 (pay now).
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, offered_fare) values
  ('00000000-0000-0000-0000-0000000174e1', '00000000-0000-0000-0000-0000000174a1', '00000000-0000-0000-0000-0000000174b1', 'accepted', 20, 20, null),
  ('00000000-0000-0000-0000-0000000174e2', '00000000-0000-0000-0000-0000000174a1', '00000000-0000-0000-0000-0000000174b1', 'on_trip', 20, 20, null),
  ('00000000-0000-0000-0000-0000000174e3', '00000000-0000-0000-0000-0000000174a1', '00000000-0000-0000-0000-0000000174b1', 'open', 20, 20, 18),
  ('00000000-0000-0000-0000-0000000174e4', '00000000-0000-0000-0000-0000000174a1', '00000000-0000-0000-0000-0000000174b1', 'on_trip', 30, 30, null),
  ('00000000-0000-0000-0000-0000000174e5', '00000000-0000-0000-0000-0000000174a1', '00000000-0000-0000-0000-0000000174b1', 'completed', 10, 10, null),
  ('00000000-0000-0000-0000-0000000174e6', '00000000-0000-0000-0000-0000000174a1', '00000000-0000-0000-0000-0000000174b1', 'completed', 10, 10, null);
update public.ride_requests set payment_status = 'due'
 where id in ('00000000-0000-0000-0000-0000000174e5', '00000000-0000-0000-0000-0000000174e6');

insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000174a1', 'get_wallet', 'topup', 50, 'test', 'test'),
  ('00000000-0000-0000-0000-0000000174a1', 'get_coin', 'topup', 500, 'test', 'test');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create or replace function pg_temp.balance(p uuid, t text) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = t), 0);
$$;
grant execute on function pg_temp.balance(uuid, text) to authenticated;

create or replace function pg_temp.ride(p uuid) returns public.ride_requests language sql as $$
  select * from public.ride_requests where id = p;
$$;
grant execute on function pg_temp.ride(uuid) to authenticated;

set local role authenticated;

-- 1. The rider can't end the trip or reprice it once accepted ----------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000174a1');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000174e2'$q$,
  'the rider completing their own trip');
select pg_temp.refused(
  $q$update public.ride_requests set ride_fare = 1 where id = '00000000-0000-0000-0000-0000000174e1'$q$,
  'the rider lowering an accepted fare');
select pg_temp.refused(
  $q$update public.ride_requests set fare = 1, ride_fare = 1 where id = '00000000-0000-0000-0000-0000000174e2'$q$,
  'the rider lowering the fare mid-trip');
select pg_temp.refused(
  $q$update public.ride_requests set tax_value = 0, tax_name = null, charges = '[]' where id = '00000000-0000-0000-0000-0000000174e1'$q$,
  'the rider dropping the tax');
select pg_temp.refused(
  $q$update public.ride_requests set coin_rewarded_at = now() where id = '00000000-0000-0000-0000-0000000174e5'$q$,
  'the rider stamping the coin reward');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'arrived' where id = '00000000-0000-0000-0000-0000000174e1'$q$,
  'the rider marking the driver arrived');
select pg_temp.refused(
  $q$insert into public.ride_requests (rider_id, status, fare) values ('00000000-0000-0000-0000-0000000174a1', 'completed', 1)$q$,
  'a request inserted already completed');
select pg_temp.refused(
  $q$update public.ride_requests set fare = 'NaN', ride_fare = 'NaN' where id = '00000000-0000-0000-0000-0000000174e3'$q$,
  'a NaN fare');
select pg_temp.refused(
  $q$update public.ride_requests set fare = -5, ride_fare = -5 where id = '00000000-0000-0000-0000-0000000174e3'$q$,
  'a negative fare');

-- 2. While open: the rider prices it; an offer is taken at the offer ---------
select pg_temp.refused(
  $q$update public.ride_requests set status = 'accepted', fare = 5, ride_fare = 5 where id = '00000000-0000-0000-0000-0000000174e3'$q$,
  'the rider taking an offer of 18 at 5');
update public.ride_requests set fare = 22, ride_fare = 22 where id = '00000000-0000-0000-0000-0000000174e3';
select pg_temp.check((select ride_fare = 22 from public.ride_requests where id = '00000000-0000-0000-0000-0000000174e3'),
  'the rider raises their open fare');

select pg_temp.as_user('00000000-0000-0000-0000-0000000174b1');
select pg_temp.refused(
  $q$update public.ride_requests set fare = 99, ride_fare = 99 where id = '00000000-0000-0000-0000-0000000174e3'$q$,
  'the bidding driver repricing the rider''s request');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'accepted', fare = 99, ride_fare = 99 where id = '00000000-0000-0000-0000-0000000174e3'$q$,
  'the driver claiming at a fare of their own');

select pg_temp.as_user('00000000-0000-0000-0000-0000000174a1');
update public.ride_requests set status = 'accepted', accepted_at = now(), fare = 18, ride_fare = 18
 where id = '00000000-0000-0000-0000-0000000174e3';
select pg_temp.check((select status = 'accepted' and ride_fare = 18 from public.ride_requests where id = '00000000-0000-0000-0000-0000000174e3'),
  'the rider takes the offer at the offer');

-- 3. The driver: forward only, and only lower when ending early --------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000174b1');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000174e1'$q$,
  'completing a trip that never started');
select pg_temp.refused(
  $q$update public.ride_requests set commission_charged_at = now() where id = '00000000-0000-0000-0000-0000000174e2'$q$,
  'the driver stamping their commission paid');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'completed', ride_fare = 40 where id = '00000000-0000-0000-0000-0000000174e2'$q$,
  'the driver raising the fare at the end');
select pg_temp.refused(
  $q$update public.ride_requests set ride_fare = 5 where id = '00000000-0000-0000-0000-0000000174e2'$q$,
  'the driver lowering the fare mid-trip without ending it');
update public.ride_requests set status = 'arrived' where id = '00000000-0000-0000-0000-0000000174e1';

-- 4. Completing charges commission on the stored fare -----------------------
update public.ride_requests set status = 'completed', completed_at = now() where id = '00000000-0000-0000-0000-0000000174e2';
update public.ride_requests set status = 'completed', completed_at = now(), ride_fare = 12, ended_early_at = now()
 where id = '00000000-0000-0000-0000-0000000174e4';
reset role;
select pg_temp.check((select commission_amount = 2.00 and commission_rate = 0.10 and commission_charged_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000174e2'),
  'commission charged on the RM20 fare');
select pg_temp.check((select commission_amount = 1.20 from public.ride_requests where id = '00000000-0000-0000-0000-0000000174e4'),
  'commission charged on the early-end fare');
select pg_temp.check((select fare = 30 from public.ride_requests where id = '00000000-0000-0000-0000-0000000174e4'),
  'the booked fare is kept beside the early-end fare');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000174b1', 'get_credit') = -3.20,
  'GET.credit carries both commissions');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000174b1');
-- The apps' own call: the fare and rate it passes change nothing.
select public.wallet_charge_ride_commission('00000000-0000-0000-0000-0000000174e2', '00000000-0000-0000-0000-0000000174b1', 1, 0.01);
select pg_temp.refused(
  $q$select public.wallet_charge_ride_commission('00000000-0000-0000-0000-0000000174e1', '00000000-0000-0000-0000-0000000174b1', 1, null)$q$,
  'charging commission on a ride not completed');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000174e2'$q$,
  'reopening a completed trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000174c1');
select pg_temp.refused(
  $q$select public.wallet_charge_ride_commission('00000000-0000-0000-0000-0000000174e2', '00000000-0000-0000-0000-0000000174c1', 1, null)$q$,
  'somebody else charging a ride''s commission');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000174b1', 'get_credit') = -3.20,
  'commission never charged twice');

-- 5. Pay now goes through only at the amount the rider saw -------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000174a1');
select pg_temp.refused(
  $q$select public.ride_pay('00000000-0000-0000-0000-0000000174e6', 'get_wallet', 9.00)$q$,
  'paying RM10 when RM9 was shown');
select public.ride_pay('00000000-0000-0000-0000-0000000174e6', 'get_wallet', 10.00);
reset role;
select pg_temp.check((select payment_status = 'paid' and paid_amount = 10 from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000174e6'), 'paid at the amount shown');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000174a1', 'get_wallet') = 40, 'rider paid RM10');

-- 6. Cash first: no coins against the same ride afterwards ------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000174a1');
select public.ride_pay_cash('00000000-0000-0000-0000-0000000174e5');
select pg_temp.check(
  (public.wallet_redeem_fare_coins('00000000-0000-0000-0000-0000000174a1', 10, '00000000-0000-0000-0000-0000000174e5')->>'coins_used')::numeric = 0,
  'no coins against a ride paid in cash');
select pg_temp.check(
  (public.wallet_redeem_fare_coins('00000000-0000-0000-0000-0000000174a1', 10, '00000000-0000-0000-0000-0000000174e6')->>'coins_used')::numeric = 0,
  'no coins against a ride already paid');
reset role;
select pg_temp.check((select fare_coins_redeemed_at is not null and fare_coins_value is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000174e5'),
  'cash stamps the ride so coins can''t follow');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000174a1', 'get_coin') = 500, 'no coins spent');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000174b1', 'get_wallet') = 10,
  'the driver got the RM10 payment and no coin payout');

-- 7. Coins spent round up --------------------------------------------------
-- 0.333 GC a ringgit: RM1 of coins is 0.333 GC, taken as 0.34.
update public.get_coin_settings set coins_per_currency = 0.333 where id = 'master';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000174a1');
select pg_temp.check(
  (public.wallet_pay('00000000-0000-0000-0000-0000000174a1', 1, 'Test', 'qr_scan', true)->>'coins_used')::numeric = 0.34,
  'coins spent round up');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000174a1', 'get_coin') = 499.66, '0.34 GC taken');

-- 8. Rewards stop at the supply cap ----------------------------------------
-- 1 GC per ringgit earned; room for 3 more coins in circulation.
update public.get_coin_settings
   set earn_coins_per_currency = 1,
       max_supply = (select sum(balance) from public.wallets where wallet_type = 'get_coin') + 3
 where id = 'master';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000174a1');
select pg_temp.check(
  public.wallet_award_ride_coins('00000000-0000-0000-0000-0000000174e2', '00000000-0000-0000-0000-0000000174a1', 999) = 3,
  'a RM20 reward is capped at the 3 coins of room left');
select pg_temp.check(
  public.wallet_award_ride_coins('00000000-0000-0000-0000-0000000174e4', '00000000-0000-0000-0000-0000000174a1', 999) = 0,
  'nothing minted once the cap is reached');
reset role;

-- 9. Internal helpers are nobody's to call ----------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.ride_charge_commission(uuid)', 'execute'),
  'ride_charge_commission is internal');
select pg_temp.check(not has_function_privilege('authenticated', 'public.coin_mint_room(numeric)', 'execute'),
  'coin_mint_room is internal');
select pg_temp.check(not has_function_privilege('anon', 'public.ride_pay(uuid, text, numeric)', 'execute'),
  'ride_pay is not for anon');

select 'payments_hardening: all passed';
rollback;
