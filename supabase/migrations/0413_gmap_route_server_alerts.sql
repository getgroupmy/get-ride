-- 0413 — Google Maps route servers share the route-server health alerts
-- ---------------------------------------------------------------------------
-- The fare order (Admin › Settings › Fare AI provider, fare_ai_provider.chain)
-- gains a "gmap" step: Google Maps' live route from the Traffic Scraper on the
-- office NAS (getgroupmy/get.route.backup). It answers GET.route's API, so
-- waze-server-health checks its servers (`gmapServers`) with the Waze ones,
-- into the same waze_server_health table (0411). Their labels say which is
-- which ("Google Maps server 1").
--
-- Only the push wording changes here: "Waze server offline" would misname a
-- Google Maps server, so the alerts say "Route server" and the server's own
-- label. The push type stays 'waze_server_status', so nothing that routes on
-- it changes. Same signature and grants as 0411.
-- ---------------------------------------------------------------------------

create or replace function public.waze_server_health_report(
  p_server_id text,
  p_label text,
  p_state text,
  p_detail text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h       public.waze_server_health;
  v_now   timestamptz := now();
  v_name  text := coalesce(nullif(btrim(left(p_label, 100)), ''), 'A route server');
  v_msg   jsonb;
  v_admin uuid;
  v_sent  int := 0;
begin
  if p_server_id is null or btrim(p_server_id) = '' or p_state not in ('ok', 'down') then
    raise exception 'WAZE_HEALTH_BAD_REPORT';
  end if;
  insert into public.waze_server_health (server_id, label) values (left(p_server_id, 100), left(p_label, 100))
    on conflict (server_id) do nothing;
  select * into h from public.waze_server_health where server_id = left(p_server_id, 100) for update;

  v_msg := null;
  if p_state = 'ok' then
    if h.offline_alerted_at is not null then
      v_msg := jsonb_build_object(
        'title', 'Route server back online',
        'body', v_name || ' is answering fares again.');
    end if;
    update public.waze_server_health
       set label = left(p_label, 100), state = 'online', last_ok_at = v_now, last_checked_at = v_now,
           failing_since = null, offline_alerted_at = null, detail = null
     where server_id = h.server_id;
  else
    update public.waze_server_health
       set label = left(p_label, 100), state = 'offline', last_checked_at = v_now,
           detail = left(p_detail, 300), failing_since = coalesce(h.failing_since, v_now)
     where server_id = h.server_id
     returning * into h;
    if h.offline_alerted_at is null and h.failing_since <= v_now - interval '5 minutes' then
      update public.waze_server_health set offline_alerted_at = v_now where server_id = h.server_id;
      v_msg := jsonb_build_object(
        'title', 'Route server offline',
        'body', v_name || ' has not been working for 5 minutes'
          || coalesce(' (' || left(p_detail, 160) || ')', '') || '. '
          || 'Fares in its area use the next server or the next step of the fare order until it is back. '
          || 'Check the NAS container and its Cloudflare Tunnel.');
    end if;
  end if;

  if v_msg is not null then
    for v_admin in select public.waze_server_alert_admins() loop
      perform public.approval_push_send(
        v_admin, v_msg,
        jsonb_build_object('type', 'waze_server_status', 'server', h.server_id, 'online', p_state = 'ok'));
      v_sent := v_sent + 1;
    end loop;
  end if;
  return jsonb_build_object('state', p_state, 'alerted', v_msg is not null, 'sent', v_sent);
end;
$$;
revoke execute on function public.waze_server_health_report(text, text, text, text) from public, anon, authenticated;
grant execute on function public.waze_server_health_report(text, text, text, text) to service_role;
