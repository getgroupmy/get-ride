-- ============================================================================
-- 0059: Wallets realtime — live balance updates in the app
-- ----------------------------------------------------------------------------
-- Adds public.wallets and public.wallet_transactions to the supabase_realtime
-- publication so the Wallet screen can subscribe to postgres_changes and show
-- balances in realtime. REPLICA IDENTITY FULL ensures UPDATE payloads always
-- carry the full row (user_id filter needs it).
-- ============================================================================

alter table public.wallets replica identity full;
alter table public.wallet_transactions replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.wallets;
exception
  when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.wallet_transactions;
exception
  when duplicate_object then null;
end$$;
