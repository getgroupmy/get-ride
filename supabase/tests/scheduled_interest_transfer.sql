-- ============================================================================
-- Regression test for migration 0198: drivers' interest in bookings, handing a
-- booking to another driver, and the passenger choosing a driver.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scheduled_interest_transfer.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000198a1'),  -- rider
  ('00000000-0000-0000-0000-0000000198b1'),  -- driver
  ('00000000-0000-0000-0000-0000000198b2'),  -- driver
  ('00000000-0000-0000-0000-0000000198b3'),  -- driver, also with a GET.me QR
  ('00000000-0000-0000-0000-0000000198b4')   -- an applicant
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000198%'
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status, my_ride_code) values
  ('00000000-0000-0000-0000-0000000198b1', 'Badrul', '+60110000198', 'approved', 'BZ98AAAA'),
  ('00000000-0000-0000-0000-0000000198b2', 'Bella', '+60110000199', 'approved', 'CZ98BBBB'),
  ('00000000-0000-0000-0000-0000000198b3', 'Bakri', '+60110000200', 'approved', 'DZ98CCCC'),
  ('00000000-0000-0000-0000-0000000198b4', 'Ben', '+60110000201', 'unapproved', 'EZ98DDDD');
insert into public.personal_qr_codes (owner_id, kind, token) values
  ('00000000-0000-0000-0000-0000000198b3', 'me', 'T198qrTokenForBakri_xyz');

update public.app_settings
   set value = value || '{"enabled": true, "mode": "release", "releaseMinutes": 20, "interestNoticeMinutes": 60}'::jsonb
 where key = 'scheduled_rides';

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
create or replace function pg_temp.told(p uuid, p_event text) returns int language sql as $$
  select count(*)::int from public.notification_outbox where profile_id = p and event_id like p_event
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

-- Bookings: 3 h away, 45 min away (inside the 60-minute notice), 5 h, 6 h.
insert into public.scheduled_rides (id, rider_id, pickup_at, status, request, fare, pickup_address) values
  ('00000000-0000-0000-0000-0000000198d1', '00000000-0000-0000-0000-0000000198a1', now() + interval '3 hours', 'scheduled', '{}', 20, 'KLCC'),
  ('00000000-0000-0000-0000-0000000198d2', '00000000-0000-0000-0000-0000000198a1', now() + interval '45 minutes', 'scheduled', '{}', 20, 'Mid Valley'),
  ('00000000-0000-0000-0000-0000000198d3', '00000000-0000-0000-0000-0000000198a1', now() + interval '5 hours', 'scheduled', '{}', 20, null),
  ('00000000-0000-0000-0000-0000000198d4', '00000000-0000-0000-0000-0000000198a1', now() + interval '6 hours', 'scheduled', '{}', 20, null);

-- 1. Every open booking, to approved drivers only -------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select pg_temp.check((select count(*) from public.scheduled_rides_upcoming()
                       where id::text like '00000000-0000-0000-0000-0000000198d%') = 4, 'a driver sees every booking');
select pg_temp.check((select bool_and(not can_accept and not interested) from public.scheduled_rides_upcoming()
                       where id::text like '00000000-0000-0000-0000-0000000198d%'), 'nothing to accept yet');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b4');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_upcoming()), 'an applicant sees none');
select pg_temp.refused($q$select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000198d1', true)$q$,
  'an applicant showing interest');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198a1');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_upcoming()), 'a rider sees none');

-- 2. Interest, and accepting once told it is ready ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select pg_temp.refused($q$select public.scheduled_ride_accept('00000000-0000-0000-0000-0000000198d2')$q$,
  'accepting without advance booking or interest');
select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000198d1', true);
select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000198d2', true);
select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000198d2', true);  -- twice is once
select pg_temp.check((select interested and can_accept from public.scheduled_rides_upcoming()
                       where id = '00000000-0000-0000-0000-0000000198d2'), 'interested and within the notice');
select pg_temp.check((select interested and not can_accept from public.scheduled_rides_upcoming()
                       where id = '00000000-0000-0000-0000-0000000198d1'), 'interested, notice still to come');
select pg_temp.refused($q$select public.scheduled_ride_accept('00000000-0000-0000-0000-0000000198d1')$q$,
  'accepting before the notice');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000198d2', true);

reset role;
select public.scheduled_rides_interest_tick();
select public.scheduled_rides_interest_tick();
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b1', 'sched-ready-%') = 1,
  'told once, for the booking within the notice only');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b2', 'sched-ready-%') = 1, 'every interested driver is told');
select pg_temp.check((select priority = 'critical' and data ->> 'role' = 'partner' from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000198b1' and event_id like 'sched-ready-%'),
  'urgent, and opens the driver''s side');

-- The first to accept gets it; the other is told it was taken.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select public.scheduled_ride_accept('00000000-0000-0000-0000-0000000198d2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select pg_temp.refused($q$select public.scheduled_ride_accept('00000000-0000-0000-0000-0000000198d2')$q$,
  'accepting a booking already taken');
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000198b2' from public.scheduled_rides
                       where id = '00000000-0000-0000-0000-0000000198d2'), 'the first driver has it');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b1', 'sched-taken-%') = 1, 'the other is told');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b2', 'sched-taken-%') = 0, 'not the one who took it');

-- 3. Handing over: by My Ride code, the other driver decides ---------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select pg_temp.refused($q$select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'CZ98BBBB')$q$,
  'handing over to yourself');
select pg_temp.refused($q$select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'ZZZZZZZZ')$q$,
  'a code that matches nobody');
select pg_temp.refused($q$select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'EZ98DDDD')$q$,
  'handing over to an applicant');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select pg_temp.refused($q$select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'DZ98CCCC')$q$,
  'handing over a booking that is not yours');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'dz98-cccc');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b3');
select pg_temp.check((select incoming and kind = 'transfer' and other_name = 'Bella'
                        from public.scheduled_ride_offers_open()), 'the other driver sees who offers it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select pg_temp.refused($q$select public.scheduled_ride_offer_respond(
  (select id from public.scheduled_ride_offers where scheduled_ride_id = '00000000-0000-0000-0000-0000000198d2'
     and status = 'pending'), true)$q$, 'a third driver answering');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b3');
select public.scheduled_ride_offer_respond((select id from public.scheduled_ride_offers_open()), false);
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000198b2' from public.scheduled_rides
                       where id = '00000000-0000-0000-0000-0000000198d2'), 'declined: still the first driver''s');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b2', 'sched-offer-declined-%') = 1, 'told it was declined');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'DZ98CCCC');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b3');
select public.scheduled_ride_offer_respond((select id from public.scheduled_ride_offers_open()), true);
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000198b3' and status = 'assigned'
                        from public.scheduled_rides where id = '00000000-0000-0000-0000-0000000198d2'), 'accepted: handed over');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198a1', 'sched-driver-changed-%') = 1,
  'the passenger is told the driver changed');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b2', 'sched-offer-accepted-%') = 1,
  'the first driver is told');

-- Letting go while a handover waits: back to the pool, the handover withdrawn.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b3');
select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d2', 'BZ98AAAA');
select public.scheduled_ride_driver_cancel('00000000-0000-0000-0000-0000000198d2');
reset role;
select pg_temp.check((select status = 'scheduled' and partner_id is null from public.scheduled_rides
                       where id = '00000000-0000-0000-0000-0000000198d2'), 'let go: back to the pool');
select pg_temp.check(not exists (select 1 from public.scheduled_ride_offers
                                  where scheduled_ride_id = '00000000-0000-0000-0000-0000000198d2' and status = 'pending'),
  'the handover is withdrawn');

-- 4. The passenger chooses a driver: My Ride code or GET.me QR --------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select pg_temp.refused($q$select public.scheduled_ride_request_driver('00000000-0000-0000-0000-0000000198d3', 'CZ98BBBB')$q$,
  'a driver choosing for someone else''s booking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198a1');
select public.scheduled_ride_request_driver('00000000-0000-0000-0000-0000000198d3', 'BZ98AAAA');
select public.scheduled_ride_request_driver('00000000-0000-0000-0000-0000000198d3',
  'https://getride.my/q/me/T198qrTokenForBakri_xyz');
select pg_temp.check((select count(*) = 1 and bool_and(not incoming and other_name = 'Bakri')
                        from public.scheduled_ride_offers_open()), 'one request at a time, the latest');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b3');
select public.scheduled_ride_offer_respond((select id from public.scheduled_ride_offers_open()), true);
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000198b3' and status = 'assigned'
                        from public.scheduled_rides where id = '00000000-0000-0000-0000-0000000198d3'), 'the chosen driver has it');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198a1', 'sched-assigned-%') >= 1, 'the passenger is told');

-- Taken by another driver first: the request lapses and the driver asked hears it.
update public.app_settings set value = value || '{"mode": "advance"}'::jsonb where key = 'scheduled_rides';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198a1');
select public.scheduled_ride_request_driver('00000000-0000-0000-0000-0000000198d1', 'BZ98AAAA');
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select public.scheduled_ride_accept('00000000-0000-0000-0000-0000000198d1');
reset role;
select pg_temp.check((select status = 'cancelled' from public.scheduled_ride_offers
                       where scheduled_ride_id = '00000000-0000-0000-0000-0000000198d1' and kind = 'assign'),
  'the passenger''s request lapses');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b1', 'sched-offer-gone-%') = 1, 'the driver asked hears it');

-- 5. Cancelled by the passenger: interested drivers and a driver asked are told ---------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b1');
select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000198d4', true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000198a1');
select public.scheduled_ride_request_driver('00000000-0000-0000-0000-0000000198d4', 'CZ98BBBB');
select public.scheduled_ride_cancel('00000000-0000-0000-0000-0000000198d4');
reset role;
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b1', 'sched-cancel-00000000-0000-0000-0000-0000000198d4-%') = 1,
  'the interested driver is told');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b2', 'sched-cancel-00000000-0000-0000-0000-0000000198d4-%') = 1,
  'the driver asked is told');
select pg_temp.check(not exists (select 1 from public.scheduled_ride_offers
                                  where scheduled_ride_id = '00000000-0000-0000-0000-0000000198d4' and status = 'pending'),
  'nothing left to accept');

-- 6. No answer by release: the offer lapses, its sender is told -------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b2');
select public.scheduled_ride_transfer('00000000-0000-0000-0000-0000000198d1', 'DZ98CCCC');
reset role;
update public.scheduled_ride_offers set expires_at = now() - interval '1 minute'
 where scheduled_ride_id = '00000000-0000-0000-0000-0000000198d1' and status = 'pending';
select public.scheduled_rides_interest_tick();
select pg_temp.check((select status = 'expired' from public.scheduled_ride_offers
                       where scheduled_ride_id = '00000000-0000-0000-0000-0000000198d1' and kind = 'transfer'), 'lapsed');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000198b2', 'sched-offer-expired-%') = 1, 'the sender is told');
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000198b2' from public.scheduled_rides
                       where id = '00000000-0000-0000-0000-0000000198d1'), 'and keeps the ride');

-- 7. Nothing readable or writable directly ----------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000198b4');
select pg_temp.check(not exists (select 1 from public.scheduled_ride_offers), 'offers of others are hidden');
select pg_temp.check(not exists (select 1 from public.scheduled_ride_interests), 'interests of others are hidden');
select pg_temp.refused($q$insert into public.scheduled_ride_interests (scheduled_ride_id, partner_id)
  values ('00000000-0000-0000-0000-0000000198d1', '00000000-0000-0000-0000-0000000198b4')$q$, 'writing interest directly');
reset role;

select 'scheduled_interest_transfer: all passed';
rollback;
