-- ============================================================================
-- 0010_admin_access_public_write_policy.sql
-- ----------------------------------------------------------------------------
-- Fixes the bootstrap deadlock on admin_access:
--
-- The original RLS in 0009 only allows writes by a profile that already has
-- access_level='edit' on page='admin-settings-sub-admin' (or '*'). With an
-- empty table that's nobody, so the first "Grant access" insert from the app
-- always fails with:
--   new row violates row-level security policy for table "admin_access"
--
-- Also: the admin app authenticates via a hardcoded super-admin session
-- (local AsyncStorage flag), not a Supabase auth user — so auth.uid() is
-- typically null in these requests and admin_can_edit(null, ...) is false.
--
-- The admin section is gated at the application layer (admin-login + the
-- AdminAccessContext super-admin flag), so we let the public role manage
-- admin_access rows. This mirrors the same approach used for app_settings
-- in 0008_app_settings_public_write_policy.sql.
-- ============================================================================

-- Drop every previous write policy so leftovers from 0009 can't conflict.
drop policy if exists "admin_access self read"          on public.admin_access;
drop policy if exists "admin_access admin read"         on public.admin_access;
drop policy if exists "admin_access admin write insert" on public.admin_access;
drop policy if exists "admin_access admin write update" on public.admin_access;
drop policy if exists "admin_access admin write delete" on public.admin_access;

-- Recreate as permissive policies on the public role (covers anon,
-- authenticated, and service_role).
create policy "admin_access public read"
  on public.admin_access for select
  to public
  using (true);

create policy "admin_access public insert"
  on public.admin_access for insert
  to public
  with check (true);

create policy "admin_access public update"
  on public.admin_access for update
  to public
  using (true)
  with check (true);

create policy "admin_access public delete"
  on public.admin_access for delete
  to public
  using (true);

-- Re-assert table-level GRANTs. RLS policies are necessary but not sufficient;
-- the role also needs the underlying privilege on the table.
grant select, insert, update, delete on public.admin_access to anon;
grant select, insert, update, delete on public.admin_access to authenticated;
grant select, insert, update, delete on public.admin_access to service_role;

-- ---------------------------------------------------------------------------
-- Verify (run after applying):
--
--   select policyname, cmd, roles
--   from pg_policies
--   where schemaname = 'public' and tablename = 'admin_access';
--
-- You should see four rows (select/insert/update/delete) all on {public}.
-- ---------------------------------------------------------------------------
