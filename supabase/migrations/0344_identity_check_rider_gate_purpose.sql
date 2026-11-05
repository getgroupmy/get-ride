-- Allow 'rider_gate' as an identity_checks purpose (migrations 0342 / 0343).
-- ============================================================================
-- The rider ID-verification flow records its check with purpose 'rider_gate'
-- (inserted by the rider-verify path of the face-compare edge function, and
-- read by rider_id_gate_apply). The original purpose CHECK (0281) only allowed
-- 'first' / 'recheck' / 'profile', so the insert would have been rejected.
-- Extend the constraint to include it. The status CHECK — status is null iff
-- purpose = 'profile' — already treats 'rider_gate' like the others (a
-- 'rider_gate' row carries a status), so it needs no change.
-- ============================================================================

alter table public.identity_checks drop constraint if exists identity_checks_purpose_check;
alter table public.identity_checks add constraint identity_checks_purpose_check
  check (purpose in ('first', 'recheck', 'profile', 'rider_gate'));

notify pgrst, 'reload schema';
