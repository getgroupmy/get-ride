-- ============================================================================
-- 0089 — GET.coin trading: the server decides the rate, and a buy/sell round
--        trip can never make money
-- ----------------------------------------------------------------------------
-- Problem: `wallet_trade_coins` (0066) trusted the client-supplied
-- `p_rate_per_gc` whenever `get_coin_settings.market_enabled` was on, only
-- clamping it to peg × (1 ± market_max_swing/100). A modified client could buy
-- at the bottom of the band and sell at the top. With a 50% swing every round
-- trip tripled the RM in GET.wallet.
--
-- Pricing the trade at a server-computed market rate alone does not close it.
-- The market signals react to the trader's own trades: a large sell drops the
-- "trading" signal, and every buy grows the "minting" signal, which pushes the
-- price down. So a user can sell high, let the price fall, and buy back
-- cheaper. Charging each side the worse end of its own price move doesn't
-- close it either, because buys lower the price.
--
-- Fix:
--   1. `get_coin_trade_quote()` ports `computeMarketRate` (Expo
--      `utils/getCoinStore.ts`, Flutter `admin/screens/commerce/get_coin.dart`)
--      to SQL over `get_coin_settings` + `get_coin_market_stats()`. It returns
--      the peg, the market rate, and the two prices the server trades at:
--        buy_rate  = max(market, peg)
--        sell_rate = min(market, peg)
--      The market rate still moves prices, but only as a spread around the
--      peg. Every buy costs at least the peg and every sell pays at most the
--      peg, for every user at every moment. So any sequence of trades that ends
--      with the same coins it started with returns at most the RM it put in,
--      however the trader moves the market signals. Fare coin redemption
--      (`wallet_redeem_fare_coins`) already values coins at the peg, so coins
--      bought here can't be cashed out above the peg there either.
--   2. `wallet_trade_coins` prices every trade from that quote. `p_rate_per_gc`
--      is kept so the four-argument signature both apps call still resolves,
--      but it is ignored. The RPC already returns the `rate_per_gc` and
--      `amount_currency` it settled at, and both apps show those values.
--   3. `get_coin_rate_history`: 0069 already made inserts admin-only, so
--      clients cannot write snapshots, and nothing prices off the history (it
--      only feeds the trade screen's chart). Since clients can't write it,
--      `wallet_trade_coins` now records a server-computed market-rate snapshot
--      at most once every 15 minutes so the chart keeps getting data.
-- ============================================================================

create or replace function public.get_coin_trade_quote()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s        public.get_coin_settings;
  v_stats  jsonb;
  v_peg    numeric := 0;
  v_p      numeric := 0;  -- signal pressure
  v_total  numeric;
  v_ratio  numeric;
  v_cap    numeric;
  v_mult   numeric := 1;
  v_market numeric;
begin
  select * into s from public.get_coin_settings where id = 'master';
  if not found or coalesce(s.coins_per_currency, 0) <= 0 then
    return jsonb_build_object(
      'peg', 0, 'market_rate', 0, 'buy_rate', 0, 'sell_rate', 0,
      'market_enabled', false);
  end if;

  v_peg := 1 / s.coins_per_currency;

  if s.market_enabled then
    v_stats := public.get_coin_market_stats();

    -- Same weights and log scales as computeMarketRate / _logNorm.
    if s.signal_trading then
      v_total := (v_stats->>'trade_buy_gc')::numeric + (v_stats->>'trade_sell_gc')::numeric;
      if v_total > 0 then
        v_p := v_p + 0.35 * ((v_stats->>'trade_buy_gc')::numeric
                             - (v_stats->>'trade_sell_gc')::numeric) / (v_total + 50);
      end if;
    end if;
    if s.signal_revenue then
      v_p := v_p + 0.25 * least(log(1 + greatest((v_stats->>'commission_revenue')::numeric, 0)) / 4, 1);
    end if;
    if s.signal_services then
      v_p := v_p + 0.2 * least(log(1 + greatest((v_stats->>'completed_services')::numeric, 0)) / 3, 1);
    end if;
    if s.signal_signups then
      v_p := v_p + 0.1 * least(log(1 + greatest((v_stats->>'new_signups')::numeric, 0)) / 2.5, 1);
    end if;
    if s.signal_minting then
      v_p := v_p - 0.3 * least(log(1 + greatest((v_stats->>'minted_gc')::numeric, 0)) / 4, 1);
    end if;
    if s.max_supply > 0 and (v_stats->>'circulating_supply')::numeric > 0 then
      v_ratio := least((v_stats->>'circulating_supply')::numeric / s.max_supply, 1);
      v_p := v_p + 0.3 * v_ratio * v_ratio;
    end if;

    v_cap := greatest(coalesce(s.market_max_swing, 0), 0) / 100;
    v_mult := 1 + least(greatest(v_p, -v_cap), v_cap);
  end if;

  v_market := round(v_peg * v_mult, 6);

  return jsonb_build_object(
    'peg',            v_peg,
    'market_rate',    v_market,
    'buy_rate',       greatest(v_market, v_peg),
    'sell_rate',      least(v_market, v_peg),
    'market_enabled', s.market_enabled
  );
end;
$$;

grant execute on function public.get_coin_trade_quote() to anon, authenticated;

-- ----------------------------------------------------------------------------
-- wallet_trade_coins — same signature and result shape as 0066; the rate is
-- now entirely server-side (p_rate_per_gc is accepted and ignored).
-- ----------------------------------------------------------------------------
create or replace function public.wallet_trade_coins(
  p_user uuid,
  p_direction text,
  p_coins numeric,
  p_rate_per_gc numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins numeric := round(coalesce(p_coins, 0), 2);
  v_quote jsonb;
  v_rate numeric;
  v_amount numeric;
  v_max_supply numeric;
  v_circulating numeric;
  v_balance numeric;
  v_rate_note text;
begin
  perform public.wallet_assert_caller(p_user);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;
  if p_direction is null or p_direction not in ('buy', 'sell') then
    raise exception 'invalid_direction';
  end if;

  -- Serialise trades so each one prices off the market state the previous
  -- one left behind.
  perform 1 from public.get_coin_settings where id = 'master' for update;

  v_quote := public.get_coin_trade_quote();
  v_rate := case when p_direction = 'buy'
                 then (v_quote->>'buy_rate')::numeric
                 else (v_quote->>'sell_rate')::numeric end;
  if coalesce(v_rate, 0) <= 0 then
    raise exception 'rate_unavailable';
  end if;

  -- Round in the house's favour, so rounding can't add up to a profit
  -- over many small trades.
  v_amount := case when p_direction = 'buy'
                   then round(ceil(v_coins * v_rate * 100) / 100, 2)
                   else round(floor(v_coins * v_rate * 100) / 100, 2) end;
  if v_amount <= 0 then
    raise exception 'invalid_amount';
  end if;

  select coalesce(max_supply, 0) into v_max_supply
  from public.get_coin_settings where id = 'master';

  v_rate_note := 'RM' || to_char(round(v_rate, 4), 'FM999999990.0000') || '/GC';

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0), (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  if p_direction = 'buy' then
    if v_max_supply > 0 then
      select coalesce(sum(balance), 0) into v_circulating
      from public.wallets where wallet_type = 'get_coin';
      if v_circulating + v_coins > v_max_supply then
        raise exception 'supply_cap_reached';
      end if;
    end if;

    select balance into v_balance
    from public.wallets
    where user_id = p_user and wallet_type = 'get_wallet'
    for update;
    if coalesce(v_balance, 0) < v_amount then
      raise exception 'insufficient_balance';
    end if;

    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_wallet', 'payment', -v_amount, 'coin_trade',
       'Bought ' || v_coins || ' GC @ ' || v_rate_note),
      (p_user, 'get_coin', 'topup', v_coins, 'trade_buy',
       'Bought @ ' || v_rate_note);
  else
    select balance into v_balance
    from public.wallets
    where user_id = p_user and wallet_type = 'get_coin'
    for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_coins';
    end if;

    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_coin', 'redeem', -v_coins, 'trade_sell',
       'Sold @ ' || v_rate_note),
      (p_user, 'get_wallet', 'topup', v_amount, 'coin_trade',
       'Sold ' || v_coins || ' GC @ ' || v_rate_note);
  end if;

  -- Server-written chart point (clients can't insert since 0069).
  if not exists (
    select 1 from public.get_coin_rate_history
    where recorded_at > now() - interval '15 minutes'
  ) then
    insert into public.get_coin_rate_history (rate_per_gc)
    values ((v_quote->>'market_rate')::numeric);
  end if;

  return jsonb_build_object(
    'coins', v_coins,
    'amount_currency', v_amount,
    'rate_per_gc', v_rate
  );
end;
$$;

grant execute on function public.wallet_trade_coins(uuid, text, numeric, numeric) to anon, authenticated;
