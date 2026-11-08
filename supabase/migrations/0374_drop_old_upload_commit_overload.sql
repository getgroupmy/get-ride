-- ============================================================================
-- 0374: drop the superseded approver_upload_commit(text, uuid) overload.
--
-- 0371 added approver_upload_commit(text, uuid, text, boolean) (two defaulted
-- params) for the pending-replacement flow, but left the original 2-arg
-- approver_upload_commit(text, uuid) in place. With both present, a 2-arg call
-- using untyped literals — as supabase/tests/approver_upload_0353.sql makes —
-- is ambiguous ("function public.approver_upload_commit(unknown, unknown) is
-- not unique"), which fails the migration-replay SQL tests.
--
-- Nothing calls the 2-arg version any more (the approver-upload edge function
-- is on v3 and passes four arguments), so it is dropped; the remaining 4-arg
-- function serves a 2-arg call through its defaults, unambiguously.
-- ============================================================================
drop function if exists public.approver_upload_commit(text, uuid);

notify pgrst, 'reload schema';
