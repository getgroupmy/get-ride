-- ============================================================================
-- 0061: GET.coin — third wallet, available to BOTH user and partner mode
-- ----------------------------------------------------------------------------
-- GET.coin balances are denominated in "GC" (Get Coins), not currency.
-- The GC <-> currency exchange rate is set by the admin from
-- Admin -> Settings -> Get Coin and stored in `get_coin_settings`.
--
-- The ledger trigger from 0060 (`trg_wallet_tx_apply`) is wallet_type
-- agnostic, so GET.coin transactions automatically move the wallet balance.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Allow the new wallet type on both tables (constraint names are the
-- auto-generated ones from 0056).
-- ----------------------------------------------------------------------------
alter table public.wallets
  drop constraint if exists wallets_wallet_type_check;
alter table public.wallets
  add constraint wallets_wallet_type_check
  check (wallet_type in ('get_wallet','get_credit','get_coin'));

alter table public.wallet_transactions
  drop constraint if exists wallet_transactions_wallet_type_check;
alter table public.wallet_transactions
  add constraint wallet_transactions_wallet_type_check
  check (wallet_type in ('get_wallet','get_credit','get_coin'));

-- ----------------------------------------------------------------------------
-- Exchange rate settings (single master row)
--   coins_per_currency: how many GC equal 1 unit of currency (RM).
--   e.g. 10 => RM1 = 10 GC, so 1 GC = RM0.10.
-- ----------------------------------------------------------------------------
create table if not exists public.get_coin_settings (
  id text primary key default 'master',
  coins_per_currency numeric(12,4) not null default 1 check (coins_per_currency > 0),
  currency text not null default 'RM',
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into public.get_coin_settings (id, coins_per_currency)
values ('master', 1)
on conflict (id) do nothing;

do $$
begin
  drop trigger if exists trg_get_coin_settings_updated_at on public.get_coin_settings;
  create trigger trg_get_coin_settings_updated_at before update on public.get_coin_settings
    for each row execute function public.set_updated_at();
end$$;

alter table public.get_coin_settings enable row level security;

drop policy if exists "get_coin_settings read"   on public.get_coin_settings;
drop policy if exists "get_coin_settings insert" on public.get_coin_settings;
drop policy if exists "get_coin_settings update" on public.get_coin_settings;

create policy "get_coin_settings read"   on public.get_coin_settings for select using (true);
create policy "get_coin_settings insert" on public.get_coin_settings for insert to public with check (true);
create policy "get_coin_settings update" on public.get_coin_settings for update to public using (true) with check (true);

grant select, insert, update on public.get_coin_settings to anon, authenticated;
