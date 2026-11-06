-- ============================================================================
-- Regression test for migration 0354: media_version() is a stable fingerprint
-- of the uploaded media set that changes on add / edit / delete and on a
-- branding image change, so the app's on-device media cache only re-syncs
-- when something changed.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/media_version_0354.sql
--
-- Runs in one transaction and is rolled back. Made-up data only.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;

do $$
declare
  v0 text; v1 text; v2 text; v3 text;
  vid uuid := '00000000-0000-0000-0000-0000003540a1';
begin
  v0 := public.media_version();
  perform pg_temp.check(v0 is not null and length(v0) = 32, 'returns a 32-char md5');

  -- add
  insert into public.media_assets (id, kind, name, path, mime, tint)
    values (vid, 'icon', 'cache-test', 'icon/00000000-0000-0000-0000-0000003540a1.png', 'image/png', false);
  v1 := public.media_version();
  perform pg_temp.check(v1 <> v0, 'an added asset changes the version');

  -- edit (re-upload: bytes change)
  update public.media_assets set bytes = 12345 where id = vid;
  v2 := public.media_version();
  perform pg_temp.check(v2 <> v1, 'an edited asset changes the version');

  -- delete
  delete from public.media_assets where id = vid;
  v3 := public.media_version();
  perform pg_temp.check(v3 <> v2, 'a deleted asset changes the version');
  perform pg_temp.check(v3 = v0, 'deleting the added asset returns to the original version');
end $$;

-- A branding image change also moves the version.
do $$
declare v_before text; v_after text;
begin
  insert into public.app_branding (id) values ('global') on conflict (id) do nothing;
  v_before := public.media_version();
  update public.app_branding set app_icon_url = 'https://example.test/icon-0354.png' where id = 'global';
  v_after := public.media_version();
  perform pg_temp.check(v_after <> v_before, 'a branding image change moves the version');
end $$;

rollback;
