-- ============================================================================
-- Regression test for migration 0189: scheduled rides.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scheduled_rides.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000189a1'),  -- rider with money
  ('00000000-0000-0000-0000-0000000189a2'),  -- rider without
  ('00000000-0000-0000-0000-0000000189b1'),  -- driver
  ('00000000-0000-0000-0000-0000000189b2'),  -- another driver
  ('00000000-0000-0000-0000-0000000189b3'),  -- an applicant
  ('00000000-0000-0000-0000-0000000189c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000189%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000189c1', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000189b1', 'Badrul', '+60110000189', 'approved'),
  ('00000000-0000-0000-0000-0000000189b2', 'Bella', '+60110000190', 'approved'),
  ('00000000-0000-0000-0000-0000000189b3', 'Ben', '+60110000191', 'unapproved');
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000189a1', 'get_wallet', 'topup', 30, 'test', 'test');

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
create or replace function pg_temp.balance(p uuid, t text) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = t), 0);
$$;
create or replace function pg_temp.req(p_fare numeric) returns jsonb language sql as $$
  select jsonb_build_object('service', 'car', 'fare', p_fare, 'ride_fare', p_fare,
    'pickup_lat', 3.15, 'pickup_lng', 101.71, 'drop_lat', 3.14, 'drop_lng', 101.69,
    'pickup_address', 'KLCC', 'drop_address', 'Bukit Bintang', 'currency', 'RM');
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.balance(uuid, text), pg_temp.req(numeric) to authenticated;

create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;

-- 1. Settings: off by default, the admin's, stored cleaned -------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
select pg_temp.refused($q$select public.schedule_ride(pg_temp.req(20), now() + interval '3 hours')$q$,
  'booking while scheduled rides are off');
select pg_temp.refused($q$select public.set_scheduled_rides_config('{"enabled":true}')$q$,
  'a rider changing the settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189c1');
select pg_temp.check((select public.set_scheduled_rides_config('{"enabled":true,"feePercent":500,"mode":"x"}')
                        ->> 'feePercent')::numeric = 100, 'settings are kept within range');
select pg_temp.check(public.scheduled_rides_config()->>'mode' = 'release', 'an unknown mode is release');
select public.set_scheduled_rides_config(jsonb_build_object(
  'enabled', true, 'minLeadMinutes', 30, 'maxDaysAhead', 7, 'feeFixed', 2, 'feePercent', 10,
  'feeTo', 'platform', 'freeCancelMinutes', 60, 'lateCancelFee', 5, 'mode', 'advance',
  'releaseMinutes', 20, 'reminderMinutes', 60));

-- 2. Booking --------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
select pg_temp.refused($q$select public.schedule_ride(pg_temp.req(20), now() + interval '10 minutes')$q$,
  'booking inside the lead time');
select pg_temp.refused($q$select public.schedule_ride(pg_temp.req(20), now() + interval '9 days')$q$,
  'booking beyond the days ahead');
select pg_temp.refused($q$select public.schedule_ride(pg_temp.req(20) || '{"booked_for_name":"Mum"}', now() + interval '3 hours')$q$,
  'booking for someone without their phone');
insert into ids select 'one', id from public.schedule_ride(
  pg_temp.req(20) || '{"status":"completed","partner_id":"00000000-0000-0000-0000-0000000189b1","payment_status":"paid"}',
  now() + interval '3 hours');
insert into ids select 'two', id from public.schedule_ride(
  pg_temp.req(30) || '{"booked_for_name":"Mum","booked_for_phone":"+60123456789"}', now() + interval '3 hours 30 minutes');
select pg_temp.check((select scheduling_fee = 4 and booked_for_name is null from public.scheduled_rides
                       where id = (select id from ids where k = 'one')), 'fixed RM2 + 10% of RM20 = RM4');
select pg_temp.check((select request ? 'status' or request ? 'partner_id' or request ? 'payment_status'
                        from public.scheduled_rides where id = (select id from ids where k = 'one')) is false,
  'what the server decides is dropped from the request');
select pg_temp.check((select request->'charges' @> '[{"name":"Scheduling fee","value":4,"platform":true}]'
                        from public.scheduled_rides where id = (select id from ids where k = 'one')),
  'the fee rides on the request as a platform charge');
select pg_temp.check((select booked_for_phone = '+60123456789' from public.scheduled_rides
                       where id = (select id from ids where k = 'two')), 'a ride booked for someone else');
select pg_temp.refused($q$update public.scheduled_rides set fare = 1$q$, 'a rider editing a booking');

-- 3. Drivers in advance mode -----------------------------------------------------------------
select pg_temp.check((select count(*) = 0 from public.scheduled_rides_open()), 'a rider sees no driver list');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b3');
select pg_temp.check((select count(*) = 0 from public.scheduled_rides_open()), 'an applicant sees none');
select pg_temp.refused($q$select public.scheduled_ride_accept((select id from ids where k = 'one'))$q$,
  'an applicant accepting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b1');
select pg_temp.check((select count(*) = 2 from public.scheduled_rides_open()
                       where id in (select id from ids)), 'an approved driver sees the bookings');
select pg_temp.check((select count(*) = 0 from public.scheduled_rides), 'nor reads the bookings themselves');
select public.scheduled_ride_accept((select id from ids where k = 'one'));
select pg_temp.refused($q$select public.scheduled_ride_accept((select id from ids where k = 'two'))$q$,
  'a driver taking two rides half an hour apart');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b2');
select pg_temp.refused($q$select public.scheduled_ride_accept((select id from ids where k = 'one'))$q$,
  'taking a ride another driver has');
select public.scheduled_ride_accept((select id from ids where k = 'two'));

-- The driver lets go before release: back in the pool, the rider is told.
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b1');
select pg_temp.refused($q$select public.scheduled_ride_driver_cancel((select id from ids where k = 'two'))$q$,
  'letting go of another driver''s ride');
select public.scheduled_ride_driver_cancel((select id from ids where k = 'one'));
reset role;
select pg_temp.check((select status = 'scheduled' and partner_id is null from public.scheduled_rides
                       where id = (select id from ids where k = 'one')), 'the booking is back in the pool');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000189a1'
                                and data->>'type' = 'scheduled_reassigning'), 'the rider hears about it');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b1');
select public.scheduled_ride_accept((select id from ids where k = 'one'));
reset role;

-- 4. Release with the driver, then the driver cancels: back to the pool ---------------------
update public.scheduled_rides set pickup_at = now() + interval '15 minutes' where id = (select id from ids where k = 'one');
select public.scheduled_rides_tick();
insert into ids select 'ride1', ride_id from public.scheduled_rides where id = (select id from ids where k = 'one');
select pg_temp.check((select b.status = 'released' and r.status = 'accepted'
                             and r.partner_id = '00000000-0000-0000-0000-0000000189b1' and r.partner_name = 'Badrul'
                             and r.rider_id = '00000000-0000-0000-0000-0000000189a1' and r.scheduled_ride_id = b.id
                             and r.ride_fare = 20 and r.charges @> '[{"name":"Scheduling fee","platform":true}]'
                        from public.scheduled_rides b join public.ride_requests r on r.id = b.ride_id
                       where b.id = (select id from ids where k = 'one')),
  'the booking becomes an accepted ride with its driver');
select pg_temp.check((select public.ride_amount_due(r) = 24 from public.ride_requests r
                       where id = (select id from ids where k = 'ride1')), 'the rider pays the fare and the fee');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b1');
select pg_temp.refused($q$update public.ride_requests set platform_fees_charged_at = now() where id = (select id from ids where k = 'ride1')$q$,
  'a driver marking the fees charged');
update public.ride_requests set status = 'cancelled', cancel_reason = 'Car broke down'
 where id = (select id from ids where k = 'ride1');
reset role;
select pg_temp.check((select status = 'open' and partner_id is null and partner_name is null and cancelled_at is null
                        from public.ride_requests where id = (select id from ids where k = 'ride1')),
  'the driver''s cancel sends the ride back to the pool');
select pg_temp.check((select status = 'released' and partner_id is null from public.scheduled_rides
                       where id = (select id from ids where k = 'one')), 'the booking waits for a new driver');
select pg_temp.check((select count(*) = 1 from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000189a1'
                         and data->>'type' = 'scheduled_reassigning' and data ? 'request_id'), 'and the rider is told');

-- A new driver takes it and completes: the platform's fee comes back from the driver.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b2');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000189b2'
 where id = (select id from ids where k = 'ride1');
reset role;
update public.ride_requests set status = 'on_trip' where id = (select id from ids where k = 'ride1');
update public.ride_requests set status = 'completed' where id = (select id from ids where k = 'ride1');
select pg_temp.check((select count(*) = 1 and sum(amount) = -4 from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000189b2' and kind = 'platform_fee'),
  'the new driver gives back the RM4 scheduling fee');
select pg_temp.check((select platform_fees_charged_at is not null from public.ride_requests
                       where id = (select id from ids where k = 'ride1')), 'once');
update public.ride_requests set status = 'completed' where id = (select id from ids where k = 'ride1');
select pg_temp.check((select count(*) = 1 from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000189b2' and kind = 'platform_fee'), 'only once');
select public.scheduled_rides_tick();
select pg_temp.check((select status = 'completed' from public.scheduled_rides where id = (select id from ids where k = 'one')),
  'the booking follows its ride to completed');

-- 5. Cancelling: free early, late from the wallet ---------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
insert into ids select 'three', id from public.schedule_ride(pg_temp.req(20), now() + interval '5 hours');
select public.scheduled_ride_cancel((select id from ids where k = 'three'));
select pg_temp.check((select status = 'cancelled' and cancel_fee = 0 and cancel_fee_status = 'none'
                        from public.scheduled_rides where id = (select id from ids where k = 'three')), 'early: free');
reset role;
update public.scheduled_rides set pickup_at = now() + interval '40 minutes' where id = (select id from ids where k = 'two');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b2');
select pg_temp.refused($q$select public.scheduled_ride_cancel((select id from ids where k = 'two'))$q$,
  'a driver cancelling as the rider');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
select public.scheduled_ride_cancel((select id from ids where k = 'two'), 'Plans changed');
select pg_temp.check((select status = 'cancelled' and cancel_fee = 5 and cancel_fee_status = 'charged'
                        from public.scheduled_rides where id = (select id from ids where k = 'two')), 'late: RM5 charged');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000189a1', 'get_wallet') = 25,
  'from the rider''s GET wallet');
select pg_temp.refused($q$select public.scheduled_ride_cancel((select id from ids where k = 'two'))$q$,
  'cancelling twice');
reset role;
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000189b2'
                                and data->>'type' = 'scheduled_cancelled'), 'the driver hears about it');

-- 6. Late without money: owed, billed on the next ride, paid when it completes ----------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a2');
insert into ids select 'four', id from public.schedule_ride(pg_temp.req(20), now() + interval '3 hours');
reset role;
update public.scheduled_rides set pickup_at = now() + interval '45 minutes' where id = (select id from ids where k = 'four');
set local role authenticated;
select public.scheduled_ride_cancel((select id from ids where k = 'four'));
select pg_temp.check((select cancel_fee_status = 'due' from public.scheduled_rides where id = (select id from ids where k = 'four')),
  'an empty wallet leaves the fee owed');
select pg_temp.check(public.my_owed_fees() = 5, 'the rider sees what they owe');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
select pg_temp.check(public.my_owed_fees() = 0, 'nobody else''s');
reset role;

insert into public.ride_requests (id, rider_id, status, fare, ride_fare, charges) values
  ('00000000-0000-0000-0000-0000000189e1', '00000000-0000-0000-0000-0000000189a2', 'open', 15, 15,
   '[{"kind":"surcharge","name":"Night","charge":"fixed","value":1}]');
select pg_temp.check((select charges @> '[{"name":"Late cancellation fee (earlier booking)","value":5,"platform":true}]'
                             and charges @> '[{"name":"Night"}]' and public.ride_amount_due(r) = 21
                        from public.ride_requests r where id = '00000000-0000-0000-0000-0000000189e1'),
  'the owed fee rides on the next order');
select pg_temp.check((select cancel_fee_status = 'billed' and billed_ride_id = '00000000-0000-0000-0000-0000000189e1'
                        from public.scheduled_rides where id = (select id from ids where k = 'four')), 'and is marked billed');
update public.ride_requests set status = 'expired' where id = '00000000-0000-0000-0000-0000000189e1';
select pg_temp.check((select cancel_fee_status = 'due' and billed_ride_id is null
                        from public.scheduled_rides where id = (select id from ids where k = 'four')),
  'a ride that never ran leaves it owed');
insert into public.ride_requests (id, rider_id, status, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000189e2', '00000000-0000-0000-0000-0000000189a2', 'open', 15, 15);
update public.ride_requests set status = 'on_trip', partner_id = '00000000-0000-0000-0000-0000000189b1'
 where id = '00000000-0000-0000-0000-0000000189e2';
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000189e2';
select pg_temp.check((select cancel_fee_status = 'paid' from public.scheduled_rides where id = (select id from ids where k = 'four')),
  'completed: the fee is paid');
select pg_temp.check((select count(*) = 1 and sum(amount) = -5 from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000189b1' and kind = 'platform_fee'),
  'and the driver who collected it gives it back');

-- A client can't mark its own charges as the platform's.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_lat, pickup_lng, charges) values
  ('00000000-0000-0000-0000-0000000189e3', '00000000-0000-0000-0000-0000000189a1', 'open', 15, 15, 3.15, 101.71,
   '[{"kind":"surcharge","name":"Fake","charge":"fixed","value":9,"platform":true}]');
reset role;
select pg_temp.check((select charges = '[{"kind":"surcharge","name":"Fake","charge":"fixed","value":9}]'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000189e3'),
  'a client-sent platform flag is dropped');

-- 7. Release mode: no driver until release; re-offered, then expired ----------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189c1');
select public.set_scheduled_rides_config(public.scheduled_rides_config() || '{"mode":"release"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b1');
select pg_temp.check((select count(*) = 0 from public.scheduled_rides_open()), 'release mode lists nothing ahead');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
insert into ids select 'five', id from public.schedule_ride(pg_temp.req(20), now() + interval '3 hours');
select pg_temp.as_user('00000000-0000-0000-0000-0000000189b1');
select pg_temp.refused($q$select public.scheduled_ride_accept((select id from ids where k = 'five'))$q$,
  'pre-accepting in release mode');
select pg_temp.refused($q$select public.scheduled_rides_tick()$q$, 'a client running the tick');
select pg_temp.refused($q$select public.scheduled_ride_release((select id from ids where k = 'five'))$q$,
  'a client releasing a booking');
reset role;

update public.scheduled_rides set pickup_at = now() + interval '50 minutes' where id = (select id from ids where k = 'five');
select public.scheduled_rides_tick();
select pg_temp.check((select reminded_at is not null and status = 'scheduled' from public.scheduled_rides
                       where id = (select id from ids where k = 'five')), 'a reminder, not yet released');
update public.scheduled_rides set pickup_at = now() + interval '10 minutes' where id = (select id from ids where k = 'five');
select public.scheduled_rides_tick();
insert into ids select 'ride5', ride_id from public.scheduled_rides where id = (select id from ids where k = 'five');
select pg_temp.check((select r.status = 'open' and r.partner_id is null from public.ride_requests r
                       where id = (select id from ids where k = 'ride5')), 'released open to the pool');
update public.ride_requests set status = 'expired' where id = (select id from ids where k = 'ride5');
select public.scheduled_rides_tick();
select pg_temp.check((select status = 'released' and releases = 2 and ride_id <> (select id from ids where k = 'ride5')
                        from public.scheduled_rides where id = (select id from ids where k = 'five')),
  'nobody took it: offered again');
update public.ride_requests set status = 'expired'
 where id = (select ride_id from public.scheduled_rides where id = (select id from ids where k = 'five'));
update public.scheduled_rides set pickup_at = now() - interval '15 minutes' where id = (select id from ids where k = 'five');
select public.scheduled_rides_tick();
select pg_temp.check((select status = 'expired' and cancel_fee_status = 'none' from public.scheduled_rides
                       where id = (select id from ids where k = 'five')), 'past pickup: expired, no charge');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000189a1'
                                and data->>'type' = 'scheduled_expired'), 'and the rider is told');

-- 8. A trip under way can't be cancelled from the booking -------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000189a1');
insert into ids select 'six', id from public.schedule_ride(pg_temp.req(20), now() + interval '3 hours');
reset role;
update public.scheduled_rides set pickup_at = now() + interval '5 minutes' where id = (select id from ids where k = 'six');
select public.scheduled_rides_tick();
update public.ride_requests set status = 'on_trip', partner_id = '00000000-0000-0000-0000-0000000189b1'
 where id = (select ride_id from public.scheduled_rides where id = (select id from ids where k = 'six'));
set local role authenticated;
select pg_temp.refused($q$select public.scheduled_ride_cancel((select id from ids where k = 'six'))$q$,
  'cancelling a booking whose trip has started');
reset role;

select 'scheduled_rides: all passed';
rollback;
