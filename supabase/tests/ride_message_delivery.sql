-- ============================================================================
-- Regression test for migration 0146: a chat message is delivered when its
-- push lands, and a resent message is stored once.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_message_delivery.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000146a1'),  -- rider
  ('00000000-0000-0000-0000-0000000146b1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000146%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, rider_name, partner_name) values
  ('00000000-0000-0000-0000-0000000146d1', '00000000-0000-0000-0000-0000000146a1',
   '00000000-0000-0000-0000-0000000146b1', 'accepted', 'Aina', 'Ravi');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

-- 1. A send retried with the same id is stored once ------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000146a1');
insert into public.ride_messages (id, request_id, sender_role, type, body, client_msg_id) values
  ('00000000-0000-0000-0000-0000000146e1', '00000000-0000-0000-0000-0000000146d1', 'rider', 'text', 'At the gate',
   '00000000-0000-0000-0000-0000000146f1')
on conflict (client_msg_id) do nothing;
insert into public.ride_messages (request_id, sender_role, type, body, client_msg_id) values
  ('00000000-0000-0000-0000-0000000146d1', 'rider', 'text', 'At the gate', '00000000-0000-0000-0000-0000000146f1')
on conflict (client_msg_id) do nothing;
select pg_temp.check((select count(*) = 1 from public.ride_messages
                       where client_msg_id = '00000000-0000-0000-0000-0000000146f1'), 'a resent message is stored once');
-- Messages from builds without an id are all kept.
insert into public.ride_messages (request_id, sender_role, type, body) values
  ('00000000-0000-0000-0000-0000000146d1', 'rider', 'text', 'One'),
  ('00000000-0000-0000-0000-0000000146d1', 'rider', 'text', 'One');
select pg_temp.check((select count(*) = 3 from public.ride_messages), 'messages without an id are not de-duplicated');
reset role;

-- 2. The push is queued for the driver, through the outbox ------------------------
select pg_temp.check(
  (select count(*) = 1 and bool_and(kind = 'ride_message' and attempts = 1 and next_attempt_at is not null
                                    and data->>'message_id' = '00000000-0000-0000-0000-0000000146e1'
                                    and data->>'role' = 'partner')
     from public.notification_outbox where event_id = 'msg:00000000-0000-0000-0000-0000000146e1'),
  'the chat push is queued for the driver with its message');
select pg_temp.check(
  (select profile_id = '00000000-0000-0000-0000-0000000146b1' from public.notification_outbox
    where event_id = 'msg:00000000-0000-0000-0000-0000000146e1'),
  'the push goes to the other side');

-- 3. The sender can't acknowledge it; the receiver's phone can ----------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000146a1');
select pg_temp.check(public.ack_notification('msg:00000000-0000-0000-0000-0000000146e1') = 0,
  'the sender has no push to acknowledge');
select pg_temp.as_user('00000000-0000-0000-0000-0000000146b1');
select pg_temp.check(public.ack_notification('msg:00000000-0000-0000-0000-0000000146e1') = 1, 'the driver''s phone acks');
select pg_temp.check((select status = 'delivered' from public.ride_messages
                       where id = '00000000-0000-0000-0000-0000000146e1'),
  'a landed push makes the message delivered');
-- Tapping it later: read.
select public.ack_notification('msg:00000000-0000-0000-0000-0000000146e1', 'read');
select pg_temp.check((select status = 'read' from public.ride_messages
                       where id = '00000000-0000-0000-0000-0000000146e1'),
  'a tapped push makes the message read');
-- A late "delivered" never takes a read message back.
select public.ack_notification('msg:00000000-0000-0000-0000-0000000146e1', 'delivered');
select pg_temp.check((select status = 'read' from public.ride_messages
                       where id = '00000000-0000-0000-0000-0000000146e1'),
  'a late delivered ack does not lower the tick');
reset role;

-- 4. The open chat delivering a message closes its push --------------------------
do $$
declare
  v_id uuid;
begin
  select id into v_id from public.ride_messages
   where request_id = '00000000-0000-0000-0000-0000000146d1' and status = 'sent' limit 1;
  perform set_config('test.msg', v_id::text, true);
end $$;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000146b1');
update public.ride_messages set status = 'delivered' where id = current_setting('test.msg')::uuid;
reset role;
select pg_temp.check(
  (select delivered_at is not null and next_attempt_at is null from public.notification_outbox
    where event_id = 'msg:' || current_setting('test.msg')),
  'a message the chat delivered is not pushed again');

-- 5. The dispatcher drops the retry of a message already delivered ----------------
do $$
declare
  v_id uuid;
begin
  select id into v_id from public.ride_messages
   where request_id = '00000000-0000-0000-0000-0000000146d1' and status = 'sent' limit 1;
  perform set_config('test.msg2', v_id::text, true);
  -- Delivered without going through the chat (as an admin session can).
  update public.ride_messages set status = 'delivered' where id = v_id;
end $$;
update public.notification_outbox set delivered_at = null, next_attempt_at = now() - interval '1 second'
 where event_id = 'msg:' || current_setting('test.msg2');
select public.dispatch_notification_outbox();
select pg_temp.check(
  (select stopped_reason = 'moved_on' and attempts = 1 from public.notification_outbox
    where event_id = 'msg:' || current_setting('test.msg2')),
  'a delivered message is not pushed again by the dispatcher');

select 'ride_message_delivery: all passed';
rollback;
