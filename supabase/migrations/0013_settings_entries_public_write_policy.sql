-- Allow the app (anon + authenticated) to write to settings_entries.
--
-- Why this is needed:
--   schema.sql enables RLS on public.settings_entries and only creates a
--   SELECT policy. With RLS enabled and no INSERT/UPDATE/DELETE policy,
--   every write the admin app issues via the Supabase JS client is
--   silently rejected — reads work, writes look successful client-side
--   but never land in Postgres, and the table stays out of sync with
--   the app.
--
--   Admin screens are gated at the app level (hardcoded admin login +
--   AdminAccessContext), so opening writes to the `public` role here
--   matches the same pattern used by:
--     - 0008_app_settings_public_write_policy.sql  (app_settings)
--     - 0010_admin_access_public_write_policy.sql  (admin_access)
--
-- Safe to re-run.

drop policy if exists "settings_entries insert" on public.settings_entries;
drop policy if exists "settings_entries update" on public.settings_entries;
drop policy if exists "settings_entries delete" on public.settings_entries;

create policy "settings_entries insert"
  on public.settings_entries for insert
  to public
  with check (true);

create policy "settings_entries update"
  on public.settings_entries for update
  to public
  using (true)
  with check (true);

create policy "settings_entries delete"
  on public.settings_entries for delete
  to public
  using (true);

grant select, insert, update, delete on public.settings_entries to anon, authenticated;
