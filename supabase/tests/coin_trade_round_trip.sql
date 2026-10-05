-- ============================================================================
-- Regression test for migration 0089 (server-side GET.coin trade rate).
--
-- Run against a scratch database that has schema.sql (or migrations through
-- 0089) applied:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/coin_trade_round_trip.sql
--
-- Everything runs in one transaction and is rolled back. A failed assertion
-- raises an exception (and with ON_ERROR_STOP, psql exits non-zero).
-- The final `select` prints 'coin_trade_round_trip: all passed'.
-- ============================================================================
begin;

-- Fixed settings: peg RM1/GC, market on, 50% swing, no supply cap, only the
-- signals a case turns on.
insert into public.get_coin_settings (id, coins_per_currency, market_enabled, market_max_swing)
values ('master', 1, true, 50)
on conflict (id) do update set coins_per_currency = 1, market_enabled = true,
  market_max_swing = 50, max_supply = 0;
update public.get_coin_settings set
  signal_trading = false, signal_revenue = false, signal_services = false,
  signal_signups = false, signal_minting = false
where id = 'master';

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a2')
on conflict do nothing;

create temp table t_user as select '00000000-0000-0000-0000-0000000000a1'::uuid as id;
grant select on t_user to authenticated;

-- helpers --------------------------------------------------------------------
create or replace function pg_temp.bal(p_type text) returns numeric language sql as $$
  select coalesce((select balance from public.wallets
                    where user_id = (select id from t_user) and wallet_type = p_type), 0)
$$;
create or replace function pg_temp.trade(p_dir text, p_coins numeric, p_rate numeric)
returns jsonb language sql as $$
  select public.wallet_trade_coins((select id from t_user), p_dir, p_coins, p_rate)
$$;
create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

select public.wallet_topup((select id from t_user), 100000, 'test');

-- 1. Market off: both sides at the peg, whatever the client sends ------------
do $$
declare q jsonb;
begin
  update public.get_coin_settings set market_enabled = false where id = 'master';
  q := public.get_coin_trade_quote();
  perform pg_temp.check((q->>'buy_rate')::numeric = 1 and (q->>'sell_rate')::numeric = 1,
    'market off → buy = sell = peg, got ' || q::text);
  perform pg_temp.check((pg_temp.trade('buy', 10, 0.0001)->>'rate_per_gc')::numeric = 1,
    'market off: forged buy rate ignored');
  perform pg_temp.check((pg_temp.trade('sell', 10, 9999)->>'rate_per_gc')::numeric = 1,
    'market off: forged sell rate ignored');
  perform pg_temp.check(pg_temp.bal('get_wallet') = 100000, 'market off round trip is neutral');
  update public.get_coin_settings set market_enabled = true where id = 'master';
end $$;

-- 2. The original exploit: buy at the band floor, sell at the band ceiling ---
do $$
declare w0 numeric := pg_temp.bal('get_wallet'); b jsonb; s jsonb;
begin
  b := pg_temp.trade('buy', 100, 0.0001);      -- 0066 priced this at RM0.50
  s := pg_temp.trade('sell', 100, 1000000);    -- 0066 priced this at RM1.50
  perform pg_temp.check((b->>'rate_per_gc')::numeric = 1, 'forged low buy rate ignored: ' || b::text);
  perform pg_temp.check((s->>'rate_per_gc')::numeric = 1, 'forged high sell rate ignored: ' || s::text);
  perform pg_temp.check(pg_temp.bal('get_wallet') <= w0, 'forged round trip gained RM');
end $$;

-- 3. Quote matches computeMarketRate: sign-ups signal saturated (+10%) ------
do $$
declare q jsonb; w0 numeric;
begin
  -- logNorm(n, 2.5) saturates at n >= 315 → +0.10
  insert into auth.users (id) select gen_random_uuid() from generate_series(1, 320);
  insert into public.profiles (id)
    select id from auth.users where id not in (select id from public.profiles);
  update public.get_coin_settings set signal_signups = true where id = 'master';

  q := public.get_coin_trade_quote();
  perform pg_temp.check((q->>'market_rate')::numeric = 1.1, 'market rate = peg × 1.10, got ' || q::text);
  perform pg_temp.check((q->>'buy_rate')::numeric = 1.1, 'buy at market when above peg');
  perform pg_temp.check((q->>'sell_rate')::numeric = 1, 'sell capped at peg when market above peg');

  w0 := pg_temp.bal('get_wallet');
  perform pg_temp.trade('buy', 100, 0.0001);
  perform pg_temp.trade('sell', 100, 1000000);
  perform pg_temp.check(pg_temp.bal('get_wallet') = w0 - 10,
    'market above peg: round trip costs the 10% spread, got ' || (pg_temp.bal('get_wallet') - w0));
  update public.get_coin_settings set signal_signups = false where id = 'master';
end $$;

-- 4. Market below peg: minting signal pulls the price down -------------------
do $$
declare q jsonb; w0 numeric;
begin
  update public.get_coin_settings set signal_minting = true where id = 'master';
  q := public.get_coin_trade_quote();
  perform pg_temp.check((q->>'market_rate')::numeric < 1, 'minting pushes market below peg: ' || q::text);
  perform pg_temp.check((q->>'buy_rate')::numeric = 1, 'buy floored at peg when market below peg');
  perform pg_temp.check((q->>'sell_rate')::numeric = (q->>'market_rate')::numeric, 'sell at market below peg');

  w0 := pg_temp.bal('get_wallet');
  perform pg_temp.trade('buy', 100, 0.0001);
  perform pg_temp.trade('sell', 100, 1000000);
  perform pg_temp.check(pg_temp.bal('get_wallet') < w0, 'market below peg: round trip loses');
  update public.get_coin_settings set signal_minting = false where id = 'master';
end $$;

-- 5. Self-manipulation: all signals on. A holder sells a large block (drops
--    the trading signal), then buys back in chunks (each buy grows the
--    minting signal, which pushes the price down). With one symmetric market
--    rate this sequence is profitable; with the peg-anchored spread it isn't.
do $$
declare w0 numeric; c0 numeric; i int;
begin
  update public.get_coin_settings set
    signal_trading = true, signal_revenue = true, signal_services = true,
    signal_signups = true, signal_minting = true
  where id = 'master';

  -- Give the user 5,000 GC earned outside trading (e.g. ride rewards).
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values ((select id from t_user), 'get_coin', 'topup', 5000, 'ride_reward', 'test grant');

  w0 := pg_temp.bal('get_wallet');
  c0 := pg_temp.bal('get_coin');
  perform pg_temp.trade('sell', 5000, 1000000);
  for i in 1..10 loop
    perform pg_temp.trade('buy', 500, 0.0001);
  end loop;
  perform pg_temp.check(pg_temp.bal('get_coin') = c0, 'coins back to start');
  perform pg_temp.check(pg_temp.bal('get_wallet') <= w0,
    'sell-then-buy-back gained RM: ' || (pg_temp.bal('get_wallet') - w0));

  -- And the reverse: buy in chunks, then dump.
  w0 := pg_temp.bal('get_wallet');
  for i in 1..10 loop
    perform pg_temp.trade('buy', 50, 0.0001);
  end loop;
  perform pg_temp.trade('sell', 500, 1000000);
  perform pg_temp.check(pg_temp.bal('get_coin') = c0, 'coins back to start (2)');
  perform pg_temp.check(pg_temp.bal('get_wallet') <= w0,
    'buy-then-sell gained RM: ' || (pg_temp.bal('get_wallet') - w0));
end $$;

-- 6. Rounding can't be farmed: 200 round trips of 0.05 GC (amounts round
--    up on buys and down on sells) ---------------------
do $$
declare w0 numeric := pg_temp.bal('get_wallet'); i int;
begin
  for i in 1..200 loop
    perform pg_temp.trade('buy', 0.05, 0.0001);
    perform pg_temp.trade('sell', 0.05, 1000000);
  end loop;
  perform pg_temp.check(pg_temp.bal('get_wallet') <= w0,
    'micro round trips gained RM: ' || (pg_temp.bal('get_wallet') - w0));
end $$;

-- 7. Server writes the chart snapshot; clients still can't -------------------
do $$
begin
  perform pg_temp.check(exists (
    select 1 from public.get_coin_rate_history where recorded_at > now() - interval '1 minute'),
    'trade records a server-computed rate snapshot');
  perform pg_temp.check(not has_table_privilege('authenticated', 'public.get_coin_rate_history', 'INSERT')
    or not exists (select 1 from pg_policies
                    where tablename = 'get_coin_rate_history' and cmd = 'INSERT'
                      and with_check not like '%caller_is_admin%'),
    'non-admin clients cannot insert rate snapshots');
end $$;

-- 8. API path: the apps' 4-argument call as an authenticated user ------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t_user), 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', (select id::text from t_user), true);
set local role authenticated;
do $$
declare r jsonb; w0 numeric;
begin
  w0 := (select balance from public.wallets
          where user_id = (select id from t_user) and wallet_type = 'get_wallet');
  r := public.wallet_trade_coins((select id from t_user), 'buy', 10, 0.0001::numeric);
  if (r->>'rate_per_gc')::numeric < 1 then
    raise exception 'FAILED: authenticated buy priced below peg: %', r;
  end if;
  r := public.wallet_trade_coins((select id from t_user), 'sell', 10, 1000000::numeric);
  if (r->>'rate_per_gc')::numeric > 1 then
    raise exception 'FAILED: authenticated sell priced above peg: %', r;
  end if;
  if (select balance from public.wallets
       where user_id = (select id from t_user) and wallet_type = 'get_wallet') > w0 then
    raise exception 'FAILED: authenticated round trip gained RM';
  end if;
  -- someone else's wallet is still refused
  begin
    perform public.wallet_trade_coins('00000000-0000-0000-0000-0000000000a2', 'buy', 1, 1);
    raise exception 'FAILED: traded on another user''s wallet';
  exception when others then
    if sqlerrm not like '%not_authorized%' then raise; end if;
  end;
end $$;
reset role;

select 'coin_trade_round_trip: all passed' as result;
rollback;
