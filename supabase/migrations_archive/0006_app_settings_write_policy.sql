-- ============================================================================
-- 0006_app_settings_write_policy.sql
-- ----------------------------------------------------------------------------
-- Allow authenticated clients to upsert into `app_settings` (so the admin app,
-- which uses the anon key + a signed-in admin session, can persist things like
-- the API keys row at key='api_providers').
--
-- Read policy already exists in schema.sql ("app_settings read" — using (true)).
-- This migration adds insert / update / delete policies for any authenticated
-- role. If you later add an `admins` table, tighten the policies to check
-- membership in it (see commented example at the bottom).
-- ============================================================================

alter table public.app_settings enable row level security;

-- INSERT --------------------------------------------------------------------
drop policy if exists "app_settings auth insert" on public.app_settings;
create policy "app_settings auth insert"
  on public.app_settings for insert
  to authenticated
  with check (true);

-- UPDATE --------------------------------------------------------------------
drop policy if exists "app_settings auth update" on public.app_settings;
create policy "app_settings auth update"
  on public.app_settings for update
  to authenticated
  using (true)
  with check (true);

-- DELETE --------------------------------------------------------------------
drop policy if exists "app_settings auth delete" on public.app_settings;
create policy "app_settings auth delete"
  on public.app_settings for delete
  to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- Optional: tighten to admins only.
-- If/when you add an `admins` table:
--
--   create table public.admins (
--     user_id uuid primary key references auth.users(id) on delete cascade
--   );
--
-- Replace the policies above with:
--
--   create policy "app_settings admin write"
--     on public.app_settings for all
--     to authenticated
--     using     (exists (select 1 from public.admins a where a.user_id = auth.uid()))
--     with check(exists (select 1 from public.admins a where a.user_id = auth.uid()));
-- ---------------------------------------------------------------------------
