-- ============================================================================
-- 0008_app_settings_public_write_policy.sql
-- ----------------------------------------------------------------------------
-- Migrations 0006 (authenticated) and 0007 (anon) still resulted in:
--   "new row violates row-level security policy for table \"app_settings\""
--
-- Root cause is usually one of:
--   1. 0007 was not actually executed in the project (paste/run skipped)
--   2. A leftover/restrictive policy from an earlier run is still in effect
--   3. The PostgREST role used by the request is neither `anon` nor
--      `authenticated` (e.g. when called via a custom JWT)
--
-- This migration takes the belt-and-suspenders approach:
--   - Drops every previous insert/update/delete policy on app_settings
--   - Recreates them targeting the `public` role, which is granted to all
--     other roles (anon, authenticated, service_role) by default in Supabase.
--   - Also re-asserts table-level INSERT/UPDATE/DELETE grants to anon and
--     authenticated, in case GRANTs were revoked somewhere.
--
-- After running this, `upsert` from the admin app (using the anon key) will
-- succeed regardless of which role the JWT resolves to.
--
-- SECURITY: this leaves app_settings writeable by anyone with the anon key.
-- That matches the existing trust model (read is already public). Tighten
-- later by switching admin login to a real Supabase session + an `admins`
-- table check (example at the bottom of 0006).
-- ============================================================================

alter table public.app_settings enable row level security;

-- ---------------------------------------------------------------------------
-- Drop ALL previously-created write policies so we start clean.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings auth insert"   on public.app_settings;
drop policy if exists "app_settings auth update"   on public.app_settings;
drop policy if exists "app_settings auth delete"   on public.app_settings;
drop policy if exists "app_settings anon insert"   on public.app_settings;
drop policy if exists "app_settings anon update"   on public.app_settings;
drop policy if exists "app_settings anon delete"   on public.app_settings;
drop policy if exists "app_settings public insert" on public.app_settings;
drop policy if exists "app_settings public update" on public.app_settings;
drop policy if exists "app_settings public delete" on public.app_settings;
drop policy if exists "app_settings write"         on public.app_settings;
drop policy if exists "app_settings admin write"   on public.app_settings;

-- ---------------------------------------------------------------------------
-- Recreate as permissive policies on `public` (covers every role).
-- ---------------------------------------------------------------------------
create policy "app_settings public insert"
  on public.app_settings for insert
  to public
  with check (true);

create policy "app_settings public update"
  on public.app_settings for update
  to public
  using (true)
  with check (true);

create policy "app_settings public delete"
  on public.app_settings for delete
  to public
  using (true);

-- ---------------------------------------------------------------------------
-- Re-assert table grants. RLS policies are necessary but not sufficient —
-- the role also needs the underlying INSERT/UPDATE/DELETE privilege.
-- Supabase normally grants these by default, but explicit is safer.
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.app_settings to anon;
grant select, insert, update, delete on public.app_settings to authenticated;
grant select, insert, update, delete on public.app_settings to service_role;

-- ---------------------------------------------------------------------------
-- Verification (run manually in SQL editor after applying this migration):
--
--   select polname, polroles::regrole[], polcmd
--     from pg_policy
--    where polrelid = 'public.app_settings'::regclass;
--
-- You should see 4 rows:
--   app_settings read           {public}  r
--   app_settings public insert  {public}  a
--   app_settings public update  {public}  w
--   app_settings public delete  {public}  d
--
-- And test the actual write with the anon key:
--
--   insert into public.app_settings (key, value)
--     values ('rls_test', '"ok"'::jsonb)
--   on conflict (key) do update set value = excluded.value;
--
-- ============================================================================
