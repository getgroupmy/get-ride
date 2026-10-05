-- ============================================================================
-- 0060: Wallet ledger sync — wallet_transactions drives wallets.balance
-- ----------------------------------------------------------------------------
-- Problem: rows written straight into wallet_transactions (admin tools, SQL
-- editor, integrations) did not move wallets.balance — only the RPCs did.
--
-- Fix: a trigger now applies every transaction's signed `amount` to the
-- matching wallets row (creating it when missing) and stamps `balance_after`
-- with the resulting balance. The wallets UPDATE fires the existing realtime
-- publication, so the app's balance figure updates live.
--
-- The wallet RPCs are rewritten to ONLY insert ledger rows — the trigger is
-- now the single writer of wallets.balance, so nothing double-counts.
-- UPDATE/DELETE on wallet_transactions re-adjust the balance too, keeping the
-- ledger authoritative even if a row is corrected or removed.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Trigger: apply ledger rows to wallets.balance
-- ----------------------------------------------------------------------------
create or replace function public.wallet_apply_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric(12,2);
begin
  if tg_op = 'INSERT' then
    insert into public.wallets (user_id, wallet_type, balance)
    values (new.user_id, new.wallet_type, 0)
    on conflict (user_id, wallet_type) do nothing;

    update public.wallets
       set balance = balance + new.amount, updated_at = now()
     where user_id = new.user_id and wallet_type = new.wallet_type
    returning balance into v_balance;

    new.balance_after := v_balance;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- Reverse the old amount from the old wallet, apply the new one.
    update public.wallets
       set balance = balance - old.amount, updated_at = now()
     where user_id = old.user_id and wallet_type = old.wallet_type;

    insert into public.wallets (user_id, wallet_type, balance)
    values (new.user_id, new.wallet_type, 0)
    on conflict (user_id, wallet_type) do nothing;

    update public.wallets
       set balance = balance + new.amount, updated_at = now()
     where user_id = new.user_id and wallet_type = new.wallet_type
    returning balance into v_balance;

    new.balance_after := v_balance;
    return new;
  end if;

  -- DELETE: reverse the amount.
  update public.wallets
     set balance = balance - old.amount, updated_at = now()
   where user_id = old.user_id and wallet_type = old.wallet_type;
  return old;
end;
$$;

drop trigger if exists trg_wallet_tx_apply on public.wallet_transactions;
create trigger trg_wallet_tx_apply
  before insert or update or delete on public.wallet_transactions
  for each row execute function public.wallet_apply_transaction();

-- ----------------------------------------------------------------------------
-- Backfill: reconcile wallets.balance with the ledger for wallets whose
-- balance drifted (e.g. transactions inserted directly before this trigger
-- existed). Only touches rows where the ledger sum disagrees with the stored
-- balance AND the wallet has ledger rows.
-- ----------------------------------------------------------------------------
update public.wallets w
   set balance = t.ledger_sum, updated_at = now()
  from (
    select user_id, wallet_type, coalesce(sum(amount), 0)::numeric(12,2) as ledger_sum
      from public.wallet_transactions
     group by user_id, wallet_type
  ) t
 where t.user_id = w.user_id
   and t.wallet_type = w.wallet_type
   and w.balance <> t.ledger_sum
   -- Never reconcile GET.wallet below zero (constraint would reject it).
   and (w.wallet_type = 'get_credit' or t.ledger_sum >= 0);

-- ----------------------------------------------------------------------------
-- wallet_topup: ledger-driven — inserts the transaction, trigger moves balance
-- ----------------------------------------------------------------------------
create or replace function public.wallet_topup(
  p_user uuid,
  p_amount numeric,
  p_method text default null
)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  w public.wallets;
begin
  if p_user is null then
    raise exception 'invalid_user';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception 'invalid_amount';
  end if;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, method, note)
  values
    (p_user, 'get_wallet', 'topup', p_amount, p_method, 'Top up GET.wallet');

  select * into w from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet';
  return w;
end;
$$;

-- ----------------------------------------------------------------------------
-- wallet_recharge_credit: ledger-driven transfer GET.wallet -> GET.credit
-- ----------------------------------------------------------------------------
create or replace function public.wallet_recharge_credit(
  p_user uuid,
  p_amount numeric
)
returns setof public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  w_master public.wallets;
  w_credit public.wallets;
begin
  if p_user is null then
    raise exception 'invalid_user';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_amount';
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0), (p_user, 'get_credit', 0)
  on conflict (user_id, wallet_type) do nothing;

  -- Lock the master row so concurrent recharges can't both pass the check.
  select * into w_master
    from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet'
   for update;

  if w_master.balance < p_amount then
    raise exception 'insufficient_balance';
  end if;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, note)
  values
    (p_user, 'get_wallet', 'recharge_out', -p_amount, 'Recharge GET.credit'),
    (p_user, 'get_credit', 'recharge_in',   p_amount, 'Recharged from GET.wallet');

  select * into w_master from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet';
  select * into w_credit from public.wallets
   where user_id = p_user and wallet_type = 'get_credit';

  return next w_master;
  return next w_credit;
end;
$$;

-- ----------------------------------------------------------------------------
-- wallet_charge_ride_commission: ledger-driven, still idempotent per ride
-- ----------------------------------------------------------------------------
create or replace function public.wallet_charge_ride_commission(
  p_ride uuid,
  p_partner uuid,
  p_fare numeric,
  p_rate numeric default null
)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  w public.wallets;
  v_rate numeric;
  v_amount numeric(12,2);
begin
  if p_partner is null then
    raise exception 'invalid_partner';
  end if;
  if p_fare is null or p_fare <= 0 then
    raise exception 'invalid_fare';
  end if;

  select * into r from public.ride_requests where id = p_ride for update;
  if not found then
    raise exception 'ride_not_found';
  end if;

  -- Already charged: idempotent no-op.
  if r.commission_charged_at is not null then
    select * into w from public.wallets
     where user_id = p_partner and wallet_type = 'get_credit';
    return w;
  end if;

  v_rate := p_rate;
  if v_rate is null then
    v_rate := public.commission_resolve_rate(p_partner, r.country, r.state, r.city, r.suburb);
  end if;
  if v_rate is null or v_rate <= 0 or v_rate >= 1 then
    raise exception 'invalid_rate';
  end if;

  v_amount := round(p_fare * v_rate, 2);

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, note)
  values
    (p_partner, 'get_credit', 'commission', -v_amount,
     'Ride commission ' || round(v_rate * 100, 1) || '% of ' ||
     coalesce(r.currency, 'RM') || ' ' || round(p_fare, 2));

  update public.ride_requests
     set commission_rate = v_rate,
         commission_amount = v_amount,
         commission_charged_at = now()
   where id = p_ride;

  select * into w from public.wallets
   where user_id = p_partner and wallet_type = 'get_credit';
  return w;
end;
$$;

grant execute on function public.wallet_topup(uuid, numeric, text) to anon, authenticated;
grant execute on function public.wallet_recharge_credit(uuid, numeric) to anon, authenticated;
grant execute on function public.wallet_charge_ride_commission(uuid, uuid, numeric, numeric)
  to anon, authenticated;
