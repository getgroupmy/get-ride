-- ============================================================================
-- 0226: session access (Admin -> SMS / WhatsApp -> Session access).
--
-- A live, real-world test of the app runs in a Claude Code cloud session (or
-- any script) that has no phone and no SIM. A full admin gives such a session
-- a key of its own, scoped to one test phone number, that lets it:
--
--   sms    text that number through the gateway phone (support or marketing
--          messages, never sign-in codes) and see what went out and came in
--          for it;
--   codes  read the sign-in codes sent to that number, so the session can
--          sign the test account in by SMS and read the code the way the
--          phone would;
--   proxy  reach the internet through a gateway phone's mobile data, via the
--          relay at proxy.getride.my (cloudflare/session-proxy), so a request
--          leaves from a real Malaysian SIM instead of a data centre.
--
-- The key is shown once; only its hash is stored. It lasts the hours the
-- admin picks (a day by default, 30 days at most) and can be removed any
-- time from the same card. Only a full admin adds or removes one, because a
-- key with `codes` reads sign-in codes (0187 keeps those from sub-admins);
-- any admin sees the list. A key is 256 random bits, so wrong keys are not
-- rate limited the way pairing codes are (0190).
--
-- Every call below takes the key as its first argument and needs no sign-in,
-- like the gateway phone's own calls (0190): a session calls them with the
-- project's anon key. docs/session-access.md has the curl lines.
-- ============================================================================

create table if not exists public.session_keys (
  id           uuid primary key default gen_random_uuid(),
  label        text not null check (length(label) between 1 and 80),
  key_hash     text not null unique,
  test_phone   text not null check (test_phone ~ '^\+[1-9][0-9]{6,14}$'),
  scopes       text[] not null default '{sms,codes}'
               check (scopes <@ array['sms', 'codes', 'proxy']::text[] and coalesce(array_length(scopes, 1), 0) >= 1),
  proxy_device uuid references public.messaging_devices(id) on delete set null,
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  last_used_at timestamptz,
  uses         integer not null default 0
);
alter table public.session_keys enable row level security;
revoke all on public.session_keys from anon, authenticated;

create index if not exists session_keys_live_idx on public.session_keys (expires_at) where revoked_at is null;

-- The digits of a phone number, so '+60 12-345 6789' and '+60123456789' match.
create or replace function public.session_phone_digits(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
$$;
revoke execute on function public.session_phone_digits(text) from public, anon, authenticated;

-- ---- The key a call carries ---------------------------------------------------------------
-- The live key, or an error; with [p_scope], also that the key may do that.
-- Counts the use.
create or replace function public.session_by_key(p_key text, p_scope text default null)
returns public.session_keys
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.session_keys;
begin
  select * into v from public.session_keys
   where key_hash = public.gateway_secret_hash(p_key) and revoked_at is null and expires_at > now();
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

-- ---- The admin adds, lists and removes ------------------------------------------------------
create or replace function public.admin_session_key_create(
  p_label text,
  p_test_phone text,
  p_scopes text[] default '{sms,codes}',
  p_hours integer default 24,
  p_proxy_device uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_label text := nullif(left(btrim(coalesce(p_label, '')), 80), '');
  v_phone text := regexp_replace(coalesce(p_test_phone, ''), '[^0-9+]', '', 'g');
  v_scopes text[] := array(
    select distinct s from unnest(coalesce(p_scopes, '{}')) s where s in ('sms', 'codes', 'proxy') order by s);
  v_hours integer := greatest(1, least(coalesce(p_hours, 24), 24 * 30));
  v_device uuid;
  v_key text;
  v_row public.session_keys;
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can add a session.' using errcode = '42501';
  end if;
  if v_label is null then
    raise exception 'SESSION_KEY_LABEL' using errcode = '22023', hint = 'Give the session a name.';
  end if;
  if v_phone !~ '^\+[1-9][0-9]{6,14}$' then
    raise exception 'SESSION_KEY_PHONE' using errcode = '22023',
      hint = 'Enter the test phone number with its country code, e.g. +60123456789.';
  end if;
  if coalesce(array_length(v_scopes, 1), 0) = 0 then
    raise exception 'SESSION_KEY_SCOPES' using errcode = '22023', hint = 'Tick at least one thing the session may do.';
  end if;
  if 'proxy' = any(v_scopes) then
    select id into v_device from public.messaging_devices where id = p_proxy_device and kind = 'gateway';
    if v_device is null then
      raise exception 'SESSION_KEY_PROXY_DEVICE' using errcode = '22023',
        hint = 'Pick the gateway phone whose internet the session uses.';
    end if;
  end if;

  v_key := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.session_keys (label, key_hash, test_phone, scopes, proxy_device, created_by, expires_at)
  values (v_label, public.gateway_secret_hash(v_key), v_phone, v_scopes, v_device, auth.uid(),
          now() + make_interval(hours => v_hours))
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'key', v_key, 'expires_at', v_row.expires_at);
end;
$$;
revoke execute on function public.admin_session_key_create(text, text, text[], integer, uuid) from public, anon;
grant execute on function public.admin_session_key_create(text, text, text[], integer, uuid) to authenticated;

-- Every key, newest first, for the card (never the hash).
create or replace function public.admin_session_keys()
returns table (
  id uuid, label text, test_phone text, scopes text[], proxy_device uuid, proxy_label text,
  created_at timestamptz, expires_at timestamptz, revoked_at timestamptz, last_used_at timestamptz, uses integer)
language sql
stable
security definer
set search_path = public
as $$
  select k.id, k.label, k.test_phone, k.scopes, k.proxy_device, d.label,
         k.created_at, k.expires_at, k.revoked_at, k.last_used_at, k.uses
    from public.session_keys k
    left join public.messaging_devices d on d.id = k.proxy_device
   where public.caller_is_admin()
   order by k.created_at desc;
$$;
revoke execute on function public.admin_session_keys() from public, anon;
grant execute on function public.admin_session_keys() to authenticated;

create or replace function public.admin_session_key_revoke(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can remove a session.' using errcode = '42501';
  end if;
  update public.session_keys set revoked_at = now() where id = p_id and revoked_at is null;
end;
$$;
revoke execute on function public.admin_session_key_revoke(uuid) from public, anon;
grant execute on function public.admin_session_key_revoke(uuid) to authenticated;

-- ---- What the session does with its key ------------------------------------------------------
-- What this key is: its name, number, scopes, expiry and proxy phone.
create or replace function public.session_key_info(p_key text)
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

-- Queues an SMS to the key's test number; the gateway phone routed to the
-- channel sends it. Support or marketing only: a sign-in code is the
-- sign-in hook's to queue.
create or replace function public.session_key_send_sms(p_key text, p_body text, p_channel text default 'support_message')
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

-- What has been queued for the test number, newest first: the session's own
-- messages and, with `codes`, the sign-in codes in clear; without it a code
-- shows masked, as it does to a sub-admin (0183).
create or replace function public.session_key_outbox(p_key text, p_limit integer default 20)
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

-- SMS the gateway received from the test number, newest first (after
-- [p_since] when given).
create or replace function public.session_key_inbox(p_key text, p_since timestamptz default null, p_limit integer default 20)
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

-- The relay (cloudflare/session-proxy) asks which gateway phone carries this
-- key's internet, and whether that phone has checked in lately.
create or replace function public.session_key_proxy_check(p_key text)
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

-- The relay asks which gateway phone a device key belongs to, when the phone
-- connects to share its internet (no side effect beyond last_used_at).
create or replace function public.gateway_key_check(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dev public.messaging_devices := public.gateway_by_key(p_key);
begin
  return jsonb_build_object('id', v_dev.id, 'label', v_dev.label);
end;
$$;

revoke execute on function public.session_key_info(text) from public;
revoke execute on function public.session_key_send_sms(text, text, text) from public;
revoke execute on function public.session_key_outbox(text, integer) from public;
revoke execute on function public.session_key_inbox(text, timestamptz, integer) from public;
revoke execute on function public.session_key_proxy_check(text) from public;
revoke execute on function public.gateway_key_check(text) from public;
grant execute on function public.session_key_info(text) to anon, authenticated;
grant execute on function public.session_key_send_sms(text, text, text) to anon, authenticated;
grant execute on function public.session_key_outbox(text, integer) to anon, authenticated;
grant execute on function public.session_key_inbox(text, timestamptz, integer) to anon, authenticated;
grant execute on function public.session_key_proxy_check(text) to anon, authenticated;
grant execute on function public.gateway_key_check(text) to anon, authenticated;

-- Keys a month past their end go.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-session-keys';
    perform cron.schedule('purge-session-keys', '23 * * * *', $job$
      delete from public.session_keys
       where expires_at < now() - interval '30 days' or revoked_at < now() - interval '30 days';
    $job$);
  end if;
end $$;
