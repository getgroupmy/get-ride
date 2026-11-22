-- ============================================================================
-- 0427: "Precise location" (Admin → App Settings → Permissions), for users and
-- for partners.
--
--   locationPrecise  The phone's precise location, not an approximate one.
--                    Android 12 and later let "Approximate" be picked when
--                    location is allowed, and an iPhone has "Precise Location"
--                    to switch off: either leaves the app up to a few
--                    kilometres from where the person is. On: the app asks
--                    for the precise one before letting them on (users before
--                    the home map, partners before going online), as it does
--                    for the other checks.
--
-- Off by default, for both: nothing changes for anyone until an admin turns
-- it on.
--
-- Builds on 0215 and 0223: permission_rules() reads it, set_permission_rules()
-- sets it, for the same admins as before (0223 scoped it to the admin pages
-- that cover it); every other switch is as before. An app from before this
-- ignores the new key.
-- ============================================================================

create or replace function public.permission_rules()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (select coalesce((select value from public.app_settings where key = 'permission_rules'), '{}'::jsonb) as r)
  select jsonb_build_object(
    'user', jsonb_build_object(
      'locationService', public.permission_rule_on(r #> '{user,locationService}', true),
      'location', public.permission_rule_on(r #> '{user,location}', true),
      'locationPrecise', public.permission_rule_on(r #> '{user,locationPrecise}', false),
      'notifications', public.permission_rule_on(r #> '{user,notifications}', true)),
    'partner', jsonb_build_object(
      'locationService', public.permission_rule_on(r #> '{partner,locationService}', true),
      'location', public.permission_rule_on(r #> '{partner,location}', true),
      'locationAlways', public.permission_rule_on(r #> '{partner,locationAlways}', true),
      'locationAlwaysAndroid', public.permission_rule_on(r #> '{partner,locationAlwaysAndroid}', false),
      'locationPrecise', public.permission_rule_on(r #> '{partner,locationPrecise}', false),
      'notifications', public.permission_rule_on(r #> '{partner,notifications}', true)),
    'showPermissionsCard', public.permission_rule_on(r -> 'showPermissionsCard', true))
  from v;
$$;
revoke execute on function public.permission_rules() from public, anon;
grant execute on function public.permission_rules() to authenticated, service_role;

create or replace function public.set_permission_rules(p_rules jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cur jsonb := public.permission_rules();
  r jsonb := coalesce(p_rules, '{}'::jsonb);
begin
  -- Who may change the rules is as 0223 left it: an admin whose pages cover
  -- this function, not any admin.
  if not public.caller_admin_can_write('rpc:set_permission_rules') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(r) <> 'object' then
    raise exception 'The permission rules must be an object.' using errcode = '22023';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('permission_rules', jsonb_build_object(
    'user', jsonb_build_object(
      'locationService', public.permission_rule_on(r #> '{user,locationService}', (cur #>> '{user,locationService}')::boolean),
      'location', public.permission_rule_on(r #> '{user,location}', (cur #>> '{user,location}')::boolean),
      'locationPrecise', public.permission_rule_on(r #> '{user,locationPrecise}', (cur #>> '{user,locationPrecise}')::boolean),
      'notifications', public.permission_rule_on(r #> '{user,notifications}', (cur #>> '{user,notifications}')::boolean)),
    'partner', jsonb_build_object(
      'locationService', public.permission_rule_on(r #> '{partner,locationService}', (cur #>> '{partner,locationService}')::boolean),
      'location', public.permission_rule_on(r #> '{partner,location}', (cur #>> '{partner,location}')::boolean),
      'locationAlways', public.permission_rule_on(r #> '{partner,locationAlways}', (cur #>> '{partner,locationAlways}')::boolean),
      'locationAlwaysAndroid', public.permission_rule_on(r #> '{partner,locationAlwaysAndroid}', (cur #>> '{partner,locationAlwaysAndroid}')::boolean),
      'locationPrecise', public.permission_rule_on(r #> '{partner,locationPrecise}', (cur #>> '{partner,locationPrecise}')::boolean),
      'notifications', public.permission_rule_on(r #> '{partner,notifications}', (cur #>> '{partner,notifications}')::boolean)),
    'showPermissionsCard', public.permission_rule_on(r -> 'showPermissionsCard', (cur ->> 'showPermissionsCard')::boolean)),
    now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.permission_rules();
end;
$$;
revoke execute on function public.set_permission_rules(jsonb) from public, anon;
grant execute on function public.set_permission_rules(jsonb) to authenticated;

notify pgrst, 'reload schema';
