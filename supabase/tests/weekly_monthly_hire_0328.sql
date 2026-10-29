-- ============================================================================
-- Regression test for migration 0328: weekly and monthly hire.
--   1. The settings: weekly and monthly off until the admin turns them on,
--      their defaults, daily unchanged with its new keys.
--   2. Public holidays: read by everyone, written by admins only.
--   3. The weekly quote: the weekdays chosen, the weeks, the week rate for
--      the weekdays and hours, a holiday skipped (or worked), the km a week,
--      the lead time; the monthly quote: a calendar month, the month rate.
--   4. Booking: a weekly hire prepaid, a row a working day at its own
--      price; a deposit refused unless the admin allows it; a monthly hire
--      on a business account.
--   5. Km by the period: the days before the period's last include what
--      they drove; the last one is charged the extra km over the week.
--   6. Drivers: a driver lets a day go and it is offered to others; the
--      admin lists the drivers, gives every day to one and one day to another.
--   7. Monthly notice: once it has started, cancelling keeps the days
--      within the notice; the rest are cancelled.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/weekly_monthly_hire_0328.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000328a1'),  -- rider, GET.wallet
  ('00000000-0000-0000-0000-0000000328a2'),  -- rider, business
  ('00000000-0000-0000-0000-0000000328a3'),  -- rider, monthly
  ('00000000-0000-0000-0000-0000000328b1'),  -- driver who takes hire
  ('00000000-0000-0000-0000-0000000328b2'),  -- driver who takes hire
  ('00000000-0000-0000-0000-0000000328b3'),  -- driver who takes hire
  ('00000000-0000-0000-0000-0000000328d1')   -- admin, EDIT on rides
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000328a1', 'Aina Mingguan', '+60100032801'),
  ('00000000-0000-0000-0000-0000000328a2', 'Badrul Bulanan', '+60100032802'),
  ('00000000-0000-0000-0000-0000000328a3', 'Chen Monthly', '+60100032803'),
  ('00000000-0000-0000-0000-0000000328b1', 'Eddy Minggu', '+60100032811'),
  ('00000000-0000-0000-0000-0000000328b2', 'Farid Bulan', '+60100032812'),
  ('00000000-0000-0000-0000-0000000328b3', 'Gani Bulan', '+60100032813'),
  ('00000000-0000-0000-0000-0000000328d1', 'Dina Admin', '+60100032821')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000328b1', 'Eddy Minggu', '+60100032811', 'approved'),
  ('00000000-0000-0000-0000-0000000328b2', 'Farid Bulan', '+60100032812', 'approved'),
  ('00000000-0000-0000-0000-0000000328b3', 'Gani Bulan', '+60100032813', 'approved');
insert into public.driver_ride_extras (driver_id, takes_hire) values
  ('00000000-0000-0000-0000-0000000328b1', true), ('00000000-0000-0000-0000-0000000328b2', true),
  ('00000000-0000-0000-0000-0000000328b3', true)
on conflict (driver_id) do update set takes_hire = excluded.takes_hire;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000328d1', 'admin-rides', 'edit')
on conflict do nothing;

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
    values (p_user, 'get_wallet', 'test_adjust', p_to - pg_temp.bal(p_user), 'test 0328');
  end if;
end $$;
create or replace function pg_temp.cfg(p_pkg text, p jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.as_server();
  perform public.set_hire_package_config(p_pkg, p);
end $$;
-- A Monday two weeks ahead, 9:00 in Malaysia.
create or replace function pg_temp.monday() returns timestamptz language sql as $$
  select (date_trunc('week', now() at time zone 'Asia/Kuala_Lumpur') + interval '14 days 9 hours')
         at time zone 'Asia/Kuala_Lumpur';
$$;
create or replace function pg_temp.q(p_pkg text, p_periods int, p_weekdays jsonb, p_hours numeric default 8,
                                     p_at timestamptz default null) returns jsonb
language sql as $$
  select public.hire_multi_quote(p_pkg, 3.10, 101.60, null, null, 'Week Saloon 328', null, p_hours,
                                 coalesce(p_at, pg_temp.monday()), 'Weekland 328', 'Negeri 328', null, null, null,
                                 false, 'Asia/Kuala_Lumpur', jsonb_build_object('periods', p_periods, 'weekdays', p_weekdays));
$$;
create or replace function pg_temp.book(p_rider uuid, p_booking jsonb, p_request jsonb default '{}'::jsonb) returns text
language sql as $$
  select pg_temp.value_as(p_rider, format($f$select (public.hire_book(%L::jsonb, %L::jsonb))->>'id'$f$,
    jsonb_build_object('service', 'Week Saloon 328', 'payment_mode', 'Get Pay', 'pickup_lat', 3.10, 'pickup_lng', 101.60,
                       'pickup_name', 'Week Plaza 328', 'fare', 1, 'ride_fare', 1, 'country', 'Weekland 328',
                       'state', 'Negeri 328', 'timezone', 'Asia/Kuala_Lumpur', 'currency', 'MYR') || p_request,
    jsonb_build_object('package', 'weekly', 'first_at', pg_temp.monday(), 'periods', 2, 'hours', 8,
                       'weekdays', '[1,2,3,4,5]'::jsonb) || p_booking));
$$;
create temp table t (k text primary key, id uuid);
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create or replace function pg_temp.bk(p_k text) returns public.hire_bookings language sql as $$
  select * from public.hire_bookings where id = pg_temp.id(p_k) $$;
create or replace function pg_temp.day(p_k text, p_n int) returns public.scheduled_rides language sql as $$
  select * from public.scheduled_rides where hire_booking_id = pg_temp.id(p_k) and hire_day_no = p_n $$;
create or replace function pg_temp.ride(p_k text) returns public.ride_requests language sql as $$
  select * from public.ride_requests where id = pg_temp.id(p_k) $$;

insert into public.countries (name, values) values ('Weekland 328', '{}');
insert into public.settings_entries (category, values, position) values
  ('vehicle-services', '{"name": "Week Saloon 328", "status": true, "costPerKm": 2, "costPerMin": 0.3,
     "minFareAmount": 5, "hireEnabled": true, "hirePerHour": 40, "hireDayRate": 300, "hireDayHours": 10,
     "hireDayKm": 150, "hireDayOvertimePerHour": 45, "hireDayExtraKm": 1.5, "hireWeekRate": 1500,
     "hireWeekKm": 800}', 9021);
select from public.set_hourly_hire_config('{"enabled": true}');
update public.app_settings set value = value || '{"enabled": true, "mode": "advance"}' where key = 'scheduled_rides';

-- ---- 1. Settings -----------------------------------------------------------------------------------------
select pg_temp.check(public.hire_package_config('weekly') @> '{"enabled": false, "maxWeeks": 8, "leadHours": 24,
  "allowPrepay": true, "allowDeposit": false, "allowBusiness": true, "kmPerWeekDefault": 1000, "rateWeekdays": 5,
  "weekdaysDefault": [1, 2, 3, 4, 5], "holidays": "skip", "kmMode": "period", "noticeDays": 0,
  "labels": {"chip": "Weekly", "title": "Weekly hire"}}', 'the weekly defaults');
select pg_temp.check(public.hire_package_config('monthly') @> '{"enabled": false, "maxMonths": 3, "leadHours": 72,
  "allowDeposit": false, "noticeDays": 7, "kmPerMonthDefault": 4000, "labels": {"chip": "Monthly", "title": "Monthly hire"}}',
  'the monthly defaults');
select pg_temp.check(public.hire_package_config('daily') @> '{"maxDays": 6, "allowDeposit": true, "allowBusiness": true}',
  'daily keeps its own, with the new keys');
select pg_temp.cfg('weekly', '{"enabled": true, "allowPrepay": false, "allowDeposit": false, "maxWeeks": 99,
                                "weekdaysDefault": [9, 1]}');
select pg_temp.check(public.hire_package_config('weekly') @> '{"allowPrepay": true, "maxWeeks": 26, "weekdaysDefault": [1]}',
  'always some payment, within the safe limits');
select pg_temp.cfg('weekly', '{"enabled": true}');
select pg_temp.cfg('monthly', '{"enabled": true, "weekdaysDefault": [1,2,3,4,5,6,7]}');

-- ---- 2. Public holidays ------------------------------------------------------------------------------------
insert into public.public_holidays (day, name, country)
values ((pg_temp.monday() at time zone 'Asia/Kuala_Lumpur')::date + 2, 'Hari Contoh 328', 'Weekland 328');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328a1',
  $q$select count(*)::text from public.public_holidays where name = 'Hari Contoh 328'$q$) = '1', 'everyone reads them');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328a1',
  $q$insert into public.public_holidays (day, name) values ('2030-01-01', 'Mine') returning 1$q$) like '%row-level security%',
  'a rider can''t add one');

-- ---- 3. The quote ------------------------------------------------------------------------------------------
-- Two weeks of Monday to Friday, 8 hours: the week 1500 × 5/5 × 8/10 = 1200, 240 a day; the Wednesday off.
select pg_temp.check(pg_temp.q('weekly', 2, '[1,2,3,4,5]') @> '{"available": true, "periods": 2, "days": 9,
  "periodRate": 1500, "periodPrice": 1200, "perDay": 240, "kmPerPeriod": 800, "kmPerDay": 160, "base": 2160,
  "kmMode": "period"}' and jsonb_array_length(pg_temp.q('weekly', 2, '[1,2,3,4,5]')->'holidaysSkipped') = 1,
  'two weeks less the holiday: ' || pg_temp.q('weekly', 2, '[1,2,3,4,5]')::text);
select pg_temp.check((select bool_and(extract(isodow from (e->>'at')::timestamptz at time zone 'Asia/Kuala_Lumpur') between 1 and 5
                                      and ((e->>'at')::timestamptz at time zone 'Asia/Kuala_Lumpur')::time = '09:00')
                        from jsonb_array_elements(pg_temp.q('weekly', 2, '[1,2,3,4,5]')->'dateList') e),
  'only the weekdays chosen, each at 9:00');
select pg_temp.check((pg_temp.q('weekly', 1, '[1,3,5]')->>'periodPrice')::numeric = 720
                     and (pg_temp.q('weekly', 1, '[1,3,5]')->>'days')::int = 2,
  'three weekdays: 3/5 of the week; the holiday Wednesday skipped');
select pg_temp.cfg('weekly', '{"enabled": true, "holidays": "work"}');
select pg_temp.check((pg_temp.q('weekly', 2, '[1,2,3,4,5]')->>'days')::int = 10, 'holidays worked: every weekday');
select pg_temp.cfg('weekly', '{"enabled": true}');
select pg_temp.check(pg_temp.q('weekly', 9, '[1,2,3,4,5]')->>'reason' = 'HIRE_PERIODS'
                     and pg_temp.q('weekly', 9, '[1,2,3,4,5]')->>'hint' = 'Choose between 1 and 8 weeks.', 'the weeks');
select pg_temp.check(pg_temp.q('weekly', 1, '[]')->>'reason' = 'HIRE_WEEKDAYS', 'no weekday');
select pg_temp.check(pg_temp.q('weekly', 1, '[1]', p_at => now() + interval '10 hours')->>'reason' = 'HIRE_LEAD',
  'a day''s notice for a week');
select pg_temp.check(pg_temp.q('monthly', 1, '[1,2,3,4,5,6,7]', p_at => now() + interval '2 days')->>'reason' = 'HIRE_LEAD',
  'three days'' notice for a month');
-- A month: the week rate × 52 / 12 = 6500, for every day of the week (7/5) and 8 of 10 hours: 7280.
select pg_temp.check(pg_temp.q('monthly', 1, '[1,2,3,4,5,6,7]') @> '{"available": true, "periods": 1,
  "periodRate": 6500, "periodPrice": 7280}'
                     and abs((pg_temp.q('monthly', 1, '[1,2,3,4,5,6,7]')->>'base')::numeric
                             - 7280 * ((pg_temp.q('monthly', 1, '[1,2,3,4,5,6,7]')->>'days')::numeric
                                       / ((pg_temp.q('monthly', 1, '[1,2,3,4,5,6,7]')->>'days')::numeric + 1))) < 1,
  'a calendar month at the month rate, less the holiday: ' || pg_temp.q('monthly', 1, '[1,2,3,4,5,6,7]')::text);

-- ---- 4. Booking ----------------------------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000328a1', 5000);
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000328a1', '{"payment_plan": "deposit"}')
  like 'HIRE_DEPOSIT_OFF%', 'weekly is paid in full unless the admin allows a deposit');
insert into t values ('w1', pg_temp.book('00000000-0000-0000-0000-0000000328a1', '{}')::uuid);
select pg_temp.check((select package = 'weekly' and days = 9 and periods = 2 and weekdays = '{1,2,3,4,5}'
                             and km_mode = 'period' and km_per_period = 800 and payment_plan = 'prepay'
                             and payment_state = 'paid' and price = 2160 and paid_amount = 2160
                        from pg_temp.bk('w1')), 'booked and prepaid: 9 days × 240');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000328a1') = 2840, 'paid from GET.wallet');
select pg_temp.check((select count(*) = 9 and bool_and(fare = 240 and hire_package = 'weekly')
                        from public.scheduled_rides where hire_booking_id = pg_temp.id('w1'))
                     and (pg_temp.day('w1', 4)).request->'hire_quote' @> '{"periodNo": 1, "periodLast": true,
                                                                          "kmIncluded": 160, "kmPerPeriod": 800}'
                     and (pg_temp.day('w1', 3)).request->'hire_quote' @> '{"periodNo": 1, "periodLast": false}',
  'a row a working day; day 4 (Friday) ends week 1');
select pg_temp.cfg('weekly', '{"enabled": true, "allowDeposit": true}');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000328a3', 5000);
insert into t values ('w2', pg_temp.book('00000000-0000-0000-0000-0000000328a3', '{"payment_plan": "deposit", "periods": 1}')::uuid);
select pg_temp.check((select payment_plan = 'deposit' and deposit_amount = round(price * 0.3, 2) from pg_temp.bk('w2')),
  'a deposit where the admin allows it');
-- A monthly hire on a business account: charged to the account, nothing upfront.
insert into public.business_accounts (id, name, reg_no, status, country, terms)
values ('00000000-0000-0000-0000-0000000328c1', 'Bulanan 328 Sdn Bhd', '2023032800', 'active', 'Weekland 328', 'invoice');
insert into public.business_members (account_id, profile_id, phone, name, role, status)
values ('00000000-0000-0000-0000-0000000328c1', '00000000-0000-0000-0000-0000000328a2', '+60100032802', 'Badrul', 'rider', 'active');
insert into t values ('m1', pg_temp.book('00000000-0000-0000-0000-0000000328a2',
  '{"package": "monthly", "periods": 1, "weekdays": [1,2,3,4,5]}',
  '{"business_account_id": "00000000-0000-0000-0000-0000000328c1"}')::uuid);
select pg_temp.check((select package = 'monthly' and payment_plan = 'business' and paid_amount = 0 and days >= 18
                        from pg_temp.bk('m1'))
                     and (select bool_and(request->>'payment_mode' like 'Business:%')
                            from public.scheduled_rides where hire_booking_id = pg_temp.id('m1')),
  'a month on the business account (its monthly invoice)');

-- ---- 5. Km by the period ---------------------------------------------------------------------------------------
select pg_temp.value_as('00000000-0000-0000-0000-0000000328b1', format('select public.hire_booking_accept(%L)::text', pg_temp.id('w1')));
select pg_temp.check((select status = 'assigned' from pg_temp.bk('w1')), 'a driver takes every day');
create or replace function pg_temp.drive(p_k text, p_n int, p_km numeric) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := public.scheduled_ride_release((pg_temp.day(p_k, p_n)).id);
  update public.ride_requests set status = 'on_trip' where id = v;
  update public.ride_requests set hire_started_at = now() - interval '8 hours' where id = v;
  perform pg_temp.value_as('00000000-0000-0000-0000-0000000328b1', format('select public.hire_end(%L, %s)::text', v, p_km));
  return v;
end $$;
insert into t values ('wd1', pg_temp.drive('w1', 1, 100)), ('wd2', pg_temp.drive('w1', 2, 100)),
                     ('wd3', pg_temp.drive('w1', 3, 100));
select pg_temp.check((select bool_and(status = 'completed' and fare = 240 and (hire_settled->>'extraKm')::numeric = 0)
                        from public.ride_requests where id in (pg_temp.id('wd1'), pg_temp.id('wd2'), pg_temp.id('wd3'))),
  'the days before the week''s last: no extra km');
insert into t values ('wd4', pg_temp.drive('w1', 4, 600));
-- The week: 900 km of 800; 100 more at 1.5 on its last day.
select pg_temp.check((select status = 'completed' and fare = 390
                             and hire_settled @> '{"kmIncluded": 500, "extraKm": 100, "extraKmAmount": 150}'
                             and hire_settled->'lines' @> '[{"label": "Extra km 100 km this period", "amount": 150}]'
                        from pg_temp.ride('wd4')), 'the week''s extra km on its last day');
select pg_temp.cfg('weekly', '{"enabled": true, "allowDeposit": true, "kmMode": "day"}');
select pg_temp.check((public.hire_multi_quote('weekly', 3.1, 101.6, null, null, 'Week Saloon 328', null, 8, pg_temp.monday(),
                        'Weekland 328', null, null, null, null, false, 'Asia/Kuala_Lumpur', '{"periods": 1}')->>'kmMode') = 'day',
  'or by the day, as the admin says');

-- ---- 6. Drivers ------------------------------------------------------------------------------------------------
-- The driver can't make day 6: it goes back to the pool and is offered to others.
select pg_temp.value_as('00000000-0000-0000-0000-0000000328b1',
  format('select public.scheduled_ride_driver_cancel(%L)::text', (pg_temp.day('w1', 6)).id));
select pg_temp.check((pg_temp.day('w1', 6)).partner_id is null
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000328b2',
  format('select count(*)::text from public.scheduled_rides_upcoming() where id = %L', (pg_temp.day('w1', 6)).id)) = '1',
  'a day the driver let go is offered to other drivers');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328a1',
  format('select public.hire_booking_admin_assign(%L, %L)::text', pg_temp.id('w1'), '00000000-0000-0000-0000-0000000328b2'))
  like 'not_authorized%', 'only an admin assigns');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select count(*)::text from public.hire_booking_admin_drivers(%L, 6) where id = %L and free',
         pg_temp.id('w1'), '00000000-0000-0000-0000-0000000328b2')) = '1', 'the admin lists who can take it');
select pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select public.hire_booking_admin_assign(%L, %L, 6)::text', pg_temp.id('w1'), '00000000-0000-0000-0000-0000000328b2'));
select pg_temp.check((pg_temp.day('w1', 6)).partner_id = '00000000-0000-0000-0000-0000000328b2'
                     and (pg_temp.day('w1', 7)).partner_id = '00000000-0000-0000-0000-0000000328b1',
  'the admin gives day 6 to another driver');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select public.hire_booking_admin_assign(%L, %L)::text', pg_temp.id('m1'), '00000000-0000-0000-0000-0000000328b2'))
  like 'SCHEDULED_CLASH%', 'not to a driver with a day that clashes (day 6 of the weekly hire)');
select pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select public.hire_booking_admin_assign(%L, %L)::text', pg_temp.id('m1'), '00000000-0000-0000-0000-0000000328b3'));
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000328b3' and status = 'assigned' from pg_temp.bk('m1'))
                     and (select bool_and(partner_id = '00000000-0000-0000-0000-0000000328b3' and status = 'assigned')
                            from public.scheduled_rides where hire_booking_id = pg_temp.id('m1')),
  'the admin gives a whole month to a driver');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000328b3'
                                and event_id like 'hire-admin-assign-' || pg_temp.id('m1') || '%'), 'the driver is told');

-- ---- 7. Monthly notice ---------------------------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000328a3', 20000);
insert into t values ('m2', pg_temp.book('00000000-0000-0000-0000-0000000328a3',
  jsonb_build_object('package', 'monthly', 'periods', 1, 'weekdays', '[1,2,3,4,5,6,7]'::jsonb,
                     'first_at', date_trunc('hour', now()) + interval '4 days'))::uuid);
select pg_temp.check((select payment_plan = 'prepay' and paid_amount = price from pg_temp.bk('m2')), 'a month prepaid');
insert into t values ('mr1', public.scheduled_ride_release((pg_temp.day('m2', 1)).id));
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328a3',
  format('select public.hire_booking_cancel_quote(%L)->>''noticeDays''', pg_temp.id('m2'))) = '7', 'the notice is 7 days');
select pg_temp.value_as('00000000-0000-0000-0000-0000000328a3', format('select public.hire_booking_cancel(%L)::text', pg_temp.id('m2')));
select pg_temp.check((select status = 'in_progress' and notice_until is not null and cancel_fee = 0 from pg_temp.bk('m2'))
                     and (select bool_and(case when pickup_at >= (pg_temp.bk('m2')).notice_until then status = 'cancelled'
                                               else status in ('scheduled', 'released') end)
                            from public.scheduled_rides where hire_booking_id = pg_temp.id('m2'))
                     and (pg_temp.day('m2', 2)).status = 'scheduled',
  'the days within the notice go ahead; the rest are cancelled');

-- ---- 8. Admin › Hire bookings ------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328a1',
  $q$select count(*)::text from public.hire_bookings_admin()$q$) like 'not_authorized%', 'admins only');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select count(*)::text from public.hire_bookings_admin(p_package => %L) where id = %L and rider_name = %L
            and last_at > first_at and days = 9', 'weekly', pg_temp.id('w1'), 'Aina Mingguan')) = '1',
  'a weekly booking with its rider and last day');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select count(*)::text from public.hire_bookings_admin(p_status => ''booked'', p_package => ''monthly'') where id = %L',
         pg_temp.id('m1'))) = '0'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select count(*)::text from public.hire_bookings_admin(p_status => ''assigned'') where id = %L and partner_name = %L',
         pg_temp.id('m1'), 'Gani Bulan')) = '1', 'filtered by status, with its driver');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  $q$select string_agg(distinct rider_name, ',')  from public.hire_bookings_admin(p_query => '0032802')$q$) = 'Badrul Bulanan'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  format('select count(*)::text from public.hire_bookings_admin(p_query => %L)', left(pg_temp.id('w2')::text, 8))) = '1'
                     and pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  $q$select count(*)::text from public.hire_bookings_admin(p_from => current_date + 400)$q$) = '0',
  'searched by phone and booking id; a date range');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000328d1',
  $q$select (count(*) = 2 and bool_and(total >= 4))::text from public.hire_bookings_admin(p_limit => 2)$q$) = 'true',
  'a page at a time, with the count of all that match');

rollback;
