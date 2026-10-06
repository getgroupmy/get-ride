-- ============================================================================
-- 0056: Wallets — GET.wallet (master) + GET.credit (partner credit)
-- ----------------------------------------------------------------------------
-- GET.wallet  : master wallet, used by the account in both user & partner mode.
-- GET.credit  : partner-only wallet used to pay for in-app services and
--               commissions. Recharged (transferred) from GET.wallet.
-- ============================================================================

create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_type text not null check (wallet_type in ('get_wallet','get_credit')),
  balance numeric(12,2) not null default 0 check (balance >= 0),
  currency text not null default 'RM',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, wallet_type)
);

create index if not exists wallets_user_idx on public.wallets(user_id);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_type text not null check (wallet_type in ('get_wallet','get_credit')),
  -- 'topup' | 'recharge_out' | 'recharge_in' | 'payment' | 'commission' | 'refund' | 'adjustment'
  kind text not null,
  -- Signed amount: positive = money into the wallet, negative = money out.
  amount numeric(12,2) not null,
  balance_after numeric(12,2),
  method text,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists wallet_tx_user_idx
  on public.wallet_transactions(user_id, created_at desc);

do $$
begin
  drop trigger if exists trg_wallets_updated_at on public.wallets;
  create trigger trg_wallets_updated_at before update on public.wallets
    for each row execute function public.set_updated_at();
end$$;

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;

drop policy if exists "wallets read"   on public.wallets;
drop policy if exists "wallets insert" on public.wallets;
drop policy if exists "wallets update" on public.wallets;

create policy "wallets read"   on public.wallets for select using (true);
create policy "wallets insert" on public.wallets for insert to public with check (true);
create policy "wallets update" on public.wallets for update to public using (true) with check (true);

drop policy if exists "wallet_transactions read"   on public.wallet_transactions;
drop policy if exists "wallet_transactions insert" on public.wallet_transactions;

create policy "wallet_transactions read"   on public.wallet_transactions for select using (true);
create policy "wallet_transactions insert" on public.wallet_transactions for insert to public with check (true);

grant select, insert, update on public.wallets to anon, authenticated;
grant select, insert on public.wallet_transactions to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Atomic top-up into GET.wallet (also creates the wallet row when missing)
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

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;

  update public.wallets
     set balance = balance + p_amount, updated_at = now()
   where user_id = p_user and wallet_type = 'get_wallet'
  returning * into w;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, balance_after, method, note)
  values
    (p_user, 'get_wallet', 'topup', p_amount, w.balance, p_method, 'Top up GET.wallet');

  return w;
end;
$$;

-- ----------------------------------------------------------------------------
-- Atomic recharge: move funds GET.wallet -> GET.credit (partner credit)
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

  select * into w_master
    from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet'
   for update;

  if w_master.balance < p_amount then
    raise exception 'insufficient_balance';
  end if;

  update public.wallets
     set balance = balance - p_amount, updated_at = now()
   where id = w_master.id
  returning * into w_master;

  update public.wallets
     set balance = balance + p_amount, updated_at = now()
   where user_id = p_user and wallet_type = 'get_credit'
  returning * into w_credit;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, balance_after, note)
  values
    (p_user, 'get_wallet', 'recharge_out', -p_amount, w_master.balance, 'Recharge GET.credit'),
    (p_user, 'get_credit', 'recharge_in',   p_amount, w_credit.balance, 'Recharged from GET.wallet');

  return next w_master;
  return next w_credit;
end;
$$;

grant execute on function public.wallet_topup(uuid, numeric, text) to anon, authenticated;
grant execute on function public.wallet_recharge_credit(uuid, numeric) to anon, authenticated;
