-- ============================================================================
-- 0331 — myGiG, part C: reassign to another driver, hotspots, the admin's
-- myGiG dashboard, the passenger's extras after the trip, the driver's
-- quick trips and regulars, and a late-cancel fee for in-app bookings.
--
-- Parts A (0329) and B (0330) made a myGiG ride and a booking for later or
-- hire by time. Here:
--
-- Version 20261030120000 (0331_mygig_extras). Re-runnable: tables, columns
-- and indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, seed rows only where missing.
--
-- 1. Settings (mygig_rules, by region as part A; mygig_settings_problem
--    checks them):
--    * reassign {enabled, when ('scheduled' | 'before' | 'during'),
--      answerMin (the passenger's time), driverAnswerMin (the new
--      driver's), noAnswer ('keep': the first driver keeps it | 'cancel':
--      cancelled with no charge), sameOrBigger, nearKm};
--    * hotspots {enabled, weeks, minCount, radiusKm};
--    * after {tips, tipMax, split, splitMax, einvoice, bookAgain, appOffer};
--    * driverExtras {quick, quickCount, regulars, regularMin}.
-- 2. Reassign to another driver (mygig_reassigns), like reassigning an app
--    order, acknowledged by both the new driver and the passenger:
--    * from the trip screen before pickup, from Scheduled myGiG (a later
--      trip or a hire, with the days left) and, when the admin allows it,
--      during the trip ("Hand over": 0199's meeting and swap, the first
--      driver's share of the trip when it completes);
--    * mygig_reassign_options: the reasons and nearby drivers with myGiG,
--      each with why they can't be chosen (no myGiG access, on a ride, at
--      today's limit, busy then, smaller vehicle, too small for the
--      passengers or luggage); mygig_reassign_start (a driver chosen or a
--      driver's code); the new driver sees the whole order
--      (mygig_reassign_view) and must tick "I accept this ride at the
--      agreed price" (mygig_reassign_driver_answer): their own myGiG prices
--      don't apply, their myGiG plan does; then the passenger is asked, in
--      the app, on the trip link (SMS or WhatsApp) or on the first driver's
--      phone, and confirms with "I understand my driver is now ...", keeps
--      the first driver, or cancels with no charge (mygig_reassign_answer);
--    * nothing changes until the passenger confirms; with no answer in the
--      admin's time the admin's rule applies (mygig_reassigns_tick, every
--      minute). Every step is in the ride's (or booking's) history.
--    * Money (no losses): a ride's link payment, held by the first driver,
--      moves to the new one, less what the first driver earned coming to
--      the pickup (theirs to keep); a booking's money is get.ride's until a
--      day is driven, so it simply follows the booking, and cash the first
--      driver took moves to the new driver's GET.credit. A refund later
--      comes from whoever holds the money (the cancel settle).
-- 3. Hotspots (mygig_hotspots): counts of myGiG pickups per area (about
--    1 km squares) in the last weeks, areas under the minimum hidden, and the
--    busiest hours on this weekday. Counts only: no passenger, no exact
--    pickup.
-- 4. Admin › Operations › myGiG dashboard (page admin-mygig):
--    mygig_admin_dashboard (today's rides, takings, how passengers accepted,
--    no-shows, flagged rides, reassigns, e-Invoice requests),
--    mygig_admin_bookings (later trips and hire by time, with filters),
--    mygig_admin_einvoice_set.
-- 5. After the trip, the passenger (app or trip link): mygig_after_view (the
--    receipt, what they may do), mygig_after_rate, mygig_after_tip (in the
--    app from GET.wallet; on the link paid by link or noted as cash),
--    mygig_split (2 or 3 people, a pay link for each other person, only
--    while something is owed), mygig_einvoice_request (no e-Invoice
--    connection to LHDN MyInvois exists yet: the request is kept for the
--    admin, who sends it, and the passenger is told so), mygig_book_again
--    (registered: a favourite driver for My Ride; others: the app offer with
--    the driver's referral code). Pay parts (mygig_pay_parts) are paid like
--    a ride: payment_mygig_intent / _link_set / payment_ride_card_paid take
--    a part's id, and payment_mygig_link_by_token lets the trip link ask
--    for one (the payments function's POST /payments/mygig-link with
--    {request_id, token}).
-- 6. The driver's quick trips (mygig_quick_trips: their most used myGiG
--    drop-offs) and regulars (mygig_regular: a number that rode with them
--    before and its usual drop-off).
-- 7. Part B follow-up: a late cancel of an in-app later trip or hourly hire
--    (nothing paid upfront) takes part A's cancellation fee from a
--    registered passenger paying in the app, after the free-cancel time
--    (mygig_booking_cancel).
-- ============================================================================

-- ---- 1. Tables ---------------------------------------------------------------------------------------
create table if not exists public.mygig_reassigns (
  id                  uuid primary key default gen_random_uuid(),
  ride_id             uuid references public.ride_requests(id) on delete cascade,
  booking_id          uuid references public.mygig_bookings(id) on delete cascade,
  from_driver         uuid not null references public.profiles(id) on delete cascade,
  to_driver           uuid not null references public.profiles(id) on delete cascade,
  passenger_id        uuid references public.profiles(id) on delete set null,
  reason              text not null check (char_length(reason) between 1 and 60),
  note                text check (note is null or char_length(note) <= 200),
  during              boolean not null default false,
  stage               text not null default 'driver'
                      check (stage in ('driver', 'passenger', 'done', 'declined', 'kept', 'cancelled', 'expired', 'stopped')),
  way                 text not null check (way in ('app', 'sms', 'whatsapp', 'here')),
  token_hash          text,
  answer_by           timestamptz not null,
  driver_answered_at  timestamptz,
  answered_at         timestamptz,
  answered_via        text check (answered_via is null or answered_via in ('app', 'link', 'here', 'timeout')),
  moved               numeric(12,2) not null default 0 check (moved >= 0),
  kept                numeric(12,2) not null default 0 check (kept >= 0),
  steps               jsonb not null default '[]'::jsonb check (jsonb_typeof(steps) = 'array' and pg_column_size(steps) <= 16384),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint mygig_reassigns_one_target check (num_nonnulls(ride_id, booking_id) = 1),
  constraint mygig_reassigns_two_drivers check (from_driver <> to_driver)
);
create unique index if not exists mygig_reassigns_ride_open_uidx on public.mygig_reassigns (ride_id)
  where stage in ('driver', 'passenger') and ride_id is not null;
create unique index if not exists mygig_reassigns_booking_open_uidx on public.mygig_reassigns (booking_id)
  where stage in ('driver', 'passenger') and booking_id is not null;
create unique index if not exists mygig_reassigns_token_uidx on public.mygig_reassigns (token_hash) where token_hash is not null;
create index if not exists mygig_reassigns_to_idx on public.mygig_reassigns (to_driver, created_at desc);
create index if not exists mygig_reassigns_from_idx on public.mygig_reassigns (from_driver, created_at desc);
create index if not exists mygig_reassigns_passenger_idx on public.mygig_reassigns (passenger_id) where passenger_id is not null;
create index if not exists mygig_reassigns_due_idx on public.mygig_reassigns (answer_by) where stage in ('driver', 'passenger');
create index if not exists mygig_reassigns_booking_idx on public.mygig_reassigns (booking_id) where booking_id is not null;
create index if not exists mygig_reassigns_ride_idx on public.mygig_reassigns (ride_id) where ride_id is not null;
comment on table public.mygig_reassigns is
  'myGiG (0331): a ride or booking handed to another driver. The new driver accepts it at the agreed price, then the passenger confirms; steps is its history.';

drop trigger if exists trg_mygig_reassigns_updated_at on public.mygig_reassigns;
create trigger trg_mygig_reassigns_updated_at before update on public.mygig_reassigns
  for each row execute function public.set_updated_at();

-- What the passenger did after the trip on the link (or in the app).
create table if not exists public.mygig_after (
  ride_id        uuid primary key references public.ride_requests(id) on delete cascade,
  driver_id      uuid not null references public.profiles(id) on delete cascade,
  stars          smallint check (stars is null or stars between 1 and 5),
  comment        text check (comment is null or char_length(comment) <= 500),
  rated_at       timestamptz,
  cash_tip       numeric(10,2) check (cash_tip is null or cash_tip > 0),
  cash_tip_at    timestamptz,
  book_again_at  timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists mygig_after_driver_idx on public.mygig_after (driver_id, created_at desc);
drop trigger if exists trg_mygig_after_updated_at on public.mygig_after;
create trigger trg_mygig_after_updated_at before update on public.mygig_after
  for each row execute function public.set_updated_at();

-- A share of the fare (split) or a tip, paid by link.
create table if not exists public.mygig_pay_parts (
  id          uuid primary key default gen_random_uuid(),
  ride_id     uuid not null references public.ride_requests(id) on delete cascade,
  kind        text not null check (kind in ('share', 'tip')),
  part_no     integer not null default 1 check (part_no between 1 and 3),
  parts       integer not null default 1 check (parts between 1 and 3),
  amount      numeric(10,2) not null check (amount > 0 and amount <= 100000),
  phone       text check (phone is null or phone ~ '^\+[0-9]{6,16}$'),
  token_hash  text,
  paid_amount numeric(10,2) not null default 0 check (paid_amount >= 0),
  paid_at     timestamptz,
  intents     jsonb not null default '[]'::jsonb check (jsonb_typeof(intents) = 'array'),
  pay_url     text,
  cancelled_at timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists mygig_pay_parts_ride_idx on public.mygig_pay_parts (ride_id);
create unique index if not exists mygig_pay_parts_token_uidx on public.mygig_pay_parts (token_hash) where token_hash is not null;

-- e-Invoice requests: no e-Invoice connection to LHDN MyInvois exists yet,
-- so get.ride's team sends them (Admin › myGiG dashboard).
create table if not exists public.mygig_einvoice_requests (
  id            uuid primary key default gen_random_uuid(),
  ride_id       uuid not null references public.ride_requests(id) on delete cascade,
  driver_id     uuid references public.profiles(id) on delete set null,
  requested_by  uuid references public.profiles(id) on delete set null,
  buyer_name    text not null check (char_length(buyer_name) between 1 and 120),
  tin           text check (tin is null or tin ~ '^[A-Za-z0-9]{6,20}$'),
  id_type       text check (id_type is null or id_type in ('nric', 'passport', 'brn', 'army')),
  id_no         text check (id_no is null or char_length(id_no) between 4 and 30),
  email         text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  amount        numeric(10,2) not null default 0,
  state         text not null default 'requested' check (state in ('requested', 'sent', 'rejected')),
  admin_note    text check (admin_note is null or char_length(admin_note) <= 300),
  handled_by    uuid references public.profiles(id) on delete set null,
  handled_at    timestamptz,
  created_at    timestamptz not null default now(),
  constraint mygig_einvoice_buyer_id check (tin is not null or (id_type is not null and id_no is not null))
);
create unique index if not exists mygig_einvoice_ride_uidx on public.mygig_einvoice_requests (ride_id);
create index if not exists mygig_einvoice_open_idx on public.mygig_einvoice_requests (created_at) where state = 'requested';
create index if not exists mygig_einvoice_driver_idx on public.mygig_einvoice_requests (driver_id);
create index if not exists mygig_einvoice_requested_by_idx on public.mygig_einvoice_requests (requested_by);
create index if not exists mygig_einvoice_handled_by_idx on public.mygig_einvoice_requests (handled_by);

-- Part B follow-up: the late-cancel fee on a booking, and its history.
alter table public.mygig_bookings add column if not exists cancel_fee numeric(10,2) not null default 0;
alter table public.mygig_bookings add column if not exists cancel_fee_status text not null default 'none';
alter table public.mygig_bookings drop constraint if exists mygig_bookings_cancel_fee_status;
alter table public.mygig_bookings add constraint mygig_bookings_cancel_fee_status
  check (cancel_fee >= 0 and cancel_fee_status in ('none', 'charged', 'due'));
alter table public.mygig_bookings add column if not exists history jsonb not null default '[]'::jsonb;
alter table public.mygig_bookings drop constraint if exists mygig_bookings_history_valid;
alter table public.mygig_bookings add constraint mygig_bookings_history_valid
  check (jsonb_typeof(history) = 'array' and pg_column_size(history) <= 32768);

-- A handover during the trip (0199's row) for a passenger who may not be registered.
alter table public.trip_handovers alter column rider_id drop not null;

-- A tip paid by link on the trip link (0314's tips).
alter table public.ride_tips drop constraint if exists ride_tips_method_check;
alter table public.ride_tips add constraint ride_tips_method_check
  check (method in ('get_wallet', 'get_coin', 'cash', 'link'));

-- ---- Access ------------------------------------------------------------------------------------------
alter table public.mygig_reassigns enable row level security;
alter table public.mygig_after enable row level security;
alter table public.mygig_pay_parts enable row level security;
alter table public.mygig_einvoice_requests enable row level security;
revoke all on public.mygig_reassigns, public.mygig_after, public.mygig_pay_parts, public.mygig_einvoice_requests from anon;
revoke insert, update, delete on public.mygig_reassigns, public.mygig_after, public.mygig_pay_parts,
  public.mygig_einvoice_requests from authenticated;
grant select on public.mygig_reassigns, public.mygig_after, public.mygig_pay_parts, public.mygig_einvoice_requests
  to authenticated;
drop policy if exists "mygig_reassigns parties read" on public.mygig_reassigns;
create policy "mygig_reassigns parties read" on public.mygig_reassigns for select to authenticated
  using (from_driver = (select auth.uid()) or to_driver = (select auth.uid()) or passenger_id = (select auth.uid())
         or (select public.caller_is_admin()));
drop policy if exists "mygig_after driver read" on public.mygig_after;
create policy "mygig_after driver read" on public.mygig_after for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "mygig_pay_parts parties read" on public.mygig_pay_parts;
create policy "mygig_pay_parts parties read" on public.mygig_pay_parts for select to authenticated
  using (exists (select 1 from public.ride_requests r where r.id = mygig_pay_parts.ride_id
                   and (r.partner_id = (select auth.uid()) or r.rider_id = (select auth.uid())))
         or (select public.caller_is_admin()));
drop policy if exists "mygig_einvoice parties read" on public.mygig_einvoice_requests;
create policy "mygig_einvoice parties read" on public.mygig_einvoice_requests for select to authenticated
  using (requested_by = (select auth.uid()) or (select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('rpc:mygig_admin_einvoice_set', 'admin-mygig')
on conflict do nothing;

-- ---- 2. Settings -------------------------------------------------------------------------------------
-- 0330's defaults, with reassign, hotspots, the passenger's extras and the
-- driver's quick trips and regulars.
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
                                      'overtimeMax', 100, 'overnightMax', 200)),
    -- 0331: reassign to another driver.
    'reassign', jsonb_build_object('enabled', true, 'when', 'before', 'answerMin', 10, 'driverAnswerMin', 5,
                                   'noAnswer', 'keep', 'sameOrBigger', true, 'nearKm', 10),
    -- 0331: where passengers wave most.
    'hotspots', jsonb_build_object('enabled', true, 'weeks', 4, 'minCount', 3, 'radiusKm', 15),
    -- 0331: the passenger's extras after the trip.
    'after', jsonb_build_object('tips', true, 'tipMax', 100, 'split', true, 'splitMax', 3, 'einvoice', true,
                                'bookAgain', true, 'appOffer', true),
    -- 0331: the driver's quick trips and regulars.
    'driverExtras', jsonb_build_object('quick', true, 'quickCount', 3, 'regulars', true, 'regularMin', 2));
$$;

-- The Default rule shows the new parts with get.ride's values.
update public.mygig_rules
   set settings = jsonb_build_object('reassign', public.mygig_defaults()->'reassign',
                                     'hotspots', public.mygig_defaults()->'hotspots',
                                     'after', public.mygig_defaults()->'after',
                                     'driverExtras', public.mygig_defaults()->'driverExtras')
                  || settings
 where level = 'default'
   and not (settings ? 'reassign' and settings ? 'hotspots' and settings ? 'after' and settings ? 'driverExtras');

-- 0330's checks, and the new parts'.
create or replace function public.mygig_settings_problem(p jsonb)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  r record;
  h jsonb := coalesce(p->'hire', '{}'::jsonb);
  ra jsonb := coalesce(p->'reassign', '{}'::jsonb);
  hs jsonb := coalesce(p->'hotspots', '{}'::jsonb);
  af jsonb := coalesce(p->'after', '{}'::jsonb);
  dx jsonb := coalesce(p->'driverExtras', '{}'::jsonb);
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
  -- 0331
  if ra ? 'when' and ra->>'when' not in ('scheduled', 'before', 'during') then
    return 'Drivers reassign scheduled bookings only, also before pickup, or also during the trip.';
  end if;
  if ra ? 'noAnswer' and ra->>'noAnswer' not in ('keep', 'cancel') then
    return 'With no answer, the first driver keeps the ride or it is cancelled with no charge.';
  end if;
  if public.mygig_num(ra->'answerMin', 10) not between 1 and 120
     or public.mygig_num(ra->'driverAnswerMin', 5) not between 1 and 60 then
    return 'The passenger answers within 1 to 120 minutes, the new driver within 1 to 60.';
  end if;
  if public.mygig_num(ra->'nearKm', 10) not between 1 and 100 then
    return 'Nearby drivers are within 1 to 100 km.';
  end if;
  if public.mygig_num(hs->'weeks', 4) not between 1 and 52 or public.mygig_num(hs->'minCount', 3) not between 1 and 1000
     or public.mygig_num(hs->'radiusKm', 15) not between 1 and 100 then
    return 'Hotspots count 1 to 52 weeks, show areas from 1 to 1000 rides, within 1 to 100 km.';
  end if;
  if public.mygig_num(af->'splitMax', 3) not between 2 and 3 then
    return 'A fare is split between 2 or 3 people.';
  end if;
  if public.mygig_num(af->'tipMax', 100) not between 1 and 1000 then
    return 'The most tip is RM1 to RM1000.';
  end if;
  if public.mygig_num(dx->'quickCount', 3) not between 1 and 6 or public.mygig_num(dx->'regularMin', 2) not between 1 and 50 then
    return 'Quick trips show 1 to 6 places; a regular has 1 to 50 rides.';
  end if;
  return null;
end;
$$;

-- ---- 3. Helpers --------------------------------------------------------------------------------------
-- How big a driver's car is, from the vehicle in use (or the partner's):
-- {size 0 bike .. 6 bus, seats, bags, type}. Unknown counts as a sedan.
create or replace function public.mygig_vehicle_fit(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select lower(coalesce(
      (select v.vehicle_type from public.vehicle_active_session s join public.vehicle v on v.id = s.vehicle_id
        where s.user_id = p_uid limit 1),
      (select p.vehicle_type from public.partners p where p.auth_user_id = p_uid order by p.updated_at desc limit 1),
      '')) as ty
  )
  select case
    when ty in ('bicycle', 'bike', 'scooter', 'motorcycle') then jsonb_build_object('size', 0, 'seats', 1, 'bags', 0)
    when ty in ('auto rickshaw') then jsonb_build_object('size', 1, 'seats', 3, 'bags', 1)
    when ty in ('kei car', 'hatchback', 'coupe', 'convertible') then jsonb_build_object('size', 1, 'seats', 4, 'bags', 2)
    when ty in ('suv', 'pickup', 'pick up') then jsonb_build_object('size', 3, 'seats', 4, 'bags', 4)
    when ty in ('mpv') then jsonb_build_object('size', 4, 'seats', 6, 'bags', 5)
    when ty in ('van', 'truck') then jsonb_build_object('size', 5, 'seats', 10, 'bags', 8)
    when ty in ('bus') then jsonb_build_object('size', 6, 'seats', 30, 'bags', 20)
    else jsonb_build_object('size', 2, 'seats', 4, 'bags', 3) end
    || jsonb_build_object('type', nullif(ty, ''))
    from t;
$$;
revoke execute on function public.mygig_vehicle_fit(uuid) from public, anon, authenticated;

-- A driver as other drivers and the passenger see them: first name, rating, car, plate.
create or replace function public.mygig_driver_public(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.mygig_driver_card(p_uid) || jsonb_build_object(
    'id', p_uid,
    'type', public.mygig_vehicle_fit(p_uid)->>'type',
    'colour', (select v.color from public.vehicle_active_session s join public.vehicle v on v.id = s.vehicle_id
                where s.user_id = p_uid limit 1));
$$;
revoke execute on function public.mygig_driver_public(uuid) from public, anon, authenticated;

-- Appends a step to a ride's or booking's history.
create or replace function public.mygig_history_add(p_ride uuid, p_booking uuid, p_step jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := jsonb_build_object('at', now()) || coalesce(p_step, '{}'::jsonb);
begin
  if p_ride is not null then
    update public.ride_requests
       set mygig = mygig || jsonb_build_object('history',
             (case when jsonb_typeof(mygig->'history') = 'array' then mygig->'history' else '[]'::jsonb end) || v)
     where id = p_ride and mygig is not null;
  end if;
  if p_booking is not null then
    update public.mygig_bookings set history = history || v where id = p_booking;
  end if;
end;
$$;
revoke execute on function public.mygig_history_add(uuid, uuid, jsonb) from public, anon, authenticated;

-- ---- 4. Reassign -------------------------------------------------------------------------------------
-- The settings where a ride or booking is.
create or replace function public.mygig_settings_of(p_ride uuid, p_booking uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select public.mygig_settings_at(r.country, r.state, r.city, r.suburb) from public.ride_requests r where r.id = p_ride),
    (select public.mygig_settings_at(b.quote #>> '{place,country}', b.quote #>> '{place,state}',
                                     b.quote #>> '{place,city}', b.quote #>> '{place,suburb}')
       from public.mygig_bookings b where b.id = p_booking),
    public.mygig_defaults());
$$;
revoke execute on function public.mygig_settings_of(uuid, uuid) from public, anon, authenticated;

-- Why [p_to] can't take it over (null: they can). [p_at] is the pickup;
-- for a booking [p_from_at, p_to_at] is when it runs.
create or replace function public.mygig_reassign_why_not(
  p_to uuid, p_from uuid, p_lat double precision, p_lng double precision, p_pax integer, p_bags integer,
  p_booking boolean, p_from_at timestamptz, p_to_at timestamptz, s jsonb, p_skip_booking uuid default null)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  st jsonb;
  f jsonb := public.mygig_vehicle_fit(p_to);
  me jsonb := public.mygig_vehicle_fit(p_from);
begin
  if p_to is null or p_to = p_from then
    return 'That is you';
  end if;
  st := public.mygig_state(p_to, p_lat, p_lng);
  if st->>'code' in ('NOT_DRIVER', 'TYPE', 'OFF_HERE', 'NOBODY', 'NOT_SELECTED', 'BLOCKED') then
    return 'No myGiG access';
  end if;
  if st->>'code' = 'PASS_NEEDED' then
    return 'No myGiG pass';
  end if;
  if not p_booking then
    if public.partner_busy(p_to) then
      return 'On a ride';
    end if;
    if st->>'code' = 'LIMIT' then
      return 'At today''s myGiG limit';
    end if;
    if not coalesce((st->>'online')::boolean, false) then
      return 'Offline';
    end if;
  elsif exists (select 1 from public.mygig_bookings b
                 where b.driver_id = p_to and b.id is distinct from p_skip_booking
                   and b.status in ('awaiting_payment', 'booked', 'in_progress')
                   and b.first_at < p_to_at + interval '1 hour' and b.last_at > p_from_at - interval '1 hour') then
    return 'Busy then';
  end if;
  if coalesce(p_pax, 1) > (f->>'seats')::int or coalesce(p_bags, 0) > (f->>'bags')::int then
    return 'Too small for this ride';
  end if;
  if public.mygig_bool(s #> '{reassign,sameOrBigger}', true) and (f->>'size')::int < (me->>'size')::int then
    return 'Smaller vehicle';
  end if;
  return null;
end;
$$;
revoke execute on function public.mygig_reassign_why_not(uuid, uuid, double precision, double precision, integer, integer,
  boolean, timestamptz, timestamptz, jsonb, uuid) from public, anon, authenticated;

-- What is being reassigned, as one record: the ride or the booking, with
-- what the eligibility and the views need. Locks the row.
create or replace function public.mygig_reassign_target(p_ride uuid, p_booking uuid, p_driver uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  v_pax int;
  v_bags int;
begin
  if p_ride is not null then
    select * into r from public.ride_requests where id = p_ride and mygig is not null for update;
    if not found or (p_driver is not null and r.partner_id is distinct from p_driver) then
      raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
    end if;
    return jsonb_build_object(
      'kind', 'ride', 'rideId', r.id, 'driver', r.partner_id, 'passenger', r.rider_id, 'status', r.status,
      'lat', r.pickup_lat, 'lng', r.pickup_lng, 'pax', coalesce(r.passengers, 1), 'bags', coalesce(r.luggage, 0),
      'from', now(), 'to', now() + interval '3 hours',
      'way', case when r.rider_id is not null then 'app' else coalesce(nullif(r.mygig->>'way', 'app'), 'here') end,
      'phone', r.mygig->>'phone', 'pay', r.mygig->>'pay', 'total', coalesce((r.mygig #>> '{quote,total}')::numeric, 0),
      'hire', r.mygig->'hire', 'bookingId', r.mygig->>'bookingId');
  end if;
  select * into b from public.mygig_bookings where id = p_booking for update;
  if not found or (p_driver is not null and b.driver_id is distinct from p_driver) then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_pax := coalesce((b.trip->>'pax')::int, 1);
  v_bags := coalesce((b.trip #>> '{bags,small}')::int, 0) + coalesce((b.trip #>> '{bags,medium}')::int, 0)
            + coalesce((b.trip #>> '{bags,large}')::int, 0);
  return jsonb_build_object(
    'kind', 'booking', 'bookingId', b.id, 'driver', b.driver_id, 'passenger', b.rider_id, 'status', b.status,
    'lat', (b.trip #>> '{pickup,lat}')::float8, 'lng', (b.trip #>> '{pickup,lng}')::float8, 'pax', v_pax, 'bags', v_bags,
    'from', coalesce((select min(d.starts_at) from public.mygig_booking_days d
                       where d.booking_id = b.id and d.status = 'scheduled'), b.first_at),
    'to', b.last_at,
    'way', case when b.rider_id is not null then 'app'
                else coalesce((select nullif(o.way, 'app') from public.mygig_offers o where o.id = b.offer_id), 'here') end,
    'phone', b.phone, 'pay', b.pay, 'total', b.price, 'kindName', b.kind);
end;
$$;
revoke execute on function public.mygig_reassign_target(uuid, uuid, uuid) from public, anon, authenticated;

-- May the caller reassign this ride or booking now? Raises the reason.
create or replace function public.mygig_reassign_allowed(t jsonb, s jsonb)
returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  v_when text := coalesce(s #>> '{reassign,when}', 'before');
begin
  if not public.mygig_bool(s #> '{reassign,enabled}', true) then
    raise exception 'MYGIG_REASSIGN_OFF' using errcode = '42501', hint = 'get.ride doesn''t allow reassigning myGiG rides here.';
  end if;
  if t->>'kind' = 'booking' then
    if t->>'status' not in ('awaiting_payment', 'booked', 'in_progress') then
      raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This booking has ended.';
    end if;
    if exists (select 1 from public.mygig_booking_days d join public.ride_requests x on x.id = d.ride_id
                where d.booking_id = (t->>'bookingId')::uuid and d.status = 'released'
                  and x.status in ('accepted', 'arrived', 'on_trip')) then
      raise exception 'MYGIG_REASSIGN_DAY_LIVE' using errcode = '22023',
        hint = 'Today''s ride is on the go: reassign it from its trip screen.';
    end if;
    return true;
  end if;
  if t->>'status' = 'on_trip' then
    if v_when <> 'during' then
      raise exception 'MYGIG_REASSIGN_DURING_OFF' using errcode = '42501',
        hint = 'get.ride doesn''t allow handing a myGiG ride over during the trip.';
    end if;
  elsif t->>'status' in ('accepted', 'arrived') then
    -- A booked day's ride counts as scheduled; a ride now needs "before pickup".
    if v_when = 'scheduled' and t->>'bookingId' is null then
      raise exception 'MYGIG_REASSIGN_SCHEDULED_ONLY' using errcode = '42501',
        hint = 'get.ride allows reassigning scheduled myGiG bookings only.';
    end if;
  else
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This ride has ended.';
  end if;
  return true;
end;
$$;
revoke execute on function public.mygig_reassign_allowed(jsonb, jsonb) from public, anon, authenticated;

-- The reasons a driver picks from.
create or replace function public.mygig_reassign_reasons()
returns jsonb
language sql
immutable
set search_path = ''
as $$ select '["Car problem", "Emergency", "Running late", "Too far away", "Other"]'::jsonb $$;

-- The first driver's choice: the reasons and nearby drivers with myGiG,
-- each with why they can't be chosen.
create or replace function public.mygig_reassign_options(p_ride uuid default null, p_booking uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  t jsonb;
  s jsonb;
  v_near numeric;
  v_lat float8;
  v_lng float8;
  v_booking boolean;
begin
  if v_uid is null or num_nonnulls(p_ride, p_booking) <> 1 then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  t := public.mygig_reassign_target(p_ride, p_booking, v_uid);
  s := public.mygig_settings_of(p_ride, p_booking);
  perform public.mygig_reassign_allowed(t, s);
  v_booking := t->>'kind' = 'booking';
  v_near := public.mygig_num(s #> '{reassign,nearKm}', 10);
  -- Near the pickup for a booking or before pickup; near the car during the trip.
  select coalesce(case when t->>'status' = 'on_trip' then d.lat end, (t->>'lat')::float8),
         coalesce(case when t->>'status' = 'on_trip' then d.lng end, (t->>'lng')::float8)
    into v_lat, v_lng
    from (select 1) x left join public.driver_presence d on d.profile_id = v_uid;
  return jsonb_build_object(
    'reasons', public.mygig_reassign_reasons(),
    'during', t->>'status' = 'on_trip',
    'booking', v_booking,
    'way', t->>'way',
    'answerMin', public.mygig_num(s #> '{reassign,answerMin}', 10),
    'driverAnswerMin', public.mygig_num(s #> '{reassign,driverAnswerMin}', 5),
    'noAnswer', coalesce(s #>> '{reassign,noAnswer}', 'keep'),
    'sameOrBigger', public.mygig_bool(s #> '{reassign,sameOrBigger}', true),
    'nearKm', v_near,
    'drivers', coalesce((
      select jsonb_agg(x order by (x->>'why') is not null, (x->>'km')::numeric)
        from (
          select public.mygig_driver_public(d.profile_id) || jsonb_build_object(
                   'km', round(public.km_between(v_lat, v_lng, d.lat, d.lng)::numeric, 1),
                   'why', public.mygig_reassign_why_not(d.profile_id, v_uid, v_lat, v_lng, (t->>'pax')::int,
                            (t->>'bags')::int, v_booking, (t->>'from')::timestamptz, (t->>'to')::timestamptz, s,
                            p_booking)) as x
            from public.driver_presence d
           where d.online and d.updated_at > now() - interval '15 minutes' and d.profile_id <> v_uid
             and d.lat is not null and v_lat is not null
             and public.km_between(v_lat, v_lng, d.lat, d.lng) <= v_near
             and exists (select 1 from public.partners p where p.auth_user_id = d.profile_id
                          and (p.status = 'approved' or p.status::text like 'permit-%'))
           order by public.km_between(v_lat, v_lng, d.lat, d.lng)
           limit 20) y), '[]'::jsonb));
end;
$$;
revoke execute on function public.mygig_reassign_options(uuid, uuid) from public, anon;
grant execute on function public.mygig_reassign_options(uuid, uuid) to authenticated;

-- A reassign as each side sees it. [p_for]: from | to | passenger | link | admin.
create or replace function public.mygig_reassign_json(x public.mygig_reassigns, p_for text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  s jsonb := public.mygig_settings_of(x.ride_id, x.booking_id);
  v_trip jsonb;
  v_total numeric;
  v_pay text;
  v_paid numeric := 0;
  v_name text;
  v_registered boolean;
  v_pax int;
  v_bags jsonb;
  v_when text;
  v_kind text;
  v_status text;
begin
  if x.ride_id is not null then
    select * into r from public.ride_requests where id = x.ride_id;
    v_trip := jsonb_build_object('pickup', jsonb_build_object('name', r.pickup_name, 'address', r.pickup_address,
                                                              'lat', r.pickup_lat, 'lng', r.pickup_lng),
                                 'drop', jsonb_build_object('name', r.drop_name, 'address', r.drop_address,
                                                            'lat', r.drop_lat, 'lng', r.drop_lng),
                                 'stops', coalesce(r.stops, '[]'::jsonb));
    v_total := coalesce((r.mygig #>> '{quote,total}')::numeric, public.ride_amount_due(r));
    v_pay := r.mygig->>'pay';
    -- What moves: the link's money less the first driver's coming to the pickup.
    v_paid := case when coalesce((r.mygig->>'payTest')::boolean, false) then 0
                   else coalesce((r.mygig->>'linkPaid')::numeric, 0)
                        - case when r.status in ('arrived', 'on_trip') or r.mygig->>'approachCashAt' is not null
                               then least(coalesce((r.mygig->>'linkPaid')::numeric, 0),
                                          coalesce((r.mygig #>> '{quote,approach}')::numeric, 0)) else 0 end end;
    v_name := coalesce(r.mygig->>'shownName', r.rider_name);
    v_registered := r.rider_id is not null;
    v_pax := coalesce(r.passengers, 1);
    v_bags := r.mygig #> '{quote,bags}';
    v_kind := coalesce(r.hire_package, 'trip');
    v_status := r.status;
    v_when := case when r.status = 'on_trip' then 'during' else 'now' end;
  else
    select * into b from public.mygig_bookings where id = x.booking_id;
    v_trip := jsonb_build_object('pickup', (b.trip->'pickup') - 'here', 'drop', b.trip->'drop', 'stops', b.trip->'stops',
                                 'directed', coalesce((b.trip->>'directed')::boolean, false));
    v_total := b.price;
    v_pay := b.pay;
    v_paid := round(b.app_left + b.link_left + b.cash_left, 2);
    v_name := b.passenger_name;
    v_registered := b.rider_id is not null;
    v_pax := coalesce((b.trip->>'pax')::int, 1);
    v_bags := b.trip->'bags';
    v_kind := b.kind;
    v_status := b.status;
    v_when := public.mygig_when_text(coalesce((select min(d.starts_at) from public.mygig_booking_days d
                                                where d.booking_id = b.id and d.status = 'scheduled'), b.first_at), b.timezone);
  end if;
  return jsonb_build_object(
    'id', x.id, 'rideId', x.ride_id, 'bookingId', x.booking_id, 'stage', x.stage, 'reason', x.reason, 'note', x.note,
    'during', x.during, 'way', x.way, 'answerBy', x.answer_by, 'createdAt', x.created_at,
    'answeredVia', x.answered_via, 'moved', x.moved, 'kept', x.kept,
    'noAnswer', coalesce(s #>> '{reassign,noAnswer}', 'keep'),
    'kind', v_kind, 'kindName', public.mygig_kind_label(v_kind), 'when', v_when, 'status', v_status,
    'trip', v_trip, 'pax', v_pax, 'bags', coalesce(v_bags, '{}'::jsonb),
    'total', v_total, 'pay', v_pay, 'paidMoves', greatest(0, v_paid),
    'days', case when b.id is not null then b.days end,
    'daysLeft', case when b.id is not null then (select count(*) from public.mygig_booking_days d
                                                   where d.booking_id = b.id and d.status = 'scheduled') end,
    'from', public.mygig_driver_public(x.from_driver),
    'to', public.mygig_driver_public(x.to_driver))
    || case
         when p_for in ('to', 'from', 'admin') then jsonb_build_object(
           'passenger', case when v_registered then public.mygig_mask_name(v_name, coalesce(s->>'nameMode', 'partial'))
                             else nullif(split_part(btrim(coalesce(v_name, '')), ' ', 1), '') end,
           'registered', v_registered,
           'plan', case when p_for = 'to' then public.mygig_fee_for(x.to_driver) end)
           || case when p_for in ('from', 'admin') then jsonb_build_object('steps', x.steps) else '{}'::jsonb end
         else jsonb_build_object('registered', v_registered) end;
end;
$$;
revoke execute on function public.mygig_reassign_json(public.mygig_reassigns, text) from public, anon, authenticated;

-- Tells the passenger the new driver accepted: in the app, by SMS on a new
-- link, or (WhatsApp, the driver's phone) nothing here: the first driver
-- sends or shows it. {token, link, message} when a link was made.
create or replace function public.mygig_reassign_ask_passenger(x public.mygig_reassigns)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d jsonb := public.mygig_driver_public(x.to_driver);
  v_phone text;
  v_token text;
  v_url text;
  v_text text;
  v_min numeric := public.mygig_num(public.mygig_settings_of(x.ride_id, x.booking_id) #> '{reassign,answerMin}', 10);
begin
  if x.way = 'app' and x.passenger_id is not null then
    perform public.enqueue_notification(x.passenger_id, 'mygig-reassign-' || x.id, 'ride_status', 'critical',
      'Your driver is changing',
      format('Your driver is changing to %s (%s). Please confirm within %s min.', d->>'name', coalesce(d->>'plate', 'plate to come'),
             trim_scale(v_min)),
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'rider'), x.ride_id);
    return '{}'::jsonb;
  end if;
  if x.way not in ('sms', 'whatsapp') then
    return '{}'::jsonb;
  end if;
  v_phone := coalesce((select r.mygig->>'phone' from public.ride_requests r where r.id = x.ride_id),
                      (select b.phone from public.mygig_bookings b where b.id = x.booking_id));
  if v_phone is null then
    return '{}'::jsonb;
  end if;
  v_token := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  update public.mygig_reassigns set token_hash = public.mygig_token_hash(v_token) where id = x.id;
  v_url := public.mygig_link_url(v_token);
  v_text := format('get.ride: your driver has changed to %s (%s). Confirm it here: %s', d->>'name',
                   coalesce(d->>'plate', 'plate to come'), v_url);
  if x.way = 'sms' then
    perform public.mygig_sms(v_phone, v_text);
  end if;
  return jsonb_build_object('token', v_token, 'link', v_url, 'message', v_text, 'phone', v_phone);
end;
$$;
revoke execute on function public.mygig_reassign_ask_passenger(public.mygig_reassigns) from public, anon, authenticated;

-- The first driver asks [p_to] (or the driver with [p_code]) to take it over.
create or replace function public.mygig_reassign_start(p_ride uuid default null, p_booking uuid default null,
                                                       p_to uuid default null, p_code text default null,
                                                       p_reason text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  t jsonb;
  s jsonb;
  v_to uuid := p_to;
  v_why text;
  x public.mygig_reassigns;
  d jsonb;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 60);
begin
  if v_uid is null or num_nonnulls(p_ride, p_booking) <> 1 then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_reason is null then
    raise exception 'MYGIG_REASSIGN_REASON' using errcode = '22023', hint = 'Choose why you are handing it over.';
  end if;
  t := public.mygig_reassign_target(p_ride, p_booking, v_uid);
  s := public.mygig_settings_of(p_ride, p_booking);
  perform public.mygig_reassign_allowed(t, s);
  if exists (select 1 from public.mygig_reassigns
              where (ride_id = p_ride or booking_id = p_booking) and stage in ('driver', 'passenger')) then
    raise exception 'MYGIG_REASSIGN_OPEN' using errcode = '22023', hint = 'This one is already waiting for an answer.';
  end if;
  if v_to is null and nullif(btrim(coalesce(p_code, '')), '') is not null then
    v_to := public.scheduled_partner_by_code(p_code);
  end if;
  if v_to is null then
    raise exception 'MYGIG_REASSIGN_DRIVER' using errcode = '22023', hint = 'Choose the new driver, or enter their code.';
  end if;
  v_why := public.mygig_reassign_why_not(v_to, v_uid, (t->>'lat')::float8, (t->>'lng')::float8, (t->>'pax')::int,
                                         (t->>'bags')::int, t->>'kind' = 'booking', (t->>'from')::timestamptz,
                                         (t->>'to')::timestamptz, s, p_booking);
  if v_why is not null then
    raise exception 'MYGIG_REASSIGN_NOT_ELIGIBLE' using errcode = '22023',
      hint = format('This driver can''t take it: %s.', lower(v_why));
  end if;
  insert into public.mygig_reassigns (ride_id, booking_id, from_driver, to_driver, passenger_id, reason, note, during,
                                      way, answer_by, steps)
  values (p_ride, p_booking, v_uid, v_to, (t->>'passenger')::uuid, v_reason, left(nullif(btrim(coalesce(p_note, '')), ''), 200),
          t->>'status' = 'on_trip', t->>'way',
          now() + make_interval(mins => public.mygig_num(s #> '{reassign,driverAnswerMin}', 5)::int),
          jsonb_build_array(jsonb_build_object('at', now(), 'what', 'asked', 'by', 'driver', 'reason', v_reason,
                                               'to', public.mygig_driver_public(v_to)->>'name')))
  returning * into x;
  perform public.mygig_history_add(p_ride, p_booking, jsonb_build_object('what', 'reassign_asked', 'reassignId', x.id,
    'reason', v_reason, 'from', v_uid, 'to', v_to));
  d := public.mygig_driver_public(v_uid);
  perform public.enqueue_notification(v_to, 'mygig-reassign-offer-' || x.id, 'ride_status', 'critical',
    'Take over a myGiG ride?',
    format('%s wants to hand you a myGiG %s at the agreed price. Tap to see it.', d->>'name',
           case when t->>'kind' = 'booking' then lower(public.mygig_kind_label(t->>'kindName'))
                when t->>'hire' is not null and t->>'hire' <> 'null' then 'hire' else 'ride' end),
    jsonb_build_object('type', 'mygig_reassign_offer', 'reassign_id', x.id, 'role', 'partner'), p_ride);
  return public.mygig_reassign_json(x, 'from');
end;
$$;
revoke execute on function public.mygig_reassign_start(uuid, uuid, uuid, text, text, text) from public, anon;
grant execute on function public.mygig_reassign_start(uuid, uuid, uuid, text, text, text) to authenticated;

-- A reassign as the caller may see it: the first driver, the new one, the
-- passenger (in the app), an admin.
create or replace function public.mygig_reassign_view(p_reassign uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  x public.mygig_reassigns;
  v_me text;
begin
  select * into x from public.mygig_reassigns where id = p_reassign;
  if found and v_uid is not null then
    v_me := case when v_uid = x.to_driver then 'to' when v_uid = x.from_driver then 'from'
                 when v_uid = x.passenger_id then 'passenger'
                 when public.mygig_admin_reader() then 'admin' end;
  end if;
  if v_me is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return public.mygig_reassign_json(x, v_me) || jsonb_build_object('me', v_me);
end;
$$;
revoke execute on function public.mygig_reassign_view(uuid) from public, anon;
grant execute on function public.mygig_reassign_view(uuid) to authenticated;

-- Open reassigns the caller is part of (the new driver's incoming ones, the
-- first driver's, the passenger's to confirm).
create or replace function public.mygig_reassigns_mine()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.mygig_reassign_json(x,
           case when x.to_driver = auth.uid() then 'to' when x.from_driver = auth.uid() then 'from' else 'passenger' end)
           || jsonb_build_object('me', case when x.to_driver = auth.uid() then 'to'
                                            when x.from_driver = auth.uid() then 'from' else 'passenger' end)
           order by x.created_at desc), '[]'::jsonb)
    from public.mygig_reassigns x
   where (x.to_driver = auth.uid() and x.stage = 'driver')
      or (x.from_driver = auth.uid() and x.stage in ('driver', 'passenger'))
      or (x.passenger_id = auth.uid() and x.stage = 'passenger');
$$;
revoke execute on function public.mygig_reassigns_mine() from public, anon;
grant execute on function public.mygig_reassigns_mine() to authenticated;

-- Ends an open reassign with [p_stage], telling who needs to know.
create or replace function public.mygig_reassign_close(x public.mygig_reassigns, p_stage text, p_via text, p_step jsonb)
returns public.mygig_reassigns
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.mygig_reassigns
     set stage = p_stage, answered_at = coalesce(answered_at, now()), answered_via = coalesce(p_via, answered_via),
         steps = steps || (jsonb_build_object('at', now(), 'what', p_stage) || coalesce(p_step, '{}'::jsonb))
   where id = x.id
  returning * into x;
  perform public.mygig_history_add(x.ride_id, x.booking_id,
    jsonb_build_object('what', 'reassign_' || p_stage, 'reassignId', x.id, 'via', p_via) || coalesce(p_step, '{}'::jsonb));
  return x;
end;
$$;
revoke execute on function public.mygig_reassign_close(public.mygig_reassigns, text, text, jsonb) from public, anon, authenticated;

-- The new driver answers. Accepting needs their tick ([p_ack]); then the
-- passenger is asked. {stage, ...the reassign}.
create or replace function public.mygig_reassign_driver_answer(p_reassign uuid, p_accept boolean, p_ack boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  x public.mygig_reassigns;
  t jsonb;
  s jsonb;
  v_why text;
  v_ask jsonb;
  d jsonb;
begin
  select * into x from public.mygig_reassigns where id = p_reassign for update;
  if not found or v_uid is null or x.to_driver <> v_uid then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if x.stage <> 'driver' or x.answer_by <= now() then
    raise exception 'MYGIG_REASSIGN_GONE' using errcode = '22023', hint = 'This request is no longer open.';
  end if;
  d := public.mygig_driver_public(v_uid);
  if not coalesce(p_accept, false) then
    x := public.mygig_reassign_close(x, 'declined', 'app', jsonb_build_object('by', 'new_driver'));
    perform public.enqueue_notification(x.from_driver, 'mygig-reassign-no-' || x.id, 'ride_status', 'critical',
      'Not taken', format('%s can''t take it. The ride is still yours: choose another driver, or carry on.', d->>'name'),
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'request_id', x.ride_id,
                         'booking_id', x.booking_id, 'role', 'partner'), x.ride_id);
    return public.mygig_reassign_json(x, 'to');
  end if;
  if not coalesce(p_ack, false) then
    raise exception 'MYGIG_REASSIGN_ACK' using errcode = '22023', hint = 'Tick that you accept this ride at the agreed price.';
  end if;
  t := public.mygig_reassign_target(x.ride_id, x.booking_id, x.from_driver);
  s := public.mygig_settings_of(x.ride_id, x.booking_id);
  perform public.mygig_reassign_allowed(t, s);
  v_why := public.mygig_reassign_why_not(v_uid, x.from_driver, (t->>'lat')::float8, (t->>'lng')::float8, (t->>'pax')::int,
                                         (t->>'bags')::int, t->>'kind' = 'booking', (t->>'from')::timestamptz,
                                         (t->>'to')::timestamptz, s, x.booking_id);
  if v_why is not null then
    raise exception 'MYGIG_REASSIGN_NOT_ELIGIBLE' using errcode = '22023', hint = format('You can''t take it now: %s.', lower(v_why));
  end if;
  update public.mygig_reassigns
     set stage = 'passenger', driver_answered_at = now(),
         answer_by = now() + make_interval(mins => public.mygig_num(s #> '{reassign,answerMin}', 10)::int),
         steps = steps || jsonb_build_object('at', now(), 'what', 'new_driver_accepted', 'by', 'new_driver', 'ack', true)
   where id = x.id
  returning * into x;
  perform public.mygig_history_add(x.ride_id, x.booking_id,
    jsonb_build_object('what', 'reassign_new_driver_accepted', 'reassignId', x.id, 'ack', true));
  v_ask := public.mygig_reassign_ask_passenger(x);
  perform public.enqueue_notification(x.from_driver, 'mygig-reassign-yes-' || x.id, 'ride_status', 'critical',
    format('%s accepted', d->>'name'),
    case x.way when 'app' then 'Waiting for the passenger to confirm the new driver in their app.'
               when 'sms' then 'The passenger was texted a link to confirm the new driver.'
               when 'whatsapp' then 'Send the passenger the WhatsApp link to confirm the new driver.'
               else 'Show the passenger your phone so they can confirm the new driver.' end,
    jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'request_id', x.ride_id,
                       'booking_id', x.booking_id, 'role', 'partner'), x.ride_id);
  return public.mygig_reassign_json(x, 'to');
end;
$$;
revoke execute on function public.mygig_reassign_driver_answer(uuid, boolean, boolean) from public, anon;
grant execute on function public.mygig_reassign_driver_answer(uuid, boolean, boolean) to authenticated;

-- The first driver: a new link for the passenger (WhatsApp, or SMS again).
create or replace function public.mygig_reassign_resend(p_reassign uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.mygig_reassigns;
begin
  select * into x from public.mygig_reassigns where id = p_reassign for update;
  if not found or x.from_driver is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if x.stage <> 'passenger' then
    raise exception 'MYGIG_REASSIGN_GONE' using errcode = '22023', hint = 'The passenger isn''t being asked now.';
  end if;
  return public.mygig_reassign_ask_passenger(x);
end;
$$;
revoke execute on function public.mygig_reassign_resend(uuid) from public, anon;
grant execute on function public.mygig_reassign_resend(uuid) to authenticated;

-- The first driver stops it, until the passenger confirms.
create or replace function public.mygig_reassign_stop(p_reassign uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.mygig_reassigns;
begin
  select * into x from public.mygig_reassigns where id = p_reassign for update;
  if not found or x.from_driver is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if x.stage not in ('driver', 'passenger') then
    return public.mygig_reassign_json(x, 'from');
  end if;
  x := public.mygig_reassign_close(x, 'stopped', 'app', jsonb_build_object('by', 'driver'));
  perform public.enqueue_notification(x.to_driver, 'mygig-reassign-stop-' || x.id, 'ride_status', 'normal',
    'Request withdrawn', 'The driver no longer needs you to take over.',
    jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
  if x.passenger_id is not null then
    perform public.enqueue_notification(x.passenger_id, 'mygig-reassign-stop-p-' || x.id, 'ride_status', 'normal',
      'Your driver carries on', 'Your driver is keeping your ride. Nothing has changed.',
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'rider'), x.ride_id);
  end if;
  return public.mygig_reassign_json(x, 'from');
end;
$$;
revoke execute on function public.mygig_reassign_stop(uuid) from public, anon;
grant execute on function public.mygig_reassign_stop(uuid) to authenticated;

-- The swap, once the passenger confirmed: the ride or booking is the new
-- driver's, with its money. {moved, kept}.
create or replace function public.mygig_reassign_apply(x public.mygig_reassigns)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  pt public.partners;
  pf public.profiles;
  car jsonb := public.dispatch_driver_car(x.to_driver);
  v_link numeric;
  v_keep numeric := 0;
  v_move numeric := 0;
  v_test boolean;
  v_pct numeric;
  v_lat float8;
  v_lng float8;
  v_fee jsonb := public.mygig_fee_for(x.to_driver);
begin
  select * into pt from public.partners where auth_user_id = x.to_driver order by created_at limit 1;
  select * into pf from public.profiles where id = x.to_driver;
  if x.ride_id is not null then
    select * into r from public.ride_requests where id = x.ride_id for update;
    if r.partner_id is distinct from x.from_driver or r.status not in ('accepted', 'arrived', 'on_trip') then
      raise exception 'MYGIG_REASSIGN_GONE' using errcode = '22023', hint = 'This ride has changed: the driver carries on.';
    end if;
    if public.partner_busy(x.to_driver) then
      raise exception 'MYGIG_REASSIGN_GONE' using errcode = '22023', hint = 'The new driver is on another ride now.';
    end if;
    v_test := coalesce((r.mygig->>'payTest')::boolean, false);
    v_link := coalesce((r.mygig->>'linkPaid')::numeric, 0);
    -- The first driver keeps what they earned coming to the pickup; the
    -- rest of what the link paid them moves to the new driver.
    if r.status in ('arrived', 'on_trip') or r.mygig->>'approachCashAt' is not null then
      v_keep := least(v_link, coalesce((r.mygig #>> '{quote,approach}')::numeric, 0));
    end if;
    v_move := round(greatest(0, v_link - v_keep), 2);
    if v_move > 0 and not v_test then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
        (x.from_driver, 'get_wallet', 'mygig_reassign_out', -v_move, 'mygig',
         'myGiG ride handed over: paid by link, moves to the new driver — ' || public.mygig_money(v_move), r.id),
        (x.to_driver, 'get_wallet', 'mygig_reassign_in', v_move, 'mygig',
         'myGiG ride handed to you: paid by link — ' || public.mygig_money(v_move), r.id);
    end if;
    if x.during then
      -- 0199's swap: the new driver meets the car; the first driver's share
      -- of the trip's net is paid when it completes.
      select coalesce(r.partner_live_lat, d.lat), coalesce(r.partner_live_lng, d.lng) into v_lat, v_lng
        from (select 1) z left join public.driver_presence d on d.profile_id = x.from_driver;
      v_pct := public.trip_handover_share_percent(r.country, r.state, r.city, r.suburb);
      insert into public.trip_handovers (ride_id, rider_id, from_partner_id, to_partner_id, mode, status, note,
                                         share_percent, meet_lat, meet_lng, answer_by, approved_at, accepted_at)
      values (r.id, r.rider_id, x.from_driver, x.to_driver, 'code', 'accepted', left('myGiG: ' || x.reason, 200),
              v_pct, v_lat, v_lng, now(), now(), now());
    end if;
    update public.ride_requests
       set partner_id = x.to_driver,
           partner_name = coalesce(pt.name, pf.name), partner_phone = coalesce(pt.phone, pf.phone),
           partner_photo = coalesce(pt.avatar_url, pf.avatar_url), partner_rating = coalesce(pt.rating, 5),
           partner_plate = car->>'plate', partner_vehicle = car->>'vehicle',
           partner_live_lat = null, partner_live_lng = null, partner_live_heading = null, partner_live_at = null,
           -- Before pickup the new driver still has to come: no waiting clock yet.
           status = case when status = 'arrived' then 'accepted' else status end,
           arrived_at = case when status = 'arrived' then null else arrived_at end,
           waiting_from = case when status = 'arrived' then null else waiting_from end,
           handover_meet_lat = case when x.during then v_lat else handover_meet_lat end,
           handover_meet_lng = case when x.during then v_lng else handover_meet_lng end,
           handed_over_at = case when x.during then now() else handed_over_at end,
           handover_boarded_at = case when x.during then null else handover_boarded_at end,
           mygig = mygig || jsonb_build_object(
             'tripFee', v_fee,
             'reassigned', coalesce(mygig->'reassigned', '[]'::jsonb) || jsonb_build_object(
               'at', now(), 'from', x.from_driver, 'to', x.to_driver, 'moved', v_move, 'kept', v_keep, 'during', x.during))
             || case when v_keep > 0 then jsonb_build_object('reassignKept', coalesce((mygig->>'reassignKept')::numeric, 0) + v_keep,
                                                               'reassignKeptBy', x.from_driver)
                     else '{}'::jsonb end
     where id = r.id;
    -- A booked day's ride: the booking follows it when nothing else is left.
    return jsonb_build_object('moved', v_move, 'kept', v_keep);
  end if;

  select * into b from public.mygig_bookings where id = x.booking_id for update;
  if b.driver_id is distinct from x.from_driver or b.status not in ('awaiting_payment', 'booked', 'in_progress') then
    raise exception 'MYGIG_REASSIGN_GONE' using errcode = '22023', hint = 'This booking has changed: the driver keeps it.';
  end if;
  -- The booking's money is get.ride's until a day is driven; cash the first
  -- driver took moves to the new driver (who is paid it as the days end).
  v_move := round(b.cash_left, 2);
  if v_move > 0 and not b.pay_test then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
      (x.from_driver, 'get_credit', 'mygig_reassign_out', -v_move, 'mygig',
       'myGiG booking handed over: the cash you took moves to the new driver — ' || public.mygig_money(v_move), b.id),
      (x.to_driver, 'get_credit', 'mygig_reassign_in', v_move, 'mygig',
       'myGiG booking handed to you: cash the passenger paid — ' || public.mygig_money(v_move), b.id);
  end if;
  update public.mygig_bookings
     set driver_id = x.to_driver, quote = quote || jsonb_build_object('tripFee', v_fee)
   where id = b.id;
  update public.mygig_booking_days set quote = quote || jsonb_build_object('tripFee', v_fee)
   where booking_id = b.id and status = 'scheduled';
  if b.hire_booking_id is not null then
    update public.hire_bookings set partner_id = x.to_driver, partner_accepted_at = now() where id = b.hire_booking_id;
  end if;
  perform public.mygig_booking_mirror(b.id);
  return jsonb_build_object('moved', v_move, 'kept', 0);
end;
$$;
revoke execute on function public.mygig_reassign_apply(public.mygig_reassigns) from public, anon, authenticated;

-- Cancels what is being reassigned with no charge (the passenger chose it,
-- or nobody answered and the admin's rule cancels): everything back.
create or replace function public.mygig_reassign_cancel_free(x public.mygig_reassigns, p_why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if x.ride_id is not null then
    update public.ride_requests
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'mygig_reassign_cancelled',
           cancel_requested_by = 'system', cancel_fee = 0, cancel_fee_status = 'none'
     where id = x.ride_id and status in ('accepted', 'arrived');
  else
    perform public.mygig_booking_cancel_do(x.booking_id, 'system', p_why, true);
  end if;
end;
$$;
revoke execute on function public.mygig_reassign_cancel_free(public.mygig_reassigns, text) from public, anon, authenticated;

-- The passenger answers: 'confirm' (with their tick [p_ack]), 'keep' the
-- first driver, or 'cancel' with no charge. In the app (signed in), on the
-- trip link ([p_token]: the reassign's link or the trip's own), or on the
-- first driver's phone (signed in as them, when that is the way).
create or replace function public.mygig_reassign_answer(p_reassign uuid default null, p_token text default null,
                                                        p_answer text default 'confirm', p_ack boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  x public.mygig_reassigns;
  v_via text;
  v jsonb;
  d jsonb;
  h text;
  v_wait int;
begin
  if p_token is not null then
    v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
    if v_wait > 0 then
      raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
    end if;
    h := public.mygig_token_hash(p_token);
    select * into x from public.mygig_reassigns m
     where m.stage = 'passenger'
       and (m.token_hash = h
            or m.ride_id in (select o.ride_id from public.mygig_offers o where o.token_hash = h and o.ride_id is not null)
            or m.ride_id in (select rr.id from public.ride_requests rr where rr.mygig->>'tokenHash' = h)
            or m.booking_id in (select o.booking_id from public.mygig_offers o where o.token_hash = h and o.booking_id is not null))
       and (p_reassign is null or m.id = p_reassign)
     order by m.created_at desc limit 1
     for update;
    v_via := 'link';
  else
    select * into x from public.mygig_reassigns where id = p_reassign for update;
    if found and v_uid is not null and v_uid = x.passenger_id then
      v_via := 'app';
    elsif found and v_uid is not null and v_uid = x.from_driver and x.way = 'here' then
      v_via := 'here';
    end if;
  end if;
  if x.id is null or v_via is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if x.stage <> 'passenger' or x.answer_by <= now() then
    raise exception 'MYGIG_REASSIGN_GONE' using errcode = '22023', hint = 'This change is no longer waiting for you.';
  end if;
  d := public.mygig_driver_public(x.to_driver);
  if p_answer = 'confirm' then
    if not coalesce(p_ack, false) then
      raise exception 'MYGIG_REASSIGN_ACK' using errcode = '22023',
        hint = format('Tick that you understand your driver is now %s.', d->>'name');
    end if;
    v := public.mygig_reassign_apply(x);
    update public.mygig_reassigns set moved = (v->>'moved')::numeric, kept = (v->>'kept')::numeric where id = x.id
    returning * into x;
    x := public.mygig_reassign_close(x, 'done', v_via, jsonb_build_object('by', 'passenger', 'ack', true,
                                       'moved', v->'moved', 'kept', v->'kept'));
    perform public.enqueue_notification(x.to_driver, 'mygig-reassign-done-' || x.id, 'ride_status', 'critical',
      'The ride is yours',
      case when x.during then 'The passenger confirmed you. Go to where the car is to take over.'
           when x.booking_id is not null then 'The passenger confirmed you. The booking is in your Scheduled myGiG.'
           else 'The passenger confirmed you. Head to the pickup.' end,
      jsonb_build_object('type', case when x.booking_id is not null then 'mygig_booking' else 'mygig_answer' end,
                         'request_id', x.ride_id, 'booking_id', x.booking_id, 'role', 'partner'), x.ride_id);
    perform public.enqueue_notification(x.from_driver, 'mygig-reassign-done-f-' || x.id, 'ride_status', 'critical',
      'Handed over',
      format('The passenger confirmed %s.%s', d->>'name',
             case when x.kept > 0 then format(' You keep %s for coming to the pickup.', public.mygig_money(x.kept)) else '' end),
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
  elsif p_answer = 'keep' then
    x := public.mygig_reassign_close(x, 'kept', v_via, jsonb_build_object('by', 'passenger'));
    perform public.enqueue_notification(x.from_driver, 'mygig-reassign-kept-' || x.id, 'ride_status', 'critical',
      'The passenger keeps you', 'The passenger wants you to keep the ride. Nothing has changed.',
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'request_id', x.ride_id,
                         'booking_id', x.booking_id, 'role', 'partner'), x.ride_id);
    perform public.enqueue_notification(x.to_driver, 'mygig-reassign-kept-t-' || x.id, 'ride_status', 'normal',
      'Not needed', 'The passenger kept their first driver.',
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
  elsif p_answer = 'cancel' then
    x := public.mygig_reassign_close(x, 'cancelled', v_via, jsonb_build_object('by', 'passenger'));
    perform public.mygig_reassign_cancel_free(x, 'Cancelled when the driver changed');
    perform public.enqueue_notification(x.from_driver, 'mygig-reassign-cancel-' || x.id, 'ride_status', 'critical',
      'Passenger cancelled', 'The passenger cancelled rather than change driver. No charge to them; anything paid goes back.',
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
    perform public.enqueue_notification(x.to_driver, 'mygig-reassign-cancel-t-' || x.id, 'ride_status', 'normal',
      'Not needed', 'The passenger cancelled the ride.',
      jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
  else
    raise exception 'MYGIG_REASSIGN_ANSWER' using errcode = '22023';
  end if;
  return public.mygig_reassign_json(x, 'passenger');
end;
$$;
revoke execute on function public.mygig_reassign_answer(uuid, text, text, boolean) from public;
grant execute on function public.mygig_reassign_answer(uuid, text, text, boolean) to anon, authenticated;

-- No answer in time: the new driver's runs out (back to the first driver);
-- the passenger's follows the admin's rule.
create or replace function public.mygig_reassigns_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.mygig_reassigns;
  s jsonb;
  n integer := 0;
begin
  for x in
    select * from public.mygig_reassigns where stage in ('driver', 'passenger') and answer_by <= now()
     order by answer_by for update skip locked
  loop
    begin
      if x.stage = 'driver' then
        x := public.mygig_reassign_close(x, 'expired', 'timeout', jsonb_build_object('by', 'new_driver'));
        perform public.enqueue_notification(x.from_driver, 'mygig-reassign-lapsed-' || x.id, 'ride_status', 'critical',
          'No answer in time', 'The driver you asked didn''t answer. The ride is still yours.',
          jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'request_id', x.ride_id,
                             'booking_id', x.booking_id, 'role', 'partner'), x.ride_id);
      else
        s := public.mygig_settings_of(x.ride_id, x.booking_id);
        if coalesce(s #>> '{reassign,noAnswer}', 'keep') = 'cancel' then
          x := public.mygig_reassign_close(x, 'cancelled', 'timeout', jsonb_build_object('by', 'rule'));
          perform public.mygig_reassign_cancel_free(x, 'No answer to the change of driver');
          perform public.enqueue_notification(x.from_driver, 'mygig-reassign-lapsed-' || x.id, 'ride_status', 'critical',
            'Cancelled: no answer', 'The passenger didn''t confirm the new driver in time, so the ride is cancelled with no charge.',
            jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
        else
          x := public.mygig_reassign_close(x, 'kept', 'timeout', jsonb_build_object('by', 'rule'));
          perform public.enqueue_notification(x.from_driver, 'mygig-reassign-lapsed-' || x.id, 'ride_status', 'critical',
            'No answer: the ride is still yours', 'The passenger didn''t confirm the new driver in time, so you keep the ride.',
            jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'request_id', x.ride_id,
                               'booking_id', x.booking_id, 'role', 'partner'), x.ride_id);
        end if;
        perform public.enqueue_notification(x.to_driver, 'mygig-reassign-lapsed-t-' || x.id, 'ride_status', 'normal',
          'Not handed over', 'The passenger didn''t confirm in time.',
          jsonb_build_object('type', 'mygig_reassign', 'reassign_id', x.id, 'role', 'partner'));
      end if;
      n := n + 1;
    exception when others then
      raise warning 'mygig_reassigns_tick %: %', x.id, sqlerrm;
    end;
  end loop;
  return n;
end;
$$;
revoke execute on function public.mygig_reassigns_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'mygig-reassigns';
    perform cron.schedule('mygig-reassigns', '* * * * *', $job$select public.mygig_reassigns_tick()$job$);
  end if;
end $$;

-- 0330's cancel settle, with a reassigned ride: the refund comes from
-- whoever holds what the link paid (the first driver kept their coming to
-- the pickup; the new driver holds the rest).
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
  v_first numeric := 0;
  v_passenger boolean := coalesce(new.cancel_reason, '') in ('passenger_no_show', 'passenger_cancelled')
                         or new.cancel_requested_by = 'rider';
  a jsonb := coalesce(new.mygig->'alloc', '{}'::jsonb);
  a_cash numeric := coalesce((a->>'cash')::numeric, 0);
  a_link numeric := coalesce((a->>'link')::numeric, 0);
  a_app numeric := coalesce((a->>'app')::numeric, 0);
  v_kept_first numeric := coalesce((new.mygig->>'reassignKept')::numeric, 0);
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
  -- 0331: the new driver holds the link's money less what the first one kept.
  if v_kept_first > 0 and new.mygig->>'reassignKeptBy' is not null then
    v_first := round(greatest(0, v_refund - greatest(0, v_link - v_kept_first)), 2);
  end if;
  update public.ride_requests
     set mygig = mygig || jsonb_build_object('refundDue', v_refund, 'kept', v_keep,
                   'approachCashBack', not v_passenger and new.mygig->>'approachCashAt' is not null,
                   'alloc', '{}'::jsonb)
   where id = new.id;
  if v_refund - v_first > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (new.partner_id, 'get_credit', 'mygig_refund', -(v_refund - v_first), 'mygig',
            'myGiG cancelled: paid by link, back to the passenger — ' || public.mygig_money(v_refund - v_first), new.id);
  end if;
  if v_first > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values ((new.mygig->>'reassignKeptBy')::uuid, 'get_credit', 'mygig_refund', -v_first, 'mygig',
            'myGiG you handed over was cancelled: what you kept goes back to the passenger — ' || public.mygig_money(v_first),
            new.id);
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_requests_mygig_cancel_settle() from public, anon, authenticated;

-- ---- 5. Part B follow-up: cancelling a booking, with the late-cancel fee -----------------------------
-- The late-cancel fee from a registered passenger paying in the app, on a
-- booking that took nothing upfront (as part A's rides: their GET.wallet,
-- the host's for Family). 'charged' | 'due' | 'none'.
create or replace function public.mygig_booking_fee_take(b public.mygig_bookings, p_fee numeric)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(p_fee, 0), 2);
begin
  if v_amount <= 0 or b.rider_id is null or b.pay not in ('wallet', 'family') then
    return 'none';
  end if;
  if not public.mygig_app_charge(b.rider_id, b.id, v_amount, 'payment', 'myGiG booking cancelled late, cancellation fee') then
    return 'due';
  end if;
  if not b.pay_test then
    perform public.mygig_payout(b.driver_id, b.id, v_amount, 'cancellation_fee', 'myGiG booking cancelled late');
  end if;
  return 'charged';
end;
$$;
revoke execute on function public.mygig_booking_fee_take(public.mygig_bookings, numeric) from public, anon, authenticated;

-- 0330's cancel, as one function for every caller: [p_by] passenger,
-- driver, admin or system; [p_free] cancels with nothing kept (a change of
-- driver the passenger won't take). 0331: a late cancel of a booking that
-- took nothing upfront charges part A's cancellation fee (registered,
-- paying in the app, after the free-cancel time).
create or replace function public.mygig_booking_cancel_do(p_booking uuid, p_by text, p_reason text, p_free boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.mygig_bookings;
  v_by text := p_by;
  v_started boolean;
  v_keep numeric := 0;
  v_fee numeric := 0;
  v_fee_status text := 'none';
  v jsonb;
  d record;
  r public.ride_requests;
begin
  select * into b from public.mygig_bookings where id = p_booking for update;
  if b.id is null then
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
  if v_by = 'passenger' and not v_started and now() >= b.free_cancel_until and not coalesce(p_free, false) then
    v_keep := b.pay_now;
    -- 0331: nothing paid upfront (charged at the start): part A's fee.
    if b.plan = 'start' and b.pay_now = 0 then
      v_fee := least(coalesce((b.quote #>> '{terms,cancelFee}')::numeric, 0), b.price);
    end if;
  end if;
  update public.mygig_bookings
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = case when v_by = 'system' then 'system' else v_by end,
         cancel_reason = left(coalesce(nullif(btrim(p_reason), ''),
                                       case v_by when 'driver' then 'Cancelled by the driver'
                                                 when 'admin' then 'Cancelled by get.ride'
                                                 when 'system' then 'Cancelled' else 'Cancelled by the passenger' end), 200),
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
                                                          when 'admin' then 'cancelled by get.ride'
                                                          when 'system' then 'cancelled, no charge' else 'cancelled' end);
  if v_fee > 0 then
    select * into b from public.mygig_bookings where id = b.id;
    v_fee_status := public.mygig_booking_fee_take(b, v_fee);
    update public.mygig_bookings set cancel_fee = case when v_fee_status = 'none' then 0 else v_fee end,
                                     cancel_fee_status = v_fee_status
     where id = b.id;
  end if;
  update public.payment_intents set status = 'cancelled', failure = 'cancelled'
   where purpose = 'ride_card' and purpose_ref = b.id::text and status = 'pending';
  select * into b from public.mygig_bookings where id = b.id;
  perform public.mygig_booking_mirror(b.id);
  perform public.mygig_history_add(null, b.id, jsonb_build_object('what', 'cancelled', 'by', v_by,
    'fee', case when v_fee_status = 'none' then 0 else v_fee end, 'feeStatus', v_fee_status));
  if v_by <> 'driver' then
    perform public.enqueue_notification(b.driver_id, 'mygig-bk-cancel-' || b.id, 'scheduled_ride', 'critical',
      'Booking cancelled',
      format('The %s on %s was cancelled.%s', lower(public.mygig_kind_label(b.kind)),
             public.mygig_when_text(b.first_at, b.timezone),
             case when (v->>'kept')::numeric > 0 then format(' %s goes to your GET.wallet.', public.mygig_money((v->>'kept')::numeric))
                  when v_fee_status = 'charged' then format(' %s cancellation fee goes to your GET.wallet.', public.mygig_money(v_fee))
                  else '' end),
      jsonb_build_object('type', 'mygig_booking', 'booking_id', b.id, 'role', 'partner'));
  end if;
  if v_by <> 'passenger' then
    perform public.mygig_tell_passenger(b, 'cancel', 'Booking cancelled',
      format('Your myGiG booking on %s was cancelled.%s', public.mygig_when_text(b.first_at, b.timezone),
             case when (v->>'refunded')::numeric > 0 then format(' %s is refunded.', public.mygig_money((v->>'refunded')::numeric))
                  else '' end));
  end if;
  return jsonb_build_object('status', 'cancelled', 'by', v_by,
                            'fee', case when v_fee_status = 'none' then 0 else v_fee end, 'feeStatus', v_fee_status) || v;
end;
$$;
revoke execute on function public.mygig_booking_cancel_do(uuid, text, text, boolean) from public, anon, authenticated;

-- 0330's public cancel: who is asking decides how.
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
begin
  if p_token is not null then
    select x.* into b from public.mygig_bookings x
     where x.id = (select o.booking_id from public.mygig_offers o where o.token_hash = public.mygig_token_hash(p_token));
    v_by := 'passenger';
  else
    select * into b from public.mygig_bookings where id = p_booking;
    if found then
      v_by := case when v_uid is not null and v_uid = b.driver_id then 'driver'
                   when v_uid is not null and v_uid = b.rider_id then 'passenger'
                   when public.caller_admin_can_write('rpc:mygig_booking_cancel') then 'admin' end;
    end if;
  end if;
  if b.id is null or v_by is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return public.mygig_booking_cancel_do(b.id, v_by, p_reason, false);
end;
$$;
revoke execute on function public.mygig_booking_cancel(uuid, text, text) from public;
grant execute on function public.mygig_booking_cancel(uuid, text, text) to anon, authenticated;

-- What the booking card shows a passenger about cancelling late (0330's
-- json, with the fee a late cancel takes when nothing was paid upfront).
create or replace function public.mygig_booking_late_fee(b public.mygig_bookings)
returns numeric
language sql
stable
set search_path = public
as $$
  select case when b.plan = 'start' and b.pay_now = 0 and b.rider_id is not null and b.pay in ('wallet', 'family')
              then least(coalesce((b.quote #>> '{terms,cancelFee}')::numeric, 0), b.price) else 0 end;
$$;
revoke execute on function public.mygig_booking_late_fee(public.mygig_bookings) from public, anon, authenticated;

-- 0330's booking as each side reads it, with the late-cancel fee (0331).
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
    -- 0331: a late cancel of a booking that took nothing upfront takes part A's fee.
    'lateFee', case when now() < b.free_cancel_until or v_done > 0 then 0 else public.mygig_booking_late_fee(b) end,
    'cancelFee', b.cancel_fee, 'cancelFeeStatus', b.cancel_fee_status,
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

-- ---- 6. Hotspots -------------------------------------------------------------------------------------
-- Where myGiG passengers wave most around [p_lat, p_lng], and the busiest
-- hours on this weekday. Counts per area only.
create or replace function public.mygig_hotspots(p_lat double precision, p_lng double precision)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s jsonb;
  v_weeks int;
  v_min int;
  v_km numeric;
  v_tz text;
  v_hour int;
  v_dow int;
  v_areas jsonb;
  v_hours jsonb;
  v_total int;
begin
  if v_uid is null or not exists (select 1 from public.partners p where p.auth_user_id = v_uid
                                   and (p.status = 'approved' or p.status::text like 'permit-%')) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  s := public.mygig_settings_here(p_lat, p_lng);
  if not public.mygig_bool(s #> '{hotspots,enabled}', true) or p_lat is null or p_lng is null then
    return jsonb_build_object('enabled', public.mygig_bool(s #> '{hotspots,enabled}', true) and p_lat is not null,
                              'areas', '[]'::jsonb, 'hours', '[]'::jsonb);
  end if;
  v_weeks := public.mygig_num(s #> '{hotspots,weeks}', 4)::int;
  v_min := public.mygig_num(s #> '{hotspots,minCount}', 3)::int;
  v_km := public.mygig_num(s #> '{hotspots,radiusKm}', 15);
  v_tz := coalesce(nullif(s->>'timezone', ''), 'Asia/Kuala_Lumpur');
  v_hour := extract(hour from now() at time zone v_tz)::int;
  v_dow := extract(isodow from now() at time zone v_tz)::int;
  with rides as (
    select r.pickup_lat as lat, r.pickup_lng as lng, r.suburb, r.city,
           extract(hour from r.created_at at time zone v_tz)::int as h,
           extract(isodow from r.created_at at time zone v_tz)::int as dow
      from public.ride_requests r
     where r.mygig is not null and r.status = 'completed'
       and r.created_at > now() - make_interval(days => v_weeks * 7)
       and r.pickup_lat between p_lat - v_km / 111.0 and p_lat + v_km / 111.0
       and r.pickup_lng between p_lng - v_km / (111.0 * greatest(cos(radians(p_lat)), 0.1))
                            and p_lng + v_km / (111.0 * greatest(cos(radians(p_lat)), 0.1))
       and public.km_between(p_lat, p_lng, r.pickup_lat, r.pickup_lng) <= v_km
  ), cells as (
    select round(lat::numeric, 2) as clat, round(lng::numeric, 2) as clng, count(*) as n,
           count(*) filter (where abs(h - v_hour) <= 1 or abs(h - v_hour) = 23) as now_n,
           mode() within group (order by coalesce(nullif(suburb, ''), nullif(city, ''))) as label
      from rides group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'lat', clat, 'lng', clng, 'name', coalesce(label, 'Area near you'), 'count', n, 'nowCount', now_n,
           'km', round(public.km_between(p_lat, p_lng, clat::float8, clng::float8)::numeric, 1))
           order by n desc), '[]'::jsonb)
    into v_areas
    from (select * from cells where n >= v_min order by n desc limit 10) c;
  select count(*) into v_total from public.ride_requests r
   where r.mygig is not null and r.status = 'completed'
     and r.created_at > now() - make_interval(days => v_weeks * 7)
     and extract(isodow from r.created_at at time zone v_tz)::int = v_dow
     and public.km_between(p_lat, p_lng, r.pickup_lat, r.pickup_lng) <= v_km;
  if v_total >= v_min then
    select jsonb_agg(jsonb_build_object('hour', g.h, 'count', coalesce(c.n, 0)) order by g.h)
      into v_hours
      from generate_series(0, 23) g(h)
      left join (select extract(hour from r.created_at at time zone v_tz)::int as h, count(*) as n
                   from public.ride_requests r
                  where r.mygig is not null and r.status = 'completed'
                    and r.created_at > now() - make_interval(days => v_weeks * 7)
                    and extract(isodow from r.created_at at time zone v_tz)::int = v_dow
                    and public.km_between(p_lat, p_lng, r.pickup_lat, r.pickup_lng) <= v_km
                  group by 1) c on c.h = g.h;
  end if;
  return jsonb_build_object('enabled', true, 'weeks', v_weeks, 'minCount', v_min, 'radiusKm', v_km,
                            'hourNow', v_hour, 'areas', v_areas, 'hours', coalesce(v_hours, '[]'::jsonb));
end;
$$;
revoke execute on function public.mygig_hotspots(double precision, double precision) from public, anon;
grant execute on function public.mygig_hotspots(double precision, double precision) to authenticated;

-- ---- 7. Quick trips and regulars ---------------------------------------------------------------------
-- The driver's most used myGiG drop-offs (the last 90 days).
create or replace function public.mygig_quick_trips()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  s := public.mygig_settings_here((select lat from public.driver_presence where profile_id = v_uid),
                                  (select lng from public.driver_presence where profile_id = v_uid));
  if not public.mygig_bool(s #> '{driverExtras,quick}', true) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', name, 'address', address, 'lat', lat, 'lng', lng, 'trips', n)
                     order by n desc, name)
      from (select (array_agg(r.drop_name order by r.created_at desc))[1] as name,
                   (array_agg(r.drop_address order by r.created_at desc))[1] as address,
                   round(avg(r.drop_lat)::numeric, 6)::float8 as lat, round(avg(r.drop_lng)::numeric, 6)::float8 as lng,
                   count(*) as n
              from public.ride_requests r
             where r.partner_id = v_uid and r.mygig is not null and r.status = 'completed'
               and r.created_at > now() - interval '90 days'
               and r.drop_lat is not null and r.drop_name is not null
             group by round(r.drop_lat::numeric, 3), round(r.drop_lng::numeric, 3)
             having count(*) >= 2
             order by count(*) desc
             limit public.mygig_num(s #> '{driverExtras,quickCount}', 3)::int) q), '[]'::jsonb);
end;
$$;
revoke execute on function public.mygig_quick_trips() from public, anon;
grant execute on function public.mygig_quick_trips() to authenticated;

-- A number that rode with this driver before: their usual drop-off.
create or replace function public.mygig_regular(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_digits text := public.mygig_phone_digits(p_phone);
  s jsonb;
  v jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_digits is null then
    return null;
  end if;
  s := public.mygig_settings_here((select lat from public.driver_presence where profile_id = v_uid),
                                  (select lng from public.driver_presence where profile_id = v_uid));
  if not public.mygig_bool(s #> '{driverExtras,regulars}', true) then
    return null;
  end if;
  select jsonb_build_object('trips', total, 'drop', jsonb_build_object('name', name, 'address', address, 'lat', lat, 'lng', lng),
                            'times', n)
    into v
    from (select (array_agg(r.drop_name order by r.created_at desc))[1] as name,
                 (array_agg(r.drop_address order by r.created_at desc))[1] as address,
                 round(avg(r.drop_lat)::numeric, 6)::float8 as lat, round(avg(r.drop_lng)::numeric, 6)::float8 as lng,
                 count(*) as n, sum(count(*)) over () as total
            from public.ride_requests r
           where r.partner_id = v_uid and r.mygig is not null and r.status = 'completed'
             and public.mygig_phone_digits(r.mygig->>'phone') = v_digits
             and r.drop_lat is not null and r.drop_name is not null
           group by round(r.drop_lat::numeric, 3), round(r.drop_lng::numeric, 3)
           order by count(*) desc
           limit 1) q
   where total >= public.mygig_num(s #> '{driverExtras,regularMin}', 2);
  return v;
end;
$$;
revoke execute on function public.mygig_regular(text) from public, anon;
grant execute on function public.mygig_regular(text) to authenticated;

-- ---- 8. After the trip -------------------------------------------------------------------------------
-- The ride the caller may act on after the trip: the passenger in the app
-- ([p_ride]) or on the trip link ([p_token]). Locks it.
create or replace function public.mygig_after_ride(p_ride uuid, p_token text)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  h text;
  v_wait int;
begin
  if p_token is not null then
    v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
    if v_wait > 0 then
      raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
    end if;
    h := public.mygig_token_hash(p_token);
    select x.* into r from public.ride_requests x
     where x.mygig is not null
       and (x.id in (select o.ride_id from public.mygig_offers o where o.token_hash = h and o.ride_id is not null)
            or x.mygig->>'tokenHash' = h
            or x.id in (select m.ride_id from public.mygig_reassigns m where m.token_hash = h)
            or x.id in (select d.ride_id from public.mygig_offers o join public.mygig_booking_days d on d.booking_id = o.booking_id
                         where o.token_hash = h and d.ride_id is not null))
     order by x.created_at desc limit 1
     for update;
  else
    select * into r from public.ride_requests where id = p_ride and mygig is not null for update;
    if r.id is not null and (auth.uid() is null or r.rider_id is distinct from auth.uid()) then
      r := null;
    end if;
  end if;
  if r.id is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return r;
end;
$$;
revoke execute on function public.mygig_after_ride(uuid, text) from public, anon, authenticated;

-- The app offer for a passenger without the app: the driver's referral code.
create or replace function public.mygig_app_offer(p_driver uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'code', coalesce(nullif(upper(btrim(p.referral_code)), ''), upper(left(replace(p.id::text, '-', ''), 8))),
    'coins', coalesce((select g.referral_referred_coins from public.get_coin_settings g where g.id = 'master'), 0),
    'enabled', coalesce((select g.referral_enabled from public.get_coin_settings g where g.id = 'master'), true),
    'driver', split_part(btrim(coalesce(p.name, 'your driver')), ' ', 1))
    from public.profiles p where p.id = p_driver;
$$;
revoke execute on function public.mygig_app_offer(uuid) from public, anon, authenticated;

-- What the passenger sees after the trip: the receipt and what they may do.
create or replace function public.mygig_after_view(p_ride uuid default null, p_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_after_ride(p_ride, p_token);
  s jsonb := public.mygig_settings_at(r.country, r.state, r.city, r.suburb);
  a public.mygig_after;
  e public.mygig_einvoice_requests;
  v_owed numeric := public.mygig_owed(r);
  v_tip jsonb;
begin
  select * into a from public.mygig_after where ride_id = r.id;
  select * into e from public.mygig_einvoice_requests where ride_id = r.id;
  select jsonb_build_object('amount', t.amount, 'method', t.method) into v_tip
    from public.ride_tips t where t.ride_id = r.id and t.method <> 'cash';
  return jsonb_build_object(
    'rideId', r.id, 'status', r.status, 'inApp', p_token is null, 'registered', r.rider_id is not null,
    'driver', public.mygig_driver_public(r.partner_id),
    'receipt', jsonb_build_object(
      'quote', r.mygig->'quote', 'final', r.mygig->'final', 'total', public.ride_amount_due(r),
      'tolls', coalesce(r.toll_charges, 0), 'other', coalesce(r.other_charges, 0),
      'waiting', coalesce(r.waiting_charge, 0) + coalesce((r.mygig->>'stopWaitCharge')::numeric, 0),
      'pay', r.mygig->>'pay', 'paymentStatus', r.payment_status, 'paidAt', r.paid_at,
      'linkPaid', coalesce((r.mygig->>'linkPaid')::numeric, 0), 'cashPaid', coalesce((r.mygig->>'cashPaid')::numeric, 0),
      'completedAt', r.completed_at, 'pickup', r.pickup_name, 'drop', r.drop_name, 'km', r.distance_km),
    'owed', v_owed,
    'rating', case when a.stars is not null then jsonb_build_object('stars', a.stars, 'comment', a.comment) end,
    'tip', coalesce(v_tip, case when a.cash_tip is not null then jsonb_build_object('amount', a.cash_tip, 'method', 'cash') end),
    'tipPart', (select jsonb_build_object('id', p.id, 'amount', p.amount, 'paid', p.paid_at is not null, 'payUrl', p.pay_url)
                  from public.mygig_pay_parts p where p.ride_id = r.id and p.kind = 'tip' and p.cancelled_at is null
                 order by p.created_at desc limit 1),
    'parts', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'no', p.part_no, 'of', p.parts, 'amount', p.amount,
                                                           'phone', case when p.phone is not null then '•••' || right(p.phone, 4) end,
                                                           'paid', p.paid_at is not null, 'payUrl', p.pay_url)
                                        order by p.part_no)
                         from public.mygig_pay_parts p where p.ride_id = r.id and p.kind = 'share' and p.cancelled_at is null),
                      '[]'::jsonb),
    'einvoice', case when e.id is not null then jsonb_build_object('state', e.state, 'email', e.email, 'at', e.created_at) end,
    'bookAgainAt', a.book_again_at,
    'can', jsonb_build_object(
      'rate', r.status = 'completed' and p_token is not null,
      'tip', r.status = 'completed' and public.mygig_bool(s #> '{after,tips}', true) and v_tip is null and a.cash_tip is null,
      'split', public.mygig_bool(s #> '{after,split}', true) and public.mygig_pays_first(r) and v_owed > 0
               and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
               and not exists (select 1 from public.mygig_pay_parts p where p.ride_id = r.id and p.kind = 'share'
                                and p.cancelled_at is null),
      'einvoice', r.status = 'completed' and public.mygig_bool(s #> '{after,einvoice}', true) and e.id is null,
      'bookAgain', r.status = 'completed' and public.mygig_bool(s #> '{after,bookAgain}', true)),
    'tipMax', public.mygig_num(s #> '{after,tipMax}', 100),
    'tipPresets', jsonb_build_array(2, 5, 10),
    'splitMax', public.mygig_num(s #> '{after,splitMax}', 3),
    'einvoiceSent', false,
    'appOffer', case when r.rider_id is null and public.mygig_bool(s #> '{after,appOffer}', true)
                     then public.mygig_app_offer(r.partner_id) end);
end;
$$;
revoke execute on function public.mygig_after_view(uuid, text) from public;
grant execute on function public.mygig_after_view(uuid, text) to anon, authenticated;

-- The link passenger rates the driver (in the app the app's own rating is used).
create or replace function public.mygig_after_rate(p_token text, p_stars integer, p_comment text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_after_ride(null, p_token);
begin
  if r.status <> 'completed' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Rate the driver once the trip is done.';
  end if;
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'MYGIG_RATING' using errcode = '22023', hint = 'Choose 1 to 5 stars.';
  end if;
  insert into public.mygig_after (ride_id, driver_id, stars, comment, rated_at)
  values (r.id, r.partner_id, p_stars, left(nullif(btrim(coalesce(p_comment, '')), ''), 500), now())
  on conflict (ride_id) do update set stars = excluded.stars, comment = excluded.comment, rated_at = now();
  return jsonb_build_object('stars', p_stars);
end;
$$;
revoke execute on function public.mygig_after_rate(text, integer, text) from public;
grant execute on function public.mygig_after_rate(text, integer, text) to anon, authenticated;

-- A tip. In the app: GET.wallet (0314's ride_tip). On the link: 'link'
-- (a pay part paid by link) or 'cash' (noted for the driver).
create or replace function public.mygig_after_tip(p_ride uuid default null, p_token text default null,
                                                  p_amount numeric default null, p_how text default 'link')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_after_ride(p_ride, p_token);
  s jsonb := public.mygig_settings_at(r.country, r.state, r.city, r.suburb);
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  p public.mygig_pay_parts;
begin
  if r.status <> 'completed' then
    raise exception 'TIP_NOT_COMPLETED' using errcode = '42501', hint = 'You can tip once the trip is complete.';
  end if;
  if not public.mygig_bool(s #> '{after,tips}', true) then
    raise exception 'TIP_OFF' using errcode = '42501', hint = 'Tips aren''t taken here.';
  end if;
  if v_amount <= 0 or v_amount > public.mygig_num(s #> '{after,tipMax}', 100) then
    raise exception 'TIP_AMOUNT' using errcode = '22023',
      hint = format('Tip from RM1 to %s.', public.mygig_money(public.mygig_num(s #> '{after,tipMax}', 100)));
  end if;
  if exists (select 1 from public.ride_tips t where t.ride_id = r.id and t.method <> 'cash')
     or exists (select 1 from public.mygig_after a where a.ride_id = r.id and a.cash_tip is not null) then
    raise exception 'TIP_DONE' using errcode = '22023', hint = 'You already tipped this trip. Thank you!';
  end if;
  if p_token is null then
    -- In the app: GET.wallet, as any ride's tip.
    return public.ride_tip(r.id, v_amount, 'get_wallet');
  end if;
  if p_how = 'cash' then
    insert into public.mygig_after (ride_id, driver_id, cash_tip, cash_tip_at)
    values (r.id, r.partner_id, v_amount, now())
    on conflict (ride_id) do update set cash_tip = excluded.cash_tip, cash_tip_at = now();
    perform public.enqueue_notification(r.partner_id, 'mygig-cash-tip-' || r.id, 'ride_tip', 'normal',
      'A cash tip', format('Your passenger says they''ll tip you %s in cash.', public.mygig_money(v_amount)),
      jsonb_build_object('type', 'ride_tip', 'rideId', r.id), r.id);
    return jsonb_build_object('method', 'cash', 'amount', v_amount);
  end if;
  update public.mygig_pay_parts set cancelled_at = now()
   where ride_id = r.id and kind = 'tip' and paid_at is null and cancelled_at is null;
  insert into public.mygig_pay_parts (ride_id, kind, amount) values (r.id, 'tip', v_amount) returning * into p;
  return jsonb_build_object('method', 'link', 'amount', v_amount, 'partId', p.id);
end;
$$;
revoke execute on function public.mygig_after_tip(uuid, text, numeric, text) from public;
grant execute on function public.mygig_after_tip(uuid, text, numeric, text) to anon, authenticated;

-- Splits what is owed between 2 or 3 people: part 1 is the caller's; the
-- others get a pay link by SMS ([p_phones]). Only while something is owed.
create or replace function public.mygig_split(p_ride uuid default null, p_token text default null,
                                              p_parts integer default 2, p_phones text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_after_ride(p_ride, p_token);
  s jsonb := public.mygig_settings_at(r.country, r.state, r.city, r.suburb);
  v_owed numeric := public.mygig_owed(r);
  v_each numeric;
  v_first numeric;
  v_phone text;
  v_token text;
  p public.mygig_pay_parts;
  v_out jsonb := '[]'::jsonb;
  d jsonb := public.mygig_driver_card(r.partner_id);
  i int;
begin
  if not public.mygig_bool(s #> '{after,split}', true) then
    raise exception 'MYGIG_SPLIT_OFF' using errcode = '42501', hint = 'Splitting the fare isn''t offered here.';
  end if;
  if not public.mygig_pays_first(r) or v_owed <= 0 or r.status not in ('accepted', 'arrived', 'on_trip', 'completed') then
    raise exception 'MYGIG_SPLIT_PAID' using errcode = '22023', hint = 'There''s nothing left to pay, so nothing to split.';
  end if;
  if p_parts is null or p_parts < 2 or p_parts > least(3, public.mygig_num(s #> '{after,splitMax}', 3)::int) then
    raise exception 'MYGIG_SPLIT_PARTS' using errcode = '22023',
      hint = format('Split between 2 and %s people.', least(3, public.mygig_num(s #> '{after,splitMax}', 3)::int));
  end if;
  if coalesce(array_length(p_phones, 1), 0) <> p_parts - 1 then
    raise exception 'MYGIG_SPLIT_PHONES' using errcode = '22023', hint = 'Enter a phone number for each other person.';
  end if;
  if exists (select 1 from public.mygig_pay_parts where ride_id = r.id and kind = 'share' and cancelled_at is null) then
    raise exception 'MYGIG_SPLIT_DONE' using errcode = '22023', hint = 'This fare is already split.';
  end if;
  v_each := floor(v_owed / p_parts * 100) / 100;
  v_first := round(v_owed - v_each * (p_parts - 1), 2);
  insert into public.mygig_pay_parts (ride_id, kind, part_no, parts, amount)
  values (r.id, 'share', 1, p_parts, v_first) returning * into p;
  v_out := v_out || jsonb_build_object('id', p.id, 'no', 1, 'amount', v_first);
  for i in 2 .. p_parts loop
    v_phone := '+' || public.mygig_phone_digits(p_phones[i - 1]);
    if v_phone is null or v_phone !~ '^\+[0-9]{6,16}$' then
      raise exception 'MYGIG_SPLIT_PHONES' using errcode = '22023', hint = 'One of the phone numbers isn''t right.';
    end if;
    v_token := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
    insert into public.mygig_pay_parts (ride_id, kind, part_no, parts, amount, phone, token_hash)
    values (r.id, 'share', i, p_parts, v_each, v_phone, public.mygig_token_hash(v_token)) returning * into p;
    perform public.mygig_sms(v_phone, format('get.ride: your share of a ride with %s is %s. Pay it here: %s',
                                             d->>'name', public.mygig_money(v_each),
                                             'https://getride.my/gig/pay/' || v_token));
    v_out := v_out || jsonb_build_object('id', p.id, 'no', i, 'amount', v_each, 'phone', '•••' || right(v_phone, 4));
  end loop;
  perform public.mygig_history_add(r.id, null, jsonb_build_object('what', 'split', 'parts', p_parts));
  return jsonb_build_object('parts', v_out, 'owed', v_owed);
end;
$$;
revoke execute on function public.mygig_split(uuid, text, integer, text[]) from public;
grant execute on function public.mygig_split(uuid, text, integer, text[]) to anon, authenticated;

-- A share's own page (the link sent to another person).
create or replace function public.mygig_pay_part_view(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.mygig_pay_parts;
  r public.ride_requests;
  v_wait int;
begin
  v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
  end if;
  select * into p from public.mygig_pay_parts where token_hash = public.mygig_token_hash(p_token);
  if not found then
    raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
  end if;
  select * into r from public.ride_requests where id = p.ride_id;
  return jsonb_build_object('id', p.id, 'amount', p.amount, 'no', p.part_no, 'of', p.parts,
                            'paid', p.paid_at is not null, 'cancelled', p.cancelled_at is not null, 'payUrl', p.pay_url,
                            'driver', public.mygig_driver_card(r.partner_id),
                            'pickup', r.pickup_name, 'drop', r.drop_name, 'at', coalesce(r.completed_at, r.created_at),
                            'appOffer', public.mygig_app_offer(r.partner_id));
end;
$$;
revoke execute on function public.mygig_pay_part_view(text) from public;
grant execute on function public.mygig_pay_part_view(text) to anon, authenticated;

-- An e-Invoice request. No e-Invoice connection to LHDN MyInvois exists
-- yet: it is kept for get.ride's team, who send it (the app says so).
create or replace function public.mygig_einvoice_request(p_ride uuid default null, p_token text default null,
                                                         p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_after_ride(p_ride, p_token);
  s jsonb := public.mygig_settings_at(r.country, r.state, r.city, r.suburb);
  e public.mygig_einvoice_requests;
  v_tin text := nullif(upper(regexp_replace(coalesce(p->>'tin', ''), '\s', '', 'g')), '');
  v_type text := nullif(p->>'idType', '');
  v_no text := nullif(btrim(coalesce(p->>'idNo', '')), '');
begin
  if not public.mygig_bool(s #> '{after,einvoice}', true) then
    raise exception 'MYGIG_EINVOICE_OFF' using errcode = '42501', hint = 'e-Invoices aren''t offered here.';
  end if;
  if r.status <> 'completed' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Ask for an e-Invoice once the trip is done.';
  end if;
  if nullif(btrim(coalesce(p->>'name', '')), '') is null then
    raise exception 'MYGIG_EINVOICE' using errcode = '22023', hint = 'Enter the name on the invoice.';
  end if;
  if coalesce(p->>'email', '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'MYGIG_EINVOICE' using errcode = '22023', hint = 'Enter an email address for the e-Invoice.';
  end if;
  if v_tin is null and (v_type is null or v_no is null) then
    raise exception 'MYGIG_EINVOICE' using errcode = '22023', hint = 'Enter your TIN, or your ID or passport number.';
  end if;
  if v_tin is not null and v_tin !~ '^[A-Z0-9]{6,20}$' then
    raise exception 'MYGIG_EINVOICE' using errcode = '22023', hint = 'A TIN is 6 to 20 letters and numbers.';
  end if;
  if v_type is not null and v_type not in ('nric', 'passport', 'brn', 'army') then
    raise exception 'MYGIG_EINVOICE' using errcode = '22023', hint = 'Choose MyKad, passport, business number or army ID.';
  end if;
  insert into public.mygig_einvoice_requests (ride_id, driver_id, requested_by, buyer_name, tin, id_type, id_no, email, amount)
  values (r.id, r.partner_id, auth.uid(), left(btrim(p->>'name'), 120), v_tin, v_type, left(v_no, 30),
          left(lower(btrim(p->>'email')), 200), public.ride_amount_due(r))
  on conflict (ride_id) do nothing
  returning * into e;
  if e.id is null then
    raise exception 'MYGIG_EINVOICE_DONE' using errcode = '22023', hint = 'An e-Invoice was already asked for this trip.';
  end if;
  return jsonb_build_object('state', e.state, 'sent', false,
    'message', 'Saved. get.ride sends it to LHDN MyInvois and emails you the e-Invoice once it is validated.');
end;
$$;
revoke execute on function public.mygig_einvoice_request(uuid, text, jsonb) from public;
grant execute on function public.mygig_einvoice_request(uuid, text, jsonb) to anon, authenticated;

-- "Book <driver> again": a registered passenger gets the driver as a
-- favourite (My Ride); others the app offer with the driver's code.
create or replace function public.mygig_book_again(p_ride uuid default null, p_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_after_ride(p_ride, p_token);
  d jsonb := public.mygig_driver_card(r.partner_id);
begin
  insert into public.mygig_after (ride_id, driver_id, book_again_at) values (r.id, r.partner_id, now())
  on conflict (ride_id) do update set book_again_at = now();
  if p_token is null and r.rider_id is not null and r.rider_id <> r.partner_id then
    insert into public.favourite_drivers (rider_id, driver_id) values (r.rider_id, r.partner_id)
    on conflict (rider_id, driver_id) do nothing;
    return jsonb_build_object('saved', true, 'driver', d->>'name');
  end if;
  return jsonb_build_object('saved', false, 'driver', d->>'name', 'appOffer', public.mygig_app_offer(r.partner_id));
end;
$$;
revoke execute on function public.mygig_book_again(uuid, text) from public;
grant execute on function public.mygig_book_again(uuid, text) to anon, authenticated;

-- ---- 9. Pay by link: shares and tips -----------------------------------------------------------------
-- The trip link (or a share's own link) may ask for a pay link for a part,
-- or for what the ride owes: the payments function checks this as the
-- service role when there is no signed-in driver.
create or replace function public.payment_mygig_link_by_token(p_token text, p_request uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  h text := public.mygig_token_hash(p_token);
  r public.ride_requests;
  p public.mygig_pay_parts;
begin
  if coalesce(p_token, '') = '' or p_request is null or public.payment_gateway_for('ride_card') is null then
    return false;
  end if;
  select * into p from public.mygig_pay_parts where id = p_request;
  if found then
    if p.paid_at is not null or p.cancelled_at is not null then
      return false;
    end if;
    if p.token_hash = h then
      return true;
    end if;
    begin
      r := public.mygig_after_ride(null, p_token);
    exception when others then
      return false;
    end;
    return r.id = p.ride_id and p.token_hash is null;
  end if;
  begin
    r := public.mygig_after_ride(null, p_token);
  exception when others then
    return false;
  end;
  return r.id = p_request and public.mygig_pays_first(r) and public.mygig_owed(r) > 0
     and r.status in ('accepted', 'arrived', 'on_trip', 'completed');
end;
$$;
revoke execute on function public.payment_mygig_link_by_token(text, uuid) from public, anon, authenticated;
grant execute on function public.payment_mygig_link_by_token(text, uuid) to service_role;

-- 0330's: a part's driver may ask for its link too.
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
                      where b.id = p_request and b.driver_id = auth.uid() and public.mygig_booking_link_owed(b) > 0)
          or exists (select 1 from public.mygig_pay_parts p join public.ride_requests r on r.id = p.ride_id
                      where p.id = p_request and p.paid_at is null and p.cancelled_at is null
                        and (r.partner_id = auth.uid() or r.rider_id = auth.uid())))
     and public.payment_gateway_for('ride_card') is not null;
$$;
revoke execute on function public.payment_mygig_link_allowed(uuid) from public, anon;
grant execute on function public.payment_mygig_link_allowed(uuid) to authenticated;

-- 0330's intent, with a part (a share or a tip).
create or replace function public.payment_mygig_intent(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  p public.mygig_pay_parts;
  v public.payment_intents;
  v_gateway uuid;
  v_values jsonb;
  v_total numeric;
  v_user uuid;
  v_name text;
  v_phone text;
begin
  select * into p from public.mygig_pay_parts where id = p_request for update;
  if found then
    if p.paid_at is not null then
      raise exception 'already_paid' using errcode = '22023';
    end if;
    if p.cancelled_at is not null then
      raise exception 'order_closed' using errcode = '22023';
    end if;
    select * into r from public.ride_requests where id = p.ride_id;
    v_total := p.amount;
    v_user := case when p.part_no = 1 then r.rider_id end;
    v_name := case when p.part_no = 1 then r.rider_name end;
    v_phone := coalesce(p.phone, r.mygig->>'phone');
  else
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

-- 0330's: a part's hosted page is kept on it; another person's share is texted to them.
create or replace function public.payment_mygig_link_set(p_request uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  p public.mygig_pay_parts;
begin
  if coalesce(p_url, '') !~ '^https://' then
    raise exception 'unknown_order' using errcode = '22023';
  end if;
  select * into p from public.mygig_pay_parts where id = p_request for update;
  if found then
    update public.mygig_pay_parts set pay_url = p_url where id = p.id;
    return;
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

-- 0330's ride_card hook, with a part: a share is paid like the ride (it
-- counts toward what the ride owes); a tip goes to the driver.
create or replace function public.payment_ride_card_paid(p_intent uuid, p_ride text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.mygig_bookings;
  p public.mygig_pay_parts;
  v public.payment_intents;
  v_ride uuid;
begin
  select * into v from public.payment_intents where id = p_intent;
  if not found or coalesce(p_ride, '') !~* '^[0-9a-f-]{36}$' then
    return;
  end if;
  select * into p from public.mygig_pay_parts where id = p_ride::uuid for update;
  if found then
    if p.intents ? v.id::text then
      return;
    end if;
    update public.mygig_pay_parts
       set intents = intents || to_jsonb(v.id::text), paid_amount = paid_amount + v.amount,
           paid_at = case when paid_amount + v.amount >= amount then coalesce(paid_at, now()) else paid_at end
     where id = p.id
    returning * into p;
    select * into r from public.ride_requests where id = p.ride_id for update;
    if p.kind = 'tip' then
      if not v.test_mode then
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
        values (r.partner_id, 'get_wallet', 'tip', v.amount, 'tip', 'Tip paid by link — ' || public.mygig_money(v.amount), r.id);
      end if;
      insert into public.ride_tips (ride_id, rider_id, partner_id, method, amount, commission_rate, driver_amount, currency)
      values (r.id, r.rider_id, r.partner_id, 'link', v.amount, 0, v.amount, r.currency)
      on conflict do nothing;
      perform public.enqueue_notification(r.partner_id, 'mygig-tip-' || v.id, 'ride_tip', 'normal',
        'You got a tip', format('Your myGiG passenger tipped you %s.', public.mygig_money(v.amount)),
        jsonb_build_object('type', 'ride_tip', 'rideId', r.id), r.id);
      return;
    end if;
    -- A share: as the ride's own link payment.
    if not v.test_mode then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.partner_id, 'get_wallet', 'ride_earning', v.amount, 'gateway',
              format('Ride paid by link (share %s of %s) — %s', p.part_no, p.parts, public.mygig_money(v.amount)), r.id);
    end if;
    update public.ride_requests
       set mygig = mygig || jsonb_build_object(
             'linkPaid', coalesce((mygig->>'linkPaid')::numeric, 0) + v.amount,
             'linkIntents', coalesce(mygig->'linkIntents', '[]'::jsonb) || to_jsonb(v.id::text),
             'linkPaidAt', now(), 'payTest', v.test_mode or coalesce((mygig->>'payTest')::boolean, false))
     where id = r.id
    returning * into r;
    if r.status = 'completed' and public.mygig_owed(r) <= 0 and r.payment_status is distinct from 'paid' then
      update public.ride_requests
         set payment_status = 'paid', paid_method = 'gateway', paid_amount = public.ride_left_to_pay(r), paid_at = now()
       where id = r.id;
    end if;
    perform public.enqueue_notification(r.partner_id, 'mygig-paid-' || v.id, 'ride_status', 'normal',
      'Paid by link', format('A share of %s was paid by link.', public.mygig_money(v.amount)),
      jsonb_build_object('type', 'mygig_answer', 'request_id', r.id, 'role', 'partner'), r.id);
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
  -- Paid in full: shares not yet paid aren't needed any more.
  update public.mygig_pay_parts set cancelled_at = now()
   where ride_id = r.id and kind = 'share' and paid_at is null and cancelled_at is null and public.mygig_owed(r) <= 0;
  perform public.enqueue_notification(r.partner_id, 'mygig-paid-' || v.id, 'ride_status', 'normal',
    'Paid by link', format('The passenger paid %s by link.', public.mygig_money(v.amount)),
    jsonb_build_object('type', 'mygig_answer', 'request_id', r.id, 'role', 'partner'), r.id);
end;
$$;
revoke execute on function public.payment_ride_card_paid(uuid, text) from public, anon, authenticated;

-- ---- 10. The trip link, with a change of driver ------------------------------------------------------
-- 0330's trip link: also opened by a change-of-driver link; shows the
-- driver the ride or booking has now, and the change waiting for the
-- passenger to confirm.
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
  ra public.mygig_reassigns;
  v_wait int;
  q jsonb;
  h text := public.mygig_token_hash(p_token);
  v_driver uuid;
begin
  v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
  end if;
  select * into o from public.mygig_offers where token_hash = h;
  if not found then
    -- A token from an earlier send: the ride it became still answers.
    select * into r from public.ride_requests x where x.mygig->>'tokenHash' = h
     order by x.created_at desc limit 1;
    -- 0331: a change-of-driver link.
    if r.id is null then
      select * into ra from public.mygig_reassigns where token_hash = h;
      if ra.id is not null and ra.ride_id is not null then
        select * into r from public.ride_requests where id = ra.ride_id;
      elsif ra.id is not null then
        select * into o from public.mygig_offers
         where id = (select b2.offer_id from public.mygig_bookings b2 where b2.id = ra.booking_id);
      end if;
    end if;
    if r.id is null and o.id is null then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
    end if;
    if o.id is null then
      select * into o from public.mygig_offers where id = (r.mygig->>'offerId')::uuid;
    end if;
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
  -- 0331: a change of driver waiting for the passenger.
  select * into ra from public.mygig_reassigns x
   where x.stage = 'passenger' and x.answer_by > now()
     and ((r.id is not null and x.ride_id = r.id) or (bk.id is not null and x.booking_id = bk.id))
   order by x.created_at desc limit 1;
  v_driver := coalesce(case when r.id is not null and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
                            then r.partner_id end, bk.driver_id, o.driver_id);
  q := o.quote;
  return jsonb_build_object(
    'status', case when o.status = 'waiting' and o.expires_at <= now() then 'expired' else o.status end,
    'kind', o.kind,
    'name', case when o.passenger_id is null then split_part(coalesce(o.passenger_name, ''), ' ', 1) end,
    'driver', public.mygig_driver_card(v_driver),
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
    'reassign', case when ra.id is not null then public.mygig_reassign_json(ra, 'link') end,
    'ride', case when r.id is not null then jsonb_build_object(
      'id', r.id,
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

-- ---- 11. Admin › myGiG dashboard ---------------------------------------------------------------------
-- Today's myGiG (or [p_day]'s, in Malaysia time): rides, takings, how
-- passengers accepted, no-shows; flagged rides; reassigns; e-Invoice requests.
create or replace function public.mygig_admin_dashboard(p_day date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s jsonb := public.mygig_settings_at('', '', '', '');
  v_tz text := coalesce(nullif(s->>'timezone', ''), 'Asia/Kuala_Lumpur');
  v_day date := coalesce(p_day, (now() at time zone v_tz)::date);
  v_from timestamptz := v_day::timestamp at time zone v_tz;
  v_to timestamptz := (v_day + 1)::timestamp at time zone v_tz;
  v_repeat int := public.mygig_num(s->'repeatFlag', 4)::int;
  v_limit int := public.mygig_num(s->'dailyLimit', 10)::int;
  v_tiles jsonb;
begin
  if not public.mygig_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select jsonb_build_object(
           'rides', count(*) filter (where r.status <> 'cancelled'),
           'completed', count(*) filter (where r.status = 'completed'),
           'cancelled', count(*) filter (where r.status = 'cancelled'),
           'takings', coalesce(sum(public.ride_amount_due(r)) filter (where r.status = 'completed'), 0),
           'noShows', count(*) filter (where r.cancel_reason = 'passenger_no_show'),
           'viaApp', count(*) filter (where r.mygig->>'via' = 'app'),
           'viaLink', count(*) filter (where r.mygig->>'via' = 'link'),
           'viaHere', count(*) filter (where r.mygig->>'via' = 'here'),
           'reassigned', count(*) filter (where jsonb_typeof(r.mygig->'reassigned') = 'array'))
    into v_tiles
    from public.ride_requests r
   where r.mygig is not null and r.created_at >= v_from and r.created_at < v_to;
  return jsonb_build_object(
    'day', v_day, 'timezone', v_tz, 'tiles', v_tiles,
    'flags', jsonb_build_object(
      'priceGuard', coalesce((
        select jsonb_agg(jsonb_build_object('rideId', r.id, 'driver', r.partner_name, 'from', r.pickup_name, 'to', r.drop_name,
                                            'total', (r.mygig #>> '{quote,total}')::numeric,
                                            'appPrice', (r.mygig #>> '{quote,appPrice}')::numeric, 'at', r.created_at)
                         order by r.created_at desc)
          from (select * from public.ride_requests x
                 where x.mygig is not null and coalesce((x.mygig->>'flagged')::boolean, false)
                   and x.created_at > v_to - interval '7 days' and x.created_at < v_to
                 order by x.created_at desc limit 50) r), '[]'::jsonb),
      'repeatNumbers', coalesce((
        select jsonb_agg(jsonb_build_object('phone', phone, 'driver', driver, 'driverId', partner_id, 'rides', n)
                         order by n desc)
          from (select x.mygig->>'phone' as phone, x.partner_id, max(x.partner_name) as driver, count(*) as n
                  from public.ride_requests x
                 where x.mygig is not null and x.mygig->>'phone' is not null
                   and x.created_at > v_to - interval '7 days' and x.created_at < v_to and x.status <> 'cancelled'
                 group by 1, 2
                having count(*) >= greatest(v_repeat, 1)
                 order by count(*) desc limit 50) y), '[]'::jsonb),
      'dailyLimit', case when v_limit > 0 then coalesce((
        select jsonb_agg(jsonb_build_object('driverId', partner_id, 'driver', driver, 'rides', n, 'limit', v_limit)
                         order by n desc)
          from (select x.partner_id, max(x.partner_name) as driver, count(*) as n
                  from public.ride_requests x
                 where x.mygig is not null and x.created_at >= v_from and x.created_at < v_to
                 group by 1
                having count(*) >= v_limit
                 order by count(*) desc limit 50) z), '[]'::jsonb) else '[]'::jsonb end),
    'reassigns', coalesce((
      select jsonb_agg(public.mygig_reassign_json(m, 'admin') order by m.created_at desc)
        from (select * from public.mygig_reassigns order by created_at desc limit 50) m), '[]'::jsonb),
    'einvoices', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'rideId', e.ride_id, 'name', e.buyer_name, 'tin', e.tin,
                                          'idType', e.id_type, 'idNo', e.id_no, 'email', e.email, 'amount', e.amount,
                                          'state', e.state, 'note', e.admin_note, 'at', e.created_at,
                                          'driver', (select x.partner_name from public.ride_requests x where x.id = e.ride_id))
                       order by e.state = 'requested' desc, e.created_at desc)
        from (select * from public.mygig_einvoice_requests order by created_at desc limit 100) e), '[]'::jsonb));
end;
$$;
revoke execute on function public.mygig_admin_dashboard(date) from public, anon;
grant execute on function public.mygig_admin_dashboard(date) to authenticated;

-- myGiG bookings for the admin: later trips and hire by time, filtered.
create or replace function public.mygig_admin_bookings(p_kind text default null, p_status text default null,
                                                       p_search text default null, p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.mygig_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.mygig_booking_json(b, 'driver') || jsonb_build_object(
             'driver', public.mygig_driver_card(b.driver_id), 'driverId', b.driver_id,
             'driverName', (select p.name from public.profiles p where p.id = b.driver_id),
             'cancelFee', b.cancel_fee, 'cancelFeeStatus', b.cancel_fee_status, 'history', b.history,
             'createdAt', b.created_at)
           order by b.first_at desc)
      from (select x.* from public.mygig_bookings x
             where (p_kind is null or p_kind = '' or x.kind = p_kind)
               and (p_status is null or p_status = '' or x.status = p_status
                    or (p_status = 'open' and x.status in ('awaiting_payment', 'booked', 'in_progress')))
               and (q = '' or lower(coalesce(x.passenger_name, '')) like '%' || q || '%'
                    or coalesce(x.phone, '') like '%' || regexp_replace(q, '\D', '', 'g') || '%' and regexp_replace(q, '\D', '', 'g') <> ''
                    or exists (select 1 from public.profiles p where p.id = x.driver_id
                                and lower(coalesce(p.name, '')) like '%' || q || '%'))
             order by x.first_at desc
             limit least(500, greatest(1, coalesce(p_limit, 100)))) b), '[]'::jsonb);
end;
$$;
revoke execute on function public.mygig_admin_bookings(text, text, text, integer) from public, anon;
grant execute on function public.mygig_admin_bookings(text, text, text, integer) to authenticated;

-- The admin marks an e-Invoice request sent (or rejected), with a note.
create or replace function public.mygig_admin_einvoice_set(p_id uuid, p_state text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.mygig_einvoice_requests;
begin
  if not (public.caller_is_admin() or public.caller_admin_can_write('rpc:mygig_admin_einvoice_set')) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_state not in ('requested', 'sent', 'rejected') then
    raise exception 'MYGIG_EINVOICE' using errcode = '22023', hint = 'Sent, rejected or still to send.';
  end if;
  update public.mygig_einvoice_requests
     set state = p_state, admin_note = left(nullif(btrim(coalesce(p_note, '')), ''), 300),
         handled_by = auth.uid(), handled_at = now()
   where id = p_id
  returning * into e;
  if e.id is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', e.id, 'state', e.state);
end;
$$;
revoke execute on function public.mygig_admin_einvoice_set(uuid, text, text) from public, anon;
grant execute on function public.mygig_admin_einvoice_set(uuid, text, text) to authenticated;

-- ---- 12. Followed live by the apps -------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['mygig_reassigns'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
