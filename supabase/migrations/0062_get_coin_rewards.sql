-- ============================================================================
-- 0062: GET.coin earn & spend
-- ----------------------------------------------------------------------------
-- Earn:  riders are rewarded GC after each completed ride, at an
--        admin-configured rate (`earn_coins_per_currency` GC per RM1 of the
--        final fare; 0 disables rewards). Reward rows are inserted into
--        `wallet_transactions` with kind 'reward' on the get_coin wallet —
--        the 0060 ledger trigger moves the balance automatically.
--
-- Spend: QR payments can be paid partially with GET.coin. The client inserts
--        a kind 'redeem' row (negative GC) on the get_coin wallet plus a
--        smaller kind 'payment' row on get_wallet for the remainder.
-- ============================================================================

alter table public.get_coin_settings
  add column if not exists earn_coins_per_currency numeric(12,4) not null default 0;

alter table public.get_coin_settings
  drop constraint if exists get_coin_settings_earn_rate_check;
alter table public.get_coin_settings
  add constraint get_coin_settings_earn_rate_check
  check (earn_coins_per_currency >= 0);

-- ----------------------------------------------------------------------------
-- Idempotent per-ride reward: anchors on ride_requests.coin_rewarded_at so a
-- ride can never be rewarded twice, even across devices.
-- ----------------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists coin_rewarded_at timestamptz;

create or replace function public.wallet_award_ride_coins(
  p_ride uuid,
  p_user uuid,
  p_fare numeric
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate numeric;
  v_coins numeric;
  v_claimed int;
begin
  select earn_coins_per_currency into v_rate
  from public.get_coin_settings
  where id = 'master';

  if v_rate is null or v_rate <= 0 or p_fare is null or p_fare <= 0 then
    return 0;
  end if;

  v_coins := round(p_fare * v_rate, 2);
  if v_coins <= 0 then
    return 0;
  end if;

  -- Claim the ride atomically; a second call finds coin_rewarded_at set.
  update public.ride_requests
  set coin_rewarded_at = now()
  where id = p_ride and coin_rewarded_at is null;
  get diagnostics v_claimed = row_count;
  if v_claimed = 0 then
    return 0;
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
  values (p_user, 'get_coin', 'reward', v_coins, 'Ride reward');

  return v_coins;
end;
$$;

grant execute on function public.wallet_award_ride_coins(uuid, uuid, numeric) to anon, authenticated;
