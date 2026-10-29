-- ============================================================================
-- 0328 — Weekly and monthly hire: a driver and car for weeks or months, on
-- the weekdays the rider chooses.
--
-- The same booking and day-row machinery as daily hire (0327): one
-- hire_bookings row, one scheduled ride a working day, each released before
-- it starts as a ride with the 0326 hire columns.
--
-- 1. Settings (app_settings 'weekly_hire', 'monthly_hire'; hire_package_config
--    / set_hire_package_config, Admin › Settings › Weekly hire, Monthly hire):
--    on / off, the most weeks (months), the hours a day, the km a week
--    (month), the weekdays a rate is for and the weekdays offered first,
--    the lead time (24 hours, 3 days) and how far ahead, payment (prepay,
--    a deposit, a business account), cancelling (free hours, the late fee,
--    and for monthly the notice in days once it has started), the same
--    driver and the cut-off, public holidays (skipped or worked), extra km
--    settled by the day or by the period, the allowances, the labels. Daily
--    gains allowDeposit and allowBusiness.
-- 2. Rates per Vehicle Service (hireWeekRate, hireMonthRate, hireWeekKm,
--    hireMonthKm; hours a day, overtime and extra km as daily's) and per
--    fare tariff card (hire_week_rate, hire_month_rate, hire_week_km,
--    hire_month_km). Without a week rate: the day rate × the weekdays the
--    rate is for; without a month rate: that × 52 / 12.
-- 3. A period's price is its rate for the weekdays chosen (pro rata to the
--    weekdays a rate is for and to the hours a day), shared over its working
--    days; a public holiday skipped is a day not driven and not charged.
-- 4. Public holidays (public_holidays: a date, a name, a country or every
--    country), kept in Admin › Settings › Public holidays.
-- 5. Km: by the day (each day its share of the period's km), or by the period
--    (the extra km over the whole period, charged on its last day).
-- 6. Monthly: on a business account it is charged to the account (its
--    monthly invoice, 0313). Cancelling once it has started keeps the days
--    within the notice; the rest are cancelled and what they were paid is
--    refunded when the hire ends.
-- 7. Drivers: a driver who can't make a day lets it go (0189's
--    scheduled_ride_driver_cancel): that day is offered to other drivers.
--    An admin assigns a driver to every day still to come, or to one day
--    (hire_booking_admin_assign; hire_booking_admin_drivers lists who can).
-- ============================================================================

-- ---- 1. Columns -----------------------------------------------------------------------------------
alter table public.ride_requests drop constraint if exists ride_requests_hire_valid;
alter table public.ride_requests add constraint ride_requests_hire_valid check (
  (hire_package is null or hire_package in ('hourly', 'daily', 'weekly', 'monthly'))
  and (hire_hours is null or hire_hours between 0.5 and 72)
  and (hire_rate is null or hire_rate between 0 and 100000)
  and (hire_km_included is null or hire_km_included between 0 and 100000)
  and (hire_overtime_rate is null or hire_overtime_rate between 0 and 100000)
  and (hire_step_min is null or hire_step_min between 1 and 240)
  and (hire_extra_km_rate is null or hire_extra_km_rate between 0 and 10000)
  and (hire_km_used is null or hire_km_used between 0 and 100000)
  and (hire_day_no is null or hire_day_no between 1 and 400)
  and (hire_quote is null or (jsonb_typeof(hire_quote) = 'object' and pg_column_size(hire_quote) <= 16384))
  and (hire_extensions is null or (jsonb_typeof(hire_extensions) = 'array' and pg_column_size(hire_extensions) <= 16384))
  and (hire_settled is null or (jsonb_typeof(hire_settled) = 'object' and pg_column_size(hire_settled) <= 16384)));

alter table public.scheduled_rides drop constraint if exists scheduled_rides_hire_valid;
alter table public.scheduled_rides add constraint scheduled_rides_hire_valid check (
  (hire_package is null or hire_package in ('hourly', 'daily', 'weekly', 'monthly'))
  and (hire_hours is null or hire_hours between 0.5 and 72)
  and (hire_day_no is null or hire_day_no between 1 and 400));

alter table public.hire_bookings add column if not exists weekdays smallint[];
alter table public.hire_bookings add column if not exists periods integer;
alter table public.hire_bookings add column if not exists km_mode text not null default 'day';
alter table public.hire_bookings add column if not exists km_per_period numeric(10,1);
alter table public.hire_bookings add column if not exists notice_until timestamptz;
alter table public.hire_bookings drop constraint if exists hire_bookings_valid;
alter table public.hire_bookings add constraint hire_bookings_valid check (
  package in ('daily', 'weekly', 'monthly')
  and status in ('booked', 'assigned', 'in_progress', 'completed', 'cancelled', 'expired')
  and days between 1 and 400
  and hours_per_day between 0.5 and 24
  and (km_per_day is null or km_per_day between 0 and 100000)
  and (km_per_period is null or km_per_period between 0 and 1000000)
  and km_mode in ('day', 'period')
  and (periods is null or periods between 1 and 60)
  and (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]))
  and payment_plan in ('deposit', 'prepay', 'business')
  and payment_state in ('none', 'deposit_paid', 'paid', 'balance_short', 'business')
  and (cancelled_by is null or cancelled_by in ('rider', 'admin', 'system'))
  and price >= 0 and deposit_amount >= 0 and balance_amount >= 0 and paid_amount >= 0
  and allocated_amount >= 0 and refunded_amount >= 0 and kept_amount >= 0 and cancel_fee >= 0
  and jsonb_typeof(quote) = 'object' and pg_column_size(quote) <= 65536
  and (stops is null or (jsonb_typeof(stops) = 'array' and pg_column_size(stops) <= 16384)));

alter table public.fare_tariffs add column if not exists hire_week_rate numeric(10,2);
alter table public.fare_tariffs add column if not exists hire_month_rate numeric(12,2);
alter table public.fare_tariffs add column if not exists hire_week_km numeric(10,1);
alter table public.fare_tariffs add column if not exists hire_month_km numeric(10,1);
alter table public.fare_tariffs drop constraint if exists fare_tariffs_hire_period_valid;
alter table public.fare_tariffs add constraint fare_tariffs_hire_period_valid check (
  (hire_week_rate is null or hire_week_rate between 0 and 10000000)
  and (hire_month_rate is null or hire_month_rate between 0 and 10000000)
  and (hire_week_km is null or hire_week_km between 0 and 100000)
  and (hire_month_km is null or hire_month_km between 0 and 500000));

-- ---- 2. Public holidays ---------------------------------------------------------------------------
create table if not exists public.public_holidays (
  id         uuid primary key default gen_random_uuid(),
  day        date not null,
  name       text not null check (char_length(btrim(name)) between 1 and 80),
  -- '' for every country.
  country    text not null default '' check (char_length(country) <= 80),
  created_at timestamptz not null default now()
);
create unique index if not exists public_holidays_day_key on public.public_holidays (day, lower(country));
alter table public.public_holidays enable row level security;
revoke all on public.public_holidays from anon;
grant select, insert, update, delete on public.public_holidays to authenticated;
drop policy if exists "public_holidays read" on public.public_holidays;
create policy "public_holidays read" on public.public_holidays for select to authenticated using (true);
drop policy if exists "public_holidays admin write" on public.public_holidays;
create policy "public_holidays admin write" on public.public_holidays for all to authenticated
  using ((select public.caller_admin_can_write('public_holidays')))
  with check ((select public.caller_admin_can_write('public_holidays')));
insert into public.admin_table_pages (target, page) values ('public_holidays', 'admin-settings-site')
on conflict do nothing;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'public_holidays') then
    alter publication supabase_realtime add table public.public_holidays;
  end if;
end $$;

-- Whether [p_day] is a public holiday in [p_country].
create or replace function public.hire_is_holiday(p_day date, p_country text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.public_holidays h
                  where h.day = p_day and (h.country = '' or lower(h.country) = lower(coalesce(p_country, ''))));
$$;
revoke execute on function public.hire_is_holiday(date, text) from public, anon, authenticated;

-- ---- 3. Settings ---------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('weekly_hire', '{}'::jsonb), ('monthly_hire', '{}'::jsonb)
on conflict (key) do nothing;

-- 0327's, with weekly and monthly, and for every package whether a deposit
-- and a business account are taken.
create or replace function public.hire_multi_normalize(p_package text, v jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  b jsonb := '{}'::jsonb;
  k text;
  d jsonb;
  v_min numeric;
  v_max numeric;
  v_mode text;
  v_chip text;
  v_title text;
  v_days jsonb;
  v_period text := case p_package when 'weekly' then 'Week' when 'monthly' then 'Month' end;
begin
  if p_package not in ('daily', 'weekly', 'monthly') or p_package is null then
    return null;
  end if;
  -- Each package's defaults.
  d := case p_package
    when 'daily' then jsonb_build_object('maxDays', 6, 'minH', 8, 'maxH', 12, 'h', 10, 'km', 200, 'lead', 12,
      'ahead', 30, 'deposit', true, 'free', 24, 'cut', 6, 'chip', 'Daily', 'title', 'Daily hire')
    when 'weekly' then jsonb_build_object('maxDays', 8, 'minH', 4, 'maxH', 12, 'h', 8, 'km', 1000, 'lead', 24,
      'ahead', 60, 'deposit', false, 'free', 48, 'cut', 24, 'chip', 'Weekly', 'title', 'Weekly hire')
    else jsonb_build_object('maxDays', 3, 'minH', 4, 'maxH', 12, 'h', 8, 'km', 4000, 'lead', 72,
      'ahead', 90, 'deposit', false, 'free', 72, 'cut', 48, 'chip', 'Monthly', 'title', 'Monthly hire') end;
  v := coalesce(v, '{}'::jsonb);
  foreach k in array array['enabled', 'allowPrepay', 'allowDeposit', 'allowBusiness', 'sameDriverDefault', 'splitDays'] loop
    b := b || jsonb_build_object(k, case when jsonb_typeof(v->k) = 'boolean' then (v->>k)::boolean
                                         when k = 'enabled' then false
                                         when k = 'allowDeposit' then (d->>'deposit')::boolean
                                         else true end);
  end loop;
  -- A package takes some payment.
  if not (b->>'allowPrepay')::boolean and not (b->>'allowDeposit')::boolean then
    b := b || jsonb_build_object('allowPrepay', true);
  end if;
  v_min := round(public.hire_cfg_num(v->'minHoursPerDay', (d->>'minH')::numeric, 1, 24) * 2) / 2;
  v_max := greatest(v_min, round(public.hire_cfg_num(v->'maxHoursPerDay', (d->>'maxH')::numeric, 1, 24) * 2) / 2);
  v_mode := v->>'lateCancelMode';
  v_chip := btrim(coalesce(v#>>'{labels,chip}', ''));
  v_title := btrim(coalesce(v#>>'{labels,title}', ''));
  b := b || jsonb_build_object(
    'package', p_package,
    'minHoursPerDay', v_min,
    'maxHoursPerDay', v_max,
    'hoursPerDayDefault', least(v_max, greatest(v_min, round(public.hire_cfg_num(v->'hoursPerDayDefault',
                                                                                (d->>'h')::numeric, 1, 24) * 2) / 2)),
    'leadHours', public.hire_cfg_num(v->'leadHours', (d->>'lead')::numeric, 0, 720)::int,
    'bookAheadDays', public.hire_cfg_num(v->'bookAheadDays', (d->>'ahead')::numeric, 1, 365)::int,
    'depositPercent', round(public.hire_cfg_num(v->'depositPercent', 30, 0, 100), 2),
    'freeCancelHours', public.hire_cfg_num(v->'freeCancelHours', (d->>'free')::numeric, 0, 720)::int,
    'lateCancelMode', case when v_mode in ('deposit', 'percent', 'first_day') then v_mode else 'deposit' end,
    'lateCancelPercent', round(public.hire_cfg_num(v->'lateCancelPercent', 50, 0, 100), 2),
    'splitAfterHours', public.hire_cfg_num(v->'splitAfterHours', (d->>'cut')::numeric, 0, 720)::int,
    'overnightAllowance', round(public.hire_cfg_num(v->'overnightAllowance', 50, 0, 100000), 2),
    'mealAllowance', round(public.hire_cfg_num(v->'mealAllowance', 0, 0, 100000), 2),
    'maxOpenBookings', public.hire_cfg_num(v->'maxOpenBookings', 3, 1, 20)::int,
    'labels', jsonb_build_object(
      'chip', case when char_length(v_chip) between 1 and 20 then v_chip else d->>'chip' end,
      'title', case when char_length(v_title) between 1 and 40 then v_title else d->>'title' end));
  if p_package = 'daily' then
    return b || jsonb_build_object(
      'maxDays', public.hire_cfg_num(v->'maxDays', 6, 1, 60)::int,
      'kmPerDayDefault', round(public.hire_cfg_num(v->'kmPerDayDefault', 200, 0, 5000), 1));
  end if;
  -- The weekdays offered first (ISO: 1 Monday .. 7 Sunday).
  select coalesce(jsonb_agg(x order by x), '[]'::jsonb) into v_days
    from (select distinct n::int as x
            from jsonb_array_elements(case when jsonb_typeof(v->'weekdaysDefault') = 'array'
                                           then v->'weekdaysDefault' else '[1,2,3,4,5]'::jsonb end) e,
                 lateral (select public.hire_num(e) as n) y
           where n between 1 and 7 and n = round(n)) z;
  if v_days = '[]'::jsonb then
    v_days := '[1,2,3,4,5]'::jsonb;
  end if;
  return b || jsonb_build_object(
    -- maxWeeks / maxMonths.
    'max' || v_period || 's', public.hire_cfg_num(v->('max' || v_period || 's'), (d->>'maxDays')::numeric, 1,
                                                  case when p_package = 'weekly' then 26 else 12 end)::int,
    'kmPer' || v_period || 'Default', round(public.hire_cfg_num(v->('kmPer' || v_period || 'Default'),
                                                                 (d->>'km')::numeric, 0, 500000), 1),
    'rateWeekdays', public.hire_cfg_num(v->'rateWeekdays', 5, 1, 7)::int,
    'weekdaysDefault', v_days,
    'holidays', case when v->>'holidays' = 'work' then 'work' else 'skip' end,
    'kmMode', case when v->>'kmMode' = 'day' then 'day' else 'period' end,
    'noticeDays', case when p_package = 'monthly' then public.hire_cfg_num(v->'noticeDays', 7, 0, 60)::int else 0 end);
end;
$$;
revoke execute on function public.hire_multi_normalize(text, jsonb) from public, anon, authenticated;

-- ---- 4. Rates ------------------------------------------------------------------------------------
-- 0327's rates, with the week's and the month's: {enabled, service, dayRate,
-- dayHours, kmPerDay, overtimePerHour, extraKm, overnight, weekRate,
-- monthRate, kmPerWeek, kmPerMonth}.
create or replace function public.hire_multi_rates(p_package text, p_service text, p_country text, p_state text,
                                                   p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hire_package_config(p_package);
  h jsonb := public.hire_rates(p_service, p_country, p_state, p_city, p_suburb);
  v jsonb;
  v_sid text;
  eq text := '';
  c record;
  v_rate numeric;
  v_hours numeric;
  v_km numeric;
  v_ot numeric;
  v_xkm numeric;
  v_night numeric;
  v_week numeric;
  v_month numeric;
  v_wkm numeric;
  v_mkm numeric;
  v_days numeric := coalesce((cfg->>'rateWeekdays')::numeric, 5);
begin
  if not coalesce((h->>'service')::boolean, false) then
    return jsonb_build_object('enabled', false, 'service', false);
  end if;
  select e.id::text, e.values into v_sid, v
    from public.settings_entries e
   where e.category = 'vehicle-services'
     and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_service, '')))
   order by e.position
   limit 1;
  for c in
    select f.*
      from public.fare_tariffs f
     where f.active and f.service_type is null
       and (f.vehicle_service is null or f.vehicle_service = v_sid)
       and (f.level = 'master'
            or (f.level = 'country' and lower(f.country) = lower(coalesce(p_country, eq)))
            or (f.level = 'state' and lower(f.country) = lower(coalesce(p_country, eq))
                and lower(f.state) = lower(coalesce(p_state, eq)))
            or (f.level = 'city' and lower(f.country) = lower(coalesce(p_country, eq))
                and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq)))
            or (f.level = 'suburb' and lower(f.country) = lower(coalesce(p_country, eq))
                and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq))
                and lower(f.suburb) = lower(coalesce(p_suburb, eq))))
     order by case f.level when 'suburb' then 0 when 'city' then 1 when 'state' then 2 when 'country' then 3 else 4 end,
              (f.vehicle_service is null)
  loop
    v_rate := coalesce(v_rate, c.hire_day_rate);
    v_hours := coalesce(v_hours, c.hire_day_hours);
    v_km := coalesce(v_km, c.hire_day_km);
    v_ot := coalesce(v_ot, c.hire_day_overtime_per_hour);
    v_xkm := coalesce(v_xkm, c.hire_day_extra_km);
    v_night := coalesce(v_night, c.hire_overnight);
    v_week := coalesce(v_week, c.hire_week_rate);
    v_month := coalesce(v_month, c.hire_month_rate);
    v_wkm := coalesce(v_wkm, c.hire_week_km);
    v_mkm := coalesce(v_mkm, c.hire_month_km);
  end loop;
  v_hours := least(24, greatest(1, coalesce(v_hours, public.hire_num(v->'hireDayHours'),
                                            (cfg->>'hoursPerDayDefault')::numeric, 10)));
  v_rate := coalesce(v_rate, public.hire_num(v->'hireDayRate'),
                     case when (h->>'perHour')::numeric > 0 then (h->>'perHour')::numeric * v_hours end);
  v_km := coalesce(v_km, public.hire_num(v->'hireDayKm'), (cfg->>'kmPerDayDefault')::numeric,
                   (public.hire_package_config('daily')->>'kmPerDayDefault')::numeric, 0);
  v_ot := coalesce(v_ot, public.hire_num(v->'hireDayOvertimePerHour'), (h->>'overtimePerHour')::numeric, 0);
  v_xkm := coalesce(v_xkm, public.hire_num(v->'hireDayExtraKm'), (h->>'extraKm')::numeric, 0);
  v_night := coalesce(v_night, public.hire_num(v->'hireOvernight'), (cfg->>'overnightAllowance')::numeric, 0);
  -- A week: the day rate for the weekdays a rate is for; a month: 52 / 12 weeks.
  v_week := coalesce(v_week, public.hire_num(v->'hireWeekRate'), v_rate * v_days);
  v_month := coalesce(v_month, public.hire_num(v->'hireMonthRate'), v_week * 52 / 12);
  v_wkm := coalesce(v_wkm, public.hire_num(v->'hireWeekKm'), (cfg->>'kmPerWeekDefault')::numeric, v_km * v_days);
  v_mkm := coalesce(v_mkm, public.hire_num(v->'hireMonthKm'), (cfg->>'kmPerMonthDefault')::numeric,
                    v_km * v_days * 52 / 12);
  return jsonb_build_object(
    'enabled', coalesce((h->>'enabled')::boolean, false),
    'service', true,
    'dayRate', case when v_rate > 0 then round(v_rate, 2) end,
    'dayHours', v_hours,
    'kmPerDay', round(greatest(0, v_km), 1),
    'overtimePerHour', round(greatest(0, v_ot), 2),
    'extraKm', round(greatest(0, v_xkm), 2),
    'overnight', round(greatest(0, v_night), 2),
    'weekRate', case when v_week > 0 then round(v_week, 2) end,
    'monthRate', case when v_month > 0 then round(v_month, 2) end,
    'kmPerWeek', round(greatest(0, v_wkm), 1),
    'kmPerMonth', round(greatest(0, v_mkm), 1));
end;
$$;
revoke execute on function public.hire_multi_rates(text, text, text, text, text, text) from public, anon, authenticated;

-- 0327's hints, with the periods, the weekdays and the payments.
create or replace function public.hire_hint(p_reason text, q jsonb default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_reason
    when 'HIRE_OFF' then case when q->>'package' in ('daily', 'weekly', 'monthly')
                              then format('%s is not available.', coalesce(q->>'title', 'This hire'))
                              else 'Hiring a driver by the hour is not available.' end
    when 'HIRE_SERVICE_OFF' then 'This vehicle can''t be hired here. Choose another.'
    when 'HIRE_NO_RATE' then 'This vehicle has no hire price here yet. Choose another.'
    when 'HIRE_HOURS' then format('Choose between %s and %s hours.',
                                  coalesce(q->>'minHours', q->>'minHoursPerDay'), coalesce(q->>'maxHours', q->>'maxHoursPerDay'))
    when 'HIRE_DAYS' then format('Choose between 1 and %s days.', q->>'maxDays')
    when 'HIRE_PERIODS' then case when q->>'package' = 'weekly' then format('Choose between 1 and %s weeks.', q->>'maxPeriods')
                                  else format('Choose between 1 and %s months.', q->>'maxPeriods') end
    when 'HIRE_WEEKDAYS' then 'Choose the days of the week with at least one working day.'
    when 'HIRE_LEAD' then format('Book at least %s hours ahead.', q->>'leadHours')
    when 'HIRE_AHEAD' then format('Book up to %s days ahead.', q->>'bookAheadDays')
    when 'HIRE_CASH' then case when q->>'package' in ('daily', 'weekly', 'monthly')
                               then 'This hire is paid in the app. Choose GET.wallet.'
                               else 'Hourly hire is paid in the app. Choose GET.wallet.' end
    when 'HIRE_PAY' then 'This hire is paid from GET.wallet, or charged to a business account.'
    when 'HIRE_PREPAY_OFF' then 'Paying the whole hire now is not offered. Pay the deposit.'
    when 'HIRE_DEPOSIT_OFF' then 'This hire is paid in full when you book it.'
    when 'HIRE_BUSINESS_OFF' then 'This hire can''t be charged to a business account.'
    when 'HIRE_NOW_OFF' then 'Hourly hire can only be booked for later.'
    when 'HIRE_LATER_OFF' then 'Hourly hire can''t be booked for later.'
    when 'HIRE_BUSINESS' then 'This hire can''t be charged to a business account.'
    else 'Hire is not available.' end;
$$;

-- ---- 5. The quote --------------------------------------------------------------------------------
-- 0327's quote, with weeks and months: [p_options] {weekdays: [1..7],
-- periods: n}. Every package's days are in dateList [{at, period, perDay,
-- km}] (dates keeps 0327's list of times).
create or replace function public.hire_multi_quote(
  p_package text, p_pickup_lat float8, p_pickup_lng float8, p_drop_lat float8, p_drop_lng float8,
  p_service text, p_days integer, p_hours numeric, p_first_at timestamptz,
  p_country text default null, p_state text default null, p_city text default null, p_suburb text default null,
  p_payment text default null, p_overnight boolean default false, p_timezone text default null,
  p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hire_package_config(p_package);
  hc jsonb := public.hourly_hire_config();
  r jsonb;
  v_tz text := public.hire_tz(p_timezone);
  v_multi boolean := p_package in ('weekly', 'monthly');
  v_reason text;
  v_days integer;
  v_max integer;
  v_periods integer;
  v_weekdays int[];
  v_hours numeric;
  v_first timestamptz := coalesce(p_first_at, now() + interval '1 day');
  v_local timestamp;
  v_start date;
  v_end date;
  v_day date;
  v_list jsonb := '[]'::jsonb;
  v_dates jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_rate numeric;
  v_period_price numeric := 0;
  v_period_km numeric := 0;
  v_nominal integer;
  v_per numeric;
  v_day_price numeric := 0;
  v_base numeric := 0;
  v_fees jsonb := '[]'::jsonb;
  v_fees_day numeric := 0;
  v_nights integer;
  v_night numeric;
  v_meal numeric;
  v_total numeric;
  v_kind text := public.hire_pay_kind(p_payment);
  q jsonb;
  i integer;
  k integer;
begin
  if cfg is null then
    return jsonb_build_object('available', false, 'reason', 'HIRE_OFF', 'package', p_package,
                              'hint', public.hire_hint('HIRE_OFF', jsonb_build_object('package', p_package)));
  end if;
  r := public.hire_multi_rates(p_package, p_service, p_country, p_state, p_city, p_suburb);
  v_hours := coalesce(p_hours, least((cfg->>'maxHoursPerDay')::numeric,
                                     greatest((cfg->>'minHoursPerDay')::numeric, coalesce((r->>'dayHours')::numeric, 10))));
  v_max := case p_package when 'weekly' then (cfg->>'maxWeeks')::int when 'monthly' then (cfg->>'maxMonths')::int
                          else (cfg->>'maxDays')::int end;
  v_rate := case p_package when 'weekly' then (r->>'weekRate')::numeric when 'monthly' then (r->>'monthRate')::numeric
                           else (r->>'dayRate')::numeric end;
  if v_multi then
    v_periods := coalesce(public.hire_num(p_options->'periods')::int, 1);
    select coalesce(array_agg(distinct x::int order by x::int), '{}') into v_weekdays
      from jsonb_array_elements(case when jsonb_typeof(p_options->'weekdays') = 'array' then p_options->'weekdays'
                                     else cfg->'weekdaysDefault' end) e,
           lateral (select public.hire_num(e) as x) y
     where x between 1 and 7 and x = round(x);
  else
    v_days := coalesce(p_days, 1);
  end if;
  v_local := v_first at time zone v_tz;
  if v_multi then
    v_periods := least(v_max, greatest(1, v_periods));
    -- A period's price: the rate for the weekdays chosen and the hours a day.
    v_period_price := round(coalesce(v_rate, 0) * cardinality(v_weekdays) / (cfg->>'rateWeekdays')::numeric
                            * v_hours / greatest(1, (r->>'dayHours')::numeric), 2);
    v_period_km := coalesce(case when p_package = 'weekly' then (r->>'kmPerWeek')::numeric
                                 else (r->>'kmPerMonth')::numeric end, 0);
    for k in 1 .. v_periods loop
      v_start := case when p_package = 'weekly' then v_local::date + (k - 1) * 7
                      else (v_local::date + make_interval(months => k - 1))::date end;
      v_end := case when p_package = 'weekly' then v_start + 7
                    else (v_local::date + make_interval(months => k))::date end;
      select count(*) into v_nominal
        from generate_series(v_start, v_end - 1, interval '1 day') g
       where extract(isodow from g)::int = any (v_weekdays);
      continue when v_nominal = 0;
      v_per := round(v_period_price / v_nominal, 2);
      for v_day in
        select g::date from generate_series(v_start, v_end - 1, interval '1 day') g
         where extract(isodow from g)::int = any (v_weekdays) order by g
      loop
        if cfg->>'holidays' = 'skip' and public.hire_is_holiday(v_day, p_country) then
          v_skipped := v_skipped || to_jsonb(v_day);
          continue;
        end if;
        v_list := v_list || jsonb_build_object(
          'at', (v_day + v_local::time) at time zone v_tz, 'period', k, 'perDay', v_per,
          'km', round(v_period_km / v_nominal, 1));
      end loop;
    end loop;
    v_days := jsonb_array_length(v_list);
    v_day_price := coalesce((v_list->0->>'perDay')::numeric, round(v_period_price / greatest(1, cardinality(v_weekdays)), 2));
  else
    v_days := least(v_max, greatest(1, v_days));
    v_day_price := round(coalesce(v_rate, 0) * v_hours / greatest(1, (r->>'dayHours')::numeric), 2);
    for i in 1 .. v_days loop
      v_list := v_list || jsonb_build_object('at', (v_local + make_interval(days => i - 1)) at time zone v_tz,
                                             'period', i, 'perDay', v_day_price,
                                             'km', coalesce((r->>'kmPerDay')::numeric, 0));
    end loop;
  end if;
  select coalesce(jsonb_agg(e->'at'), '[]'::jsonb), coalesce(sum((e->>'perDay')::numeric), 0)
    into v_dates, v_base
    from jsonb_array_elements(v_list) e;
  if not (cfg->>'enabled')::boolean then
    v_reason := 'HIRE_OFF';
  elsif not coalesce((r->>'enabled')::boolean, false) then
    v_reason := 'HIRE_SERVICE_OFF';
  elsif v_rate is null then
    v_reason := 'HIRE_NO_RATE';
  elsif not v_multi and (coalesce(p_days, 1) < 1 or coalesce(p_days, 1) > v_max) then
    v_reason := 'HIRE_DAYS';
  elsif v_multi and (coalesce(public.hire_num(p_options->'periods'), 1) < 1
                     or coalesce(public.hire_num(p_options->'periods'), 1) > v_max) then
    v_reason := 'HIRE_PERIODS';
  elsif v_multi and (cardinality(v_weekdays) = 0 or v_days = 0) then
    v_reason := 'HIRE_WEEKDAYS';
  elsif v_hours < (cfg->>'minHoursPerDay')::numeric or v_hours > (cfg->>'maxHoursPerDay')::numeric
        or v_hours <> round(v_hours * 2) / 2 then
    v_reason := 'HIRE_HOURS';
  elsif p_payment is not null and v_kind = 'cash' then
    v_reason := 'HIRE_CASH';
  elsif v_first < now() + make_interval(hours => (cfg->>'leadHours')::int) then
    v_reason := 'HIRE_LEAD';
  elsif v_first > now() + make_interval(days => (cfg->>'bookAheadDays')::int) then
    v_reason := 'HIRE_AHEAD';
  end if;
  v_hours := least((cfg->>'maxHoursPerDay')::numeric, greatest((cfg->>'minHoursPerDay')::numeric, round(v_hours * 2) / 2));
  if v_rate is not null and v_days > 0 then
    v_fees := public.place_ride_charges(public.airport_at(p_pickup_lat, p_pickup_lng),
                                        public.airport_at(p_drop_lat, p_drop_lng), null, p_service, v_day_price, v_first);
    v_fees_day := coalesce((select round(sum((l->>'value')::numeric), 2) from jsonb_array_elements(v_fees) l), 0);
  end if;
  v_nights := case when coalesce(p_overnight, false) then greatest(0, v_days - 1) else 0 end;
  v_night := coalesce((r->>'overnight')::numeric, 0);
  v_meal := (cfg->>'mealAllowance')::numeric;
  v_total := round(v_base + v_fees_day * v_days + v_nights * v_night + v_days * v_meal, 2);
  q := jsonb_build_object(
    'available', v_reason is null,
    'reason', v_reason,
    'package', p_package,
    'title', cfg#>>'{labels,title}',
    'service', p_service,
    'days', v_days,
    'maxDays', (cfg->>'maxDays')::int,
    'maxPeriods', v_max,
    'hours', v_hours,
    'minHoursPerDay', (cfg->>'minHoursPerDay')::numeric,
    'maxHoursPerDay', (cfg->>'maxHoursPerDay')::numeric,
    'dayRate', (r->>'dayRate')::numeric,
    'dayHours', (r->>'dayHours')::numeric,
    'perDay', v_day_price,
    'kmPerDay', case when v_multi then coalesce((v_list->0->>'km')::numeric, 0) else coalesce((r->>'kmPerDay')::numeric, 0) end,
    'overtimePerHour', coalesce((r->>'overtimePerHour')::numeric, 0),
    'stepMinutes', (hc->>'stepMinutes')::int,
    'extraKm', coalesce((r->>'extraKm')::numeric, 0),
    'overnight', coalesce(p_overnight, false),
    'nights', v_nights,
    'overnightAllowance', v_night,
    'overnightTotal', round(v_nights * v_night, 2),
    'mealAllowance', v_meal,
    'mealTotal', round(v_days * v_meal, 2),
    'placeFees', v_fees,
    'placeFeesPerDay', v_fees_day,
    'placeFeesTotal', round(v_fees_day * v_days, 2),
    'base', round(v_base, 2),
    'total', v_total,
    'depositPercent', (cfg->>'depositPercent')::numeric,
    'deposit', round(v_total * (cfg->>'depositPercent')::numeric / 100, 2),
    'allowPrepay', (cfg->>'allowPrepay')::boolean,
    'allowDeposit', (cfg->>'allowDeposit')::boolean,
    'allowBusiness', (cfg->>'allowBusiness')::boolean,
    'sameDriverDefault', (cfg->>'sameDriverDefault')::boolean,
    'freeCancelHours', (cfg->>'freeCancelHours')::int,
    'freeCancelUntil', v_first - make_interval(hours => (cfg->>'freeCancelHours')::int),
    'lateCancelMode', cfg->>'lateCancelMode',
    'lateCancelPercent', (cfg->>'lateCancelPercent')::numeric,
    'leadHours', (cfg->>'leadHours')::int,
    'bookAheadDays', (cfg->>'bookAheadDays')::int,
    'firstAt', v_first,
    'timezone', v_tz,
    'dates', v_dates,
    'dateList', v_list);
  if v_multi then
    q := q || jsonb_build_object(
      'periods', v_periods, 'weekdays', to_jsonb(v_weekdays), 'periodRate', v_rate, 'periodPrice', v_period_price,
      'rateWeekdays', (cfg->>'rateWeekdays')::int, 'kmPerPeriod', v_period_km, 'kmMode', cfg->>'kmMode',
      'holidays', cfg->>'holidays', 'holidaysSkipped', v_skipped, 'noticeDays', (cfg->>'noticeDays')::int);
  end if;
  if v_reason is not null then
    q := q || jsonb_build_object('hint', public.hire_hint(v_reason, q));
  end if;
  return q;
end;
$$;
revoke execute on function public.hire_multi_quote(text, float8, float8, float8, float8, text, integer, numeric, timestamptz,
  text, text, text, text, text, boolean, text, jsonb) from public, anon;
grant execute on function public.hire_multi_quote(text, float8, float8, float8, float8, text, integer, numeric, timestamptz,
  text, text, text, text, text, boolean, text, jsonb) to authenticated, service_role;

-- 0327's day of a booking, with the day's own price and km (a period's
-- share), its period, and whether it is the period's last day.
create or replace function public.hire_day_quote(q jsonb, p_day integer)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with e as (select coalesce(q->'dateList'->(p_day - 1), '{}'::jsonb) as d),
       v as (select coalesce((e.d->>'perDay')::numeric, (q->>'perDay')::numeric) as base,
                    coalesce((e.d->>'km')::numeric, (q->>'kmPerDay')::numeric, 0) as km,
                    coalesce((e.d->>'period')::int, p_day) as period,
                    coalesce(q->'dateList'->p_day->>'period', '') is distinct from coalesce(e.d->>'period', '') as last
               from e)
  select jsonb_build_object(
    'package', q->>'package', 'service', q->>'service', 'title', q->>'title',
    'hours', (q->>'hours')::numeric, 'minHours', (q->>'hours')::numeric, 'maxHours', (q->>'hours')::numeric,
    'hourStep', 0.5,
    'rate', round(v.base / greatest(0.5, (q->>'hours')::numeric), 2),
    'kmPerHour', round(v.km / greatest(0.5, (q->>'hours')::numeric), 1),
    'kmIncluded', v.km,
    'overtimePerHour', coalesce((q->>'overtimePerHour')::numeric, 0),
    'stepMinutes', coalesce((q->>'stepMinutes')::int, 30),
    'extraKm', coalesce((q->>'extraKm')::numeric, 0),
    'base', v.base,
    'placeFees', coalesce(q->'placeFees', '[]'::jsonb),
    'placeFeesTotal', coalesce((q->>'placeFeesPerDay')::numeric, 0),
    'meal', coalesce((q->>'mealAllowance')::numeric, 0),
    'overnight', case when coalesce((q->>'overnight')::boolean, false) and p_day < (q->>'days')::int
                      then coalesce((q->>'overnightAllowance')::numeric, 0) else 0 end,
    'total', round(v.base + coalesce((q->>'placeFeesPerDay')::numeric, 0)
                   + coalesce((q->>'mealAllowance')::numeric, 0)
                   + case when coalesce((q->>'overnight')::boolean, false) and p_day < (q->>'days')::int
                          then coalesce((q->>'overnightAllowance')::numeric, 0) else 0 end, 2),
    'dayNo', p_day, 'days', (q->>'days')::int,
    'periodNo', v.period, 'periodLast', v.last,
    'kmMode', coalesce(q->>'kmMode', 'day'), 'kmPerPeriod', coalesce((q->>'kmPerPeriod')::numeric, v.km),
    'holdInWallet', false, 'hold', 0, 'allowCash', false)
  from v;
$$;

-- ---- 6. Booking ----------------------------------------------------------------------------------
-- 0327's hire_book, with weeks and months ([p_booking] weekdays and
-- periods), each day at its own price, and the payments each package takes.
create or replace function public.hire_book(p_request jsonb, p_booking jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_req jsonb := public.scheduled_request_clean(coalesce(p_request, '{}'::jsonb));
  v_pkg text := coalesce(p_booking->>'package', 'daily');
  cfg jsonb := public.hire_package_config(v_pkg);
  q jsonb;
  v_first timestamptz;
  v_days integer;
  v_hours numeric;
  v_overnight boolean := coalesce((p_booking->>'overnight')::boolean, false);
  v_same boolean;
  v_plan text := p_booking->>'payment_plan';
  v_kind text;
  v_name text;
  v_phone text;
  v_tz text;
  b public.hire_bookings;
  d jsonb;
  i integer := 0;
  v_total numeric;
  v_now numeric;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if cfg is null then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_OFF', 'package', v_pkg));
  end if;
  if jsonb_typeof(v_req->'pickup_lat') <> 'number' or jsonb_typeof(v_req->'pickup_lng') <> 'number' then
    raise exception 'SCHEDULED_PICKUP' using hint = 'A pickup point is needed.';
  end if;
  v_name := nullif(btrim(coalesce(v_req->>'booked_for_name', '')), '');
  v_phone := nullif(btrim(coalesce(v_req->>'booked_for_phone', '')), '');
  if (v_name is not null and (v_phone is null or length(v_name) > 80))
     or (v_phone is not null and length(v_phone) not between 6 and 32) then
    raise exception 'SCHEDULED_PASSENGER' using hint = 'Give the passenger''s name and phone number.';
  end if;
  begin
    v_first := (p_booking->>'first_at')::timestamptz;
  exception when others then
    v_first := null;
  end;
  if v_first is null then
    raise exception 'HIRE_LEAD' using errcode = '22023', hint = 'Choose the first day and the start time.';
  end if;
  v_days := case when jsonb_typeof(p_booking->'days') = 'number' then (p_booking->>'days')::numeric::int end;
  v_hours := public.hire_num(p_booking->'hours');
  v_same := coalesce((p_booking->>'same_driver')::boolean, (cfg->>'sameDriverDefault')::boolean);
  v_tz := public.hire_tz(v_req->>'timezone');
  if (select count(*) from public.hire_bookings
       where rider_id = v_uid and status in ('booked', 'assigned', 'in_progress')) >= (cfg->>'maxOpenBookings')::int then
    raise exception 'HIRE_BOOKING_LIMIT' using errcode = 'P0001',
      hint = format('You already have %s hires booked.', cfg->>'maxOpenBookings');
  end if;
  q := public.hire_multi_quote(v_pkg, (v_req->>'pickup_lat')::float8, (v_req->>'pickup_lng')::float8,
         case when jsonb_typeof(v_req->'drop_lat') = 'number' then (v_req->>'drop_lat')::float8 end,
         case when jsonb_typeof(v_req->'drop_lng') = 'number' then (v_req->>'drop_lng')::float8 end,
         v_req->>'service', v_days, v_hours, v_first, v_req->>'country', v_req->>'state', v_req->>'city',
         v_req->>'suburb', coalesce(v_req->>'payment_mode', 'Get Pay'), v_overnight, v_tz,
         jsonb_build_object('weekdays', p_booking->'weekdays', 'periods', p_booking->'periods'));
  if not (q->>'available')::boolean then
    perform public.hire_raise(q);
  end if;
  -- Paid from GET.wallet (or Family), or charged to a business account; as
  -- the package takes it.
  v_kind := case when coalesce(v_req->>'business_account_id', '') <> '' then 'business'
                 else public.hire_pay_kind(v_req->>'payment_mode') end;
  if v_kind = 'business' then
    if not (cfg->>'allowBusiness')::boolean then
      perform public.hire_raise(jsonb_build_object('reason', 'HIRE_BUSINESS_OFF', 'package', v_pkg));
    end if;
    v_plan := 'business';
  elsif v_kind <> 'wallet' then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_PAY', 'package', v_pkg));
  else
    v_plan := coalesce(v_plan, case when (cfg->>'allowDeposit')::boolean then 'deposit' else 'prepay' end);
    if v_plan = 'prepay' and not (cfg->>'allowPrepay')::boolean then
      perform public.hire_raise(jsonb_build_object('reason', 'HIRE_PREPAY_OFF', 'package', v_pkg));
    elsif v_plan = 'deposit' and not (cfg->>'allowDeposit')::boolean then
      perform public.hire_raise(jsonb_build_object('reason', 'HIRE_DEPOSIT_OFF', 'package', v_pkg));
    elsif v_plan not in ('deposit', 'prepay') then
      v_plan := case when (cfg->>'allowDeposit')::boolean then 'deposit' else 'prepay' end;
    end if;
  end if;

  insert into public.hire_bookings (
    rider_id, package, service, pickup_name, pickup_address, pickup_lat, pickup_lng,
    drop_name, drop_address, drop_lat, drop_lng, stops, first_at, days, timezone, hours_per_day, km_per_day,
    overnight, same_driver, payment_mode, payment_plan, price, quote, currency, booked_for_name, booked_for_phone,
    family, business_account_id, payment_state, weekdays, periods, km_mode, km_per_period)
  values (
    v_uid, v_pkg, v_req->>'service', v_req->>'pickup_name', coalesce(v_req->>'pickup_address', v_req->>'pickup_name'),
    (v_req->>'pickup_lat')::float8, (v_req->>'pickup_lng')::float8,
    v_req->>'drop_name', coalesce(v_req->>'drop_address', v_req->>'drop_name'),
    case when jsonb_typeof(v_req->'drop_lat') = 'number' then (v_req->>'drop_lat')::float8 end,
    case when jsonb_typeof(v_req->'drop_lng') = 'number' then (v_req->>'drop_lng')::float8 end,
    case when jsonb_typeof(v_req->'stops') = 'array' then v_req->'stops' end,
    -- The first day the hire drives (a week or month may start on a day off).
    coalesce(((q->'dateList'->0->>'at'))::timestamptz, v_first), (q->>'days')::int, v_tz, (q->>'hours')::numeric,
    (q->>'kmPerDay')::numeric,
    v_overnight, v_same, v_req->>'payment_mode', v_plan, (q->>'total')::numeric,
    q - 'available' - 'reason' - 'hint' || jsonb_build_object('country', v_req->>'country', 'state', v_req->>'state',
                                                              'city', v_req->>'city', 'suburb', v_req->>'suburb'),
    v_req->>'currency', v_name, v_phone, case when jsonb_typeof(v_req->'family') = 'object' then v_req->'family' end,
    case when v_kind = 'business' and (v_req->>'business_account_id') ~* '^[0-9a-f-]{36}$'
         then (v_req->>'business_account_id')::uuid end,
    case when v_kind = 'business' then 'business' else 'none' end,
    case when jsonb_typeof(q->'weekdays') = 'array'
         then array(select (x #>> '{}')::smallint from jsonb_array_elements(q->'weekdays') x) end,
    (q->>'periods')::int,
    coalesce(q->>'kmMode', 'day'),
    (q->>'kmPerPeriod')::numeric)
  returning * into b;

  -- One booking row a working day, through every booking trigger.
  v_req := v_req || jsonb_build_object('timezone', v_tz);
  for d in select value from jsonb_array_elements(q->'dateList') loop
    i := i + 1;
    insert into public.scheduled_rides (
      rider_id, pickup_at, request, service, pickup_address, drop_address,
      pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km, fare, scheduling_fee, currency,
      booked_for_name, booked_for_phone, hire_package, hire_hours, hire_booking_id, hire_day_no)
    values (
      v_uid, (d->>'at')::timestamptz,
      v_req || jsonb_build_object('hire_package', v_pkg, 'hire_hours', b.hours_per_day,
                                  'hire_booking_id', b.id, 'hire_day_no', i),
      b.service, b.pickup_address, b.drop_address, b.pickup_lat, b.pickup_lng, b.drop_lat, b.drop_lng,
      case when jsonb_typeof(v_req->'distance_km') = 'number' then (v_req->>'distance_km')::numeric end,
      (d->>'perDay')::numeric, 0, b.currency, v_name, v_phone, v_pkg, b.hours_per_day, b.id, i);
  end loop;

  -- The total: each day's amount due as its ride will be (taxes included).
  select coalesce(sum(public.ride_amount_due(jsonb_populate_record(null::public.ride_requests, s.request))), 0)
    into v_total
    from public.scheduled_rides s where s.hire_booking_id = b.id;
  v_total := round(v_total, 2);
  v_now := case v_plan when 'prepay' then v_total
                       when 'deposit' then round(v_total * (cfg->>'depositPercent')::numeric / 100, 2)
                       else 0 end;
  update public.hire_bookings
     set price = v_total, deposit_amount = v_now,
         balance_amount = case when v_plan = 'deposit' then v_total - v_now else 0 end,
         quote = quote || jsonb_build_object('grandTotal', v_total, 'payNow', v_now)
   where id = b.id
  returning * into b;
  if v_plan in ('deposit', 'prepay') then
    if not public.hire_booking_charge(b, v_now, case when v_plan = 'prepay' then 'hire_prepay' else 'hire_deposit' end,
                                      coalesce(q->>'title', 'Hire') || case when v_plan = 'prepay' then ' paid' else ' deposit' end) then
      raise exception 'HIRE_BALANCE' using errcode = 'P0001',
        hint = format('Top up your GET.wallet: %s is paid now for this hire.', 'RM' || to_char(v_now, 'FM999999990.00'));
    end if;
    update public.hire_bookings
       set paid_amount = v_now,
           payment_state = case when v_plan = 'prepay' or balance_amount = 0 then 'paid' else 'deposit_paid' end
     where id = b.id
    returning * into b;
  end if;
  return to_jsonb(b) || jsonb_build_object('day_rows', (
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'day', s.hire_day_no, 'pickup_at', s.pickup_at,
                                                 'fare', s.fare) order by s.hire_day_no), '[]'::jsonb)
      from public.scheduled_rides s where s.hire_booking_id = b.id));
end;
$$;
revoke execute on function public.hire_book(jsonb, jsonb) from public, anon;
grant execute on function public.hire_book(jsonb, jsonb) to authenticated;

-- ---- 7. The end of a day: km by the period ---------------------------------------------------------
-- 0327's hire_settle, with km settled by the period: a day before the
-- period's last includes what was driven; the last day includes what is
-- left of the period's km after the other days', so the extra km over the
-- whole period is charged there.
create or replace function public.hire_settle(r public.ride_requests, p_km numeric, p_at timestamptz,
                                              p_by text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  q jsonb := coalesce(r.hire_quote, '{}'::jsonb);
  v_step numeric := coalesce((q->>'hourStep')::numeric, (cfg->>'hourStep')::numeric);
  v_min numeric := coalesce((q->>'minHours')::numeric, (cfg->>'minHours')::numeric);
  v_booked numeric := r.hire_hours;
  v_used_min numeric := greatest(0, extract(epoch from p_at - coalesce(r.hire_started_at, p_at)) / 60);
  v_ext_min integer := public.hire_extension_minutes(r.hire_extensions);
  v_pays text := cfg->>'earlyEndPays';
  v_multi boolean := r.hire_package is distinct from 'hourly';
  v_hours numeric;
  v_over_min numeric;
  v_overtime numeric;
  v_km numeric := round(greatest(0, coalesce(p_km, 0)), 1);
  v_included numeric;
  v_extra_km numeric;
  v_extra numeric;
  v_base numeric;
  v_early boolean;
  v_label text;
  v_other numeric;
  v_lines jsonb := '[]'::jsonb;
begin
  v_early := v_used_min < v_booked * 60;
  -- The hours billed: the booked ones, or what an early end pays.
  v_hours := case
    when not v_early or v_pays = 'booked' or v_multi then v_booked
    when v_pays = 'minimum' then least(v_booked, greatest(v_min, ceil(v_used_min / 60 / v_step) * v_step))
    else least(v_booked, greatest(v_step, ceil(v_used_min / 60 / v_step) * v_step)) end;
  v_base := case when v_multi then coalesce((q->>'base')::numeric, round(v_hours * r.hire_rate, 2))
                 else round(v_hours * r.hire_rate, 2) end;
  -- Overtime: what is used past the booked hours, in started steps, up to
  -- the minutes the rider approved.
  v_over_min := least(v_ext_min, greatest(0, v_used_min - v_booked * 60));
  v_over_min := least(v_ext_min, ceil(v_over_min / greatest(1, r.hire_step_min)) * greatest(1, r.hire_step_min));
  v_overtime := public.hire_overtime_amount(v_over_min, r.hire_step_min, r.hire_overtime_rate);
  v_included := round(coalesce(r.hire_km_included, 0)
                      + v_ext_min / 60.0 * coalesce((q->>'kmPerHour')::numeric, 0), 1);
  -- 0328: km by the period.
  if v_multi and q->>'kmMode' = 'period' and r.hire_booking_id is not null then
    if coalesce((q->>'periodLast')::boolean, false) then
      select coalesce(sum(x.hire_km_used), 0) into v_other
        from public.ride_requests x
       where x.hire_booking_id = r.hire_booking_id and x.id <> r.id and x.status = 'completed'
         and x.hire_quote->>'periodNo' = q->>'periodNo';
      v_included := round(greatest(0, coalesce((q->>'kmPerPeriod')::numeric, 0) - v_other)
                          + v_ext_min / 60.0 * coalesce((q->>'kmPerHour')::numeric, 0), 1);
    else
      v_included := greatest(v_included, v_km);
    end if;
  end if;
  v_extra_km := greatest(0, round(v_km - v_included, 1));
  v_extra := round(v_extra_km * coalesce(r.hire_extra_km_rate, 0), 2);
  if r.whole_fare then
    v_base := ceil(v_base);
    v_overtime := ceil(v_overtime);
    v_extra := ceil(v_extra);
  end if;
  v_label := case when v_multi
                  then coalesce(q->>'title', 'Hire') || ' day ' || coalesce(r.hire_day_no, (q->>'dayNo')::int, 1)
                       || ' of ' || coalesce((q->>'days')::int, 1)
                  else public.hire_hours_label(v_hours) end;
  v_lines := jsonb_build_array(jsonb_build_object('kind', 'hire', 'label', v_label, 'amount', v_base));
  if v_overtime > 0 then
    v_lines := v_lines || jsonb_build_object('kind', 'overtime', 'label', 'Overtime ' || v_over_min::int || ' min',
                                             'amount', v_overtime);
  end if;
  if v_extra > 0 then
    v_lines := v_lines || jsonb_build_object('kind', 'extra_km',
      'label', case when v_multi and q->>'kmMode' = 'period'
                    then 'Extra km ' || public.hire_plain(v_extra_km) || ' km this period'
                    else 'Extra km ' || public.hire_plain(v_extra_km) || ' km' end,
      'amount', v_extra);
  end if;
  return jsonb_build_object(
    'base', v_base, 'hours', v_hours, 'bookedHours', v_booked, 'earlyEnd', v_early, 'earlyEndPays', v_pays,
    'usedMinutes', round(v_used_min)::int, 'extensionMinutes', v_ext_min,
    'overtimeMinutes', v_over_min::int, 'overtime', v_overtime,
    'kmUsed', v_km, 'kmIncluded', v_included, 'extraKm', v_extra_km, 'extraKmAmount', v_extra,
    'placeFees', coalesce((q->>'placeFeesTotal')::numeric, 0),
    'fare', round(v_base + v_overtime + v_extra, 2),
    'endedBy', p_by, 'endedAt', p_at, 'lines', v_lines);
end;
$$;
revoke execute on function public.hire_settle(public.ride_requests, numeric, timestamptz, text) from public, anon, authenticated;

-- ---- 8. Cancelling a monthly hire: the notice ------------------------------------------------------
-- 0327's terms, with the notice: a monthly hire that has started keeps the
-- days within noticeDays of now. {free, fee, freeUntil, started, mode,
-- refund, noticeDays, noticeUntil}.
create or replace function public.hire_booking_cancel_terms(b public.hire_bookings)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hire_package_config(b.package);
  v_first timestamptz;
  v_started boolean;
  v_fee numeric := 0;
  v_until timestamptz;
  v_notice integer := coalesce((cfg->>'noticeDays')::int, 0);
  v_keep numeric := 0;
begin
  select min(pickup_at), bool_or(status in ('released', 'completed')) into v_first, v_started
    from public.scheduled_rides where hire_booking_id = b.id;
  v_first := coalesce(v_first, b.first_at);
  v_until := b.first_at - make_interval(hours => (cfg->>'freeCancelHours')::int);
  if coalesce(v_started, false) and v_notice > 0 then
    -- The days within the notice still happen, and are paid for.
    select coalesce(sum(public.ride_amount_due(jsonb_populate_record(null::public.ride_requests, s.request))), 0)
      into v_keep
      from public.scheduled_rides s
     where s.hire_booking_id = b.id and s.status in ('scheduled', 'assigned')
       and s.pickup_at < now() + make_interval(days => v_notice);
    return jsonb_build_object('free', true, 'fee', 0, 'freeUntil', v_until, 'started', true,
                              'mode', cfg->>'lateCancelMode', 'noticeDays', v_notice,
                              'noticeUntil', now() + make_interval(days => v_notice),
                              'refund', greatest(0, public.hire_booking_pot(b) - v_keep));
  end if;
  if not coalesce(v_started, false) and now() >= v_until and b.payment_plan <> 'business' then
    v_fee := case cfg->>'lateCancelMode'
      when 'percent' then round(b.price * (cfg->>'lateCancelPercent')::numeric / 100, 2)
      when 'first_day' then (select public.ride_amount_due(jsonb_populate_record(null::public.ride_requests, s.request))
                               from public.scheduled_rides s where s.hire_booking_id = b.id order by s.hire_day_no limit 1)
      -- The deposit: its percent of the price, whether it was paid as a
      -- deposit or with the rest (prepaid).
      else round(b.price * coalesce((b.quote->>'depositPercent')::numeric, (cfg->>'depositPercent')::numeric) / 100, 2) end;
    v_fee := least(coalesce(v_fee, 0), public.hire_booking_pot(b));
  end if;
  return jsonb_build_object('free', v_fee = 0, 'fee', v_fee, 'freeUntil', v_until,
                            'started', coalesce(v_started, false), 'mode', cfg->>'lateCancelMode',
                            'noticeDays', v_notice, 'refund', public.hire_booking_pot(b) - v_fee);
end;
$$;
revoke execute on function public.hire_booking_cancel_terms(public.hire_bookings) from public, anon, authenticated;

-- 0327's cancel, with a monthly hire's notice once it has started: the days
-- after the notice are cancelled, the rest go ahead, and what is left of
-- its money is refunded when the last one ends.
create or replace function public.hire_booking_cancel(p_booking uuid, p_reason text default null)
returns public.hire_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  v_admin boolean;
  t jsonb;
  v_from timestamptz;
  v_driver uuid;
begin
  select * into b from public.hire_bookings where id = p_booking for update;
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_admin := b.rider_id is distinct from auth.uid();
  if v_admin and not public.caller_admin_can_write('rpc:hire_booking_admin') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status not in ('booked', 'assigned', 'in_progress') then
    raise exception 'SCHEDULED_CLOSED' using hint = 'This hire can no longer be cancelled.';
  end if;
  if exists (select 1 from public.ride_requests where hire_booking_id = b.id and status = 'on_trip') then
    raise exception 'SCHEDULED_ON_TRIP' using hint = 'Today''s hire is on the go. Cancel once it has ended.';
  end if;
  t := public.hire_booking_cancel_terms(b);
  if not v_admin and t ? 'noticeUntil' then
    v_from := (t->>'noticeUntil')::timestamptz;
    for v_driver in
      select distinct partner_id from public.scheduled_rides
       where hire_booking_id = b.id and partner_id is not null and status in ('scheduled', 'assigned')
         and pickup_at >= v_from
    loop
      perform public.enqueue_notification(v_driver, 'hire-notice-' || b.id || '-' || v_driver, 'scheduled_ride', 'normal',
        'Hire ending early',
        format('The %s ends after %s: the days after that are cancelled.', lower(coalesce(b.quote->>'title', 'hire')),
               public.scheduled_when(v_from)),
        jsonb_build_object('type', 'hire_notice', 'hire_booking_id', b.id));
    end loop;
    update public.hire_bookings set notice_until = v_from, cancel_reason = left(p_reason, 200) where id = b.id;
    perform set_config('getride.hire_booking_cancel', b.id::text, true);
    update public.scheduled_rides
       set status = 'cancelled', cancelled_at = now(), cancelled_by = 'rider',
           cancel_reason = left(coalesce(p_reason, 'Hire ended with notice'), 200)
     where hire_booking_id = b.id and status in ('scheduled', 'assigned') and pickup_at >= v_from;
    perform set_config('getride.hire_booking_cancel', '', true);
    perform public.hire_booking_sync(b.id);
    select * into b from public.hire_bookings where id = b.id;
    return b;
  end if;
  return public.hire_booking_close(b.id, case when v_admin then 'admin' else 'rider' end, p_reason,
                                   case when v_admin then 0 else (t->>'fee')::numeric end);
end;
$$;
revoke execute on function public.hire_booking_cancel(uuid, text) from public, anon;
grant execute on function public.hire_booking_cancel(uuid, text) to authenticated;

-- ---- 9. Drivers: the admin assigns -----------------------------------------------------------------
-- Approved drivers who take hire, for the admin to choose from for
-- [p_booking] (or its day [p_day]): free when no day clashes.
create or replace function public.hire_booking_admin_drivers(p_booking uuid, p_day integer default null)
returns table(id uuid, name text, phone text, free boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:hire_booking_admin') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select p.auth_user_id, coalesce(nullif(btrim(p.name), ''), 'Driver'), p.phone,
           not exists (select 1 from public.scheduled_rides s
                        where s.hire_booking_id = p_booking and s.status in ('scheduled', 'assigned')
                          and (p_day is null or s.hire_day_no = p_day)
                          and public.scheduled_partner_clash(p.auth_user_id, s.pickup_at, s.id))
      from public.partners p
     where p.auth_user_id is not null and (p.status = 'approved' or p.status::text like 'permit-%')
       and public.driver_takes_hire(p.auth_user_id)
     order by 4 desc, 2
     limit 300;
end;
$$;
revoke execute on function public.hire_booking_admin_drivers(uuid, integer) from public, anon;
grant execute on function public.hire_booking_admin_drivers(uuid, integer) to authenticated;

-- The admin gives [p_driver] every day of [p_booking] still to come (or
-- only day [p_day]): the days not yet released, with the clash check.
create or replace function public.hire_booking_admin_assign(p_booking uuid, p_driver uuid, p_day integer default null)
returns public.hire_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  s public.scheduled_rides;
  n integer := 0;
begin
  if not public.caller_admin_can_write('rpc:hire_booking_admin') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into b from public.hire_bookings where id = p_booking for update;
  if not found or b.status not in ('booked', 'assigned', 'in_progress') then
    raise exception 'SCHEDULED_CLOSED' using hint = 'This hire is no longer open.';
  end if;
  if not exists (select 1 from public.partners p where p.auth_user_id = p_driver
                    and (p.status = 'approved' or p.status::text like 'permit-%')) then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Choose an approved driver.';
  end if;
  if not public.driver_takes_hire(p_driver) then
    raise exception 'HIRE_DRIVER_OFF' using errcode = '42501', hint = 'This driver doesn''t take hire.';
  end if;
  for s in select * from public.scheduled_rides
            where hire_booking_id = b.id and status in ('scheduled', 'assigned') and pickup_at > now()
              and (p_day is null or hire_day_no = p_day)
              and partner_id is distinct from p_driver
            order by hire_day_no
  loop
    if public.scheduled_partner_clash(p_driver, s.pickup_at, s.id) then
      raise exception 'SCHEDULED_CLASH' using hint = format('The driver has a ride within an hour of day %s (%s).',
        s.hire_day_no, public.scheduled_when(s.pickup_at));
    end if;
    n := n + 1;
  end loop;
  if n = 0 then
    raise exception 'SCHEDULED_TAKEN' using hint = 'No day still to come to give this driver.';
  end if;
  perform set_config('getride.hire_whole', b.id::text, true);
  update public.scheduled_rides set status = 'assigned', partner_id = p_driver, partner_accepted_at = now()
   where hire_booking_id = b.id and status in ('scheduled', 'assigned') and pickup_at > now()
     and (p_day is null or hire_day_no = p_day)
     and partner_id is distinct from p_driver;
  perform set_config('getride.hire_whole', '', true);
  if p_day is null then
    update public.hire_bookings set partner_id = p_driver, partner_accepted_at = now(),
           status = case when status = 'booked' then 'assigned' else status end
     where id = b.id;
  end if;
  perform public.enqueue_notification(p_driver, 'hire-admin-assign-' || b.id || '-' || coalesce(p_day, 0) || '-' || p_driver,
    'scheduled_ride', 'normal', 'Hire given to you',
    format('You have the %s from %s%s.', lower(coalesce(b.quote->>'title', 'hire')), public.scheduled_when(b.first_at),
           case when p_day is null then '' else ', day ' || p_day end),
    jsonb_build_object('type', 'hire_assigned', 'hire_booking_id', b.id));
  perform public.enqueue_notification(b.rider_id, 'hire-admin-driver-' || b.id || '-' || coalesce(p_day, 0) || '-' || p_driver,
    'scheduled_ride', 'normal', 'Driver confirmed',
    case when p_day is null then 'A driver is confirmed for the days of your hire still to come.'
         else format('A driver is confirmed for day %s of your hire.', p_day) end,
    jsonb_build_object('type', 'hire_assigned', 'hire_booking_id', b.id));
  select * into b from public.hire_bookings where id = b.id;
  return b;
end;
$$;
revoke execute on function public.hire_booking_admin_assign(uuid, uuid, integer) from public, anon;
grant execute on function public.hire_booking_admin_assign(uuid, uuid, integer) to authenticated;

-- ---- 10. The drivers' list of whole bookings: the weeks and weekdays -----------------------------------
drop function if exists public.hire_bookings_open();
create or replace function public.hire_bookings_open()
returns table(id uuid, package text, title text, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, first_at timestamptz, days integer,
              hours_per_day numeric, km_per_day numeric, overnight boolean, fare numeric, currency text,
              day_list jsonb, stops jsonb, periods integer, weekdays smallint[], km_per_period numeric)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.package, b.quote->>'title', b.service, b.pickup_address, b.drop_address, b.pickup_lat, b.pickup_lng,
         b.first_at, b.days, b.hours_per_day, b.km_per_day, b.overnight,
         (select coalesce(sum(s.fare), 0) from public.scheduled_rides s where s.hire_booking_id = b.id),
         b.currency,
         (select coalesce(jsonb_agg(jsonb_build_object('day', s.hire_day_no, 'pickup_at', s.pickup_at, 'fare', s.fare)
                                    order by s.hire_day_no), '[]'::jsonb)
            from public.scheduled_rides s where s.hire_booking_id = b.id and s.status = 'scheduled'),
         b.stops, b.periods, b.weekdays, b.km_per_period
    from public.hire_bookings b
   where b.status = 'booked' and b.partner_id is null and b.same_driver and b.split_at is null
     and b.first_at > now()
     and public.caller_is_approved_partner()
     and b.rider_id <> auth.uid()
     and not public.rider_blocks_driver(b.rider_id, auth.uid())
     and public.driver_takes_hire(auth.uid())
     and public.driver_takes_service(auth.uid(), b.service)
     and public.service_order_driver_allows(auth.uid(), b.service)
     and public.driver_permit_problem(auth.uid()) is null
   order by b.first_at
   limit 100;
$$;
revoke execute on function public.hire_bookings_open() from public, anon;
grant execute on function public.hire_bookings_open() to authenticated, service_role;

-- ---- 11. Admin › Hire bookings ------------------------------------------------------------------
-- Every hire for several days, newest first, filtered by status, package,
-- the rider (name or phone), the booking's id and the first day's date
-- (from / to, in the booking's time zone), [p_limit] rows from [p_offset];
-- total is how many match. Any admin reads it; assigning and cancelling
-- are hire_booking_admin_assign and hire_booking_cancel.
drop function if exists public.hire_bookings_admin(text, text, text, date, date, integer, integer);
create or replace function public.hire_bookings_admin(p_status text default null, p_package text default null,
                                                      p_query text default null, p_from date default null,
                                                      p_to date default null, p_limit integer default 50,
                                                      p_offset integer default 0)
returns table(id uuid, package text, title text, status text, service text, first_at timestamptz,
              last_at timestamptz, days integer, price numeric, paid_amount numeric, deposit_amount numeric,
              balance_amount numeric, payment_plan text, payment_state text, currency text, split_at timestamptz,
              same_driver boolean, rider_id uuid, rider_name text, rider_phone text, partner_id uuid,
              partner_name text, created_at timestamptz, total bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q text := nullif(lower(btrim(coalesce(p_query, ''))), '');
  digits text := nullif(regexp_replace(coalesce(p_query, ''), '\D', '', 'g'), '');
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select b.id, b.package, coalesce(b.quote->>'title', initcap(b.package) || ' hire'), b.status, b.service,
           b.first_at,
           (select max(s.pickup_at) from public.scheduled_rides s where s.hire_booking_id = b.id),
           b.days, b.price, b.paid_amount, b.deposit_amount, b.balance_amount, b.payment_plan, b.payment_state,
           b.currency, b.split_at, b.same_driver, b.rider_id, rp.name, rp.phone, b.partner_id,
           coalesce(nullif(btrim(pp.name), ''), dp.name), b.created_at,
           count(*) over ()
      from public.hire_bookings b
      left join public.profiles rp on rp.id = b.rider_id
      left join public.profiles dp on dp.id = b.partner_id
      left join lateral (select p.name from public.partners p where p.auth_user_id = b.partner_id limit 1) pp on true
     where (p_status is null or b.status = p_status)
       and (p_package is null or b.package = p_package)
       and (p_from is null or (b.first_at at time zone b.timezone)::date >= p_from)
       and (p_to is null or (b.first_at at time zone b.timezone)::date <= p_to)
       and (q is null
            or b.id::text like q || '%'
            or lower(coalesce(rp.name, '')) like '%' || q || '%'
            or (digits is not null and length(digits) >= 4
                and regexp_replace(coalesce(rp.phone, ''), '\D', '', 'g') like '%' || digits || '%'))
     order by b.created_at desc
     limit least(200, greatest(1, coalesce(p_limit, 50))) offset greatest(0, coalesce(p_offset, 0));
end;
$$;
revoke execute on function public.hire_bookings_admin(text, text, text, date, date, integer, integer) from public, anon;
grant execute on function public.hire_bookings_admin(text, text, text, date, date, integer, integer) to authenticated;

notify pgrst, 'reload schema';
