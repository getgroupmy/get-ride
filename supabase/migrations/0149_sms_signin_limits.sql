-- ============================================================================
-- 0149: sign-in SMS limits, set by an admin, enforced on every code
--
-- Supabase Auth sends the sign-in code through a "Send SMS" hook. This is
-- that hook, as a Postgres function (Auth → Hooks → Send SMS → Postgres →
-- public.send_sms_hook): it checks the admin's limits and, when they allow
-- it, queues the code on the `otp` channel for the gateway phone
-- (sms_outbox, delivered by gateway_claim_sms / gateway_report_sms). No SMS
-- provider account and no secrets.
--
--   * sms_settings: one row the admin edits (Admin → Messaging → Sign-in SMS
--     limits): on/off, per number per hour and per day, the least time
--     between two codes to one number, a global hourly cap, allowed country
--     prefixes, blocked numbers and the message wording;
--   * sms_log: every attempt, queued or blocked and why, for the activity
--     panel (admins only; numbers are masked in the app);
--   * send_sms_hook(event): the hook. A refusal answers Auth with an error
--     (http_code + message), which the app shows to the person signing in.
--     With no gateway phone on the otp route seen in the last 10 minutes it
--     refuses too, rather than queue a code nobody will send.
--
-- Supabase's own Auth rate limits stay on as an upper cap, and per-IP limits
-- stay with them: the hook is not told the caller's IP.
--
-- Rollback: turn the hook off in Auth → Hooks; Auth goes back to its own
-- SMS provider at once.
-- ============================================================================

create table if not exists public.sms_settings (
  id                 int primary key default 1 check (id = 1),
  enabled            boolean not null default true,
  per_phone_per_hour int not null default 3 check (per_phone_per_hour between 1 and 20),
  per_phone_per_day  int not null default 10 check (per_phone_per_day between 1 and 50),
  min_resend_seconds int not null default 60 check (min_resend_seconds between 15 and 600),
  global_per_hour    int not null default 500 check (global_per_hour between 1 and 100000),
  allowed_prefixes   text[] not null default '{+60}',
  blocked_numbers    text[] not null default '{}',
  message_template   text not null default 'Your GET.ride code is {code}. Do not share it.'
                     check (position('{code}' in message_template) > 0 and char_length(message_template) <= 300),
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint sms_settings_day_covers_hour check (per_phone_per_day >= per_phone_per_hour)
);
insert into public.sms_settings (id) values (1) on conflict do nothing;

create table if not exists public.sms_log (
  id         bigint generated always as identity primary key,
  phone      text not null,
  user_id    uuid,
  status     text not null check (status in ('queued', 'blocked', 'failed')),
  reason     text,
  outbox_id  uuid,
  created_at timestamptz not null default now()
);
create index if not exists sms_log_phone_time on public.sms_log (phone, created_at desc);
create index if not exists sms_log_time on public.sms_log (created_at desc);

alter table public.sms_settings enable row level security;
alter table public.sms_log enable row level security;

drop policy if exists "sms_settings admin read" on public.sms_settings;
drop policy if exists "sms_settings admin update" on public.sms_settings;
drop policy if exists "sms_log admin read" on public.sms_log;
create policy "sms_settings admin read" on public.sms_settings for select using (public.caller_is_admin());
create policy "sms_settings admin update" on public.sms_settings for update
  using (public.caller_is_admin()) with check (public.caller_is_admin());
create policy "sms_log admin read" on public.sms_log for select using (public.caller_is_admin());

revoke all on public.sms_settings, public.sms_log from anon, authenticated;
grant select, update on public.sms_settings to authenticated;
grant select on public.sms_log to authenticated;

create or replace function public.sms_settings_touch()
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
revoke execute on function public.sms_settings_touch() from public, anon, authenticated;

drop trigger if exists trg_sms_settings_touch on public.sms_settings;
create trigger trg_sms_settings_touch before update on public.sms_settings
  for each row execute function public.sms_settings_touch();

-- ---- The phone number as the log keeps it: +<digits> -----------------------------
create or replace function public.sms_e164(p_phone text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when coalesce(regexp_replace(p_phone, '[^0-9]', '', 'g'), '') = '' then null
              else '+' || regexp_replace(p_phone, '[^0-9]', '', 'g') end;
$$;

-- ---- What to do with one request for a code ------------------------------------------
-- Null when it may be sent; otherwise the reason it may not.
create or replace function public.sms_otp_refusal(p_phone text, p_now timestamptz default now())
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.sms_settings;
begin
  select * into s from public.sms_settings where id = 1;
  if not found then
    return null;  -- no settings row: no extra limits
  end if;
  if not s.enabled then
    return 'disabled';
  end if;
  if p_phone is null then
    return 'no_number';
  end if;
  if p_phone = any (select public.sms_e164(b) from unnest(s.blocked_numbers) b) then
    return 'blocked_number';
  end if;
  if cardinality(s.allowed_prefixes) > 0
     and not exists (select 1 from unnest(s.allowed_prefixes) p where p_phone like public.sms_e164(p) || '%') then
    return 'prefix';
  end if;
  if exists (select 1 from public.sms_log
              where phone = p_phone and status = 'queued'
                and created_at > p_now - make_interval(secs => s.min_resend_seconds)) then
    return 'resend_too_soon';
  end if;
  if (select count(*) from public.sms_log
       where phone = p_phone and status = 'queued' and created_at > p_now - interval '1 hour') >= s.per_phone_per_hour then
    return 'per_phone_hour';
  end if;
  if (select count(*) from public.sms_log
       where phone = p_phone and status = 'queued' and created_at > p_now - interval '1 day') >= s.per_phone_per_day then
    return 'per_phone_day';
  end if;
  if (select count(*) from public.sms_log
       where status = 'queued' and created_at > p_now - interval '1 hour') >= s.global_per_hour then
    return 'global_hour';
  end if;
  -- A gateway phone has to be there to send it.
  if not exists (
    select 1 from public.messaging_routes r
      join public.messaging_devices d on d.id = any (r.device_ids)
     where r.channel = 'otp' and r.direction = 'outbound' and r.transport = 'sms' and r.enabled
       and d.last_seen_at > p_now - interval '10 minutes'
  ) then
    return 'gateway_offline';
  end if;
  return null;
end;
$$;
revoke execute on function public.sms_otp_refusal(text, timestamptz) from public, anon, authenticated;

-- What the person signing in is told for each refusal.
create or replace function public.sms_refusal_message(p_reason text, p_wait_seconds int default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object('error', jsonb_build_object(
    'http_code', case p_reason
                   when 'disabled' then 503 when 'gateway_offline' then 503
                   when 'blocked_number' then 403 when 'prefix' then 403 when 'no_number' then 400
                   else 429 end,
    'message', case p_reason
                 when 'disabled' then 'Sign-in by SMS is unavailable right now. Please try again later.'
                 when 'gateway_offline' then 'Sign-in by SMS is unavailable right now. Please try again later.'
                 when 'blocked_number' then 'This number can''t receive sign-in codes.'
                 when 'prefix' then 'Sign-in codes can''t be sent to this country yet.'
                 when 'no_number' then 'Enter a phone number to get a code.'
                 when 'resend_too_soon' then 'Please wait ' || coalesce(p_wait_seconds, 60) || ' seconds before asking for another code.'
                 when 'per_phone_hour' then 'Too many codes asked for this number. Please try again later.'
                 when 'per_phone_day' then 'You''ve reached today''s limit of codes for this number.'
                 when 'global_hour' then 'Sign-in by SMS is busy. Please try again in a few minutes.'
                 else 'The code couldn''t be sent. Please try again.' end));
$$;

-- ---- The hook ---------------------------------------------------------------------
create or replace function public.send_sms_hook(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := public.sms_e164(event #>> '{user,phone}');
  v_user  uuid;
  v_code  text := event #>> '{sms,otp}';
  v_reason text;
  v_template text;
  v_outbox uuid;
begin
  begin
    v_user := (event #>> '{user,id}')::uuid;
  exception when others then
    v_user := null;
  end;
  -- One request at a time per number, so two at once can't both pass.
  perform pg_advisory_xact_lock(hashtextextended('sms_otp|' || coalesce(v_phone, ''), 149));

  v_reason := public.sms_otp_refusal(v_phone);
  if v_reason is null and coalesce(v_code, '') = '' then
    v_reason := 'no_code';
  end if;
  if v_reason is not null then
    insert into public.sms_log (phone, user_id, status, reason) values (coalesce(v_phone, ''), v_user, 'blocked', v_reason);
    return public.sms_refusal_message(v_reason,
      (select min_resend_seconds from public.sms_settings where id = 1));
  end if;

  select message_template into v_template from public.sms_settings where id = 1;
  insert into public.sms_outbox (to_phone, body, channel, created_by)
  values (v_phone, replace(coalesce(v_template, 'Your GET.ride code is {code}. Do not share it.'), '{code}', v_code), 'otp', null)
  returning id into v_outbox;
  insert into public.sms_log (phone, user_id, status, outbox_id) values (v_phone, v_user, 'queued', v_outbox);
  return '{}'::jsonb;
exception when others then
  begin
    insert into public.sms_log (phone, user_id, status, reason)
    values (coalesce(v_phone, ''), v_user, 'failed', left(sqlerrm, 200));
  exception when others then
    null;
  end;
  return public.sms_refusal_message('error');
end;
$$;

-- Only Auth calls the hook.
revoke execute on function public.send_sms_hook(jsonb) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant usage on schema public to supabase_auth_admin';
    execute 'grant execute on function public.send_sms_hook(jsonb) to supabase_auth_admin';
  end if;
end $$;

-- ---- Admin: the last hour at a glance ---------------------------------------------------
create or replace function public.sms_activity_summary(p_hours int default 1)
returns table (queued bigint, blocked bigint, failed bigint)
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
  select count(*) filter (where l.status = 'queued'),
         count(*) filter (where l.status = 'blocked'),
         count(*) filter (where l.status = 'failed')
    from public.sms_log l
   where l.created_at > now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 1), 720)));
end;
$$;
revoke execute on function public.sms_activity_summary(int) from public, anon;
grant execute on function public.sms_activity_summary(int) to authenticated;

-- ---- Housekeeping and live updates --------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-sms-log';
    perform cron.schedule('purge-sms-log', '23 3 * * *',
      $job$delete from public.sms_log where created_at < now() - interval '90 days'$job$);
  end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sms_log') then
      alter publication supabase_realtime add table public.sms_log;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sms_settings') then
      alter publication supabase_realtime add table public.sms_settings;
    end if;
  end if;
end $$;

notify pgrst, 'reload schema';
