-- ============================================================================
-- Regression test for migration 0191: an unanswered cancellation request
-- lapses after the admin's time without ending the ride; a declined or
-- lapsed one is recorded and opens one support ticket per ride.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/cancel_request_timeout.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000191a1'),  -- rider
  ('00000000-0000-0000-0000-0000000191b1'),  -- driver
  ('00000000-0000-0000-0000-0000000191c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000191%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000191c1', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000191b1', 'Dan', '+60110000191', 'approved');
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name, drop_name) values
  ('00000000-0000-0000-0000-0000000191d1', '00000000-0000-0000-0000-0000000191a1',
   '00000000-0000-0000-0000-0000000191b1', 'on_trip', 20, 20, 'KLCC', 'Mid Valley'),
  ('00000000-0000-0000-0000-0000000191d2', '00000000-0000-0000-0000-0000000191a1',
   '00000000-0000-0000-0000-0000000191b1', 'arrived', 15, 15, 'Bangsar', 'TRX');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text) to authenticated;

-- 1. Settings: the admin's, kept within limits ------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000191a1');
select pg_temp.refused($q$select public.set_ride_cancel_request_config('{"timeoutSeconds":60}')$q$, 'a rider changing the timeout');
select pg_temp.as_user('00000000-0000-0000-0000-0000000191c1');
select pg_temp.check((public.set_ride_cancel_request_config('{"timeoutSeconds":5}')->>'timeoutSeconds')::int = 30,
  'the timeout is at least 30 seconds');
select public.set_ride_cancel_request_config('{"timeoutSeconds":120,"openTicket":true}');

-- 2. The rider asks to cancel mid-trip; nobody answers ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000191a1');
update public.ride_requests set cancel_requested_at = now() - interval '3 minutes', cancel_requested_by = 'rider',
       cancel_reason = 'Wrong destination'
 where id = '00000000-0000-0000-0000-0000000191d1';
update public.ride_requests set cancel_request_outcome = 'expired' where id = '00000000-0000-0000-0000-0000000191d1';
reset role;
select pg_temp.check((select cancel_request_outcome is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d1'),
  'a client cannot write the outcome');

-- A fresh request on the other ride is not due yet.
update public.ride_requests set cancel_requested_at = now(), cancel_requested_by = 'rider'
 where id = '00000000-0000-0000-0000-0000000191d2';
select pg_temp.check(public.ride_cancel_requests_lapse() = 1, 'only the overdue request lapses');
select pg_temp.check((select status = 'on_trip' and cancel_requested_at is null and cancel_request_outcome = 'expired'
                             and cancel_request_outcome_by = 'rider' and cancel_ticket_id is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d1'),
  'it lapses: the ride carries on, recorded as not answered');
select pg_temp.check((select cancel_requested_at is not null from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d2'),
  'the other request still waits');
select pg_temp.check((select t.profile_id = '00000000-0000-0000-0000-0000000191a1' and t.subject like '%not answered%'
                             and t.unread_admin = 1
                        from public.support_tickets t join public.ride_requests r on r.cancel_ticket_id = t.id
                       where r.id = '00000000-0000-0000-0000-0000000191d1'),
  'a ticket is opened for the rider');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where request_id = '00000000-0000-0000-0000-0000000191d1'
                                and title = 'No answer to your cancellation'),
  'the rider is told nobody answered');

-- 3. Asked again, then declined: the same ticket ---------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000191a1');
update public.ride_requests set cancel_requested_at = now(), cancel_requested_by = 'rider'
 where id = '00000000-0000-0000-0000-0000000191d1';
reset role;
select pg_temp.check((select cancel_request_outcome is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d1'),
  'asking again clears the outcome');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000191b1');
update public.ride_requests set cancel_requested_at = null, cancel_requested_by = null
 where id = '00000000-0000-0000-0000-0000000191d1';
reset role;
select pg_temp.check((select cancel_request_outcome = 'declined' from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d1'),
  'the driver''s answer is recorded as declined');
select pg_temp.check((select count(*) = 1 from public.support_tickets where profile_id = '00000000-0000-0000-0000-0000000191a1'),
  'one ticket per ride');
select pg_temp.check((select count(*) = 2 from public.support_messages m join public.ride_requests r on r.cancel_ticket_id = m.ticket_id
                       where r.id = '00000000-0000-0000-0000-0000000191d1'),
  'the decline is added to it');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where request_id = '00000000-0000-0000-0000-0000000191d1' and title = 'Cancellation declined'),
  'a decline still reads as declined');

-- 4. Approved: no outcome, no ticket -----------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000191b1');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000191d2';
reset role;
select pg_temp.check((select cancel_request_outcome is null and cancel_ticket_id is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d2'),
  'an approved cancellation opens nothing');

-- 5. Tickets can be switched off ---------------------------------------------------------------------
update public.app_settings set value = '{"timeoutSeconds":120,"openTicket":false}' where key = 'ride_cancel_request';
update public.ride_requests set cancel_requested_at = now() - interval '5 minutes', cancel_requested_by = 'partner',
       cancel_ticket_id = null
 where id = '00000000-0000-0000-0000-0000000191d1';
select public.ride_cancel_requests_lapse();
select pg_temp.check((select cancel_request_outcome = 'expired' and cancel_request_outcome_by = 'partner' and cancel_ticket_id is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000191d1'),
  'lapsed, without a ticket when switched off');
select pg_temp.check(not has_function_privilege('authenticated', 'public.ride_cancel_requests_lapse()', 'execute'),
  'clients do not run the lapse');

select 'cancel_request_timeout: all passed';
rollback;
