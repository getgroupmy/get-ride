-- ============================================================================
-- 0099 — re-apply 0076 and 0097 for databases that never ran them
-- ----------------------------------------------------------------------------
-- The 0097 squashed baseline is recorded as applied on existing databases without being
-- run (baseline-migration-history.sh), so anything an existing database was
-- missing at that point would never reach it. On the live project that was:
--
--   * 0076: user_sessions.cellular_generation. Its history listed 0076, but
--     the column is not there (checked 2026-10-06).
--   * 0097: the revoke of client write grants on wallet_transfer_requests,
--     merged shortly before the squash and possibly not pushed yet.
--
-- Both statements are idempotent, so this is a no-op on a database built
-- from the 0097 baseline (which already contains them) and on one that has them already.
-- ============================================================================

alter table public.user_sessions
  add column if not exists cellular_generation text;

revoke insert, update, delete, truncate, references, trigger
  on public.wallet_transfer_requests from anon, authenticated;
