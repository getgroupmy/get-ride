-- 0101: GET.coin paid towards a fare reaches the driver.
--
-- wallet_redeem_fare_coins (0066) took the rider's coins for part of a ride
-- fare and left it there: nothing told the driver, who still collected the
-- whole fare in cash, and nothing paid them for the part the coins covered.
-- Now, for a ride:
--   * the coins are redeemed against what the rider actually owes on the ride
--     (ride fare plus the tolls and other charges the driver declared, 0100) —
--     the client's p_fare can lower that, never raise it;
--   * the ride must be completed, by its own rider;
--   * the coin value and coins used are stamped on the ride
--     (fare_coins_value / fare_coins_used), so both apps show the driver what
--     was paid in coins and what is left to collect in cash;
--   * the coin value is credited to the driver's GET.wallet in the same
--     transaction (kind 'ride_coin_payout').
-- The once-per-ride rule (fare_coins_redeemed_at) is unchanged, so a payout
-- can't repeat. A call without p_ride (Expo's simulated rides) behaves as
-- before and pays nobody. fare_coins_* are written only by this function:
-- the 0100 guard now also stops any client from setting them.

alter table public.ride_requests
  add column if not exists fare_coins_value numeric(10,2),
  add column if not exists fare_coins_used numeric(12,2);

create or replace function public.wallet_redeem_fare_coins(
  p_user uuid,
  p_fare numeric,
  p_ride uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric := round(coalesce(p_fare, 0), 2);
  v_due numeric;
  v_rate numeric;
  v_coin_balance numeric := 0;
  v_max_coin_value numeric := 0;
  v_coin_value numeric := 0;
  v_coins_used numeric := 0;
begin
  perform public.wallet_assert_caller(p_user);
  if v_fare <= 0 or v_fare > 10000 then
    raise exception 'invalid_amount';
  end if;

  select coins_per_currency into v_rate
  from public.get_coin_settings where id = 'master';
  if coalesce(v_rate, 0) <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  if p_ride is not null then
    select * into r from public.ride_requests where id = p_ride for update;
    if found then
      if r.rider_id is not null and r.rider_id <> p_user then
        raise exception 'not_authorized';
      end if;
      if r.status <> 'completed' then
        raise exception 'ride_not_completed';
      end if;
      if r.fare_coins_redeemed_at is not null then
        return jsonb_build_object('coins_used', 0, 'coin_value', 0);
      end if;
      v_due := round(coalesce(r.ride_fare, r.fare, 0)
                     + coalesce(r.toll_charges, 0)
                     + coalesce(r.other_charges, 0), 2);
      v_fare := least(v_fare, v_due);
      update public.ride_requests
         set fare_coins_redeemed_at = now()
       where id = p_ride;
    end if;
  end if;

  if v_fare <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_coin_balance
  from public.wallets
  where user_id = p_user and wallet_type = 'get_coin'
  for update;
  v_coin_balance := coalesce(v_coin_balance, 0);

  if v_coin_balance > 0 then
    v_max_coin_value := floor((v_coin_balance / v_rate) * 100) / 100;
    v_coin_value := least(v_max_coin_value, v_fare);
    v_coins_used := round(v_coin_value * v_rate, 2);
  end if;

  if v_coins_used <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, method, note)
  values
    (p_user, 'get_coin', 'redeem', -v_coins_used, 'ride_fare',
     'Ride fare — RM' || to_char(v_coin_value, 'FM999999990.00') || ' paid with coins');

  if r.id is not null then
    update public.ride_requests
       set fare_coins_value = v_coin_value,
           fare_coins_used = v_coins_used
     where id = r.id;
    if r.partner_id is not null then
      insert into public.wallet_transactions
        (user_id, wallet_type, kind, amount, method, note)
      values
        (r.partner_id, 'get_wallet', 'ride_coin_payout', v_coin_value, 'ride_fare',
         'Ride fare paid with GET.coin — RM' || to_char(v_coin_value, 'FM999999990.00'));
    end if;
  end if;

  return jsonb_build_object('coins_used', v_coins_used, 'coin_value', v_coin_value);
end;
$$;

grant execute on function public.wallet_redeem_fare_coins(uuid, numeric, uuid) to anon, authenticated;

-- 0100's guard, extended to the coin columns: no client sets them.
create or replace function public.ride_requests_guard_charges()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if coalesce(new.toll_charges, 0) <> 0
       or coalesce(new.other_charges, 0) <> 0
       or new.other_charges_note is not null then
      raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
        hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
    end if;
    if new.fare_coins_value is not null or new.fare_coins_used is not null then
      raise exception 'RIDE_FARE_COINS_SERVER_ONLY' using errcode = '42501';
    end if;
    return new;
  end if;
  if (new.toll_charges, new.other_charges, new.other_charges_note)
       is distinct from (old.toll_charges, old.other_charges, old.other_charges_note)
     and (old.partner_id is null or old.partner_id is distinct from auth.uid()) then
    raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
      hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
  end if;
  if (new.fare_coins_value, new.fare_coins_used) is distinct from (old.fare_coins_value, old.fare_coins_used) then
    raise exception 'RIDE_FARE_COINS_SERVER_ONLY' using errcode = '42501';
  end if;
  return new;
end;
$$;
