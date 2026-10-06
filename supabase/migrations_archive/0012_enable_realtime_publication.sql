-- Enable Supabase Realtime for the tables the admin app subscribes to.
--
-- Why this is needed:
--   Supabase Realtime only forwards Postgres `INSERT/UPDATE/DELETE` events
--   for tables that are members of the `supabase_realtime` publication.
--   Without this, `supabase.channel(...).on('postgres_changes', { table: 'settings_entries' }, ...)`
--   subscribes successfully but never receives any payloads — so screens
--   like admin-settings-partner-type.tsx do not update live.
--
-- We also set REPLICA IDENTITY FULL so DELETE events carry the old row
-- (otherwise the client receives an empty `old` and may discard the event).
--
-- Safe to re-run: each ALTER PUBLICATION is wrapped to ignore duplicates.

-- settings_entries (partner-type, vehicle-type, payment-type, etc.)
do $$
begin
  alter publication supabase_realtime add table public.settings_entries;
exception when duplicate_object then null;
end$$;
alter table public.settings_entries replica identity full;

-- partners (admin-partners-*.tsx live updates)
do $$
begin
  alter publication supabase_realtime add table public.partners;
exception when duplicate_object then null;
end$$;
alter table public.partners replica identity full;

-- admin_access (Grant access + admin-login button visibility)
do $$
begin
  alter publication supabase_realtime add table public.admin_access;
exception when duplicate_object then null;
end$$;
alter table public.admin_access replica identity full;

-- profiles (so user list screens stay live too)
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null;
end$$;
alter table public.profiles replica identity full;

-- app_settings (api keys, supabase settings)
do $$
begin
  alter publication supabase_realtime add table public.app_settings;
exception when duplicate_object then null;
end$$;
alter table public.app_settings replica identity full;
