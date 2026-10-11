-- ============================================================================
-- Regression test for migration 0144: trip pushes through the outbox, with
-- retries until the app acknowledges them.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/notification_outbox.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000144a1'),  -- rider
  ('00000000-0000-0000-0000-0000000144b1'),  -- driver
  ('00000000-0000-0000-0000-0000000144c1'),  -- somebody else
  ('00000000-0000-0000-0000-0000000144d1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000144%'
on conflict do nothing;
insert into public.admin_access (profile_id, page) values ('00000000-0000-0000-0000-0000000144d1', 'admin-push')
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, partner_name, partner_plate, pickup_name) values
  ('00000000-0000-0000-0000-0000000144e1', '00000000-0000-0000-0000-0000000144a1', '00000000-0000-0000-0000-0000000144b1',
   'accepted', 20, 20, 'Ali', 'ABC1234', 'KLCC');

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

-- 1. Who is told what -----------------------------------------------------------
do $$
declare
  o public.ride_requests;
  n public.ride_requests;
  m jsonb;
  rider constant uuid := '00000000-0000-0000-0000-0000000144a1';
  driver constant uuid := '00000000-0000-0000-0000-0000000144b1';
begin
  select * into o from public.ride_requests where id = '00000000-0000-0000-0000-0000000144e1';
  o.status := 'open';
  n := o; n.status := 'accepted';
  -- The driver took it: only the rider is told.
  m := public.ride_status_messages(o, n, driver);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'rider' or m->0->>'body' not like 'Ali is on the way in ABC1234%' then
    raise exception 'FAILED: driver assigned goes to the rider: %', m;
  end if;
  -- The rider accepted the driver's offer: only the driver is told.
  m := public.ride_status_messages(o, n, rider);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'partner' then
    raise exception 'FAILED: an accepted offer goes to the driver: %', m;
  end if;
  -- Arrived.
  o := n; n.status := 'arrived';
  m := public.ride_status_messages(o, n, driver);
  if jsonb_array_length(m) <> 1 or m->0->>'title' <> 'Your driver has arrived' or m->0->>'priority' <> 'critical' then
    raise exception 'FAILED: arrived: %', m;
  end if;
  -- Cancelled by the rider: only the driver is told.
  o := n; n.status := 'cancelled';
  m := public.ride_status_messages(o, n, rider);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'partner' then
    raise exception 'FAILED: a rider cancel tells the driver: %', m;
  end if;
  -- Cancelled server-side: both.
  m := public.ride_status_messages(o, n, null);
  if jsonb_array_length(m) <> 2 then
    raise exception 'FAILED: a server cancel tells both: %', m;
  end if;
  -- A cancellation asked for by the driver goes to the rider; declined goes back.
  n := o; n.cancel_requested_at := now(); n.cancel_requested_by := 'partner';
  m := public.ride_status_messages(o, n, driver);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'rider' or m->0->'data'->>'type' <> 'ride_cancel_request' then
    raise exception 'FAILED: a cancellation request goes to the other side: %', m;
  end if;
  m := public.ride_status_messages(n, o, rider);
  if jsonb_array_length(m) <> 1 or m->0->>'to' <> 'partner' or m->0->>'title' <> 'Cancellation declined' then
    raise exception 'FAILED: a declined cancellation goes back to who asked: %', m;
  end if;
  -- Nothing changed, nothing said.
  if jsonb_array_length(public.ride_status_messages(o, o, driver)) <> 0 then
    raise exception 'FAILED: no change, no message';
  end if;
end $$;

-- 2. The driver arrives: the rider's push is queued and sent once ---------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000144b1');
update public.ride_requests set status = 'arrived' where id = '00000000-0000-0000-0000-0000000144e1';
reset role;
select pg_temp.check(
  (select count(*) = 1 and bool_and(attempts = 1 and next_attempt_at > now() and kind = 'ride_status'
                                    and profile_id = '00000000-0000-0000-0000-0000000144a1')
     from public.notification_outbox where request_id = '00000000-0000-0000-0000-0000000144e1'),
  'arrived is queued for the rider, sent once, with a retry due');

-- The same event is never queued twice.
select public.enqueue_notification('00000000-0000-0000-0000-0000000144a1',
  '00000000-0000-0000-0000-0000000144e1:arrived:r', 'ride_status', 'critical', 't', 'b', '{}', null);
select pg_temp.check((select count(*) = 1 from public.notification_outbox
                       where event_id = '00000000-0000-0000-0000-0000000144e1:arrived:r'), 'one row per event');

-- 3. Not acknowledged: the dispatcher sends it again --------------------------
update public.notification_outbox set next_attempt_at = now() - interval '1 second'
 where request_id = '00000000-0000-0000-0000-0000000144e1';
select public.dispatch_notification_outbox();
select pg_temp.check((select attempts = 2 from public.notification_outbox
                       where event_id = '00000000-0000-0000-0000-0000000144e1:arrived:r'), 'retried');

-- 4. Only the owner acknowledges, and the retries stop ------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000144c1');
select pg_temp.check(public.ack_notification('00000000-0000-0000-0000-0000000144e1:arrived:r') = 0,
  'somebody else can''t acknowledge it');
select pg_temp.check((select count(*) = 0 from public.notification_outbox), 'somebody else can''t see it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000144a1');
select pg_temp.check((select count(*) = 1 from public.notification_outbox), 'the rider sees their own row');
select pg_temp.check(public.ack_notification('00000000-0000-0000-0000-0000000144e1:arrived:r', 'read') = 1, 'acknowledged');
-- The app can't write the outbox: row security leaves the update nothing to touch.
update public.notification_outbox set delivered_at = null, read_at = null;
reset role;
select pg_temp.check((select delivered_at is not null and read_at is not null and next_attempt_at is null
                        from public.notification_outbox where event_id = '00000000-0000-0000-0000-0000000144e1:arrived:r'),
  'acknowledged rows are not retried');

-- 5. A trip that moved on stops its retries -----------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000144b1');
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000144e1';
reset role;
insert into public.notification_outbox (event_id, profile_id, request_id, kind, priority, title, body, data, attempts, next_attempt_at)
values ('stale-arrived', '00000000-0000-0000-0000-0000000144a1', '00000000-0000-0000-0000-0000000144e1',
        'ride_status', 'critical', 't', 'b', '{"status":"arrived"}', 1, now() - interval '1 second');
select public.dispatch_notification_outbox();
select pg_temp.check((select stopped_reason = 'moved_on' and next_attempt_at is null and attempts = 1
                        from public.notification_outbox where event_id = 'stale-arrived'),
  'an arrived push is not resent once the trip started');

-- The trip screen acknowledges everything about the trip.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000144a1');
select pg_temp.check(public.ack_ride_notifications('00000000-0000-0000-0000-0000000144e1') >= 1, 'trip screen acks');
reset role;

-- 6. The retry schedule ---------------------------------------------------------
select pg_temp.check(public.notification_retry_delay('critical', 1) = interval '20 seconds'
                 and public.notification_retry_delay('critical', 3) = interval '180 seconds'
                 and public.notification_retry_delay('critical', 4) is null
                 and public.notification_retry_delay('normal', 1) = interval '120 seconds'
                 and public.notification_retry_delay('normal', 2) is null, 'retry schedule');

-- 7. Payment pushes go through the outbox --------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000144b1');
update public.ride_requests set status = 'completed', toll_charges = 2 where id = '00000000-0000-0000-0000-0000000144e1';
reset role;
select pg_temp.check((select count(*) = 1 from public.notification_outbox
                       where kind = 'ride_payment' and profile_id = '00000000-0000-0000-0000-0000000144a1'
                         and data->>'payment_status' = 'due'),
  'trip complete with the total to pay is queued for the rider');

-- 8. Stats are for admins ---------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000144a1');
select pg_temp.refused($q$select * from public.notification_delivery_stats(24)$q$, 'a rider reading delivery stats');
select pg_temp.as_user('00000000-0000-0000-0000-0000000144d1');
select pg_temp.check((select sum(sent) >= 2 from public.notification_delivery_stats(24)), 'admin stats');
reset role;

select 'notification_outbox: all passed';
rollback;
