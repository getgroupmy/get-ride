-- ============================================================================
-- 0183: sign-in codes are for the phone they're sent to, not for the admin
-- panel (audit 14 Oct 2026).
--
-- Every admin, sub-admins included, could read sms_outbox, and a sign-in
-- code sat there in plain text (and went out on realtime) until it expired:
-- enough to sign in as anyone. Now:
--   * an OTP job's text is kept in sms_otp_secret, which no client can read;
--     the queue row shows it with the digits masked ("Your code is ••••••"),
--     so the admin panel still sees every job, its number and its status;
--   * only the gateway's claim (gateway_claim_sms) hands out the real text;
--   * admins can't queue OTP jobs by hand (only the sign-in hook does);
--   * a code still waiting after 10 minutes is no use to anyone: it is
--     failed as expired instead of being sent late after an outage;
--   * the queue and the secrets are purged (30 days, 1 day).
-- ============================================================================

create table if not exists public.sms_otp_secret (
  outbox_id  uuid primary key,
  body       text not null,
  created_at timestamptz not null default now()
);
alter table public.sms_otp_secret enable row level security;
revoke all on public.sms_otp_secret from public, anon, authenticated;

-- ---- The code leaves the queue row as it goes in -------------------------------------
create or replace function public.sms_outbox_hide_otp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.channel = 'otp' then
    insert into public.sms_otp_secret (outbox_id, body) values (new.id, new.body)
    on conflict (outbox_id) do update set body = excluded.body;
    new.body := regexp_replace(new.body, '[0-9]', '•', 'g');
  end if;
  return new;
end;
$$;
revoke execute on function public.sms_outbox_hide_otp() from public, anon, authenticated;

drop trigger if exists trg_sms_outbox_hide_otp on public.sms_outbox;
create trigger trg_sms_outbox_hide_otp
  before insert on public.sms_outbox
  for each row execute function public.sms_outbox_hide_otp();

-- Codes already in the queue: still-waiting ones keep working, all are masked.
insert into public.sms_otp_secret (outbox_id, body)
select id, body from public.sms_outbox where channel = 'otp' and status in ('queued', 'sending')
on conflict (outbox_id) do nothing;
update public.sms_outbox set body = regexp_replace(body, '[0-9]', '•', 'g')
 where channel = 'otp' and body ~ '[0-9]';

-- ---- Admins queue marketing and support messages, never codes ----------------------------
drop policy if exists "sms_outbox admin queue" on public.sms_outbox;
create policy "sms_outbox admin queue" on public.sms_outbox
  for insert to authenticated
  with check (public.caller_is_admin() and status = 'queued' and device_id is null and channel <> 'otp');

-- ---- The gateway gets the real text; late codes are dropped --------------------------------
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

  -- A sign-in code is valid for minutes: one still waiting is failed, not sent.
  update public.sms_outbox
     set status = 'failed', error = 'expired before sending'
   where channel = 'otp' and status in ('queued', 'sending')
     and created_at < now() - interval '10 minutes';

  return query
  with claimed as (
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
    returning o.*
  )
  select (jsonb_populate_record(null::public.sms_outbox,
            to_jsonb(c) || jsonb_build_object('body', coalesce(s.body, c.body)))).*
    from claimed c
    left join public.sms_otp_secret s on s.outbox_id = c.id;
end;
$function$;

revoke all on function public.gateway_claim_sms(uuid, integer) from public, anon;
grant execute on function public.gateway_claim_sms(uuid, integer) to authenticated;

-- ---- Housekeeping ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-sms-outbox';
    perform cron.schedule('purge-sms-outbox', '29 3 * * *',
      $job$delete from public.sms_otp_secret where created_at < now() - interval '1 day';
           delete from public.sms_outbox where created_at < now() - interval '30 days'$job$);
  end if;
end $$;
