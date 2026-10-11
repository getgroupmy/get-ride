-- ============================================================================
-- 0150: a trip alert the app never confirmed goes out as an SMS
--
-- Trip pushes go through the notification outbox (0144) and are retried
-- until the app acknowledges them. A phone with no data, push turned off or
-- the app killed by the OS never acknowledges, and the passenger standing at
-- the kerb never hears that their driver has arrived. This sends such an
-- alert once as an SMS, through the gateway phone (sms_outbox, delivered by
-- gateway_claim_sms / gateway_report_sms, 0120). No SMS provider, no secrets.
--
--   * sms_fallback_settings: one row the admin edits (Admin → SMS / WhatsApp
--     → SMS fallback for trips): on/off (off by default), how long a push
--     waits for the app before the SMS, critical alerts only or all, which
--     gateway route sends it, and per-number hourly cap;
--   * notification_outbox gains sms_status / sms_reason / sms_at / sms_phone
--     / sms_outbox_id: what the fallback did with each alert, once;
--   * dispatch_sms_fallback() (pg_cron, every 20 s): the unconfirmed alerts
--     old enough, still relevant (the trip hasn't moved on), to a number the
--     sign-in SMS limits (0149) allow, within the cap; with no gateway phone
--     online on the route it waits rather than queue for nobody;
--   * sms_fallback_summary(hours): what it did, for the admin.
--
-- Rollback: switch it off in the admin; nothing else depends on it.
-- ============================================================================

create table if not exists public.sms_fallback_settings (
  id                 int primary key default 1 check (id = 1),
  enabled            boolean not null default false,
  after_seconds      int not null default 60 check (after_seconds between 20 and 600),
  critical_only      boolean not null default true,
  channel            text not null default 'otp' check (channel in ('otp', 'support_message')),
  per_phone_per_hour int not null default 6 check (per_phone_per_hour between 1 and 30),
  updated_at         timestamptz not null default now(),
  updated_by         uuid
);
insert into public.sms_fallback_settings (id) values (1) on conflict do nothing;

alter table public.sms_fallback_settings enable row level security;
drop policy if exists "sms_fallback_settings admin read" on public.sms_fallback_settings;
create policy "sms_fallback_settings admin read" on public.sms_fallback_settings
  for select using (public.caller_is_admin());
drop policy if exists "sms_fallback_settings admin update" on public.sms_fallback_settings;
create policy "sms_fallback_settings admin update" on public.sms_fallback_settings
  for update using (public.caller_is_admin()) with check (public.caller_is_admin());
revoke all on public.sms_fallback_settings from anon, authenticated;
grant select, update on public.sms_fallback_settings to authenticated;

create or replace function public.sms_fallback_settings_touch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.id := 1;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.sms_fallback_settings_touch() from public, anon, authenticated;

drop trigger if exists trg_sms_fallback_settings_touch on public.sms_fallback_settings;
create trigger trg_sms_fallback_settings_touch before update on public.sms_fallback_settings
  for each row execute function public.sms_fallback_settings_touch();

-- ---- What the fallback did with each alert ---------------------------------------
alter table public.notification_outbox add column if not exists sms_status text
  check (sms_status is null or sms_status in ('queued', 'skipped'));
alter table public.notification_outbox add column if not exists sms_reason text;
alter table public.notification_outbox add column if not exists sms_at timestamptz;
alter table public.notification_outbox add column if not exists sms_phone text;
alter table public.notification_outbox add column if not exists sms_outbox_id uuid;

create index if not exists notification_outbox_sms_due
  on public.notification_outbox (created_at)
  where delivered_at is null and sms_at is null;
create index if not exists notification_outbox_sms_phone
  on public.notification_outbox (sms_phone, sms_at)
  where sms_status = 'queued';

-- ---- The number an alert would go to -----------------------------------------------
-- The account's own number, else the number the ride holds for that side.
create or replace function public.sms_fallback_phone(r public.notification_outbox)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select public.sms_e164(coalesce(
    nullif(btrim((select p.phone from public.profiles p where p.id = r.profile_id)), ''),
    (select case when q.rider_id = r.profile_id then nullif(btrim(q.rider_phone), '')
                 when q.partner_id = r.profile_id then nullif(btrim(q.partner_phone), '') end
       from public.ride_requests q where q.id = r.request_id)
  ));
$$;
revoke execute on function public.sms_fallback_phone(public.notification_outbox) from public, anon, authenticated;

-- ---- Why an alert may not go by SMS (null when it may) -----------------------------
create or replace function public.sms_fallback_refusal(r public.notification_outbox, p_phone text, p_now timestamptz default now())
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.sms_fallback_settings;
  s public.sms_settings;
begin
  select * into f from public.sms_fallback_settings where id = 1;
  if not public.notification_still_relevant(r) then
    return 'moved_on';
  end if;
  if p_phone is null then
    return 'no_number';
  end if;
  -- The sign-in limits' country and block lists apply here too.
  select * into s from public.sms_settings where id = 1;
  if found then
    if p_phone = any (select public.sms_e164(b) from unnest(s.blocked_numbers) b) then
      return 'blocked_number';
    end if;
    if cardinality(s.allowed_prefixes) > 0
       and not exists (select 1 from unnest(s.allowed_prefixes) p where p_phone like public.sms_e164(p) || '%') then
      return 'prefix';
    end if;
  end if;
  if (select count(*) from public.notification_outbox o
       where o.sms_phone = p_phone and o.sms_status = 'queued'
         and o.sms_at > p_now - interval '1 hour') >= coalesce(f.per_phone_per_hour, 6) then
    return 'per_phone_hour';
  end if;
  return null;
end;
$$;
revoke execute on function public.sms_fallback_refusal(public.notification_outbox, text, timestamptz)
  from public, anon, authenticated;

-- ---- Is a gateway phone there to send it? ------------------------------------------
create or replace function public.sms_gateway_online(p_channel text, p_now timestamptz default now())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.messaging_routes r
      join public.messaging_devices d on d.id = any (r.device_ids)
     where r.channel = p_channel and r.direction = 'outbound' and r.transport = 'sms' and r.enabled
       and d.last_seen_at > p_now - interval '10 minutes'
  );
$$;
revoke execute on function public.sms_gateway_online(text, timestamptz) from public, anon, authenticated;

-- ---- The fallback ----------------------------------------------------------------------
create or replace function public.dispatch_sms_fallback(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.sms_fallback_settings;
  r public.notification_outbox;
  v_phone text;
  v_reason text;
  v_outbox uuid;
  n int := 0;
begin
  select * into f from public.sms_fallback_settings where id = 1;
  if not found or not f.enabled then
    return 0;
  end if;
  -- No gateway phone: wait. An alert still in its window goes once one is back.
  if not public.sms_gateway_online(f.channel, p_now) then
    return 0;
  end if;

  for r in
    select * from public.notification_outbox o
     where o.delivered_at is null and o.sms_at is null
       and o.created_at <= p_now - make_interval(secs => f.after_seconds)
       and o.created_at > p_now - interval '10 minutes'
       and o.expires_at > p_now
       and (not f.critical_only or o.priority = 'critical')
     order by o.created_at
     limit 50
     for update skip locked
  loop
    v_phone := public.sms_fallback_phone(r);
    v_reason := public.sms_fallback_refusal(r, v_phone, p_now);
    if v_reason is not null then
      update public.notification_outbox
         set sms_status = 'skipped', sms_reason = v_reason, sms_at = p_now, sms_phone = v_phone
       where id = r.id;
      continue;
    end if;
    insert into public.sms_outbox (channel, to_phone, body, created_by)
    values (f.channel, v_phone, left('GET.ride: ' || r.title || '. ' || r.body, 300), null)
    returning id into v_outbox;
    update public.notification_outbox
       set sms_status = 'queued', sms_reason = null, sms_at = p_now, sms_phone = v_phone, sms_outbox_id = v_outbox
     where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.dispatch_sms_fallback(timestamptz) from public, anon, authenticated;

-- ---- Admin: what it did ----------------------------------------------------------------
create or replace function public.sms_fallback_summary(p_hours int default 24)
returns table (alerts bigint, confirmed bigint, sms_queued bigint, sms_skipped bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  select count(*),
         count(*) filter (where o.delivered_at is not null),
         count(*) filter (where o.sms_status = 'queued'),
         count(*) filter (where o.sms_status = 'skipped')
    from public.notification_outbox o
   where o.created_at > now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 168)));
end;
$$;
revoke execute on function public.sms_fallback_summary(int) from public, anon;
grant execute on function public.sms_fallback_summary(int) to authenticated;

-- ---- Schedule and live updates -----------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'dispatch-sms-fallback';
    perform cron.schedule('dispatch-sms-fallback', '20 seconds', $job$select public.dispatch_sms_fallback()$job$);
  end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'sms_fallback_settings') then
    alter publication supabase_realtime add table public.sms_fallback_settings;
  end if;
end $$;

notify pgrst, 'reload schema';
