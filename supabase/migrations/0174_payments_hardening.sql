-- ============================================================================
-- 0174: payments and wallets hardening
--
-- A ride's participants may update its row (the "participant update" policy),
-- and until now nothing stopped them changing what the money is worked out
-- from. A rider could mark their own trip completed and lower its fare, then
-- pay the lower amount (ride_pay prices from the row) or redeem coins against
-- it; a driver could lower the fare their commission is charged on, or pass
-- any fare to wallet_charge_ride_commission. This migration closes that:
--
--   * ride_requests_guard_fare (BEFORE INSERT/UPDATE, client roles only):
--       - a request is inserted open, unpaid, and with no server-only stamps;
--       - the status moves only along the trip's real path: open -> accepted
--         (the partner claiming, the rider taking an offer, auto-accept),
--         open -> cancelled / expired (the rider), accepted -> arrived and
--         accepted/arrived -> on_trip (the partner), accepted/arrived/on_trip
--         -> cancelled (either side; 0106 still keeps the driver from
--         cancelling a passenger on board), on_trip -> completed (the partner
--         alone). Nothing comes back from completed, cancelled or expired;
--       - while open, only the rider changes the fare (raising it, or taking
--         a partner's offer at exactly that offer); auto-accept (0141) bills
--         the offer under the rider's own amount;
--       - once accepted the fare, the pricing (currency, whole fare, tax,
--         charges), the offer and the auto-accept amount are frozen, except
--         that the partner may LOWER ride_fare when completing (ending early);
--       - commission, coin-reward and coin-redemption stamps are server-only.
--   * Commission is charged by the database when the trip completes, on the
--     stored fare at the rate it resolves itself. wallet_charge_ride_commission
--     stays for the apps that still call it; it ignores the caller's fare and
--     rate and charges only the ride's own partner, once, after completion.
--   * ride_pay(p_ride, p_method, p_expected): with p_expected the payment goes
--     through only when the amount left to pay is still what the rider saw.
--   * No coins against a ride already paid or being paid in cash; the cash
--     paths stamp fare_coins_redeemed_at so coins can't follow them.
--   * Every coin mint (ride reward, referral bonuses) respects max_supply.
--   * Coin rounding favours the house: coins spent are rounded up, coins
--     earned rounded down, so many small payments can't add up to a profit.
--
-- Admins (caller_is_admin), SECURITY DEFINER functions and the service role
-- are not client roles and pass the guard, as with the other ride guards.
-- ============================================================================

-- A money amount a client may store: present, not negative, finite. NaN sorts
-- above every number, so the upper bound shuts it out too.
create or replace function public.ride_money_ok(p numeric)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p is null or (p >= 0 and p < 1000000000);
$$;

create or replace function public.ride_requests_guard_fare()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_is_rider  boolean;
  v_old_fare  numeric;
  v_new_fare  numeric;
  v_fare_changed boolean;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if not (public.ride_money_ok(new.fare) and public.ride_money_ok(new.ride_fare)
          and public.ride_money_ok(new.offered_fare) and public.ride_money_ok(new.auto_accept_fare)) then
    raise exception 'RIDE_FARE_INVALID' using errcode = '22023';
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'open' then
      raise exception 'RIDE_STATUS_TRANSITION' using errcode = '42501',
        hint = 'A ride request starts open.';
    end if;
    if new.payment_status is not null or new.paid_method is not null
       or new.paid_amount is not null or new.paid_at is not null
       or new.commission_rate is not null or new.commission_amount is not null
       or new.commission_charged_at is not null or new.coin_rewarded_at is not null
       or new.fare_coins_redeemed_at is not null then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
    end if;
    return new;
  end if;

  -- Stamps only the server writes.
  if (new.commission_rate, new.commission_amount, new.commission_charged_at,
      new.coin_rewarded_at, new.fare_coins_redeemed_at)
     is distinct from
     (old.commission_rate, old.commission_amount, old.commission_charged_at,
      old.coin_rewarded_at, old.fare_coins_redeemed_at) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
  end if;

  v_is_rider := v_uid is not null and v_uid = old.rider_id;

  -- The status, along the trip's own path.
  if new.status is distinct from old.status then
    if not (
         (old.status = 'open' and new.status = 'accepted'
            and ((v_is_rider and old.partner_id is not null and new.partner_id = old.partner_id)
                 or (not v_is_rider and v_uid is not null and new.partner_id = v_uid)))
      or (old.status = 'open' and new.status in ('cancelled', 'expired') and v_is_rider)
      or (old.status = 'accepted' and new.status = 'arrived' and v_uid = old.partner_id)
      or (old.status in ('accepted', 'arrived') and new.status = 'on_trip' and v_uid = old.partner_id)
      or (old.status in ('accepted', 'arrived', 'on_trip') and new.status = 'cancelled'
            and (v_is_rider or v_uid = old.partner_id))
      or (old.status = 'on_trip' and new.status = 'completed' and v_uid = old.partner_id)
    ) then
      raise exception 'RIDE_STATUS_TRANSITION' using errcode = '42501',
        hint = format('A ride can''t go from %s to %s here.', old.status, new.status);
    end if;
  end if;

  -- The pricing a ride was booked with is fixed once it is written.
  if (new.currency, new.whole_fare, new.tax_name, new.tax_kind, new.tax_value, new.charges)
     is distinct from
     (old.currency, old.whole_fare, old.tax_name, old.tax_kind, old.tax_value, old.charges) then
    raise exception 'RIDE_FARE_LOCKED' using errcode = '42501';
  end if;

  if old.status <> 'open'
     and (new.offered_fare, new.auto_accept_fare) is distinct from (old.offered_fare, old.auto_accept_fare) then
    raise exception 'RIDE_FARE_LOCKED' using errcode = '42501';
  end if;

  v_fare_changed := (new.fare, new.ride_fare) is distinct from (old.fare, old.ride_fare);
  v_old_fare := round(coalesce(old.ride_fare, old.fare, 0), 2);
  v_new_fare := round(coalesce(new.ride_fare, new.fare, 0), 2);

  if old.status = 'open' and new.status = 'accepted' then
    if v_is_rider then
      -- Taking an offer: billed at exactly that offer.
      if old.offered_fare is null
         or round(new.fare, 2) is distinct from round(old.offered_fare, 2)
         or v_new_fare <> round(old.offered_fare, 2) then
        raise exception 'RIDE_FARE_LOCKED' using errcode = '42501',
          hint = 'Accept the offer at the amount offered.';
      end if;
    elsif v_fare_changed then
      -- A partner's claim keeps the rider's fare, unless the rider's own
      -- auto-accept amount took the partner's offer (0141).
      if not (old.auto_accept_fare is not null and new.offered_fare is not null
              and new.offered_fare <= old.auto_accept_fare + 0.005
              and round(new.fare, 2) = round(new.offered_fare, 2)
              and v_new_fare = round(new.offered_fare, 2)) then
        raise exception 'RIDE_FARE_LOCKED' using errcode = '42501';
      end if;
    end if;
    return new;
  end if;

  if not v_fare_changed then
    return new;
  end if;

  -- The rider prices their own open request.
  if old.status = 'open' and new.status = 'open' and v_is_rider then
    return new;
  end if;

  -- Ending early: the partner may lower the fare stored on the ride, never
  -- raise it, and the booked fare stays as it was.
  if old.status = 'on_trip' and new.status = 'completed' and v_uid = old.partner_id
     and new.fare is not distinct from old.fare
     and new.ride_fare is not null and round(new.ride_fare, 2) > 0
     and round(new.ride_fare, 2) <= v_old_fare then
    return new;
  end if;

  raise exception 'RIDE_FARE_LOCKED' using errcode = '42501',
    hint = 'The fare is fixed once a driver has accepted the ride.';
end;
$$;

revoke execute on function public.ride_requests_guard_fare() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_guard_fare on public.ride_requests;
create trigger trg_ride_requests_b_guard_fare
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_fare();

-- ----------------------------------------------------------------------------
-- Commission, charged by the database from the stored fare.
-- ----------------------------------------------------------------------------
create or replace function public.ride_charge_commission(p_ride uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric;
  v_rate numeric;
  v_amount numeric(12,2);
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.status <> 'completed' or r.partner_id is null or r.commission_charged_at is not null then
    return;
  end if;

  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  if not public.ride_money_ok(v_fare) or v_fare <= 0 then
    return;
  end if;

  v_rate := public.commission_resolve_rate(r.partner_id, r.country, r.state, r.city, r.suburb);
  if v_rate is null or not (v_rate > 0 and v_rate < 1) then
    return;
  end if;

  v_amount := round(v_fare * v_rate, 2);

  -- Ledger-driven: trg_wallet_tx_apply moves the balance.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
  values (r.partner_id, 'get_credit', 'commission', -v_amount,
          'Ride commission ' || round(v_rate * 100, 1) || '% of ' ||
          coalesce(r.currency, 'RM') || ' ' || v_fare);

  update public.ride_requests
     set commission_rate = v_rate,
         commission_amount = v_amount,
         commission_charged_at = now()
   where id = p_ride;
end;
$$;

revoke all on function public.ride_charge_commission(uuid) from public, anon, authenticated, service_role;

create or replace function public.ride_requests_charge_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A completion is never held up by the commission: a failure here is left
  -- for the back office, as the apps' own call was.
  begin
    perform public.ride_charge_commission(new.id);
  exception when others then
    raise warning 'ride % commission not charged: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

revoke execute on function public.ride_requests_charge_commission() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_commission on public.ride_requests;
create trigger trg_ride_requests_commission
  after update of status on public.ride_requests
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function public.ride_requests_charge_commission();

-- The apps' call (1.4.5 and older): the fare and rate they pass are ignored.
create or replace function public.wallet_charge_ride_commission(p_ride uuid, p_partner uuid, p_fare numeric, p_rate numeric default null)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  w public.wallets;
begin
  perform public.wallet_assert_caller(p_partner);

  select * into r from public.ride_requests where id = p_ride;
  if not found then
    raise exception 'ride_not_found';
  end if;
  if r.partner_id is null or r.partner_id <> p_partner then
    raise exception 'not_authorized';
  end if;
  if r.status <> 'completed' then
    raise exception 'ride_not_completed';
  end if;

  perform public.ride_charge_commission(p_ride);

  select * into w from public.wallets where user_id = p_partner and wallet_type = 'get_credit';
  return w;
end;
$$;

-- ----------------------------------------------------------------------------
-- Coins: supply cap and rounding.
-- ----------------------------------------------------------------------------

-- How many of p_coins may be minted under max_supply (0 or unset: no cap).
-- Locks the settings row, so two mints can't both take the last room.
create or replace function public.coin_mint_room(p_coins numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max numeric;
  v_circulating numeric;
begin
  if coalesce(p_coins, 0) <= 0 then
    return 0;
  end if;
  select coalesce(max_supply, 0) into v_max
    from public.get_coin_settings where id = 'master' for update;
  if coalesce(v_max, 0) <= 0 then
    return p_coins;
  end if;
  select coalesce(sum(balance), 0) into v_circulating
    from public.wallets where wallet_type = 'get_coin';
  return greatest(0, least(p_coins, floor((v_max - v_circulating) * 100) / 100));
end;
$$;

revoke all on function public.coin_mint_room(numeric) from public, anon, authenticated, service_role;

create or replace function public.wallet_award_ride_coins(p_ride uuid, p_user uuid, p_fare numeric)
returns numeric
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

  -- Earned coins round down; never more than the supply has room for.
  v_coins := public.coin_mint_room(floor(v_fare * v_rate * 100) / 100);
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

create or replace function public.apply_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_referrer uuid;
  v_created timestamptz;
  v_enabled boolean := true;
  v_referrer_coins numeric := 0;
  v_referred_coins numeric := 0;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if length(v_code) < 4 then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  -- New accounts only: a referral is part of signing up.
  select created_at into v_created from public.profiles where id = v_user;
  if v_created is null or v_created < now() - interval '7 days' then
    return jsonb_build_object('ok', false, 'error', 'not_new_account');
  end if;

  select coalesce(referral_enabled, true),
         coalesce(referral_referrer_coins, 0),
         coalesce(referral_referred_coins, 0)
    into v_enabled, v_referrer_coins, v_referred_coins
    from public.get_coin_settings
   where id = 'master';

  if not coalesce(v_enabled, true) then
    return jsonb_build_object('ok', false, 'error', 'disabled');
  end if;

  -- Resolve the referrer: an explicit profiles.referral_code wins, else the
  -- deterministic account-id code the apps share (its first 8 characters).
  select id into v_referrer
    from public.profiles
   where upper(coalesce(referral_code, '')) = v_code
   limit 1;
  if v_referrer is null and length(v_code) = 8 then
    select id into v_referrer
      from public.profiles
     where upper(left(replace(id::text, '-', ''), 8)) = v_code
     limit 1;
  end if;

  if v_referrer is null then
    return jsonb_build_object('ok', false, 'error', 'code_not_found');
  end if;
  if v_referrer = v_user then
    return jsonb_build_object('ok', false, 'error', 'self_referral');
  end if;
  if exists (select 1 from public.referrals where referred_user_id = v_user) then
    return jsonb_build_object('ok', false, 'error', 'already_referred');
  end if;

  -- Bonuses are minted coins: only what the supply has room for. The
  -- referral itself is recorded either way, at what was actually given.
  v_referred_coins := public.coin_mint_room(v_referred_coins);
  if v_referred_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_user, 'get_coin', 'referral', v_referred_coins, 'referral', 'Welcome bonus — joined with a referral link');
  end if;
  v_referrer_coins := public.coin_mint_room(v_referrer_coins);
  if v_referrer_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_referrer, 'get_coin', 'referral', v_referrer_coins, 'referral', 'Referral bonus — a friend joined with your link');
  end if;

  insert into public.referrals
    (referrer_user_id, referred_user_id, code, referrer_coins, referred_coins)
  values
    (v_referrer, v_user, v_code, v_referrer_coins, v_referred_coins);

  return jsonb_build_object(
    'ok', true,
    'referrer_coins', v_referrer_coins,
    'referred_coins', v_referred_coins
  );
end;
$$;

create or replace function public.wallet_pay(p_user uuid, p_amount numeric, p_note text default null,
                                             p_method text default 'qr_scan', p_redeem_coins boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric := 0;
  v_coin_balance numeric := 0;
  v_wallet_balance numeric;
  v_max_coin_value numeric := 0;
  v_coin_value numeric := 0;
  v_coins_used numeric := 0;
  v_wallet_share numeric;
begin
  perform public.wallet_assert_caller(p_user);
  if not public.ride_money_ok(v_amount) or v_amount <= 0 or v_amount > 100000 then
    raise exception 'invalid_amount';
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0), (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  if coalesce(p_redeem_coins, false) then
    select coins_per_currency into v_rate
    from public.get_coin_settings where id = 'master';

    if coalesce(v_rate, 0) > 0 then
      select balance into v_coin_balance
      from public.wallets
      where user_id = p_user and wallet_type = 'get_coin'
      for update;
      v_coin_balance := coalesce(v_coin_balance, 0);

      if v_coin_balance > 0 then
        v_max_coin_value := floor((v_coin_balance / v_rate) * 100) / 100;
        v_coin_value := least(v_max_coin_value, v_amount);
        -- Coins spent round up (never past the balance: v_coin_value * rate
        -- is at most the two-decimal balance).
        v_coins_used := ceil(v_coin_value * v_rate * 100) / 100;
      end if;
    end if;
  end if;

  v_wallet_share := round(v_amount - v_coin_value, 2);

  select balance into v_wallet_balance
  from public.wallets
  where user_id = p_user and wallet_type = 'get_wallet'
  for update;

  if coalesce(v_wallet_balance, 0) < v_wallet_share then
    raise exception 'insufficient_balance';
  end if;

  if v_coins_used > 0 then
    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_coin', 'redeem', -v_coins_used, p_method,
       coalesce(p_note, 'Payment') || ' — paid with coins (RM' ||
       to_char(v_coin_value, 'FM999999990.00') || ')');
  end if;

  if v_wallet_share > 0 then
    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_wallet', 'payment', -v_wallet_share, p_method, p_note);
  end if;

  return jsonb_build_object(
    'coins_used', v_coins_used,
    'coin_value', v_coin_value,
    'wallet_paid', v_wallet_share
  );
end;
$$;

create or replace function public.wallet_redeem_fare_coins(p_user uuid, p_fare numeric, p_ride uuid default null)
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
  if not public.ride_money_ok(v_fare) or v_fare <= 0 or v_fare > 10000 then
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
      -- Already paid, or being paid in cash: coins would pay it twice.
      if r.fare_coins_redeemed_at is not null
         or r.payment_status in ('paid', 'cash_pending') then
        return jsonb_build_object('coins_used', 0, 'coin_value', 0);
      end if;
      v_due := public.ride_left_to_pay(r);
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
    v_coins_used := ceil(v_coin_value * v_rate * 100) / 100;
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

-- ----------------------------------------------------------------------------
-- Paying for the ride.
-- ----------------------------------------------------------------------------
drop function if exists public.ride_pay(uuid, text);

create or replace function public.ride_pay(p_ride uuid, p_method text, p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_due numeric;
  v_rate numeric;
  v_coins numeric;
  v_balance numeric;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_method not in ('get_wallet', 'get_coin') then
    raise exception 'invalid_method';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized';
  end if;
  if r.status <> 'completed' then
    raise exception 'ride_not_completed';
  end if;
  if r.payment_status = 'paid' then
    return jsonb_build_object('paid', coalesce(r.paid_amount, 0), 'method', r.paid_method, 'already', true);
  end if;
  if r.partner_id is null then
    raise exception 'no_driver';
  end if;

  v_due := public.ride_left_to_pay(r);
  if not public.ride_money_ok(v_due) then
    raise exception 'invalid_amount';
  end if;

  -- The rider agreed to pay what they were shown; anything else waits for
  -- them to look again.
  if p_expected is not null and abs(round(p_expected, 2) - v_due) > 0.005 then
    raise exception 'amount_changed' using hint = v_due::text;
  end if;

  if v_due > 0 and p_method = 'get_wallet' then
    insert into public.wallets (user_id, wallet_type, balance) values (r.rider_id, 'get_wallet', 0)
      on conflict (user_id, wallet_type) do nothing;
    select balance into v_balance from public.wallets
     where user_id = r.rider_id and wallet_type = 'get_wallet' for update;
    if coalesce(v_balance, 0) < v_due then
      raise exception 'insufficient_balance';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
      (r.rider_id, 'get_wallet', 'ride_payment', -v_due, 'ride',
       'Ride paid — RM' || to_char(v_due, 'FM999999990.00')),
      (r.partner_id, 'get_wallet', 'ride_earning', v_due, 'ride',
       'Ride fare received — RM' || to_char(v_due, 'FM999999990.00'));
  elsif v_due > 0 and p_method = 'get_coin' then
    select coins_per_currency into v_rate from public.get_coin_settings where id = 'master';
    if coalesce(v_rate, 0) <= 0 then
      raise exception 'coins_unavailable';
    end if;
    v_coins := ceil(v_due * v_rate * 100) / 100;
    insert into public.wallets (user_id, wallet_type, balance) values (r.rider_id, 'get_coin', 0)
      on conflict (user_id, wallet_type) do nothing;
    select balance into v_balance from public.wallets
     where user_id = r.rider_id and wallet_type = 'get_coin' for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_balance';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
      (r.rider_id, 'get_coin', 'redeem', -v_coins, 'ride_fare',
       'Ride fare — RM' || to_char(v_due, 'FM999999990.00') || ' paid with coins'),
      (r.partner_id, 'get_wallet', 'ride_coin_payout', v_due, 'ride_fare',
       'Ride fare paid with GET.coin — RM' || to_char(v_due, 'FM999999990.00'));
  end if;

  update public.ride_requests
     set payment_status = 'paid',
         paid_method = p_method,
         paid_amount = v_due,
         paid_at = now(),
         fare_coins_value = case when p_method = 'get_coin' then coalesce(fare_coins_value, 0) + v_due else fare_coins_value end,
         fare_coins_used = case when p_method = 'get_coin' then coalesce(fare_coins_used, 0) + coalesce(v_coins, 0) else fare_coins_used end,
         fare_coins_redeemed_at = coalesce(fare_coins_redeemed_at, now())
   where id = p_ride;

  return jsonb_build_object('paid', v_due, 'method', p_method, 'coins', coalesce(v_coins, 0));
end;
$$;

revoke execute on function public.ride_pay(uuid, text, numeric) from public, anon;
grant execute on function public.ride_pay(uuid, text, numeric) to authenticated;

create or replace function public.ride_pay_cash(p_ride uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or auth.uid() is null or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized';
  end if;
  if r.status <> 'completed' then
    raise exception 'ride_not_completed';
  end if;
  if r.payment_status = 'paid' then
    return 'paid';
  end if;
  update public.ride_requests
     set payment_status = 'cash_pending',
         paid_method = 'cash',
         fare_coins_redeemed_at = coalesce(fare_coins_redeemed_at, now())
   where id = p_ride;
  return 'cash_pending';
end;
$$;

create or replace function public.ride_confirm_cash(p_ride uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or auth.uid() is null or r.partner_id is distinct from auth.uid() then
    raise exception 'not_authorized';
  end if;
  if r.status <> 'completed' then
    raise exception 'ride_not_completed';
  end if;
  if r.payment_status = 'paid' then
    return 'paid';
  end if;
  update public.ride_requests
     set payment_status = 'paid',
         paid_method = 'cash',
         paid_amount = public.ride_left_to_pay(r),
         paid_at = now(),
         fare_coins_redeemed_at = coalesce(fare_coins_redeemed_at, now())
   where id = p_ride;
  return 'paid';
end;
$$;
