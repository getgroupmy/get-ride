-- ============================================================================
-- Regression test for migration 0330: myGiG, part B (bookings for later and
-- hire by time from myGiG).
--   1. Settings: the later and hire keys and their checks; a region rule.
--   2. The driver's own hire rates, kept within the admin's limits; get.ride's
--      rates when the admin doesn't allow their own.
--   3. Lead times: a time passed, too soon for each kind, too far ahead.
--   4. Each package's price: hourly, daily (overnight), weekly, monthly (a
--      public holiday skipped); hire with no drop-off.
--   5. How it is paid: in the app charged at the start; a non-app passenger
--      pays by link first (link_first, deposit, full) or isn't offered
--      multi-day hire ('no'); a business account on its invoice.
--   6. A later trip: booked, reminded, started from Scheduled myGiG,
--      charged in the app at the start, completed, the driver paid.
--   7. A daily hire paid by link and cash: the deposit by link confirms it,
--      the balance before day 1 (cash), each day released with the hire's
--      columns, overtime and extra km paid before the day ends, the next day
--      left in Scheduled myGiG, the hire_bookings row following it.
--   8. Weekly hire in the app: in full when accepted; a monthly business
--      hire: nothing upfront, each day on the account.
--   9. Cancelling: free before the free-cancel time, the deposit kept after
--      it, everything back when the driver cancels; a booking not paid in
--      time ends.
--  10. Family: the host's GET.wallet pays the booking.
--  11. Hourly hire now: the ride carries the hire; 0326's End hire goes
--      through myGiG.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mygig_later_hire_0330.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000330d1'),  -- driver Hafiz
  ('00000000-0000-0000-0000-0000000330d2'),  -- driver Lee
  ('00000000-0000-0000-0000-0000000330a1'),  -- passenger Aisha: latest app
  ('00000000-0000-0000-0000-0000000330a2'),  -- passenger Ravi: older app, business
  ('00000000-0000-0000-0000-0000000330f1'),  -- Family host Farid
  ('00000000-0000-0000-0000-0000000330e1')   -- admin
on conflict do nothing;
insert into public.profiles (id, name, phone, app_version, app_platform) values
  ('00000000-0000-0000-0000-0000000330d1', 'Hafiz Contoh', '+60100330001', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000330d2', 'Lee Sample', '+60100330002', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000330a1', 'Aisha Rahman', '+60100330011', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000330a2', 'Ravi Kumar', '+60100330012', '0.0.1', 'android'),
  ('00000000-0000-0000-0000-0000000330f1', 'Farid Contoh', '+60100330021', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000330e1', 'Admin 330', '+60100330031', null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone,
  app_version = excluded.app_version, app_platform = excluded.app_platform;
insert into public.partners (auth_user_id, name, phone, status, partner_types, plate, vehicle) values
  ('00000000-0000-0000-0000-0000000330d1', 'Hafiz Contoh', '+60100330001', 'approved', '{"Gig Car 330"}', 'WXY 2481', 'Perodua Bezza'),
  ('00000000-0000-0000-0000-0000000330d2', 'Lee Sample', '+60100330002', 'approved', '{"Gig Car 330"}', 'VBC 7720', 'Toyota Innova');
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000330d1', true, 3.11, 101.66, now()),
  ('00000000-0000-0000-0000-0000000330d2', true, 3.11, 101.66, now())
on conflict (profile_id) do update set online = true, updated_at = now();
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000330e1', 'admin-mygig', 'edit');
insert into public.settings_entries (category, values, position, active) values
  ('partner-type', '{"name": "Gig Car 330", "vehicleRequired": true,
                     "rules": {"mygig": {"allowed": true, "all": true, "regions": []}}}', 9330, true),
  ('app-version-setting', '{"version": "9.0.0", "platform": "All"}', 9330, true);

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
  if p_user is null then
    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  else
    perform set_config('role', 'authenticated', true);
    perform pg_temp.as_user(p_user);
  end if;
  execute p_sql into v;
  perform pg_temp.as_server();
  return coalesce(nullif(v, ''), 'ok');
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.j(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v text := pg_temp.value_as(p_user, p_sql);
begin
  return v::jsonb;
exception when others then
  raise exception 'FAILED: % gave %', p_sql, v;
end $$;
create or replace function pg_temp.bal(p_user uuid, p_type text default 'get_wallet') returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = p_type), 0);
$$;
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric, p_type text default 'get_wallet') returns void
language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user, p_type) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, p_type, 'test_adjust', p_to - pg_temp.bal(p_user, p_type), 'test 0330');
  end if;
end $$;
create or replace function pg_temp.rule(p jsonb) returns void language sql as $$
  update public.mygig_rules set settings = public.mygig_merge(settings, p) where level = 'default';
$$;
create temp table t (k text primary key, id uuid, v jsonb);
grant all on t to authenticated, anon;
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create or replace function pg_temp.bk(p_k text) returns public.mygig_bookings language sql as $$
  select * from public.mygig_bookings where id = pg_temp.id(p_k) $$;
create or replace function pg_temp.ride(p_id uuid) returns public.ride_requests language sql as $$
  select * from public.ride_requests where id = p_id $$;
create or replace function pg_temp.trip(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object(
    'pickup', jsonb_build_object('lat', 3.110, 'lng', 101.660, 'name', 'Bangsar South 330', 'here', false),
    'drop', jsonb_build_object('lat', 3.134, 'lng', 101.686, 'name', 'Sentral 330'),
    'stops', '[]'::jsonb, 'km', 6, 'min', 15, 'pax', 1, 'bags', jsonb_build_object('small', 0, 'medium', 0, 'large', 0),
    'pay', 'cash') || p_extra;
$$;
-- A hire with no drop-off ("as directed").
create or replace function pg_temp.hire(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object(
    'pickup', jsonb_build_object('lat', 3.110, 'lng', 101.660, 'name', 'TTDI 330', 'here', false),
    'pax', 1, 'bags', jsonb_build_object('small', 0, 'medium', 0, 'large', 0), 'pay', 'cash') || p_extra;
$$;
create or replace function pg_temp.send_sql(p_trip jsonb, p_phone text, p_name text, p_way text, p_booking jsonb) returns text
language sql as $$
  select format('select public.mygig_create(%L, 3.11, 101.66)::text',
                jsonb_build_object('trip', p_trip, 'phone', p_phone, 'name', p_name, 'way', p_way, 'booking', p_booking));
$$;
create or replace function pg_temp.quote(p_trip jsonb) returns jsonb language sql as $$
  select pg_temp.j('00000000-0000-0000-0000-0000000330d1', format('select public.mygig_quote(%L, 3.11, 101.66)::text', p_trip));
$$;
-- Sends [p_trip] with [p_booking], then the passenger accepts as [p_way] says; the booking's id is kept as [p_k].
create or replace function pg_temp.book(p_k text, p_trip jsonb, p_phone text, p_name text, p_way text, p_booking jsonb)
returns void language plpgsql as $$
declare
  o jsonb := pg_temp.j('00000000-0000-0000-0000-0000000330d1', pg_temp.send_sql(p_trip, p_phone, p_name, p_way, p_booking));
  a jsonb;
begin
  if p_way = 'app' then
    a := pg_temp.j('00000000-0000-0000-0000-0000000330a1', format('select public.mygig_accept(%L)::text', o->>'offerId'));
  elsif p_way = 'sms' then
    a := pg_temp.j(null, format('select public.mygig_link_answer(%L, true)::text', o->>'token'));
  else
    a := pg_temp.j('00000000-0000-0000-0000-0000000330d1', format('select public.mygig_accept_here(%L)::text', o->>'offerId'));
  end if;
  insert into t values (p_k, (a->>'bookingId')::uuid, o || jsonb_build_object('accept', a));
end $$;
-- A paid link (as the payments function settles one).
create or replace function pg_temp.link_pay(p_ref uuid, p_amount numeric, p_n int) returns void language plpgsql as $$
begin
  insert into public.payment_intents (id, user_id, purpose, purpose_ref, provider, amount)
  values (('00000000-0000-0000-0000-0000003300' || lpad(p_n::text, 2, '0'))::uuid, null, 'ride_card', p_ref::text, 'stripe', p_amount);
  perform public.payment_ride_card_paid(('00000000-0000-0000-0000-0000003300' || lpad(p_n::text, 2, '0'))::uuid, p_ref::text);
end $$;
-- Makes the next day of [p_k] due now.
create or replace function pg_temp.due(p_k text) returns void language sql as $$
  update public.mygig_booking_days set starts_at = now() + interval '10 minutes'
   where booking_id = pg_temp.id(p_k) and day_no = (select min(day_no) from public.mygig_booking_days
                                                    where booking_id = pg_temp.id(p_k) and status = 'scheduled');
$$;
create or replace function pg_temp.d1(p_sql text) returns jsonb language sql as $$
  select pg_temp.j('00000000-0000-0000-0000-0000000330d1', p_sql);
$$;
create or replace function pg_temp.d1v(p_sql text) returns text language sql as $$
  select pg_temp.value_as('00000000-0000-0000-0000-0000000330d1', p_sql);
$$;

select pg_temp.rule('{"dailyLimit": 50}');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330d1', 100, 'get_credit');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330d1', 0);

-- ---- 1. Settings ---------------------------------------------------------------------------------------
select pg_temp.check(public.mygig_settings_at('', '', '', '') @> '{"later": {"enabled": true, "aheadDays": 60},
  "hire": {"leadMin": {"trip": 30, "hourly": 60, "daily": 720, "weekly": 1440, "monthly": 2880}, "depositPct": 30,
           "nonApp": "link", "maxDays": 6, "maxWeeks": 4, "maxMonths": 3}}', 'the later and hire settings and their defaults');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000330e1',
  'update public.mygig_rules set settings = settings || ''{"hire": {"nonApp": "cash"}}'' where level = ''default'' returning 1')
  like 'MYGIG_SETTINGS_INVALID%', 'no "pay day by day" for passengers without the app');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000330e1',
  'update public.mygig_rules set settings = settings || ''{"hire": {"depositPct": 120}}'' where level = ''default'' returning 1')
  like 'MYGIG_SETTINGS_INVALID%', 'a deposit is 0 to 100%');
insert into public.mygig_rules (level, country, settings) values ('country', 'Gigland 330', '{"hire": {"maxDays": 3}}');
select pg_temp.check(public.mygig_settings_at('Gigland 330', '', '', '') @> '{"hire": {"maxDays": 3, "maxWeeks": 4, "depositPct": 30}}',
  'a region rule overrides only what it sets');
select pg_temp.check(not exists (select 1 from jsonb_object_keys(public.mygig_defaults()->'hire') k
                                  where k ilike '%cover%' or k ilike '%daybyday%' or k ilike '%writeoff%'),
  'no "covers" or "pay day by day" setting');

-- ---- 2. The driver's own hire rates -----------------------------------------------------------------------
select pg_temp.d1($q$select public.mygig_save_prefs('{"hire": {"own": true, "offer": {"monthly": true},
  "rates": {"hour": 500, "day": 380, "week": 2000, "month": 7500, "overtime": 50, "overnight": 1}}}', 3.11, 101.66)::text$q$);
select pg_temp.check((select prefs #> '{hire,rates}' from public.mygig_driver_prefs where driver_id = '00000000-0000-0000-0000-0000000330d1')
  @> '{"hour": 100, "day": 380, "week": 2000, "month": 7500, "overtime": 50, "overnight": 1}',
  'own rates kept within the admin''s limits (an hour at most RM100)');
select pg_temp.check(public.mygig_hire_card(public.mygig_settings_at('', '', '', ''),
  public.mygig_prefs_of('00000000-0000-0000-0000-0000000330d1', public.mygig_settings_at('', '', '', ''))) @> '{"own": true, "day": 380, "kmDay": 200}',
  'the hire card: the driver''s rates and get.ride''s km');
select pg_temp.rule('{"hire": {"allowOwnRates": false}}');
select pg_temp.check(public.mygig_hire_card(public.mygig_settings_at('', '', '', ''),
  public.mygig_prefs_of('00000000-0000-0000-0000-0000000330d1', public.mygig_settings_at('', '', '', ''))) @> '{"own": false, "day": 350}',
  'not allowed: get.ride''s myGiG hire rates');
select pg_temp.rule('{"hire": {"allowOwnRates": true}}');
select pg_temp.d1($q$select public.mygig_save_prefs('{"hire": {"own": false, "offer": {"monthly": false}}}', 3.11, 101.66)::text$q$);
select pg_temp.check((pg_temp.d1('select public.mygig_config(3.11, 101.66)::text')->'hireKinds') = '["hourly", "daily", "weekly"]',
  'the packages the driver offers');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.hire(), null, 'Ben', 'here',
  jsonb_build_object('kind', 'monthly', 'when', 'later', 'at', now() + interval '3 days', 'hoursPerDay', 10, 'periods', 1)))
  like 'MYGIG_HIRE_OFF%', 'a package the driver doesn''t offer can''t be sent');
select pg_temp.d1($q$select public.mygig_save_prefs('{"hire": {"own": false}}', 3.11, 101.66)::text$q$);
select pg_temp.rule('{"hire": {"packages": {"weekly": false}}}');
select pg_temp.check(not ((pg_temp.d1('select public.mygig_config(3.11, 101.66)::text')->'hireKinds') ? 'weekly'),
  'the admin switches a package off');
select pg_temp.rule('{"hire": {"packages": {"weekly": true}}}');

-- ---- 3. Lead times ---------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.trip(), null, 'Ben', 'here',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() - interval '5 minutes'))) like 'MYGIG_TIME_PASSED%',
  'a time that passed is refused');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.trip(), null, 'Ben', 'here',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '20 minutes'))) like 'MYGIG_TOO_SOON%',
  'a later ride at least 30 min ahead');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '20 minutes'),
  public.mygig_settings_at('', '', '', ''))->>'message' = 'A later ride must start at least 30 min from now.', 'with the reason');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'hourly', 'when', 'later', 'at', now() + interval '50 minutes'),
  public.mygig_settings_at('', '', '', ''))->>'message' = 'Hourly hire must start at least 1 hour from now.', 'hourly: 1 hour');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'daily', 'when', 'later', 'at', now() + interval '11 hours'),
  public.mygig_settings_at('', '', '', ''))->>'message' = 'Daily hire must start at least 12 hours from now.', 'daily: 12 hours');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'weekly', 'when', 'later', 'at', now() + interval '20 hours'),
  public.mygig_settings_at('', '', '', ''))->>'message' = 'Weekly hire must start at least 1 day from now.', 'weekly: 24 hours');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'monthly', 'when', 'later', 'at', now() + interval '47 hours'),
  public.mygig_settings_at('', '', '', ''))->>'message' = 'Monthly hire must start at least 2 days from now.', 'monthly: 48 hours');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '70 days'),
  public.mygig_settings_at('', '', '', ''))->>'code' = 'MYGIG_TOO_FAR_AHEAD', 'not too far ahead');
select pg_temp.check(public.mygig_when_problem(jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '2 hours'),
  public.mygig_settings_at('', '', '', '')) is null, 'two hours ahead is fine');
select pg_temp.rule('{"later": {"enabled": false}}');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.trip(), null, 'Ben', 'here',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '2 hours'))) like 'MYGIG_LATER_OFF%',
  'later bookings switched off');
select pg_temp.rule('{"later": {"enabled": true}}');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.hire(), null, 'Ben', 'here',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '2 days', 'days', 9, 'hoursPerDay', 10))) like 'MYGIG_HIRE_LIMIT%',
  'no more days than the admin allows');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.hire(), null, 'Ben', 'here',
  jsonb_build_object('kind', 'hourly', 'hours', 1))) like 'MYGIG_HIRE_LIMIT%', 'hourly: 2 to 12 hours');

-- ---- 4. Prices ---------------------------------------------------------------------------------------------
-- Hourly: 3 h × RM40, 60 km included; no drop-off.
insert into t values ('qh', null, pg_temp.quote(pg_temp.hire() || '{"booking": {"kind": "hourly", "hours": 3}}'));
select pg_temp.check((select v @> '{"hire": true, "kind": "hourly", "base": 120, "kmIncluded": 60, "overtimePerHour": 45, "days": 1}'
                             and (v->>'total')::numeric = (v #>> '{dateList,0,total}')::numeric
                             and (v #>> '{trip,directed}')::boolean and v #>> '{trip,drop,name}' = 'No drop-off · as directed'
                        from t where k = 'qh'), 'hourly: hours × the hour rate, as directed');
-- Daily: 2 days of 12 h at RM350 for 10 h = RM420 a day, one night RM80.
insert into t values ('qd', null, pg_temp.quote(pg_temp.hire() || jsonb_build_object('booking',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '2 days', 'days', 2, 'hoursPerDay', 12, 'overnight', true))));
select pg_temp.check((select v @> '{"days": 2, "base": 840, "nights": 1, "overnightTotal": 80, "kmIncluded": 400}'
                             and (v->>'total')::numeric = (v #>> '{dateList,0,total}')::numeric + (v #>> '{dateList,1,total}')::numeric
                             and (v #>> '{dateList,0,night}')::numeric = 80 and (v #>> '{dateList,1,night}')::numeric = 0
                        from t where k = 'qd'), 'daily: the day rate for the hours a day, a night between days');
-- Weekly: Mon to Fri, 10 h: RM1900 a week shared over its 5 days.
insert into t values ('qw', null, pg_temp.quote(pg_temp.hire() || jsonb_build_object('booking',
  jsonb_build_object('kind', 'weekly', 'at', now() + interval '3 days', 'periods', 1, 'hoursPerDay', 10, 'weekdays', '[1,2,3,4,5]'::jsonb))));
select pg_temp.check((select v @> '{"days": 5, "base": 1900, "perDay": 380, "kmIncluded": 1200}' from t where k = 'qw'),
  'weekly: the week''s rate over its working days');
-- 3 working days, 8 hours: 1900 × 8/10 × 3/5 = 912.
insert into t values ('qw3', null, pg_temp.quote(pg_temp.hire() || jsonb_build_object('booking',
  jsonb_build_object('kind', 'weekly', 'at', now() + interval '3 days', 'periods', 1, 'hoursPerDay', 8, 'weekdays', '[1,3,5]'::jsonb))));
select pg_temp.check((select v @> '{"days": 3, "base": 912}' from t where k = 'qw3'), 'pro rata to the days and hours');
-- Monthly: a public holiday on a working day is skipped (not driven, not charged).
insert into public.public_holidays (day, name, country)
select g::date, 'Gig Day 330', '' from generate_series(current_date + 5, current_date + 12, interval '1 day') g
 where extract(isodow from g) between 1 and 5 limit 1;
insert into t values ('qm', null, pg_temp.quote(pg_temp.hire() || jsonb_build_object('booking',
  jsonb_build_object('kind', 'monthly', 'at', now() + interval '3 days', 'periods', 1, 'hoursPerDay', 10))));
select pg_temp.check((select jsonb_array_length(v->'holidaysSkipped') = 1
                             and (v->>'base')::numeric = round(7200.0 / ((v->>'days')::int + 1), 2) * (v->>'days')::int
                        from t where k = 'qm'), 'monthly: a public holiday skipped and not charged');

-- ---- 5. How it is paid -----------------------------------------------------------------------------------
select pg_temp.check(public.mygig_booking_plan('{"kind": "trip", "when": "later"}', 'wallet', true, public.mygig_settings_at('', '', '', ''), 20)
  @> '{"plan": "start", "payNow": 0, "balance": 20, "balanceBy": "app"}', 'a later trip in the app: charged at the start');
select pg_temp.check(public.mygig_booking_plan('{"kind": "hourly", "when": "later"}', 'cash', false, public.mygig_settings_at('', '', '', ''), 120)
  @> '{"plan": "link_first", "payNow": 120, "payNowBy": "link", "pay": "link"}', 'hourly later without the app: by link first');
select pg_temp.check(public.mygig_booking_plan('{"kind": "hourly", "when": "now"}', 'cash', false, public.mygig_settings_at('', '', '', ''), 120)
  @> '{"plan": "now", "payNow": 0}', 'hourly now: as a myGiG ride');
select pg_temp.check(public.mygig_booking_plan('{"kind": "daily", "when": "later"}', 'wallet', true, public.mygig_settings_at('', '', '', ''), 1000)
  @> '{"plan": "deposit", "payNow": 300, "payNowBy": "app", "balance": 700, "balanceBy": "app"}', 'daily: a 30% deposit, the balance on day 1');
select pg_temp.check(public.mygig_booking_plan('{"kind": "daily", "when": "later"}', 'cash', false, public.mygig_settings_at('', '', '', ''), 1000)
  @> '{"plan": "deposit", "payNow": 300, "payNowBy": "link", "balanceBy": "cash"}', 'daily without the app: the deposit by link first');
select pg_temp.check(public.mygig_booking_plan('{"kind": "weekly", "when": "later"}', 'link', false, public.mygig_settings_at('', '', '', ''), 1900)
  @> '{"plan": "full", "payNow": 1900, "payNowBy": "link"}', 'weekly: in full, by link first');
select pg_temp.check(public.mygig_booking_plan('{"kind": "monthly", "when": "later"}', 'business', true, public.mygig_settings_at('', '', '', ''), 7000)
  @> '{"plan": "business", "payNow": 0}', 'business: on the account');
select pg_temp.rule('{"hire": {"nonApp": "no"}}');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.hire(), '0100330099', 'Ben Tamu', 'sms',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '2 days', 'days', 2, 'hoursPerDay', 10))) like 'MYGIG_HIRE_APP_ONLY%',
  'not offered: multi-day hire needs a passenger paying in the app');
select pg_temp.rule('{"hire": {"nonApp": "link"}}');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.hire(), null, 'Ben Tamu', 'here',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '2 days', 'days', 2, 'hoursPerDay', 10))) like 'MYGIG_PAY%',
  'a deposit by link needs the passenger''s phone');

-- ---- 6. A later trip in the app ---------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330a1', 100);
select pg_temp.book('b1', pg_temp.trip('{"pay": "wallet"}'), '10 033 0011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '3 hours'));
select pg_temp.check((select status = 'booked' and plan = 'start' and kind = 'trip' and days = 1 and app_paid = 0
                        from pg_temp.bk('b1')) and pg_temp.bal('00000000-0000-0000-0000-0000000330a1') = 100,
  'booked; nothing charged until the start');
select pg_temp.check((select status = 'accepted' and booking_id = pg_temp.id('b1') from public.mygig_offers
                       where id = (select offer_id from pg_temp.bk('b1'))), 'the offer became the booking');
select pg_temp.check(not exists (select 1 from public.ride_requests where mygig->>'bookingId' = pg_temp.id('b1')::text),
  'no ride until it starts');
select pg_temp.check((select jsonb_array_length(pg_temp.d1('select public.mygig_scheduled()::text')) = 1)
  and (pg_temp.d1('select public.mygig_config(3.11, 101.66)::text')->>'scheduledCount')::int = 1,
  'in Scheduled myGiG, counted on the home button');
select pg_temp.check((select jsonb_array_length(pg_temp.j('00000000-0000-0000-0000-0000000330a1', 'select public.mygig_my_bookings()::text')) = 1),
  'and in the passenger''s app');
select pg_temp.check(pg_temp.d1v(pg_temp.send_sql(pg_temp.trip('{"pay": "wallet"}'), '10 033 0011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '3 hours 30 minutes'))) like 'MYGIG_CLASH%',
  'a booking at the same time clashes');
select pg_temp.check(pg_temp.d1v(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b1'))) like 'MYGIG_NOT_YET%',
  'Start only when due');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000330d2', format('select public.mygig_booking_start(%L)::text', pg_temp.id('b1')))
  like 'MYGIG_NOT_FOUND%', 'only its driver starts it');
-- The reminder to both.
update public.mygig_booking_days set starts_at = now() + interval '30 minutes' where booking_id = pg_temp.id('b1');
select public.mygig_bookings_tick();
select pg_temp.check((select count(*) from public.notification_outbox where event_id = 'mygig-remind-' || pg_temp.id('b1') || '-1') = 1
  and exists (select 1 from public.notification_outbox where event_id = 'mygig-bk-remind1-' || pg_temp.id('b1')
                and profile_id = '00000000-0000-0000-0000-0000000330a1'), 'both reminded before');
select pg_temp.due('b1');
insert into t values ('r1', (pg_temp.d1(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b1')))->>'rideId')::uuid, null);
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000330a1') = 100 - (select price from pg_temp.bk('b1'))
  and (select app_paid = price and allocated_amount = price and status = 'in_progress' from pg_temp.bk('b1')),
  'charged in the app at the start; the day given its share');
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000330d1' and rider_id = '00000000-0000-0000-0000-0000000330a1'
                             and (mygig->>'prepaid')::numeric = public.ride_amount_due(r) and hire_package is null
                        from pg_temp.ride(pg_temp.id('r1')) r), 'a ride with the driver, already paid for');
select pg_temp.check((pg_temp.d1(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b1')))->>'resumed')::boolean,
  'Start again opens the day going');
select pg_temp.d1(format('select public.mygig_arrived(%L)::text', pg_temp.id('r1')));
select pg_temp.d1(format('select public.mygig_start(%L)::text', pg_temp.id('r1')));
insert into t values ('c1', null, pg_temp.d1(format('select public.mygig_complete(%L, 3)::text', pg_temp.id('r1'))));
select pg_temp.check((select (v->>'needsPayment')::boolean is false from t where k = 'c1')
  and (select payment_status = 'paid' and (mygig->>'appPaid')::numeric = 3 from pg_temp.ride(pg_temp.id('r1')))
  and pg_temp.bal('00000000-0000-0000-0000-0000000330d1') = (select price from pg_temp.bk('b1')) + 3,
  'tolls charged in the app; the driver paid the booking''s share and the tolls');
select pg_temp.check((select status = 'completed' from pg_temp.bk('b1'))
  and (select status = 'completed' from public.mygig_booking_days where booking_id = pg_temp.id('b1')),
  'the booking ends with its day');

-- ---- 7. A daily hire, by link and cash ---------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330d1', 0);
select pg_temp.book('b2', pg_temp.hire(), '0100330099', 'Ben Tamu', 'sms',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '2 days', 'days', 2, 'hoursPerDay', 10));
select pg_temp.check((select status = 'awaiting_payment' and plan = 'deposit' and pay = 'cash' and pay_now = round(price * 0.3, 2)
                             and pay_until is not null and rider_id is null from pg_temp.bk('b2')),
  'waiting for the deposit by link before it is confirmed');
select pg_temp.check(pg_temp.d1v(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b2'))) like 'MYGIG_PAY_FIRST%',
  'not started before it is confirmed');
select pg_temp.check((pg_temp.j(null, format('select public.mygig_link_view(%L)::text', (select v->>'token' from t where k = 'b2')))
  #>> '{booking,status}') = 'awaiting_payment', 'the trip link shows the booking');
select pg_temp.check((select h.package = 'daily' and h.partner_id = '00000000-0000-0000-0000-0000000330d1' and h.rider_id is null
                             and h.mygig_booking_id = b.id and h.price = b.price
                        from public.hire_bookings h join pg_temp.bk('b2') b on b.hire_booking_id = h.id),
  'a hire_bookings row, for Admin › Hire bookings');
select pg_temp.check(pg_temp.d1v(format('select public.payment_mygig_link_allowed(%L)::text', pg_temp.id('b2'))) in ('true', 'false'),
  'the driver may ask for its link');
select pg_temp.link_pay(pg_temp.id('b2'), (select pay_now from pg_temp.bk('b2')), 1);
select public.payment_ride_card_paid('00000000-0000-0000-0000-000000330001', pg_temp.id('b2')::text);
select pg_temp.check((select status = 'booked' and link_paid = pay_now and link_left = pay_now from pg_temp.bk('b2'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000330d1') = 0, 'confirmed when the deposit is paid, once; get.ride holds it');
select pg_temp.check((select payment_state = 'deposit_paid' and status = 'assigned' from public.hire_bookings
                       where id = (select hire_booking_id from pg_temp.bk('b2'))), 'the hire row follows');
-- Day 1: the balance before it starts.
select pg_temp.due('b2');
select pg_temp.check(pg_temp.d1v(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b2'))) like 'MYGIG_BALANCE_FIRST%',
  'the balance first: by link or cash');
select pg_temp.check((pg_temp.d1(format('select public.mygig_booking_cash(%L)::text', pg_temp.id('b2')))->>'cash')::numeric
  = (select price - pay_now from pg_temp.bk('b2')), 'the driver confirms the balance in cash');
insert into t values ('r2', (pg_temp.d1(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b2')))->>'rideId')::uuid, null);
select pg_temp.check((select r.hire_package = 'daily' and r.hire_day_no = 1 and r.hire_hours = 10 and r.hire_km_included = 200
                             and r.hire_overtime_rate = 45 and r.hire_extra_km_rate = 1
                             and r.hire_booking_id = (select hire_booking_id from pg_temp.bk('b2'))
                             and (r.mygig->>'cashPaid')::numeric + (r.mygig->>'prepaid')::numeric = public.ride_amount_due(r)
                             and public.family_ride_module(r) = 'mygig'
                        from pg_temp.ride(pg_temp.id('r2')) r), 'day 1 released: the hire''s columns, its share (cash first)');
select pg_temp.check((select (b->>'dayText') = 'Day 1 of 2' and b->>'rideId' = pg_temp.id('r2')::text
                        from jsonb_array_elements(pg_temp.d1('select public.mygig_scheduled()::text')) b
                       where b->>'id' = pg_temp.id('b2')::text), 'Scheduled myGiG: day 1 of 2, going');
select pg_temp.d1(format('select public.mygig_start(%L)::text', pg_temp.id('r2')));
-- 11 hours used (an hour over), 230 km (30 over).
update public.ride_requests set hire_started_at = now() - interval '11 hours' where id = pg_temp.id('r2');
insert into t values ('c2', null, pg_temp.d1(format('select public.mygig_hire_end(%L, 230)::text', pg_temp.id('r2'))));
select pg_temp.check((select (v->>'needsPayment')::boolean and (v->>'owed')::numeric >= 45 + 30 from t where k = 'c2')
  and (select status = 'on_trip' from pg_temp.ride(pg_temp.id('r2'))), 'overtime and extra km paid before the day ends');
select pg_temp.check((select v #>> '{final,hireExtra,overtimeMinutes}' = '60' and (v #>> '{final,hireExtra,extraKm}')::numeric = 30
                        from t where k = 'c2'), 'an hour''s overtime and 30 km over');
select pg_temp.d1(format('select public.mygig_take_cash(%L)::text', pg_temp.id('r2')));
insert into t values ('c2b', null, pg_temp.d1(format('select public.mygig_hire_end(%L, 230)::text', pg_temp.id('r2'))));
select pg_temp.check((select status = 'completed' and payment_status = 'paid' and hire_settled->>'mygig' = 'true'
                             and jsonb_array_length(hire_settled->'lines') = 3 from pg_temp.ride(pg_temp.id('r2'))),
  'cash taken: the day ends, its hire lines settled');
select pg_temp.check((select status = 'in_progress' from pg_temp.bk('b2'))
  and (select status from public.mygig_booking_days where booking_id = pg_temp.id('b2') and day_no = 2) = 'scheduled'
  and pg_temp.bal('00000000-0000-0000-0000-0000000330d1') = (select (mygig->>'prepaid')::numeric from pg_temp.ride(pg_temp.id('r2'))),
  'day 2 stays in Scheduled myGiG; the driver paid the day''s non-cash share');
select pg_temp.check((select (b->>'dayText') = 'Day 2 of 2' from jsonb_array_elements(pg_temp.d1('select public.mygig_scheduled()::text')) b
                       where b->>'id' = pg_temp.id('b2')::text), 'next: day 2 of 2');
-- Day 2: nothing more to pay; the passenger doesn't come: the driver keeps the day.
select pg_temp.due('b2');
insert into t values ('r2b', (pg_temp.d1(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b2')))->>'rideId')::uuid, null);
select pg_temp.check((select hire_day_no = 2 and public.mygig_owed(r) = 0 from pg_temp.ride(pg_temp.id('r2b')) r), 'day 2 is paid for');
select pg_temp.d1(format('select public.mygig_arrived(%L)::text', pg_temp.id('r2b')));
update public.ride_requests set arrived_at = now() - interval '30 minutes' where id = pg_temp.id('r2b');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330d1', 0);
select pg_temp.d1(format('select public.mygig_no_show(%L)::text', pg_temp.id('r2b')));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000330d1') > 0
  and (select status = 'completed' and kept_amount > 0 from pg_temp.bk('b2'))
  and (select status = 'completed' from public.hire_bookings where id = (select hire_booking_id from pg_temp.bk('b2'))),
  'no-show on a paid day: the driver keeps it; the booking and its hire row end');

-- ---- 8. Weekly in the app; monthly on a business account -----------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330a1', 3000);
select pg_temp.book('b3', pg_temp.hire('{"pay": "wallet"}'), '10 033 0011', null, 'app',
  jsonb_build_object('kind', 'weekly', 'at', now() + interval '10 days', 'periods', 1, 'hoursPerDay', 10));
select pg_temp.check((select status = 'booked' and plan = 'full' and app_paid = price and price > 0 from pg_temp.bk('b3'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000330a1') = 3000 - (select price from pg_temp.bk('b3')),
  'weekly: paid in full in the app when accepted');
insert into public.business_accounts (id, name, reg_no, status) values
  ('00000000-0000-0000-0000-0000000330b9', 'Gig Corp 330', '203001033000', 'active');
insert into public.business_members (account_id, profile_id, phone, name, role, status) values
  ('00000000-0000-0000-0000-0000000330b9', '00000000-0000-0000-0000-0000000330a2', '+60100330012', 'Ravi', 'rider', 'active');
select pg_temp.book('b4', pg_temp.hire('{"pay": "business", "businessId": "00000000-0000-0000-0000-0000000330b9"}'), '10 033 0012', null,
  'here', jsonb_build_object('kind', 'weekly', 'at', now() + interval '20 days', 'periods', 1, 'hoursPerDay', 8));
select pg_temp.check((select status = 'booked' and plan = 'business' and pay_now = 0 and public.mygig_booking_due(b) = 0
                        from pg_temp.bk('b4') b), 'business: nothing upfront, on the monthly invoice');
select pg_temp.due('b4');
insert into t values ('r4', (pg_temp.d1(format('select public.mygig_booking_start(%L)::text', pg_temp.id('b4')))->>'rideId')::uuid, null);
select pg_temp.check((select business_account_id = '00000000-0000-0000-0000-0000000330b9' and hire_package = 'weekly'
                             and coalesce((mygig->>'prepaid')::numeric, 0) = 0
                        from pg_temp.ride(pg_temp.id('r4'))), 'each day is a business ride');
insert into t values ('x4', null, pg_temp.j('00000000-0000-0000-0000-0000000330a2',
  format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b4'))));
select pg_temp.check((select status = 'cancelled' and cancelled_by = 'passenger' from pg_temp.bk('b4'))
  and (select status = 'cancelled' from pg_temp.ride(pg_temp.id('r4'))), 'the passenger cancels; the day released but not started ends too');

-- ---- 9. Cancelling ----------------------------------------------------------------------------------------
-- Free before the free-cancel time: everything back to the GET.wallet.
insert into t values ('x3', null, pg_temp.j('00000000-0000-0000-0000-0000000330a1',
  format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b3'))));
select pg_temp.check((select (v->>'kept')::numeric = 0 from t where k = 'x3') and pg_temp.bal('00000000-0000-0000-0000-0000000330a1') = 3000
  and (select status = 'cancelled' and cancelled_by = 'passenger' from pg_temp.bk('b3'))
  and (select status = 'cancelled' and cancelled_by = 'rider' from public.hire_bookings where id = (select hire_booking_id from pg_temp.bk('b3'))),
  'cancelled in time: free, refunded');
-- After it: the deposit is kept for the driver.
select pg_temp.book('b5', pg_temp.hire('{"pay": "wallet"}'), '10 033 0011', null, 'app',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '2 days', 'days', 3, 'hoursPerDay', 8));
select pg_temp.check((select app_paid = pay_now and pay_now = round(price * 0.3, 2) from pg_temp.bk('b5')), 'the deposit in the app');
update public.mygig_bookings set free_cancel_until = now() - interval '1 minute' where id = pg_temp.id('b5');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330d1', 0);
insert into t values ('x5', null, pg_temp.j('00000000-0000-0000-0000-0000000330a1',
  format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b5'))));
select pg_temp.check((select (v->>'kept')::numeric = (select pay_now from pg_temp.bk('b5')) from t where k = 'x5')
  and pg_temp.bal('00000000-0000-0000-0000-0000000330d1') = (select pay_now from pg_temp.bk('b5'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000330a1') = 3000 - (select pay_now from pg_temp.bk('b5')),
  'late: the deposit kept, paid to the driver');
-- The driver cancels: everything back, even late; a link payment as refundDue.
select pg_temp.book('b6', pg_temp.hire(), '0100330098', 'Cik Tamu', 'sms',
  jsonb_build_object('kind', 'hourly', 'when', 'later', 'at', now() + interval '5 days', 'hours', 4));
select pg_temp.check((select plan = 'link_first' and pay = 'link' and status = 'awaiting_payment' from pg_temp.bk('b6')),
  'hourly later without the app: by link first');
select pg_temp.link_pay(pg_temp.id('b6'), (select pay_now from pg_temp.bk('b6')), 2);
update public.mygig_bookings set free_cancel_until = now() - interval '1 minute' where id = pg_temp.id('b6');
select pg_temp.d1(format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b6')));
select pg_temp.check((select status = 'cancelled' and cancelled_by = 'driver' and kept_amount = 0 and refund_due = link_paid
                        from pg_temp.bk('b6')), 'the driver cancels: all of it back to the passenger');
-- The passenger cancels on the trip link (no sign-in).
select pg_temp.book('b7', pg_temp.hire(), '0100330097', 'Dee Tamu', 'sms',
  jsonb_build_object('kind', 'hourly', 'when', 'later', 'at', now() + interval '6 days', 'hours', 2));
select pg_temp.check((pg_temp.j(null, format('select public.mygig_booking_cancel(null, %L)::text', (select v->>'token' from t where k = 'b7')))
  ->>'by') = 'passenger', 'cancelled on the trip link');
-- Not paid in time: the booking ends.
select pg_temp.book('b8', pg_temp.hire(), '0100330096', 'Eve Tamu', 'sms',
  jsonb_build_object('kind', 'weekly', 'at', now() + interval '30 days', 'periods', 1, 'hoursPerDay', 10));
update public.mygig_bookings set pay_until = now() - interval '1 minute' where id = pg_temp.id('b8');
select public.mygig_bookings_tick();
select pg_temp.check((select status = 'expired' from pg_temp.bk('b8')), 'not paid in time: ended, nothing saved');
-- 0328's cancel goes through myGiG's.
select pg_temp.book('b9', pg_temp.hire('{"pay": "wallet"}'), '10 033 0011', null, 'app',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '40 days', 'days', 1, 'hoursPerDay', 10));
select pg_temp.j('00000000-0000-0000-0000-0000000330a1',
  format('select to_jsonb(public.hire_booking_cancel(%L))::text', (select hire_booking_id from pg_temp.bk('b9'))));
select pg_temp.check((select status = 'cancelled' from pg_temp.bk('b9')), 'Hire bookings'' cancel cancels the myGiG booking');

-- ---- 10. Family -------------------------------------------------------------------------------------------
select pg_temp.value_as('00000000-0000-0000-0000-0000000330f1',
  $q$select public.family_invite('{}', '+60100330011', 'Aisha', 'sister')->>'id'$q$);
insert into t select 'm', id, null from public.family_members
 where family_id = (select id from public.families where host_id = '00000000-0000-0000-0000-0000000330f1');
select pg_temp.value_as('00000000-0000-0000-0000-0000000330a1',
  format('select public.family_respond(%L, true, ''{"shown": ["payments"]}'')', pg_temp.id('m')));
insert into public.family_module_rules (level, module_key, family_pays, book_for_member, child_allowed, live_share)
values ('default', 'mygig', true, false, false, true)
on conflict (place_key, module_key) do update set family_pays = true;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330f1', 5000);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000330a1', 0);
select pg_temp.book('b10', pg_temp.hire('{"pay": "family"}'), '10 033 0011', null, 'app',
  jsonb_build_object('kind', 'daily', 'at', now() + interval '3 days', 'days', 1, 'hoursPerDay', 8));
select pg_temp.check((select module_key = 'mygig' and family_pays from public.family_trips where trip_id = pg_temp.id('b10'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000330f1') = 5000 - (select pay_now from pg_temp.bk('b10'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000330a1') = 0, 'the deposit from the host''s GET.wallet (module mygig)');
select pg_temp.j('00000000-0000-0000-0000-0000000330a1', format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b10')));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000330f1') = 5000, 'refunded to the host');

-- ---- 11. Hourly hire now ------------------------------------------------------------------------------------
insert into t values ('o11', null, pg_temp.d1(pg_temp.send_sql(pg_temp.hire(), '0100330095', 'Fay Tamu', 'here',
  '{"kind": "hourly", "hours": 2}')));
insert into t values ('r11', (pg_temp.d1(format('select public.mygig_accept_here(%L)::text', (select v->>'offerId' from t where k = 'o11')))
  ->>'rideId')::uuid, null);
select pg_temp.check((select hire_package = 'hourly' and hire_hours = 2 and hire_km_included = 40 and mygig ? 'hire'
                             and drop_name = 'No drop-off · as directed' and status = 'accepted'
                        from pg_temp.ride(pg_temp.id('r11'))), 'hourly now: a myGiG ride with the hire''s terms');
select pg_temp.d1(format('select public.mygig_start(%L)::text', pg_temp.id('r11')));
select pg_temp.check((select hire_started_at is not null and hire_ends_at is not null from pg_temp.ride(pg_temp.id('r11'))),
  'the hire clock runs');
select pg_temp.d1(format('select public.hire_end(%L, 10)::text', pg_temp.id('r11')));
select pg_temp.check((select status = 'completed' and hire_km_used = 10 and fare > 0 from pg_temp.ride(pg_temp.id('r11'))),
  '0326''s End hire ends it with myGiG''s money');

-- ---- Who reads what -------------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000330d2', 'select count(*)::text from public.mygig_bookings') = '0',
  'another driver reads none of these bookings');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000330a1',
  'update public.mygig_bookings set price = 1 returning 1') not in ('1'), 'nobody writes a booking from the app');

rollback;
