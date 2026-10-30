-- ============================================================================
-- 0330 — myGiG, part B: bookings for later and hire by time from myGiG.
--
-- Part A (0329) made a myGiG ride now. Here the driver also books the
-- passenger for later (Now / Later on the trip details) and hires
-- themselves out by time (Trip / Hourly / Daily / Weekly / Monthly). A
-- myGiG hire is a hire booking that came from a driver's myGiG instead of
-- the rider app: its rides are ride_requests rows with 0326's hire columns
-- (the trip card, overtime, statements' hire lines), a multi-day hire has
-- a hire_bookings row (Admin › Hire bookings), each day is released and
-- started from Scheduled myGiG, and the minute's hire tick runs it. It is
-- priced from the driver's own hire rates or get.ride's myGiG hire rates.
--
-- Version 20261030110000 (0330_mygig_later_hire). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first.
--
-- 1. Settings (mygig_rules, by region as part A): `later` {enabled,
--    aheadDays, remindMin, startEarlyMin, payWaitMin} and `hire` {enabled,
--    packages {hourly, daily, weekly, monthly}, leadMin {trip 30, hourly 60,
--    daily 720, weekly 1440, monthly 2880}, minHours 2, maxHours 12,
--    dayHoursMin 8, dayHoursMax 12, maxDays 6, maxWeeks 4, maxMonths 3,
--    depositPct 30, freeCancelHours {trip 1, hourly 2, daily 24, weekly 24,
--    monthly 48}, nonApp ('link': pay by link first | 'no': not offered),
--    holidays ('skip' | 'work', 0328's public_holidays), stepMin, rates
--    (get.ride's myGiG hire rates: per hour, km an hour, overtime an hour,
--    extra km, per day (10 h), km a day, per week (5 days), km a week, per
--    month (5 days a week), km a month, overnight), allowOwnRates and
--    ownLimits}. mygig_settings_problem checks them.
-- 2. Drivers: prefs.hire {offer {hourly, daily, weekly, monthly}, own,
--    rates {hour, day, week, month, overtime, overnight}} kept within the
--    admin's limits (mygig_prefs_normalize); mygig_hire_card is the rates
--    a hire is priced with.
-- 3. The booking the driver sends: {kind, when, at, hours, days,
--    hoursPerDay, periods, weekdays, overnight} (mygig_booking_clean), its
--    time checked (mygig_when_problem: passed, too soon for the lead time,
--    too far ahead), priced (mygig_hire_price: the package, overnight
--    allowances, luggage and coming to the pickup on day 1, the place fees
--    each day, the region's tax and rounding, each day's own total; public
--    holidays skipped for weeks and months) and paid as the owner's rule
--    says (mygig_booking_plan, below). A clash with the driver's other
--    bookings is refused (MYGIG_CLASH).
-- 4. mygig_bookings (one per later booking or hire by time, the driver's
--    with the passenger) and mygig_booking_days (each start: a later trip or
--    hourly hire has one, a daily, weekly or monthly hire one a working
--    day). A multi-day hire also has its hire_bookings row (rider_id may
--    now be empty: the passenger may not be registered), so Admin › Hire
--    bookings lists it and its rides carry hire_booking_id and hire_day_no.
--    Family: module 'mygig' (trg_mygig_bookings_family).
-- 5. Scheduled myGiG: mygig_scheduled (the driver's bookings: date and
--    time, passenger as the admin shows them, price, what is paid, "Day 2
--    of 5", Start when due), mygig_my_bookings (the passenger's app),
--    mygig_booking_start (collects what is due, then releases the day: a
--    ride with the driver, the hire's columns, the day's share of the
--    money), mygig_booking_cash, mygig_booking_cancel (driver, passenger in
--    the app or on the trip link, admin), and the trip link shows the
--    booking until it ends. Reminders to both, unpaid bookings ending, and
--    days nobody started, run in the hire tick (hire_tick ->
--    mygig_bookings_tick).
-- 6. The hire's day: mygig_hire_end (km driven, tolls, other charges):
--    overtime (past the day's hours, in the admin's steps, at the overtime
--    rate) and extra km over the day's km, taxed as the day; charged in the
--    app, or paid before the day ends (cash confirmed or a link).
--
-- No losses to get.ride or the driver (owner's rule; nothing is charged
-- later to anyone without in-app payment; no "get.ride covers" or "driver
-- covers"):
--   * hourly hire now: as a myGiG ride (part A: the link paid at
--     acceptance, extras and overtime paid before Complete);
--   * a later trip or hourly hire: a registered passenger paying in the app
--     (GET.wallet, Family) is charged when the driver starts; anyone else
--     pays the price by link when they accept ('link_first'), and the
--     booking is confirmed only once paid;
--   * daily: the deposit (depositPct) when they accept (in the app, else by
--     link first), the balance before day 1 starts (in the app, else by
--     link or cash the driver confirms); weekly and monthly: in full when
--     they accept; a business account: nothing upfront, each day on the
--     account (0313). Passengers without in-app payment always pay by link
--     before the booking is confirmed, or (nonApp 'no') multi-day hire isn't
--     offered to them. There is no "pay day by day";
--   * overtime and extra km each day: charged in the app; otherwise paid
--     before the driver ends the day (cash confirmed or a link);
--   * the booking's money is get.ride's until a day is driven: each day's
--     share goes to the driver when the day ends;
--   * cancelling: free until freeCancelHours before the start; after that
--     the deposit (or what was paid upfront) is kept and paid to the
--     driver. The driver or the admin cancelling refunds everything; once
--     a day has started the days left are cancelled free. A refund in the
--     app goes back to whoever paid (Family's host); a link payment is
--     refundDue on the gateway for the admin.
-- 7. Pay by link: the payments function's POST /payments/mygig-link takes a
--    booking's id as well as a ride's (payment_mygig_link_allowed,
--    payment_mygig_intent, payment_mygig_link_set, payment_ride_card_paid
--    tell them apart). No edge function change.
-- ============================================================================

-- ---- 1. Columns and tables -------------------------------------------------------------------------
alter table public.mygig_offers add column if not exists booking jsonb;
alter table public.mygig_offers add column if not exists booking_id uuid;
alter table public.mygig_offers drop constraint if exists mygig_offers_booking_valid;
alter table public.mygig_offers add constraint mygig_offers_booking_valid check (
  booking is null or (jsonb_typeof(booking) = 'object' and pg_column_size(booking) <= 16384));
comment on column public.mygig_offers.booking is
  'myGiG (0330): when and what was offered ({kind, when, at, hours, days, ...} and how it is paid); null for a ride now.';

-- A myGiG hire's passenger may not be registered.
alter table public.hire_bookings alter column rider_id drop not null;
alter table public.hire_bookings add column if not exists mygig_booking_id uuid;
create index if not exists hire_bookings_mygig_idx on public.hire_bookings (mygig_booking_id)
  where mygig_booking_id is not null;

create table if not exists public.mygig_bookings (
  id                uuid primary key default gen_random_uuid(),
  offer_id          uuid references public.mygig_offers(id) on delete set null,
  driver_id         uuid not null references public.profiles(id) on delete cascade,
  rider_id          uuid references public.profiles(id) on delete set null,
  passenger_name    text check (passenger_name is null or char_length(passenger_name) <= 80),
  phone             text check (phone is null or phone ~ '^\+[0-9]{6,16}$'),
  kind              text not null check (kind in ('trip', 'hourly', 'daily', 'weekly', 'monthly')),
  status            text not null default 'booked'
                    check (status in ('awaiting_payment', 'booked', 'in_progress', 'completed', 'cancelled', 'expired')),
  first_at          timestamptz not null,
  last_at           timestamptz not null,
  timezone          text not null default 'Asia/Kuala_Lumpur',
  days              integer not null default 1 check (days between 1 and 400),
  trip              jsonb not null check (jsonb_typeof(trip) = 'object' and pg_column_size(trip) <= 16384),
  quote             jsonb not null check (jsonb_typeof(quote) = 'object' and pg_column_size(quote) <= 65536),
  pay               text not null check (pay in ('cash', 'wallet', 'link', 'family', 'business')),
  plan              text not null check (plan in ('start', 'link_first', 'deposit', 'full', 'business')),
  business_account_id uuid,
  price             numeric(12,2) not null check (price >= 0),
  pay_now           numeric(12,2) not null default 0,
  pay_now_by        text not null default 'none' check (pay_now_by in ('none', 'app', 'link')),
  app_paid          numeric(12,2) not null default 0,
  link_paid         numeric(12,2) not null default 0,
  cash_paid         numeric(12,2) not null default 0,
  app_left          numeric(12,2) not null default 0,
  link_left         numeric(12,2) not null default 0,
  cash_left         numeric(12,2) not null default 0,
  allocated_amount  numeric(12,2) not null default 0,
  kept_amount       numeric(12,2) not null default 0,
  refunded_amount   numeric(12,2) not null default 0,
  refund_due        numeric(12,2) not null default 0,
  pay_test          boolean not null default false,
  link_intents      jsonb not null default '[]'::jsonb,
  pay_url           text,
  pay_until         timestamptz,
  free_cancel_until timestamptz not null,
  hire_booking_id   uuid,
  reminded_at       timestamptz,
  cancelled_at      timestamptz,
  cancelled_by      text check (cancelled_by is null or cancelled_by in ('passenger', 'driver', 'admin', 'system')),
  cancel_reason     text check (cancel_reason is null or char_length(cancel_reason) <= 200),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
alter table public.mygig_bookings drop constraint if exists mygig_bookings_money;
alter table public.mygig_bookings add constraint mygig_bookings_money check (
  pay_now >= 0 and app_paid >= 0 and link_paid >= 0 and cash_paid >= 0 and app_left >= 0 and link_left >= 0
  and cash_left >= 0 and allocated_amount >= 0 and kept_amount >= 0 and refunded_amount >= 0 and refund_due >= 0
  and jsonb_typeof(link_intents) = 'array');
create index if not exists mygig_bookings_driver_idx on public.mygig_bookings (driver_id, first_at);
create index if not exists mygig_bookings_rider_idx on public.mygig_bookings (rider_id, first_at) where rider_id is not null;
create index if not exists mygig_bookings_offer_idx on public.mygig_bookings (offer_id);
create index if not exists mygig_bookings_open_idx on public.mygig_bookings (status, first_at)
  where status in ('awaiting_payment', 'booked', 'in_progress');
comment on table public.mygig_bookings is
  'myGiG (0330): a booking for later or a hire by time a driver made with a passenger in myGiG. The money columns are get.ride''s ledger of what was paid (in the app, by link, in cash) and where it went.';

create table if not exists public.mygig_booking_days (
  booking_id  uuid not null references public.mygig_bookings(id) on delete cascade,
  day_no      integer not null check (day_no between 1 and 400),
  starts_at   timestamptz not null,
  status      text not null default 'scheduled'
              check (status in ('scheduled', 'released', 'completed', 'cancelled', 'expired')),
  quote       jsonb not null check (jsonb_typeof(quote) = 'object' and pg_column_size(quote) <= 16384),
  ride_id     uuid references public.ride_requests(id) on delete set null,
  reminded_at timestamptz,
  primary key (booking_id, day_no)
);
create index if not exists mygig_booking_days_due_idx on public.mygig_booking_days (starts_at) where status = 'scheduled';
create index if not exists mygig_booking_days_ride_idx on public.mygig_booking_days (ride_id) where ride_id is not null;

drop trigger if exists trg_mygig_bookings_updated_at on public.mygig_bookings;
create trigger trg_mygig_bookings_updated_at before update on public.mygig_bookings
  for each row execute function public.set_updated_at();

alter table public.mygig_bookings enable row level security;
alter table public.mygig_booking_days enable row level security;
revoke all on public.mygig_bookings, public.mygig_booking_days from anon;
revoke insert, update, delete on public.mygig_bookings, public.mygig_booking_days from authenticated;
grant select on public.mygig_bookings, public.mygig_booking_days to authenticated;
drop policy if exists "mygig_bookings read" on public.mygig_bookings;
create policy "mygig_bookings read" on public.mygig_bookings for select to authenticated
  using (driver_id = (select auth.uid()) or rider_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "mygig_booking_days read" on public.mygig_booking_days;
create policy "mygig_booking_days read" on public.mygig_booking_days for select to authenticated
  using (exists (select 1 from public.mygig_bookings b where b.id = mygig_booking_days.booking_id
                   and (b.driver_id = (select auth.uid()) or b.rider_id = (select auth.uid())
                        or (select public.caller_is_admin()))));

insert into public.admin_table_pages (target, page) values
  ('rpc:mygig_booking_cancel', 'admin-mygig')
on conflict do nothing;

-- ---- 2. Settings -----------------------------------------------------------------------------------
-- 0329's defaults, with bookings for later and hire by time.
create or replace function public.mygig_defaults()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'enabled', true,
    'qrChoice', true,
    'phoneRequired', false,
    'nameMode', 'partial',            -- full | partial | hide
    'idMode', 'last4',                -- full | last4 | hide
    'ways', jsonb_build_object('app', true, 'sms', true, 'whatsapp', true, 'here', true),
    'acceptWaitSec', 120,
    'linkExpiryHours', 24,
    'fare', jsonb_build_object('base', 4, 'perKm', 0.95, 'perMin', 0.25, 'min', 8),
    'allowOwnFare', true,
    'ownFareLimits', jsonb_build_object('baseMax', 10, 'perKmMin', 0.5, 'perKmMax', 2.5, 'perMinMax', 1,
                                        'minMax', 20),
    'luggage', jsonb_build_object('maxBags', 5, 'maxPerBag', 10),
    'approach', jsonb_build_object('allowed', true, 'maxPerKm', 5, 'maxPerRide', 30),
    'busy', jsonb_build_object('allowed', true, 'nightFrom', '00:00', 'nightTo', '06:00',
                               'peakFrom', '17:00', 'peakTo', '20:00', 'maxPct', 50, 'maxPeak', 10),
    'waiting', jsonb_build_object('on', true, 'freeMin', 3, 'perMin', 0.30, 'allowOwn', true, 'maxPerMin', 2,
                                  'cap', 60),
    'cancel', jsonb_build_object('on', true, 'freeMin', 2, 'max', 10),
    'noShow', jsonb_build_object('on', true, 'max', 10),
    'dailyLimit', 10,
    'guard', 1.5,
    'maxKm', 0,
    'repeatFlag', 4,
    'lookupPer10Min', 30,
    'timezone', 'Asia/Kuala_Lumpur',
    -- 0330: bookings for later.
    'later', jsonb_build_object('enabled', true, 'aheadDays', 60, 'remindMin', 60, 'startEarlyMin', 60,
                                'payWaitMin', 30),
    -- 0330: hire by time from myGiG.
    'hire', jsonb_build_object(
      'enabled', true,
      'packages', jsonb_build_object('hourly', true, 'daily', true, 'weekly', true, 'monthly', true),
      'leadMin', jsonb_build_object('trip', 30, 'hourly', 60, 'daily', 720, 'weekly', 1440, 'monthly', 2880),
      'minHours', 2, 'maxHours', 12, 'dayHoursMin', 8, 'dayHoursMax', 12,
      'maxDays', 6, 'maxWeeks', 4, 'maxMonths', 3,
      'depositPct', 30,
      'freeCancelHours', jsonb_build_object('trip', 1, 'hourly', 2, 'daily', 24, 'weekly', 24, 'monthly', 48),
      'nonApp', 'link',
      'holidays', 'skip',
      'stepMin', 30,
      'rates', jsonb_build_object('hour', 40, 'kmHour', 20, 'overtime', 45, 'extraKm', 1,
                                  'day', 350, 'kmDay', 200, 'week', 1900, 'kmWeek', 1200,
                                  'month', 7200, 'kmMonth', 4500, 'overnight', 80),
      'allowOwnRates', true,
      'ownLimits', jsonb_build_object('hourMin', 20, 'hourMax', 100, 'dayMin', 150, 'dayMax', 800,
                                      'weekMin', 800, 'weekMax', 4000, 'monthMin', 3000, 'monthMax', 15000,
                                      'overtimeMax', 100, 'overnightMax', 200)));
$$;

-- The Default rule shows the new parts with get.ride's values (Admin ›
-- myGiG settings edits them there; a region rule sets only what it sets).
update public.mygig_rules
   set settings = jsonb_build_object('later', public.mygig_defaults()->'later', 'hire', public.mygig_defaults()->'hire')
                  || settings
 where level = 'default' and not (settings ? 'later' and settings ? 'hire');

-- 0329's checks, and the booking and hire settings.
create or replace function public.mygig_settings_problem(p jsonb)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  r record;
  h jsonb := coalesce(p->'hire', '{}'::jsonb);
begin
  if p ? 'nameMode' and p->>'nameMode' not in ('full', 'partial', 'hide') then
    return 'A registered passenger''s name is shown full, partly hidden or hidden.';
  end if;
  if p ? 'idMode' and p->>'idMode' not in ('full', 'last4', 'hide') then
    return 'An ID number is shown full, as its last 4, or hidden.';
  end if;
  for r in
    select key, value from jsonb_each(coalesce(p->'busy', '{}'::jsonb)) where key in ('nightFrom', 'nightTo', 'peakFrom', 'peakTo')
  loop
    if coalesce(r.value #>> '{}', '') !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then
      return 'Busy times are times of day, like 06:00.';
    end if;
  end loop;
  if exists (with recursive leaves(v) as (
               select value from jsonb_each(p)
               union all
               select e.value from leaves l, jsonb_each(case when jsonb_typeof(l.v) = 'object' then l.v else '{}'::jsonb end) e)
             select 1 from leaves where jsonb_typeof(v) = 'number' and ((v #>> '{}')::numeric < 0 or (v #>> '{}')::numeric > 100000)) then
    return 'Amounts are 0 to 100000.';
  end if;
  if public.mygig_num(p->'guard', 1.5) > 100 then
    return 'The price guard is 0 (off) to 100 times the app price.';
  end if;
  -- 0330
  if h ? 'nonApp' and h->>'nonApp' not in ('link', 'no') then
    return 'Passengers who can''t pay in the app pay by link first, or multi-day hire isn''t offered to them.';
  end if;
  if h ? 'holidays' and h->>'holidays' not in ('skip', 'work') then
    return 'Public holidays are skipped or worked.';
  end if;
  if public.mygig_num(h->'depositPct', 30) > 100 then
    return 'The deposit is 0 to 100%.';
  end if;
  if public.mygig_num(h->'minHours', 2) < 1 or public.mygig_num(h->'maxHours', 12) > 24
     or public.mygig_num(h->'minHours', 2) > public.mygig_num(h->'maxHours', 12) then
    return 'Hourly hire is 1 to 24 hours, the least no more than the most.';
  end if;
  if public.mygig_num(h->'dayHoursMin', 8) < 1 or public.mygig_num(h->'dayHoursMax', 12) > 24
     or public.mygig_num(h->'dayHoursMin', 8) > public.mygig_num(h->'dayHoursMax', 12) then
    return 'Hours a day are 1 to 24, the least no more than the most.';
  end if;
  if public.mygig_num(h->'maxDays', 6) not between 1 and 60 or public.mygig_num(h->'maxWeeks', 4) not between 1 and 52
     or public.mygig_num(h->'maxMonths', 3) not between 1 and 24 then
    return 'The most days is 1 to 60, weeks 1 to 52, months 1 to 24.';
  end if;
  if public.mygig_num(h->'stepMin', 30) not between 1 and 240 then
    return 'Overtime is counted in steps of 1 to 240 minutes.';
  end if;
  if public.mygig_num(p #> '{later,aheadDays}', 60) not between 1 and 400 then
    return 'Bookings are 1 to 400 days ahead.';
  end if;
  return null;
end;
$$;

-- ---- 3. The driver's own hire settings ------------------------------------------------------------
-- 0329's prefs, with hire by time: the packages the driver offers, and
-- their own rates when the admin allows them, within the admin's limits.
create or replace function public.mygig_prefs_normalize(p jsonb, s jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  lim jsonb := coalesce(s->'ownFareLimits', '{}'::jsonb);
  card jsonb := coalesce(s->'fare', '{}'::jsonb);
  f jsonb := coalesce(p->'fare', '{}'::jsonb);
  maxBag numeric := public.mygig_num(s #> '{luggage,maxPerBag}', 10);
  ap jsonb := coalesce(p->'approach', '{}'::jsonb);
  bz jsonb := coalesce(p->'busy', '{}'::jsonb);
  wt jsonb := coalesce(p->'wait', '{}'::jsonb);
  ns jsonb := coalesce(p->'noShow', '{}'::jsonb);
  cx jsonb := coalesce(p->'cancel', '{}'::jsonb);
  hr jsonb := coalesce(p #> '{hire,rates}', '{}'::jsonb);
  hl jsonb := coalesce(s #> '{hire,ownLimits}', '{}'::jsonb);
  gr jsonb := coalesce(s #> '{hire,rates}', '{}'::jsonb);
  v_min numeric;
  v_perkm numeric;
begin
  p := coalesce(p, '{}'::jsonb);
  v_perkm := round(least(public.mygig_num(lim->'perKmMax', 2.5), greatest(public.mygig_num(lim->'perKmMin', 0),
                     public.mygig_num(f->'perKm', public.mygig_num(card->'perKm', 0.95)))), 2);
  v_min := round(least(public.mygig_num(lim->'minMax', 20), greatest(0,
                     public.mygig_num(f->'min', public.mygig_num(card->'min', 8)))), 2);
  return jsonb_build_object(
    'ownFare', public.mygig_bool(p->'ownFare', false) and public.mygig_bool(s->'allowOwnFare', true),
    'fare', jsonb_build_object(
      'base', round(least(public.mygig_num(lim->'baseMax', 10), greatest(0,
                public.mygig_num(f->'base', public.mygig_num(card->'base', 4)))), 2),
      'perKm', v_perkm,
      'perMin', round(least(public.mygig_num(lim->'perMinMax', 1), greatest(0,
                public.mygig_num(f->'perMin', public.mygig_num(card->'perMin', 0.25)))), 2),
      'min', v_min),
    'lug', jsonb_build_object(
      'small', round(least(maxBag, greatest(0, public.mygig_num(p #> '{lug,small}', 0))), 2),
      'medium', round(least(maxBag, greatest(0, public.mygig_num(p #> '{lug,medium}', 2))), 2),
      'large', round(least(maxBag, greatest(0, public.mygig_num(p #> '{lug,large}', 4))), 2)),
    'freeBags', least(20, greatest(0, public.mygig_num(p->'freeBags', 0)::int)),
    'showTax', public.mygig_bool(p->'showTax', true),
    'roundUp', public.mygig_bool(p->'roundUp', false),
    'approach', jsonb_build_object(
      'mode', case when not public.mygig_bool(s #> '{approach,allowed}', true) then 'off'
                   when ap->>'mode' in ('off', 'perkm', 'fixed') then ap->>'mode' else 'off' end,
      'perKm', round(least(public.mygig_num(s #> '{approach,maxPerKm}', 5), greatest(0, public.mygig_num(ap->'perKm', 1))), 2),
      'fixed', round(least(public.mygig_num(s #> '{approach,maxPerRide}', 30), greatest(0, public.mygig_num(ap->'fixed', 5))), 2),
      'freeKm', round(least(50, greatest(0, public.mygig_num(ap->'freeKm', 1))), 1)),
    'busy', jsonb_build_object(
      'on', public.mygig_bool(bz->'on', false) and public.mygig_bool(s #> '{busy,allowed}', true),
      'night', round(least(public.mygig_num(s #> '{busy,maxPct}', 50), greatest(0, public.mygig_num(bz->'night', 20))), 1),
      'peak', round(least(public.mygig_num(s #> '{busy,maxPeak}', 10), greatest(0, public.mygig_num(bz->'peak', 2))), 2),
      'weekend', round(least(public.mygig_num(s #> '{busy,maxPct}', 50), greatest(0, public.mygig_num(bz->'weekend', 10))), 1)),
    'wait', jsonb_build_object(
      'on', public.mygig_bool(wt->'on', true),
      'own', public.mygig_bool(wt->'own', false) and public.mygig_bool(s #> '{waiting,allowOwn}', true),
      'free', least(60, greatest(0, public.mygig_num(wt->'free', 5)::int)),
      'perMin', round(least(public.mygig_num(s #> '{waiting,maxPerMin}', 2), greatest(0, public.mygig_num(wt->'perMin', 0.40))), 2)),
    'noShow', jsonb_build_object(
      'on', public.mygig_bool(ns->'on', false),
      'amount', round(least(public.mygig_num(s #> '{noShow,max}', 10), greatest(0, public.mygig_num(ns->'amount', 5))), 2)),
    'cancel', jsonb_build_object(
      'on', public.mygig_bool(cx->'on', false),
      'amount', round(least(public.mygig_num(s #> '{cancel,max}', 10), greatest(0, public.mygig_num(cx->'amount', 5))), 2)),
    -- 0330
    'hire', jsonb_build_object(
      'offer', jsonb_build_object(
        'hourly', public.mygig_bool(p #> '{hire,offer,hourly}', true),
        'daily', public.mygig_bool(p #> '{hire,offer,daily}', true),
        'weekly', public.mygig_bool(p #> '{hire,offer,weekly}', true),
        'monthly', public.mygig_bool(p #> '{hire,offer,monthly}', true)),
      'own', public.mygig_bool(p #> '{hire,own}', false) and public.mygig_bool(s #> '{hire,allowOwnRates}', true),
      'rates', jsonb_build_object(
        'hour', round(least(public.mygig_num(hl->'hourMax', 100), greatest(public.mygig_num(hl->'hourMin', 0),
                  public.mygig_num(hr->'hour', public.mygig_num(gr->'hour', 40)))), 2),
        'day', round(least(public.mygig_num(hl->'dayMax', 800), greatest(public.mygig_num(hl->'dayMin', 0),
                  public.mygig_num(hr->'day', public.mygig_num(gr->'day', 350)))), 2),
        'week', round(least(public.mygig_num(hl->'weekMax', 4000), greatest(public.mygig_num(hl->'weekMin', 0),
                  public.mygig_num(hr->'week', public.mygig_num(gr->'week', 1900)))), 2),
        'month', round(least(public.mygig_num(hl->'monthMax', 15000), greatest(public.mygig_num(hl->'monthMin', 0),
                  public.mygig_num(hr->'month', public.mygig_num(gr->'month', 7200)))), 2),
        'overtime', round(least(public.mygig_num(hl->'overtimeMax', 100), greatest(0,
                  public.mygig_num(hr->'overtime', public.mygig_num(gr->'overtime', 45)))), 2),
        'overnight', round(least(public.mygig_num(hl->'overnightMax', 200), greatest(0,
                  public.mygig_num(hr->'overnight', public.mygig_num(gr->'overnight', 80)))), 2))));
end;
$$;

-- The rates a hire is priced with: the driver's own (per hour, day, week,
-- month, overtime, overnight) when they chose them and the admin allows it,
-- with get.ride's km and extra km; else get.ride's myGiG hire rates.
create or replace function public.mygig_hire_card(s jsonb, pr jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case when public.mygig_bool(pr #> '{hire,own}', false) and public.mygig_bool(s #> '{hire,allowOwnRates}', true)
              then coalesce(s #> '{hire,rates}', '{}'::jsonb) || coalesce(pr #> '{hire,rates}', '{}'::jsonb)
                   || jsonb_build_object('own', true)
              else coalesce(s #> '{hire,rates}', '{}'::jsonb) || jsonb_build_object('own', false) end;
$$;

-- The hire packages this driver may send here.
create or replace function public.mygig_hire_kinds(s jsonb, pr jsonb)
returns text[]
language sql
immutable
set search_path = public
as $$
  select case when not public.mygig_bool(s #> '{hire,enabled}', true) then '{}'::text[] else
    array_remove(array[
      case when public.mygig_bool(s #> '{hire,packages,hourly}', true) and public.mygig_bool(pr #> '{hire,offer,hourly}', true) then 'hourly' end,
      case when public.mygig_bool(s #> '{hire,packages,daily}', true) and public.mygig_bool(pr #> '{hire,offer,daily}', true) then 'daily' end,
      case when public.mygig_bool(s #> '{hire,packages,weekly}', true) and public.mygig_bool(pr #> '{hire,offer,weekly}', true) then 'weekly' end,
      case when public.mygig_bool(s #> '{hire,packages,monthly}', true) and public.mygig_bool(pr #> '{hire,offer,monthly}', true) then 'monthly' end],
      null) end;
$$;

-- ---- 4. The booking: what, when, how it is paid -----------------------------------------------------
create or replace function public.mygig_kind_label(p_kind text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_kind when 'hourly' then 'Hourly hire' when 'daily' then 'Daily hire' when 'weekly' then 'Weekly hire'
                     when 'monthly' then 'Monthly hire' else 'myGiG ride' end;
$$;

-- "30 min", "1 hour", "12 hours", "2 days".
create or replace function public.mygig_lead_text(p_min numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_min < 60 then round(p_min)::int || ' min'
              when p_min < 1440 or mod(p_min::int, 1440) <> 0 then
                trim(trailing '.' from trim(trailing '0' from round(p_min / 60.0, 1)::text))
                || case when p_min = 60 then ' hour' else ' hours' end
              else (p_min / 1440)::int || case when p_min = 1440 then ' day' else ' days' end end;
$$;

-- "Mon 2 Nov, 8:00 am" in [p_tz].
create or replace function public.mygig_when_text(p_at timestamptz, p_tz text default 'Asia/Kuala_Lumpur')
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Kuala_Lumpur'), 'Dy FMDD Mon, FMHH12:MI')
         || lower(to_char(p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Kuala_Lumpur'), ' am'));
$$;

-- The booking as the app sends it ({kind, when, at, hours, days,
-- hoursPerDay, periods, weekdays, overnight}), checked against the
-- settings [s]: a value outside the admin's limits is refused with why.
create or replace function public.mygig_booking_clean(p jsonb, s jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  h jsonb := coalesce(s->'hire', '{}'::jsonb);
  k text := coalesce(nullif(p->>'kind', ''), 'trip');
  w text := case when p->>'when' = 'later' then 'later' else 'now' end;
  v_at timestamptz;
  v_hours numeric := public.mygig_num(p->'hours', 3);
  v_days int := public.mygig_num(p->'days', 1)::int;
  v_hpd numeric := public.mygig_num(p->'hoursPerDay', 10);
  v_periods int := public.mygig_num(p->'periods', 1)::int;
  v_max int;
  wd int[];
begin
  p := coalesce(p, '{}'::jsonb);
  if k not in ('trip', 'hourly', 'daily', 'weekly', 'monthly') then
    raise exception 'MYGIG_HIRE' using errcode = '22023', hint = 'Choose a trip or a hire package.';
  end if;
  -- Days, weeks and months are booked ahead.
  if k in ('daily', 'weekly', 'monthly') then
    w := 'later';
  end if;
  if w = 'later' then
    begin
      v_at := (p->>'at')::timestamptz;
    exception when others then
      v_at := null;
    end;
    if v_at is null then
      raise exception 'MYGIG_WHEN' using errcode = '22023', hint = 'Choose the start date and time.';
    end if;
  end if;
  if k = 'hourly' and (v_hours < public.mygig_num(h->'minHours', 2) or v_hours > public.mygig_num(h->'maxHours', 12)
                       or v_hours <> round(v_hours * 2) / 2) then
    raise exception 'MYGIG_HIRE_LIMIT' using errcode = '22023',
      hint = format('Hourly hire is %s to %s hours.', trim_scale(public.mygig_num(h->'minHours', 2)),
                    trim_scale(public.mygig_num(h->'maxHours', 12)));
  end if;
  if k in ('daily', 'weekly', 'monthly') and (v_hpd < public.mygig_num(h->'dayHoursMin', 8)
       or v_hpd > public.mygig_num(h->'dayHoursMax', 12) or v_hpd <> round(v_hpd * 2) / 2) then
    raise exception 'MYGIG_HIRE_LIMIT' using errcode = '22023',
      hint = format('A day is %s to %s hours.', trim_scale(public.mygig_num(h->'dayHoursMin', 8)),
                    trim_scale(public.mygig_num(h->'dayHoursMax', 12)));
  end if;
  if k = 'daily' and (v_days < 1 or v_days > public.mygig_num(h->'maxDays', 6)) then
    raise exception 'MYGIG_HIRE_LIMIT' using errcode = '22023',
      hint = format('Daily hire is 1 to %s days.', public.mygig_num(h->'maxDays', 6)::int);
  end if;
  v_max := case k when 'weekly' then public.mygig_num(h->'maxWeeks', 4)::int else public.mygig_num(h->'maxMonths', 3)::int end;
  if k in ('weekly', 'monthly') and (v_periods < 1 or v_periods > v_max) then
    raise exception 'MYGIG_HIRE_LIMIT' using errcode = '22023',
      hint = format('%s is 1 to %s %s.', public.mygig_kind_label(k), v_max, case k when 'weekly' then 'weeks' else 'months' end);
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into wd
    from (select public.mygig_num(e, 0)::int x
            from jsonb_array_elements(case when jsonb_typeof(p->'weekdays') = 'array' then p->'weekdays'
                                           else '[1, 2, 3, 4, 5]'::jsonb end) e) y
   where x between 1 and 7;
  if k in ('weekly', 'monthly') and cardinality(wd) = 0 then
    raise exception 'MYGIG_HIRE_DAYS' using errcode = '22023', hint = 'Choose the working days.';
  end if;
  return jsonb_build_object(
    'kind', k, 'when', w, 'at', v_at,
    'hours', case when k = 'hourly' then v_hours end,
    'days', case when k = 'daily' then v_days end,
    'hoursPerDay', case when k in ('daily', 'weekly', 'monthly') then v_hpd end,
    'periods', case when k in ('weekly', 'monthly') then v_periods end,
    'weekdays', case when k in ('weekly', 'monthly') then to_jsonb(wd) end,
    'overnight', k = 'daily' and public.mygig_bool(p->'overnight', false));
end;
$$;

-- Why the booking's time can't be, or null: {code, message}.
create or replace function public.mygig_when_problem(b jsonb, s jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  k text := b->>'kind';
  v_at timestamptz := nullif(b->>'at', '')::timestamptz;
  v_lead numeric := public.mygig_num(s #> array['hire', 'leadMin', k],
                      case k when 'trip' then 30 when 'hourly' then 60 when 'daily' then 720 when 'weekly' then 1440 else 2880 end);
  v_ahead numeric := public.mygig_num(s #> '{later,aheadDays}', 60);
begin
  if b->>'when' <> 'later' then
    return null;
  end if;
  if not public.mygig_bool(s #> '{later,enabled}', true) then
    return jsonb_build_object('code', 'MYGIG_LATER_OFF', 'message', 'Bookings for later aren''t offered here.');
  end if;
  if v_at is null then
    return jsonb_build_object('code', 'MYGIG_WHEN', 'message', 'Choose the start date and time.');
  end if;
  if v_at <= p_now then
    return jsonb_build_object('code', 'MYGIG_TIME_PASSED', 'message', 'That time has passed. Choose a later time.');
  end if;
  if v_at < p_now + make_interval(mins => v_lead::int) then
    return jsonb_build_object('code', 'MYGIG_TOO_SOON', 'leadMin', v_lead,
      'message', format('%s must start at least %s from now.',
                        case k when 'trip' then 'A later ride' else public.mygig_kind_label(k) end,
                        public.mygig_lead_text(v_lead)));
  end if;
  if v_at > p_now + make_interval(days => v_ahead::int) then
    return jsonb_build_object('code', 'MYGIG_TOO_FAR_AHEAD',
      'message', format('Bookings go up to %s days ahead.', v_ahead::int));
  end if;
  return null;
end;
$$;

-- How a booking is paid (owner's rule): {plan, payNow, payNowBy, balance,
-- balanceBy, pay, freeCancelHours, freeCancelUntil, depositPct, problem}.
--   now:        part A's rules (plan 'now').
--   business:   nothing upfront; each day on the account (0313).
--   trip / hourly later: in the app ('start': charged when the driver
--               starts); otherwise the price by link when they accept.
--   daily:      the deposit when they accept (in the app, else by link),
--               the balance before day 1 starts.
--   weekly / monthly: in full when they accept (in the app, else by link).
-- A passenger without in-app payment pays by link before the booking is
-- confirmed, or (nonApp 'no') isn't offered multi-day hire.
create or replace function public.mygig_booking_plan(b jsonb, p_pay text, p_registered boolean, s jsonb,
                                                     p_total numeric)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  k text := b->>'kind';
  v_inapp boolean := coalesce(p_registered, false) and p_pay in ('wallet', 'family');
  v_pct numeric := least(100, greatest(0, public.mygig_num(s #> '{hire,depositPct}', 30)));
  v_free numeric := public.mygig_num(s #> array['hire', 'freeCancelHours', k],
                      case k when 'trip' then 1 when 'hourly' then 2 when 'monthly' then 48 else 24 end);
  v_at timestamptz := nullif(b->>'at', '')::timestamptz;
  v_plan text;
  v_now numeric := 0;
  v_by text := 'none';
  v_bal numeric := 0;
  v_bal_by text := 'none';
  v_pay text := p_pay;
  v_problem jsonb;
begin
  p_total := round(coalesce(p_total, 0), 2);
  if b->>'when' <> 'later' then
    return jsonb_build_object('plan', 'now', 'payNow', 0, 'payNowBy', 'none', 'balance', 0, 'balanceBy', 'none',
                              'pay', p_pay);
  end if;
  if p_pay = 'business' then
    v_plan := 'business';
  elsif k in ('trip', 'hourly') then
    if v_inapp then
      v_plan := 'start'; v_bal := p_total; v_bal_by := 'app';
    else
      v_plan := 'link_first'; v_now := p_total; v_by := 'link'; v_pay := 'link';
    end if;
  else
    if not v_inapp and coalesce(s #>> '{hire,nonApp}', 'link') = 'no' then
      v_problem := jsonb_build_object('code', 'MYGIG_HIRE_APP_ONLY',
        'message', public.mygig_kind_label(k) || ' needs a registered passenger paying in the app (set by get.ride).');
    end if;
    if k = 'daily' then
      v_plan := 'deposit';
      v_now := round(p_total * v_pct / 100, 2);
      v_bal := round(p_total - v_now, 2);
      v_by := case when v_inapp then 'app' else 'link' end;
      v_bal_by := case when v_inapp then 'app' when p_pay = 'cash' then 'cash' else 'link_or_cash' end;
      if not v_inapp and p_pay <> 'cash' then
        v_pay := 'link';
      end if;
    else
      v_plan := 'full';
      v_now := p_total;
      v_by := case when v_inapp then 'app' else 'link' end;
      if not v_inapp then
        v_pay := 'link';
      end if;
    end if;
  end if;
  return jsonb_build_object(
    'plan', v_plan, 'payNow', v_now, 'payNowBy', case when v_now > 0 then v_by else 'none' end,
    'balance', v_bal, 'balanceBy', case when v_bal > 0 then v_bal_by else 'none' end,
    'pay', v_pay, 'depositPct', v_pct, 'freeCancelHours', v_free,
    'freeCancelUntil', v_at - make_interval(secs => (v_free * 3600)::int),
    'payWaitMin', public.mygig_num(s #> '{later,payWaitMin}', 30),
    'problem', v_problem);
end;
$$;

-- The trip as sent, for a booking: a hire may have no drop-off ("as
-- directed": the passenger tells the driver where to go).
create or replace function public.mygig_trip_for(p_trip jsonb, b jsonb, s jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := coalesce(p_trip, '{}'::jsonb);
  v_dir boolean := false;
begin
  if coalesce(b->>'kind', 'trip') <> 'trip'
     and (jsonb_typeof(v->'drop') is distinct from 'object' or public.mygig_bool(v #> '{drop,directed}', false)
          or public.mygig_bool(v->'directed', false)) then
    v := v || jsonb_build_object(
      'drop', jsonb_build_object('lat', v #> '{pickup,lat}', 'lng', v #> '{pickup,lng}',
                                 'name', 'No drop-off · as directed'),
      'stops', '[]'::jsonb, 'km', 0, 'min', 0, 'round', false);
    v_dir := true;
  end if;
  return public.mygig_trip_clean(v, s) || jsonb_build_object('directed', v_dir);
end;
$$;

-- The price of hire [b] (cleaned) for driver [p_uid]: the package from the
-- hire card (hourly: hours × the hour rate; daily: the day rate (for 10
-- hours) pro rata to the hours a day, a night's allowance between days
-- when overnight; weekly / monthly: the period's rate (5 days a week, 10
-- hours a day) pro rata to the working days and hours, shared over its
-- working days, a public holiday skipped as 0328 does); luggage and coming
-- to the pickup on day 1; the place fees each day; the region's tax on
-- each day; rounding each day's total up when the driver rounds. The total
-- is the days' totals; dateList holds each day.
create or replace function public.mygig_hire_price(p_uid uuid, p_trip jsonb, s jsonb, pr jsonb, p_place jsonb,
                                                   b jsonb, p_at timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  h jsonb := coalesce(s->'hire', '{}'::jsonb);
  c jsonb := public.mygig_hire_card(s, pr);
  k text := b->>'kind';
  v_tz text := coalesce(nullif(s->>'timezone', ''), 'Asia/Kuala_Lumpur');
  v_first timestamptz := coalesce(nullif(b->>'at', '')::timestamptz, p_at);
  v_local timestamp := v_first at time zone v_tz;
  v_hours numeric;
  v_hpd numeric := public.mygig_num(b->'hoursPerDay', 10);
  v_wd int[];
  v_periods int := greatest(1, public.mygig_num(b->'periods', 1)::int);
  v_list jsonb := '[]'::jsonb;
  v_out jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_rate numeric;
  v_pprice numeric;
  v_pkm numeric;
  v_nominal int;
  v_per numeric;
  v_start date;
  v_end date;
  v_day date;
  i int;
  kk int;
  tq jsonb;
  v_fees numeric;
  v_lug numeric;
  v_appr numeric;
  v_night numeric;
  d jsonb;
  v_sub numeric;
  v_tax numeric;
  v_exact numeric;
  v_tot numeric;
  t_base numeric := 0;
  t_night numeric := 0;
  t_sub numeric := 0;
  t_tax numeric := 0;
  t_exact numeric := 0;
  t_total numeric := 0;
  t_km numeric := 0;
  v_round boolean;
  v_days int;
begin
  select coalesce(array_agg((x #>> '{}')::int order by (x #>> '{}')::int), '{1,2,3,4,5}')
    into v_wd from jsonb_array_elements(case when jsonb_typeof(b->'weekdays') = 'array' then b->'weekdays'
                                                  else '[1, 2, 3, 4, 5]'::jsonb end) x;
  -- Luggage, coming to the pickup, the place fees and the tax, as a trip's.
  tq := public.mygig_price(p_uid, p_trip, s, pr, p_place, v_first);
  v_fees := coalesce((tq->>'placeFees')::numeric, 0);
  v_lug := coalesce((tq->>'luggage')::numeric, 0);
  v_appr := coalesce((tq->>'approach')::numeric, 0);
  v_round := coalesce((tq->>'roundUp')::boolean, false);
  if k = 'hourly' then
    v_hours := public.mygig_num(b->'hours', 3);
    v_list := jsonb_build_array(jsonb_build_object(
      'at', v_first, 'base', round(v_hours * public.mygig_num(c->'hour', 0), 2),
      'km', round(v_hours * public.mygig_num(c->'kmHour', 0), 1), 'hours', v_hours, 'period', 1));
  elsif k = 'daily' then
    v_hours := v_hpd;
    v_days := greatest(1, public.mygig_num(b->'days', 1)::int);
    v_per := round(public.mygig_num(c->'day', 0) * v_hpd / 10, 2);
    for i in 1 .. v_days loop
      v_list := v_list || jsonb_build_object(
        'at', (v_local + make_interval(days => i - 1)) at time zone v_tz, 'base', v_per,
        'km', public.mygig_num(c->'kmDay', 0), 'hours', v_hpd, 'period', i,
        'night', case when public.mygig_bool(b->'overnight', false) and i < v_days
                      then public.mygig_num(c->'overnight', 0) else 0 end);
    end loop;
  else
    v_hours := v_hpd;
    v_rate := case k when 'weekly' then public.mygig_num(c->'week', 0) else public.mygig_num(c->'month', 0) end;
    v_pprice := round(v_rate * v_hpd / 10 * cardinality(v_wd) / 5.0, 2);
    v_pkm := case k when 'weekly' then public.mygig_num(c->'kmWeek', 0) else public.mygig_num(c->'kmMonth', 0) end;
    for kk in 1 .. v_periods loop
      v_start := case when k = 'weekly' then v_local::date + (kk - 1) * 7
                      else (v_local::date + make_interval(months => kk - 1))::date end;
      v_end := case when k = 'weekly' then v_start + 7 else (v_local::date + make_interval(months => kk))::date end;
      select count(*) into v_nominal
        from generate_series(v_start, v_end - 1, interval '1 day') g
       where extract(isodow from g)::int = any (v_wd);
      continue when v_nominal = 0;
      v_per := round(v_pprice / v_nominal, 2);
      for v_day in
        select g::date from generate_series(v_start, v_end - 1, interval '1 day') g
         where extract(isodow from g)::int = any (v_wd) order by g
      loop
        if coalesce(h->>'holidays', 'skip') = 'skip' and public.hire_is_holiday(v_day, p_place->>'country') then
          v_skipped := v_skipped || to_jsonb(v_day);
          continue;
        end if;
        v_list := v_list || jsonb_build_object('at', (v_day + v_local::time) at time zone v_tz, 'base', v_per,
                                               'km', round(v_pkm / v_nominal, 1), 'hours', v_hpd, 'period', kk);
      end loop;
    end loop;
  end if;
  i := 0;
  for d in select value from jsonb_array_elements(v_list) loop
    i := i + 1;
    v_night := coalesce((d->>'night')::numeric, 0);
    v_sub := round((d->>'base')::numeric + v_night + v_fees + case when i = 1 then v_lug + v_appr else 0 end, 2);
    v_tax := case when tq->>'taxName' is null then 0
                  when tq->>'taxKind' = 'fixed' then round(public.mygig_num(tq->'taxValue', 0), 2)
                  else round(v_sub * public.mygig_num(tq->'taxValue', 0) / 100, 2) end;
    v_exact := round(v_sub + v_tax, 2);
    v_tot := round(case when v_round then ceil(v_exact - 0.000001) else v_exact end, 2);
    v_out := v_out || jsonb_build_array(d || jsonb_build_object(
      'day', i, 'night', v_night, 'fees', v_fees,
      'luggage', case when i = 1 then v_lug else 0 end, 'approach', case when i = 1 then v_appr else 0 end,
      'sub', v_sub, 'tax', v_tax, 'exact', v_exact, 'total', v_tot,
      'endsAt', (d->>'at')::timestamptz + make_interval(mins => ((d->>'hours')::numeric * 60)::int)));
    t_base := t_base + (d->>'base')::numeric;
    t_night := t_night + v_night;
    t_sub := t_sub + v_sub;
    t_tax := t_tax + v_tax;
    t_exact := t_exact + v_exact;
    t_total := t_total + v_tot;
    t_km := t_km + coalesce((d->>'km')::numeric, 0);
  end loop;
  v_days := jsonb_array_length(v_out);
  return (tq - 'fare' - 'busy' - 'busyLabel' - 'appPrice' - 'guard' - 'card') || jsonb_build_object(
    'hire', true, 'kind', k, 'title', public.mygig_kind_label(k),
    'hours', v_hours, 'hoursPerDay', case when k <> 'hourly' then v_hpd end,
    'days', v_days, 'periods', case when k in ('weekly', 'monthly') then v_periods end,
    'weekdays', case when k in ('weekly', 'monthly') then to_jsonb(v_wd) end,
    'overnight', public.mygig_bool(b->'overnight', false),
    'nights', (select count(*) from jsonb_array_elements(v_out) e where (e->>'night')::numeric > 0),
    'overnightAllowance', public.mygig_num(c->'overnight', 0), 'overnightTotal', round(t_night, 2),
    'card', c, 'ownRates', coalesce((c->>'own')::boolean, false),
    'fare', round(t_base, 2), 'base', round(t_base, 2),
    'perDay', coalesce((v_out->0->>'base')::numeric, 0),
    'kmIncluded', round(t_km, 1), 'kmPerDay', coalesce((v_out->0->>'km')::numeric, 0),
    'km', round(t_km, 1), 'min', round(v_hours * 60),
    'overtimePerHour', public.mygig_num(c->'overtime', 0), 'extraKm', public.mygig_num(c->'extraKm', 0),
    'stepMinutes', public.mygig_num(h->'stepMin', 30)::int,
    'placeFeesPerDay', v_fees, 'placeFees', round(v_fees * v_days, 2),
    'sub', round(t_sub, 2), 'tax', round(t_tax, 2), 'exact', round(t_exact, 2),
    'rounded', round(t_total - t_exact, 2), 'total', round(t_total, 2),
    'guard', false, 'busy', 0,
    'wait', jsonb_build_object('on', false, 'freeMin', 0, 'perMin', 0, 'cap', 0),
    'holidaysSkipped', v_skipped,
    'firstAt', coalesce(v_out->0->>'at', v_first::text),
    'lastAt', coalesce(v_out->(v_days - 1)->>'endsAt', v_first::text),
    'dateList', v_out);
end;
$$;
revoke execute on function public.mygig_hire_price(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, timestamptz) from public, anon, authenticated;

-- A later trip's one start, in the same shape as a hire's days.
create or replace function public.mygig_trip_days(q jsonb, b jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_array(jsonb_build_object(
    'day', 1, 'at', b->>'at', 'base', q->'fare', 'km', q->'km', 'hours', round(coalesce((q->>'min')::numeric, 0) / 60.0, 1),
    'sub', q->'sub', 'tax', q->'tax', 'exact', q->'exact', 'total', q->'total', 'fees', q->'placeFees',
    'luggage', q->'luggage', 'approach', q->'approach',
    'endsAt', (b->>'at')::timestamptz + make_interval(mins => coalesce((q->>'min')::numeric, 30)::int + 30)));
$$;

-- Day [p_day]'s money and hire terms, as the day's ride carries them in
-- mygig.quote (part A's shape, so the final price, the receipt and the
-- trip link read it as a ride's) and mygig.hire (0326's hire columns).
create or replace function public.mygig_day_quote(q jsonb, p_day int)
returns jsonb
language sql
immutable
set search_path = public
as $$
  with d as (select coalesce(case when jsonb_typeof(q->'dateList') = 'array' then q->'dateList'->(p_day - 1) end,
                             '{}'::jsonb) as v)
  select case when coalesce((q->>'hire')::boolean, false) then
    (q - 'dateList' - 'card' - 'holidaysSkipped') || jsonb_build_object(
      'sub', d.v->'sub', 'tax', d.v->'tax', 'exact', d.v->'exact', 'total', d.v->'total',
      'rounded', round(coalesce((d.v->>'total')::numeric, 0) - coalesce((d.v->>'exact')::numeric, 0), 2),
      'fare', d.v->'base', 'base', d.v->'base', 'night', d.v->'night',
      'luggage', coalesce(d.v->'luggage', '0'::jsonb), 'approach', coalesce(d.v->'approach', '0'::jsonb),
      'placeFees', coalesce(d.v->'fees', '0'::jsonb),
      'km', d.v->'km', 'min', round(coalesce((d.v->>'hours')::numeric, 0) * 60),
      'dayNo', p_day, 'at', d.v->'at', 'endsAt', d.v->'endsAt',
      'hire', jsonb_build_object(
        'package', q->>'kind', 'title', q->>'title', 'dayNo', p_day, 'days', q->'days',
        'hours', d.v->'hours', 'minHours', d.v->'hours', 'maxHours', d.v->'hours', 'hourStep', 0.5,
        'rate', round(coalesce((d.v->>'base')::numeric, 0) / greatest(0.5, coalesce((d.v->>'hours')::numeric, 1)), 2),
        'kmIncluded', d.v->'km', 'overtimePerHour', q->'overtimePerHour', 'extraKm', q->'extraKm',
        'stepMinutes', q->'stepMinutes', 'base', d.v->'base', 'total', d.v->'total',
        'holdInWallet', false, 'hold', 0, 'allowCash', false, 'mygig', true))
  else q end
  from d;
$$;

-- The driver has another booking then: [p_from, p_to) overlaps one of
-- their days still to come (their own span, an hour's gap).
create or replace function public.mygig_booking_clash(p_driver uuid, p_from timestamptz, p_to timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.mygig_booking_days d join public.mygig_bookings b on b.id = d.booking_id
     where b.driver_id = p_driver and b.status in ('awaiting_payment', 'booked', 'in_progress')
       and d.status in ('scheduled', 'released')
       and d.starts_at < p_to + interval '1 hour'
       and coalesce((d.quote->>'endsAt')::timestamptz, d.starts_at + interval '2 hours') + interval '1 hour' > p_from);
$$;
revoke execute on function public.mygig_booking_clash(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- ---- 5. Sending: the quote, the offer, accepting -----------------------------------------------------
-- 0329's quote, with a booking (p_trip.booking: kind and when; p_trip.registered
-- tells how a registered passenger would pay): the price, the place
-- problems, why the time can't be, and how it would be paid.
create or replace function public.mygig_quote(p_trip jsonb, p_lat double precision default null,
                                              p_lng double precision default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s jsonb;
  pr jsonb;
  t jsonb;
  pl jsonb;
  b jsonb;
  q jsonb;
  v_prob jsonb;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  pl := coalesce(public.mygig_place((p_trip #>> '{pickup,lat}')::float8, (p_trip #>> '{pickup,lng}')::float8), '{}'::jsonb);
  s := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  pr := public.mygig_prefs_of(v_uid, s);
  b := public.mygig_booking_clean(coalesce(p_trip->'booking', '{}'::jsonb), s);
  t := public.mygig_trip_for(p_trip - 'booking' - 'registered', b, s);
  if b->>'kind' = 'trip' then
    q := public.mygig_price(v_uid, t, s, pr, pl, coalesce(nullif(b->>'at', '')::timestamptz, now()));
  else
    q := public.mygig_hire_price(v_uid, t, s, pr, pl, b, now());
  end if;
  v_prob := public.mygig_place_problem(t);
  if coalesce((t->>'directed')::boolean, false) and v_prob->>'end' = 'drop' then
    v_prob := null;
  end if;
  return q || jsonb_build_object(
    'problem', v_prob, 'trip', t,
    'kinds', to_jsonb(public.mygig_hire_kinds(s, pr)),
    'kindProblem', case when b->>'kind' <> 'trip' and not (b->>'kind' = any (public.mygig_hire_kinds(s, pr)))
                        then jsonb_build_object('code', 'MYGIG_HIRE_OFF',
                               'message', public.mygig_kind_label(b->>'kind') || ' isn''t offered here.') end,
    'whenProblem', public.mygig_when_problem(b, s),
    'booking', b || public.mygig_booking_plan(b, t->>'pay', public.mygig_bool(p_trip->'registered', false), s,
                                              (q->>'total')::numeric));
end;
$$;
revoke execute on function public.mygig_quote(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_quote(jsonb, double precision, double precision) to authenticated;

-- 0329's send, worded for a booking.
create or replace function public.mygig_send(o public.mygig_offers, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d jsonb := public.mygig_driver_card(o.driver_id);
  v_text text;
  v_url text := case when p_token is not null then public.mygig_link_url(p_token) end;
  v_what text;
begin
  v_what := case when o.booking is null or (o.booking->>'kind' = 'trip' and o.booking->>'when' = 'now')
                 then format('a myGiG ride to %s', o.trip #>> '{drop,name}')
                 when o.booking->>'kind' = 'trip'
                 then format('a myGiG ride to %s on %s', o.trip #>> '{drop,name}',
                             public.mygig_when_text((o.booking->>'at')::timestamptz, o.quote #>> '{place,timezone}'))
                 when o.booking->>'when' = 'later'
                 then format('a myGiG %s from %s', lower(public.mygig_kind_label(o.booking->>'kind')),
                             public.mygig_when_text((o.booking->>'at')::timestamptz))
                 else format('a myGiG %s', lower(public.mygig_kind_label(o.booking->>'kind'))) end;
  v_text := case when o.kind = 'change'
    then format('get.ride: %s asks you to accept a new price, %s. Open: %s', d->>'name', public.mygig_money(o.total), v_url)
    else format('get.ride: %s sent you %s for %s. Accept it here: %s', d->>'name', v_what,
                public.mygig_money(o.total), v_url) end;
  if o.way = 'app' and o.passenger_id is not null then
    perform public.enqueue_notification(o.passenger_id, 'mygig-offer-' || o.id || '-' || o.sends, 'ride_status', 'critical',
      case when o.kind = 'change' then 'New price for your ride'
           when o.booking is not null and o.booking->>'when' = 'later' then 'Accept your booking?'
           else 'Accept your ride?' end,
      case when o.kind = 'change' then format('%s changed the trip: %s. Tap to accept.', d->>'name', public.mygig_money(o.total))
           else format('%s has sent you %s: %s. Tap to accept.', d->>'name', v_what, public.mygig_money(o.total)) end,
      jsonb_build_object('type', 'mygig_offer', 'offer_id', o.id, 'role', 'rider'), o.ride_id);
  elsif o.way = 'sms' and o.phone is not null and v_url is not null then
    begin
      insert into public.sms_outbox (channel, to_phone, body, created_by)
      values ('trip_share', o.phone, left(v_text, 300), null);
    exception when others then
      raise warning 'myGiG SMS not queued: %', sqlerrm;
    end;
  end if;
  return jsonb_build_object('link', v_url, 'message', case when v_url is not null then v_text end);
end;
$$;
revoke execute on function public.mygig_send(public.mygig_offers, text) from public, anon, authenticated;

-- 0329's create, with a booking ({trip, phone, name, way, booking}): the
-- package and the time checked, priced as hire when it is, and paid as the
-- plan says. A later booking is checked against the driver's other ones.
create or replace function public.mygig_create(p jsonb, p_lat double precision default null,
                                               p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  st jsonb;
  s jsonb;
  pr jsonb;
  pl jsonb;
  t jsonb;
  q jsonb;
  lk jsonb;
  prob jsonb;
  b jsonb;
  plan jsonb;
  v_digits text;
  v_phone text;
  v_name text := nullif(left(btrim(coalesce(p->>'name', '')), 80), '');
  v_way text := p->>'way';
  v_lookup text;
  v_pid uuid;
  v_token text := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  o public.mygig_offers;
  v_sent jsonb;
  v_later boolean;
  d jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform public.mygig_expire(v_uid);
  st := public.mygig_require(v_uid, p_lat, p_lng, true);
  if exists (select 1 from public.mygig_offers x where x.driver_id = v_uid and x.status = 'waiting' and x.kind = 'new') then
    update public.mygig_offers set status = 'cancelled', answered_at = now()
     where driver_id = v_uid and status = 'waiting' and kind = 'new';
  end if;
  pl := coalesce(public.mygig_place((p #>> '{trip,pickup,lat}')::float8, (p #>> '{trip,pickup,lng}')::float8), '{}'::jsonb);
  s := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  if not public.mygig_bool(s->'enabled', true) then
    raise exception 'MYGIG_OFF_HERE' using errcode = '42501', hint = 'myGiG isn''t offered where this trip starts.';
  end if;
  pr := public.mygig_prefs_of(v_uid, s);
  -- 0330: what and when.
  b := public.mygig_booking_clean(coalesce(p->'booking', '{}'::jsonb), s);
  v_later := b->>'when' = 'later';
  if b->>'kind' <> 'trip' and not (b->>'kind' = any (public.mygig_hire_kinds(s, pr))) then
    raise exception 'MYGIG_HIRE_OFF' using errcode = '42501',
      hint = public.mygig_kind_label(b->>'kind') || ' isn''t offered here, or is off in your myGiG settings.';
  end if;
  prob := public.mygig_when_problem(b, s);
  if prob is not null then
    raise exception '%', prob->>'code' using errcode = '22023', hint = prob->>'message';
  end if;
  t := public.mygig_trip_for(p->'trip', b, s);
  prob := public.mygig_place_problem(t);
  if prob is not null and not (coalesce((t->>'directed')::boolean, false) and prob->>'end' = 'drop') then
    raise exception '%', prob->>'code' using errcode = '42501', hint = prob->>'message';
  end if;

  -- The passenger.
  v_digits := public.mygig_phone_digits(p->>'phone');
  if v_digits is not null and char_length(v_digits) < 9 then
    raise exception 'MYGIG_PHONE' using errcode = '22023', hint = 'Finish the phone number, or clear it.';
  end if;
  if v_digits is null and public.mygig_bool(s->'phoneRequired', false) then
    raise exception 'MYGIG_PHONE' using errcode = '22023', hint = 'Enter the passenger''s phone number.';
  end if;
  if v_digits is not null then
    lk := public.mygig_lookup_inner(v_uid, v_digits, s);
    if lk->>'state' = 'blocked' then
      raise exception 'MYGIG_BLOCKED_NUMBER' using errcode = '42501', hint = 'You blocked this number.';
    end if;
    v_lookup := lk->>'state';
    v_phone := '+' || v_digits;
    if v_lookup in ('latest', 'old') then
      select x.id into v_pid from public.profiles x
       where regexp_replace(coalesce(x.phone, ''), '\D', '', 'g') = v_digits and x.deleted_at is null
       order by x.created_at limit 1;
      v_name := lk->>'name';
    elsif v_name is null then
      raise exception 'MYGIG_NAME' using errcode = '22023', hint = 'Enter the passenger''s name: this number isn''t registered.';
    end if;
  else
    v_lookup := 'nophone';
  end if;
  -- Payment: GET.wallet, Family and business need a registered passenger.
  if t->>'pay' in ('wallet', 'family', 'business') and v_pid is null then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'GET.wallet, Family and business need a registered passenger.';
  end if;
  if t->>'pay' = 'link' and v_phone is null then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Pay by link needs the passenger''s phone.';
  end if;
  if t->>'pay' = 'family' and lk->'family' is null then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Family isn''t available for this passenger.';
  end if;
  if t->>'pay' = 'business' and not exists (
       select 1 from jsonb_array_elements(coalesce(lk->'businesses', '[]'::jsonb)) bz where bz->>'id' = t->>'businessId') then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Choose one of the passenger''s business accounts.';
  end if;
  -- How they accept.
  if v_way is null or not (v_way = any (public.mygig_ways(s, v_lookup, v_phone is not null))) then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'Choose how the passenger accepts the fare.';
  end if;
  if t->>'pay' = 'family' and v_way <> 'app' then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'A Family ride is accepted in the passenger''s app.';
  end if;

  if b->>'kind' = 'trip' then
    q := public.mygig_price(v_uid, t, s, pr, pl, coalesce(nullif(b->>'at', '')::timestamptz, now()));
  else
    q := public.mygig_hire_price(v_uid, t, s, pr, pl, b, now());
    if coalesce((q->>'days')::int, 0) = 0 then
      raise exception 'MYGIG_HIRE_DAYS' using errcode = '22023', hint = 'There are no working days in this period.';
    end if;
  end if;
  -- How it is paid (owner's rule: nothing later without in-app payment).
  plan := public.mygig_booking_plan(b, t->>'pay', v_pid is not null, s, (q->>'total')::numeric);
  if plan->'problem' is not null and jsonb_typeof(plan->'problem') = 'object' then
    raise exception '%', plan #>> '{problem,code}' using errcode = '22023', hint = plan #>> '{problem,message}';
  end if;
  if plan->>'payNowBy' = 'link' and v_phone is null then
    raise exception 'MYGIG_PAY' using errcode = '22023',
      hint = 'Paying by link needs the passenger''s phone: they pay before the booking is confirmed.';
  end if;
  if v_later then
    -- Cash or link becomes link first; the trip says how the rides are paid.
    t := t || jsonb_build_object('pay', plan->>'pay');
    if b->>'kind' = 'trip' then
      d := public.mygig_trip_days(q, b) -> 0;
    else
      d := jsonb_build_object('at', q->>'firstAt', 'endsAt', q->>'lastAt');
    end if;
    if public.mygig_booking_clash(v_uid, (d->>'at')::timestamptz, (d->>'endsAt')::timestamptz) then
      raise exception 'MYGIG_CLASH' using errcode = '22023', hint = 'You have another myGiG booking at that time.';
    end if;
  elsif t->>'pay' = 'cash' and not public.commission_credit_ok(v_uid) then
    -- Cash: the commission and the myGiG fee come off GET.credit at the end,
    -- so a driver below the minimum takes no cash myGiG (0218's setting).
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = 'Your GET.credit is below the minimum for cash trips. Top up, or ask for another way to pay.';
  end if;
  q := q || jsonb_build_object('terms', public.mygig_terms(v_pid is not null, t->>'pay', s, pr, q),
                               'tripFee', st->'fee', 'lookup', v_lookup, 'shownName', v_name,
                               'idShown', lk->'id', 'idType', lk->'idType', 'flagged', coalesce((lk->>'flagged')::boolean, false),
                               'repeat', coalesce((lk->>'repeat')::int, 0), 'trip', t);
  insert into public.mygig_offers (kind, driver_id, passenger_id, passenger_name, phone, lookup, way, token_hash,
                                   trip, quote, total, expires_at, booking)
  values ('new', v_uid, v_pid, v_name, v_phone, v_lookup, v_way, public.mygig_token_hash(v_token),
          t, q - 'trip', (q->>'total')::numeric,
          now() + make_interval(secs => greatest(30, least(1800, public.mygig_num(s->'acceptWaitSec', 120)::int))),
          case when b->>'kind' <> 'trip' or v_later then b || plan end)
  returning * into o;
  v_sent := public.mygig_send(o, v_token);
  return jsonb_build_object('offerId', o.id, 'token', v_token, 'way', o.way, 'expiresAt', o.expires_at,
                            'total', o.total, 'quote', o.quote, 'link', v_sent->>'link', 'message', v_sent->>'message',
                            'phone', v_phone, 'booking', o.booking);
end;
$$;
revoke execute on function public.mygig_create(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_create(jsonb, double precision, double precision) to authenticated;

-- 0329's offer, with its booking.
create or replace function public.mygig_offer_json(o public.mygig_offers)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', o.id, 'kind', o.kind, 'status', case when o.status = 'waiting' and o.expires_at <= now() then 'expired' else o.status end,
    'way', o.way, 'phone', o.phone, 'name', o.passenger_name, 'lookup', o.lookup, 'registered', o.passenger_id is not null,
    'trip', o.trip, 'quote', o.quote, 'total', o.total, 'expiresAt', o.expires_at, 'answeredAt', o.answered_at,
    'answeredVia', o.answered_via, 'rideId', o.ride_id, 'sends', o.sends, 'createdAt', o.created_at,
    'driver', public.mygig_driver_card(o.driver_id),
    'booking', o.booking, 'bookingId', o.booking_id,
    'bookingStatus', (select x.status from public.mygig_bookings x where x.id = o.booking_id));
$$;
revoke execute on function public.mygig_offer_json(public.mygig_offers) from public, anon, authenticated;

-- The ride row: 0329's mygig_make_ride, for an offer accepted now and for a
-- booking's day ([p] holds the driver, the passenger, the trip, the money
-- quote, and for a day its booking, hire terms and share of the money).
create or replace function public.mygig_ride_insert(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := gen_random_uuid();
  v_driver uuid := (p->>'driver')::uuid;
  v_pid uuid := nullif(p->>'passenger', '')::uuid;
  t jsonb := p->'trip';
  q jsonb := p->'quote';
  v_pay text := t->>'pay';
  d public.profiles;
  pt public.partners;
  car jsonb := public.dispatch_driver_car(v_driver);
  pl jsonb := coalesce(q->'place', '{}'::jsonb);
  v_share uuid := gen_random_uuid();
  v_fare numeric;
  v_money jsonb;
  v_here boolean := public.mygig_bool(t #> '{pickup,here}', false) and p->>'bookingId' is null;
  v_wait_on boolean := public.mygig_bool(q #> '{wait,on}', true);
  s jsonb := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  v_hire jsonb := p->'hire';
begin
  -- Gone over the daily limit while it waited, or a ride started meanwhile.
  if public.mygig_active_ride(v_driver) is not null then
    raise exception 'MYGIG_DRIVER_BUSY' using errcode = '22023', hint = 'The driver has another ride on the go.';
  end if;
  if not coalesce((p->>'skipLimit')::boolean, false) and public.mygig_num(s->'dailyLimit', 0) > 0
     and public.mygig_today_count(v_driver, s->>'timezone') >= public.mygig_num(s->'dailyLimit', 0) then
    raise exception 'MYGIG_LIMIT' using errcode = '42501', hint = 'The driver reached today''s myGiG limit.';
  end if;
  select * into d from public.profiles where id = v_driver;
  select * into pt from public.partners where auth_user_id = v_driver order by created_at limit 1;
  v_money := public.mygig_ride_money(q, (q->>'total')::numeric, (q->>'tax')::numeric);
  v_fare := (v_money->>'fare')::numeric;
  insert into public.ride_requests (
    id, rider_id, rider_name, rider_phone, service, payment_mode, business_account_id,
    pickup_name, pickup_address, pickup_lat, pickup_lng, drop_name, drop_address, drop_lat, drop_lng,
    distance_km, duration_min, fare, ride_fare, passengers, luggage, stops, round_trip,
    country, state, city, suburb, whole_fare, tax_name, tax_kind, tax_value, timezone,
    status, partner_id, partner_name, partner_phone, partner_photo, partner_vehicle, partner_plate, partner_rating,
    accepted_at, arrived_at, waiting_from, waiting_terms, start_method, mygig, family, booked_for_other, charges, airport_fare,
    hire_package)
  values (
    v_id, v_pid, coalesce(p->>'name', 'myGiG passenger'), p->>'phone', t->>'service',
    case v_pay when 'wallet' then 'Get Pay' when 'family' then 'Family' when 'link' then 'Pay by link'
               when 'business' then 'Business' else 'Cash' end,
    case when v_pay = 'business' then (t->>'businessId')::uuid end,
    t #>> '{pickup,name}', t #>> '{pickup,address}', (t #>> '{pickup,lat}')::float8, (t #>> '{pickup,lng}')::float8,
    t #>> '{drop,name}', t #>> '{drop,address}', (t #>> '{drop,lat}')::float8, (t #>> '{drop,lng}')::float8,
    (q->>'km')::numeric, (q->>'min')::numeric::int, v_fare, v_fare,
    coalesce((t->>'pax')::int, 1),
    coalesce((t #>> '{bags,small}')::int, 0) + coalesce((t #>> '{bags,medium}')::int, 0) + coalesce((t #>> '{bags,large}')::int, 0),
    coalesce((select jsonb_agg(jsonb_build_object('name', x->>'name', 'address', x->>'address',
                                                  'lat', (x->>'lat')::float8, 'lng', (x->>'lng')::float8))
                from jsonb_array_elements(t->'stops') x), '[]'::jsonb),
    coalesce((t->>'round')::boolean, false),
    nullif(pl->>'country', ''), nullif(pl->>'state', ''), nullif(pl->>'city', ''), nullif(pl->>'suburb', ''),
    coalesce((q->>'roundUp')::boolean, false),
    case when coalesce((q->>'tax')::numeric, 0) > 0 then coalesce(q->>'taxName', 'Tax') end,
    case when coalesce((q->>'tax')::numeric, 0) > 0 then 'fixed' end,
    case when coalesce((q->>'tax')::numeric, 0) > 0 then (q->>'tax')::numeric end,
    coalesce(nullif(s->>'timezone', ''), 'Asia/Kuala_Lumpur'),
    -- Picked up where the driver is: already there, the waiting clock running.
    case when v_here then 'arrived' else 'accepted' end,
    v_driver, coalesce(pt.name, d.name), coalesce(pt.phone, d.phone), coalesce(pt.avatar_url, d.avatar_url),
    car->>'vehicle', car->>'plate', coalesce(pt.rating, 5),
    now(), case when v_here then now() end,
    case when v_here and v_wait_on then now() end,
    case when v_here and v_wait_on then jsonb_build_object(
      'freeMinutes', public.mygig_num(q #> '{wait,freeMin}', 0), 'perMinute', public.mygig_num(q #> '{wait,perMin}', 0),
      'cap', public.mygig_num(q #> '{wait,cap}', 60)) end,
    null,
    jsonb_build_object(
      'offerId', p->>'offerId', 'way', p->>'way', 'via', p->>'via', 'registered', v_pid is not null,
      'lookup', p->>'lookup', 'phone', p->>'phone', 'shownName', p->>'name', 'pay', v_pay,
      'quote', q, 'terms', q->'terms', 'tripFee', q->'tripFee', 'tokenHash', p->>'tokenHash',
      'stopWaitMin', 0, 'acceptedAt', now(), 'flagged', coalesce((q->>'flagged')::boolean, false))
    || case when v_hire is not null then jsonb_build_object('hire', v_hire) else '{}'::jsonb end
    || case when p->>'bookingId' is not null then jsonb_build_object(
         'bookingId', p->>'bookingId', 'dayNo', (p->>'dayNo')::int, 'days', (p->>'days')::int,
         'prepaid', coalesce((p->>'prepaid')::numeric, 0), 'cashPaid', coalesce((p->>'cashPaid')::numeric, 0),
         'alloc', coalesce(p->'alloc', '{}'::jsonb), 'payTest', coalesce((p->>'payTest')::boolean, false))
       else '{}'::jsonb end,
    null, false, nullif(v_money->'charges', 'null'::jsonb), v_money->'airportFare',
    v_hire->>'package');
  -- The trip link follows the ride (the shared ride page, 0108 / 0220).
  insert into public.ride_request_private as x (request_id, share_token)
  values (v_id, v_share)
  on conflict (request_id) do update set share_token = coalesce(x.share_token, excluded.share_token), updated_at = now();
  return v_id;
end;
$$;
revoke execute on function public.mygig_ride_insert(jsonb) from public, anon, authenticated;

-- The ride row an accepted offer becomes (0329), an hourly hire now with
-- its hire terms.
create or replace function public.mygig_make_ride(o public.mygig_offers, p_via text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  q jsonb := o.quote;
  v_hire jsonb;
begin
  if o.booking->>'kind' = 'hourly' then
    q := public.mygig_day_quote(o.quote, 1);
    v_hire := q->'hire';
    q := (q - 'hire') || jsonb_build_object('terms', o.quote->'terms');
  end if;
  v_id := public.mygig_ride_insert(jsonb_build_object(
    'driver', o.driver_id, 'passenger', o.passenger_id, 'name', o.passenger_name, 'phone', o.phone,
    'way', o.way, 'via', p_via, 'lookup', o.lookup, 'offerId', o.id, 'tokenHash', o.token_hash,
    'trip', o.trip, 'quote', q, 'hire', v_hire));
  update public.mygig_offers set ride_id = v_id where id = o.id;
  return v_id;
end;
$$;
revoke execute on function public.mygig_make_ride(public.mygig_offers, text) from public, anon, authenticated;

-- Accepting, whichever way (0329): a ride now, or a booking (0330).
create or replace function public.mygig_accept_offer(o public.mygig_offers, p_via text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride uuid;
  v_book jsonb;
  bk public.mygig_bookings;
begin
  if o.status <> 'waiting' or o.expires_at <= now() then
    if o.status = 'waiting' then
      update public.mygig_offers set status = 'expired', answered_at = now() where id = o.id;
    end if;
    raise exception 'MYGIG_ENDED' using errcode = '22023',
      hint = case when o.status = 'accepted' then 'This ride was already accepted.'
                  else 'This request has ended. Ask the driver to send it again.' end;
  end if;
  if o.kind = 'change' then
    perform public.mygig_apply_change(o);
    v_ride := o.ride_id;
  elsif o.booking is not null and o.booking->>'when' = 'later' then
    v_book := public.mygig_book(o, p_via);
    select * into bk from public.mygig_bookings where id = (v_book->>'bookingId')::uuid;
  else
    v_ride := public.mygig_make_ride(o, p_via);
  end if;
  update public.mygig_offers set status = 'accepted', answered_at = now(), answered_via = p_via,
                                 booking_id = coalesce(bk.id, booking_id)
   where id = o.id;
  perform public.enqueue_notification(o.driver_id, 'mygig-answer-' || o.id, 'ride_status', 'critical',
    case when o.kind = 'change' then 'New price accepted'
         when bk.id is not null and bk.status = 'awaiting_payment' then 'Booking accepted: waiting for payment'
         when bk.id is not null then 'Booking accepted'
         else 'Fare accepted' end,
    case when o.kind = 'change' then 'The passenger accepted the new price. Carry on.'
         when bk.id is not null and bk.status = 'awaiting_payment'
           then format('The passenger accepted. The booking is confirmed once they pay %s by link.',
                       public.mygig_money(bk.pay_now))
         when bk.id is not null
           then format('The passenger accepted %s for %s. It is in your Scheduled myGiG.',
                       public.mygig_money(o.total), public.mygig_when_text(bk.first_at, bk.timezone))
         else format('The passenger accepted %s. Your trip is on.', public.mygig_money(o.total)) end,
    jsonb_build_object('type', 'mygig_answer', 'offer_id', o.id, 'request_id', v_ride, 'booking_id', bk.id,
                       'role', 'partner'), v_ride);
  return jsonb_build_object('offerId', o.id, 'rideId', v_ride, 'status', 'accepted', 'kind', o.kind,
                            'bookingId', bk.id, 'bookingStatus', bk.status, 'payNow', bk.pay_now,
                            'payNowBy', bk.pay_now_by);
end;
$$;
revoke execute on function public.mygig_accept_offer(public.mygig_offers, text) from public, anon, authenticated;

-- ---- 6. Bookings -------------------------------------------------------------------------------------
-- Family: a booking the family pays is the 'mygig' module's trip (0317):
-- its charges (deposit, balance, in full) are redirected to the host
-- within the member's limits, and refunds go back there.
create or replace function public.mygig_bookings_family()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.pay <> 'family' or new.rider_id is null then
    return null;
  end if;
  perform public.family_attach_trip('mygig', new.id, new.rider_id, null, new.price,
                                    coalesce(new.quote->'place', '{}'::jsonb), null, true);
  return null;
end;
$$;
revoke execute on function public.mygig_bookings_family() from public, anon, authenticated;
drop trigger if exists trg_mygig_bookings_family on public.mygig_bookings;
create trigger trg_mygig_bookings_family
  after insert on public.mygig_bookings
  for each row execute function public.mygig_bookings_family();

-- Takes [p_amount] from the passenger's GET.wallet (the host's where the
-- family pays) for [p_trip] (a booking or a ride): get.ride holds it until
-- the day is driven. False when the wallet is short.
create or replace function public.mygig_app_charge(p_rider uuid, p_trip uuid, p_amount numeric, p_kind text, p_note text)
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
  if p_rider is null then
    return false;
  end if;
  v_owner := public.family_wallet_owner(p_trip, p_rider, p_amount);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets where user_id = v_owner and wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < p_amount then
    return false;
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (p_rider, 'get_wallet', p_kind, -round(p_amount, 2), 'mygig',
          left(p_note || ' — ' || public.mygig_money(p_amount), 300), p_trip);
  return true;
end;
$$;
revoke execute on function public.mygig_app_charge(uuid, uuid, numeric, text, text) from public, anon, authenticated;

-- What a booking still needs before a day starts: the price less what was
-- paid (nothing for a business account).
create or replace function public.mygig_booking_due(b public.mygig_bookings)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case when b.plan = 'business' or b.status in ('cancelled', 'expired', 'completed') then 0
              else greatest(0, round(b.price - b.app_paid - b.link_paid - b.cash_paid, 2)) end;
$$;

-- What the passenger can pay by link now: what confirms the booking, then
-- the balance before day 1 (not for an in-app payer, who is charged).
create or replace function public.mygig_booking_link_owed(b public.mygig_bookings)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case when b.status = 'awaiting_payment' then greatest(0, round(b.pay_now - b.app_paid - b.link_paid - b.cash_paid, 2))
              when b.status in ('booked', 'in_progress') then public.mygig_booking_due(b)
              else 0 end;
$$;

-- The hire_bookings row of a multi-day hire follows its booking.
create or replace function public.mygig_booking_mirror(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  v_paid numeric;
begin
  select * into b from public.mygig_bookings where id = p_booking;
  if not found or b.kind not in ('daily', 'weekly', 'monthly') then
    return;
  end if;
  v_paid := round(b.app_paid + b.link_paid + b.cash_paid, 2);
  if b.hire_booking_id is null then
    insert into public.hire_bookings (
      rider_id, package, service, status, pickup_name, pickup_address, pickup_lat, pickup_lng,
      drop_name, drop_address, drop_lat, drop_lng, first_at, days, timezone, hours_per_day, km_per_day, overnight,
      same_driver, partner_id, partner_accepted_at, payment_mode, payment_plan, price, deposit_amount, balance_amount,
      paid_amount, payment_state, quote, currency, booked_for_name, booked_for_phone, business_account_id,
      weekdays, periods, km_mode, mygig_booking_id)
    values (
      b.rider_id, b.kind, coalesce(nullif(b.trip->>'service', ''), 'myGiG'), 'assigned',
      b.trip #>> '{pickup,name}', b.trip #>> '{pickup,address}', (b.trip #>> '{pickup,lat}')::float8,
      (b.trip #>> '{pickup,lng}')::float8,
      case when not coalesce((b.trip->>'directed')::boolean, false) then b.trip #>> '{drop,name}' end,
      case when not coalesce((b.trip->>'directed')::boolean, false) then b.trip #>> '{drop,address}' end,
      case when not coalesce((b.trip->>'directed')::boolean, false) then (b.trip #>> '{drop,lat}')::float8 end,
      case when not coalesce((b.trip->>'directed')::boolean, false) then (b.trip #>> '{drop,lng}')::float8 end,
      b.first_at, b.days, b.timezone, coalesce((b.quote->>'hoursPerDay')::numeric, 10),
      (b.quote->>'kmPerDay')::numeric, coalesce((b.quote->>'overnight')::boolean, false),
      true, b.driver_id, b.created_at, 'myGiG ' || b.pay,
      case b.plan when 'deposit' then 'deposit' when 'business' then 'business' else 'prepay' end,
      b.price, b.pay_now, greatest(0, b.price - b.pay_now), v_paid, 'none',
      jsonb_build_object('title', 'myGiG ' || lower(public.mygig_kind_label(b.kind)), 'mygig', true,
                         'country', b.quote #>> '{place,country}', 'state', b.quote #>> '{place,state}',
                         'city', b.quote #>> '{place,city}', 'suburb', b.quote #>> '{place,suburb}'),
      'MYR', b.passenger_name, b.phone, b.business_account_id,
      case when b.kind in ('weekly', 'monthly')
           then array(select (x #>> '{}')::smallint from jsonb_array_elements(coalesce(b.quote->'weekdays', '[]'::jsonb)) x) end,
      (b.quote->>'periods')::int, 'day', b.id)
    returning id into b.hire_booking_id;
    update public.mygig_bookings set hire_booking_id = b.hire_booking_id where id = b.id;
  end if;
  update public.hire_bookings
     set status = case b.status when 'awaiting_payment' then 'booked' when 'booked' then 'assigned' else b.status end,
         paid_amount = v_paid, allocated_amount = b.allocated_amount, refunded_amount = b.refunded_amount,
         kept_amount = b.kept_amount,
         payment_state = case when b.plan = 'business' then 'business'
                              when v_paid >= b.price and b.price > 0 then 'paid'
                              when v_paid > 0 then 'deposit_paid' else 'none' end,
         cancelled_at = b.cancelled_at,
         cancelled_by = case when b.cancelled_by is null then null when b.cancelled_by = 'passenger' then 'rider'
                             when b.cancelled_by = 'admin' then 'admin' else 'system' end,
         cancel_reason = b.cancel_reason, cancel_fee = b.kept_amount
   where id = b.hire_booking_id;
end;
$$;
revoke execute on function public.mygig_booking_mirror(uuid) from public, anon, authenticated;

-- A text to a passenger without the app (the gateway's trip_share channel).
create or replace function public.mygig_sms(p_phone text, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_phone is null then
    return;
  end if;
  insert into public.sms_outbox (channel, to_phone, body, created_by) values ('trip_share', p_phone, left(p_body, 300), null);
exception when others then
  raise warning 'myGiG SMS not queued: %', sqlerrm;
end;
$$;
revoke execute on function public.mygig_sms(text, text) from public, anon, authenticated;

-- Tells the passenger: in the app when registered, else by SMS.
create or replace function public.mygig_tell_passenger(b public.mygig_bookings, p_event text, p_title text, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if b.rider_id is not null then
    perform public.enqueue_notification(b.rider_id, 'mygig-bk-' || p_event || '-' || b.id, 'scheduled_ride', 'normal',
      p_title, p_body, jsonb_build_object('type', 'mygig_booking', 'booking_id', b.id, 'role', 'rider'));
  else
    perform public.mygig_sms(b.phone, 'get.ride: ' || p_body);
  end if;
end;
$$;
revoke execute on function public.mygig_tell_passenger(public.mygig_bookings, text, text, text) from public, anon, authenticated;

-- An accepted offer for later becomes a booking: its days, the hire row of
-- a multi-day hire, and what is paid now (in the app at once; by link
-- before it is confirmed).
create or replace function public.mygig_book(o public.mygig_offers, p_via text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bk jsonb := o.booking;
  q jsonb := o.quote;
  b public.mygig_bookings;
  v_days jsonb;
  d jsonb;
  v_payn numeric := coalesce((bk->>'payNow')::numeric, 0);
  v_wait numeric := public.mygig_num(bk->'payWaitMin', 30);
  i int := 0;
begin
  if public.mygig_booking_clash(o.driver_id, (q->>'firstAt')::timestamptz,
                                coalesce((q->>'lastAt')::timestamptz, (bk->>'at')::timestamptz + interval '2 hours')) then
    raise exception 'MYGIG_CLASH' using errcode = '22023', hint = 'The driver has another booking at that time now.';
  end if;
  v_days := case when bk->>'kind' = 'trip' then public.mygig_trip_days(q, bk) else q->'dateList' end;
  insert into public.mygig_bookings (
    offer_id, driver_id, rider_id, passenger_name, phone, kind, status, first_at, last_at, timezone, days,
    trip, quote, pay, plan, business_account_id, price, pay_now, pay_now_by, pay_until, free_cancel_until)
  values (
    o.id, o.driver_id, o.passenger_id, o.passenger_name, o.phone, bk->>'kind',
    case when v_payn > 0 and bk->>'payNowBy' = 'link' then 'awaiting_payment' else 'booked' end,
    (v_days->0->>'at')::timestamptz, (v_days->(jsonb_array_length(v_days) - 1)->>'endsAt')::timestamptz,
    coalesce(q #>> '{place,timezone}', 'Asia/Kuala_Lumpur'), jsonb_array_length(v_days),
    o.trip, q || jsonb_build_object('booking', bk), coalesce(bk->>'pay', o.trip->>'pay'), bk->>'plan',
    case when o.trip->>'pay' = 'business' then (o.trip->>'businessId')::uuid end,
    o.total, v_payn, coalesce(bk->>'payNowBy', 'none'),
    case when v_payn > 0 and bk->>'payNowBy' = 'link' then now() + make_interval(mins => v_wait::int) end,
    coalesce((bk->>'freeCancelUntil')::timestamptz, (v_days->0->>'at')::timestamptz))
  returning * into b;
  for d in select value from jsonb_array_elements(v_days) loop
    i := i + 1;
    insert into public.mygig_booking_days (booking_id, day_no, starts_at, quote)
    values (b.id, i, (d->>'at')::timestamptz,
            case when bk->>'kind' = 'trip' then (q - 'dateList') || jsonb_build_object('endsAt', d->'endsAt', 'at', d->'at')
                 else public.mygig_day_quote(q, i) end);
  end loop;
  -- Paid now in the app: the deposit, or the whole price.
  if v_payn > 0 and bk->>'payNowBy' = 'app' then
    if not public.mygig_app_charge(b.rider_id, b.id, v_payn, 'mygig_booking',
                                   'myGiG ' || lower(public.mygig_kind_label(b.kind))
                                   || case when b.plan = 'deposit' then ' deposit' else ' paid' end) then
      raise exception 'MYGIG_BALANCE' using errcode = 'P0001',
        hint = format('Top up your GET.wallet: %s is paid now for this booking.', public.mygig_money(v_payn));
    end if;
    update public.mygig_bookings set app_paid = v_payn, app_left = v_payn where id = b.id returning * into b;
  end if;
  perform public.mygig_booking_mirror(b.id);
  if b.status = 'booked' then
    perform public.mygig_tell_passenger(b, 'booked', 'myGiG booked',
      format('%s with %s from %s, %s.', public.mygig_kind_label(b.kind),
             coalesce((public.mygig_driver_card(b.driver_id))->>'name', 'your driver'),
             public.mygig_when_text(b.first_at, b.timezone), public.mygig_money(b.price)));
  end if;
  return jsonb_build_object('bookingId', b.id, 'status', b.status, 'payNow', b.pay_now, 'payNowBy', b.pay_now_by);
end;
$$;
revoke execute on function public.mygig_book(public.mygig_offers, text) from public, anon, authenticated;

-- Money in: [p_amount] paid by [p_how] ('app', 'link', 'cash'); confirms
-- a booking waiting for its payment.
create or replace function public.mygig_booking_paid(p_booking uuid, p_amount numeric, p_how text, p_test boolean default false)
returns public.mygig_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
begin
  update public.mygig_bookings
     set app_paid = app_paid + case when p_how = 'app' then p_amount else 0 end,
         app_left = app_left + case when p_how = 'app' then p_amount else 0 end,
         link_paid = link_paid + case when p_how = 'link' then p_amount else 0 end,
         link_left = link_left + case when p_how = 'link' then p_amount else 0 end,
         cash_paid = cash_paid + case when p_how = 'cash' then p_amount else 0 end,
         cash_left = cash_left + case when p_how = 'cash' then p_amount else 0 end,
         pay_test = pay_test or coalesce(p_test, false)
   where id = p_booking
  returning * into b;
  if b.status = 'awaiting_payment' and b.app_paid + b.link_paid + b.cash_paid >= b.pay_now - 0.005 then
    update public.mygig_bookings set status = 'booked', pay_url = null, pay_until = null where id = b.id returning * into b;
    perform public.enqueue_notification(b.driver_id, 'mygig-bk-confirmed-' || b.id, 'scheduled_ride', 'critical',
      'Booking confirmed', format('The passenger paid. %s on %s is in your Scheduled myGiG.',
                                  public.mygig_kind_label(b.kind), public.mygig_when_text(b.first_at, b.timezone)),
      jsonb_build_object('type', 'mygig_booking', 'booking_id', b.id, 'role', 'partner'));
    perform public.mygig_tell_passenger(b, 'confirmed', 'myGiG booked',
      format('Paid, thank you. %s from %s is booked.', public.mygig_kind_label(b.kind),
             public.mygig_when_text(b.first_at, b.timezone)));
  end if;
  perform public.mygig_booking_mirror(b.id);
  return b;
end;
$$;
revoke execute on function public.mygig_booking_paid(uuid, numeric, text, boolean) from public, anon, authenticated;

-- Pays the driver [p_amount] of get.ride's held money for [p_trip].
create or replace function public.mygig_payout(p_driver uuid, p_trip uuid, p_amount numeric, p_kind text, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_amount, 0) <= 0 then
    return;
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (p_driver, 'get_wallet', p_kind, round(p_amount, 2), 'mygig',
          left(p_note || ' — ' || public.mygig_money(p_amount), 300), p_trip);
end;
$$;
revoke execute on function public.mygig_payout(uuid, uuid, numeric, text, text) from public, anon, authenticated;

-- Gives back what is left of a booking's money and keeps [p_keep] of it
-- for the driver. Kept: from the link, then the app, then the cash (the
-- driver already has cash); paid to the driver at once. Refunded: the app's
-- to the GET.wallet it came from (the host's, for Family), the link's as
-- refundDue on the gateway, cash off the driver's GET.credit (they have it)
-- and refundDue. {kept, refunded, refundDue}.
create or replace function public.mygig_booking_settle(p_booking uuid, p_keep numeric, p_why text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  v_keep numeric;
  k_link numeric;
  k_app numeric;
  k_cash numeric;
  v_due numeric := 0;
begin
  select * into b from public.mygig_bookings where id = p_booking for update;
  v_keep := least(greatest(0, coalesce(p_keep, 0)), b.link_left + b.app_left + b.cash_left);
  k_link := least(v_keep, b.link_left);
  k_app := least(v_keep - k_link, b.app_left);
  k_cash := least(v_keep - k_link - k_app, b.cash_left);
  if not b.pay_test then
    perform public.mygig_payout(b.driver_id, b.id, k_link + k_app, 'mygig_cancel_kept', 'myGiG booking cancelled late, kept');
  end if;
  if b.app_left - k_app > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.rider_id, 'get_wallet', 'mygig_refund', b.app_left - k_app, 'mygig',
            left('myGiG booking refund (' || p_why || ') — ' || public.mygig_money(b.app_left - k_app), 300), b.id);
  end if;
  v_due := round(b.link_left - k_link, 2);
  if b.cash_left - k_cash > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.driver_id, 'get_credit', 'mygig_refund', -(b.cash_left - k_cash), 'mygig',
            'myGiG booking: cash back to the passenger — ' || public.mygig_money(b.cash_left - k_cash), b.id);
    v_due := v_due + round(b.cash_left - k_cash, 2);
  end if;
  update public.mygig_bookings
     set kept_amount = kept_amount + v_keep,
         refunded_amount = refunded_amount + (link_left - k_link) + (app_left - k_app) + (cash_left - k_cash),
         refund_due = refund_due + v_due,
         link_left = 0, app_left = 0, cash_left = 0
   where id = b.id;
  return jsonb_build_object('kept', v_keep, 'refunded', round(b.link_left + b.app_left + b.cash_left - v_keep, 2),
                            'refundDue', v_due);
end;
$$;
revoke execute on function public.mygig_booking_settle(uuid, numeric, text) from public, anon, authenticated;

-- A booking's state from its days: in progress once a day was released,
-- completed when none is left (what is left of its money goes back).
create or replace function public.mygig_booking_refresh(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
begin
  select * into b from public.mygig_bookings where id = p_booking for update;
  if not found or b.status not in ('booked', 'in_progress') then
    return;
  end if;
  if not exists (select 1 from public.mygig_booking_days where booking_id = b.id and status in ('scheduled', 'released')) then
    perform public.mygig_booking_settle(b.id, 0, 'days not driven');
    update public.mygig_bookings set status = 'completed' where id = b.id;
  elsif b.status = 'booked' and exists (select 1 from public.mygig_booking_days
                                         where booking_id = b.id and status in ('released', 'completed')) then
    update public.mygig_bookings set status = 'in_progress' where id = b.id;
  end if;
  perform public.mygig_booking_mirror(b.id);
end;
$$;
revoke execute on function public.mygig_booking_refresh(uuid) from public, anon, authenticated;

-- A day's ride ended: the day follows it, then the booking.
create or replace function public.ride_requests_mygig_booking_after()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.mygig_booking_days
     set status = case new.status when 'completed' then 'completed' else 'cancelled' end
   where ride_id = new.id and status = 'released';
  perform public.mygig_booking_refresh((new.mygig->>'bookingId')::uuid);
  return null;
end;
$$;
revoke execute on function public.ride_requests_mygig_booking_after() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_mygig_zbooking_after on public.ride_requests;
create trigger trg_ride_requests_mygig_zbooking_after
  after update of status on public.ride_requests
  for each row
  when (new.status in ('completed', 'cancelled', 'expired') and old.status is distinct from new.status
        and new.mygig ? 'bookingId')
  execute function public.ride_requests_mygig_booking_after();

-- The booking as the apps show it. [p_for]: 'driver' (the passenger as the
-- admin lets drivers see them, the phone), 'passenger', 'link'.
create or replace function public.mygig_booking_json(b public.mygig_bookings, p_for text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s jsonb := public.mygig_settings_at(b.quote #>> '{place,country}', b.quote #>> '{place,state}',
                                      b.quote #>> '{place,city}', b.quote #>> '{place,suburb}');
  v_next record;
  v_live record;
  v_done int;
  v_early numeric := public.mygig_num(s #> '{later,startEarlyMin}', 60);
  v_paid numeric := round(b.app_paid + b.link_paid + b.cash_paid, 2);
begin
  select d.day_no, d.starts_at, d.quote into v_next from public.mygig_booking_days d
   where d.booking_id = b.id and d.status = 'scheduled' order by d.day_no limit 1;
  select d.day_no, d.ride_id, r.status into v_live from public.mygig_booking_days d
    join public.ride_requests r on r.id = d.ride_id
   where d.booking_id = b.id and d.status = 'released' and r.status in ('accepted', 'arrived', 'on_trip')
   order by d.day_no desc limit 1;
  select count(*) into v_done from public.mygig_booking_days where booking_id = b.id and status = 'completed';
  return jsonb_build_object(
    'id', b.id, 'kind', b.kind, 'title', public.mygig_kind_label(b.kind), 'status', b.status,
    'firstAt', b.first_at, 'lastAt', b.last_at, 'timezone', b.timezone, 'days', b.days, 'daysDone', v_done,
    'whenText', public.mygig_when_text(b.first_at, b.timezone),
    'price', b.price, 'pay', b.pay, 'plan', b.plan, 'payNow', b.pay_now, 'payNowBy', b.pay_now_by,
    'paid', v_paid, 'due', public.mygig_booking_due(b), 'linkOwed', public.mygig_booking_link_owed(b),
    'payUrl', case when public.mygig_booking_link_owed(b) > 0 then b.pay_url end,
    'payUntil', b.pay_until, 'freeCancelUntil', b.free_cancel_until,
    'depositPct', b.quote #> '{booking,depositPct}',
    'canCancel', b.status in ('awaiting_payment', 'booked', 'in_progress') and v_live.status is distinct from 'on_trip',
    'cancelFree', now() < b.free_cancel_until or v_done > 0
                  or exists (select 1 from public.mygig_booking_days where booking_id = b.id and status in ('released', 'completed')),
    'keepIfCancelled', case when now() < b.free_cancel_until then 0
                            else least(b.pay_now, b.app_left + b.link_left + b.cash_left) end,
    'trip', jsonb_build_object('pickup', (b.trip->'pickup') - 'here', 'drop', b.trip->'drop', 'stops', b.trip->'stops',
                               'directed', coalesce((b.trip->>'directed')::boolean, false), 'pax', b.trip->'pax',
                               'bags', b.trip->'bags'),
    'hours', b.quote->'hours', 'hoursPerDay', b.quote->'hoursPerDay', 'periods', b.quote->'periods',
    'weekdays', b.quote->'weekdays', 'overnight', b.quote->'overnight', 'kmIncluded', b.quote->'kmIncluded',
    'kmPerDay', b.quote->'kmPerDay', 'overtimePerHour', b.quote->'overtimePerHour', 'extraKm', b.quote->'extraKm',
    'quote', jsonb_build_object('total', b.quote->'total', 'tax', b.quote->'tax', 'taxName', b.quote->'taxName',
                                'showTax', b.quote->'showTax', 'base', b.quote->'base', 'placeFees', b.quote->'placeFees',
                                'luggage', b.quote->'luggage', 'approach', b.quote->'approach',
                                'overnightTotal', b.quote->'overnightTotal', 'rounded', b.quote->'rounded',
                                'fare', b.quote->'fare', 'km', b.quote->'km', 'min', b.quote->'min'),
    'nextDay', case when v_next.day_no is not null then jsonb_build_object(
                 'day', v_next.day_no, 'at', v_next.starts_at, 'whenText', public.mygig_when_text(v_next.starts_at, b.timezone),
                 'canStart', b.status in ('booked', 'in_progress') and v_live.ride_id is null
                             and now() >= v_next.starts_at - make_interval(mins => v_early::int),
                 'startFrom', v_next.starts_at - make_interval(mins => v_early::int)) end,
    'dayText', case when b.days > 1 then format('Day %s of %s', coalesce(v_live.day_no, v_next.day_no, b.days), b.days) end,
    'rideId', v_live.ride_id, 'rideStatus', v_live.status,
    'refundDue', b.refund_due, 'kept', b.kept_amount,
    'cancelledBy', b.cancelled_by, 'cancelReason', b.cancel_reason)
    || case when p_for = 'driver' then jsonb_build_object(
         'name', coalesce(b.passenger_name, 'myGiG passenger'), 'phone', b.phone, 'registered', b.rider_id is not null,
         'payTest', b.pay_test)
       when p_for = 'link' then jsonb_build_object('name', split_part(coalesce(b.passenger_name, ''), ' ', 1),
         'driver', public.mygig_driver_card(b.driver_id))
       else jsonb_build_object('driver', public.mygig_driver_card(b.driver_id)) end;
end;
$$;
revoke execute on function public.mygig_booking_json(public.mygig_bookings, text) from public, anon, authenticated;

-- Scheduled myGiG: the driver's bookings still to come or going, soonest first.
create or replace function public.mygig_scheduled()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.mygig_booking_json(b, 'driver') order by b.first_at), '[]'::jsonb)
    from public.mygig_bookings b
   where b.driver_id = auth.uid() and b.status in ('awaiting_payment', 'booked', 'in_progress');
$$;
revoke execute on function public.mygig_scheduled() from public, anon;
grant execute on function public.mygig_scheduled() to authenticated;

-- The passenger's myGiG bookings in their app, until they end (and a day after).
create or replace function public.mygig_my_bookings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.mygig_booking_json(b, 'passenger') order by b.first_at), '[]'::jsonb)
    from public.mygig_bookings b
   where b.rider_id = auth.uid()
     and (b.status in ('awaiting_payment', 'booked', 'in_progress') or b.updated_at > now() - interval '1 day');
$$;
revoke execute on function public.mygig_my_bookings() from public, anon;
grant execute on function public.mygig_my_bookings() to authenticated;

-- Start (from Scheduled myGiG, when due): what the booking still needs is
-- collected first (in the app; otherwise by link or cash the driver
-- confirms: MYGIG_BALANCE_FIRST), then the next day is released as a ride
-- with the driver and given its share of the money (cash first, then the
-- link's, then the app's). A day already going is returned.
create or replace function public.mygig_booking_start(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  d public.mygig_booking_days;
  o public.mygig_offers;
  s jsonb;
  v_live uuid;
  v_due numeric;
  v_share numeric;
  a_cash numeric := 0;
  a_link numeric := 0;
  a_app numeric := 0;
  q jsonb;
  v_hire jsonb;
  v_ride uuid;
  v_early numeric;
  v_trip jsonb;
begin
  select * into b from public.mygig_bookings where id = p_booking for update;
  if not found or auth.uid() is null or b.driver_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  select d2.ride_id into v_live from public.mygig_booking_days d2 join public.ride_requests r on r.id = d2.ride_id
   where d2.booking_id = b.id and d2.status = 'released' and r.status in ('accepted', 'arrived', 'on_trip') limit 1;
  if v_live is not null then
    return jsonb_build_object('rideId', v_live, 'resumed', true);
  end if;
  if b.status = 'awaiting_payment' then
    raise exception 'MYGIG_PAY_FIRST' using errcode = '42501',
      hint = format('The booking is confirmed once the passenger pays %s by link.', public.mygig_money(public.mygig_booking_link_owed(b)));
  end if;
  if b.status not in ('booked', 'in_progress') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This booking has ended.';
  end if;
  select * into d from public.mygig_booking_days where booking_id = b.id and status = 'scheduled'
   order by day_no limit 1 for update;
  if not found then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'No day left to start.';
  end if;
  s := public.mygig_settings_at(b.quote #>> '{place,country}', b.quote #>> '{place,state}',
                                b.quote #>> '{place,city}', b.quote #>> '{place,suburb}');
  v_early := public.mygig_num(s #> '{later,startEarlyMin}', 60);
  if now() < d.starts_at - make_interval(mins => v_early::int) then
    raise exception 'MYGIG_NOT_YET' using errcode = '22023',
      hint = format('You can start from %s.', public.mygig_when_text(d.starts_at - make_interval(mins => v_early::int), b.timezone));
  end if;
  if public.mygig_active_ride(b.driver_id) is not null then
    raise exception 'MYGIG_DRIVER_BUSY' using errcode = '22023', hint = 'Finish the ride you are on first.';
  end if;
  -- What the booking still needs: in the app, or by link or cash first.
  v_due := public.mygig_booking_due(b);
  if v_due > 0 then
    if b.rider_id is not null and b.pay in ('wallet', 'family')
       and public.mygig_app_charge(b.rider_id, b.id, v_due, 'mygig_booking',
                                   'myGiG ' || lower(public.mygig_kind_label(b.kind))
                                   || case when b.plan = 'deposit' then ' balance' else ' paid' end) then
      b := public.mygig_booking_paid(b.id, v_due, 'app');
    else
      raise exception 'MYGIG_BALANCE_FIRST' using errcode = '42501',
        hint = format('Collect %s before you start: by link or in cash.', public.mygig_money(v_due));
    end if;
  end if;
  -- The day's share of the money (none for a business account).
  if b.plan <> 'business' then
    v_share := least(coalesce((d.quote->>'total')::numeric, 0), b.cash_left + b.link_left + b.app_left);
    a_cash := least(v_share, b.cash_left);
    a_link := least(v_share - a_cash, b.link_left);
    a_app := least(v_share - a_cash - a_link, b.app_left);
    update public.mygig_bookings
       set cash_left = cash_left - a_cash, link_left = link_left - a_link, app_left = app_left - a_app,
           allocated_amount = allocated_amount + a_cash + a_link + a_app
     where id = b.id;
  end if;
  select * into o from public.mygig_offers where id = b.offer_id;
  q := d.quote;
  v_hire := q->'hire';
  if v_hire is not null then
    v_hire := v_hire || jsonb_build_object('hireBookingId', b.hire_booking_id);
  end if;
  -- No fee after the fact on a booked day: it is paid for.
  q := (q - 'hire') || jsonb_build_object(
    'terms', coalesce(b.quote->'terms', '{}'::jsonb) || jsonb_build_object('noShowFee', 0, 'cancelFee', 0),
    'tripFee', b.quote->'tripFee', 'place', b.quote->'place');
  v_trip := b.trip || jsonb_build_object('pickup', (b.trip->'pickup') || jsonb_build_object('here', false));
  v_ride := public.mygig_ride_insert(jsonb_build_object(
    'driver', b.driver_id, 'passenger', b.rider_id, 'name', b.passenger_name, 'phone', b.phone,
    'way', o.way, 'via', 'booking', 'lookup', o.lookup, 'offerId', b.offer_id, 'tokenHash', o.token_hash,
    'trip', v_trip, 'quote', q, 'hire', v_hire, 'skipLimit', true,
    'bookingId', b.id, 'dayNo', d.day_no, 'days', b.days,
    'prepaid', a_link + a_app, 'cashPaid', a_cash,
    'alloc', jsonb_build_object('cash', a_cash, 'link', a_link, 'app', a_app),
    'payTest', b.pay_test));
  update public.mygig_booking_days set status = 'released', ride_id = v_ride where booking_id = b.id and day_no = d.day_no;
  perform public.mygig_booking_refresh(b.id);
  perform public.mygig_tell_passenger(b, 'day' || d.day_no, 'Your driver is on the way',
    format('%s is coming for your %s%s.', coalesce(public.mygig_driver_card(b.driver_id)->>'name', 'Your driver'),
           lower(public.mygig_kind_label(b.kind)),
           case when b.days > 1 then format(', day %s of %s', d.day_no, b.days) else '' end));
  return jsonb_build_object('rideId', v_ride, 'day', d.day_no, 'days', b.days);
end;
$$;
revoke execute on function public.mygig_booking_start(uuid) from public, anon;
grant execute on function public.mygig_booking_start(uuid) to authenticated;

-- The driver confirms the passenger paid what the booking still needs in
-- cash (the balance before day 1, or a booking paid by link that wasn't).
create or replace function public.mygig_booking_cash(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  v numeric;
begin
  select * into b from public.mygig_bookings where id = p_booking for update;
  if not found or auth.uid() is null or b.driver_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if b.status not in ('booked', 'in_progress') or b.plan = 'business' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Nothing to collect in cash for this booking now.';
  end if;
  v := public.mygig_booking_due(b);
  if v <= 0 then
    return jsonb_build_object('cash', 0);
  end if;
  update public.payment_intents set status = 'cancelled', failure = 'cash'
   where purpose = 'ride_card' and purpose_ref = b.id::text and status = 'pending';
  perform public.mygig_booking_paid(b.id, v, 'cash');
  return jsonb_build_object('cash', v);
end;
$$;
revoke execute on function public.mygig_booking_cash(uuid) from public, anon;
grant execute on function public.mygig_booking_cash(uuid) to authenticated;

-- Cancelling a booking: by the driver or the admin (everything back), by
-- the passenger in the app or on the trip link ([p_token]): free until the
-- free-cancel time, after that what was paid when they accepted is kept for
-- the driver. Once a day has started, the days left are cancelled free.
create or replace function public.mygig_booking_cancel(p_booking uuid default null, p_token text default null,
                                                       p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  v_uid uuid := auth.uid();
  v_by text;
  v_started boolean;
  v_keep numeric := 0;
  v jsonb;
  d record;
  r public.ride_requests;
begin
  if p_token is not null then
    select x.* into b from public.mygig_bookings x
     where x.id = (select o.booking_id from public.mygig_offers o where o.token_hash = public.mygig_token_hash(p_token))
     for update;
    v_by := 'passenger';
  else
    select * into b from public.mygig_bookings where id = p_booking for update;
    if found then
      v_by := case when v_uid is not null and v_uid = b.driver_id then 'driver'
                   when v_uid is not null and v_uid = b.rider_id then 'passenger'
                   when public.caller_admin_can_write('rpc:mygig_booking_cancel') then 'admin' end;
    end if;
  end if;
  if b.id is null or v_by is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if b.status not in ('awaiting_payment', 'booked', 'in_progress') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This booking has ended.';
  end if;
  if exists (select 1 from public.mygig_booking_days x join public.ride_requests rr on rr.id = x.ride_id
              where x.booking_id = b.id and rr.status = 'on_trip') then
    raise exception 'MYGIG_ON_TRIP' using errcode = '22023', hint = 'Today''s trip is on the go. Cancel once it has ended.';
  end if;
  v_started := exists (select 1 from public.mygig_booking_days where booking_id = b.id and status in ('released', 'completed'));
  -- Closed first, so a day's ride cancelled below doesn't end the booking as driven.
  if v_by = 'passenger' and not v_started and now() >= b.free_cancel_until then
    v_keep := b.pay_now;
  end if;
  update public.mygig_bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_by,
         cancel_reason = left(coalesce(nullif(btrim(p_reason), ''),
                                       case v_by when 'driver' then 'Cancelled by the driver'
                                                 when 'admin' then 'Cancelled by get.ride' else 'Cancelled by the passenger' end), 200),
         pay_url = null
   where id = b.id;
  -- A day released but not started: its share back, its ride cancelled.
  for d in
    select x.day_no, x.ride_id from public.mygig_booking_days x
     where x.booking_id = b.id and x.status = 'released'
  loop
    select * into r from public.ride_requests where id = d.ride_id for update;
    if r.status in ('accepted', 'arrived') then
      update public.mygig_bookings
         set cash_left = cash_left + coalesce((r.mygig #>> '{alloc,cash}')::numeric, 0),
             link_left = link_left + coalesce((r.mygig #>> '{alloc,link}')::numeric, 0),
             app_left = app_left + coalesce((r.mygig #>> '{alloc,app}')::numeric, 0),
             allocated_amount = greatest(0, allocated_amount - coalesce((r.mygig #>> '{alloc,cash}')::numeric, 0)
                                - coalesce((r.mygig #>> '{alloc,link}')::numeric, 0)
                                - coalesce((r.mygig #>> '{alloc,app}')::numeric, 0))
       where id = b.id;
      update public.ride_requests
         set mygig = mygig || jsonb_build_object('alloc', '{}'::jsonb, 'prepaid', 0, 'cashPaid', 0),
             status = 'cancelled', cancelled_at = now(), cancel_reason = 'booking_cancelled',
             cancel_requested_by = case v_by when 'passenger' then 'rider' when 'driver' then 'partner' else 'system' end,
             cancel_fee = 0, cancel_fee_status = 'none'
       where id = r.id;
    end if;
  end loop;
  update public.mygig_booking_days set status = 'cancelled' where booking_id = b.id and status in ('scheduled', 'released');
  v := public.mygig_booking_settle(b.id, v_keep, case v_by when 'driver' then 'driver cancelled'
                                                          when 'admin' then 'cancelled by get.ride' else 'cancelled' end);
  update public.payment_intents set status = 'cancelled', failure = 'cancelled'
   where purpose = 'ride_card' and purpose_ref = b.id::text and status = 'pending';
  select * into b from public.mygig_bookings where id = b.id;
  perform public.mygig_booking_mirror(b.id);
  if v_by <> 'driver' then
    perform public.enqueue_notification(b.driver_id, 'mygig-bk-cancel-' || b.id, 'scheduled_ride', 'critical',
      'Booking cancelled',
      format('The %s on %s was cancelled.%s', lower(public.mygig_kind_label(b.kind)),
             public.mygig_when_text(b.first_at, b.timezone),
             case when (v->>'kept')::numeric > 0 then format(' %s goes to your GET.wallet.', public.mygig_money((v->>'kept')::numeric))
                  else '' end),
      jsonb_build_object('type', 'mygig_booking', 'booking_id', b.id, 'role', 'partner'));
  end if;
  if v_by <> 'passenger' then
    perform public.mygig_tell_passenger(b, 'cancel', 'Booking cancelled',
      format('Your myGiG booking on %s was cancelled.%s', public.mygig_when_text(b.first_at, b.timezone),
             case when (v->>'refunded')::numeric > 0 then format(' %s is refunded.', public.mygig_money((v->>'refunded')::numeric))
                  else '' end));
  end if;
  return jsonb_build_object('status', 'cancelled', 'by', v_by) || v;
end;
$$;
revoke execute on function public.mygig_booking_cancel(uuid, text, text) from public;
grant execute on function public.mygig_booking_cancel(uuid, text, text) to anon, authenticated;

-- The minute's work for bookings (from hire_tick): a booking not paid in
-- time ends (any link payment back); reminders to both before each day; a
-- day nobody started by its end is let go (its money goes back when the
-- booking ends).
create or replace function public.mygig_bookings_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  d record;
  s jsonb;
  n integer := 0;
begin
  for b in
    select * from public.mygig_bookings where status = 'awaiting_payment' and pay_until is not null and pay_until <= now()
  loop
    perform public.mygig_booking_settle(b.id, 0, 'not paid in time');
    update public.mygig_booking_days set status = 'expired' where booking_id = b.id and status = 'scheduled';
    update public.mygig_bookings set status = 'expired', cancelled_by = 'system', cancel_reason = 'Not paid in time',
                                     cancelled_at = now(), pay_url = null
     where id = b.id returning * into b;
    update public.payment_intents set status = 'cancelled', failure = 'expired'
     where purpose = 'ride_card' and purpose_ref = b.id::text and status = 'pending';
    perform public.mygig_booking_mirror(b.id);
    perform public.enqueue_notification(b.driver_id, 'mygig-bk-expired-' || b.id, 'scheduled_ride', 'normal',
      'Booking not paid', 'The passenger didn''t pay in time, so the booking ended. Nothing was saved.',
      jsonb_build_object('type', 'mygig_booking', 'booking_id', b.id, 'role', 'partner'));
    perform public.mygig_tell_passenger(b, 'expired', 'Booking ended',
      'Your myGiG booking ended: it wasn''t paid in time.');
    n := n + 1;
  end loop;
  for d in
    select x.booking_id, x.day_no, x.starts_at, bb.timezone, bb.driver_id, bb.kind, bb.days, bb.quote
      from public.mygig_booking_days x join public.mygig_bookings bb on bb.id = x.booking_id
     where x.status = 'scheduled' and x.reminded_at is null and bb.status in ('booked', 'in_progress')
       and x.starts_at > now() and x.starts_at <= now() + interval '1 day'
  loop
    s := public.mygig_settings_at(d.quote #>> '{place,country}', d.quote #>> '{place,state}',
                                  d.quote #>> '{place,city}', d.quote #>> '{place,suburb}');
    continue when d.starts_at - make_interval(mins => public.mygig_num(s #> '{later,remindMin}', 60)::int) > now();
    select * into b from public.mygig_bookings where id = d.booking_id;
    perform public.enqueue_notification(d.driver_id, 'mygig-remind-' || d.booking_id || '-' || d.day_no, 'scheduled_ride',
      'critical', 'myGiG booking coming up',
      format('%s%s at %s. Start it from Scheduled myGiG.', public.mygig_kind_label(d.kind),
             case when d.days > 1 then format(', day %s of %s,', d.day_no, d.days) else '' end,
             public.mygig_when_text(d.starts_at, d.timezone)),
      jsonb_build_object('type', 'mygig_booking', 'booking_id', d.booking_id, 'role', 'partner'));
    perform public.mygig_tell_passenger(b, 'remind' || d.day_no, 'myGiG booking coming up',
      format('Your %s with %s starts %s.', lower(public.mygig_kind_label(d.kind)),
             coalesce(public.mygig_driver_card(d.driver_id)->>'name', 'your driver'),
             public.mygig_when_text(d.starts_at, d.timezone)));
    update public.mygig_booking_days set reminded_at = now() where booking_id = d.booking_id and day_no = d.day_no;
    n := n + 1;
  end loop;
  for d in
    select x.booking_id, x.day_no from public.mygig_booking_days x join public.mygig_bookings bb on bb.id = x.booking_id
     where x.status = 'scheduled' and bb.status in ('booked', 'in_progress')
       and coalesce((x.quote->>'endsAt')::timestamptz, x.starts_at + interval '12 hours') < now() - interval '1 hour'
  loop
    update public.mygig_booking_days set status = 'expired' where booking_id = d.booking_id and day_no = d.day_no;
    perform public.mygig_booking_refresh(d.booking_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.mygig_bookings_tick() from public, anon, authenticated;

-- ---- 7. The ride: a booked day, a hire's day -------------------------------------------------------
-- 0329's, with what a booked day was given from its booking (prepaid) and
-- extras charged in the app (appPaid).
create or replace function public.mygig_paid_so_far(r public.ride_requests)
returns numeric
language sql
immutable
set search_path = public
as $$
  select round(coalesce((r.mygig->>'linkPaid')::numeric, 0) + coalesce((r.mygig->>'cashPaid')::numeric, 0)
               + coalesce((r.mygig->>'prepaid')::numeric, 0) + coalesce((r.mygig->>'appPaid')::numeric, 0), 2);
$$;

-- Whether the ride is paid as it goes (part A's pay by link, and every
-- booked day but a business account's): owed before the start and at the end.
create or replace function public.mygig_pays_first(r public.ride_requests)
returns boolean
language sql
immutable
set search_path = public
as $$
  select r.mygig is not null
     and (r.mygig->>'pay' = 'link' or (r.mygig ? 'bookingId' and r.mygig->>'pay' <> 'business'));
$$;

create or replace function public.mygig_owed(r public.ride_requests)
returns numeric
language sql
stable
set search_path = public
as $$
  select case
    when not public.mygig_pays_first(r) or r.payment_status = 'paid' then 0
    when r.status = 'completed' then greatest(0, round(public.ride_left_to_pay(r) - public.mygig_paid_so_far(r), 2))
    else greatest(0, round(coalesce((r.mygig #>> '{pendingFinal,due}')::numeric, (r.mygig #>> '{quote,total}')::numeric, 0)
                           - public.mygig_paid_so_far(r), 2)) end;
$$;

-- 0329's start, with a booked day: paid for already (its share), so only
-- what isn't is owed first; coming to the pickup is in a booking's price.
create or replace function public.mygig_start(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  c jsonb;
  v_owed numeric;
  v_appr numeric := coalesce((r.mygig #>> '{quote,approach}')::numeric, 0);
  v_booked boolean := r.mygig ? 'bookingId';
begin
  if r.status not in ('accepted', 'arrived') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This trip already started or ended.';
  end if;
  -- A child's trip still needs the pickup code (0317).
  c := public.family_driver_child(r.id);
  if c is not null and not coalesce((c->>'verified')::boolean, false) then
    raise exception 'FAMILY_CODE_NEEDED' using errcode = '42501', hint = 'Check the child''s photo and enter the pickup code first.';
  end if;
  -- No losses: paid before the trip.
  v_owed := public.mygig_owed(r);
  if public.mygig_pays_first(r) and v_owed > 0.005 then
    raise exception 'MYGIG_PAY_FIRST' using errcode = '42501',
      hint = format('The passenger pays %s by link before the trip starts, or in cash to you.', public.mygig_money(v_owed));
  end if;
  if r.mygig->>'pay' = 'cash' then
    -- Coming to the pickup, paid in cash at the pickup before the trip.
    if not v_booked and v_appr > 0 and r.mygig->>'approachCashAt' is null then
      raise exception 'MYGIG_APPROACH_CASH' using errcode = '42501',
        hint = format('Collect %s in cash for coming to the pickup first.', public.mygig_money(v_appr));
    end if;
    -- The commission and the myGiG fee come off GET.credit at the end.
    if not public.commission_credit_ok(r.partner_id) then
      raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
        hint = 'Your GET.credit is below the minimum for cash trips. Top up to start this myGiG.';
    end if;
  end if;
  update public.ride_requests
     set status = 'on_trip', started_at = now(), start_method = 'none',
         arrived_at = coalesce(arrived_at, now())
   where id = r.id;
  return jsonb_build_object('status', 'on_trip');
end;
$$;
revoke execute on function public.mygig_start(uuid) from public, anon;
grant execute on function public.mygig_start(uuid) to authenticated;

-- A hire's day at [p_at]: the time used, overtime past the day's hours (in
-- the hire's steps, at its overtime rate) and km over the day's km.
create or replace function public.mygig_hire_extra(r public.ride_requests, p_at timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_step int := greatest(1, coalesce(r.hire_step_min, 30));
  v_used numeric := greatest(0, extract(epoch from (p_at - coalesce(r.hire_started_at, p_at))) / 60);
  v_over numeric;
  v_ot numeric;
  v_km numeric := round(greatest(0, coalesce(r.hire_km_used, 0)), 1);
  v_xkm numeric;
  v_xamt numeric;
  v_lines jsonb := '[]'::jsonb;
begin
  if r.hire_package is null then
    return jsonb_build_object('amount', 0, 'lines', '[]'::jsonb);
  end if;
  v_over := ceil(greatest(0, v_used - coalesce(r.hire_hours, 0) * 60) / v_step) * v_step;
  v_ot := public.hire_overtime_amount(v_over, v_step, r.hire_overtime_rate);
  v_xkm := greatest(0, round(v_km - coalesce(r.hire_km_included, 0), 1));
  v_xamt := round(v_xkm * coalesce(r.hire_extra_km_rate, 0), 2);
  if v_ot > 0 then
    v_lines := v_lines || jsonb_build_object('kind', 'overtime', 'label', 'Overtime ' || v_over::int || ' min', 'amount', v_ot);
  end if;
  if v_xamt > 0 then
    v_lines := v_lines || jsonb_build_object('kind', 'extra_km', 'label', 'Extra km ' || public.hire_plain(v_xkm) || ' km',
                                             'amount', v_xamt);
  end if;
  return jsonb_build_object(
    'usedMinutes', round(v_used)::int, 'bookedHours', r.hire_hours, 'overtimeMinutes', v_over::int, 'overtime', v_ot,
    'kmUsed', v_km, 'kmIncluded', r.hire_km_included, 'extraKm', v_xkm, 'extraKmAmount', v_xamt,
    'amount', round(v_ot + v_xamt, 2), 'lines', v_lines);
end;
$$;
revoke execute on function public.mygig_hire_extra(public.ride_requests, timestamptz) from public, anon, authenticated;

-- 0329's final price, with a hire's overtime and extra km (taxed as the day).
create or replace function public.mygig_final(r public.ride_requests)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q jsonb := r.mygig->'quote';
  v_wait numeric := round(coalesce(r.waiting_charge, 0) + coalesce((r.mygig->>'stopWaitCharge')::numeric, 0), 2);
  v_ex jsonb := public.mygig_hire_extra(r, coalesce(r.completed_at, now()));
  v_sub numeric;
  v_tax numeric := 0;
  v_exact numeric;
  v_total numeric;
begin
  v_sub := round(coalesce((q->>'sub')::numeric, 0) + v_wait + coalesce((v_ex->>'amount')::numeric, 0), 2);
  if q->>'taxName' is not null and coalesce((q->>'taxValue')::numeric, 0) > 0 then
    v_tax := round(case when q->>'taxKind' = 'fixed' then (q->>'taxValue')::numeric
                        else v_sub * (q->>'taxValue')::numeric / 100 end, 2);
  end if;
  v_exact := round(v_sub + v_tax, 2);
  v_total := case when coalesce((q->>'roundUp')::boolean, false) then ceil(v_exact - 0.000001) else v_exact end;
  return jsonb_build_object('waiting', v_wait, 'pickupWaitMin', coalesce(r.waiting_minutes, 0),
                            'stopWaitMin', coalesce((r.mygig->>'stopWaitMin')::int, 0),
                            'hireExtra', v_ex,
                            'sub', v_sub, 'tax', v_tax, 'exact', v_exact, 'rounded', round(v_total - v_exact, 2),
                            'total', round(v_total, 2),
                            'fare', (public.mygig_ride_money(q, round(v_total, 2), v_tax)->>'fare')::numeric);
end;
$$;
revoke execute on function public.mygig_final(public.ride_requests) from public, anon, authenticated;

-- 0329's Complete trip, with a booked day and a hire's day: what isn't paid
-- yet (overtime, extra km, waiting, tolls) is charged in the app for an
-- in-app payer, else paid before the day ends (a link, or cash the driver
-- confirms); the day's share from the booking goes to the driver.
create or replace function public.mygig_complete(p_ride uuid, p_tolls numeric default null, p_other numeric default null,
                                                 p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  f jsonb;
  v_tolls numeric := round(greatest(0, least(10000, coalesce(p_tolls, (r.mygig #>> '{pendingFinal,tolls}')::numeric, 0))), 2);
  v_other numeric := round(greatest(0, least(10000, coalesce(p_other, (r.mygig #>> '{pendingFinal,other}')::numeric, 0))), 2);
  v_note text := coalesce(p_note, r.mygig #>> '{pendingFinal,note}');
  v_fee numeric;
  v_paid text;
  v_due numeric;
  v_owed numeric;
  v_link numeric;
  v_refund numeric := 0;
  v_first boolean := public.mygig_pays_first(r);
  v_settled jsonb;
  v_out numeric;
begin
  if r.status <> 'on_trip' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Start the trip first.';
  end if;
  -- A stop wait still running ends now.
  if r.mygig->>'stopWaitSince' is not null then
    perform public.mygig_stop_wait(r.id, false);
    select * into r from public.ride_requests where id = r.id;
  end if;
  f := public.mygig_final(r);
  -- No losses: what was added (tolls, parking, waiting, overtime, extra km,
  -- a changed route) is paid before the trip can end.
  if v_first then
    v_due := round((f->>'total')::numeric + v_tolls + v_other, 2);
    v_owed := round(v_due - public.mygig_paid_so_far(r), 2);
    if v_owed > 0.005 and r.rider_id is not null and r.mygig->>'pay' in ('wallet', 'family')
       and public.mygig_app_charge(r.rider_id, r.id, v_owed, 'ride_payment', 'myGiG ride extras') then
      update public.ride_requests
         set mygig = mygig || jsonb_build_object('appPaid', coalesce((mygig->>'appPaid')::numeric, 0) + v_owed)
       where id = r.id;
      select * into r from public.ride_requests where id = r.id;
      v_owed := 0;
    end if;
    if v_owed > 0.005 then
      update public.ride_requests
         set mygig = mygig || jsonb_build_object('pendingFinal', jsonb_build_object(
                       'tolls', v_tolls, 'other', v_other, 'note', v_note, 'due', v_due, 'at', now()))
       where id = r.id;
      return jsonb_build_object('status', 'on_trip', 'needsPayment', true, 'owed', v_owed, 'due', v_due, 'final', f);
    end if;
    -- Paid more than the end price by link: the difference goes back.
    v_link := coalesce((r.mygig->>'linkPaid')::numeric, 0);
    v_refund := least(v_link, greatest(0, -v_owed));
  end if;
  v_fee := public.mygig_trip_fee(r.mygig->'tripFee', (f->>'total')::numeric);
  if r.hire_package is not null then
    v_settled := (f->'hireExtra') || jsonb_build_object(
      'base', coalesce((r.mygig #>> '{quote,base}')::numeric, (r.mygig #>> '{quote,fare}')::numeric, 0),
      'hours', r.hire_hours, 'placeFees', coalesce((r.mygig #>> '{quote,placeFees}')::numeric, 0),
      'fare', (f->>'fare')::numeric, 'endedBy', 'driver', 'endedAt', now(), 'mygig', true,
      'lines', jsonb_build_array(jsonb_build_object('kind', 'hire',
                 'label', case when coalesce((r.mygig->>'days')::int, 1) > 1
                               then format('%s day %s of %s', public.mygig_kind_label(r.hire_package),
                                           r.mygig->>'dayNo', r.mygig->>'days')
                               else public.hire_hours_label(r.hire_hours) end,
                 'amount', coalesce((r.mygig #>> '{quote,base}')::numeric, (r.mygig #>> '{quote,fare}')::numeric, 0)))
               || coalesce(f #> '{hireExtra,lines}', '[]'::jsonb));
  end if;
  update public.ride_requests
     set status = 'completed', completed_at = now(),
         fare = (f->>'fare')::numeric, ride_fare = (f->>'fare')::numeric,
         tax_name = case when (f->>'tax')::numeric > 0 then coalesce(r.mygig #>> '{quote,taxName}', 'Tax') end,
         tax_kind = case when (f->>'tax')::numeric > 0 then 'fixed' end,
         tax_value = case when (f->>'tax')::numeric > 0 then (f->>'tax')::numeric end,
         toll_charges = nullif(v_tolls, 0), other_charges = nullif(v_other, 0),
         other_charges_note = case when v_other > 0 then left(nullif(btrim(coalesce(v_note, '')), ''), 80) end,
         hire_settled = coalesce(v_settled, hire_settled),
         mygig = (mygig - 'pendingFinal') || jsonb_build_object('final', f, 'tripFeeAmount', v_fee)
                 || case when v_refund > 0 then jsonb_build_object('refundDue', v_refund) else '{}'::jsonb end
   where id = r.id;
  if v_fee > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (r.partner_id, 'get_credit', 'mygig_fee', -v_fee, 'mygig', 'myGiG fee — ' || public.mygig_money(v_fee), r.id);
  end if;
  if v_refund > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (r.partner_id, 'get_credit', 'mygig_refund', -v_refund, 'mygig',
            'myGiG paid by link above the end price, back to the passenger — ' || public.mygig_money(v_refund), r.id);
  end if;
  select * into r from public.ride_requests where id = r.id;
  if v_first then
    -- The booking's share and what was charged in the app go to the driver now.
    v_out := coalesce((r.mygig->>'prepaid')::numeric, 0) + coalesce((r.mygig->>'appPaid')::numeric, 0);
    if v_out > 0 and not coalesce((r.mygig->>'payTest')::boolean, false) then
      perform public.mygig_payout(r.partner_id, r.id, v_out, 'ride_earning', 'myGiG ride paid');
    end if;
    update public.ride_requests
       set payment_status = 'paid',
           paid_method = case when coalesce((mygig->>'cashPaid')::numeric, 0) >= public.ride_left_to_pay(r) - 0.005 then 'cash'
                              when coalesce((mygig->>'linkPaid')::numeric, 0) + coalesce((mygig->>'prepaid')::numeric, 0) > 0
                                then 'gateway'
                              else 'get_wallet' end,
           paid_amount = public.ride_left_to_pay(r), paid_at = now(),
           mygig = mygig || jsonb_build_object('paidOut', v_out)
     where id = r.id;
  elsif r.mygig->>'pay' = 'family' then
    v_paid := public.mygig_pay_family(r.id);
  end if;
  select * into r from public.ride_requests where id = r.id;
  return jsonb_build_object('status', r.status, 'total', public.ride_amount_due(r), 'final', f,
                            'tripFee', v_fee, 'paymentStatus', r.payment_status, 'family', v_paid,
                            'needsPayment', false, 'refund', v_refund, 'settled', v_settled);
end;
$$;
revoke execute on function public.mygig_complete(uuid, numeric, numeric, text) from public, anon;
grant execute on function public.mygig_complete(uuid, numeric, numeric, text) to authenticated;

-- End the hire's day (or the hourly hire): the km driven (else as the trip
-- measured them), then Complete with tolls and other charges.
create or replace function public.mygig_hire_end(p_ride uuid, p_km numeric default null, p_tolls numeric default null,
                                                 p_other numeric default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  v_km numeric := p_km;
begin
  if r.hire_package is null then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This ride isn''t a hire.';
  end if;
  if r.status <> 'on_trip' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Start the hire first.';
  end if;
  if v_km is not null and (v_km < 0 or v_km > 5000) then
    raise exception 'HIRE_KM' using errcode = '22023', hint = 'Enter the km driven (0 to 5000).';
  end if;
  if v_km is null then
    select t.actual_trip_km into v_km from public.ride_telematics t where t.ride_id = r.id;
  end if;
  update public.ride_requests set hire_km_used = round(greatest(0, coalesce(v_km, hire_km_used, 0)), 1) where id = r.id;
  return public.mygig_complete(r.id, p_tolls, p_other, p_note);
end;
$$;
revoke execute on function public.mygig_hire_end(uuid, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.mygig_hire_end(uuid, numeric, numeric, numeric, text) to authenticated;

-- 0329's take cash, for every ride paid as it goes (a booked day too).
create or replace function public.mygig_take_cash(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  v_owed numeric;
begin
  if not public.mygig_pays_first(r) or r.status not in ('accepted', 'arrived', 'on_trip', 'completed') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Nothing to take in cash.';
  end if;
  v_owed := public.mygig_owed(r);
  if v_owed <= 0 then
    return jsonb_build_object('cash', 0, 'paymentStatus', r.payment_status);
  end if;
  update public.payment_intents set status = 'cancelled', failure = 'cash'
   where purpose = 'ride_card' and purpose_ref = r.id::text and status = 'pending';
  update public.ride_requests
     set mygig = mygig || jsonb_build_object('cashPaid', coalesce((mygig->>'cashPaid')::numeric, 0) + v_owed,
                                             'linkUnpaid', true)
   where id = r.id;
  if r.status = 'completed' then
    select * into r from public.ride_requests where id = r.id;
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'cash', paid_amount = public.ride_left_to_pay(r), paid_at = now()
     where id = r.id;
  end if;
  return jsonb_build_object('cash', v_owed);
end;
$$;
revoke execute on function public.mygig_take_cash(uuid) from public, anon;
grant execute on function public.mygig_take_cash(uuid) to authenticated;

-- 0329's cancel settle, with a booked day: the passenger cancelled or
-- didn't come, so the driver keeps the day's share (paid to them); the
-- driver cancelled, so it goes back to the booking.
create or replace function public.ride_requests_mygig_cancel_settle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link numeric := coalesce((new.mygig->>'linkPaid')::numeric, 0);
  v_keep numeric := 0;
  v_refund numeric;
  v_passenger boolean := coalesce(new.cancel_reason, '') in ('passenger_no_show', 'passenger_cancelled')
                         or new.cancel_requested_by = 'rider';
  a jsonb := coalesce(new.mygig->'alloc', '{}'::jsonb);
  a_cash numeric := coalesce((a->>'cash')::numeric, 0);
  a_link numeric := coalesce((a->>'link')::numeric, 0);
  a_app numeric := coalesce((a->>'app')::numeric, 0);
begin
  if new.mygig is null or new.mygig ? 'refundDue' then
    return null;
  end if;
  if new.mygig ? 'bookingId' and a_cash + a_link + a_app > 0 then
    if v_passenger then
      if not coalesce((new.mygig->>'payTest')::boolean, false) then
        perform public.mygig_payout(new.partner_id, new.id, a_link + a_app, 'mygig_cancel_kept',
                                    'myGiG booked day, passenger didn''t come');
      end if;
      update public.mygig_bookings set kept_amount = kept_amount + a_cash + a_link + a_app
       where id = (new.mygig->>'bookingId')::uuid;
    else
      update public.mygig_bookings
         set cash_left = cash_left + a_cash, link_left = link_left + a_link, app_left = app_left + a_app,
             allocated_amount = greatest(0, allocated_amount - a_cash - a_link - a_app)
       where id = (new.mygig->>'bookingId')::uuid;
    end if;
  end if;
  if v_passenger then
    v_keep := least(v_link, coalesce((new.mygig #>> '{quote,approach}')::numeric, 0));
  end if;
  v_refund := round(v_link - v_keep, 2);
  update public.ride_requests
     set mygig = mygig || jsonb_build_object('refundDue', v_refund, 'kept', v_keep,
                   'approachCashBack', not v_passenger and new.mygig->>'approachCashAt' is not null,
                   'alloc', '{}'::jsonb)
   where id = new.id;
  if v_refund > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (new.partner_id, 'get_credit', 'mygig_refund', -v_refund, 'mygig',
            'myGiG cancelled: paid by link, back to the passenger — ' || public.mygig_money(v_refund), new.id);
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_requests_mygig_cancel_settle() from public, anon, authenticated;

-- ---- 8. Pay by link: a booking as well as a ride ----------------------------------------------------
create or replace function public.payment_mygig_link_allowed(p_request uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (exists (select 1 from public.ride_requests r
                   where r.id = p_request and r.partner_id = auth.uid() and r.mygig is not null
                     and public.mygig_pays_first(r) and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
                     and public.mygig_owed(r) > 0)
          or exists (select 1 from public.mygig_bookings b
                      where b.id = p_request and b.driver_id = auth.uid() and public.mygig_booking_link_owed(b) > 0))
     and public.payment_gateway_for('ride_card') is not null;
$$;
revoke execute on function public.payment_mygig_link_allowed(uuid) from public, anon;
grant execute on function public.payment_mygig_link_allowed(uuid) to authenticated;

-- Service role: the intent for what is owed now on a ride (0329) or a
-- booking (what confirms it, or the balance before day 1).
create or replace function public.payment_mygig_intent(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  v public.payment_intents;
  v_gateway uuid;
  v_values jsonb;
  v_total numeric;
  v_user uuid;
  v_name text;
  v_phone text;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if found then
    if r.mygig is null or not public.mygig_pays_first(r) then
      raise exception 'not_pay_link' using errcode = '22023';
    end if;
    if r.payment_status = 'paid' then
      raise exception 'already_paid' using errcode = '22023';
    end if;
    if r.status not in ('accepted', 'arrived', 'on_trip', 'completed') then
      raise exception 'order_closed' using errcode = '22023';
    end if;
    v_total := public.mygig_owed(r);
    v_user := r.rider_id;
    v_name := r.rider_name;
    v_phone := r.mygig->>'phone';
  else
    select * into b from public.mygig_bookings where id = p_request for update;
    if not found then
      raise exception 'not_pay_link' using errcode = '22023';
    end if;
    if b.status not in ('awaiting_payment', 'booked', 'in_progress') then
      raise exception 'order_closed' using errcode = '22023';
    end if;
    v_total := public.mygig_booking_link_owed(b);
    v_user := b.rider_id;
    v_name := b.passenger_name;
    v_phone := b.phone;
  end if;
  if v_total <= 0 then
    raise exception 'already_paid' using errcode = '22023';
  end if;
  select * into v from public.payment_intents
   where purpose = 'ride_card' and purpose_ref = p_request::text and status = 'pending' and amount = v_total
   order by created_at desc limit 1;
  if not found then
    v_gateway := public.payment_gateway_for('ride_card');
    select e.values into v_values from public.settings_entries e where e.id = v_gateway;
    if v_values is null then
      raise exception 'no_gateway' using errcode = '22023';
    end if;
    update public.payment_intents set status = 'cancelled', failure = 'replaced'
     where purpose = 'ride_card' and purpose_ref = p_request::text and status = 'pending';
    insert into public.payment_intents (user_id, purpose, purpose_ref, gateway_id, provider, test_mode, amount, currency)
    values (v_user, 'ride_card', p_request::text, v_gateway, v_values ->> 'providerId',
            coalesce(v_values ->> 'mode', 'Live') = 'Sandbox', v_total, 'MYR')
    returning * into v;
  end if;
  return to_jsonb(v) || jsonb_build_object(
    'customer', jsonb_build_object('name', coalesce(v_name, ''), 'phone', coalesce(v_phone, ''), 'email', ''),
    'owed', v_total);
end;
$$;
revoke execute on function public.payment_mygig_intent(uuid) from public, anon, authenticated;
grant execute on function public.payment_mygig_intent(uuid) to service_role;

-- Service role: the hosted page is on the ride or the booking; the
-- passenger is texted it.
create or replace function public.payment_mygig_link_set(p_request uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
begin
  if coalesce(p_url, '') !~ '^https://' then
    raise exception 'unknown_order' using errcode = '22023';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if found then
    if r.mygig is null then
      raise exception 'unknown_order' using errcode = '22023';
    end if;
    update public.ride_requests set mygig = mygig || jsonb_build_object('payUrl', p_url, 'payLinkAt', now())
     where id = r.id;
    perform public.mygig_sms(r.mygig->>'phone',
      'get.ride: pay ' || public.mygig_money(public.mygig_owed(r)) || ' for your ride by card, FPX or DuitNow: ' || p_url);
    return;
  end if;
  select * into b from public.mygig_bookings where id = p_request for update;
  if not found then
    raise exception 'unknown_order' using errcode = '22023';
  end if;
  update public.mygig_bookings set pay_url = p_url where id = b.id;
  perform public.mygig_sms(b.phone,
    'get.ride: pay ' || public.mygig_money(public.mygig_booking_link_owed(b)) || ' for your myGiG booking ('
    || public.mygig_when_text(b.first_at, b.timezone) || ') by card, FPX or DuitNow: ' || p_url);
end;
$$;
revoke execute on function public.payment_mygig_link_set(uuid, text) from public, anon, authenticated;
grant execute on function public.payment_mygig_link_set(uuid, text) to service_role;

-- 0252's ride_card hook: a myGiG ride paid by link (0329), or a booking
-- (0330: held by get.ride until each day is driven), paid once per intent.
create or replace function public.payment_ride_card_paid(p_intent uuid, p_ride text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  v public.payment_intents;
begin
  select * into v from public.payment_intents where id = p_intent;
  if not found or coalesce(p_ride, '') !~* '^[0-9a-f-]{36}$' then
    return;
  end if;
  select * into b from public.mygig_bookings where id = p_ride::uuid for update;
  if found then
    if b.link_intents ? v.id::text then
      return;
    end if;
    update public.mygig_bookings set link_intents = link_intents || to_jsonb(v.id::text) where id = b.id;
    perform public.mygig_booking_paid(b.id, v.amount, 'link', v.test_mode);
    perform public.enqueue_notification(b.driver_id, 'mygig-paid-' || v.id, 'scheduled_ride', 'normal',
      'Paid by link', format('The passenger paid %s by link for the booking.', public.mygig_money(v.amount)),
      jsonb_build_object('type', 'mygig_booking', 'booking_id', b.id, 'role', 'partner'));
    return;
  end if;
  select * into r from public.ride_requests where id = p_ride::uuid for update;
  if not found or r.mygig is null or r.payment_status = 'paid'
     or coalesce(r.mygig->'linkIntents', '[]'::jsonb) ? v.id::text then
    return;
  end if;
  -- A sandbox payment moves the ride on but pays nothing out.
  if not v.test_mode then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (r.partner_id, 'get_wallet', 'ride_earning', v.amount, 'gateway',
            'Ride paid by link — ' || public.mygig_money(v.amount), r.id);
  end if;
  update public.ride_requests
     set mygig = mygig || jsonb_build_object(
           'linkPaid', coalesce((mygig->>'linkPaid')::numeric, 0) + v.amount,
           'linkIntents', coalesce(mygig->'linkIntents', '[]'::jsonb) || to_jsonb(v.id::text),
           'linkPaidAt', now(), 'payTest', v.test_mode or coalesce((mygig->>'payTest')::boolean, false))
   where id = r.id
  returning * into r;
  if r.status = 'completed' and public.mygig_owed(r) <= 0 then
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'gateway', paid_amount = public.ride_left_to_pay(r), paid_at = now()
     where id = r.id;
  end if;
  perform public.enqueue_notification(r.partner_id, 'mygig-paid-' || v.id, 'ride_status', 'normal',
    'Paid by link', format('The passenger paid %s by link.', public.mygig_money(v.amount)),
    jsonb_build_object('type', 'mygig_answer', 'request_id', r.id, 'role', 'partner'), r.id);
end;
$$;
revoke execute on function public.payment_ride_card_paid(uuid, text) from public, anon, authenticated;

-- ---- 9. The trip link and the driver's config -------------------------------------------------------
-- 0329's trip link, with the booking it became: shown until the booking
-- ends (and the link expiry after), with the day's live ride.
create or replace function public.mygig_link_view(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
  c public.mygig_offers;
  r public.ride_requests;
  bk public.mygig_bookings;
  v_wait int;
  q jsonb;
begin
  v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
  end if;
  select * into o from public.mygig_offers where token_hash = public.mygig_token_hash(p_token);
  if not found then
    -- A token from an earlier send: the ride it became still answers.
    select * into r from public.ride_requests x where x.mygig->>'tokenHash' = public.mygig_token_hash(p_token)
     order by x.created_at desc limit 1;
    if r.id is null then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
    end if;
    select * into o from public.mygig_offers where id = (r.mygig->>'offerId')::uuid;
  end if;
  if o.booking_id is not null then
    select * into bk from public.mygig_bookings where id = o.booking_id;
    select x.* into r from public.mygig_booking_days d join public.ride_requests x on x.id = d.ride_id
     where d.booking_id = bk.id order by d.day_no desc limit 1;
  elsif o.ride_id is not null then
    select * into r from public.ride_requests where id = o.ride_id;
    -- A new price waiting for the passenger shows on the first link too.
    select * into c from public.mygig_offers x
     where x.ride_id = o.ride_id and x.kind = 'change' and x.status = 'waiting' and x.expires_at > now()
     order by x.created_at desc limit 1;
    if c.id is not null then
      o := c;
    end if;
  end if;
  if bk.id is not null then
    if bk.status in ('completed', 'cancelled', 'expired')
       and bk.updated_at < now() - make_interval(hours => coalesce((bk.quote->>'linkHours')::int, 24)) then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link has expired.';
    end if;
  elsif r.id is not null and r.status in ('completed', 'cancelled')
     and coalesce(r.completed_at, r.cancelled_at, r.updated_at)
         < now() - make_interval(hours => coalesce((r.mygig #>> '{quote,linkHours}')::int, 24)) then
    raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link has expired.';
  end if;
  q := o.quote;
  return jsonb_build_object(
    'status', case when o.status = 'waiting' and o.expires_at <= now() then 'expired' else o.status end,
    'kind', o.kind,
    'name', case when o.passenger_id is null then split_part(coalesce(o.passenger_name, ''), ' ', 1) end,
    'driver', public.mygig_driver_card(o.driver_id),
    'trip', jsonb_build_object('pickup', (o.trip -> 'pickup') - 'here', 'drop', o.trip->'drop',
                               'stops', o.trip->'stops', 'round', o.trip->'round', 'pax', o.trip->'pax',
                               'bags', o.trip->'bags', 'pay', o.trip->'pay',
                               'directed', coalesce((o.trip->>'directed')::boolean, false)),
    'quote', jsonb_build_object('km', q->'km', 'min', q->'min', 'fare', q->'fare', 'busy', q->'busy',
                                'busyLabel', q->'busyLabel', 'luggage', q->'luggage', 'approach', q->'approach',
                                'approachKm', q->'approachKm', 'pickupFee', q->'pickupFee', 'dropFee', q->'dropFee',
                                'pickupFeeName', q->'pickupFeeName', 'dropFeeName', q->'dropFeeName',
                                'tax', q->'tax', 'taxName', q->'taxName', 'showTax', q->'showTax',
                                'rounded', q->'rounded', 'total', q->'total', 'guard', q->'guard',
                                'appPrice', case when (q->>'guard')::boolean then q->'appPrice' end,
                                'terms', q->'terms',
                                'hire', q->'hire', 'title', q->'title', 'hours', q->'hours',
                                'hoursPerDay', q->'hoursPerDay', 'days', q->'days', 'periods', q->'periods',
                                'weekdays', q->'weekdays', 'kmIncluded', q->'kmIncluded',
                                'overtimePerHour', q->'overtimePerHour', 'extraKm', q->'extraKm',
                                'overnightTotal', q->'overnightTotal', 'base', q->'base', 'placeFees', q->'placeFees'),
    'offerBooking', o.booking,
    'booking', case when bk.id is not null then public.mygig_booking_json(bk, 'link') end,
    'expiresAt', o.expires_at,
    'ride', case when r.id is not null then jsonb_build_object(
      'status', r.status,
      'shareToken', (select x.share_token from public.ride_request_private x where x.request_id = r.id),
      'total', public.ride_amount_due(r),
      'paymentStatus', r.payment_status,
      'cancelFee', case when r.accepted_at < now() - make_interval(
                               secs => (coalesce((r.mygig #>> '{terms,cancelFreeMin}')::numeric, 2) * 60)::int)
                        then coalesce((r.mygig #>> '{terms,cancelFee}')::numeric, 0) else 0 end,
      'canCancel', r.status in ('accepted', 'arrived') and bk.id is null,
      'owed', public.mygig_owed(r), 'linkPaid', coalesce((r.mygig->>'linkPaid')::numeric, 0),
      'payUrl', case when public.mygig_owed(r) > 0 then r.mygig->>'payUrl' end,
      'dayNo', r.mygig->'dayNo', 'days', r.mygig->'days',
      'waitingCharge', coalesce(r.waiting_charge, 0) + coalesce((r.mygig->>'stopWaitCharge')::numeric, 0)) end);
end;
$$;
revoke execute on function public.mygig_link_view(text) from public;
grant execute on function public.mygig_link_view(text) to anon, authenticated;

-- 0329's config, with the hire packages the driver may send, the hire
-- rates they price with, and how many bookings are in Scheduled myGiG.
create or replace function public.mygig_config(p_lat double precision default null, p_lng double precision default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  st jsonb;
  s jsonb;
  pr jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  st := public.mygig_state(v_uid, p_lat, p_lng);
  s := st->'settings';
  pr := public.mygig_prefs_of(v_uid, s);
  return st || jsonb_build_object(
    'global', jsonb_build_object('who', public.mygig_global()->>'who'),
    'prefs', pr,
    'blocked', coalesce((select jsonb_agg(b.digits order by b.created_at desc) from public.mygig_blocked_numbers b
                          where b.driver_id = v_uid), '[]'::jsonb),
    'pricing', (select public.mygig_region_pricing(p->>'country', p->>'state', p->>'city', p->>'suburb')
                  from (select coalesce(public.mygig_place(p_lat, p_lng), '{}'::jsonb) p) x),
    'hireKinds', to_jsonb(public.mygig_hire_kinds(s, pr)),
    'hireCard', public.mygig_hire_card(s, pr),
    'scheduledCount', (select count(*) from public.mygig_bookings b
                        where b.driver_id = v_uid and b.status in ('awaiting_payment', 'booked', 'in_progress')));
end;
$$;
revoke execute on function public.mygig_config(double precision, double precision) from public, anon;
grant execute on function public.mygig_config(double precision, double precision) to authenticated;

-- ---- 10. 0326-0328's hire, for a myGiG hire ---------------------------------------------------------
-- 0327's, and a myGiG hire is priced by myGiG (its fare is set when the
-- ride is made).
create or replace function public.ride_requests_hire_price()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  q jsonb;
begin
  if new.hire_package is null or new.mygig is not null then
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

-- 0327's, and a myGiG hire takes its terms from its myGiG day (mygig.hire):
-- the hours, the km, overtime and extra km, its hire booking and day.
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
    -- 0330: a myGiG hire (now, or a booked day): its terms are its myGiG
    -- day's, its price myGiG's.
    if new.mygig is not null and jsonb_typeof(new.mygig->'hire') = 'object' then
      q := new.mygig->'hire';
      new.hire_quote := q;
      new.hire_hours := (q->>'hours')::numeric;
      new.hire_rate := (q->>'rate')::numeric;
      new.hire_km_included := (q->>'kmIncluded')::numeric;
      new.hire_overtime_rate := (q->>'overtimePerHour')::numeric;
      new.hire_step_min := coalesce((q->>'stepMinutes')::int, 30);
      new.hire_extra_km_rate := (q->>'extraKm')::numeric;
      new.hire_booking_id := case when coalesce(q->>'hireBookingId', '') ~* '^[0-9a-f-]{36}$'
                                  then (q->>'hireBookingId')::uuid end;
      new.hire_day_no := case when coalesce((q->>'days')::int, 1) > 1 then (q->>'dayNo')::int end;
      new.hire_started_at := null; new.hire_ends_at := null; new.hire_extensions := '[]'::jsonb;
      new.hire_km_used := null; new.hire_settled := null; new.hire_reminded_at := null;
      new.option_names := coalesce(case when jsonb_typeof(new.option_names) = 'object' then new.option_names end,
                                   '{}'::jsonb) || jsonb_build_object('hire', coalesce(q->>'title', 'Hire'));
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

-- 0327's hold, and a myGiG hire holds nothing: its money is myGiG's (paid
-- before the start, and its share given when the day starts).
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
  if new.mygig is not null then
    return null;
  end if;
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

-- 0327's hire tick: a myGiG hire isn't ended for the driver (they end the
-- day and collect what isn't paid), and myGiG's bookings have their minute.
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
       and mygig is null
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
  -- 0330: myGiG's bookings.
  begin
    n := n + public.mygig_bookings_tick();
  exception when others then
    raise warning 'mygig_bookings_tick: %', sqlerrm;
  end;
  return n;
end;
$$;
revoke execute on function public.hire_tick() from public, anon, authenticated;

-- 0326's End hire: a myGiG hire ends with myGiG's money (mygig_hire_end).
create or replace function public.hire_end(p_ride uuid, p_km_used numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_uid uuid := auth.uid();
  v_by text;
  s jsonb;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or r.hire_package is null then
    raise exception 'HIRE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if r.mygig is not null then
    return public.mygig_hire_end(p_ride, p_km_used);
  end if;
  v_by := case when v_uid = r.partner_id then 'driver'
               when v_uid = r.rider_id and (public.hourly_hire_config()->>'riderCanEndEarly')::boolean then 'rider' end;
  if v_by is null then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Only the driver ends this hire.';
  end if;
  if r.status <> 'on_trip' then
    raise exception 'HIRE_NOT_ON' using errcode = '22023', hint = 'The hire ends once it has started.';
  end if;
  if p_km_used is not null and (p_km_used < 0 or p_km_used > 5000) then
    raise exception 'HIRE_KM' using errcode = '22023', hint = 'Enter the km driven (0 to 5000).';
  end if;
  -- The rider's own end: km as the trip measured it, never the rider's figure.
  s := public.hire_finish(p_ride, case when v_by = 'driver' then p_km_used end, v_by);
  if v_by = 'rider' then
    perform public.enqueue_notification(r.partner_id, 'hire-end-' || r.id, 'ride_status', 'critical',
      'The rider ended the hire', 'The hire is over. The trip is complete.',
      jsonb_build_object('type', 'hire_ended', 'request_id', r.id), r.id);
  end if;
  return s;
end;
$$;
revoke execute on function public.hire_end(uuid, numeric) from public, anon;
grant execute on function public.hire_end(uuid, numeric) to authenticated;

-- 0328's cancel: a myGiG hire is cancelled as a myGiG booking.
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
  if b.mygig_booking_id is not null then
    perform public.mygig_booking_cancel(b.mygig_booking_id, null, p_reason);
    select * into b from public.hire_bookings where id = p_booking;
    return b;
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

-- 0328's assign: a myGiG hire stays with the driver who made it.
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
  if b.mygig_booking_id is not null then
    raise exception 'MYGIG_BOOKING' using errcode = '22023',
      hint = 'A myGiG hire is the driver''s own booking with the passenger: cancel it, it can''t be given to another driver.';
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

-- ---- 11. Followed live by the apps ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['mygig_bookings', 'mygig_booking_days'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
