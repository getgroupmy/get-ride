-- ============================================================================
-- 0057: Ride commissions — auto-deduct from GET.credit per completed trip
-- ----------------------------------------------------------------------------
-- When a partner completes a trip, the platform commission (default 15% of the
-- final fare) is deducted from their GET.credit wallet. GET.credit may go
-- negative (commission owed); GET.wallet must stay non-negative. The charge is
-- recorded on the ride row so it can never be applied twice.
-- ============================================================================

-- Allow GET.credit to go negative; keep GET.wallet >= 0.
alter table public.wallets drop constraint if exists wallets_balance_check;
alter table public.wallets add constraint wallets_balance_check
  check (wallet_type = 'get_credit' or balance >= 0);

-- Commission bookkeeping on the ride itself (idempotency anchor).
alter table public.ride_requests
  add column if not exists commission_rate       numeric(6,4),
  add column if not exists commission_amount     numeric(12,2),
  add column if not exists commission_charged_at timestamptz;

-- ----------------------------------------------------------------------------
-- Atomic, idempotent commission charge for a completed ride.
-- Locks the ride row; if it was already charged, returns without deducting.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_charge_ride_commission(
  p_ride uuid,
  p_partner uuid,
  p_fare numeric,
  p_rate numeric default 0.15
)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  w public.wallets;
  v_amount numeric(12,2);
begin
  if p_partner is null then
    raise exception 'invalid_partner';
  end if;
  if p_fare is null or p_fare <= 0 then
    raise exception 'invalid_fare';
  end if;
  if p_rate is null or p_rate <= 0 or p_rate >= 1 then
    raise exception 'invalid_rate';
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

  v_amount := round(p_fare * p_rate, 2);

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_partner, 'get_credit', 0)
  on conflict (user_id, wallet_type) do nothing;

  update public.wallets
     set balance = balance - v_amount, updated_at = now()
   where user_id = p_partner and wallet_type = 'get_credit'
  returning * into w;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, balance_after, note)
  values
    (p_partner, 'get_credit', 'commission', -v_amount, w.balance,
     'Ride commission ' || round(p_rate * 100, 1) || '% of ' ||
     coalesce(r.currency, 'RM') || ' ' || round(p_fare, 2));

  update public.ride_requests
     set commission_rate = p_rate,
         commission_amount = v_amount,
         commission_charged_at = now()
   where id = p_ride;

  return w;
end;
$$;

grant execute on function public.wallet_charge_ride_commission(uuid, uuid, numeric, numeric)
  to anon, authenticated;
