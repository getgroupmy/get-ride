-- ============================================================================
-- 0347: tell the admins when the self-hosted face match server (the NAS) goes
-- offline, and when it is back — the same idea as the SMS gateway alert
-- (0178), adapted for a server that is reached on demand rather than one that
-- checks in.
--
-- The face match server (deploy/face-server, on the office NAS behind a
-- Cloudflare Tunnel, _shared/face_server.ts) is only contacted when a face
-- comparison runs (a partner going online, a document check). If it is down
-- when nobody is going online, nothing notices until the next check fails
-- ("Couldn't check · NAS"). So a health ping runs on a schedule, like the
-- gateway:
--
--   * face_server_health (one row): the last state, when it was last OK, and
--     when its admins were told, so each outage is one push, not one a minute;
--   * a pg_cron job every minute invokes the `face-server-health` edge
--     function (face_server_health_tick, via pg_net + the Vault
--     push_webhook_secret, exactly as send_push_webhook invokes send-push).
--     That function reads the face server key (Admin → API Keys), pings its
--     /health, and reports the result;
--   * face_server_health_report(state, detail) records it: unreachable for 5
--     minutes → push "Face match server offline" to the face/selfie admins
--     (face_server_alert_admins); answering again → "back online". When no
--     face server is configured it reports 'disabled' and nothing is sent.
--
-- The push goes to the same admins the online-selfie alerts reach: those on a
-- Documents / Partners / Partner selfie checks page (or full access), plus the
-- admins picked in Dispatch → Partner selfie checks ('online_selfie'
-- alertAdmins).
-- ============================================================================

-- ---- 0. The state (one row) ----------------------------------------------------------------------
create table if not exists public.face_server_health (
  id                 boolean primary key default true check (id),
  state              text not null default 'unknown'
                       check (state in ('unknown', 'online', 'offline', 'disabled')),
  last_ok_at         timestamptz,
  last_checked_at    timestamptz,
  failing_since      timestamptz,
  offline_alerted_at timestamptz,
  detail             text check (detail is null or char_length(detail) <= 300)
);
comment on table public.face_server_health is
  'The self-hosted face match server''s reachability (0347): one row, written only by face_server_health_report from the scheduled health ping.';
insert into public.face_server_health (id) values (true) on conflict (id) do nothing;

alter table public.face_server_health enable row level security;
revoke all on public.face_server_health from public, anon, authenticated;
grant select on public.face_server_health to authenticated;
grant all on public.face_server_health to service_role;

-- Guard the create rather than "drop ... if exists" first: a DROP triggers a
-- destructive-operation confirmation that hangs the migration apply.
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'face_server_health'
       and policyname = 'face_server_health_read') then
    create policy face_server_health_read on public.face_server_health
      for select to authenticated using ((select public.caller_is_admin()));
  end if;
end $$;

-- ---- 1. Who to tell ------------------------------------------------------------------------------
-- The admins the online-selfie alerts reach (0290): a Documents / Partners /
-- Partner selfie checks page or full access, plus the admins picked in
-- Dispatch → Partner selfie checks ('online_selfie' alertAdmins).
create or replace function public.face_server_alert_admins()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select a.profile_id from public.admin_access a
   where a.page in ('*', 'admin-documents', 'admin-documents-users', 'admin-documents-partners',
                    'admin-partners', 'admin-partner-edit', 'admin-dispatch-selfie-checks')
  union
  select a.profile_id from public.admin_access a
   where a.profile_id::text in (
     select jsonb_array_elements_text(
       case when jsonb_typeof(public.online_selfie_settings() -> 'alertAdmins') = 'array'
            then public.online_selfie_settings() -> 'alertAdmins' else '[]'::jsonb end));
$$;
revoke execute on function public.face_server_alert_admins() from public, anon, authenticated;

-- ---- 2. Record a health result, and alert on a change --------------------------------------------
-- [p_state]: 'ok' (answered), 'down' (configured but unreachable), 'disabled'
-- (no face server configured). Pushes once when it has been down for 5
-- minutes, and once when it comes back. Called by the edge function with the
-- service role.
create or replace function public.face_server_health_report(p_state text, p_detail text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h       public.face_server_health;
  v_now   timestamptz := now();
  v_msg   jsonb;
  v_admin uuid;
  v_sent  int := 0;
  v_down  boolean;
begin
  select * into h from public.face_server_health where id;
  if not found then
    insert into public.face_server_health (id) values (true);
    select * into h from public.face_server_health where id;
  end if;

  if p_state = 'disabled' then
    -- No server configured (or its key was removed): stop watching, quietly.
    update public.face_server_health
       set state = 'disabled', failing_since = null, offline_alerted_at = null,
           last_checked_at = v_now, detail = p_detail
     where id;
    return jsonb_build_object('state', 'disabled', 'alerted', false);
  end if;

  if p_state = 'ok' then
    v_msg := null;
    if h.offline_alerted_at is not null then
      v_msg := jsonb_build_object(
        'title', 'Face match server back online',
        'body', 'The self-hosted face server is answering again.');
    end if;
    update public.face_server_health
       set state = 'online', last_ok_at = v_now, last_checked_at = v_now,
           failing_since = null, offline_alerted_at = null, detail = p_detail
     where id;
  else
    -- 'down': configured but the ping failed.
    update public.face_server_health
       set state = 'offline', last_checked_at = v_now, detail = p_detail,
           failing_since = coalesce(h.failing_since, v_now)
     where id
     returning * into h;
    v_msg := null;
    -- Been down for 5 minutes and the admins haven't been told yet.
    if h.offline_alerted_at is null and h.failing_since <= v_now - interval '5 minutes' then
      update public.face_server_health set offline_alerted_at = v_now where id;
      v_msg := jsonb_build_object(
        'title', 'Face match server offline',
        'body', 'The self-hosted face server has not answered for 5 minutes. '
          || 'Partners'' selfies can''t be face-matched against it until it is back. '
          || 'Check the server and its Cloudflare Tunnel.');
    end if;
  end if;

  if v_msg is not null then
    v_down := p_state <> 'ok';
    for v_admin in select public.face_server_alert_admins() loop
      perform public.approval_push_send(
        v_admin, v_msg, jsonb_build_object('type', 'face_server_status', 'online', not v_down));
      v_sent := v_sent + 1;
    end loop;
  end if;
  return jsonb_build_object('state', p_state, 'alerted', v_msg is not null, 'sent', v_sent);
end;
$$;
revoke execute on function public.face_server_health_report(text, text) from public, anon, authenticated;
grant execute on function public.face_server_health_report(text, text) to service_role;

-- ---- 3. The scheduled ping -----------------------------------------------------------------------
-- Invoke the face-server-health edge function, which does the actual /health
-- ping and calls face_server_health_report. Fire-and-forget via pg_net, with
-- the Vault push_webhook_secret, exactly as send_push_webhook (0128).
create or replace function public.face_server_health_tick()
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
    url     := v_url || '/functions/v1/face-server-health',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := '{}'::jsonb);
exception when others then
  null;
end;
$$;
revoke execute on function public.face_server_health_tick() from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'face-server-health',
      '* * * * *',
      $sql$select public.face_server_health_tick()$sql$
    );
  end if;
end
$$;

notify pgrst, 'reload schema';
