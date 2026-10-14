-- ============================================================================
-- 0176: each account's app version, recorded at every launch and sign-in
--
-- user_sessions already logs a row per launch with the version that sent it;
-- this keeps the latest on the account itself, so the admin can see at a
-- glance who is still on an old build before forcing an update (Admin → App
-- Settings → App updates) without scanning the session history.
--
--   * profiles.app_version / app_build / app_platform / app_version_at;
--   * record_app_version(version, build, platform): the signed-in user's own
--     row only; anything that isn't a short version string is ignored.
-- ============================================================================

alter table public.profiles
  add column if not exists app_version text,
  add column if not exists app_build text,
  add column if not exists app_platform text,
  add column if not exists app_version_at timestamptz;

create or replace function public.record_app_version(p_version text, p_build text default null, p_platform text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_version text := btrim(coalesce(p_version, ''));
  v_build text := nullif(btrim(coalesce(p_build, '')), '');
  v_platform text := nullif(lower(btrim(coalesce(p_platform, ''))), '');
begin
  if v_uid is null or v_version !~ '^[0-9]+(\.[0-9]+){0,3}$' then
    return;
  end if;
  if v_build is not null and v_build !~ '^[0-9A-Za-z.\-]{1,20}$' then
    v_build := null;
  end if;
  if v_platform is not null and v_platform !~ '^[a-z]{1,16}$' then
    v_platform := null;
  end if;
  update public.profiles
     set app_version = v_version,
         app_build = v_build,
         app_platform = v_platform,
         app_version_at = now()
   where id = v_uid
     and (app_version, app_build, app_platform) is distinct from (v_version, v_build, v_platform)
      or (id = v_uid and (app_version_at is null or app_version_at < now() - interval '1 day'));
end;
$$;

revoke execute on function public.record_app_version(text, text, text) from public, anon;
grant execute on function public.record_app_version(text, text, text) to authenticated;
