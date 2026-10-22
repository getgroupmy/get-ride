-- ============================================================================
-- Regression test for migration 0273: the Media Gallery's uploads — anyone
-- reads them, only an admin with EDIT on Display Settings adds one, and
-- media_asset_delete refuses while a setting still points at the upload.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/media_gallery_0273.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000273a1'),  -- admin, EDIT on Display Settings
  ('00000000-0000-0000-0000-0000000273a2'),  -- admin, READ on Display Settings
  ('00000000-0000-0000-0000-0000000273c1')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000273%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000273a1', 'admin-settings-display', 'edit'),
  ('00000000-0000-0000-0000-0000000273a2', 'admin-settings-display', 'read')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED (not refused): %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused_with(p_sql text, p_code text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_code in sqlerrm) > 0 then
      return;
    end if;
    raise exception 'FAILED: % refused with "%", not %', p_what, sqlerrm, p_code;
  end;
  raise exception 'FAILED (not refused): %', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text) to authenticated;

-- ---- 1. The table, the bucket, live ------------------------------------------------------------------
select pg_temp.check((select relrowsecurity from pg_class where oid = 'public.media_assets'::regclass),
  'row-level security on');
select pg_temp.check(exists (select 1 from storage.buckets where id = 'media' and public), 'a public media bucket');
select pg_temp.check(exists (select 1 from pg_publication_tables
                              where pubname = 'supabase_realtime' and tablename = 'media_assets'),
  'media_assets is live');

-- ---- 2. Who adds one ---------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000273c1');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000027301', 'icon', 'Rider icon',
          'icon/00000000-0000-0000-0000-000000027301.png', 'image/png')$q$, 'a rider adding one');
select pg_temp.as_user('00000000-0000-0000-0000-0000000273a2');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000027301', 'icon', 'Read-only icon',
          'icon/00000000-0000-0000-0000-000000027301.png', 'image/png')$q$, 'a read-only admin adding one');

select pg_temp.as_user('00000000-0000-0000-0000-0000000273a1');
insert into public.media_assets (id, kind, name, path, mime, width, height, bytes, tint)
values ('00000000-0000-0000-0000-000000027301', 'icon', 'Pharmacy cross',
        'icon/00000000-0000-0000-0000-000000027301.png', 'image/png', 256, 256, 1200, true),
       ('00000000-0000-0000-0000-000000027302', 'logo', 'Partner logo',
        'logo/00000000-0000-0000-0000-000000027302.png', 'image/png', 400, 120, 9000, false);
update public.media_assets set dark_path = 'logo/00000000-0000-0000-0000-000000027302-dark.png'
 where id = '00000000-0000-0000-0000-000000027302';
select pg_temp.check((select created_by from public.media_assets where id = '00000000-0000-0000-0000-000000027301')
  = '00000000-0000-0000-0000-0000000273a1', 'the uploader is recorded');
select pg_temp.refused_with($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000027303', 'icon', 'Wrong place', 'image/elsewhere.png', 'image/png')$q$,
  'media_assets_path_check', 'a file outside its own <kind>/<id> path');
select pg_temp.refused_with($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000027303', 'video', 'Clip', 'video/x.png', 'image/png')$q$,
  'media_assets_kind_check', 'a kind other than icon, image or logo');

-- Anyone reads them, the rider and the signed-out app too.
select pg_temp.as_user('00000000-0000-0000-0000-0000000273c1');
select pg_temp.check((select count(*) from public.media_assets where id::text like '00000000-0000-0000-0000-00000002730%') = 2,
  'a rider reads the uploads');
select pg_temp.refused($q$update public.media_assets set name = 'Mine' where id = '00000000-0000-0000-0000-000000027301'$q$,
  'a rider renaming one');
select pg_temp.refused($q$delete from public.media_assets where id = '00000000-0000-0000-0000-000000027301'$q$,
  'a rider deleting one directly');
select pg_temp.refused_with($q$select public.media_asset_delete('00000000-0000-0000-0000-000000027302')$q$,
  'Only an admin', 'a rider calling the delete');
reset role;
set local role anon;
select pg_temp.check((select count(*) from public.media_assets where id::text like '00000000-0000-0000-0000-00000002730%') = 2,
  'the signed-out app reads them');
reset role;

-- ---- 3. Delete: refused while referenced, done when not -----------------------------------------------
-- Used as a custom side menu item's icon, and the logo's file address in a banner.
insert into public.admin_display_settings (id, settings) values ('global', '{}')
on conflict (id) do nothing;
update public.admin_display_settings
   set settings = jsonb_set(coalesce(settings, '{}'), '{userMenu}', jsonb_build_object('customItems', jsonb_build_array(
         jsonb_build_object('id', 'custom-273', 'label', 'Pharmacy', 'iconName', 'media:00000000-0000-0000-0000-000000027301'))))
 where id = 'global';
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-0000000273e1', 'advertisement-banners',
   '{"title":"Partner promo","url":"https://example.supabase.co/storage/v1/object/public/media/logo/00000000-0000-0000-0000-000000027302.png"}', 1);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000273a2');
select pg_temp.refused_with($q$select public.media_asset_delete('00000000-0000-0000-0000-000000027301')$q$,
  'Only an admin', 'a read-only admin deleting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000273a1');
select pg_temp.refused_with($q$select public.media_asset_delete('00000000-0000-0000-0000-000000027301')$q$,
  'media_in_use', 'deleting an icon a side menu item uses');
select pg_temp.refused_with($q$select public.media_asset_delete('00000000-0000-0000-0000-000000027302')$q$,
  'media_in_use', 'deleting a logo a banner shows by its address');
select pg_temp.check((select count(*) from public.media_assets where id::text like '00000000-0000-0000-0000-00000002730%') = 2,
  'both kept');
reset role;

-- The places change to something else: now both go.
update public.admin_display_settings
   set settings = jsonb_set(settings, '{userMenu}', jsonb_build_object('customItems', jsonb_build_array(
         jsonb_build_object('id', 'custom-273', 'label', 'Pharmacy', 'iconName', 'Pill'))))
 where id = 'global';
update public.settings_entries set values = '{"title":"Partner promo","url":""}'
 where id = '00000000-0000-0000-0000-0000000273e1';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000273a1');
select public.media_asset_delete('00000000-0000-0000-0000-000000027301');
select public.media_asset_delete('00000000-0000-0000-0000-000000027302');
select pg_temp.check(not exists (select 1 from public.media_assets
                                  where id::text like '00000000-0000-0000-0000-00000002730%'), 'both deleted');
select pg_temp.refused_with($q$select public.media_asset_delete('00000000-0000-0000-0000-000000027301')$q$,
  'media_not_found', 'deleting one already gone');
reset role;

rollback;
\echo 'media_gallery_0273: OK'
