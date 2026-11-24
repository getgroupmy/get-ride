-- ============================================================================
-- 0440: tell the admins when a monitored server (Admin → API Keys) goes
-- offline, and when it is back — the per-provider version of the face server
-- (0347) and Waze (0411) watchers, switched on per provider by the admin.
--
-- Admin → API Keys lists the app's providers; several are self-hosted servers
-- behind a Cloudflare Tunnel (GET eKYC, Umami/NAS, a custom OSRM/Overpass),
-- only reached when something needs them, so one going down is unnoticed until
-- a check fails. A "Monitor this server" switch on a provider (the provider's
-- `monitor` flag in the api_providers row) turns on a scheduled health ping;
-- when the server stops answering the admins are pushed, again every 6 hours
-- while it stays down, and once when it is back.
--
--   * provider_health: one row per monitored provider id — its last state,
--     when it was last OK, and when the admins were last told, so each outage
--     is one push (plus a re-nudge while it stays down);
--   * a pg_cron job every minute invokes the `provider-health` edge function
--     (provider_health_tick, pg_net + the Vault push_webhook_secret, exactly
--     as face_server_health_tick 0347). It reads the monitored providers,
--     pings each server's /health, and reports the result;
--   * provider_health_report(id, label, state, detail): unreachable for 5
--     minutes → push "<server> offline"; still down 6 hours later → push
--     again; answering again → "back online". provider_health_prune(ids)
--     drops servers switched off or removed, quietly.
--
-- Only connectivity counts as down: a timeout, a refused connection or a 5xx
-- (a Cloudflare 530 when a tunnel drops). A server that answers at all — a
-- 401 or a 404 included — is up; a wrong key is the Test button's job, not an
-- outage. The push goes to full-access admins and those on the API Keys page.
--
-- The face match server (0347) keeps its own built-in watcher, so this one
-- skips it (see _shared/provider_health.ts BUILTIN_WATCHED).
-- ============================================================================

-- ---- 0. The state (one row per monitored provider) ----------------------------------------------
create table if not exists public.provider_health (
  provider_id        text primary key check (char_length(provider_id) between 1 and 100),
  label              text check (label is null or char_length(label) <= 100),
  state              text not null default 'unknown'
                       check (state in ('unknown', 'online', 'offline')),
  last_ok_at         timestamptz,
  last_checked_at    timestamptz,
  failing_since      timestamptz,
  offline_alerted_at timestamptz,
  detail             text check (detail is null or char_length(detail) <= 300)
);
comment on table public.provider_health is
  'Each monitored API-Keys server''s reachability (0440): written only by provider_health_report from the scheduled health ping.';

alter table public.provider_health enable row level security;
revoke all on public.provider_health from public, anon, authenticated;
grant select on public.provider_health to authenticated;
grant all on public.provider_health to service_role;

-- Guard the create rather than "drop ... if exists" first: a DROP triggers a
-- destructive-operation confirmation that hangs the migration apply.
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'provider_health'
       and policyname = 'provider_health_read') then
    create policy provider_health_read on public.provider_health
      for select to authenticated using ((select public.caller_is_admin()));
  end if;
end $$;

-- ---- 1. Who to tell -----------------------------------------------------------------------------
-- Full-access admins and those on the API Keys page.
create or replace function public.provider_health_alert_admins()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select distinct profile_id from public.admin_access
   where page in ('*', 'admin-settings-api-keys');
$$;
revoke execute on function public.provider_health_alert_admins() from public, anon, authenticated;

-- ---- 2. Record a health result, and alert on a change -------------------------------------------
-- [p_state]: 'ok' (the server answered) or 'down' (unreachable: a timeout, a
-- refused connection or a 5xx). Pushes once when a server has been down for 5
-- minutes, again every 6 hours while it stays down, and once when it is back.
-- Called by the edge function with the service role.
create or replace function public.provider_health_report(
  p_provider_id text,
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
  h       public.provider_health;
  v_now   timestamptz := now();
  v_name  text := coalesce(nullif(btrim(left(p_label, 100)), ''), 'A server');
  v_msg   jsonb;
  v_admin uuid;
  v_sent  int := 0;
begin
  if p_provider_id is null or btrim(p_provider_id) = '' or p_state not in ('ok', 'down') then
    raise exception 'PROVIDER_HEALTH_BAD_REPORT';
  end if;
  insert into public.provider_health (provider_id, label) values (left(p_provider_id, 100), left(p_label, 100))
    on conflict (provider_id) do nothing;
  select * into h from public.provider_health where provider_id = left(p_provider_id, 100) for update;

  v_msg := null;
  if p_state = 'ok' then
    if h.offline_alerted_at is not null then
      v_msg := jsonb_build_object(
        'title', v_name || ' back online',
        'body', v_name || ' is answering again.');
    end if;
    update public.provider_health
       set label = left(p_label, 100), state = 'online', last_ok_at = v_now, last_checked_at = v_now,
           failing_since = null, offline_alerted_at = null, detail = null
     where provider_id = h.provider_id;
  else
    update public.provider_health
       set label = left(p_label, 100), state = 'offline', last_checked_at = v_now,
           detail = left(p_detail, 300), failing_since = coalesce(h.failing_since, v_now)
     where provider_id = h.provider_id
     returning * into h;
    if h.offline_alerted_at is null and h.failing_since <= v_now - interval '5 minutes' then
      -- First alert: down for 5 minutes.
      update public.provider_health set offline_alerted_at = v_now where provider_id = h.provider_id;
      v_msg := jsonb_build_object(
        'title', v_name || ' offline',
        'body', v_name || ' has not answered for 5 minutes'
          || coalesce(' (' || left(p_detail, 160) || ')', '') || '. '
          || 'Check the server and its Cloudflare Tunnel.');
    elsif h.offline_alerted_at is not null and h.offline_alerted_at <= v_now - interval '6 hours' then
      -- Re-nudge: still down 6 hours after the last alert.
      update public.provider_health set offline_alerted_at = v_now where provider_id = h.provider_id;
      v_msg := jsonb_build_object(
        'title', v_name || ' still offline',
        'body', v_name || ' has still not answered'
          || coalesce(' (' || left(p_detail, 160) || ')', '') || '. '
          || 'Check the server and its Cloudflare Tunnel.');
    end if;
  end if;

  if v_msg is not null then
    for v_admin in select public.provider_health_alert_admins() loop
      perform public.approval_push_send(
        v_admin, v_msg,
        jsonb_build_object('type', 'provider_server_status', 'provider', h.provider_id, 'online', p_state = 'ok'));
      v_sent := v_sent + 1;
    end loop;
  end if;
  return jsonb_build_object('state', p_state, 'alerted', v_msg is not null, 'sent', v_sent);
end;
$$;
revoke execute on function public.provider_health_report(text, text, text, text) from public, anon, authenticated;
grant execute on function public.provider_health_report(text, text, text, text) to service_role;

-- Forget every provider not in [p_keep] (its monitor was switched off, or it
-- was removed), quietly: no push for a server the admin stopped watching.
create or replace function public.provider_health_prune(p_keep text[])
returns int
language sql
security definer
set search_path = public
as $$
  with gone as (
    delete from public.provider_health
     where not (provider_id = any (coalesce(p_keep, '{}'::text[])))
    returning 1)
  select count(*)::int from gone;
$$;
revoke execute on function public.provider_health_prune(text[]) from public, anon, authenticated;
grant execute on function public.provider_health_prune(text[]) to service_role;

-- ---- 3. The scheduled ping ----------------------------------------------------------------------
-- Invoke the provider-health edge function, which pings the monitored servers
-- and reports each. Fire-and-forget via pg_net with the Vault
-- push_webhook_secret, exactly as face_server_health_tick (0347).
create or replace function public.provider_health_tick()
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
    url     := v_url || '/functions/v1/provider-health',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := '{}'::jsonb);
exception when others then
  null;
end;
$$;
revoke execute on function public.provider_health_tick() from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'provider-health',
      '* * * * *',
      $sql$select public.provider_health_tick()$sql$
    );
  end if;
end
$$;

notify pgrst, 'reload schema';
