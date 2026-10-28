-- ============================================================================
-- Regression test for migration 0318: Office NAS backups and uptime.
--   * the settings are read leniently and clamped, like
--     lib/src/core/office_nas.dart;
--   * pairing: only a full admin makes a code; it works once; a wrong code
--     is counted; the key's hash only;
--   * the NAS's check-in fills nas_services, gets the settings without the
--     alert addresses, its targets ({payment} filled in) and the waiting
--     "Back up now" once;
--   * a run starts and finishes; a failed one alerts (push to the full
--     admins, WhatsApp/SMS, Telegram and email left for the function);
--   * uptime: an incident after failAfter failed checks in a row, "resolved"
--     when back; a stale source doesn't hold it open; gateway phones from
--     their last check-in; the 30-day counts;
--   * targets: add, change, built-ins kept; who may do what; no direct reads.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/nas_backups_uptime_0318.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people and devices only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000318a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000318a2'),  -- admin, EDIT on Office NAS
  ('00000000-0000-0000-0000-0000000318a3'),  -- admin, READ on Office NAS
  ('00000000-0000-0000-0000-0000000318c1')   -- not an admin
on conflict do nothing;
insert into public.profiles (id, name) select id, 'NAS test ' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000318%'
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000318a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000318a2', 'admin-settings-office-nas', 'edit'),
  ('00000000-0000-0000-0000-0000000318a3', 'admin-settings-office-nas', 'read')
on conflict do nothing;

-- Start from nothing of ours (a database that already has a NAS keeps it
-- outside this transaction).
delete from public.uptime_alerts;
delete from public.uptime_incidents;
delete from public.uptime_state;
delete from public.uptime_daily;
delete from public.uptime_checks;
delete from public.nas_backup_requests;
delete from public.backup_runs;
delete from public.nas_ops_agents;
delete from public.nas_ops_pair_failures;
delete from public.office_nas_settings;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'service_role', true);
end $$;
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'none', true);
end $$;
-- Whether calling p_sql raises.
create or replace function pg_temp.refused(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end $$;

-- ---- Settings, read leniently --------------------------------------------------------------------
select pg_temp.check(public.nas_backup_normalize(null) = jsonb_build_object(
  'on', true, 'at', '02:00', 'timezone', 'Asia/Kuala_Lumpur', 'keepNightly', 30, 'keepMonthly', 12,
  'skipBuckets', '[]'::jsonb, 'restoreTest', jsonb_build_object('on', true, 'day', 1),
  'offsite', jsonb_build_object('where', 'none', 'lastCopyOn', null)), 'backup defaults');
select pg_temp.check(public.nas_backup_normalize(
  '{"at": "25:00", "timezone": "x; drop", "keepNightly": 9999, "keepMonthly": "3", "skipBuckets": ["a", " a ", "", "b"],
    "restoreTest": {"day": 31, "on": false}, "offsite": {"where": "b2", "lastCopyOn": "2026-10-27"}}')
  = jsonb_build_object(
  'on', true, 'at', '02:00', 'timezone', 'Asia/Kuala_Lumpur', 'keepNightly', 365, 'keepMonthly', 3,
  'skipBuckets', '["a", "b"]'::jsonb, 'restoreTest', jsonb_build_object('on', false, 'day', 28),
  'offsite', jsonb_build_object('where', 'b2', 'lastCopyOn', '2026-10-27')), 'backup clamped');
select pg_temp.check(public.nas_uptime_normalize(null) = jsonb_build_object(
  'failAfter', 2, 'nasEveryMinutes', 1, 'cloudEveryMinutes', 5, 'slowMs', 3000, 'gatewayLateMinutes', 3,
  'gatewayDownMinutes', 10, 'channels', jsonb_build_object('push', true, 'telegram', false, 'sms', false, 'email', false),
  'telegramChats', '[]'::jsonb, 'smsNumbers', '[]'::jsonb, 'emails', '[]'::jsonb, 'emailFrom', null), 'uptime defaults');
select pg_temp.check((public.nas_uptime_normalize('{"failAfter": 0, "gatewayLateMinutes": 30, "gatewayDownMinutes": 5}')
  - array['channels', 'telegramChats', 'smsNumbers', 'emails', 'emailFrom'])
  = '{"failAfter": 1, "nasEveryMinutes": 1, "cloudEveryMinutes": 5, "slowMs": 3000, "gatewayLateMinutes": 30, "gatewayDownMinutes": 31}',
  'uptime clamped: down after late');

-- ---- Who may change the settings -----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a2');
select pg_temp.check((public.admin_nas_backup_set('{"at": "03:30", "keepNightly": 14, "skipBuckets": ["ai-reports"]}') ->> 'at') = '03:30',
  'EDIT on Office NAS saves the backup settings');
select pg_temp.check((public.admin_nas_uptime_set(
  '{"failAfter": 2, "channels": {"push": true, "telegram": true, "sms": true, "email": false},
    "telegramChats": ["-100123"], "smsNumbers": ["+60120000318"], "emails": ["ops@example.com"]}') ->> 'failAfter') = '2',
  'EDIT on Office NAS saves the uptime settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a3');
select pg_temp.check(pg_temp.refused($$select public.admin_nas_backup_set('{}')$$), 'READ can''t save the backups');
select pg_temp.check(pg_temp.refused($$select public.admin_nas_uptime_set('{}')$$), 'READ can''t save the monitor');
select pg_temp.check(pg_temp.refused($$select public.admin_uptime_test_alert()$$), 'READ can''t send a test');
select pg_temp.check((public.admin_office_nas() -> 'backup' ->> 'at') = '03:30', 'READ sees the page');
select pg_temp.check(pg_temp.refused($$select count(*) from public.office_nas_settings$$), 'no direct read of the settings');
select pg_temp.check(pg_temp.refused($$select count(*) from public.uptime_checks$$), 'no direct read of the checks');
select pg_temp.check(pg_temp.refused($$select count(*) from public.nas_ops_agents$$), 'no direct read of the keys');
select pg_temp.as_user('00000000-0000-0000-0000-0000000318c1');
select pg_temp.check(pg_temp.refused($$select public.admin_office_nas()$$), 'not an admin: no page');
select pg_temp.check((select count(*) from public.backup_runs) = 0, 'not an admin: no runs');
select pg_temp.check(pg_temp.refused($$select public.nas_ops_heartbeat('x')$$), 'the NAS calls are the server''s');

-- ---- Pairing ---------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a2');
select pg_temp.check(pg_temp.refused($$select public.admin_nas_ops_pairing_code('DS224+')$$),
  'only a full admin connects the NAS');
select pg_temp.check(pg_temp.refused($$select public.admin_nas_backup_request('backup')$$),
  'nothing to back up with before the NAS is connected');
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a1');
create temp table t_code on commit drop as select public.admin_nas_ops_pairing_code('DS224+ office') as c;
grant select on t_code to service_role, authenticated;
select pg_temp.check((select c ->> 'code' from t_code) ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$', 'a XXXX-XXXX code');

select pg_temp.as_server();
select pg_temp.check((public.nas_ops_pair('WRONG-CODE', 'nas-318') ->> 'error') = 'NAS_PAIR_CODE', 'a wrong code');
create temp table t_key on commit drop as
  select public.nas_ops_pair((select lower(c ->> 'code') from t_code), 'nas-318', null, 'DS224+ · J4125', '1.0.0') as k;
select pg_temp.check(length(k ->> 'key') = 64 and k ->> 'label' = 'DS224+ office', 'the code gives a key and the name')
  from t_key;
select pg_temp.check((public.nas_ops_pair((select c ->> 'code' from t_code), 'nas-other') ->> 'error') = 'NAS_PAIR_CODE',
  'a code works once');
select pg_temp.as_db();
select pg_temp.check((select count(*) from public.nas_ops_pair_failures) = 2, 'wrong codes are counted');
select pg_temp.check((select key_hash from public.nas_ops_agents) = public.gateway_secret_hash((select k ->> 'key' from t_key)),
  'only the key''s hash is kept');

-- ---- The NAS checks in -------------------------------------------------------------------------
update public.settings_entries set active = false where category = 'payment-gateway';
insert into public.settings_entries (category, values, active)
values ('payment-gateway', '{"providerId": "billplz", "isDefault": true}', true);

select pg_temp.as_user('00000000-0000-0000-0000-0000000318a2');
create temp table t_req on commit drop as select public.admin_nas_backup_request('backup') as r;
grant select on t_req to service_role, authenticated;
select pg_temp.check((public.admin_nas_backup_request('backup') ->> 'id') = (select r ->> 'id' from t_req),
  'one waiting "Back up now" at a time');

select pg_temp.as_server();
create temp table t_beat on commit drop as
  select public.nas_ops_heartbeat((select k ->> 'key' from t_key), 'DS224+', '1.0.1',
    '{"backup": {"status": "ok", "detail": {"buckets": ["avatars", "ID_Image"]}},
      "box": {"status": "ok", "detail": {"memUsedMb": 9100}}, "maps": {"status": "x"}}') as b;
grant select on t_beat to service_role, authenticated;
select pg_temp.check((b -> 'backup' ->> 'at') = '03:30', 'the NAS gets the backup settings') from t_beat;
select pg_temp.check(not (b -> 'uptime' ? 'smsNumbers') and not (b -> 'uptime' ? 'channels')
                     and (b -> 'uptime' ->> 'failAfter') = '2', 'but not where alerts go') from t_beat;
select pg_temp.check((select string_agg(t ->> 'id', ',' order by t ->> 'id') from jsonb_array_elements(b -> 'targets') t)
  = 'admin,database,functions,payment,website', 'the NAS checks the network targets') from t_beat;
select pg_temp.check((select t ->> 'url' from jsonb_array_elements(b -> 'targets') t where t ->> 'id' = 'payment')
  = 'https://www.billplz.com', '{payment} is the gateway in use') from t_beat;
select pg_temp.check(jsonb_array_length(b -> 'requests') = 1 and (b -> 'requests' -> 0 ->> 'kind') = 'backup',
  'the waiting backup is handed over') from t_beat;
select pg_temp.check(jsonb_array_length(public.nas_ops_heartbeat((select k ->> 'key' from t_key)) -> 'requests') = 0,
  'only once');
select pg_temp.check(pg_temp.refused($$select public.nas_ops_heartbeat(repeat('0', 64))$$), 'an unknown key is refused');
select pg_temp.as_db();
select pg_temp.check((select string_agg(service, ',' order by service) from public.nas_services
                       where service in ('backup', 'box', 'maps', 'uptime')) = 'backup,box', 'nas_services: only ours');

-- ---- Runs -----------------------------------------------------------------------------------------
select pg_temp.as_server();
create temp table t_run on commit drop as
  select public.nas_backup_started((select k ->> 'key' from t_key), 'backup', 'manual', (select (r ->> 'id')::uuid from t_req)) as id;
grant select on t_run to service_role, authenticated;
select pg_temp.check(public.nas_backup_finished((select k ->> 'key' from t_key), (select id from t_run), true,
  1800000000, 3104, 5000000, 1805000000, null, '{"buckets": 9}') = 'ok', 'a backup finishes');
select pg_temp.check(public.nas_backup_finished((select k ->> 'key' from t_key), (select id from t_run), false) = 'not_yours',
  'a finished run stays finished');
create temp table t_run2 on commit drop as
  select public.nas_backup_started((select k ->> 'key' from t_key), 'restore_test') as id;
grant select on t_run2 to service_role, authenticated;
select pg_temp.check(public.nas_backup_finished((select k ->> 'key' from t_key), (select id from t_run2), false,
  p_error => 'profiles came back empty') = 'failed', 'a restore test fails');
select pg_temp.as_db();
select pg_temp.check((select trigger = 'manual' and files = 3104 and total_bytes = 1805000000 from public.backup_runs
                       where id = (select id from t_run)), 'the run is kept with its sizes');
select pg_temp.check((select run_id from public.nas_backup_requests where id = (select (r ->> 'id')::uuid from t_req))
  = (select id from t_run), 'the request points at its run');
select pg_temp.check((select count(*) from public.uptime_alerts where kind = 'restore_failed'
                       and telegram = 'pending' and email = 'off' and sms_count = 1
                       and push_count = (select count(distinct a.profile_id) from public.admin_access a
                                          join public.profiles p on p.id = a.profile_id where a.page = '*')) = 1,
  'a failed restore test alerts: push to every full admin, one SMS, Telegram pending, email off (switched off)');
select pg_temp.check((select count(*) from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000318a1' and priority = 'critical') = 1,
  'the full admin gets the push');
select pg_temp.check((select count(*) from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000318a2') = 0,
  'a sub-admin doesn''t');
select pg_temp.check((select count(*) from public.sms_outbox where channel = 'ops_alert' and to_phone = '+60120000318') = 1,
  'WhatsApp/SMS through the gateway');

-- ---- Sending Telegram and email ------------------------------------------------------------------
create temp table t_alert on commit drop as select id from public.uptime_alerts where kind = 'restore_failed';
grant select on t_alert to service_role;
select pg_temp.as_server();
select pg_temp.check(jsonb_array_length(public.uptime_alerts_due() -> 'alerts') = 1, 'one alert to send');
select pg_temp.check((public.uptime_alerts_due() ->> 'emailFrom') = 'GET.ride Reports <reports@getride.my>',
  'the Reports sender by default');
select public.uptime_alert_sent((select id from t_alert), 'HTTP 502', null);
select pg_temp.as_db();
select pg_temp.check((select telegram = 'pending' and tries = 1 from public.uptime_alerts where kind = 'restore_failed'),
  'a failed send is tried again');
select pg_temp.as_server();
select public.uptime_alert_sent((select id from t_alert), 'sent', null);
select pg_temp.check(jsonb_array_length(public.uptime_alerts_due() -> 'alerts') = 0, 'nothing left to send');
select pg_temp.as_db();
select pg_temp.check((select telegram from public.uptime_alerts where kind = 'restore_failed') = 'sent', 'then sent');

-- ---- Uptime: down, then resolved ---------------------------------------------------------------
select pg_temp.as_server();
select pg_temp.check(public.uptime_record('nas', '[{"id": "website", "status": "down", "ms": 10000, "detail": "Timed out"},
  {"id": "nope", "status": "down"}, {"id": "admin", "status": "sideways"}]') = 1, 'unknown targets and statuses are skipped');
select pg_temp.as_db();
select pg_temp.check(not exists (select 1 from public.uptime_incidents), 'one failed check: no alert yet');
select pg_temp.as_server();
select public.uptime_record('cloud', '[{"id": "website", "status": "up", "ms": 210}]');
select public.uptime_record('nas', '[{"id": "website", "status": "down", "ms": 10000, "detail": "Timed out"}]');
select pg_temp.as_db();
select pg_temp.check((select count(*) from public.uptime_incidents where target_id = 'website' and resolved_at is null) = 1,
  'two in a row from the NAS: an incident');
select pg_temp.check((select title from public.uptime_alerts where kind = 'down') = 'getride.my is down', 'and an alert');
select pg_temp.as_server();
select public.uptime_record('nas', '[{"id": "website", "status": "down"}]');
select pg_temp.as_db();
select pg_temp.check((select count(*) from public.uptime_alerts where kind = 'down') = 1, 'alerted once');
select pg_temp.as_server();
select public.uptime_record('nas', '[{"id": "website", "status": "slow", "ms": 4100}]');
select pg_temp.as_db();
select pg_temp.check((select resolved_at is not null from public.uptime_incidents where target_id = 'website'),
  'slow counts as up: resolved');
select pg_temp.check((select body like 'Resolved: down for %' from public.uptime_alerts where kind = 'resolved'),
  'with a resolved message');

-- A NAS that stops checking doesn't hold an incident open.
select pg_temp.as_server();
select public.uptime_record('nas', '[{"id": "admin", "status": "down"}, {"id": "admin", "status": "down"}]');
select pg_temp.as_db();
select pg_temp.check((select count(*) from public.uptime_incidents where target_id = 'admin' and resolved_at is null) = 1,
  'admin down from the NAS');
update public.uptime_state set last_at = now() - interval '1 hour' where target_id = 'admin' and source = 'nas';
select pg_temp.as_server();
select public.uptime_record('cloud', '[{"id": "admin", "status": "up"}]');
select pg_temp.as_db();
select pg_temp.check((select count(*) from public.uptime_incidents where target_id = 'admin' and resolved_at is null) = 0,
  'the cloud sees it up and the NAS went quiet: resolved');

-- ---- What the database tells by itself ----------------------------------------------------------
insert into public.messaging_devices (id, user_id, device_id, label, kind, capabilities, last_seen_at) values
  ('00000000-0000-0000-0000-0000000318d1', '00000000-0000-0000-0000-0000000318a1', 'gw-1', 'Phone 1', 'gateway', '{sms}', now() - interval '40 seconds'),
  ('00000000-0000-0000-0000-0000000318d2', '00000000-0000-0000-0000-0000000318a1', 'gw-2', 'Phone 2', 'gateway', '{sms}', now() - interval '6 minutes'),
  ('00000000-0000-0000-0000-0000000318d3', '00000000-0000-0000-0000-0000000318a1', 'gw-3', null, 'gateway', '{sms}', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-0000000318d4', '00000000-0000-0000-0000-0000000318a1', 'app-1', 'Admin phone', 'app', '{voip}', now());
select pg_temp.check((select jsonb_object_agg(r ->> 'id', r ->> 'status') from jsonb_array_elements(public.uptime_local_results()) r
                       where r ->> 'id' like 'gateway:00000000-0000-0000-0000-0000000318%')
  = jsonb_build_object('gateway:00000000-0000-0000-0000-0000000318d1', 'up',
                       'gateway:00000000-0000-0000-0000-0000000318d2', 'slow',
                       'gateway:00000000-0000-0000-0000-0000000318d3', 'down'),
  'gateway phones: up, late, down; app installs aren''t gateways');
select pg_temp.check((select r ->> 'status' from jsonb_array_elements(public.uptime_local_results()) r where r ->> 'id' = 'nas') = 'up',
  'the NAS checked in just now');
update public.nas_ops_agents set last_seen_at = now() - interval '20 minutes';
update public.nas_services set last_seen = now() - interval '20 minutes';
select pg_temp.check((select r ->> 'status' from jsonb_array_elements(public.uptime_local_results()) r where r ->> 'id' = 'nas') = 'down',
  'a NAS quiet for 20 minutes is down');
select pg_temp.check((select r ->> 'status' from jsonb_array_elements(public.uptime_local_results()) r where r ->> 'id' = 'backup') = 'up',
  'a backup finished today');
update public.uptime_state set last_at = now() - interval '10 minutes' where source = 'cloud';
select pg_temp.check(public.uptime_cron() >= 4, 'the cloud round, when due, records them');
select pg_temp.check(public.uptime_cron() = 0, 'and is not due again a minute later');
select pg_temp.check(public.uptime_target_name('gateway:00000000-0000-0000-0000-0000000318d1') = 'SMS gateway · Phone 1',
  'a gateway phone''s name');

-- ---- The page ----------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a3');
create temp table t_page on commit drop as select public.admin_office_nas() as p;
select pg_temp.check((select (s ->> 'checks30')::int = 5 and (s ->> 'up30')::int = 2
                        from jsonb_array_elements(p -> 'status') s where s ->> 'id' = 'website'), '30-day counts')
  from t_page;
select pg_temp.check((p -> 'last_backup' ->> 'status') = 'ok' and (p -> 'last_restore_test' ->> 'status') = 'failed',
  'the last backup and restore test') from t_page;
select pg_temp.check(jsonb_array_length(p -> 'agents') = 1 and jsonb_array_length(p -> 'requests') = 0,
  'the NAS; its backup done, nothing waiting') from t_page;
select pg_temp.check((select count(*) from public.admin_uptime_history('website')) = 5, 'the history');

-- ---- Targets -------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a2');
select pg_temp.check((public.admin_uptime_target_save('{"name": "QR site", "kind": "http", "url": "https://qr.getride.my"}') ->> 'id')
  = 'qr-site', 'a new target');
select pg_temp.check(pg_temp.refused($$select public.admin_uptime_target_save('{"name": "Bad", "url": "ftp://x"}')$$),
  'a web address starting with https://');
select pg_temp.check(pg_temp.refused($$select public.admin_uptime_target_save('{"name": "Phones", "kind": "gateways"}')$$),
  'new targets are addresses or the database');
select pg_temp.check((public.admin_uptime_target_save('{"id": "payment", "name": "Billplz", "kind": "database", "on": false}') ->> 'kind')
  = 'http', 'a built-in keeps its kind');
select pg_temp.check((select url = '{payment}' and not on_off from public.uptime_targets where id = 'payment'),
  'and its filled-in address; switched off');
select pg_temp.check(pg_temp.refused($$select public.admin_uptime_target_delete('website')$$), 'built-ins stay');
select public.admin_uptime_target_delete('qr-site');
select pg_temp.as_db();
select pg_temp.check(not exists (select 1 from public.uptime_targets where id = 'qr-site'), 'an added one goes');
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a3');
select pg_temp.check(pg_temp.refused($$select public.admin_uptime_target_save('{"name": "X", "url": "https://x.example"}')$$),
  'READ can''t add targets');

-- ---- Disconnecting ---------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a2');
select pg_temp.check(pg_temp.refused($$select public.admin_nas_ops_remove((select id from public.nas_ops_agents limit 1))$$),
  'only a full admin disconnects');
select pg_temp.as_db();
create temp table t_agent on commit drop as select id from public.nas_ops_agents;
grant select on t_agent to authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000318a1');
select public.admin_nas_ops_remove((select id from t_agent));
select pg_temp.as_server();
select pg_temp.check(pg_temp.refused($$select public.nas_ops_heartbeat((select k ->> 'key' from t_key))$$),
  'its key stops working');

select pg_temp.as_db();
rollback;
