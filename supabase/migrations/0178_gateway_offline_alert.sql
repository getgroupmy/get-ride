-- ============================================================================
-- 0178: tell the admins when an SMS gateway phone goes offline, and when it
-- is back
--
-- Sign-in codes go out only through a GET.ride Gateway phone (0149 refuses
-- them with "Sign-in by SMS is unavailable" while none has checked in for
-- ten minutes). A phone that silently stopped — switched off, out of
-- battery, the app ended — went unnoticed until people could not sign in.
--
--   * messaging_devices.offline_alerted_at: when its admins were told, so
--     each outage is one push, not one a minute;
--   * gateway_offline_check(): every minute (pg_cron), for each gateway
--     phone on an enabled SMS route: no check-in for 5 minutes → push
--     "SMS gateway offline" to every admin with SMS / WhatsApp access (or
--     full access); checking in again → "SMS gateway back online".
-- ============================================================================

alter table public.messaging_devices
  add column if not exists offline_alerted_at timestamptz;

-- The admins who look after SMS / WhatsApp.
create or replace function public.gateway_alert_admins()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select distinct profile_id from public.admin_access
   where page in ('*', 'admin-settings-messaging', 'messaging');
$$;

create or replace function public.gateway_offline_check(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  d record;
  v_admin uuid;
  v_name text;
  v_msg jsonb;
  v_sent int := 0;
begin
  for d in
    select dev.id, dev.label, dev.sim_number, dev.offline_alerted_at,
           dev.last_seen_at < p_now - interval '5 minutes' as offline,
           bool_or(r.channel = 'otp' and r.direction = 'outbound') as carries_otp
      from public.messaging_devices dev
      join public.messaging_routes r on dev.id = any (r.device_ids)
     where dev.kind = 'gateway' and r.enabled and r.transport = 'sms'
     group by dev.id
  loop
    v_name := coalesce(nullif(btrim(d.label), ''), nullif(btrim(d.sim_number), ''), 'The gateway phone');
    if d.offline and d.offline_alerted_at is null then
      update public.messaging_devices set offline_alerted_at = p_now where id = d.id;
      v_msg := jsonb_build_object(
        'title', 'SMS gateway offline',
        'body', v_name || ' has not checked in for 5 minutes. '
          || case when d.carries_otp then 'Sign-in codes can''t be sent until it is back. ' else '' end
          || 'Check the phone and open the GET.ride Gateway app.'
      );
    elsif not d.offline and d.offline_alerted_at is not null then
      update public.messaging_devices set offline_alerted_at = null where id = d.id;
      v_msg := jsonb_build_object(
        'title', 'SMS gateway back online',
        'body', v_name || ' is sending again.'
      );
    else
      continue;
    end if;
    for v_admin in select public.gateway_alert_admins() loop
      perform public.approval_push_send(
        v_admin,
        v_msg,
        jsonb_build_object('type', 'gateway_status', 'device', d.id, 'online', not d.offline)
      );
      v_sent := v_sent + 1;
    end loop;
  end loop;
  return v_sent;
end;
$$;

revoke execute on function public.gateway_alert_admins() from public, anon, authenticated;
revoke execute on function public.gateway_offline_check(timestamptz) from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'gateway-offline-check',
      '* * * * *',
      $sql$select public.gateway_offline_check()$sql$
    );
  end if;
end
$$;
