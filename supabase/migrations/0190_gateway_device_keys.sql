-- ============================================================================
-- 0190: the gateway phone runs without a sign-in.
--
-- The gateway app used an admin's account session. When the session's token
-- lapsed while the phone was in the background, the gateway stopped ("You
-- were signed out") and SMS waited until someone signed in again.
--
-- Now a full admin pairs the phone once: Admin -> SMS / WhatsApp -> "Pair a
-- gateway phone" gives a code good for 10 minutes; the gateway app takes it
-- and gets a device key of its own. The key never expires; removing the
-- device in Admin ends it. Only a hash of the key is stored.
--
-- Only a full admin pairs, because a gateway sends sign-in codes (0187 keeps
-- those from sub-admins). The signed-in functions stay for older gateways.
-- ============================================================================

-- ---- Keys and pairing codes ----------------------------------------------------------------
create table if not exists public.gateway_keys (
  device_row   uuid primary key references public.messaging_devices(id) on delete cascade,
  key_hash     text not null unique,
  paired_by    uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);
alter table public.gateway_keys enable row level security;
revoke all on public.gateway_keys from anon, authenticated;

create table if not exists public.gateway_pairings (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,
  created_by  uuid not null references auth.users(id) on delete cascade,
  label       text,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  device_row  uuid references public.messaging_devices(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.gateway_pairings enable row level security;
revoke all on public.gateway_pairings from anon, authenticated;

-- Wrong codes, to slow down guessing.
create table if not exists public.gateway_pair_failures (
  at timestamptz not null default now()
);
create index if not exists gateway_pair_failures_at_idx on public.gateway_pair_failures (at);
alter table public.gateway_pair_failures enable row level security;
revoke all on public.gateway_pair_failures from anon, authenticated;

create or replace function public.gateway_secret_hash(p_secret text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(extensions.digest(convert_to(coalesce(p_secret, ''), 'UTF8'), 'sha256'), 'hex');
$$;
revoke execute on function public.gateway_secret_hash(text) from public, anon, authenticated;

-- ---- The admin makes a pairing code ----------------------------------------------------------
-- 8 characters from an alphabet without look-alikes, shown as XXXX-XXXX.
create or replace function public.admin_gateway_pairing_code(p_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(8);
  v_code text := '';
  v_expires timestamptz := now() + interval '10 minutes';
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can pair a gateway phone.' using errcode = '42501';
  end if;
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % length(v_alphabet)), 1);
  end loop;
  -- Unused codes of this admin's go: one live code at a time.
  delete from public.gateway_pairings where created_by = auth.uid() and used_at is null;
  insert into public.gateway_pairings (code_hash, created_by, label, expires_at)
  values (public.gateway_secret_hash(v_code), auth.uid(), nullif(left(btrim(coalesce(p_label, '')), 80), ''), v_expires);
  return jsonb_build_object('code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4), 'expires_at', v_expires);
end;
$$;
revoke execute on function public.admin_gateway_pairing_code(text) from public, anon;
grant execute on function public.admin_gateway_pairing_code(text) to authenticated;

-- ---- The gateway pairs: code in, device key out (once) ---------------------------------------
create or replace function public.gateway_pair(
  p_code text, p_device_id text, p_label text default null, p_sim_number text default null,
  p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_pair public.gateway_pairings;
  v_dev public.messaging_devices;
  v_key text;
begin
  if (select count(*) from public.gateway_pair_failures where at > now() - interval '10 minutes') >= 20 then
    raise exception 'GATEWAY_PAIR_BUSY' using errcode = 'P0001',
      hint = 'Too many wrong codes. Wait 10 minutes and try again.';
  end if;
  if coalesce(btrim(p_device_id), '') = '' then
    raise exception 'GATEWAY_PAIR_DEVICE' using errcode = '22023';
  end if;

  select * into v_pair from public.gateway_pairings
   where code_hash = public.gateway_secret_hash(v_code) and used_at is null and expires_at > now()
   for update;
  if not found then
    -- Answered, not raised, so the failure is kept for the limit above.
    insert into public.gateway_pair_failures default values;
    return jsonb_build_object('error', 'GATEWAY_PAIR_CODE',
      'hint', 'That code is wrong or has expired. Make a new one in Admin -> SMS / WhatsApp.');
  end if;

  insert into public.messaging_devices
    (user_id, device_id, label, platform, kind, capabilities, sim_number, app_version, last_seen_at)
  values
    (v_pair.created_by, left(p_device_id, 200), coalesce(v_pair.label, left(p_label, 80)), 'android', 'gateway',
     array['sms'], left(p_sim_number, 32), left(p_app_version, 40), now())
  on conflict (user_id, device_id) do update
     set label = coalesce(v_pair.label, public.messaging_devices.label, excluded.label),
         kind = 'gateway',
         capabilities = array['sms'],
         sim_number = coalesce(excluded.sim_number, public.messaging_devices.sim_number),
         app_version = excluded.app_version,
         last_seen_at = now()
  returning * into v_dev;

  v_key := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.gateway_keys (device_row, key_hash, paired_by)
  values (v_dev.id, public.gateway_secret_hash(v_key), v_pair.created_by)
  on conflict (device_row) do update
     set key_hash = excluded.key_hash, paired_by = excluded.paired_by, created_at = now(), last_used_at = null;

  update public.gateway_pairings set used_at = now(), device_row = v_dev.id where id = v_pair.id;
  return jsonb_build_object('key', v_key, 'device', v_dev.id, 'label', v_dev.label);
end;
$$;
revoke execute on function public.gateway_pair(text, text, text, text, text) from public;
grant execute on function public.gateway_pair(text, text, text, text, text) to anon, authenticated;

-- The device a key belongs to; refuses an unknown (or removed) key.
create or replace function public.gateway_by_key(p_key text)
returns public.messaging_devices
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dev public.messaging_devices;
begin
  select d.* into v_dev
    from public.gateway_keys k join public.messaging_devices d on d.id = k.device_row
   where k.key_hash = public.gateway_secret_hash(p_key) and d.kind = 'gateway';
  if not found then
    raise exception 'GATEWAY_KEY_INVALID' using errcode = '42501',
      hint = 'This phone is no longer paired. Pair it again from Admin -> SMS / WhatsApp.';
  end if;
  update public.gateway_keys set last_used_at = now()
   where device_row = v_dev.id and (last_used_at is null or last_used_at < now() - interval '1 minute');
  return v_dev;
end;
$$;
revoke execute on function public.gateway_by_key(text) from public, anon, authenticated;

-- ---- The work, by device (shared by the signed-in and the keyed calls) -----------------------
create or replace function public.gateway_claim_for(p_dev uuid, p_limit integer)
returns setof public.sms_outbox
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.messaging_devices set last_seen_at = now() where id = p_dev;

  -- A sign-in code is good for the admin's minutes: one still waiting after
  -- that is failed, not sent.
  update public.sms_outbox
     set status = 'failed', error = 'expired before sending'
   where channel = 'otp' and status in ('queued', 'sending')
     and created_at < now() - make_interval(mins => coalesce(
           (select code_valid_minutes from public.sms_settings where id = 1), 5));

  return query
  with claimed as (
    update public.sms_outbox o
       set status = 'sending', device_id = p_dev, claimed_at = now(), attempts = o.attempts + 1
     where o.id in (
       select q.id from public.sms_outbox q
        join public.messaging_routes r
          on r.channel = q.channel and r.direction = 'outbound'
         and r.transport = 'sms' and r.enabled and p_dev = any(r.device_ids)
        where (q.status = 'queued'
               or (q.status = 'sending' and q.device_id = p_dev and q.claimed_at < now() - interval '5 minutes'))
          and q.attempts < 3
        order by q.created_at
        limit greatest(1, least(coalesce(p_limit, 10), 50))
        for update of q skip locked
     )
    returning o.*
  )
  select (jsonb_populate_record(null::public.sms_outbox,
            to_jsonb(c) || jsonb_build_object('body', coalesce(s.body, c.body)))).*
    from claimed c
    left join public.sms_otp_secret s on s.outbox_id = c.id;
end;
$$;
revoke execute on function public.gateway_claim_for(uuid, integer) from public, anon, authenticated;

create or replace function public.gateway_report_for(p_dev uuid, p_id uuid, p_ok boolean, p_error text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.sms_outbox
     set status = case when p_ok then 'sent' when attempts >= 3 then 'failed' else 'queued' end,
         sent_at = case when p_ok then now() else null end,
         error = case when p_ok then null else left(p_error, 500) end,
         device_id = case when p_ok or attempts >= 3 then device_id else null end
   where id = p_id and device_id = p_dev and status = 'sending';
$$;
revoke execute on function public.gateway_report_for(uuid, uuid, boolean, text) from public, anon, authenticated;

create or replace function public.gateway_receive_for(p_dev uuid, p_from text, p_body text, p_received_at timestamptz)
returns public.sms_inbox
language plpgsql
security definer
set search_path = public
as $$
declare
  v_channels text[];
  v_row public.sms_inbox;
begin
  select array_agg(channel) into v_channels from public.messaging_routes
   where direction = 'inbound' and transport = 'sms' and enabled and p_dev = any(device_ids);
  insert into public.sms_inbox (device_id, channel, from_phone, body, received_at)
  values (p_dev,
          case when coalesce(array_length(v_channels, 1), 0) = 1 then v_channels[1] end,
          left(p_from, 32), left(p_body, 1600), coalesce(p_received_at, now()))
  returning * into v_row;
  return v_row;
end;
$$;
revoke execute on function public.gateway_receive_for(uuid, text, text, timestamptz) from public, anon, authenticated;

-- The signed-in calls (older gateway apps) now share that work.
create or replace function public.gateway_claim_sms(p_device uuid, p_limit integer default 10)
returns setof public.sms_outbox
language plpgsql
security definer
set search_path = public
as $$
begin
  return query select * from public.gateway_claim_for((public.messaging_own_gateway(p_device)).id, p_limit);
end;
$$;

create or replace function public.gateway_report_sms(p_device uuid, p_id uuid, p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.gateway_report_for((public.messaging_own_gateway(p_device)).id, p_id, p_ok, p_error);
end;
$$;

create or replace function public.gateway_receive_sms(
  p_device uuid, p_from text, p_body text, p_received_at timestamptz default now())
returns public.sms_inbox
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.gateway_receive_for((public.messaging_own_gateway(p_device)).id, p_from, p_body, p_received_at);
end;
$$;

-- ---- The keyed calls -------------------------------------------------------------------------
create or replace function public.gateway_key_heartbeat(
  p_key text, p_label text default null, p_sim_number text default null, p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dev public.messaging_devices := public.gateway_by_key(p_key);
begin
  update public.messaging_devices
     set label = coalesce(label, left(p_label, 80)),
         sim_number = coalesce(left(p_sim_number, 32), sim_number),
         app_version = coalesce(left(p_app_version, 40), app_version),
         last_seen_at = now()
   where id = v_dev.id
  returning * into v_dev;
  return jsonb_build_object('id', v_dev.id, 'label', v_dev.label);
end;
$$;

create or replace function public.gateway_key_claim(p_key text, p_limit integer default 10)
returns setof public.sms_outbox
language plpgsql
security definer
set search_path = public
as $$
begin
  return query select * from public.gateway_claim_for((public.gateway_by_key(p_key)).id, p_limit);
end;
$$;

create or replace function public.gateway_key_report(p_key text, p_id uuid, p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.gateway_report_for((public.gateway_by_key(p_key)).id, p_id, p_ok, p_error);
end;
$$;

create or replace function public.gateway_key_receive(
  p_key text, p_from text, p_body text, p_received_at timestamptz default now())
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.gateway_receive_for((public.gateway_by_key(p_key)).id, p_from, p_body, p_received_at);
end;
$$;

revoke execute on function public.gateway_key_heartbeat(text, text, text, text) from public;
revoke execute on function public.gateway_key_claim(text, integer) from public;
revoke execute on function public.gateway_key_report(text, uuid, boolean, text) from public;
revoke execute on function public.gateway_key_receive(text, text, text, timestamptz) from public;
grant execute on function public.gateway_key_heartbeat(text, text, text, text) to anon, authenticated;
grant execute on function public.gateway_key_claim(text, integer) to anon, authenticated;
grant execute on function public.gateway_key_report(text, uuid, boolean, text) to anon, authenticated;
grant execute on function public.gateway_key_receive(text, text, text, timestamptz) to anon, authenticated;

-- Which gateways are paired (for the admin's device list).
create or replace function public.admin_gateway_keys()
returns table (device_row uuid, created_at timestamptz, last_used_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select k.device_row, k.created_at, k.last_used_at from public.gateway_keys k where public.caller_is_admin();
$$;
revoke execute on function public.admin_gateway_keys() from public, anon;
grant execute on function public.admin_gateway_keys() to authenticated;

-- Old pairing codes and failures go.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-gateway-pairings';
    perform cron.schedule('purge-gateway-pairings', '17 * * * *', $job$
      delete from public.gateway_pairings where expires_at < now() - interval '1 day';
      delete from public.gateway_pair_failures where at < now() - interval '1 day';
    $job$);
  end if;
end $$;
