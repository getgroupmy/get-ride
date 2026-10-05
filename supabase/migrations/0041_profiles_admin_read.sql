-- ============================================================================
-- 0041_profiles_admin_read.sql
-- ----------------------------------------------------------------------------
-- The admin "All Users" screen (admin-users-all.tsx) reads every row from
-- public.profiles regardless of status (column `profile_status` / `status`,
-- i.e. the user_status, with '*' = all statuses).
--
-- However the only SELECT policy on public.profiles is "profiles self read":
--
--     using (auth.uid() = id)
--
-- ...which restricts each session to reading ONLY its own row. As a result the
-- admin list comes back empty/partial no matter the approval status.
--
-- This migration adds an additional SELECT policy that lets any admin (any
-- profile with a row in public.admin_access, via the is_admin() helper from
-- 0009_admin_access.sql) read ALL profiles. RLS policies are OR-combined, so
-- the existing self-read policy continues to work for normal users.
-- ============================================================================

drop policy if exists "profiles admin read all" on public.profiles;
create policy "profiles admin read all"
  on public.profiles for select
  using (public.is_admin(auth.uid()));
