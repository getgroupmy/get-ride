-- ============================================================================
-- 0023_admin_display_settings.sql
-- Global admin Display Settings.
--
-- Singleton table public.admin_display_settings (id = 'global') stores the
-- full display-settings JSON. Every device pulls it on app start and applies
-- it locally so admin changes take effect for all users on next launch.
--
-- Safe to re-run.
-- ============================================================================

create table if not exists public.admin_display_settings (
  id          text primary key default 'global',
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

insert into public.admin_display_settings (id, settings)
values ('global', '{}'::jsonb)
on conflict (id) do nothing;

alter table public.admin_display_settings enable row level security;

drop policy if exists "admin_display_settings read"   on public.admin_display_settings;
drop policy if exists "admin_display_settings insert" on public.admin_display_settings;
drop policy if exists "admin_display_settings update" on public.admin_display_settings;
drop policy if exists "admin_display_settings delete" on public.admin_display_settings;

create policy "admin_display_settings read"
  on public.admin_display_settings for select
  using (true);

create policy "admin_display_settings insert"
  on public.admin_display_settings for insert
  to public
  with check (true);

create policy "admin_display_settings update"
  on public.admin_display_settings for update
  to public
  using (true)
  with check (true);

create policy "admin_display_settings delete"
  on public.admin_display_settings for delete
  to public
  using (true);

grant select, insert, update, delete
  on public.admin_display_settings
  to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.admin_display_settings;
exception when duplicate_object then null;
end$$;
