-- ============================================================================
-- 0236: the admin sets the longest a sign-in code waits for the gateway phone.
--
-- Nothing tells the gateway phone an SMS is queued; it asks every 5 s while
-- busy, easing to every 10 s and then to a maximum when quiet. That maximum
-- (15 s until now, fixed in the app) is the longest a sign-in code can wait
-- before the phone picks it up. The admin now sets it, 5-60 seconds, in
-- Admin -> SMS / WhatsApp -> Sign-in SMS limits: shorter means faster codes
-- but more calls from the gateway phone to the server.
--
-- It sits with the other sign-in SMS settings (sms_settings, admin read and
-- write only). The paired phone has no account, so it can't read that
-- table: the device-key heartbeat (0190), which it calls once a minute,
-- now also answers with the value. Only a valid device key gets it.
--
-- Older gateway apps ignore the extra field; a gateway app newer than this
-- database finds no field and keeps 15 s.
-- ============================================================================

alter table public.sms_settings
  add column if not exists gateway_poll_max_seconds integer not null default 15
    check (gateway_poll_max_seconds between 5 and 60);

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
  return jsonb_build_object(
    'id', v_dev.id,
    'label', v_dev.label,
    'poll_max_seconds', coalesce((select gateway_poll_max_seconds from public.sms_settings where id = 1), 15));
end;
$$;

revoke execute on function public.gateway_key_heartbeat(text, text, text, text) from public;
grant execute on function public.gateway_key_heartbeat(text, text, text, text) to anon, authenticated;
