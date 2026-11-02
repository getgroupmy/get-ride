-- ============================================================================
-- Regression test for migration 0336: Media Gallery › Map Icons. A map icon
-- is stored under map_icon/<id>.<ext>; it can't be tinted, can't have a
-- dark version, and a made-up kind is still refused. A multi-angle map icon
-- keeps 2 to 72 frames in angles ([{deg, path}], sorted, no heading twice,
-- 0-359, under map_icon/<id>/<ddd>.png|webp); only a map icon has them.
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

-- ---- Multi-angle ----
insert into public.media_assets (id, kind, name, path, mime, width, height, bytes, angles)
values ('00000000-0000-0000-0000-000000033611', 'map_icon', 'Taxi, 4 angles',
        'map_icon/00000000-0000-0000-0000-000000033611/000.png', 'image/png', 256, 256, 900,
        '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033611/000.png"},
          {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033611/090.png"},
          {"deg": 180, "path": "map_icon/00000000-0000-0000-0000-000000033611/180.webp"},
          {"deg": 270, "path": "map_icon/00000000-0000-0000-0000-000000033611/270.png"}]');
-- No main file: the frames alone.
insert into public.media_assets (id, kind, name, path, mime, angles)
values ('00000000-0000-0000-0000-000000033612', 'map_icon', 'Van, 2 angles', null, 'image/png',
        '[{"deg": 45, "path": "map_icon/00000000-0000-0000-0000-000000033612/045.png"},
          {"deg": 225, "path": "map_icon/00000000-0000-0000-0000-000000033612/225.png"}]');
-- 72 frames, every 5 degrees.
insert into public.media_assets (id, kind, name, path, mime, angles)
select '00000000-0000-0000-0000-000000033613', 'map_icon', 'Bike, 72 angles',
       'map_icon/00000000-0000-0000-0000-000000033613/000.png', 'image/png',
       jsonb_agg(jsonb_build_object('deg', d, 'path',
         'map_icon/00000000-0000-0000-0000-000000033613/' || lpad(d::text, 3, '0') || '.png') order by d)
  from generate_series(0, 355, 5) d;

do $$
begin
  if (select jsonb_array_length(angles) from public.media_assets
       where id = '00000000-0000-0000-0000-000000033611') <> 4 then
    raise exception 'FAILED: a 4-angle icon was not stored with its frames';
  end if;
  if (select jsonb_array_length(angles) from public.media_assets
       where id = '00000000-0000-0000-0000-000000033613') <> 72 then
    raise exception 'FAILED: a 72-angle icon was not stored';
  end if;
  if not exists (select 1 from public.media_assets
                  where id = '00000000-0000-0000-0000-000000033612' and path is null) then
    raise exception 'FAILED: a multi-angle icon with no main file was refused';
  end if;
  -- Single icons are unchanged: no angles.
  if (select angles from public.media_assets where id = '00000000-0000-0000-0000-000000033601') is not null then
    raise exception 'FAILED: a single map icon has angles';
  end if;
end $$;

-- Only map icons have angles.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime, angles)
  values ('00000000-0000-0000-0000-000000033621', 'icon', 'Icon with angles',
          'icon/00000000-0000-0000-0000-000000033621.png', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033621/000.png"},
            {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033621/090.png"}]')$q$, 'angles on an icon');
-- One frame is not multi-angle; 73 is too many; an empty list too.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033622', 'map_icon', 'One frame', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033622/000.png"}]')$q$, 'a single frame');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033622', 'map_icon', 'No frames', 'image/png', '[]')$q$, 'no frames');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  select '00000000-0000-0000-0000-000000033623', 'map_icon', '73 frames', 'image/png',
         jsonb_agg(jsonb_build_object('deg', d, 'path',
           'map_icon/00000000-0000-0000-0000-000000033623/' || lpad(d::text, 3, '0') || '.png') order by d)
    from generate_series(0, 72) d$q$, '73 frames');
-- A heading twice, out of order, out of range, or not whole.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033624', 'map_icon', 'Twice', 'image/png',
          '[{"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033624/090.png"},
            {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033624/090.webp"}]')$q$, 'a heading twice');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033625', 'map_icon', 'Unsorted', 'image/png',
          '[{"deg": 180, "path": "map_icon/00000000-0000-0000-0000-000000033625/180.png"},
            {"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033625/000.png"}]')$q$, 'frames out of order');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033626', 'map_icon', '360', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033626/000.png"},
            {"deg": 360, "path": "map_icon/00000000-0000-0000-0000-000000033626/360.png"}]')$q$, 'a heading of 360');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033627', 'map_icon', 'Half', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033627/000.png"},
            {"deg": 22.5, "path": "map_icon/00000000-0000-0000-0000-000000033627/022.png"}]')$q$, 'a heading of 22.5');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033628', 'map_icon', 'Negative', 'image/png',
          '[{"deg": -90, "path": "map_icon/00000000-0000-0000-0000-000000033628/-90.png"},
            {"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033628/000.png"}]')$q$, 'a negative heading');
-- Frames in the wrong place, under the wrong name, or of the wrong type.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033629', 'map_icon', 'Other id', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033611/000.png"},
            {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033611/090.png"}]')$q$, 'frames of another upload');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033630', 'map_icon', 'Wrong name', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033630/000.png"},
            {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033630/045.png"}]')$q$, 'a frame named for another heading');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033631', 'map_icon', 'SVG frame', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033631/000.svg"},
            {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033631/090.png"}]')$q$, 'an SVG frame');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033632', 'map_icon', 'No path', 'image/png',
          '[{"deg": 0}, {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033632/090.png"}]')$q$, 'a frame with no file');
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime, angles)
  values ('00000000-0000-0000-0000-000000033633', 'map_icon', 'Object', 'image/png',
          '{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033633/000.png"}')$q$, 'angles that are not a list');
-- The main file of a multi-angle icon is its first frame, nothing else.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime, angles)
  values ('00000000-0000-0000-0000-000000033634', 'map_icon', 'Main elsewhere',
          'map_icon/00000000-0000-0000-0000-000000033634.png', 'image/png',
          '[{"deg": 0, "path": "map_icon/00000000-0000-0000-0000-000000033634/000.png"},
            {"deg": 90, "path": "map_icon/00000000-0000-0000-0000-000000033634/090.png"}]')$q$, 'a main file that is not a frame');
-- A single map icon's path stays map_icon/<id>.<ext>, never a frame's.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, path, mime)
  values ('00000000-0000-0000-0000-000000033635', 'map_icon', 'Frame path, no angles',
          'map_icon/00000000-0000-0000-0000-000000033635/000.png', 'image/png')$q$, 'a frame path without angles');
-- An upload needs a file: no path, no dark path, no angles.
select pg_temp.refused($q$insert into public.media_assets (id, kind, name, mime)
  values ('00000000-0000-0000-0000-000000033636', 'map_icon', 'Nothing', 'image/png')$q$, 'an upload with no file');
-- Taking the frames off later is checked the same way.
select pg_temp.refused($q$update public.media_assets set angles = null
  where id = '00000000-0000-0000-0000-000000033611'$q$, 'a multi-angle icon losing its frames under a frame path');

rollback;
