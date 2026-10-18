-- ============================================================================
-- 0230: a session key may come as the X-Session-Key header.
--
-- A Claude Code cloud environment can hold a key as a network secret: it
-- adds a header to every request to the hosts the admin names, and nothing
-- in the session ever sees the key. The relay (proxy.getride.my) already
-- reads `X-Session-Key`; the backend's keyed calls (0226) took the key only
-- as their first argument, in the JSON body, which such a secret cannot
-- fill. Now each of them takes the key from the request's X-Session-Key
-- header when `p_key` is not given (an explicit `p_key` still wins), so one
-- secret with that header, allowed for both hosts, covers everything.
--
-- `p_key` gets a default of null so PostgREST accepts the call without it;
-- the functions' bodies are otherwise 0226's.
-- ============================================================================

-- The key a request carries in its X-Session-Key header, or null.
create or replace function public.session_key_from_request()
returns text
language plpgsql
stable
set search_path = public
as $$
declare
  h json;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    return null;
  end;
  return nullif(btrim(coalesce(h ->> 'x-session-key', '')), '');
end;
$$;
revoke execute on function public.session_key_from_request() from public, anon, authenticated;

-- The live key, or an error; with [p_scope], also that the key may do that.
-- Counts the use. The key is [p_key], else the request's header.
create or replace function public.session_by_key(p_key text, p_scope text default null)
returns public.session_keys
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := coalesce(nullif(btrim(coalesce(p_key, '')), ''), public.session_key_from_request());
  v public.session_keys;
begin
  if v_key is null then
    raise exception 'SESSION_KEY_MISSING' using errcode = '42501',
      hint = 'Send the session key as p_key, or as the X-Session-Key header (a cloud environment adds it as a network secret).';
  end if;
  select * into v from public.session_keys
   where key_hash = public.gateway_secret_hash(v_key) and revoked_at is null and expires_at > now();
  if not found then
    raise exception 'SESSION_KEY_INVALID' using errcode = '42501',
      hint = 'This session key is unknown, has expired or was removed. A full admin adds a new one in Admin -> SMS / WhatsApp -> Session access.';
  end if;
  if p_scope is not null and not (p_scope = any(v.scopes)) then
    raise exception 'SESSION_KEY_SCOPE' using errcode = '42501',
      hint = format('This session key was not given "%s" access. A full admin adds a key with it in Admin -> SMS / WhatsApp -> Session access.', p_scope);
  end if;
  update public.session_keys set last_used_at = now(), uses = uses + 1 where id = v.id;
  return v;
end;
$$;
revoke execute on function public.session_by_key(text, text) from public, anon, authenticated;

-- ---- The keyed calls, with p_key optional (bodies as in 0226) -------------------------------
create or replace function public.session_key_info(p_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.session_keys := public.session_by_key(p_key);
  d public.messaging_devices;
begin
  if v.proxy_device is not null then
    select * into d from public.messaging_devices where id = v.proxy_device;
  end if;
  return jsonb_build_object(
    'label', v.label,
    'test_phone', v.test_phone,
    'scopes', to_jsonb(v.scopes),
    'expires_at', v.expires_at,
    'proxy', case when d.id is null then null else jsonb_build_object(
      'device', d.id, 'label', d.label, 'sim_number', d.sim_number,
      'online', d.last_seen_at > now() - interval '3 minutes') end);
end;
$$;

create or replace function public.session_key_send_sms(p_key text default null, p_body text default null, p_channel text default 'support_message')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.session_keys := public.session_by_key(p_key, 'sms');
  v_id uuid;
begin
  if coalesce(p_channel, '') not in ('support_message', 'marketing') then
    raise exception 'SESSION_KEY_CHANNEL' using errcode = '22023',
      hint = 'A session sends support_message or marketing SMS, never sign-in codes.';
  end if;
  if not (length(btrim(coalesce(p_body, ''))) between 1 and 1600) then
    raise exception 'SESSION_KEY_BODY' using errcode = '22023', hint = 'Write the message (up to 1600 characters).';
  end if;
  insert into public.sms_outbox (channel, to_phone, body, created_by)
  values (p_channel, v.test_phone, btrim(p_body), v.created_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'to', v.test_phone, 'channel', p_channel, 'status', 'queued');
end;
$$;

create or replace function public.session_key_outbox(p_key text default null, p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.session_keys := public.session_by_key(p_key);
  v_codes boolean := 'codes' = any(v.scopes);
begin
  if not (v.scopes && array['sms', 'codes']) then
    raise exception 'SESSION_KEY_SCOPE' using errcode = '42501',
      hint = 'This session key was given neither "sms" nor "codes" access.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'channel', o.channel, 'to', o.to_phone,
             'body', case when o.channel = 'otp' and v_codes then coalesce(s.body, o.body) else o.body end,
             'status', o.status, 'error', o.error, 'attempts', o.attempts,
             'created_at', o.created_at, 'sent_at', o.sent_at) order by o.created_at desc)
      from (
        select * from public.sms_outbox
         where public.session_phone_digits(to_phone) = public.session_phone_digits(v.test_phone)
         order by created_at desc
         limit greatest(1, least(coalesce(p_limit, 20), 100))
      ) o
      left join public.sms_otp_secret s on s.outbox_id = o.id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.session_key_inbox(p_key text default null, p_since timestamptz default null, p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.session_keys := public.session_by_key(p_key, 'sms');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', i.id, 'from', i.from_phone, 'body', i.body, 'channel', i.channel,
             'received_at', i.received_at) order by i.received_at desc)
      from (
        select * from public.sms_inbox
         where public.session_phone_digits(from_phone) = public.session_phone_digits(v.test_phone)
           and (p_since is null or received_at > p_since)
         order by received_at desc
         limit greatest(1, least(coalesce(p_limit, 20), 100))
      ) i
  ), '[]'::jsonb);
end;
$$;

create or replace function public.session_key_proxy_check(p_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.session_keys := public.session_by_key(p_key, 'proxy');
  d public.messaging_devices;
begin
  if v.proxy_device is not null then
    select * into d from public.messaging_devices where id = v.proxy_device and kind = 'gateway';
  end if;
  if d.id is null then
    return jsonb_build_object('ok', false, 'error', 'NO_PROXY_PHONE',
      'hint', 'The gateway phone this session key used was removed. A full admin adds a new key in Admin -> SMS / WhatsApp -> Session access.');
  end if;
  return jsonb_build_object('ok', true, 'device', d.id, 'label', d.label,
    'online', d.last_seen_at > now() - interval '3 minutes');
end;
$$;
