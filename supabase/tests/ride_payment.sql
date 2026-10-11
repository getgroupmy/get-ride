-- ============================================================================
-- Regression test for migration 0142: paying for a ride when it ends.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_payment.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000142a1'),  -- rider
  ('00000000-0000-0000-0000-0000000142b1'),  -- driver
  ('00000000-0000-0000-0000-0000000142c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000142%'
on conflict do nothing;

insert into public.get_coin_settings (id, coins_per_currency) values ('master', 10)
on conflict (id) do update set coins_per_currency = 10;

-- c1: on trip, RM20 fare + RM5 toll. c2: same, for cash. c3: RM100 fare with
-- a 10% surcharge, SST 6% (plain) and a 2% scheduled tax on fare+surcharge.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000142d1', '00000000-0000-0000-0000-0000000142a1', '00000000-0000-0000-0000-0000000142b1', 'on_trip', 20, 20),
  ('00000000-0000-0000-0000-0000000142d2', '00000000-0000-0000-0000-0000000142a1', '00000000-0000-0000-0000-0000000142b1', 'on_trip', 20, 20),
  ('00000000-0000-0000-0000-0000000142d4', '00000000-0000-0000-0000-0000000142a1', '00000000-0000-0000-0000-0000000142b1', 'on_trip', 30, 30);
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, tax_name, tax_kind, tax_value, charges) values
  ('00000000-0000-0000-0000-0000000142d3', '00000000-0000-0000-0000-0000000142a1', '00000000-0000-0000-0000-0000000142b1', 'completed', 100, 100,
   'SST', 'percent', 6,
   '[{"kind":"surcharge","name":"Night","charge":"percent","value":10},{"kind":"tax","name":"Levy","charge":"percent","value":2}]');

-- Money to pay with.
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000142a1', 'get_wallet', 'topup', 30, 'test', 'test'),
  ('00000000-0000-0000-0000-0000000142a1', 'get_coin', 'topup', 100, 'test', 'test');

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

-- 1. The total is priced as the app prices it ---------------------------------
-- 100 + 10 surcharge + 6 SST (on the fare) + 2.20 levy (on 110) = 118.20
select pg_temp.check(
  (select public.ride_amount_due(r) from public.ride_requests r where id = '00000000-0000-0000-0000-0000000142d3') = 118.20,
  'surcharges and taxes are priced as the app prices them');

set local role authenticated;

-- 2. The driver completes with a toll: the ride is due -------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000142b1');
update public.ride_requests set status = 'completed', toll_charges = 5
 where id in ('00000000-0000-0000-0000-0000000142d1', '00000000-0000-0000-0000-0000000142d2');
select pg_temp.check((select payment_status = 'due' from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d1'),
  'a completed trip is due');
select pg_temp.refused(
  $q$update public.ride_requests set payment_status = 'paid' where id = '00000000-0000-0000-0000-0000000142d1'$q$,
  'the driver marking a ride paid by hand');

-- 3. Nobody but the rider pays; the rider can't write it by hand --------------
select pg_temp.refused(
  $q$select public.ride_pay('00000000-0000-0000-0000-0000000142d1', 'get_wallet')$q$,
  'the driver paying the rider''s ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000000142a1');
select pg_temp.refused(
  $q$update public.ride_requests set payment_status = 'paid' where id = '00000000-0000-0000-0000-0000000142d1'$q$,
  'the rider marking a ride paid by hand');
select pg_temp.refused(
  $q$select public.ride_pay('00000000-0000-0000-0000-0000000142d4', 'get_wallet')$q$,
  'paying a trip still under way');

-- 4. Pay now with GET.wallet: RM25 moves from the rider to the driver ---------
select public.ride_pay('00000000-0000-0000-0000-0000000142d1', 'get_wallet');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000142a1', 'get_wallet') = 5, 'rider wallet debited 25');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000142b1', 'get_wallet') = 25, 'driver wallet credited 25');
select pg_temp.check((select payment_status = 'paid' and paid_method = 'get_wallet' and paid_amount = 25
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d1'), 'marked paid by GET.wallet');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000142a1');
-- Paying again is a no-op.
select public.ride_pay('00000000-0000-0000-0000-0000000142d1', 'get_wallet');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000142a1', 'get_wallet') = 5, 'never charged twice');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000142a1');

-- 5. Not enough in the wallet: refused, nothing moves -------------------------
select pg_temp.refused(
  $q$select public.ride_pay('00000000-0000-0000-0000-0000000142d2', 'get_wallet')$q$,
  'paying RM25 from RM5');
reset role;
select pg_temp.check((select payment_status = 'due' from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d2'),
  'still due after a failed payment');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000142a1');

-- 6. Paid in cash: pending until the driver confirms --------------------------
select public.ride_pay_cash('00000000-0000-0000-0000-0000000142d2');
reset role;
select pg_temp.check((select payment_status = 'cash_pending' from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d2'),
  'cash waits for the driver');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000142c1');
select pg_temp.refused(
  $q$select public.ride_confirm_cash('00000000-0000-0000-0000-0000000142d2')$q$,
  'somebody else confirming the cash');
select pg_temp.as_user('00000000-0000-0000-0000-0000000142b1');
select public.ride_confirm_cash('00000000-0000-0000-0000-0000000142d2');
reset role;
select pg_temp.check((select payment_status = 'paid' and paid_method = 'cash' and paid_amount = 25
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d2'), 'cash confirmed');

-- 7. Pay now with GET.coin: 118.20 at 10 GC a ringgit is 1182 GC -------------
select pg_temp.check(
  (select count(*) from jsonb_array_elements(public.ride_payment_messages(
      (select r from public.ride_requests r where id = '00000000-0000-0000-0000-0000000142d4'),
      (select r from public.ride_requests r where id = '00000000-0000-0000-0000-0000000142d4'))) ) = 0,
  'no message without a change');
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000142a1', 'get_coin', 'topup', 1100, 'test', 'test');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000142a1');
select public.ride_pay('00000000-0000-0000-0000-0000000142d3', 'get_coin');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000142a1', 'get_coin') = 18, '1182 GC spent of 1200');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000142b1', 'get_wallet') = 25 + 118.20, 'driver credited 118.20');
select pg_temp.check((select fare_coins_value = 118.20 and fare_coins_redeemed_at is not null and paid_method = 'get_coin'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d3'),
  'the coins show as the GET.coin line, and can''t be spent on the ride again');

-- 8. What each side is told -----------------------------------------------------
do $$
declare
  o public.ride_requests;
  n public.ride_requests;
  m jsonb;
begin
  select * into o from public.ride_requests where id = '00000000-0000-0000-0000-0000000142d4';
  n := o;
  n.status := 'completed';
  n.payment_status := 'due';
  n.toll_charges := 4;
  m := public.ride_payment_messages(o, n);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'rider' or m->0->>'body' not like '%added tolls%RM34.00%' then
    raise exception 'FAILED: the rider is told the total and the added charges: %', m;
  end if;
  o := n;
  n.payment_status := 'cash_pending';
  m := public.ride_payment_messages(o, n);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'partner' then
    raise exception 'FAILED: the driver is asked to confirm the cash: %', m;
  end if;
end $$;

select 'ride_payment: all passed';
rollback;
