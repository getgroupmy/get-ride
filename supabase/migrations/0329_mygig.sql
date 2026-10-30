-- ============================================================================
-- 0329 — myGiG, part A: a street-hail ride for drivers who aren't TEKSI.
--
-- A passenger waves a driver down. The driver enters the trip, the server
-- prices it, the passenger accepts that fixed price (in their get.ride app,
-- on a trip link sent by SMS or WhatsApp, or on the driver's phone), and the
-- trip is saved as a normal ride (a ride_requests row with a driver, marked
-- `mygig`), so the live map, God View, SOS, trip records, statements,
-- commission and Admin › Rides see it. Part B (0330) adds bookings for later
-- and hire by time; part C (0331) the passenger's extras after the trip.
--
-- Version 20261030100000 (0329_mygig). Re-runnable: tables, columns and
-- indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, seed rows only where missing.
--
-- 1. Settings
--    * mygig_rules: Admin › Operations › myGiG settings (page admin-mygig,
--      grantable to sub-admins). A Default row and a row per country,
--      state, city or suburb (keyed as 0253's ride_option_places). `settings`
--      holds only the keys a place sets; the smallest place that sets a key
--      decides it (mygig_settings_at), so a region rule only overrides what
--      it sets and switches parts on or off per region. Keys and defaults:
--      mygig_defaults(); a rule's values are checked as it is saved
--      (mygig_settings_problem: known choices, HH:MM times, amounts 0 to
--      100000).
--    * app_settings 'mygig' (mygig_global / set_mygig_global): who may use
--      myGiG (all drivers, selected drivers, nobody) and the default charge
--      to drivers (none, per trip RM or % of the fare, or a pass per day,
--      week, month, 6 months or year).
--    * mygig_driver_access: per driver, allowed / blocked / selected and
--      their charge (default, none, their own). Admins only.
--    * mygig_place_rules: per fenced place (airport_areas, the place fees
--      list): no pickups, no drop-offs, or neither.
--    * Partner types (0245 rules): rules.mygig {allowed, all, regions}, off
--      until the admin turns it on for a type; never TEKSI (it has the meter).
-- 2. Drivers: mygig_driver_prefs (their own fare when allowed, luggage per
--    size and free bags, coming to the pickup, busy times, waiting, no-show
--    and cancellation fees, the tax line, rounding up), normalized and kept
--    within the admin's limits by mygig_save_prefs; mygig_blocked_numbers;
--    mygig_passes (bought from GET.credit or GET.wallet, mygig_buy_pass).
-- 3. mygig_config(lat, lng): what the driver's app needs (may they, why
--    not, the settings here, their prefs, plan, pass, today's count).
-- 4. mygig_lookup_phone: rate-limited, only for an online approved driver
--    with access. latest / old / none / blocked, the name and ID as the
--    admin lets drivers see them (ID last 4 by default), Family and
--    business options, and a flag for a number with many myGiG rides.
-- 5. mygig_quote / mygig_price: the price, the server's alone: the fare card
--    (get.ride's or the driver's own within limits), busy-time extra,
--    luggage, coming to the pickup (waivable), place fees (0324), the
--    region's service tax, rounding up, and the price guard against the
--    same trip in the app.
-- 6. mygig_offers: the request waiting for the passenger (nothing is a ride
--    yet). mygig_create sends it (push to the app, an SMS link through the
--    gateway's trip_share channel, a WhatsApp link the driver's phone sends,
--    or shown on the driver's phone); mygig_resend, mygig_switch_way,
--    mygig_cancel_offer, mygig_offer_status. It ends unanswered after the
--    admin's wait (nothing saved). Accepting: mygig_accept (the passenger's
--    app), mygig_link_answer (the trip link's token, no sign-in),
--    mygig_accept_here (the driver's phone). mygig_link_view shows the link
--    page; after acceptance it carries the ride's share token, so the page
--    follows the ride and shows the receipt at the end.
-- 7. The ride: ride_requests.mygig (the agreed quote and terms; the
--    server's; the app can't write it, change the price, start, complete
--    or, as the passenger, cancel it around these functions). The fare is
--    the price less its tax and place fees: the tax is a fixed tax line and
--    the place fees are 0324's charges lines, so ride_amount_due is the
--    price agreed and the place gets its share as for any ride. Picked up
--    where the driver is, the ride starts 'arrived' with the waiting clock
--    running. mygig_arrived, mygig_start (no trip code: the passenger is
--    there and agreed), mygig_stop_wait, mygig_no_show and mygig_cancel_ride
--    (a fee only for a registered passenger paying GET.wallet, Family or
--    business: nobody else can be charged after the fact), mygig_reprice
--    (change destination, add a stop: back to the passenger the same way;
--    declined keeps the accepted route; the first trip link shows and
--    answers it too), mygig_complete (tolls and other
--    charges, waiting, the final price, Family charged at once, business by
--    its own settlement, the per-trip myGiG fee from GET.credit).
--    mygig_take_cash: a pay-by-link passenger who didn't pay pays cash.
-- No losses to get.ride or the driver (owner's rule; no setting makes
-- either absorb an unpaid amount):
--   * pay by link: the agreed price (coming to the pickup included) is paid
--     when the passenger accepts, before Start trip (MYGIG_PAY_FIRST);
--     anything added later (tolls, parking, waiting, an accepted change) is
--     paid before the trip can end: Complete waits (needsPayment) for a
--     second link or cash the driver confirms (mygig_take_cash; also
--     instead of the first link). Paid more than the end price, or the
--     ride cancelled: what the link paid goes back (refundDue, off the
--     driver's GET.credit, which got it), but for the coming to the pickup
--     when the passenger cancelled or didn't come; all of it when the
--     driver cancels (trg_ride_requests_mygig_cancel_settle);
--   * cash: coming to the pickup is paid in cash at the pickup before
--     Start trip (mygig_approach_cash, MYGIG_APPROACH_CASH); the commission
--     and the per-trip fee come off GET.credit at the end, so a cash myGiG
--     is neither sent nor started below 0218's GET.credit minimum
--     (GET_CREDIT_TOO_LOW);
--   * cancellation and no-show fees: only registered passengers paying in
--     the app, as above.
-- 8. Pay by link: payment_mygig_intent / payment_mygig_link_set for the
--    `payments` function's POST /payments/mygig-link, and the ride_card
--    hook (payment_ride_card_paid) pays a myGiG ride once.
-- 9. Admin: set_mygig_global, mygig_admin_drivers, mygig_admin_driver_set,
--    mygig_admin_places, mygig_admin_place_set; mygig_rules by table writes.
-- 10. Family: module 'mygig' (family_register_module); family_ride_module
--    names it, so the ride's insert trigger runs family_attach_trip and the
--    guard and event triggers (0317) cover it.
-- ============================================================================

-- ---- 1. Columns and tables -------------------------------------------------------------------------
alter table public.ride_requests add column if not exists mygig jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_mygig_valid;
alter table public.ride_requests add constraint ride_requests_mygig_valid check (
  mygig is null or (jsonb_typeof(mygig) = 'object' and pg_column_size(mygig) <= 32768));
comment on column public.ride_requests.mygig is
  'myGiG (0329): the agreed quote, the way it was accepted and the terms (waiting, no-show, cancel, the driver''s fee). Null for any other ride. The server''s.';
create index if not exists ride_requests_mygig_driver_idx on public.ride_requests (partner_id, created_at)
  where mygig is not null;

create table if not exists public.mygig_rules (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  settings   jsonb not null default '{}'::jsonb
             check (jsonb_typeof(settings) = 'object' and pg_column_size(settings) <= 16384),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mygig_rules_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null))
);
create unique index if not exists mygig_rules_key_uidx on public.mygig_rules (place_key);
comment on table public.mygig_rules is
  'myGiG settings by place (0329): Default or a country / state / city / suburb. settings holds the keys the place sets; the smallest place that sets a key decides it.';

create table if not exists public.mygig_driver_access (
  driver_id     uuid primary key references public.profiles(id) on delete cascade,
  -- Null: the default (allowed with "All drivers", not selected with "Selected drivers only").
  allowed       boolean,
  charge        text not null default 'default' check (charge in ('default', 'none', 'custom')),
  custom_mode   text check (custom_mode is null or custom_mode in ('none', 'trip', 'day', 'week', 'month', 'half', 'year')),
  custom_amount numeric(10,2) check (custom_amount is null or custom_amount between 0 and 100000),
  custom_unit   text check (custom_unit is null or custom_unit in ('RM', '%')),
  note          text check (note is null or char_length(note) <= 300),
  updated_by    uuid references public.profiles(id) on delete set null,
  updated_at    timestamptz not null default now()
);
create index if not exists mygig_driver_access_updated_by_idx on public.mygig_driver_access (updated_by);

create table if not exists public.mygig_place_rules (
  area_id    uuid primary key references public.airport_areas(id) on delete cascade,
  rule       text not null check (rule in ('pickup', 'drop', 'both')),
  updated_at timestamptz not null default now()
);

create table if not exists public.mygig_driver_prefs (
  driver_id  uuid primary key references public.profiles(id) on delete cascade,
  prefs      jsonb not null default '{}'::jsonb check (jsonb_typeof(prefs) = 'object' and pg_column_size(prefs) <= 8192),
  updated_at timestamptz not null default now()
);

create table if not exists public.mygig_blocked_numbers (
  driver_id  uuid not null references public.profiles(id) on delete cascade,
  digits     text not null check (digits ~ '^[0-9]{6,16}$'),
  created_at timestamptz not null default now(),
  primary key (driver_id, digits)
);

create table if not exists public.mygig_passes (
  id         uuid primary key default gen_random_uuid(),
  driver_id  uuid not null references public.profiles(id) on delete cascade,
  mode       text not null check (mode in ('day', 'week', 'month', 'half', 'year')),
  amount     numeric(10,2) not null check (amount between 0 and 100000),
  paid_from  text not null check (paid_from in ('get_credit', 'get_wallet')),
  starts_at  timestamptz not null default now(),
  ends_at    timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists mygig_passes_driver_idx on public.mygig_passes (driver_id, ends_at desc);

-- The request waiting for the passenger. Not a booking: nothing is saved as
-- a ride until it is accepted. 'change' asks the passenger to accept a new
-- route and price on a ride already going.
create table if not exists public.mygig_offers (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null default 'new' check (kind in ('new', 'change')),
  driver_id       uuid not null references public.profiles(id) on delete cascade,
  passenger_id    uuid references public.profiles(id) on delete set null,
  passenger_name  text check (passenger_name is null or char_length(passenger_name) <= 80),
  phone           text check (phone is null or phone ~ '^\+[0-9]{6,16}$'),
  lookup          text not null default 'none' check (lookup in ('latest', 'old', 'none', 'nophone')),
  way             text not null check (way in ('app', 'sms', 'whatsapp', 'here')),
  token_hash      text not null,
  trip            jsonb not null check (jsonb_typeof(trip) = 'object' and pg_column_size(trip) <= 16384),
  quote           jsonb not null check (jsonb_typeof(quote) = 'object' and pg_column_size(quote) <= 16384),
  total           numeric(10,2) not null check (total >= 0 and total <= 100000),
  status          text not null default 'waiting'
                  check (status in ('waiting', 'accepted', 'declined', 'expired', 'cancelled')),
  ride_id         uuid references public.ride_requests(id) on delete cascade,
  sends           integer not null default 1 check (sends between 0 and 50),
  expires_at      timestamptz not null,
  answered_at     timestamptz,
  answered_via    text check (answered_via is null or answered_via in ('app', 'link', 'here')),
  created_at      timestamptz not null default now()
);
create index if not exists mygig_offers_driver_idx on public.mygig_offers (driver_id, created_at desc);
create index if not exists mygig_offers_passenger_idx on public.mygig_offers (passenger_id, created_at desc);
create index if not exists mygig_offers_ride_idx on public.mygig_offers (ride_id);
create unique index if not exists mygig_offers_token_uidx on public.mygig_offers (token_hash);

alter table public.mygig_rules enable row level security;
alter table public.mygig_driver_access enable row level security;
alter table public.mygig_place_rules enable row level security;
alter table public.mygig_driver_prefs enable row level security;
alter table public.mygig_blocked_numbers enable row level security;
alter table public.mygig_passes enable row level security;
alter table public.mygig_offers enable row level security;
revoke all on public.mygig_rules, public.mygig_driver_access, public.mygig_place_rules, public.mygig_driver_prefs,
  public.mygig_blocked_numbers, public.mygig_passes, public.mygig_offers from anon;
revoke insert, update, delete on public.mygig_driver_access, public.mygig_place_rules, public.mygig_driver_prefs,
  public.mygig_blocked_numbers, public.mygig_passes, public.mygig_offers from authenticated;
grant select on public.mygig_driver_access, public.mygig_place_rules, public.mygig_driver_prefs,
  public.mygig_blocked_numbers, public.mygig_passes to authenticated;
grant select, insert, update, delete on public.mygig_rules to authenticated;
-- Offers are read through the functions only (the token's hash stays on the server).
revoke all on public.mygig_offers from authenticated;

drop policy if exists "mygig_rules read" on public.mygig_rules;
drop policy if exists "mygig_rules admin insert" on public.mygig_rules;
drop policy if exists "mygig_rules admin update" on public.mygig_rules;
drop policy if exists "mygig_rules admin delete" on public.mygig_rules;
create policy "mygig_rules read" on public.mygig_rules for select to authenticated
  using ((select auth.uid()) is not null);
create policy "mygig_rules admin insert" on public.mygig_rules for insert to authenticated
  with check ((select public.caller_admin_can_write('mygig_rules')));
create policy "mygig_rules admin update" on public.mygig_rules for update to authenticated
  using ((select public.caller_admin_can_write('mygig_rules')))
  with check ((select public.caller_admin_can_write('mygig_rules')));
create policy "mygig_rules admin delete" on public.mygig_rules for delete to authenticated
  using ((select public.caller_admin_can_write('mygig_rules')));

drop policy if exists "mygig_driver_access read" on public.mygig_driver_access;
create policy "mygig_driver_access read" on public.mygig_driver_access for select to authenticated
  using ((select public.caller_is_admin()));
drop policy if exists "mygig_place_rules read" on public.mygig_place_rules;
create policy "mygig_place_rules read" on public.mygig_place_rules for select to authenticated
  using ((select auth.uid()) is not null);
drop policy if exists "mygig_driver_prefs own read" on public.mygig_driver_prefs;
create policy "mygig_driver_prefs own read" on public.mygig_driver_prefs for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "mygig_blocked_numbers own read" on public.mygig_blocked_numbers;
create policy "mygig_blocked_numbers own read" on public.mygig_blocked_numbers for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "mygig_passes own read" on public.mygig_passes;
create policy "mygig_passes own read" on public.mygig_passes for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('mygig_rules', 'admin-mygig'),
  ('rpc:set_mygig_global', 'admin-mygig'),
  ('rpc:mygig_admin_driver_set', 'admin-mygig'),
  ('rpc:mygig_admin_place_set', 'admin-mygig')
on conflict do nothing;

drop trigger if exists trg_mygig_rules_updated_at on public.mygig_rules;
create trigger trg_mygig_rules_updated_at before update on public.mygig_rules
  for each row execute function public.set_updated_at();

-- ---- 2. Settings -------------------------------------------------------------------------------------
-- Every key a place may set, with get.ride's defaults.
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
    'timezone', 'Asia/Kuala_Lumpur');
$$;

-- A JSON number as numeric, else [p_default].
create or replace function public.mygig_num(p jsonb, p_default numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric
              else p_default end;
$$;

create or replace function public.mygig_bool(p jsonb, p_default boolean)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(p) = 'boolean' then (p #>> '{}')::boolean
              when jsonb_typeof(p) = 'string' then lower(p #>> '{}') in ('true', 't', '1', 'on', 'yes')
              else p_default end;
$$;

-- Deep merge: objects key by key, anything else replaced; a JSON null keeps [a]'s.
create or replace function public.mygig_merge(a jsonb, b jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when b is null or jsonb_typeof(b) = 'null' then a
    when jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      a || coalesce((select jsonb_object_agg(k, public.mygig_merge(a -> k, v))
                       from jsonb_each(b) e(k, v) where jsonb_typeof(v) <> 'null'), '{}'::jsonb)
    else b end;
$$;

insert into public.mygig_rules (level, settings)
values ('default', public.mygig_defaults())
on conflict (place_key) do nothing;

-- Why a rule's settings can't be saved, or null: the choices are known
-- ones, times are HH:MM, every amount is 0 to 100000, the guard 0 to 100.
create or replace function public.mygig_settings_problem(p jsonb)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  r record;
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
  return null;
end;
$$;

create or replace function public.mygig_rules_check()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_why text := public.mygig_settings_problem(new.settings);
begin
  if v_why is not null then
    raise exception 'MYGIG_SETTINGS_INVALID' using errcode = '22023', hint = v_why;
  end if;
  return new;
end;
$$;
revoke execute on function public.mygig_rules_check() from public, anon, authenticated;
drop trigger if exists trg_mygig_rules_check on public.mygig_rules;
create trigger trg_mygig_rules_check before insert or update on public.mygig_rules
  for each row execute function public.mygig_rules_check();

-- The Default stays (it can be changed, not deleted).
create or replace function public.mygig_rules_keep_default()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.level = 'default' then
    raise exception 'MYGIG_DEFAULT_STAYS' using errcode = '42501',
      hint = 'The Default rule can be changed but not deleted.';
  end if;
  return old;
end;
$$;
revoke execute on function public.mygig_rules_keep_default() from public, anon, authenticated;
drop trigger if exists trg_mygig_rules_keep_default on public.mygig_rules;
create trigger trg_mygig_rules_keep_default before delete on public.mygig_rules
  for each row execute function public.mygig_rules_keep_default();

-- The settings at a place: get.ride's defaults, then Default, the country,
-- state, city and suburb, each overriding only what it sets.
create or replace function public.mygig_settings_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := public.mygig_defaults();
  r record;
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_country, '')));
  s text := lower(btrim(coalesce(p_state, '')));
  t text := lower(btrim(coalesce(p_city, '')));
  b text := lower(btrim(coalesce(p_suburb, '')));
begin
  if c <> '' then
    k := k || c;
    if s <> '' then
      k := k || (c || '|' || s);
      if t <> '' then
        k := k || (c || '|' || s || '|' || t);
        if b <> '' then
          k := k || (c || '|' || s || '|' || t || '|' || b);
        end if;
      end if;
    end if;
  end if;
  for r in
    select m.settings from public.mygig_rules m
     where m.place_key = any (k)
     order by case m.level when 'default' then 0 when 'country' then 1 when 'state' then 2
                           when 'city' then 3 else 4 end
  loop
    v := public.mygig_merge(v, r.settings);
  end loop;
  return v;
end;
$$;
revoke execute on function public.mygig_settings_at(text, text, text, text) from public, anon, authenticated;

-- The place at a point, as ride options read a pickup (0253).
create or replace function public.mygig_place(p_lat double precision, p_lng double precision)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('country', coalesce(p.country, ''), 'state', coalesce(p.state, ''),
                            'city', coalesce(p.city, ''), 'suburb', coalesce(p.suburb, ''))
    from public.ride_option_place(p_lat, p_lng, null, null, null) p
   limit 1;
$$;
revoke execute on function public.mygig_place(double precision, double precision) from public, anon, authenticated;

create or replace function public.mygig_settings_here(p_lat double precision, p_lng double precision)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.mygig_settings_at(p->>'country', p->>'state', p->>'city', p->>'suburb')
    from (select coalesce(public.mygig_place(p_lat, p_lng), '{}'::jsonb) p) x;
$$;
revoke execute on function public.mygig_settings_here(double precision, double precision) from public, anon, authenticated;

-- Who may use myGiG and the default charge (app_settings 'mygig').
create or replace function public.mygig_fee_normalize(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'mode', case when p->>'mode' in ('none', 'trip', 'day', 'week', 'month', 'half', 'year') then p->>'mode' else 'none' end,
    'amount', round(least(100000, greatest(0, public.mygig_num(p->'amount', 0))), 2),
    'unit', case when p->>'unit' = '%' then '%' else 'RM' end);
$$;

create or replace function public.mygig_global()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'who', case when v->>'who' in ('all', 'selected', 'none') then v->>'who' else 'all' end,
    'fee', public.mygig_fee_normalize(coalesce(v->'fee', '{}'::jsonb)))
    from (select coalesce((select value from public.app_settings where key = 'mygig'), '{}'::jsonb) v) x;
$$;
revoke execute on function public.mygig_global() from public, anon;
grant execute on function public.mygig_global() to authenticated;

create or replace function public.set_mygig_global(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_mygig_global') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the myGiG settings.';
  end if;
  if jsonb_typeof(p) is distinct from 'object' then
    raise exception 'MYGIG_INVALID' using errcode = '22023';
  end if;
  v := jsonb_build_object(
    'who', case when p->>'who' in ('all', 'selected', 'none') then p->>'who' else 'all' end,
    'fee', public.mygig_fee_normalize(coalesce(p->'fee', '{}'::jsonb)));
  if v #>> '{fee,unit}' = '%' and (v #>> '{fee,amount}')::numeric > 100 then
    raise exception 'MYGIG_INVALID' using errcode = '22023', hint = 'A percentage is 0 to 100.';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('mygig', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_mygig_global(jsonb) from public, anon;
grant execute on function public.set_mygig_global(jsonb) to authenticated;

-- ---- 3. Helpers ----------------------------------------------------------------------------------------
create or replace function public.mygig_money(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'RM' || to_char(round(coalesce(p, 0), 2), 'FM999999990.00');
$$;

-- A phone as typed (+60 12 345 6789, 012-345 6789): its digits with the
-- country code; Malaysia's when it starts with 0 or has none.
create or replace function public.mygig_phone_digits(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when d = '' then null
              when d like '0%' then '60' || substr(d, 2)
              when char_length(d) <= 10 and d not like '60%' then '60' || d
              else d end
    from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') d) x;
$$;

-- a >= b as versions (1.4.11 >= 1.4.6).
create or replace function public.mygig_version_ge(a text, b text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (select array_agg(coalesce(nullif(regexp_replace(x, '\D', '', 'g'), ''), '0')::int order by n)
       from unnest(string_to_array(split_part(split_part(lower(btrim(a)), '+', 1), '-', 1), '.')) with ordinality t(x, n)
      where n <= 4)
    >=
    (select array_agg(coalesce(nullif(regexp_replace(x, '\D', '', 'g'), ''), '0')::int order by n)
       from unnest(string_to_array(split_part(split_part(lower(btrim(b)), '+', 1), '-', 1), '.')) with ordinality t(x, n)
      where n <= 4), false);
$$;

-- The newest version published for [p_platform] (Admin › Settings › App
-- Version); null when none is set.
create or replace function public.mygig_latest_version(p_platform text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select v from (
    select btrim(e.values->>'version') v
      from public.settings_entries e
     where e.category = 'app-version-setting' and e.active
       and btrim(coalesce(e.values->>'version', '')) ~ '^v?[0-9]'
       and (lower(btrim(coalesce(e.values->>'platform', ''))) in ('', 'all', 'both')
            or lower(btrim(coalesce(e.values->>'platform', ''))) = lower(btrim(coalesce(p_platform, '')))
            or p_platform is null)
  ) x
  order by (select array_agg(coalesce(nullif(regexp_replace(y, '\D', '', 'g'), ''), '0')::int order by n)
              from unnest(string_to_array(ltrim(x.v, 'vV'), '.')) with ordinality t(y, n)) desc nulls last
  limit 1;
$$;
revoke execute on function public.mygig_latest_version(text) from public, anon, authenticated;

-- The region's pricing at a place (Admin › Country / States / Cities ›
-- Fare pricing): the country's, else the smallest place that overrides it.
create or replace function public.mygig_region_pricing(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  w jsonb;
begin
  select c.values into v from public.countries c where lower(btrim(c.name)) = lower(btrim(coalesce(p_country, '')))
   order by c.position limit 1;
  select s.values into w from public.states s
   where lower(btrim(s.country)) = lower(btrim(coalesce(p_country, '')))
     and lower(btrim(s.name)) = lower(btrim(coalesce(p_state, '')))
     and public.mygig_bool(s.values->'pricingOverride', false) limit 1;
  v := coalesce(w, v);
  w := null;
  select c.values into w from public.cities c
   where lower(btrim(c.country)) = lower(btrim(coalesce(p_country, '')))
     and lower(btrim(c.state)) = lower(btrim(coalesce(p_state, '')))
     and lower(btrim(c.name)) = lower(btrim(coalesce(p_city, '')))
     and public.mygig_bool(c.values->'pricingOverride', false) limit 1;
  v := coalesce(w, v);
  w := null;
  select b.values into w from public.suburbs b
   where lower(btrim(b.country)) = lower(btrim(coalesce(p_country, '')))
     and lower(btrim(b.state)) = lower(btrim(coalesce(p_state, '')))
     and lower(btrim(b.city)) = lower(btrim(coalesce(p_city, '')))
     and lower(btrim(b.name)) = lower(btrim(coalesce(p_suburb, '')))
     and public.mygig_bool(b.values->'pricingOverride', false) limit 1;
  v := coalesce(w, v, '{}'::jsonb);
  return jsonb_build_object(
    'wholeFare', public.mygig_bool(v->'wholeFare', false),
    'taxName', case when public.mygig_bool(v->'taxEnabled', false) and btrim(coalesce(v->>'taxName', '')) <> ''
                         and public.mygig_num(v->'taxAmount', 0) > 0 then left(btrim(v->>'taxName'), 40) end,
    'taxKind', case when v->>'taxType' in ('fixed', 'amount', 'Fixed') then 'fixed' else 'percent' end,
    'taxValue', case when public.mygig_bool(v->'taxEnabled', false) and btrim(coalesce(v->>'taxName', '')) <> ''
                     then public.mygig_num(v->'taxAmount', 0) else 0 end);
end;
$$;
revoke execute on function public.mygig_region_pricing(text, text, text, text) from public, anon, authenticated;

-- One of the driver's partner types (not TEKSI) allows myGiG at the point
-- (a point that can't be placed is not refused). The rule is
-- rules.mygig {allowed, all, regions} on the type, off until set.
create or replace function public.mygig_type_ok(p_uid uuid, p_lat double precision, p_lng double precision)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.partners%rowtype;
  pl record;
  t text;
  r jsonb;
  v jsonb;
begin
  select * into p from public.partners where auth_user_id = p_uid order by created_at limit 1;
  if not found then
    return false;
  end if;
  select * into pl from public.ptr_point_place(p_lat, p_lng);
  foreach t in array coalesce(p.partner_types, '{}') loop
    continue when btrim(coalesce(t, '')) = '' or public.ptr_key(t) = 'teksi';
    select e.values into v from public.settings_entries e
     where e.category = 'partner-type' and public.ptr_key(e.values ->> 'name') = public.ptr_key(t)
     order by e.active desc, e.position, e.created_at limit 1;
    r := coalesce(public.ptr_json(public.ptr_json(coalesce(v, '{}'::jsonb) -> 'rules') -> 'mygig'), '{}'::jsonb);
    continue when jsonb_typeof(r) <> 'object' or not public.ptr_bool(r -> 'allowed', false);
    if coalesce(pl.country, '') = ''
       or public.ptr_list_allows(r, pl.country, pl.state, pl.city, pl.suburb) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;
revoke execute on function public.mygig_type_ok(uuid, double precision, double precision) from public, anon, authenticated;

-- The charge for [p_uid]: their own, none, or the default.
create or replace function public.mygig_fee_for(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when a.charge = 'none' then jsonb_build_object('mode', 'none', 'amount', 0, 'unit', 'RM', 'own', true)
    when a.charge = 'custom' then public.mygig_fee_normalize(jsonb_build_object(
      'mode', a.custom_mode, 'amount', a.custom_amount, 'unit', a.custom_unit)) || jsonb_build_object('own', true)
    else (public.mygig_global()->'fee') || jsonb_build_object('own', false) end
    from (select 1) x left join public.mygig_driver_access a on a.driver_id = p_uid;
$$;
revoke execute on function public.mygig_fee_for(uuid) from public, anon, authenticated;

-- The pass running now for the charge's period, or null.
create or replace function public.mygig_pass_now(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('id', s.id, 'mode', s.mode, 'amount', s.amount, 'paidFrom', s.paid_from,
                            'startsAt', s.starts_at, 'endsAt', s.ends_at)
    from public.mygig_passes s
   where s.driver_id = p_uid and s.ends_at > now() and s.starts_at <= now()
   order by s.ends_at desc limit 1;
$$;
revoke execute on function public.mygig_pass_now(uuid) from public, anon, authenticated;

-- myGiG rides the driver took today (on the settings' clock): accepted ones,
-- whatever became of them.
create or replace function public.mygig_today_count(p_uid uuid, p_tz text default 'Asia/Kuala_Lumpur')
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.ride_requests r
   where r.partner_id = p_uid and r.mygig is not null
     and r.created_at >= (date_trunc('day', now() at time zone coalesce(nullif(p_tz, ''), 'Asia/Kuala_Lumpur'))
                          at time zone coalesce(nullif(p_tz, ''), 'Asia/Kuala_Lumpur'));
$$;
revoke execute on function public.mygig_today_count(uuid, text) from public, anon, authenticated;

-- The driver's ride on the go, if any.
create or replace function public.mygig_active_ride(p_uid uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select r.id from public.ride_requests r
   where r.partner_id = p_uid and r.status in ('accepted', 'arrived', 'on_trip')
     and r.updated_at > now() - interval '12 hours'
   order by r.created_at desc limit 1;
$$;
revoke execute on function public.mygig_active_ride(uuid) from public, anon, authenticated;

-- May [p_uid] take a myGiG ride at the point now: {ok, code, message} and
-- what the app shows. Codes: NOT_DRIVER, TYPE, OFF_HERE, NOBODY,
-- NOT_SELECTED, BLOCKED, ACTIVE_TRIP, LIMIT, PASS_NEEDED.
create or replace function public.mygig_state(p_uid uuid, p_lat double precision, p_lng double precision)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  g jsonb := public.mygig_global();
  s jsonb;
  a public.mygig_driver_access;
  fee jsonb := public.mygig_fee_for(p_uid);
  pass jsonb := public.mygig_pass_now(p_uid);
  v_today int;
  v_limit int;
  v_code text;
  v_msg text;
  v_online boolean;
begin
  s := public.mygig_settings_here(p_lat, p_lng);
  select * into a from public.mygig_driver_access where driver_id = p_uid;
  v_today := public.mygig_today_count(p_uid, s->>'timezone');
  v_limit := public.mygig_num(s->'dailyLimit', 0)::int;
  select coalesce(d.online, false) into v_online from public.driver_presence d where d.profile_id = p_uid;
  if not exists (select 1 from public.partners p where p.auth_user_id = p_uid
                  and (p.status = 'approved' or p.status::text like 'permit-%')) then
    v_code := 'NOT_DRIVER'; v_msg := 'myGiG is for approved drivers.';
  elsif not public.mygig_type_ok(p_uid, p_lat, p_lng) then
    v_code := 'TYPE'; v_msg := 'myGiG isn''t offered for your Partner Service type here.';
  elsif not public.mygig_bool(s->'enabled', true) then
    v_code := 'OFF_HERE'; v_msg := 'myGiG isn''t offered here.';
  elsif g->>'who' = 'none' then
    v_code := 'NOBODY'; v_msg := 'get.ride has switched myGiG off for now. You can still take ride requests as usual.';
  elsif g->>'who' = 'selected' and not coalesce(a.allowed, false) then
    v_code := 'NOT_SELECTED'; v_msg := 'myGiG is open to selected drivers only. Contact get.ride support to ask for it.';
  elsif g->>'who' = 'all' and a.allowed is false then
    v_code := 'BLOCKED'; v_msg := 'get.ride has turned off myGiG for your account. Contact support to find out why. You can still take ride requests as usual.';
  elsif public.mygig_active_ride(p_uid) is not null then
    v_code := 'ACTIVE_TRIP'; v_msg := 'Finish the ride you are on first.';
  elsif v_limit > 0 and v_today >= v_limit then
    v_code := 'LIMIT';
    v_msg := format('You''ve taken %s myGiG rides today, the most get.ride allows a day. Passengers can still book you in the app with your QR: there''s no limit on app rides.', v_today);
  elsif fee->>'mode' in ('day', 'week', 'month', 'half', 'year') and pass is null then
    v_code := 'PASS_NEEDED'; v_msg := 'Get a myGiG pass to take myGiG rides.';
  end if;
  return jsonb_build_object('ok', v_code is null, 'code', v_code, 'message', v_msg,
                            'online', coalesce(v_online, false), 'today', v_today, 'limit', v_limit,
                            'fee', fee, 'pass', pass, 'settings', s);
end;
$$;
revoke execute on function public.mygig_state(uuid, double precision, double precision) from public, anon, authenticated;

-- Raises the state's refusal (the app checks first, to say why).
create or replace function public.mygig_require(p_uid uuid, p_lat double precision, p_lng double precision,
                                                p_online boolean default true)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  st jsonb := public.mygig_state(p_uid, p_lat, p_lng);
begin
  if not (st->>'ok')::boolean then
    raise exception 'MYGIG_%', st->>'code' using errcode = '42501', hint = st->>'message';
  end if;
  if p_online and not (st->>'online')::boolean then
    raise exception 'MYGIG_OFFLINE' using errcode = '42501', hint = 'Go online to take a myGiG ride.';
  end if;
  return st;
end;
$$;
revoke execute on function public.mygig_require(uuid, double precision, double precision, boolean) from public, anon, authenticated;

-- ---- 4. The driver's own settings ----------------------------------------------------------------------
-- The driver's prefs, filled with the defaults and kept within the
-- settings' limits [s].
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
      'amount', round(least(public.mygig_num(s #> '{cancel,max}', 10), greatest(0, public.mygig_num(cx->'amount', 5))), 2)));
end;
$$;

create or replace function public.mygig_prefs_of(p_uid uuid, s jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.mygig_prefs_normalize(coalesce((select d.prefs from public.mygig_driver_prefs d where d.driver_id = p_uid),
                                               '{}'::jsonb), s);
$$;
revoke execute on function public.mygig_prefs_of(uuid, jsonb) from public, anon, authenticated;

create or replace function public.mygig_save_prefs(p_prefs jsonb, p_lat double precision default null,
                                                   p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v jsonb;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(p_prefs) is distinct from 'object' then
    raise exception 'MYGIG_INVALID' using errcode = '22023';
  end if;
  v := public.mygig_prefs_normalize(p_prefs, public.mygig_settings_here(p_lat, p_lng));
  insert into public.mygig_driver_prefs (driver_id, prefs, updated_at) values (v_uid, v, now())
  on conflict (driver_id) do update set prefs = excluded.prefs, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.mygig_save_prefs(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_save_prefs(jsonb, double precision, double precision) to authenticated;

-- What the driver's app needs.
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
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  st := public.mygig_state(v_uid, p_lat, p_lng);
  s := st->'settings';
  return st || jsonb_build_object(
    'global', jsonb_build_object('who', public.mygig_global()->>'who'),
    'prefs', public.mygig_prefs_of(v_uid, s),
    'blocked', coalesce((select jsonb_agg(b.digits order by b.created_at desc) from public.mygig_blocked_numbers b
                          where b.driver_id = v_uid), '[]'::jsonb),
    'pricing', (select public.mygig_region_pricing(p->>'country', p->>'state', p->>'city', p->>'suburb')
                  from (select coalesce(public.mygig_place(p_lat, p_lng), '{}'::jsonb) p) x));
end;
$$;
revoke execute on function public.mygig_config(double precision, double precision) from public, anon;
grant execute on function public.mygig_config(double precision, double precision) to authenticated;

-- ---- 5. The price ---------------------------------------------------------------------------------------
-- A time of day 'HH:MM' in minutes.
create or replace function public.mygig_hhmm(p text, p_default int)
returns int
language sql
immutable
set search_path = ''
as $$
  select case when coalesce(p, '') ~ '^[0-9]{1,2}:[0-9]{2}$'
              then (split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int) % 1440 else p_default end;
$$;

create or replace function public.mygig_in_window(p_min int, p_from int, p_to int)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case when p_from = p_to then false
              when p_from < p_to then p_min >= p_from and p_min < p_to
              else p_min >= p_from or p_min < p_to end;
$$;

-- The straight-line km along the trip's points: the least the route can be.
create or replace function public.mygig_line_km(p_trip jsonb)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
  pts jsonb := jsonb_build_array(p_trip->'pickup') || coalesce(p_trip->'stops', '[]'::jsonb)
               || jsonb_build_array(p_trip->'drop');
  km double precision := 0;
  i int;
begin
  if public.mygig_bool(p_trip->'round', false) then
    pts := pts || jsonb_build_array(p_trip->'pickup');
  end if;
  for i in 1 .. jsonb_array_length(pts) - 1 loop
    continue when (pts->(i-1)->>'lat') is null or (pts->i->>'lat') is null;
    km := km + public.km_between((pts->(i-1)->>'lat')::float8, (pts->(i-1)->>'lng')::float8,
                                 (pts->i->>'lat')::float8, (pts->i->>'lng')::float8);
  end loop;
  return round(km::numeric, 2);
end;
$$;

-- The trip as the app sends it, checked: pickup and drop {lat, lng, name,
-- address}, up to 4 stops, round, km and min of the route, passengers,
-- bags {small, medium, large}, waiveApproach, approachKm, pay, service.
create or replace function public.mygig_trip_clean(p jsonb, s jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  pt jsonb;
  stops jsonb := '[]'::jsonb;
  x jsonb;
  bags jsonb;
  v_km numeric;
  v_line numeric;
  v_min numeric;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    raise exception 'MYGIG_TRIP' using errcode = '22023', hint = 'The trip is missing.';
  end if;
  foreach pt in array array[p->'pickup', p->'drop'] loop
    if jsonb_typeof(pt) is distinct from 'object' or public.mygig_num(pt->'lat', -999) not between -90 and 90
       or public.mygig_num(pt->'lng', -999) not between -180 and 180 then
      raise exception 'MYGIG_TRIP' using errcode = '22023', hint = 'Set the pickup and the drop-off.';
    end if;
  end loop;
  if jsonb_typeof(p->'stops') = 'array' then
    if jsonb_array_length(p->'stops') > 4 then
      raise exception 'MYGIG_STOPS' using errcode = '22023', hint = 'Up to 4 stops.';
    end if;
    for x in select value from jsonb_array_elements(p->'stops') loop
      if public.mygig_num(x->'lat', -999) not between -90 and 90 or public.mygig_num(x->'lng', -999) not between -180 and 180 then
        raise exception 'MYGIG_TRIP' using errcode = '22023', hint = 'A stop has no place.';
      end if;
      stops := stops || jsonb_build_array(jsonb_build_object(
        'lat', (x->>'lat')::float8, 'lng', (x->>'lng')::float8,
        'name', left(coalesce(nullif(btrim(x->>'name'), ''), 'Stop'), 120),
        'address', left(nullif(btrim(coalesce(x->>'address', '')), ''), 200)));
    end loop;
  end if;
  bags := jsonb_build_object(
    'small', least(20, greatest(0, public.mygig_num(p #> '{bags,small}', 0)::int)),
    'medium', least(20, greatest(0, public.mygig_num(p #> '{bags,medium}', 0)::int)),
    'large', least(20, greatest(0, public.mygig_num(p #> '{bags,large}', 0)::int)));
  if (bags->>'small')::int + (bags->>'medium')::int + (bags->>'large')::int
     > public.mygig_num(s #> '{luggage,maxBags}', 5) then
    raise exception 'MYGIG_BAGS' using errcode = '22023',
      hint = format('Up to %s bags.', public.mygig_num(s #> '{luggage,maxBags}', 5));
  end if;
  x := jsonb_build_object(
    'pickup', jsonb_build_object('lat', (p #>> '{pickup,lat}')::float8, 'lng', (p #>> '{pickup,lng}')::float8,
                                 'name', left(coalesce(nullif(btrim(p #>> '{pickup,name}'), ''), 'Pickup'), 120),
                                 'address', left(nullif(btrim(coalesce(p #>> '{pickup,address}', '')), ''), 200),
                                 'here', public.mygig_bool(p #> '{pickup,here}', true)),
    'drop', jsonb_build_object('lat', (p #>> '{drop,lat}')::float8, 'lng', (p #>> '{drop,lng}')::float8,
                               'name', left(coalesce(nullif(btrim(p #>> '{drop,name}'), ''), 'Drop-off'), 120),
                               'address', left(nullif(btrim(coalesce(p #>> '{drop,address}', '')), ''), 200)),
    'stops', stops,
    'round', public.mygig_bool(p->'round', false));
  -- The route's km and minutes are the app's (as every fare's); never under
  -- the straight line, never over five times it.
  v_line := public.mygig_line_km(x);
  v_km := public.mygig_num(p->'km', v_line * 1.3);
  v_km := round(least(greatest(v_km, v_line), greatest(v_line * 5, 1)), 2);
  v_min := public.mygig_num(p->'min', null);
  if v_min is null or v_min < 0 then
    v_min := round(case when v_km < 15 then 3 + v_km * 1.9 else v_km * 0.95 end);
  end if;
  v_min := least(round(v_min), 24 * 60);
  if public.mygig_num(s->'maxKm', 0) > 0 and v_km > public.mygig_num(s->'maxKm', 0) then
    raise exception 'MYGIG_TOO_FAR' using errcode = '22023',
      hint = format('myGiG rides go up to %s km here.', public.mygig_num(s->'maxKm', 0));
  end if;
  return x || jsonb_build_object(
    'km', v_km, 'min', v_min,
    'pax', least(8, greatest(1, public.mygig_num(p->'pax', 1)::int)),
    'bags', bags,
    'approachKm', round(least(200, greatest(0, public.mygig_num(p->'approachKm', 0))), 2),
    'waiveApproach', public.mygig_bool(p->'waiveApproach', false),
    'pay', case when p->>'pay' in ('cash', 'wallet', 'link', 'family', 'business') then p->>'pay' else 'cash' end,
    'businessId', case when coalesce(p->>'businessId', '') ~* '^[0-9a-f-]{36}$' then p->>'businessId' end,
    'service', left(nullif(btrim(coalesce(p->>'service', '')), ''), 80));
end;
$$;

-- The place rule ('pickup', 'drop', 'both') at a point, with the place's name.
create or replace function public.mygig_place_rule_at(p_lat double precision, p_lng double precision)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('area', a.id, 'name', coalesce(a.values->>'name', 'this place'), 'rule', m.rule)
    from (select public.airport_at(p_lat, p_lng) id) x
    join public.airport_areas a on a.id = x.id
    join public.mygig_place_rules m on m.area_id = a.id;
$$;
revoke execute on function public.mygig_place_rule_at(double precision, double precision) from public, anon, authenticated;

-- Why the trip can't be a myGiG because of where it starts or ends, or null.
create or replace function public.mygig_place_problem(p_trip jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a jsonb := public.mygig_place_rule_at((p_trip #>> '{pickup,lat}')::float8, (p_trip #>> '{pickup,lng}')::float8);
  b jsonb := public.mygig_place_rule_at((p_trip #>> '{drop,lat}')::float8, (p_trip #>> '{drop,lng}')::float8);
begin
  if a->>'rule' in ('pickup', 'both') then
    return jsonb_build_object('code', 'MYGIG_NO_PICKUP', 'end', 'pickup', 'name', a->>'name',
      'message', format('myGiG pickups aren''t allowed at %s.', a->>'name'));
  end if;
  if b->>'rule' in ('drop', 'both') then
    return jsonb_build_object('code', 'MYGIG_NO_DROP', 'end', 'drop', 'name', b->>'name',
      'message', format('myGiG drop-offs aren''t allowed at %s.', b->>'name'));
  end if;
  return null;
end;
$$;
revoke execute on function public.mygig_place_problem(jsonb) from public, anon, authenticated;

-- The price of [p_trip] (cleaned) for driver [p_uid] at [p_at], with the
-- settings [s] and prefs [pr]: every line, the tax, the total, the app's
-- price for the same trip and the guard.
create or replace function public.mygig_price(p_uid uuid, p_trip jsonb, s jsonb, pr jsonb, p_place jsonb,
                                              p_at timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  own boolean := public.mygig_bool(pr->'ownFare', false) and public.mygig_bool(s->'allowOwnFare', true);
  card jsonb := case when own then pr->'fare' else s->'fare' end;
  gcard jsonb := s->'fare';
  km numeric := public.mygig_num(p_trip->'km', 0);
  mins numeric := public.mygig_num(p_trip->'min', 0);
  v_fare numeric;
  v_app_fare numeric;
  v_busy numeric := 0;
  v_busy_label text;
  v_local timestamp := p_at at time zone coalesce(nullif(s->>'timezone', ''), 'Asia/Kuala_Lumpur');
  v_m int;
  v_lug numeric := 0;
  v_free int := public.mygig_num(pr->'freeBags', 0)::int;
  sz text;
  n int;
  i int;
  v_appr numeric := 0;
  v_appr_full numeric := 0;
  v_akm numeric := public.mygig_num(p_trip->'approachKm', 0);
  ap jsonb := pr->'approach';
  pf jsonb;
  v_fees numeric := 0;
  v_pick_fee numeric := 0;
  v_drop_fee numeric := 0;
  rp jsonb;
  v_sub numeric;
  v_tax numeric := 0;
  v_exact numeric;
  v_total numeric;
  v_round boolean;
  v_app numeric;
  v_guard numeric := public.mygig_num(s->'guard', 1.5);
  w jsonb;
begin
  v_fare := round(greatest(public.mygig_num(card->'min', 0),
                           public.mygig_num(card->'base', 0) + public.mygig_num(card->'perKm', 0) * km
                           + public.mygig_num(card->'perMin', 0) * mins), 2);
  -- Busy times: night (a %), else peak (an amount), else the weekend (a %).
  if public.mygig_bool(pr #> '{busy,on}', false) and public.mygig_bool(s #> '{busy,allowed}', true) then
    v_m := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
    if public.mygig_in_window(v_m, public.mygig_hhmm(s #>> '{busy,nightFrom}', 0), public.mygig_hhmm(s #>> '{busy,nightTo}', 360))
       and public.mygig_num(pr #> '{busy,night}', 0) > 0 then
      v_busy := round(v_fare * public.mygig_num(pr #> '{busy,night}', 0) / 100, 2);
      v_busy_label := format('Night +%s%%', trim_scale(public.mygig_num(pr #> '{busy,night}', 0)));
    elsif public.mygig_in_window(v_m, public.mygig_hhmm(s #>> '{busy,peakFrom}', 1020), public.mygig_hhmm(s #>> '{busy,peakTo}', 1200))
          and public.mygig_num(pr #> '{busy,peak}', 0) > 0 then
      v_busy := round(public.mygig_num(pr #> '{busy,peak}', 0), 2);
      v_busy_label := 'Peak +' || public.mygig_money(v_busy);
    elsif extract(isodow from v_local) in (6, 7) and public.mygig_num(pr #> '{busy,weekend}', 0) > 0 then
      v_busy := round(v_fare * public.mygig_num(pr #> '{busy,weekend}', 0) / 100, 2);
      v_busy_label := format('Weekend +%s%%', trim_scale(public.mygig_num(pr #> '{busy,weekend}', 0)));
    end if;
  end if;
  -- Luggage: the free bags come off the cheapest sizes first.
  for sz in
    select k from (values ('small'), ('medium'), ('large')) v(k)
     order by public.mygig_num(pr #> array['lug', k], 0), case k when 'small' then 0 when 'medium' then 1 else 2 end
  loop
    n := public.mygig_num(p_trip #> array['bags', sz], 0)::int;
    for i in 1 .. n loop
      if v_free > 0 then
        v_free := v_free - 1;
      else
        v_lug := v_lug + public.mygig_num(pr #> array['lug', sz], 0);
      end if;
    end loop;
  end loop;
  v_lug := round(v_lug, 2);
  -- Coming to the pickup, when it isn't where the driver is.
  if not public.mygig_bool(p_trip #> '{pickup,here}', true) and v_akm > 0
     and public.mygig_bool(s #> '{approach,allowed}', true) and ap->>'mode' in ('perkm', 'fixed') then
    if ap->>'mode' = 'perkm' then
      v_appr_full := greatest(0, v_akm - public.mygig_num(ap->'freeKm', 0))
                     * least(public.mygig_num(ap->'perKm', 0), public.mygig_num(s #> '{approach,maxPerKm}', 5));
    elsif v_akm > public.mygig_num(ap->'freeKm', 0) then
      v_appr_full := public.mygig_num(ap->'fixed', 0);
    end if;
    v_appr_full := round(least(v_appr_full, public.mygig_num(s #> '{approach,maxPerRide}', 30)), 2);
    v_appr := case when public.mygig_bool(p_trip->'waiveApproach', false) then 0 else v_appr_full end;
  end if;
  -- Place fees at the pickup and the drop-off (0324).
  begin
    pf := public.place_fees_quote((p_trip #>> '{pickup,lat}')::float8, (p_trip #>> '{pickup,lng}')::float8,
                                  (p_trip #>> '{drop,lat}')::float8, (p_trip #>> '{drop,lng}')::float8,
                                  p_trip->'stops', p_trip->>'service', v_fare, p_at);
  exception when others then
    pf := null;
  end;
  v_fees := round(public.mygig_num(pf->'total', 0), 2);
  v_pick_fee := coalesce((select round(sum(public.mygig_num(f->'amount', 0)), 2)
                            from jsonb_array_elements(coalesce(pf #> '{pickup,fees}', '[]'::jsonb)) f), 0);
  v_drop_fee := greatest(0, v_fees - v_pick_fee);
  -- Waiting is added at the end of the trip.
  w := case when public.mygig_bool(pr #> '{wait,own}', false) and public.mygig_bool(s #> '{waiting,allowOwn}', true)
            then jsonb_build_object('freeMin', public.mygig_num(pr #> '{wait,free}', 0),
                                    'perMin', public.mygig_num(pr #> '{wait,perMin}', 0))
            else jsonb_build_object('freeMin', public.mygig_num(s #> '{waiting,freeMin}', 3),
                                    'perMin', public.mygig_num(s #> '{waiting,perMin}', 0.3)) end
       || jsonb_build_object('on', public.mygig_bool(pr #> '{wait,on}', true) and public.mygig_bool(s #> '{waiting,on}', true),
                             'cap', public.mygig_num(s #> '{waiting,cap}', 60));

  v_sub := round(v_fare + v_busy + v_lug + v_fees + v_appr, 2);
  rp := public.mygig_region_pricing(p_place->>'country', p_place->>'state', p_place->>'city', p_place->>'suburb');
  if rp->>'taxName' is not null then
    v_tax := round(case when rp->>'taxKind' = 'fixed' then public.mygig_num(rp->'taxValue', 0)
                        else v_sub * public.mygig_num(rp->'taxValue', 0) / 100 end, 2);
  end if;
  v_exact := round(v_sub + v_tax, 2);
  v_round := public.mygig_bool(pr->'roundUp', false) or public.mygig_bool(rp->'wholeFare', false);
  v_total := case when v_round then ceil(v_exact - 0.000001) else v_exact end;
  -- The same trip booked in the app: get.ride's fare, the place fees and the tax.
  v_app_fare := round(greatest(public.mygig_num(gcard->'min', 0),
                               public.mygig_num(gcard->'base', 0) + public.mygig_num(gcard->'perKm', 0) * km
                               + public.mygig_num(gcard->'perMin', 0) * mins), 2);
  v_app := round(v_app_fare + v_fees + case when rp->>'taxName' is null then 0
                   when rp->>'taxKind' = 'fixed' then public.mygig_num(rp->'taxValue', 0)
                   else (v_app_fare + v_fees) * public.mygig_num(rp->'taxValue', 0) / 100 end, 2);
  return jsonb_build_object(
    'km', km, 'min', mins, 'ownFare', own, 'card', card,
    'fare', v_fare,
    'busy', v_busy, 'busyLabel', v_busy_label,
    'luggage', v_lug, 'bags', p_trip->'bags',
    'approach', v_appr, 'approachFull', v_appr_full, 'approachKm', v_akm,
    'approachWaived', public.mygig_bool(p_trip->'waiveApproach', false) and v_appr_full > 0,
    'placeFees', v_fees, 'pickupFee', v_pick_fee, 'dropFee', v_drop_fee,
    'feeLines', coalesce(pf->'lines', '[]'::jsonb),
    'pickupFeeName', pf #>> '{pickup,name}', 'dropFeeName', pf #>> '{drop,name}',
    'wait', w,
    'sub', v_sub,
    'taxName', rp->>'taxName', 'taxKind', rp->>'taxKind', 'taxValue', public.mygig_num(rp->'taxValue', 0),
    'tax', v_tax, 'showTax', public.mygig_bool(pr->'showTax', true),
    'exact', v_exact, 'rounded', round(v_total - v_exact, 2), 'total', round(v_total, 2),
    'roundUp', v_round,
    'appPrice', v_app,
    'guard', v_guard > 0 and v_guard < 99 and v_total > round(v_app * v_guard, 2),
    'guardTimes', v_guard,
    'place', p_place,
    'at', p_at);
end;
$$;
revoke execute on function public.mygig_price(uuid, jsonb, jsonb, jsonb, jsonb, timestamptz) from public, anon, authenticated;

-- What the passenger may be charged after the fact: only a registered
-- passenger paying in the app (GET.wallet, Family, business).
create or replace function public.mygig_terms(p_registered boolean, p_pay text, s jsonb, pr jsonb, q jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'canCharge', can,
    'noShowFee', case when can and public.mygig_bool(s #> '{noShow,on}', true) and public.mygig_bool(pr #> '{noShow,on}', false)
                      then least(public.mygig_num(pr #> '{noShow,amount}', 0), public.mygig_num(s #> '{noShow,max}', 10)) else 0 end,
    'cancelFee', case when can and public.mygig_bool(s #> '{cancel,on}', true) and public.mygig_bool(pr #> '{cancel,on}', false)
                      then least(public.mygig_num(pr #> '{cancel,amount}', 0), public.mygig_num(s #> '{cancel,max}', 10)) else 0 end,
    'cancelFreeMin', public.mygig_num(s #> '{cancel,freeMin}', 2),
    'wait', q->'wait')
    from (select coalesce(p_registered, false) and p_pay in ('wallet', 'family', 'business') as can) x;
$$;

-- The app's quote: the price and the place problems, nothing written.
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
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  pl := coalesce(public.mygig_place((p_trip #>> '{pickup,lat}')::float8, (p_trip #>> '{pickup,lng}')::float8), '{}'::jsonb);
  s := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  pr := public.mygig_prefs_of(v_uid, s);
  t := public.mygig_trip_clean(p_trip, s);
  return public.mygig_price(v_uid, t, s, pr, pl, now())
    || jsonb_build_object('problem', public.mygig_place_problem(t), 'trip', t);
end;
$$;
revoke execute on function public.mygig_quote(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_quote(jsonb, double precision, double precision) to authenticated;

-- ---- 6. The passenger's phone ---------------------------------------------------------------------------
-- A name as the admin lets drivers see it: full, partly hidden (Ai**a) or hidden.
create or replace function public.mygig_mask_name(p_name text, p_mode text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when btrim(coalesce(p_name, '')) = '' then null
    when p_mode = 'hide' then 'Registered passenger'
    when p_mode = 'full' then btrim(p_name)
    else (select case when char_length(f) <= 3 then left(f, 1) || '**'
                      else left(f, 2) || repeat('*', char_length(f) - 3) || right(f, 1) end
            from (select split_part(btrim(p_name), ' ', 1) f) x) end;
$$;

-- An ID or passport number: full, the last 4, or hidden (the default is the last 4).
create or replace function public.mygig_mask_id(p_id text, p_mode text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when btrim(coalesce(p_id, '')) = '' or p_mode = 'hide' then null
    when p_mode = 'full' then btrim(p_id)
    else '•••• ' || right(regexp_replace(p_id, '[^0-9A-Za-z]', '', 'g'), 4) end;
$$;

-- What a number is to this driver: {state: latest | old | none | blocked,
-- name, id, version, family, businesses, repeat, flagged}.
create or replace function public.mygig_lookup_inner(p_uid uuid, p_digits text, s jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.profiles;
  v_latest text;
  v_state text;
  v_repeat int;
  fam jsonb;
  biz jsonb;
  m public.family_members;
  v_host text;
begin
  if p_digits is null or char_length(p_digits) < 9 then
    return jsonb_build_object('state', 'short');
  end if;
  select count(*) into v_repeat from public.ride_requests r
   where r.mygig is not null and r.created_at > now() - interval '7 days'
     and public.mygig_phone_digits(r.mygig->>'phone') = p_digits;
  if exists (select 1 from public.mygig_blocked_numbers b where b.driver_id = p_uid and b.digits = p_digits) then
    return jsonb_build_object('state', 'blocked', 'digits', p_digits);
  end if;
  select * into p from public.profiles x
   where regexp_replace(coalesce(x.phone, ''), '\D', '', 'g') = p_digits and x.deleted_at is null
   order by x.created_at limit 1;
  if p.id is null or p.id = p_uid then
    return jsonb_build_object('state', 'none', 'digits', p_digits, 'repeat', v_repeat,
                              'flagged', v_repeat >= public.mygig_num(s->'repeatFlag', 4));
  end if;
  v_latest := public.mygig_latest_version(p.app_platform);
  v_state := case when v_latest is null or (p.app_version is not null and public.mygig_version_ge(p.app_version, v_latest))
                  then 'latest' else 'old' end;
  if p.app_version is null and v_latest is not null then
    v_state := 'old';
  end if;
  -- Family: the member's host pays within the member's limits (0317).
  select * into m from public.family_members x where x.profile_id = p.id and x.status = 'active' and x.kind = 'member'
   limit 1;
  if m.id is not null then
    select coalesce(nullif(btrim(h.name), ''), 'Family host') into v_host
      from public.families f join public.profiles h on h.id = f.host_id where f.id = m.family_id;
    if coalesce((public.family_module_rule_at('mygig',
                  public.family_place_of((select f from public.families f where f.id = m.family_id)))->>'familyPays')::boolean, false) then
      fam := jsonb_build_object('host', split_part(v_host, ' ', 1), 'left', public.family_month_left(m.id),
                                'perRide', m.per_ride_limit);
    end if;
  end if;
  select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name) into biz
    from public.business_members bm join public.business_accounts a on a.id = bm.account_id
   where bm.profile_id = p.id and bm.status = 'active' and a.status = 'active';
  return jsonb_build_object(
    'state', v_state, 'digits', p_digits,
    'name', public.mygig_mask_name(p.name, s->>'nameMode'),
    'first', case when s->>'nameMode' = 'full' then split_part(btrim(coalesce(p.name, '')), ' ', 1) end,
    'idType', case when s->>'idMode' <> 'hide' and btrim(coalesce(p.ic, '')) <> ''
                   then case lower(coalesce(p.id_type, '')) when 'mykad' then 'MyKad' when 'mypr' then 'MyPR'
                                                            when 'passport' then 'Passport' else 'ID' end end,
    'id', public.mygig_mask_id(p.ic, s->>'idMode'),
    'version', p.app_version, 'latest', v_latest,
    'family', fam, 'businesses', coalesce(biz, '[]'::jsonb),
    'repeat', v_repeat, 'flagged', false);
end;
$$;
revoke execute on function public.mygig_lookup_inner(uuid, text, jsonb) from public, anon, authenticated;

create or replace function public.mygig_lookup_phone(p_phone text, p_lat double precision default null,
                                                     p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  st jsonb;
  v_wait int;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  st := public.mygig_require(v_uid, p_lat, p_lng, true);
  v_wait := public.auth_rate_take('mygig_lookup', v_uid::text,
                                  greatest(5, public.mygig_num(st #> '{settings,lookupPer10Min}', 30)::int),
                                  interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001',
      hint = 'Too many numbers checked. Try again in a few minutes.';
  end if;
  return public.mygig_lookup_inner(v_uid, public.mygig_phone_digits(p_phone), st->'settings');
end;
$$;
revoke execute on function public.mygig_lookup_phone(text, double precision, double precision) from public, anon;
grant execute on function public.mygig_lookup_phone(text, double precision, double precision) to authenticated;

-- ---- 7. Offers --------------------------------------------------------------------------------------------
create or replace function public.mygig_token_hash(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex');
$$;

create or replace function public.mygig_link_url(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'https://getride.my/gig/' || p_token;
$$;

-- The driver as the passenger sees them.
create or replace function public.mygig_driver_card(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'name', split_part(btrim(coalesce(p.name, 'Your driver')), ' ', 1),
    'rating', coalesce((select pt.rating from public.partners pt where pt.auth_user_id = p_uid order by pt.created_at limit 1), 5),
    'plate', public.dispatch_driver_car(p_uid)->>'plate',
    'vehicle', public.dispatch_driver_car(p_uid)->>'vehicle')
    from public.profiles p where p.id = p_uid;
$$;
revoke execute on function public.mygig_driver_card(uuid) from public, anon, authenticated;

-- Sends offer [o] the way it says: a push to the app, an SMS link through
-- the gateway (trip_share), or nothing to send (WhatsApp goes from the
-- driver's phone, "here" is on it).
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
begin
  v_text := case when o.kind = 'change'
    then format('get.ride: %s asks you to accept a new price, %s. Open: %s', d->>'name', public.mygig_money(o.total), v_url)
    else format('get.ride: %s sent you a myGiG ride to %s for %s. Accept it here: %s', d->>'name',
                o.trip #>> '{drop,name}', public.mygig_money(o.total), v_url) end;
  if o.way = 'app' and o.passenger_id is not null then
    perform public.enqueue_notification(o.passenger_id, 'mygig-offer-' || o.id || '-' || o.sends, 'ride_status', 'critical',
      case when o.kind = 'change' then 'New price for your ride' else 'Accept your ride?' end,
      case when o.kind = 'change' then format('%s changed the trip: %s. Tap to accept.', d->>'name', public.mygig_money(o.total))
           else format('%s has sent you a myGiG ride: %s to %s. Tap to accept.', d->>'name',
                       public.mygig_money(o.total), o.trip #>> '{drop,name}') end,
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

-- An offer that waited past its time ends (nothing saved).
create or replace function public.mygig_expire(p_driver uuid default null)
returns integer
language sql
security definer
set search_path = public
as $$
  with x as (
    update public.mygig_offers set status = 'expired', answered_at = now()
     where status = 'waiting' and expires_at <= now() and (p_driver is null or driver_id = p_driver)
    returning 1)
  select count(*)::int from x;
$$;
revoke execute on function public.mygig_expire(uuid) from public, anon, authenticated;

-- The ways the admin allows, for what the number is.
create or replace function public.mygig_ways(s jsonb, p_lookup text, p_has_phone boolean)
returns text[]
language sql
immutable
set search_path = public
as $$
  select array_remove(array[
    case when p_lookup = 'latest' and public.mygig_bool(s #> '{ways,app}', true) then 'app' end,
    case when p_has_phone and public.mygig_bool(s #> '{ways,whatsapp}', true) then 'whatsapp' end,
    case when p_has_phone and public.mygig_bool(s #> '{ways,sms}', true) then 'sms' end,
    case when public.mygig_bool(s #> '{ways,here}', true) then 'here' end], null);
$$;

-- The driver sends a myGiG: {trip, phone, name, way}. Checked here (access,
-- places, phone, name, payment, way), priced by the server, kept as an
-- offer until the passenger answers. Returns the offer, the token (for the
-- link and "here"), the link and the message.
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
  v_digits text;
  v_phone text;
  v_name text := nullif(left(btrim(coalesce(p->>'name', '')), 80), '');
  v_way text := p->>'way';
  v_lookup text;
  v_pid uuid;
  v_token text := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  o public.mygig_offers;
  v_sent jsonb;
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
  t := public.mygig_trip_clean(p->'trip', s);
  prob := public.mygig_place_problem(t);
  if prob is not null then
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
       select 1 from jsonb_array_elements(coalesce(lk->'businesses', '[]'::jsonb)) b where b->>'id' = t->>'businessId') then
    raise exception 'MYGIG_PAY' using errcode = '22023', hint = 'Choose one of the passenger''s business accounts.';
  end if;
  -- How they accept.
  if v_way is null or not (v_way = any (public.mygig_ways(s, v_lookup, v_phone is not null))) then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'Choose how the passenger accepts the fare.';
  end if;
  if t->>'pay' = 'family' and v_way <> 'app' then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'A Family ride is accepted in the passenger''s app.';
  end if;

  -- Cash: the commission and the myGiG fee come off GET.credit at the end,
  -- so a driver below the minimum takes no cash myGiG (0218's setting).
  if t->>'pay' = 'cash' and not public.commission_credit_ok(v_uid) then
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = 'Your GET.credit is below the minimum for cash trips. Top up, or ask for another way to pay.';
  end if;
  q := public.mygig_price(v_uid, t, s, pr, pl, now());
  q := q || jsonb_build_object('terms', public.mygig_terms(v_pid is not null, t->>'pay', s, pr, q),
                               'tripFee', st->'fee', 'lookup', v_lookup, 'shownName', v_name,
                               'idShown', lk->'id', 'idType', lk->'idType', 'flagged', coalesce((lk->>'flagged')::boolean, false),
                               'repeat', coalesce((lk->>'repeat')::int, 0));
  insert into public.mygig_offers (kind, driver_id, passenger_id, passenger_name, phone, lookup, way, token_hash,
                                   trip, quote, total, expires_at)
  values ('new', v_uid, v_pid, v_name, v_phone, v_lookup, v_way, public.mygig_token_hash(v_token),
          t, q, (q->>'total')::numeric,
          now() + make_interval(secs => greatest(30, least(1800, public.mygig_num(s->'acceptWaitSec', 120)::int))))
  returning * into o;
  v_sent := public.mygig_send(o, v_token);
  return jsonb_build_object('offerId', o.id, 'token', v_token, 'way', o.way, 'expiresAt', o.expires_at,
                            'total', o.total, 'quote', q, 'link', v_sent->>'link', 'message', v_sent->>'message',
                            'phone', v_phone);
end;
$$;
revoke execute on function public.mygig_create(jsonb, double precision, double precision) from public, anon;
grant execute on function public.mygig_create(jsonb, double precision, double precision) to authenticated;

-- The driver's offer, as their waiting screen reads it.
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
    'driver', public.mygig_driver_card(o.driver_id));
$$;
revoke execute on function public.mygig_offer_json(public.mygig_offers) from public, anon, authenticated;

create or replace function public.mygig_offer_status(p_offer uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
begin
  perform public.mygig_expire(auth.uid());
  select * into o from public.mygig_offers where id = p_offer;
  if not found or (o.driver_id is distinct from auth.uid() and o.passenger_id is distinct from auth.uid()) then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  return public.mygig_offer_json(o);
end;
$$;
revoke execute on function public.mygig_offer_status(uuid) from public, anon;
grant execute on function public.mygig_offer_status(uuid) to authenticated;

-- The driver: send it again (a new token), or another way.
create or replace function public.mygig_resend(p_offer uuid, p_way text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
  s jsonb;
  v_token text := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_sent jsonb;
begin
  perform public.mygig_expire(auth.uid());
  select * into o from public.mygig_offers where id = p_offer for update;
  if not found or o.driver_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if o.status <> 'waiting' then
    raise exception 'MYGIG_ANSWERED' using errcode = '22023', hint = 'The passenger already answered, or it ended.';
  end if;
  s := public.mygig_settings_at(o.quote #>> '{place,country}', o.quote #>> '{place,state}',
                                o.quote #>> '{place,city}', o.quote #>> '{place,suburb}');
  if p_way is not null and p_way <> o.way then
    if not (p_way = any (public.mygig_ways(s, o.lookup, o.phone is not null))) then
      raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'That way isn''t available for this passenger.';
    end if;
    if o.quote #>> '{trip,pay}' = 'family' and p_way <> 'app' then
      raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'A Family ride is accepted in the passenger''s app.';
    end if;
  end if;
  update public.mygig_offers
     set way = coalesce(p_way, way), token_hash = public.mygig_token_hash(v_token), sends = least(50, sends + 1),
         expires_at = now() + make_interval(secs => greatest(30, least(1800, public.mygig_num(s->'acceptWaitSec', 120)::int)))
   where id = o.id
  returning * into o;
  v_sent := public.mygig_send(o, v_token);
  return public.mygig_offer_json(o) || jsonb_build_object('token', v_token, 'link', v_sent->>'link',
                                                         'message', v_sent->>'message');
end;
$$;
revoke execute on function public.mygig_resend(uuid, text) from public, anon;
grant execute on function public.mygig_resend(uuid, text) to authenticated;

create or replace function public.mygig_cancel_offer(p_offer uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
begin
  update public.mygig_offers set status = 'cancelled', answered_at = now()
   where id = p_offer and driver_id = auth.uid() and status = 'waiting'
  returning * into o;
  if not found then
    select * into o from public.mygig_offers where id = p_offer and driver_id = auth.uid();
    if not found then
      raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return public.mygig_offer_json(o);
end;
$$;
revoke execute on function public.mygig_cancel_offer(uuid) from public, anon;
grant execute on function public.mygig_cancel_offer(uuid) to authenticated;

-- The ride's fare and its place-fee lines for a price [q]: the place fees
-- go on the ride as 0324 stamps them (charges, so the place's share is
-- paid as for any ride), the tax as its own fixed line, and the fare is
-- the rest, so ride_amount_due is the price agreed. airport_fare marks the
-- row as priced by the server, so 0249's trigger keeps it as it is.
create or replace function public.mygig_ride_money(q jsonb, p_total numeric, p_tax numeric)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'fare', round(p_total - coalesce(p_tax, 0) - fees, 2),
    'charges', case when jsonb_array_length(lines) > 0 then lines end,
    'airportFare', jsonb_build_object(
      'how', 'myGiG', 'fixed', true, 'fare', round(p_total - coalesce(p_tax, 0) - fees, 2),
      'normal', round(p_total - coalesce(p_tax, 0) - fees, 2), 'charge', fees,
      'total', round(p_total - coalesce(p_tax, 0), 2),
      'lines', jsonb_build_array(jsonb_build_object('label', 'myGiG fare', 'amount', round(p_total - coalesce(p_tax, 0) - fees, 2)))
               || coalesce((select jsonb_agg(jsonb_build_object('label', l->>'name', 'amount', (l->>'value')::numeric, 'charge', true))
                              from jsonb_array_elements(lines) l), '[]'::jsonb)))
    from (select coalesce(public.mygig_num(q->'placeFees', 0), 0) fees,
                 case when jsonb_typeof(q->'feeLines') = 'array' then q->'feeLines' else '[]'::jsonb end lines) x;
$$;

-- The ride row an accepted offer becomes.
create or replace function public.mygig_make_ride(o public.mygig_offers, p_via text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := gen_random_uuid();
  t jsonb := o.trip;
  q jsonb := o.quote;
  v_pay text := t->>'pay';
  d public.profiles;
  pt public.partners;
  car jsonb := public.dispatch_driver_car(o.driver_id);
  pl jsonb := coalesce(q->'place', '{}'::jsonb);
  v_share uuid := gen_random_uuid();
  v_fare numeric;
  v_money jsonb;
  v_here boolean := public.mygig_bool(o.trip #> '{pickup,here}', false);
  v_wait_on boolean := public.mygig_bool(o.quote #> '{wait,on}', true);
  s jsonb := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
begin
  -- Gone over the daily limit while it waited, or a ride started meanwhile.
  if public.mygig_active_ride(o.driver_id) is not null then
    raise exception 'MYGIG_DRIVER_BUSY' using errcode = '22023', hint = 'The driver has another ride on the go.';
  end if;
  if public.mygig_num(s->'dailyLimit', 0) > 0
     and public.mygig_today_count(o.driver_id, s->>'timezone') >= public.mygig_num(s->'dailyLimit', 0) then
    raise exception 'MYGIG_LIMIT' using errcode = '42501', hint = 'The driver reached today''s myGiG limit.';
  end if;
  select * into d from public.profiles where id = o.driver_id;
  select * into pt from public.partners where auth_user_id = o.driver_id order by created_at limit 1;
  -- The fare is the price less its tax: the tax is its own fixed line, so
  -- ride_amount_due (and the receipt) add up to the price agreed.
  v_money := public.mygig_ride_money(q, (q->>'total')::numeric, (q->>'tax')::numeric);
  v_fare := (v_money->>'fare')::numeric;
  insert into public.ride_requests (
    id, rider_id, rider_name, rider_phone, service, payment_mode, business_account_id,
    pickup_name, pickup_address, pickup_lat, pickup_lng, drop_name, drop_address, drop_lat, drop_lng,
    distance_km, duration_min, fare, ride_fare, passengers, luggage, stops, round_trip,
    country, state, city, suburb, whole_fare, tax_name, tax_kind, tax_value, timezone,
    status, partner_id, partner_name, partner_phone, partner_photo, partner_vehicle, partner_plate, partner_rating,
    accepted_at, arrived_at, waiting_from, waiting_terms, start_method, mygig, family, booked_for_other, charges, airport_fare)
  values (
    v_id, o.passenger_id, coalesce(o.passenger_name, 'myGiG passenger'), o.phone, t->>'service',
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
    o.driver_id, coalesce(pt.name, d.name), coalesce(pt.phone, d.phone), coalesce(pt.avatar_url, d.avatar_url),
    car->>'vehicle', car->>'plate', coalesce(pt.rating, 5),
    now(), case when v_here then now() end,
    case when v_here and v_wait_on then now() end,
    case when v_here and v_wait_on then jsonb_build_object(
      'freeMinutes', public.mygig_num(q #> '{wait,freeMin}', 0), 'perMinute', public.mygig_num(q #> '{wait,perMin}', 0),
      'cap', public.mygig_num(q #> '{wait,cap}', 60)) end,
    null,
    jsonb_build_object(
      'offerId', o.id, 'way', o.way, 'via', p_via, 'registered', o.passenger_id is not null,
      'lookup', o.lookup, 'phone', o.phone, 'shownName', o.passenger_name, 'pay', v_pay,
      'quote', q, 'terms', q->'terms', 'tripFee', q->'tripFee', 'tokenHash', o.token_hash,
      'stopWaitMin', 0, 'acceptedAt', now(), 'flagged', coalesce((q->>'flagged')::boolean, false)),
    null, false, nullif(v_money->'charges', 'null'::jsonb), v_money->'airportFare');
  -- The trip link follows the ride (the shared ride page, 0108 / 0220).
  insert into public.ride_request_private as x (request_id, share_token)
  values (v_id, v_share)
  on conflict (request_id) do update set share_token = coalesce(x.share_token, excluded.share_token), updated_at = now();
  update public.mygig_offers set ride_id = v_id where id = o.id;
  return v_id;
end;
$$;
revoke execute on function public.mygig_make_ride(public.mygig_offers, text) from public, anon, authenticated;

-- A 'change' accepted: the ride takes the new route and price.
create or replace function public.mygig_apply_change(o public.mygig_offers)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  q jsonb := o.quote;
  t jsonb := o.trip;
  v_money jsonb := public.mygig_ride_money(o.quote, (o.quote->>'total')::numeric, (o.quote->>'tax')::numeric);
  v_fare numeric := (v_money->>'fare')::numeric;
begin
  select * into r from public.ride_requests where id = o.ride_id for update;
  if not found or r.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'MYGIG_RIDE_OVER' using errcode = '22023', hint = 'The ride has ended.';
  end if;
  update public.ride_requests
     set drop_name = t #>> '{drop,name}', drop_address = t #>> '{drop,address}',
         drop_lat = (t #>> '{drop,lat}')::float8, drop_lng = (t #>> '{drop,lng}')::float8,
         stops = coalesce((select jsonb_agg(jsonb_build_object('name', x->>'name', 'address', x->>'address',
                                                               'lat', (x->>'lat')::float8, 'lng', (x->>'lng')::float8))
                             from jsonb_array_elements(t->'stops') x), '[]'::jsonb),
         distance_km = (q->>'km')::numeric, duration_min = (q->>'min')::numeric::int,
         fare = v_fare, ride_fare = v_fare, charges = nullif(v_money->'charges', 'null'::jsonb), airport_fare = v_money->'airportFare',
         tax_name = case when coalesce((q->>'tax')::numeric, 0) > 0 then coalesce(q->>'taxName', 'Tax') end,
         tax_kind = case when coalesce((q->>'tax')::numeric, 0) > 0 then 'fixed' end,
         tax_value = case when coalesce((q->>'tax')::numeric, 0) > 0 then (q->>'tax')::numeric end,
         mygig = r.mygig || jsonb_build_object('quote', q || jsonb_build_object('terms', r.mygig #> '{quote,terms}',
                                                                                 'tripFee', r.mygig #> '{quote,tripFee}'),
                                               'changes', coalesce(r.mygig->'changes', '[]'::jsonb)
                                                 || jsonb_build_array(jsonb_build_object('offerId', o.id, 'at', now(),
                                                      'from', r.mygig #> '{quote,total}', 'to', q->'total')))
   where id = r.id;
end;
$$;
revoke execute on function public.mygig_apply_change(public.mygig_offers) from public, anon, authenticated;

-- Accepting, whichever way: the offer (locked, still waiting) becomes a ride.
create or replace function public.mygig_accept_offer(o public.mygig_offers, p_via text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride uuid;
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
  else
    v_ride := public.mygig_make_ride(o, p_via);
  end if;
  update public.mygig_offers set status = 'accepted', answered_at = now(), answered_via = p_via where id = o.id;
  perform public.enqueue_notification(o.driver_id, 'mygig-answer-' || o.id, 'ride_status', 'critical',
    case when o.kind = 'change' then 'New price accepted' else 'Fare accepted' end,
    case when o.kind = 'change' then 'The passenger accepted the new price. Carry on.'
         else format('The passenger accepted %s. Your trip is on.', public.mygig_money(o.total)) end,
    jsonb_build_object('type', 'mygig_answer', 'offer_id', o.id, 'request_id', v_ride, 'role', 'partner'), v_ride);
  return jsonb_build_object('offerId', o.id, 'rideId', v_ride, 'status', 'accepted', 'kind', o.kind);
end;
$$;
revoke execute on function public.mygig_accept_offer(public.mygig_offers, text) from public, anon, authenticated;

create or replace function public.mygig_decline_offer(o public.mygig_offers, p_via text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if o.status <> 'waiting' then
    return jsonb_build_object('offerId', o.id, 'status', o.status);
  end if;
  update public.mygig_offers set status = 'declined', answered_at = now(), answered_via = p_via where id = o.id;
  perform public.enqueue_notification(o.driver_id, 'mygig-answer-' || o.id, 'ride_status', 'critical',
    case when o.kind = 'change' then 'Route not changed' else 'Fare declined' end,
    case when o.kind = 'change' then 'The passenger didn''t accept the new price. Carry on with the route they accepted.'
         else 'The passenger didn''t accept the fare. Nothing was saved or charged.' end,
    jsonb_build_object('type', 'mygig_answer', 'offer_id', o.id, 'request_id', o.ride_id, 'role', 'partner'), o.ride_id);
  return jsonb_build_object('offerId', o.id, 'status', 'declined', 'kind', o.kind);
end;
$$;
revoke execute on function public.mygig_decline_offer(public.mygig_offers, text) from public, anon, authenticated;

-- The passenger in their app.
create or replace function public.mygig_accept(p_offer uuid, p_accept boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
begin
  select * into o from public.mygig_offers where id = p_offer for update;
  if not found or auth.uid() is null or o.passenger_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not coalesce(p_accept, true) then
    return public.mygig_decline_offer(o, 'app');
  end if;
  return public.mygig_accept_offer(o, 'app');
end;
$$;
revoke execute on function public.mygig_accept(uuid, boolean) from public, anon;
grant execute on function public.mygig_accept(uuid, boolean) to authenticated;

-- The passenger's offers waiting in their app (newest first).
create or replace function public.mygig_my_offers()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.mygig_offer_json(o) - 'phone' order by o.created_at desc), '[]'::jsonb)
    from public.mygig_offers o
   where o.passenger_id = auth.uid() and o.status = 'waiting' and o.expires_at > now();
$$;
revoke execute on function public.mygig_my_offers() from public, anon;
grant execute on function public.mygig_my_offers() to authenticated;

-- The driver's phone, turned to the passenger.
create or replace function public.mygig_accept_here(p_offer uuid, p_accept boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
begin
  select * into o from public.mygig_offers where id = p_offer for update;
  if not found or auth.uid() is null or o.driver_id is distinct from auth.uid() then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if o.way <> 'here' then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'Switch to "Show on this phone" first.';
  end if;
  if not coalesce(p_accept, true) then
    return public.mygig_decline_offer(o, 'here');
  end if;
  return public.mygig_accept_offer(o, 'here');
end;
$$;
revoke execute on function public.mygig_accept_here(uuid, boolean) from public, anon;
grant execute on function public.mygig_accept_here(uuid, boolean) to authenticated;

-- The trip link (no sign-in): what the page shows. Only what the passenger
-- needs: the driver's first name, car, plate and rating, the route, the
-- price lines, the app price when the guard is over, and, once accepted,
-- the ride's share token for the live ride and the receipt.
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
    select * into r from public.ride_requests x where x.mygig->>'tokenHash' = public.mygig_token_hash(p_token);
    if r.id is null then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
    end if;
    select * into o from public.mygig_offers where id = (r.mygig->>'offerId')::uuid;
  end if;
  if o.ride_id is not null then
    select * into r from public.ride_requests where id = o.ride_id;
    -- A new price waiting for the passenger shows on the first link too.
    select * into c from public.mygig_offers x
     where x.ride_id = o.ride_id and x.kind = 'change' and x.status = 'waiting' and x.expires_at > now()
     order by x.created_at desc limit 1;
    if c.id is not null then
      o := c;
    end if;
  end if;
  if r.id is not null and r.status in ('completed', 'cancelled')
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
                               'bags', o.trip->'bags', 'pay', o.trip->'pay'),
    'quote', jsonb_build_object('km', q->'km', 'min', q->'min', 'fare', q->'fare', 'busy', q->'busy',
                                'busyLabel', q->'busyLabel', 'luggage', q->'luggage', 'approach', q->'approach',
                                'approachKm', q->'approachKm', 'pickupFee', q->'pickupFee', 'dropFee', q->'dropFee',
                                'pickupFeeName', q->'pickupFeeName', 'dropFeeName', q->'dropFeeName',
                                'tax', q->'tax', 'taxName', q->'taxName', 'showTax', q->'showTax',
                                'rounded', q->'rounded', 'total', q->'total', 'guard', q->'guard',
                                'appPrice', case when (q->>'guard')::boolean then q->'appPrice' end,
                                'terms', q->'terms'),
    'expiresAt', o.expires_at,
    'ride', case when r.id is not null then jsonb_build_object(
      'status', r.status,
      'shareToken', (select x.share_token from public.ride_request_private x where x.request_id = r.id),
      'total', public.ride_amount_due(r),
      'paymentStatus', r.payment_status,
      'cancelFee', case when r.accepted_at < now() - make_interval(
                               secs => (coalesce((r.mygig #>> '{terms,cancelFreeMin}')::numeric, 2) * 60)::int)
                        then coalesce((r.mygig #>> '{terms,cancelFee}')::numeric, 0) else 0 end,
      'canCancel', r.status in ('accepted', 'arrived'),
      'owed', public.mygig_owed(r), 'linkPaid', coalesce((r.mygig->>'linkPaid')::numeric, 0),
      'payUrl', case when public.mygig_owed(r) > 0 then r.mygig->>'payUrl' end,
      'waitingCharge', coalesce(r.waiting_charge, 0) + coalesce((r.mygig->>'stopWaitCharge')::numeric, 0)) end);
end;
$$;
revoke execute on function public.mygig_link_view(text) from public;
grant execute on function public.mygig_link_view(text) to anon, authenticated;

create or replace function public.mygig_link_answer(p_token text, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
  c public.mygig_offers;
  v_wait int;
begin
  v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
  end if;
  select * into o from public.mygig_offers where token_hash = public.mygig_token_hash(p_token) for update;
  if not found then
    raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
  end if;
  -- The first link answers a new price waiting on its ride, too.
  if o.status = 'accepted' and o.ride_id is not null then
    select * into c from public.mygig_offers x
     where x.ride_id = o.ride_id and x.kind = 'change' and x.status = 'waiting'
     order by x.created_at desc limit 1
     for update;
    if c.id is not null then
      o := c;
    end if;
  end if;
  if o.way not in ('sms', 'whatsapp') then
    raise exception 'MYGIG_WAY' using errcode = '22023', hint = 'The driver asked another way. Ask them to send the link again.';
  end if;
  if not coalesce(p_accept, false) then
    return public.mygig_decline_offer(o, 'link');
  end if;
  return public.mygig_accept_offer(o, 'link');
end;
$$;
revoke execute on function public.mygig_link_answer(text, boolean) from public;
grant execute on function public.mygig_link_answer(text, boolean) to anon, authenticated;

-- ---- 8. The ride --------------------------------------------------------------------------------------------
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
  return r;
end;
$$;
revoke execute on function public.mygig_ride_for_driver(uuid) from public, anon, authenticated;

-- I've arrived: the waiting clock starts on the agreed terms (0314's
-- columns, so both apps run the same clock; picked up, it is charged).
create or replace function public.mygig_arrived(p_ride uuid, p_lat double precision default null,
                                                p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  w jsonb := r.mygig #> '{quote,wait}';
begin
  if r.status <> 'accepted' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'You already arrived.';
  end if;
  update public.ride_requests
     set status = 'arrived', arrived_at = now(),
         partner_arrive_lat = coalesce(p_lat, partner_arrive_lat), partner_arrive_lng = coalesce(p_lng, partner_arrive_lng),
         waiting_from = case when public.mygig_bool(w->'on', true) then now() end,
         waiting_terms = case when public.mygig_bool(w->'on', true) then jsonb_build_object(
           'freeMinutes', public.mygig_num(w->'freeMin', 0), 'perMinute', public.mygig_num(w->'perMin', 0),
           'cap', public.mygig_num(w->'cap', 60)) end
   where id = r.id;
  return jsonb_build_object('status', 'arrived');
end;
$$;
revoke execute on function public.mygig_arrived(uuid, double precision, double precision) from public, anon;
grant execute on function public.mygig_arrived(uuid, double precision, double precision) to authenticated;

-- No losses to get.ride or the driver (owner's rule). What a pay-by-link
-- passenger paid so far: by link (paid to the driver's GET.wallet as it
-- comes in) and cash the driver confirmed (at the pickup, or instead of a
-- link).
create or replace function public.mygig_paid_so_far(r public.ride_requests)
returns numeric
language sql
immutable
set search_path = public
as $$
  select round(coalesce((r.mygig->>'linkPaid')::numeric, 0) + coalesce((r.mygig->>'cashPaid')::numeric, 0), 2);
$$;

-- What a pay-by-link passenger owes now: before the trip, the agreed price
-- (an accepted change included); at Complete, the final total with the
-- tolls, other charges and waiting; less what they paid.
create or replace function public.mygig_owed(r public.ride_requests)
returns numeric
language sql
stable
set search_path = public
as $$
  select case
    when r.mygig is null or r.mygig->>'pay' <> 'link' or r.payment_status = 'paid' then 0
    when r.status = 'completed' then greatest(0, round(public.ride_left_to_pay(r) - public.mygig_paid_so_far(r), 2))
    else greatest(0, round(coalesce((r.mygig #>> '{pendingFinal,due}')::numeric, (r.mygig #>> '{quote,total}')::numeric, 0)
                           - public.mygig_paid_so_far(r), 2)) end;
$$;

-- Start trip: no trip code (the passenger is with the driver and agreed).
-- From 'accepted' too, when the pickup is where the driver is.
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
begin
  if r.status not in ('accepted', 'arrived') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'This trip already started or ended.';
  end if;
  -- A child's trip still needs the pickup code (0317).
  c := public.family_driver_child(r.id);
  if c is not null and not coalesce((c->>'verified')::boolean, false) then
    raise exception 'FAMILY_CODE_NEEDED' using errcode = '42501', hint = 'Check the child''s photo and enter the pickup code first.';
  end if;
  -- No losses: a pay-by-link passenger pays the agreed price before the trip.
  v_owed := public.mygig_owed(r);
  if r.mygig->>'pay' = 'link' and v_owed > 0.005 then
    raise exception 'MYGIG_PAY_FIRST' using errcode = '42501',
      hint = format('The passenger pays %s by link before the trip starts, or in cash to you.', public.mygig_money(v_owed));
  end if;
  if r.mygig->>'pay' = 'cash' then
    -- Coming to the pickup, paid in cash at the pickup before the trip.
    if v_appr > 0 and r.mygig->>'approachCashAt' is null then
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

-- A cash passenger paid the driver for coming to the pickup (before Start trip).
create or replace function public.mygig_approach_cash(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  v_appr numeric := coalesce((r.mygig #>> '{quote,approach}')::numeric, 0);
begin
  if r.status not in ('accepted', 'arrived') or r.mygig->>'pay' <> 'cash' or v_appr <= 0 then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Nothing to collect for coming to the pickup.';
  end if;
  if r.mygig->>'approachCashAt' is null then
    update public.ride_requests
       set mygig = mygig || jsonb_build_object('approachCashAt', now(),
                     'cashPaid', coalesce((mygig->>'cashPaid')::numeric, 0) + v_appr)
     where id = r.id;
  end if;
  return jsonb_build_object('approachCash', v_appr);
end;
$$;
revoke execute on function public.mygig_approach_cash(uuid) from public, anon;
grant execute on function public.mygig_approach_cash(uuid) to authenticated;

-- Waiting at a stop: started, then ended; every minute counts (the
-- passenger sees it). {stopWaitMin, waiting}.
create or replace function public.mygig_stop_wait(p_ride uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  v_since timestamptz := nullif(r.mygig->>'stopWaitSince', '')::timestamptz;
  v_min int := coalesce((r.mygig->>'stopWaitMin')::int, 0);
  w jsonb := r.mygig #> '{quote,wait}';
begin
  if r.status <> 'on_trip' then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Waiting at a stop is during the trip.';
  end if;
  if not public.mygig_bool(w->'on', true) then
    raise exception 'MYGIG_WAIT_OFF' using errcode = '22023', hint = 'Waiting is free on this ride.';
  end if;
  if coalesce(p_on, false) and v_since is null then
    v_since := now();
  elsif not coalesce(p_on, false) and v_since is not null then
    v_min := v_min + greatest(0, ceil(extract(epoch from (now() - v_since)) / 60))::int;
    v_since := null;
  end if;
  update public.ride_requests
     set mygig = mygig || jsonb_build_object('stopWaitMin', v_min, 'stopWaitSince', v_since,
                                             'stopWaitCharge', round(least(public.mygig_num(w->'cap', 60),
                                                                         v_min * public.mygig_num(w->'perMin', 0)), 2))
   where id = r.id;
  return jsonb_build_object('stopWaitMin', v_min, 'waiting', v_since is not null, 'since', v_since);
end;
$$;
revoke execute on function public.mygig_stop_wait(uuid, boolean) from public, anon;
grant execute on function public.mygig_stop_wait(uuid, boolean) to authenticated;

-- A fee after the fact ([p_kind] 'no_show' or 'late_cancel'): only a
-- registered passenger paying in the app, through the ride's own fee path
-- (0317: from whoever pays the trip, else owed).
create or replace function public.mygig_fee_status(r public.ride_requests, p_fee numeric, p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_fee, 0) <= 0 or r.rider_id is null
     or not coalesce((r.mygig #>> '{terms,canCharge}')::boolean, false) then
    return 'none';
  end if;
  return public.ride_fee_take(r, p_fee, p_kind);
end;
$$;
revoke execute on function public.mygig_fee_status(public.ride_requests, numeric, text) from public, anon, authenticated;

-- Passenger didn't come: after the free minutes since I've arrived.
create or replace function public.mygig_no_show(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  v_free numeric := public.mygig_num(r.mygig #> '{quote,wait,freeMin}', 3);
  v_fee numeric := coalesce((r.mygig #>> '{terms,noShowFee}')::numeric, 0);
  v_status text;
begin
  if r.status <> 'arrived' or r.arrived_at is null then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'Tap I''ve arrived first.';
  end if;
  if r.arrived_at > now() - make_interval(secs => (v_free * 60)::int) then
    raise exception 'MYGIG_TOO_SOON' using errcode = '22023',
      hint = format('Wait the %s free minutes first.', trim_scale(v_free));
  end if;
  v_status := public.mygig_fee_status(r, v_fee, 'no_show');
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'passenger_no_show',
         cancel_requested_by = 'partner',
         cancel_fee = case when v_status = 'none' then 0 else v_fee end, cancel_fee_status = v_status
   where id = r.id;
  return jsonb_build_object('status', 'cancelled', 'fee', case when v_status = 'none' then 0 else v_fee end,
                            'feeStatus', v_status);
end;
$$;
revoke execute on function public.mygig_no_show(uuid) from public, anon;
grant execute on function public.mygig_no_show(uuid) to authenticated;

-- The passenger cancels after accepting, until the trip starts: in the app
-- (signed in) or on the trip link ([p_token]). A fee only per the terms.
create or replace function public.mygig_cancel_ride(p_ride uuid default null, p_token text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fee numeric;
  v_free numeric;
  v_status text;
begin
  if p_token is not null then
    select * into r from public.ride_requests x
     where x.mygig is not null
       and x.id = (select o.ride_id from public.mygig_offers o where o.token_hash = public.mygig_token_hash(p_token)
                    and o.kind = 'new')
     for update;
  else
    select * into r from public.ride_requests x where x.id = p_ride and x.mygig is not null for update;
    if r.id is not null and (auth.uid() is null or r.rider_id is distinct from auth.uid()) then
      r := null;
    end if;
  end if;
  if r.id is null then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if r.status not in ('accepted', 'arrived') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'The trip has started or ended: it can''t be cancelled now.';
  end if;
  v_free := coalesce((r.mygig #>> '{terms,cancelFreeMin}')::numeric, 2);
  v_fee := case when r.accepted_at < now() - make_interval(secs => (v_free * 60)::int)
                then coalesce((r.mygig #>> '{terms,cancelFee}')::numeric, 0) else 0 end;
  v_status := public.mygig_fee_status(r, v_fee, 'late_cancel');
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'passenger_cancelled',
         cancel_requested_by = 'rider', cancel_requested_at = coalesce(cancel_requested_at, now()),
         cancel_fee = case when v_status = 'none' then 0 else v_fee end, cancel_fee_status = v_status
   where id = r.id;
  perform public.enqueue_notification(r.partner_id, 'mygig-cancel-' || r.id, 'ride_status', 'critical',
    'Passenger cancelled',
    case when v_status = 'none' then 'The passenger cancelled the myGiG ride. You''re online for the next request.'
         else format('The passenger cancelled. %s cancellation fee goes to your GET.wallet.', public.mygig_money(v_fee)) end,
    jsonb_build_object('type', 'mygig_cancelled', 'request_id', r.id, 'role', 'partner'), r.id);
  return jsonb_build_object('status', 'cancelled', 'fee', case when v_status = 'none' then 0 else v_fee end,
                            'feeStatus', v_status);
end;
$$;
revoke execute on function public.mygig_cancel_ride(uuid, text) from public;
grant execute on function public.mygig_cancel_ride(uuid, text) to anon, authenticated;

-- Change destination or add a stop: priced again (as accepted: the same
-- prefs, the same coming-to-the-pickup), back to the passenger the same way.
-- {drop?, stops?}. Returns the change offer (with its token for the link
-- and "here").
create or replace function public.mygig_reprice(p_ride uuid, p_change jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.mygig_ride_for_driver(p_ride);
  o0 public.mygig_offers;
  o public.mygig_offers;
  s jsonb;
  pr jsonb;
  t jsonb;
  q jsonb;
  pl jsonb := coalesce(r.mygig #> '{quote,place}', '{}'::jsonb);
  prob jsonb;
  v_token text := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_sent jsonb;
begin
  if r.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'MYGIG_STATE' using errcode = '22023', hint = 'The ride has ended.';
  end if;
  select * into o0 from public.mygig_offers where id = (r.mygig->>'offerId')::uuid;
  update public.mygig_offers set status = 'cancelled', answered_at = now()
   where ride_id = r.id and kind = 'change' and status = 'waiting';
  s := public.mygig_settings_at(pl->>'country', pl->>'state', pl->>'city', pl->>'suburb');
  pr := public.mygig_prefs_of(r.partner_id, s);
  t := o0.trip || jsonb_build_object('drop', coalesce(p_change->'drop', o0.trip->'drop'),
                                     'stops', coalesce(p_change->'stops', o0.trip->'stops'),
                                     'km', p_change->'km', 'min', p_change->'min');
  t := public.mygig_trip_clean(t, s);
  prob := public.mygig_place_problem(t);
  if prob is not null and prob->>'end' = 'drop' then
    raise exception '%', prob->>'code' using errcode = '42501', hint = prob->>'message';
  end if;
  q := public.mygig_price(r.partner_id, t, s, pr, pl, coalesce((r.mygig #>> '{quote,at}')::timestamptz, now()))
       || jsonb_build_object('terms', r.mygig #> '{quote,terms}', 'tripFee', r.mygig #> '{quote,tripFee}',
                             'lookup', o0.lookup, 'shownName', o0.passenger_name);
  insert into public.mygig_offers (kind, driver_id, passenger_id, passenger_name, phone, lookup, way, token_hash,
                                   trip, quote, total, ride_id, expires_at)
  values ('change', r.partner_id, o0.passenger_id, o0.passenger_name, o0.phone, o0.lookup, o0.way,
          public.mygig_token_hash(v_token), t, q, (q->>'total')::numeric, r.id,
          now() + make_interval(secs => greatest(30, least(1800, public.mygig_num(s->'acceptWaitSec', 120)::int))))
  returning * into o;
  v_sent := public.mygig_send(o, v_token);
  return public.mygig_offer_json(o) || jsonb_build_object('token', v_token, 'link', v_sent->>'link',
                                                         'message', v_sent->>'message',
                                                         'was', r.mygig #> '{quote,total}');
end;
$$;
revoke execute on function public.mygig_reprice(uuid, jsonb) from public, anon;
grant execute on function public.mygig_reprice(uuid, jsonb) to authenticated;

-- The final price: the agreed quote's subtotal with the waiting (at the
-- pickup, 0314's columns; at stops, ours), the tax and the rounding again.
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
  v_sub numeric;
  v_tax numeric := 0;
  v_exact numeric;
  v_total numeric;
begin
  v_sub := round(coalesce((q->>'sub')::numeric, 0) + v_wait, 2);
  if q->>'taxName' is not null and coalesce((q->>'taxValue')::numeric, 0) > 0 then
    v_tax := round(case when q->>'taxKind' = 'fixed' then (q->>'taxValue')::numeric
                        else v_sub * (q->>'taxValue')::numeric / 100 end, 2);
  end if;
  v_exact := round(v_sub + v_tax, 2);
  v_total := case when coalesce((q->>'roundUp')::boolean, false) then ceil(v_exact - 0.000001) else v_exact end;
  return jsonb_build_object('waiting', v_wait, 'pickupWaitMin', coalesce(r.waiting_minutes, 0),
                            'stopWaitMin', coalesce((r.mygig->>'stopWaitMin')::int, 0),
                            'sub', v_sub, 'tax', v_tax, 'exact', v_exact, 'rounded', round(v_total - v_exact, 2),
                            'total', round(v_total, 2),
                            'fare', (public.mygig_ride_money(q, round(v_total, 2), v_tax)->>'fare')::numeric);
end;
$$;
revoke execute on function public.mygig_final(public.ride_requests) from public, anon, authenticated;

-- The driver's per-trip myGiG fee on [p_amount] (the fare paid).
create or replace function public.mygig_trip_fee(p_fee jsonb, p_amount numeric)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case when p_fee->>'mode' <> 'trip' then 0
              when p_fee->>'unit' = '%' then round(coalesce(p_amount, 0) * public.mygig_num(p_fee->'amount', 0) / 100, 2)
              else round(public.mygig_num(p_fee->'amount', 0), 2) end;
$$;

-- Family: the host's GET.wallet pays at once, within the member's limits
-- (as ride_pay's 'family', run by the server: the passenger agreed the
-- price). Not covered: left to the passenger to pay as any ride.
create or replace function public.mygig_pay_family(p_ride uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_due numeric;
  v_owner uuid;
  v_balance numeric;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if r.payment_status = 'paid' then
    return 'paid';
  end if;
  v_due := public.ride_left_to_pay(r);
  if v_due <= 0 then
    return 'nothing';
  end if;
  if public.family_trip_state(r.id, r.rider_id, v_due) <> 'ok' then
    return 'not_covered';
  end if;
  v_owner := public.family_wallet_owner(r.id, r.rider_id, v_due);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets where user_id = v_owner and wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_due then
    return 'short';
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
    (r.rider_id, 'get_wallet', 'ride_payment', -v_due, 'ride', 'Ride paid — RM' || to_char(v_due, 'FM999999990.00'), r.id),
    (r.partner_id, 'get_wallet', 'ride_earning', v_due, 'ride', 'Ride fare received — RM' || to_char(v_due, 'FM999999990.00'), r.id);
  update public.ride_requests set payment_status = 'paid', paid_method = 'get_wallet', paid_amount = v_due, paid_at = now()
   where id = r.id;
  return 'paid';
end;
$$;
revoke execute on function public.mygig_pay_family(uuid) from public, anon, authenticated;

-- Complete trip: tolls and other charges, the waiting, the final price.
-- Family pays at once; business by its own settlement (0313); the
-- driver's per-trip myGiG fee comes off their GET.credit.
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
  -- No losses: pay by link, anything added since (tolls, parking, waiting, a
  -- changed route) is paid before the trip can end, by a second link or in
  -- cash the driver confirms (mygig_take_cash).
  if r.mygig->>'pay' = 'link' then
    v_due := round((f->>'total')::numeric + v_tolls + v_other, 2);
    v_owed := round(v_due - public.mygig_paid_so_far(r), 2);
    if v_owed > 0.005 then
      update public.ride_requests
         set mygig = mygig || jsonb_build_object('pendingFinal', jsonb_build_object(
                       'tolls', v_tolls, 'other', v_other, 'note', v_note, 'due', v_due, 'at', now()))
       where id = r.id;
      return jsonb_build_object('status', 'on_trip', 'needsPayment', true, 'owed', v_owed, 'due', v_due, 'final', f);
    end if;
    -- Paid more than the end price (a shorter route accepted): the
    -- difference goes back, never the driver's to keep.
    v_link := coalesce((r.mygig->>'linkPaid')::numeric, 0);
    v_refund := least(v_link, greatest(0, -v_owed));
  end if;
  v_fee := public.mygig_trip_fee(r.mygig->'tripFee', (f->>'total')::numeric);
  update public.ride_requests
     set status = 'completed', completed_at = now(),
         fare = (f->>'fare')::numeric, ride_fare = (f->>'fare')::numeric,
         tax_name = case when (f->>'tax')::numeric > 0 then coalesce(r.mygig #>> '{quote,taxName}', 'Tax') end,
         tax_kind = case when (f->>'tax')::numeric > 0 then 'fixed' end,
         tax_value = case when (f->>'tax')::numeric > 0 then (f->>'tax')::numeric end,
         toll_charges = nullif(v_tolls, 0), other_charges = nullif(v_other, 0),
         other_charges_note = case when v_other > 0 then left(nullif(btrim(coalesce(v_note, '')), ''), 80) end,
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
  if r.mygig->>'pay' = 'link' then
    update public.ride_requests
       set payment_status = 'paid',
           paid_method = case when coalesce((mygig->>'linkPaid')::numeric, 0) > 0 then 'gateway' else 'cash' end,
           paid_amount = public.ride_left_to_pay(r), paid_at = now()
     where id = r.id;
  elsif r.mygig->>'pay' = 'family' then
    v_paid := public.mygig_pay_family(r.id);
  end if;
  select * into r from public.ride_requests where id = r.id;
  return jsonb_build_object('status', r.status, 'total', public.ride_amount_due(r), 'final', f,
                            'tripFee', v_fee, 'paymentStatus', r.payment_status, 'family', v_paid,
                            'needsPayment', false, 'refund', v_refund);
end;
$$;
revoke execute on function public.mygig_complete(uuid, numeric, numeric, text) from public, anon;
grant execute on function public.mygig_complete(uuid, numeric, numeric, text) to authenticated;

-- Pay by link not paid: the passenger pays cash ("Didn't pay? Take cash").
-- Pay by link: the passenger pays the driver in cash instead (before the
-- trip, at Complete for what was added, or a link left unpaid after it).
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
  if r.mygig->>'pay' <> 'link' or r.status not in ('accepted', 'arrived', 'on_trip', 'completed') then
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

-- Block a number (from the collect card, or by typing it), and unblock.
create or replace function public.mygig_block(p_phone text default null, p_ride uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_digits text := public.mygig_phone_digits(p_phone);
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_ride is not null then
    select public.mygig_phone_digits(r.mygig->>'phone') into v_digits
      from public.ride_requests r where r.id = p_ride and r.partner_id = v_uid and r.mygig is not null;
  end if;
  if v_digits is null or v_digits !~ '^[0-9]{6,16}$' then
    raise exception 'MYGIG_PHONE' using errcode = '22023', hint = 'There is no number to block.';
  end if;
  insert into public.mygig_blocked_numbers (driver_id, digits) values (v_uid, v_digits) on conflict do nothing;
  return jsonb_build_object('blocked', v_digits);
end;
$$;
revoke execute on function public.mygig_block(text, uuid) from public, anon;
grant execute on function public.mygig_block(text, uuid) to authenticated;

create or replace function public.mygig_unblock(p_digits text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.mygig_blocked_numbers where driver_id = auth.uid()
     and digits = coalesce(public.mygig_phone_digits(p_digits), '');
  return jsonb_build_object('unblocked', public.mygig_phone_digits(p_digits));
end;
$$;
revoke execute on function public.mygig_unblock(text) from public, anon;
grant execute on function public.mygig_unblock(text) to authenticated;

-- ---- 9. Passes -----------------------------------------------------------------------------------------------
create or replace function public.mygig_pass_end(p_mode text, p_from timestamptz, p_tz text)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case p_mode
    when 'day' then ((date_trunc('day', p_from at time zone p_tz) + interval '1 day' - interval '1 minute') at time zone p_tz)
    when 'week' then p_from + interval '7 days'
    when 'month' then p_from + interval '30 days'
    when 'half' then p_from + interval '182 days'
    else p_from + interval '365 days' end;
$$;

-- Buy the pass the driver's charge needs, from GET.credit or GET.wallet.
-- A pass already running runs to its end (nothing is bought twice).
create or replace function public.mygig_buy_pass(p_from text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  fee jsonb;
  v_amount numeric;
  v_type text := case when p_from = 'wallet' then 'get_wallet' else 'get_credit' end;
  v_balance numeric;
  v_now jsonb;
  ps public.mygig_passes;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('mygig_pass:' || v_uid::text, 329));
  fee := public.mygig_fee_for(v_uid);
  if fee->>'mode' not in ('day', 'week', 'month', 'half', 'year') then
    raise exception 'MYGIG_NO_PASS' using errcode = '22023', hint = 'You don''t need a pass for myGiG.';
  end if;
  v_now := public.mygig_pass_now(v_uid);
  if v_now is not null then
    return v_now || jsonb_build_object('already', true);
  end if;
  v_amount := round((fee->>'amount')::numeric, 2);
  insert into public.wallets (user_id, wallet_type, balance) values (v_uid, v_type, 0)
  on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets where user_id = v_uid and wallet_type = v_type for update;
  if coalesce(v_balance, 0) < v_amount then
    raise exception 'MYGIG_BALANCE' using errcode = '22023',
      hint = format('Not enough in your %s. Top up, or pay from the other one.',
                    case when v_type = 'get_wallet' then 'GET.wallet' else 'GET.credit' end);
  end if;
  insert into public.mygig_passes (driver_id, mode, amount, paid_from, ends_at)
  values (v_uid, fee->>'mode', v_amount, v_type,
          public.mygig_pass_end(fee->>'mode', now(), coalesce(public.mygig_defaults()->>'timezone', 'Asia/Kuala_Lumpur')))
  returning * into ps;
  if v_amount > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_uid, v_type, 'mygig_pass', -v_amount, 'mygig', 'myGiG pass — ' || public.mygig_money(v_amount));
  end if;
  return jsonb_build_object('id', ps.id, 'mode', ps.mode, 'amount', ps.amount, 'paidFrom', ps.paid_from,
                            'startsAt', ps.starts_at, 'endsAt', ps.ends_at, 'already', false);
end;
$$;
revoke execute on function public.mygig_buy_pass(text) from public, anon;
grant execute on function public.mygig_buy_pass(text) to authenticated;

-- ---- 10. Pay by link (the `payments` function: POST /payments/mygig-link) --------------------------------
-- The driver of a completed pay-by-link myGiG ride may ask for its link.
create or replace function public.payment_mygig_link_allowed(p_request uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ride_requests r
                  where r.id = p_request and r.partner_id = auth.uid() and r.mygig is not null
                    and r.mygig->>'pay' = 'link' and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
                    and public.mygig_owed(r) > 0)
     and public.payment_gateway_for('ride_card') is not null;
$$;
revoke execute on function public.payment_mygig_link_allowed(uuid) from public, anon;
grant execute on function public.payment_mygig_link_allowed(uuid) to authenticated;

-- Service role: the intent for the ride's amount (the pending one with the
-- same amount when there is one).
create or replace function public.payment_mygig_intent(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v public.payment_intents;
  v_gateway uuid;
  v_values jsonb;
  v_total numeric;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.mygig is null or r.mygig->>'pay' <> 'link' then
    raise exception 'not_pay_link' using errcode = '22023';
  end if;
  if r.payment_status = 'paid' then
    raise exception 'already_paid' using errcode = '22023';
  end if;
  if r.status not in ('accepted', 'arrived', 'on_trip', 'completed') then
    raise exception 'order_closed' using errcode = '22023';
  end if;
  -- What is owed now: the agreed price at acceptance, then what was added.
  v_total := public.mygig_owed(r);
  if v_total <= 0 then
    raise exception 'already_paid' using errcode = '22023';
  end if;
  select * into v from public.payment_intents
   where purpose = 'ride_card' and purpose_ref = r.id::text and status = 'pending' and amount = v_total
   order by created_at desc limit 1;
  if not found then
    v_gateway := public.payment_gateway_for('ride_card');
    select e.values into v_values from public.settings_entries e where e.id = v_gateway;
    if v_values is null then
      raise exception 'no_gateway' using errcode = '22023';
    end if;
    update public.payment_intents set status = 'cancelled', failure = 'replaced'
     where purpose = 'ride_card' and purpose_ref = r.id::text and status = 'pending';
    insert into public.payment_intents (user_id, purpose, purpose_ref, gateway_id, provider, test_mode, amount, currency)
    values (r.rider_id, 'ride_card', r.id::text, v_gateway, v_values ->> 'providerId',
            coalesce(v_values ->> 'mode', 'Live') = 'Sandbox', v_total, 'MYR')
    returning * into v;
  end if;
  return to_jsonb(v) || jsonb_build_object(
    'customer', jsonb_build_object('name', coalesce(r.rider_name, ''), 'phone', coalesce(r.mygig->>'phone', ''), 'email', ''),
    'owed', v_total);
end;
$$;
revoke execute on function public.payment_mygig_intent(uuid) from public, anon, authenticated;
grant execute on function public.payment_mygig_intent(uuid) to service_role;

-- Service role: the hosted page is on the ride; the passenger is texted it.
create or replace function public.payment_mygig_link_set(p_request uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.mygig is null or coalesce(p_url, '') !~ '^https://' then
    raise exception 'unknown_order' using errcode = '22023';
  end if;
  update public.ride_requests set mygig = mygig || jsonb_build_object('payUrl', p_url, 'payLinkAt', now())
   where id = r.id;
  if r.mygig->>'phone' is not null then
    begin
      insert into public.sms_outbox (channel, to_phone, body, created_by)
      values ('trip_share', r.mygig->>'phone',
              left('get.ride: pay ' || public.mygig_money(public.ride_left_to_pay(r)) || ' for your ride by card, FPX or DuitNow: '
                   || p_url, 300), null);
    exception when others then
      raise warning 'myGiG pay link SMS not queued: %', sqlerrm;
    end;
  end if;
end;
$$;
revoke execute on function public.payment_mygig_link_set(uuid, text) from public, anon, authenticated;
grant execute on function public.payment_mygig_link_set(uuid, text) to service_role;

-- 0252's ride_card hook: a myGiG ride paid by link is paid, once, and the
-- driver's GET.wallet gets the fare (as a GET.wallet payment would).
create or replace function public.payment_ride_card_paid(p_intent uuid, p_ride text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v public.payment_intents;
begin
  select * into v from public.payment_intents where id = p_intent;
  if not found or coalesce(p_ride, '') !~* '^[0-9a-f-]{36}$' then
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

-- A pay-by-link ride cancelled before the trip: what was paid by link goes
-- back to the passenger, but for the coming to the pickup when the
-- passenger cancelled or didn't come (the driver drove there); all of it
-- when the driver cancels. The driver's GET.credit gives back what their
-- GET.wallet got; refundDue tells the admin what to refund on the gateway.
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
begin
  if new.mygig is null or new.mygig ? 'refundDue' then
    return null;
  end if;
  if v_passenger then
    v_keep := least(v_link, coalesce((new.mygig #>> '{quote,approach}')::numeric, 0));
  end if;
  v_refund := round(v_link - v_keep, 2);
  update public.ride_requests
     set mygig = mygig || jsonb_build_object('refundDue', v_refund, 'kept', v_keep,
                   'approachCashBack', not v_passenger and new.mygig->>'approachCashAt' is not null)
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
drop trigger if exists trg_ride_requests_mygig_cancel_settle on public.ride_requests;
create trigger trg_ride_requests_mygig_cancel_settle
  after update of status on public.ride_requests
  for each row
  when (new.status = 'cancelled' and old.status is distinct from 'cancelled' and new.mygig is not null)
  execute function public.ride_requests_mygig_cancel_settle();

-- ---- 11. Admin -----------------------------------------------------------------------------------------------
create or replace function public.mygig_admin_reader()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.caller_is_admin() or public.caller_admin_can_write('rpc:mygig_admin_driver_set')
      or exists (select 1 from public.admin_access a where a.profile_id = auth.uid()
                  and (a.page = '*' or a.page = 'admin-mygig'));
$$;
revoke execute on function public.mygig_admin_reader() from public, anon;
grant execute on function public.mygig_admin_reader() to authenticated;

-- The drivers (search by name, phone, plate), with their access and charge.
create or replace function public.mygig_admin_drivers(p_search text default null, p_limit integer default 50)
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
    select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object(
        'id', p.auth_user_id, 'name', coalesce(nullif(btrim(p.name), ''), 'Driver'), 'phone', p.phone,
        'plate', coalesce(public.dispatch_driver_car(p.auth_user_id)->>'plate', p.plate),
        'vehicle', coalesce(public.dispatch_driver_car(p.auth_user_id)->>'vehicle', p.vehicle),
        'types', to_jsonb(p.partner_types),
        'allowed', a.allowed, 'charge', coalesce(a.charge, 'default'),
        'custom', jsonb_build_object('mode', a.custom_mode, 'amount', a.custom_amount, 'unit', a.custom_unit),
        'note', a.note, 'today', public.mygig_today_count(p.auth_user_id), 'pass', public.mygig_pass_now(p.auth_user_id)) x
        from public.partners p
        left join public.mygig_driver_access a on a.driver_id = p.auth_user_id
       where p.auth_user_id is not null and (p.status = 'approved' or p.status::text like 'permit-%')
         and (q = '' or lower(coalesce(p.name, '')) like '%' || q || '%'
              or regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') like '%' || regexp_replace(q, '\D', '', 'g') || '%' and regexp_replace(q, '\D', '', 'g') <> ''
              or lower(coalesce(p.plate, '')) like '%' || q || '%')
       order by p.name
       limit least(200, greatest(1, coalesce(p_limit, 50)))) s), '[]'::jsonb);
end;
$$;
revoke execute on function public.mygig_admin_drivers(text, integer) from public, anon;
grant execute on function public.mygig_admin_drivers(text, integer) to authenticated;

create or replace function public.mygig_admin_driver_set(p_driver uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.mygig_fee_normalize(coalesce(p->'custom', '{}'::jsonb));
begin
  if not public.caller_admin_can_write('rpc:mygig_admin_driver_set') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change myGiG access.';
  end if;
  if not exists (select 1 from public.partners where auth_user_id = p_driver) then
    raise exception 'MYGIG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if c->>'unit' = '%' and (c->>'amount')::numeric > 100 then
    raise exception 'MYGIG_INVALID' using errcode = '22023', hint = 'A percentage is 0 to 100.';
  end if;
  insert into public.mygig_driver_access (driver_id, allowed, charge, custom_mode, custom_amount, custom_unit, note,
                                          updated_by, updated_at)
  values (p_driver,
          case when jsonb_typeof(p->'allowed') = 'boolean' then (p->>'allowed')::boolean end,
          case when p->>'charge' in ('default', 'none', 'custom') then p->>'charge' else 'default' end,
          c->>'mode', (c->>'amount')::numeric, c->>'unit', left(nullif(btrim(coalesce(p->>'note', '')), ''), 300),
          auth.uid(), now())
  on conflict (driver_id) do update
    set allowed = excluded.allowed, charge = excluded.charge, custom_mode = excluded.custom_mode,
        custom_amount = excluded.custom_amount, custom_unit = excluded.custom_unit, note = excluded.note,
        updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('driver', p_driver, 'fee', public.mygig_fee_for(p_driver));
end;
$$;
revoke execute on function public.mygig_admin_driver_set(uuid, jsonb) from public, anon;
grant execute on function public.mygig_admin_driver_set(uuid, jsonb) to authenticated;

-- The fenced places (the place fees list) with their myGiG rule.
create or replace function public.mygig_admin_places()
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
    select jsonb_agg(jsonb_build_object('id', a.id, 'name', coalesce(a.values->>'name', 'Place'), 'kind', a.kind,
                                        'active', a.active, 'rule', m.rule)
                     order by coalesce(a.values->>'name', ''))
      from public.airport_areas a left join public.mygig_place_rules m on m.area_id = a.id), '[]'::jsonb);
end;
$$;
revoke execute on function public.mygig_admin_places() from public, anon;
grant execute on function public.mygig_admin_places() to authenticated;

create or replace function public.mygig_admin_place_set(p_area uuid, p_rule text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:mygig_admin_place_set') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change myGiG places.';
  end if;
  if coalesce(p_rule, '') in ('', 'allowed') then
    delete from public.mygig_place_rules where area_id = p_area;
  elsif p_rule in ('pickup', 'drop', 'both') then
    insert into public.mygig_place_rules (area_id, rule, updated_at) values (p_area, p_rule, now())
    on conflict (area_id) do update set rule = excluded.rule, updated_at = now();
  else
    raise exception 'MYGIG_INVALID' using errcode = '22023';
  end if;
  return jsonb_build_object('area', p_area, 'rule', nullif(p_rule, 'allowed'));
end;
$$;
revoke execute on function public.mygig_admin_place_set(uuid, text) from public, anon;
grant execute on function public.mygig_admin_place_set(uuid, text) to authenticated;

-- ---- 12. The ride's myGiG column is the server's -------------------------------------------------------------
create or replace function public.ride_requests_mygig_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.mygig is not null then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'A myGiG ride is made by the server.';
    end if;
    return new;
  end if;
  if new.mygig is distinct from old.mygig then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'A myGiG ride''s terms are the server''s.';
  end if;
  if old.mygig is not null and (new.fare, new.ride_fare, new.tax_value, new.payment_mode, new.rider_id)
       is distinct from (old.fare, old.ride_fare, old.tax_value, old.payment_mode, old.rider_id) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'A myGiG ride''s price was agreed with the passenger.';
  end if;
  -- Start, no-show and completion go through the myGiG functions.
  if old.mygig is not null and new.status is distinct from old.status and new.status in ('on_trip', 'completed') then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'Use the myGiG trip buttons.';
  end if;
  -- The passenger cancels before the trip with mygig_cancel_ride (the agreed fee terms).
  if old.mygig is not null and new.status = 'cancelled' and old.status in ('accepted', 'arrived')
     and auth.uid() is not distinct from old.rider_id then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'Cancel this myGiG ride from its trip screen.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_mygig_guard() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_b_mygig_guard on public.ride_requests;
create trigger trg_ride_requests_b_mygig_guard
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_mygig_guard();

-- ---- 13. Family: the 'mygig' module ---------------------------------------------------------------------------
select public.family_register_module('mygig', 'myGiG');

-- As 0326, and a myGiG ride is the 'mygig' module.
create or replace function public.family_ride_module(r public.ride_requests)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- 0329: a myGiG ride (a street hail, priced by the driver's myGiG).
  if r.mygig is not null then
    return 'mygig';
  end if;
  -- 0326: an hourly hire, now or released from a booking.
  if r.hire_package is not null then
    return 'hire';
  end if;
  if r.parcel_size is not null or coalesce(public.vehicle_service_is_courier(r.service), false) then
    return 'courier';
  end if;
  if public.ride_request_is_freight(r) then
    return 'freight';
  end if;
  if r.scheduled_ride_id is not null then
    return 'scheduled_ride';
  end if;
  return 'ride';
end;
$$;
revoke execute on function public.family_ride_module(public.ride_requests) from public, anon, authenticated;

-- ---- 14. Followed live by the apps ----------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['mygig_rules', 'mygig_place_rules'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
