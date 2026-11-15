-- ============================================================================
-- 0411: tell the admins when a Waze route server (GET.route) goes offline, and
-- when it is back — the SMS gateway alert (0178) as the face match server has
-- it (0347), once per server.
--
-- Admin → Settings → Fare AI provider can take fares from Waze through
-- GET.route servers: containers on the office NAS behind a Cloudflare Tunnel,
-- one per area (`fare_ai_provider.wazeServers`, _shared/waze_route.ts). They
-- are only called when a rider asks for a fare, so a server that stopped (the
-- NAS, its tunnel, or Waze refusing its tokens) goes unnoticed until fares
-- fall back. So, like the face server:
--
--   * waze_server_health: one row per server id: its last state, when it was
--     last OK, and when its admins were told, so each outage is one push;
--   * a pg_cron job every minute invokes the `waze-server-health` edge
--     function (waze_server_health_tick, pg_net + the Vault
--     push_webhook_secret, as face_server_health_tick). It pings each
--     enabled server's /health with its key: GET.route answers whether its
--     latest Waze call worked, so no Waze call is spent on the check;
--   * waze_server_health_report(id, label, state, detail): down for 5
--     minutes → push "Waze server offline" to the Fare AI admins; answering
--     again → "back online". waze_server_health_prune(ids) drops servers that
--     were removed, switched off, or all of them when Waze is not the source.
--
-- The push goes to admins with Fare AI access (admin-settings-fare-ai) or
-- full access.
-- ============================================================================

-- ---- 0. The state (one row per server) ----------------------------------------------------------
create table if not exists public.waze_server_health (
  server_id          text primary key check (char_length(server_id) between 1 and 100),
  label              text check (label is null or char_length(label) <= 100),
  state              text not null default 'unknown'
                       check (state in ('unknown', 'online', 'offline')),
  last_ok_at         timestamptz,
  last_checked_at    timestamptz,
  failing_since      timestamptz,
  offline_alerted_at timestamptz,
  detail             text check (detail is null or char_length(detail) <= 300)
);
comment on table public.waze_server_health is
  'Each GET.route Waze server''s reachability (0411): written only by waze_server_health_report from the scheduled health ping.';

alter table public.waze_server_health enable row level security;
revoke all on public.waze_server_health from public, anon, authenticated;
grant select on public.waze_server_health to authenticated;
grant all on public.waze_server_health to service_role;

-- Guard the create rather than "drop ... if exists" first (a DROP asks for a
-- destructive-operation confirmation that hangs the apply).
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'waze_server_health'
       and policyname = 'waze_server_health_read') then
    create policy waze_server_health_read on public.waze_server_health
      for select to authenticated using ((select public.caller_is_admin()));
  end if;
end $$;

-- ---- 1. Who to tell ------------------------------------------------------------------------------
create or replace function public.waze_server_alert_admins()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select distinct profile_id from public.admin_access
   where page in ('*', 'admin-settings-fare-ai');
$$;
revoke execute on function public.waze_server_alert_admins() from public, anon, authenticated;

-- ---- 2. Record a health result, and alert on a change --------------------------------------------
-- [p_state]: 'ok' (answered, and its last Waze call worked) or 'down'. Pushes
-- once when a server has been down for 5 minutes, and once when it is back.
-- Called by the edge function with the service role.
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
  v_name  text := coalesce(nullif(btrim(left(p_label, 100)), ''), 'A Waze server');
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
        'title', 'Waze server back online',
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
        'title', 'Waze server offline',
        'body', v_name || ' has not been working for 5 minutes'
          || coalesce(' (' || left(p_detail, 160) || ')', '') || '. '
          || 'Fares in its area use the next Waze server or the fallback until it is back. '
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

-- Forget every server not in [p_keep] (removed, switched off, or Waze is no
-- longer the source), quietly: no push for a server the admin took away.
create or replace function public.waze_server_health_prune(p_keep text[])
returns int
language sql
security definer
set search_path = public
as $$
  with gone as (
    delete from public.waze_server_health
     where not (server_id = any (coalesce(p_keep, '{}'::text[])))
    returning 1)
  select count(*)::int from gone;
$$;
revoke execute on function public.waze_server_health_prune(text[]) from public, anon, authenticated;
grant execute on function public.waze_server_health_prune(text[]) to service_role;

-- ---- 3. The scheduled ping -----------------------------------------------------------------------
-- Invoke the waze-server-health edge function, which pings the servers and
-- reports each. Fire-and-forget via pg_net with the Vault push_webhook_secret,
-- exactly as face_server_health_tick (0347).
create or replace function public.waze_server_health_tick()
returns void
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
    return;
  end;
  if v_url is null or v_secret is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/waze-server-health',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := '{}'::jsonb);
exception when others then
  null;
end;
$$;
revoke execute on function public.waze_server_health_tick() from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'waze-server-health',
      '* * * * *',
      $sql$select public.waze_server_health_tick()$sql$
    );
  end if;
end
$$;

notify pgrst, 'reload schema';
