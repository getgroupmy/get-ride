-- ============================================================================
-- 0142: paying for a ride when it ends
--
-- The driver completes the trip with any tolls and other charges (0100).
-- The passenger is then shown the total and pays:
--
--   * "Pay now" from GET.wallet or GET.coin (ride_pay): the passenger's
--     wallet is debited and the driver's GET.wallet credited, in one go;
--   * "Paid in cash" (ride_pay_cash): the ride waits for the driver, who
--     confirms the cash was received (ride_confirm_cash).
--
-- ride_requests.payment_status follows it:
--     null (a ride from before this, or not completed yet)
--     'due'           the trip is completed and nothing is paid yet
--     'cash_pending'  the passenger says they paid in cash
--     'paid'          done (paid_method, paid_amount, paid_at say how)
--
-- The amount is always worked out here, never taken from the phone
-- (ride_amount_due: the fare, its region surcharges and taxes as the app
-- prices them, tolls and other charges), less what GET.coin already paid.
-- Only these functions write the payment columns.
-- ============================================================================

alter table public.ride_requests add column if not exists payment_status text;
alter table public.ride_requests add column if not exists paid_method text;
alter table public.ride_requests add column if not exists paid_amount numeric(10,2);
alter table public.ride_requests add column if not exists paid_at timestamptz;

alter table public.ride_requests drop constraint if exists ride_requests_payment_status_check;
alter table public.ride_requests add constraint ride_requests_payment_status_check
  check (payment_status is null or payment_status in ('due', 'cash_pending', 'paid'));
alter table public.ride_requests drop constraint if exists ride_requests_paid_method_check;
alter table public.ride_requests add constraint ride_requests_paid_method_check
  check (paid_method is null or paid_method in ('get_wallet', 'get_coin', 'cash'));

-- ---- What the ride comes to --------------------------------------------------
-- As RegionPricing / RideRequest.totalDue price it in the app: the fare, its
-- surcharges, the taxes (the plain tax on the fare; scheduled taxes on the
-- fare and its surcharges), each to the cent, then tolls and other charges.
create or replace function public.ride_amount_due(r public.ride_requests)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  f numeric := coalesce(r.ride_fare, r.fare, 0);
  c jsonb;
  v numeric;
  surcharge numeric := 0;
  tax numeric := 0;
  base numeric;
begin
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' = 'tax';
      surcharge := surcharge + round(greatest(0, case when c->>'charge' = 'fixed' then v else f * v / 100 end), 2);
    end loop;
  end if;
  surcharge := round(greatest(0, surcharge), 2);
  base := f + surcharge;

  if btrim(coalesce(r.tax_name, '')) <> '' and coalesce(r.tax_value, 0) > 0 then
    tax := tax + round(greatest(0, case when r.tax_kind = 'fixed' then r.tax_value else f * r.tax_value / 100 end), 2);
  end if;
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' <> 'tax';
      tax := tax + round(greatest(0, case when c->>'charge' = 'fixed' then v else base * v / 100 end), 2);
    end loop;
  end if;
  tax := round(greatest(0, tax), 2);

  return round(f + surcharge + tax + coalesce(r.toll_charges, 0) + coalesce(r.other_charges, 0), 2);
end;
$$;

revoke execute on function public.ride_amount_due(public.ride_requests) from public, anon;
grant execute on function public.ride_amount_due(public.ride_requests) to authenticated;

-- What is left to pay: the total less what GET.coin already paid.
create or replace function public.ride_left_to_pay(r public.ride_requests)
returns numeric
language sql
stable
set search_path = public
as $$
  select greatest(0, round(public.ride_amount_due(r) - coalesce(r.fare_coins_value, 0), 2));
$$;

revoke execute on function public.ride_left_to_pay(public.ride_requests) from public, anon;
grant execute on function public.ride_left_to_pay(public.ride_requests) to authenticated;

-- ---- Only the functions below write the payment ------------------------------
-- A completed trip becomes 'due' however it was completed (any app).
create or replace function public.ride_requests_guard_payment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_is_admin()
     and (new.payment_status, new.paid_method, new.paid_amount, new.paid_at)
         is distinct from (old.payment_status, old.paid_method, old.paid_amount, old.paid_at) then
    raise exception 'RIDE_PAYMENT_SERVER_ONLY' using errcode = '42501';
  end if;
  if new.status = 'completed' and old.status is distinct from 'completed' and new.payment_status is null then
    new.payment_status := 'due';
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_guard_payment() from public, anon, authenticated;

create or replace trigger trg_ride_requests_b_guard_payment
  before update on public.ride_requests
  for each row execute function public.ride_requests_guard_payment();

-- ---- Pay now: GET.wallet or GET.coin ------------------------------------------
create or replace function public.ride_pay(p_ride uuid, p_method text)
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
    v_coins := round(v_due * v_rate, 2);
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
         -- Coins paid: they show as the GET.coin line, and a choice made at
         -- booking can no longer spend coins on this ride a second time.
         fare_coins_value = case when p_method = 'get_coin' then coalesce(fare_coins_value, 0) + v_due else fare_coins_value end,
         fare_coins_used = case when p_method = 'get_coin' then coalesce(fare_coins_used, 0) + coalesce(v_coins, 0) else fare_coins_used end,
         fare_coins_redeemed_at = coalesce(fare_coins_redeemed_at, now())
   where id = p_ride;

  return jsonb_build_object('paid', v_due, 'method', p_method, 'coins', coalesce(v_coins, 0));
end;
$$;

revoke execute on function public.ride_pay(uuid, text) from public, anon;
grant execute on function public.ride_pay(uuid, text) to authenticated;

-- ---- Paid in cash: the passenger says so, the driver confirms ----------------
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
  update public.ride_requests set payment_status = 'cash_pending', paid_method = 'cash' where id = p_ride;
  return 'cash_pending';
end;
$$;

revoke execute on function public.ride_pay_cash(uuid) from public, anon;
grant execute on function public.ride_pay_cash(uuid) to authenticated;

-- The driver confirms the cash: from 'cash_pending', or straight from 'due'
-- (a passenger on an app without this screen pays the driver in hand).
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
     set payment_status = 'paid', paid_method = 'cash', paid_amount = public.ride_left_to_pay(r), paid_at = now()
   where id = p_ride;
  return 'paid';
end;
$$;

revoke execute on function public.ride_confirm_cash(uuid) from public, anon;
grant execute on function public.ride_confirm_cash(uuid) to authenticated;

-- ---- Telling the other side ----------------------------------------------------
-- Who is told what, on its own so it is tested on its own: a list of
-- {to: 'rider'|'partner', title, body, data}.
create or replace function public.ride_payment_messages(o public.ride_requests, n public.ride_requests)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  out jsonb := '[]'::jsonb;
  amount text;
  extra numeric := coalesce(n.toll_charges, 0) + coalesce(n.other_charges, 0);
begin
  amount := 'RM' || to_char(public.ride_left_to_pay(n), 'FM999999990.00');
  if n.status = 'completed' and o.status is distinct from 'completed' and n.payment_status = 'due' then
    out := out || jsonb_build_array(jsonb_build_object(
      'to', 'rider',
      'title', 'Trip complete',
      'body', case when extra > 0
                then 'Your driver added tolls or other charges. Total to pay: ' || amount || '.'
                else 'Total to pay: ' || amount || '.' end,
      'data', jsonb_build_object('type', 'ride_payment', 'request_id', n.id, 'role', 'rider')));
  end if;
  if n.payment_status = 'cash_pending' and o.payment_status is distinct from 'cash_pending' then
    out := out || jsonb_build_array(jsonb_build_object(
      'to', 'partner',
      'title', 'Paid in cash',
      'body', 'Your passenger says they paid ' || amount || ' in cash. Confirm you received it.',
      'data', jsonb_build_object('type', 'ride_payment', 'request_id', n.id, 'role', 'partner')));
  end if;
  if n.payment_status = 'paid' and o.payment_status is distinct from 'paid' then
    if n.paid_method = 'cash' then
      out := out || jsonb_build_array(jsonb_build_object(
        'to', 'rider',
        'title', 'Payment confirmed',
        'body', 'Your driver confirmed your cash payment. Thanks for riding!',
        'data', jsonb_build_object('type', 'ride_payment', 'request_id', n.id, 'role', 'rider')));
    else
      out := out || jsonb_build_array(jsonb_build_object(
        'to', 'partner',
        'title', 'Payment received',
        'body', 'Your passenger paid RM' || to_char(coalesce(n.paid_amount, 0), 'FM999999990.00')
                || case when n.paid_method = 'get_coin' then ' with GET.coin.' else ' with GET.wallet.' end,
        'data', jsonb_build_object('type', 'ride_payment', 'request_id', n.id, 'role', 'partner')));
    end if;
  end if;
  return out;
end;
$$;

revoke execute on function public.ride_payment_messages(public.ride_requests, public.ride_requests) from public, anon, authenticated;

create or replace function public.notify_ride_payment_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb;
  v_to uuid;
begin
  for m in select value from jsonb_array_elements(public.ride_payment_messages(old, new)) loop
    v_to := case m->>'to' when 'rider' then new.rider_id else new.partner_id end;
    if v_to is not null then
      perform public.send_push_webhook((m - 'to') || jsonb_build_object('profileId', v_to));
    end if;
  end loop;
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_payment_push() from public, anon, authenticated;

create or replace trigger trg_ride_requests_payment_push
  after update of status, payment_status on public.ride_requests
  for each row execute function public.notify_ride_payment_push();

notify pgrst, 'reload schema';
