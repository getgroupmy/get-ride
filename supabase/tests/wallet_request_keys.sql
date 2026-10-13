-- ============================================================================
-- Regression test for migration 0164: a money call repeated with the same
-- request id moves money once, and answers with the first call's result.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/wallet_request_keys.sql
--
-- Everything runs in one transaction and is rolled back. A failed assertion
-- raises an exception.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000c1'),
  ('00000000-0000-0000-0000-0000000000c2')
on conflict do nothing;

-- A fixed coin price (RM1/GC, no market) for the trade case.
insert into public.get_coin_settings (id, coins_per_currency, market_enabled)
values ('master', 1, false)
on conflict (id) do update set coins_per_currency = 1, market_enabled = false, max_supply = 0;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

create or replace function pg_temp.bal(p_user uuid, p_type text) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = p_type), 0)
$$;

select public.wallet_topup('00000000-0000-0000-0000-0000000000c1', 100, 'test');

-- 1. The same id twice: one payment, the same answer -------------------------
do $$
declare
  u uuid := '00000000-0000-0000-0000-0000000000c1';
  k uuid := '11111111-1111-1111-1111-111111111111';
  w0 numeric := pg_temp.bal(u, 'get_wallet');
  a jsonb; b jsonb;
begin
  a := public.wallet_pay_once(k, u, 10, 'first', 'qr_scan', false);
  b := public.wallet_pay_once(k, u, 10, 'first', 'qr_scan', false);
  perform pg_temp.check(pg_temp.bal(u, 'get_wallet') = w0 - 10, 'a repeated id paid twice');
  perform pg_temp.check(a = b, 'the repeat answered differently: ' || a::text || ' vs ' || b::text);
end $$;

-- 2. A new id is a new payment ----------------------------------------------
do $$
declare
  u uuid := '00000000-0000-0000-0000-0000000000c1';
  w0 numeric := pg_temp.bal(u, 'get_wallet');
begin
  perform public.wallet_pay_once('22222222-2222-2222-2222-222222222222', u, 5, null, 'qr_scan', false);
  perform public.wallet_pay_once('33333333-3333-3333-3333-333333333333', u, 5, null, 'qr_scan', false);
  perform pg_temp.check(pg_temp.bal(u, 'get_wallet') = w0 - 10, 'two ids should be two payments');
end $$;

-- 3. A refused call leaves no claim behind: the retry runs for real ----------
do $$
declare
  u uuid := '00000000-0000-0000-0000-0000000000c1';
  k uuid := '44444444-4444-4444-4444-444444444444';
  refused boolean := false;
begin
  begin
    perform public.wallet_pay_once(k, u, 1000000, null, 'qr_scan', false);
  exception when others then
    refused := true;
  end;
  perform pg_temp.check(refused, 'paying more than the balance should be refused');
  perform pg_temp.check(not exists (select 1 from public.wallet_request_keys where wallet_request_keys.id = k),
    'a refused call kept its claim');
end $$;

-- 4. Another account cannot replay someone's id ------------------------------
do $$
declare
  refused boolean := false;
begin
  begin
    perform public.wallet_pay_once('11111111-1111-1111-1111-111111111111',
      '00000000-0000-0000-0000-0000000000c2', 1, null, 'qr_scan', false);
  exception when others then
    refused := sqlerrm like '%request_id_conflict%';
  end;
  perform pg_temp.check(refused, 'another account reused an id');
end $$;

-- 5. The other wrappers: once each, however often repeated --------------------
do $$
declare
  u uuid := '00000000-0000-0000-0000-0000000000c1';
  w0 numeric := pg_temp.bal(u, 'get_wallet');
  c0 numeric := pg_temp.bal(u, 'get_credit');
begin
  perform public.wallet_recharge_credit_once('55555555-5555-5555-5555-555555555555', u, 3);
  perform public.wallet_recharge_credit_once('55555555-5555-5555-5555-555555555555', u, 3);
  perform pg_temp.check(pg_temp.bal(u, 'get_credit') = c0 + 3, 'recharge ran twice');
  perform pg_temp.check(pg_temp.bal(u, 'get_wallet') = w0 - 3, 'recharge took twice');

  perform public.wallet_trade_coins_once('66666666-6666-6666-6666-666666666666', u, 'buy', 2, null);
  perform public.wallet_trade_coins_once('66666666-6666-6666-6666-666666666666', u, 'buy', 2, null);
  perform pg_temp.check(pg_temp.bal(u, 'get_coin') = 2, 'a repeated trade bought twice');
end $$;

-- 6. Signed out cannot call them; signed in can --------------------------------
do $$
begin
  perform pg_temp.check(not has_function_privilege('anon',
    'public.wallet_pay_once(uuid, uuid, numeric, text, text, boolean)', 'execute'), 'anon can pay');
  perform pg_temp.check(has_function_privilege('authenticated',
    'public.wallet_pay_once(uuid, uuid, numeric, text, text, boolean)', 'execute'), 'signed in cannot pay');
  perform pg_temp.check(not has_function_privilege('authenticated',
    'public.wallet_request_claim(uuid, uuid, text)', 'execute'), 'the claim helper is callable');
end $$;

rollback;

select 'wallet_request_keys: all passed';
