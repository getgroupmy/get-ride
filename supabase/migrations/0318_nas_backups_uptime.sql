-- ============================================================================
-- 0318 — Office NAS, part N1: nightly backups with a monthly restore test,
-- and an uptime monitor with alerts (docs/NAS.md items 1 and 3; docs/KIV.md
-- "Synology DS224+").
--
-- Version 20261028110000 (0318_nas_backups_uptime). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first, seed rows only where missing.
--
-- get.ride keeps working when the NAS is off: everything here is a side job.
-- The NAS app (deploy/nas-backup) only calls out, to the nas-ops edge
-- function, with a key of its own; the database's connection string and the
-- storage service key stay in the NAS's .env and are never sent here.
--
-- 1. nas_services: one row per NAS service (backup, uptime, box, and the
--    other NAS apps), its last check-in, status and details. The shared
--    heartbeat table of the NAS batches (same columns in each).
-- 2. Pairing, as the document reader does (0293): a full admin makes a code
--    good for 10 minutes (admin_nas_ops_pairing_code); the NAS app trades it
--    once for a key (nas_ops_pair); only the key's hash is kept
--    (nas_ops_agents). Disconnecting it in Admin ends the key.
-- 3. office_nas_settings ('backup', 'uptime'): admins only (phone numbers,
--    emails and chat ids live here), written through the admin RPCs below
--    with an EDIT grant on admin-settings-office-nas (admin_table_pages).
--    backup: on, the time and time zone, nightly and monthly copies kept,
--    the buckets left out, the monthly restore test (on, day), the off-site
--    copy (where, and the last copy's date when the NAS can't tell).
--    uptime: alert after N failed checks in a row, how often the NAS and the
--    cloud check, "slow" from, a gateway phone's late and down minutes, the
--    channels (admin app push, Telegram, WhatsApp/SMS, email) each switchable,
--    and where each sends.
-- 4. Backups: "Back up now" and "Run a restore test" (nas_backup_requests)
--    are handed to the NAS at its next check-in; backup_runs keeps every run
--    (started, finished, database and file sizes, files, status, error). A
--    failed backup or restore test alerts.
-- 5. Uptime: uptime_targets (editable; seeded with getride.my, the admin, the
--    server functions, the database, the SMS gateway phones, the payment
--    gateway, the office NAS and last night's backup), checked from the NAS
--    and from the cloud (pg_cron every minute, as due, through the
--    uptime-check edge function), so a dead NAS is still reported.
--    uptime_checks keeps 7 days of checks; uptime_daily the counts for the
--    30-day uptime. uptime_record keeps a streak per target and source;
--    N failed checks in a row from any source opens an incident and alerts;
--    every fresh source back up resolves it ("resolved" message).
-- 6. Alerts (uptime_alerts): admin app push to full admins and WhatsApp/SMS
--    (the ops_alert channel of the SMS gateway, 0193/0269) go out from here;
--    Telegram (bot token in Admin > API Keys > Telegram) and email (Resend)
--    from the uptime-check function, which the database wakes.
-- ============================================================================

-- ---- 1. NAS service heartbeat (shared by the NAS batches) --------------------------------------
create table if not exists public.nas_services (
  service   text primary key,
  last_seen timestamptz,
  status    text,
  detail    jsonb,
  version   text
);
alter table public.nas_services enable row level security;
revoke all on public.nas_services from anon, authenticated;
grant select on public.nas_services to authenticated;
drop policy if exists "nas_services admin read" on public.nas_services;
create policy "nas_services admin read" on public.nas_services
  for select to authenticated using ((select public.caller_is_admin()));

-- ---- 2. The NAS app, its key and pairing codes --------------------------------------------------
create table if not exists public.nas_ops_agents (
  id           uuid primary key default gen_random_uuid(),
  label        text not null,
  device_id    text not null unique,
  model        text,
  app_version  text,
  key_hash     text not null unique,
  paired_by    uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz
);
alter table public.nas_ops_agents enable row level security;
revoke all on public.nas_ops_agents from anon, authenticated;

create table if not exists public.nas_ops_pairings (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,
  label       text,
  created_by  uuid not null references auth.users(id) on delete cascade,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  agent_id    uuid references public.nas_ops_agents(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.nas_ops_pairings enable row level security;
revoke all on public.nas_ops_pairings from anon, authenticated;

create table if not exists public.nas_ops_pair_failures (
  at timestamptz not null default now()
);
create index if not exists nas_ops_pair_failures_at_idx on public.nas_ops_pair_failures (at);
alter table public.nas_ops_pair_failures enable row level security;
revoke all on public.nas_ops_pair_failures from anon, authenticated;

-- ---- 3. Settings ----------------------------------------------------------------------------------
create table if not exists public.office_nas_settings (
  key        text primary key check (key in ('backup', 'uptime')),
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
alter table public.office_nas_settings enable row level security;
revoke all on public.office_nas_settings from anon, authenticated;

-- A whole number from jsonb, clamped; the default when missing or not a number.
create or replace function public.office_nas_int(p jsonb, p_default integer, p_min integer, p_max integer)
returns integer
language sql
immutable
set search_path = public
as $$
  select greatest(p_min, least(p_max,
    case when jsonb_typeof(p) = 'number' then round((p #>> '{}')::numeric)::integer
         when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^\s*-?\d+(\.\d+)?\s*$'
           then round(btrim(p #>> '{}')::numeric)::integer
         else p_default end));
$$;
revoke execute on function public.office_nas_int(jsonb, integer, integer, integer) from public, anon, authenticated;

-- A list of short, unique, non-empty strings (at most p_max of them).
create or replace function public.office_nas_strings(p jsonb, p_max integer default 20, p_len integer default 120)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce(jsonb_agg(s order by n), '[]'::jsonb)
    from (
      select s, min(n) as n
        from (select left(btrim(e.v), p_len) as s, e.n
                from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end)
                     with ordinality as e(v, n)
               where btrim(e.v) <> '') x
       group by s
       order by min(n)
       limit p_max
    ) y;
$$;
revoke execute on function public.office_nas_strings(jsonb, integer, integer) from public, anon, authenticated;

-- Backup settings, the shape lib/src/core/office_nas.dart keeps too.
create or replace function public.nas_backup_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := coalesce(p, '{}'::jsonb);
  v_at text := coalesce(v ->> 'at', '');
  v_tz text := nullif(btrim(coalesce(v ->> 'timezone', '')), '');
  v_rt jsonb := case when jsonb_typeof(v -> 'restoreTest') = 'object' then v -> 'restoreTest' else '{}'::jsonb end;
  v_off jsonb := case when jsonb_typeof(v -> 'offsite') = 'object' then v -> 'offsite' else '{}'::jsonb end;
  v_where text := coalesce(v_off ->> 'where', '');
  v_last text := coalesce(v_off ->> 'lastCopyOn', '');
begin
  if v_at !~ '^([01]\d|2[0-3]):[0-5]\d$' then
    v_at := '02:00';
  end if;
  if v_tz is null or v_tz !~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$' then
    v_tz := 'Asia/Kuala_Lumpur';
  end if;
  if v_where not in ('b2', 'c2', 'other', 'none') then
    v_where := 'none';
  end if;
  if v_last !~ '^\d{4}-\d{2}-\d{2}$' then
    v_last := null;
  end if;
  return jsonb_build_object(
    'on', coalesce((v ->> 'on')::boolean, true),
    'at', v_at,
    'timezone', v_tz,
    'keepNightly', public.office_nas_int(v -> 'keepNightly', 30, 1, 365),
    'keepMonthly', public.office_nas_int(v -> 'keepMonthly', 12, 0, 120),
    'skipBuckets', public.office_nas_strings(v -> 'skipBuckets', 50, 100),
    'restoreTest', jsonb_build_object(
      'on', coalesce((v_rt ->> 'on')::boolean, true),
      'day', public.office_nas_int(v_rt -> 'day', 1, 1, 28)),
    'offsite', jsonb_build_object(
      'where', v_where,
      'lastCopyOn', v_last));
end;
$$;
revoke execute on function public.nas_backup_normalize(jsonb) from public, anon, authenticated;

-- Uptime settings, the shape lib/src/core/office_nas.dart keeps too.
create or replace function public.nas_uptime_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := coalesce(p, '{}'::jsonb);
  v_ch jsonb := case when jsonb_typeof(v -> 'channels') = 'object' then v -> 'channels' else '{}'::jsonb end;
  v_late integer := public.office_nas_int(v -> 'gatewayLateMinutes', 3, 1, 120);
  v_from text := nullif(left(btrim(coalesce(v ->> 'emailFrom', '')), 200), '');
begin
  return jsonb_build_object(
    'failAfter', public.office_nas_int(v -> 'failAfter', 2, 1, 10),
    'nasEveryMinutes', public.office_nas_int(v -> 'nasEveryMinutes', 1, 1, 60),
    'cloudEveryMinutes', public.office_nas_int(v -> 'cloudEveryMinutes', 5, 1, 60),
    'slowMs', public.office_nas_int(v -> 'slowMs', 3000, 200, 30000),
    'gatewayLateMinutes', v_late,
    'gatewayDownMinutes', greatest(v_late + 1, public.office_nas_int(v -> 'gatewayDownMinutes', 10, 2, 240)),
    'channels', jsonb_build_object(
      'push', coalesce((v_ch ->> 'push')::boolean, true),
      'telegram', coalesce((v_ch ->> 'telegram')::boolean, false),
      'sms', coalesce((v_ch ->> 'sms')::boolean, false),
      'email', coalesce((v_ch ->> 'email')::boolean, false)),
    'telegramChats', public.office_nas_strings(v -> 'telegramChats', 10, 40),
    'smsNumbers', public.office_nas_strings(v -> 'smsNumbers', 10, 32),
    'emails', public.office_nas_strings(v -> 'emails', 20, 200),
    'emailFrom', v_from);
end;
$$;
revoke execute on function public.nas_uptime_normalize(jsonb) from public, anon, authenticated;

create or replace function public.nas_backup_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.nas_backup_normalize((select value from public.office_nas_settings where key = 'backup'));
$$;
revoke execute on function public.nas_backup_config() from public, anon, authenticated;

create or replace function public.nas_uptime_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.nas_uptime_normalize((select value from public.office_nas_settings where key = 'uptime'));
$$;
revoke execute on function public.nas_uptime_config() from public, anon, authenticated;
grant execute on function public.nas_uptime_config() to service_role;

-- ---- 4. Backups ---------------------------------------------------------------------------------
create table if not exists public.backup_runs (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('backup', 'restore_test')),
  trigger      text not null default 'schedule' check (trigger in ('schedule', 'manual')),
  agent_id     uuid references public.nas_ops_agents(id) on delete set null,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running' check (status in ('running', 'ok', 'failed')),
  db_bytes     bigint,
  files        integer,
  files_bytes  bigint,
  total_bytes  bigint,
  error        text,
  detail       jsonb not null default '{}'::jsonb
);
create index if not exists backup_runs_started_idx on public.backup_runs (kind, started_at desc);
alter table public.backup_runs enable row level security;
revoke all on public.backup_runs from anon, authenticated;
grant select on public.backup_runs to authenticated;
drop policy if exists "backup_runs admin read" on public.backup_runs;
create policy "backup_runs admin read" on public.backup_runs
  for select to authenticated using ((select public.caller_is_admin()));

create table if not exists public.nas_backup_requests (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('backup', 'restore_test')),
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  taken_at     timestamptz,
  run_id       uuid references public.backup_runs(id) on delete set null
);
create index if not exists nas_backup_requests_open_idx on public.nas_backup_requests (requested_at) where taken_at is null;
alter table public.nas_backup_requests enable row level security;
revoke all on public.nas_backup_requests from anon, authenticated;

-- ---- 5. Uptime ----------------------------------------------------------------------------------
-- kind  http      GET the url ({project} = the backend's address; {payment} =
--                 the payment gateway in use); up when it answers below 500
--       database  a query (the cloud: through the API; the NAS: straight
--                 to the database with its own connection string)
--       gateways  each SMS gateway phone, from when it last checked in
--       nas       the office NAS, from its last check-in (cloud only)
--       backup    a backup that finished OK in the last 26 hours (cloud only)
create table if not exists public.uptime_targets (
  id         text primary key check (id ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  name       text not null check (char_length(name) between 1 and 80),
  kind       text not null check (kind in ('http', 'database', 'gateways', 'nas', 'backup')),
  url        text check (url is null or char_length(url) <= 500),
  on_off     boolean not null default true,
  from_nas   boolean not null default true,
  from_cloud boolean not null default true,
  slow_ms    integer check (slow_ms is null or slow_ms between 100 and 60000),
  position   integer not null default 0,
  builtin    boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.uptime_targets enable row level security;
revoke all on public.uptime_targets from anon, authenticated;
grant select on public.uptime_targets to authenticated;
drop policy if exists "uptime_targets admin read" on public.uptime_targets;
create policy "uptime_targets admin read" on public.uptime_targets
  for select to authenticated using ((select public.caller_is_admin()));

insert into public.uptime_targets (id, name, kind, url, from_nas, from_cloud, position, builtin) values
  ('website',   'getride.my',       'http',     'https://getride.my',                              true,  true,  10, true),
  ('admin',     'Admin',            'http',     'https://getride.my/admin',                        true,  true,  20, true),
  ('functions', 'Server functions', 'http',     '{project}/functions/v1/uptime-check?ping=1',      true,  true,  30, true),
  ('database',  'Database',         'database', null,                                              true,  true,  40, true),
  ('gateways',  'SMS gateway phones', 'gateways', null,                                            false, true,  50, true),
  ('payment',   'Payment gateway',  'http',     '{payment}',                                       true,  true,  60, true),
  ('nas',       'Office NAS',       'nas',      null,                                              false, true,  70, true),
  ('backup',    'Last night''s backup', 'backup', null,                                            false, true,  80, true)
on conflict (id) do nothing;

-- target_id: a target's id, or gateway:<device id> for one gateway phone.
create table if not exists public.uptime_checks (
  id         bigint generated always as identity primary key,
  target_id  text not null,
  source     text not null check (source in ('nas', 'cloud')),
  checked_at timestamptz not null default now(),
  status     text not null check (status in ('up', 'slow', 'down')),
  ms         integer,
  detail     text
);
create index if not exists uptime_checks_target_idx on public.uptime_checks (target_id, checked_at desc);
create index if not exists uptime_checks_at_idx on public.uptime_checks (checked_at);
alter table public.uptime_checks enable row level security;
revoke all on public.uptime_checks from anon, authenticated;

create table if not exists public.uptime_daily (
  target_id text not null,
  day       date not null,
  checks    integer not null default 0,
  up        integer not null default 0,
  primary key (target_id, day)
);
alter table public.uptime_daily enable row level security;
revoke all on public.uptime_daily from anon, authenticated;

create table if not exists public.uptime_state (
  target_id   text not null,
  source      text not null check (source in ('nas', 'cloud')),
  streak      integer not null default 0,
  last_status text,
  last_ms     integer,
  last_detail text,
  last_at     timestamptz,
  primary key (target_id, source)
);
alter table public.uptime_state enable row level security;
revoke all on public.uptime_state from anon, authenticated;

create table if not exists public.uptime_incidents (
  id          uuid primary key default gen_random_uuid(),
  target_id   text not null,
  name        text not null,
  started_at  timestamptz not null default now(),
  resolved_at timestamptz,
  detail      text
);
create unique index if not exists uptime_incidents_open_idx on public.uptime_incidents (target_id) where resolved_at is null;
alter table public.uptime_incidents enable row level security;
revoke all on public.uptime_incidents from anon, authenticated;

-- telegram / email: 'pending' (the function sends it), 'sent', 'failed: …',
-- or 'off' (switched off or nowhere to send).
create table if not exists public.uptime_alerts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('down', 'resolved', 'backup_failed', 'restore_failed', 'test')),
  target_id   text,
  title       text not null,
  body        text not null,
  created_at  timestamptz not null default now(),
  push_count  integer not null default 0,
  sms_count   integer not null default 0,
  telegram    text not null default 'off',
  email       text not null default 'off',
  tries       integer not null default 0
);
create index if not exists uptime_alerts_created_idx on public.uptime_alerts (created_at desc);
create index if not exists uptime_alerts_pending_idx on public.uptime_alerts (created_at)
  where telegram = 'pending' or email = 'pending';
alter table public.uptime_alerts enable row level security;
revoke all on public.uptime_alerts from anon, authenticated;

-- ---- 6. Alerts ----------------------------------------------------------------------------------
-- Wakes the uptime-check function (Telegram and email, or a cloud check
-- round) with the push webhook's Vault secret, as ai_report_email_kick
-- (0280) does. False when it could not be queued.
create or replace function public.uptime_kick(p_body jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return false;
  end;
  if v_url is null or v_secret is null then
    return false;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/uptime-check',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := coalesce(p_body, '{}'::jsonb),
    timeout_milliseconds := 60000
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.uptime_kick(jsonb) from public, anon, authenticated;

-- One alert: admin app push to the full admins and WhatsApp/SMS go out now;
-- Telegram and email are left 'pending' for the uptime-check function.
-- Never stands in the way of what called it. The alert's id, or null.
create or replace function public.uptime_alert(p_kind text, p_target text, p_title text, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.nas_uptime_config();
  v_id uuid;
  v_push integer := 0;
  v_sms integer := 0;
  v_to uuid;
  v_num text;
  v_title text := left(coalesce(p_title, 'get.ride monitor'), 120);
  v_body text := left(coalesce(p_body, ''), 600);
begin
  begin
    insert into public.uptime_alerts (kind, target_id, title, body, telegram, email)
    values (p_kind, p_target, v_title, v_body,
            case when (c #>> '{channels,telegram}')::boolean and jsonb_array_length(c -> 'telegramChats') > 0
                 then 'pending' else 'off' end,
            case when (c #>> '{channels,email}')::boolean and jsonb_array_length(c -> 'emails') > 0
                 then 'pending' else 'off' end)
    returning id into v_id;

    if (c #>> '{channels,push}')::boolean then
      for v_to in
        select distinct a.profile_id from public.admin_access a
         where a.page = '*' and exists (select 1 from public.profiles p where p.id = a.profile_id)
      loop
        perform public.enqueue_notification(v_to, 'uptime-' || v_id || '-' || v_to, 'office_nas',
          case when p_kind in ('down', 'backup_failed', 'restore_failed') then 'critical' else 'normal' end,
          v_title, v_body,
          jsonb_build_object('type', 'office_nas', 'alert_id', v_id, 'route', '/admin/m/office-nas?tab=uptime'),
          null);
        v_push := v_push + 1;
      end loop;
    end if;

    if (c #>> '{channels,sms}')::boolean then
      for v_num in select jsonb_array_elements_text(c -> 'smsNumbers') loop
        insert into public.sms_outbox (to_phone, body, channel)
        values (left(v_num, 32), left('get.ride monitor: ' || v_title || '. ' || v_body, 1600), 'ops_alert');
        v_sms := v_sms + 1;
      end loop;
    end if;

    update public.uptime_alerts set push_count = v_push, sms_count = v_sms where id = v_id;
    if exists (select 1 from public.uptime_alerts where id = v_id and (telegram = 'pending' or email = 'pending')) then
      perform public.uptime_kick(jsonb_build_object('action', 'flush'));
    end if;
  exception when others then
    raise warning 'uptime_alert: %', sqlerrm;
  end;
  return v_id;
end;
$$;
revoke execute on function public.uptime_alert(text, text, text, text) from public, anon, authenticated;

-- What the uptime-check function still has to send, and where to. The
-- sender: the monitor's own, else Admin > Reports' (0280).
create or replace function public.uptime_alerts_due()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.nas_uptime_config();
  v_from text := c ->> 'emailFrom';
begin
  if v_from is null then
    begin
      execute 'select email_from from public.ai_report_settings limit 1' into v_from;
    exception when others then
      v_from := null;
    end;
  end if;
  -- After 5 tries, or a day, an alert is given up on.
  update public.uptime_alerts
     set telegram = case when telegram = 'pending' then 'failed: gave up' else telegram end,
         email = case when email = 'pending' then 'failed: gave up' else email end
   where (telegram = 'pending' or email = 'pending')
     and (tries >= 5 or created_at < now() - interval '1 day');
  return jsonb_build_object(
    'telegramChats', c -> 'telegramChats',
    'emails', c -> 'emails',
    'emailFrom', v_from,
    'alerts', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'title', a.title, 'body', a.body,
                                          'created_at', a.created_at,
                                          'telegram', a.telegram = 'pending', 'email', a.email = 'pending')
                       order by a.created_at)
        from (select * from public.uptime_alerts
               where telegram = 'pending' or email = 'pending'
               order by created_at limit 20) a), '[]'::jsonb));
end;
$$;
revoke execute on function public.uptime_alerts_due() from public, anon, authenticated;
grant execute on function public.uptime_alerts_due() to service_role;

-- How a send went: 'sent' or 'failed: …' per channel (null: not tried).
-- A failed send stays pending for the next round, up to 5 tries.
create or replace function public.uptime_alert_sent(p_id uuid, p_telegram text default null, p_email text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.uptime_alerts
     set tries = tries + 1,
         telegram = case when telegram <> 'pending' or p_telegram is null then telegram
                         when p_telegram = 'sent' then 'sent'
                         when tries + 1 >= 5 then left('failed: ' || p_telegram, 300)
                         else 'pending' end,
         email = case when email <> 'pending' or p_email is null then email
                      when p_email = 'sent' then 'sent'
                      when tries + 1 >= 5 then left('failed: ' || p_email, 300)
                      else 'pending' end
   where id = p_id;
end;
$$;
revoke execute on function public.uptime_alert_sent(uuid, text, text) from public, anon, authenticated;
grant execute on function public.uptime_alert_sent(uuid, text, text) to service_role;

-- ---- 7. Recording checks ------------------------------------------------------------------------
-- The name of a target (or of one gateway phone).
create or replace function public.uptime_target_name(p_id text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select t.name from public.uptime_targets t where t.id = p_id),
    (select 'SMS gateway · ' || coalesce(nullif(btrim(d.label), ''), d.sim_number, left(d.device_id, 12))
       from public.messaging_devices d
      where p_id like 'gateway:%' and d.id::text = substr(p_id, 9)),
    p_id);
$$;
revoke execute on function public.uptime_target_name(text) from public, anon, authenticated;

-- Checks from one source: [{id, status: up|slow|down, ms?, detail?}].
-- Unknown targets and statuses are skipped. Keeps the streaks, opens an
-- incident (and alerts) after failAfter failed checks in a row from any
-- fresh source, and resolves it when every fresh source is back up. A
-- source is fresh while its last check is under 3 of its rounds old (a
-- dead NAS doesn't hold an incident open). How many checks were kept.
create or replace function public.uptime_record(p_source text, p_results jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.nas_uptime_config();
  v_fail integer := (c ->> 'failAfter')::integer;
  r jsonb;
  v_id text;
  v_status text;
  v_ms integer;
  v_detail text;
  v_name text;
  v_down boolean;
  v_clear boolean;
  v_inc public.uptime_incidents;
  n integer := 0;
begin
  if p_source not in ('nas', 'cloud') or jsonb_typeof(p_results) <> 'array' then
    return 0;
  end if;
  for r in select * from jsonb_array_elements(p_results) limit 200 loop
    v_id := left(r ->> 'id', 60);
    v_status := r ->> 'status';
    if v_id is null or v_status not in ('up', 'slow', 'down') then
      continue;
    end if;
    if not exists (select 1 from public.uptime_targets t where t.id = v_id)
       and not (v_id like 'gateway:%' and exists (select 1 from public.messaging_devices d where d.id::text = substr(v_id, 9))) then
      continue;
    end if;
    v_ms := case when jsonb_typeof(r -> 'ms') = 'number' then greatest(0, least(600000, round((r ->> 'ms')::numeric)))::integer end;
    v_detail := left(nullif(btrim(coalesce(r ->> 'detail', '')), ''), 300);

    insert into public.uptime_checks (target_id, source, status, ms, detail)
    values (v_id, p_source, v_status, v_ms, v_detail);
    insert into public.uptime_daily (target_id, day, checks, up)
    values (v_id, (now() at time zone 'Asia/Kuala_Lumpur')::date, 1, case when v_status = 'down' then 0 else 1 end)
    on conflict (target_id, day) do update
       set checks = public.uptime_daily.checks + 1, up = public.uptime_daily.up + excluded.up;
    insert into public.uptime_state as s (target_id, source, streak, last_status, last_ms, last_detail, last_at)
    values (v_id, p_source, case when v_status = 'down' then 1 else 0 end, v_status, v_ms, v_detail, now())
    on conflict (target_id, source) do update
       set streak = case when excluded.last_status = 'down' then s.streak + 1 else 0 end,
           last_status = excluded.last_status, last_ms = excluded.last_ms,
           last_detail = excluded.last_detail, last_at = excluded.last_at;
    n := n + 1;

    -- Down: failAfter in a row from any fresh source. Clear: no fresh source failing.
    select coalesce(bool_or(s.streak >= v_fail), false), coalesce(bool_and(s.streak = 0), true)
      into v_down, v_clear
      from public.uptime_state s
     where s.target_id = v_id
       and s.last_at > now() - make_interval(mins => 3 * (case s.source when 'nas' then (c ->> 'nasEveryMinutes')::integer
                                                                           else (c ->> 'cloudEveryMinutes')::integer end) + 1);
    select * into v_inc from public.uptime_incidents where target_id = v_id and resolved_at is null;
    v_name := public.uptime_target_name(v_id);
    if v_down and v_inc.id is null then
      insert into public.uptime_incidents (target_id, name, detail) values (v_id, v_name, v_detail);
      perform public.uptime_alert('down', v_id, v_name || ' is down',
        coalesce(v_detail || '. ', '') || v_fail || ' checks in a row' ||
        case p_source when 'nas' then ' from the office NAS.' else ' from the cloud.' end ||
        ' Open Admin > Settings > Office NAS > Uptime.');
    elsif v_clear and v_inc.id is not null then
      update public.uptime_incidents set resolved_at = now() where id = v_inc.id;
      perform public.uptime_alert('resolved', v_id, v_name || ' is back up',
        'Resolved: down for ' || public.uptime_duration(now() - v_inc.started_at) || '.');
    end if;
  end loop;
  return n;
end;
$$;
revoke execute on function public.uptime_record(text, jsonb) from public, anon, authenticated;
grant execute on function public.uptime_record(text, jsonb) to service_role;

-- "4 min", "2 h 5 min", "3 days" for the resolved message.
create or replace function public.uptime_duration(p interval)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p < interval '1 minute' then 'under a minute'
    when p < interval '1 hour' then floor(extract(epoch from p) / 60)::int || ' min'
    when p < interval '1 day' then floor(extract(epoch from p) / 3600)::int || ' h'
         || case when floor(extract(epoch from p) / 60)::int % 60 > 0
                 then ' ' || (floor(extract(epoch from p) / 60)::int % 60) || ' min' else '' end
    else floor(extract(epoch from p) / 86400)::int || case when p < interval '2 days' then ' day' else ' days' end
  end;
$$;
revoke execute on function public.uptime_duration(interval) from public, anon, authenticated;

-- The payment gateway in use (the default account, else an active one),
-- as an address to reach. Null when there is none or it isn't known.
create or replace function public.uptime_payment_url()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_provider text;
begin
  -- As payment_gateway_for (0252): the default account, else an active one.
  select lower(coalesce(e.values ->> 'providerId', e.values ->> 'provider')) into v_provider
    from public.settings_entries e
   where e.category = 'payment-gateway' and e.active
     and coalesce(e.values ->> 'active', 'true') <> 'false'
   order by (coalesce(e.values ->> 'isDefault', '') = 'true') desc, e.id
   limit 1;
  return case v_provider
    when 'stripe' then 'https://api.stripe.com/healthcheck'
    when 'fiuu' then 'https://pay.fiuu.com'
    when 'billplz' then 'https://www.billplz.com'
    when 'ipay88' then 'https://payment.ipay88.com.my'
    when 'senangpay' then 'https://app.senangpay.my'
    when 'toyyibpay' then 'https://toyyibpay.com'
    when 'hitpay' then 'https://api.hit-pay.com'
    when 'paypal' then 'https://api-m.paypal.com'
    when 'airwallex' then 'https://api.airwallex.com'
    when 'xendit' then 'https://api.xendit.co'
    when 'adyen' then 'https://checkout-live.adyen.com'
    when 'curlec' then 'https://api.razorpay.com'
    when '2c2p' then 'https://pgw.2c2p.com'
    when 'eghl' then 'https://pay.e-ghl.com'
    when 'adaptis' then 'https://pay.e-ghl.com'
    when 'payhalal' then 'https://api.payhalal.my'
    when 'paydibs' then 'https://online.paydibs.com'
    else null end;
exception when others then
  return null;
end;
$$;
revoke execute on function public.uptime_payment_url() from public, anon, authenticated;

-- What a source checks over the network: http and database targets that are
-- on for it, {payment} filled in (a target without an address is left out).
-- {project} is filled in by the caller, which knows its own address.
create or replace function public.uptime_targets_for(p_source text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind, 'url', t.url,
                                               'slowMs', coalesce(t.slow_ms, (public.nas_uptime_config() ->> 'slowMs')::int))
                            order by t.position, t.id), '[]'::jsonb)
    from (select x.id, x.name, x.kind, x.position, x.slow_ms,
                 case when x.url = '{payment}' then public.uptime_payment_url() else x.url end as url
            from public.uptime_targets x
           where x.on_off and x.kind in ('http', 'database')
             and case p_source when 'nas' then x.from_nas when 'cloud' then x.from_cloud else false end) t
   where t.kind = 'database' or nullif(btrim(coalesce(t.url, '')), '') is not null;
$$;
revoke execute on function public.uptime_targets_for(text) from public, anon, authenticated;
grant execute on function public.uptime_targets_for(text) to service_role;

-- The cloud's database check: answers at once.
create or replace function public.uptime_ping()
returns timestamptz
language sql
stable
set search_path = public
as $$
  select now();
$$;
revoke execute on function public.uptime_ping() from public, anon, authenticated;
grant execute on function public.uptime_ping() to service_role;

-- What the database can tell by itself (no network): the gateway phones, the
-- office NAS and last night's backup, as checks from the cloud.
create or replace function public.uptime_local_results()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c jsonb := public.nas_uptime_config();
  b jsonb := public.nas_backup_config();
  v_late integer := (c ->> 'gatewayLateMinutes')::integer;
  v_dead integer := (c ->> 'gatewayDownMinutes')::integer;
  v jsonb := '[]'::jsonb;
  v_seen timestamptz;
  v_ok timestamptz;
  d record;
begin
  if exists (select 1 from public.uptime_targets where id = 'gateways' and on_off and from_cloud) then
    for d in
      select m.id, m.last_seen_at from public.messaging_devices m
       where m.kind = 'gateway' and 'sms' = any(m.capabilities)
    loop
      v := v || jsonb_build_object('id', 'gateway:' || d.id,
        'status', case when d.last_seen_at > now() - make_interval(mins => v_late) then 'up'
                       when d.last_seen_at > now() - make_interval(mins => v_dead) then 'slow'
                       else 'down' end,
        'ms', null,
        'detail', 'Last seen ' || public.uptime_duration(now() - d.last_seen_at) || ' ago');
    end loop;
  end if;
  if exists (select 1 from public.uptime_targets where id = 'nas' and on_off and from_cloud)
     and exists (select 1 from public.nas_ops_agents) then
    select greatest((select max(last_seen) from public.nas_services), (select max(last_seen_at) from public.nas_ops_agents))
      into v_seen;
    v := v || jsonb_build_object('id', 'nas',
      'status', case when v_seen > now() - interval '3 minutes' then 'up'
                     when v_seen > now() - interval '10 minutes' then 'slow' else 'down' end,
      'detail', case when v_seen is null then 'Never checked in'
                     else 'Last checked in ' || public.uptime_duration(now() - v_seen) || ' ago' end);
  end if;
  if exists (select 1 from public.uptime_targets where id = 'backup' and on_off and from_cloud)
     and (b ->> 'on')::boolean and exists (select 1 from public.nas_ops_agents) then
    select max(finished_at) into v_ok from public.backup_runs where kind = 'backup' and status = 'ok';
    -- Only once a first backup has had its chance.
    if v_ok is not null or exists (select 1 from public.nas_ops_agents where created_at < now() - interval '26 hours') then
      v := v || jsonb_build_object('id', 'backup',
        'status', case when v_ok > now() - interval '26 hours' then 'up' else 'down' end,
        'detail', case when v_ok is null then 'No backup has finished yet'
                       else 'Last good backup ' || public.uptime_duration(now() - v_ok) || ' ago' end);
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function public.uptime_local_results() from public, anon, authenticated;

-- pg_cron, every minute: when the cloud round is due (cloudEveryMinutes),
-- records what the database can tell by itself and wakes the uptime-check
-- function for the network checks. Also retries Telegram and email sends.
create or replace function public.uptime_cron()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.nas_uptime_config();
  v_last timestamptz;
  n integer := 0;
begin
  select max(last_at) into v_last from public.uptime_state where source = 'cloud';
  if v_last is null or v_last <= now() - make_interval(mins => (c ->> 'cloudEveryMinutes')::integer) + interval '20 seconds' then
    n := public.uptime_record('cloud', public.uptime_local_results());
    perform public.uptime_kick(jsonb_build_object('action', 'check'));
  elsif exists (select 1 from public.uptime_alerts where telegram = 'pending' or email = 'pending') then
    perform public.uptime_kick(jsonb_build_object('action', 'flush'));
  end if;
  return n;
end;
$$;
revoke execute on function public.uptime_cron() from public, anon, authenticated;

-- ---- 8. The NAS app's calls (through the nas-ops edge function only) ---------------------------
create or replace function public.nas_ops_pair(
  p_code text, p_device_id text, p_label text default null, p_model text default null,
  p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_pair public.nas_ops_pairings;
  v_agent public.nas_ops_agents;
  v_key text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if (select count(*) from public.nas_ops_pair_failures where at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('error', 'NAS_PAIR_BUSY', 'hint', 'Too many wrong codes. Wait 10 minutes and try again.');
  end if;
  if coalesce(btrim(p_device_id), '') = '' then
    return jsonb_build_object('error', 'NAS_PAIR_DEVICE', 'hint', 'The NAS app sent no device id.');
  end if;
  select * into v_pair from public.nas_ops_pairings
   where code_hash = public.gateway_secret_hash(v_code) and used_at is null and expires_at > now()
   for update;
  if not found then
    insert into public.nas_ops_pair_failures default values;
    return jsonb_build_object('error', 'NAS_PAIR_CODE',
      'hint', 'That code is wrong or has expired. Make a new one in Admin > Settings > Office NAS.');
  end if;
  insert into public.nas_ops_agents (label, device_id, model, app_version, key_hash, paired_by, last_seen_at)
  values (coalesce(v_pair.label, nullif(left(btrim(coalesce(p_label, '')), 80), ''), 'Office NAS'),
          left(p_device_id, 200), left(p_model, 120), left(p_app_version, 40),
          public.gateway_secret_hash(v_key), v_pair.created_by, now())
  on conflict (device_id) do update
     set label = coalesce(v_pair.label, public.nas_ops_agents.label),
         model = coalesce(excluded.model, public.nas_ops_agents.model),
         app_version = excluded.app_version,
         key_hash = excluded.key_hash,
         paired_by = excluded.paired_by,
         last_seen_at = now()
  returning * into v_agent;
  update public.nas_ops_pairings set used_at = now(), agent_id = v_agent.id where id = v_pair.id;
  return jsonb_build_object('key', v_key, 'agent', v_agent.id, 'label', v_agent.label);
end;
$$;

-- The agent a key belongs to; refuses an unknown (or removed) key.
create or replace function public.nas_ops_by_key(p_key text)
returns public.nas_ops_agents
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_ops_agents;
begin
  update public.nas_ops_agents set last_seen_at = now()
   where key_hash = public.gateway_secret_hash(p_key)
  returning * into v;
  if not found then
    raise exception 'NAS_KEY_INVALID' using errcode = '42501',
      hint = 'This NAS app is no longer connected. Connect it again from Admin > Settings > Office NAS.';
  end if;
  return v;
end;
$$;

-- Check-in. p_services: {backup: {status, detail}, uptime: {...}, box: {...}}
-- (only these three are taken). Answers the settings, the uptime targets for
-- the NAS, and hands over the waiting "Back up now" / "Run a restore test".
create or replace function public.nas_ops_heartbeat(
  p_key text, p_model text default null, p_app_version text default null, p_services jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_ops_agents := public.nas_ops_by_key(p_key);
  s text;
  v_req jsonb;
begin
  update public.nas_ops_agents
     set model = coalesce(left(p_model, 120), model), app_version = coalesce(left(p_app_version, 40), app_version)
   where id = v.id;
  if jsonb_typeof(p_services) = 'object' then
    foreach s in array array['backup', 'uptime', 'box'] loop
      if jsonb_typeof(p_services -> s) = 'object' then
        insert into public.nas_services (service, last_seen, status, detail, version)
        values (s, now(), left(p_services -> s ->> 'status', 40),
                case when length((p_services -> s -> 'detail')::text) <= 20000
                     and jsonb_typeof(p_services -> s -> 'detail') = 'object'
                     then p_services -> s -> 'detail' end,
                left(p_app_version, 40))
        on conflict (service) do update
           set last_seen = now(), status = excluded.status, detail = excluded.detail, version = excluded.version;
      end if;
    end loop;
  end if;
  with taken as (
    update public.nas_backup_requests r set taken_at = now()
     where r.taken_at is null and r.requested_at > now() - interval '1 day'
    returning r.id, r.kind, r.requested_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind) order by requested_at), '[]'::jsonb)
    into v_req from taken;
  return jsonb_build_object(
    'agent', v.id, 'label', v.label,
    'backup', public.nas_backup_config(),
    'uptime', public.nas_uptime_config() - array['telegramChats', 'smsNumbers', 'emails', 'emailFrom', 'channels'],
    'targets', public.uptime_targets_for('nas'),
    'requests', v_req);
end;
$$;

-- A backup or restore test starts. The run's id.
create or replace function public.nas_backup_started(
  p_key text, p_kind text, p_trigger text default 'schedule', p_request uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_ops_agents := public.nas_ops_by_key(p_key);
  v_id uuid;
begin
  if p_kind not in ('backup', 'restore_test') then
    raise exception 'NAS_BAD_KIND' using errcode = '22023';
  end if;
  -- One left running by a NAS that restarted is marked failed.
  update public.backup_runs set status = 'failed', finished_at = now(),
         error = coalesce(error, 'The NAS app stopped before it finished.')
   where agent_id = v.id and kind = p_kind and status = 'running';
  insert into public.backup_runs (kind, trigger, agent_id)
  values (p_kind, case when p_trigger = 'manual' then 'manual' else 'schedule' end, v.id)
  returning id into v_id;
  if p_request is not null then
    update public.nas_backup_requests set run_id = v_id where id = p_request;
  end if;
  return v_id;
end;
$$;

-- A run finished. A failed backup or restore test alerts.
create or replace function public.nas_backup_finished(
  p_key text, p_run uuid, p_ok boolean, p_db_bytes bigint default null, p_files integer default null,
  p_files_bytes bigint default null, p_total_bytes bigint default null, p_error text default null,
  p_detail jsonb default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_ops_agents := public.nas_ops_by_key(p_key);
  r public.backup_runs;
begin
  update public.backup_runs
     set status = case when p_ok then 'ok' else 'failed' end,
         finished_at = now(),
         db_bytes = greatest(0, p_db_bytes),
         files = greatest(0, p_files),
         files_bytes = greatest(0, p_files_bytes),
         total_bytes = greatest(0, p_total_bytes),
         error = case when p_ok then null else left(coalesce(nullif(btrim(p_error), ''), 'Failed'), 500) end,
         detail = case when jsonb_typeof(p_detail) = 'object' and length(p_detail::text) <= 20000 then p_detail
                       else '{}'::jsonb end
   where id = p_run and agent_id = v.id and status = 'running'
  returning * into r;
  if not found then
    return 'not_yours';
  end if;
  if not p_ok then
    perform public.uptime_alert(
      case r.kind when 'backup' then 'backup_failed' else 'restore_failed' end, null,
      case r.kind when 'backup' then 'Backup failed' else 'Restore test failed' end,
      coalesce(r.error, 'Failed') || '. Open Admin > Settings > Office NAS > Backups.');
  end if;
  return r.status;
end;
$$;

-- The NAS's own uptime checks.
create or replace function public.nas_uptime_report(p_key text, p_results jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_ops_agents := public.nas_ops_by_key(p_key);
begin
  return public.uptime_record('nas', p_results);
end;
$$;

-- Only the nas-ops edge function (service role) calls these.
revoke execute on function public.nas_ops_pair(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.nas_ops_by_key(text) from public, anon, authenticated;
revoke execute on function public.nas_ops_heartbeat(text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.nas_backup_started(text, text, text, uuid) from public, anon, authenticated;
revoke execute on function public.nas_backup_finished(text, uuid, boolean, bigint, integer, bigint, bigint, text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.nas_uptime_report(text, jsonb) from public, anon, authenticated;
grant execute on function public.nas_ops_pair(text, text, text, text, text) to service_role;
grant execute on function public.nas_ops_heartbeat(text, text, text, jsonb) to service_role;
grant execute on function public.nas_backup_started(text, text, text, uuid) to service_role;
grant execute on function public.nas_backup_finished(text, uuid, boolean, bigint, integer, bigint, bigint, text, jsonb)
  to service_role;
grant execute on function public.nas_uptime_report(text, jsonb) to service_role;

-- ---- 9. The admin page (Admin > Settings > Office NAS) -----------------------------------------
-- Everything the Overview, Backups and Uptime tabs show. Admins only.
create or replace function public.admin_office_nas()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_since date := (now() at time zone 'Asia/Kuala_Lumpur')::date - 29;
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'now', now(),
    'services', coalesce((
      select jsonb_agg(jsonb_build_object('service', s.service, 'last_seen', s.last_seen, 'status', s.status,
                                          'detail', s.detail, 'version', s.version) order by s.service)
        from public.nas_services s), '[]'::jsonb),
    'agents', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'label', a.label, 'model', a.model,
                                          'app_version', a.app_version, 'created_at', a.created_at,
                                          'last_seen_at', a.last_seen_at,
                                          'online', coalesce(a.last_seen_at > now() - interval '3 minutes', false))
                       order by a.created_at)
        from public.nas_ops_agents a), '[]'::jsonb),
    'backup', public.nas_backup_config(),
    'uptime', public.nas_uptime_config(),
    'runs', coalesce((
      select jsonb_agg(to_jsonb(r) - 'agent_id' order by r.started_at desc)
        from (select * from public.backup_runs order by started_at desc limit 30) r), '[]'::jsonb),
    'last_backup', (select to_jsonb(r) - 'agent_id' from public.backup_runs r
                     where r.kind = 'backup' and r.status <> 'running' order by r.started_at desc limit 1),
    'last_restore_test', (select to_jsonb(r) - 'agent_id' from public.backup_runs r
                           where r.kind = 'restore_test' and r.status <> 'running' order by r.started_at desc limit 1),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'requested_at', q.requested_at,
                                          'taken_at', q.taken_at) order by q.requested_at)
        from public.nas_backup_requests q
       where q.requested_at > now() - interval '1 day'
         and (q.taken_at is null
              or exists (select 1 from public.backup_runs b where b.id = q.run_id and b.status = 'running'))), '[]'::jsonb),
    'targets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'name', t.name, 'kind', t.kind, 'url', t.url, 'on', t.on_off,
               'from_nas', t.from_nas, 'from_cloud', t.from_cloud, 'slow_ms', t.slow_ms,
               'position', t.position, 'builtin', t.builtin) order by t.position, t.id)
        from public.uptime_targets t), '[]'::jsonb),
    -- Every target and gateway phone that has been checked: last result per
    -- source, 30-day uptime, and whether an incident is open.
    'status', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.target_id,
               'name', public.uptime_target_name(x.target_id),
               'sources', (select jsonb_object_agg(s.source, jsonb_build_object(
                                  'status', s.last_status, 'ms', s.last_ms, 'detail', s.last_detail,
                                  'at', s.last_at, 'streak', s.streak))
                             from public.uptime_state s where s.target_id = x.target_id),
               'checks30', (select coalesce(sum(d.checks), 0) from public.uptime_daily d
                             where d.target_id = x.target_id and d.day >= v_since),
               'up30', (select coalesce(sum(d.up), 0) from public.uptime_daily d
                         where d.target_id = x.target_id and d.day >= v_since),
               'down_since', (select i.started_at from public.uptime_incidents i
                               where i.target_id = x.target_id and i.resolved_at is null))
             order by x.target_id)
        from (select distinct s.target_id from public.uptime_state s
               where s.target_id not like 'gateway:%'
                  or exists (select 1 from public.messaging_devices d where d.id::text = substr(s.target_id, 9))) x),
      '[]'::jsonb),
    'alerts', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'target_id', a.target_id, 'title', a.title,
                                          'body', a.body, 'created_at', a.created_at, 'push', a.push_count,
                                          'sms', a.sms_count, 'telegram', a.telegram, 'email', a.email)
                       order by a.created_at desc)
        from (select * from public.uptime_alerts order by created_at desc limit 20) a), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_office_nas() from public, anon;
grant execute on function public.admin_office_nas() to authenticated;

-- The last 200 checks of one target (or gateway phone), newest first.
create or replace function public.admin_uptime_history(p_target text)
returns table (checked_at timestamptz, source text, status text, ms integer, detail text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  return query
  select c.checked_at, c.source, c.status, c.ms, c.detail
    from public.uptime_checks c
   where c.target_id = p_target
   order by c.checked_at desc
   limit 200;
end;
$$;
revoke execute on function public.admin_uptime_history(text) from public, anon;
grant execute on function public.admin_uptime_history(text) to authenticated;

create or replace function public.admin_nas_backup_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.nas_backup_normalize(coalesce(p, '{}'::jsonb));
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_nas_backup_set') then
    raise exception 'You can''t change the backups.' using errcode = '42501';
  end if;
  insert into public.office_nas_settings (key, value, updated_by) values ('backup', v, auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
  return v;
end;
$$;
revoke execute on function public.admin_nas_backup_set(jsonb) from public, anon;
grant execute on function public.admin_nas_backup_set(jsonb) to authenticated;

create or replace function public.admin_nas_uptime_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.nas_uptime_normalize(coalesce(p, '{}'::jsonb));
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_nas_uptime_set') then
    raise exception 'You can''t change the uptime monitor.' using errcode = '42501';
  end if;
  insert into public.office_nas_settings (key, value, updated_by) values ('uptime', v, auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
  return v;
end;
$$;
revoke execute on function public.admin_nas_uptime_set(jsonb) from public, anon;
grant execute on function public.admin_nas_uptime_set(jsonb) to authenticated;

-- "Back up now" / "Run a restore test": handed to the NAS at its next
-- check-in (within a minute). One waiting request of a kind at a time.
create or replace function public.admin_nas_backup_request(p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.nas_backup_requests;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_nas_backup_request') then
    raise exception 'You can''t start a backup.' using errcode = '42501';
  end if;
  if p_kind not in ('backup', 'restore_test') then
    raise exception 'Unknown kind.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.nas_ops_agents) then
    raise exception 'NAS_NOT_CONNECTED' using errcode = 'P0001',
      hint = 'Connect the NAS backup app first (Overview > Connect the NAS).';
  end if;
  select * into r from public.nas_backup_requests
   where kind = p_kind and taken_at is null and requested_at > now() - interval '1 day'
   order by requested_at limit 1;
  if not found then
    insert into public.nas_backup_requests (kind, requested_by) values (p_kind, auth.uid()) returning * into r;
  end if;
  return jsonb_build_object('id', r.id, 'kind', r.kind, 'requested_at', r.requested_at);
end;
$$;
revoke execute on function public.admin_nas_backup_request(text) from public, anon;
grant execute on function public.admin_nas_backup_request(text) to authenticated;

-- Add or change a target. p: {id?, name, kind (http | database), url, on,
-- from_nas, from_cloud, slow_ms, position}. A built-in target keeps its kind
-- (and its address where the server fills it in). The saved row.
create or replace function public.admin_uptime_target_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := lower(btrim(coalesce(p ->> 'id', '')));
  v_old public.uptime_targets;
  v_name text := left(btrim(coalesce(p ->> 'name', '')), 80);
  v_kind text := coalesce(p ->> 'kind', 'http');
  v_url text := nullif(left(btrim(coalesce(p ->> 'url', '')), 500), '');
  v_slow integer := case when jsonb_typeof(p -> 'slow_ms') = 'number'
                         then public.office_nas_int(p -> 'slow_ms', 3000, 100, 60000) end;
  v_row public.uptime_targets;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_uptime_target_save') then
    raise exception 'You can''t change the uptime targets.' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'UPTIME_NAME' using errcode = '22023', hint = 'Give the target a name.';
  end if;
  if v_id <> '' then
    select * into v_old from public.uptime_targets where id = v_id;
  end if;
  if v_old.id is not null and v_old.builtin then
    v_kind := v_old.kind;
    if v_old.url in ('{payment}') and (v_url is null or v_url = v_old.url) then
      v_url := v_old.url;
    end if;
  elsif v_kind not in ('http', 'database') then
    raise exception 'UPTIME_KIND' using errcode = '22023', hint = 'A new target is a web address or the database.';
  end if;
  if v_kind = 'http' and (v_url is null
       or (v_url !~ '^https?://[^\s/]+' and v_url !~ '^\{project\}/' and v_url <> '{payment}')) then
    raise exception 'UPTIME_URL' using errcode = '22023', hint = 'Give a web address starting with https://.';
  end if;
  if v_kind <> 'http' then
    v_url := null;
  end if;
  if v_old.id is null then
    v_id := left(trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g')), 30);
    if v_id = '' then
      v_id := 'target';
    end if;
    while exists (select 1 from public.uptime_targets where id = v_id) loop
      v_id := left(v_id, 30) || '-' || substr(md5(random()::text), 1, 4);
    end loop;
  end if;
  insert into public.uptime_targets (id, name, kind, url, on_off, from_nas, from_cloud, slow_ms, position, builtin)
  values (v_id, v_name, v_kind, v_url,
          coalesce((p ->> 'on')::boolean, true),
          coalesce((p ->> 'from_nas')::boolean, true),
          coalesce((p ->> 'from_cloud')::boolean, true),
          v_slow,
          coalesce(case when jsonb_typeof(p -> 'position') = 'number' then (p ->> 'position')::numeric::int end,
                   (select coalesce(max(position), 0) + 10 from public.uptime_targets)),
          false)
  on conflict (id) do update
     set name = excluded.name, url = excluded.url, on_off = excluded.on_off,
         from_nas = case when public.uptime_targets.kind in ('gateways', 'nas', 'backup') then false else excluded.from_nas end,
         from_cloud = excluded.from_cloud, slow_ms = excluded.slow_ms,
         position = case when jsonb_typeof(p -> 'position') = 'number' then excluded.position
                         else public.uptime_targets.position end,
         updated_at = now()
  returning * into v_row;
  -- Switched off: an open incident is closed without a message.
  if not v_row.on_off then
    update public.uptime_incidents set resolved_at = now()
     where resolved_at is null and (target_id = v_row.id or (v_row.kind = 'gateways' and target_id like 'gateway:%'));
  end if;
  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.admin_uptime_target_save(jsonb) from public, anon;
grant execute on function public.admin_uptime_target_save(jsonb) to authenticated;

create or replace function public.admin_uptime_target_delete(p_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_uptime_target_delete') then
    raise exception 'You can''t change the uptime targets.' using errcode = '42501';
  end if;
  if exists (select 1 from public.uptime_targets where id = p_id and builtin) then
    raise exception 'UPTIME_BUILTIN' using errcode = '22023', hint = 'A built-in target can be switched off, not removed.';
  end if;
  delete from public.uptime_targets where id = p_id;
  delete from public.uptime_state where target_id = p_id;
  update public.uptime_incidents set resolved_at = now() where target_id = p_id and resolved_at is null;
end;
$$;
revoke execute on function public.admin_uptime_target_delete(text) from public, anon;
grant execute on function public.admin_uptime_target_delete(text) to authenticated;

-- A test message on every channel that is on. The alert's id.
create or replace function public.admin_uptime_test_alert()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_uptime_test_alert') then
    raise exception 'You can''t send a test alert.' using errcode = '42501';
  end if;
  if exists (select 1 from public.uptime_alerts where kind = 'test' and created_at > now() - interval '1 minute') then
    raise exception 'UPTIME_TEST_BUSY' using errcode = 'P0001', hint = 'A test was sent less than a minute ago.';
  end if;
  return public.uptime_alert('test', null, 'Test alert',
    'This is a test from Admin > Settings > Office NAS > Uptime. Alerts reach you here.');
end;
$$;
revoke execute on function public.admin_uptime_test_alert() from public, anon;
grant execute on function public.admin_uptime_test_alert() to authenticated;

-- Connecting the NAS app: a full admin only (it is given the backups' state).
create or replace function public.admin_nas_ops_pairing_code(p_label text default null)
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
    raise exception 'Only a full admin can connect the NAS.' using errcode = '42501';
  end if;
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % length(v_alphabet)), 1);
  end loop;
  delete from public.nas_ops_pairings where created_by = auth.uid() and used_at is null;
  insert into public.nas_ops_pairings (code_hash, label, created_by, expires_at)
  values (public.gateway_secret_hash(v_code), nullif(left(btrim(coalesce(p_label, '')), 80), ''), auth.uid(), v_expires);
  return jsonb_build_object('code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4), 'expires_at', v_expires);
end;
$$;
revoke execute on function public.admin_nas_ops_pairing_code(text) from public, anon;
grant execute on function public.admin_nas_ops_pairing_code(text) to authenticated;

create or replace function public.admin_nas_ops_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can disconnect the NAS.' using errcode = '42501';
  end if;
  update public.backup_runs set status = 'failed', finished_at = now(), error = 'The NAS was disconnected.'
   where agent_id = p_id and status = 'running';
  delete from public.nas_ops_agents where id = p_id;
end;
$$;
revoke execute on function public.admin_nas_ops_remove(uuid) from public, anon;
grant execute on function public.admin_nas_ops_remove(uuid) to authenticated;

-- ---- 10. Who may change what --------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_nas_backup_set', 'admin-settings-office-nas'),
  ('rpc:admin_nas_uptime_set', 'admin-settings-office-nas'),
  ('rpc:admin_nas_backup_request', 'admin-settings-office-nas'),
  ('rpc:admin_uptime_target_save', 'admin-settings-office-nas'),
  ('rpc:admin_uptime_target_delete', 'admin-settings-office-nas'),
  ('rpc:admin_uptime_test_alert', 'admin-settings-office-nas')
on conflict do nothing;

-- ---- 11. Schedules ------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'uptime-cloud';
    perform cron.schedule('uptime-cloud', '* * * * *', $job$select public.uptime_cron()$job$);
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-office-nas';
    perform cron.schedule('purge-office-nas', '41 * * * *', $job$
      delete from public.nas_ops_pairings where expires_at < now() - interval '1 day';
      delete from public.nas_ops_pair_failures where at < now() - interval '1 day';
      delete from public.uptime_checks where checked_at < now() - interval '7 days';
      delete from public.uptime_daily where day < current_date - 400;
      delete from public.uptime_alerts where created_at < now() - interval '90 days';
      delete from public.uptime_incidents where resolved_at < now() - interval '90 days';
      delete from public.nas_backup_requests where requested_at < now() - interval '30 days';
      delete from public.backup_runs where started_at < now() - interval '400 days';
      delete from public.uptime_state s where s.target_id like 'gateway:%'
         and not exists (select 1 from public.messaging_devices d where d.id::text = substr(s.target_id, 9));
    $job$);
  end if;
end $$;

-- Not in the realtime publication: the NAS checks in every minute (as the
-- gateway phones do, 0229); the admin page re-reads every 30 seconds.

notify pgrst, 'reload schema';
