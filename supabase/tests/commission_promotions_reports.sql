-- ============================================================================
-- Regression test for migration 0224: commission promotions (a lower rate
-- for a time, a place, a service, days and hours, or new drivers), the
-- commission reports, the drivers under the GET.credit floor, and meter
-- hires on the Earnings page and statements.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/commission_promotions_reports.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000224a1'),  -- rider
  ('00000000-0000-0000-0000-0000000224b1'),  -- driver, joined 100 days ago
  ('00000000-0000-0000-0000-0000000224b2'),  -- driver, joined 5 days ago
  ('00000000-0000-0000-0000-0000000224c1'),  -- admin (edit)
  ('00000000-0000-0000-0000-0000000224c2')   -- admin (view only)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000224%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000224c1', 'admin-settings-commission', 'edit'),
  ('00000000-0000-0000-0000-0000000224c2', 'admin-settings-commission', 'read');
insert into public.partners (auth_user_id, name, phone, status, joined_at) values
  ('00000000-0000-0000-0000-0000000224b1', 'Old Driver', '60120000224', 'approved', now() - interval '100 days'),
  ('00000000-0000-0000-0000-0000000224b2', 'New Driver', '60120000225', 'approved', now() - interval '5 days');

delete from public.commission_rates;
delete from public.commission_tiers;
delete from public.commission_promotions;
insert into public.commission_rates (level, rate) values ('master', 0.20);
-- Everyone meets this tier: 15%.
insert into public.commission_tiers (id, name, metric, window_days, threshold, adjust, value) values
  ('00000000-0000-0000-0000-0000000224d1', 'Everyone', 'trips', 7, 0, 'rate', 0.15);
update public.app_settings
   set value = value || '{"meterCommission": true, "baseTolls": false, "baseSurcharges": [],
                          "allowNegativeCredit": true, "negativeLimit": 10}'
 where key = 'commission';

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

create or replace function pg_temp.refused(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
declare n int;
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

-- A rate for an old driver's car trip in Kajang at [p_at] (Malaysia), or wherever given.
create or replace function pg_temp.promo(p_at timestamptz, p_tz text default null, p_service text default 'car',
                                         p_uid uuid default '00000000-0000-0000-0000-0000000224b1',
                                         p_city text default 'Kajang', p_rate numeric default 0.15,
                                         p_level text default 'master')
returns table (rate numeric, promotion_id uuid) language sql as $$
  select * from public.commission_apply_promotions(p_uid, p_rate, p_level, p_at, p_tz, p_service,
                                                   null, null, 'Malaysia', 'Selangor', p_city, null);
$$;

create or replace function pg_temp.hire(p_id text, p_ago interval default interval '1 hour') returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p_id,
    'startedAt', (extract(epoch from now() - p_ago - interval '20 minutes') * 1000)::bigint,
    'endedAt', (extract(epoch from now() - p_ago) * 1000)::bigint,
    'distanceM', 8400, 'elapsedMs', 1200000, 'waitingMs', 60000,
    'rateLabel', 'Kuala Lumpur', 'period', 'day', 'currency', 'RM',
    'fare', 20, 'extra', 5, 'airportSurcharge', 3, 'cardSurcharge', 2, 'total', 30,
    'pickup', jsonb_build_object('at', 0, 'latitude', 3.15, 'longitude', 101.71, 'place', 'KLCC'),
    'dropoff', jsonb_build_object('at', 0, 'latitude', 3.13, 'longitude', 101.68, 'place', 'Mid Valley'),
    'plate', 'WXY 224');
$$;

grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text),
  pg_temp.hire(text, interval) to authenticated, anon;

-- 1. Only an editing admin writes promotions; only admins read them --------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000224c2');
select pg_temp.refused(
  $q$insert into public.commission_promotions (name, rate, starts_at, ends_at)
     values ('x', 0.05, now(), now() + interval '1 day')$q$,
  'a view-only admin adding a promotion');

select pg_temp.as_user('00000000-0000-0000-0000-0000000224c1');
insert into public.commission_promotions (id, name, rate, starts_at, ends_at, country, state, city, services,
                                          weekdays, time_from, time_to, new_driver_days, active) values
  -- Running, Kajang only.
  ('00000000-0000-0000-0000-0000000224e1', 'Kajang week', 0.10, now() - interval '1 day', now() + interval '1 day',
   'Malaysia', ' ', 'Kajang', null, null, null, null, null, true),
  -- Not yet running.
  ('00000000-0000-0000-0000-0000000224e2', 'Next week', 0.01, now() + interval '1 day', now() + interval '2 days',
   null, null, null, null, null, null, null, null, true),
  -- Higher than the rate: never chosen.
  ('00000000-0000-0000-0000-0000000224e3', 'Raise', 0.30, now() - interval '1 day', now() + interval '1 day',
   null, null, null, null, null, null, null, null, true),
  -- New drivers: their first 30 days.
  ('00000000-0000-0000-0000-0000000224e4', 'Welcome', 0.05, now() - interval '1 day', now() + interval '1 day',
   null, null, null, null, null, null, null, 30, true),
  -- Meter hires only.
  ('00000000-0000-0000-0000-0000000224e5', 'Meter month', 0.08, now() - interval '1 day', now() + interval '1 day',
   null, null, null, array['METER', ' meter '], null, null, null, null, true),
  -- Turned off.
  ('00000000-0000-0000-0000-0000000224e6', 'Off', 0, now() - interval '1 day', now() + interval '1 day',
   null, null, null, null, null, null, null, null, false),
  -- Weekday mornings in 2020.
  ('00000000-0000-0000-0000-0000000224e7', 'Mornings', 0.03, '2020-01-01 00:00+08', '2021-01-01 00:00+08',
   null, null, null, null, array[1, 2, 3, 4, 5]::smallint[], '07:00', '10:00', null, true),
  -- Nights in 2020, past midnight.
  ('00000000-0000-0000-0000-0000000224e8', 'Nights', 0.04, '2020-01-01 00:00+08', '2021-01-01 00:00+08',
   null, null, null, null, null, '22:00', '06:00', null, true);
select pg_temp.check(
  (select services = array['meter'] and state is null
     from public.commission_promotions where id = '00000000-0000-0000-0000-0000000224e5')
  and (select state is null from public.commission_promotions where id = '00000000-0000-0000-0000-0000000224e1'),
  'services are kept once, lower case; a blank place is no place');
select pg_temp.check((select count(*) = 8 from public.commission_rate_history where op = 'promo:insert'),
  'promotion changes are in the history');
select pg_temp.refused(
  $q$insert into public.commission_promotions (name, rate, starts_at, ends_at) values ('Backwards', 0.05, now(), now() - interval '1 hour')$q$,
  'a promotion ending before it starts');

select pg_temp.as_user('00000000-0000-0000-0000-0000000224b1');
select pg_temp.check((select count(*) = 0 from public.commission_promotions), 'a driver reads no promotions');
select pg_temp.refused(
  $q$update public.commission_promotions set rate = 0 where id = '00000000-0000-0000-0000-0000000224e1'$q$,
  'a driver changing a promotion');
reset role;

-- 2. Which promotion applies --------------------------------------------------------------------
select pg_temp.check((select rate = 0.10 and promotion_id = '00000000-0000-0000-0000-0000000224e1' from pg_temp.promo(now())),
  'in Kajang, while it runs, the Kajang promotion lowers 15% to 10%');
select pg_temp.check((select rate = 0.15 and promotion_id is null from pg_temp.promo(now(), p_city => 'Bangi')),
  'outside its city it does not apply; the 30% one never raises it');
select pg_temp.check((select rate = 0.15 and promotion_id is null from pg_temp.promo(now() - interval '2 days')),
  'before it starts it does not apply');
select pg_temp.check((select rate = 0.05 and promotion_id = '00000000-0000-0000-0000-0000000224e4'
                        from pg_temp.promo(now(), p_uid => '00000000-0000-0000-0000-0000000224b2')),
  'a driver who joined 5 days ago gets the new-driver rate; the lowest wins');
select pg_temp.check((select rate = 0.15 from pg_temp.promo(now(), p_city => 'Bangi', p_uid => null)),
  'no driver: no new-driver promotion');
select pg_temp.check((select rate = 0.08 and promotion_id = '00000000-0000-0000-0000-0000000224e5'
                        from pg_temp.promo(now(), p_service => 'meter', p_city => 'Bangi')),
  'a meter-only promotion for a meter hire');
select pg_temp.check((select rate = 0.25 and promotion_id is null from pg_temp.promo(now(), p_rate => 0.25, p_level => 'user')),
  'a personal rate is not lowered, as with tiers');
select pg_temp.check((select rate = 0.05 and promotion_id is null from pg_temp.promo(now(), p_rate => 0.05)),
  'a promotion no lower than the rate leaves it (and the tier) as it is');

-- Days and hours, in the ride's time zone. 1 June 2020 was a Monday.
select pg_temp.check((select rate = 0.03 from pg_temp.promo('2020-06-01 08:00+08')), 'Monday 08:00: mornings');
select pg_temp.check((select rate = 0.15 from pg_temp.promo('2020-06-01 11:00+08')), 'Monday 11:00: nothing');
select pg_temp.check((select rate = 0.15 from pg_temp.promo('2020-06-06 08:00+08')), 'Saturday 08:00: not a weekday');
select pg_temp.check((select rate = 0.15 from pg_temp.promo('2020-06-01 08:00+08', 'Europe/London')),
  '08:00 in Malaysia is 01:00 in London');
select pg_temp.check((select rate = 0.03 from pg_temp.promo('2020-06-01 15:00+08', 'Europe/London')),
  '15:00 in Malaysia is 08:00 in London');
select pg_temp.check((select rate = 0.03 from pg_temp.promo('2020-06-01 08:00+08', 'Not/AZone')),
  'an unknown time zone counts as Malaysia''s');
select pg_temp.check((select rate = 0.04 from pg_temp.promo('2020-06-01 23:30+08'))
                     and (select rate = 0.04 from pg_temp.promo('2020-06-02 05:00+08'))
                     and (select rate = 0.15 from pg_temp.promo('2020-06-02 12:00+08')),
  'a night window runs past midnight');

-- 3. Locked at accept with the promotion; charged at it -----------------------------------------
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, state, city, service) values
  ('00000000-0000-0000-0000-0000000224f1', '00000000-0000-0000-0000-0000000224a1', 'open', 50, 50, 'Malaysia', 'Selangor', 'Kajang', 'car'),
  ('00000000-0000-0000-0000-0000000224f2', '00000000-0000-0000-0000-0000000224a1', 'open', 50, 50, 'Malaysia', 'Selangor', 'Bangi', 'car'),
  ('00000000-0000-0000-0000-0000000224f3', '00000000-0000-0000-0000-0000000224a1', 'open', 50, 50, 'Malaysia', 'Selangor', 'Kajang', 'car');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000224b1', accepted_at = now()
 where id in ('00000000-0000-0000-0000-0000000224f1', '00000000-0000-0000-0000-0000000224f2');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000224b2', accepted_at = now()
 where id = '00000000-0000-0000-0000-0000000224f3';
select pg_temp.check(
  (select commission_rate = 0.10 and commission_base_rate = 0.20 and commission_tier_id is null
          and commission_promotion_id = '00000000-0000-0000-0000-0000000224e1'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000224f1'),
  'Kajang: the promotion is locked with the rate, and replaces the tier');
select pg_temp.check(
  (select commission_rate = 0.15 and commission_tier_id = '00000000-0000-0000-0000-0000000224d1'
          and commission_promotion_id is null
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000224f2'),
  'Bangi: no promotion, the tier stays');
select pg_temp.check(
  (select commission_rate = 0.05 and commission_promotion_id = '00000000-0000-0000-0000-0000000224e4'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000224f3'),
  'the new driver: the welcome rate');

-- A promotion turned off after the accept does not change the trip.
update public.commission_promotions set active = false where id = '00000000-0000-0000-0000-0000000224e1';
update public.ride_requests set status = 'completed', completed_at = now()
 where id::text like '00000000-0000-0000-0000-0000000224f%';
update public.commission_promotions set active = true where id = '00000000-0000-0000-0000-0000000224e1';
select pg_temp.check(
  (select commission_amount = 5 from public.ride_requests where id = '00000000-0000-0000-0000-0000000224f1')
  and (select commission_amount = 7.5 from public.ride_requests where id = '00000000-0000-0000-0000-0000000224f2')
  and (select commission_amount = 2.5 from public.ride_requests where id = '00000000-0000-0000-0000-0000000224f3'),
  'charged at the locked rates: 10%, 15% and 5% of 50');

-- 4. Meter hires get promotions -----------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000224b1');
select pg_temp.check(
  (select (r->>'charged')::boolean and (r->>'amount')::numeric = 1.60
     from public.meter_trip_record(pg_temp.hire('00000000-0000-0000-0000-0000000224f9')) r),
  'a meter hire: 8% of the fare 20');
reset role;
select pg_temp.check(
  (select commission_promotion_id = '00000000-0000-0000-0000-0000000224e5' and commission_tier_id is null
     from public.meter_trips where id = '00000000-0000-0000-0000-0000000224f9'),
  'the hire records the promotion');

-- 5. Reports --------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000224b1');
select pg_temp.refused($q$select * from public.admin_commission_report(now() - interval '1 day', now() + interval '1 day', 'day')$q$,
  'a driver reading the report', '%Only an admin%');
select pg_temp.refused($q$select * from public.admin_drivers_below_credit()$q$,
  'a driver reading who is under the floor', '%Only an admin%');

select pg_temp.as_user('00000000-0000-0000-0000-0000000224c2');
select pg_temp.refused($q$select * from public.admin_commission_report(now(), now() - interval '1 day', 'day')$q$,
  'a range ending before it starts', '%COMMISSION_REPORT%');
select pg_temp.refused($q$select * from public.admin_commission_report(now() - interval '1 day', now(), 'year')$q$,
  'an unknown grouping', '%COMMISSION_REPORT%');
select pg_temp.check(
  (select trips = 2 and meter_trips = 1 and commission = 14.10 and label = 'Old Driver' and base_amount = 120
     from public.admin_commission_report(now() - interval '1 day', now() + interval '1 day', 'driver')
    where group_key = '00000000-0000-0000-0000-0000000224b1'),
  'by driver: two trips and a meter hire, 5 + 7.50 + 1.60');
select pg_temp.check(
  (select commission = 2.5 from public.admin_commission_report(now() - interval '1 day', now() + interval '1 day', 'driver')
    where group_key = '00000000-0000-0000-0000-0000000224b2'),
  'by driver: the new driver');
select pg_temp.check(
  (select commission = 7.5 and trips = 2 and detail = 'Selangor, Malaysia'
     from public.admin_commission_report(now() - interval '1 day', now() + interval '1 day', 'city')
    where label = 'Kajang'),
  'by city: Kajang''s two trips, 5 + 2.50');
select pg_temp.check(
  (select sum(commission) = 16.60 and sum(trips) = 3 and sum(meter_trips) = 1
     from public.admin_commission_report(now() - interval '1 day', now() + interval '1 day', 'month')),
  'by month: everything charged');
select pg_temp.check(
  (select count(*) = 0 from public.admin_commission_report(now() - interval '10 days', now() - interval '9 days', 'week')),
  'nothing charged in another range');

-- Under the floor (RM -10): the old driver at RM -14.10, not the new one at RM -2.50.
select pg_temp.check(
  (select balance = -14.10 and credit_floor = -10 and name = 'Old Driver'
     from public.admin_drivers_below_credit() where partner_id = '00000000-0000-0000-0000-0000000224b1'),
  'the old driver is under the floor');
select pg_temp.check(
  (select count(*) = 0 from public.admin_drivers_below_credit() where partner_id = '00000000-0000-0000-0000-0000000224b2'),
  'the new driver is not');
reset role;

-- 6. Meter hires on the Earnings page and statements ---------------------------------------------
select pg_temp.check(
  (select (l->>'fare')::numeric = 20 and (l->>'tolls')::numeric = 5 and (l->>'surchargesPass')::numeric = 5
          and (l->>'surcharges')::numeric = 0 and (l->>'commission')::numeric = 1.6 and (l->>'cash')::numeric = 30
     from (select public.statement_meter_lines(m, '{}') l from public.meter_trips m
            where m.id = '00000000-0000-0000-0000-0000000224f9') s)
  and (select (l->>'surcharges')::numeric = 3 and (l->>'surchargesPass')::numeric = 2
         from (select public.statement_meter_lines(m, array['Airport surcharge']) l from public.meter_trips m
                where m.id = '00000000-0000-0000-0000-0000000224f9') s),
  'a hire''s lines: tolls & charges as tolls, its surcharges earnings only when marked so');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000224b1');
select pg_temp.check(
  (select (t->>'trips')::int = 3 and (t->>'meterTrips')::int = 1 and (t->>'fare')::numeric = 120
          and (t->>'commission')::numeric = 14.10 and (t->>'tolls')::numeric = 5
     from public.my_earnings(now() - interval '1 day', now() + interval '1 day') t),
  'my earnings count the meter hire with the trips');
select pg_temp.check(
  (select sum((totals->>'meterTrips')::int) = 1
     from public.my_earnings_series(now() - interval '1 day', now() + interval '1 day', 'day')),
  'and so does the series');
select pg_temp.check(
  (select (d->'totals'->>'meterTrips')::int = 1
          and exists (select 1 from jsonb_array_elements(d->'trips') x where x->>'kind' = 'meter' and x->>'pickup' = 'KLCC')
     from public.partner_statement_data('weekly',
            public.statement_week_start(((now() - interval '1 hour') at time zone 'Asia/Kuala_Lumpur')::date), 'en') d),
  'the weekly statement lists the meter hire, marked');
select pg_temp.as_user('00000000-0000-0000-0000-0000000224b2');
select pg_temp.check(
  (select not (t ? 'meterTrips') and (t->>'trips')::int = 1
     from public.my_earnings(now() - interval '1 day', now() + interval '1 day') t),
  'no meter hires: totals read as before');
reset role;

select 'commission_promotions_reports: all passed';
rollback;
