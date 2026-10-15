-- ============================================================================
-- 0196: what the app holds people to before they can use it (Admin → App
-- Settings → Permissions).
--
-- Riders: before the home map, after signing in. Partners: before going
-- online. Each check can be enforced (the app waits on a page that says
-- what to switch on) or bypassed, separately for riders and partners:
--
--   locationService  the phone's Location switched on
--   location         GET.ride allowed to use it
--   locationAlways   allowed "Always" (iPhone; partners only)
--   notifications    GET.ride allowed to send notifications
--
-- and showPermissionsCard shows or hides Settings → Permissions in the app.
-- Everyone signed in reads them (the app needs them before anything else);
-- only admins change them. Independent of 0195.
-- ============================================================================

insert into public.app_settings (key, value)
values ('permission_rules', jsonb_build_object(
  'user', jsonb_build_object('locationService', true, 'location', true, 'notifications', true),
  'partner', jsonb_build_object('locationService', true, 'location', true, 'locationAlways', true, 'notifications', true),
  'showPermissionsCard', true))
on conflict (key) do nothing;

-- A switch as stored, with its default when missing or unreadable.
create or replace function public.permission_rule_on(p jsonb, p_default boolean)
returns boolean
language sql
immutable
as $$
  select case
    when p is null or jsonb_typeof(p) = 'null' then p_default
    when jsonb_typeof(p) = 'boolean' then p::text = 'true'
    else lower(trim(both '"' from p::text)) not in ('false', 'f', '0', 'off', 'no')
  end;
$$;

-- The rules, every switch present: what is stored, defaults for the rest.
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
      'notifications', public.permission_rule_on(r #> '{partner,notifications}', true)),
    'showPermissionsCard', public.permission_rule_on(r -> 'showPermissionsCard', true))
  from v;
$$;
revoke execute on function public.permission_rules() from public, anon;
grant execute on function public.permission_rules() to authenticated, service_role;

-- Admins only. Takes the whole set or part of it; what is left out keeps
-- its current value.
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
