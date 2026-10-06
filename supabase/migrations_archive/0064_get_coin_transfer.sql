-- ============================================================================
-- 0064: GET.coin P2P transfers — coins are tradable between accounts
-- ----------------------------------------------------------------------------
-- Any account (user or partner) can send GC straight to another account.
-- Transfers move existing coins 1:1 — nothing is minted or burned — through
-- the atomic `wallet_transfer_coins` RPC:
--   sender    : get_coin 'transfer_out' (-GC, method p2p_transfer)
--   recipient : get_coin 'transfer_in'  (+GC, method p2p_transfer)
-- The 0060 ledger trigger moves both balances; the sender's wallet row is
-- locked first so a concurrent transfer can't overdraw it (the >= 0 wallet
-- constraint backstops this).
--
-- Recipients are addressed by account id (scanned getpay:// QR) or by phone
-- number, resolved server-side — profiles are RLS-protected, so the client
-- cannot look other users up itself.
--
-- get_coin_market_stats is also updated: p2p transfers are excluded from the
-- "minted" market signal, since they only move coins already in circulation.
-- ============================================================================

create or replace function public.wallet_transfer_coins(
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid    := p_to;
  v_to_name   text;
  v_from_name text;
  v_digits    text;
  v_balance   numeric;
  v_after     numeric;
  v_suffix    text := coalesce(' — ' || nullif(trim(p_note), ''), '');
begin
  if p_from is null then
    raise exception 'invalid_user';
  end if;
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  if v_to is not null then
    select coalesce(name, '') into v_to_name from public.profiles where id = v_to;
    if not found then
      select coalesce(name, '') into v_to_name from public.partners where id = v_to;
      if not found then
        raise exception 'recipient_not_found';
      end if;
    end if;
  else
    -- Resolve by phone: compare digits only, so "+60 12-345 6789" and
    -- "0123456789" line up; fall back to matching the last 9 digits to
    -- bridge country-code prefixes.
    v_digits := regexp_replace(coalesce(p_to_phone, ''), '\D', '', 'g');
    if length(v_digits) < 7 then
      raise exception 'recipient_not_found';
    end if;

    select id, coalesce(name, '') into v_to, v_to_name
    from public.profiles
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
       or (length(v_digits) >= 9
           and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
    order by created_at
    limit 1;

    if v_to is null then
      select id, coalesce(name, '') into v_to, v_to_name
      from public.partners
      where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
         or (length(v_digits) >= 9
             and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
      order by created_at
      limit 1;
    end if;

    if v_to is null then
      raise exception 'recipient_not_found';
    end if;
  end if;

  if v_to = p_from then
    raise exception 'self_transfer';
  end if;

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  -- Lock the sender's coin wallet so concurrent transfers serialise.
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
    'recipient_id',   v_to,
    'recipient_name', nullif(v_to_name, ''),
    'balance_after',  v_after
  );
end;
$$;

grant execute on function public.wallet_transfer_coins(uuid, numeric, uuid, text, text)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Market stats: exclude p2p transfers from the "minted" signal — a transfer
-- moves coins that already exist, so it must not push the market price down.
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

  -- New coins generated (rewards, admin grants, purchases) (30d) —
  -- p2p transfers move existing coins, so they don't count as minting.
  select coalesce(sum(amount), 0) into v_minted
  from public.wallet_transactions
  where wallet_type = 'get_coin' and amount > 0
    and coalesce(method, '') <> 'p2p_transfer'
    and created_at >= v_since;

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
