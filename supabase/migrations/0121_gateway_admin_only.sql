-- 0121: A gateway phone is an admin's.
--
-- 0120 let any signed-in account register a gateway (kind 'gateway', the
-- SMS capability) and claim the jobs routed to it. Routes are the admin's,
-- so only a routed gateway ever sees a job, but a gateway carries sign-in
-- codes: an account that is not an admin — or no longer is — must not be
-- able to stand one up, or keep taking jobs after its access is removed.
--
--   messaging_heartbeat    a 'gateway' heartbeat needs an admin
--   messaging_own_gateway  (behind claim / report / receive) needs an admin

create or replace function public.messaging_heartbeat(
  p_device_id text,
  p_label text default null,
  p_platform text default null,
  p_kind text default 'app',
  p_capabilities text[] default '{}',
  p_sim_number text default null,
  p_app_version text default null
) returns public.messaging_devices
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_row public.messaging_devices;
  v_kind text := case when p_kind = 'gateway' then 'gateway' else 'app' end;
  v_caps text[] := array(
    select distinct c from unnest(coalesce(p_capabilities, '{}')) c
     where c in ('sms', 'voip') and (c <> 'sms' or v_kind = 'gateway')
  );
begin
  if auth.uid() is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  if v_kind = 'gateway' and not public.caller_is_admin() then
    raise exception 'GATEWAY_NEEDS_ADMIN' using errcode = '42501',
      hint = 'Sign in to the gateway app with an admin account.';
  end if;
  insert into public.messaging_devices
    (user_id, device_id, label, platform, kind, capabilities, sim_number, app_version, last_seen_at)
  values
    (auth.uid(), left(p_device_id, 200), left(p_label, 80), left(p_platform, 40), v_kind, v_caps,
     left(p_sim_number, 32), left(p_app_version, 40), now())
  on conflict (user_id, device_id) do update
     set label = coalesce(public.messaging_devices.label, excluded.label),
         platform = excluded.platform,
         kind = excluded.kind,
         capabilities = excluded.capabilities,
         sim_number = coalesce(excluded.sim_number, public.messaging_devices.sim_number),
         app_version = excluded.app_version,
         last_seen_at = now()
  returning * into v_row;
  return v_row;
end;
$function$;

create or replace function public.messaging_own_gateway(p_device uuid)
  returns public.messaging_devices
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_dev public.messaging_devices;
begin
  if not public.caller_is_admin() then
    raise exception 'GATEWAY_NEEDS_ADMIN' using errcode = '42501';
  end if;
  select * into v_dev from public.messaging_devices
   where id = p_device and user_id = auth.uid() and kind = 'gateway' and 'sms' = any(capabilities);
  if not found then
    raise exception 'NOT_A_GATEWAY' using errcode = '42501';
  end if;
  return v_dev;
end;
$function$;

revoke all on function public.messaging_own_gateway(uuid) from public, anon, authenticated;
