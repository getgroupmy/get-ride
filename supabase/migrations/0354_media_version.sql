-- ============================================================================
-- 0354: a fingerprint of the uploaded icons / images, so the app only
-- re-syncs its on-device media cache when something actually changed.
--
-- The app loads the whole Media Gallery set (media_assets) and the branding
-- images live; downloading every file on every launch is wasteful. media_version()
-- is a cheap hash of the current set — every media_assets row (id, paths, mime,
-- bytes, tint, angles, created_at) plus the branding splash/app-icon URLs. It
-- changes on any add, re-upload (bytes change), edit (angles, paths) or delete,
-- and on a branding image change. The app keeps the last hash; when it differs
-- it fetches the set it already reads, downloads the new/changed files, drops
-- the removed ones, and stores the new hash. No change → no downloads.
--
-- It only reads already-public configuration (the media bucket is public and
-- the branding row is read by every client), so it is granted to anon too.
-- ============================================================================
create or replace function public.media_version()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select md5(
    coalesce((
      select string_agg(
        m.id::text || '|' || coalesce(m.path, '') || '|' || coalesce(m.dark_path, '') || '|'
          || coalesce(m.mime, '') || '|' || coalesce(m.bytes::text, '') || '|' || coalesce(m.tint::text, '')
          || '|' || coalesce(m.angles::text, '') || '|' || coalesce(m.created_at::text, ''),
        chr(10) order by m.id)
      from public.media_assets m), '')
    || '::'
    || coalesce((
      select coalesce(b.splash_image_url, '') || '|' || coalesce(b.app_icon_url, '') || '|'
          || coalesce(b.icon_changed_at::text, '')
      from public.app_branding b where b.id = 'global'), ''));
$$;
revoke execute on function public.media_version() from public;
grant execute on function public.media_version() to anon, authenticated;

notify pgrst, 'reload schema';
