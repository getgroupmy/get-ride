-- Re-apply public write policies on settings_entries.
--
-- Why: the live database is currently rejecting all writes to
-- public.settings_entries (INSERT fails with a 42501 RLS violation, UPDATE
-- silently affects 0 rows). This means admin edits — including partner-type
-- custom icons (iconUrl) and the "Vehicle required" toggle — never persist,
-- even though the app's local cache makes them look saved.
--
-- Migration 0013 originally created these policies; either it was never
-- applied to this project or a schema reset dropped them. This migration is
-- idempotent and safe to re-run.

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
