-- 0336: Media Gallery › Map Icons.
--
-- A fourth kind of upload next to icons, images and logos: map icons, the
-- markers drawn on the map (a vehicle service's Map Icon). Stored in the
-- same public `media` bucket under map_icon/<id>.<ext>, with the same
-- admin rights, size limit and file types. Only the kind check changes;
-- the path check already follows the kind.

alter table public.media_assets drop constraint if exists media_assets_kind_check;
alter table public.media_assets add constraint media_assets_kind_check
  check (kind in ('icon', 'image', 'logo', 'map_icon'));

comment on table public.media_assets is
  'Media Gallery uploads (0273, map icons 0336): icons, images, logos and map icons in the public media bucket, referenced from settings as media:<id>.';

notify pgrst, 'reload schema';
