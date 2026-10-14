-- ============================================================================
-- 0188: the admin sets how long a sign-in code is good for (Admin -> SMS).
--
-- Supabase Auth checks the code against its own "SMS OTP Expiry" (dashboard:
-- Authentication -> Phone), which this database can't change; the admin keeps
-- the two equal. Here it decides the queue's side: a code the gateway hasn't
-- sent within that time is failed as expired instead of reaching a phone
-- already dead (0183 used a fixed 10 minutes). Default 5 minutes.
-- ============================================================================

alter table public.sms_settings
  add column if not exists code_valid_minutes integer not null default 5
    check (code_valid_minutes between 1 and 60);

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
