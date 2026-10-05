-- ============================================================================
-- 0089 — wallet_transfer_requests: participants and admins only
-- ----------------------------------------------------------------------------
-- 0065 created `wallet_transfer_requests` with a `using (true)` select policy
-- and granted select to `anon`. 0069 scoped most tables but missed this one,
-- so any client, including a signed-out one holding the public anon key, could
-- list every P2P GET.coin transfer (sender/recipient ids and names, amounts,
-- notes). The table is in the `supabase_realtime` publication, so anyone could
-- also subscribe to all of them live.
--
-- Fix: a row is readable only by its sender, its recipient or an admin
-- (`caller_is_admin()`, from 0069), and `anon` loses its select grant.
--
-- Unaffected:
--   * Writes. They all go through the SECURITY DEFINER RPCs
--     (`wallet_request_coin_transfer`, `wallet_respond_coin_transfer`,
--     `wallet_cancel_transfer_request`), which run as their owner.
--   * Realtime. postgres_changes applies RLS per subscriber, so the
--     recipient's popup channel (`to_user_id=eq.<uid>`) and the sender's watch
--     on their own request (`id=eq.<id>`) keep working for the participants.
--   * The admin fraud scans (Expo `admin-trace-fraud`, Flutter security
--     screen), which read every row as admins.
-- ============================================================================

drop policy if exists "wallet_transfer_requests read" on public.wallet_transfer_requests;
create policy "wallet_transfer_requests read"
  on public.wallet_transfer_requests for select
  using (
    from_user_id = auth.uid()
    or to_user_id = auth.uid()
    or public.caller_is_admin()
  );

revoke select on public.wallet_transfer_requests from anon;
grant select on public.wallet_transfer_requests to authenticated;
