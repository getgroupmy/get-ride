-- ============================================================================
-- 0222 — Coin transfers are no phone-number lookup; commission is your own
--
-- 1. Sending GET.coin by phone number found the account behind any number,
--    without limit and before the sender's balance was checked, and answered
--    with the account's id. Now, in wallet_transfer_coins and
--    wallet_request_coin_transfer:
--      * the sender's balance is checked first (an empty wallet learns
--        nothing);
--      * a number is looked up at most 20 times in 10 minutes per sender
--        (auth_rate_take 'phone_resolve'; over it, 'RATE_LIMITED:<seconds>');
--      * a recipient is a person: a profile, or a partner's own account
--        (partners.auth_user_id), never a partner record's id;
--      * the answer carries the masked name, not the recipient's id.
--
-- 2. commission_resolve() / commission_resolve_rate() told any signed-in
--    caller another driver's own commission rate; commission_credit_ok()
--    their credit standing. The first two are now the server's alone (every
--    caller is a server function); the apps ask commission_credit_ok_self()
--    for their own standing, which is what the ride guard needs since 0221
--    (a driver only ever takes a ride for themselves).
-- ============================================================================

-- ---- 1. Coin transfers -----------------------------------------------------------------------
-- The person [p_to] / [p_to_phone] names, and their name; raises
-- recipient_not_found, self_transfer or RATE_LIMITED.
create or replace function public.wallet_resolve_recipient(p_from uuid, p_to uuid, p_to_phone text)
returns table (id uuid, name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to     uuid;
  v_name   text;
  v_digits text;
  v_wait   integer;
begin
  if p_to is not null then
    select pr.id, coalesce(pr.name, '') into v_to, v_name from public.profiles pr where pr.id = p_to;
    if v_to is null then
      select pa.auth_user_id, coalesce(pa.name, '') into v_to, v_name
        from public.partners pa where pa.auth_user_id = p_to limit 1;
    end if;
  else
    v_wait := public.auth_rate_take('phone_resolve', p_from::text, 20, interval '10 minutes');
    if v_wait > 0 then
      raise exception 'RATE_LIMITED:%', v_wait;
    end if;
    -- Digits only, so "+60 12-345 6789" and "0123456789" line up; the last
    -- 9 digits bridge country-code prefixes.
    v_digits := regexp_replace(coalesce(p_to_phone, ''), '\D', '', 'g');
    if length(v_digits) >= 7 then
      select pr.id, coalesce(pr.name, '') into v_to, v_name
        from public.profiles pr
       where regexp_replace(coalesce(pr.phone, ''), '\D', '', 'g') = v_digits
          or (length(v_digits) >= 9
              and right(regexp_replace(coalesce(pr.phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
       order by pr.created_at
       limit 1;
      if v_to is null then
        select pa.auth_user_id, coalesce(pa.name, '') into v_to, v_name
          from public.partners pa
         where pa.auth_user_id is not null
           and (regexp_replace(coalesce(pa.phone, ''), '\D', '', 'g') = v_digits
                or (length(v_digits) >= 9
                    and right(regexp_replace(coalesce(pa.phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9)))
         order by pa.created_at
         limit 1;
      end if;
    end if;
  end if;
  if v_to is null then
    raise exception 'recipient_not_found';
  end if;
  if v_to = p_from then
    raise exception 'self_transfer';
  end if;
  return query select v_to, v_name;
end;
$$;
revoke execute on function public.wallet_resolve_recipient(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.wallet_request_coin_transfer(
  p_from uuid, p_coins numeric, p_to uuid default null, p_to_phone text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid;
  v_to_name   text;
  v_from_name text;
  v_balance   numeric;
  v_request   public.wallet_transfer_requests;
begin
  perform public.wallet_assert_caller(p_from);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  -- Soft balance check, before anybody is looked up: an unfunded request
  -- learns nothing about the number. The authoritative check re-runs at
  -- acceptance time.
  select balance into v_balance
    from public.wallets
   where user_id = p_from and wallet_type = 'get_coin';
  if v_balance is null or v_balance < v_coins then
    raise exception 'insufficient_coins';
  end if;

  select r.id, r.name into v_to, v_to_name from public.wallet_resolve_recipient(p_from, p_to, p_to_phone) r;

  -- 0090: the sender only ever sees a masked name ("Ahmad A.").
  v_to_name := coalesce(public.wallet_mask_name(v_to_name), '');

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  insert into public.wallet_transfer_requests
    (from_user_id, from_name, to_user_id, to_name, coins, note)
  values
    (p_from, nullif(v_from_name, ''), v_to, nullif(v_to_name, ''), v_coins,
     nullif(trim(coalesce(p_note, '')), ''))
  returning * into v_request;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'recipient_name', nullif(v_to_name, ''),
    'coins',          v_coins,
    'expires_at',     v_request.expires_at
  );
end;
$$;

create or replace function public.wallet_transfer_coins(
  p_from uuid, p_coins numeric, p_to uuid default null, p_to_phone text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid;
  v_to_name   text;
  v_from_name text;
  v_balance   numeric;
  v_after     numeric;
  v_suffix    text := coalesce(' — ' || nullif(trim(p_note), ''), '');
begin
  perform public.wallet_assert_caller(p_from);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  -- Lock the sender's coin wallet so concurrent transfers serialise, and
  -- check it before anybody is looked up.
  insert into public.wallets (user_id, wallet_type, balance)
  values (p_from, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance
    from public.wallets
   where user_id = p_from and wallet_type = 'get_coin'
     for update;
  if v_balance is null or v_balance < v_coins then
    raise exception 'insufficient_coins';
  end if;

  select r.id, r.name into v_to, v_to_name from public.wallet_resolve_recipient(p_from, p_to, p_to_phone) r;

  -- 0090: the sender only ever sees a masked name ("Ahmad A.").
  v_to_name := coalesce(public.wallet_mask_name(v_to_name), '');

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves both balances.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values
    (p_from, 'get_coin', 'transfer_out', -v_coins, 'p2p_transfer',
     'Sent to ' || coalesce(nullif(v_to_name, ''), 'user') || v_suffix),
    (v_to, 'get_coin', 'transfer_in', v_coins, 'p2p_transfer',
     'Received from ' || coalesce(nullif(v_from_name, ''), 'user') || v_suffix);

  select balance into v_after
    from public.wallets
   where user_id = p_from and wallet_type = 'get_coin';

  return jsonb_build_object(
    'coins',          v_coins,
    'recipient_name', nullif(v_to_name, ''),
    'balance_after',  v_after
  );
end;
$$;

-- ---- 2. Commission: your own ------------------------------------------------------------------
revoke execute on function public.commission_resolve(uuid, double precision, double precision, text, text, text, text)
  from authenticated;
revoke execute on function public.commission_resolve_rate(uuid, text, text, text, text) from authenticated;

create or replace function public.commission_credit_ok_self()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.commission_credit_ok(auth.uid());
$$;
revoke execute on function public.commission_credit_ok_self() from public, anon;
grant execute on function public.commission_credit_ok_self() to authenticated;

-- As in 0218; the caller is the driver (0221), so their own standing.
create or replace function public.ride_requests_guard_credit()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.partner_id is null
     or (tg_op = 'UPDATE' and new.partner_id is not distinct from old.partner_id)
     or current_user not in ('anon', 'authenticated')
     or public.caller_is_admin() then
    return new;
  end if;
  if auth.uid() is distinct from new.partner_id then
    -- 0221 lets only the driver themselves take a ride.
    raise exception 'DRIVER_UNAVAILABLE' using errcode = 'P0001',
      hint = 'This driver can''t take trips right now. Please book another driver.';
  end if;
  if not public.commission_credit_ok_self() then
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = case when public.commission_credit_floor() = 0
                  then 'Your GET.credit is below zero. Top up to take trips again.'
                  else 'Your GET.credit is below RM ' || to_char(public.commission_credit_floor(), 'FM999990.00')
                       || '. Top up to take trips again.' end;
  end if;
  return new;
end;
$$;

revoke execute on function public.commission_credit_ok(uuid) from authenticated;
