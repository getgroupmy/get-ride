-- ============================================================================
-- 0332 — myGiG, part D: myGiG Delivery. Someone stops a driver and asks for
-- something to be delivered; the driver enters it, the server prices it,
-- the sender accepts (in their app, on a link, or on the driver's phone)
-- and it is saved as a myGiG ride (ride_requests.mygig, kind 'delivery'),
-- so the live map, God View, SOS, statements, commission, Family and
-- Admin › Rides see it. Same myGiG access, passes, daily limit and charges
-- to drivers as myGiG rides (0329).
--
-- Version 20261030130000 (0332_mygig_delivery). Re-runnable: tables, columns
-- and indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, seed rows only where missing.
--
-- 1. Settings (mygig_rules, by region as parts A to C; a region rule sets
--    the whole `delivery` part or follows the place above):
--    delivery {enabled, vehicles {bike | car | van: {on, base, perKm, min,
--    maxKg}}, sizes {small | medium | large | bulky: {bike, car, van}},
--    extras {medium, large, bulky, freeKg, perKg, fragile, extraDrop},
--    itemTypes[], prohibited[], maxDrops, senderPhone (required |
--    optional), maxValue, protection {fee, free, pct} (the cover), guaranteeFee, waiting
--    {freeMin, perMin, allowanceMin}, returnPct, returnPctMax, ackMin,
--    recipientPays, cod {on, feePct, max}, proof (code | codeOrPhoto |
--    photo), pickupPhotos, allowOwnRates, allowOwnWait, ownLimits {base,
--    perKmMin, perKmMax, minMax, extraMax, waitMax}}. A driver's vehicle is
--    a bike, a car or a van (mygig_delivery_class, from 0331's
--    mygig_vehicle_fit); "A delivery" shows only where its class is on.
-- 2. The driver's Delivery settings (mygig_delivery_prefs, its own row so
--    the ride prefs never drop it): their own rates and waiting when
--    allowed and within the limits, the return charge %, item types they
--    don't take, the longest delivery, COD and recipient pays on or off,
--    the tax line and rounding up (mygig_delivery_save_prefs).
-- 3. mygig_delivery_quote / mygig_delivery_price: the server's price. The
--    vehicle's fare by km, the size extra, weight over the free kg, fragile,
--    each extra drop-off, the cover fee (free cover up to the admin's
--    amount, then a % of the declared value), the region's tax, rounding
--    up; per drop-off the return fare (back to the pickup, the same card,
--    with tax) and the failed-return fee (the driver's return %), and the
--    deposit for a sender without in-app payment.
-- 4. The offer (mygig_offers.delivery): mygig_delivery_create checks the
--    parcel (item type, a size the vehicle carries, weight within the
--    vehicle's most, declared value, photos, the no-prohibited-items tick),
--    the sender (phone checked as myGiG rides; a name when not registered),
--    up to the admin's most drop-offs (each with a recipient's phone and,
--    when not registered, their name) and the payment. It is sent like a
--    myGiG ride (mygig_send, a link getride.my/gig/d/<token>). The sender
--    accepts with mygig_delivery_answer (their tick "no prohibited items,
--    the details are right" is required; the plain ride answers refuse a
--    delivery); accepting makes the ride (mygig_delivery_make).
-- 5. The delivery (mygig_deliveries, mygig_delivery_drops,
--    mygig_delivery_returns; read through the functions): pickup (photos,
--    the item matches, the seal code written on it, the sender's cash
--    before Start delivery; the driver may refuse the item: nothing is
--    charged), Start delivery (each recipient gets the tracking link and
--    their 4-digit delivery code), at each drop-off the recipient pays
--    what is due (cash or link) before the hand-over, proof per the admin
--    (the code, the code or a photo with a name, a photo), waiting, and
--    returns.
-- 6. Returns (each with its payer fixed before the parcel moves):
--    'failed' (nobody there or refused): the sender's, the return % of the
--    return fare, from their in-app account or the deposit (one trip back:
--    the largest failed fee is charged once). 'asked' (the recipient sends
--    it back, at the door or on their link before the delivery ends): the
--    full return fare, paid by who was chosen at the start; the recipient
--    by link, or in cash counted only when BOTH the driver and the
--    recipient confirm; the sender in the app or by link when they
--    acknowledge. Before a return starts: payment secured, the payer's
--    acknowledgement, a photo of the item now and the original sender's
--    acknowledgement; no answer within ackMin: support is told and decides
--    (mygig_admin_delivery_decide). Finished with the sender's return code.
-- No losses to get.ride or the driver (owner's rule; nothing is charged or
-- paid out later to anyone without in-app payment, and no setting makes
-- get.ride or the driver cover anything):
--   * the sender pays before the parcel moves: cash at pickup (before
--     Start delivery), GET.wallet / Family / business, or by link before
--     pickup;
--   * a sender without in-app payment pays a refundable deposit by link
--     when accepting: the most a failed return can cost + a waiting
--     allowance (allowanceMin) + the fare when the recipient is to pay it
--     + the non-refundable guarantee fee (it pays the gateway on the
--     refund). What isn't used is refunded (refund_due) when it ends;
--   * recipient pays is always guaranteed: by the in-app sender, or the
--     deposit holds the fare. Business senders pay themselves;
--   * waiting: added to what the recipient pays at the first drop-off, or
--     the in-app sender's, or the deposit's allowance; when that is used up
--     the driver is told to start the return;
--   * COD only for registered senders (paid into their GET.wallet less the
--     COD fee); the driver's cash COD comes off their GET.credit at once
--     (blocked when GET.credit can't cover it: the recipient pays by link);
--   * cover: the cover fee is a platform line of the ride (0189's platform
--     fees take it back from GET.credit), left out of the commission;
--   * link and in-app money is held by get.ride and paid to the driver
--     when the delivery ends (mygig_delivery_finish); commission and the
--     myGiG fee come off GET.credit as for rides.
-- 7. Pay by link through the payments function's POST /payments/mygig-link
--    (no change there): every amount is a mygig_pay_parts row of kind
--    'delivery' (purpose accept | door | return), which payment_mygig_intent,
--    payment_mygig_link_set and payment_mygig_link_allowed already serve;
--    payment_mygig_link_by_token takes the sender's and recipients' tokens
--    and payment_ride_card_paid applies a paid part (mygig_delivery_paid).
-- 8. The sender's and recipients' page (getride.my/gig/d/<token>, no
--    sign-in): mygig_delivery_link_view and its actions; the sender in the
--    app: mygig_delivery_mine.
-- 9. Admin: the delivery part of myGiG settings, mygig_admin_delivery_stats
--    and mygig_admin_deliveries for the myGiG dashboard (with the Money
--    safety panel), mygig_admin_delivery_decide for returns support decides.
-- 10. Family: a delivery is a myGiG ride (module 'mygig', 0329): the ride's
--    insert trigger runs family_attach_trip; the Family sender's host pays
--    what the sender owes in the app (family_wallet_owner).
-- ============================================================================

-- ---- 1. Tables ---------------------------------------------------------------------------------------
alter table public.mygig_offers add column if not exists delivery jsonb;
alter table public.mygig_offers drop constraint if exists mygig_offers_delivery_valid;
alter table public.mygig_offers add constraint mygig_offers_delivery_valid check (
  delivery is null or (jsonb_typeof(delivery) = 'object' and pg_column_size(delivery) <= 32768));

create table if not exists public.mygig_delivery_prefs (
  driver_id  uuid primary key references public.profiles(id) on delete cascade,
  prefs      jsonb not null default '{}'::jsonb check (jsonb_typeof(prefs) = 'object' and pg_column_size(prefs) <= 8192),
  updated_at timestamptz not null default now()
);

create table if not exists public.mygig_deliveries (
  id              uuid primary key default gen_random_uuid(),
  ride_id         uuid not null unique references public.ride_requests(id) on delete cascade,
  offer_id        uuid references public.mygig_offers(id) on delete set null,
  driver_id       uuid not null references public.profiles(id) on delete cascade,
  sender_id       uuid references public.profiles(id) on delete set null,
  sender_name     text check (sender_name is null or char_length(sender_name) <= 80),
  sender_phone    text check (sender_phone is null or sender_phone ~ '^\+[0-9]{6,16}$'),
  token_hash      text not null,
  vehicle         text not null check (vehicle in ('bike', 'car', 'van')),
  parcel          jsonb not null check (jsonb_typeof(parcel) = 'object' and pg_column_size(parcel) <= 8192),
  payer           text not null check (payer in ('sender', 'recipient')),
  pay             text not null check (pay in ('cash', 'wallet', 'family', 'business', 'link')),
  in_app          boolean not null default false,
  ret_payer       text not null check (ret_payer in ('sender', 'recipient')),
  quote           jsonb not null check (jsonb_typeof(quote) = 'object' and pg_column_size(quote) <= 16384),
  total           numeric(10,2) not null check (total >= 0 and total <= 100000),
  tax             numeric(10,2) not null default 0 check (tax >= 0),
  cover           numeric(10,2) not null default 0 check (cover >= 0),
  cod_amount      numeric(10,2) not null default 0 check (cod_amount >= 0 and cod_amount <= 100000),
  cod_fee         numeric(10,2) not null default 0 check (cod_fee >= 0),
  cod_status      text not null default 'none' check (cod_status in ('none', 'due', 'cash', 'link', 'refused')),
  deposit         numeric(10,2) not null default 0 check (deposit >= 0),
  deposit_parts   jsonb,
  deposit_paid    numeric(10,2) not null default 0 check (deposit_paid >= 0),
  deposit_used    numeric(10,2) not null default 0 check (deposit_used >= 0),
  guarantee_fee   numeric(10,2) not null default 0 check (guarantee_fee >= 0),
  fare_paid_by    text check (fare_paid_by is null or fare_paid_by in
                    ('sender_cash', 'sender_link', 'sender_app', 'business', 'recipient_cash', 'recipient_link',
                     'deposit', 'sender_app_guarantee')),
  cash_driver     numeric(10,2) not null default 0 check (cash_driver >= 0),
  held            numeric(10,2) not null default 0 check (held >= 0),
  wait_amount     numeric(10,2) not null default 0 check (wait_amount >= 0),
  wait_deposit    numeric(10,2) not null default 0 check (wait_deposit >= 0),
  wait_in_app     numeric(10,2) not null default 0 check (wait_in_app >= 0),
  fail_fee        numeric(10,2) not null default 0 check (fail_fee >= 0),
  earned          numeric(10,2) not null default 0 check (earned >= 0),
  paid_out        numeric(10,2) not null default 0 check (paid_out >= 0),
  refund_due      numeric(10,2) not null default 0 check (refund_due >= 0),
  in_app_short    numeric(10,2) not null default 0 check (in_app_short >= 0),
  test            boolean not null default false,
  status          text not null default 'pickup'
                  check (status in ('pickup', 'delivering', 'done', 'refused', 'cancelled')),
  pickup_arrived_at timestamptz,
  pickup_photos   jsonb not null default '[]'::jsonb check (jsonb_typeof(pickup_photos) = 'array'),
  item_matches    boolean not null default false,
  sealed          boolean not null default false,
  sender_cash_at  timestamptz,
  seal_code       text not null,
  return_code     text check (return_code is null or return_code ~ '^[0-9]{4}$'),
  started_at      timestamptz,
  ended_at        timestamptz,
  history         jsonb not null default '[]'::jsonb check (jsonb_typeof(history) = 'array'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists mygig_deliveries_driver_idx on public.mygig_deliveries (driver_id, created_at desc);
create index if not exists mygig_deliveries_sender_idx on public.mygig_deliveries (sender_id, created_at desc)
  where sender_id is not null;
create index if not exists mygig_deliveries_offer_idx on public.mygig_deliveries (offer_id);
create index if not exists mygig_deliveries_open_idx on public.mygig_deliveries (status, created_at)
  where status in ('pickup', 'delivering');
create unique index if not exists mygig_deliveries_token_uidx on public.mygig_deliveries (token_hash);
comment on table public.mygig_deliveries is
  'myGiG delivery (0332): one per delivery ride: the parcel, who pays, the deposit, COD, waiting, returns and the money held for the driver. The server''s; read through the functions.';

create table if not exists public.mygig_delivery_drops (
  id             uuid primary key default gen_random_uuid(),
  delivery_id    uuid not null references public.mygig_deliveries(id) on delete cascade,
  n              integer not null check (n between 1 and 10),
  place          jsonb not null check (jsonb_typeof(place) = 'object'),
  recipient_id   uuid references public.profiles(id) on delete set null,
  recipient_name text check (recipient_name is null or char_length(recipient_name) <= 80),
  phone          text not null check (phone ~ '^\+[0-9]{6,16}$'),
  lookup         text not null default 'none' check (lookup in ('latest', 'old', 'none')),
  token_hash     text,
  code           text not null check (code ~ '^[0-9]{4}$'),
  return_km      numeric(10,2) not null default 0,
  return_fare    numeric(10,2) not null default 0 check (return_fare >= 0),
  fail_fee       numeric(10,2) not null default 0 check (fail_fee >= 0),
  status         text not null default 'waiting'
                 check (status in ('waiting', 'arrived', 'delivered', 'returning', 'returned')),
  due_fare       numeric(10,2) not null default 0 check (due_fare >= 0),
  due_cod        numeric(10,2) not null default 0 check (due_cod >= 0),
  due_wait       numeric(10,2) not null default 0 check (due_wait >= 0),
  paid_how       text check (paid_how is null or paid_how in ('cash', 'link')),
  paid_at        timestamptz,
  arrived_at     timestamptz,
  wait_charge    numeric(10,2) not null default 0 check (wait_charge >= 0),
  wait_to        text check (wait_to is null or wait_to in ('recipient', 'sender_app', 'deposit', 'none')),
  proof          jsonb,
  delivered_at   timestamptz,
  created_at     timestamptz not null default now(),
  unique (delivery_id, n)
);
create unique index if not exists mygig_delivery_drops_token_uidx on public.mygig_delivery_drops (token_hash)
  where token_hash is not null;
create index if not exists mygig_delivery_drops_recipient_idx on public.mygig_delivery_drops (recipient_id)
  where recipient_id is not null;

create table if not exists public.mygig_delivery_returns (
  id                    uuid primary key default gen_random_uuid(),
  delivery_id           uuid not null references public.mygig_deliveries(id) on delete cascade,
  drop_id               uuid not null references public.mygig_delivery_drops(id) on delete cascade,
  kind                  text not null check (kind in ('failed', 'asked')),
  reason                text not null check (char_length(reason) between 1 and 200),
  payer                 text not null check (payer in ('sender', 'recipient')),
  method                text not null check (method in ('app', 'deposit', 'link', 'cash')),
  amount                numeric(10,2) not null check (amount >= 0 and amount <= 100000),
  paid_at               timestamptz,
  payer_ack_at          timestamptz,
  payer_ack_via         text check (payer_ack_via is null or payer_ack_via in ('app', 'link', 'here')),
  driver_cash_at        timestamptz,
  recipient_cash_ack_at timestamptz,
  photo                 text,
  sender_ack_at         timestamptz,
  sender_ack_via        text check (sender_ack_via is null or sender_ack_via in ('app', 'link', 'support')),
  answer_by             timestamptz not null,
  ack_token_hash        text,
  status                text not null default 'waiting' check (status in ('waiting', 'support', 'started', 'done')),
  support_at            timestamptz,
  support_by            uuid references public.profiles(id) on delete set null,
  support_note          text check (support_note is null or char_length(support_note) <= 300),
  started_at            timestamptz,
  done_at               timestamptz,
  created_at            timestamptz not null default now()
);
create unique index if not exists mygig_delivery_returns_drop_uidx on public.mygig_delivery_returns (drop_id);
create index if not exists mygig_delivery_returns_delivery_idx on public.mygig_delivery_returns (delivery_id);
create index if not exists mygig_delivery_returns_due_idx on public.mygig_delivery_returns (answer_by)
  where status = 'waiting' and sender_ack_at is null;
create index if not exists mygig_delivery_returns_support_by_idx on public.mygig_delivery_returns (support_by);
create unique index if not exists mygig_delivery_returns_ack_token_uidx on public.mygig_delivery_returns (ack_token_hash)
  where ack_token_hash is not null;

drop trigger if exists trg_mygig_deliveries_updated_at on public.mygig_deliveries;
create trigger trg_mygig_deliveries_updated_at before update on public.mygig_deliveries
  for each row execute function public.set_updated_at();

-- A delivery's link payments are parts (0331's table): accept (the sender's
-- fare by link and the deposit), door (what a recipient pays at the
-- door), return (a return fare paid by link).
alter table public.mygig_pay_parts drop constraint if exists mygig_pay_parts_kind_check;
alter table public.mygig_pay_parts add constraint mygig_pay_parts_kind_check check (kind in ('share', 'tip', 'delivery'));
alter table public.mygig_pay_parts add column if not exists purpose text;
alter table public.mygig_pay_parts drop constraint if exists mygig_pay_parts_purpose_check;
alter table public.mygig_pay_parts add constraint mygig_pay_parts_purpose_check check (
  (kind = 'delivery') = (purpose is not null) and (purpose is null or purpose in ('accept', 'door', 'return')));
alter table public.mygig_pay_parts add column if not exists delivery_id uuid references public.mygig_deliveries(id) on delete cascade;
alter table public.mygig_pay_parts add column if not exists drop_id uuid references public.mygig_delivery_drops(id) on delete cascade;
alter table public.mygig_pay_parts add column if not exists return_id uuid references public.mygig_delivery_returns(id) on delete cascade;
alter table public.mygig_pay_parts add column if not exists split jsonb;
create index if not exists mygig_pay_parts_delivery_idx on public.mygig_pay_parts (delivery_id) where delivery_id is not null;
create index if not exists mygig_pay_parts_drop_idx on public.mygig_pay_parts (drop_id) where drop_id is not null;
create index if not exists mygig_pay_parts_return_idx on public.mygig_pay_parts (return_id) where return_id is not null;

alter table public.mygig_delivery_prefs enable row level security;
alter table public.mygig_deliveries enable row level security;
alter table public.mygig_delivery_drops enable row level security;
alter table public.mygig_delivery_returns enable row level security;
revoke all on public.mygig_delivery_prefs, public.mygig_deliveries, public.mygig_delivery_drops,
  public.mygig_delivery_returns from anon, authenticated;
grant select on public.mygig_delivery_prefs to authenticated;
-- The rest is read through the functions (codes, tokens and the other side's details stay on the server).
drop policy if exists "mygig_delivery_prefs own read" on public.mygig_delivery_prefs;
create policy "mygig_delivery_prefs own read" on public.mygig_delivery_prefs for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('rpc:mygig_admin_delivery_decide', 'admin-mygig')
on conflict do nothing;

-- ---- 2. Settings -------------------------------------------------------------------------------------
-- 0331's defaults, with myGiG Delivery.
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
    'driverExtras', jsonb_build_object('quick', true, 'quickCount', 3, 'regulars', true, 'regularMin', 2),
    -- 0332: myGiG Delivery.
    'delivery', jsonb_build_object(
      'enabled', true,
      'vehicles', jsonb_build_object(
        'bike', jsonb_build_object('on', true, 'base', 5, 'perKm', 0.8, 'min', 7, 'maxKg', 10),
        'car', jsonb_build_object('on', true, 'base', 6, 'perKm', 1.0, 'min', 9, 'maxKg', 30),
        'van', jsonb_build_object('on', true, 'base', 15, 'perKm', 1.6, 'min', 25, 'maxKg', 300)),
      'sizes', jsonb_build_object(
        'small', jsonb_build_object('bike', true, 'car', true, 'van', true),
        'medium', jsonb_build_object('bike', true, 'car', true, 'van', true),
        'large', jsonb_build_object('bike', false, 'car', true, 'van', true),
        'bulky', jsonb_build_object('bike', false, 'car', false, 'van', true)),
      'extras', jsonb_build_object('medium', 2, 'large', 5, 'bulky', 15, 'freeKg', 5, 'perKg', 0.5, 'fragile', 3,
                                   'extraDrop', 3),
      'itemTypes', jsonb_build_array('Documents', 'Parcel', 'Food', 'Groceries', 'Flowers', 'Electronics', 'Other'),
      'prohibited', jsonb_build_array('Cash or valuables over the limit', 'Weapons and explosives',
                                      'Drugs or medicine without a prescription', 'Live animals',
                                      'Flammable or hazardous goods', 'Anything illegal'),
      'maxDrops', 4,
      'senderPhone', 'required',
      'maxValue', 2000,
      'protection', jsonb_build_object('fee', 0.5, 'free', 300, 'pct', 1),
      'guaranteeFee', 0.5,
      'waiting', jsonb_build_object('freeMin', 5, 'perMin', 0.3, 'allowanceMin', 15),
      'returnPct', 50,
      'returnPctMax', 100,
      'ackMin', 10,
      'recipientPays', true,
      'cod', jsonb_build_object('on', true, 'feePct', 1.5, 'max', 1000),
      'proof', 'code',
      'pickupPhotos', 1,
      'allowOwnRates', true,
      'allowOwnWait', true,
      'ownLimits', jsonb_build_object('base', 20, 'perKmMin', 0.5, 'perKmMax', 3, 'minMax', 50, 'extraMax', 30,
                                      'waitMax', 1)));
$$;


-- The Default rule shows the delivery part with get.ride's values.
update public.mygig_rules
   set settings = jsonb_build_object('delivery', public.mygig_defaults()->'delivery') || settings
 where level = 'default' and not (settings ? 'delivery');

-- Why the delivery part can't be saved, or null.
create or replace function public.mygig_delivery_problem(dl jsonb)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  k text;
  x jsonb;
begin
  if dl ? 'senderPhone' and dl->>'senderPhone' not in ('required', 'optional') then
    return 'The sender''s phone is required or optional.';
  end if;
  if dl ? 'proof' and dl->>'proof' not in ('code', 'codeOrPhoto', 'photo') then
    return 'Proof of delivery is the code, the code or a photo with a name, or a photo.';
  end if;
  if public.mygig_num(dl->'maxDrops', 4) not between 1 and 5 then
    return 'A delivery has 1 to 5 drop-offs.';
  end if;
  if public.mygig_num(dl->'returnPct', 50) > 100 or public.mygig_num(dl->'returnPctMax', 100) > 100
     or public.mygig_num(dl #> '{protection,pct}', 1) > 100 or public.mygig_num(dl #> '{cod,feePct}', 1.5) > 100 then
    return 'Percentages are 0 to 100.';
  end if;
  if public.mygig_num(dl->'ackMin', 10) not between 1 and 240 then
    return 'The sender answers a return within 1 to 240 minutes.';
  end if;
  if public.mygig_num(dl->'pickupPhotos', 1) not between 1 and 6 then
    return 'Take 1 to 6 photos at pickup.';
  end if;
  if public.mygig_num(dl #> '{waiting,allowanceMin}', 15) > 240 then
    return 'The deposit''s waiting allowance is 0 to 240 minutes.';
  end if;
  if public.mygig_num(dl #> '{ownLimits,perKmMin}', 0.5) > public.mygig_num(dl #> '{ownLimits,perKmMax}', 3) then
    return 'The lowest own per km is no more than the highest.';
  end if;
  foreach k in array array['itemTypes', 'prohibited'] loop
    if dl ? k then
      if jsonb_typeof(dl->k) <> 'array' or jsonb_array_length(dl->k) > 40 then
        return 'Item types and prohibited items are lists of up to 40.';
      end if;
      for x in select value from jsonb_array_elements(dl->k) loop
        if jsonb_typeof(x) <> 'string' or char_length(btrim(x #>> '{}')) not between 1 and 80 then
          return 'Each item type or prohibited item is 1 to 80 characters.';
        end if;
      end loop;
    end if;
  end loop;
  if dl ? 'itemTypes' and jsonb_array_length(dl->'itemTypes') = 0 then
    return 'Keep at least one item type.';
  end if;
  return null;
end;
$$;

-- 0331's checks, and the delivery part's (mygig_delivery_problem).
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
  dl jsonb := coalesce(p->'delivery', '{}'::jsonb);
  v_dl text;
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
  -- 0332
  v_dl := public.mygig_delivery_problem(dl);
  if v_dl is not null then
    return v_dl;
  end if;
  return null;
end;
$$;


-- ---- 3. Helpers --------------------------------------------------------------------------------------
-- The delivery part of settings [s].
create or replace function public.mygig_delivery_settings(s jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select public.mygig_merge(public.mygig_defaults()->'delivery', coalesce(s->'delivery', '{}'::jsonb));
$$;

-- A driver's vehicle for deliveries: bike, car or van (from 0331's fit).
create or replace function public.mygig_delivery_class(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when coalesce((f->>'size')::int, 2) = 0 then 'bike'
              when coalesce((f->>'size')::int, 2) >= 5 or f->>'type' in ('pickup', 'pick up') then 'van'
              else 'car' end
    from (select public.mygig_vehicle_fit(p_uid) f) x;
$$;
revoke execute on function public.mygig_delivery_class(uuid) from public, anon, authenticated;

create or replace function public.mygig_delivery_vehicle_name(p_class text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_class when 'bike' then 'Motorbike' when 'van' then 'Van' else 'Car' end;
$$;

-- Deliveries are on here for this vehicle.
create or replace function public.mygig_delivery_offered(ds jsonb, p_class text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select public.mygig_bool(ds->'enabled', true) and public.mygig_bool(ds #> array['vehicles', p_class, 'on'], false);
$$;

-- get.ride's rate card for the vehicle: its fare and the extras.
create or replace function public.mygig_delivery_gcard(ds jsonb, p_class text)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'base', public.mygig_num(ds #> array['vehicles', p_class, 'base'], 6),
    'perKm', public.mygig_num(ds #> array['vehicles', p_class, 'perKm'], 1),
    'min', public.mygig_num(ds #> array['vehicles', p_class, 'min'], 9),
    'medium', public.mygig_num(ds #> '{extras,medium}', 2),
    'large', public.mygig_num(ds #> '{extras,large}', 5),
    'bulky', public.mygig_num(ds #> '{extras,bulky}', 15),
    'freeKg', public.mygig_num(ds #> '{extras,freeKg}', 5),
    'perKg', public.mygig_num(ds #> '{extras,perKg}', 0.5),
    'fragile', public.mygig_num(ds #> '{extras,fragile}', 3),
    'extraDrop', public.mygig_num(ds #> '{extras,extraDrop}', 3));
$$;

-- The driver's Delivery settings, filled with get.ride's values and kept
-- within the admin's limits.
create or replace function public.mygig_delivery_prefs_normalize(p jsonb, ds jsonb, p_class text)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  lim jsonb := coalesce(ds->'ownLimits', '{}'::jsonb);
  g jsonb := public.mygig_delivery_gcard(ds, p_class);
  r jsonb;
  k text;
  rates jsonb;
  v_ex numeric := public.mygig_num(lim->'extraMax', 30);
  v_off jsonb;
begin
  p := coalesce(p, '{}'::jsonb);
  r := coalesce(p->'rates', '{}'::jsonb);
  rates := jsonb_build_object(
    'base', round(least(public.mygig_num(lim->'base', 20), greatest(0, public.mygig_num(r->'base', (g->>'base')::numeric))), 2),
    'perKm', round(least(public.mygig_num(lim->'perKmMax', 3), greatest(public.mygig_num(lim->'perKmMin', 0),
               public.mygig_num(r->'perKm', (g->>'perKm')::numeric))), 2),
    'min', round(least(public.mygig_num(lim->'minMax', 50), greatest(0, public.mygig_num(r->'min', (g->>'min')::numeric))), 2),
    'freeKg', least(1000, greatest(0, round(public.mygig_num(r->'freeKg', (g->>'freeKg')::numeric))))::int);
  foreach k in array array['medium', 'large', 'bulky', 'perKg', 'fragile', 'extraDrop'] loop
    rates := rates || jsonb_build_object(k, round(least(v_ex, greatest(0, public.mygig_num(r->k, (g->>k)::numeric))), 2));
  end loop;
  select coalesce(jsonb_agg(t.value), '[]'::jsonb) into v_off
    from jsonb_array_elements(case when jsonb_typeof(p->'offTypes') = 'array' then p->'offTypes' else '[]'::jsonb end) t
   where jsonb_typeof(t.value) = 'string' and coalesce(ds->'itemTypes', '[]'::jsonb) ? (t.value #>> '{}');
  return jsonb_build_object(
    'own', public.mygig_bool(p->'own', false) and public.mygig_bool(ds->'allowOwnRates', true),
    'rates', rates,
    'waitOwn', public.mygig_bool(p->'waitOwn', false) and public.mygig_bool(ds->'allowOwnWait', true),
    'waitFree', least(60, greatest(0, round(public.mygig_num(p->'waitFree', public.mygig_num(ds #> '{waiting,freeMin}', 5)))))::int,
    'waitPerMin', round(least(public.mygig_num(lim->'waitMax', 1), greatest(0,
                    public.mygig_num(p->'waitPerMin', public.mygig_num(ds #> '{waiting,perMin}', 0.3)))), 2),
    'returnPct', round(least(public.mygig_num(ds->'returnPctMax', 100), greatest(0,
                   public.mygig_num(p->'returnPct', public.mygig_num(ds->'returnPct', 50))))),
    'maxKm', least(500, greatest(1, round(public.mygig_num(p->'maxKm', 25))))::int,
    'offTypes', v_off,
    'takeCod', public.mygig_bool(p->'takeCod', true),
    'takeRecipientPays', public.mygig_bool(p->'takeRecipientPays', true),
    'showTax', public.mygig_bool(p->'showTax', true),
    'roundUp', public.mygig_bool(p->'roundUp', false));
end;
$$;

create or replace function public.mygig_delivery_prefs_of(p_uid uuid, ds jsonb, p_class text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.mygig_delivery_prefs_normalize(
    coalesce((select d.prefs from public.mygig_delivery_prefs d where d.driver_id = p_uid), '{}'::jsonb), ds, p_class);
$$;
revoke execute on function public.mygig_delivery_prefs_of(uuid, jsonb, text) from public, anon, authenticated;

-- The rate card a delivery is priced with: the driver's own when allowed, else get.ride's.
create or replace function public.mygig_delivery_card(ds jsonb, pr jsonb, p_class text)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case when public.mygig_bool(pr->'own', false) and public.mygig_bool(ds->'allowOwnRates', true)
              then (pr->'rates') || jsonb_build_object('own', true)
              else public.mygig_delivery_gcard(ds, p_class) || jsonb_build_object('own', false) end;
$$;

-- The waiting charge at the pickup and the drop-offs.
create or replace function public.mygig_delivery_wait_card(ds jsonb, pr jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case when public.mygig_bool(pr->'waitOwn', false) and public.mygig_bool(ds->'allowOwnWait', true)
              then jsonb_build_object('freeMin', public.mygig_num(pr->'waitFree', 5), 'perMin', public.mygig_num(pr->'waitPerMin', 0.3),
                                      'own', true)
              else jsonb_build_object('freeMin', public.mygig_num(ds #> '{waiting,freeMin}', 5),
                                      'perMin', public.mygig_num(ds #> '{waiting,perMin}', 0.3), 'own', false) end
         || jsonb_build_object('allowanceMin', public.mygig_num(ds #> '{waiting,allowanceMin}', 15));
$$;

-- A 4-digit code.
create or replace function public.mygig_delivery_code()
returns text
language sql
volatile
set search_path = ''
as $$
  select lpad((floor(random() * 10000))::int::text, 4, '0');
$$;

create or replace function public.mygig_delivery_link_url(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'https://getride.my/gig/d/' || p_token;
$$;

create or replace function public.mygig_delivery_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
$$;

-- What the driver's app needs for deliveries: may they, here, with this
-- vehicle; the settings, their Delivery settings and the cards.
create or replace function public.mygig_delivery_config(p_lat double precision default null, p_lng double precision default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  st jsonb;
  ds jsonb;
  v_cls text;
  pr jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  st := public.mygig_state(v_uid, p_lat, p_lng);
  ds := public.mygig_delivery_settings(st->'settings');
  v_cls := public.mygig_delivery_class(v_uid);
  pr := public.mygig_delivery_prefs_of(v_uid, ds, v_cls);
  return (st - 'settings') || jsonb_build_object(
    'settings', ds,
    'vehicle', v_cls, 'vehicleName', public.mygig_delivery_vehicle_name(v_cls),
    'offered', public.mygig_delivery_offered(ds, v_cls),
    'prefs', pr,
    'card', public.mygig_delivery_card(ds, pr, v_cls),
    'gcard', public.mygig_delivery_gcard(ds, v_cls),
    'wait', public.mygig_delivery_wait_card(ds, pr),
    'pricing', (select public.mygig_region_pricing(p->>'country', p->>'state', p->>'city', p->>'suburb')
                  from (select coalesce(public.mygig_place(p_lat, p_lng), '{}'::jsonb) p) x));
end;
$$;
revoke execute on function public.mygig_delivery_config(double precision, double precision) from public, anon;
grant execute on function public.mygig_delivery_config(double precision, double precision) to authenticated;

create or replace function public.mygig_delivery_save_prefs(p_prefs jsonb, p_lat double precision default null,
                                                            p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v jsonb;
  ds jsonb;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(p_prefs) is distinct from 'object' then
    raise exception 'MYGIG_INVALID' using errcode = '22023';
  end if;
  ds := public.mygig_delivery_settings(public.mygig_settings_here(p_lat, p_lng));
  v := public.mygig_delivery_prefs_normalize(p_prefs, ds, public.mygig_delivery_class(v_uid));
  insert into public.mygig_delivery_prefs (driver_id, prefs, updated_at) values (v_uid, v, now())
  on conflict (driver_id) do update set prefs = excluded.prefs, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.mygig_delivery_save_prefs(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_delivery_save_prefs(jsonb, double precision, double precision) to authenticated;

-- ---- 4. The delivery as the driver enters it, and its price ---------------------------------------------
-- The delivery as the app sends it, checked against the settings [ds], the
-- vehicle [p_class] and the driver's [pr]: {parcel {type, size, kg, value,
-- fragile, upright, photos[], noProhibited}, pickup {lat, lng, name,
-- address, here}, drops [{lat, lng, name, address, returnKm, phone,
-- recipient}], km, min, payer, pay, businessId, cod, retPayer, service}.
-- The phones are checked by mygig_delivery_create.
create or replace function public.mygig_delivery_clean(p_uid uuid, p jsonb, s jsonb, ds jsonb, p_class text, pr jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  pc jsonb := coalesce(p->'parcel', '{}'::jsonb);
  v_type text := btrim(coalesce(pc->>'type', ''));
  v_size text := coalesce(pc->>'size', 'small');
  v_kg numeric := round(public.mygig_num(pc->'kg', 1), 1);
  v_value numeric := round(public.mygig_num(pc->'value', 0), 2);
  v_max_kg numeric := public.mygig_num(ds #> array['vehicles', p_class, 'maxKg'], 30);
  v_vname text := lower(public.mygig_delivery_vehicle_name(p_class));
  v_photos jsonb := '[]'::jsonb;
  x jsonb;
  drops jsonb := '[]'::jsonb;
  n int;
  i int;
  t jsonb;
  v_line numeric;
  v_rk numeric;
  v_cod numeric := round(public.mygig_num(p->'cod', 0), 2);
begin
  if v_type = '' or not (coalesce(ds->'itemTypes', '[]'::jsonb) ? v_type) then
    raise exception 'MYGIG_DELIVERY_TYPE' using errcode = '22023', hint = 'Choose what is being sent.';
  end if;
  if coalesce(pr->'offTypes', '[]'::jsonb) ? v_type then
    raise exception 'MYGIG_DELIVERY_TYPE' using errcode = '22023',
      hint = format('You don''t take %s (Delivery settings).', lower(v_type));
  end if;
  if v_size not in ('small', 'medium', 'large', 'bulky') then
    raise exception 'MYGIG_DELIVERY_SIZE' using errcode = '22023', hint = 'Choose the size.';
  end if;
  if not public.mygig_bool(ds #> array['sizes', v_size, p_class], false) then
    raise exception 'MYGIG_DELIVERY_SIZE' using errcode = '22023', hint = format('Your %s can''t carry this size.', v_vname);
  end if;
  if v_kg <= 0 or v_kg > v_max_kg then
    raise exception 'MYGIG_DELIVERY_WEIGHT' using errcode = '22023',
      hint = format('Too heavy for your %s (up to %s kg).', v_vname, trim_scale(v_max_kg));
  end if;
  if v_value < 0 or v_value > public.mygig_num(ds->'maxValue', 2000) then
    raise exception 'MYGIG_DELIVERY_VALUE' using errcode = '22023',
      hint = format('The declared value is over the %s limit.', public.mygig_money(public.mygig_num(ds->'maxValue', 2000)));
  end if;
  if jsonb_typeof(pc->'photos') = 'array' then
    for x in select value from jsonb_array_elements(pc->'photos') loop
      if jsonb_typeof(x) = 'string' and char_length(x #>> '{}') <= 300 and (x #>> '{}') like p_uid::text || '/%' then
        v_photos := v_photos || jsonb_build_array(x);
      end if;
    end loop;
  end if;
  if jsonb_array_length(v_photos) = 0 or jsonb_array_length(v_photos) > 6 then
    raise exception 'MYGIG_DELIVERY_PHOTO' using errcode = '22023', hint = 'Take a photo of the item (up to 6).';
  end if;
  if not public.mygig_bool(pc->'noProhibited', false) then
    raise exception 'MYGIG_DELIVERY_PROHIBITED' using errcode = '22023',
      hint = 'The sender must confirm there are no prohibited items.';
  end if;
  if jsonb_typeof(p->'drops') <> 'array' or jsonb_array_length(p->'drops') = 0 then
    raise exception 'MYGIG_DELIVERY_DROPS' using errcode = '22023', hint = 'Add a drop-off.';
  end if;
  n := jsonb_array_length(p->'drops');
  if n > least(5, public.mygig_num(ds->'maxDrops', 4)) then
    raise exception 'MYGIG_DELIVERY_DROPS' using errcode = '22023',
      hint = format('Up to %s drop-offs.', least(5, public.mygig_num(ds->'maxDrops', 4)::int));
  end if;
  -- The route: the pickup, the drop-offs in order (the last is the ride's drop-off).
  t := public.mygig_trip_clean(jsonb_build_object(
         'pickup', p->'pickup', 'drop', p->'drops'->(n - 1),
         'stops', case when n > 1 then (select jsonb_agg(e.value order by e.ordinality)
                                          from jsonb_array_elements(p->'drops') with ordinality e
                                         where e.ordinality < n) else '[]'::jsonb end,
         'km', p->'km', 'min', p->'min', 'pay', 'cash', 'service', p->>'service'), s);
  if (t->>'km')::numeric > public.mygig_num(pr->'maxKm', 25) then
    raise exception 'MYGIG_TOO_FAR' using errcode = '22023',
      hint = format('Longer than your %s km limit (Delivery settings).', pr->>'maxKm');
  end if;
  for i in 0 .. n - 1 loop
    x := p->'drops'->i;
    v_line := round(public.km_between((x->>'lat')::float8, (x->>'lng')::float8,
                                      (t #>> '{pickup,lat}')::float8, (t #>> '{pickup,lng}')::float8)::numeric, 2);
    v_rk := public.mygig_num(x->'returnKm', v_line * 1.3);
    v_rk := round(least(greatest(v_rk, v_line), greatest(v_line * 5, 1)), 2);
    drops := drops || jsonb_build_array(jsonb_build_object(
      'n', i + 1,
      'place', jsonb_build_object('lat', (x->>'lat')::float8, 'lng', (x->>'lng')::float8,
                                  'name', left(coalesce(nullif(btrim(x->>'name'), ''), 'Drop-off'), 120),
                                  'address', left(nullif(btrim(coalesce(x->>'address', '')), ''), 200)),
      'returnKm', v_rk,
      'phone', x->>'phone',
      'recipient', left(nullif(btrim(coalesce(x->>'recipient', '')), ''), 80)));
  end loop;
  if v_cod < 0 then
    v_cod := 0;
  end if;
  return jsonb_build_object(
    'parcel', jsonb_build_object('type', v_type, 'size', v_size, 'kg', v_kg, 'value', v_value,
                                 'fragile', public.mygig_bool(pc->'fragile', false),
                                 'upright', public.mygig_bool(pc->'upright', false),
                                 'photos', v_photos, 'noProhibited', true),
    'trip', t,
    'drops', drops,
    'payer', case when p->>'payer' = 'recipient' then 'recipient' else 'sender' end,
    'pay', case when p->>'pay' in ('cash', 'wallet', 'link', 'family', 'business') then p->>'pay' else 'cash' end,
    'businessId', case when coalesce(p->>'businessId', '') ~* '^[0-9a-f-]{36}$' then p->>'businessId' end,
    'cod', v_cod,
    'retPayer', case when p->>'retPayer' = 'sender' then 'sender' else 'recipient' end);
end;
$$;
revoke execute on function public.mygig_delivery_clean(uuid, jsonb, jsonb, jsonb, text, jsonb) from public, anon, authenticated;

-- The price of delivery [c] (cleaned): every line, the tax, the total, each
-- drop-off's return fare and failed-return fee, the waiting card, the COD
-- fee and, for a sender without in-app payment ([p_in_app] false), the
-- deposit's parts.
create or replace function public.mygig_delivery_price(c jsonb, ds jsonb, pr jsonb, p_class text, p_place jsonb,
                                                       p_in_app boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  card jsonb := public.mygig_delivery_card(ds, pr, p_class);
  pc jsonb := c->'parcel';
  km numeric := public.mygig_num(c #> '{trip,km}', 0);
  n int := jsonb_array_length(c->'drops');
  v_fare numeric;
  v_size numeric;
  v_kg numeric;
  v_fragile numeric;
  v_extra numeric;
  v_value numeric := public.mygig_num(pc->'value', 0);
  v_free numeric := public.mygig_num(ds #> '{protection,free}', 300);
  v_cover numeric;
  v_sub numeric;
  rp jsonb;
  v_tax numeric := 0;
  v_tax_pct numeric := 0;
  v_exact numeric;
  v_total numeric;
  v_round boolean;
  v_ret_pct numeric := least(public.mygig_num(pr->'returnPct', 50), public.mygig_num(ds->'returnPctMax', 100));
  rets jsonb := '[]'::jsonb;
  x jsonb;
  v_rf numeric;
  v_ff numeric;
  v_max_fail numeric := 0;
  v_max_ret numeric := 0;
  w jsonb := public.mygig_delivery_wait_card(ds, pr);
  dep jsonb;
  v_cod numeric := public.mygig_num(c->'cod', 0);
begin
  v_fare := round(greatest(public.mygig_num(card->'min', 0),
                           public.mygig_num(card->'base', 0) + public.mygig_num(card->'perKm', 0) * km), 2);
  v_size := case when pc->>'size' = 'small' then 0 else round(public.mygig_num(card->(pc->>'size'), 0), 2) end;
  v_kg := round(greatest(0, public.mygig_num(pc->'kg', 0) - public.mygig_num(card->'freeKg', 0)) * public.mygig_num(card->'perKg', 0), 2);
  v_fragile := case when public.mygig_bool(pc->'fragile', false) then round(public.mygig_num(card->'fragile', 0), 2) else 0 end;
  v_extra := round(greatest(0, n - 1) * public.mygig_num(card->'extraDrop', 0), 2);
  v_cover := round(public.mygig_num(ds #> '{protection,fee}', 0.5)
                   + case when v_value > v_free then (v_value - v_free) * public.mygig_num(ds #> '{protection,pct}', 1) / 100 else 0 end, 2);
  v_sub := round(v_fare + v_size + v_kg + v_fragile + v_extra + v_cover, 2);
  rp := public.mygig_region_pricing(p_place->>'country', p_place->>'state', p_place->>'city', p_place->>'suburb');
  if rp->>'taxName' is not null then
    if rp->>'taxKind' = 'fixed' then
      v_tax := round(public.mygig_num(rp->'taxValue', 0), 2);
    else
      v_tax_pct := public.mygig_num(rp->'taxValue', 0);
      v_tax := round(v_sub * v_tax_pct / 100, 2);
    end if;
  end if;
  v_exact := round(v_sub + v_tax, 2);
  v_round := public.mygig_bool(pr->'roundUp', false) or public.mygig_bool(rp->'wholeFare', false);
  v_total := case when v_round then ceil(v_exact - 0.000001) else v_exact end;
  -- Each drop-off back to the pickup, on the same card, with tax.
  for x in select value from jsonb_array_elements(c->'drops') loop
    v_rf := round(greatest(public.mygig_num(card->'min', 0),
                           public.mygig_num(card->'base', 0) + public.mygig_num(card->'perKm', 0) * public.mygig_num(x->'returnKm', 0))
                  * (1 + v_tax_pct / 100), 2);
    v_ff := round(v_rf * v_ret_pct / 100, 2);
    v_max_fail := greatest(v_max_fail, v_ff);
    v_max_ret := greatest(v_max_ret, v_rf);
    rets := rets || jsonb_build_array(jsonb_build_object('n', x->'n', 'km', x->'returnKm', 'fare', v_rf, 'failFee', v_ff));
  end loop;
  if not coalesce(p_in_app, false) then
    dep := jsonb_build_object(
      'ret', v_max_fail,
      'wait', round(public.mygig_num(w->'allowanceMin', 15) * public.mygig_num(w->'perMin', 0), 2),
      'fare', case when c->>'payer' = 'recipient' then round(v_total, 2) else 0 end,
      'fee', round(public.mygig_num(ds->'guaranteeFee', 0.5), 2),
      'waitMin', public.mygig_num(w->'allowanceMin', 15));
    dep := dep || jsonb_build_object('total', round((dep->>'ret')::numeric + (dep->>'wait')::numeric
                                                    + (dep->>'fare')::numeric + (dep->>'fee')::numeric, 2));
  end if;
  return jsonb_build_object(
    'km', km, 'min', public.mygig_num(c #> '{trip,min}', 0), 'card', card, 'own', coalesce((card->>'own')::boolean, false),
    'vehicle', p_class, 'vehicleName', public.mygig_delivery_vehicle_name(p_class),
    'drops', n,
    'fare', v_fare, 'size', v_size, 'kg', v_kg, 'fragile', v_fragile, 'extraDrops', v_extra,
    'cover', v_cover, 'coverFree', v_free, 'coverPct', public.mygig_num(ds #> '{protection,pct}', 1),
    'coverUpTo', greatest(v_value, v_free),
    'sub', v_sub,
    'taxName', rp->>'taxName', 'taxKind', rp->>'taxKind', 'taxValue', public.mygig_num(rp->'taxValue', 0),
    'tax', v_tax, 'showTax', public.mygig_bool(pr->'showTax', true),
    'exact', v_exact, 'rounded', round(v_total - v_exact, 2), 'total', round(v_total, 2), 'roundUp', v_round,
    'retPct', v_ret_pct, 'returns', rets, 'maxFail', v_max_fail, 'maxReturn', v_max_ret,
    'wait', w,
    'cod', v_cod, 'codFee', round(v_cod * public.mygig_num(ds #> '{cod,feePct}', 1.5) / 100, 2),
    'codFeePct', public.mygig_num(ds #> '{cod,feePct}', 1.5),
    'deposit', dep,
    'place', p_place, 'at', now());
end;
$$;
revoke execute on function public.mygig_delivery_price(jsonb, jsonb, jsonb, text, jsonb, boolean) from public, anon, authenticated;

-- The app's price before sending: nothing written. [p] as for create, with
-- registered (the sender's number is registered) for the deposit.
create or replace function public.mygig_delivery_quote(p jsonb, p_lat double precision default null,
                                                       p_lng double precision default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  pl jsonb;
  s jsonb;
  ds jsonb;
  v_cls text;
  pr jsonb;
  c jsonb;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  pl := coalesce(public.mygig_place((p #>> '{pickup,lat}')::float8, (p #>> '{pickup,lng}')::float8), '{}'::jsonb);
  s := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  ds := public.mygig_delivery_settings(s);
  v_cls := public.mygig_delivery_class(v_uid);
  pr := public.mygig_delivery_prefs_of(v_uid, ds, v_cls);
  c := public.mygig_delivery_clean(v_uid, p, s, ds, v_cls, pr);
  return public.mygig_delivery_price(c, ds, pr, v_cls, pl,
           public.mygig_bool(p->'registered', false) and c->>'pay' in ('wallet', 'family', 'business'))
    || jsonb_build_object('problem', public.mygig_place_problem(c->'trip'), 'trip', c->'trip');
end;
$$;
revoke execute on function public.mygig_delivery_quote(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_delivery_quote(jsonb, double precision, double precision) to authenticated;

-- ---- 5. Sending it to the sender ---------------------------------------------------------------------------
-- The driver sends a myGiG delivery: the parcel, the route, the sender's
-- and recipients' phones, who pays and how, COD, who pays a return the
-- recipient asks for, and how the sender accepts ([p].way). Checked and
-- priced here, kept as an offer until the sender answers.
create or replace function public.mygig_delivery_create(p jsonb, p_lat double precision default null,
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
  ds jsonb;
  pl jsonb;
  pr jsonb;
  c jsonb;
  q jsonb;
  lk jsonb;
  rl jsonb;
  prob jsonb;
  v_cls text;
  v_digits text;
  v_phone text;
  v_name text := nullif(left(btrim(coalesce(p #>> '{sender,name}', '')), 80), '');
  v_way text := p->>'way';
  v_lookup text;
  v_pid uuid;
  v_pay text;
  v_in_app boolean;
  v_token text := public.mygig_delivery_token();
  o public.mygig_offers;
  v_sent jsonb;
  drops jsonb := '[]'::jsonb;
  x jsonb;
  v_rid uuid;
  v_rname text;
  v_rdig text;
  v_n text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform public.mygig_expire(v_uid);
  st := public.mygig_require(v_uid, p_lat, p_lng, true);
  update public.mygig_offers set status = 'cancelled', answered_at = now()
   where driver_id = v_uid and status = 'waiting' and kind = 'new';
  pl := coalesce(public.mygig_place((p #>> '{pickup,lat}')::float8, (p #>> '{pickup,lng}')::float8), '{}'::jsonb);
  s := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  if not public.mygig_bool(s->'enabled', true) then
    raise exception 'MYGIG_OFF_HERE' using errcode = '42501', hint = 'myGiG isn''t offered where this starts.';
  end if;
  ds := public.mygig_delivery_settings(s);
  v_cls := public.mygig_delivery_class(v_uid);
  if not public.mygig_delivery_offered(ds, v_cls) then
    raise exception 'MYGIG_DELIVERY_OFF' using errcode = '42501',
      hint = 'myGiG deliveries aren''t offered for your vehicle here.';
  end if;
  pr := public.mygig_delivery_prefs_of(v_uid, ds, v_cls);
  c := public.mygig_delivery_clean(v_uid, p, s, ds, v_cls, pr);
  prob := public.mygig_place_problem(c->'trip');
  if prob is not null then
    raise exception '%', prob->>'code' using errcode = '42501', hint = prob->>'message';
  end if;

  -- The sender, checked as a myGiG passenger.
  v_digits := public.mygig_phone_digits(p #>> '{sender,phone}');
  if v_digits is not null and char_length(v_digits) < 9 then
    raise exception 'MYGIG_PHONE' using errcode = '22023', hint = 'Finish the sender''s phone number, or clear it.';
  end if;
  if v_digits is null and ds->>'senderPhone' = 'required' then
    raise exception 'MYGIG_PHONE' using errcode = '22023', hint = 'Enter the sender''s phone.';
  end if;
  if v_digits is not null then
    lk := public.mygig_lookup_inner(v_uid, v_digits, s);
    if lk->>'state' = 'blocked' then
      raise exception 'MYGIG_BLOCKED_NUMBER' using errcode = '42501', hint = 'You blocked this number.';
    end if;
    v_lookup := lk->>'state';
    v_phone := '+' || v_digits;
    if v_lookup in ('latest', 'old') then
      select x2.id into v_pid from public.profiles x2
       where regexp_replace(coalesce(x2.phone, ''), '\D', '', 'g') = v_digits and x2.deleted_at is null
       order by x2.created_at limit 1;
      v_name := lk->>'name';
    elsif v_name is null then
      raise exception 'MYGIG_NAME' using errcode = '22023', hint = 'Enter the sender''s name: this number isn''t registered.';
    end if;
  else
    v_lookup := 'nophone';
    if v_name is null then
      raise exception 'MYGIG_NAME' using errcode = '22023', hint = 'Enter the sender''s name.';
    end if;
  end if;

  -- Each recipient: a phone always, a name when not registered.
  for x in select value from jsonb_array_elements(c->'drops') loop
    v_n := case when jsonb_array_length(c->'drops') > 1 then ' ' || (x->>'n') else '' end;
    v_rdig := public.mygig_phone_digits(x->>'phone');
    if v_rdig is null or char_length(v_rdig) < 9 then
      raise exception 'MYGIG_PHONE' using errcode = '22023', hint = format('Enter the recipient''s phone for drop-off%s.', v_n);
    end if;
    rl := public.mygig_lookup_inner(v_uid, v_rdig, s);
    if rl->>'state' = 'blocked' then
      raise exception 'MYGIG_BLOCKED_NUMBER' using errcode = '42501', hint = 'You blocked this number.';
    end if;
    v_rid := null;
    v_rname := x->>'recipient';
    if rl->>'state' in ('latest', 'old') then
      select x3.id into v_rid from public.profiles x3
       where regexp_replace(coalesce(x3.phone, ''), '\D', '', 'g') = v_rdig and x3.deleted_at is null
       order by x3.created_at limit 1;
      v_rname := rl->>'name';
    elsif v_rname is null then
      raise exception 'MYGIG_NAME' using errcode = '22023',
        hint = format('Enter the recipient''s name for drop-off%s: this number isn''t registered.', v_n);
    end if;
    drops := drops || jsonb_build_array((x - 'recipient') || jsonb_build_object(
      'phone', '+' || v_rdig, 'lookup', case when rl->>'state' in ('latest', 'old') then rl->>'state' else 'none' end,
      'recipientId', v_rid, 'name', v_rname));
  end loop;
  c := c || jsonb_build_object('drops', drops);

  -- Payment (owner's rule: nothing later without in-app payment).
  v_pay := c->>'pay';
  if v_pay in ('wallet', 'family', 'business') and v_pid is null then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'GET.wallet, Family and business need a registered sender.';
  end if;
  if v_pay = 'family' and lk->'family' is null then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Family isn''t available for this sender.';
  end if;
  if v_pay = 'business' and not exists (
       select 1 from jsonb_array_elements(coalesce(lk->'businesses', '[]'::jsonb)) bz where bz->>'id' = c->>'businessId') then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Choose one of the sender''s business accounts.';
  end if;
  v_in_app := v_pid is not null and v_pay in ('wallet', 'family', 'business');
  if c->>'payer' = 'recipient' then
    if not (public.mygig_bool(ds->'recipientPays', true) and public.mygig_bool(pr->'takeRecipientPays', true)) then
      raise exception 'MYGIG_DELIVERY_RECIPIENT_PAYS' using errcode = '22023',
        hint = case when not public.mygig_bool(pr->'takeRecipientPays', true)
                    then 'You don''t take recipient pays (Delivery settings).'
                    else 'get.ride has switched off recipient pays.' end;
    end if;
    if v_pay = 'business' then
      raise exception 'MYGIG_DELIVERY_RECIPIENT_PAYS' using errcode = '22023',
        hint = 'A business account pays the delivery itself: choose Sender.';
    end if;
  end if;
  if not v_in_app and v_phone is null then
    raise exception 'MYGIG_DELIVERY_DEPOSIT_PHONE' using errcode = '22023',
      hint = 'A sender without in-app payment pays a refundable deposit by link: enter their phone.';
  end if;
  if v_pay = 'link' and v_phone is null then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Pay by link needs the sender''s phone.';
  end if;
  if (c->>'cod')::numeric > 0 then
    if not (public.mygig_bool(ds #> '{cod,on}', true) and public.mygig_bool(pr->'takeCod', true)) then
      raise exception 'MYGIG_DELIVERY_COD_OFF' using errcode = '22023',
        hint = case when not public.mygig_bool(pr->'takeCod', true) then 'You don''t take cash on delivery (Delivery settings).'
                    else 'get.ride has switched off cash on delivery here.' end;
    end if;
    if v_pid is null then
      raise exception 'MYGIG_DELIVERY_COD_SENDER' using errcode = '22023',
        hint = 'Cash on delivery needs a registered sender: the money goes to their GET.wallet.';
    end if;
    if (c->>'cod')::numeric > public.mygig_num(ds #> '{cod,max}', 1000) then
      raise exception 'MYGIG_DELIVERY_COD_MAX' using errcode = '22023',
        hint = format('Cash on delivery is up to %s.', public.mygig_money(public.mygig_num(ds #> '{cod,max}', 1000)));
    end if;
  end if;
  -- How the sender accepts.
  if v_way is null or not (v_way = any (public.mygig_ways(s, v_lookup, v_phone is not null))) then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'Choose how the sender accepts.';
  end if;
  if v_pay = 'family' and v_way <> 'app' then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'A Family delivery is accepted in the sender''s app.';
  end if;
  -- Cash in the driver's hand: the commission and the myGiG fee come off GET.credit at the end.
  if (v_pay = 'cash' or c->>'payer' = 'recipient') and not public.commission_credit_ok(v_uid) then
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = 'Your GET.credit is below the minimum for cash jobs. Top up, or ask for another way to pay.';
  end if;

  q := public.mygig_delivery_price(c, ds, pr, v_cls, pl, v_in_app);
  q := q || jsonb_build_object('terms', jsonb_build_object('canCharge', v_in_app, 'cancelFee', 0, 'noShowFee', 0),
                               'tripFee', st->'fee', 'lookup', v_lookup, 'shownName', v_name,
                               'flagged', coalesce((lk->>'flagged')::boolean, false), 'repeat', coalesce((lk->>'repeat')::int, 0),
                               'rules', jsonb_build_object(
                                 'proof', coalesce(ds->>'proof', 'code'),
                                 'ackMin', public.mygig_num(ds->'ackMin', 10),
                                 'pickupPhotos', public.mygig_num(ds->'pickupPhotos', 1),
                                 'prohibited', coalesce(ds->'prohibited', '[]'::jsonb)));
  insert into public.mygig_offers (kind, driver_id, passenger_id, passenger_name, phone, lookup, way, token_hash,
                                   trip, quote, total, expires_at, delivery)
  values ('new', v_uid, v_pid, v_name, v_phone, v_lookup, v_way, public.mygig_token_hash(v_token),
          (c->'trip') || jsonb_build_object('pay', v_pay, 'businessId', c->>'businessId'), q, (q->>'total')::numeric,
          now() + make_interval(secs => greatest(30, least(1800, public.mygig_num(s->'acceptWaitSec', 120)::int))),
          (c - 'trip') || jsonb_build_object('vehicle', v_cls, 'inApp', v_in_app, 'senderLookup', v_lookup))
  returning * into o;
  v_sent := public.mygig_send(o, v_token);
  return jsonb_build_object('offerId', o.id, 'token', v_token, 'way', o.way, 'expiresAt', o.expires_at,
                            'total', o.total, 'quote', o.quote, 'link', v_sent->>'link', 'message', v_sent->>'message',
                            'phone', v_phone, 'delivery', o.delivery);
end;
$$;
revoke execute on function public.mygig_delivery_create(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_delivery_create(jsonb, double precision, double precision) to authenticated;

-- A delivery offer, sent the way it says (as 0329's mygig_send).
create or replace function public.mygig_delivery_send(o public.mygig_offers, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d jsonb := public.mygig_driver_card(o.driver_id);
  v_url text := case when p_token is not null then public.mygig_delivery_link_url(p_token) end;
  n int := jsonb_array_length(coalesce(o.delivery->'drops', '[]'::jsonb));
  v_to text := case when n > 1 then format('%s drop-offs', n) else coalesce(o.delivery #>> '{drops,0,place,name}', 'the drop-off') end;
  v_text text;
begin
  v_text := format('get.ride: %s will deliver your %s to %s for %s. Check it and accept here: %s', d->>'name',
                   lower(coalesce(o.delivery #>> '{parcel,type}', 'parcel')), v_to, public.mygig_money(o.total), v_url);
  if o.way = 'app' and o.passenger_id is not null then
    perform public.enqueue_notification(o.passenger_id, 'mygig-offer-' || o.id || '-' || o.sends, 'ride_status', 'critical',
      'Accept your delivery?',
      format('%s will deliver your %s to %s: %s. Tap to check and accept.', d->>'name',
             lower(coalesce(o.delivery #>> '{parcel,type}', 'parcel')), v_to, public.mygig_money(o.total)),
      jsonb_build_object('type', 'mygig_offer', 'offer_id', o.id, 'role', 'rider', 'delivery', true), o.ride_id);
  elsif o.way = 'sms' and o.phone is not null and v_url is not null then
    perform public.mygig_sms(o.phone, v_text);
  end if;
  return jsonb_build_object('link', v_url, 'message', case when v_url is not null then v_text end);
end;
$$;
revoke execute on function public.mygig_delivery_send(public.mygig_offers, text) from public, anon, authenticated;

-- ---- 6. Accepting, and the ride it becomes ------------------------------------------------------------
-- 0330's send, and a delivery's (mygig_delivery_send).
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
  -- 0332: a delivery is worded and linked as one.
  if o.delivery is not null and o.kind = 'new' then
    return public.mygig_delivery_send(o, p_token);
  end if;
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

-- 0330's offer, with a delivery.
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
    'bookingStatus', (select x.status from public.mygig_bookings x where x.id = o.booking_id),
    -- 0332: a delivery's parcel, drop-offs and terms.
    'delivery', o.delivery);
$$;
revoke execute on function public.mygig_offer_json(public.mygig_offers) from public, anon, authenticated;

-- 0330's accepting, and a delivery (0332).
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
  elsif o.delivery is not null then
    -- 0332: a delivery is accepted with the sender's tick (mygig_delivery_answer).
    if coalesce(current_setting('getride.mygig_delivery_ack', true), '') <> '1' then
      raise exception 'MYGIG_DELIVERY_ACK' using errcode = '22023',
        hint = 'Open the delivery to check it and tick that there are no prohibited items.';
    end if;
    v_ride := public.mygig_delivery_make(o, p_via);
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
         when o.delivery is not null then 'Delivery accepted'
         when bk.id is not null and bk.status = 'awaiting_payment' then 'Booking accepted: waiting for payment'
         when bk.id is not null then 'Booking accepted'
         else 'Fare accepted' end,
    case when o.kind = 'change' then 'The passenger accepted the new price. Carry on.'
         when o.delivery is not null
           then format('The sender accepted %s. Pick up the parcel.', public.mygig_money(o.total))
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

-- The sender answers a delivery: in their app ([p_offer], signed in), on
-- the link ([p_token]) or on the driver's phone ([p_offer], the driver,
-- the way 'here'). Accepting needs their tick [p_ack]: no prohibited
-- items, the details are right. The answer says what is to pay by link now.
create or replace function public.mygig_delivery_answer(p_offer uuid default null, p_token text default null,
                                                        p_accept boolean default true, p_ack boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
  v_via text;
  v_wait int;
  r jsonb;
  pp public.mygig_pay_parts;
begin
  if p_token is not null then
    v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
    if v_wait > 0 then
      raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
    end if;
    select * into o from public.mygig_offers where token_hash = public.mygig_token_hash(p_token) and kind = 'new' for update;
    if not found or o.delivery is null then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
    end if;
    if o.way not in ('sms', 'whatsapp') then
      raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'The driver asked another way. Ask them to send the link again.';
    end if;
    v_via := 'link';
  else
    select * into o from public.mygig_offers where id = p_offer for update;
    if not found or o.delivery is null or auth.uid() is null then
      raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
    end if;
    if o.passenger_id = auth.uid() then
      v_via := 'app';
    elsif o.driver_id = auth.uid() and o.way = 'here' then
      v_via := 'here';
    elsif o.driver_id = auth.uid() then
      raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'Switch to "Show on this phone" first.';
    else
      raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  if not coalesce(p_accept, false) then
    return public.mygig_decline_offer(o, v_via);
  end if;
  if not coalesce(p_ack, false) then
    raise exception 'MYGIG_DELIVERY_ACK' using errcode = '22023',
      hint = 'Tick that there are no prohibited items and the details are right.';
  end if;
  perform set_config('getride.mygig_delivery_ack', '1', true);
  r := public.mygig_accept_offer(o, v_via);
  perform set_config('getride.mygig_delivery_ack', '', true);
  select p.* into pp from public.mygig_pay_parts p join public.mygig_deliveries d on d.id = p.delivery_id
   where d.ride_id = (r->>'rideId')::uuid and p.purpose = 'accept' and p.cancelled_at is null
   order by p.created_at desc limit 1;
  return r || jsonb_build_object('payNow', coalesce(pp.amount, 0), 'payRequest', pp.id,
                                 'deliveryId', (select d.id from public.mygig_deliveries d where d.ride_id = (r->>'rideId')::uuid));
end;
$$;
revoke execute on function public.mygig_delivery_answer(uuid, text, boolean, boolean) from public;
grant execute on function public.mygig_delivery_answer(uuid, text, boolean, boolean) to anon, authenticated;

-- An amount to pay by link for a delivery: a part of kind 'delivery'. An
-- open one for the same thing and amount is kept; others are cancelled.
create or replace function public.mygig_delivery_part(p_delivery uuid, p_purpose text, p_drop uuid, p_return uuid,
                                                      p_amount numeric, p_split jsonb, p_phone text, p_part_no int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
  v_id uuid;
begin
  select * into d from public.mygig_deliveries where id = p_delivery;
  select id into v_id from public.mygig_pay_parts
   where delivery_id = p_delivery and purpose = p_purpose and drop_id is not distinct from p_drop
     and return_id is not distinct from p_return and paid_at is null and cancelled_at is null
     and amount = round(p_amount, 2)
   limit 1;
  if v_id is not null then
    return v_id;
  end if;
  update public.mygig_pay_parts set cancelled_at = now()
   where delivery_id = p_delivery and purpose = p_purpose and drop_id is not distinct from p_drop
     and return_id is not distinct from p_return and paid_at is null and cancelled_at is null;
  insert into public.mygig_pay_parts (ride_id, kind, purpose, part_no, parts, amount, phone, delivery_id, drop_id, return_id, split)
  values (d.ride_id, 'delivery', p_purpose, p_part_no, 1, round(p_amount, 2), p_phone, p_delivery, p_drop, p_return, p_split)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.mygig_delivery_part(uuid, text, uuid, uuid, numeric, jsonb, text, int) from public, anon, authenticated;

-- A step in the delivery's history; the ride is touched so the apps following it refresh.
create or replace function public.mygig_delivery_log(p_delivery uuid, p_step jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride uuid;
begin
  update public.mygig_deliveries set history = history || jsonb_build_array(jsonb_build_object('at', now()) || p_step)
   where id = p_delivery
  returning ride_id into v_ride;
  update public.ride_requests set mygig = mygig || jsonb_build_object('deliveryAt', now()) where id = v_ride;
end;
$$;
revoke execute on function public.mygig_delivery_log(uuid, jsonb) from public, anon, authenticated;

-- The ride an accepted delivery becomes, and the delivery's own rows.
create or replace function public.mygig_delivery_make(o public.mygig_offers, p_via text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  dl jsonb := o.delivery;
  q jsonb := o.quote;
  v_ride uuid;
  v_id uuid;
  v_in_app boolean := coalesce((dl->>'inApp')::boolean, false);
  v_bal numeric;
  v_link numeric;
  v_dep numeric := coalesce((q #>> '{deposit,total}')::numeric, 0);
  x jsonb;
  v_here boolean := public.mygig_bool(o.trip #> '{pickup,here}', false);
begin
  -- GET.wallet: the delivery and a possible return come from it.
  if dl->>'pay' = 'wallet' and o.passenger_id is not null then
    select balance into v_bal from public.wallets where user_id = o.passenger_id and wallet_type = 'get_wallet';
    if coalesce(v_bal, 0) < (q->>'total')::numeric + coalesce((q->>'maxFail')::numeric, 0) then
      raise exception 'MYGIG_WALLET_LOW' using errcode = 'P0001',
        hint = format('Top up your GET.wallet to at least %s: the delivery and a possible return come from it.',
                      public.mygig_money((q->>'total')::numeric + coalesce((q->>'maxFail')::numeric, 0)));
    end if;
  end if;
  v_ride := public.mygig_ride_insert(jsonb_build_object(
    'driver', o.driver_id, 'passenger', o.passenger_id, 'name', o.passenger_name, 'phone', o.phone,
    'way', o.way, 'via', p_via, 'lookup', o.lookup, 'offerId', o.id, 'tokenHash', o.token_hash,
    'trip', o.trip,
    -- The cover fee is a platform line (0189 takes it back from GET.credit; not in the commission).
    'quote', q || jsonb_build_object(
      'placeFees', coalesce((q->>'cover')::numeric, 0),
      'feeLines', case when coalesce((q->>'cover')::numeric, 0) > 0
                       then jsonb_build_array(jsonb_build_object('kind', 'surcharge', 'charge', 'fixed', 'name', 'Delivery cover',
                                                                 'value', (q->>'cover')::numeric, 'platform', true))
                       else '[]'::jsonb end,
      'wait', jsonb_build_object('on', false))));
  insert into public.mygig_deliveries (
    ride_id, offer_id, driver_id, sender_id, sender_name, sender_phone, token_hash, vehicle, parcel, payer, pay, in_app,
    ret_payer, quote, total, tax, cover, cod_amount, cod_fee, cod_status, deposit, deposit_parts, guarantee_fee,
    seal_code, pickup_arrived_at, history)
  values (
    v_ride, o.id, o.driver_id, o.passenger_id, o.passenger_name, o.phone, o.token_hash, dl->>'vehicle', dl->'parcel',
    dl->>'payer', dl->>'pay', v_in_app, dl->>'retPayer', q, (q->>'total')::numeric, coalesce((q->>'tax')::numeric, 0),
    coalesce((q->>'cover')::numeric, 0), coalesce((dl->>'cod')::numeric, 0), coalesce((q->>'codFee')::numeric, 0),
    case when coalesce((dl->>'cod')::numeric, 0) > 0 then 'due' else 'none' end,
    v_dep, q->'deposit', coalesce((q #>> '{deposit,fee}')::numeric, 0),
    'GR-' || upper(substr(md5(gen_random_uuid()::text), 1, 4)),
    case when v_here then now() end,
    jsonb_build_array(jsonb_build_object('at', now(), 'step', 'accepted', 'via', p_via)))
  returning id into v_id;
  for x in select value from jsonb_array_elements(dl->'drops') loop
    insert into public.mygig_delivery_drops (delivery_id, n, place, recipient_id, recipient_name, phone, lookup, code,
                                             return_km, return_fare, fail_fee)
    values (v_id, (x->>'n')::int, x->'place', nullif(x->>'recipientId', '')::uuid, x->>'name', x->>'phone',
            coalesce(x->>'lookup', 'none'), public.mygig_delivery_code(), coalesce((x->>'returnKm')::numeric, 0),
            coalesce((select (rt->>'fare')::numeric from jsonb_array_elements(q->'returns') rt where rt->'n' = x->'n'), 0),
            coalesce((select (rt->>'failFee')::numeric from jsonb_array_elements(q->'returns') rt where rt->'n' = x->'n'), 0));
  end loop;
  -- Paid by link before the pickup: the fare (sender pays by link) and the deposit.
  v_link := case when dl->>'payer' = 'sender' and dl->>'pay' = 'link' then (q->>'total')::numeric else 0 end;
  if v_link + v_dep > 0 then
    perform public.mygig_delivery_part(v_id, 'accept', null, null, v_link + v_dep,
                                       jsonb_build_object('fare', v_link, 'deposit', v_dep), o.phone, 1);
  end if;
  perform set_config('getride.mygig_delivery', '1', true);
  update public.ride_requests set mygig = mygig || jsonb_build_object('kind', 'delivery', 'deliveryId', v_id) where id = v_ride;
  perform set_config('getride.mygig_delivery', '', true);
  update public.mygig_offers set ride_id = v_ride where id = o.id;
  return v_ride;
end;
$$;
revoke execute on function public.mygig_delivery_make(public.mygig_offers, text) from public, anon, authenticated;

-- 0329's: the ride functions refuse a delivery (it has its own screen).
create or replace function public.mygig_ride_for_driver(p_ride uuid)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.mygig is null or auth.uid() is null or r.partner_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if r.mygig->>'kind' = 'delivery' then
    raise exception 'MYGIG_DELIVERY' using errcode = '22023', hint = 'Use the delivery''s own buttons.';
  end if;
  return r;
end;
$$;
revoke execute on function public.mygig_ride_for_driver(uuid) from public, anon, authenticated;

-- 0330's: a delivery is paid on its own parts (mygig_pay_parts kind
-- 'delivery'), never as a ride paid as it goes, so no ride-level pay link
-- can be asked for it (payment_mygig_link_allowed / payment_mygig_intent).
create or replace function public.mygig_pays_first(r public.ride_requests)
returns boolean
language sql
immutable
set search_path = public
as $$
  select r.mygig is not null and r.mygig->>'kind' is distinct from 'delivery'
     and (r.mygig->>'pay' = 'link' or (r.mygig ? 'bookingId' and r.mygig->>'pay' <> 'business'));
$$;

-- A delivery ride moves only through the delivery functions: its status
-- and its driver can't be changed around them (no plain cancel, start,
-- complete or reassign), so its money is always settled.
create or replace function public.ride_requests_mygig_delivery_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.mygig->>'kind' is distinct from 'delivery'
     or coalesce(current_setting('getride.mygig_delivery', true), '') = '1' then
    return new;
  end if;
  if new.status is distinct from old.status or new.partner_id is distinct from old.partner_id
     or new.mygig->>'kind' is distinct from 'delivery' then
    raise exception 'MYGIG_DELIVERY' using errcode = '42501', hint = 'A myGiG delivery moves with its own buttons.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_mygig_delivery_guard() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_b_mygig_delivery_guard on public.ride_requests;
create trigger trg_ride_requests_b_mygig_delivery_guard
  before update on public.ride_requests
  for each row execute function public.ride_requests_mygig_delivery_guard();

-- ---- 7. The delivery ------------------------------------------------------------------------------------
-- The caller's delivery as its driver, locked.
create or replace function public.mygig_delivery_for_driver(p_ride uuid)
returns public.mygig_deliveries
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
begin
  select * into d from public.mygig_deliveries where ride_id = p_ride for update;
  if not found or auth.uid() is null or d.driver_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return d;
end;
$$;
revoke execute on function public.mygig_delivery_for_driver(uuid) from public, anon, authenticated;

-- Waiting since [p_since] on [d]'s card: {min, over, charge}.
create or replace function public.mygig_delivery_wait_now(d public.mygig_deliveries, p_since timestamptz)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object('min', m, 'over', greatest(0, m - free), 'free', free, 'perMin', per,
                            'charge', round(greatest(0, m - free) * per, 2))
    from (select case when p_since is null then 0 else floor(extract(epoch from (now() - p_since)) / 60)::int end m,
                 public.mygig_num(d.quote #> '{wait,freeMin}', 5)::int free,
                 public.mygig_num(d.quote #> '{wait,perMin}', 0.3) per) x;
$$;

-- What the deposit can still pay for waiting.
create or replace function public.mygig_delivery_wait_left(d public.mygig_deliveries)
returns numeric
language sql
stable
set search_path = public
as $$
  select case when d.in_app then null
              else greatest(0, round(coalesce((d.deposit_parts->>'wait')::numeric, 0) - d.wait_deposit, 2)) end;
$$;

-- Charges waiting [p_amount]: the in-app sender's (at the end), or the
-- deposit's allowance (as far as it goes). What was charged.
create or replace function public.mygig_delivery_charge_wait(p_delivery uuid, p_amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
  v numeric := round(greatest(0, coalesce(p_amount, 0)), 2);
begin
  select * into d from public.mygig_deliveries where id = p_delivery for update;
  if v <= 0 then
    return 0;
  end if;
  if d.in_app then
    update public.mygig_deliveries set wait_in_app = wait_in_app + v, wait_amount = wait_amount + v where id = d.id;
    return v;
  end if;
  v := least(v, public.mygig_delivery_wait_left(d));
  if v > 0 then
    update public.mygig_deliveries set wait_deposit = wait_deposit + v, wait_amount = wait_amount + v where id = d.id;
  end if;
  return v;
end;
$$;
revoke execute on function public.mygig_delivery_charge_wait(uuid, numeric) from public, anon, authenticated;

-- What the recipient at drop-off [dr] pays before the hand-over: the fare
-- (recipient pays, at the first drop-off), the COD (first drop-off) and the
-- waiting there when they pay the fare.
create or replace function public.mygig_delivery_due(d public.mygig_deliveries, dr public.mygig_delivery_drops)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object('fare', fare, 'cod', cod, 'wait', wait, 'total', round(fare + cod + wait, 2))
    from (select case when dr.n = 1 and d.payer = 'recipient' and d.fare_paid_by is null and dr.paid_at is null
                      then d.total else 0 end fare,
                 case when dr.n = 1 and d.cod_status = 'due' and dr.paid_at is null then d.cod_amount else 0 end cod,
                 case when dr.n = 1 and d.payer = 'recipient' and d.fare_paid_by is null and dr.paid_at is null
                      then (public.mygig_delivery_wait_now(d, dr.arrived_at)->>'charge')::numeric else 0 end wait) x;
$$;

-- Whether every line before a return starts is done:
-- {pay, payerAck, photo, sender, all}.
create or replace function public.mygig_delivery_return_checks(rt public.mygig_delivery_returns)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object('pay', pay, 'payerAck', ack, 'photo', photo, 'sender', sender,
                            'all', pay and ack and photo and sender)
    from (select case when rt.kind = 'failed' then true
                      when rt.method = 'cash' then rt.driver_cash_at is not null and rt.recipient_cash_ack_at is not null
                      else rt.paid_at is not null end pay,
                 case when rt.kind = 'failed' then rt.sender_ack_at is not null
                      when rt.payer = 'recipient' then rt.payer_ack_at is not null
                      else rt.sender_ack_at is not null end ack,
                 rt.photo is not null photo,
                 rt.sender_ack_at is not null sender) x;
$$;

-- No answer from the sender in time: support is told and decides.
create or replace function public.mygig_delivery_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns;
  n int := 0;
  d public.mygig_deliveries;
begin
  for rt in
    select * from public.mygig_delivery_returns
     where status = 'waiting' and sender_ack_at is null and answer_by <= now()
     for update skip locked
  loop
    update public.mygig_delivery_returns set status = 'support', support_at = now() where id = rt.id;
    select * into d from public.mygig_deliveries where id = rt.delivery_id;
    perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_support', 'returnId', rt.id));
    perform public.enqueue_notification(d.driver_id, 'mygig-dret-support-' || rt.id, 'ride_status', 'critical',
      'get.ride support is deciding',
      'The sender didn''t answer in time. get.ride support decides what happens to the parcel; don''t keep it.',
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.mygig_delivery_tick() from public, anon, authenticated;

-- A delivery as each side sees it. [p_for]: driver | sender | recipient |
-- admin; [p_drop] the recipient's own drop-off.
create or replace function public.mygig_delivery_json(d public.mygig_deliveries, p_for text, p_drop uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  drops jsonb;
  rets jsonb;
  parts jsonb;
begin
  select * into r from public.ride_requests where id = d.ride_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'n', x.n, 'place', x.place, 'status', x.status,
           'name', case when p_for = 'sender' then split_part(coalesce(x.recipient_name, 'Recipient'), ' ', 1)
                        else coalesce(x.recipient_name, 'Recipient') end,
           'phone', case when p_for in ('driver', 'admin') then x.phone end,
           'registered', x.recipient_id is not null,
           'code', case when p_for = 'recipient' and x.id = p_drop then x.code end,
           'due', case when p_for in ('driver', 'admin') or (p_for = 'recipient' and x.id = p_drop)
                       then public.mygig_delivery_due(d, x) end,
           'paidHow', x.paid_how, 'paidAt', x.paid_at,
           'arrivedAt', x.arrived_at,
           'wait', case when x.status = 'arrived' then public.mygig_delivery_wait_now(d, x.arrived_at) end,
           'waitCharge', x.wait_charge, 'waitTo', x.wait_to,
           'returnFare', x.return_fare, 'failFee', x.fail_fee,
           'proof', case when x.proof is null then null
                         else (x.proof - 'photo') || jsonb_build_object('photo', x.proof->>'photo' is not null)
                              || case when p_for in ('driver', 'admin') then jsonb_build_object('photoPath', x.proof->>'photo')
                                      else '{}'::jsonb end end,
           'deliveredAt', x.delivered_at)
           order by x.n), '[]'::jsonb) into drops
    from public.mygig_delivery_drops x
   where x.delivery_id = d.id and (p_for <> 'recipient' or x.id = p_drop);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'dropId', t.drop_id, 'n', (select x.n from public.mygig_delivery_drops x where x.id = t.drop_id),
           'kind', t.kind, 'reason', t.reason, 'payer', t.payer, 'method', t.method, 'amount', t.amount,
           'paidAt', t.paid_at, 'payerAckAt', t.payer_ack_at, 'driverCashAt', t.driver_cash_at,
           'recipientCashAckAt', t.recipient_cash_ack_at, 'photo', t.photo is not null,
           'senderAckAt', t.sender_ack_at, 'senderAckVia', t.sender_ack_via, 'answerBy', t.answer_by,
           'status', t.status, 'supportAt', t.support_at, 'supportNote', t.support_note,
           'startedAt', t.started_at, 'doneAt', t.done_at,
           'checks', public.mygig_delivery_return_checks(t),
           'payRequest', (select p.id from public.mygig_pay_parts p where p.return_id = t.id and p.paid_at is null
                           and p.cancelled_at is null limit 1))
           order by t.created_at), '[]'::jsonb) into rets
    from public.mygig_delivery_returns t
   where t.delivery_id = d.id
     and (p_for <> 'recipient' or t.drop_id = p_drop);
  if p_for in ('sender', 'admin', 'driver') then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'purpose', p.purpose, 'amount', p.amount, 'paidAt', p.paid_at,
                                                 'split', p.split) order by p.created_at), '[]'::jsonb) into parts
      from public.mygig_pay_parts p where p.delivery_id = d.id and p.cancelled_at is null
       and (p_for <> 'sender' or p.purpose <> 'door');
  end if;
  return jsonb_build_object(
    'id', d.id, 'rideId', d.ride_id, 'status', d.status, 'rideStatus', r.status,
    'vehicle', d.vehicle, 'vehicleName', public.mygig_delivery_vehicle_name(d.vehicle),
    'parcel', d.parcel - 'photos', 'photos', case when p_for in ('driver', 'admin') then d.parcel->'photos' end,
    'sealCode', d.seal_code,
    'sender', jsonb_build_object('name', case when p_for = 'recipient' then split_part(coalesce(d.sender_name, 'Sender'), ' ', 1)
                                              else d.sender_name end,
                                 'phone', case when p_for in ('driver', 'admin') then d.sender_phone end,
                                 'registered', d.sender_id is not null),
    'pickup', jsonb_build_object('name', r.pickup_name, 'address', r.pickup_address, 'lat', r.pickup_lat, 'lng', r.pickup_lng),
    'driver', public.mygig_driver_card(d.driver_id),
    'payer', d.payer, 'pay', d.pay, 'inApp', d.in_app, 'retPayer', d.ret_payer,
    'quote', case when p_for <> 'recipient' then d.quote end,
    'total', d.total,
    'cod', case when p_for <> 'recipient' or exists (select 1 from public.mygig_delivery_drops x where x.id = p_drop and x.n = 1)
                then jsonb_build_object('amount', d.cod_amount, 'fee', d.cod_fee, 'status', d.cod_status) end,
    'deposit', case when p_for in ('sender', 'admin', 'driver') then jsonb_build_object(
                 'total', d.deposit, 'parts', d.deposit_parts, 'paid', d.deposit_paid, 'used', d.deposit_used,
                 'fee', d.guarantee_fee, 'waitLeft', public.mygig_delivery_wait_left(d)) end,
    'money', case when p_for in ('driver', 'admin') then jsonb_build_object(
                 'farePaidBy', d.fare_paid_by, 'cash', d.cash_driver, 'held', d.held, 'waitAmount', d.wait_amount,
                 'waitDeposit', d.wait_deposit, 'waitInApp', d.wait_in_app, 'failFee', d.fail_fee, 'earned', d.earned,
                 'paidOut', d.paid_out, 'refundDue', d.refund_due, 'inAppShort', d.in_app_short, 'test', d.test)
               when p_for = 'sender' then jsonb_build_object('farePaidBy', d.fare_paid_by, 'refundDue', d.refund_due) end,
    'pickupArrivedAt', d.pickup_arrived_at,
    'pickupWait', case when d.status = 'pickup' then public.mygig_delivery_wait_now(d, d.pickup_arrived_at) end,
    'pickupPhotos', case when p_for in ('driver', 'admin') then d.pickup_photos else to_jsonb(jsonb_array_length(d.pickup_photos)) end,
    'itemMatches', d.item_matches, 'sealed', d.sealed, 'senderCashAt', d.sender_cash_at,
    'returnCode', case when p_for = 'sender' and exists (select 1 from public.mygig_delivery_returns t where t.delivery_id = d.id
                                                          and t.status <> 'done') then d.return_code end,
    'drops', drops, 'returns', rets, 'payParts', parts,
    'rules', d.quote->'rules',
    'shareToken', case when p_for in ('sender', 'recipient') and r.status <> 'cancelled'
                       then (select x.share_token from public.ride_request_private x where x.request_id = r.id) end,
    'startedAt', d.started_at, 'endedAt', d.ended_at, 'createdAt', d.created_at,
    'history', case when p_for in ('driver', 'admin', 'sender') then d.history end);
end;
$$;
revoke execute on function public.mygig_delivery_json(public.mygig_deliveries, text, uuid) from public, anon, authenticated;

-- The driver's delivery screen.
create or replace function public.mygig_delivery_view(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
begin
  perform public.mygig_delivery_tick();
  select * into d from public.mygig_deliveries where ride_id = p_ride;
  if not found or auth.uid() is null or d.driver_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return public.mygig_delivery_json(d, 'driver');
end;
$$;
revoke execute on function public.mygig_delivery_view(uuid) from public, anon;
grant execute on function public.mygig_delivery_view(uuid) to authenticated;

-- The sender in their app.
create or replace function public.mygig_delivery_mine(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
  x public.mygig_delivery_drops;
begin
  perform public.mygig_delivery_tick();
  select * into d from public.mygig_deliveries where ride_id = p_ride;
  if found and auth.uid() is not null and d.sender_id = auth.uid() then
    return public.mygig_delivery_json(d, 'sender') || jsonb_build_object('role', 'sender');
  end if;
  select * into x from public.mygig_delivery_drops where delivery_id = d.id and recipient_id = auth.uid() and auth.uid() is not null
   order by n limit 1;
  if x.id is not null and d.started_at is not null then
    return public.mygig_delivery_json(d, 'recipient', x.id) || jsonb_build_object('role', 'recipient');
  end if;
  raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
end;
$$;
revoke execute on function public.mygig_delivery_mine(uuid) from public, anon;
grant execute on function public.mygig_delivery_mine(uuid) to authenticated;

-- At the pickup (when it isn't where the driver is): the waiting clock starts.
create or replace function public.mygig_delivery_arrived_pickup(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
begin
  if d.status <> 'pickup' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'The parcel was already picked up.';
  end if;
  update public.mygig_deliveries set pickup_arrived_at = coalesce(pickup_arrived_at, now()) where id = d.id;
  perform set_config('getride.mygig_delivery', '1', true);
  update public.ride_requests set status = 'arrived', arrived_at = coalesce(arrived_at, now())
   where id = d.ride_id and status = 'accepted';
  perform set_config('getride.mygig_delivery', '', true);
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'pickup_arrived'));
  return jsonb_build_object('status', 'arrived');
end;
$$;
revoke execute on function public.mygig_delivery_arrived_pickup(uuid) from public, anon;
grant execute on function public.mygig_delivery_arrived_pickup(uuid) to authenticated;

-- The pickup check: photos (storage paths in the driver's folder), the item matches, the seal code written on it.
create or replace function public.mygig_delivery_pickup(p_ride uuid, p_photos jsonb default null, p_matches boolean default null,
                                                        p_sealed boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  v jsonb := d.pickup_photos;
  x jsonb;
begin
  if d.status <> 'pickup' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'The parcel was already picked up.';
  end if;
  if jsonb_typeof(p_photos) = 'array' then
    v := '[]'::jsonb;
    for x in select value from jsonb_array_elements(p_photos) loop
      if jsonb_typeof(x) = 'string' and (x #>> '{}') like auth.uid()::text || '/%' and char_length(x #>> '{}') <= 300
         and jsonb_array_length(v) < 6 then
        v := v || jsonb_build_array(x);
      end if;
    end loop;
  end if;
  update public.mygig_deliveries
     set pickup_photos = v, item_matches = coalesce(p_matches, item_matches), sealed = coalesce(p_sealed, sealed)
   where id = d.id
  returning * into d;
  return public.mygig_delivery_json(d, 'driver');
end;
$$;
revoke execute on function public.mygig_delivery_pickup(uuid, jsonb, boolean, boolean) from public, anon;
grant execute on function public.mygig_delivery_pickup(uuid, jsonb, boolean, boolean) to authenticated;

-- The sender paid the fare in cash at the pickup.
create or replace function public.mygig_delivery_sender_cash(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
begin
  if d.status <> 'pickup' or d.payer <> 'sender' or d.pay <> 'cash' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'There is no cash to take at the pickup.';
  end if;
  if d.sender_cash_at is null then
    update public.mygig_deliveries
       set sender_cash_at = now(), cash_driver = cash_driver + total, fare_paid_by = 'sender_cash'
     where id = d.id;
    perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'sender_cash', 'amount', d.total));
  end if;
  return jsonb_build_object('paid', d.total);
end;
$$;
revoke execute on function public.mygig_delivery_sender_cash(uuid) from public, anon;
grant execute on function public.mygig_delivery_sender_cash(uuid) to authenticated;

-- Ends a delivery before it started (the driver refused the item, the
-- sender cancelled, an admin): nothing is charged; what was paid by link
-- comes back (refund_due) but the guarantee fee; cash taken goes back by hand.
create or replace function public.mygig_delivery_cancel_do(p_delivery uuid, p_by text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
  v_refund numeric;
begin
  select * into d from public.mygig_deliveries where id = p_delivery for update;
  if d.status <> 'pickup' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'The parcel is on its way: it can''t be cancelled now.';
  end if;
  v_refund := round(d.held + greatest(0, d.deposit_paid - case when d.deposit_paid > 0 then d.guarantee_fee else 0 end), 2);
  update public.mygig_deliveries
     set status = case when p_by = 'driver' then 'refused' else 'cancelled' end, ended_at = now(),
         refund_due = case when test then 0 else v_refund end, held = 0, deposit_used = 0,
         cash_driver = 0
   where id = d.id;
  update public.mygig_pay_parts set cancelled_at = now() where delivery_id = d.id and paid_at is null and cancelled_at is null;
  perform set_config('getride.mygig_delivery', '1', true);
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(),
         cancel_reason = case when p_by = 'driver' then 'driver_cancelled' else 'passenger_cancelled' end,
         cancel_requested_by = case when p_by = 'driver' then 'partner' when p_by = 'sender' then 'rider' else 'admin' end,
         cancel_requested_at = coalesce(cancel_requested_at, now()), cancel_fee = 0, cancel_fee_status = 'none'
   where id = d.ride_id;
  perform set_config('getride.mygig_delivery', '', true);
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'cancelled', 'by', p_by, 'reason', p_reason,
                                                             'refundDue', v_refund, 'cashBack', d.cash_driver));
  if p_by <> 'driver' then
    perform public.enqueue_notification(d.driver_id, 'mygig-dcancel-' || d.id, 'ride_status', 'critical',
      'Delivery cancelled', 'The sender cancelled the delivery. Nothing was charged. You''re online for the next request.',
      jsonb_build_object('type', 'mygig_cancelled', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  elsif d.sender_id is not null then
    perform public.enqueue_notification(d.sender_id, 'mygig-drefused-' || d.id, 'ride_status', 'normal',
      'Delivery not taken', 'The driver didn''t take the item. Nothing was charged; anything paid by link is refunded.',
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'rider'), d.ride_id);
  end if;
  return jsonb_build_object('status', case when p_by = 'driver' then 'refused' else 'cancelled' end,
                            'refundDue', v_refund, 'cashBack', d.cash_driver);
end;
$$;
revoke execute on function public.mygig_delivery_cancel_do(uuid, text, text) from public, anon, authenticated;

-- The driver refuses the item at the pickup.
create or replace function public.mygig_delivery_refuse(p_ride uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
begin
  return public.mygig_delivery_cancel_do(d.id, 'driver', left(coalesce(nullif(btrim(p_reason), ''), 'Refused at the pickup'), 200));
end;
$$;
revoke execute on function public.mygig_delivery_refuse(uuid, text) from public, anon;
grant execute on function public.mygig_delivery_refuse(uuid, text) to authenticated;

-- The sender cancels before the pickup (in the app or on their link).
create or replace function public.mygig_delivery_cancel(p_ride uuid default null, p_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
begin
  if p_token is not null then
    select * into d from public.mygig_deliveries where token_hash = public.mygig_token_hash(p_token);
  else
    select * into d from public.mygig_deliveries where ride_id = p_ride and sender_id = auth.uid() and auth.uid() is not null;
  end if;
  if d.id is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return public.mygig_delivery_cancel_do(d.id, 'sender', 'Cancelled by the sender');
end;
$$;
revoke execute on function public.mygig_delivery_cancel(uuid, text) from public;
grant execute on function public.mygig_delivery_cancel(uuid, text) to anon, authenticated;

-- Start delivery: the pickup check done, paid before it moves; each
-- recipient gets the tracking link and their delivery code. Returns the
-- recipients' links and messages (for WhatsApp from the driver's phone).
create or replace function public.mygig_delivery_start(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  x public.mygig_delivery_drops;
  v_need int := coalesce((d.quote #>> '{rules,pickupPhotos}')::int, 1);
  v_token text;
  v_text text;
  out jsonb := '[]'::jsonb;
  v_wait jsonb;
  dc jsonb := public.mygig_driver_card(d.driver_id);
  pp public.mygig_pay_parts;
begin
  if d.status <> 'pickup' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This delivery already started or ended.';
  end if;
  if jsonb_array_length(d.pickup_photos) < v_need then
    raise exception 'MYGIG_DELIVERY_PICKUP' using errcode = '22023',
      hint = format('Take %s photo%s of the item first.', v_need, case when v_need > 1 then 's' else '' end);
  end if;
  if not d.item_matches or not d.sealed then
    raise exception 'MYGIG_DELIVERY_PICKUP' using errcode = '22023',
      hint = 'Check the item matches and write the seal code on it first.';
  end if;
  -- No losses: paid before it moves.
  select * into pp from public.mygig_pay_parts
   where delivery_id = d.id and purpose = 'accept' and cancelled_at is null order by created_at desc limit 1;
  if pp.id is not null and pp.paid_at is null then
    raise exception 'MYGIG_PAY_FIRST' using errcode = '42501',
      hint = format('The sender pays %s by link first (%s).', public.mygig_money(pp.amount),
                    case when coalesce((pp.split->>'fare')::numeric, 0) > 0 then 'the delivery and the refundable deposit'
                         else 'the refundable deposit' end);
  end if;
  if d.payer = 'sender' and d.pay = 'cash' and d.sender_cash_at is null then
    raise exception 'MYGIG_DELIVERY_CASH' using errcode = '42501',
      hint = format('Collect %s in cash from the sender first.', public.mygig_money(d.total));
  end if;
  if (d.pay = 'cash' or d.payer = 'recipient') and not public.commission_credit_ok(d.driver_id) then
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = 'Your GET.credit is below the minimum for cash jobs. Top up to start this delivery.';
  end if;
  -- Waiting at the pickup: the in-app sender's, or the deposit's allowance.
  v_wait := public.mygig_delivery_wait_now(d, d.pickup_arrived_at);
  perform public.mygig_delivery_charge_wait(d.id, (v_wait->>'charge')::numeric);
  update public.mygig_deliveries
     set status = 'delivering', started_at = now(),
         fare_paid_by = case when fare_paid_by is not null then fare_paid_by
                             when payer = 'sender' and pay = 'business' then 'business'
                             when payer = 'sender' and pay in ('wallet', 'family') then 'sender_app' else fare_paid_by end
   where id = d.id
  returning * into d;
  perform set_config('getride.mygig_delivery', '1', true);
  update public.ride_requests
     set status = 'on_trip', started_at = now(), start_method = 'none', arrived_at = coalesce(arrived_at, now())
   where id = d.ride_id;
  perform set_config('getride.mygig_delivery', '', true);
  -- Each recipient: their own link and delivery code.
  for x in select * from public.mygig_delivery_drops where delivery_id = d.id order by n loop
    v_token := public.mygig_delivery_token();
    update public.mygig_delivery_drops set token_hash = public.mygig_token_hash(v_token) where id = x.id;
    v_text := format('get.ride: %s is sending you a %s with %s. Track it and get your delivery code: %s',
                     split_part(coalesce(d.sender_name, 'Someone'), ' ', 1), lower(coalesce(d.parcel->>'type', 'parcel')),
                     dc->>'name', public.mygig_delivery_link_url(v_token));
    if x.recipient_id is not null and x.lookup = 'latest' then
      perform public.enqueue_notification(x.recipient_id, 'mygig-dstart-' || x.id, 'ride_status', 'critical',
        'A delivery is on its way to you',
        format('%s is sending you a %s with %s. Your delivery code is %s: give it to the driver only when you have it.',
               split_part(coalesce(d.sender_name, 'Someone'), ' ', 1), lower(coalesce(d.parcel->>'type', 'parcel')),
               dc->>'name', x.code),
        jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'rider',
                           'link', public.mygig_delivery_link_url(v_token)), d.ride_id);
    else
      perform public.mygig_sms(x.phone, v_text);
    end if;
    out := out || jsonb_build_array(jsonb_build_object('n', x.n, 'phone', x.phone, 'link', public.mygig_delivery_link_url(v_token),
                                                       'message', v_text, 'app', x.recipient_id is not null and x.lookup = 'latest'));
  end loop;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'started', 'pickupWait', v_wait));
  return jsonb_build_object('status', 'delivering', 'recipients', out);
end;
$$;
revoke execute on function public.mygig_delivery_start(uuid) from public, anon;
grant execute on function public.mygig_delivery_start(uuid) to authenticated;

-- The drop-off of [p_ride] numbered [p_n], locked.
create or replace function public.mygig_delivery_drop(d public.mygig_deliveries, p_n int)
returns public.mygig_delivery_drops
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.mygig_delivery_drops;
begin
  select * into x from public.mygig_delivery_drops where delivery_id = d.id and n = p_n for update;
  if not found then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return x;
end;
$$;
revoke execute on function public.mygig_delivery_drop(public.mygig_deliveries, int) from public, anon, authenticated;

-- I've arrived at drop-off [p_n]: the waiting clock starts.
create or replace function public.mygig_delivery_arrived(p_ride uuid, p_n int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  x public.mygig_delivery_drops := public.mygig_delivery_drop(d, p_n);
begin
  if d.status <> 'delivering' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Start the delivery first.';
  end if;
  if x.status = 'waiting' then
    update public.mygig_delivery_drops set status = 'arrived', arrived_at = now() where id = x.id;
    perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'arrived', 'n', p_n));
  end if;
  return jsonb_build_object('status', 'arrived');
end;
$$;
revoke execute on function public.mygig_delivery_arrived(uuid, int) from public, anon;
grant execute on function public.mygig_delivery_arrived(uuid, int) to authenticated;

-- What a recipient paid at the door ([p_how] cash or link, [p_due] the amounts).
create or replace function public.mygig_delivery_door_paid(p_drop uuid, p_how text, p_due jsonb, p_test boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.mygig_delivery_drops;
  d public.mygig_deliveries;
  v_fare numeric := coalesce((p_due->>'fare')::numeric, 0);
  v_cod numeric := coalesce((p_due->>'cod')::numeric, 0);
  v_wait numeric := coalesce((p_due->>'wait')::numeric, 0);
begin
  select * into x from public.mygig_delivery_drops where id = p_drop for update;
  select * into d from public.mygig_deliveries where id = x.delivery_id for update;
  if x.paid_at is not null then
    return;
  end if;
  update public.mygig_delivery_drops
     set paid_how = p_how, paid_at = now(), due_fare = v_fare, due_cod = v_cod, due_wait = v_wait,
         wait_charge = wait_charge + v_wait, wait_to = case when v_wait > 0 then 'recipient' else wait_to end
   where id = x.id;
  update public.mygig_deliveries
     set fare_paid_by = case when v_fare > 0 then case when p_how = 'cash' then 'recipient_cash' else 'recipient_link' end
                             else fare_paid_by end,
         cash_driver = cash_driver + case when p_how = 'cash' then v_fare + v_wait else 0 end,
         held = held + case when p_how = 'link' then v_fare + v_wait else 0 end,
         wait_amount = wait_amount + v_wait,
         cod_status = case when v_cod > 0 then p_how else cod_status end,
         test = test or coalesce(p_test, false)
   where id = d.id;
  -- COD: settled at once. Cash: off the driver's GET.credit (they have the cash); by link: get.ride has it.
  if v_cod > 0 and not coalesce(p_test, false) then
    if p_how = 'cash' then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (d.driver_id, 'get_credit', 'cod_collect', -v_cod, 'cod',
              'Cash on delivery collected in cash, paid to the sender — ' || public.mygig_money(v_cod), d.ride_id);
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (d.sender_id, 'get_wallet', 'cod_payout', round(v_cod - d.cod_fee, 2), 'cod',
            format('Cash on delivery for your item, %s less the %s COD fee', public.mygig_money(v_cod), public.mygig_money(d.cod_fee)),
            d.ride_id);
  end if;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'door_paid', 'n', x.n, 'how', p_how, 'due', p_due));
end;
$$;
revoke execute on function public.mygig_delivery_door_paid(uuid, text, jsonb, boolean) from public, anon, authenticated;

-- The recipient paid what is due in cash. Cash COD comes off the
-- driver's GET.credit at once, so it needs enough GET.credit.
create or replace function public.mygig_delivery_door_cash(p_ride uuid, p_n int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  x public.mygig_delivery_drops := public.mygig_delivery_drop(d, p_n);
  due jsonb := public.mygig_delivery_due(d, x);
  v_credit numeric;
begin
  if x.status <> 'arrived' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Tap I''ve arrived at this drop-off first.';
  end if;
  if (due->>'total')::numeric <= 0 then
    return jsonb_build_object('paid', 0);
  end if;
  if (due->>'cod')::numeric > 0 then
    select balance into v_credit from public.wallets where user_id = d.driver_id and wallet_type = 'get_credit';
    if coalesce(v_credit, 0) < (due->>'cod')::numeric then
      raise exception 'MYGIG_COD_CREDIT' using errcode = 'P0001',
        hint = format('Cash COD comes off your GET.credit (%s), which can''t cover %s. The recipient pays by link, or top up first.',
                      public.mygig_money(coalesce(v_credit, 0)), public.mygig_money((due->>'cod')::numeric));
    end if;
  end if;
  perform public.mygig_delivery_door_paid(x.id, 'cash', due);
  return jsonb_build_object('paid', due->'total', 'due', due);
end;
$$;
revoke execute on function public.mygig_delivery_door_cash(uuid, int) from public, anon;
grant execute on function public.mygig_delivery_door_cash(uuid, int) to authenticated;

-- A pay link for what is due at drop-off [p_n] (the driver asks for it).
create or replace function public.mygig_delivery_door_link(p_ride uuid, p_n int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  x public.mygig_delivery_drops := public.mygig_delivery_drop(d, p_n);
  due jsonb := public.mygig_delivery_due(d, x);
begin
  if x.status <> 'arrived' or (due->>'total')::numeric <= 0 then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Nothing is due at this drop-off.';
  end if;
  return jsonb_build_object('requestId', public.mygig_delivery_part(d.id, 'door', x.id, null, (due->>'total')::numeric, due, x.phone, 2),
                            'amount', due->'total', 'due', due);
end;
$$;
revoke execute on function public.mygig_delivery_door_link(uuid, int) from public, anon;
grant execute on function public.mygig_delivery_door_link(uuid, int) to authenticated;

-- Every drop-off ended (delivered or back with the sender) and no return
-- going: the delivery ends.
create or replace function public.mygig_delivery_maybe_finish(p_delivery uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.mygig_delivery_drops where delivery_id = p_delivery and status not in ('delivered', 'returned'))
     or exists (select 1 from public.mygig_delivery_returns where delivery_id = p_delivery and status <> 'done') then
    return null;
  end if;
  return public.mygig_delivery_finish(p_delivery);
end;
$$;
revoke execute on function public.mygig_delivery_maybe_finish(uuid) from public, anon, authenticated;

-- The hand-over at drop-off [p_n]: paid first if due, then the proof the
-- admin asks for: the recipient's code ('code'), the code or a photo with
-- the name of who took it ('codeOrPhoto'), or a photo ('photo').
create or replace function public.mygig_delivery_handover(p_ride uuid, p_n int, p_code text default null,
                                                          p_name text default null, p_photo text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  x public.mygig_delivery_drops := public.mygig_delivery_drop(d, p_n);
  due jsonb := public.mygig_delivery_due(d, x);
  v_rule text := coalesce(d.quote #>> '{rules,proof}', 'code');
  v_code_ok boolean := coalesce(nullif(btrim(coalesce(p_code, '')), '') = x.code, false);
  v_photo text := case when coalesce(p_photo, '') like auth.uid()::text || '/%' and char_length(p_photo) <= 300 then p_photo end;
  v_name text := nullif(left(btrim(coalesce(p_name, '')), 80), '');
  v_proof jsonb;
  v_wait jsonb;
  v_charged numeric := 0;
  f jsonb;
  dc jsonb := public.mygig_driver_card(d.driver_id);
begin
  if x.status <> 'arrived' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Tap I''ve arrived at this drop-off first.';
  end if;
  if (due->>'total')::numeric > 0 then
    raise exception 'MYGIG_DELIVERY_UNPAID' using errcode = '42501',
      hint = format('Collect %s first (cash or link).', public.mygig_money((due->>'total')::numeric));
  end if;
  if v_rule = 'code' and not v_code_ok then
    raise exception 'MYGIG_DELIVERY_CODE' using errcode = '22023', hint = 'Enter the recipient''s 4-digit delivery code.';
  elsif v_rule = 'photo' and v_photo is null then
    raise exception 'MYGIG_DELIVERY_PROOF' using errcode = '22023', hint = 'Take the hand-over photo.';
  elsif v_rule = 'codeOrPhoto' and not v_code_ok and (v_photo is null or v_name is null) then
    raise exception 'MYGIG_DELIVERY_PROOF' using errcode = '22023',
      hint = 'Enter the delivery code, or hand it to someone else with their name and a photo.';
  end if;
  v_proof := jsonb_build_object('kind', case when v_code_ok then 'code' else 'photo' end, 'at', now(),
                                'name', case when v_code_ok then coalesce(x.recipient_name, 'Recipient') else v_name end,
                                'photo', v_photo);
  -- Waiting here that the recipient didn't pay: the in-app sender's, or the deposit's.
  if x.paid_at is null or x.due_wait = 0 then
    v_wait := public.mygig_delivery_wait_now(d, x.arrived_at);
    v_charged := public.mygig_delivery_charge_wait(d.id, (v_wait->>'charge')::numeric);
  end if;
  update public.mygig_delivery_drops
     set status = 'delivered', delivered_at = now(), proof = v_proof,
         wait_charge = wait_charge + v_charged,
         wait_to = case when v_charged > 0 then case when d.in_app then 'sender_app' else 'deposit' end else wait_to end
   where id = x.id;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'delivered', 'n', p_n, 'proof', v_proof - 'photo',
                                                             'photo', v_photo is not null));
  -- The sender gets the proof.
  if d.sender_id is not null then
    perform public.enqueue_notification(d.sender_id, 'mygig-ddone-' || x.id, 'ride_status', 'normal', 'Delivered',
      format('Your %s was delivered to %s at %s%s.', lower(coalesce(d.parcel->>'type', 'parcel')),
             split_part(coalesce(x.recipient_name, 'the recipient'), ' ', 1),
             to_char(now() at time zone 'Asia/Kuala_Lumpur', 'HH12:MI am'),
             case when v_code_ok then ' (delivery code given)' else format(', handed to %s with a photo', v_name) end),
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'rider'), d.ride_id);
  elsif d.sender_phone is not null then
    perform public.mygig_sms(d.sender_phone,
      format('get.ride: your %s was delivered to %s by %s.', lower(coalesce(d.parcel->>'type', 'parcel')),
             split_part(coalesce(x.recipient_name, 'the recipient'), ' ', 1), dc->>'name'));
  end if;
  f := public.mygig_delivery_maybe_finish(d.id);
  return jsonb_build_object('status', 'delivered', 'finished', f is not null, 'final', f);
end;
$$;
revoke execute on function public.mygig_delivery_handover(uuid, int, text, text, text) from public, anon;
grant execute on function public.mygig_delivery_handover(uuid, int, text, text, text) to authenticated;

-- ---- 8. Returns -----------------------------------------------------------------------------------------
-- Asks the original sender to acknowledge return [rt]: in the app when
-- registered on the latest app, else a link by SMS (a token of its own).
-- The link and message are returned for WhatsApp from the driver's phone.
create or replace function public.mygig_delivery_ask_sender(p_return uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns;
  d public.mygig_deliveries;
  x public.mygig_delivery_drops;
  v_token text := public.mygig_delivery_token();
  v_text text;
  v_app boolean;
begin
  select * into rt from public.mygig_delivery_returns where id = p_return for update;
  select * into d from public.mygig_deliveries where id = rt.delivery_id;
  select * into x from public.mygig_delivery_drops where id = rt.drop_id;
  update public.mygig_delivery_returns set ack_token_hash = public.mygig_token_hash(v_token) where id = rt.id;
  v_text := format('get.ride: your %s to %s is coming back (%s). Please acknowledge: %s',
                   lower(coalesce(d.parcel->>'type', 'parcel')), split_part(coalesce(x.recipient_name, 'the recipient'), ' ', 1),
                   lower(rt.reason), public.mygig_delivery_link_url(v_token));
  v_app := d.sender_id is not null and exists (select 1 from public.mygig_offers o where o.id = d.offer_id and o.lookup = 'latest');
  if d.sender_id is not null then
    perform public.enqueue_notification(d.sender_id, 'mygig-dret-' || rt.id, 'ride_status', 'critical',
      'Your parcel is coming back',
      format('Your %s to %s is coming back: %s. Open to acknowledge.', lower(coalesce(d.parcel->>'type', 'parcel')),
             split_part(coalesce(x.recipient_name, 'the recipient'), ' ', 1), lower(rt.reason)),
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'rider', 'return_id', rt.id), d.ride_id);
  end if;
  if not v_app and d.sender_phone is not null then
    perform public.mygig_sms(d.sender_phone, v_text);
  end if;
  return jsonb_build_object('link', public.mygig_delivery_link_url(v_token), 'message', v_text, 'phone', d.sender_phone,
                            'app', v_app);
end;
$$;
revoke execute on function public.mygig_delivery_ask_sender(uuid) from public, anon, authenticated;

create or replace function public.mygig_delivery_open_return(d public.mygig_deliveries, x public.mygig_delivery_drops,
                                                             p_kind text, p_reason text, p_payer text, p_method text,
                                                             p_amount numeric, p_payer_ack text)
returns public.mygig_delivery_returns
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns;
begin
  if exists (select 1 from public.mygig_delivery_returns where drop_id = x.id) then
    raise exception 'MYGIG_DELIVERY_RETURN' using errcode = '22023', hint = 'This parcel is already coming back.';
  end if;
  update public.mygig_deliveries set return_code = coalesce(return_code, public.mygig_delivery_code()) where id = d.id;
  insert into public.mygig_delivery_returns (delivery_id, drop_id, kind, reason, payer, method, amount,
                                             payer_ack_at, payer_ack_via, answer_by)
  values (d.id, x.id, p_kind, left(coalesce(nullif(btrim(p_reason), ''), 'Coming back'), 200), p_payer, p_method,
          round(p_amount, 2), case when p_payer_ack is not null then now() end, p_payer_ack,
          now() + make_interval(mins => greatest(1, coalesce((d.quote #>> '{rules,ackMin}')::int, 10))))
  returning * into rt;
  update public.mygig_delivery_drops set status = 'returning' where id = x.id;
  return rt;
end;
$$;
revoke execute on function public.mygig_delivery_open_return(public.mygig_deliveries, public.mygig_delivery_drops, text, text, text,
  text, numeric, text) from public, anon, authenticated;

-- Nobody there, or refused (the driver at drop-off [p_n]): the sender's
-- return, the failed-return fee from their in-app account or the deposit.
create or replace function public.mygig_delivery_return_failed(p_ride uuid, p_n int, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  x public.mygig_delivery_drops := public.mygig_delivery_drop(d, p_n);
  rt public.mygig_delivery_returns;
  v_wait jsonb;
  v_charged numeric;
  ask jsonb;
begin
  if d.status <> 'delivering' or x.status <> 'arrived' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Tap I''ve arrived at this drop-off first.';
  end if;
  -- The waiting here: the in-app sender's or the deposit's (never unpaid).
  v_wait := public.mygig_delivery_wait_now(d, x.arrived_at);
  v_charged := public.mygig_delivery_charge_wait(d.id, (v_wait->>'charge')::numeric);
  update public.mygig_delivery_drops
     set wait_charge = wait_charge + v_charged,
         wait_to = case when v_charged > 0 then case when d.in_app then 'sender_app' else 'deposit' end else wait_to end
   where id = x.id;
  if x.n = 1 and d.cod_status = 'due' then
    update public.mygig_deliveries set cod_status = 'refused' where id = d.id;
  end if;
  rt := public.mygig_delivery_open_return(d, x, 'failed', coalesce(nullif(btrim(p_reason), ''), 'Nobody there, or refused at the door'),
                                          'sender', case when d.in_app then 'app' else 'deposit' end, x.fail_fee, null);
  ask := public.mygig_delivery_ask_sender(rt.id);
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_failed', 'n', p_n, 'returnId', rt.id,
                                                             'fee', x.fail_fee, 'wait', v_charged));
  return jsonb_build_object('returnId', rt.id, 'fee', x.fail_fee, 'ask', ask);
end;
$$;
revoke execute on function public.mygig_delivery_return_failed(uuid, int, text) from public, anon;
grant execute on function public.mygig_delivery_return_failed(uuid, int, text) to authenticated;

-- The recipient sends it back: on their link ([p_token]) or on the
-- driver's phone at the door ([p_ride], [p_n]). Needs their tick [p_ack].
-- The full return fare, paid by who was chosen at the start: the
-- recipient by link or cash ([p_method]); the sender when they acknowledge.
create or replace function public.mygig_delivery_return_ask(p_token text default null, p_ride uuid default null,
                                                            p_n int default null, p_reason text default null,
                                                            p_method text default 'link', p_ack boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
  x public.mygig_delivery_drops;
  rt public.mygig_delivery_returns;
  v_via text;
  v_method text;
  v_part uuid;
  v_wait int;
  ask jsonb;
begin
  if p_token is not null then
    v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
    if v_wait > 0 then
      raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
    end if;
    select * into x from public.mygig_delivery_drops where token_hash = public.mygig_token_hash(p_token) for update;
    if not found then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
    end if;
    select * into d from public.mygig_deliveries where id = x.delivery_id for update;
    v_via := 'link';
  else
    d := public.mygig_delivery_for_driver(p_ride);
    x := public.mygig_delivery_drop(d, p_n);
    v_via := 'here';
  end if;
  if not coalesce(p_ack, false) then
    raise exception 'MYGIG_DELIVERY_ACK' using errcode = '22023', hint = 'Tick that you are sending it back in the same condition.';
  end if;
  if d.status <> 'delivering' or x.status not in ('arrived', 'delivered') then
    raise exception 'MYGIG_STATE' using errcode = '22023',
      hint = 'It can be sent back while the driver is still on this delivery. Contact support.';
  end if;
  v_method := case when d.ret_payer = 'sender' then case when d.in_app then 'app' else 'link' end
                   when p_method = 'cash' then 'cash' else 'link' end;
  rt := public.mygig_delivery_open_return(d, x, 'asked', coalesce(nullif(btrim(p_reason), ''), 'The recipient sent it back'),
                                          d.ret_payer, v_method, x.return_fare,
                                          case when d.ret_payer = 'recipient' then v_via end);
  if d.ret_payer = 'recipient' and v_method = 'link' then
    v_part := public.mygig_delivery_part(d.id, 'return', null, rt.id, rt.amount, jsonb_build_object('return', rt.amount), x.phone, 2);
  end if;
  ask := public.mygig_delivery_ask_sender(rt.id);
  perform public.enqueue_notification(d.driver_id, 'mygig-dask-' || rt.id, 'ride_status', 'critical',
    'The recipient is sending it back',
    format('%s is sending the parcel back: %s. Don''t start the return until every line is done.',
           split_part(coalesce(x.recipient_name, 'The recipient'), ' ', 1), lower(rt.reason)),
    jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_asked', 'n', x.n, 'returnId', rt.id,
                                                             'payer', d.ret_payer, 'method', v_method, 'via', v_via));
  return jsonb_build_object('returnId', rt.id, 'amount', rt.amount, 'payer', d.ret_payer, 'method', v_method,
                            'payRequest', v_part, 'ask', ask);
end;
$$;
revoke execute on function public.mygig_delivery_return_ask(text, uuid, int, text, text, boolean) from public;
grant execute on function public.mygig_delivery_return_ask(text, uuid, int, text, text, boolean) to anon, authenticated;

-- The driver's return of [p_ride], locked.
create or replace function public.mygig_delivery_return_for_driver(p_ride uuid, p_return uuid)
returns public.mygig_delivery_returns
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries := public.mygig_delivery_for_driver(p_ride);
  rt public.mygig_delivery_returns;
begin
  select * into rt from public.mygig_delivery_returns where id = p_return and delivery_id = d.id for update;
  if not found then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return rt;
end;
$$;
revoke execute on function public.mygig_delivery_return_for_driver(uuid, uuid) from public, anon, authenticated;

-- The driver: the recipient handed over the return fare in cash (counted
-- only once the recipient confirms it too).
create or replace function public.mygig_delivery_return_cash(p_ride uuid, p_return uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns := public.mygig_delivery_return_for_driver(p_ride, p_return);
begin
  if rt.method <> 'cash' or rt.status not in ('waiting', 'support') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This return isn''t paid in cash.';
  end if;
  update public.mygig_delivery_returns set driver_cash_at = coalesce(driver_cash_at, now()) where id = rt.id;
  perform public.mygig_delivery_log(rt.delivery_id, jsonb_build_object('step', 'return_cash_driver', 'returnId', rt.id));
  return public.mygig_delivery_return_checks((select x from public.mygig_delivery_returns x where x.id = rt.id));
end;
$$;
revoke execute on function public.mygig_delivery_return_cash(uuid, uuid) from public, anon;
grant execute on function public.mygig_delivery_return_cash(uuid, uuid) to authenticated;

-- The recipient, on their link: "I paid the return fare in cash".
create or replace function public.mygig_delivery_return_cash_ack(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.mygig_delivery_drops;
  rt public.mygig_delivery_returns;
begin
  select * into x from public.mygig_delivery_drops where token_hash = public.mygig_token_hash(p_token);
  if not found then
    raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
  end if;
  select * into rt from public.mygig_delivery_returns where drop_id = x.id for update;
  if rt.id is null or rt.method <> 'cash' or rt.status not in ('waiting', 'support') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'There is no cash return fare to confirm.';
  end if;
  update public.mygig_delivery_returns set recipient_cash_ack_at = coalesce(recipient_cash_ack_at, now()) where id = rt.id;
  perform public.mygig_delivery_log(rt.delivery_id, jsonb_build_object('step', 'return_cash_recipient', 'returnId', rt.id));
  return public.mygig_delivery_return_checks((select y from public.mygig_delivery_returns y where y.id = rt.id));
end;
$$;
revoke execute on function public.mygig_delivery_return_cash_ack(text) from public;
grant execute on function public.mygig_delivery_return_cash_ack(text) to anon, authenticated;

-- The driver: a photo of the item now (before it goes back).
create or replace function public.mygig_delivery_return_photo(p_ride uuid, p_return uuid, p_photo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns := public.mygig_delivery_return_for_driver(p_ride, p_return);
begin
  if coalesce(p_photo, '') not like auth.uid()::text || '/%' or char_length(p_photo) > 300 then
    raise exception 'MYGIG_DELIVERY_PROOF' using errcode = '22023', hint = 'Take a photo of the item.';
  end if;
  update public.mygig_delivery_returns set photo = p_photo where id = rt.id;
  return public.mygig_delivery_return_checks((select x from public.mygig_delivery_returns x where x.id = rt.id));
end;
$$;
revoke execute on function public.mygig_delivery_return_photo(uuid, uuid, text) from public, anon;
grant execute on function public.mygig_delivery_return_photo(uuid, uuid, text) to authenticated;

-- The original sender acknowledges a return (in the app, or on a link:
-- their delivery link or the return's own), with their tick [p_tick].
-- When they agreed to pay returns the recipient asks for, they pay it
-- now: from GET.wallet / Family, by their business account, or by link.
create or replace function public.mygig_delivery_return_ack(p_return uuid default null, p_token text default null,
                                                            p_tick boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns;
  d public.mygig_deliveries;
  v_via text;
  v_part uuid;
  h text := public.mygig_token_hash(p_token);
begin
  if p_token is not null then
    select * into rt from public.mygig_delivery_returns where ack_token_hash = h for update;
    if rt.id is null then
      select t.* into rt from public.mygig_delivery_returns t join public.mygig_deliveries x on x.id = t.delivery_id
       where x.token_hash = h and (p_return is null or t.id = p_return) and t.sender_ack_at is null
       order by t.created_at limit 1 for update of t;
    end if;
    v_via := 'link';
  else
    select t.* into rt from public.mygig_delivery_returns t join public.mygig_deliveries x on x.id = t.delivery_id
     where t.id = p_return and x.sender_id = auth.uid() and auth.uid() is not null for update of t;
    v_via := 'app';
  end if;
  if rt.id is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into d from public.mygig_deliveries where id = rt.delivery_id for update;
  if not coalesce(p_tick, false) then
    raise exception 'MYGIG_DELIVERY_ACK' using errcode = '22023', hint = 'Tick that you''ll be there to take it back.';
  end if;
  if rt.status in ('started', 'done') or rt.sender_ack_at is not null then
    return jsonb_build_object('returnId', rt.id, 'already', true);
  end if;
  -- The sender pays a return the recipient asked for, when that was agreed.
  if rt.kind = 'asked' and rt.payer = 'sender' and rt.paid_at is null then
    if d.pay = 'business' then
      update public.mygig_delivery_returns set paid_at = now() where id = rt.id;
    elsif d.in_app then
      if not public.mygig_app_charge(d.sender_id, d.ride_id, rt.amount, 'ride_payment', 'myGiG delivery: return fare') then
        raise exception 'MYGIG_WALLET_LOW' using errcode = 'P0001',
          hint = format('Top up your GET.wallet: the return fare is %s.', public.mygig_money(rt.amount));
      end if;
      update public.mygig_delivery_returns set paid_at = now() where id = rt.id;
      update public.mygig_deliveries set held = held + rt.amount where id = d.id;
    else
      v_part := public.mygig_delivery_part(d.id, 'return', null, rt.id, rt.amount, jsonb_build_object('return', rt.amount),
                                           d.sender_phone, 1);
    end if;
  end if;
  update public.mygig_delivery_returns
     set sender_ack_at = now(), sender_ack_via = v_via,
         payer_ack_at = case when payer = 'sender' then now() else payer_ack_at end,
         payer_ack_via = case when payer = 'sender' then v_via else payer_ack_via end,
         status = case when status = 'support' then 'waiting' else status end
   where id = rt.id;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_sender_ack', 'returnId', rt.id, 'via', v_via));
  perform public.enqueue_notification(d.driver_id, 'mygig-dack-' || rt.id, 'ride_status', 'critical',
    'The sender acknowledged the return',
    case when v_part is not null then format('They pay %s by link; start the return once it''s paid.', public.mygig_money(rt.amount))
         else 'They know it''s coming and have the return code.' end,
    jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  return jsonb_build_object('returnId', rt.id, 'payRequest', v_part, 'amount', case when v_part is not null then rt.amount else 0 end,
                            'returnCode', d.return_code);
end;
$$;
revoke execute on function public.mygig_delivery_return_ack(uuid, text, boolean) from public;
grant execute on function public.mygig_delivery_return_ack(uuid, text, boolean) to anon, authenticated;

-- Start the return: every line done (payment secured, the payer's
-- acknowledgement, a photo now, the sender's acknowledgement or support's
-- decision).
create or replace function public.mygig_delivery_return_start(p_ride uuid, p_return uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns := public.mygig_delivery_return_for_driver(p_ride, p_return);
  c jsonb := public.mygig_delivery_return_checks(rt);
begin
  if rt.status = 'started' then
    return jsonb_build_object('status', 'started');
  end if;
  if rt.status <> 'waiting' then
    raise exception 'MYGIG_STATE' using errcode = '22023',
      hint = case when rt.status = 'support' then 'get.ride support is deciding. Don''t keep the parcel: they''ll call you.'
                  else 'This return has ended.' end;
  end if;
  if not (c->>'all')::boolean then
    raise exception 'MYGIG_DELIVERY_RETURN_CHECKS' using errcode = '42501',
      hint = case when not (c->>'pay')::boolean then 'The return isn''t paid yet.'
                  when not (c->>'photo')::boolean then 'Take a photo of the item now.'
                  when not (c->>'sender')::boolean then 'The sender hasn''t acknowledged it yet.'
                  else 'The payer hasn''t acknowledged it yet.' end;
  end if;
  update public.mygig_delivery_returns set status = 'started', started_at = now() where id = rt.id;
  -- Cash both sides confirmed: the driver has it.
  if rt.method = 'cash' then
    update public.mygig_deliveries set cash_driver = cash_driver + rt.amount where id = rt.delivery_id;
  end if;
  perform public.mygig_delivery_log(rt.delivery_id, jsonb_build_object('step', 'return_started', 'returnId', rt.id));
  return jsonb_build_object('status', 'started');
end;
$$;
revoke execute on function public.mygig_delivery_return_start(uuid, uuid) from public, anon;
grant execute on function public.mygig_delivery_return_start(uuid, uuid) to authenticated;

-- Back with the sender: their return code finishes it.
create or replace function public.mygig_delivery_return_done(p_ride uuid, p_return uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns := public.mygig_delivery_return_for_driver(p_ride, p_return);
  d public.mygig_deliveries;
  f jsonb;
begin
  select * into d from public.mygig_deliveries where id = rt.delivery_id;
  if rt.status <> 'started' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Start the return first.';
  end if;
  if nullif(btrim(coalesce(p_code, '')), '') is distinct from d.return_code then
    raise exception 'MYGIG_DELIVERY_CODE' using errcode = '22023', hint = 'Enter the sender''s 4-digit return code.';
  end if;
  update public.mygig_delivery_returns set status = 'done', done_at = now() where id = rt.id;
  update public.mygig_delivery_drops set status = 'returned' where id = rt.drop_id;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_done', 'returnId', rt.id));
  f := public.mygig_delivery_maybe_finish(d.id);
  return jsonb_build_object('status', 'done', 'finished', f is not null, 'final', f);
end;
$$;
revoke execute on function public.mygig_delivery_return_done(uuid, uuid, text) from public, anon;
grant execute on function public.mygig_delivery_return_done(uuid, uuid, text) to authenticated;

-- ---- 9. The end: every amount settled --------------------------------------------------------------------
-- The fare the recipient didn't pay is the sender's (their in-app account
-- or the deposit); the failed-return fee once (the largest: one trip
-- back); waiting as charged. The in-app sender is charged now (GET.wallet
-- or the Family host's within the member's limits); a business account by
-- its own settlement (0313) on the ride's amount. What get.ride holds (link
-- and in-app money, the deposit used) is paid to the driver; the rest of
-- the deposit is refunded but the guarantee fee; the myGiG fee comes off
-- GET.credit; the commission and the cover line as for any ride.
create or replace function public.mygig_delivery_finish(p_delivery uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.mygig_deliveries;
  r public.ride_requests;
  v_owed_app numeric := 0;
  v_fail numeric := 0;
  v_asked numeric := 0;
  v_asked_business numeric := 0;
  v_dep_used numeric;
  v_paid_by text;
  v_earned numeric;
  v_amount numeric;
  v_fare numeric;
  v_out numeric;
  v_fee numeric;
  v_refund numeric;
  v_short numeric := 0;
begin
  select * into d from public.mygig_deliveries where id = p_delivery for update;
  if d.status = 'done' then
    return jsonb_build_object('status', 'done', 'already', true);
  end if;
  select * into r from public.ride_requests where id = d.ride_id for update;
  v_dep_used := d.deposit_used + d.wait_deposit;
  v_paid_by := d.fare_paid_by;
  -- The fare.
  if v_paid_by is null then
    if d.in_app then
      v_owed_app := v_owed_app + d.total;
      v_paid_by := 'sender_app_guarantee';
    else
      v_dep_used := v_dep_used + d.total;
      v_paid_by := 'deposit';
    end if;
  elsif v_paid_by in ('sender_app', 'business') then
    v_owed_app := v_owed_app + d.total;
  end if;
  -- Waiting the in-app sender owes.
  v_owed_app := v_owed_app + d.wait_in_app;
  -- One trip back: the largest failed-return fee, once.
  select coalesce(max(amount), 0) into v_fail from public.mygig_delivery_returns
   where delivery_id = d.id and kind = 'failed' and status = 'done';
  if d.in_app then
    v_owed_app := v_owed_app + v_fail;
  else
    v_dep_used := v_dep_used + v_fail;
  end if;
  select coalesce(sum(amount), 0), coalesce(sum(amount) filter (where payer = 'sender' and d.pay = 'business'), 0)
    into v_asked, v_asked_business
    from public.mygig_delivery_returns where delivery_id = d.id and kind = 'asked' and status = 'done';
  v_owed_app := round(v_owed_app, 2);
  v_dep_used := round(least(v_dep_used, greatest(0, d.deposit_paid - case when d.deposit_paid > 0 then d.guarantee_fee else 0 end)), 2);
  -- The in-app sender pays now (GET.wallet; Family: the host's within the limits).
  if d.pay in ('wallet', 'family') and v_owed_app > 0 then
    if public.mygig_app_charge(d.sender_id, d.ride_id, v_owed_app, 'ride_payment', 'myGiG delivery') then
      update public.mygig_deliveries set held = held + v_owed_app where id = d.id returning * into d;
    else
      v_short := v_owed_app;
    end if;
  end if;
  v_earned := round(d.total + d.wait_amount + v_fail + v_asked, 2);
  -- A business account settles what the sender owes; the rest was paid to the driver directly.
  v_amount := case when d.pay = 'business' then round(v_owed_app + v_asked_business, 2) else v_earned end;
  v_fare := round(greatest(0, v_amount - d.tax - d.cover), 2);
  perform set_config('getride.mygig_delivery', '1', true);
  update public.ride_requests
     set status = 'completed', completed_at = now(), fare = v_fare, ride_fare = v_fare,
         payment_status = case when d.pay = 'business' then payment_status when v_short > 0 then 'pending' else 'paid' end,
         paid_method = case when d.pay = 'business' then paid_method when v_short > 0 then null
                            when d.held + v_dep_used >= d.cash_driver then 'gateway' else 'cash' end,
         paid_amount = case when d.pay = 'business' or v_short > 0 then paid_amount else v_earned end,
         paid_at = case when d.pay = 'business' or v_short > 0 then paid_at else now() end,
         mygig = mygig || jsonb_build_object('final', jsonb_build_object('total', v_earned, 'fare', v_fare, 'tax', d.tax,
                                                                         'cover', d.cover, 'wait', d.wait_amount, 'failFee', v_fail,
                                                                         'returns', v_asked))
   where id = d.ride_id;
  perform set_config('getride.mygig_delivery', '', true);
  -- get.ride pays the driver what it holds for them.
  v_out := round(d.held + v_dep_used, 2);
  if v_out > 0 and not d.test then
    perform public.mygig_payout(d.driver_id, d.ride_id, v_out, 'ride_earning', 'myGiG delivery paid');
  end if;
  v_fee := public.mygig_trip_fee(r.mygig->'tripFee', v_earned);
  if v_fee > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (d.driver_id, 'get_credit', 'mygig_fee', -v_fee, 'mygig', 'myGiG fee — ' || public.mygig_money(v_fee), d.ride_id);
  end if;
  v_refund := case when d.test then 0
                   else round(greatest(0, d.deposit_paid - v_dep_used - case when d.deposit_paid > 0 then d.guarantee_fee else 0 end), 2) end;
  update public.mygig_deliveries
     set status = 'done', ended_at = now(), fare_paid_by = v_paid_by, deposit_used = v_dep_used, fail_fee = v_fail,
         earned = v_earned, paid_out = case when test then 0 else v_out end, refund_due = refund_due + v_refund,
         in_app_short = v_short
   where id = d.id
  returning * into d;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'done', 'earned', v_earned, 'paidOut', v_out,
                                                             'refundDue', v_refund, 'inAppShort', v_short));
  if d.sender_id is not null then
    perform public.enqueue_notification(d.sender_id, 'mygig-dend-' || d.id, 'ride_status', 'normal', 'Delivery done',
      case when v_refund > 0 then format('Your delivery is done. %s of your deposit is refunded.', public.mygig_money(v_refund))
           else 'Your delivery is done. The proof for each drop-off is in the delivery.' end,
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'rider'), d.ride_id);
  elsif v_refund > 0 and d.sender_phone is not null then
    perform public.mygig_sms(d.sender_phone,
      format('get.ride: your delivery is done. %s of your deposit is refunded to the card or account you paid with.',
             public.mygig_money(v_refund)));
  end if;
  return jsonb_build_object('status', 'done', 'earned', v_earned, 'paidOut', d.paid_out, 'tripFee', v_fee,
                            'refundDue', v_refund, 'inAppShort', v_short, 'failFee', v_fail, 'wait', d.wait_amount,
                            'cash', d.cash_driver);
end;
$$;
revoke execute on function public.mygig_delivery_finish(uuid) from public, anon, authenticated;

-- ---- 10. Pay by link ------------------------------------------------------------------------------------
-- A paid delivery part: the sender's fare and deposit, what a recipient
-- paid at the door, or a return fare. get.ride holds it for the driver.
create or replace function public.mygig_delivery_paid(p_part uuid, p_test boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.mygig_pay_parts;
  d public.mygig_deliveries;
  v_fare numeric;
  v_dep numeric;
begin
  select * into p from public.mygig_pay_parts where id = p_part;
  select * into d from public.mygig_deliveries where id = p.delivery_id for update;
  if p.purpose = 'accept' then
    v_fare := coalesce((p.split->>'fare')::numeric, 0);
    v_dep := coalesce((p.split->>'deposit')::numeric, 0);
    update public.mygig_deliveries
       set held = held + v_fare, fare_paid_by = case when v_fare > 0 then 'sender_link' else fare_paid_by end,
           deposit_paid = deposit_paid + v_dep, test = test or coalesce(p_test, false)
     where id = d.id;
    perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'sender_paid', 'fare', v_fare, 'deposit', v_dep));
    perform public.enqueue_notification(d.driver_id, 'mygig-dpaid-' || p.id, 'ride_status', 'normal', 'Paid by link',
      format('The sender paid %s by link. Pick up the parcel.', public.mygig_money(p.amount)),
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  elsif p.purpose = 'door' then
    perform public.mygig_delivery_door_paid(p.drop_id, 'link', p.split, p_test);
    perform public.enqueue_notification(d.driver_id, 'mygig-dpaid-' || p.id, 'ride_status', 'normal', 'Paid by link',
      format('The recipient paid %s by link. Hand it over.', public.mygig_money(p.amount)),
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  elsif p.purpose = 'return' then
    update public.mygig_delivery_returns set paid_at = coalesce(paid_at, now()) where id = p.return_id;
    update public.mygig_deliveries set held = held + p.amount, test = test or coalesce(p_test, false) where id = d.id;
    perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_paid', 'returnId', p.return_id, 'amount', p.amount));
    perform public.enqueue_notification(d.driver_id, 'mygig-dpaid-' || p.id, 'ride_status', 'normal', 'Return paid',
      format('The return fare, %s, was paid by link.', public.mygig_money(p.amount)),
      jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  end if;
end;
$$;
revoke execute on function public.mygig_delivery_paid(uuid, boolean) from public, anon, authenticated;

-- May the holder of [h] (a token's hash) pay delivery part [p]: the sender
-- (their delivery link or a return's link) for the accept part and a
-- return they pay; a recipient (their link) for their door part and a
-- return they pay.
create or replace function public.mygig_delivery_token_may_pay(h text, p public.mygig_pay_parts)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p.kind = 'delivery' and p.paid_at is null and p.cancelled_at is null and (
       (p.purpose in ('accept', 'return') and exists (select 1 from public.mygig_deliveries d where d.id = p.delivery_id
                                                        and d.token_hash = h))
    or (p.purpose = 'return' and exists (select 1 from public.mygig_delivery_returns t where t.id = p.return_id
                                           and t.ack_token_hash = h and t.payer = 'sender'))
    or (p.purpose = 'door' and exists (select 1 from public.mygig_delivery_drops x where x.id = p.drop_id and x.token_hash = h))
    or (p.purpose = 'return' and exists (select 1 from public.mygig_delivery_returns t join public.mygig_delivery_drops x
                                           on x.id = t.drop_id where t.id = p.return_id and t.payer = 'recipient'
                                           and x.token_hash = h)));
$$;
revoke execute on function public.mygig_delivery_token_may_pay(text, public.mygig_pay_parts) from public, anon, authenticated;

-- The page asks for a pay link ([p_token]): the sender's accept part or a
-- return they pay; a recipient's door part (made now for what is due) or
-- the return they pay. {requestId, amount}.
create or replace function public.mygig_delivery_pay_request(p_token text, p_what text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h text := public.mygig_token_hash(p_token);
  d public.mygig_deliveries;
  x public.mygig_delivery_drops;
  p public.mygig_pay_parts;
  due jsonb;
begin
  select * into x from public.mygig_delivery_drops where token_hash = h;
  if x.id is not null then
    select * into d from public.mygig_deliveries where id = x.delivery_id;
    if coalesce(p_what, 'door') = 'door' then
      due := public.mygig_delivery_due(d, x);
      if (due->>'total')::numeric <= 0 or x.status <> 'arrived' then
        raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Nothing is due yet: pay when the driver is at your door.';
      end if;
      return jsonb_build_object('requestId', public.mygig_delivery_part(d.id, 'door', x.id, null, (due->>'total')::numeric, due, x.phone, 2),
                                'amount', due->'total');
    end if;
    select pp.* into p from public.mygig_pay_parts pp join public.mygig_delivery_returns t on t.id = pp.return_id
     where t.drop_id = x.id and pp.paid_at is null and pp.cancelled_at is null limit 1;
  else
    select pp.* into p from public.mygig_pay_parts pp
     where pp.paid_at is null and pp.cancelled_at is null and pp.kind = 'delivery'
       and (pp.delivery_id in (select y.id from public.mygig_deliveries y where y.token_hash = h)
            or pp.return_id in (select t.id from public.mygig_delivery_returns t where t.ack_token_hash = h))
       and (p_what is null or pp.purpose = p_what)
     order by pp.created_at limit 1;
  end if;
  if p.id is null then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Nothing to pay here now.';
  end if;
  return jsonb_build_object('requestId', p.id, 'amount', p.amount);
end;
$$;
revoke execute on function public.mygig_delivery_pay_request(text, text) from public;
grant execute on function public.mygig_delivery_pay_request(text, text) to anon, authenticated;

-- 0331's, and a delivery's parts by the sender's and recipients' links.
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
    -- 0332: a delivery's part: the sender's or the recipient's own link.
    if p.kind = 'delivery' then
      return public.mygig_delivery_token_may_pay(h, p);
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

-- 0331's ride_card hook, with a delivery's parts (mygig_delivery_paid).
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
    -- 0332: a delivery's part, once paid in full.
    if p.kind = 'delivery' then
      if p.paid_at is not null then
        perform public.mygig_delivery_paid(p.id, v.test_mode);
      end if;
      return;
    end if;
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

-- ---- 11. The sender's and recipients' page ---------------------------------------------------------------
-- getride.my/gig/d/<token> (no sign-in): the sender's link (the offer to
-- accept, then the delivery), a return's link (the sender acknowledges),
-- or a recipient's (tracking, the delivery code, pay, send it back).
create or replace function public.mygig_delivery_link_view(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h text := public.mygig_token_hash(p_token);
  o public.mygig_offers;
  d public.mygig_deliveries;
  x public.mygig_delivery_drops;
  rt public.mygig_delivery_returns;
  v_wait int;
  v_status text;
begin
  v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 240, interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
  end if;
  perform public.mygig_delivery_tick();
  select * into o from public.mygig_offers where token_hash = h and kind = 'new' and delivery is not null;
  if o.id is not null then
    select * into d from public.mygig_deliveries where offer_id = o.id;
    if d.id is not null then
      return jsonb_build_object('role', 'sender', 'stage', 'delivery', 'delivery', public.mygig_delivery_json(d, 'sender'));
    end if;
    v_status := case when o.status = 'waiting' and o.expires_at <= now() then 'expired' else o.status end;
    return jsonb_build_object('role', 'sender', 'stage', 'offer', 'offer', jsonb_build_object(
      'id', o.id, 'status', v_status, 'way', o.way, 'name', o.passenger_name, 'registered', o.passenger_id is not null,
      'total', o.total, 'quote', o.quote, 'expiresAt', o.expires_at, 'driver', public.mygig_driver_card(o.driver_id),
      'pickup', o.trip->'pickup',
      'delivery', (o.delivery - 'drops') || jsonb_build_object('drops',
        (select coalesce(jsonb_agg((e - 'phone' - 'recipientId') || jsonb_build_object(
                  'name', split_part(coalesce(e->>'name', 'Recipient'), ' ', 1)) order by (e->>'n')::int), '[]'::jsonb)
           from jsonb_array_elements(o.delivery->'drops') e))));
  end if;
  select * into rt from public.mygig_delivery_returns where ack_token_hash = h;
  if rt.id is not null then
    select * into d from public.mygig_deliveries where id = rt.delivery_id;
    return jsonb_build_object('role', 'sender', 'stage', 'delivery', 'returnId', rt.id,
                              'delivery', public.mygig_delivery_json(d, 'sender'));
  end if;
  select * into x from public.mygig_delivery_drops where token_hash = h;
  if x.id is not null then
    select * into d from public.mygig_deliveries where id = x.delivery_id;
    return jsonb_build_object('role', 'recipient', 'stage', 'delivery', 'dropId', x.id,
                              'delivery', public.mygig_delivery_json(d, 'recipient', x.id));
  end if;
  raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
end;
$$;
revoke execute on function public.mygig_delivery_link_view(text) from public;
grant execute on function public.mygig_delivery_link_view(text) to anon, authenticated;

-- ---- 12. Admin ---------------------------------------------------------------------------------------------
-- Today's (or [p_day]'s) deliveries: how many, delivered, returned, COD,
-- recipient paid, the average, and the money get.ride holds or owes back.
create or replace function public.mygig_admin_delivery_stats(p_day date default null)
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
  v jsonb;
begin
  if not public.mygig_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'day', v_day,
    'deliveries', count(*),
    'delivered', count(*) filter (where d.status = 'done'
                                     and not exists (select 1 from public.mygig_delivery_returns t where t.delivery_id = d.id)),
    'returned', count(*) filter (where exists (select 1 from public.mygig_delivery_returns t where t.delivery_id = d.id
                                                  and t.status = 'done')),
    'refused', count(*) filter (where d.status in ('refused', 'cancelled')),
    'going', count(*) filter (where d.status in ('pickup', 'delivering')),
    'cod', coalesce(sum(d.cod_amount) filter (where d.cod_status in ('cash', 'link')), 0),
    'recipientPaidPct', case when count(*) filter (where d.status = 'done') = 0 then 0
                             else round(100.0 * count(*) filter (where d.fare_paid_by in ('recipient_cash', 'recipient_link'))
                                        / count(*) filter (where d.status = 'done')) end,
    'avgFare', coalesce(round(avg(d.total) filter (where d.status = 'done'), 2), 0),
    'earned', coalesce(sum(d.earned), 0),
    'depositsHeld', coalesce(sum(d.deposit_paid) filter (where d.status in ('pickup', 'delivering')), 0),
    'refundDue', coalesce(sum(d.refund_due), 0),
    'inAppShort', coalesce(sum(d.in_app_short), 0),
    'support', (select count(*) from public.mygig_delivery_returns t where t.status = 'support'))
    into v
    from public.mygig_deliveries d
   where d.created_at >= v_from and d.created_at < v_to;
  return v;
end;
$$;
revoke execute on function public.mygig_admin_delivery_stats(date) from public, anon;
grant execute on function public.mygig_admin_delivery_stats(date) to authenticated;

-- The deliveries list: 'open' (going), 'support' (a return waiting for
-- support), 'refunds' (a deposit or payment to refund), 'all'.
create or replace function public.mygig_admin_deliveries(p_filter text default 'open', p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.mygig_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.mygig_delivery_json(d, 'admin') || jsonb_build_object(
             'driverName', (select p.name from public.profiles p where p.id = d.driver_id)) order by d.created_at desc)
      from (select * from public.mygig_deliveries d
             where case coalesce(p_filter, 'open')
                     when 'open' then d.status in ('pickup', 'delivering')
                     when 'support' then exists (select 1 from public.mygig_delivery_returns t where t.delivery_id = d.id
                                                    and t.status = 'support')
                     when 'refunds' then d.refund_due > 0 or d.in_app_short > 0
                     else true end
             order by d.created_at desc
             limit least(200, greatest(1, coalesce(p_limit, 50)))) d), '[]'::jsonb);
end;
$$;
revoke execute on function public.mygig_admin_deliveries(text, integer) from public, anon;
grant execute on function public.mygig_admin_deliveries(text, integer) to authenticated;

-- Support decides a return the sender didn't answer: it goes back (the
-- decision stands for the sender's acknowledgement, in the history with
-- the note). The driver never keeps the parcel.
create or replace function public.mygig_admin_delivery_decide(p_return uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rt public.mygig_delivery_returns;
  d public.mygig_deliveries;
begin
  if not (public.caller_is_admin() or public.caller_admin_can_write('rpc:mygig_admin_delivery_decide')) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'MYGIG_NOTE' using errcode = '22023', hint = 'Say what was decided (who was called, what they said).';
  end if;
  select * into rt from public.mygig_delivery_returns where id = p_return for update;
  if rt.id is null or rt.status not in ('waiting', 'support') then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.mygig_delivery_returns
     set sender_ack_at = coalesce(sender_ack_at, now()), sender_ack_via = coalesce(sender_ack_via, 'support'),
         payer_ack_at = case when payer = 'sender' then coalesce(payer_ack_at, now()) else payer_ack_at end,
         status = 'waiting', support_by = auth.uid(), support_note = left(btrim(p_note), 300)
   where id = rt.id;
  select * into d from public.mygig_deliveries where id = rt.delivery_id;
  perform public.mygig_delivery_log(d.id, jsonb_build_object('step', 'return_support_decided', 'returnId', rt.id,
                                                             'by', auth.uid(), 'note', left(btrim(p_note), 300)));
  perform public.enqueue_notification(d.driver_id, 'mygig-dsupport-' || rt.id, 'ride_status', 'critical',
    'Support decided: take it back', 'get.ride support decided the parcel goes back to the sender. Start the return when the other lines are done.',
    jsonb_build_object('type', 'mygig_delivery', 'request_id', d.ride_id, 'role', 'partner'), d.ride_id);
  return jsonb_build_object('returnId', rt.id, 'status', 'waiting');
end;
$$;
revoke execute on function public.mygig_admin_delivery_decide(uuid, text) from public, anon;
grant execute on function public.mygig_admin_delivery_decide(uuid, text) to authenticated;

notify pgrst, 'reload schema';
