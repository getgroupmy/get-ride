-- ============================================================================
-- Regression test for migration 0239: empty support tickets older than 30
-- minutes are deleted (or closed, when a file or recording refers to them);
-- fresh ones, ones with a message and ones with a call stay.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/empty_support_tickets_0239.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when insufficient_privilege then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to anon, authenticated;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000239a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000239a1') on conflict do nothing;

insert into public.support_tickets (id, profile_id, status, created_at) values
  ('00000000-0000-0000-0000-0000000239b1', '00000000-0000-0000-0000-0000000239a1', 'open', now() - interval '2 hours'),    -- empty, old
  ('00000000-0000-0000-0000-0000000239b2', '00000000-0000-0000-0000-0000000239a1', 'open', now() - interval '10 minutes'), -- empty, fresh
  ('00000000-0000-0000-0000-0000000239b3', '00000000-0000-0000-0000-0000000239a1', 'open', now() - interval '2 hours'),    -- has a message
  ('00000000-0000-0000-0000-0000000239b4', '00000000-0000-0000-0000-0000000239a1', 'open', now() - interval '2 hours'),    -- had a call
  ('00000000-0000-0000-0000-0000000239b5', '00000000-0000-0000-0000-0000000239a1', 'open', now() - interval '2 hours'),    -- upload, no message
  ('00000000-0000-0000-0000-0000000239b6', '00000000-0000-0000-0000-0000000239a1', 'pending', now() - interval '2 hours'), -- recording asked for it
  ('00000000-0000-0000-0000-0000000239b7', '00000000-0000-0000-0000-0000000239a1', 'closed', now() - interval '2 hours');  -- empty, closed, old

insert into public.support_messages (ticket_id, sender_role, sender_id, type, body)
values ('00000000-0000-0000-0000-0000000239b3', 'user', '00000000-0000-0000-0000-0000000239a1', 'text', 'hello');
insert into public.support_calls (ticket_id, profile_id, status, created_at)
values ('00000000-0000-0000-0000-0000000239b4', '00000000-0000-0000-0000-0000000239a1', 'missed', now() - interval '2 hours');
insert into storage.objects (bucket_id, name)
values ('support-media', '00000000-0000-0000-0000-0000000239b5/image/20261019-x.jpg');
insert into public.voice_protection_recordings (profile_id, ticket_id)
values ('00000000-0000-0000-0000-0000000239a1', '00000000-0000-0000-0000-0000000239b6');

-- The apps can't run it -------------------------------------------------------------------------
select pg_temp.check(
  not has_function_privilege('anon', 'public.support_purge_empty_tickets()', 'execute')
  and not has_function_privilege('authenticated', 'public.support_purge_empty_tickets()', 'execute')
  and not has_function_privilege('public', 'public.support_purge_empty_tickets()', 'execute')
  and has_function_privilege('service_role', 'public.support_purge_empty_tickets()', 'execute'),
  'only service_role may execute support_purge_empty_tickets');
set local role anon;
select pg_temp.refused('select public.support_purge_empty_tickets()', 'anon calling the purge');
reset role;
set local role authenticated;
select pg_temp.refused('select public.support_purge_empty_tickets()', 'authenticated calling the purge');
reset role;

-- The purge --------------------------------------------------------------------------------------
select pg_temp.check(
  public.support_purge_empty_tickets() = '{"deleted": 2, "closed": 2}'::jsonb,
  'two deleted, two closed');

select pg_temp.check(
  not exists (select 1 from public.support_tickets where id = '00000000-0000-0000-0000-0000000239b1'),
  'an empty ticket older than 30 minutes is deleted');
select pg_temp.check(
  not exists (select 1 from public.support_tickets where id = '00000000-0000-0000-0000-0000000239b7'),
  'an empty closed one goes too');
select pg_temp.check(
  (select status = 'open' and subject = 'Support' from public.support_tickets
    where id = '00000000-0000-0000-0000-0000000239b2'),
  'an empty ticket under 30 minutes old stays as it was');
select pg_temp.check(
  (select status = 'open' and subject = 'Support' from public.support_tickets
    where id = '00000000-0000-0000-0000-0000000239b3')
  and exists (select 1 from public.support_messages where ticket_id = '00000000-0000-0000-0000-0000000239b3'),
  'a ticket with a message stays as it was');
select pg_temp.check(
  (select status = 'open' and subject = 'Support' from public.support_tickets
    where id = '00000000-0000-0000-0000-0000000239b4')
  and exists (select 1 from public.support_calls where ticket_id = '00000000-0000-0000-0000-0000000239b4'),
  'a ticket with call history stays as it was');
select pg_temp.check(
  (select status = 'closed' and subject like 'Support (closed automatically:%' and last_message_at is null
     from public.support_tickets where id = '00000000-0000-0000-0000-0000000239b5'),
  'an empty ticket holding an upload is closed with a note, not deleted');
select pg_temp.check(
  (select status = 'closed' and subject like 'Support (closed automatically:%'
     from public.support_tickets where id = '00000000-0000-0000-0000-0000000239b6'),
  'an empty ticket a recording points at is closed with a note');

-- Again: nothing more to do, and the note isn't added twice.
select pg_temp.check(
  public.support_purge_empty_tickets() = '{"deleted": 0, "closed": 0}'::jsonb,
  'a second run changes nothing');
select pg_temp.check(
  (select count(*) = 2 from public.support_tickets
    where id in ('00000000-0000-0000-0000-0000000239b5', '00000000-0000-0000-0000-0000000239b6')
      and subject = 'Support (closed automatically: its first message never arrived)'),
  'the note is added once');

-- Scheduled hourly where pg_cron is installed.
select pg_temp.check(
  not exists (select 1 from pg_extension where extname = 'pg_cron')
  or exists (select 1 from cron.job where jobname = 'purge-empty-support-tickets'
               and schedule = '37 * * * *' and command like '%support_purge_empty_tickets()%'),
  'the purge is scheduled hourly');

rollback;

select 'empty_support_tickets_0239: all passed';
