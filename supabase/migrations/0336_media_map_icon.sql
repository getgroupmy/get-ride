-- ============================================================================
-- 0336 — Media Gallery › Map Icons, single or multi-angle.
--
-- Version 20261102130000 (0336_media_map_icon). Re-runnable: the column
-- "if not exists", the function "create or replace", constraints dropped
-- first.
--
-- 1. A fourth kind of upload next to icons, images and logos: map icons,
--    the markers drawn on the map (a vehicle service's Map Icon). Stored in
--    the same public `media` bucket with the same admin rights, size limit
--    and file types.
-- 2. A map icon is either single, one file at map_icon/<id>.<ext> as
--    before, or multi-angle: one vehicle drawn from several directions,
--    one frame per heading, in media_assets.angles:
--      [{"deg": 0, "path": "map_icon/<id>/000.png"},
--       {"deg": 45, "path": "map_icon/<id>/045.png"}, ...]
--    deg a whole compass heading 0-359 (0 = facing north / up), path the
--    frame's file in the bucket under map_icon/<id>/<deg as 3 digits>.png
--    (or .webp). 2 to 72 frames, sorted by deg with no heading twice.
--    Only a map icon has angles. A multi-angle row's path is its first
--    frame's (the 0° one when it has one; the gallery's thumbnail), or null.
--    The app shows the frame nearest the car's heading, unturned.
-- 3. Deleting: media_asset_delete (0273) is unchanged. It removes the row
--    once nothing points at the id (a frame's address holds the id too, so
--    the search still finds it); the app then removes the files, every
--    frame included (lib/src/data/media_repository.dart), as it removes a
--    logo's two files. Storage files can't be deleted from SQL.
-- ============================================================================

-- ---- 1. The kind -------------------------------------------------------------------------------------
alter table public.media_assets drop constraint if exists media_assets_kind_check;
alter table public.media_assets add constraint media_assets_kind_check
  check (kind in ('icon', 'image', 'logo', 'map_icon'));

-- ---- 2. Multi-angle frames ---------------------------------------------------------------------------
alter table public.media_assets add column if not exists angles jsonb;
comment on column public.media_assets.angles is
  'A multi-angle map icon''s frames (0336): [{deg, path}] sorted by deg, 2 to 72, deg 0-359, path map_icon/<id>/<ddd>.png|webp. Null for every other upload.';

-- Whether [p_angles] is a well-formed frame list of upload [p_id]: an
-- array of 2 to 72 {deg, path}, deg a whole number 0-359 in rising order
-- (so none twice), path map_icon/<id>/<deg as 3 digits>.png or .webp.
create or replace function public.media_assets_angles_ok(p_id uuid, p_angles jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  v_prev integer := -1;
  v_deg integer;
  v_frame jsonb;
begin
  if p_angles is null or jsonb_typeof(p_angles) <> 'array' then
    return false;
  end if;
  if jsonb_array_length(p_angles) not between 2 and 72 then
    return false;
  end if;
  for v_frame in select value from jsonb_array_elements(p_angles) loop
    if jsonb_typeof(v_frame) <> 'object'
       or coalesce(jsonb_typeof(v_frame -> 'deg'), '') <> 'number'
       or coalesce(jsonb_typeof(v_frame -> 'path'), '') <> 'string' then
      return false;
    end if;
    if (v_frame ->> 'deg') !~ '^[0-9]{1,3}$' then
      return false;
    end if;
    v_deg := (v_frame ->> 'deg')::integer;
    if v_deg > 359 or v_deg <= v_prev then
      return false;
    end if;
    if (v_frame ->> 'path') !~ ('^map_icon/' || p_id::text || '/' || lpad(v_deg::text, 3, '0') || '\.(png|webp)$') then
      return false;
    end if;
    v_prev := v_deg;
  end loop;
  return true;
end;
$$;
revoke execute on function public.media_assets_angles_ok(uuid, jsonb) from public, anon;
grant execute on function public.media_assets_angles_ok(uuid, jsonb) to authenticated;

alter table public.media_assets drop constraint if exists media_assets_angles_check;
alter table public.media_assets add constraint media_assets_angles_check
  check (angles is null or (kind = 'map_icon' and public.media_assets_angles_ok(id, angles)));

-- A multi-angle icon may have no main file of its own.
alter table public.media_assets drop constraint if exists media_assets_file_check;
alter table public.media_assets add constraint media_assets_file_check
  check (path is not null or dark_path is not null or angles is not null);

-- Its main file, when set, is its first frame.
alter table public.media_assets drop constraint if exists media_assets_path_check;
alter table public.media_assets add constraint media_assets_path_check
  check (path is null
      or (angles is null and path ~ ('^' || kind || '/' || id::text || '\.(png|jpg|webp|svg)$'))
      or (angles is not null and path = angles -> 0 ->> 'path'));

comment on table public.media_assets is
  'Media Gallery uploads (0273, map icons 0336): icons, images, logos and map icons (single or multi-angle) in the public media bucket, referenced from settings as media:<id>.';

notify pgrst, 'reload schema';
