-- ============================================================================
-- 0134: ride calls that ring like a phone call
--
-- A ride call (0131) used to reach a closed app as an ordinary "… is calling"
-- notification and a vibration. Builds that can show the phone's own
-- incoming-call screen now say so, and send-push rings them instead
-- (supabase/functions/_shared/push.ts: planDeliveries):
--
--   * push_tokens.capabilities lists what the build behind a token can do;
--     `call_ui` is a build with the native call screen. A build from before
--     has none, and keeps getting the notification it can show;
--   * push_register_device registers a token with its capabilities. The old
--     push_register_token is left as it was for the Expo app and older
--     Flutter builds, and leaves a token's capabilities alone;
--   * an iPhone's PushKit (VoIP) token is stored with platform `ios_voip`;
--     send-push sends it nothing but ride calls;
--   * a call that stops ringing unanswered (the caller hangs up, or it rings
--     out) pushes the callee `ride_call_end`, so a phone still ringing stops
--     and the callee learns they missed it;
--   * the call push carries the caller's name in its data, for the call
--     screen (a data-only message has no title to read it from).
-- ============================================================================

alter table public.push_tokens
  add column if not exists capabilities text[] not null default '{}';

create or replace function public.push_register_device(
  p_token text,
  p_platform text default null,
  p_device_name text default null,
  p_capabilities text[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Only capabilities send-push knows; anything else is dropped.
  v_caps text[] := array(
    select distinct c from unnest(coalesce(p_capabilities, '{}')) c where c in ('call_ui') order by c
  );
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_token is null or length(trim(p_token)) = 0 or length(p_token) > 512 then
    raise exception 'invalid_token';
  end if;
  insert into public.push_tokens (token, profile_id, platform, device_name, capabilities)
  values (p_token, auth.uid(), p_platform, p_device_name, v_caps)
  on conflict (token) do update
    set profile_id   = excluded.profile_id,
        platform     = excluded.platform,
        device_name  = excluded.device_name,
        capabilities = excluded.capabilities,
        updated_at   = now();
end;
$$;

revoke execute on function public.push_register_device(text, text, text, text[]) from public, anon;
grant execute on function public.push_register_device(text, text, text, text[]) to authenticated;

-- The call push, as in 0131, with the caller's name in the data.
create or replace function public.notify_ride_call_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.send_push_webhook(jsonb_build_object(
    'title', coalesce(new.caller_name, 'GET.ride') || ' is calling',
    'body', 'Voice call about your ride. Tap to answer.',
    'profileId', new.callee_id,
    'data', jsonb_build_object(
      'type', 'ride_call',
      'request_id', new.request_id,
      'call_id', new.id,
      'caller_name', new.caller_name,
      'role', case new.caller_role when 'rider' then 'partner' else 'rider' end
    )
  ));
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_call_push() from public, anon, authenticated;

-- {title, body, data} of the push for a call that stopped ringing, or null
-- when the change is not one: only an unanswered call (the caller gave up,
-- or it rang out). A declined call was the callee's own doing.
create or replace function public.ride_call_end_message(
  p_old_status text,
  p_new_status text,
  p_call_id uuid,
  p_request_id uuid,
  p_caller_name text,
  p_caller_role text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_old_status = 'ringing' and p_new_status in ('missed', 'cancelled') then jsonb_build_object(
      'title', 'Missed call',
      'body', coalesce(nullif(btrim(coalesce(p_caller_name, '')), ''), 'Someone') || ' called about your ride.',
      'data', jsonb_build_object(
        'type', 'ride_call_end',
        'request_id', p_request_id,
        'call_id', p_call_id,
        'status', p_new_status,
        'role', case p_caller_role when 'rider' then 'partner' else 'rider' end
      )
    )
  end;
$$;

create or replace function public.notify_ride_call_end_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb := public.ride_call_end_message(
    old.status, new.status, new.id, new.request_id, new.caller_name, new.caller_role
  );
begin
  if m is not null then
    perform public.send_push_webhook(m || jsonb_build_object('profileId', new.callee_id));
  end if;
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_call_end_push() from public, anon, authenticated;

create or replace trigger trg_ride_calls_end_push after update of status on public.ride_calls
  for each row execute function public.notify_ride_call_end_push();

notify pgrst, 'reload schema';
