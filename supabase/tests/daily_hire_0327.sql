-- ============================================================================
-- Regression test for migration 0327: daily hire (and the hourly gaps).
--   1. The quote: off until the admin turns it on, the days and hours,
--      the lead time and how far ahead, cash refused, the day rate pro rata,
--      the allowances, the fallback to the hourly rate, a tariff card.
--   2. A booking: the booking and one day row a day at the same local time,
--      each priced from the booking with its allowances; the total with the
--      place fees; the deposit from GET.wallet naming the booking; a short
--      wallet refused; the lead time.
--   3. Drivers: the whole booking listed (to drivers who take hire), its days
--      not taken one by one, the clash check across every day, the accept.
--   4. A day released: the balance charged, the day's share held from the
--      booking's money, the day's terms; overtime and extra km per day; paid.
--   5. Same driver or not: the cut-off splits the days (or closes the
--      booking, refunded); a booking without the same driver is listed by day.
--   6. Cancel: free before the free-cancel time, the late fee after (deposit,
--      percent), a single day not cancelled on its own.
--   7. Family: the deposit and the balance from the host, the refund to the host.
--   8. A business account books daily and hourly hire.
--   9. Whole-fare regions round the hire price up.
--  10. A later hourly hire booked in cash after cash was turned off.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/daily_hire_0327.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000327a1'),  -- rider, GET.wallet
  ('00000000-0000-0000-0000-0000000327a2'),  -- rider, business
  ('00000000-0000-0000-0000-0000000327a3'),  -- rider
  ('00000000-0000-0000-0000-0000000327a4'),  -- rider, cash
  ('00000000-0000-0000-0000-0000000327b1'),  -- driver who takes hire
  ('00000000-0000-0000-0000-0000000327b2'),  -- driver who takes hire
  ('00000000-0000-0000-0000-0000000327b3'),  -- driver who doesn't
  ('00000000-0000-0000-0000-0000000327f1'),  -- family host
  ('00000000-0000-0000-0000-0000000327f2')   -- family member
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000327a1', 'Aina Harian', '+60100032701'),
  ('00000000-0000-0000-0000-0000000327a2', 'Badrul Harian', '+60100032702'),
  ('00000000-0000-0000-0000-0000000327a3', 'Chen Daily', '+60100032703'),
  ('00000000-0000-0000-0000-0000000327a4', 'Devi Daily', '+60100032704'),
  ('00000000-0000-0000-0000-0000000327b1', 'Eddy Sehari', '+60100032711'),
  ('00000000-0000-0000-0000-0000000327b2', 'Farid Sehari', '+60100032712'),
  ('00000000-0000-0000-0000-0000000327b3', 'Gani Sehari', '+60100032713'),
  ('00000000-0000-0000-0000-0000000327f1', 'Hadi Keluarga', '+60100032721'),
  ('00000000-0000-0000-0000-0000000327f2', 'Ina Keluarga', '+60100032722')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000327b1', 'Eddy Sehari', '+60100032711', 'approved'),
  ('00000000-0000-0000-0000-0000000327b2', 'Farid Sehari', '+60100032712', 'approved'),
  ('00000000-0000-0000-0000-0000000327b3', 'Gani Sehari', '+60100032713', 'approved');
insert into public.driver_ride_extras (driver_id, takes_hire) values
  ('00000000-0000-0000-0000-0000000327b1', true), ('00000000-0000-0000-0000-0000000327b2', true)
on conflict (driver_id) do update set takes_hire = excluded.takes_hire;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return coalesce(nullif(v, ''), 'ok');
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.bal(p_user uuid) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = 'get_wallet'), 0);
$$;
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric) returns void language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, 'get_wallet', 'test_adjust', p_to - pg_temp.bal(p_user), 'test 0327');
  end if;
end $$;
create or replace function pg_temp.daily(p jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.as_server();
  perform public.set_hire_package_config('daily', p);
end $$;
-- Two days ahead, on the hour (local time is Malaysia's).
create or replace function pg_temp.first(p_days int default 2) returns timestamptz language sql as $$
  select date_trunc('hour', now()) + make_interval(days => p_days);
$$;
create or replace function pg_temp.q(p_days int, p_hours numeric, p_at timestamptz default null,
                                     p_service text default 'Day Saloon 327', p_payment text default null,
                                     p_overnight boolean default false) returns jsonb
language sql as $$
  select public.hire_multi_quote('daily', 3.10, 101.60, null, null, p_service, p_days, p_hours,
                                 coalesce(p_at, pg_temp.first()), 'Dayland 327', 'Negeri 327', null, null, p_payment,
                                 p_overnight, 'Asia/Kuala_Lumpur');
$$;
-- hire_book as [p_rider]: the booking's id, or the error.
create or replace function pg_temp.book(p_rider uuid, p_booking jsonb, p_request jsonb default '{}'::jsonb) returns text
language sql as $$
  select pg_temp.value_as(p_rider, format($f$select (public.hire_book(%L::jsonb, %L::jsonb))->>'id'$f$,
    jsonb_build_object('service', 'Day Saloon 327', 'payment_mode', 'Get Pay', 'pickup_lat', 3.10, 'pickup_lng', 101.60,
                       'pickup_name', 'Day Plaza 327', 'fare', 1, 'ride_fare', 1, 'country', 'Dayland 327',
                       'state', 'Negeri 327', 'timezone', 'Asia/Kuala_Lumpur', 'currency', 'MYR') || p_request,
    jsonb_build_object('package', 'daily', 'first_at', pg_temp.first(), 'days', 3, 'hours', 10) || p_booking));
$$;
create temp table t (k text primary key, id uuid);
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create or replace function pg_temp.bk(p_k text) returns public.hire_bookings language sql as $$
  select * from public.hire_bookings where id = pg_temp.id(p_k) $$;
create or replace function pg_temp.day(p_k text, p_n int) returns public.scheduled_rides language sql as $$
  select * from public.scheduled_rides where hire_booking_id = pg_temp.id(p_k) and hire_day_no = p_n $$;
create or replace function pg_temp.ride(p_k text) returns public.ride_requests language sql as $$
  select * from public.ride_requests where id = pg_temp.id(p_k) $$;

-- The place, the services and a fee at the pickup (lat 3.0..3.2, lng 101.5..101.7).
insert into public.countries (name, values) values ('Dayland 327', '{}');
insert into public.settings_entries (category, values, position) values
  ('vehicle-services', '{"name": "Day Saloon 327", "status": true, "costPerKm": 2, "costPerMin": 0.3,
     "minFareAmount": 5, "hireEnabled": true, "hirePerHour": 40, "hireKmPerHour": 15, "hireOvertimePerHour": 50,
     "hireExtraKm": 1.2, "hireDayRate": 300, "hireDayHours": 10, "hireDayKm": 150, "hireDayOvertimePerHour": 45,
     "hireDayExtraKm": 1.5, "hireOvernight": 80}', 9011),
  ('vehicle-services', '{"name": "Hourly Only 327", "status": true, "costPerKm": 1, "costPerMin": 0.2,
     "minFareAmount": 5, "hireEnabled": true, "hirePerHour": 40}', 9012),
  ('vehicle-services', '{"name": "No Hire 327", "status": true, "costPerKm": 1, "costPerMin": 0.2,
     "minFareAmount": 5}', 9013);
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000327e1', jsonb_build_object('name', 'Day Plaza 327',
    'boundary', '{"bbox":{"north":3.2,"south":3.0,"east":101.7,"west":101.5}}'));
update public.airport_settings set fares_on = false, pick_door_required = false, drop_door_required = false,
       restrict_pickups = false
 where airport_id = '00000000-0000-0000-0000-0000000327e1';
delete from public.place_fees where area_id = '00000000-0000-0000-0000-0000000327e1';
insert into public.place_fees (area_id, name, applies_to, amount) values
  ('00000000-0000-0000-0000-0000000327e1', 'Plaza pickup fee', 'pickup', 5);
select from public.set_hourly_hire_config('{"enabled": true}');
update public.app_settings set value = value || '{"enabled": true, "mode": "advance"}' where key = 'scheduled_rides';

-- ---- 1. The quote --------------------------------------------------------------------------------------
select pg_temp.check(public.hire_package_config('daily') @> '{"enabled": false, "maxDays": 6, "minHoursPerDay": 8,
  "maxHoursPerDay": 12, "hoursPerDayDefault": 10, "leadHours": 12, "depositPercent": 30, "allowPrepay": true,
  "freeCancelHours": 24, "lateCancelMode": "deposit", "sameDriverDefault": true, "splitDays": true,
  "splitAfterHours": 6, "overnightAllowance": 50, "mealAllowance": 0, "labels": {"chip": "Daily", "title": "Daily hire"}}',
  'the defaults');
select pg_temp.check(public.hire_package_config('yearly') is null, 'no such package');
select pg_temp.check(pg_temp.q(3, 10)->>'reason' = 'HIRE_OFF', 'off until the admin turns it on');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a1',
  $q$select public.set_hire_package_config('daily', '{"enabled": true}')::text$q$) like 'NOT_ALLOWED%',
  'a rider can''t change the settings');
select pg_temp.daily('{"enabled": true, "maxDays": 99, "depositPercent": 130, "lateCancelMode": "x"}');
select pg_temp.check(public.hire_package_config('daily') @> '{"maxDays": 60, "depositPercent": 100,
  "lateCancelMode": "deposit"}', 'saved within the safe limits');
select pg_temp.daily('{"enabled": true, "mealAllowance": 20}');
select pg_temp.check(pg_temp.q(3, 10, p_overnight => true) @> '{"available": true, "days": 3, "hours": 10,
  "dayRate": 300, "perDay": 300, "kmPerDay": 150, "overtimePerHour": 45, "extraKm": 1.5, "nights": 2,
  "overnightAllowance": 80, "overnightTotal": 160, "mealTotal": 60, "placeFeesPerDay": 5, "placeFeesTotal": 15,
  "base": 900, "total": 1135, "deposit": 340.5}', 'three days of ten hours, two nights away: ' || pg_temp.q(3, 10, p_overnight => true)::text);
select pg_temp.check(jsonb_array_length(pg_temp.q(3, 10)->'dates') = 3
                     and ((pg_temp.q(3, 10)->'dates'->>2)::timestamptz - (pg_temp.q(3, 10)->'dates'->>0)::timestamptz)
                         = interval '2 days', 'each day at the same time');
select pg_temp.check((pg_temp.q(2, 8)->>'perDay')::numeric = 240, 'eight hours: the day rate pro rata');
select pg_temp.check(pg_temp.q(7, 10)->>'reason' = 'HIRE_DAYS' and pg_temp.q(0, 10)->>'reason' = 'HIRE_DAYS'
                     and pg_temp.q(7, 10)->>'hint' = 'Choose between 1 and 6 days.', 'the days');
select pg_temp.check(pg_temp.q(2, 7)->>'reason' = 'HIRE_HOURS' and pg_temp.q(2, 13)->>'reason' = 'HIRE_HOURS'
                     and pg_temp.q(2, 9.25)->>'reason' = 'HIRE_HOURS', 'the hours a day');
select pg_temp.check(pg_temp.q(2, 10, now() + interval '3 hours')->>'reason' = 'HIRE_LEAD'
                     and pg_temp.q(2, 10, now() + interval '3 hours')->>'hint' = 'Book at least 12 hours ahead.',
  'the lead time');
select pg_temp.check(pg_temp.q(2, 10, now() + interval '40 days')->>'reason' = 'HIRE_AHEAD', 'how far ahead');
select pg_temp.check(pg_temp.q(2, 10, p_payment => 'Cash')->>'reason' = 'HIRE_CASH', 'cash refused');
select pg_temp.check(pg_temp.q(2, 10, p_service => 'No Hire 327')->>'reason' = 'HIRE_SERVICE_OFF', 'a service without hire');
select pg_temp.check(pg_temp.q(2, 10, p_service => 'Hourly Only 327') @> '{"available": true, "dayRate": 400,
  "perDay": 400, "kmPerDay": 200, "overnightAllowance": 50}', 'no day rate: the hourly rate × 10 hours, the settings'' km');
insert into public.fare_tariffs (level, country, hire_day_rate, hire_overnight) values ('country', 'Dayland 327', 350, 90);
select pg_temp.check(pg_temp.q(2, 10, p_overnight => true) @> '{"dayRate": 350, "overnightAllowance": 90}',
  'the country card''s day rate and overnight');
delete from public.fare_tariffs where country = 'Dayland 327';

-- ---- 2. A booking ----------------------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327a1', 2000);
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000327a1', jsonb_build_object('first_at', now() + interval '2 hours'))
  like 'HIRE_LEAD%', 'too soon: refused');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000327a1', '{}', '{"payment_mode": "Cash"}')
  like 'HIRE_CASH%', 'cash: refused');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000327a1', '{"package": "hourly"}') like 'HIRE_OFF%',
  'hourly hire is not booked this way');
insert into t values ('d1', pg_temp.book('00000000-0000-0000-0000-0000000327a1', '{"overnight": true}')::uuid);
select pg_temp.check((select status = 'booked' and package = 'daily' and days = 3 and hours_per_day = 10 and overnight
                             and same_driver and price = 1135 and deposit_amount = 340.5 and balance_amount = 794.5
                             and paid_amount = 340.5 and payment_state = 'deposit_paid' and payment_plan = 'deposit'
                        from pg_temp.bk('d1')), 'booked: 1135, 340.50 now, 794.50 on day 1');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000327a1') = 1659.5
                     and exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('d1')
                                    and kind = 'hire_deposit' and amount = -340.5), 'the deposit names the booking');
select pg_temp.check((select count(*) = 3 and bool_and(hire_package = 'daily' and hire_hours = 10 and fare = 300
                                                       and scheduling_fee = 0 and status = 'scheduled')
                        from public.scheduled_rides where hire_booking_id = pg_temp.id('d1')), 'one row a day');
select pg_temp.check((pg_temp.day('d1', 2)).pickup_at = (pg_temp.day('d1', 1)).pickup_at + interval '1 day'
                     and (pg_temp.day('d1', 1)).pickup_at = pg_temp.first(), 'each day at the same time');
select pg_temp.check((pg_temp.day('d1', 1)).request->'charges' @> '[{"name": "Meal allowance", "value": 20},
                                                                    {"name": "Overnight allowance", "value": 80}]'
                     and (pg_temp.day('d1', 3)).request->'charges' @> '[{"name": "Meal allowance", "value": 20}]'
                     and not ((pg_temp.day('d1', 3)).request->'charges' @> '[{"name": "Overnight allowance"}]')
                     and (pg_temp.day('d1', 1)).request->'hire_quote' @> '{"base": 300, "kmIncluded": 150, "rate": 30,
                                                                          "overtimePerHour": 45, "dayNo": 1, "days": 3}'
                     and (pg_temp.day('d1', 1)).request->'option_names' @> '{"hire": "Daily hire"}',
  'each day priced from the booking, the night away on the first two');
select pg_temp.check(exists (select 1 from public.hire_bookings b where b.id = pg_temp.id('d1')
                               and b.quote @> '{"grandTotal": 1135, "payNow": 340.5}'), 'the total and what was paid now');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327a3', 10);
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{}') like 'HIRE_BALANCE%'
                     and not exists (select 1 from public.hire_bookings where rider_id = '00000000-0000-0000-0000-0000000327a3'),
  'a short wallet: refused, nothing booked');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a1',
  $q$select public.schedule_ride('{"service": "Day Saloon 327", "pickup_lat": 3.1, "pickup_lng": 101.6, "fare": 10,
       "hire_package": "daily", "hire_hours": 10, "hire_booking_id": "00000000-0000-0000-0000-000000000000"}',
       now() + interval '3 hours')::text$q$) like 'HIRE_OFF%', 'a day row is only made by hire_book');

-- ---- 3. Drivers ------------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select count(*)::text from public.hire_bookings_open() where id = %L and days = 3 and fare = 900
           and jsonb_array_length(day_list) = 3', pg_temp.id('d1'))) = '1', 'listed whole to a driver who takes hire');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b3',
  format('select count(*)::text from public.hire_bookings_open() where id = %L', pg_temp.id('d1'))) = '0',
  'not to one who doesn''t');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select count(*)::text from public.scheduled_rides_upcoming() where hire_booking_id = %L', pg_temp.id('d1'))) = '0'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select count(*)::text from public.scheduled_rides_open() where hire_booking_id = %L', pg_temp.id('d1'))) = '0',
  'its days aren''t listed one by one');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select public.scheduled_ride_accept(%L)::text', (pg_temp.day('d1', 2)).id)) like 'HIRE_WHOLE_BOOKING%',
  'nor taken one by one');
-- A ride of the driver's two hours into day 2: a clash.
insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, fare, status, partner_id)
values ('00000000-0000-0000-0000-0000000327a4', pg_temp.first() + interval '1 day 2 hours',
        '{"service": "Day Saloon 327", "pickup_lat": 3.1, "pickup_lng": 101.6, "fare": 10}', 'Day Saloon 327',
        3.1, 101.6, 10, 'assigned', '00000000-0000-0000-0000-0000000327b1');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select public.hire_booking_accept(%L)::text', pg_temp.id('d1'))) like 'SCHEDULED_CLASH%',
  'a clash on any day: ' || pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select public.hire_booking_accept(%L)::text', pg_temp.id('d1'))));
delete from public.scheduled_rides where rider_id = '00000000-0000-0000-0000-0000000327a4'
   and partner_id = '00000000-0000-0000-0000-0000000327b1';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b3',
  format('select public.hire_booking_accept(%L)::text', pg_temp.id('d1'))) like 'HIRE_DRIVER_OFF%',
  'a driver who doesn''t take hire can''t');
select pg_temp.value_as('00000000-0000-0000-0000-0000000327b1', format('select public.hire_booking_accept(%L)::text', pg_temp.id('d1')));
select pg_temp.check((select status = 'assigned' and partner_id = '00000000-0000-0000-0000-0000000327b1' from pg_temp.bk('d1'))
                     and (select count(*) = 3 and bool_and(status = 'assigned' and partner_id = '00000000-0000-0000-0000-0000000327b1')
                            from public.scheduled_rides where hire_booking_id = pg_temp.id('d1')),
  'every day is the driver''s');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000327a1'
                                and event_id like 'hire-assigned-' || pg_temp.id('d1') || '%'), 'the rider is told');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a1',
  format('select count(*)::text from public.hire_bookings where id = %L', pg_temp.id('d1'))) = '1'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select count(*)::text from public.hire_bookings where id = %L', pg_temp.id('d1'))) = '1'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000327a3',
  format('select count(*)::text from public.hire_bookings where id = %L', pg_temp.id('d1'))) = '0',
  'the rider and the driver read the booking; others don''t');

-- ---- 4. A day released -----------------------------------------------------------------------------------
insert into t values ('r1', public.scheduled_ride_release((pg_temp.day('d1', 1)).id));
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000327b1'
                             and hire_package = 'daily' and hire_booking_id = pg_temp.id('d1') and hire_day_no = 1
                             and hire_hours = 10 and fare = 300 and hire_km_included = 150 and hire_overtime_rate = 45
                             and hire_extra_km_rate = 1.5 and option_names ? 'hire'
                        from pg_temp.ride('r1')), 'day 1 is a hire with its driver');
select pg_temp.check(public.ride_amount_due(pg_temp.ride('r1')) = 405, 'day 1 due: 300 + 5 + 20 + 80');
select pg_temp.check((select payment_state = 'paid' and paid_amount = 1135 and allocated_amount = 405
                             and status = 'in_progress' from pg_temp.bk('d1'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a1') = 865
                     and (select amount = 405 and status = 'held' from public.hire_holds where ride_id = pg_temp.id('r1')),
  'the balance taken on day 1, the day''s share held from the booking: ' || pg_temp.bal('00000000-0000-0000-0000-0000000327a1'));
update public.ride_requests set status = 'on_trip' where id = pg_temp.id('r1');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a1',
  format('select public.hire_extend_ask(%L, 60)::jsonb->>''status''', pg_temp.id('r1'))) = 'approved', 'an hour more');
update public.ride_requests set hire_started_at = now() - interval '11 hours', hire_ends_at = now()
 where id = pg_temp.id('r1');
select pg_temp.value_as('00000000-0000-0000-0000-0000000327b1', format('select public.hire_end(%L, 200)::text', pg_temp.id('r1')));
-- 60 min overtime at 45; km included 150 + 15 for the hour; 35 more at 1.5.
select pg_temp.check((select status = 'completed' and fare = 397.5
                             and hire_settled @> '{"base": 300, "overtime": 45, "kmIncluded": 165, "extraKm": 35,
                                                   "extraKmAmount": 52.5}'
                             and hire_settled->'lines' @> '[{"label": "Daily hire day 1 of 3", "amount": 300}]'
                        from pg_temp.ride('r1')), 'day 1 settled: 300 + 45 overtime + 52.50 extra km');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a1',
  format('select public.ride_pay(%L, ''get_wallet'')->>''paid''', pg_temp.id('r1'))) = '502.50', 'paid: 502.50');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000327a1') = 767.5,
  'only the overtime and extra km are new money: ' || pg_temp.bal('00000000-0000-0000-0000-0000000327a1'));
-- Day 2 released by the minute's tick.
update public.scheduled_rides set pickup_at = now() + interval '10 minutes' where id = (pg_temp.day('d1', 2)).id;
select public.scheduled_rides_tick();
select pg_temp.check((select status = 'released' and ride_id is not null from pg_temp.day('d1', 2))
                     and (select r.hire_day_no = 2 and r.partner_id = '00000000-0000-0000-0000-0000000327b1'
                            from public.ride_requests r where r.id = (pg_temp.day('d1', 2)).ride_id)
                     and (select allocated_amount = 810 from pg_temp.bk('d1')), 'day 2 released at its time');

-- ---- 5. Same driver or not --------------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327a3', 2000);
insert into t values ('d2', pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 2}')::uuid);
select pg_temp.daily('{"enabled": true, "mealAllowance": 20, "splitAfterHours": 720}');
select public.hire_tick();
select pg_temp.check((select split_at is not null and status = 'booked' from pg_temp.bk('d2'))
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000327b2',
  format('select count(*)::text from public.scheduled_rides_upcoming() where hire_booking_id = %L', pg_temp.id('d2'))) = '2',
  'nobody took it whole by the cut-off: each day offered on its own');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b2',
  format('select public.scheduled_ride_accept(%L)::text', (pg_temp.day('d2', 2)).id)) like '(%'
                     and (pg_temp.day('d2', 2)).partner_id = '00000000-0000-0000-0000-0000000327b2', 'a driver takes day 2');
insert into t values ('d3', pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 1}')::uuid);
select pg_temp.daily('{"enabled": true, "mealAllowance": 20, "splitAfterHours": 720, "splitDays": false}');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327a3', 0);
select public.hire_tick();
select pg_temp.check((select status = 'expired' and refunded_amount = 97.5 from pg_temp.bk('d3'))
                     and (select status = 'expired' from pg_temp.day('d3', 1))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 97.5,
  'with the split off: closed and the deposit refunded');
select pg_temp.daily('{"enabled": true, "mealAllowance": 20}');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327a3', 2000);
insert into t values ('d4', pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 2, "same_driver": false}')::uuid);
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b2',
  format('select count(*)::text from public.scheduled_rides_upcoming() where hire_booking_id = %L', pg_temp.id('d4'))) = '2'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000327b2',
  format('select count(*)::text from public.hire_bookings_open() where id = %L', pg_temp.id('d4'))) = '0',
  'the same driver switched off: listed by day from the start');

-- ---- 6. Cancel --------------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a3',
  format('select public.scheduled_ride_cancel(%L)::text', (pg_temp.day('d4', 1)).id)) like 'HIRE_BOOKING_CANCEL%',
  'a day isn''t cancelled on its own');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327b1',
  format('select public.hire_booking_cancel(%L)::text', pg_temp.id('d4'))) like 'not_authorized%', 'only the rider');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327a3',
  format('select public.hire_booking_cancel_quote(%L)->>''free''', pg_temp.id('d4'))) = 'true', 'free two days ahead');
select pg_temp.value_as('00000000-0000-0000-0000-0000000327a3', format('select public.hire_booking_cancel(%L)::text', pg_temp.id('d4')));
select pg_temp.check((select status = 'cancelled' and cancelled_by = 'rider' and cancel_fee = 0 and refunded_amount = paid_amount
                        from pg_temp.bk('d4'))
                     and (select bool_and(status = 'cancelled') from public.scheduled_rides where hire_booking_id = pg_temp.id('d4'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 2000, 'cancelled free: all back');
select pg_temp.daily('{"enabled": true, "mealAllowance": 20, "freeCancelHours": 100}');
insert into t values ('d5', pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 2}')::uuid);
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 1805, 'deposit 195 of 650');
select pg_temp.value_as('00000000-0000-0000-0000-0000000327a3', format('select public.hire_booking_cancel(%L)::text', pg_temp.id('d5')));
select pg_temp.check((select cancel_fee = 195 and kept_amount = 195 and refunded_amount = 0 from pg_temp.bk('d5'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 1805, 'late: the deposit is kept');
insert into t values ('d5b', pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 2, "payment_plan": "prepay"}')::uuid);
select pg_temp.value_as('00000000-0000-0000-0000-0000000327a3', format('select public.hire_booking_cancel(%L)::text', pg_temp.id('d5b')));
select pg_temp.check((select cancel_fee = 195 and refunded_amount = 455 from pg_temp.bk('d5b'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 1610,
  'late and prepaid: only the deposit''s share is kept: ' || pg_temp.bal('00000000-0000-0000-0000-0000000327a3'));
select pg_temp.daily('{"enabled": true, "mealAllowance": 20, "freeCancelHours": 100, "lateCancelMode": "percent",
                       "lateCancelPercent": 10}');
insert into t values ('d6', pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 2, "payment_plan": "prepay"}')::uuid);
select pg_temp.check((select paid_amount = 650 and payment_state = 'paid' and balance_amount = 0 from pg_temp.bk('d6'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 960, 'prepaid in full');
select pg_temp.value_as('00000000-0000-0000-0000-0000000327a3', format('select public.hire_booking_cancel(%L)::text', pg_temp.id('d6')));
select pg_temp.check((select cancel_fee = 65 and refunded_amount = 585 from pg_temp.bk('d6'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a3') = 1545, 'late, 10%: 65 kept, the rest back');
select pg_temp.daily('{"enabled": true, "mealAllowance": 20, "allowPrepay": false}');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000327a3', '{"days": 1, "payment_plan": "prepay"}')
  like 'HIRE_PREPAY_OFF%', 'prepaying switched off');
select pg_temp.daily('{"enabled": true, "mealAllowance": 20}');

-- ---- 7. Family --------------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000327f1',
  $q$select public.family_invite('{"country": "Dayland 327"}', '+60100032722', 'Ina', 'daughter')->>'id'$q$)
  ~ '^[0-9a-f-]{36}$', 'the host invites the member');
insert into t select 'm', id from public.family_members
 where family_id = (select id from public.families where host_id = '00000000-0000-0000-0000-0000000327f1');
select pg_temp.value_as('00000000-0000-0000-0000-0000000327f2',
  format('select public.family_respond(%L, true, ''{"shown": ["payments"]}'')', pg_temp.id('m')));
insert into public.family_module_rules (level, module_key, family_pays, book_for_member, child_allowed, live_share)
values ('default', 'hire', true, true, false, true)
on conflict (place_key, module_key) do update set family_pays = true, book_for_member = true;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327f1', 400);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327f2', 0);
insert into t values ('d7', pg_temp.book('00000000-0000-0000-0000-0000000327f2', '{"days": 1, "hours": 8}',
                                         '{"payment_mode": "Family"}')::uuid);
select pg_temp.check((select module_key = 'hire' and family_pays from public.family_trips where trip_id = pg_temp.id('d7'))
                     and (select price = 265 and deposit_amount = 79.5 from pg_temp.bk('d7'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327f1') = 320.5
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327f2') = 0,
  'the deposit from the host''s GET.wallet: ' || pg_temp.bal('00000000-0000-0000-0000-0000000327f1'));
insert into t values ('r7', public.scheduled_ride_release((pg_temp.day('d7', 1)).id));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000327f1') = 135
                     and (select module_key = 'hire' and family_pays from public.family_trips where trip_id = pg_temp.id('r7'))
                     and (select amount = 265 from public.hire_holds where ride_id = pg_temp.id('r7')),
  'the balance from the host on day 1: ' || pg_temp.bal('00000000-0000-0000-0000-0000000327f1'));
select pg_temp.value_as('00000000-0000-0000-0000-0000000327f2', format('select public.hire_booking_cancel(%L)::text', pg_temp.id('d7')));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000327f1') = 400
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327f2') = 0
                     and (select status = 'cancelled' from pg_temp.ride('r7')),
  'cancelled before the trip: all back to the host: ' || pg_temp.bal('00000000-0000-0000-0000-0000000327f1'));

-- ---- 8. Business ------------------------------------------------------------------------------------------
insert into public.business_accounts (id, name, reg_no, status, country, terms)
values ('00000000-0000-0000-0000-0000000327c1', 'Harian 327 Sdn Bhd', '2023032700', 'active', 'Dayland 327', 'invoice');
insert into public.business_members (account_id, profile_id, phone, name, role, status)
values ('00000000-0000-0000-0000-0000000327c1', '00000000-0000-0000-0000-0000000327a2', '+60100032702', 'Badrul', 'rider', 'active');
insert into t values ('d8', pg_temp.book('00000000-0000-0000-0000-0000000327a2', '{"days": 2}',
                                         '{"business_account_id": "00000000-0000-0000-0000-0000000327c1"}')::uuid);
select pg_temp.check((select payment_plan = 'business' and payment_state = 'business' and paid_amount = 0
                             and business_account_id = '00000000-0000-0000-0000-0000000327c1' from pg_temp.bk('d8'))
                     and (select bool_and(request->>'payment_mode' like 'Business:%')
                            from public.scheduled_rides where hire_booking_id = pg_temp.id('d8'))
                     and pg_temp.bal('00000000-0000-0000-0000-0000000327a2') = 0,
  'a business account books daily hire: nothing paid upfront');
insert into t values ('r8', public.scheduled_ride_release((pg_temp.day('d8', 1)).id));
select pg_temp.check((select business_account_id = '00000000-0000-0000-0000-0000000327c1' and fare = 300
                             and not exists (select 1 from public.hire_holds h where h.ride_id = pg_temp.id('r8'))
                        from pg_temp.ride('r8')), 'its day is the account''s, nothing held');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('r8');
insert into t values ('h1', pg_temp.value_as('00000000-0000-0000-0000-0000000327a2',
  $q$insert into public.ride_requests (rider_id, status, service, payment_mode, pickup_lat, pickup_lng, pickup_name,
       fare, ride_fare, offer_me, country, hire_package, hire_hours, business_account_id)
     values ('00000000-0000-0000-0000-0000000327a2', 'open', 'Day Saloon 327', 'Business', 3.1, 101.6, 'Day Plaza 327',
             1, 1, true, 'Dayland 327', 'hourly', 3, '00000000-0000-0000-0000-0000000327c1') returning id::text$q$)::uuid);
select pg_temp.check((select fare = 120 and payment_mode like 'Business:%' and business_member_id is not null
                        from pg_temp.ride('h1')), 'a business account books hourly hire, at the hire''s price');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('h1');

-- ---- 9. Whole fares --------------------------------------------------------------------------------------
update public.settings_entries set values = values || '{"hirePerHour": 40.25, "hireDayRate": 333}'
 where category = 'vehicle-services' and values->>'name' = 'Day Saloon 327';
select pg_temp.set_bal('00000000-0000-0000-0000-0000000327a4', 2000);
insert into t values ('h2', pg_temp.value_as('00000000-0000-0000-0000-0000000327a4',
  $q$insert into public.ride_requests (rider_id, status, service, payment_mode, pickup_lat, pickup_lng, fare, ride_fare,
       country, hire_package, hire_hours, whole_fare)
     values ('00000000-0000-0000-0000-0000000327a4', 'open', 'Day Saloon 327', 'Get Pay', 3.1, 101.6, 1, 1,
             'Dayland 327', 'hourly', 3, true) returning id::text$q$)::uuid);
select pg_temp.check((select fare = 121 and ride_fare = 121 from pg_temp.ride('h2')), 'hourly: 120.75 rounded up to 121');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('h2');
insert into t values ('d9', pg_temp.book('00000000-0000-0000-0000-0000000327a4', '{"days": 1, "hours": 9}',
                                         '{"whole_fare": true}')::uuid);
select pg_temp.check((pg_temp.day('d9', 1)).fare = 300, 'daily: 299.70 rounded up to 300');
update public.settings_entries set values = values || '{"hirePerHour": 40, "hireDayRate": 300}'
 where category = 'vehicle-services' and values->>'name' = 'Day Saloon 327';

-- ---- 10. Cash turned off after a cash booking ---------------------------------------------------------
select from public.set_hourly_hire_config('{"enabled": true, "allowCash": true}');
create or replace function pg_temp.cash_later() returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, fare)
  values ('00000000-0000-0000-0000-0000000327a4', now() + interval '3 hours',
          '{"service": "Day Saloon 327", "pickup_lat": 3.1, "pickup_lng": 101.6, "fare": 7, "ride_fare": 7,
            "payment_mode": "Cash", "country": "Dayland 327", "hire_package": "hourly", "hire_hours": 3}',
          'Day Saloon 327', 3.1, 101.6, 7)
  returning id into v;
  return v;
end $$;
insert into t values ('c1', pg_temp.cash_later()), ('c2', pg_temp.cash_later()), ('c3', pg_temp.cash_later());
select from public.set_hourly_hire_config('{"enabled": true, "allowCash": false}');
select pg_temp.check(public.hourly_hire_config()->>'cashOffLater' = 'cash', 'by default: as booked');
insert into t values ('x1', public.scheduled_ride_release(pg_temp.id('c1')));
select pg_temp.check((select payment_mode = 'Cash' and status = 'open' from pg_temp.ride('x1')), 'goes ahead in cash');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('x1');
select from public.set_hourly_hire_config('{"enabled": true, "allowCash": false, "cashOffLater": "wallet"}');
insert into t values ('x2', public.scheduled_ride_release(pg_temp.id('c2')));
select pg_temp.check((select payment_mode = 'Get Pay' and status = 'open' from pg_temp.ride('x2'))
                     and exists (select 1 from public.notification_outbox where event_id = 'hire-cash-wallet-' || pg_temp.id('x2')),
  'switched to GET.wallet, the rider told');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('x2');
select from public.set_hourly_hire_config('{"enabled": true, "allowCash": false, "cashOffLater": "cancel"}');
insert into t values ('x3', public.scheduled_ride_release(pg_temp.id('c3')));
select pg_temp.check((select status = 'cancelled' and cancel_requested_by = 'system' from pg_temp.ride('x3'))
                     and exists (select 1 from public.notification_outbox where event_id = 'hire-cash-cancel-' || pg_temp.id('x3')),
  'cancelled free, the rider told');
select public.scheduled_rides_tick();
select pg_temp.check((select status = 'cancelled' and cancel_fee = 0 from public.scheduled_rides where id = pg_temp.id('c3')),
  'its booking is closed with no fee');

-- The Family module is registered under its new name.
select pg_temp.check(exists (select 1 from public.booking_modules where key = 'hire' and name = 'Hire'), 'the hire module');

rollback;
