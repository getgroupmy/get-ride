-- ============================================================================
-- Regression test for migration 0347: the face match server (NAS) offline
-- alert.
--   * face_server_health_report: 'down' before 5 minutes doesn't alert; once
--     it has been down for 5 minutes it alerts the face/selfie admins, once;
--     a later 'down' doesn't alert again; 'ok' sends "back online" and clears;
--     'disabled' clears silently.
--   * face_server_alert_admins covers the Documents/Partners/selfie-check
--     pages and the online_selfie 'alertAdmins' list.
--   * only the service role may report; only admins may read the state.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/face_server_offline_alert_0347.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000347a1'),  -- admin: Documents page (a recipient)
  ('00000000-0000-0000-0000-0000000347a2'),  -- admin: alertAdmins list only
  ('00000000-0000-0000-0000-0000000347a3')   -- admin: unrelated page (not a recipient)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000347%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000347a1', 'admin-documents', 'edit'),
  ('00000000-0000-0000-0000-0000000347a2', 'admin-support', 'read'),
  ('00000000-0000-0000-0000-0000000347a3', 'admin-settings-commission', 'read')
on conflict do nothing;
-- a2 is in the online_selfie alertAdmins list, so it is a recipient too.
insert into public.app_settings (key, value, updated_at) values
  ('online_selfie', jsonb_build_object('alertAdmins', jsonb_build_array('00000000-0000-0000-0000-0000000347a2')), now())
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

-- The recipients: a1 (Documents page) and a2 (alertAdmins); not a3.
select pg_temp.check(
  (select array_agg(x order by x) from (select public.face_server_alert_admins() x) s
     where x::text like '00000000-0000-0000-0000-0000000347%')
    = array['00000000-0000-0000-0000-0000000347a1','00000000-0000-0000-0000-0000000347a2']::uuid[],
  'the Documents admin and the alertAdmins admin are recipients, not the unrelated one');

-- 1. Down, but not yet 5 minutes: no alert.
select pg_temp.check((public.face_server_health_report('down', 'test') ->> 'alerted') = 'false',
  'a fresh outage does not alert before 5 minutes');
select pg_temp.check((select state = 'offline' and offline_alerted_at is null from public.face_server_health),
  'it is marked offline, not yet alerted');

-- 2. Still down after 5 minutes: one alert, to both recipients.
update public.face_server_health set failing_since = now() - interval '6 minutes' where id;
select pg_temp.check((select r ->> 'alerted' = 'true' and (r ->> 'sent')::int = 2
                        from (select public.face_server_health_report('down', 'test') r) q),
  'after 5 minutes down it alerts the two recipients');
select pg_temp.check((select offline_alerted_at is not null from public.face_server_health),
  'the alert is stamped so it is not repeated');

-- 3. Still down: no second alert.
select pg_temp.check((public.face_server_health_report('down', 'test') ->> 'alerted') = 'false',
  'a continuing outage does not alert again');

-- 4. Back up: "back online", and the state clears.
select pg_temp.check((public.face_server_health_report('ok', null) ->> 'alerted') = 'true',
  'coming back online alerts once');
select pg_temp.check(
  (select state = 'online' and offline_alerted_at is null and failing_since is null and last_ok_at is not null
     from public.face_server_health),
  'online, with the outage cleared');
select pg_temp.check((public.face_server_health_report('ok', null) ->> 'alerted') = 'false',
  'staying online does not alert');

-- 5. No server configured: disabled, silently.
select pg_temp.check((public.face_server_health_report('disabled', null) ->> 'alerted') = 'false',
  'disabled does not alert');
select pg_temp.check((select state = 'disabled' from public.face_server_health), 'and the state is disabled');

-- 6. Who may do what.
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.errored(text) to authenticated;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000347a1', 'role', 'authenticated')::text, true);
select pg_temp.check(pg_temp.errored($q$select public.face_server_health_report('down', 'x')$q$),
  'an authenticated caller cannot report (service role only)');
select pg_temp.check((select count(*) = 1 from public.face_server_health),
  'an admin can read the health row');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000347a3', 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.check((select count(*) = 1 from public.face_server_health),
  'a sub-admin (any admin_access row) can read the health row');
reset role;

rollback;
