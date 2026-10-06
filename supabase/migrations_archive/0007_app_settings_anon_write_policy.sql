-- ============================================================================
-- 0007_app_settings_anon_write_policy.sql
-- ----------------------------------------------------------------------------
-- The admin app authenticates via a local PIN / hardcoded credentials and does
-- NOT call `supabase.auth.signInWithPassword`, so the Supabase client stays on
-- the `anon` role. Migration 0006 only granted insert/update/delete to
-- `authenticated`, which is why writes still fail with:
--   "new row violates row-level security policy for table \"app_settings\""
--
-- This migration extends the same policies to the `anon` role so the admin app
-- can persist `api_providers` (and any other app_settings rows) with the anon
-- key. Reads were already open to anon (see schema.sql "app_settings read").
--
-- Security note: anyone with the anon key can now write app_settings. Since
-- the anon key is already shipped in the app bundle and reads are public,
-- this matches the existing trust model. To tighten later, switch the admin
-- login to a real Supabase auth session and revert these `anon` grants.
-- ============================================================================

alter table public.app_settings enable row level security;

-- INSERT --------------------------------------------------------------------
drop policy if exists "app_settings anon insert" on public.app_settings;
create policy "app_settings anon insert"
  on public.app_settings for insert
  to anon
  with check (true);

-- UPDATE --------------------------------------------------------------------
drop policy if exists "app_settings anon update" on public.app_settings;
create policy "app_settings anon update"
  on public.app_settings for update
  to anon
  using (true)
  with check (true);

-- DELETE --------------------------------------------------------------------
drop policy if exists "app_settings anon delete" on public.app_settings;
create policy "app_settings anon delete"
  on public.app_settings for delete
  to anon
  using (true);
