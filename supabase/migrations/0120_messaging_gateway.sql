-- 0120: SMS / WhatsApp routing (Admin → Settings → SMS / WhatsApp).
--
-- Which signed-in device carries each channel, each way:
--
--   channel    otp | marketing | support_call | support_message
--   direction  inbound | outbound
--   transport  sms (a gateway phone's SIM) | whatsapp (the Business Cloud
--              API number) | voip (the in-app support call)
--
-- messaging_devices  every device that can carry a channel, kept fresh by a
--                    heartbeat: the GET.ride Gateway app (Android, SMS) and
--                    admins' / support agents' app installs (VoIP).
-- messaging_routes   the admin's assignment: per channel and direction, the
--                    transport and the devices (several: the first online
--                    one sends; for a call, all of them ring).
-- sms_outbox         SMS waiting to go out. A gateway claims the jobs of the
--                    channels routed to it (gateway_claim_sms) and reports
--                    each one (gateway_report_sms).
-- sms_inbox          SMS the gateway received (gateway_receive_sms), filed
--                    under the inbound channel routed to that device.

-- ---- Devices -------------------------------------------------------------

create table if not exists public.messaging_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_id text not null check (length(device_id) between 1 and 200),
  label text check (label is null or length(label) <= 80),
  platform text check (platform is null or length(platform) <= 40),
  kind text not null default 'app' check (kind in ('app', 'gateway')),
  capabilities text[] not null default '{}',
  sim_number text check (sim_number is null or length(sim_number) <= 32),
  app_version text check (app_version is null or length(app_version) <= 40),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, device_id)
);

alter table public.messaging_devices enable row level security;

drop policy if exists "messaging_devices read" on public.messaging_devices;
create policy "messaging_devices read" on public.messaging_devices
  for select to authenticated using (user_id = auth.uid() or public.caller_is_admin());

drop policy if exists "messaging_devices admin update" on public.messaging_devices;
create policy "messaging_devices admin update" on public.messaging_devices
  for update to authenticated using (public.caller_is_admin()) with check (public.caller_is_admin());

drop policy if exists "messaging_devices delete" on public.messaging_devices;
create policy "messaging_devices delete" on public.messaging_devices
  for delete to authenticated using (user_id = auth.uid() or public.caller_is_admin());

grant select, update, delete on public.messaging_devices to authenticated;

-- A device says it is here (on launch, then every minute or so). Only the
-- gateway app may claim the SMS capability, and only for a gateway row.
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

revoke all on function public.messaging_heartbeat(text, text, text, text, text[], text, text) from public, anon;
grant execute on function public.messaging_heartbeat(text, text, text, text, text[], text, text) to authenticated;

-- ---- Routes --------------------------------------------------------------

create table if not exists public.messaging_routes (
  channel text not null check (channel in ('otp', 'marketing', 'support_call', 'support_message')),
  direction text not null check (direction in ('inbound', 'outbound')),
  transport text not null check (transport in ('sms', 'whatsapp', 'voip')),
  device_ids uuid[] not null default '{}',
  whatsapp_number text check (whatsapp_number is null or length(whatsapp_number) <= 32),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (channel, direction),
  -- A call is VoIP; a message is SMS or WhatsApp.
  check ((channel = 'support_call') = (transport = 'voip'))
);

alter table public.messaging_routes enable row level security;

drop policy if exists "messaging_routes read" on public.messaging_routes;
create policy "messaging_routes read" on public.messaging_routes
  for select to authenticated using (true);

drop policy if exists "messaging_routes admin write" on public.messaging_routes;
create policy "messaging_routes admin write" on public.messaging_routes
  for all to authenticated using (public.caller_is_admin()) with check (public.caller_is_admin());

grant select, insert, update, delete on public.messaging_routes to authenticated;

-- ---- SMS queue -----------------------------------------------------------

create table if not exists public.sms_outbox (
  id uuid primary key default gen_random_uuid(),
  channel text not null check (channel in ('otp', 'marketing', 'support_message')),
  to_phone text not null check (length(to_phone) between 3 and 32),
  body text not null check (length(body) between 1 and 1600),
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed')),
  device_id uuid references public.messaging_devices(id) on delete set null,
  attempts integer not null default 0,
  error text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz
);

create index if not exists sms_outbox_queue_idx on public.sms_outbox (status, channel, created_at);

alter table public.sms_outbox enable row level security;

drop policy if exists "sms_outbox admin read" on public.sms_outbox;
create policy "sms_outbox admin read" on public.sms_outbox
  for select to authenticated using (public.caller_is_admin());

-- Admins queue messages (a marketing blast, a test); the server queues OTPs.
drop policy if exists "sms_outbox admin queue" on public.sms_outbox;
create policy "sms_outbox admin queue" on public.sms_outbox
  for insert to authenticated with check (public.caller_is_admin() and status = 'queued' and device_id is null);

grant select, insert on public.sms_outbox to authenticated;

create table if not exists public.sms_inbox (
  id uuid primary key default gen_random_uuid(),
  device_id uuid references public.messaging_devices(id) on delete set null,
  channel text check (channel is null or channel in ('otp', 'marketing', 'support_message')),
  from_phone text not null check (length(from_phone) between 1 and 32),
  body text not null check (length(body) <= 1600),
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists sms_inbox_recent_idx on public.sms_inbox (created_at desc);

alter table public.sms_inbox enable row level security;

drop policy if exists "sms_inbox admin read" on public.sms_inbox;
create policy "sms_inbox admin read" on public.sms_inbox
  for select to authenticated using (public.caller_is_admin());

grant select on public.sms_inbox to authenticated;

-- The gateway device of the caller, or an error.
create or replace function public.messaging_own_gateway(p_device uuid)
  returns public.messaging_devices
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_dev public.messaging_devices;
begin
  select * into v_dev from public.messaging_devices
   where id = p_device and user_id = auth.uid() and kind = 'gateway' and 'sms' = any(capabilities);
  if not found then
    raise exception 'NOT_A_GATEWAY' using errcode = '42501';
  end if;
  return v_dev;
end;
$function$;

revoke all on function public.messaging_own_gateway(uuid) from public, anon, authenticated;

-- The next SMS jobs for this gateway: queued ones of the channels whose
-- outbound route is SMS through it (and jobs stuck "sending" on it for
-- over five minutes, which it is retrying). Marks them sending.
create or replace function public.gateway_claim_sms(p_device uuid, p_limit integer default 10)
  returns setof public.sms_outbox
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_dev public.messaging_devices := public.messaging_own_gateway(p_device);
begin
  update public.messaging_devices set last_seen_at = now() where id = v_dev.id;
  return query
  update public.sms_outbox o
     set status = 'sending', device_id = v_dev.id, claimed_at = now(), attempts = o.attempts + 1
   where o.id in (
     select q.id from public.sms_outbox q
      join public.messaging_routes r
        on r.channel = q.channel and r.direction = 'outbound'
       and r.transport = 'sms' and r.enabled and v_dev.id = any(r.device_ids)
      where (q.status = 'queued'
             or (q.status = 'sending' and q.device_id = v_dev.id and q.claimed_at < now() - interval '5 minutes'))
        and q.attempts < 3
      order by q.created_at
      limit greatest(1, least(coalesce(p_limit, 10), 50))
      for update of q skip locked
   )
  returning o.*;
end;
$function$;

revoke all on function public.gateway_claim_sms(uuid, integer) from public, anon;
grant execute on function public.gateway_claim_sms(uuid, integer) to authenticated;

-- How a claimed job went. A failure goes back to the queue until it has
-- been tried three times.
create or replace function public.gateway_report_sms(p_device uuid, p_id uuid, p_ok boolean, p_error text default null)
  returns void
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_dev public.messaging_devices := public.messaging_own_gateway(p_device);
begin
  update public.sms_outbox
     set status = case when p_ok then 'sent' when attempts >= 3 then 'failed' else 'queued' end,
         sent_at = case when p_ok then now() else null end,
         error = case when p_ok then null else left(p_error, 500) end,
         device_id = case when p_ok or attempts >= 3 then device_id else null end
   where id = p_id and device_id = v_dev.id and status = 'sending';
end;
$function$;

revoke all on function public.gateway_report_sms(uuid, uuid, boolean, text) from public, anon;
grant execute on function public.gateway_report_sms(uuid, uuid, boolean, text) to authenticated;

-- An SMS the gateway received, filed under the inbound SMS channel routed
-- to it (none when it carries no inbound channel, or several).
create or replace function public.gateway_receive_sms(p_device uuid, p_from text, p_body text, p_received_at timestamptz default now())
  returns public.sms_inbox
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_dev public.messaging_devices := public.messaging_own_gateway(p_device);
  v_channels text[];
  v_row public.sms_inbox;
begin
  select array_agg(channel) into v_channels from public.messaging_routes
   where direction = 'inbound' and transport = 'sms' and enabled and v_dev.id = any(device_ids);
  insert into public.sms_inbox (device_id, channel, from_phone, body, received_at)
  values (v_dev.id,
          case when coalesce(array_length(v_channels, 1), 0) = 1 then v_channels[1] end,
          left(p_from, 32), left(p_body, 1600), coalesce(p_received_at, now()))
  returning * into v_row;
  return v_row;
end;
$function$;

revoke all on function public.gateway_receive_sms(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.gateway_receive_sms(uuid, text, text, timestamptz) to authenticated;

-- ---- Realtime --------------------------------------------------------------
-- The admin page follows devices, routes and the queue live; RLS still
-- decides what each subscriber receives.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['messaging_devices', 'messaging_routes', 'sms_outbox', 'sms_inbox'] loop
      if not exists (
        select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
