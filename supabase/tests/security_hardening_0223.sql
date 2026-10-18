-- ============================================================================
-- Regression test for migration 0223 (parts 2-14 and the money flows):
-- changing a PIN takes proof; who asked to cancel, the trip times, the route
-- and a finished ride's money are the server's; the back office's EV order
-- keys; launch telemetry; SOS / referral limits; the sub-admin directory;
-- support message senders; trip recordings; incentives count a ride once;
-- coin transfers are the server's.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_hardening_0223.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000223c1'),  -- rider
  ('00000000-0000-0000-0000-0000000223d1'),  -- driver
  ('00000000-0000-0000-0000-0000000223e1'),  -- sub-admin: EV orders + support, edit
  ('00000000-0000-0000-0000-0000000223f1')   -- full admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000223%'
on conflict do nothing;
update public.profiles set name = 'Bella', phone = '+60100000223' where id = '00000000-0000-0000-0000-0000000223c1';
update public.profiles set name = 'Dina' where id = '00000000-0000-0000-0000-0000000223d1';
update public.profiles set name = 'Eve' where id = '00000000-0000-0000-0000-0000000223e1';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000223e1', 'admin-orders', 'edit'),
  ('00000000-0000-0000-0000-0000000223e1', 'admin-support', 'edit'),
  ('00000000-0000-0000-0000-0000000223f1', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000223d1', 'Dina', '+60110000223', 'approved');

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000223a1', '00000000-0000-0000-0000-0000000223c1', '00000000-0000-0000-0000-0000000223d1', 'on_trip',   20, 20),
  ('00000000-0000-0000-0000-0000000223a2', '00000000-0000-0000-0000-0000000223c1', '00000000-0000-0000-0000-0000000223d1', 'accepted',  20, 20),
  ('00000000-0000-0000-0000-0000000223a3', '00000000-0000-0000-0000-0000000223c1', '00000000-0000-0000-0000-0000000223d1', 'completed', 20, 20),
  ('00000000-0000-0000-0000-0000000223a4', '00000000-0000-0000-0000-0000000223c1', '00000000-0000-0000-0000-0000000223d1', 'on_trip',  100, 100);

create or replace function pg_temp.as_user(p uuid, p_amr jsonb default '[]') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p, 'role', 'authenticated', 'amr', p_amr)::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    if sqlerrm not like p_like then
      raise exception 'FAILED: % refused for the wrong reason: %', p_what, sqlerrm;
    end if;
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.as_user(uuid, jsonb), pg_temp.as_anon(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text, text) to anon, authenticated;
create temp table ids (k text primary key, id uuid);
grant all on ids to anon, authenticated;

-- 2. Changing a PIN takes the current one, or a fresh SMS sign-in -----------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.check(public.set_login_pin('135790', null), 'the first PIN is set without proof');
select pg_temp.refused($q$select public.set_login_pin('246810', null)$q$, 'a new PIN without proof', '%PIN_PROOF_REQUIRED%');
select pg_temp.check(public.set_login_pin('246810', null, '000000') = false, 'a wrong current PIN changes nothing');
select pg_temp.check(public.set_login_pin('246810', null, '135790'), 'the current PIN changes it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1',
  jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint)));
select pg_temp.check(public.set_login_pin('112233', null), 'a fresh SMS sign-in changes it (forgot PIN)');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1',
  jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint - 3600)));
select pg_temp.refused($q$select public.set_login_pin('445566', null)$q$, 'an hour-old SMS sign-in', '%PIN_PROOF_REQUIRED%');
reset role;
update public.profiles set pin_failed_attempts = 0, pin_locked_until = null where id = '00000000-0000-0000-0000-0000000223c1';

-- 3. Who asked to cancel is who the caller is -------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223d1');
update public.ride_requests set cancel_requested_at = now(), cancel_requested_by = 'rider'
 where id = '00000000-0000-0000-0000-0000000223a1';
select pg_temp.check((select cancel_requested_by = 'partner' from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000223a1'), 'the driver''s request is the driver''s');
select pg_temp.refused($q$update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000223a1'$q$,
  'a driver cancelling mid-trip on their own request');
select pg_temp.refused($q$update public.ride_requests set cancel_requested_by = 'rider' where id = '00000000-0000-0000-0000-0000000223a1'$q$,
  'a driver blaming the rider', '%RIDE_CANCEL_BY_SERVER_ONLY%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
update public.ride_requests set cancel_requested_at = now() - interval '1 second'
 where id = '00000000-0000-0000-0000-0000000223a1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000223d1');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000223a1';
select pg_temp.check((select status = 'cancelled' and cancel_requested_by = 'rider' from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000223a1'), 'the rider''s own request lets the driver end it');

-- 4. Trip times, the route, the rating and a finished ride's money -----------------------------
update public.ride_requests set status = 'arrived', arrived_at = '2000-01-01'
 where id = '00000000-0000-0000-0000-0000000223a2';
select pg_temp.check((select arrived_at > now() - interval '1 minute' from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000223a2'), 'arriving is stamped with the server''s clock');
select pg_temp.refused($q$update public.ride_requests set accepted_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000223a2'$q$,
  'a driver re-dating the trip', '%RIDE_SERVER_ONLY%');
select pg_temp.refused($q$update public.ride_requests set pickup_lat = 1.3, pickup_lng = 103.8 where id = '00000000-0000-0000-0000-0000000223a2'$q$,
  'moving the pickup after booking', '%RIDE_ROUTE_LOCKED%');
select pg_temp.refused($q$update public.ride_requests set toll_charges = 3 where id = '00000000-0000-0000-0000-0000000223a3'$q$,
  'adding a toll to a finished trip', '%RIDE_FARE_LOCKED%');
select pg_temp.refused($q$update public.ride_requests set status = 'completed', toll_charges = 'NaN' where id = '00000000-0000-0000-0000-0000000223a4'$q$,
  'a toll that is not a number');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
update public.ride_requests set rider_rating = 1 where id = '00000000-0000-0000-0000-0000000223a2';
select pg_temp.check((select rider_rating = 5 from public.ride_requests where id = '00000000-0000-0000-0000-0000000223a2'),
  'the rider''s rating is the server''s');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, completed_at)
  values ('00000000-0000-0000-0000-0000000223c1', 'open', 5, 5, now())$q$, 'a new request carrying trip times', '%RIDE_SERVER_ONLY%');
reset role;
-- Ending early: never below the floor.
do $$
declare
  r public.ride_requests;
  f numeric;
begin
  select * into r from public.ride_requests where id = '00000000-0000-0000-0000-0000000223a4';
  f := public.ride_early_end_floor(r);
  if f is null or f < 0 or f > 100 then
    raise exception 'FAILED: an early-end floor of % for a fare of 100', f;
  end if;
  perform set_config('test.floor', f::text, true);
end $$;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223d1');
do $$
declare f numeric := current_setting('test.floor')::numeric;
begin
  if f >= 0.02 then
    perform pg_temp.refused(format($q$update public.ride_requests set status = 'completed', ride_fare = %s
      where id = '00000000-0000-0000-0000-0000000223a4'$q$, f - 0.01), 'an early end below the floor', '%RIDE_FARE_TOO_LOW%');
  end if;
end $$;
reset role;

-- 5. EV orders: the back office's keys --------------------------------------------------------
insert into public.ev_delivery_advisors (id, values) values
  ('00000000-0000-0000-0000-0000000223ad', '{"name": "Adam", "daNumber": "DA223", "contact": "+60120000999"}');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
insert into public.ev_orders (id, values)
values ('00000000-0000-0000-0000-0000000223e0',
        '{"status": "delivered", "depositPaid": true, "checklistSubmitted": true, "advisorId": "x", "total": 100}');
select pg_temp.check((select values->>'status' = 'pending' and values->>'depositPaid' = 'false'
                             and not values ? 'checklistSubmitted' and not values ? 'advisorId'
                             and values->>'total' = '100'
                        from public.ev_orders where id = '00000000-0000-0000-0000-0000000223e0'),
  'a new order starts pending with nothing received');
update public.ev_orders set values = values || '{"depositPaid": true, "depositStatus": "received", "plateNumber": "WXY1"}'
 where id = '00000000-0000-0000-0000-0000000223e0';
select pg_temp.check((select values->>'depositPaid' = 'false' and values->>'plateNumber' = 'WXY1'
                        from public.ev_orders where id = '00000000-0000-0000-0000-0000000223e0'),
  'the customer saves their own step, not a payment received');
update public.ev_orders set values = values || '{"advisorId": "00000000-0000-0000-0000-0000000223ad", "advisorName": "Fake", "status": "assigned"}'
 where id = '00000000-0000-0000-0000-0000000223e0';
select pg_temp.check((select values->>'advisorName' = 'Adam' and values->>'status' = 'assigned'
                        from public.ev_orders where id = '00000000-0000-0000-0000-0000000223e0'),
  'linking a delivery advisor by code copies the catalogue''s advisor');
update public.ev_orders set values = values || '{"checklistAccepted": true, "status": "delivered"}'
 where id = '00000000-0000-0000-0000-0000000223e0';
select pg_temp.check((select values->>'status' = 'assigned' and not values ? 'checklistAccepted'
                        from public.ev_orders where id = '00000000-0000-0000-0000-0000000223e0'),
  'no delivery before the advisor''s checklist');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223e1');
update public.ev_orders set values = values || '{"checklistSubmitted": true, "status": "ready_for_delivery", "depositPaid": true}'
 where id = '00000000-0000-0000-0000-0000000223e0';
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
update public.ev_orders set values = values || '{"checklistAccepted": true, "status": "delivered"}'
 where id = '00000000-0000-0000-0000-0000000223e0';
select pg_temp.check((select values->>'status' = 'delivered' and values->>'checklistAccepted' = 'true'
                             and values->>'depositPaid' = 'true'
                        from public.ev_orders where id = '00000000-0000-0000-0000-0000000223e0'),
  'the customer accepts delivery once the checklist is in; the back office''s keys stand');
reset role;

-- 6. Launch telemetry ----------------------------------------------------------------------------
set local role anon;
select pg_temp.as_anon();
insert into public.user_sessions (user_id, event_type, device_id, is_physical_device)
values (null, 'app_launch', 'device-0223', false);
select pg_temp.refused($q$insert into public.user_sessions (user_id, event_type)
  values ('00000000-0000-0000-0000-0000000223c1', 'app_launch')$q$, 'a signed-out row naming somebody');
select pg_temp.check(not (select is_emulator from public.device_registration_status('device-0223')),
  'a signed-out "emulator" row doesn''t mark the device');
reset role;
insert into public.auth_rate_hits (bucket, key) select 'telemetry_anon', '203.0.113.23' from generate_series(1, 120);
set local role anon;
select pg_temp.as_anon();
select set_config('request.headers', '{"x-real-ip": "203.0.113.23"}', true);
select pg_temp.refused($q$insert into public.user_sessions (user_id, event_type) values (null, 'app_launch')$q$,
  'the 121st signed-out row from one address in an hour', '%RATE_LIMITED%');
select set_config('request.headers', '', true);
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.refused($q$insert into public.user_location_history (user_id, latitude, longitude) values (null, 3.1, 101.6)$q$,
  'a location row naming nobody');
insert into public.user_location_history (user_id, latitude, longitude)
values ('00000000-0000-0000-0000-0000000223c1', 3.1, 101.6);
reset role;

-- 7. SOS and referral limits --------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
insert into ids select 'sos', public.sos_raise(null, 3.15, 101.71);
reset role;
insert into public.auth_rate_hits (bucket, key) select 'sos', '00000000-0000-0000-0000-0000000223c1' from generate_series(1, 3);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.check(public.sos_raise(null, 3.16, 101.72) = (select id from ids where k = 'sos'),
  'pressing again within ten minutes still updates the alert');
reset role;
update public.safety_incidents set status = 'resolved' where id = (select id from ids where k = 'sos');
insert into public.auth_rate_hits (bucket, key)
select 'referral', '00000000-0000-0000-0000-0000000223c1' from generate_series(1, 10);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.refused($q$select public.sos_raise(null, 3.15, 101.71)$q$, 'a fourth new alert in an hour', '%RATE_LIMITED%');
select pg_temp.refused($q$select public.apply_referral('ABCD1234')$q$, 'an eleventh referral code in an hour', '%RATE_LIMITED%');
reset role;

-- 8. The sub-admin directory is for admins ------------------------------------------------------
insert into public.settings_entries (category, values) values ('sub-admin', '{"email": "eve@example.com"}');
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(not exists (select 1 from public.settings_entries where category = 'sub-admin'),
  'signed out, no sub-admin rows');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.check(not exists (select 1 from public.settings_entries where category = 'sub-admin'),
  'a rider sees no sub-admin rows');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223f1');
select pg_temp.check(exists (select 1 from public.settings_entries where category = 'sub-admin'),
  'an admin still does');
reset role;

-- 13. Who sent a support message ----------------------------------------------------------------
insert into public.support_tickets (id, profile_id) values
  ('00000000-0000-0000-0000-0000000223ab', '00000000-0000-0000-0000-0000000223c1');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
insert into public.support_messages (ticket_id, sender_role, sender_id, sender_name, body)
values ('00000000-0000-0000-0000-0000000223ab', 'admin', '00000000-0000-0000-0000-0000000223f1', 'GET Support', 'Refund approved');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223e1');
insert into public.support_messages (ticket_id, sender_role, body)
values ('00000000-0000-0000-0000-0000000223ab', 'user', 'Hello, how can I help?');
reset role;
select pg_temp.check((select sender_role = 'user' and sender_id = '00000000-0000-0000-0000-0000000223c1'
                             and sender_name = 'Bella'
                        from public.support_messages where body = 'Refund approved'),
  'a user can''t post as support');
select pg_temp.check((select sender_role = 'admin' and sender_name = 'Eve'
                        from public.support_messages where body = 'Hello, how can I help?'),
  'a support editor answers as support');

-- 14. Trip recordings: the phone only answers an upload request ---------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
insert into public.voice_protection_recordings (id, profile_id, uploaded, media_url, upload_requested)
values ('00000000-0000-0000-0000-0000000223af', '00000000-0000-0000-0000-0000000223c1', true, 'elsewhere/x.m4a', true);
select pg_temp.check((select not uploaded and media_url is null and not upload_requested
                        from public.voice_protection_recordings where id = '00000000-0000-0000-0000-0000000223af'),
  'a new recording starts with no request and no upload');
select pg_temp.refused($q$update public.voice_protection_recordings
  set uploaded = true, media_url = '00000000-0000-0000-0000-0000000223c1/00000000-0000-0000-0000-0000000223af.m4a'
  where id = '00000000-0000-0000-0000-0000000223af'$q$, 'an upload nobody asked for', '%VOICE_RECORDING_UPLOAD_INVALID%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000223e1');
update public.voice_protection_recordings set upload_requested = true, upload_requested_at = now()
 where id = '00000000-0000-0000-0000-0000000223af';
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.refused($q$update public.voice_protection_recordings
  set uploaded = true, media_url = '00000000-0000-0000-0000-0000000223d1/x.m4a'
  where id = '00000000-0000-0000-0000-0000000223af'$q$, 'an upload in someone else''s folder', '%VOICE_RECORDING_UPLOAD_INVALID%');
select pg_temp.refused($q$update public.voice_protection_recordings set ride_label = 'Other trip'
  where id = '00000000-0000-0000-0000-0000000223af'$q$, 'the phone relabelling a recording', '%VOICE_RECORDING_SERVER_ONLY%');
update public.voice_protection_recordings
   set uploaded = true, uploaded_at = '2000-01-01', unavailable = false,
       media_url = '00000000-0000-0000-0000-0000000223c1/00000000-0000-0000-0000-0000000223af.m4a'
 where id = '00000000-0000-0000-0000-0000000223af';
select pg_temp.check((select uploaded and uploaded_at > now() - interval '1 minute'
                        from public.voice_protection_recordings where id = '00000000-0000-0000-0000-0000000223af'),
  'the phone answers the request with its own file');
reset role;

-- B7-1. A ride counts once towards a rule ------------------------------------------------------
insert into public.driver_incentive (values, active) values
  ('{"name": "One-trip week 0223", "minRides": 1, "reward": 7, "active": true}', true);
insert into public.ride_requests (status, partner_id, rider_id, fare, completed_at)
values ('completed', '00000000-0000-0000-0000-0000000223d1', '00000000-0000-0000-0000-0000000223c1', 10,
        (public.statement_week_start((now() at time zone 'Asia/Kuala_Lumpur')::date - 7) + 2)::timestamp
          at time zone 'Asia/Kuala_Lumpur');
select pg_temp.check(public.partner_incentives_weekly() >= 1, 'the rule pays for last week''s trip');
delete from public.partner_incentives where profile_id = '00000000-0000-0000-0000-0000000223d1';
select pg_temp.check(not exists (select 1 from public.partner_incentives where profile_id = '00000000-0000-0000-0000-0000000223d1')
                     and public.partner_incentives_weekly() = 0
                     and not exists (select 1 from public.partner_incentives where profile_id = '00000000-0000-0000-0000-0000000223d1'),
  'the same trip doesn''t pay the rule again');

-- B7-6 / B7-8 -----------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated',
  'public.wallet_transfer_coins(uuid, numeric, uuid, text, text)', 'execute'), 'coins move by request only');
select pg_temp.check(not has_function_privilege('authenticated',
  'public.wallet_transfer_coins_once(uuid, uuid, numeric, uuid, text, text)', 'execute'), 'nor through the retry wrapper');
select pg_temp.check((select bool_and(prosrc like '%driver_credit_assert%') and count(*) = 3 from pg_proc
                       where pronamespace = 'public'::regnamespace
                         and proname in ('trip_handover_accept', 'scheduled_ride_accept', 'scheduled_ride_offer_respond')),
  'taking a handover or a booking asks for GET.credit');
select pg_temp.check((select bool_and(prosrc like '%r.rider_id is null and not public.caller_admin_can_write%') and count(*) = 2
                        from pg_proc
                       where pronamespace = 'public'::regnamespace
                         and proname in ('wallet_award_ride_coins', 'wallet_redeem_fare_coins')),
  'a ride with no rider pays no coins to whoever asks');

-- 15. A ride that was taken keeps its driver ----------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223c1');
select pg_temp.refused($q$update public.ride_requests set partner_id = null
  where id = '00000000-0000-0000-0000-0000000223a2'$q$, 'the rider dropping the driver of an accepted ride', '%RIDE_DRIVER_KEPT%');
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000223d1' from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000223a2'), 'the driver is still on it');

select 'security_hardening_0223: all passed';
rollback;
