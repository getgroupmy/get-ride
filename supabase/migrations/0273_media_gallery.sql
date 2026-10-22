-- ============================================================================
-- 0273 — Media Gallery: the icons, images and logos an admin uploads under
-- Admin → Display Settings → Media Gallery, kept in a public bucket and
-- pointed at from settings as `media:<id>`.
--
-- Applied by hand as version 20261021033100 (0273_media_gallery in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", policies are dropped first.
--
-- 1. public.media_assets: one row per upload.
--      kind        icon / image / logo
--      name        what the admin called it
--      path        the file in the `media` bucket: <kind>/<id>.<ext>
--                  (a logo's light version; null for a logo with a dark
--                  version only). The id is in the path, so a search for
--                  the id also finds a setting that kept the file's address.
--      dark_path   a logo's dark version: <kind>/<id>-dark.<ext>
--      mime        image/png, image/jpeg, image/webp or image/svg+xml
--      width, height, bytes   of the main file
--      tint        "Follow the theme colour": a one-colour icon the app
--                  draws in the theme's icon colour
--      created_by  the admin who uploaded it (set by the server)
--    Everyone reads it, signed in or not (the app shows these pictures,
--    the sign-in screen included). Admins with EDIT on Display Settings
--    (caller_admin_can_write('media_assets')) add and rename; nobody
--    deletes a row directly.
-- 2. The public `media` bucket (5 MB, PNG / JPEG / WebP / SVG): read by
--    everyone, written by the same admins (storage:media).
-- 3. media_asset_delete(id): deletes an upload only when no setting points
--    at it. The gallery checks first; this checks again on the server: a
--    text search of the display settings blob, every settings_entries
--    value, every app_settings value (App Page Settings, the home-screen
--    icon), the app_branding row, the EV catalogue (ev_vehicle_details,
--    ev_vehicle_inventory) and vehicle_make_models.icon_uri for the id
--    (which every reference, `media:<id>` or the file's address, contains). Refused with
--    'media_in_use' while any is found. The client then removes the files.
-- 4. media_assets joins supabase_realtime, so a new upload shows on every
--    open app.
-- ============================================================================

-- ---- 1. The uploads ----------------------------------------------------------------------------------
create table if not exists public.media_assets (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null,
  name       text not null,
  path       text,
  dark_path  text,
  mime       text not null default 'image/png',
  width      integer,
  height     integer,
  bytes      integer,
  tint       boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table public.media_assets is
  'Media Gallery uploads (0273): icons, images and logos in the public media bucket, referenced from settings as media:<id>.';

alter table public.media_assets drop constraint if exists media_assets_kind_check;
alter table public.media_assets add constraint media_assets_kind_check check (kind in ('icon', 'image', 'logo'));
alter table public.media_assets drop constraint if exists media_assets_name_check;
alter table public.media_assets add constraint media_assets_name_check
  check (length(btrim(name)) between 1 and 80);
alter table public.media_assets drop constraint if exists media_assets_mime_check;
alter table public.media_assets add constraint media_assets_mime_check
  check (mime in ('image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'));
alter table public.media_assets drop constraint if exists media_assets_file_check;
alter table public.media_assets add constraint media_assets_file_check check (path is not null or dark_path is not null);
alter table public.media_assets drop constraint if exists media_assets_path_check;
alter table public.media_assets add constraint media_assets_path_check
  check (path is null or path ~ ('^' || kind || '/' || id::text || '\.(png|jpg|webp|svg)$'));
alter table public.media_assets drop constraint if exists media_assets_dark_path_check;
alter table public.media_assets add constraint media_assets_dark_path_check
  check (dark_path is null or (kind = 'logo' and dark_path ~ ('^logo/' || id::text || '-dark\.(png|jpg|webp|svg)$')));
alter table public.media_assets drop constraint if exists media_assets_size_check;
alter table public.media_assets add constraint media_assets_size_check
  check ((bytes is null or bytes between 0 and 5242880)
     and (width is null or width between 1 and 10000)
     and (height is null or height between 1 and 10000));
alter table public.media_assets drop constraint if exists media_assets_tint_check;
alter table public.media_assets add constraint media_assets_tint_check check (not tint or kind = 'icon');

create index if not exists media_assets_kind_idx on public.media_assets (kind, created_at desc);

-- Who uploaded it is the server's to say.
create or replace function public.media_assets_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
  else
    new.id := old.id;
    new.kind := old.kind;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;
revoke execute on function public.media_assets_stamp() from public, anon, authenticated;

drop trigger if exists trg_media_assets_stamp on public.media_assets;
create trigger trg_media_assets_stamp
  before insert or update on public.media_assets
  for each row execute function public.media_assets_stamp();

alter table public.media_assets enable row level security;
revoke all on public.media_assets from anon, authenticated;
grant select on public.media_assets to anon, authenticated;
grant insert, update on public.media_assets to authenticated;

drop policy if exists "media_assets read" on public.media_assets;
create policy "media_assets read" on public.media_assets
  for select to anon, authenticated using (true);
drop policy if exists "media_assets admin insert" on public.media_assets;
create policy "media_assets admin insert" on public.media_assets
  for insert to authenticated
  with check ((select public.caller_admin_can_write('media_assets')));
drop policy if exists "media_assets admin update" on public.media_assets;
create policy "media_assets admin update" on public.media_assets
  for update to authenticated
  using ((select public.caller_admin_can_write('media_assets')))
  with check ((select public.caller_admin_can_write('media_assets')));

-- ---- 2. The bucket -----------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "media read" on storage.objects;
drop policy if exists "media admin insert" on storage.objects;
drop policy if exists "media admin update" on storage.objects;
drop policy if exists "media admin delete" on storage.objects;

create policy "media read"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'media');
create policy "media admin insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (select public.caller_admin_can_write('storage:media')));
create policy "media admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'media' and (select public.caller_admin_can_write('storage:media')))
  with check (bucket_id = 'media' and (select public.caller_admin_can_write('storage:media')));
create policy "media admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (select public.caller_admin_can_write('storage:media')));

-- Display Settings edits it all (Edit on 'admin-settings' covers it too).
insert into public.admin_table_pages (target, page) values
  ('media_assets', 'admin-settings-display'),
  ('storage:media', 'admin-settings-display'),
  ('rpc:media_asset_delete', 'admin-settings-display')
on conflict do nothing;

-- ---- 3. Delete, only when nothing uses it ------------------------------------------------------------
-- Where [p_id] is still referenced (labels for the error), empty when nowhere.
create or replace function public.media_asset_references(p_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(w order by w), '{}') from (
    select 'Display Settings' as w
      from public.admin_display_settings d
     where strpos(d.settings::text, p_id::text) > 0
    union
    select 'settings_entries: ' || e.category
      from public.settings_entries e
     where strpos(e.values::text, p_id::text) > 0
    union
    select 'app_settings: ' || s.key
      from public.app_settings s
     where strpos(s.value::text, p_id::text) > 0
    union
    select 'App Settings (app_branding)'
      from public.app_branding b
     where strpos(to_jsonb(b)::text, p_id::text) > 0
    union
    select 'EV Vehicle Details'
      from public.ev_vehicle_details v
     where strpos(v.values::text, p_id::text) > 0
    union
    select 'EV Vehicle Inventory'
      from public.ev_vehicle_inventory v
     where strpos(v.values::text, p_id::text) > 0
    union
    select 'Vehicle Make & Model'
      from public.vehicle_make_models m
     where strpos(m.icon_uri, p_id::text) > 0
  ) found;
$$;
revoke execute on function public.media_asset_references(uuid) from public, anon, authenticated;

create or replace function public.media_asset_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_used text[];
begin
  if not public.caller_admin_can_write('rpc:media_asset_delete') then
    raise exception 'Only an admin who can edit Display Settings can delete media.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.media_assets where id = p_id) then
    raise exception 'media_not_found' using errcode = 'P0002';
  end if;
  v_used := public.media_asset_references(p_id);
  if cardinality(v_used) > 0 then
    raise exception 'media_in_use: still used by %', array_to_string(v_used, ', ')
      using errcode = 'P0001',
            hint = 'Change those places to another icon first.';
  end if;
  delete from public.media_assets where id = p_id;
end;
$$;
revoke execute on function public.media_asset_delete(uuid) from public, anon;
grant execute on function public.media_asset_delete(uuid) to authenticated;

-- ---- 4. Live -----------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'media_assets') then
    alter publication supabase_realtime add table public.media_assets;
  end if;
end $$;
