-- Regression test for the provider health watcher (migration 0440):
-- provider_health_report's down → 5 min → alert → re-nudge (6 h) → recovery
-- flow, and provider_health_prune. Run by the Backend workflow's
-- migrations-replay job (psql, ON_ERROR_STOP) on a fresh database.
--
-- The push itself is not exercised here: a fresh database has no admin_access
-- rows, so provider_health_alert_admins() returns none and nothing is sent;
-- 'alerted' in the result reflects only whether a message was built.
begin;

-- 1. A fresh 'down' does not alert (not yet down for 5 minutes).
do $$
declare r jsonb;
begin
  r := public.provider_health_report('t_ekyc', 'GET eKYC', 'down', 'timeout');
  if (r->>'alerted')::bool then raise exception '1: a fresh down should not alert: %', r; end if;
  if (select state from public.provider_health where provider_id = 't_ekyc') <> 'offline'
    then raise exception '1: state should be offline'; end if;
end $$;

-- 2. Down for more than 5 minutes: the first alert fires.
update public.provider_health set failing_since = now() - interval '6 minutes' where provider_id = 't_ekyc';
do $$
declare r jsonb;
begin
  r := public.provider_health_report('t_ekyc', 'GET eKYC', 'down', 'timeout');
  if not (r->>'alerted')::bool then raise exception '2: down 6 min should alert: %', r; end if;
  if (select offline_alerted_at from public.provider_health where provider_id = 't_ekyc') is null
    then raise exception '2: offline_alerted_at should be set'; end if;
end $$;

-- 3. Still down, just alerted: no repeat.
do $$
declare r jsonb;
begin
  r := public.provider_health_report('t_ekyc', 'GET eKYC', 'down', 'timeout');
  if (r->>'alerted')::bool then raise exception '3: should not re-alert so soon: %', r; end if;
end $$;

-- 4. Still down 6 hours after the last alert: a re-nudge.
update public.provider_health set offline_alerted_at = now() - interval '7 hours' where provider_id = 't_ekyc';
do $$
declare r jsonb;
begin
  r := public.provider_health_report('t_ekyc', 'GET eKYC', 'down', 'timeout');
  if not (r->>'alerted')::bool then raise exception '4: re-nudge after 6 h should alert: %', r; end if;
end $$;

-- 5. Back up: a recovery alert, and the state is cleared.
do $$
declare r jsonb;
begin
  r := public.provider_health_report('t_ekyc', 'GET eKYC', 'ok', null);
  if not (r->>'alerted')::bool then raise exception '5: recovery should alert: %', r; end if;
  if (select state from public.provider_health where provider_id = 't_ekyc') <> 'online'
    then raise exception '5: state should be online'; end if;
  if (select offline_alerted_at from public.provider_health where provider_id = 't_ekyc') is not null
    then raise exception '5: offline_alerted_at should be cleared'; end if;
end $$;

-- 6. Already up: an 'ok' report does not alert.
do $$
declare r jsonb;
begin
  r := public.provider_health_report('t_ekyc', 'GET eKYC', 'ok', null);
  if (r->>'alerted')::bool then raise exception '6: ok when already up should not alert: %', r; end if;
end $$;

-- 7. A bad state is rejected.
do $$
declare raised boolean := false;
begin
  begin
    perform public.provider_health_report('t_ekyc', 'GET eKYC', 'maybe', null);
  exception when others then raised := true;
  end;
  if not raised then raise exception '7: a bad state should raise'; end if;
end $$;

-- 8. prune drops the providers not kept and keeps the rest.
select public.provider_health_report('t_umami', 'Umami', 'ok', null);
do $$
declare dropped int;
begin
  dropped := public.provider_health_prune(array['t_umami']);
  if dropped <> 1 then raise exception '8: prune should drop 1 (t_ekyc), dropped %', dropped; end if;
  if exists (select 1 from public.provider_health where provider_id = 't_ekyc')
    then raise exception '8: t_ekyc should be pruned'; end if;
  if not exists (select 1 from public.provider_health where provider_id = 't_umami')
    then raise exception '8: t_umami should remain'; end if;
end $$;

rollback;
