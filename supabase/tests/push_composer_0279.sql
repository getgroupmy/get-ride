-- ============================================================================
-- Regression test for migration 0279: the push composer.
--   * push_schedule_next: a day, a week, a month on; the 31st goes on the
--     last day of a shorter month and back to the 31st after; Malaysia time;
--   * push_schedules_due claims a due row, calls send-push with the push
--     webhook secret and nothing else in the headers and the schedule's id
--     in the body, then moves a repeat on (never into the past) or marks a
--     one-off done; a future or cancelled row is left alone;
--   * a non-admin, and an admin of another page, read no push_schedules and
--     write none; a push admin with READ reads but does not write;
--   * a user reads only the push_messages a notification of theirs carries.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push_composer_0279.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', what; end if;
end $$;
create function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.refused(text, text)
  to authenticated;

-- 1. The next time, in Malaysia time (UTC+8) ------------------------------------------------------
select pg_temp.check(public.push_schedule_next('2026-10-25 01:00+00', '2026-10-25 01:00+00', 'daily')
                     = '2026-10-26 01:00+00'::timestamptz, 'daily: a day on');
select pg_temp.check(public.push_schedule_next('2026-10-25 01:00+00', '2026-10-25 01:00+00', 'weekly')
                     = '2026-11-01 01:00+00'::timestamptz, 'weekly: a week on');
select pg_temp.check(public.push_schedule_next('2026-10-25 01:00+00', '2026-10-25 01:00+00', 'once') is null,
                     'once: no next time');
-- 31 Jan 09:00 MYT is 31 Jan 01:00 UTC; February has 28 days in 2027.
select pg_temp.check(public.push_schedule_next('2027-01-31 01:00+00', '2027-01-31 01:00+00', 'monthly')
                     = '2027-02-28 01:00+00'::timestamptz, 'monthly: the 31st goes on the last of February');
select pg_temp.check(public.push_schedule_next('2027-02-28 01:00+00', '2027-01-31 01:00+00', 'monthly')
                     = '2027-03-31 01:00+00'::timestamptz, 'monthly: back to the 31st in March');
-- 1 Nov 07:30 MYT is 31 Oct 23:30 UTC: the day is Malaysia's, not UTC's.
select pg_temp.check(public.push_schedule_next('2026-10-31 23:30+00', '2026-10-31 23:30+00', 'monthly')
                     = '2026-11-30 23:30+00'::timestamptz, 'monthly: by the Malaysian date');

-- People ------------------------------------------------------------------------------------------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000279a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000279a2'),  -- push admin, READ
  ('00000000-0000-0000-0000-0000000279a3'),  -- admin of another page, EDIT
  ('00000000-0000-0000-0000-0000000279b1'),  -- a rider who got the push
  ('00000000-0000-0000-0000-0000000279b2')   -- a rider who did not
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000279%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000279a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000279a2', 'admin-settings-push-notification', 'read'),
  ('00000000-0000-0000-0000-0000000279a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

-- 2. The scheduled run ---------------------------------------------------------------------------
delete from vault.secrets where name = 'project_url';
select vault.create_secret('https://example.invalid', 'project_url');

insert into public.push_schedules (id, title, body, audience, partner_types, approved_only, send_at, repeat) values
  ('00000000-0000-0000-0000-000000027901', 'Weekend bonus', 'RM 30 extra', 'partners', '{eHailing,Teksi}', true,
   now() - interval '1 minute', 'weekly'),
  ('00000000-0000-0000-0000-000000027902', 'Promo', 'Once only', 'users', '{}', true,
   now() - interval '2 minutes', 'once'),
  ('00000000-0000-0000-0000-000000027903', 'Later', 'Not yet', 'all', '{}', true,
   now() + interval '1 day', 'daily'),
  ('00000000-0000-0000-0000-000000027904', 'Cancelled', 'Never', 'all', '{}', true,
   now() - interval '1 minute', 'daily');
update public.push_schedules set status = 'cancelled' where id = '00000000-0000-0000-0000-000000027904';
-- A daily push that missed a week: it goes once, and next time is ahead.
insert into public.push_schedules (id, title, body, audience, send_at, repeat) values
  ('00000000-0000-0000-0000-000000027905', 'Daily', 'Every day', 'all', now() - interval '7 days 1 minute', 'daily');

select pg_temp.check((select next_at = send_at from public.push_schedules
                       where id = '00000000-0000-0000-0000-000000027901'), 'next_at starts at send_at');

create temp table q0 as select coalesce(max(id), 0) as id from net.http_request_queue;
create function pg_temp.calls(p_schedule uuid) returns bigint language sql as $$
  select count(*) from net.http_request_queue q
   where q.id > (select id from q0)
     and q.url = 'https://example.invalid/functions/v1/send-push'
     and convert_from(q.body, 'utf8')::jsonb ->> 'scheduleId' = p_schedule::text
$$;

select pg_temp.check(public.push_schedules_due() = 3, 'the three due rows are sent');
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-000000027901') = 1, 'the weekly push is sent');
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-000000027902') = 1, 'the one-off push is sent');
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-000000027903') = 0, 'a future push waits');
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-000000027904') = 0, 'a cancelled push is not sent');
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-000000027905') = 1, 'a missed daily push goes once');

select pg_temp.check((select q.headers = jsonb_build_object(
                        'Content-Type', 'application/json',
                        'x-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_webhook_secret'))
                        from net.http_request_queue q where q.id > (select id from q0)
                         and q.url like '%/send-push' order by q.id limit 1),
                     'only the webhook secret in the headers');
select pg_temp.check((select convert_from(q.body, 'utf8')::jsonb = jsonb_build_object(
                        'title', 'Weekend bonus', 'body', 'RM 30 extra', 'audience', 'partners',
                        'approvedOnly', true, 'partnerTypes', jsonb_build_array('eHailing', 'Teksi'),
                        'scheduleId', '00000000-0000-0000-0000-000000027901')
                        from net.http_request_queue q where q.id > (select id from q0)
                         and convert_from(q.body, 'utf8')::jsonb ->> 'scheduleId' = '00000000-0000-0000-0000-000000027901'),
                     'the body carries the push, the partner types and the schedule id');

select pg_temp.check((select status = 'active' and next_at > now() + interval '6 days' and last_sent_at is not null
                        from public.push_schedules where id = '00000000-0000-0000-0000-000000027901'),
                     'the weekly push moves a week on');
select pg_temp.check((select status = 'done' from public.push_schedules where id = '00000000-0000-0000-0000-000000027902'),
                     'the one-off push is done');
select pg_temp.check((select next_at > now() and next_at <= now() + interval '1 day'
                        from public.push_schedules where id = '00000000-0000-0000-0000-000000027905'),
                     'a missed daily push moves to the next day ahead, not into the past');
select pg_temp.check(public.push_schedules_due() = 0, 'nothing is sent twice');

-- Moving the time sets next_at again.
update public.push_schedules set send_at = now() + interval '3 days' where id = '00000000-0000-0000-0000-000000027903';
select pg_temp.check((select next_at = send_at from public.push_schedules where id = '00000000-0000-0000-0000-000000027903'),
                     'next_at follows a moved send_at');

-- 3. The full message, and who reads it ----------------------------------------------------------
insert into public.push_messages (id, title, body, blocks, created_by) values
  ('00000000-0000-0000-0000-0000002790f1', 'Weekend bonus', 'RM 30 extra',
   '[{"type":"heading","spans":[{"text":"Weekend bonus"}]}]', '00000000-0000-0000-0000-0000000279a1'),
  ('00000000-0000-0000-0000-0000002790f2', 'Other', 'Not for b1', '[]', '00000000-0000-0000-0000-0000000279a1');
insert into public.user_notifications (profile_id, title, body, data) values
  ('00000000-0000-0000-0000-0000000279b1', 'Weekend bonus', 'RM 30 extra',
   '{"message_id": "00000000-0000-0000-0000-0000002790f1"}');

set local role authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000279b1');
select pg_temp.check((select count(*) from public.push_messages) = 1, 'a user reads the message they were sent, only');
select pg_temp.check((select id from public.push_messages) = '00000000-0000-0000-0000-0000002790f1',
                     'it is the message of their notification');
select pg_temp.check((select count(*) from public.push_schedules) = 0, 'a user reads no schedules');
select pg_temp.refused($q$insert into public.push_messages (title) values ('Mine')$q$, 'a user writing a message');
select pg_temp.refused($q$insert into public.push_schedules (title, body, send_at) values ('x', 'y', now())$q$,
  'a user scheduling a push');

select pg_temp.as_user('00000000-0000-0000-0000-0000000279b2');
select pg_temp.check((select count(*) from public.push_messages) = 0, 'a user who got nothing reads no message');

select pg_temp.as_user('00000000-0000-0000-0000-0000000279a3');
select pg_temp.check((select count(*) from public.push_schedules) = 0, 'an admin of another page reads no schedules');
select pg_temp.refused($q$update public.push_schedules set status = 'cancelled'$q$, 'an admin of another page cancelling');
select pg_temp.refused($q$insert into public.push_messages (title) values ('Theirs')$q$,
  'an admin of another page writing a message');

select pg_temp.as_user('00000000-0000-0000-0000-0000000279a2');
select pg_temp.check((select count(*) from public.push_schedules) = 5, 'a push admin with READ reads the schedules');
select pg_temp.check((select count(*) from public.push_messages) = 2, 'a push admin reads every message');
select pg_temp.refused($q$update public.push_schedules set status = 'cancelled'$q$, 'a READ push admin cancelling');
select pg_temp.refused($q$insert into public.push_schedules (title, body, send_at) values ('x', 'y', now())$q$,
  'a READ push admin scheduling');

select pg_temp.as_user('00000000-0000-0000-0000-0000000279a1');
insert into public.push_messages (title, body, blocks) values ('Admin', 'Hi', '[]');
insert into public.push_schedules (title, body, send_at, repeat) values ('Admin', 'Hi', now() + interval '1 hour', 'monthly');
select pg_temp.check((select count(*) from public.push_schedules where created_by = '00000000-0000-0000-0000-0000000279a1') = 1,
                     'a push editor schedules, as themselves');
update public.push_schedules set status = 'cancelled' where id = '00000000-0000-0000-0000-000000027903';
select pg_temp.check((select status = 'cancelled' from public.push_schedules
                       where id = '00000000-0000-0000-0000-000000027903'), 'a push editor cancels');
select pg_temp.refused($q$insert into public.push_schedules (title, body, send_at, created_by)
                          values ('x', 'y', now(), '00000000-0000-0000-0000-0000000279a2')$q$,
  'scheduling in someone else''s name');
select pg_temp.refused($q$delete from public.push_schedules$q$, 'deleting a schedule');
select pg_temp.refused($q$select public.push_schedules_due()$q$, 'a client running the scheduled job');

reset role;

rollback;
