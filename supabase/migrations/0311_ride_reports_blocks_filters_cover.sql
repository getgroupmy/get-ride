-- ============================================================================
-- 0311 — City ride safety: reporting a trip, blocking a driver, the driver's
-- request filters, and passenger cover and the driver's permit on the
-- receipt (docs/KIV.md, City ride before launch).
--
-- Version 20261028040000 (0311_ride_reports_blocks_filters_cover).
-- Re-runnable: tables, columns and indexes "if not exists", functions
-- "create or replace", policies and triggers dropped first, seed rows only
-- where missing, functions edited in place only where not edited yet.
--
-- 1. Settings, one row (ride_safety_settings), admin page "Ride safety"
--    (admin-settings-ride-safety, grantable to sub-admins): how many days
--    after a trip it can be reported (default 30), how many drivers a rider
--    can block (default 20), how many riders' blocks flag a driver for review
--    (default 3), the driver request filters (each can be switched off; the
--    minimum fare filter's cap, default RM 30; the pickup distance from 1 to
--    10 km) and whether the receipt shows the driver's permit.
-- 2. Report categories (trip_report_categories): Safety, Driver behaviour,
--    Fare, Route, Lost item, Vehicle, Other, seeded once; the admin adds,
--    renames and removes them (a removed one is kept inactive, as reports
--    name it), each urgent or normal, and whether it shows the SOS reminder
--    (Safety does).
-- 3. A report is a support ticket with the trip linked: support_tickets gets
--    request_id (a city ride), c2c_booking_id (a City to City booking),
--    report_category, priority ('urgent' or 'normal'), reported_driver_id
--    and reported_at. trip_report_create(...) checks the rider's own trip,
--    that it has ended and is within the report window, opens the ticket
--    with the trip, route, fare and driver in its first message, and, when
--    asked, blocks the driver too. Photos and voice notes follow as ticket
--    messages (the app's support upload). An urgent report alerts the
--    on-duty admins as SOS does (0193: the on-call list, else every full
--    admin) through the push outbox (0144), kind 'trip_report'. The apps
--    can't set the report columns themselves (trg_support_tickets_guard_report).
-- 4. Blocks (rider_blocks), enforced by the server:
--      * a blocked driver doesn't see the rider's open requests: city rides
--        (restrictive policy "ride_requests rider blocks"), scheduled rides
--        (scheduled_rides_open and scheduled_rides_upcoming, edited in place)
--        and City to City (restrictive policy "c2c_bookings rider blocks"
--        beside 0307's read policy, and c2c_driver_requests edited in place);
--        nor is pushed them (ride_request_push_nearby and
--        ride_request_push_everyone, edited in place) nor counted in the
--        hidden-extras line (ride_extras_hidden_count);
--      * can't offer or take: ride_offers, c2c_offers and scheduled handovers
--        refused on insert, partner_id / driver_id refused when the driver or
--        the rider sets it; the driver is told "This request is no longer
--        open.", never why;
--      * My Ride and GET.now: a favourite of a blocked driver is removed and
--        can't be added again; a GET.now booking to him is refused
--        (DRIVER_BLOCKED, to the rider); a blocked driver is left out of a
--        request's favourites (target_driver_ids).
--    rider_block_driver / rider_unblock_driver / my_blocked_drivers for the
--    rider (Settings > Blocked drivers). Blocking withdraws the driver's open
--    offers on the rider's open requests. At most the admin's limit.
--    Admins read every block; a driver blocked by the admin's number of
--    riders since the last review is flagged (admin_driver_safety_flags for
--    the Partners list, admin_driver_safety for the partner's sheet,
--    admin_driver_block_review to mark it reviewed).
-- 5. Driver request filters (driver_request_filters): minimum fare, maximum
--    pickup distance and sort, saved to the account (and on the phone),
--    kept within the admin's limits by the server. They only hide requests
--    in the driver's own list. No per-driver acceptance rate exists, so
--    nothing is counted against the driver for a hidden request.
-- 6. Passenger cover (passenger_cover_rules): per region, the default (no
--    place) plus country, state or city rules, the most specific wins (even
--    one that is off): insurer, policy number, cover amount, claim days,
--    hotline, terms link, on/off. passenger_cover_for(country, state, city);
--    "You were covered on this trip" shows only for a rule that is on and has
--    an insurer, a policy number and an amount. trip_safety_info(ride) gives
--    the receipt the cover, the driver's approved permits shown to passengers
--    (0254's ride_permit_items: issuer, name, number, valid until) when the
--    admin's switch is on, the report window and categories, an earlier
--    report and the block. passenger_cover_mine() for the Safety page.
--
-- Nothing here is an admin RPC on 0223's rewrite list; the functions edited
-- in place are edited in their current definitions (pg_get_functiondef), as
-- 0254, 0263 and 0267 did.
-- ============================================================================

-- ---- 1. Settings -------------------------------------------------------------------------------------
create table if not exists public.ride_safety_settings (
  id                     smallint primary key default 1 check (id = 1),
  report_window_days     integer not null default 30 check (report_window_days between 1 and 365),
  max_blocks_per_rider   integer not null default 20 check (max_blocks_per_rider between 1 and 500),
  block_flag_riders      integer not null default 3 check (block_flag_riders between 1 and 100),
  filter_min_fare_on     boolean not null default true,
  filter_min_fare_cap    numeric(10,2) not null default 30 check (filter_min_fare_cap between 1 and 10000),
  filter_distance_on     boolean not null default true,
  filter_distance_min_km numeric(6,1) not null default 1 check (filter_distance_min_km between 0.5 and 200),
  filter_distance_max_km numeric(6,1) not null default 10 check (filter_distance_max_km between 0.5 and 200),
  filter_sort_on         boolean not null default true,
  show_driver_permit     boolean not null default true,
  currency               text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  updated_at             timestamptz not null default now(),
  updated_by             uuid,
  constraint ride_safety_settings_distance check (filter_distance_min_km <= filter_distance_max_km)
);
comment on table public.ride_safety_settings is
  'Ride safety (0311), one row: report window, block limit and flag, driver request filter limits, the permit on receipts.';
insert into public.ride_safety_settings (id) values (1) on conflict (id) do nothing;

create or replace function public.ride_safety_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end;
$$;
revoke execute on function public.ride_safety_stamp() from public, anon, authenticated;

drop trigger if exists trg_ride_safety_settings_stamp on public.ride_safety_settings;
create trigger trg_ride_safety_settings_stamp
  before insert or update on public.ride_safety_settings
  for each row execute function public.ride_safety_stamp();

-- ---- 2. Report categories ----------------------------------------------------------------------------
create table if not exists public.trip_report_categories (
  id           uuid primary key default gen_random_uuid(),
  label        text not null check (char_length(btrim(label)) between 1 and 40 and label = btrim(label)),
  urgent       boolean not null default false,
  sos_reminder boolean not null default false,
  position     integer not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);
create unique index if not exists trip_report_categories_label_uidx
  on public.trip_report_categories (lower(label)) where active;
comment on table public.trip_report_categories is
  'What a rider picks when reporting a trip (0311). Urgent ones go to the top of support and alert the on-duty admins; a removed one is kept inactive.';

insert into public.trip_report_categories (label, urgent, sos_reminder, position)
select x.label, x.urgent, x.sos, x.pos
  from (values ('Safety', true, true, 0), ('Driver behaviour', true, false, 1), ('Fare', false, false, 2),
               ('Route', false, false, 3), ('Lost item', false, false, 4), ('Vehicle', false, false, 5),
               ('Other', false, false, 6)) as x(label, urgent, sos, pos)
 where not exists (select 1 from public.trip_report_categories);

drop trigger if exists trg_trip_report_categories_stamp on public.trip_report_categories;
create trigger trg_trip_report_categories_stamp
  before insert or update on public.trip_report_categories
  for each row execute function public.ride_safety_stamp();

-- ---- 6. Passenger cover by region --------------------------------------------------------------------
create table if not exists public.passenger_cover_rules (
  id           uuid primary key default gen_random_uuid(),
  -- No place: the default. A state needs its country, a city its state.
  country      text check (country is null or char_length(btrim(country)) between 1 and 120),
  state        text check (state is null or char_length(btrim(state)) between 1 and 120),
  city         text check (city is null or char_length(btrim(city)) between 1 and 120),
  enabled      boolean not null default true,
  insurer      text not null default '' check (char_length(insurer) <= 120),
  policy_no    text not null default '' check (char_length(policy_no) <= 80),
  cover_amount numeric(14,2) check (cover_amount is null or cover_amount between 0 and 100000000),
  currency     text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  claim_days   integer check (claim_days is null or claim_days between 1 and 3650),
  hotline      text not null default '' check (char_length(hotline) <= 40),
  terms_url    text not null default '' check (terms_url = '' or (terms_url ~* '^https?://' and char_length(terms_url) <= 500)),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint passenger_cover_rules_place check ((state is null or country is not null) and (city is null or state is not null))
);
create unique index if not exists passenger_cover_rules_place_uidx
  on public.passenger_cover_rules (lower(coalesce(country, '')), lower(coalesce(state, '')), lower(coalesce(city, '')));
comment on table public.passenger_cover_rules is
  'Passenger cover shown on receipts and the Safety page (0311): the default (no place) and country, state or city rules; the most specific wins.';

-- The default, off and empty until the admin fills it in.
insert into public.passenger_cover_rules (enabled)
select false where not exists (select 1 from public.passenger_cover_rules where country is null);

drop trigger if exists trg_passenger_cover_rules_stamp on public.passenger_cover_rules;
create trigger trg_passenger_cover_rules_stamp
  before insert or update on public.passenger_cover_rules
  for each row execute function public.ride_safety_stamp();

-- ---- Reading and writing the admin's tables ----------------------------------------------------------
-- Everyone signed in reads (the apps show the categories, the limits and the
-- cover); admins with EDIT on Ride safety write.
do $rls$
declare
  t text;
begin
  foreach t in array array['ride_safety_settings', 'trip_report_categories', 'passenger_cover_rules'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || ' read', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) is not null)',
                   t || ' read', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin insert', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin update', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin delete', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.caller_admin_can_write(%L))) with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin update', t, t, t);
    -- The settings are one row: changed, never added or removed.
    if t <> 'ride_safety_settings' then
      execute format('create policy %I on public.%I for insert to authenticated with check ((select public.caller_admin_can_write(%L)))',
                     t || ' admin insert', t, t);
      execute format('create policy %I on public.%I for delete to authenticated using ((select public.caller_admin_can_write(%L)))',
                     t || ' admin delete', t, t);
    end if;
  end loop;
end
$rls$;

-- ---- 3. Reports are support tickets with the trip linked ----------------------------------------------
alter table public.support_tickets
  add column if not exists request_id uuid references public.ride_requests(id) on delete set null,
  add column if not exists c2c_booking_id uuid references public.c2c_bookings(id) on delete set null,
  add column if not exists report_category text,
  add column if not exists report_category_id uuid,
  add column if not exists priority text not null default 'normal',
  add column if not exists reported_driver_id uuid,
  add column if not exists reported_at timestamptz;
alter table public.support_tickets drop constraint if exists support_tickets_priority_check;
alter table public.support_tickets add constraint support_tickets_priority_check check (priority in ('normal', 'urgent'));
create index if not exists support_tickets_request_idx on public.support_tickets (request_id) where request_id is not null;
create index if not exists support_tickets_c2c_idx on public.support_tickets (c2c_booking_id) where c2c_booking_id is not null;
create index if not exists support_tickets_reported_driver_idx
  on public.support_tickets (reported_driver_id, reported_at desc) where reported_driver_id is not null;

-- A rider's or driver's own writes leave the report columns as the server
-- set them (a new ticket from the app is never a report, nor urgent).
-- Support admins may change the priority.
create or replace function public.support_tickets_guard_report()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.request_id := null;
    new.c2c_booking_id := null;
    new.report_category := null;
    new.report_category_id := null;
    new.priority := 'normal';
    new.reported_driver_id := null;
    new.reported_at := null;
    return new;
  end if;
  new.request_id := old.request_id;
  new.c2c_booking_id := old.c2c_booking_id;
  new.report_category := old.report_category;
  new.report_category_id := old.report_category_id;
  new.reported_driver_id := old.reported_driver_id;
  new.reported_at := old.reported_at;
  if not public.caller_admin_can_write('support_tickets') then
    new.priority := old.priority;
  end if;
  return new;
end;
$$;
revoke execute on function public.support_tickets_guard_report() from public, anon, authenticated;
drop trigger if exists trg_support_tickets_guard_report on public.support_tickets;
create trigger trg_support_tickets_guard_report
  before insert or update on public.support_tickets
  for each row execute function public.support_tickets_guard_report();

-- ---- 4. Blocks ---------------------------------------------------------------------------------------
create table if not exists public.rider_blocks (
  id             uuid primary key default gen_random_uuid(),
  rider_id       uuid not null references public.profiles(id) on delete cascade,
  -- The driver's account id (partners.auth_user_id), as ride_requests.partner_id.
  driver_id      uuid not null references auth.users(id) on delete cascade,
  request_id     uuid references public.ride_requests(id) on delete set null,
  c2c_booking_id uuid references public.c2c_bookings(id) on delete set null,
  source         text not null default 'receipt' check (source in ('receipt', 'report', 'settings')),
  created_at     timestamptz not null default now(),
  unique (rider_id, driver_id),
  check (rider_id <> driver_id)
);
create index if not exists rider_blocks_driver_idx on public.rider_blocks (driver_id, created_at desc);
comment on table public.rider_blocks is
  'A rider''s blocked drivers (0311): the driver doesn''t see the rider''s requests, can''t offer or take them, and isn''t told. Written only by rider_block_driver / rider_unblock_driver.';

alter table public.rider_blocks enable row level security;
revoke all on public.rider_blocks from public, anon, authenticated;
grant select on public.rider_blocks to authenticated;
grant all on public.rider_blocks to service_role;
drop policy if exists "rider_blocks own or admin read" on public.rider_blocks;
create policy "rider_blocks own or admin read" on public.rider_blocks for select to authenticated
  using (rider_id = (select auth.uid()) or (select public.caller_is_admin()));

-- When an admin last reviewed a driver's blocks: the flag counts from then.
create table if not exists public.driver_block_reviews (
  driver_id   uuid primary key,
  reviewed_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(id) on delete set null
);
alter table public.driver_block_reviews enable row level security;
revoke all on public.driver_block_reviews from public, anon, authenticated;
grant select on public.driver_block_reviews to authenticated;
grant all on public.driver_block_reviews to service_role;
drop policy if exists "driver_block_reviews admin read" on public.driver_block_reviews;
create policy "driver_block_reviews admin read" on public.driver_block_reviews for select to authenticated
  using ((select public.caller_is_admin()));

-- Whether rider [p_rider] blocked driver [p_driver]. The server's own.
create or replace function public.rider_blocks_driver(p_rider uuid, p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_rider is not null and p_driver is not null
     and exists (select 1 from public.rider_blocks b where b.rider_id = p_rider and b.driver_id = p_driver);
$$;
revoke execute on function public.rider_blocks_driver(uuid, uuid) from public, anon, authenticated;

-- The drivers [p_rider] blocked, as a JSON array of ids (a push's exclude list).
create or replace function public.rider_blocked_driver_ids(p_rider uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select jsonb_agg(b.driver_id) from public.rider_blocks b where b.rider_id = p_rider), '[]'::jsonb);
$$;
revoke execute on function public.rider_blocked_driver_ids(uuid) from public, anon, authenticated;

-- For the read policies: whether rider [p_rider] blocked the caller. Only
-- the caller is asked about, as the other caller_* checks.
create or replace function public.caller_blocked_by(p_rider uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.rider_blocks_driver(p_rider, auth.uid());
$$;
revoke execute on function public.caller_blocked_by(uuid) from public, anon;
grant execute on function public.caller_blocked_by(uuid) to authenticated, service_role;

-- A name as riders and drivers see each other: "Hafiz R.".
create or replace function public.ride_safety_short_name(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when nullif(btrim(coalesce(p_name, '')), '') is null then null
    when array_length(regexp_split_to_array(btrim(p_name), '\s+'), 1) = 1 then btrim(p_name)
    else (regexp_split_to_array(btrim(p_name), '\s+'))[1] || ' '
         || upper(left((regexp_split_to_array(btrim(p_name), '\s+'))[2], 1)) || '.' end;
$$;

-- ---- Who sees an open request ------------------------------------------------------------------------
-- Restrictive, beside the others (0254, 0263, 0267, 0268): a city ride
-- request is hidden from the drivers its rider blocked.
drop policy if exists "ride_requests rider blocks" on public.ride_requests;
create policy "ride_requests rider blocks" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or not public.caller_blocked_by(rider_id));

-- City to City (0307's read policy lets drivers in reach read open and
-- offered requests): the same, restrictive beside it.
drop policy if exists "c2c_bookings rider blocks" on public.c2c_bookings;
create policy "c2c_bookings rider blocks" on public.c2c_bookings as restrictive for select to authenticated
  using (status not in ('open', 'offered')
         or rider_id = (select auth.uid()) or driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or not public.caller_blocked_by(rider_id));

-- ---- Who can offer or take ---------------------------------------------------------------------------
-- After the My Ride trigger (trg_ride_requests_c_my_ride sets the favourites
-- and GET.now's driver): a blocked driver is left out of the favourites; a
-- GET.now booking to him is refused; a blocked driver taking the request,
-- or the rider picking him, is refused.
create or replace function public.ride_requests_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_targets uuid[];
begin
  if new.rider_id is null or not exists (select 1 from public.rider_blocks b where b.rider_id = new.rider_id) then
    return new;
  end if;
  if new.direct_driver_id is not null
     and (tg_op = 'INSERT' or new.direct_driver_id is distinct from old.direct_driver_id)
     and public.rider_blocks_driver(new.rider_id, new.direct_driver_id) then
    raise exception 'DRIVER_BLOCKED' using errcode = 'P0001',
      hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers to book them.';
  end if;
  if coalesce(cardinality(new.target_driver_ids), 0) > 0
     and (tg_op = 'INSERT' or new.target_driver_ids is distinct from old.target_driver_ids) then
    v_targets := array(select x from unnest(new.target_driver_ids) x
                        where not public.rider_blocks_driver(new.rider_id, x));
    if coalesce(cardinality(v_targets), 0) = 0 then
      new.target_driver_ids := null;
      new.targeted_until := null;
    elsif cardinality(v_targets) <> cardinality(new.target_driver_ids) then
      new.target_driver_ids := v_targets;
    end if;
  end if;
  if new.partner_id is not null
     and (tg_op = 'INSERT' or new.partner_id is distinct from old.partner_id)
     and public.rider_blocks_driver(new.rider_id, new.partner_id) then
    if auth.uid() = new.rider_id then
      raise exception 'DRIVER_BLOCKED' using errcode = 'P0001',
        hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers first.';
    elsif auth.uid() = new.partner_id then
      raise exception 'OFFER_REQUEST_CLOSED' using errcode = 'P0001', hint = 'This request is no longer open.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_c_my_ride_zblocks on public.ride_requests;
create trigger trg_ride_requests_c_my_ride_zblocks
  before insert or update of partner_id, direct_driver_id, target_driver_ids on public.ride_requests
  for each row execute function public.ride_requests_rider_blocks();

-- A driver's offer on a city ride request (0269's ride_offer_make and the
-- request trigger both insert here).
create or replace function public.ride_offers_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.ride_requests r
              where r.id = new.request_id and public.rider_blocks_driver(r.rider_id, new.partner_id)) then
    raise exception 'OFFER_REQUEST_CLOSED' using errcode = 'P0001', hint = 'This request is no longer open.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_offers_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_ride_offers_rider_blocks on public.ride_offers;
create trigger trg_ride_offers_rider_blocks
  before insert on public.ride_offers
  for each row execute function public.ride_offers_rider_blocks();

-- Scheduled rides: a blocked driver accepting (or handed) the booking, or
-- the rider asking him to take it.
create or replace function public.scheduled_rides_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.partner_id is not null and new.partner_id is distinct from old.partner_id
     and public.rider_blocks_driver(new.rider_id, new.partner_id) then
    if auth.uid() = new.rider_id then
      raise exception 'DRIVER_BLOCKED' using errcode = 'P0001',
        hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers first.';
    elsif auth.uid() is not null then
      raise exception 'SCHEDULED_NOT_AVAILABLE' using errcode = 'P0001', hint = 'This booking is no longer available.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_rider_blocks on public.scheduled_rides;
create trigger trg_scheduled_rides_rider_blocks
  before update of partner_id on public.scheduled_rides
  for each row execute function public.scheduled_rides_rider_blocks();

create or replace function public.scheduled_ride_offers_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.rider_blocks_driver(new.rider_id, new.to_partner_id) then
    if auth.uid() = new.rider_id then
      raise exception 'DRIVER_BLOCKED' using errcode = 'P0001',
        hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers first.';
    end if;
    raise exception 'SCHEDULED_NOT_AVAILABLE' using errcode = 'P0001',
      hint = 'This driver can''t take this booking. Pick another driver.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_ride_offers_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_scheduled_ride_offers_rider_blocks on public.scheduled_ride_offers;
create trigger trg_scheduled_ride_offers_rider_blocks
  before insert on public.scheduled_ride_offers
  for each row execute function public.scheduled_ride_offers_rider_blocks();

-- City to City: an offer, and picking or handing the booking to a driver.
create or replace function public.c2c_offers_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.c2c_bookings b
              where b.id = new.booking_id and public.rider_blocks_driver(b.rider_id, new.driver_id)) then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This request is no longer open.';
  end if;
  return new;
end;
$$;
revoke execute on function public.c2c_offers_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_c2c_offers_rider_blocks on public.c2c_offers;
create trigger trg_c2c_offers_rider_blocks
  before insert on public.c2c_offers
  for each row execute function public.c2c_offers_rider_blocks();

create or replace function public.c2c_bookings_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.driver_id is not null and new.driver_id is distinct from old.driver_id
     and public.rider_blocks_driver(new.rider_id, new.driver_id) then
    if auth.uid() = new.rider_id then
      raise exception 'DRIVER_BLOCKED' using errcode = '22023',
        hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers first.';
    elsif auth.uid() is not null then
      raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This request is no longer open.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.c2c_bookings_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_c2c_bookings_rider_blocks on public.c2c_bookings;
create trigger trg_c2c_bookings_rider_blocks
  before update of driver_id on public.c2c_bookings
  for each row execute function public.c2c_bookings_rider_blocks();

-- My Ride: a blocked driver can't be made a favourite.
create or replace function public.favourite_drivers_rider_blocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.rider_blocks_driver(new.rider_id, new.driver_id) then
    raise exception 'DRIVER_BLOCKED' using errcode = 'P0001',
      hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers first.';
  end if;
  return new;
end;
$$;
revoke execute on function public.favourite_drivers_rider_blocks() from public, anon, authenticated;
drop trigger if exists trg_favourite_drivers_rider_blocks on public.favourite_drivers;
create trigger trg_favourite_drivers_rider_blocks
  before insert or update of rider_id, driver_id on public.favourite_drivers
  for each row execute function public.favourite_drivers_rider_blocks();

-- ---- The feeds and pushes, each edited in its current definition ----------------------------------------
do $edit$
declare
  e record;
  v_def text;
  v_n int;
begin
  for e in
    select * from (values
      ('ride_request_push_nearby', 'continue when v_driver = p_rider;',
         'continue when v_driver = p_rider;' || chr(10)
         || '    continue when public.rider_blocks_driver(p_rider, v_driver);'),
      ('ride_request_push_everyone',
         '''excludeProfileIds'', case when v_rider is null then ''[]''::jsonb else jsonb_build_array(v_rider) end || v_skip',
         '''excludeProfileIds'', case when v_rider is null then ''[]''::jsonb else jsonb_build_array(v_rider) end || v_skip'
         || ' || public.rider_blocked_driver_ids(v_rider)'),
      ('scheduled_rides_open', 'and s.rider_id <> auth.uid()',
         'and s.rider_id <> auth.uid()' || chr(10)
         || '     and not public.rider_blocks_driver(s.rider_id, auth.uid())'),
      ('scheduled_rides_upcoming', 'and s.rider_id <> auth.uid()',
         'and s.rider_id <> auth.uid()' || chr(10)
         || '     and not public.rider_blocks_driver(s.rider_id, auth.uid())'),
      ('ride_extras_hidden_count', 'and r.rider_id is distinct from auth.uid()',
         'and r.rider_id is distinct from auth.uid()' || chr(10)
         || '       and not public.rider_blocks_driver(r.rider_id, auth.uid())'),
      ('c2c_driver_requests', 'and b.rider_id <> v_uid',
         'and b.rider_id <> v_uid' || chr(10)
         || '         and not public.rider_blocks_driver(b.rider_id, v_uid)')
    ) as t(fn, anchor, added)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = e.fn;
    if v_def is null then
      raise exception '0311: public.% is missing', e.fn;
    end if;
    -- Run again: a place already edited is left alone.
    continue when position(e.added in v_def) > 0;
    v_n := (length(v_def) - length(replace(v_def, e.anchor, ''))) / length(e.anchor);
    if v_n <> 1 then
      raise exception '0311: public.% should have "%" once (has %); update this migration', e.fn, e.anchor, v_n;
    end if;
    execute replace(v_def, e.anchor, e.added);
  end loop;
end
$edit$;

-- ---- The rider blocks and unblocks ---------------------------------------------------------------------
-- The block itself, for [p_rider] (the caller, or the report on their
-- behalf): only a driver they rode with (a city ride or a City to City
-- booking), at most the admin's number. Their favourite of him is removed,
-- and his open offers on their open requests withdrawn.
create or replace function public.rider_block_insert(p_rider uuid, p_driver uuid, p_request uuid,
                                                     p_c2c_booking uuid, p_source text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.ride_safety_settings;
  v_req uuid;
begin
  if p_rider is null or p_driver is null or p_rider = p_driver then
    raise exception 'BLOCK_BAD' using errcode = '22023', hint = 'Pick a driver from one of your trips.';
  end if;
  if public.rider_blocks_driver(p_rider, p_driver) then
    return false;
  end if;
  if not exists (select 1 from public.ride_requests r where r.rider_id = p_rider and r.partner_id = p_driver)
     and not exists (select 1 from public.c2c_bookings b where b.rider_id = p_rider and b.driver_id = p_driver) then
    raise exception 'BLOCK_BAD' using errcode = '22023', hint = 'You can block a driver you have ridden with.';
  end if;
  select * into s from public.ride_safety_settings where id = 1;
  if (select count(*) from public.rider_blocks b where b.rider_id = p_rider) >= coalesce(s.max_blocks_per_rider, 20) then
    raise exception 'BLOCK_LIMIT' using errcode = 'P0001',
      hint = format('You can block up to %s drivers. Unblock one in Settings › Blocked drivers first.',
                    coalesce(s.max_blocks_per_rider, 20));
  end if;
  insert into public.rider_blocks (rider_id, driver_id, request_id, c2c_booking_id, source)
  values (p_rider, p_driver, p_request, p_c2c_booking,
          case when p_source in ('receipt', 'report', 'settings') then p_source else 'receipt' end)
  on conflict (rider_id, driver_id) do nothing;

  delete from public.favourite_drivers where rider_id = p_rider and driver_id = p_driver;

  -- His open offers on the rider's open requests.
  for v_req in
    update public.ride_offers o set status = 'withdrawn', closed_reason = 'withdrawn', closed_at = now()
      from public.ride_requests r
     where o.request_id = r.id and r.rider_id = p_rider and r.status = 'open'
       and o.partner_id = p_driver and o.status = 'open'
    returning o.request_id
  loop
    if to_regprocedure('public.ride_offers_mirror(uuid)') is not null then
      perform public.ride_offers_mirror(v_req);
    end if;
  end loop;
  update public.c2c_offers o set status = 'declined', declined_reason = 'rider'
    from public.c2c_bookings b
   where o.booking_id = b.id and b.rider_id = p_rider and b.status in ('open', 'offered')
     and o.driver_id = p_driver and o.status = 'open';
  update public.c2c_bookings b set status = 'open'
   where b.rider_id = p_rider and b.status = 'offered'
     and not exists (select 1 from public.c2c_offers o where o.booking_id = b.id and o.status = 'open');
  return true;
end;
$$;
revoke execute on function public.rider_block_insert(uuid, uuid, uuid, uuid, text) from public, anon, authenticated;

-- The rider blocks the driver of [p_request] (a city ride) or [p_c2c_booking]
-- (City to City), or [p_driver] directly. The driver isn't told.
create or replace function public.rider_block_driver(p_driver uuid default null, p_request uuid default null,
                                                     p_c2c_booking uuid default null,
                                                     p_source text default 'receipt')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_driver uuid := p_driver;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_request is not null then
    select r.partner_id into v_driver from public.ride_requests r where r.id = p_request and r.rider_id = v_uid;
  elsif p_c2c_booking is not null then
    select b.driver_id into v_driver from public.c2c_bookings b where b.id = p_c2c_booking and b.rider_id = v_uid;
  end if;
  if v_driver is null or (p_driver is not null and v_driver <> p_driver) then
    raise exception 'BLOCK_BAD' using errcode = '22023', hint = 'Pick a driver from one of your trips.';
  end if;
  perform public.rider_block_insert(v_uid, v_driver, p_request, p_c2c_booking, p_source);
  return jsonb_build_object('blocked', true, 'driver_id', v_driver);
end;
$$;
revoke execute on function public.rider_block_driver(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.rider_block_driver(uuid, uuid, uuid, text) to authenticated;

create or replace function public.rider_unblock_driver(p_driver uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  delete from public.rider_blocks where rider_id = auth.uid() and driver_id = p_driver;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;
revoke execute on function public.rider_unblock_driver(uuid) from public, anon;
grant execute on function public.rider_unblock_driver(uuid) to authenticated;

-- The rider's list (Settings > Blocked drivers): the driver as "Hafiz R.",
-- their photo, the car of the trip they were blocked from, and when.
create or replace function public.my_blocked_drivers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'driver_id', b.driver_id,
           'name', coalesce(public.ride_safety_short_name(coalesce(r.partner_name, pa.name, pr.name)), 'Driver'),
           'photo', coalesce(r.partner_photo, pr.avatar_url),
           'vehicle', nullif(btrim(concat_ws(' · ', r.partner_vehicle, r.partner_plate)), ''),
           'blocked_at', b.created_at) order by b.created_at desc), '[]'::jsonb)
    from public.rider_blocks b
    left join public.ride_requests r on r.id = b.request_id
    left join public.profiles pr on pr.id = b.driver_id
    left join lateral (select p.name from public.partners p where p.auth_user_id = b.driver_id
                        order by (p.status::text = 'approved') desc, p.created_at limit 1) pa on true
   where b.rider_id = auth.uid();
$$;
revoke execute on function public.my_blocked_drivers() from public, anon;
grant execute on function public.my_blocked_drivers() to authenticated;

-- ---- Reporting a trip --------------------------------------------------------------------------------
-- The on-duty admins: SOS's on-call list (0193), else every full admin.
create or replace function public.ride_safety_alert_admins(p_event text, p_title text, p_body text, p_data jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to uuid;
  v_n int := 0;
  v_on_call jsonb := '[]'::jsonb;
begin
  if to_regprocedure('public.sos_ops_config()') is not null then
    v_on_call := coalesce(public.sos_ops_config()->'onCall', '[]'::jsonb);
  end if;
  for v_to in
    select distinct x::uuid from (
      select jsonb_array_elements_text(v_on_call) as x
      union all
      select a.profile_id::text from public.admin_access a
       where jsonb_array_length(v_on_call) = 0 and a.page = '*' and a.access_level = 'edit'
    ) s
     where exists (select 1 from public.profiles p where p.id = s.x::uuid)
  loop
    perform public.enqueue_notification(v_to, p_event || '-' || v_to, 'trip_report', 'critical', p_title, p_body,
                                        p_data, null);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.ride_safety_alert_admins(text, text, text, jsonb) from public, anon, authenticated;

-- The trip [p_request] (a city ride) or [p_c2c_booking] (City to City) of
-- the caller: who drove, when it ended, its words for the ticket.
create or replace function public.ride_safety_trip(p_uid uuid, p_request uuid, p_c2c_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  b public.c2c_bookings;
  v_tz text;
begin
  if p_request is not null then
    select * into r from public.ride_requests where id = p_request;
    if r.id is null or r.rider_id is distinct from p_uid then
      return null;
    end if;
    v_tz := coalesce(r.timezone, 'Asia/Kuala_Lumpur');
    return jsonb_build_object(
      'kind', 'ride', 'id', r.id, 'driver_id', r.partner_id,
      'ended', r.status in ('completed', 'cancelled', 'expired'),
      'completed', r.status = 'completed',
      'ended_at', case when r.status in ('completed', 'cancelled', 'expired')
                       then coalesce(r.completed_at, r.cancelled_at, r.updated_at, r.created_at) end,
      'ref', 'GR-' || upper(left(replace(r.id::text, '-', ''), 8)),
      'when', to_char(coalesce(r.started_at, r.accepted_at, r.created_at) at time zone v_tz, 'DD Mon YYYY, HH24:MI'),
      'route', coalesce(nullif(btrim(r.pickup_name), ''), 'Pickup') || ' to ' || coalesce(nullif(btrim(r.drop_name), ''), 'drop-off'),
      'fare', coalesce(r.fare, r.ride_fare), 'currency', coalesce(r.currency, 'MYR'),
      'driver_name', public.ride_safety_short_name(r.partner_name),
      'vehicle', nullif(btrim(concat_ws(' · ', r.partner_vehicle, r.partner_plate)), ''),
      'country', r.country, 'state', r.state, 'city', r.city);
  end if;
  if p_c2c_booking is not null then
    select * into b from public.c2c_bookings where id = p_c2c_booking;
    if b.id is null or b.rider_id is distinct from p_uid then
      return null;
    end if;
    v_tz := coalesce(b.timezone, 'Asia/Kuala_Lumpur');
    return jsonb_build_object(
      'kind', 'c2c', 'id', b.id, 'driver_id', b.driver_id,
      'ended', b.status in ('completed', 'cancelled', 'expired'),
      'completed', b.status = 'completed',
      'ended_at', case when b.status in ('completed', 'cancelled', 'expired')
                       then coalesce(b.completed_at, b.cancelled_at, b.expired_at, b.updated_at) end,
      'ref', b.ref,
      'when', to_char(coalesce(b.started_at, b.leave_at) at time zone v_tz, 'DD Mon YYYY, HH24:MI'),
      'route', b.pickup_name || ' to ' || b.drop_name,
      'fare', coalesce(b.agreed_fare, b.fare), 'currency', b.currency,
      'driver_name', (select public.ride_safety_short_name(coalesce(o.driver_name, p.name))
                        from public.profiles p
                        left join public.c2c_offers o on o.id = b.offer_id
                       where p.id = b.driver_id),
      'vehicle', (select nullif(btrim(concat_ws(' · ', o.car, o.plate)), '') from public.c2c_offers o where o.id = b.offer_id),
      'country', b.pickup_place->>'country', 'state', b.pickup_place->>'state', 'city', b.pickup_place->>'city');
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_safety_trip(uuid, uuid, uuid) from public, anon, authenticated;

-- The caller's open report on the trip, if any.
create or replace function public.ride_safety_open_report(p_uid uuid, p_request uuid, p_c2c_booking uuid)
returns public.support_tickets
language sql
stable
security definer
set search_path = public
as $$
  select t.* from public.support_tickets t
   where t.profile_id = p_uid and t.reported_at is not null and t.status <> 'closed'
     and ((p_request is not null and t.request_id = p_request)
          or (p_c2c_booking is not null and t.c2c_booking_id = p_c2c_booking))
   order by t.reported_at desc limit 1;
$$;
revoke execute on function public.ride_safety_open_report(uuid, uuid, uuid) from public, anon, authenticated;

-- The rider reports their trip: a support ticket with the trip linked.
create or replace function public.trip_report_create(p_request uuid, p_category uuid, p_note text default null,
                                                     p_also_block boolean default false,
                                                     p_c2c_booking uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s public.ride_safety_settings;
  trip jsonb;
  c public.trip_report_categories;
  prior public.support_tickets;
  v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 1000);
  v_body text;
  v_rider text;
  v_ticket uuid;
  v_number integer;
  v_blocked boolean := false;
  v_block_error text;
  v_ended timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if (p_request is null) = (p_c2c_booking is null) then
    raise exception 'REPORT_BAD' using errcode = '22023', hint = 'Pick the trip to report.';
  end if;
  trip := public.ride_safety_trip(v_uid, p_request, p_c2c_booking);
  if trip is null then
    raise exception 'REPORT_NOT_YOURS' using errcode = '42501', hint = 'You can report only your own trips.';
  end if;
  if trip->>'driver_id' is null then
    raise exception 'REPORT_NO_DRIVER' using errcode = '22023',
      hint = 'This trip had no driver. Contact support in Help if something went wrong.';
  end if;
  if not (trip->>'ended')::boolean then
    raise exception 'REPORT_NOT_ENDED' using errcode = '22023',
      hint = 'You can report a trip once it has ended. In danger now? Use SOS.';
  end if;
  select * into s from public.ride_safety_settings where id = 1;
  v_ended := (trip->>'ended_at')::timestamptz;
  if v_ended is not null and now() > v_ended + make_interval(days => coalesce(s.report_window_days, 30)) then
    raise exception 'REPORT_WINDOW_CLOSED' using errcode = '22023',
      hint = format('Trips can be reported up to %s days after they end. Contact support in Help.',
                    coalesce(s.report_window_days, 30));
  end if;
  select * into c from public.trip_report_categories where id = p_category and active;
  if c.id is null then
    raise exception 'REPORT_CATEGORY' using errcode = '22023', hint = 'Pick what happened.';
  end if;
  prior := public.ride_safety_open_report(v_uid, p_request, p_c2c_booking);
  if prior.id is not null then
    raise exception 'REPORT_ALREADY' using errcode = '22023',
      hint = format('You reported this trip already (ticket #%s). Add to it in Help, My tickets.', prior.ticket_number);
  end if;

  select nullif(btrim(p.name), '') into v_rider from public.profiles p where p.id = v_uid;
  v_body := 'Trip report: ' || c.label || chr(10)
            || 'Trip ' || (trip->>'ref') || ', ' || (trip->>'when') || chr(10)
            || (trip->>'route')
            || coalesce(' · ' || (trip->>'currency') || ' ' || to_char((trip->>'fare')::numeric, 'FM999999990.00'), '')
            || chr(10)
            || 'Driver: ' || coalesce(trip->>'driver_name', 'Driver') || coalesce(' · ' || (trip->>'vehicle'), '')
            || chr(10) || chr(10)
            || coalesce(v_note, '(No note)');

  insert into public.support_tickets (profile_id, subject, status, last_message, last_message_at, last_sender_role,
                                      unread_admin, unread_user, request_id, c2c_booking_id, report_category,
                                      report_category_id, priority, reported_driver_id, reported_at)
  values (v_uid, left('Trip report: ' || c.label || ' · ' || (trip->>'ref'), 120), 'open', left(v_body, 200), now(),
          'user', 1, 0, p_request, p_c2c_booking, c.label, c.id,
          case when c.urgent then 'urgent' else 'normal' end, (trip->>'driver_id')::uuid, now())
  returning id, ticket_number into v_ticket, v_number;
  insert into public.support_messages (ticket_id, sender_role, sender_id, sender_name, type, body)
  values (v_ticket, 'user', v_uid, v_rider, 'text', v_body);

  if coalesce(p_also_block, false) then
    begin
      perform public.rider_block_insert(v_uid, (trip->>'driver_id')::uuid, p_request, p_c2c_booking, 'report');
      v_blocked := true;
    exception when others then
      -- The report stands; the rider is told why the block didn't.
      get stacked diagnostics v_block_error = pg_exception_hint;
      v_block_error := coalesce(nullif(v_block_error, ''), sqlerrm);
    end;
  end if;

  if c.urgent then
    perform public.ride_safety_alert_admins(
      'trip-report-' || v_ticket,
      'Urgent trip report: ' || c.label,
      coalesce(public.ride_safety_short_name(v_rider), 'A rider') || ' reported ' || coalesce(trip->>'driver_name', 'a driver')
        || ' · ' || (trip->>'ref') || ' · ticket #' || coalesce(v_number::text, '?'),
      jsonb_build_object('type', 'trip_report', 'ticket_id', v_ticket, 'route', '/admin/support/' || v_ticket));
  end if;

  return jsonb_build_object('ticket_id', v_ticket, 'ticket_number', v_number, 'urgent', c.urgent,
                            'category', c.label, 'blocked', v_blocked, 'block_error', v_block_error,
                            'driver_id', trip->>'driver_id');
end;
$$;
revoke execute on function public.trip_report_create(uuid, uuid, text, boolean, uuid) from public, anon;
grant execute on function public.trip_report_create(uuid, uuid, text, boolean, uuid) to authenticated;

-- ---- 6. Cover and permits ------------------------------------------------------------------------------
-- The cover rule for a place: the most specific that holds it (city 3,
-- state 2, country 1, the default 0), on or off; then whether riders see it.
create or replace function public.passenger_cover_for(p_country text, p_state text default null,
                                                      p_city text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when c.id is null then jsonb_build_object('shown', false)
    else jsonb_build_object(
      'shown', c.enabled and btrim(c.insurer) <> '' and btrim(c.policy_no) <> '' and coalesce(c.cover_amount, 0) > 0,
      'rule_id', c.id,
      'place', coalesce(c.city, c.state, c.country),
      'insurer', btrim(c.insurer), 'policy_no', btrim(c.policy_no), 'cover_amount', c.cover_amount,
      'currency', c.currency, 'claim_days', c.claim_days, 'hotline', btrim(c.hotline),
      'terms_url', nullif(btrim(c.terms_url), '')) end
    from (select 1) one
    left join lateral (
      select x.* from public.passenger_cover_rules x
       where (x.country is null or public.commission_place_matches(x.country, p_country))
         and (x.state is null or public.commission_place_matches(x.state, p_state))
         and (x.city is null or public.commission_place_matches(x.city, p_city))
       order by (case when x.city is not null then 3 when x.state is not null then 2
                      when x.country is not null then 1 else 0 end) desc, x.updated_at desc
       limit 1) c on true;
$$;
revoke execute on function public.passenger_cover_for(text, text, text) from public, anon;
grant execute on function public.passenger_cover_for(text, text, text) to authenticated, service_role;

-- The Safety page: the cover where the caller last rode (else their
-- country, else the default), and whether receipts show the driver's permit.
create or replace function public.passenger_cover_mine()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r record;
  v_country text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select x.country, x.state, x.city into r from public.ride_requests x
   where x.rider_id = auth.uid() and x.status = 'completed' and x.country is not null
   order by x.completed_at desc nulls last, x.created_at desc limit 1;
  if r.country is null then
    select nullif(btrim(p.nationality), '') into v_country from public.profiles p where p.id = auth.uid();
  end if;
  return public.passenger_cover_for(coalesce(r.country, v_country), r.state, r.city)
         || jsonb_build_object('show_permit',
              coalesce((select show_driver_permit from public.ride_safety_settings where id = 1), true));
end;
$$;
revoke execute on function public.passenger_cover_mine() from public, anon;
grant execute on function public.passenger_cover_mine() to authenticated;

-- The receipt's safety part, for the trip's rider: the cover (a completed
-- trip), the driver's permits (the admin's switch), reporting (window,
-- categories, an earlier report) and the block.
create or replace function public.trip_safety_info(p_request uuid default null, p_c2c_booking uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s public.ride_safety_settings;
  trip jsonb;
  prior public.support_tickets;
  v_until timestamptz;
  v_permits jsonb := '[]'::jsonb;
  v_cover jsonb;
begin
  if v_uid is null then
    return null;
  end if;
  trip := public.ride_safety_trip(v_uid, p_request, p_c2c_booking);
  if trip is null then
    return null;
  end if;
  select * into s from public.ride_safety_settings where id = 1;
  if (trip->>'ended')::boolean and trip->>'ended_at' is not null then
    v_until := (trip->>'ended_at')::timestamptz + make_interval(days => coalesce(s.report_window_days, 30));
  end if;
  prior := public.ride_safety_open_report(v_uid, p_request, p_c2c_booking);
  if (trip->>'completed')::boolean then
    v_cover := public.passenger_cover_for(trip->>'country', trip->>'state', trip->>'city');
  end if;
  if coalesce(s.show_driver_permit, true) and p_request is not null
     and to_regprocedure('public.ride_permit_items(uuid)') is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', i->>'name', 'short_name', nullif(i->>'short_name', ''), 'issuer', nullif(i->>'issuer', ''),
             'number', (select f->>'value' from jsonb_array_elements(i->'fields') f where f->>'role' = 'number' limit 1),
             'valid_until', (select f->>'value' from jsonb_array_elements(i->'fields') f
                              where f->>'role' = 'valid_until' limit 1))), '[]'::jsonb)
      into v_permits
      from jsonb_array_elements(public.ride_permit_items(p_request)) i;
  end if;
  return jsonb_build_object(
    'trip', trip - array['country', 'state', 'city'],
    'can_report', (trip->>'ended')::boolean and trip->>'driver_id' is not null and prior.id is null
                  and (v_until is null or now() <= v_until),
    'report_until', v_until,
    'report_window_days', coalesce(s.report_window_days, 30),
    'report', case when prior.id is null then null
                   else jsonb_build_object('ticket_id', prior.id, 'ticket_number', prior.ticket_number,
                                           'category', prior.report_category, 'status', prior.status) end,
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'label', x.label, 'urgent', x.urgent,
                                                                'sos_reminder', x.sos_reminder)
                                             order by x.position, x.label)
                              from public.trip_report_categories x where x.active), '[]'::jsonb),
    'blocked', public.rider_blocks_driver(v_uid, (trip->>'driver_id')::uuid),
    'cover', case when coalesce((v_cover->>'shown')::boolean, false) then v_cover end,
    'permits', v_permits);
end;
$$;
revoke execute on function public.trip_safety_info(uuid, uuid) from public, anon;
grant execute on function public.trip_safety_info(uuid, uuid) to authenticated;

-- ---- 5. Driver request filters --------------------------------------------------------------------------
create table if not exists public.driver_request_filters (
  driver_id  uuid primary key references auth.users(id) on delete cascade,
  min_fare   numeric(10,2) not null default 0 check (min_fare >= 0),
  -- Null: any distance.
  max_km     numeric(6,1) check (max_km is null or max_km > 0),
  sort       text not null default 'distance' check (sort in ('newest', 'price', 'distance')),
  updated_at timestamptz not null default now()
);
comment on table public.driver_request_filters is
  'A driver''s request list filters (0311): minimum fare, maximum pickup distance, sort. Only hides requests from the driver''s own list; kept within ride_safety_settings.';

-- Kept within the admin's limits, and always the caller's own row.
create or replace function public.driver_request_filters_clamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.ride_safety_settings;
begin
  if current_user in ('anon', 'authenticated') then
    new.driver_id := auth.uid();
  end if;
  select * into s from public.ride_safety_settings where id = 1;
  new.min_fare := least(greatest(coalesce(new.min_fare, 0), 0), coalesce(s.filter_min_fare_cap, 30));
  if new.max_km is not null then
    new.max_km := least(greatest(new.max_km, coalesce(s.filter_distance_min_km, 1)), coalesce(s.filter_distance_max_km, 10));
  end if;
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.driver_request_filters_clamp() from public, anon, authenticated;
drop trigger if exists trg_driver_request_filters_clamp on public.driver_request_filters;
create trigger trg_driver_request_filters_clamp
  before insert or update on public.driver_request_filters
  for each row execute function public.driver_request_filters_clamp();

alter table public.driver_request_filters enable row level security;
revoke all on public.driver_request_filters from public, anon;
grant select, insert, update, delete on public.driver_request_filters to authenticated;
grant all on public.driver_request_filters to service_role;
drop policy if exists "driver_request_filters own read" on public.driver_request_filters;
create policy "driver_request_filters own read" on public.driver_request_filters for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "driver_request_filters own insert" on public.driver_request_filters;
create policy "driver_request_filters own insert" on public.driver_request_filters for insert to authenticated
  with check (driver_id = (select auth.uid()));
drop policy if exists "driver_request_filters own update" on public.driver_request_filters;
create policy "driver_request_filters own update" on public.driver_request_filters for update to authenticated
  using (driver_id = (select auth.uid())) with check (driver_id = (select auth.uid()));
drop policy if exists "driver_request_filters own delete" on public.driver_request_filters;
create policy "driver_request_filters own delete" on public.driver_request_filters for delete to authenticated
  using (driver_id = (select auth.uid()));

-- ---- Admins: reports and blocks per driver -------------------------------------------------------------
-- Every driver with a report or a block: reports (urgent among them), the
-- riders who blocked them, those since the last review, and the flag.
create or replace function public.admin_driver_safety_flags()
returns table (partner_id uuid, reports integer, urgent integer, blocks integer, blocks_since_review integer,
               flagged boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select coalesce(block_flag_riders, 3) into v_n from public.ride_safety_settings where id = 1;
  v_n := coalesce(v_n, 3);
  return query
    with d as (
      select t.reported_driver_id as id from public.support_tickets t where t.reported_driver_id is not null
      union
      select b.driver_id from public.rider_blocks b
    )
    select d.id,
           (select count(*)::int from public.support_tickets t where t.reported_driver_id = d.id),
           (select count(*)::int from public.support_tickets t where t.reported_driver_id = d.id and t.priority = 'urgent'),
           (select count(*)::int from public.rider_blocks b where b.driver_id = d.id),
           (select count(*)::int from public.rider_blocks b
             where b.driver_id = d.id
               and b.created_at > coalesce((select v.reviewed_at from public.driver_block_reviews v where v.driver_id = d.id),
                                           '-infinity'::timestamptz)),
           (select count(*) from public.rider_blocks b
             where b.driver_id = d.id
               and b.created_at > coalesce((select v.reviewed_at from public.driver_block_reviews v where v.driver_id = d.id),
                                           '-infinity'::timestamptz)) >= v_n
      from d;
end;
$$;
revoke execute on function public.admin_driver_safety_flags() from public, anon;
grant execute on function public.admin_driver_safety_flags() to authenticated;

-- One driver ([p_partner]: the account id): their reports and who blocked them.
create or replace function public.admin_driver_safety(p_partner uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int;
  v_reviewed timestamptz;
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select coalesce(block_flag_riders, 3) into v_n from public.ride_safety_settings where id = 1;
  v_n := coalesce(v_n, 3);
  select reviewed_at into v_reviewed from public.driver_block_reviews where driver_id = p_partner;
  return jsonb_build_object(
    'flag_riders', v_n,
    'reviewed_at', v_reviewed,
    'blocks_since_review', (select count(*) from public.rider_blocks b
                             where b.driver_id = p_partner and b.created_at > coalesce(v_reviewed, '-infinity'::timestamptz)),
    'reports', coalesce((select jsonb_agg(jsonb_build_object(
                           'ticket_id', t.id, 'ticket_number', t.ticket_number, 'category', t.report_category,
                           'urgent', t.priority = 'urgent', 'status', t.status, 'reported_at', t.reported_at,
                           'request_id', t.request_id, 'c2c_booking_id', t.c2c_booking_id,
                           'rider_name', (select p.name from public.profiles p where p.id = t.profile_id))
                         order by t.reported_at desc)
                          from public.support_tickets t where t.reported_driver_id = p_partner), '[]'::jsonb),
    'blocks', coalesce((select jsonb_agg(jsonb_build_object(
                          'rider_id', b.rider_id, 'rider_name', p.name, 'blocked_at', b.created_at,
                          'source', b.source, 'request_id', b.request_id) order by b.created_at desc)
                         from public.rider_blocks b left join public.profiles p on p.id = b.rider_id
                        where b.driver_id = p_partner), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_driver_safety(uuid) from public, anon;
grant execute on function public.admin_driver_safety(uuid) to authenticated;

create or replace function public.admin_driver_block_review(p_partner uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_driver_block_review') then
    raise exception 'Only admins who can edit partners can mark blocks reviewed.' using errcode = '42501';
  end if;
  if p_partner is null then
    raise exception 'BLOCK_REVIEW_BAD' using errcode = '22023';
  end if;
  insert into public.driver_block_reviews (driver_id, reviewed_at, reviewed_by)
  values (p_partner, now(), auth.uid())
  on conflict (driver_id) do update set reviewed_at = now(), reviewed_by = auth.uid();
end;
$$;
revoke execute on function public.admin_driver_block_review(uuid) from public, anon;
grant execute on function public.admin_driver_block_review(uuid) to authenticated;

-- ---- Which admin pages write what (0223) -----------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('ride_safety_settings', 'admin-settings-ride-safety'),
  ('trip_report_categories', 'admin-settings-ride-safety'),
  ('passenger_cover_rules', 'admin-settings-ride-safety'),
  ('rpc:admin_driver_block_review', 'admin-partners'),
  ('rpc:admin_driver_block_review', 'admin-settings-ride-safety')
on conflict do nothing;

-- ---- Live: the admin's changes reach the apps at once ------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  foreach t in array array['ride_safety_settings', 'trip_report_categories', 'passenger_cover_rules',
                           'rider_blocks'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
