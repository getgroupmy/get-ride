-- 0096: GET.wallet top-up is admin-only until a real payment gateway exists.
--
-- wallet_topup credited GET.wallet with any amount up to RM100,000 for the
-- owner of the wallet, and nothing upstream takes a payment: the Expo reload
-- popup lets the user pick an amount and a "method" (a label from the payment
-- gateway settings) and calls this function directly. Any signed-in account
-- could therefore mint wallet money and spend it through QR payments, coin
-- buys and transfers.
--
-- Until a gateway verifies the payment server-side (an edge function crediting
-- with the service role), only admins, the service role and direct database
-- sessions may credit a wallet. Everyone else gets `topup_requires_payment`,
-- which the Expo client explains instead of reporting a generic failure.

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
  if not public.caller_is_admin() then
    raise exception 'topup_requires_payment';
  end if;
  if p_user is null then
    raise exception 'invalid_user';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception 'invalid_amount';
  end if;

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves the balance.
  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, method, note)
  values
    (p_user, 'get_wallet', 'topup', p_amount, p_method, 'Top up GET.wallet');

  select * into w from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet';
  return w;
end;
$$;

revoke execute on function public.wallet_topup(uuid, numeric, text) from public, anon;
grant execute on function public.wallet_topup(uuid, numeric, text) to authenticated, service_role;
