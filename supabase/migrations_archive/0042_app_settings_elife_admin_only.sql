-- ============================================================================
-- 0042_app_settings_elife_admin_only.sql
-- ----------------------------------------------------------------------------
-- The Elife Transfer integration stores its connection config — including the
-- OAuth `clientSecret` — in public.app_settings under:
--
--     key = 'elife_api_connection'
--
-- (see expo/utils/elifeApiStore.ts -> ELIFE_REMOTE_KEY).
--
-- Today app_settings is wide open: migration 0008 created PERMISSIVE policies
-- on the `public` role that allow ANY anon/authenticated session to SELECT,
-- INSERT, UPDATE and DELETE every row. That means anyone with the anon key can
-- read or overwrite the Elife client secret. We need to lock that one key down
-- to admins only, WITHOUT breaking open access to all the other settings rows
-- (api_providers, supabase settings, etc.) that the app relies on.
--
-- HOW THIS WORKS
-- --------------
-- Postgres combines RLS policies as follows:
--   * PERMISSIVE policies are OR-combined (grant access).
--   * RESTRICTIVE policies are AND-combined (further constrain access).
-- A row is only visible/mutable if it passes (any permissive) AND (every
-- restrictive) policy.
--
-- So we add RESTRICTIVE policies whose condition is:
--
--     key <> 'elife_api_connection'  OR  public.is_admin(auth.uid())
--
-- For every other key this is TRUE (key <> ...), so the existing public
-- policies keep working unchanged. For the elife row it is TRUE only when the
-- caller is an admin (has a row in public.admin_access, via is_admin() from
-- 0009_admin_access.sql). Non-admins simply can't see or touch that row.
-- ============================================================================

alter table public.app_settings enable row level security;

-- ---------------------------------------------------------------------------
-- SELECT: only admins can read the elife row; all other rows stay readable.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only select" on public.app_settings;
create policy "app_settings elife admin only select"
  on public.app_settings
  as restrictive
  for select
  to public
  using (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- INSERT: only admins can create the elife row.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only insert" on public.app_settings;
create policy "app_settings elife admin only insert"
  on public.app_settings
  as restrictive
  for insert
  to public
  with check (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- UPDATE: only admins can modify the elife row (both the existing row it
-- targets, USING, and the new values it writes, WITH CHECK).
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only update" on public.app_settings;
create policy "app_settings elife admin only update"
  on public.app_settings
  as restrictive
  for update
  to public
  using (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  )
  with check (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- DELETE: only admins can delete the elife row.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only delete" on public.app_settings;
create policy "app_settings elife admin only delete"
  on public.app_settings
  as restrictive
  for delete
  to public
  using (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- Verification (run manually in the Supabase SQL editor after applying):
--
--   select polname, polpermissive, polcmd
--     from pg_policy
--    where polrelid = 'public.app_settings'::regclass
--    order by polname;
--
-- The 4 new policies should show polpermissive = false (restrictive).
--
-- As a NON-admin session (anon key), this should now return 0 rows:
--   select * from public.app_settings where key = 'elife_api_connection';
-- ...while other keys still read fine:
--   select * from public.app_settings where key = 'api_providers';
-- ============================================================================
