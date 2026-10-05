-- ============================================================================
-- 0022_app_branding.sql
-- Global app branding: splash screen image/background + app icon.
--
-- Storage:
--   public bucket `app-branding` (public read, anon write) holds the uploaded
--   splash image and app icon files.
--
-- Table:
--   public.app_branding (singleton, id = 'global') stores the current image
--   URLs and metadata so every user device can fetch and apply the latest
--   branding globally.
--
-- Safe to re-run.
-- ============================================================================

-- ---- Storage bucket -------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('app-branding', 'app-branding', true)
on conflict (id) do update set public = excluded.public;

-- Permissive storage policies so the anon client used inside the app can
-- upload and replace branding assets, mirroring the project's other buckets.
drop policy if exists "app-branding read"   on storage.objects;
drop policy if exists "app-branding insert" on storage.objects;
drop policy if exists "app-branding update" on storage.objects;
drop policy if exists "app-branding delete" on storage.objects;

create policy "app-branding read"
  on storage.objects for select
  using (bucket_id = 'app-branding');

create policy "app-branding insert"
  on storage.objects for insert
  to public
  with check (bucket_id = 'app-branding');

create policy "app-branding update"
  on storage.objects for update
  to public
  using (bucket_id = 'app-branding')
  with check (bucket_id = 'app-branding');

create policy "app-branding delete"
  on storage.objects for delete
  to public
  using (bucket_id = 'app-branding');

-- ---- app_branding table ---------------------------------------------------
create table if not exists public.app_branding (
  id                text primary key default 'global',
  splash_image_url  text,
  splash_bg_color   text not null default '#ff007f',
  app_icon_url      text,
  icon_changed_at   timestamptz,
  updated_at        timestamptz not null default now()
);

insert into public.app_branding (id, splash_bg_color)
values ('global', '#ff007f')
on conflict (id) do nothing;

alter table public.app_branding enable row level security;

drop policy if exists "app_branding read"   on public.app_branding;
drop policy if exists "app_branding insert" on public.app_branding;
drop policy if exists "app_branding update" on public.app_branding;
drop policy if exists "app_branding delete" on public.app_branding;

create policy "app_branding read"
  on public.app_branding for select
  using (true);

create policy "app_branding insert"
  on public.app_branding for insert
  to public
  with check (true);

create policy "app_branding update"
  on public.app_branding for update
  to public
  using (true)
  with check (true);

create policy "app_branding delete"
  on public.app_branding for delete
  to public
  using (true);

grant select, insert, update, delete
  on public.app_branding
  to anon, authenticated;

-- ---- Realtime -------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.app_branding;
exception when duplicate_object then null;
end$$;
