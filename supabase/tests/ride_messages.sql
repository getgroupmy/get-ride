-- ============================================================================
-- Regression test for migration 0129: the rider ↔ driver chat of a ride is
-- the two participants' alone, open only while the ride is, and a message's
-- tick is moved only by its receiver.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_messages.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

-- Read-only checks first: what the push says, and what clients can't call.
do $$
begin
  if public.ride_message_push_body('location', null) <> 'Shared a location' then
    raise exception 'FAILED: a location push should say so';
  end if;
  if public.ride_message_push_body('text', '  At the gate  ') <> 'At the gate' then
    raise exception 'FAILED: a text push carries the text';
  end if;
  if char_length(public.ride_message_push_body('text', repeat('x', 900))) <> 160 then
    raise exception 'FAILED: a long text is cut for the push';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_ride_messages_push')
     or not exists (select 1 from pg_trigger where tgname = 'trg_ride_messages_guard_update')
     or not exists (select 1 from pg_trigger where tgname = 'trg_ride_messages_before_insert') then
    raise exception 'FAILED: a ride_messages trigger is missing';
  end if;

  if has_function_privilege('authenticated', 'public.notify_ride_message_push()', 'execute')
     or has_function_privilege('anon', 'public.notify_ride_message_push()', 'execute')
     or has_function_privilege('authenticated', 'public.ride_messages_guard_update()', 'execute')
     or has_function_privilege('anon', 'public.ride_messages_guard_update()', 'execute') then
    raise exception 'FAILED: the ride_messages definer functions must not be callable by clients';
  end if;
  if has_column_privilege('authenticated', 'public.ride_messages', 'body', 'update')
     or not has_column_privilege('authenticated', 'public.ride_messages', 'status', 'update') then
    raise exception 'FAILED: clients may update the tick and nothing else';
  end if;
  if has_table_privilege('anon', 'public.ride_messages', 'select') then
    raise exception 'FAILED: anon must not read ride messages';
  end if;
end
$$;

begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000129a1'),  -- rider
  ('00000000-0000-0000-0000-0000000129b1'),  -- driver
  ('00000000-0000-0000-0000-0000000129c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000129%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, rider_name, partner_name) values
  ('00000000-0000-0000-0000-0000000129d1', '00000000-0000-0000-0000-0000000129a1', '00000000-0000-0000-0000-0000000129b1', 'accepted', 'Aina', 'Ravi'),
  ('00000000-0000-0000-0000-0000000129d2', '00000000-0000-0000-0000-0000000129a1', '00000000-0000-0000-0000-0000000129b1', 'completed', 'Aina', 'Ravi');

-- An old message on the finished ride, written while it was still running.
insert into public.ride_messages (id, request_id, sender_id, sender_role, type, body) values
  ('00000000-0000-0000-0000-0000000129e9', '00000000-0000-0000-0000-0000000129d2',
   '00000000-0000-0000-0000-0000000129b1', 'partner', 'quick', 'I''ve arrived');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

create or replace function pg_temp.expect_count(p_n int, p_what text) returns void language plpgsql as $$
begin
  if (select count(*) from public.ride_messages) <> p_n then
    raise exception 'FAILED: % (saw %)', p_what, (select count(*) from public.ride_messages);
  end if;
end $$;
grant execute on function pg_temp.expect_count(int, text) to authenticated;

create or replace function pg_temp.expect_tick(p_id uuid, p_status text) returns void language plpgsql as $$
begin
  if (select status from public.ride_messages where id = p_id) is distinct from p_status then
    raise exception 'FAILED: message % should be %', p_id, p_status;
  end if;
end $$;
grant execute on function pg_temp.expect_tick(uuid, text) to authenticated;

set local role authenticated;

-- 1. Both participants write on the running ride ----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000129a1');
insert into public.ride_messages (id, request_id, sender_role, type, body, status, created_at) values
  ('00000000-0000-0000-0000-0000000129e1', '00000000-0000-0000-0000-0000000129d1', 'rider', 'text',
   '  At the gate  ', 'read', '2000-01-01');
do $$
declare
  m public.ride_messages;
begin
  select * into m from public.ride_messages where id = '00000000-0000-0000-0000-0000000129e1';
  if m.sender_id <> '00000000-0000-0000-0000-0000000129a1' or m.body <> 'At the gate' or m.status <> 'sent'
     or m.created_at < now() - interval '1 minute' then
    raise exception 'FAILED: a new message should be the sender''s, trimmed, sent and stamped now: %', m;
  end if;
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000129b1');
insert into public.ride_messages (id, request_id, sender_role, type, body) values
  ('00000000-0000-0000-0000-0000000129e2', '00000000-0000-0000-0000-0000000129d1', 'partner', 'quick', 'I''m on my way');
insert into public.ride_messages (request_id, sender_role, type, latitude, longitude) values
  ('00000000-0000-0000-0000-0000000129d1', 'partner', 'location', 2.93, 101.83);
select pg_temp.expect_count(4, 'the driver should see both rides'' messages');

select pg_temp.as_user('00000000-0000-0000-0000-0000000129a1');
select pg_temp.expect_count(4, 'the rider should see both rides'' messages');

-- 2. Nobody writes as the other side, or anything empty ---------------------
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, body)
     values ('00000000-0000-0000-0000-0000000129d1', 'partner', 'hi')$q$,
  'the rider writing as the driver');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_id, sender_role, body)
     values ('00000000-0000-0000-0000-0000000129d1', '00000000-0000-0000-0000-0000000129b1', 'rider', 'hi')$q$,
  'a message under somebody else''s id');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, body)
     values ('00000000-0000-0000-0000-0000000129d1', 'rider', '   ')$q$,
  'an empty message');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, type)
     values ('00000000-0000-0000-0000-0000000129d1', 'rider', 'location')$q$,
  'a location without a position');

-- 3. A finished ride keeps its history but takes nothing new ----------------
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, body)
     values ('00000000-0000-0000-0000-0000000129d2', 'rider', 'Thanks!')$q$,
  'a message after the ride completed');

-- 4. An outsider neither sees nor writes ------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000129c1');
select pg_temp.expect_count(0, 'an outsider should see no ride messages');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, body)
     values ('00000000-0000-0000-0000-0000000129d1', 'rider', 'hello')$q$,
  'an outsider writing as the rider');
update public.ride_messages set status = 'read';
delete from public.ride_messages;

-- 5. Only the receiver moves the tick, and only forward ---------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000129a1');
select pg_temp.refused(
  $q$update public.ride_messages set status = 'read' where id = '00000000-0000-0000-0000-0000000129e1'$q$,
  'the sender marking their own message read');
select pg_temp.expect_tick('00000000-0000-0000-0000-0000000129e1', 'sent');

select pg_temp.as_user('00000000-0000-0000-0000-0000000129b1');
update public.ride_messages set status = 'delivered' where id = '00000000-0000-0000-0000-0000000129e1';
select pg_temp.expect_tick('00000000-0000-0000-0000-0000000129e1', 'delivered');
update public.ride_messages set status = 'read' where id = '00000000-0000-0000-0000-0000000129e1';
select pg_temp.expect_tick('00000000-0000-0000-0000-0000000129e1', 'read');
select pg_temp.refused(
  $q$update public.ride_messages set status = 'delivered' where id = '00000000-0000-0000-0000-0000000129e1'$q$,
  'a tick moving backwards');
select pg_temp.refused(
  $q$update public.ride_messages set body = 'Changed' where id = '00000000-0000-0000-0000-0000000129e1'$q$,
  'the receiver editing the text');

select pg_temp.as_user('00000000-0000-0000-0000-0000000129a1');
select pg_temp.refused(
  $q$update public.ride_messages set body = 'Changed' where id = '00000000-0000-0000-0000-0000000129e1'$q$,
  'the sender editing the text');
update public.ride_messages set status = 'read' where id = '00000000-0000-0000-0000-0000000129e2';
select pg_temp.expect_tick('00000000-0000-0000-0000-0000000129e2', 'read');

-- 6. Participants don't delete ----------------------------------------------
delete from public.ride_messages;
select pg_temp.expect_count(4, 'a participant deleted messages');

-- 7. Not even an admin session rewrites what was said -----------------------
reset role;
select pg_temp.refused(
  $q$update public.ride_messages set body = 'Changed' where id = '00000000-0000-0000-0000-0000000129e2'$q$,
  'rewriting a message''s text');

select 'ride_messages: all passed';
rollback;
