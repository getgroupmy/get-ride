-- ============================================================================
-- 0165: push notifications reach each phone once, and the right people
--
-- 1. One token per device. A reinstall, a sign-in on a second account or a
--    rotated FCM token left the old token row behind, so one phone could get
--    the same notification two or three times (live: one account held three
--    iPhone tokens and two VoIP tokens). push_register_device now takes the
--    device's key (a hash the app derives per install: the Android id, the
--    iPhone's APNs token) and drops any other token from the same device of
--    the same kind (the ordinary token, or the VoIP one). Without a key it
--    behaves as before, so older builds are unchanged.
--
-- 2. "Every driver" ride broadcasts (nobody known nearby) went to every
--    partner row: unapproved partners, who cannot take the ride, and the
--    rider themself when they are also a partner. They now ask send-push for
--    approved partners only (approvedOnly) and exclude the rider. An older
--    send-push ignores both fields and keeps the old behaviour.
-- ============================================================================

alter table public.push_tokens add column if not exists device_key text;
create index if not exists push_tokens_device_key_idx on public.push_tokens (device_key) where device_key is not null;

drop function if exists public.push_register_device(text, text, text, text[]);

create or replace function public.push_register_device(
  p_token text,
  p_platform text default null,
  p_device_name text default null,
  p_capabilities text[] default '{}',
  p_device_key text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caps text[] := array(
    select distinct c from unnest(coalesce(p_capabilities, '{}')) c where c in ('call_ui') order by c
  );
  v_key text := nullif(left(trim(coalesce(p_device_key, '')), 128), '');
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_token is null or length(trim(p_token)) = 0 or length(p_token) > 512 then
    raise exception 'invalid_token';
  end if;
  insert into public.push_tokens (token, profile_id, platform, device_name, capabilities, device_key)
  values (p_token, auth.uid(), p_platform, p_device_name, v_caps, v_key)
  on conflict (token) do update
    set profile_id   = excluded.profile_id,
        platform     = excluded.platform,
        device_name  = excluded.device_name,
        capabilities = excluded.capabilities,
        device_key   = coalesce(excluded.device_key, push_tokens.device_key),
        updated_at   = now();

  -- This device's earlier token of the same kind, whoever it belonged to:
  -- the phone now answers to this one account and this one token.
  if v_key is not null then
    delete from public.push_tokens
     where device_key = v_key
       and token <> p_token
       and (platform = 'ios_voip') = (coalesce(p_platform, '') = 'ios_voip');
  end if;
end;
$$;

revoke execute on function public.push_register_device(text, text, text, text[], text) from public, anon;
grant execute on function public.push_register_device(text, text, text, text[], text) to authenticated, service_role;

create or replace function public.ride_request_push_everyone(p_request uuid, p_message jsonb, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rider uuid;
begin
  select rider_id into v_rider from public.ride_requests where id = p_request;
  insert into public.ride_request_pushes (request_id, profile_id, kind) values (p_request, null, p_kind);
  perform public.send_push_webhook(p_message || jsonb_build_object(
    'audience', 'partners',
    'approvedOnly', true,
    'excludeProfileIds', case when v_rider is null then '[]'::jsonb else jsonb_build_array(v_rider) end
  ));
end;
$$;

revoke execute on function public.ride_request_push_everyone(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.ride_request_push_everyone(uuid, jsonb, text) to service_role;
