-- ============================================================================
-- 0068: MCash schema groundwork (docs/get-wallet-mcash-flow.md)
-- ----------------------------------------------------------------------------
-- GET.wallet is planned to be re-based onto the MCash e-money platform: MCash
-- becomes the custodian and ledger of record, and the Supabase ledger a
-- read-side mirror written by the future `mcash-proxy` edge function. This
-- migration adds only the columns that flow needs — no behavior changes:
-- existing ledger rows keep working (status defaults to the previously
-- implicit 'success') and the app ignores the new columns until the proxy
-- ships.
-- ============================================================================

-- Profile <-> MCash identity. All nullable: a null mcash_wallet_id simply
-- means the account has not been provisioned on MCash yet.
alter table public.profiles
  add column if not exists mcash_wallet_id text,
  add column if not exists mcash_ekyc_status text,
  add column if not exists mcash_customer_status text;

alter table public.profiles
  drop constraint if exists profiles_mcash_ekyc_status_check;
alter table public.profiles
  add constraint profiles_mcash_ekyc_status_check
  check (mcash_ekyc_status in
    ('never_submit','pending_screening','pending_review','approved',
     'rejected','on_hold','next_screening_due'));

alter table public.profiles
  drop constraint if exists profiles_mcash_customer_status_check;
alter table public.profiles
  add constraint profiles_mcash_customer_status_check
  check (mcash_customer_status in
    ('active','inactive','partial_blocked','blacklisted','terminated'));

-- One MCash wallet per profile; MCash webhooks/reconciliation resolve the
-- profile by wallet id.
create unique index if not exists profiles_mcash_wallet_id_key
  on public.profiles(mcash_wallet_id) where mcash_wallet_id is not null;

-- Mirror-ledger columns: FPX reloads settle asynchronously, so mirrored rows
-- can sit at pending/processing until MCash acknowledges. Every pre-MCash row
-- is final — hence the 'success' default. mcash_ref carries MCash's
-- transaction reference for reconciliation.
--
-- Note: the 0060 balance trigger still applies every row to wallets.balance
-- regardless of status. That stays correct today because nothing writes
-- non-success rows yet; the mcash-proxy work reworks the trigger when
-- pending mirror rows start to exist.
alter table public.wallet_transactions
  add column if not exists status text not null default 'success',
  add column if not exists mcash_ref text;

alter table public.wallet_transactions
  drop constraint if exists wallet_transactions_status_check;
alter table public.wallet_transactions
  add constraint wallet_transactions_status_check
  check (status in ('success','failed','pending','processing','paused','cancelled'));

create index if not exists wallet_tx_mcash_ref_idx
  on public.wallet_transactions(mcash_ref) where mcash_ref is not null;
