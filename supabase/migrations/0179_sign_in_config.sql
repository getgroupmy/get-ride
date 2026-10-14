-- ============================================================================
-- 0179: the sign-in switches: passkeys per surface, one device per account
--
-- Admin → App Settings → Sign-in security. Four switches, all OFF:
--
--   * passkeyWeb / passkeyAndroid / passkeyIos: draw "Sign in with a
--     passkey" (and offer to save one) on that surface. Off until each is
--     set up: passkeys on for the project in the Supabase dashboard
--     (Authentication → Configuration → Passkeys, relying party www.getride.my)
--     for all three; on Android also assetlinks.json naming the app and
--     its signing keys, on iOS the Associated Domains entitlement and
--     apple-app-site-association. A button drawn before that fails for
--     everybody who presses it. Not a security control: GoTrue decides
--     whether a passkey is accepted.
--   * oneDevice: an account that is not an admin or sub-admin may be
--     signed in on one device at a time (migration 0180). Turn it on only
--     once App Version's minimum is 1.4.8: older builds don't know they
--     were signed out elsewhere.
--
-- sign_in_config() is read before anybody signs in, so it is open to
-- anon; set_sign_in_config() is the admin's save.
-- ============================================================================

insert into public.app_settings (key, value)
values ('sign_in', '{"passkeyWeb": false, "passkeyAndroid": false, "passkeyIos": false, "oneDevice": false}'::jsonb)
on conflict (key) do nothing;

create or replace function public.sign_in_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'passkeyWeb', coalesce((v->>'passkeyWeb')::boolean, false),
    'passkeyAndroid', coalesce((v->>'passkeyAndroid')::boolean, false),
    'passkeyIos', coalesce((v->>'passkeyIos')::boolean, false),
    'oneDevice', coalesce((v->>'oneDevice')::boolean, false)
  )
  from (select (select value from public.app_settings where key = 'sign_in') as v) s;
$$;

revoke execute on function public.sign_in_config() from public;
grant execute on function public.sign_in_config() to anon, authenticated;

-- Whether one device per account is on (0180 reads it on every sign-in).
create or replace function public.one_device_on()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value->>'oneDevice')::boolean from public.app_settings where key = 'sign_in'), false);
$$;

revoke execute on function public.one_device_on() from public, anon, authenticated;

-- The admin's save. Only the four known switches, as booleans.
create or replace function public.set_sign_in_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change sign-in security.' using errcode = '42501';
  end if;
  v := jsonb_build_object(
    'passkeyWeb', coalesce((p_config->>'passkeyWeb')::boolean, false),
    'passkeyAndroid', coalesce((p_config->>'passkeyAndroid')::boolean, false),
    'passkeyIos', coalesce((p_config->>'passkeyIos')::boolean, false),
    'oneDevice', coalesce((p_config->>'oneDevice')::boolean, false)
  );
  insert into public.app_settings (key, value, updated_at) values ('sign_in', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  -- Off: nobody is held to one device any more (0180's table, when present).
  if not (v->>'oneDevice')::boolean and to_regclass('public.active_sessions') is not null then
    execute 'delete from public.active_sessions where true';
  end if;
  return v;
end;
$$;

revoke execute on function public.set_sign_in_config(jsonb) from public, anon;
grant execute on function public.set_sign_in_config(jsonb) to authenticated;
