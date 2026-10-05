-- ============================================================================
-- 0093 — ride reward: price GET.coin on the ride's own fare
-- ----------------------------------------------------------------------------
-- `wallet_award_ride_coins(p_ride, p_user, p_fare)` (0062, locked down in
-- 0066) credits `p_fare × earn_coins_per_currency` GC to the rider of a
-- completed ride, once per ride. The fare it multiplied was the one the
-- client passed in, checked only against a 10,000 ceiling — so a rider could
-- claim any completed ride's reward on RM10,000 instead of what the trip
-- cost, minting coins from nothing.
--
-- Fix: the reward is priced on the fare stored on the ride
-- (`ride_fare`, falling back to `fare`). `p_fare` stays in the signature so
-- existing apps keep calling the same function, but it is ignored. Every
-- other rule is unchanged: caller must be the ride's rider
-- (`wallet_assert_caller` + rider check), the ride must be `completed`, and
-- `coin_rewarded_at` makes it once per ride.
-- ============================================================================

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
  r public.ride_requests;
  v_rate numeric;
  v_fare numeric;
  v_coins numeric;
begin
  perform public.wallet_assert_caller(p_user);

  select earn_coins_per_currency into v_rate
  from public.get_coin_settings
  where id = 'master';

  if v_rate is null or v_rate <= 0 then
    return 0;
  end if;

  -- Only the ride's rider can claim, only for a completed ride, only once.
  select * into r from public.ride_requests where id = p_ride for update;
  if not found then
    return 0;
  end if;
  if r.status <> 'completed' then
    return 0;
  end if;
  if r.rider_id is not null and r.rider_id <> p_user then
    raise exception 'not_authorized';
  end if;
  if r.coin_rewarded_at is not null then
    return 0;
  end if;

  -- The fare the trip was billed at, never the caller's number.
  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  if v_fare <= 0 or v_fare > 10000 then
    return 0;
  end if;

  v_coins := round(v_fare * v_rate, 2);
  if v_coins <= 0 then
    return 0;
  end if;

  update public.ride_requests
  set coin_rewarded_at = now()
  where id = p_ride;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
  values (p_user, 'get_coin', 'reward', v_coins, 'Ride reward');

  return v_coins;
end;
$$;

grant execute on function public.wallet_award_ride_coins(uuid, uuid, numeric) to anon, authenticated;
