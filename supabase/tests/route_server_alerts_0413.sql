-- ============================================================================
-- Regression test for migration 0413: route-server health alerts name the
-- server, not "Waze", now that Google Maps servers (the fare order's "gmap"
-- step) share waze_server_health with the Waze ones.
--   * a Google Maps server down for 5 minutes alerts the Fare AI admins once,
--     titled "Route server offline" with its own label; "back online" once;
--   * a Waze server in the same table keeps its own row and its own alert;
--   * the push type stays 'waze_server_status'.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/route_server_alerts_0413.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000413a1')   -- admin: Fare AI page (a recipient)
on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000413a1')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000413a1', 'admin-settings-fare-ai', 'edit')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

-- Catch the pushes instead of sending them (rolled back with the rest).
create temp table sent_pushes (profile uuid, title text, body text, data jsonb);
create or replace function public.approval_push_send(p_user uuid, p_msg jsonb, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into pg_temp.sent_pushes values (p_user, p_msg->>'title', p_msg->>'body', p_data);
end $$;

-- 1. A Google Maps server goes down: no alert before 5 minutes.
select pg_temp.check(
  (public.waze_server_health_report('gmap-test', 'Google Maps server 1', 'down', 'Google Maps is refusing this server: x')
     ->> 'alerted') = 'false',
  'a fresh outage does not alert');

-- 2. Down for 5 minutes: one "Route server offline" naming it.
update public.waze_server_health set failing_since = now() - interval '6 minutes' where server_id = 'gmap-test';
select public.waze_server_health_report('gmap-test', 'Google Maps server 1', 'down', 'still down');
select pg_temp.check(
  (select count(*) = 1 from sent_pushes
    where profile = '00000000-0000-0000-0000-0000000413a1'
      and title = 'Route server offline'
      and body like 'Google Maps server 1 has not been working for 5 minutes (still down).%'
      and body like '%the next step of the fare order%'
      and body not like '%Waze%'
      and data ->> 'type' = 'waze_server_status'
      and data ->> 'server' = 'gmap-test'
      and (data ->> 'online')::boolean = false),
  'the offline alert names the Google Maps server, not Waze');

-- 3. Still down: no second alert.
select public.waze_server_health_report('gmap-test', 'Google Maps server 1', 'down', 'still down');
select pg_temp.check(
  (select count(*) = 1 from sent_pushes where profile = '00000000-0000-0000-0000-0000000413a1'),
  'a continuing outage does not alert again');

-- 4. A Waze server is its own row: down there doesn't touch the Google Maps row.
select public.waze_server_health_report('waze-test', 'Waze server 1', 'ok');
select pg_temp.check(
  (select state = 'offline' from public.waze_server_health where server_id = 'gmap-test')
  and (select state = 'online' from public.waze_server_health where server_id = 'waze-test'),
  'each server keeps its own state');

-- 5. Back: "Route server back online", once.
select public.waze_server_health_report('gmap-test', 'Google Maps server 1', 'ok');
select pg_temp.check(
  (select count(*) = 1 from sent_pushes
    where profile = '00000000-0000-0000-0000-0000000413a1'
      and title = 'Route server back online'
      and body = 'Google Maps server 1 is answering fares again.'
      and (data ->> 'online')::boolean = true),
  'back online is announced once, by name');
select pg_temp.check(
  (select state = 'online' and offline_alerted_at is null and failing_since is null
     from public.waze_server_health where server_id = 'gmap-test'),
  'online, with the outage cleared');

-- 6. A report without a label still reads well.
update public.waze_server_health set failing_since = now() - interval '6 minutes', state = 'offline'
 where server_id = 'gmap-test';
select public.waze_server_health_report('gmap-test', '', 'down', null);
select pg_temp.check(
  (select count(*) = 1 from sent_pushes where title = 'Route server offline' and body like 'A route server has not%'),
  'an unlabelled server is "A route server"');

rollback;
