-- ============================================================================
-- 0327 — Daily hire: a driver and car for 1 to N days, booked ahead.
--
-- One booking (hire_bookings) and one scheduled_rides row per day
-- (hire_package 'daily', hire_booking_id, hire_day_no), each released before
-- its start as a scheduled ride is. Each released day is a ride_requests row
-- with the 0326 hire columns, so the 12-hour limits, dispatch, the trip
-- screen, Extend, End hire, payment, commission, statements and receipts are
-- 0326's. Nothing here is a second trip table.
--
-- 1. Settings (app_settings 'daily_hire', hire_package_config('daily') /
--    set_hire_package_config, Admin › Settings › Daily hire): on / off, the
--    most days, the hours a day (least, most, the default), the km a day,
--    the lead time and how far ahead, the deposit percent and whether a
--    rider may prepay, the free-cancel hours and what a late cancel costs
--    ('deposit', a 'percent', the 'first_day'), the same-driver default, the
--    cut-off before day 1 after which each day is offered on its own (or the
--    booking is closed, refunded), the overnight and meal allowances, the
--    most open bookings and the labels.
-- 2. Rates per Vehicle Service (hireDayRate, hireDayHours, hireDayKm,
--    hireDayOvertimePerHour, hireDayExtraKm, hireOvernight) and per fare
--    tariff card (hire_day_* and hire_overnight columns), resolved as 0326
--    resolves hourly: the narrowest card, else the service, else the
--    fallback (the hourly rate × the day's hours, the settings' hours and km
--    a day, the hourly overtime and extra km, the settings' overnight).
-- 3. hire_multi_quote: the days, their dates (each day at the same local
--    start time), the day price (the day rate for the service's hours a day,
--    pro rata for the hours chosen), the place fees a day, the allowances,
--    the total, the deposit and the free-cancel time. HIRE_DAYS, HIRE_HOURS,
--    HIRE_LEAD, HIRE_AHEAD, HIRE_CASH, HIRE_PAY refusals.
-- 4. hire_book: the booking and its day rows (scheduled_rides, through every
--    booking trigger: business, place fees, Family...), the total as each
--    day's amount due (taxes included), then the deposit (or the whole
--    total, prepaid) from GET.wallet with ride_id = the booking, so Family's
--    layer charges the host. A business booking pays nothing upfront: each
--    day is charged to the account as a ride is.
-- 5. Drivers: hire_bookings_open lists bookings waiting for one driver for
--    every day (to drivers who take hire); hire_booking_accept takes all its
--    days, with the clash check over every day's span. While a booking waits
--    for one driver its days are not listed or taken one by one
--    (HIRE_WHOLE_BOOKING). The rider can switch the same driver off: each
--    day is then offered on its own from the start.
-- 6. The minute's tick (hire_tick): at splitAfterHours before day 1 a
--    booking nobody took whole is split (each day offered on its own), or
--    closed and refunded when splitDays is off.
-- 7. Money per day: when a day is released the balance is charged (day 1),
--    then the day's amount due is moved from the booking's prepaid money to
--    a hire_holds row for that day's ride (no new charge); 0326's ride_pay
--    returns it before charging the settled day, so only overtime, extra km
--    and declared tolls are new money. A day cancelled or expired puts its
--    share back into the booking; what is left when the booking ends is
--    refunded (to the host where the family paid).
-- 8. Cancel (hire_booking_cancel): free until freeCancelHours before day 1;
--    after that the late fee (lateCancelMode), never more than was paid.
--    Once a day has been released the remaining days are cancelled free.
-- 9. Family: module 'hire' (0326) for the booking and for each day row
--    (family_attach_trip from hire_bookings_family and scheduled_rides_family).
-- 10. Hourly gaps: a business account can book hire (priced before the
--    business check runs: trg_ride_requests_c_ahire_price); whole-fare
--    regions round the hire price up; a later hire booked in cash after the
--    admin turned cash off goes by hourly_hire.cashOffLater ('cash': as
--    booked, 'wallet': switched to GET.wallet and the rider told, 'cancel':
--    cancelled free and the rider told).
-- ============================================================================

-- ---- 1. Columns -----------------------------------------------------------------------------------
alter table public.ride_requests add column if not exists hire_booking_id uuid;
alter table public.ride_requests add column if not exists hire_day_no integer;
alter table public.ride_requests drop constraint if exists ride_requests_hire_valid;
alter table public.ride_requests add constraint ride_requests_hire_valid check (
  (hire_package is null or hire_package in ('hourly', 'daily'))
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
create index if not exists ride_requests_hire_booking_idx on public.ride_requests (hire_booking_id)
  where hire_booking_id is not null;

alter table public.scheduled_rides add column if not exists hire_booking_id uuid;
alter table public.scheduled_rides add column if not exists hire_day_no integer;
alter table public.scheduled_rides drop constraint if exists scheduled_rides_hire_valid;
alter table public.scheduled_rides add constraint scheduled_rides_hire_valid check (
  (hire_package is null or hire_package in ('hourly', 'daily')) and (hire_hours is null or hire_hours between 0.5 and 72)
  and (hire_day_no is null or hire_day_no between 1 and 400));
create index if not exists scheduled_rides_hire_booking_idx on public.scheduled_rides (hire_booking_id, hire_day_no)
  where hire_booking_id is not null;

alter table public.fare_tariffs add column if not exists hire_day_rate numeric(10,2);
alter table public.fare_tariffs add column if not exists hire_day_hours numeric(4,1);
alter table public.fare_tariffs add column if not exists hire_day_km numeric(8,1);
alter table public.fare_tariffs add column if not exists hire_day_overtime_per_hour numeric(10,2);
alter table public.fare_tariffs add column if not exists hire_day_extra_km numeric(10,2);
alter table public.fare_tariffs add column if not exists hire_overnight numeric(10,2);
alter table public.fare_tariffs drop constraint if exists fare_tariffs_hire_day_valid;
alter table public.fare_tariffs add constraint fare_tariffs_hire_day_valid check (
  (hire_day_rate is null or hire_day_rate between 0 and 1000000)
  and (hire_day_hours is null or hire_day_hours between 1 and 24)
  and (hire_day_km is null or hire_day_km between 0 and 5000)
  and (hire_day_overtime_per_hour is null or hire_day_overtime_per_hour between 0 and 100000)
  and (hire_day_extra_km is null or hire_day_extra_km between 0 and 10000)
  and (hire_overnight is null or hire_overnight between 0 and 100000));

-- ---- 2. The bookings -----------------------------------------------------------------------------
create table if not exists public.hire_bookings (
  id                  uuid primary key default gen_random_uuid(),
  rider_id            uuid not null references auth.users(id) on delete cascade,
  package             text not null,
  service             text not null,
  status              text not null default 'booked',
  pickup_name         text,
  pickup_address      text,
  pickup_lat          double precision not null,
  pickup_lng          double precision not null,
  drop_name           text,
  drop_address        text,
  drop_lat            double precision,
  drop_lng            double precision,
  stops               jsonb,
  first_at            timestamptz not null,
  days                integer not null,
  timezone            text not null default 'Asia/Kuala_Lumpur',
  hours_per_day       numeric(4,1) not null,
  km_per_day          numeric(8,1),
  overnight           boolean not null default false,
  same_driver         boolean not null default true,
  split_at            timestamptz,
  partner_id          uuid,
  partner_accepted_at timestamptz,
  payment_mode        text,
  payment_plan        text not null default 'deposit',
  price               numeric(12,2) not null default 0,
  deposit_amount      numeric(12,2) not null default 0,
  balance_amount      numeric(12,2) not null default 0,
  paid_amount         numeric(12,2) not null default 0,
  allocated_amount    numeric(12,2) not null default 0,
  refunded_amount     numeric(12,2) not null default 0,
  kept_amount         numeric(12,2) not null default 0,
  payment_state       text not null default 'none',
  quote               jsonb not null default '{}'::jsonb,
  currency            text,
  booked_for_name     text,
  booked_for_phone    text,
  family              jsonb,
  business_account_id uuid,
  cancelled_at        timestamptz,
  cancelled_by        text,
  cancel_reason       text,
  cancel_fee          numeric(12,2) not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
alter table public.hire_bookings drop constraint if exists hire_bookings_valid;
alter table public.hire_bookings add constraint hire_bookings_valid check (
  package in ('daily')
  and status in ('booked', 'assigned', 'in_progress', 'completed', 'cancelled', 'expired')
  and days between 1 and 400
  and hours_per_day between 0.5 and 24
  and (km_per_day is null or km_per_day between 0 and 100000)
  and payment_plan in ('deposit', 'prepay', 'business')
  and payment_state in ('none', 'deposit_paid', 'paid', 'balance_short', 'business')
  and (cancelled_by is null or cancelled_by in ('rider', 'admin', 'system'))
  and price >= 0 and deposit_amount >= 0 and balance_amount >= 0 and paid_amount >= 0
  and allocated_amount >= 0 and refunded_amount >= 0 and kept_amount >= 0 and cancel_fee >= 0
  and jsonb_typeof(quote) = 'object' and pg_column_size(quote) <= 65536
  and (stops is null or (jsonb_typeof(stops) = 'array' and pg_column_size(stops) <= 16384)));
create index if not exists hire_bookings_rider_idx on public.hire_bookings (rider_id, first_at desc);
create index if not exists hire_bookings_open_idx on public.hire_bookings (status, first_at)
  where status in ('booked', 'assigned', 'in_progress');
create index if not exists hire_bookings_partner_idx on public.hire_bookings (partner_id) where partner_id is not null;

drop trigger if exists trg_hire_bookings_updated_at on public.hire_bookings;
create trigger trg_hire_bookings_updated_at
  before update on public.hire_bookings
  for each row execute function public.set_updated_at();

alter table public.hire_bookings enable row level security;
revoke all on public.hire_bookings from anon, authenticated;
grant select on public.hire_bookings to authenticated;
drop policy if exists "hire_bookings read" on public.hire_bookings;
create policy "hire_bookings read" on public.hire_bookings for select to authenticated
  using (rider_id = (select auth.uid()) or partner_id = (select auth.uid()) or (select public.caller_is_admin())
         or exists (select 1 from public.scheduled_rides s
                     where s.hire_booking_id = hire_bookings.id and s.partner_id = (select auth.uid())));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'hire_bookings') then
    alter publication supabase_realtime add table public.hire_bookings;
  end if;
end $$;

-- ---- 3. Settings ---------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('daily_hire', '{}'::jsonb) on conflict (key) do nothing;

-- A number from [v] within [lo, hi], else [d].
create or replace function public.hire_cfg_num(v jsonb, d numeric, lo numeric, hi numeric)
returns numeric
language sql
immutable
set search_path = public
as $$ select least(hi, greatest(lo, coalesce(public.hire_num(v), d))); $$;

-- A booking package's settings with every key (a missing or wrong one
-- takes its default). 0328 adds weekly and monthly.
create or replace function public.hire_multi_normalize(p_package text, v jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  b jsonb := '{}'::jsonb;
  k text;
  v_min numeric;
  v_max numeric;
  v_mode text;
  v_chip text;
  v_title text;
begin
  if p_package is distinct from 'daily' then
    return null;
  end if;
  v := coalesce(v, '{}'::jsonb);
  foreach k in array array['enabled', 'allowPrepay', 'sameDriverDefault', 'splitDays'] loop
    b := b || jsonb_build_object(k, case when jsonb_typeof(v->k) = 'boolean' then (v->>k)::boolean
                                         else k <> 'enabled' end);
  end loop;
  v_min := round(public.hire_cfg_num(v->'minHoursPerDay', 8, 1, 24) * 2) / 2;
  v_max := greatest(v_min, round(public.hire_cfg_num(v->'maxHoursPerDay', 12, 1, 24) * 2) / 2);
  v_mode := v->>'lateCancelMode';
  v_chip := btrim(coalesce(v#>>'{labels,chip}', ''));
  v_title := btrim(coalesce(v#>>'{labels,title}', ''));
  return b || jsonb_build_object(
    'package', 'daily',
    'maxDays', public.hire_cfg_num(v->'maxDays', 6, 1, 60)::int,
    'minHoursPerDay', v_min,
    'maxHoursPerDay', v_max,
    'hoursPerDayDefault', least(v_max, greatest(v_min, round(public.hire_cfg_num(v->'hoursPerDayDefault', 10, 1, 24) * 2) / 2)),
    'kmPerDayDefault', round(public.hire_cfg_num(v->'kmPerDayDefault', 200, 0, 5000), 1),
    'leadHours', public.hire_cfg_num(v->'leadHours', 12, 0, 720)::int,
    'bookAheadDays', public.hire_cfg_num(v->'bookAheadDays', 30, 1, 365)::int,
    'depositPercent', round(public.hire_cfg_num(v->'depositPercent', 30, 0, 100), 2),
    'freeCancelHours', public.hire_cfg_num(v->'freeCancelHours', 24, 0, 720)::int,
    'lateCancelMode', case when v_mode in ('deposit', 'percent', 'first_day') then v_mode else 'deposit' end,
    'lateCancelPercent', round(public.hire_cfg_num(v->'lateCancelPercent', 50, 0, 100), 2),
    'splitAfterHours', public.hire_cfg_num(v->'splitAfterHours', 6, 0, 720)::int,
    'overnightAllowance', round(public.hire_cfg_num(v->'overnightAllowance', 50, 0, 100000), 2),
    'mealAllowance', round(public.hire_cfg_num(v->'mealAllowance', 0, 0, 100000), 2),
    'maxOpenBookings', public.hire_cfg_num(v->'maxOpenBookings', 3, 1, 20)::int,
    'labels', jsonb_build_object(
      'chip', case when char_length(v_chip) between 1 and 20 then v_chip else 'Daily' end,
      'title', case when char_length(v_title) between 1 and 40 then v_title else 'Daily hire' end));
end;
$$;
revoke execute on function public.hire_multi_normalize(text, jsonb) from public, anon, authenticated;

create or replace function public.hire_package_config(p_package text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.hire_multi_normalize(p_package,
           coalesce((select value from public.app_settings where key = p_package || '_hire'), '{}'::jsonb));
$$;
revoke execute on function public.hire_package_config(text) from public;
grant execute on function public.hire_package_config(text) to anon, authenticated, service_role;

-- Admin › Settings › Daily hire (and 0328's weekly and monthly).
create or replace function public.set_hire_package_config(p_package text, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_hire_package_config') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the hire settings.';
  end if;
  if jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'HIRE_CONFIG_INVALID' using errcode = '22023';
  end if;
  v := public.hire_multi_normalize(p_package, p_config);
  if v is null then
    raise exception 'HIRE_CONFIG_INVALID' using errcode = '22023', hint = 'Unknown hire package.';
  end if;
  insert into public.app_settings (key, value, updated_at) values (p_package || '_hire', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_hire_package_config(text, jsonb) from public, anon;
grant execute on function public.set_hire_package_config(text, jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:set_hire_package_config', 'admin-settings-site'),
  ('rpc:hire_booking_admin', 'admin-rides')
on conflict do nothing;

-- 0326's hourly settings, plus cashOffLater: what a booking for later paid
-- in cash does at its release when the admin has since turned cash off.
create or replace function public.hourly_hire_normalize(v jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  b jsonb := '{}'::jsonb;
  k text;
  d boolean;
  v_min numeric;
  v_max numeric;
  v_step numeric;
  v_choices jsonb;
  v_pays text := v->>'earlyEndPays';
  v_cash text := v->>'cashOffLater';
  v_tile text := btrim(coalesce(v->>'tileTitle', ''));
  v_trip text := btrim(coalesce(v#>>'{panelLabels,trip}', ''));
  v_hire text := btrim(coalesce(v#>>'{panelLabels,hire}', ''));
  n numeric;
begin
  v := coalesce(v, '{}'::jsonb);
  foreach k in array array['enabled', 'allowNow', 'allowLater', 'extendNeedsRider', 'riderCanEndEarly',
                           'holdInWallet', 'allowCash'] loop
    d := k not in ('enabled', 'allowCash');
    b := b || jsonb_build_object(k, case when jsonb_typeof(v->k) = 'boolean' then (v->>k)::boolean else d end);
  end loop;
  v_step := case when public.hire_num(v->'hourStep') = 0.5 then 0.5 else 1 end;
  v_min := least(24, greatest(0.5, coalesce(public.hire_num(v->'minHours'), 2)));
  v_min := ceil(v_min / v_step) * v_step;
  v_max := least(72, greatest(v_min, coalesce(public.hire_num(v->'maxHours'), 12)));
  v_max := greatest(v_min, floor(v_max / v_step) * v_step);
  select coalesce(jsonb_agg(m order by m), '[]'::jsonb) into v_choices
    from (select distinct x::int as m
            from jsonb_array_elements(case when jsonb_typeof(v->'extendChoices') = 'array'
                                           then v->'extendChoices' else '[30,60,120]'::jsonb end) e,
                 lateral (select public.hire_num(e) as x) y
           where x is not null and x between 5 and 720 and x = round(x)
           limit 6) c;
  if v_choices = '[]'::jsonb then
    v_choices := '[30,60,120]'::jsonb;
  end if;
  n := public.hire_num(v->'holdBufferPercent');
  return b || jsonb_build_object(
    'minHours', v_min,
    'maxHours', v_max,
    'hourStep', v_step,
    'stepMinutes', least(120, greatest(5, coalesce(round(public.hire_num(v->'stepMinutes')), 30)))::int,
    'extendChoices', v_choices,
    'earlyEndPays', case when v_pays in ('booked', 'minimum', 'used') then v_pays else 'booked' end,
    'holdBufferPercent', round(least(100, greatest(0, coalesce(n, 0))), 2),
    'kmPerHourDefault', round(least(500, greatest(0, coalesce(public.hire_num(v->'kmPerHourDefault'), 20))), 1),
    'reminderBeforeEndMin', least(240, greatest(0, coalesce(round(public.hire_num(v->'reminderBeforeEndMin')), 15)))::int,
    'autoEndAfterMin', least(1440, greatest(5, coalesce(round(public.hire_num(v->'autoEndAfterMin')), 30)))::int,
    'cashOffLater', case when v_cash in ('cash', 'wallet', 'cancel') then v_cash else 'cash' end,
    'tileTitle', case when char_length(v_tile) between 1 and 40 then v_tile else 'Hire a driver' end,
    'panelLabels', jsonb_build_object(
      'trip', case when char_length(v_trip) between 1 and 30 then v_trip else 'Go somewhere' end,
      'hire', case when char_length(v_hire) between 1 and 30 then v_hire else 'Hire by time' end));
end;
$$;
revoke execute on function public.hourly_hire_normalize(jsonb) from public, anon, authenticated;

-- ---- 4. Rates ------------------------------------------------------------------------------------
-- A service's multi-day rates where the pickup is: each value from the
-- narrowest tariff card that sets it, else the Vehicle Service's own, else
-- the fallback. {enabled, service, dayRate, dayHours, kmPerDay,
-- overtimePerHour, extraKm, overnight}. 0328 adds week and month rates.
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
  end loop;
  v_hours := least(24, greatest(1, coalesce(v_hours, public.hire_num(v->'hireDayHours'),
                                            (cfg->>'hoursPerDayDefault')::numeric, 10)));
  v_rate := coalesce(v_rate, public.hire_num(v->'hireDayRate'),
                     case when (h->>'perHour')::numeric > 0 then (h->>'perHour')::numeric * v_hours end);
  v_km := coalesce(v_km, public.hire_num(v->'hireDayKm'), (cfg->>'kmPerDayDefault')::numeric, 0);
  v_ot := coalesce(v_ot, public.hire_num(v->'hireDayOvertimePerHour'), (h->>'overtimePerHour')::numeric, 0);
  v_xkm := coalesce(v_xkm, public.hire_num(v->'hireDayExtraKm'), (h->>'extraKm')::numeric, 0);
  v_night := coalesce(v_night, public.hire_num(v->'hireOvernight'), (cfg->>'overnightAllowance')::numeric, 0);
  return jsonb_build_object(
    'enabled', coalesce((h->>'enabled')::boolean, false),
    'service', true,
    'dayRate', case when v_rate > 0 then round(v_rate, 2) end,
    'dayHours', v_hours,
    'kmPerDay', round(greatest(0, v_km), 1),
    'overtimePerHour', round(greatest(0, v_ot), 2),
    'extraKm', round(greatest(0, v_xkm), 2),
    'overnight', round(greatest(0, v_night), 2));
end;
$$;
revoke execute on function public.hire_multi_rates(text, text, text, text, text, text) from public, anon, authenticated;

-- A time zone name the server knows, else Malaysia's.
create or replace function public.hire_tz(p text)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce((select n.name from pg_catalog.pg_timezone_names n where n.name = btrim(coalesce(p, '')) limit 1),
                  'Asia/Kuala_Lumpur');
$$;

-- What a refusal reason says to the rider (0326's, with the multi-day ones).
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
    when 'HIRE_LEAD' then format('Book at least %s hours ahead.', q->>'leadHours')
    when 'HIRE_AHEAD' then format('Book up to %s days ahead.', q->>'bookAheadDays')
    when 'HIRE_CASH' then case when q->>'package' in ('daily', 'weekly', 'monthly')
                               then 'This hire is paid in the app. Choose GET.wallet.'
                               else 'Hourly hire is paid in the app. Choose GET.wallet.' end
    when 'HIRE_PAY' then 'This hire is paid from GET.wallet, or charged to a business account.'
    when 'HIRE_PREPAY_OFF' then 'Paying the whole hire now is not offered. Pay the deposit.'
    when 'HIRE_NOW_OFF' then 'Hourly hire can only be booked for later.'
    when 'HIRE_LATER_OFF' then 'Hourly hire can''t be booked for later.'
    when 'HIRE_BUSINESS' then 'This hire can''t be charged to a business account.'
    else 'Hire is not available.' end;
$$;

-- ---- 5. The quote --------------------------------------------------------------------------------
-- The server's price for [p_days] days of [p_hours] a day of [p_service],
-- the first at [p_first_at] (each next day at the same local time in
-- [p_timezone]). [p_options]: 0328's weekdays and periods.
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
  v_reason text;
  v_days integer;
  v_hours numeric;
  v_first timestamptz := coalesce(p_first_at, now() + interval '1 day');
  v_local timestamp;
  v_dates jsonb := '[]'::jsonb;
  v_day numeric := 0;
  v_fees jsonb := '[]'::jsonb;
  v_fees_day numeric := 0;
  v_nights integer;
  v_night numeric;
  v_meal numeric;
  v_total numeric;
  v_kind text := public.hire_pay_kind(p_payment);
  q jsonb;
  i integer;
begin
  if cfg is null then
    return jsonb_build_object('available', false, 'reason', 'HIRE_OFF', 'package', p_package,
                              'hint', public.hire_hint('HIRE_OFF', jsonb_build_object('package', p_package)));
  end if;
  r := public.hire_multi_rates(p_package, p_service, p_country, p_state, p_city, p_suburb);
  v_days := coalesce(p_days, 1);
  v_hours := coalesce(p_hours, least((cfg->>'maxHoursPerDay')::numeric,
                                     greatest((cfg->>'minHoursPerDay')::numeric, coalesce((r->>'dayHours')::numeric, 10))));
  if not (cfg->>'enabled')::boolean then
    v_reason := 'HIRE_OFF';
  elsif not coalesce((r->>'enabled')::boolean, false) then
    v_reason := 'HIRE_SERVICE_OFF';
  elsif r->>'dayRate' is null then
    v_reason := 'HIRE_NO_RATE';
  elsif v_days < 1 or v_days > (cfg->>'maxDays')::int then
    v_reason := 'HIRE_DAYS';
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
  v_days := least((cfg->>'maxDays')::int, greatest(1, v_days));
  v_hours := least((cfg->>'maxHoursPerDay')::numeric, greatest((cfg->>'minHoursPerDay')::numeric, round(v_hours * 2) / 2));
  -- Each day at the same local start time.
  v_local := v_first at time zone v_tz;
  for i in 1 .. v_days loop
    v_dates := v_dates || to_jsonb((v_local + make_interval(days => i - 1)) at time zone v_tz);
  end loop;
  if r->>'dayRate' is not null then
    -- The day rate is for the service's hours a day; other hours pro rata.
    v_day := round((r->>'dayRate')::numeric * v_hours / greatest(1, (r->>'dayHours')::numeric), 2);
    v_fees := public.place_ride_charges(public.airport_at(p_pickup_lat, p_pickup_lng),
                                        public.airport_at(p_drop_lat, p_drop_lng), null, p_service, v_day, v_first);
    v_fees_day := coalesce((select round(sum((l->>'value')::numeric), 2) from jsonb_array_elements(v_fees) l), 0);
  end if;
  v_nights := case when coalesce(p_overnight, false) then v_days - 1 else 0 end;
  v_night := coalesce((r->>'overnight')::numeric, 0);
  v_meal := (cfg->>'mealAllowance')::numeric;
  v_total := round(v_day * v_days + v_fees_day * v_days + v_nights * v_night + v_days * v_meal, 2);
  q := jsonb_build_object(
    'available', v_reason is null,
    'reason', v_reason,
    'package', p_package,
    'title', cfg#>>'{labels,title}',
    'service', p_service,
    'days', v_days,
    'maxDays', (cfg->>'maxDays')::int,
    'hours', v_hours,
    'minHoursPerDay', (cfg->>'minHoursPerDay')::numeric,
    'maxHoursPerDay', (cfg->>'maxHoursPerDay')::numeric,
    'dayRate', (r->>'dayRate')::numeric,
    'dayHours', (r->>'dayHours')::numeric,
    'perDay', v_day,
    'kmPerDay', coalesce((r->>'kmPerDay')::numeric, 0),
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
    'base', round(v_day * v_days, 2),
    'total', v_total,
    'depositPercent', (cfg->>'depositPercent')::numeric,
    'deposit', round(v_total * (cfg->>'depositPercent')::numeric / 100, 2),
    'allowPrepay', (cfg->>'allowPrepay')::boolean,
    'sameDriverDefault', (cfg->>'sameDriverDefault')::boolean,
    'freeCancelHours', (cfg->>'freeCancelHours')::int,
    'freeCancelUntil', v_first - make_interval(hours => (cfg->>'freeCancelHours')::int),
    'lateCancelMode', cfg->>'lateCancelMode',
    'lateCancelPercent', (cfg->>'lateCancelPercent')::numeric,
    'leadHours', (cfg->>'leadHours')::int,
    'bookAheadDays', (cfg->>'bookAheadDays')::int,
    'firstAt', v_first,
    'timezone', v_tz,
    'dates', v_dates);
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

-- Day [p_day] of a booking's quote, shaped as an hourly quote (0326), so a
-- day's ride is priced, extended and ended as an hourly hire is.
create or replace function public.hire_day_quote(q jsonb, p_day integer)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'package', q->>'package', 'service', q->>'service', 'title', q->>'title',
    'hours', (q->>'hours')::numeric, 'minHours', (q->>'hours')::numeric, 'maxHours', (q->>'hours')::numeric,
    'hourStep', 0.5,
    'rate', round((q->>'perDay')::numeric / greatest(0.5, (q->>'hours')::numeric), 2),
    'kmPerHour', round(coalesce((q->>'kmPerDay')::numeric, 0) / greatest(0.5, (q->>'hours')::numeric), 1),
    'kmIncluded', coalesce((q->>'kmPerDay')::numeric, 0),
    'overtimePerHour', coalesce((q->>'overtimePerHour')::numeric, 0),
    'stepMinutes', coalesce((q->>'stepMinutes')::int, 30),
    'extraKm', coalesce((q->>'extraKm')::numeric, 0),
    'base', (q->>'perDay')::numeric,
    'placeFees', coalesce(q->'placeFees', '[]'::jsonb),
    'placeFeesTotal', coalesce((q->>'placeFeesPerDay')::numeric, 0),
    'meal', coalesce((q->>'mealAllowance')::numeric, 0),
    'overnight', case when coalesce((q->>'overnight')::boolean, false) and p_day < (q->>'days')::int
                      then coalesce((q->>'overnightAllowance')::numeric, 0) else 0 end,
    'total', round((q->>'perDay')::numeric + coalesce((q->>'placeFeesPerDay')::numeric, 0)
                   + coalesce((q->>'mealAllowance')::numeric, 0)
                   + case when coalesce((q->>'overnight')::boolean, false) and p_day < (q->>'days')::int
                          then coalesce((q->>'overnightAllowance')::numeric, 0) else 0 end, 2),
    'dayNo', p_day, 'days', (q->>'days')::int,
    'holdInWallet', false, 'hold', 0, 'allowCash', false);
$$;

-- ---- 6. A day row: priced from its booking --------------------------------------------------------
-- 0326's scheduled_rides_hire, with a booking's day ('daily': from its
-- booking's quote, its allowances as fixed charges, no scheduling fee), a
-- business account allowed, and a whole-fare region's price rounded up.
create or replace function public.scheduled_rides_hire()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  cfg jsonb;
  sc jsonb;
  quote jsonb;
  v_fee numeric;
  v_charges jsonb;
  b public.hire_bookings;
  v_day integer;
  v_label text;
begin
  if coalesce(q->>'hire_package', '') = '' then
    new.request := q - 'hire_package' - 'hire_hours' - 'hire_quote' - 'hire_booking_id' - 'hire_day_no';
    new.hire_package := null;
    new.hire_hours := null;
    new.hire_booking_id := null;
    new.hire_day_no := null;
    if jsonb_typeof(q->'option_names') = 'object' and q->'option_names' ? 'hire' then
      new.request := jsonb_set(new.request, '{option_names}', (q->'option_names') - 'hire');
    end if;
    return new;
  end if;

  -- A day of a booking: only hire_book writes one (with its booking's id).
  if q->>'hire_package' <> 'hourly' then
    if coalesce(q->>'hire_booking_id', '') ~* '^[0-9a-f-]{36}$' then
      select * into b from public.hire_bookings
       where id = (q->>'hire_booking_id')::uuid and rider_id = new.rider_id and package = q->>'hire_package';
    end if;
    v_day := case when jsonb_typeof(q->'hire_day_no') = 'number' then (q->>'hire_day_no')::int end;
    if b.id is null or v_day is null or v_day < 1 or v_day > b.days then
      perform public.hire_raise(jsonb_build_object('reason', 'HIRE_OFF', 'package', q->>'hire_package'));
    end if;
    quote := public.hire_day_quote(b.quote, v_day);
    new.hire_package := b.package;
    new.hire_hours := b.hours_per_day;
    new.hire_booking_id := b.id;
    new.hire_day_no := v_day;
    new.fare := (quote->>'base')::numeric;
    if (q->>'whole_fare')::boolean is true then
      new.fare := ceil(new.fare);
    end if;
    new.scheduling_fee := 0;
    select coalesce(jsonb_agg(c), '[]'::jsonb) into v_charges
      from jsonb_array_elements(case when jsonb_typeof(q->'charges') = 'array' then q->'charges' else '[]'::jsonb end) c
     where jsonb_typeof(c) = 'object'
       and not (c->>'kind' = 'surcharge' and c->>'name' in ('Scheduling fee', 'Meal allowance', 'Overnight allowance'));
    if (quote->>'meal')::numeric > 0 then
      v_charges := v_charges || jsonb_build_array(jsonb_build_object(
        'kind', 'surcharge', 'name', 'Meal allowance', 'charge', 'fixed', 'value', (quote->>'meal')::numeric));
    end if;
    if (quote->>'overnight')::numeric > 0 then
      v_charges := v_charges || jsonb_build_array(jsonb_build_object(
        'kind', 'surcharge', 'name', 'Overnight allowance', 'charge', 'fixed', 'value', (quote->>'overnight')::numeric));
    end if;
    v_label := coalesce(b.quote->>'title', 'Hire');
    new.request := (q - 'auto_accept_fare') || jsonb_build_object(
      'fare', new.fare, 'ride_fare', new.fare, 'offer_me', false,
      'hire_package', b.package, 'hire_hours', b.hours_per_day,
      'hire_booking_id', b.id, 'hire_day_no', v_day,
      'hire_quote', quote, 'charges', v_charges,
      'option_names', coalesce(case when jsonb_typeof(q->'option_names') = 'object' then q->'option_names' end,
                               '{}'::jsonb) || jsonb_build_object('hire', v_label));
    return new;
  end if;

  new.hire_booking_id := null;
  new.hire_day_no := null;
  cfg := public.hourly_hire_config();
  if (cfg->>'enabled')::boolean and not (cfg->>'allowLater')::boolean then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_LATER_OFF'));
  end if;
  quote := public.hire_quote(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng,
                             coalesce(new.service, q->>'service'), public.hire_num(q->'hire_hours'), new.pickup_at,
                             q->>'country', q->>'state', q->>'city', q->>'suburb', q->>'payment_mode');
  if not (quote->>'available')::boolean then
    perform public.hire_raise(quote);
  end if;
  new.hire_package := 'hourly';
  new.hire_hours := (quote->>'hours')::numeric;
  new.fare := (quote->>'base')::numeric;
  -- 0327: a whole-fare region's price, rounded up as a ride's is.
  if (q->>'whole_fare')::boolean is true then
    new.fare := ceil(new.fare);
  end if;
  -- The scheduling fee on the hire's price.
  sc := public.scheduled_rides_config();
  v_fee := round((sc->>'feeFixed')::numeric + new.fare * (sc->>'feePercent')::numeric / 100, 2);
  select coalesce(jsonb_agg(c), '[]'::jsonb) into v_charges
    from jsonb_array_elements(case when jsonb_typeof(q->'charges') = 'array' then q->'charges' else '[]'::jsonb end) c
   where not (c->>'name' = 'Scheduling fee' and c->>'kind' = 'surcharge');
  if v_fee > 0 then
    v_charges := v_charges || jsonb_build_array(jsonb_build_object(
      'kind', 'surcharge', 'name', 'Scheduling fee', 'charge', 'fixed', 'value', v_fee,
      'platform', (sc->>'feeTo') = 'platform'));
  end if;
  new.scheduling_fee := greatest(v_fee, 0);
  new.request := (q - 'auto_accept_fare' - 'hire_booking_id' - 'hire_day_no') || jsonb_build_object(
    'fare', new.fare, 'ride_fare', new.fare, 'offer_me', false,
    'hire_package', 'hourly', 'hire_hours', new.hire_hours,
    'hire_quote', quote - 'available' - 'reason' - 'hint',
    'charges', v_charges,
    'option_names', coalesce(case when jsonb_typeof(q->'option_names') = 'object' then q->'option_names' end,
                             '{}'::jsonb) || jsonb_build_object('hire', 'Hourly hire'));
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_hire() from public, anon, authenticated;

-- ---- 7. The ride row -----------------------------------------------------------------------------
-- Priced before the business check (trg_ride_requests_c_business), so a
-- business account checks the hire's price, not the app's: the fare only.
-- trg_ride_requests_c_zzhire still stamps (and refuses) the hire.
create or replace function public.ride_requests_hire_price()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  q jsonb;
begin
  if new.hire_package is null then
    return new;
  end if;
  if new.scheduled_ride_id is not null then
    select s.request->'hire_quote' into q from public.scheduled_rides s
     where s.id = new.scheduled_ride_id and s.rider_id = new.rider_id and s.hire_package is not null;
  elsif new.hire_package = 'hourly' then
    q := public.hire_quote(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng, new.service,
                           new.hire_hours, now(), new.country, new.state, new.city, new.suburb, new.payment_mode);
  end if;
  if jsonb_typeof(q->'base') = 'number' then
    new.fare := case when new.whole_fare then ceil((q->>'base')::numeric) else (q->>'base')::numeric end;
    new.ride_fare := new.fare;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_hire_price() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_c_ahire_price on public.ride_requests;
create trigger trg_ride_requests_c_ahire_price
  before insert on public.ride_requests
  for each row execute function public.ride_requests_hire_price();

-- 0326's ride_requests_hire, with: a released day of a booking (its
-- package, booking and day from the booking's day row), a business account
-- allowed, a whole-fare region's price rounded up, and a cash booking whose
-- cash the admin has since turned off going by cashOffLater.
create or replace function public.ride_requests_hire()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_client boolean := current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('ride_requests');
  cfg jsonb;
  q jsonb;
  v_rest jsonb;
  v_fees jsonb;
  s record;
  v_pkg text := 'hourly';
  v_label text := 'Hourly hire';
begin
  if tg_op = 'INSERT' then
    if new.hire_package is null then
      -- A normal ride carries no hire value, and can't ask for hire drivers.
      new.hire_hours := null; new.hire_rate := null; new.hire_km_included := null; new.hire_overtime_rate := null;
      new.hire_step_min := null; new.hire_extra_km_rate := null; new.hire_quote := null;
      new.hire_started_at := null; new.hire_ends_at := null; new.hire_extensions := null;
      new.hire_km_used := null; new.hire_settled := null; new.hire_reminded_at := null;
      new.hire_booking_id := null; new.hire_day_no := null;
      if jsonb_typeof(new.option_names) = 'object' and new.option_names ? 'hire' then
        new.option_names := nullif(new.option_names - 'hire', '{}'::jsonb);
      end if;
      return new;
    end if;
    cfg := public.hourly_hire_config();
    new.hire_booking_id := null;
    new.hire_day_no := null;
    -- A released booking keeps the quote it was booked at.
    if new.scheduled_ride_id is not null then
      select x.request->'hire_quote' as quote, x.hire_package, x.hire_booking_id, x.hire_day_no into s
        from public.scheduled_rides x
       where x.id = new.scheduled_ride_id and x.rider_id = new.rider_id and x.hire_package is not null
         and jsonb_typeof(x.request->'hire_quote') = 'object';
      if found then
        q := s.quote;
        v_pkg := s.hire_package;
        new.hire_booking_id := s.hire_booking_id;
        new.hire_day_no := s.hire_day_no;
        if v_pkg <> 'hourly' then
          v_label := coalesce(q->>'title', 'Hire');
        end if;
      end if;
    end if;
    if q is null then
      -- Only an hourly hire is booked straight onto a ride; the others are
      -- booked ahead (hire_book).
      if new.hire_package is distinct from 'hourly' then
        perform public.hire_raise(jsonb_build_object('reason', 'HIRE_OFF', 'package', new.hire_package));
      end if;
      if v_client and not (cfg->>'allowNow')::boolean then
        perform public.hire_raise(jsonb_build_object('reason', 'HIRE_NOW_OFF'));
      end if;
      q := public.hire_quote(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng, new.service,
                             new.hire_hours, now(), new.country, new.state, new.city, new.suburb, new.payment_mode);
      if not (q->>'available')::boolean then
        perform public.hire_raise(q);
      end if;
      -- The place fees on the hire's price (0324 worked them out on the
      -- app's fare): a client's are dropped, the quote's stamped.
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where jsonb_typeof(e) = 'object' and e->'airport' is null;
      v_fees := public.place_fees_fit(v_rest, coalesce(q->'placeFees', '[]'::jsonb));
      v_rest := v_rest || v_fees;
      new.charges := case when v_rest = '[]'::jsonb then null else v_rest end;
    elsif public.hire_pay_kind(new.payment_mode) = 'cash' and not (cfg->>'allowCash')::boolean then
      -- 0327: a booking for later paid in cash while the admin has since
      -- turned cash off: as the admin says (cashOffLater).
      if cfg->>'cashOffLater' = 'wallet' then
        new.payment_mode := 'Get Pay';
        perform public.enqueue_notification(new.rider_id, 'hire-cash-wallet-' || new.id, 'scheduled_ride', 'critical',
          'Your hire is paid from GET.wallet',
          'Hire is no longer paid in cash, so your booked hire will be paid from your GET.wallet. Top up if you need to.',
          jsonb_build_object('type', 'hire_cash_off', 'request_id', new.id, 'scheduled_ride_id', new.scheduled_ride_id));
      elsif cfg->>'cashOffLater' = 'cancel' then
        new.status := 'cancelled';
        new.cancelled_at := now();
        new.cancel_requested_by := 'system';
        new.cancel_reason := 'Hire is no longer paid in cash';
        perform public.enqueue_notification(new.rider_id, 'hire-cash-cancel-' || new.id, 'scheduled_ride', 'critical',
          'Your hire was cancelled',
          'Hire is no longer paid in cash, so your booked hire was cancelled. You haven''t been charged. Book again with GET.wallet.',
          jsonb_build_object('type', 'hire_cash_off', 'request_id', new.id, 'scheduled_ride_id', new.scheduled_ride_id));
      end if;
    end if;
    new.hire_package := v_pkg;
    new.hire_quote := q - 'available' - 'reason' - 'hint';
    new.hire_hours := (q->>'hours')::numeric;
    new.hire_rate := (q->>'rate')::numeric;
    new.hire_km_included := (q->>'kmIncluded')::numeric;
    new.hire_overtime_rate := (q->>'overtimePerHour')::numeric;
    new.hire_step_min := (q->>'stepMinutes')::int;
    new.hire_extra_km_rate := (q->>'extraKm')::numeric;
    new.hire_started_at := null;
    new.hire_ends_at := null;
    new.hire_extensions := '[]'::jsonb;
    new.hire_km_used := null;
    new.hire_settled := null;
    new.hire_reminded_at := null;
    -- The price is the server's, fixed: no offers, no auto-accept, no
    -- airport fare; rounded up where fares are whole (0327).
    new.fare := (q->>'base')::numeric;
    if new.whole_fare then
      new.fare := ceil(new.fare);
    end if;
    new.ride_fare := new.fare;
    new.airport_fare := null;
    new.offer_me := false;
    new.auto_accept_fare := null;
    new.offered_fare := null;
    new.distance_km := coalesce(new.distance_km, 0);
    -- Offered only to drivers who take hire (0253's add-on filter).
    new.option_names := coalesce(case when jsonb_typeof(new.option_names) = 'object' then new.option_names end,
                                 '{}'::jsonb) || jsonb_build_object('hire', v_label);
    return new;
  end if;

  -- UPDATE
  if old.hire_package is null then
    if new.hire_package is not null then
      new.hire_package := null;
    end if;
    return new;
  end if;
  if v_client then
    -- The hire's terms are the server's once written.
    new.hire_package := old.hire_package; new.hire_hours := old.hire_hours; new.hire_rate := old.hire_rate;
    new.hire_km_included := old.hire_km_included; new.hire_overtime_rate := old.hire_overtime_rate;
    new.hire_step_min := old.hire_step_min; new.hire_extra_km_rate := old.hire_extra_km_rate;
    new.hire_quote := old.hire_quote; new.hire_started_at := old.hire_started_at;
    new.hire_ends_at := old.hire_ends_at; new.hire_extensions := old.hire_extensions;
    new.hire_km_used := old.hire_km_used; new.hire_settled := old.hire_settled;
    new.hire_reminded_at := old.hire_reminded_at;
    new.hire_booking_id := old.hire_booking_id; new.hire_day_no := old.hire_day_no;
    if (new.fare, new.ride_fare) is distinct from (old.fare, old.ride_fare)
       or (new.offered_fare is not null and round(new.offered_fare, 2) <> round(coalesce(old.fare, 0), 2))
       or new.auto_accept_fare is not null then
      raise exception 'HIRE_FIXED_FARE' using errcode = '42501', hint = 'Hire is at a fixed price.';
    end if;
    if old.status = 'open' and new.partner_id is not null and new.partner_id is distinct from old.partner_id
       and not public.driver_takes_hire(new.partner_id) then
      raise exception 'HIRE_DRIVER_OFF' using errcode = '42501',
        hint = 'Turn on "Take hourly hire" in your preferences to take hires.';
    end if;
    if new.status = 'completed' and old.status is distinct from 'completed' then
      raise exception 'HIRE_END_USE' using errcode = '42501', hint = 'Use End hire to finish a hire.';
    end if;
  end if;
  -- The clock starts with the trip.
  if new.status = 'on_trip' and old.status is distinct from 'on_trip' and new.hire_started_at is null then
    new.hire_started_at := now();
    new.hire_ends_at := now() + make_interval(mins => (new.hire_hours * 60)::int
                                                      + public.hire_extension_minutes(new.hire_extensions));
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_hire() from public, anon, authenticated;

-- ---- 8. Money ------------------------------------------------------------------------------------
-- What is left of a booking's prepaid money.
create or replace function public.hire_booking_pot(b public.hire_bookings)
returns numeric
language sql
immutable
set search_path = ''
as $$ select greatest(0, round(b.paid_amount - b.allocated_amount - b.refunded_amount - b.kept_amount, 2)); $$;

-- Moves [p_amount] of what the family spent from the booking's trip to the
-- day's ride (negative: back), so a hold returned on the day's ride goes
-- back to the host and the booking's refund is within what the family paid.
create or replace function public.hire_family_move(p_booking uuid, p_ride uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tb public.family_trips;
  tr public.family_trips;
begin
  if coalesce(p_amount, 0) = 0 then
    return;
  end if;
  select * into tb from public.family_trips where trip_id = p_booking and family_pays and released_at is null;
  select * into tr from public.family_trips where trip_id = p_ride and family_pays and released_at is null;
  if tb.trip_id is null or tr.trip_id is null then
    return;
  end if;
  insert into public.family_spend (family_id, member_id, trip_id, module_key, amount, kind) values
    (tb.family_id, tb.member_id, p_booking, tb.module_key, -round(p_amount, 2), 'hire_day'),
    (tr.family_id, tr.member_id, p_ride, tr.module_key, round(p_amount, 2), 'hire_day');
end;
$$;
revoke execute on function public.hire_family_move(uuid, uuid, numeric) from public, anon, authenticated;

-- Takes [p_amount] from the rider's (or the paying host's) GET.wallet for
-- a booking, named by the booking so Family's layer redirects it. False
-- when the wallet is short.
create or replace function public.hire_booking_charge(b public.hire_bookings, p_amount numeric, p_kind text,
                                                      p_note text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_balance numeric;
begin
  if coalesce(p_amount, 0) <= 0 then
    return true;
  end if;
  v_owner := public.family_wallet_owner(b.id, b.rider_id, p_amount);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets where user_id = v_owner and wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < p_amount then
    return false;
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (b.rider_id, 'get_wallet', p_kind, -round(p_amount, 2), 'hire',
          left(p_note || ' — RM' || to_char(p_amount, 'FM999999990.00'), 300), b.id);
  return true;
end;
$$;
revoke execute on function public.hire_booking_charge(public.hire_bookings, numeric, text, text) from public, anon, authenticated;

-- Gives back what is left of a booking's prepaid money (to whoever paid it).
create or replace function public.hire_booking_refund_rest(p_booking uuid, p_why text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  v numeric;
begin
  select * into b from public.hire_bookings where id = p_booking for update;
  v := public.hire_booking_pot(b);
  if v <= 0 then
    return 0;
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (b.rider_id, 'get_wallet', 'hire_refund', v, 'hire',
          left(coalesce(b.quote->>'title', 'Hire') || ' refund (' || p_why || ') — RM'
               || to_char(v, 'FM999999990.00'), 300), b.id);
  update public.hire_bookings set refunded_amount = refunded_amount + v where id = b.id;
  return v;
end;
$$;
revoke execute on function public.hire_booking_refund_rest(uuid, text) from public, anon, authenticated;

-- A day of a booking released: the balance (on the first day released), then
-- the day's amount due moved from the booking's money to the day's hold.
create or replace function public.hire_booking_day_released(r public.ride_requests)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  v_share numeric;
begin
  select * into b from public.hire_bookings where id = r.hire_booking_id for update;
  if not found or b.status in ('cancelled', 'expired', 'completed') then
    return;
  end if;
  if b.payment_state = 'deposit_paid' and b.balance_amount > 0 then
    if public.hire_booking_charge(b, b.balance_amount, 'hire_balance',
                                  coalesce(b.quote->>'title', 'Hire') || ' balance') then
      update public.hire_bookings set paid_amount = paid_amount + balance_amount, payment_state = 'paid'
       where id = b.id returning * into b;
    else
      update public.hire_bookings set payment_state = 'balance_short' where id = b.id returning * into b;
      perform public.enqueue_notification(b.rider_id, 'hire-balance-short-' || b.id, 'scheduled_ride', 'critical',
        'Top up for your hire',
        format('The balance of %s couldn''t be taken from your GET.wallet. Each day is paid when it ends instead.',
               'RM' || to_char(b.balance_amount, 'FM999999990.00')),
        jsonb_build_object('type', 'hire_balance_short', 'hire_booking_id', b.id, 'request_id', r.id));
    end if;
  end if;
  v_share := least(public.ride_amount_due(r), public.hire_booking_pot(b));
  if v_share > 0 and r.status in ('open', 'accepted') then
    insert into public.hire_holds (ride_id, rider_id, amount) values (r.id, r.rider_id, v_share)
    on conflict (ride_id) do nothing;
    if found then
      update public.hire_bookings set allocated_amount = allocated_amount + v_share where id = b.id;
      perform public.hire_family_move(b.id, r.id, v_share);
    end if;
  end if;
  if b.status in ('booked', 'assigned') then
    update public.hire_bookings set status = 'in_progress' where id = b.id;
  end if;
end;
$$;
revoke execute on function public.hire_booking_day_released(public.ride_requests) from public, anon, authenticated;

-- 0326's hold, with a booking's day taking its share of the booking's money.
create or replace function public.ride_requests_hire_hold()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb;
  v_amount numeric;
  v_owner uuid;
  v_balance numeric;
begin
  if new.hire_booking_id is not null then
    perform public.hire_booking_day_released(new);
    return null;
  end if;
  if new.hire_package is null or new.status not in ('open', 'accepted')
     or public.hire_pay_kind(new.payment_mode) <> 'wallet' then
    return null;
  end if;
  cfg := public.hourly_hire_config();
  if not (cfg->>'holdInWallet')::boolean then
    return null;
  end if;
  v_amount := round(coalesce((new.hire_quote->>'total')::numeric, new.fare, 0)
                    * (1 + (cfg->>'holdBufferPercent')::numeric / 100), 2);
  if v_amount <= 0 then
    return null;
  end if;
  v_owner := public.family_wallet_owner(new.id, new.rider_id, v_amount);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets where user_id = v_owner and wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_amount then
    if new.scheduled_ride_id is not null then
      return null;  -- released from a booking: goes ahead unheld, paid at the end
    end if;
    raise exception 'HIRE_BALANCE' using errcode = 'P0001',
      hint = format('Top up your GET.wallet: %s is held for this hire until it ends.',
                    'RM' || to_char(v_amount, 'FM999999990.00'));
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (new.rider_id, 'get_wallet', 'hire_hold', -v_amount, 'hire',
          'Hourly hire held — RM' || to_char(v_amount, 'FM999999990.00'), new.id);
  insert into public.hire_holds (ride_id, rider_id, amount) values (new.id, new.rider_id, v_amount)
  on conflict (ride_id) do nothing;
  return null;
end;
$$;
revoke execute on function public.ride_requests_hire_hold() from public, anon, authenticated;

-- 0326's hold return. A booking's day cancelled or expired puts its share
-- back into the booking (no wallet movement); paid, it comes back to the
-- wallet for ride_pay to charge the settled day, as 0326's hold does.
create or replace function public.hire_hold_return(p_ride uuid, p_why text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.hire_holds;
  v_booking uuid;
begin
  select * into h from public.hire_holds where ride_id = p_ride and status = 'held' for update;
  if not found then
    return false;
  end if;
  select hire_booking_id into v_booking from public.ride_requests where id = p_ride;
  if v_booking is not null and p_why is distinct from 'paid' then
    update public.hire_bookings set allocated_amount = greatest(0, allocated_amount - h.amount) where id = v_booking;
    perform public.hire_family_move(v_booking, p_ride, -h.amount);
  else
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (h.rider_id, 'get_wallet', 'hire_hold_return', h.amount, 'hire',
            case when v_booking is not null then 'Hire day paid from the booking'
                 when p_why = 'paid' then 'Hourly hire hold returned (paid)'
                 else 'Hourly hire hold returned' end, p_ride);
  end if;
  update public.hire_holds set status = 'returned', returned_at = now(), returned_why = left(p_why, 40)
   where ride_id = p_ride;
  return true;
end;
$$;
revoke execute on function public.hire_hold_return(uuid, text) from public, anon, authenticated;

-- ---- 9. Booking ----------------------------------------------------------------------------------
-- [p_request]: the ride_requests row the app would send for day 1 (as
-- schedule_ride takes it). [p_booking]: {package, first_at, days, hours,
-- overnight, same_driver, payment_plan ('deposit' | 'prepay')}.
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
  v_plan text := coalesce(p_booking->>'payment_plan', 'deposit');
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
         coalesce(p_booking - 'package' - 'first_at' - 'days' - 'hours' - 'overnight' - 'same_driver' - 'payment_plan',
                  '{}'::jsonb));
  if not (q->>'available')::boolean then
    perform public.hire_raise(q);
  end if;
  -- Paid from GET.wallet (or Family), or charged to a business account.
  v_kind := case when coalesce(v_req->>'business_account_id', '') <> '' then 'business'
                 else public.hire_pay_kind(v_req->>'payment_mode') end;
  if v_kind = 'business' then
    v_plan := 'business';
  elsif v_kind <> 'wallet' then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_PAY', 'package', v_pkg));
  elsif v_plan = 'prepay' and not (cfg->>'allowPrepay')::boolean then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_PREPAY_OFF', 'package', v_pkg));
  elsif v_plan not in ('deposit', 'prepay') then
    v_plan := 'deposit';
  end if;

  insert into public.hire_bookings (
    rider_id, package, service, pickup_name, pickup_address, pickup_lat, pickup_lng,
    drop_name, drop_address, drop_lat, drop_lng, stops, first_at, days, timezone, hours_per_day, km_per_day,
    overnight, same_driver, payment_mode, payment_plan, price, quote, currency, booked_for_name, booked_for_phone,
    family, business_account_id, payment_state)
  values (
    v_uid, v_pkg, v_req->>'service', v_req->>'pickup_name', coalesce(v_req->>'pickup_address', v_req->>'pickup_name'),
    (v_req->>'pickup_lat')::float8, (v_req->>'pickup_lng')::float8,
    v_req->>'drop_name', coalesce(v_req->>'drop_address', v_req->>'drop_name'),
    case when jsonb_typeof(v_req->'drop_lat') = 'number' then (v_req->>'drop_lat')::float8 end,
    case when jsonb_typeof(v_req->'drop_lng') = 'number' then (v_req->>'drop_lng')::float8 end,
    case when jsonb_typeof(v_req->'stops') = 'array' then v_req->'stops' end,
    v_first, (q->>'days')::int, v_tz, (q->>'hours')::numeric, (q->>'kmPerDay')::numeric,
    v_overnight, v_same, v_req->>'payment_mode', v_plan, (q->>'total')::numeric,
    q - 'available' - 'reason' - 'hint' || jsonb_build_object('country', v_req->>'country', 'state', v_req->>'state',
                                                              'city', v_req->>'city', 'suburb', v_req->>'suburb'),
    v_req->>'currency', v_name, v_phone, case when jsonb_typeof(v_req->'family') = 'object' then v_req->'family' end,
    case when v_kind = 'business' and (v_req->>'business_account_id') ~* '^[0-9a-f-]{36}$'
         then (v_req->>'business_account_id')::uuid end,
    case when v_kind = 'business' then 'business' else 'none' end)
  returning * into b;

  -- One booking row a day, through every booking trigger.
  v_req := v_req || jsonb_build_object('timezone', v_tz);
  for d in select value from jsonb_array_elements(q->'dates') loop
    i := i + 1;
    insert into public.scheduled_rides (
      rider_id, pickup_at, request, service, pickup_address, drop_address,
      pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km, fare, scheduling_fee, currency,
      booked_for_name, booked_for_phone, hire_package, hire_hours, hire_booking_id, hire_day_no)
    values (
      v_uid, (d #>> '{}')::timestamptz,
      v_req || jsonb_build_object('hire_package', v_pkg, 'hire_hours', b.hours_per_day,
                                  'hire_booking_id', b.id, 'hire_day_no', i),
      b.service, b.pickup_address, b.drop_address, b.pickup_lat, b.pickup_lng, b.drop_lat, b.drop_lng,
      case when jsonb_typeof(v_req->'distance_km') = 'number' then (v_req->>'distance_km')::numeric end,
      (q->>'perDay')::numeric, 0, b.currency, v_name, v_phone, v_pkg, b.hours_per_day, b.id, i);
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

-- ---- 10. Family ----------------------------------------------------------------------------------
-- The booking is the family's trip too: its deposit, balance and refunds
-- name it (ride_id), and the payment layer moves them to the host.
create or replace function public.hire_bookings_family()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pays boolean := lower(btrim(coalesce(new.payment_mode, ''))) = 'family';
  v_passenger uuid := public.family_passenger_of(new.family);
begin
  if not v_pays and v_passenger is null then
    return null;
  end if;
  perform public.family_attach_trip('hire', new.id, new.rider_id, v_passenger, new.price,
                                    jsonb_build_object('country', new.quote->>'country', 'state', new.quote->>'state',
                                                       'city', new.quote->>'city', 'suburb', new.quote->>'suburb'),
                                    new.family, v_pays);
  return null;
end;
$$;
revoke execute on function public.hire_bookings_family() from public, anon, authenticated;
drop trigger if exists trg_hire_bookings_family on public.hire_bookings;
create trigger trg_hire_bookings_family
  after insert on public.hire_bookings
  for each row execute function public.hire_bookings_family();

-- ---- 11. Drivers ---------------------------------------------------------------------------------
-- Whether a booking's days are listed and taken one by one: not while the
-- booking waits for one driver for every day.
create or replace function public.hire_day_listed(p_booking uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_booking is null
      or exists (select 1 from public.hire_bookings b
                  where b.id = p_booking and (not b.same_driver or b.split_at is not null or b.partner_id is not null));
$$;
revoke execute on function public.hire_day_listed(uuid) from public, anon;
grant execute on function public.hire_day_listed(uuid) to authenticated;

-- Bookings waiting for one driver for all their days, with the days.
create or replace function public.hire_bookings_open()
returns table(id uuid, package text, title text, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, first_at timestamptz, days integer,
              hours_per_day numeric, km_per_day numeric, overnight boolean, fare numeric, currency text,
              day_list jsonb, stops jsonb)
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
         b.stops
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

-- A driver takes every day of a booking: the clash check over each day.
create or replace function public.hire_booking_accept(p_booking uuid)
returns public.hire_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  b public.hire_bookings;
  s public.scheduled_rides;
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into b from public.hire_bookings where id = p_booking for update;
  if not found or b.status <> 'booked' or b.partner_id is not null or b.first_at <= now()
     or not b.same_driver or b.split_at is not null then
    raise exception 'SCHEDULED_TAKEN' using hint = 'Another driver has taken this hire, or it is no longer open.';
  end if;
  if b.rider_id = v_uid or public.rider_blocks_driver(b.rider_id, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not public.driver_takes_hire(v_uid) then
    raise exception 'HIRE_DRIVER_OFF' using errcode = '42501',
      hint = 'Turn on "Take hourly hire" in your preferences to take hires.';
  end if;
  if not public.driver_takes_service(v_uid, b.service) or public.driver_permit_problem(v_uid) is not null then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Your vehicle can''t take this hire.';
  end if;
  perform public.driver_credit_assert(v_uid);
  for s in select * from public.scheduled_rides where hire_booking_id = b.id and status = 'scheduled' order by hire_day_no loop
    if public.scheduled_partner_clash(v_uid, s.pickup_at, s.id) then
      raise exception 'SCHEDULED_CLASH' using hint = format('You already have a ride within an hour of day %s (%s).',
        s.hire_day_no, public.scheduled_when(s.pickup_at));
    end if;
  end loop;
  perform set_config('getride.hire_whole', b.id::text, true);
  update public.scheduled_rides set status = 'assigned', partner_id = v_uid, partner_accepted_at = now()
   where hire_booking_id = b.id and status = 'scheduled' and partner_id is null;
  perform set_config('getride.hire_whole', '', true);
  update public.hire_bookings set partner_id = v_uid, partner_accepted_at = now(), status = 'assigned'
   where id = b.id
  returning * into b;
  perform public.enqueue_notification(b.rider_id, 'hire-assigned-' || b.id || '-' || v_uid, 'scheduled_ride', 'normal',
    'Driver confirmed',
    format('A driver has accepted all %s days of your hire from %s.', b.days, public.scheduled_when(b.first_at)),
    jsonb_build_object('type', 'hire_assigned', 'hire_booking_id', b.id));
  return b;
end;
$$;
revoke execute on function public.hire_booking_accept(uuid) from public, anon;
grant execute on function public.hire_booking_accept(uuid) to authenticated;

-- 0326's guard on a booked hire's driver, with a booking's day: not taken on
-- its own while its booking waits for one driver for every day.
create or replace function public.scheduled_rides_hire_driver()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.hire_package is not null and new.partner_id is not null
     and new.partner_id is distinct from old.partner_id and not public.driver_takes_hire(new.partner_id) then
    raise exception 'HIRE_DRIVER_OFF' using errcode = '42501',
      hint = 'Turn on "Take hourly hire" in your preferences to take hires.';
  end if;
  if new.hire_booking_id is not null and new.partner_id is not null and old.partner_id is null
     and coalesce(current_setting('getride.hire_whole', true), '') <> new.hire_booking_id::text
     and not public.hire_day_listed(new.hire_booking_id) and not public.caller_is_admin() then
    raise exception 'HIRE_WHOLE_BOOKING' using errcode = '42501',
      hint = 'This hire is taken for all its days: accept it from the hire''s card.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_hire_driver() from public, anon, authenticated;

-- A day of a booking is cancelled with its booking (hire_booking_cancel),
-- not on its own before it is released.
create or replace function public.scheduled_rides_hire_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.hire_booking_id is not null and new.status = 'cancelled' and old.status is distinct from 'cancelled'
     and old.ride_id is null and new.cancelled_by = 'rider'
     and coalesce(current_setting('getride.hire_booking_cancel', true), '') <> new.hire_booking_id::text then
    raise exception 'HIRE_BOOKING_CANCEL' using errcode = '42501',
      hint = 'Cancel the hire from its booking: its days are cancelled together.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_hire_cancel() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_hire_cancel on public.scheduled_rides;
create trigger trg_scheduled_rides_hire_cancel
  before update of status on public.scheduled_rides
  for each row execute function public.scheduled_rides_hire_cancel();

-- The booking follows its days: in progress once one is released, done when
-- every day is over (what is left of its money refunded).
create or replace function public.hire_booking_sync(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  n integer;
  n_done integer;
  n_over integer;
  n_expired integer;
  n_live integer;
  v_status text;
begin
  select * into b from public.hire_bookings where id = p_booking for update;
  if not found or b.status in ('cancelled', 'expired', 'completed') then
    return;
  end if;
  select count(*), count(*) filter (where status = 'completed'),
         count(*) filter (where status in ('completed', 'cancelled', 'expired')),
         count(*) filter (where status = 'expired'),
         count(*) filter (where status = 'released')
    into n, n_done, n_over, n_expired, n_live
    from public.scheduled_rides where hire_booking_id = b.id;
  v_status := case when n > 0 and n_over = n then
                     case when n_done > 0 then 'completed' when n_expired = n then 'expired' else 'cancelled' end
                   when n_done > 0 or n_live > 0 then 'in_progress'
                   when b.partner_id is not null then 'assigned'
                   else 'booked' end;
  if v_status is distinct from b.status then
    update public.hire_bookings set status = v_status,
           cancelled_at = case when v_status = 'cancelled' then coalesce(cancelled_at, now()) end,
           cancelled_by = case when v_status = 'cancelled' then coalesce(cancelled_by, 'system') end
     where id = b.id;
  end if;
  if v_status in ('completed', 'expired', 'cancelled') then
    perform public.hire_booking_refund_rest(b.id, v_status);
  end if;
end;
$$;
revoke execute on function public.hire_booking_sync(uuid) from public, anon, authenticated;

create or replace function public.scheduled_rides_hire_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.hire_booking_sync(new.hire_booking_id);
  return null;
end;
$$;
revoke execute on function public.scheduled_rides_hire_booking() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_hire_booking on public.scheduled_rides;
create trigger trg_scheduled_rides_hire_booking
  after update of status, partner_id on public.scheduled_rides
  for each row when (new.hire_booking_id is not null)
  execute function public.scheduled_rides_hire_booking();

-- ---- 12. Cancelling ------------------------------------------------------------------------------
-- Closes [p_booking]: its days not yet over are cancelled, [p_fee] (at most
-- its money) is kept and the rest refunded.
create or replace function public.hire_booking_close(p_booking uuid, p_by text, p_reason text, p_fee numeric,
                                                     p_status text default 'cancelled')
returns public.hire_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  v_fee numeric;
  v_driver uuid;
begin
  select * into b from public.hire_bookings where id = p_booking for update;
  update public.hire_bookings set status = p_status, cancelled_at = now(), cancelled_by = p_by,
         cancel_reason = left(p_reason, 200)
   where id = b.id;
  perform set_config('getride.hire_booking_cancel', b.id::text, true);
  -- Its released days not on the trip yet: cancelled (their shares back in the booking).
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(), cancel_requested_by = case when p_by = 'rider' then 'rider' else 'system' end,
         cancel_reason = left(coalesce(p_reason, 'Hire cancelled'), 200)
   where hire_booking_id = b.id and status in ('open', 'accepted', 'arrived');
  for v_driver in
    select distinct partner_id from public.scheduled_rides
     where hire_booking_id = b.id and partner_id is not null and status in ('scheduled', 'assigned', 'released')
  loop
    perform public.enqueue_notification(v_driver, 'hire-cancel-' || b.id || '-' || v_driver, 'scheduled_ride', 'normal',
      'Hire cancelled',
      format('The %s from %s was cancelled.', lower(coalesce(b.quote->>'title', 'hire')), public.scheduled_when(b.first_at)),
      jsonb_build_object('type', 'hire_cancelled', 'hire_booking_id', b.id));
  end loop;
  update public.scheduled_rides
     set status = case when p_status = 'expired' then 'expired' else 'cancelled' end,
         cancelled_at = now(), cancelled_by = p_by, cancel_reason = left(p_reason, 200)
   where hire_booking_id = b.id and status in ('scheduled', 'assigned', 'released');
  perform set_config('getride.hire_booking_cancel', '', true);
  select * into b from public.hire_bookings where id = b.id for update;
  v_fee := least(round(greatest(0, coalesce(p_fee, 0)), 2), public.hire_booking_pot(b));
  update public.hire_bookings set cancel_fee = v_fee, kept_amount = kept_amount + v_fee where id = b.id;
  perform public.hire_booking_refund_rest(b.id, p_status);
  select * into b from public.hire_bookings where id = b.id;
  return b;
end;
$$;
revoke execute on function public.hire_booking_close(uuid, text, text, numeric, text) from public, anon, authenticated;

-- What cancelling [b] now would cost: {free, fee, freeUntil, started}.
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
begin
  select min(pickup_at), bool_or(status in ('released', 'completed')) into v_first, v_started
    from public.scheduled_rides where hire_booking_id = b.id;
  v_first := coalesce(v_first, b.first_at);
  v_until := b.first_at - make_interval(hours => (cfg->>'freeCancelHours')::int);
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
                            'refund', public.hire_booking_pot(b) - v_fee);
end;
$$;
revoke execute on function public.hire_booking_cancel_terms(public.hire_bookings) from public, anon, authenticated;

-- What the rider sees before cancelling.
create or replace function public.hire_booking_cancel_quote(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
begin
  select * into b from public.hire_bookings where id = p_booking;
  if not found or (b.rider_id is distinct from auth.uid() and not public.caller_is_admin()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.hire_booking_cancel_terms(b);
end;
$$;
revoke execute on function public.hire_booking_cancel_quote(uuid) from public, anon;
grant execute on function public.hire_booking_cancel_quote(uuid) to authenticated;

-- The rider (or an admin, free) cancels a booking: every day not over yet.
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
  return public.hire_booking_close(b.id, case when v_admin then 'admin' else 'rider' end, p_reason,
                                   case when v_admin then 0 else (t->>'fee')::numeric end);
end;
$$;
revoke execute on function public.hire_booking_cancel(uuid, text) from public, anon;
grant execute on function public.hire_booking_cancel(uuid, text) to authenticated;

-- ---- 13. The tick --------------------------------------------------------------------------------
-- A booking nobody took for every day by the cut-off: each day offered on
-- its own (splitDays), or closed and refunded.
create or replace function public.hire_bookings_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.hire_bookings;
  cfg jsonb;
  n integer := 0;
begin
  for b in
    select * from public.hire_bookings
     where status = 'booked' and same_driver and partner_id is null and split_at is null
  loop
    cfg := public.hire_package_config(b.package);
    continue when cfg is null or b.first_at - make_interval(hours => (cfg->>'splitAfterHours')::int) > now();
    if (cfg->>'splitDays')::boolean then
      update public.hire_bookings set split_at = now() where id = b.id;
      perform public.enqueue_notification(b.rider_id, 'hire-split-' || b.id, 'scheduled_ride', 'normal',
        'Finding a driver for each day',
        'No one driver could take every day of your hire, so we''re finding a driver for each day.',
        jsonb_build_object('type', 'hire_split', 'hire_booking_id', b.id));
    else
      perform public.hire_booking_close(b.id, 'system', 'No driver for every day', 0, 'expired');
      perform public.enqueue_notification(b.rider_id, 'hire-nodriver-' || b.id, 'scheduled_ride', 'normal',
        'No driver found',
        'No driver could take every day of your hire, so it was cancelled. What you paid is back in your GET.wallet.',
        jsonb_build_object('type', 'hire_expired', 'hire_booking_id', b.id));
    end if;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.hire_bookings_tick() from public, anon, authenticated;

-- 0326's hire_tick, plus the bookings'.
create or replace function public.hire_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  r public.ride_requests;
  n integer := 0;
begin
  if (cfg->>'reminderBeforeEndMin')::int > 0 then
    for r in
      select * from public.ride_requests
       where hire_package is not null and status = 'on_trip' and hire_ends_at is not null
         and hire_reminded_at is null and hire_ends_at > now()
         and hire_ends_at - make_interval(mins => (cfg->>'reminderBeforeEndMin')::int) <= now()
    loop
      perform public.enqueue_notification(p, 'hire-remind-' || r.id || '-' || extract(epoch from r.hire_ends_at)::bigint,
        'ride_status', 'normal', 'Hire time nearly up',
        format('The hire ends at %s.', to_char(r.hire_ends_at at time zone coalesce(r.timezone, 'Asia/Kuala_Lumpur'), 'HH12:MI am')),
        jsonb_build_object('type', 'hire_reminder', 'request_id', r.id), r.id)
        from unnest(array[r.rider_id, r.partner_id]) p;
      update public.ride_requests set hire_reminded_at = now() where id = r.id;
    end loop;
  end if;
  for r in
    select * from public.ride_requests
     where hire_package is not null and status = 'on_trip' and hire_ends_at is not null
       and hire_ends_at + make_interval(mins => (cfg->>'autoEndAfterMin')::int) <= now()
  loop
    perform public.hire_finish(r.id, null, 'auto');
    perform public.enqueue_notification(p, 'hire-auto-end-' || r.id, 'ride_status', 'normal', 'Hire ended',
      'The hire''s time was up, so it has been ended.',
      jsonb_build_object('type', 'hire_ended', 'request_id', r.id), r.id)
      from unnest(array[r.rider_id, r.partner_id]) p;
    n := n + 1;
  end loop;
  -- 0327: the bookings' cut-off.
  begin
    n := n + public.hire_bookings_tick();
  exception when others then
    raise warning 'hire_bookings_tick: %', sqlerrm;
  end;
  return n;
end;
$$;
revoke execute on function public.hire_tick() from public, anon, authenticated;

-- ---- 14. The end of a day ------------------------------------------------------------------------
-- 0326's hire_settle: a booking's day bills the day booked (an early end
-- still pays the day), its line names the day; a whole-fare region's
-- amounts are rounded up.
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
    v_lines := v_lines || jsonb_build_object('kind', 'extra_km', 'label', 'Extra km ' || public.hire_plain(v_extra_km) || ' km',
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

-- ---- 15. The drivers' lists ----------------------------------------------------------------------
-- 0326's lists, with a booking's days left out while the booking waits for
-- one driver for every day, and each day's booking, number, the booking's
-- days and its title last.
drop function if exists public.scheduled_rides_open();
create or replace function public.scheduled_rides_open()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              place_fees jsonb, hire_package text, hire_hours numeric, hire_booking_id uuid, hire_day_no integer,
              hire_days integer, hire_title text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         public.place_fee_lines(s),
         s.hire_package, s.hire_hours, s.hire_booking_id, s.hire_day_no,
         (s.request->'hire_quote'->>'days')::int, s.request->'hire_quote'->>'title'
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
     and not public.rider_blocks_driver(s.rider_id, auth.uid())
     and public.service_order_driver_allows(auth.uid(), s.service)
     and public.driver_permit_problem(auth.uid()) is null
     and public.driver_takes_service(auth.uid(), s.service)
     and public.driver_takes_freight(auth.uid(), s.service)
     and public.driver_takes_extras(auth.uid(), public.ride_extra_keys(
           s.request->'pets', s.request->'assistance', s.request->'option_names',
           case when jsonb_typeof(s.request->'passengers') = 'number'
                then floor((s.request->>'passengers')::numeric)::integer end))
     -- 0326: a hire only for drivers who take hire (also its 'hire' add-on above).
     and (s.hire_package is null or public.driver_takes_hire(auth.uid()))
     -- 0327: a booking's days one by one only once it isn't waiting for one driver.
     and public.hire_day_listed(s.hire_booking_id)
   order by s.pickup_at
   limit 100;
$$;
revoke execute on function public.scheduled_rides_open() from public, anon;
grant execute on function public.scheduled_rides_open() to authenticated, service_role;

drop function if exists public.scheduled_rides_upcoming();
create or replace function public.scheduled_rides_upcoming()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              interested boolean, can_accept boolean, accept_from timestamptz, place_fees jsonb,
              hire_package text, hire_hours numeric, hire_booking_id uuid, hire_day_no integer,
              hire_days integer, hire_title text)
language sql
stable
security definer
set search_path = public
as $$
  with c as (select public.scheduled_rides_config() as v)
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when c.v->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         i.partner_id is not null,
         c.v->>'mode' = 'advance'
           or (i.partner_id is not null and (c.v->>'interestNoticeMinutes')::int > 0
               and now() >= s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int)),
         case when c.v->>'mode' = 'advance' then null
              when (c.v->>'interestNoticeMinutes')::int > 0
              then s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int) end,
         public.place_fee_lines(s),
         s.hire_package, s.hire_hours, s.hire_booking_id, s.hire_day_no,
         (s.request->'hire_quote'->>'days')::int, s.request->'hire_quote'->>'title'
    from public.scheduled_rides s
    cross join c
    left join public.scheduled_ride_interests i on i.scheduled_ride_id = s.id and i.partner_id = auth.uid()
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and (c.v->>'enabled')::boolean
     and public.caller_is_approved_partner()
     and s.rider_id <> auth.uid()
     and not public.rider_blocks_driver(s.rider_id, auth.uid())
     -- 0326: a hire only for drivers who take hire.
     and (s.hire_package is null or public.driver_takes_hire(auth.uid()))
     -- 0327: a booking's days one by one only once it isn't waiting for one driver.
     and public.hire_day_listed(s.hire_booking_id)
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_rides_upcoming() from public, anon;
grant execute on function public.scheduled_rides_upcoming() to authenticated, service_role;

-- ---- 16. Family: the module's name now covers every hire ----------------------------------------
select public.family_register_module('hire', 'Hire');
update public.booking_modules set name = 'Hire', description = 'A driver and car by the hour or by the day'
 where key = 'hire';

notify pgrst, 'reload schema';
