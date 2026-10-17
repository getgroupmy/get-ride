-- ============================================================================
-- 0215: "Allow all the time" for Android partners (Admin → App Settings →
-- Permissions), its own switch beside the iPhone's "Always".
--
--   locationAlwaysAndroid  Android partners pick "Allow all the time" before
--                          going online. Off by default: Android keeps an
--                          online partner's location through its foreground
--                          service with "While using the app" already.
--
-- Builds on 0196: permission_rules() reads it, set_permission_rules() sets
-- it; every other switch is as before.
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
      'notifications', public.permission_rule_on(r #> '{user,notifications}', true)),
    'partner', jsonb_build_object(
      'locationService', public.permission_rule_on(r #> '{partner,locationService}', true),
      'location', public.permission_rule_on(r #> '{partner,location}', true),
      'locationAlways', public.permission_rule_on(r #> '{partner,locationAlways}', true),
      'locationAlwaysAndroid', public.permission_rule_on(r #> '{partner,locationAlwaysAndroid}', false),
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
  if not public.caller_is_admin() then
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
      'notifications', public.permission_rule_on(r #> '{user,notifications}', (cur #>> '{user,notifications}')::boolean)),
    'partner', jsonb_build_object(
      'locationService', public.permission_rule_on(r #> '{partner,locationService}', (cur #>> '{partner,locationService}')::boolean),
      'location', public.permission_rule_on(r #> '{partner,location}', (cur #>> '{partner,location}')::boolean),
      'locationAlways', public.permission_rule_on(r #> '{partner,locationAlways}', (cur #>> '{partner,locationAlways}')::boolean),
      'locationAlwaysAndroid', public.permission_rule_on(r #> '{partner,locationAlwaysAndroid}', (cur #>> '{partner,locationAlwaysAndroid}')::boolean),
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
