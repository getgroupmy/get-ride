-- ============================================================================
-- Regression test for migration 0336: Media Gallery › Map Icons. A map icon
-- is stored under map_icon/<id>.<ext>; it can't be tinted, can't have a
-- dark version, and a made-up kind is still refused.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/media_map_icon_0336.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when check_violation then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;

insert into public.media_assets (id, kind, name, path, mime, width, height, bytes)
values ('00000000-0000-0000-0000-000000033601', 'map_icon', 'Blue car',
        'map_icon/00000000-0000-0000-0000-000000033601.png', 'image/png', 128, 128, 900);

do $$
begin
  if not exists (select 1 from public.media_assets
                  where id = '00000000-0000-0000-0000-000000033601' and kind = 'map_icon') then
    raise exception 'FAILED: a map icon was not stored';
  end if;
end $$;

select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000033602', 'map_icon', 'Wrong folder',
          'icon/00000000-0000-0000-0000-000000033602.png', 'image/png')$q$, 'a map icon outside map_icon/');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime, tint)
  values ('00000000-0000-0000-0000-000000033603', 'map_icon', 'Tinted',
          'map_icon/00000000-0000-0000-0000-000000033603.png', 'image/png', true)$q$, 'a tinted map icon');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000033604', 'marker', 'Unknown kind',
          'marker/00000000-0000-0000-0000-000000033604.png', 'image/png')$q$, 'an unknown kind');

rollback;
