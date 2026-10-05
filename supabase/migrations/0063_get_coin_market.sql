-- ============================================================================
-- 0063: GET.coin trading + market-speculated pricing + supply cap
-- ----------------------------------------------------------------------------
-- Trading: users buy GC with GET.wallet and sell GC back at the current rate.
--   The client inserts ledger rows (0060 trigger moves balances):
--     buy : get_wallet 'payment' (-RM, method coin_trade)
--           + get_coin 'topup' (+GC, method trade_buy)
--     sell: get_coin 'redeem' (-GC, method trade_sell)
--           + get_wallet 'topup' (+RM, method coin_trade)
--
-- Market pricing: when `market_enabled`, the coin's RM value floats around the
-- admin peg, driven by real in-app signals (each individually toggleable):
--   trading volume, commission revenue, completed services, new sign-ups,
--   and new coins minted. `market_max_swing` clamps the move (± percent).
--
-- Supply cap: `max_supply` (0 = unlimited) caps total GC in circulation, like
-- Bitcoin's 21M cap. Enforced on buys (minting).
-- ============================================================================

alter table public.get_coin_settings
  add column if not exists market_enabled  boolean       not null default false,
  add column if not exists signal_trading  boolean       not null default true,
  add column if not exists signal_revenue  boolean       not null default true,
  add column if not exists signal_services boolean       not null default true,
  add column if not exists signal_signups  boolean       not null default true,
  add column if not exists signal_minting  boolean       not null default true,
  add column if not exists market_max_swing numeric(6,2) not null default 50,
  add column if not exists max_supply      numeric(18,2) not null default 0;

alter table public.get_coin_settings
  drop constraint if exists get_coin_settings_swing_check;
alter table public.get_coin_settings
  add constraint get_coin_settings_swing_check
  check (market_max_swing >= 0 and market_max_swing <= 95);

alter table public.get_coin_settings
  drop constraint if exists get_coin_settings_supply_check;
alter table public.get_coin_settings
  add constraint get_coin_settings_supply_check
  check (max_supply >= 0);

-- ----------------------------------------------------------------------------
-- Rate history — snapshots of the effective RM value of 1 GC, for the trade
-- screen's price chart. Clients insert at most one point per ~15 minutes.
-- ----------------------------------------------------------------------------
create table if not exists public.get_coin_rate_history (
  id uuid primary key default gen_random_uuid(),
  rate_per_gc numeric(14,6) not null check (rate_per_gc > 0),
  recorded_at timestamptz not null default now()
);

create index if not exists get_coin_rate_history_time_idx
  on public.get_coin_rate_history(recorded_at desc);

alter table public.get_coin_rate_history enable row level security;

drop policy if exists "coin rate history read"   on public.get_coin_rate_history;
drop policy if exists "coin rate history insert" on public.get_coin_rate_history;

create policy "coin rate history read"   on public.get_coin_rate_history for select using (true);
create policy "coin rate history insert" on public.get_coin_rate_history for insert to public with check (true);

grant select, insert on public.get_coin_rate_history to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Market stats — one security-definer RPC returning every pricing signal over
-- a 30-day window plus circulating supply, so clients never need broad table
-- read access.
-- ----------------------------------------------------------------------------
create or replace function public.get_coin_market_stats()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_since    timestamptz := now() - interval '30 days';
  v_buy      numeric := 0;
  v_sell     numeric := 0;
  v_revenue  numeric := 0;
  v_services bigint  := 0;
  v_signups  bigint  := 0;
  v_minted   numeric := 0;
  v_supply   numeric := 0;
begin
  -- GC bought / sold through trading (30d)
  select coalesce(sum(amount), 0) into v_buy
  from public.wallet_transactions
  where wallet_type = 'get_coin' and method = 'trade_buy'
    and amount > 0 and created_at >= v_since;

  select coalesce(sum(-amount), 0) into v_sell
  from public.wallet_transactions
  where wallet_type = 'get_coin' and method = 'trade_sell'
    and amount < 0 and created_at >= v_since;

  -- App revenue from commissions charged to partners (30d)
  select coalesce(sum(-amount), 0) into v_revenue
  from public.wallet_transactions
  where wallet_type = 'get_credit' and kind = 'commission'
    and amount < 0 and created_at >= v_since;

  -- Completed services (30d)
  select count(*) into v_services
  from public.ride_requests
  where status = 'completed' and created_at >= v_since;

  -- New sign-ups: users + partners (30d)
  select
    (select count(*) from public.profiles where created_at >= v_since)
    + (select count(*) from public.partners where created_at >= v_since)
  into v_signups;

  -- New coins generated (rewards, admin grants, purchases) (30d)
  select coalesce(sum(amount), 0) into v_minted
  from public.wallet_transactions
  where wallet_type = 'get_coin' and amount > 0 and created_at >= v_since;

  -- Total GC in circulation right now
  select coalesce(sum(balance), 0) into v_supply
  from public.wallets
  where wallet_type = 'get_coin';

  return jsonb_build_object(
    'trade_buy_gc',        v_buy,
    'trade_sell_gc',       v_sell,
    'commission_revenue',  v_revenue,
    'completed_services',  v_services,
    'new_signups',         v_signups,
    'minted_gc',           v_minted,
    'circulating_supply',  v_supply
  );
end;
$$;

grant execute on function public.get_coin_market_stats() to anon, authenticated;
