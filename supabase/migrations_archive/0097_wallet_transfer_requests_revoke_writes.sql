-- ============================================================================
-- 0097 — wallet_transfer_requests: drop the leftover client write grants
-- ----------------------------------------------------------------------------
-- 00891 scoped reads to participants and admins and removed anon's SELECT,
-- but anon and authenticated still held Supabase's default INSERT, UPDATE,
-- DELETE, TRUNCATE, REFERENCES and TRIGGER on the table. No policy allows the
-- row writes, so RLS already refused them; TRUNCATE is not subject to RLS at
-- all, though the REST API has no way to issue it.
--
-- Neither app writes to this table directly: both only SELECT (fetch and
-- realtime). Every write goes through the SECURITY DEFINER RPCs
-- (`wallet_request_coin_transfer`, `wallet_respond_coin_transfer`,
-- `wallet_cancel_transfer_request`), which run as their owner and are
-- unaffected. authenticated keeps SELECT; service_role is untouched.
-- ============================================================================

revoke insert, update, delete, truncate, references, trigger
  on public.wallet_transfer_requests from anon, authenticated;
