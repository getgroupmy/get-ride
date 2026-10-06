-- ============================================================================
-- 0024_admin_display_settings_global_sync.sql
-- Force-assert the global Display Settings sync so admin changes (including
-- "Coming Soon" toggles) reach EVERY device, not just the admin's own.
--
-- This re-runs the table/RLS/grants from 0023 (safe, idempotent) and ADDS the
-- two things needed for reliable cross-device delivery:
--   1. The table is in the `supabase_realtime` publication (live push).
--   2. REPLICA IDENTITY FULL so realtime UPDATE payloads always carry the
--      full `settings` JSON to every subscribed client.
--
-- Safe to re-run.
-- ============================================================================

create table if not exists public.admin_display_settings (
  id          text primary key default 'global',
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- Ensure the singleton row exists.
insert into public.admin_display_settings (id, settings)
values ('global', '{}'::jsonb)
on conflict (id) do nothing;

-- Row level security: everyone can read the global config, everyone can write
-- it (admin gating happens in the app UI). This is what makes the settings
-- truly global instead of per-device.
alter table public.admin_display_settings enable row level security;

drop policy if exists "admin_display_settings read"   on public.admin_display_settings;
drop policy if exists "admin_display_settings insert" on public.admin_display_settings;
drop policy if exists "admin_display_settings update" on public.admin_display_settings;
drop policy if exists "admin_display_settings delete" on public.admin_display_settings;

create policy "admin_display_settings read"
  on public.admin_display_settings for select
  to anon, authenticated
  using (true);

create policy "admin_display_settings insert"
  on public.admin_display_settings for insert
  to anon, authenticated
  with check (true);

create policy "admin_display_settings update"
  on public.admin_display_settings for update
  to anon, authenticated
  using (true)
  with check (true);

create policy "admin_display_settings delete"
  on public.admin_display_settings for delete
  to anon, authenticated
  using (true);

grant select, insert, update, delete
  on public.admin_display_settings
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime delivery to every device.
-- ---------------------------------------------------------------------------

-- Make sure realtime UPDATE events include the full new row (so subscribers
-- receive the complete `settings` JSON, not just changed keys).
alter table public.admin_display_settings replica identity full;

-- Add the table to the realtime publication if it isn't already. Wrapped so
-- re-running never errors when the table is already a member.
do $$
begin
  alter publication supabase_realtime add table public.admin_display_settings;
exception
  when duplicate_object then null;
  when undefined_object then
    -- Publication doesn't exist yet (fresh project) — create it with the table.
    create publication supabase_realtime for table public.admin_display_settings;
end$$;
