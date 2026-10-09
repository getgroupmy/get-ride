-- ============================================================================
-- Regression test for migration 0131: rider ↔ driver calls are the two
-- participants' alone, only ring while the ride is in progress, and a call's
-- status moves forward only, each step by the side allowed to take it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_calls.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

-- Read-only checks first: when a call rings out, and what clients can't call.
do $$
begin
  if public.ride_call_rang_out('ringing', '2026-01-01 00:00:00+00', '2026-01-01 00:00:44+00')
     or not public.ride_call_rang_out('ringing', '2026-01-01 00:00:00+00', '2026-01-01 00:00:45+00')
     or public.ride_call_rang_out('answered', '2026-01-01 00:00:00+00', '2026-01-01 01:00:00+00') then
    raise exception 'FAILED: a call rings out after 45 seconds of ringing, and only then';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_ride_calls_guard')
     or not exists (select 1 from pg_trigger where tgname = 'trg_ride_calls_before_insert')
     or not exists (select 1 from pg_trigger where tgname = 'trg_ride_calls_push')
     or not exists (select 1 from pg_trigger where tgname = 'trg_ride_calls_clear_signals')
     or not exists (select 1 from pg_trigger where tgname = 'trg_ride_requests_end_calls') then
    raise exception 'FAILED: a ride_calls trigger is missing';
  end if;

  if has_function_privilege('authenticated', 'public.notify_ride_call_push()', 'execute')
     or has_function_privilege('anon', 'public.notify_ride_call_push()', 'execute')
     or has_function_privilege('authenticated', 'public.ride_calls_before_insert()', 'execute')
     or has_function_privilege('authenticated', 'public.ride_calls_clear_signals()', 'execute')
     or has_function_privilege('authenticated', 'public.ride_requests_end_calls()', 'execute')
     or has_function_privilege('anon', 'public.ride_requests_end_calls()', 'execute') then
    raise exception 'FAILED: the ride_calls definer functions must not be callable by clients';
  end if;
  if has_column_privilege('authenticated', 'public.ride_calls', 'callee_id', 'update')
     or has_column_privilege('authenticated', 'public.ride_calls', 'caller_id', 'insert')
     or not has_column_privilege('authenticated', 'public.ride_calls', 'status', 'update')
     or not has_column_privilege('authenticated', 'public.ride_calls', 'request_id', 'insert') then
    raise exception 'FAILED: clients name the ride and move the status, nothing else';
  end if;
  if has_table_privilege('anon', 'public.ride_calls', 'select')
     or has_table_privilege('anon', 'public.ride_call_signals', 'select') then
    raise exception 'FAILED: anon must not read ride calls';
  end if;
end
$$;

begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000131a1'),  -- rider
  ('00000000-0000-0000-0000-0000000131b1'),  -- driver
  ('00000000-0000-0000-0000-0000000131c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000131%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, rider_name, partner_name) values
  ('00000000-0000-0000-0000-0000000131d1', '00000000-0000-0000-0000-0000000131a1', '00000000-0000-0000-0000-0000000131b1', 'accepted', 'Aina', 'Ravi'),
  ('00000000-0000-0000-0000-0000000131d2', '00000000-0000-0000-0000-0000000131a1', '00000000-0000-0000-0000-0000000131b1', 'completed', 'Aina', 'Ravi'),
  ('00000000-0000-0000-0000-0000000131d3', '00000000-0000-0000-0000-0000000131a1', null, 'open', 'Aina', null);

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

create or replace function pg_temp.expect_status(p_id uuid, p_status text) returns void language plpgsql as $$
begin
  if (select status from public.ride_calls where id = p_id) is distinct from p_status then
    raise exception 'FAILED: call % should be % (is %)', p_id, p_status,
      (select status from public.ride_calls where id = p_id);
  end if;
end $$;
grant execute on function pg_temp.expect_status(uuid, text) to authenticated;

create or replace function pg_temp.expect_calls(p_n int, p_what text) returns void language plpgsql as $$
begin
  if (select count(*) from public.ride_calls) <> p_n then
    raise exception 'FAILED: % (saw %)', p_what, (select count(*) from public.ride_calls);
  end if;
end $$;
grant execute on function pg_temp.expect_calls(int, text) to authenticated;

-- The id of the live call on the running ride.
create or replace function pg_temp.live() returns uuid language sql as $$
  select id from public.ride_calls
   where request_id = '00000000-0000-0000-0000-0000000131d1' and status in ('ringing', 'answered')
$$;
grant execute on function pg_temp.live() to authenticated;

set local role authenticated;

-- 1. The rider rings the driver; who is who comes from the ride -------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1');
do $$
declare
  c public.ride_calls;
begin
  select * into c from public.ride_calls where id = pg_temp.live();
  if c.caller_id <> '00000000-0000-0000-0000-0000000131a1' or c.callee_id <> '00000000-0000-0000-0000-0000000131b1'
     or c.caller_role <> 'rider' or c.caller_name <> 'Aina' or c.callee_name <> 'Ravi' or c.status <> 'ringing' then
    raise exception 'FAILED: a new call should be the rider ringing the driver: %', c;
  end if;
end $$;

-- 2. Not on a finished ride, one without a driver, or a second at once ------
select pg_temp.refused(
  $q$insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d2')$q$,
  'a call on a completed ride');
select pg_temp.refused(
  $q$insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d3')$q$,
  'a call on a ride with no driver');
select pg_temp.refused(
  $q$insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1')$q$,
  'a second live call on the ride');
select pg_temp.refused(
  $q$insert into public.ride_calls (request_id, callee_id, caller_role)
     values ('00000000-0000-0000-0000-0000000131d1', '00000000-0000-0000-0000-0000000131c1', 'partner')$q$,
  'a client choosing who is called');

-- 3. An outsider neither sees, rings nor answers ----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000131c1');
select pg_temp.expect_calls(0, 'an outsider should see no ride calls');
select pg_temp.refused(
  $q$insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1')$q$,
  'an outsider ringing on somebody''s ride');
update public.ride_calls set status = 'declined';

-- 4. The caller can't answer their own call; the callee does ---------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
select pg_temp.refused(
  $q$update public.ride_calls set status = 'answered' where id = pg_temp.live()$q$,
  'the caller answering their own call');
select pg_temp.as_user('00000000-0000-0000-0000-0000000131b1');
select pg_temp.expect_calls(1, 'the driver should see the call');
select pg_temp.refused(
  $q$update public.ride_calls set status = 'cancelled' where id = pg_temp.live()$q$,
  'the callee cancelling the caller''s call');
select pg_temp.refused(
  $q$update public.ride_calls set status = 'missed' where id = pg_temp.live()$q$,
  'the callee calling a ringing call missed');
update public.ride_calls set status = 'answered' where id = pg_temp.live();
select pg_temp.expect_status(pg_temp.live(), 'answered');

-- 5. Signals: the two of them only, and gone once the call is over ---------
insert into public.ride_call_signals (call_id, kind, payload) values (pg_temp.live(), 'offer', '{"sdp":"o"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
insert into public.ride_call_signals (call_id, kind, payload) values (pg_temp.live(), 'answer', '{"sdp":"a"}');
select pg_temp.refused(
  $q$insert into public.ride_call_signals (call_id, sender, kind)
     values (pg_temp.live(), '00000000-0000-0000-0000-0000000131b1', 'bye')$q$,
  'a signal under the other side''s id');
do $$
begin
  if (select count(*) from public.ride_call_signals) <> 2 then
    raise exception 'FAILED: the rider should see both signals';
  end if;
end $$;
select set_config('test.call', pg_temp.live()::text, true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000131c1');
do $$
begin
  if (select count(*) from public.ride_call_signals) <> 0 then
    raise exception 'FAILED: an outsider read a call''s signals';
  end if;
end $$;
select pg_temp.refused(
  $q$insert into public.ride_call_signals (call_id, kind)
     values (current_setting('test.call')::uuid, 'bye')$q$,
  'an outsider signalling');

-- 6. Answered only ever ends, by either side; finished stays finished ------
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
select pg_temp.refused(
  $q$update public.ride_calls set status = 'ringing' where id = pg_temp.live()$q$,
  'an answered call ringing again');
select pg_temp.refused(
  $q$update public.ride_calls set status = 'declined' where id = pg_temp.live()$q$,
  'declining a call already answered');
select pg_temp.refused(
  $q$update public.ride_calls set caller_name = 'Someone' where id = pg_temp.live()$q$,
  'renaming the caller');
do $$
declare
  v uuid := pg_temp.live();
begin
  update public.ride_calls set status = 'ended' where id = v;
  perform pg_temp.expect_status(v, 'ended');
  if (select ended_at from public.ride_calls where id = v) is null
     or (select answered_at from public.ride_calls where id = v) is null then
    raise exception 'FAILED: an ended call keeps when it was answered and stamps when it ended';
  end if;
  if exists (select 1 from public.ride_call_signals where call_id = v) then
    raise exception 'FAILED: a finished call''s signals should be deleted';
  end if;
  begin
    update public.ride_calls set status = 'answered' where id = v;
    raise exception 'FAILED: an ended call was answered again';
  exception when insufficient_privilege then
    null;
  end;
end $$;

-- 7. The driver rings; the caller cancels, the callee declines -------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000131b1');
insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1');
do $$
begin
  if (select caller_role from public.ride_calls where id = pg_temp.live()) <> 'partner'
     or (select callee_name from public.ride_calls where id = pg_temp.live()) <> 'Aina' then
    raise exception 'FAILED: the driver ringing the rider';
  end if;
end $$;
do $$
declare
  v uuid := pg_temp.live();
begin
  update public.ride_calls set status = 'cancelled' where id = v;
  perform pg_temp.expect_status(v, 'cancelled');
end $$;
insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1');
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
do $$
declare
  v uuid := pg_temp.live();
begin
  update public.ride_calls set status = 'declined' where id = v;
  perform pg_temp.expect_status(v, 'declined');
end $$;

-- 8. A call that rang out is missed: answering it records that -------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000131b1');
insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1');
reset role;
-- Wind the clock back on it (a superuser edit, as if it had rung 50 s ago).
alter table public.ride_calls disable trigger trg_ride_calls_guard;
update public.ride_calls set created_at = now() - interval '50 seconds' where id = pg_temp.live();
alter table public.ride_calls enable trigger trg_ride_calls_guard;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
do $$
declare
  v uuid := pg_temp.live();
begin
  update public.ride_calls set status = 'answered' where id = v;
  perform pg_temp.expect_status(v, 'missed');
end $$;

-- A rung-out call nobody recorded doesn't block the next one.
insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1');
reset role;
alter table public.ride_calls disable trigger trg_ride_calls_guard;
update public.ride_calls set created_at = now() - interval '50 seconds' where id = pg_temp.live();
alter table public.ride_calls enable trigger trg_ride_calls_guard;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000131b1');
do $$
declare
  v_old uuid := pg_temp.live();
begin
  insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1');
  perform pg_temp.expect_status(v_old, 'missed');
  if pg_temp.live() = v_old then
    raise exception 'FAILED: the new call should be the live one';
  end if;
end $$;

-- 9. The ride ending ends its call ------------------------------------------
reset role;
do $$
declare
  v uuid := pg_temp.live();
begin
  update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000131d1';
  perform pg_temp.expect_status(v, 'cancelled');
end $$;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000131a1');
select pg_temp.refused(
  $q$insert into public.ride_calls (request_id) values ('00000000-0000-0000-0000-0000000131d1')$q$,
  'a call once the ride has completed');

-- 10. Participants don't delete --------------------------------------------
select pg_temp.refused($q$delete from public.ride_calls$q$, 'a participant deleting calls');

select 'ride_calls: all passed';
rollback;
