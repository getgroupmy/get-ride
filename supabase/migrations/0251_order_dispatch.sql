-- ============================================================================
-- 0251: Order dispatch — stands, their admins and staff, groups and fleets
--
-- A stand is a pickup point with a counter: a taxi stand, a mall or hotel
-- concierge, a bus terminal or train station counter, a hospital, an event
-- venue. Its people create an order for a walk-in customer and either
-- assign it to one driver or broadcast it to a group:
--
--   * closed: only its approved members get the order;
--   * open:   its members get it first for members_first_sec seconds, then
--             any approved driver can take it, like a normal booking;
--   * fleet:  the drivers of one company's cars (the vehicles a partner
--             owns, vehicle.owner_partner_id, and whoever drives them), plus
--             the drivers its owner added or let in.
--
-- Roles (every one an ordinary account: phone + PIN, the same app):
--   * Admin (admin_access): every stand; creates stand admin and fleet owner
--     IDs (Admin → Dispatch → Accounts) through the dispatch-account function.
--   * Stand admin (dispatch_stand_people, role 'admin'): the console of their
--     stands, and their own staff: creates staff IDs and sets each one's
--     access (assign, broadcast, fixed fare, cancel, reassign, see reports)
--     and on/off. Never more than a stand admin has, never admin rights.
--   * Stand staff (role 'staff'): the console of their stand, within their
--     access — enforced here, not only hidden in the app.
--   * Fleet owner (dispatch_fleet_owners): their fleet only — its drivers
--     (adds them by phone or plate, removes them), the drivers asking to
--     join it, and its stand orders and takings.
-- Drivers ask to join from their app; closed and open groups are approved
-- by an admin, a fleet by its owner (or an admin).
--
-- The order is an ordinary ride_requests row (rider_id null), so drivers
-- take it with the same Accept, and it runs accepted → arrived → on_trip →
-- completed on their usual screens. What is new on the row is who it was
-- offered to; the read policy and a claim guard keep it to them, so a
-- modified app can neither see nor take an order it was not offered:
--
--   * assign:    the named driver, for 30 seconds; then it is back with the
--                stand (dispatch_returned_at) until someone re-sends it;
--   * broadcast: the group's members (see above); Re-send can widen it to
--                any nearby driver (dispatch_widened_at).
--
-- Stand people read their own stands' orders and write only through the
-- RPCs below, each checking their access on that stand. Every action is
-- logged with the person's name (dispatch_order_events).
--
-- Money, per stand:
--   * settlement for "paid at counter" (and card / e-wallet at the counter):
--     'wallet' pays the driver's fare into their GET.wallet when the trip is
--     done (stand_payout); 'outside' records the trip as paid and moves
--     nothing;
--   * a stand fee: fixed RM or % of the fare, paid by the customer (added
--     to what they pay) or the driver (taken off what they get; the usual
--     commission still applies). Admins set it, or the stand admin when the
--     admin lets them (fee_set_by). Out of it the platform takes its fee
--     from the stand (% of the stand fee or fixed per order, admins only);
--     the stand keeps the rest, in its account (owner_id, else its stand
--     admin). Ledger rows (wallet_transactions, one of each kind per ride):
--       paid at the counter, settled in the app: stand_payout (+ driver's
--       GET.wallet), stand_payout_due and stand_platform_fee (- the stand's
--       GET.credit: what it owes for the driver and the platform);
--       cash to the driver: stand_fee (- the driver's GET.credit, who holds
--       the fee), stand_fee_earning (+ the stand's GET.wallet, its share).
--     dispatch_statement is the stand's statement.
--
-- With 0249 (airports) and 0250 (the service order):
--   * the service order, when on, applies to stand orders as to any other:
--     an assigned or re-sent driver, a group's pushes, the read rule and
--     the claim all go by service_order_driver_allows;
--   * a stand inside an airport: the stand's own orders (assign, broadcast)
--     are not held for the airport's queue and keep the stand's fare; only
--     the Call centre's "Nearby drivers · normal booking" follows the
--     airport's rules, as an app booking does;
--   * the stand's operators read their open orders through both restrictive
--     read rules, to watch them on the board.
-- ============================================================================

-- ---- Groups and fleets -----------------------------------------------------------------------
create table if not exists public.dispatch_groups (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null check (char_length(btrim(name)) between 1 and 80),
  kind                   text not null check (kind in ('closed', 'open', 'fleet')),
  -- Open groups: how long only the members see a new order.
  members_first_sec      integer not null default 30 check (members_first_sec between 0 and 600),
  -- Fleets: the partner whose cars make the fleet (vehicle.owner_partner_id).
  fleet_owner_partner_id uuid references public.partners(id) on delete set null,
  -- Drivers may ask to join from their app.
  allow_join             boolean not null default true,
  active                 boolean not null default true,
  note                   text check (note is null or char_length(note) <= 500),
  created_by             uuid references public.profiles(id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index if not exists dispatch_groups_fleet_owner_idx on public.dispatch_groups (fleet_owner_partner_id);
create index if not exists dispatch_groups_created_by_idx on public.dispatch_groups (created_by);

-- Members and join requests: one row per driver and group. A driver's own
-- row starts 'pending'; an admin approves or rejects it, or removes it.
create table if not exists public.dispatch_group_members (
  group_id     uuid not null references public.dispatch_groups(id) on delete cascade,
  driver_id    uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   uuid references public.profiles(id) on delete set null,
  primary key (group_id, driver_id)
);
create index if not exists dispatch_group_members_driver_idx on public.dispatch_group_members (driver_id);
create index if not exists dispatch_group_members_decided_by_idx on public.dispatch_group_members (decided_by);
create index if not exists dispatch_group_members_pending_idx on public.dispatch_group_members (requested_at)
  where status = 'pending';

-- ---- Stands ---------------------------------------------------------------------------------
create table if not exists public.dispatch_stands (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (char_length(btrim(name)) between 1 and 120),
  kind             text not null default 'other'
    check (kind in ('mall', 'hotel', 'bus_terminal', 'train_station', 'airport', 'hospital', 'event_venue', 'other',
                    'call_centre')),
  -- The ticket numbers' prefix: PAV-0041.
  code             text not null unique check (code ~ '^[A-Z0-9]{2,6}$'),
  address          text check (address is null or char_length(address) <= 300),
  -- Null only on an admins-only pickup (the Call centre: each order has its own).
  lat              double precision check (lat between -90 and 90),
  lng              double precision check (lng between -180 and 180),
  -- Admins only: never a stand admin's or staff's (the Call centre).
  admin_only       boolean not null default false,
  allow_fixed_fare boolean not null default false,
  settlement       text not null default 'wallet' check (settlement in ('wallet', 'outside')),
  fee_type         text not null default 'none' check (fee_type in ('none', 'fixed', 'percent')),
  fee_value        numeric(10,2) not null default 0 check (fee_value >= 0 and fee_value <= 10000),
  fee_bearer       text not null default 'customer' check (fee_bearer in ('customer', 'driver')),
  -- Who sets the stand fee: admins only, or the stand admin too.
  fee_set_by       text not null default 'admin' check (fee_set_by in ('admin', 'stand')),
  -- What the platform takes from the stand per order, out of its fee: a
  -- percentage of the stand fee, or a fixed amount. Admins only.
  platform_fee_type  text not null default 'percent' check (platform_fee_type in ('percent', 'fixed')),
  platform_fee_value numeric(10,2) not null default 0 check (platform_fee_value >= 0 and platform_fee_value <= 10000),
  -- The account the stand's earnings go to (else its first stand admin).
  owner_id         uuid references public.profiles(id) on delete set null,
  next_ticket      integer not null default 1 check (next_ticket >= 1),
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (fee_type <> 'percent' or fee_value <= 100),
  check (platform_fee_type <> 'percent' or platform_fee_value <= 100),
  check (admin_only or (lat is not null and lng is not null))
);
create index if not exists dispatch_stands_owner_idx on public.dispatch_stands (owner_id);

-- The groups and fleets a stand may send to.
create table if not exists public.dispatch_stand_groups (
  stand_id uuid not null references public.dispatch_stands(id) on delete cascade,
  group_id uuid not null references public.dispatch_groups(id) on delete cascade,
  primary key (stand_id, group_id)
);
create index if not exists dispatch_stand_groups_group_idx on public.dispatch_stand_groups (group_id);

-- Who runs a stand. A stand admin (an ID an admin creates) may do everything
-- at their stands and creates their own staff; a staff member (an ID their
-- stand admin creates) may do what their access says. A disabled row is no
-- access at all.
create table if not exists public.dispatch_stand_people (
  stand_id       uuid not null references public.dispatch_stands(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  role           text not null default 'staff' check (role in ('admin', 'staff')),
  name           text check (name is null or char_length(name) <= 80),
  phone          text check (phone is null or char_length(phone) <= 32),
  can_assign     boolean not null default false,
  can_broadcast  boolean not null default true,
  can_fixed_fare boolean not null default false,
  can_cancel     boolean not null default false,
  can_reassign   boolean not null default false,
  can_reports    boolean not null default false,
  active         boolean not null default true,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (stand_id, user_id)
);
create index if not exists dispatch_stand_people_user_idx on public.dispatch_stand_people (user_id);
create index if not exists dispatch_stand_people_created_by_idx on public.dispatch_stand_people (created_by);

-- A fleet owner's ID: runs one fleet (a 'fleet' group) — its drivers, the
-- drivers asking to join it, and its orders.
create table if not exists public.dispatch_fleet_owners (
  group_id   uuid not null references public.dispatch_groups(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  name       text check (name is null or char_length(name) <= 120),
  phone      text check (phone is null or char_length(phone) <= 32),
  active     boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists dispatch_fleet_owners_user_idx on public.dispatch_fleet_owners (user_id);
create index if not exists dispatch_fleet_owners_created_by_idx on public.dispatch_fleet_owners (created_by);

-- ---- The order on the ride ------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists stand_id               uuid references public.dispatch_stands(id) on delete set null,
  add column if not exists ticket_no              text,
  add column if not exists dispatch_stand_name    text,
  add column if not exists dispatch_created_by    uuid references public.profiles(id) on delete set null,
  add column if not exists dispatch_mode          text,
  add column if not exists dispatch_group_id      uuid references public.dispatch_groups(id) on delete set null,
  add column if not exists dispatch_group_name    text,
  add column if not exists dispatch_group_kind    text,
  add column if not exists dispatch_driver_id     uuid references public.profiles(id) on delete set null,
  add column if not exists dispatch_offered_at    timestamptz,
  add column if not exists dispatch_offer_until   timestamptz,
  add column if not exists dispatch_open_after    timestamptz,
  add column if not exists dispatch_widened_at    timestamptz,
  add column if not exists dispatch_widen_pushed_at timestamptz,
  add column if not exists dispatch_returned_at   timestamptz,
  add column if not exists fare_mode              text,
  add column if not exists dispatch_payment       text,
  add column if not exists stand_settlement       text,
  add column if not exists stand_fee_type         text,
  add column if not exists stand_fee_value        numeric(10,2),
  add column if not exists stand_fee_bearer       text,
  add column if not exists stand_fee_earner_id    uuid references public.profiles(id) on delete set null,
  add column if not exists stand_fee_amount       numeric(10,2),
  add column if not exists stand_platform_fee_type  text,
  add column if not exists stand_platform_fee_value numeric(10,2),
  add column if not exists stand_platform_fee     numeric(10,2),
  add column if not exists dispatch_settled_at    timestamptz,
  -- Call centre bookings: how the customer asked, and whether the ride is on
  -- their own GET.ride account (rider_id) or a guest's.
  add column if not exists dispatch_booked_via    text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ride_requests_dispatch_shape') then
    alter table public.ride_requests add constraint ride_requests_dispatch_shape check (
      (dispatch_mode is null or dispatch_mode in ('assign', 'broadcast', 'nearby'))
      and (dispatch_booked_via is null or dispatch_booked_via in ('phone', 'sms', 'whatsapp'))
      and (dispatch_group_kind is null or dispatch_group_kind in ('closed', 'open', 'fleet'))
      and (fare_mode is null or fare_mode in ('meter', 'estimate', 'fixed'))
      and (dispatch_payment is null or dispatch_payment in ('counter', 'cash', 'app'))
      and (stand_settlement is null or stand_settlement in ('wallet', 'outside'))
      and (stand_fee_type is null or stand_fee_type in ('none', 'fixed', 'percent'))
      and (stand_fee_bearer is null or stand_fee_bearer in ('customer', 'driver'))
      and (stand_fee_amount is null or stand_fee_amount >= 0)
      and (stand_id is null or (ticket_no is not null and dispatch_mode is not null))
    );
  end if;
end $$;

-- One live ride per ticket (a scheduled booking released again after nobody
-- took it leaves an expired row with the same ticket).
create unique index if not exists ride_requests_stand_ticket_key
  on public.ride_requests (stand_id, ticket_no) where stand_id is not null and status <> 'expired';
create index if not exists ride_requests_stand_idx
  on public.ride_requests (stand_id, created_at desc) where stand_id is not null;
create index if not exists ride_requests_dispatch_created_by_idx on public.ride_requests (dispatch_created_by);
create index if not exists ride_requests_dispatch_group_idx on public.ride_requests (dispatch_group_id);
create index if not exists ride_requests_dispatch_driver_idx on public.ride_requests (dispatch_driver_id);
create index if not exists ride_requests_stand_fee_earner_idx on public.ride_requests (stand_fee_earner_id);

-- ---- Booked ahead: the scheduled-rides machinery (0189, 0198) ---------------------------------
-- A stand's (or the Call centre's) booking for later is a scheduled_rides row
-- like a rider's: the same release loop, reminders and driver requests. It
-- may have no rider (a walk-in or guest), names its stand, and goes out
-- [lead_minutes] before pickup instead of the setting's release time. Its
-- request carries the order's dispatch fields to the ride it becomes.
alter table public.scheduled_rides alter column rider_id drop not null;
alter table public.scheduled_rides
  add column if not exists stand_id     uuid references public.dispatch_stands(id) on delete set null,
  add column if not exists lead_minutes integer;
create index if not exists scheduled_rides_stand_idx on public.scheduled_rides (stand_id, pickup_at)
  where stand_id is not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'scheduled_rides_dispatch_shape') then
    alter table public.scheduled_rides add constraint scheduled_rides_dispatch_shape check (
      (rider_id is not null or stand_id is not null)
      and (lead_minutes is null or lead_minutes between 5 and 180));
  end if;
end $$;
-- A stand's request to its assigned driver may have no rider.
alter table public.scheduled_ride_offers alter column rider_id drop not null;

-- A counter payment is recorded as paid at the counter.
alter table public.ride_requests drop constraint if exists ride_requests_paid_method_check;
alter table public.ride_requests add constraint ride_requests_paid_method_check
  check (paid_method is null or paid_method in ('get_wallet', 'get_coin', 'cash', 'counter'));

-- One of each stand money row per ride in the ledger.
create unique index if not exists wallet_transactions_stand_ride_key
  on public.wallet_transactions (ride_id, kind)
  where kind in ('stand_payout', 'stand_payout_due', 'stand_platform_fee', 'stand_fee', 'stand_fee_earning');

-- ---- What every operator action leaves behind -------------------------------------------------
create table if not exists public.dispatch_order_events (
  id         uuid primary key default gen_random_uuid(),
  -- The ride, or (booked ahead, not yet released) the scheduled booking.
  request_id uuid references public.ride_requests(id) on delete cascade,
  scheduled_ride_id uuid references public.scheduled_rides(id) on delete cascade,
  stand_id   uuid not null references public.dispatch_stands(id) on delete cascade,
  actor_id   uuid references public.profiles(id) on delete set null,
  actor_name text,
  action     text not null check (char_length(action) between 1 and 40),
  detail     text check (detail is null or char_length(detail) <= 300),
  at         timestamptz not null default now(),
  check (request_id is not null or scheduled_ride_id is not null)
);
create index if not exists dispatch_order_events_request_idx on public.dispatch_order_events (request_id, at);
create index if not exists dispatch_order_events_stand_idx on public.dispatch_order_events (stand_id, at desc);
create index if not exists dispatch_order_events_actor_idx on public.dispatch_order_events (actor_id);
create index if not exists dispatch_order_events_scheduled_idx on public.dispatch_order_events (scheduled_ride_id, at);

-- ---- Fleet vehicles and their drivers (see "A fleet's vehicles" below) -----------------------
alter table public.vehicle add column if not exists dispatch_fleet_id uuid
  references public.dispatch_groups(id) on delete set null;
create index if not exists vehicle_dispatch_fleet_idx on public.vehicle (dispatch_fleet_id);

alter table public.vehicle_user_assignment
  add column if not exists approval text not null default 'approved',
  add column if not exists dispatch_fleet_id uuid references public.dispatch_groups(id) on delete set null;
create index if not exists vehicle_user_assignment_dispatch_fleet_idx on public.vehicle_user_assignment (dispatch_fleet_id);
create index if not exists vehicle_user_assignment_pending_idx on public.vehicle_user_assignment (assigned_at)
  where approval = 'pending';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'vehicle_user_assignment_approval_check') then
    alter table public.vehicle_user_assignment add constraint vehicle_user_assignment_approval_check
      check (approval in ('pending', 'approved', 'rejected'));
  end if;
end $$;

-- ---- Small pure helpers (mirrored in lib/src/core/dispatch.dart) --------------------------------
-- "PAV-0041": the stand's code and its running number, at least four digits.
create or replace function public.dispatch_ticket_text(p_code text, p_n integer)
returns text
language sql
immutable
set search_path = ''
as $$ select p_code || '-' || lpad(p_n::text, greatest(4, char_length(p_n::text)), '0') $$;

-- The fee on a fare: a fixed amount, or a percentage rounded to the sen.
create or replace function public.dispatch_fee_amount(p_type text, p_value numeric, p_fare numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when p_type = 'fixed' then round(greatest(0, coalesce(p_value, 0)), 2)
    when p_type = 'percent' then round(greatest(0, coalesce(p_fare, 0)) * least(100, greatest(0, coalesce(p_value, 0))) / 100, 2)
    else 0::numeric end
$$;

-- A stand order's money (mirrored by dispatchSplit in lib/src/core/dispatch.dart):
--   fee      the stand fee on the fare;
--   platform what the platform takes out of it (a % of it, or fixed; never
--            more than the fee);
--   stand    what the stand keeps (fee - platform);
--   customer what the customer pays (the fare, plus the fee they bear);
--   driver   what the driver gets before the usual commission (the fare,
--            less the fee they bear).
create or replace function public.dispatch_split(p_fare numeric, p_fee_type text, p_fee_value numeric, p_payer text,
                                                 p_platform_type text, p_platform_value numeric)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with f as (select round(greatest(0, coalesce(p_fare, 0)), 2) as fare,
                    public.dispatch_fee_amount(p_fee_type, p_fee_value, p_fare) as fee),
       p as (select f.*, least(f.fee, case
                when coalesce(p_platform_type, 'percent') = 'fixed' then round(greatest(0, coalesce(p_platform_value, 0)), 2)
                else round(f.fee * least(100, greatest(0, coalesce(p_platform_value, 0))) / 100, 2) end) as platform
               from f)
  select jsonb_build_object(
    'fare', fare, 'fee', fee, 'platform', platform, 'stand', fee - platform,
    'customer', fare + case when p_payer = 'customer' then fee else 0 end,
    'driver', fare - case when p_payer = 'driver' then fee else 0 end)
    from p
$$;

create or replace function public.dispatch_km(p_lat1 double precision, p_lng1 double precision,
                                              p_lat2 double precision, p_lng2 double precision)
returns double precision
language sql
immutable
set search_path = ''
as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(p_lat2 - p_lat1) / 2), 2)
    + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2)))
$$;

-- ---- Who is in a group ----------------------------------------------------------------------
-- An approved member, or (a fleet) a driver of one of the fleet owner's cars,
-- or the owner themself.
create or replace function public.dispatch_member_of(p_group uuid, p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_group is not null and p_driver is not null and (
    exists (select 1 from public.dispatch_group_members m
             where m.group_id = p_group and m.driver_id = p_driver and m.status = 'approved')
    or exists (
      select 1 from public.dispatch_groups g
       where g.id = p_group and g.kind = 'fleet' and g.fleet_owner_partner_id is not null
         and (exists (select 1 from public.partners pa
                       where pa.id = g.fleet_owner_partner_id and pa.auth_user_id = p_driver)
              or exists (select 1 from public.vehicle_user_assignment a
                           join public.vehicle v on v.id = a.vehicle_id
                          where v.owner_partner_id = g.fleet_owner_partner_id
                            and a.user_id = p_driver and a.is_active and a.approval = 'approved')))
  );
$$;
revoke execute on function public.dispatch_member_of(uuid, uuid) from public, anon;
grant execute on function public.dispatch_member_of(uuid, uuid) to authenticated, service_role;

-- Whether a stand order is offered to [p_driver] now (the row's columns are
-- passed in, so the read policy needn't read the row again):
--   assign:    the named driver, inside the accept window, until it returns;
--   broadcast: widened → any approved driver; else a member of the group;
--              an open group's order → anyone once the members' time is up.
create or replace function public.dispatch_offer_ok(
  p_driver uuid, p_mode text, p_target uuid, p_group uuid,
  p_until timestamptz, p_open_after timestamptz, p_widened timestamptz, p_returned timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_driver is null then false
    when p_mode = 'assign' then p_driver = p_target and p_returned is null and p_until is not null and p_until > now()
    -- Like a booking made in the app: any approved driver.
    when p_mode = 'nearby' then true
    when p_mode = 'broadcast' then
      p_widened is not null
      or (p_open_after is not null and p_open_after <= now())
      or public.dispatch_member_of(p_group, p_driver)
    else false end;
$$;
revoke execute on function public.dispatch_offer_ok(uuid, text, uuid, uuid, timestamptz, timestamptz, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.dispatch_offer_ok(uuid, text, uuid, uuid, timestamptz, timestamptz, timestamptz, timestamptz)
  to authenticated, service_role;

-- A driver busy with another trip.
create or replace function public.dispatch_driver_busy(p_driver uuid, p_except uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ride_requests r
                  where r.partner_id = p_driver and r.status in ('accepted', 'arrived', 'on_trip')
                    and r.id is distinct from p_except
                    and r.updated_at > now() - interval '12 hours');
$$;
revoke execute on function public.dispatch_driver_busy(uuid, uuid) from public, anon, authenticated;

-- The car a driver is driving: the vehicle of their active session (as
-- ride_partner_card stamps on a ride they take), else the one on their
-- partner record. {plate, vehicle: "Silver Toyota Vios"} (colour, make, model).
create or replace function public.dispatch_driver_car(p_driver uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with car as (
    select v.plate, nullif(btrim(concat_ws(' ', v.color, v.make, v.model)), '') as label
      from public.vehicle_active_session s
      join public.vehicle v on v.id = s.vehicle_id
     where s.user_id = p_driver
     limit 1
  ), me as (
    select p.plate, coalesce(nullif(btrim(concat_ws(' ', p.make, p.model)), ''), nullif(btrim(p.vehicle), '')) as label
      from public.partners p
     where p.auth_user_id = p_driver
     order by p.updated_at desc
     limit 1
  )
  select jsonb_build_object(
    'plate', coalesce(nullif(btrim((select plate from car)), ''), nullif(btrim((select plate from me)), '')),
    'vehicle', coalesce((select label from car), (select label from me)));
$$;
revoke execute on function public.dispatch_driver_car(uuid) from public, anon, authenticated;

-- The same for the caller (the claim guard runs as the caller).
create or replace function public.dispatch_caller_busy(p_except uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.dispatch_driver_busy(auth.uid(), p_except) $$;
revoke execute on function public.dispatch_caller_busy(uuid) from public, anon;
grant execute on function public.dispatch_caller_busy(uuid) to authenticated;

-- ---- Who runs a stand -----------------------------------------------------------------------
-- The stands the caller works at (stand admin or staff, active).
create or replace function public.dispatch_caller_stand_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(o.stand_id), '{}')
    from public.dispatch_stand_people o
    join public.dispatch_stands s on s.id = o.stand_id
   where o.user_id = auth.uid() and o.active and s.active and not s.admin_only;
$$;
revoke execute on function public.dispatch_caller_stand_ids() from public, anon;
grant execute on function public.dispatch_caller_stand_ids() to authenticated;

-- The stands the caller is the stand admin of.
create or replace function public.dispatch_caller_admin_stand_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(o.stand_id), '{}')
    from public.dispatch_stand_people o
    join public.dispatch_stands s on s.id = o.stand_id
   where o.user_id = auth.uid() and o.role = 'admin' and o.active and s.active and not s.admin_only;
$$;
revoke execute on function public.dispatch_caller_admin_stand_ids() from public, anon;
grant execute on function public.dispatch_caller_admin_stand_ids() to authenticated;

-- The fleets (groups) the caller owns.
create or replace function public.dispatch_caller_fleet_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(f.group_id), '{}')
    from public.dispatch_fleet_owners f
    join public.dispatch_groups g on g.id = f.group_id
   where f.user_id = auth.uid() and f.active and g.active and g.kind = 'fleet';
$$;
revoke execute on function public.dispatch_caller_fleet_ids() from public, anon;
grant execute on function public.dispatch_caller_fleet_ids() to authenticated;

-- Whether [p_user] may [p_perm] ('use', 'assign', 'broadcast', 'fixed_fare',
-- 'cancel', 'reassign', 'reports', 'staff') on [p_stand]: a stand admin may
-- everything there; staff what their access says ('staff', managing staff,
-- is the stand admin's alone).
create or replace function public.dispatch_person_can(p_user uuid, p_stand uuid, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case
      when o.role = 'admin' then true
      else case p_perm
        when 'use' then true
        when 'assign' then o.can_assign
        when 'broadcast' then o.can_broadcast
        when 'fixed_fare' then o.can_fixed_fare
        when 'cancel' then o.can_cancel
        when 'reassign' then o.can_reassign
        when 'reports' then o.can_reports
        else false end end
      from public.dispatch_stand_people o
      join public.dispatch_stands s on s.id = o.stand_id and s.active and not s.admin_only
     where o.stand_id = p_stand and o.user_id = p_user and o.active), false);
$$;
revoke execute on function public.dispatch_person_can(uuid, uuid, text) from public, anon, authenticated;

-- The same for the caller, where an admin with the Dispatch console page may
-- everything at every stand.
create or replace function public.dispatch_caller_can(p_stand uuid, p_perm text default 'use')
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;
  if public.caller_admin_can_write('rpc:dispatch_console') then
    return true;
  end if;
  return public.dispatch_person_can(auth.uid(), p_stand, p_perm);
end;
$$;
revoke execute on function public.dispatch_caller_can(uuid, text) from public, anon;
grant execute on function public.dispatch_caller_can(uuid, text) to authenticated;

-- Who did it, for the action log.
create or replace function public.dispatch_actor_name(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select nullif(btrim(o.name), '') from public.dispatch_stand_people o where o.user_id = p_uid
      order by o.updated_at desc limit 1),
    (select nullif(btrim(p.name), '') from public.profiles p where p.id = p_uid),
    (select nullif(btrim(pa.name), '') from public.partners pa where pa.auth_user_id = p_uid
      order by pa.updated_at desc limit 1),
    (select nullif(btrim(p.phone), '') from public.profiles p where p.id = p_uid),
    case when p_uid is null then 'System' else 'Admin' end);
$$;
revoke execute on function public.dispatch_actor_name(uuid) from public, anon, authenticated;

create or replace function public.dispatch_log(p_request uuid, p_stand uuid, p_action text, p_detail text default null,
                                               p_actor uuid default auth.uid())
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.dispatch_order_events (request_id, stand_id, actor_id, actor_name, action, detail)
  values (p_request, p_stand, p_actor, public.dispatch_actor_name(p_actor), p_action, left(p_detail, 300));
$$;
revoke execute on function public.dispatch_log(uuid, uuid, text, text, uuid) from public, anon, authenticated;

create or replace function public.dispatch_log_scheduled(p_booking uuid, p_stand uuid, p_action text,
                                                         p_detail text default null, p_actor uuid default auth.uid())
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.dispatch_order_events (scheduled_ride_id, stand_id, actor_id, actor_name, action, detail)
  values (p_booking, p_stand, p_actor, public.dispatch_actor_name(p_actor), p_action, left(p_detail, 300));
$$;
revoke execute on function public.dispatch_log_scheduled(uuid, uuid, text, text, uuid) from public, anon, authenticated;

-- ---- Row-level security ---------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('rpc:dispatch_console',   'admin-dispatch'),
  ('dispatch_stands',        'admin-dispatch-stands'),
  ('dispatch_stand_groups',  'admin-dispatch-stands'),
  ('dispatch_stand_people',  'admin-dispatch-stands'),
  ('dispatch_groups',        'admin-dispatch-groups'),
  ('dispatch_group_members', 'admin-dispatch-groups'),
  ('dispatch_fleet_owners',  'admin-dispatch-accounts'),
  ('dispatch_stand_people',  'admin-dispatch-accounts'),
  ('rpc:dispatch_accounts',  'admin-dispatch-accounts')
on conflict do nothing;

alter table public.dispatch_groups enable row level security;
alter table public.dispatch_group_members enable row level security;
alter table public.dispatch_stands enable row level security;
alter table public.dispatch_stand_groups enable row level security;
alter table public.dispatch_stand_people enable row level security;
alter table public.dispatch_fleet_owners enable row level security;
alter table public.dispatch_order_events enable row level security;

revoke all on public.dispatch_groups, public.dispatch_group_members, public.dispatch_stands,
  public.dispatch_stand_groups, public.dispatch_stand_people, public.dispatch_fleet_owners,
  public.dispatch_order_events from anon;
grant select, insert, update, delete on public.dispatch_groups, public.dispatch_stands,
  public.dispatch_stand_groups, public.dispatch_stand_people, public.dispatch_fleet_owners,
  public.dispatch_group_members to authenticated;
revoke all on public.dispatch_order_events from authenticated;
grant select on public.dispatch_order_events to authenticated;

-- Groups: drivers see the ones they may ask to join (and their own); a fleet
-- owner theirs; admins all.
drop policy if exists "dispatch_groups read" on public.dispatch_groups;
create policy "dispatch_groups read" on public.dispatch_groups
  for select to authenticated using (
    (active and allow_join)
    or exists (select 1 from public.dispatch_group_members m
                where m.group_id = dispatch_groups.id and m.driver_id = (select auth.uid()))
    or array[id] <@ (select public.dispatch_caller_fleet_ids())
    or (select public.caller_is_admin()));
drop policy if exists "dispatch_groups admin insert" on public.dispatch_groups;
create policy "dispatch_groups admin insert" on public.dispatch_groups
  for insert to authenticated with check ((select public.caller_admin_can_write('dispatch_groups')));
drop policy if exists "dispatch_groups admin update" on public.dispatch_groups;
create policy "dispatch_groups admin update" on public.dispatch_groups
  for update to authenticated using ((select public.caller_admin_can_write('dispatch_groups')))
  with check ((select public.caller_admin_can_write('dispatch_groups')));
drop policy if exists "dispatch_groups admin delete" on public.dispatch_groups;
create policy "dispatch_groups admin delete" on public.dispatch_groups
  for delete to authenticated using ((select public.caller_admin_can_write('dispatch_groups')));

-- Members: a driver reads, asks for and leaves their own; admins decide for
-- every group, a fleet owner for their fleet.
drop policy if exists "dispatch_group_members read" on public.dispatch_group_members;
create policy "dispatch_group_members read" on public.dispatch_group_members
  for select to authenticated using (
    driver_id = (select auth.uid())
    or array[group_id] <@ (select public.dispatch_caller_fleet_ids())
    or (select public.caller_is_admin()));
drop policy if exists "dispatch_group_members ask" on public.dispatch_group_members;
create policy "dispatch_group_members ask" on public.dispatch_group_members
  for insert to authenticated with check (
    (driver_id = (select auth.uid()) and status = 'pending' and (select public.caller_is_approved_partner()))
    or array[group_id] <@ (select public.dispatch_caller_fleet_ids())
    or (select public.caller_admin_can_write('dispatch_group_members')));
drop policy if exists "dispatch_group_members decide" on public.dispatch_group_members;
create policy "dispatch_group_members decide" on public.dispatch_group_members
  for update to authenticated using (
    array[group_id] <@ (select public.dispatch_caller_fleet_ids())
    or (select public.caller_admin_can_write('dispatch_group_members')))
  with check (
    array[group_id] <@ (select public.dispatch_caller_fleet_ids())
    or (select public.caller_admin_can_write('dispatch_group_members')));
drop policy if exists "dispatch_group_members leave" on public.dispatch_group_members;
create policy "dispatch_group_members leave" on public.dispatch_group_members
  for delete to authenticated using (
    driver_id = (select auth.uid())
    or array[group_id] <@ (select public.dispatch_caller_fleet_ids())
    or (select public.caller_admin_can_write('dispatch_group_members')));

-- Stands: the people who work there, and admins.
drop policy if exists "dispatch_stands read" on public.dispatch_stands;
create policy "dispatch_stands read" on public.dispatch_stands
  for select to authenticated using (
    array[id] <@ (select public.dispatch_caller_stand_ids()) or (select public.caller_is_admin()));
drop policy if exists "dispatch_stands admin insert" on public.dispatch_stands;
create policy "dispatch_stands admin insert" on public.dispatch_stands
  for insert to authenticated with check ((select public.caller_admin_can_write('dispatch_stands')));
drop policy if exists "dispatch_stands admin update" on public.dispatch_stands;
create policy "dispatch_stands admin update" on public.dispatch_stands
  for update to authenticated using ((select public.caller_admin_can_write('dispatch_stands')))
  with check ((select public.caller_admin_can_write('dispatch_stands')));
drop policy if exists "dispatch_stands admin delete" on public.dispatch_stands;
create policy "dispatch_stands admin delete" on public.dispatch_stands
  for delete to authenticated using ((select public.caller_admin_can_write('dispatch_stands')));

drop policy if exists "dispatch_stand_groups read" on public.dispatch_stand_groups;
create policy "dispatch_stand_groups read" on public.dispatch_stand_groups
  for select to authenticated using (
    array[stand_id] <@ (select public.dispatch_caller_stand_ids()) or (select public.caller_is_admin()));
drop policy if exists "dispatch_stand_groups admin insert" on public.dispatch_stand_groups;
create policy "dispatch_stand_groups admin insert" on public.dispatch_stand_groups
  for insert to authenticated with check ((select public.caller_admin_can_write('dispatch_stand_groups')));
drop policy if exists "dispatch_stand_groups admin delete" on public.dispatch_stand_groups;
create policy "dispatch_stand_groups admin delete" on public.dispatch_stand_groups
  for delete to authenticated using ((select public.caller_admin_can_write('dispatch_stand_groups')));

-- Stand people: each reads their own rows; a stand admin their stands'
-- staff, and changes their access or turns them off (never a stand admin's
-- row, and never into one: dispatch_people_guard). New IDs come from
-- dispatch_grant, through the dispatch-account function.
drop policy if exists "dispatch_stand_people read" on public.dispatch_stand_people;
create policy "dispatch_stand_people read" on public.dispatch_stand_people
  for select to authenticated using (
    user_id = (select auth.uid())
    or array[stand_id] <@ (select public.dispatch_caller_admin_stand_ids())
    or (select public.caller_is_admin()));
drop policy if exists "dispatch_stand_people admin insert" on public.dispatch_stand_people;
create policy "dispatch_stand_people admin insert" on public.dispatch_stand_people
  for insert to authenticated with check ((select public.caller_admin_can_write('dispatch_stand_people')));
drop policy if exists "dispatch_stand_people update" on public.dispatch_stand_people;
create policy "dispatch_stand_people update" on public.dispatch_stand_people
  for update to authenticated using (
    (role = 'staff' and array[stand_id] <@ (select public.dispatch_caller_admin_stand_ids()))
    or (select public.caller_admin_can_write('dispatch_stand_people')))
  with check (
    (role = 'staff' and array[stand_id] <@ (select public.dispatch_caller_admin_stand_ids()))
    or (select public.caller_admin_can_write('dispatch_stand_people')));
drop policy if exists "dispatch_stand_people delete" on public.dispatch_stand_people;
create policy "dispatch_stand_people delete" on public.dispatch_stand_people
  for delete to authenticated using (
    (role = 'staff' and array[stand_id] <@ (select public.dispatch_caller_admin_stand_ids()))
    or (select public.caller_admin_can_write('dispatch_stand_people')));

drop policy if exists "dispatch_fleet_owners read" on public.dispatch_fleet_owners;
create policy "dispatch_fleet_owners read" on public.dispatch_fleet_owners
  for select to authenticated using (user_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "dispatch_fleet_owners admin insert" on public.dispatch_fleet_owners;
create policy "dispatch_fleet_owners admin insert" on public.dispatch_fleet_owners
  for insert to authenticated with check ((select public.caller_admin_can_write('dispatch_fleet_owners')));
drop policy if exists "dispatch_fleet_owners admin update" on public.dispatch_fleet_owners;
create policy "dispatch_fleet_owners admin update" on public.dispatch_fleet_owners
  for update to authenticated using ((select public.caller_admin_can_write('dispatch_fleet_owners')))
  with check ((select public.caller_admin_can_write('dispatch_fleet_owners')));
drop policy if exists "dispatch_fleet_owners admin delete" on public.dispatch_fleet_owners;
create policy "dispatch_fleet_owners admin delete" on public.dispatch_fleet_owners
  for delete to authenticated using ((select public.caller_admin_can_write('dispatch_fleet_owners')));

-- A stand admin's change to their staff: access and on/off only.
create or replace function public.dispatch_people_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('dispatch_stand_people') then
    return new;
  end if;
  if (new.stand_id, new.user_id, new.role, new.created_by, new.created_at)
     is distinct from (old.stand_id, old.user_id, old.role, old.created_by, old.created_at)
     or new.role <> 'staff' then
    raise exception 'DISPATCH_STAFF_ONLY' using errcode = '42501',
      hint = 'A stand admin changes their staff''s access and on/off only.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_dispatch_stand_people_guard on public.dispatch_stand_people;
create trigger trg_dispatch_stand_people_guard
  before update on public.dispatch_stand_people
  for each row execute function public.dispatch_people_guard();

drop policy if exists "dispatch_order_events read" on public.dispatch_order_events;
create policy "dispatch_order_events read" on public.dispatch_order_events
  for select to authenticated using (
    array[stand_id] <@ (select public.dispatch_caller_stand_ids()) or (select public.caller_is_admin()));

-- ride_requests: an open stand order reaches only the drivers it is offered
-- to; its stand's operators read it.
drop policy if exists "ride_requests read" on public.ride_requests;
create policy "ride_requests read" on public.ride_requests
  for select using (
    (status = 'open'
      and (select public.caller_is_approved_partner())
      and (targeted_until is null or targeted_until <= now()
           or coalesce(cardinality(target_driver_ids), 0) = 0
           or (select auth.uid()) = any (target_driver_ids))
      and (stand_id is null
           or public.dispatch_offer_ok((select auth.uid()), dispatch_mode, dispatch_driver_id, dispatch_group_id,
                                       dispatch_offer_until, dispatch_open_after, dispatch_widened_at,
                                       dispatch_returned_at)))
    or rider_id = (select auth.uid())
    or partner_id = (select auth.uid())
    or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
    or (select public.caller_is_admin()));

-- Writes by drivers and operators keep to the server's columns.
create or replace function public.dispatch_member_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('dispatch_group_members')
     or (new.group_id = any (public.dispatch_caller_fleet_ids())
         and (tg_op = 'INSERT' or old.group_id = new.group_id)) then
    if tg_op = 'INSERT' and new.status <> 'pending' then
      new.decided_at := now();
      new.decided_by := auth.uid();
    elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
      new.decided_at := now();
      new.decided_by := auth.uid();
    end if;
    return new;
  end if;
  -- A driver's own request: pending, undecided, for a group that takes requests.
  new.status := 'pending';
  new.requested_at := now();
  new.decided_at := null;
  new.decided_by := null;
  if not exists (select 1 from public.dispatch_groups g
                  where g.id = new.group_id and g.active and g.allow_join) then
    raise exception 'DISPATCH_GROUP_CLOSED' using errcode = '42501',
      hint = 'This group doesn''t take requests to join.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_dispatch_group_members_guard on public.dispatch_group_members;
create trigger trg_dispatch_group_members_guard
  before insert or update on public.dispatch_group_members
  for each row execute function public.dispatch_member_guard();

create or replace function public.dispatch_touch_updated()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_dispatch_groups_updated on public.dispatch_groups;
create trigger trg_dispatch_groups_updated before update on public.dispatch_groups
  for each row execute function public.dispatch_touch_updated();
drop trigger if exists trg_dispatch_stands_updated on public.dispatch_stands;
create trigger trg_dispatch_stands_updated before update on public.dispatch_stands
  for each row execute function public.dispatch_touch_updated();

-- The stand's codes are upper case.
create or replace function public.dispatch_stands_normalise()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.code := upper(btrim(new.code));
  new.name := btrim(new.name);
  return new;
end;
$$;
drop trigger if exists trg_dispatch_stands_normalise on public.dispatch_stands;
create trigger trg_dispatch_stands_normalise before insert or update on public.dispatch_stands
  for each row execute function public.dispatch_stands_normalise();

-- ---- The claim guard on ride_requests ---------------------------------------------------------
-- Not security definer: the server's own writes (the RPCs below, cron) run
-- as the function owner and pass; a client's go through.
create or replace function public.ride_requests_guard_dispatch()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if num_nonnulls(new.stand_id, new.ticket_no, new.dispatch_mode, new.dispatch_group_id, new.dispatch_driver_id,
                    new.dispatch_offered_at, new.dispatch_offer_until, new.dispatch_open_after,
                    new.dispatch_widened_at, new.dispatch_returned_at, new.fare_mode, new.dispatch_payment,
                    new.stand_settlement, new.stand_fee_type, new.stand_fee_amount, new.stand_fee_earner_id,
                    new.dispatch_settled_at, new.dispatch_created_by, new.dispatch_booked_via) > 0 then
      raise exception 'DISPATCH_SERVER_ONLY' using errcode = '42501',
        hint = 'Stand orders are made at the stand.';
    end if;
    return new;
  end if;

  if (new.stand_id, new.ticket_no, new.dispatch_stand_name, new.dispatch_created_by, new.dispatch_mode,
      new.dispatch_group_id, new.dispatch_group_name, new.dispatch_group_kind, new.dispatch_driver_id,
      new.dispatch_offered_at, new.dispatch_offer_until, new.dispatch_open_after, new.dispatch_widened_at,
      new.dispatch_widen_pushed_at, new.dispatch_returned_at, new.fare_mode, new.dispatch_payment,
      new.stand_settlement, new.stand_fee_type, new.stand_fee_value, new.stand_fee_bearer,
      new.stand_fee_earner_id, new.stand_fee_amount, new.dispatch_settled_at,
      new.stand_platform_fee_type, new.stand_platform_fee_value, new.stand_platform_fee, new.dispatch_booked_via)
     is distinct from
     (old.stand_id, old.ticket_no, old.dispatch_stand_name, old.dispatch_created_by, old.dispatch_mode,
      old.dispatch_group_id, old.dispatch_group_name, old.dispatch_group_kind, old.dispatch_driver_id,
      old.dispatch_offered_at, old.dispatch_offer_until, old.dispatch_open_after, old.dispatch_widened_at,
      old.dispatch_widen_pushed_at, old.dispatch_returned_at, old.fare_mode, old.dispatch_payment,
      old.stand_settlement, old.stand_fee_type, old.stand_fee_value, old.stand_fee_bearer,
      old.stand_fee_earner_id, old.stand_fee_amount, old.dispatch_settled_at,
      old.stand_platform_fee_type, old.stand_platform_fee_value, old.stand_platform_fee, old.dispatch_booked_via) then
    raise exception 'DISPATCH_SERVER_ONLY' using errcode = '42501',
      hint = 'A stand order is changed at the stand.';
  end if;

  if old.stand_id is null then
    return new;
  end if;

  -- Taking it: only a driver it is offered to, and free.
  if old.status = 'open' and new.partner_id is not null and new.partner_id is distinct from old.partner_id then
    if not public.dispatch_offer_ok(auth.uid(), old.dispatch_mode, old.dispatch_driver_id, old.dispatch_group_id,
                                    old.dispatch_offer_until, old.dispatch_open_after, old.dispatch_widened_at,
                                    old.dispatch_returned_at) then
      raise exception 'DISPATCH_NOT_OFFERED' using errcode = '42501',
        hint = 'This stand order was sent to other drivers.';
    end if;
    if public.dispatch_caller_busy(old.id) then
      raise exception 'DISPATCH_DRIVER_BUSY' using errcode = '42501',
        hint = 'Finish your trip before taking a stand order.';
    end if;
    -- No bids on a stand order: it is taken at the stand's fare.
    if new.status is distinct from 'accepted' then
      raise exception 'DISPATCH_NO_OFFERS' using errcode = '42501',
        hint = 'A stand order is accepted at its fare.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_ride_requests_a_guard_dispatch on public.ride_requests;
create trigger trg_ride_requests_a_guard_dispatch
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_dispatch();

-- ---- Pushes ----------------------------------------------------------------------------------
create or replace function public.dispatch_push_message(r public.ride_requests, p_assigned boolean)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'title', case when p_assigned then 'Stand order assigned to you'
                  else 'Stand order · ' || coalesce(r.dispatch_group_name, 'nearby') end,
    'body', coalesce(r.dispatch_stand_name, r.pickup_name, 'A stand') || ' to '
            || coalesce(nullif(r.drop_name, ''), 'a destination') || ' · Ticket ' || r.ticket_no,
    'data', jsonb_build_object('type', 'ride_request', 'ride_request_id', r.id, 'stand_order', true,
                               'assigned', p_assigned));
$$;
revoke execute on function public.dispatch_push_message(public.ride_requests, boolean) from public, anon, authenticated;

-- Tells the drivers an order is offered to now: the named driver, or the
-- group's members who are online and free, or (widened) the drivers near
-- the stand. Never holds up the order. Returns how many were told.
create or replace function public.dispatch_push(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_msg jsonb;
  v_driver uuid;
  n int := 0;
begin
  select * into r from public.ride_requests where id = p_request;
  if not found or r.stand_id is null or r.status <> 'open' or r.dispatch_mode = 'nearby' then
    return 0;  -- a normal booking's pushes (notify_partners_on_ride_request) reach it
  end if;
  begin
    if r.dispatch_mode = 'assign' then
      if r.dispatch_returned_at is null and r.dispatch_offer_until > now() then
        perform public.send_push_webhook(public.dispatch_push_message(r, true)
                                         || jsonb_build_object('profileId', r.dispatch_driver_id));
        n := 1;
      end if;
      return n;
    end if;
    v_msg := public.dispatch_push_message(r, false);
    if r.dispatch_widened_at is not null or (r.dispatch_open_after is not null and r.dispatch_open_after <= now()) then
      return public.ride_request_push_nearby(r.id, null, r.pickup_lat, r.pickup_lng,
        (public.vehicle_service_dispatch_config(r.service)->>'search_radius_max_km')::double precision,
        v_msg, 'nearby', true);
    end if;
    for v_driver in
      select d.profile_id from public.driver_presence d
       where d.online and d.updated_at > now() - interval '3 minutes'
         and public.dispatch_member_of(r.dispatch_group_id, d.profile_id)
         and not public.dispatch_driver_busy(d.profile_id)
         and public.service_order_driver_allows(d.profile_id, r.service)
    loop
      insert into public.ride_request_pushes (request_id, profile_id, kind)
      values (r.id, v_driver, 'nearby')
      on conflict (request_id, profile_id) where profile_id is not null do nothing;
      perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      n := n + 1;
    end loop;
  exception when others then
    raise warning 'stand order % not pushed: %', p_request, sqlerrm;
  end;
  return n;
end;
$$;
revoke execute on function public.dispatch_push(uuid) from public, anon, authenticated;

-- A customer's SMS through the SMS gateway (sms_outbox): quiet on failure.
create or replace function public.dispatch_sms(p_phone text, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to text := public.sms_e164(p_phone);
begin
  if v_to is null or char_length(v_to) < 8 then
    return;
  end if;
  insert into public.sms_outbox (channel, to_phone, body, created_by)
  values ('support_message', v_to, left(p_body, 300), null);
exception when others then
  raise warning 'stand SMS not queued: %', sqlerrm;
end;
$$;
revoke execute on function public.dispatch_sms(text, text) from public, anon, authenticated;

-- ---- The order, as the console and the ticket read it ------------------------------------------
create or replace function public.dispatch_order_json(p_request uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id, 'stand_id', r.stand_id, 'stand_name', r.dispatch_stand_name, 'ticket_no', r.ticket_no,
    'status', r.status, 'mode', r.dispatch_mode, 'group_id', r.dispatch_group_id,
    'group_name', r.dispatch_group_name, 'group_kind', r.dispatch_group_kind,
    'driver_id', r.dispatch_driver_id,
    'driver_target_name', case when r.dispatch_driver_id is not null then public.dispatch_actor_name(r.dispatch_driver_id) end,
    'offered_at', r.dispatch_offered_at, 'offer_until', r.dispatch_offer_until,
    'open_after', r.dispatch_open_after, 'widened_at', r.dispatch_widened_at,
    'returned_at', r.dispatch_returned_at, 'created_at', r.created_at,
    'pickup_name', r.pickup_name, 'pickup_address', r.pickup_address,
    'pickup_lat', r.pickup_lat, 'pickup_lng', r.pickup_lng,
    'booked_via', r.dispatch_booked_via, 'rider_account', r.rider_id is not null,
    'drop_name', r.drop_name, 'drop_address', r.drop_address, 'drop_lat', r.drop_lat, 'drop_lng', r.drop_lng,
    'service', r.service, 'passengers', r.passengers, 'note', r.note)
  || jsonb_build_object(
    'fare_mode', r.fare_mode, 'fare', coalesce(r.ride_fare, r.fare), 'currency', r.currency,
    'payment', r.dispatch_payment, 'payment_mode', r.payment_mode, 'payment_status', r.payment_status,
    'settlement', r.stand_settlement,
    'fee_type', r.stand_fee_type, 'fee_value', r.stand_fee_value, 'fee_bearer', r.stand_fee_bearer,
    'fee_amount', r.stand_fee_amount, 'settled_at', r.dispatch_settled_at,
    'platform_fee', r.stand_platform_fee,
    'customer_name', coalesce(pv.rider_name, r.rider_name),
    'customer_phone', coalesce(r.rider_phone, pv.rider_phone),
    'partner_id', r.partner_id, 'partner_name', r.partner_name, 'partner_phone', r.partner_phone,
    'partner_plate', r.partner_plate, 'partner_vehicle', r.partner_vehicle,
    'accepted_at', r.accepted_at, 'arrived_at', r.arrived_at, 'started_at', r.started_at,
    'completed_at', r.completed_at, 'cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason,
    'trip_code', (select c.code from public.ride_trip_codes c where c.request_id = r.id),
    'share_token', coalesce(r.share_token, pv.share_token),
    'created_by', r.dispatch_created_by, 'created_by_name', public.dispatch_actor_name(r.dispatch_created_by),
    'events', coalesce((select jsonb_agg(jsonb_build_object('action', e.action, 'detail', e.detail,
                                                            'actor', e.actor_name, 'at', e.at) order by e.at)
                          from public.dispatch_order_events e
                         where e.request_id = r.id
                            or (r.scheduled_ride_id is not null and e.scheduled_ride_id = r.scheduled_ride_id)),
                       '[]'::jsonb),
    'scheduled_ride_id', r.scheduled_ride_id,
    'pickup_at', (select b.pickup_at from public.scheduled_rides b where b.id = r.scheduled_ride_id))
  from public.ride_requests r
  left join public.ride_request_private pv on pv.request_id = r.id
  where r.id = p_request;
$$;
revoke execute on function public.dispatch_order_json(uuid) from public, anon, authenticated;

-- ---- The caller's stands ----------------------------------------------------------------------
create or replace function public.dispatch_my_stands()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admin boolean := public.caller_admin_can_write('rpc:dispatch_console');
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'kind', s.kind, 'code', s.code, 'address', s.address, 'admin_only', s.admin_only,
      'lat', s.lat, 'lng', s.lng, 'allow_fixed_fare', s.allow_fixed_fare, 'settlement', s.settlement,
      'fee_type', s.fee_type, 'fee_value', s.fee_value, 'fee_bearer', s.fee_bearer, 'fee_set_by', s.fee_set_by,
      'platform_fee_type', s.platform_fee_type, 'platform_fee_value', s.platform_fee_value,
      'admin', v_admin,
      'role', case when v_admin then 'admin' else o.role end,
      'perms', jsonb_build_object(
        'assign', v_admin or o.role = 'admin' or coalesce(o.can_assign, false),
        'broadcast', v_admin or o.role = 'admin' or coalesce(o.can_broadcast, false),
        'fixed_fare', v_admin or o.role = 'admin' or coalesce(o.can_fixed_fare, false),
        'cancel', v_admin or o.role = 'admin' or coalesce(o.can_cancel, false),
        'reassign', v_admin or o.role = 'admin' or coalesce(o.can_reassign, false),
        'reports', v_admin or o.role = 'admin' or coalesce(o.can_reports, false),
        'staff', o.role = 'admin'),
      'groups', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', g.id, 'name', g.name, 'kind', g.kind, 'members_first_sec', g.members_first_sec,
          'members', (select count(*) from public.dispatch_group_members m
                       where m.group_id = g.id and m.status = 'approved')) order by g.name)
          from public.dispatch_groups g
         where g.active
           and (exists (select 1 from public.dispatch_stand_groups sg where sg.stand_id = s.id and sg.group_id = g.id)
                or v_admin)), '[]'::jsonb)
    ) order by s.name)
      from public.dispatch_stands s
      left join public.dispatch_stand_people o on o.stand_id = s.id and o.user_id = auth.uid() and o.active
     where s.active and (v_admin or (o.user_id is not null and not s.admin_only))), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_my_stands() from public, anon;
grant execute on function public.dispatch_my_stands() to authenticated;

-- ---- Drivers near a stand, nearest first ------------------------------------------------------
create or replace function public.dispatch_drivers(p_stand uuid, p_radius_km double precision default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.dispatch_stands;
begin
  if not public.dispatch_caller_can(p_stand, 'use') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into s from public.dispatch_stands where id = p_stand;
  return coalesce((
    select jsonb_agg(x.j order by x.km)
      from (
        select d.km, jsonb_build_object(
          'id', d.profile_id, 'name', coalesce(nullif(btrim(pa.name), ''), public.dispatch_actor_name(d.profile_id)),
          'plate', public.dispatch_driver_car(d.profile_id)->>'plate',
          'vehicle', public.dispatch_driver_car(d.profile_id)->>'vehicle',
          'service', coalesce((select se.values->>'name' from public.settings_entries se
                                where se.id::text = public.driver_vehicle_service(d.profile_id)), pa.vehicle_type),
          'km', round(d.km::numeric, 2),
          'state', case when public.dispatch_driver_busy(d.profile_id) then 'on_trip'
                        when d.km <= 0.3 then 'at_stand' else 'free' end,
          'groups', coalesce((select jsonb_agg(g.name order by g.name)
                                from public.dispatch_stand_groups sg
                                join public.dispatch_groups g on g.id = sg.group_id
                               where sg.stand_id = p_stand and public.dispatch_member_of(g.id, d.profile_id)),
                             '[]'::jsonb)) as j
          from (select dp.profile_id, public.dispatch_km(s.lat, s.lng, dp.lat, dp.lng) as km
                  from public.driver_presence dp
                 where dp.online and dp.updated_at > now() - interval '3 minutes'
                   and dp.lat is not null and dp.lng is not null) d
          join lateral (select p.* from public.partners p
                         where p.auth_user_id = d.profile_id
                           and (p.status = 'approved' or p.status::text like 'permit-%')
                         order by p.updated_at desc limit 1) pa on true
         where d.km <= coalesce(p_radius_km, 30)
         order by d.km
         limit 60) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_drivers(uuid, double precision) from public, anon;
grant execute on function public.dispatch_drivers(uuid, double precision) to authenticated;

-- ---- A new order ----------------------------------------------------------------------------
-- p_order: drop_name, drop_address, drop_lat, drop_lng, distance_km,
-- duration_min, service, passengers, customer_name, customer_phone, note,
-- fare_mode (meter | estimate | fixed), fare, payment (counter | cash | app),
-- mode (assign | broadcast), group_id, driver_id.
-- "Mon 21 Oct, 14:30" in the stand's time zone (Malaysia's).
create or replace function public.dispatch_when(p_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$ select to_char(p_at at time zone 'Asia/Kuala_Lumpur', 'Dy DD Mon, HH24:MI') $$;

create or replace function public.dispatch_create_order(p_stand uuid, p_order jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s public.dispatch_stands;
  g public.dispatch_groups;
  v_admin boolean := public.caller_admin_can_write('rpc:dispatch_console');
  v_call boolean;
  v_mode text := coalesce(nullif(p_order->>'mode', ''), 'broadcast');
  v_fare_mode text := coalesce(nullif(p_order->>'fare_mode', ''), 'meter');
  v_pay text;
  v_drop text := nullif(btrim(coalesce(p_order->>'drop_name', '')), '');
  v_name text := nullif(btrim(coalesce(p_order->>'customer_name', '')), '');
  v_phone text := nullif(btrim(coalesce(p_order->>'customer_phone', '')), '');
  v_note text := nullif(btrim(coalesce(p_order->>'note', '')), '');
  v_via text := nullif(p_order->>'booked_via', '');
  v_pickup_at timestamptz := nullif(p_order->>'pickup_at', '')::timestamptz;
  v_lead integer := coalesce(nullif(p_order->>'lead_minutes', '')::integer, 30);
  v_rider uuid;
  v_driver uuid;
  v_fare numeric;
  v_n integer;
  v_ticket text;
  v_id uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_fee numeric;
  v_earner uuid;
  v_detail text;
  v_pax integer := coalesce(nullif(p_order->>'passengers', '')::integer, 1);
  v_plat double precision;
  v_plng double precision;
  v_pname text;
  v_paddr text;
  v_row jsonb;
  v_cols text;
  v_offer uuid;
  b public.scheduled_rides;
  j jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into s from public.dispatch_stands where id = p_stand and active;
  if not found or not public.dispatch_caller_can(p_stand, 'use') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- The Call centre (admins only): a customer who phoned or texted.
  v_call := s.admin_only;
  if v_call and not v_admin then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_pay := coalesce(nullif(p_order->>'payment', ''), case when v_call then 'cash' else 'counter' end);

  if v_drop is null or char_length(v_drop) > 200 then
    raise exception 'DISPATCH_DESTINATION' using errcode = '22023', hint = 'Say where the customer is going.';
  end if;
  if v_pax < 1 or v_pax > 20 then
    raise exception 'DISPATCH_PASSENGERS' using errcode = '22023', hint = 'Passengers are 1 to 20.';
  end if;
  if v_name is not null and char_length(v_name) > 80 then
    raise exception 'DISPATCH_CUSTOMER' using errcode = '22023', hint = 'The name is too long.';
  end if;
  if v_phone is not null and char_length(regexp_replace(v_phone, '\D', '', 'g')) not between 6 and 20 then
    raise exception 'DISPATCH_PHONE' using errcode = '22023', hint = 'The phone number doesn''t look right.';
  end if;
  if v_pay not in ('counter', 'cash', 'app') then
    raise exception 'DISPATCH_PAYMENT' using errcode = '22023';
  end if;

  -- Where the customer is picked up: the stand, or (Call centre) their address.
  if v_call then
    if v_name is null or v_phone is null then
      raise exception 'DISPATCH_CUSTOMER' using errcode = '22023', hint = 'A phone booking needs the customer''s name and phone.';
    end if;
    if v_via is null or v_via not in ('phone', 'sms', 'whatsapp') then
      raise exception 'DISPATCH_VIA' using errcode = '22023', hint = 'Say how the customer booked.';
    end if;
    v_plat := nullif(p_order->>'pickup_lat', '')::double precision;
    v_plng := nullif(p_order->>'pickup_lng', '')::double precision;
    v_pname := nullif(btrim(coalesce(p_order->>'pickup_name', '')), '');
    v_paddr := nullif(btrim(coalesce(p_order->>'pickup_address', '')), '');
    if v_plat is null or v_plng is null or v_pname is null then
      raise exception 'DISPATCH_PICKUP' using errcode = '22023', hint = 'Find the pickup address.';
    end if;
    -- A customer with a GET.ride account: booked on their account (their app
    -- tracks it); else a guest.
    v_rider := public.dispatch_profile_by_phone(v_phone);
    if v_rider is not null and v_pickup_at is null and exists (
         select 1 from public.ride_requests x
          where x.rider_id = v_rider
            and ((x.status = 'open' and x.created_at > now() - interval '7 minutes')
                 or (x.status in ('accepted', 'arrived', 'on_trip') and x.updated_at > now() - interval '12 hours'))) then
      raise exception 'RIDE_REQUEST_DUPLICATE' using errcode = 'P0001',
        hint = 'This customer already has a ride on the go.';
    end if;
  else
    v_via := null;
    v_plat := s.lat;
    v_plng := s.lng;
    v_pname := s.name;
    v_paddr := s.address;
  end if;

  -- When: now, or booked ahead (released [lead] minutes before pickup).
  if v_pickup_at is not null then
    if v_lead not in (15, 30, 60) then
      raise exception 'DISPATCH_LEAD' using errcode = '22023', hint = 'Send it 15, 30 or 60 minutes before.';
    end if;
    if v_pickup_at < now() + make_interval(mins => v_lead + 5) or v_pickup_at > now() + interval '30 days' then
      raise exception 'DISPATCH_TIME' using errcode = '22023',
        hint = format('Pick a time at least %s minutes from now, within 30 days.', v_lead + 5);
    end if;
    if v_rider is not null and (select count(*) from public.scheduled_rides
                                 where rider_id = v_rider and status in ('scheduled', 'assigned', 'released')) >= 5 then
      raise exception 'SCHEDULED_LIMIT' using hint = 'This customer already has 5 upcoming rides.';
    end if;
  end if;

  -- The fare.
  if v_fare_mode not in ('meter', 'estimate', 'fixed') then
    raise exception 'DISPATCH_FARE' using errcode = '22023';
  end if;
  if v_fare_mode = 'fixed' and not (v_admin or (s.allow_fixed_fare and public.dispatch_caller_can(p_stand, 'fixed_fare'))) then
    raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501', hint = 'You can''t set a fixed fare here.';
  end if;
  if v_fare_mode in ('fixed', 'estimate') then
    v_fare := round(nullif(p_order->>'fare', '')::numeric, 2);
    if v_fare is null or v_fare <= 0 or not public.ride_money_ok(v_fare) then
      raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Enter the fare.';
    end if;
  end if;

  -- Who it goes to.
  if v_mode = 'assign' then
    if not public.dispatch_caller_can(p_stand, 'assign') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501', hint = 'You can''t assign drivers here.';
    end if;
    v_driver := nullif(p_order->>'driver_id', '')::uuid;
    if v_driver is null or v_driver = v_rider or not exists (
         select 1 from public.partners p where p.auth_user_id = v_driver
            and (p.status = 'approved' or p.status::text like 'permit-%')) then
      raise exception 'DISPATCH_DRIVER' using errcode = '22023', hint = 'Pick a driver.';
    end if;
    -- The service order (0250): only a vehicle of this service or a higher one.
    if not public.service_order_driver_allows(v_driver, nullif(btrim(coalesce(p_order->>'service', '')), '')) then
      raise exception 'SERVICE_ORDER_DIRECT' using errcode = '42501',
        hint = 'This driver''s vehicle can''t take this service. Pick another driver or service.';
    end if;
    v_detail := 'Assigned to ' || public.dispatch_actor_name(v_driver);
  elsif v_mode = 'broadcast' then
    if not public.dispatch_caller_can(p_stand, 'broadcast') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501', hint = 'You can''t broadcast here.';
    end if;
    select * into g from public.dispatch_groups
     where id = nullif(p_order->>'group_id', '')::uuid and active;
    if not found or not (v_admin or exists (select 1 from public.dispatch_stand_groups sg
                                             where sg.stand_id = p_stand and sg.group_id = g.id)) then
      raise exception 'DISPATCH_GROUP' using errcode = '22023', hint = 'Pick a group this stand sends to.';
    end if;
    v_detail := 'Broadcast to ' || g.name;
  elsif v_mode = 'nearby' and v_call then
    v_detail := 'Nearby drivers, as a normal booking';
  else
    raise exception 'DISPATCH_MODE' using errcode = '22023';
  end if;

  -- The ticket: the stand's next number, under its row lock.
  update public.dispatch_stands set next_ticket = next_ticket + 1 where id = p_stand
  returning next_ticket - 1 into v_n;
  v_ticket := public.dispatch_ticket_text(s.code, v_n);

  v_fee := case when s.fee_type = 'none' then null
                else public.dispatch_fee_amount(s.fee_type, s.fee_value, coalesce(v_fare, 0)) end;
  v_earner := public.dispatch_stand_account(s.id);

  -- The ride as it goes out (now, or when the booking is released).
  v_row := jsonb_build_object(
    'rider_id', v_rider, 'rider_name', coalesce(v_name, 'Customer'), 'rider_phone', v_phone,
    'service', nullif(btrim(coalesce(p_order->>'service', '')), ''),
    'payment_mode', case v_pay when 'counter' then 'Paid at counter' when 'app' then 'Card / e-wallet' else 'Cash' end,
    'pickup_name', v_pname, 'pickup_address', v_paddr, 'pickup_lat', v_plat, 'pickup_lng', v_plng,
    'drop_name', v_drop, 'drop_address', nullif(btrim(coalesce(p_order->>'drop_address', '')), ''),
    'drop_lat', nullif(p_order->>'drop_lat', '')::double precision,
    'drop_lng', nullif(p_order->>'drop_lng', '')::double precision,
    'distance_km', nullif(p_order->>'distance_km', '')::numeric,
    'duration_min', nullif(p_order->>'duration_min', '')::numeric::integer,
    'fare', v_fare, 'ride_fare', v_fare, 'passengers', v_pax, 'note', left(v_note, 300), 'share_token', v_token)
  || jsonb_build_object(
    'stand_id', s.id, 'ticket_no', v_ticket, 'dispatch_stand_name', s.name, 'dispatch_created_by', v_uid,
    'dispatch_mode', v_mode, 'dispatch_group_id', g.id, 'dispatch_group_name', g.name, 'dispatch_group_kind', g.kind,
    'dispatch_driver_id', v_driver, 'fare_mode', v_fare_mode, 'dispatch_payment', v_pay,
    'stand_settlement', s.settlement, 'stand_fee_type', s.fee_type, 'stand_fee_value', s.fee_value,
    'stand_fee_bearer', s.fee_bearer, 'stand_fee_earner_id', v_earner, 'stand_fee_amount', v_fee,
    'stand_platform_fee_type', s.platform_fee_type, 'stand_platform_fee_value', s.platform_fee_value,
    'dispatch_booked_via', v_via);
  -- Booked ahead: the trip code is fixed now, for the ticket.
  if v_pickup_at is not null then
    v_row := v_row || jsonb_build_object('otp', public.new_trip_code());
  end if;

  perform set_config('dispatch.rpc', '1', true);

  if v_pickup_at is not null then
    insert into public.scheduled_rides (
      rider_id, pickup_at, request, service, pickup_address, drop_address,
      pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km, fare, scheduling_fee, currency, stand_id, lead_minutes)
    values (
      v_rider, v_pickup_at, jsonb_strip_nulls(v_row), v_row->>'service', coalesce(v_paddr, v_pname),
      coalesce(v_row->>'drop_address', v_drop), v_plat, v_plng,
      (v_row->>'drop_lat')::double precision, (v_row->>'drop_lng')::double precision,
      (v_row->>'distance_km')::numeric, coalesce(v_fare, 0), 0, 'MYR', s.id, v_lead)
    returning * into b;
    perform public.dispatch_log_scheduled(b.id, s.id, 'created',
      v_ticket || ' · for ' || public.dispatch_when(v_pickup_at) || ' · ' || v_detail
      || coalesce(' · booked by ' || v_via, ''));
    -- An assigned driver is asked now, as a passenger's choice of driver is (0198).
    if v_driver is not null then
      insert into public.scheduled_ride_offers (scheduled_ride_id, kind, rider_id, from_id, to_partner_id, expires_at)
      values (b.id, 'assign', v_rider, v_uid, v_driver, public.scheduled_offer_deadline(v_pickup_at))
      returning id into v_offer;
      perform public.enqueue_notification(v_driver, 'sched-offer-' || v_offer, 'scheduled_ride', 'normal',
        'Stand booking for you',
        coalesce(s.name, 'A stand') || ' asks you to take a ride on ' || public.scheduled_when(v_pickup_at)
        || ' from ' || coalesce(v_pname, 'the stand') || '. Accept or decline it.',
        jsonb_build_object('type', 'scheduled_offer', 'scheduled_ride_id', b.id, 'offer_id', v_offer, 'role', 'partner'));
    end if;
    j := public.dispatch_scheduled_json(b.id);
  else
    v_row := v_row || jsonb_build_object(
      'id', v_id, 'status', 'open', 'dispatch_offered_at', now(),
      'dispatch_offer_until', case when v_mode = 'assign' then now() + interval '30 seconds' end,
      'dispatch_open_after', case when v_mode = 'broadcast' and g.kind = 'open'
                                  then now() + make_interval(secs => g.members_first_sec) end);
    select string_agg(quote_ident(a.attname), ', ') into v_cols
      from pg_attribute a
     where a.attrelid = 'public.ride_requests'::regclass and a.attnum > 0 and not a.attisdropped
       and v_row ? a.attname;
    execute format('insert into public.ride_requests (%1$s) select %1$s from jsonb_populate_record(null::public.ride_requests, $1)',
                   v_cols) using v_row;
    perform public.dispatch_log(v_id, s.id, 'created', v_ticket || ' · ' || v_detail || coalesce(' · booked by ' || v_via, ''));
    perform public.dispatch_push(v_id);
    j := public.dispatch_order_json(v_id);
  end if;

  -- A guest (no GET.ride account) is texted the ticket; an account holder
  -- has it in their app.
  if v_phone is not null and v_rider is null then
    perform public.dispatch_sms(v_phone,
      'GET.ride ' || s.name || ': ticket ' || v_ticket || ' to ' || v_drop
      || coalesce(', pickup ' || public.dispatch_when(v_pickup_at), '')
      || coalesce('. Trip code ' || (j->>'trip_code'), '')
      || '. Track: https://getride.my/share/' || v_token);
  end if;
  return j;
end;
$$;
revoke execute on function public.dispatch_create_order(uuid, jsonb) from public, anon;
grant execute on function public.dispatch_create_order(uuid, jsonb) to authenticated;

-- ---- Bookings ahead on the board ------------------------------------------------------------------
create or replace function public.dispatch_scheduled_json(p_booking uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select b.request
    - array['rider_id', 'stand_fee_earner_id', 'dispatch_created_by', 'otp', 'share_token', 'rider_name', 'rider_phone']
    || jsonb_build_object(
      'id', b.id, 'kind', 'scheduled', 'scheduled_ride_id', b.id, 'status', 'scheduled',
      'booking_status', b.status, 'pickup_at', b.pickup_at, 'lead_minutes', coalesce(b.lead_minutes,
        (public.scheduled_rides_config()->>'releaseMinutes')::int),
      'stand_id', b.stand_id, 'stand_name', b.request->>'dispatch_stand_name', 'ticket_no', b.request->>'ticket_no',
      'mode', b.request->>'dispatch_mode', 'group_name', b.request->>'dispatch_group_name',
      'group_kind', b.request->>'dispatch_group_kind', 'driver_id', b.request->>'dispatch_driver_id',
      'driver_target_name', case when b.request ? 'dispatch_driver_id'
                                 then public.dispatch_actor_name((b.request->>'dispatch_driver_id')::uuid) end,
      'driver_confirmed', b.partner_id is not null,
      'offer_status', (select o.status from public.scheduled_ride_offers o where o.scheduled_ride_id = b.id
                        order by o.created_at desc limit 1),
      'partner_id', b.partner_id,
      'partner_name', case when b.partner_id is not null then public.dispatch_actor_name(b.partner_id) end,
      'partner_plate', case when b.partner_id is not null then public.dispatch_driver_car(b.partner_id)->>'plate' end,
      'partner_vehicle', case when b.partner_id is not null then public.dispatch_driver_car(b.partner_id)->>'vehicle' end,
      'fare_mode', b.request->>'fare_mode', 'fare', b.request->'fare', 'payment', b.request->>'dispatch_payment',
      'payment_mode', b.request->>'payment_mode', 'booked_via', b.request->>'dispatch_booked_via',
      'rider_account', b.rider_id is not null,
      'customer_name', b.request->>'rider_name', 'customer_phone', b.request->>'rider_phone',
      'fee_type', b.request->>'stand_fee_type', 'fee_value', b.request->'stand_fee_value',
      'fee_bearer', b.request->>'stand_fee_bearer', 'fee_amount', b.request->'stand_fee_amount',
      'trip_code', b.request->>'otp', 'share_token', b.request->>'share_token',
      'created_at', b.created_at, 'created_by_name', public.dispatch_actor_name((b.request->>'dispatch_created_by')::uuid),
      'events', coalesce((select jsonb_agg(jsonb_build_object('action', e.action, 'detail', e.detail,
                                                              'actor', e.actor_name, 'at', e.at) order by e.at)
                            from public.dispatch_order_events e where e.scheduled_ride_id = b.id), '[]'::jsonb))
    from public.scheduled_rides b
   where b.id = p_booking and b.stand_id is not null;
$$;
revoke execute on function public.dispatch_scheduled_json(uuid) from public, anon, authenticated;

-- A booking ahead: 'release' (send it now), 'reschedule' (p_args.pickup_at,
-- p_args.lead_minutes), 'cancel' (p_args.reason).
create or replace function public.dispatch_scheduled_action(p_booking uuid, p_action text, p_args jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.scheduled_rides;
  v_at timestamptz;
  v_lead integer;
  v_ride uuid;
  v_claims text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into b from public.scheduled_rides where id = p_booking for update;
  if not found or b.stand_id is null or not public.dispatch_caller_can(b.stand_id, 'use') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status not in ('scheduled', 'assigned') then
    raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'It has already gone out, or is closed.';
  end if;
  perform set_config('dispatch.rpc', '1', true);

  if p_action = 'release' then
    perform public.dispatch_log_scheduled(b.id, b.stand_id, 'released', 'Sent out now');
    -- Released as the release loop does (the server's own context), so the
    -- confirmed driver's card is read as it is there.
    v_claims := current_setting('request.jwt.claims', true);
    perform set_config('request.jwt.claims', '', true);
    begin
      v_ride := public.scheduled_ride_release(b.id);
    exception when others then
      perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
      raise;
    end;
    perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
    return coalesce(public.dispatch_order_json(v_ride), '{}'::jsonb);
  elsif p_action = 'reschedule' then
    v_at := nullif(p_args->>'pickup_at', '')::timestamptz;
    v_lead := coalesce(nullif(p_args->>'lead_minutes', '')::integer, b.lead_minutes, 30);
    if v_lead not in (15, 30, 60) then
      raise exception 'DISPATCH_LEAD' using errcode = '22023', hint = 'Send it 15, 30 or 60 minutes before.';
    end if;
    if v_at is null or v_at < now() + make_interval(mins => v_lead + 5) or v_at > now() + interval '30 days' then
      raise exception 'DISPATCH_TIME' using errcode = '22023',
        hint = format('Pick a time at least %s minutes from now, within 30 days.', v_lead + 5);
    end if;
    update public.scheduled_rides
       set pickup_at = v_at, lead_minutes = v_lead, reminded_at = null, partner_reminded_id = null
     where id = b.id;
    update public.scheduled_ride_offers set expires_at = public.scheduled_offer_deadline(v_at)
     where scheduled_ride_id = b.id and status = 'pending';
    if b.partner_id is not null then
      perform public.enqueue_notification(b.partner_id, 'sched-moved-' || b.id || '-' || extract(epoch from v_at)::bigint,
        'scheduled_ride', 'normal', 'Booking time changed',
        'The stand moved the ride to ' || public.scheduled_when(v_at) || '.',
        jsonb_build_object('type', 'scheduled_assigned', 'scheduled_ride_id', b.id, 'role', 'partner'));
    end if;
    perform public.dispatch_log_scheduled(b.id, b.stand_id, 'rescheduled',
      'Now for ' || public.dispatch_when(v_at) || ', out ' || v_lead || ' min before');
  elsif p_action = 'cancel' then
    if not public.dispatch_caller_can(b.stand_id, 'cancel') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
    end if;
    update public.scheduled_rides
       set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin',
           cancel_reason = left(coalesce(nullif(btrim(coalesce(p_args->>'reason', '')), ''), 'Cancelled by the stand'), 200)
     where id = b.id;
    if b.partner_id is not null then
      perform public.enqueue_notification(b.partner_id, 'sched-cancel-' || b.id, 'scheduled_ride', 'normal',
        'Scheduled ride cancelled',
        'The stand cancelled the ride booked for ' || public.scheduled_when(b.pickup_at) || '.',
        jsonb_build_object('type', 'scheduled_cancelled', 'scheduled_ride_id', b.id, 'role', 'partner'));
    end if;
    perform public.enqueue_notification(b.rider_id, 'sched-cancel-rider-' || b.id, 'scheduled_ride', 'normal',
      'Scheduled ride cancelled', 'Your ride for ' || public.scheduled_when(b.pickup_at) || ' was cancelled.',
      jsonb_build_object('type', 'scheduled_cancelled', 'scheduled_ride_id', b.id));
    perform public.dispatch_log_scheduled(b.id, b.stand_id, 'cancelled', 'Cancelled before it went out');
  else
    raise exception 'DISPATCH_ACTION' using errcode = '22023';
  end if;
  return public.dispatch_scheduled_json(b.id);
end;
$$;
revoke execute on function public.dispatch_scheduled_action(uuid, text, jsonb) from public, anon;
grant execute on function public.dispatch_scheduled_action(uuid, text, jsonb) to authenticated;

-- A released booking's ride: its offer starts now; a driver who confirmed
-- has it straight away (the customer is texted, the log says so); else it
-- goes to whom the stand chose.
create or replace function public.ride_requests_dispatch_release_timing()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_sec integer;
begin
  if new.stand_id is null or new.scheduled_ride_id is null then
    return new;
  end if;
  new.dispatch_offered_at := now();
  new.dispatch_returned_at := null;
  new.dispatch_widened_at := null;
  new.dispatch_widen_pushed_at := null;
  new.dispatch_offer_until := case when new.dispatch_mode = 'assign' and new.status = 'open'
                                   then now() + interval '30 seconds' end;
  if new.dispatch_mode = 'broadcast' and new.dispatch_group_kind = 'open' then
    select g.members_first_sec into v_sec from public.dispatch_groups g where g.id = new.dispatch_group_id;
    new.dispatch_open_after := now() + make_interval(secs => coalesce(v_sec, 0));
  else
    new.dispatch_open_after := null;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_ride_requests_a_dispatch_release on public.ride_requests;
create trigger trg_ride_requests_a_dispatch_release
  before insert on public.ride_requests
  for each row execute function public.ride_requests_dispatch_release_timing();

-- ---- A stand at an airport (0249) ---------------------------------------------------------------
-- A stand order the stand sends itself (assign, broadcast) is not held for
-- the airport's queue and keeps the stand's fare: no airport re-quote, no
-- door required, no hold. Only "Nearby drivers · normal booking" (and the
-- Call centre's nearby bookings) follow the airport's rules, as an app
-- booking does. The two triggers wrap the airport step (c_zairport).
create or replace function public.ride_requests_dispatch_airport_before()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.stand_id is null or coalesce(new.dispatch_mode, '') = 'nearby' then
    return new;
  end if;
  perform set_config('dispatch.airport_row', new.id::text, true);
  perform set_config('dispatch.airport_prev', coalesce(current_setting('getride.airport_server', true), ''), true);
  perform set_config('dispatch.airport_sched', coalesce(new.scheduled_ride_id::text, ''), true);
  perform set_config('dispatch.airport_fare', coalesce(new.airport_fare::text, ''), true);
  perform set_config('getride.airport_server', 'on', true);
  new.scheduled_ride_id := null;
  new.airport_fare := coalesce(new.airport_fare, '{"stand": true}'::jsonb);
  return new;
end;
$$;
revoke execute on function public.ride_requests_dispatch_airport_before() from public, anon, authenticated;

create or replace function public.ride_requests_dispatch_airport_after()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('dispatch.airport_row', true), '') <> new.id::text then
    return new;
  end if;
  new.scheduled_ride_id := nullif(current_setting('dispatch.airport_sched', true), '')::uuid;
  new.airport_fare := nullif(current_setting('dispatch.airport_fare', true), '')::jsonb;
  new.airport_hold := false;
  new.airport_open_at := null;
  if new.status = 'expired' and new.cancel_reason = 'AIRPORT_NO_DRIVER' then
    new.status := 'open';
    new.cancel_reason := null;
  end if;
  perform set_config('getride.airport_server', coalesce(current_setting('dispatch.airport_prev', true), ''), true);
  perform set_config('dispatch.airport_row', '', true);
  return new;
end;
$$;
revoke execute on function public.ride_requests_dispatch_airport_after() from public, anon, authenticated;

-- Just before c_zairport, and just after it.
drop trigger if exists trg_ride_requests_c_yairport_stand on public.ride_requests;
create trigger trg_ride_requests_c_yairport_stand
  before insert on public.ride_requests
  for each row execute function public.ride_requests_dispatch_airport_before();
drop trigger if exists trg_ride_requests_c_zairport_stand on public.ride_requests;
create trigger trg_ride_requests_c_zairport_stand
  before insert on public.ride_requests
  for each row execute function public.ride_requests_dispatch_airport_after();

-- The restrictive read rules of 0249 (airport hold) and 0250 (service
-- order), as they were, plus the order's stand operators, who watch it on
-- the board while it waits.
drop policy if exists "ride_requests airport hold" on public.ride_requests;
create policy "ride_requests airport hold" on public.ride_requests as restrictive for select to authenticated
  using (not airport_hold or status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or public.airport_ride_offered(id, (select auth.uid()))
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids())));

drop policy if exists "ride_requests service order" on public.ride_requests;
create policy "ride_requests service order" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or not (select public.service_order_enforced())
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or public.service_order_allows((select public.caller_vehicle_service()), service)
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids())));

create or replace function public.ride_requests_dispatch_released()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
begin
  if new.stand_id is null or new.scheduled_ride_id is null then
    return null;
  end if;
  begin
    perform public.dispatch_log(new.id, new.stand_id, 'released',
      case when new.status = 'accepted'
           then 'Out to ' || coalesce(new.partner_name, 'the confirmed driver')
           else 'Out to drivers' end, null);
    if new.status = 'open' then
      perform public.dispatch_push(new.id);
    elsif new.status = 'accepted' and new.rider_id is null then
      v_phone := coalesce(new.rider_phone, (select p.rider_phone from public.ride_request_private p
                                            where p.request_id = new.id));
      if v_phone is not null then
        perform public.dispatch_sms(v_phone,
          'GET.ride ticket ' || new.ticket_no || ': your driver is '
          || concat_ws(', ', coalesce(nullif(btrim(coalesce(new.partner_name, '')), ''), 'on the way'),
                       nullif(btrim(coalesce(new.partner_vehicle, '')), ''),
                       nullif(btrim(coalesce(new.partner_plate, '')), ''))
          || ', coming to ' || coalesce(new.pickup_name, 'you')
          || coalesce('. Track: https://getride.my/share/' || coalesce(new.share_token,
               (select p.share_token from public.ride_request_private p where p.request_id = new.id)), ''));
      end if;
    end if;
  exception when others then
    raise warning 'released stand order % follow-up failed: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;
revoke execute on function public.ride_requests_dispatch_released() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_dispatch_released on public.ride_requests;
create trigger trg_ride_requests_dispatch_released
  after insert on public.ride_requests
  for each row execute function public.ride_requests_dispatch_released();

-- A stand's booking: only the stand (dispatch_create_order) names one, its
-- request's dispatch fields stay with it alone, and only the driver the
-- stand asked (or one a driver hands it over to) takes it — not a driver
-- off the open list.
create or replace function public.scheduled_rides_dispatch_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and new.stand_id is not null and coalesce(current_setting('dispatch.rpc', true), '') <> '1' then
    raise exception 'DISPATCH_SERVER_ONLY' using errcode = '42501', hint = 'Stand bookings are made at the stand.';
  end if;
  if tg_op = 'UPDATE' and new.stand_id is distinct from old.stand_id then
    raise exception 'DISPATCH_SERVER_ONLY' using errcode = '42501';
  end if;
  if new.stand_id is null then
    new.request := new.request - array['stand_id', 'ticket_no', 'dispatch_stand_name', 'dispatch_created_by',
      'dispatch_mode', 'dispatch_group_id', 'dispatch_group_name', 'dispatch_group_kind', 'dispatch_driver_id',
      'fare_mode', 'dispatch_payment', 'stand_settlement', 'stand_fee_type', 'stand_fee_value', 'stand_fee_bearer',
      'stand_fee_earner_id', 'stand_fee_amount', 'stand_platform_fee_type', 'stand_platform_fee_value',
      'dispatch_booked_via', 'share_token'];
  end if;
  if tg_op = 'UPDATE' and new.stand_id is not null and new.partner_id is not null
     and new.partner_id is distinct from old.partner_id
     and coalesce(current_setting('dispatch.rpc', true), '') <> '1'
     and not exists (select 1 from public.scheduled_ride_offers o
                      where o.scheduled_ride_id = new.id and o.to_partner_id = new.partner_id and o.status = 'accepted') then
    raise exception 'SCHEDULED_TAKEN' using hint = 'This ride was booked by a stand for another driver.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_scheduled_rides_dispatch_guard on public.scheduled_rides;
create trigger trg_scheduled_rides_dispatch_guard
  before insert or update on public.scheduled_rides
  for each row execute function public.scheduled_rides_dispatch_guard();

-- 0249's request fields, plus an order's dispatch fields, kept
-- only on a stand's booking (scheduled_rides_dispatch_guard strips them from
-- anyone else's).
create or replace function public.scheduled_request_clean(p_request jsonb, p_fee numeric default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce((
    select jsonb_object_agg(e.key,
      case when e.key = 'charges' then (
        select coalesce(jsonb_agg(
          case when p_fee is not null and c->>'name' = 'Scheduling fee' and c->'value' = to_jsonb(p_fee)
                    and c->>'kind' = 'surcharge'
               then c else c - 'platform' end), '[]'::jsonb)
          from jsonb_array_elements(e.value) c
         where jsonb_typeof(c) = 'object')
      else e.value end)
      from jsonb_each(coalesce(p_request, '{}'::jsonb)) e
     where e.key = any (array[
       'rider_name', 'rider_phone', 'rider_photo', 'service', 'payment_mode',
       'pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng',
       'drop_name', 'drop_address', 'drop_lat', 'drop_lng', 'stops',
       'distance_km', 'duration_min', 'fare', 'ride_fare', 'currency',
       'passengers', 'luggage', 'note', 'offer_me', 'otp', 'device_os',
       'user_accept_lat', 'user_accept_lng', 'booked_for_name', 'booked_for_phone',
       'country', 'state', 'city', 'suburb', 'full_address', 'ip_address', 'gender',
       'whole_fare', 'tax_name', 'tax_kind', 'tax_value', 'charges', 'timezone',
       'promo_code_id', 'pets', 'assistance', 'option_charges', 'option_names',
       'pickup_door_id', 'drop_door_id',
       -- 0251: a stand's order (kept only on a stand's booking).
       'stand_id', 'ticket_no', 'dispatch_stand_name', 'dispatch_created_by', 'dispatch_mode',
       'dispatch_group_id', 'dispatch_group_name', 'dispatch_group_kind', 'dispatch_driver_id',
       'fare_mode', 'dispatch_payment', 'stand_settlement', 'stand_fee_type', 'stand_fee_value',
       'stand_fee_bearer', 'stand_fee_earner_id', 'stand_fee_amount', 'stand_platform_fee_type',
       'stand_platform_fee_value', 'dispatch_booked_via', 'share_token'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;

-- Drivers' lists of rides to take ahead (0250's, service order kept): a stand's bookings are the stand's
-- to send (to its driver, group or nearby drivers at release).
create or replace function public.scheduled_rides_open()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
     and public.service_order_driver_allows(auth.uid(), s.service)
   order by s.pickup_at
   limit 100;
$$;

create or replace function public.scheduled_rides_upcoming()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              interested boolean, can_accept boolean, accept_from timestamptz)
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
              then s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int) end
    from public.scheduled_rides s
    cross join c
    left join public.scheduled_ride_interests i on i.scheduled_ride_id = s.id and i.partner_id = auth.uid()
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and (c.v->>'enabled')::boolean
     and public.caller_is_approved_partner()
     and s.rider_id <> auth.uid()
   order by s.pickup_at;
$$;

-- The release loop (0189) with each stand booking's own lead time.
create or replace function public.scheduled_rides_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.scheduled_rides_config();
  s record;
begin
  -- Reminders.
  if (c->>'reminderMinutes')::int > 0 then
    for s in
      select * from public.scheduled_rides
       where status in ('scheduled', 'assigned') and reminded_at is null and pickup_at > now()
         and pickup_at - make_interval(mins => (c->>'reminderMinutes')::int) <= now()
    loop
      perform public.enqueue_notification(s.rider_id, 'sched-remind-' || s.id, 'scheduled_ride', 'normal',
        'Ride coming up',
        'Your ride is booked for ' || to_char(s.pickup_at at time zone 'Asia/Kuala_Lumpur', 'HH24:MI') ||
        case when s.partner_id is not null then '. Your driver is confirmed.' else '. We''ll find you a driver shortly.' end,
        jsonb_build_object('type', 'scheduled_reminder', 'scheduled_ride_id', s.id));
      update public.scheduled_rides set reminded_at = now() where id = s.id;
    end loop;
  end if;

  -- What became of released rides.
  for s in
    select b.id, b.rider_id, b.pickup_at, b.status, q.status as ride_status, q.cancel_requested_by
      from public.scheduled_rides b join public.ride_requests q on q.id = b.ride_id
     where b.status = 'released' and q.status in ('completed', 'cancelled', 'expired')
  loop
    if s.ride_status = 'completed' then
      update public.scheduled_rides set status = 'completed' where id = s.id;
    elsif s.ride_status = 'cancelled' then
      update public.scheduled_rides
         set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()),
             cancelled_by = coalesce(cancelled_by, case when s.cancel_requested_by = 'rider' then 'rider' else 'system' end)
       where id = s.id;
    elsif now() < s.pickup_at + interval '10 minutes' then
      -- Nobody took it in time: offered again until just after pickup time.
      begin
        perform public.scheduled_ride_release(s.id);
      exception when others then
        update public.scheduled_rides set last_error = left(sqlerrm, 300) where id = s.id;
      end;
    else
      update public.scheduled_rides set status = 'expired' where id = s.id;
      perform public.enqueue_notification(s.rider_id, 'sched-expired-' || s.id, 'scheduled_ride', 'normal',
        'No driver found', 'We couldn''t find a driver for your scheduled ride. You haven''t been charged.',
        jsonb_build_object('type', 'scheduled_expired', 'scheduled_ride_id', s.id));
    end if;
  end loop;

  -- Release what is due: a stand's booking at its own lead time (0251).
  for s in
    select id from public.scheduled_rides
     where status in ('scheduled', 'assigned')
       and pickup_at - make_interval(mins => coalesce(lead_minutes, (c->>'releaseMinutes')::int)) <= now()
       and pickup_at > now() - interval '10 minutes'
     order by pickup_at
  loop
    begin
      perform public.scheduled_ride_release(s.id);
    exception when others then
      update public.scheduled_rides set last_error = left(sqlerrm, 300) where id = s.id;
    end;
  end loop;

  -- Bookings that could never be released.
  for s in
    select * from public.scheduled_rides
     where status in ('scheduled', 'assigned') and pickup_at <= now() - interval '10 minutes'
  loop
    update public.scheduled_rides set status = 'expired' where id = s.id;
    perform public.enqueue_notification(s.rider_id, 'sched-expired-' || s.id, 'scheduled_ride', 'normal',
      'No driver found', 'We couldn''t arrange your scheduled ride. You haven''t been charged.',
      jsonb_build_object('type', 'scheduled_expired', 'scheduled_ride_id', s.id));
  end loop;
end;
$$;

-- ---- The Call centre's customer --------------------------------------------------------------
-- Whether a phone number has a GET.ride account, and its name: the console
-- says the ride will be on their account. Admins with the console only.
create or replace function public.dispatch_lookup_customer(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:dispatch_console') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if char_length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 8 then
    return jsonb_build_object('found', false);
  end if;
  v_user := public.dispatch_profile_by_phone(p_phone);
  return jsonb_build_object('found', v_user is not null,
    'name', case when v_user is not null then
      coalesce((select nullif(btrim(p.name), '') from public.profiles p where p.id = v_user), 'GET.ride customer') end);
end;
$$;
revoke execute on function public.dispatch_lookup_customer(text) from public, anon;
grant execute on function public.dispatch_lookup_customer(text) to authenticated;

-- ---- The console's actions ----------------------------------------------------------------------
-- p_action: 'widen' (broadcast to any nearby driver), 'resend_group'
-- (p_args.group_id), 'resend_driver' / 'reassign' (p_args.driver_id, or
-- p_args.group_id to broadcast), 'picked_up', 'complete' (p_args.fare for a
-- metered trip), 'cancel' (p_args.reason).
create or replace function public.dispatch_order_action(p_request uuid, p_action text, p_args jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  g public.dispatch_groups;
  v_driver uuid;
  v_fare numeric;
  v_reason text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.stand_id is null or not public.dispatch_caller_can(r.stand_id, 'use') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform set_config('dispatch.rpc', '1', true);

  if p_action = 'widen' then
    if not public.dispatch_caller_can(r.stand_id, 'broadcast') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
    end if;
    if r.status <> 'open' then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Only a waiting order is re-sent.';
    end if;
    update public.ride_requests
       set dispatch_mode = 'broadcast', dispatch_widened_at = now(), dispatch_offered_at = now(),
           dispatch_returned_at = null, dispatch_offer_until = null, dispatch_driver_id = null,
           dispatch_widen_pushed_at = now()
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'widened', 'Re-sent to any nearby driver');
    perform public.dispatch_push(r.id);

  elsif p_action in ('resend_group', 'resend_driver', 'reassign') then
    if p_action = 'reassign' then
      if not public.dispatch_caller_can(r.stand_id, 'reassign') then
        raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
      end if;
      if r.status not in ('open', 'accepted', 'arrived') then
        raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023',
          hint = 'Only an order not yet picked up is reassigned.';
      end if;
    elsif r.status <> 'open' then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Only a waiting order is re-sent.';
    end if;
    v_driver := nullif(p_args->>'driver_id', '')::uuid;
    if v_driver is not null then
      if not public.dispatch_caller_can(r.stand_id, 'assign') then
        raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
      end if;
      if not exists (select 1 from public.partners p where p.auth_user_id = v_driver
                        and (p.status = 'approved' or p.status::text like 'permit-%')) then
        raise exception 'DISPATCH_DRIVER' using errcode = '22023', hint = 'Pick a driver.';
      end if;
      if not public.service_order_driver_allows(v_driver, r.service) then
        raise exception 'SERVICE_ORDER_DIRECT' using errcode = '42501',
          hint = 'This driver''s vehicle can''t take this service. Pick another driver.';
      end if;
    else
      if not public.dispatch_caller_can(r.stand_id, 'broadcast') then
        raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
      end if;
      select * into g from public.dispatch_groups
       where id = coalesce(nullif(p_args->>'group_id', '')::uuid, r.dispatch_group_id) and active;
      if not found or not (public.caller_admin_can_write('rpc:dispatch_console')
                           or exists (select 1 from public.dispatch_stand_groups sg
                                       where sg.stand_id = r.stand_id and sg.group_id = g.id)) then
        raise exception 'DISPATCH_GROUP' using errcode = '22023', hint = 'Pick a group this stand sends to.';
      end if;
    end if;
    update public.ride_requests
       set status = 'open', partner_id = null, partner_name = null, partner_phone = null,
           partner_photo = null, partner_vehicle = null, partner_plate = null, partner_rating = null,
           partner_trips = null, accepted_at = null, arrived_at = null, offered_fare = null,
           commission_locked_at = null,
           dispatch_mode = case when v_driver is not null then 'assign' else 'broadcast' end,
           dispatch_driver_id = v_driver,
           dispatch_group_id = case when v_driver is null then g.id end,
           dispatch_group_name = case when v_driver is null then g.name end,
           dispatch_group_kind = case when v_driver is null then g.kind end,
           dispatch_offered_at = now(),
           dispatch_offer_until = case when v_driver is not null then now() + interval '30 seconds' end,
           dispatch_open_after = case when v_driver is null and g.kind = 'open'
                                      then now() + make_interval(secs => g.members_first_sec) end,
           dispatch_widened_at = null, dispatch_widen_pushed_at = null, dispatch_returned_at = null
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, case when p_action = 'reassign' then 'reassigned' else 'resent' end,
      case when v_driver is not null then 'To ' || public.dispatch_actor_name(v_driver) else 'To ' || g.name end
      || case when r.partner_id is not null and r.status <> 'open'
              then ' (was ' || coalesce(r.partner_name, 'a driver') || ')' else '' end);
    perform public.dispatch_push(r.id);

  elsif p_action = 'picked_up' then
    if r.status not in ('accepted', 'arrived') then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'The driver hasn''t taken it yet.';
    end if;
    update public.ride_requests set status = 'on_trip', start_method = 'none', started_at = now() where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'picked_up', 'Customer picked up');

  elsif p_action = 'complete' then
    if r.status <> 'on_trip' then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Only a trip under way is completed.';
    end if;
    v_fare := round(nullif(p_args->>'fare', '')::numeric, 2);
    if r.fare_mode = 'meter' and coalesce(r.ride_fare, r.fare) is null and v_fare is null then
      raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Enter the meter fare.';
    end if;
    if v_fare is not null and (v_fare <= 0 or not public.ride_money_ok(v_fare) or r.fare_mode <> 'meter') then
      raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Only a metered trip takes a fare here.';
    end if;
    update public.ride_requests
       set status = 'completed', completed_at = now(),
           fare = coalesce(v_fare, fare), ride_fare = coalesce(v_fare, ride_fare, fare)
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'completed',
      case when v_fare is not null then 'Meter fare ' || to_char(v_fare, 'FM999999990.00') else 'Trip done' end);

  elsif p_action = 'cancel' then
    if not public.dispatch_caller_can(r.stand_id, 'cancel') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
    end if;
    if r.status not in ('open', 'accepted', 'arrived') then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023',
        hint = 'Only an order not yet picked up is cancelled here.';
    end if;
    v_reason := coalesce(nullif(btrim(coalesce(p_args->>'reason', '')), ''), 'Cancelled by the stand');
    update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_reason = left(v_reason, 200)
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'cancelled', v_reason);

  else
    raise exception 'DISPATCH_ACTION' using errcode = '22023';
  end if;

  return public.dispatch_order_json(r.id);
end;
$$;
revoke execute on function public.dispatch_order_action(uuid, text, jsonb) from public, anon;
grant execute on function public.dispatch_order_action(uuid, text, jsonb) to authenticated;

-- ---- The board ----------------------------------------------------------------------------------
-- The orders of [p_stand] (or every stand the caller runs): the ones still
-- under way, and the ones finished in the last [p_hours] hours.
create or replace function public.dispatch_board(p_stand uuid default null, p_hours integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admin boolean := public.caller_is_admin() and auth.uid() is not null;
  v_mine uuid[] := public.dispatch_caller_stand_ids();
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_stand is not null and not (v_admin or p_stand = any (v_mine)) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.dispatch_scheduled_json(b.id) order by b.pickup_at)
      from public.scheduled_rides b
     where b.stand_id is not null and b.status in ('scheduled', 'assigned')
       and (p_stand is null or b.stand_id = p_stand)
       and (v_admin or b.stand_id = any (v_mine))), '[]'::jsonb)
  || coalesce((
    select jsonb_agg(public.dispatch_order_json(r.id) order by r.created_at desc)
      from public.ride_requests r
     where r.stand_id is not null
       and (p_stand is null or r.stand_id = p_stand)
       and (v_admin or r.stand_id = any (v_mine))
       and (r.status in ('open', 'accepted', 'arrived', 'on_trip')
            or r.updated_at > now() - interval '2 hours'
            or (r.updated_at > now() - make_interval(hours => least(greatest(coalesce(p_hours, 12), 1), 72))
                and (v_admin or public.dispatch_caller_can(r.stand_id, 'reports'))))
     limit 300), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_board(uuid, integer) from public, anon;
grant execute on function public.dispatch_board(uuid, integer) to authenticated;

-- One order, for the ticket.
create or replace function public.dispatch_order(p_request uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_stand uuid;
begin
  select stand_id into v_stand from public.ride_requests where id = p_request;
  if v_stand is null then
    select stand_id into v_stand from public.scheduled_rides where id = p_request;
  end if;
  if v_stand is null or not (public.dispatch_caller_can(v_stand, 'use')
                             or (public.caller_is_admin() and auth.uid() is not null)) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce(public.dispatch_order_json(p_request), public.dispatch_scheduled_json(p_request));
end;
$$;
revoke execute on function public.dispatch_order(uuid) from public, anon;
grant execute on function public.dispatch_order(uuid) to authenticated;

-- ---- The driver says no -------------------------------------------------------------------------
-- An assigned order goes straight back to the stand; a broadcast one is
-- only noted (the others still have it).
create or replace function public.dispatch_decline(p_request uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.stand_id is null or r.status <> 'open'
     or not public.dispatch_offer_ok(auth.uid(), r.dispatch_mode, r.dispatch_driver_id, r.dispatch_group_id,
                                     r.dispatch_offer_until, r.dispatch_open_after, r.dispatch_widened_at,
                                     r.dispatch_returned_at) then
    return 'gone';
  end if;
  if r.dispatch_mode = 'assign' then
    update public.ride_requests set dispatch_returned_at = now() where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'declined', 'Declined by the driver; back to the stand');
    return 'returned';
  end if;
  perform public.dispatch_log(r.id, r.stand_id, 'declined', 'Declined by a driver');
  return 'noted';
end;
$$;
revoke execute on function public.dispatch_decline(uuid) from public, anon;
grant execute on function public.dispatch_decline(uuid) to authenticated;

-- The driver completes a metered stand order at what the meter shows (a
-- metered order has no fare until then, so the usual completion can't set
-- one).
create or replace function public.dispatch_driver_complete(p_request uuid, p_fare numeric)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or auth.uid() is null or r.partner_id is distinct from auth.uid() or r.stand_id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status = 'completed' then
    return 'completed';
  end if;
  if r.status <> 'on_trip' or r.fare_mode <> 'meter' or coalesce(r.ride_fare, r.fare) is not null then
    raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Complete it the usual way.';
  end if;
  if p_fare is null or p_fare <= 0 or not public.ride_money_ok(round(p_fare, 2)) then
    raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Enter the meter fare.';
  end if;
  update public.ride_requests
     set status = 'completed', completed_at = now(), fare = round(p_fare, 2), ride_fare = round(p_fare, 2)
   where id = r.id;
  return 'completed';
end;
$$;
revoke execute on function public.dispatch_driver_complete(uuid, numeric) from public, anon;
grant execute on function public.dispatch_driver_complete(uuid, numeric) to authenticated;

-- ---- Money when the trip is done ----------------------------------------------------------------
create or replace function public.dispatch_settle(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  m jsonb;
  v_fare numeric;
  v_fee numeric;
  v_plat numeric;
  v_stand numeric;
  v_driver numeric;
  v_total numeric;
  v_note text;
  v_no_fee boolean;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.stand_id is null or r.status <> 'completed' or r.dispatch_settled_at is not null then
    return jsonb_build_object('settled', false);
  end if;
  v_no_fee := coalesce(r.stand_fee_type, 'none') = 'none';
  m := public.dispatch_split(coalesce(r.ride_fare, r.fare, 0), r.stand_fee_type, r.stand_fee_value,
                             r.stand_fee_bearer, r.stand_platform_fee_type, r.stand_platform_fee_value);
  v_fare := (m->>'fare')::numeric;
  v_fee := (m->>'fee')::numeric;
  v_plat := (m->>'platform')::numeric;
  v_stand := (m->>'stand')::numeric;
  v_driver := (m->>'driver')::numeric;
  v_total := (m->>'customer')::numeric;
  v_note := coalesce(r.dispatch_stand_name, 'Stand') || ' · ticket ' || r.ticket_no;

  if r.dispatch_payment in ('counter', 'app') then
    -- The stand has the customer's money. Paid out in the app: the driver's
    -- share to their wallet, owed by the stand with the platform's fee.
    if r.stand_settlement = 'wallet' and r.partner_id is not null then
      if v_driver > 0 then
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
        values (r.partner_id, 'get_wallet', 'stand_payout', v_driver, 'stand',
                'Fare paid at the counter — ' || v_note, r.id)
        on conflict do nothing;
      end if;
      if r.stand_fee_earner_id is not null then
        if v_driver > 0 then
          insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
          values (r.stand_fee_earner_id, 'get_credit', 'stand_payout_due', -v_driver, 'stand',
                  'Driver paid for you — ' || v_note, r.id)
          on conflict do nothing;
        end if;
        if v_plat > 0 then
          insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
          values (r.stand_fee_earner_id, 'get_credit', 'stand_platform_fee', -v_plat, 'stand',
                  'Platform fee — ' || v_note, r.id)
          on conflict do nothing;
        end if;
      end if;
    end if;
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'counter', paid_amount = v_total, paid_at = now(),
           stand_fee_amount = case when v_no_fee then null else v_fee end,
           stand_platform_fee = case when v_no_fee then null else v_plat end,
           dispatch_settled_at = now()
     where id = r.id;
  else
    -- Cash to the driver, who holds the fee too: it comes off their
    -- GET.credit; the stand gets its share, the platform keeps its own.
    if v_fee > 0 and r.partner_id is not null then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.partner_id, 'get_credit', 'stand_fee', -v_fee, 'stand', 'Stand fee — ' || v_note, r.id)
      on conflict do nothing;
      if r.stand_fee_earner_id is not null and v_stand > 0 then
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
        values (r.stand_fee_earner_id, 'get_wallet', 'stand_fee_earning', v_stand, 'stand',
                'Stand fee less the platform''s — ' || v_note, r.id)
        on conflict do nothing;
      end if;
    end if;
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'cash', paid_amount = v_total, paid_at = now(),
           stand_fee_amount = case when v_no_fee then null else v_fee end,
           stand_platform_fee = case when v_no_fee then null else v_plat end,
           dispatch_settled_at = now()
     where id = r.id;
  end if;
  return jsonb_build_object('settled', true) || m;
end;
$$;
revoke execute on function public.dispatch_settle(uuid) from public, anon, authenticated;

-- ---- After each change of a stand order ---------------------------------------------------------
create or replace function public.ride_requests_dispatch_after()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_logged boolean := coalesce(current_setting('dispatch.rpc', true), '') = '1';
  v_phone text;
  v_token uuid;
begin
  if new.stand_id is null or new.status is not distinct from old.status then
    return null;
  end if;
  begin
    if new.status = 'accepted' and old.status = 'open' then
      perform public.dispatch_log(new.id, new.stand_id, 'accepted',
        coalesce(new.partner_name, 'A driver') || coalesce(' · ' || new.partner_plate, ''), new.partner_id);
      v_phone := coalesce(new.rider_phone, (select p.rider_phone from public.ride_request_private p
                                            where p.request_id = new.id));
      v_token := coalesce(new.share_token, (select p.share_token from public.ride_request_private p
                                            where p.request_id = new.id));
      if v_phone is not null then
        perform public.dispatch_sms(v_phone,
          'GET.ride ticket ' || new.ticket_no || ': your driver is '
          || concat_ws(', ', coalesce(nullif(btrim(coalesce(new.partner_name, '')), ''), 'on the way'),
                       nullif(btrim(coalesce(new.partner_vehicle, '')), ''),
                       nullif(btrim(coalesce(new.partner_plate, '')), ''))
          || ', coming to ' || coalesce(new.dispatch_stand_name, 'the stand')
          || coalesce('. Track: https://getride.my/share/' || v_token, ''));
      end if;
    elsif v_logged then
      null;  -- the operator's action logged itself
    elsif new.status = 'arrived' then
      perform public.dispatch_log(new.id, new.stand_id, 'arrived', 'Driver at the stand', new.partner_id);
    elsif new.status = 'on_trip' then
      perform public.dispatch_log(new.id, new.stand_id, 'picked_up', 'Trip started by the driver', new.partner_id);
    elsif new.status = 'completed' then
      perform public.dispatch_log(new.id, new.stand_id, 'completed', 'Trip done', new.partner_id);
    elsif new.status = 'cancelled' then
      perform public.dispatch_log(new.id, new.stand_id, 'cancelled',
        coalesce(new.cancel_reason, 'Cancelled'), auth.uid());
    elsif new.status = 'expired' then
      perform public.dispatch_log(new.id, new.stand_id, 'expired', 'Nobody took it', null);
    end if;
    if new.status = 'completed' then
      perform public.dispatch_settle(new.id);
    end if;
  exception when others then
    -- Never holds up the trip.
    raise warning 'stand order % follow-up failed: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;
revoke execute on function public.ride_requests_dispatch_after() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_dispatch_after on public.ride_requests;
create trigger trg_ride_requests_dispatch_after
  after update of status on public.ride_requests
  for each row execute function public.ride_requests_dispatch_after();

-- ---- The clock ----------------------------------------------------------------------------------
-- Assigned orders nobody answered go back to the stand; open groups' orders
-- whose members' time is up reach the drivers nearby.
create or replace function public.dispatch_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  n int := 0;
begin
  for r in
    select * from public.ride_requests
     where status = 'open' and stand_id is not null and dispatch_mode = 'assign'
       and dispatch_returned_at is null and dispatch_offer_until <= now()
     for update skip locked
  loop
    update public.ride_requests set dispatch_returned_at = now() where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'no_answer', 'No answer in 30 s; back to the stand', null);
    n := n + 1;
  end loop;
  for r in
    select * from public.ride_requests
     where status = 'open' and stand_id is not null and dispatch_mode = 'broadcast'
       and dispatch_open_after <= now() and dispatch_widen_pushed_at is null
     for update skip locked
  loop
    update public.ride_requests set dispatch_widen_pushed_at = now() where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'opened', 'Members'' time up; any nearby driver can take it', null);
    perform public.dispatch_push(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.dispatch_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'dispatch-orders-tick';
    perform cron.schedule('dispatch-orders-tick', '10 seconds', $job$select public.dispatch_tick()$job$);
  end if;
end $$;

-- ---- The stand's account, fee and statement ---------------------------------------------------
-- Where the stand's earnings go: its owner account, else its first stand admin.
create or replace function public.dispatch_stand_account(p_stand uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select s.owner_id from public.dispatch_stands s where s.id = p_stand),
    (select o.user_id from public.dispatch_stand_people o
      where o.stand_id = p_stand and o.role = 'admin' and o.active order by o.created_at limit 1));
$$;
revoke execute on function public.dispatch_stand_account(uuid) from public, anon, authenticated;

-- The stand fee, by an admin with the Stands page, or by the stand admin
-- when the admin let the stand set it. Never by staff; never the platform
-- fee or who sets it (those are the admin's, on the table itself).
create or replace function public.dispatch_set_stand_fee(p_stand uuid, p_type text, p_value numeric, p_payer text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.dispatch_stands;
begin
  select * into s from public.dispatch_stands where id = p_stand for update;
  if not found or auth.uid() is null
     or not (public.caller_admin_can_write('dispatch_stands')
             or (s.fee_set_by = 'stand' and array[p_stand] <@ public.dispatch_caller_admin_stand_ids())) then
    raise exception 'not_authorized' using errcode = '42501', hint = 'The admin sets this stand''s fee.';
  end if;
  if p_type not in ('none', 'fixed', 'percent') or p_payer not in ('customer', 'driver')
     or coalesce(p_value, -1) < 0 or p_value > 10000 or (p_type = 'percent' and p_value > 100) then
    raise exception 'DISPATCH_FEE' using errcode = '22023', hint = 'A fee is RM 0 or more, or 0 to 100 %.';
  end if;
  update public.dispatch_stands set fee_type = p_type, fee_value = round(p_value, 2), fee_bearer = p_payer
   where id = p_stand;
  return jsonb_build_object('fee_type', p_type, 'fee_value', round(p_value, 2), 'fee_bearer', p_payer);
end;
$$;
revoke execute on function public.dispatch_set_stand_fee(uuid, text, numeric, text) from public, anon;
grant execute on function public.dispatch_set_stand_fee(uuid, text, numeric, text) to authenticated;

-- The stand's statement for [p_from, p_to): each finished order with its
-- fare, the stand fee, the platform's fee and what the stand keeps, and the
-- totals. Stand admins, staff with See reports, admins.
create or replace function public.dispatch_statement(p_stand uuid, p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.dispatch_caller_can(p_stand, 'reports') or (public.caller_is_admin() and auth.uid() is not null)) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return (
    with o as (
      select r.id, r.ticket_no, r.completed_at, r.dispatch_payment, r.stand_settlement, r.partner_name,
             coalesce(r.ride_fare, r.fare, 0) as fare, coalesce(r.stand_fee_amount, 0) as fee,
             coalesce(r.stand_platform_fee, 0) as platform, r.stand_fee_bearer, r.paid_amount
        from public.ride_requests r
       where r.stand_id = p_stand and r.status = 'completed'
         and r.completed_at >= p_from and r.completed_at < p_to)
    select jsonb_build_object(
      'orders', coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id, 'ticket_no', o.ticket_no, 'completed_at', o.completed_at, 'payment', o.dispatch_payment,
        'settlement', o.stand_settlement, 'driver', o.partner_name, 'fare', o.fare, 'fee', o.fee,
        'platform', o.platform, 'stand', o.fee - o.platform, 'payer', o.stand_fee_bearer,
        'customer_paid', o.paid_amount) order by o.completed_at), '[]'::jsonb),
      'totals', jsonb_build_object(
        'orders', count(o.id), 'fares', coalesce(sum(o.fare), 0), 'fees', coalesce(sum(o.fee), 0),
        'platform', coalesce(sum(o.platform), 0), 'stand', coalesce(sum(o.fee - o.platform), 0),
        'counter', coalesce(sum(o.paid_amount) filter (where o.dispatch_payment in ('counter', 'app')), 0)))
      from o);
end;
$$;
revoke execute on function public.dispatch_statement(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.dispatch_statement(uuid, timestamptz, timestamptz) to authenticated;

-- ---- Reports ------------------------------------------------------------------------------------
-- A stand's orders over the last [p_days] days: how many, done, cancelled,
-- the fares and the booking fees. Needs "See reports".
create or replace function public.dispatch_report(p_stand uuid, p_days integer default 1)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.dispatch_caller_can(p_stand, 'reports') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'orders', count(*),
      'done', count(*) filter (where r.status = 'completed'),
      'cancelled', count(*) filter (where r.status in ('cancelled', 'expired')),
      'fares', coalesce(sum(coalesce(r.ride_fare, r.fare)) filter (where r.status = 'completed'), 0),
      'fees', coalesce(sum(r.stand_fee_amount) filter (where r.status = 'completed'), 0),
      'platform', coalesce(sum(r.stand_platform_fee) filter (where r.status = 'completed'), 0))
      from public.ride_requests r
     where r.stand_id = p_stand
       and r.created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 1), 1), 92)));
end;
$$;
revoke execute on function public.dispatch_report(uuid, integer) from public, anon;
grant execute on function public.dispatch_report(uuid, integer) to authenticated;

-- ---- IDs: stand admins, staff and fleet owners --------------------------------------------------
-- Whether [p_caller] holds edit on an admin page (or every page).
create or replace function public.dispatch_admin_edits(p_caller uuid, p_page text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_caller is not null and exists (
    select 1 from public.admin_access a
     where a.profile_id = p_caller and a.access_level = 'edit' and a.page in ('*', p_page));
$$;
revoke execute on function public.dispatch_admin_edits(uuid, text) from public, anon, authenticated;

-- Whether [p_caller] may give someone the role [p_kind]: stand admins and
-- fleet owners are made by admins with the Accounts page; staff by a stand
-- admin of every stand named (or such an admin).
create or replace function public.dispatch_may_grant(p_caller uuid, p_kind text, p_stand_ids uuid[], p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_caller is not null and case p_kind
    when 'stand_admin' then public.dispatch_admin_edits(p_caller, 'admin-dispatch-accounts')
      and coalesce(cardinality(p_stand_ids), 0) > 0
      and (select count(*) from public.dispatch_stands s
            where s.id = any (p_stand_ids) and not s.admin_only) = cardinality(p_stand_ids)
    when 'fleet_owner' then public.dispatch_admin_edits(p_caller, 'admin-dispatch-accounts')
      and exists (select 1 from public.dispatch_groups g where g.id = p_group and g.kind = 'fleet')
    when 'staff' then coalesce(cardinality(p_stand_ids), 0) > 0
      and not exists (select 1 from public.dispatch_stands s where s.id = any (p_stand_ids) and s.admin_only)
      and (public.dispatch_admin_edits(p_caller, 'admin-dispatch-accounts')
           or not exists (
             select 1 from unnest(p_stand_ids) x(stand_id)
              where not exists (select 1 from public.dispatch_stand_people o
                                 where o.stand_id = x.stand_id and o.user_id = p_caller
                                   and o.role = 'admin' and o.active)))
    else false end;
$$;
revoke execute on function public.dispatch_may_grant(uuid, text, uuid[], uuid) from public, anon, authenticated;
grant execute on function public.dispatch_may_grant(uuid, text, uuid[], uuid) to service_role;

-- The account a phone number signs in with (auth's phone, digits only).
create or replace function public.dispatch_profile_by_phone(p_phone text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select u.id from auth.users u
   where nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') is not null
     and regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') = regexp_replace(p_phone, '\D', '', 'g')
   order by u.created_at
   limit 1;
$$;
revoke execute on function public.dispatch_profile_by_phone(text) from public, anon, authenticated;
grant execute on function public.dispatch_profile_by_phone(text) to service_role;

-- Gives [p_user] the role, on behalf of [p_caller] (checked again here):
--   stand_admin: [p_stand_ids], every access;
--   staff:       [p_stand_ids], the access in [p_perms] ({assign, broadcast,
--                fixed_fare, cancel, reassign, reports}); a stand admin is
--                never turned into staff;
--   fleet_owner: the fleet [p_group].
-- Texts them how to sign in. Called by the dispatch-account function (with
-- the caller from their token) and by dispatch_grant_existing.
create or replace function public.dispatch_grant(
  p_caller uuid, p_user uuid, p_kind text, p_name text, p_phone text,
  p_stand_ids uuid[] default '{}', p_group uuid default null, p_perms jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stand uuid;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_where text;
begin
  if not public.dispatch_may_grant(p_caller, p_kind, p_stand_ids, p_group) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'DISPATCH_NO_ACCOUNT' using errcode = '22023';
  end if;
  if v_name is null or char_length(v_name) > 80 then
    raise exception 'DISPATCH_NAME' using errcode = '22023', hint = 'Give their name.';
  end if;
  if p_user = p_caller and p_kind = 'staff' then
    raise exception 'DISPATCH_SELF' using errcode = '22023', hint = 'You can''t add yourself as staff.';
  end if;

  if p_kind in ('stand_admin', 'staff') then
    foreach v_stand in array p_stand_ids loop
      if p_kind = 'staff' and exists (select 1 from public.dispatch_stand_people o
                                       where o.stand_id = v_stand and o.user_id = p_user and o.role = 'admin') then
        raise exception 'DISPATCH_ALREADY_ADMIN' using errcode = '22023',
          hint = 'They are already the stand admin there.';
      end if;
      insert into public.dispatch_stand_people as o (stand_id, user_id, role, name, phone,
        can_assign, can_broadcast, can_fixed_fare, can_cancel, can_reassign, can_reports, active, created_by)
      values (v_stand, p_user, case when p_kind = 'stand_admin' then 'admin' else 'staff' end, v_name, p_phone,
        p_kind = 'stand_admin' or coalesce((p_perms->>'assign')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'broadcast')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'fixed_fare')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'cancel')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'reassign')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'reports')::boolean, false),
        true, p_caller)
      on conflict (stand_id, user_id) do update set
        role = excluded.role, name = excluded.name, phone = coalesce(excluded.phone, o.phone),
        can_assign = excluded.can_assign, can_broadcast = excluded.can_broadcast,
        can_fixed_fare = excluded.can_fixed_fare, can_cancel = excluded.can_cancel,
        can_reassign = excluded.can_reassign, can_reports = excluded.can_reports,
        active = true, updated_at = now();
    end loop;
    select string_agg(s.name, ', ' order by s.name) into v_where from public.dispatch_stands s where s.id = any (p_stand_ids);
  else
    insert into public.dispatch_fleet_owners as f (group_id, user_id, name, phone, active, created_by)
    values (p_group, p_user, v_name, p_phone, true, p_caller)
    on conflict (group_id, user_id) do update set name = excluded.name, phone = coalesce(excluded.phone, f.phone),
      active = true;
    select g.name into v_where from public.dispatch_groups g where g.id = p_group;
  end if;

  perform public.dispatch_sms(coalesce(p_phone, (select phone from public.profiles where id = p_user)),
    'GET.ride: you are now ' || case p_kind when 'stand_admin' then 'the stand admin' when 'staff' then 'staff'
                                            else 'the fleet owner' end
    || ' for ' || coalesce(v_where, 'GET.ride') || '. Sign in to the GET.ride app with this number; '
    || 'a new account gets a code by SMS to set its PIN.');
  return jsonb_build_object('user_id', p_user, 'kind', p_kind, 'granted', true);
end;
$$;
revoke execute on function public.dispatch_grant(uuid, uuid, text, text, text, uuid[], uuid, jsonb) from public, anon, authenticated;
grant execute on function public.dispatch_grant(uuid, uuid, text, text, text, uuid[], uuid, jsonb) to service_role;

-- From the app: the role for a phone that already has an account. A phone
-- with none answers {needs_account: true}; the app then asks the
-- dispatch-account function, which makes the account first.
create or replace function public.dispatch_grant_existing(
  p_kind text, p_name text, p_phone text, p_stand_ids uuid[] default '{}', p_group uuid default null,
  p_perms jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if auth.uid() is null or not public.dispatch_may_grant(auth.uid(), p_kind, p_stand_ids, p_group) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if char_length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) not between 8 and 15 then
    raise exception 'DISPATCH_PHONE' using errcode = '22023', hint = 'The phone number doesn''t look right.';
  end if;
  v_user := public.dispatch_profile_by_phone(p_phone);
  if v_user is null then
    return jsonb_build_object('needs_account', true);
  end if;
  return public.dispatch_grant(auth.uid(), v_user, p_kind, p_name, p_phone, p_stand_ids, p_group, p_perms);
end;
$$;
revoke execute on function public.dispatch_grant_existing(text, text, text, uuid[], uuid, jsonb) from public, anon;
grant execute on function public.dispatch_grant_existing(text, text, text, uuid[], uuid, jsonb) to authenticated;

-- The admin's list of IDs: stand admins (with their stands and how many
-- staff they have) and fleet owners.
create or replace function public.dispatch_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object(
      'kind', 'stand_admin', 'user_id', o.user_id, 'name', max(o.name), 'phone', max(o.phone),
      'active', bool_or(o.active),
      'places', jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name),
      'staff', (select count(*) from public.dispatch_stand_people x
                 where x.role = 'staff' and x.stand_id = any (array_agg(o.stand_id)))) as x
      from public.dispatch_stand_people o
      join public.dispatch_stands s on s.id = o.stand_id
     where o.role = 'admin'
     group by o.user_id
    union all
    select jsonb_build_object(
      'kind', 'fleet_owner', 'user_id', f.user_id, 'name', max(f.name), 'phone', max(f.phone),
      'active', bool_or(f.active),
      'places', jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) order by g.name), 'staff', 0)
      from public.dispatch_fleet_owners f
      join public.dispatch_groups g on g.id = f.group_id
     group by f.user_id) y(x)), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_accounts() from public, anon;
grant execute on function public.dispatch_accounts() to authenticated;

-- ---- A fleet owner's fleet ---------------------------------------------------------------------
create or replace function public.dispatch_caller_runs_fleet(p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (p_group = any (public.dispatch_caller_fleet_ids())
          or public.caller_admin_can_write('dispatch_group_members'));
$$;
revoke execute on function public.dispatch_caller_runs_fleet(uuid) from public, anon, authenticated;

-- The fleets the caller owns.
create or replace function public.dispatch_my_fleets()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) order by g.name), '[]'::jsonb)
    from public.dispatch_groups g where g.id = any (public.dispatch_caller_fleet_ids());
$$;
revoke execute on function public.dispatch_my_fleets() from public, anon;
grant execute on function public.dispatch_my_fleets() to authenticated;

-- The fleet: its drivers, who is asking to join, and today's stand orders.
create or replace function public.dispatch_fleet(p_group uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  g public.dispatch_groups;
begin
  if not public.dispatch_caller_runs_fleet(p_group) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into g from public.dispatch_groups where id = p_group and kind = 'fleet';
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'id', g.id, 'name', g.name,
    'drivers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'driver_id', m.driver_id, 'status', m.status, 'requested_at', m.requested_at,
        'name', public.dispatch_actor_name(m.driver_id),
        'plate', public.dispatch_driver_car(m.driver_id)->>'plate',
        'vehicle', public.dispatch_driver_car(m.driver_id)->>'vehicle',
        'service', pa.vehicle_type,
        'state', case when public.dispatch_driver_busy(m.driver_id) then 'on_trip'
                      when exists (select 1 from public.driver_presence d where d.profile_id = m.driver_id
                                     and d.online and d.updated_at > now() - interval '3 minutes') then 'free'
                      else 'offline' end) order by m.status, m.requested_at)
        from public.dispatch_group_members m
        left join lateral (select p.plate, p.vehicle_type, p.vehicle from public.partners p
                            where p.auth_user_id = m.driver_id order by p.updated_at desc limit 1) pa on true
       where m.group_id = g.id and m.status in ('approved', 'pending')), '[]'::jsonb),
    'today', (
      select jsonb_build_object(
        'orders', count(*),
        'done', count(*) filter (where r.status = 'completed'),
        'cancelled', count(*) filter (where r.status = 'cancelled'),
        'fares', coalesce(sum(coalesce(r.ride_fare, r.fare)) filter (where r.status = 'completed'), 0))
        from public.ride_requests r
       where r.stand_id is not null and r.created_at > date_trunc('day', now())
         and r.partner_id is not null and public.dispatch_member_of(g.id, r.partner_id)));
end;
$$;
revoke execute on function public.dispatch_fleet(uuid) from public, anon;
grant execute on function public.dispatch_fleet(uuid) to authenticated;

-- Adds a driver to the fleet by their phone number or plate.
create or replace function public.dispatch_fleet_add(p_group uuid, p_query text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_digits text := regexp_replace(coalesce(p_query, ''), '\D', '', 'g');
  v_plate text := upper(regexp_replace(coalesce(p_query, ''), '\s', '', 'g'));
  v_driver uuid;
begin
  if not public.dispatch_caller_runs_fleet(p_group)
     or not exists (select 1 from public.dispatch_groups where id = p_group and kind = 'fleet') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select p.auth_user_id into v_driver from public.partners p
   where p.auth_user_id is not null
     and (p.status = 'approved' or p.status::text like 'permit-%')
     and ((char_length(v_digits) >= 8 and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') = v_digits)
          or (char_length(v_plate) >= 2 and upper(regexp_replace(coalesce(p.plate, ''), '\s', '', 'g')) = v_plate))
   order by p.updated_at desc
   limit 1;
  if v_driver is null then
    raise exception 'DISPATCH_DRIVER' using errcode = '22023', hint = 'No approved driver has that phone or plate.';
  end if;
  insert into public.dispatch_group_members (group_id, driver_id, status, decided_at, decided_by)
  values (p_group, v_driver, 'approved', now(), auth.uid())
  on conflict (group_id, driver_id) do update set status = 'approved', decided_at = now(), decided_by = auth.uid();
  return jsonb_build_object('driver_id', v_driver, 'name', public.dispatch_actor_name(v_driver));
end;
$$;
revoke execute on function public.dispatch_fleet_add(uuid, text) from public, anon;
grant execute on function public.dispatch_fleet_add(uuid, text) to authenticated;

-- The admin's view of a group's drivers and requests (names included).
create or replace function public.dispatch_group_people(p_group uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not (public.caller_is_admin() or p_group = any (public.dispatch_caller_fleet_ids())) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'driver_id', m.driver_id, 'status', m.status, 'requested_at', m.requested_at,
      'name', public.dispatch_actor_name(m.driver_id),
      'plate', (select p.plate from public.partners p where p.auth_user_id = m.driver_id
                 order by p.updated_at desc limit 1)) order by m.status, m.requested_at)
      from public.dispatch_group_members m where m.group_id = p_group), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_group_people(uuid) from public, anon;
grant execute on function public.dispatch_group_people(uuid) to authenticated;

-- ---- A fleet's vehicles -----------------------------------------------------------------------
-- A fleet owner adds a vehicle with the driver app's own vehicle steps (the
-- `vehicle` row, its documents, the admin's usual approval: Pending review →
-- Approved / Rejected), then links it to their fleet here. They pick which of
-- their drivers drives it: a vehicle_user_assignment that waits for an
-- admin's approval (approval = 'pending'); claim_vehicle drives neither an
-- unapproved vehicle (0186) nor on an unapproved assignment (below).
-- The fleet a vehicle is in is set by dispatch_fleet_link_vehicle only.
create or replace function public.vehicle_guard_dispatch_fleet()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('vehicle')
     and new.dispatch_fleet_id is distinct from (case when tg_op = 'UPDATE' then old.dispatch_fleet_id end) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:dispatch_fleet_id' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_vehicle_a_guard_fleet on public.vehicle;
create trigger trg_vehicle_a_guard_fleet before insert or update on public.vehicle
  for each row execute function public.vehicle_guard_dispatch_fleet();

-- Only an admin approves an assignment; a new one by anyone else waits.
create or replace function public.vehicle_assignment_guard_approval()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('vehicle_user_assignment') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.approval := 'pending';
  elsif new.approval is distinct from old.approval then
    raise exception 'ASSIGNMENT_APPROVAL_ADMIN_ONLY' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_vehicle_user_assignment_approval on public.vehicle_user_assignment;
create trigger trg_vehicle_user_assignment_approval before insert or update on public.vehicle_user_assignment
  for each row execute function public.vehicle_assignment_guard_approval();

-- Links a vehicle the caller owns to their fleet.
create or replace function public.dispatch_fleet_link_vehicle(p_group uuid, p_vehicle uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.dispatch_caller_runs_fleet(p_group)
     or not exists (select 1 from public.dispatch_groups where id = p_group and kind = 'fleet') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not exists (
       select 1 from public.vehicle v
        where v.id = p_vehicle
          and (v.dispatch_fleet_id is null or v.dispatch_fleet_id = p_group)
          and (v.auth_user_id = auth.uid()
               or exists (select 1 from public.partners pa where pa.id = v.owner_partner_id
                             and pa.auth_user_id = auth.uid())
               or public.caller_admin_can_write('vehicle'))) then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Only your own vehicles join your fleet.';
  end if;
  update public.vehicle set dispatch_fleet_id = p_group where id = p_vehicle;
end;
$$;
revoke execute on function public.dispatch_fleet_link_vehicle(uuid, uuid) from public, anon;
grant execute on function public.dispatch_fleet_link_vehicle(uuid, uuid) to authenticated;

-- Picks the fleet driver who drives a fleet vehicle (null: nobody). The
-- assignment waits for an admin; the one it replaces ends.
create or replace function public.dispatch_fleet_assign(p_group uuid, p_vehicle uuid, p_driver uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner uuid;
begin
  if not public.dispatch_caller_runs_fleet(p_group)
     or not exists (select 1 from public.vehicle where id = p_vehicle and dispatch_fleet_id = p_group) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_driver is not null and not exists (
       select 1 from public.dispatch_group_members m
        where m.group_id = p_group and m.driver_id = p_driver and m.status = 'approved') then
    raise exception 'DISPATCH_DRIVER' using errcode = '22023', hint = 'Only a driver of your fleet.';
  end if;
  delete from public.vehicle_user_assignment
   where vehicle_id = p_vehicle and dispatch_fleet_id = p_group and user_id is distinct from p_driver;
  if p_driver is null then
    return jsonb_build_object('driver_id', null);
  end if;
  select pa.id into v_partner from public.partners pa where pa.auth_user_id = p_driver
   order by pa.updated_at desc limit 1;
  insert into public.vehicle_user_assignment (vehicle_id, user_id, partner_id, role, assigned_by, is_active,
                                              approval, dispatch_fleet_id, notes)
  values (p_vehicle, p_driver, v_partner, 'driver', auth.uid(), true, 'pending', p_group, 'Fleet assignment')
  on conflict (vehicle_id, user_id) do update
    set dispatch_fleet_id = p_group, is_active = true,
        approval = case when vehicle_user_assignment.approval = 'approved' then 'approved' else 'pending' end;
  return jsonb_build_object('driver_id', p_driver,
    'approval', (select approval from public.vehicle_user_assignment where vehicle_id = p_vehicle and user_id = p_driver));
end;
$$;
revoke execute on function public.dispatch_fleet_assign(uuid, uuid, uuid) from public, anon;
grant execute on function public.dispatch_fleet_assign(uuid, uuid, uuid) to authenticated;

-- The fleet's vehicles with their approval and who drives them.
create or replace function public.dispatch_fleet_vehicles(p_group uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.dispatch_caller_runs_fleet(p_group) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model, 'service', v.vehicle_type,
      'status', v.status, 'documents_ok', v.documents_ok, 'onboarding_step', v.onboarding_step,
      'fleet_id', v.dispatch_fleet_id,
      'drivers', coalesce((select jsonb_agg(jsonb_build_object(
                   'driver_id', a.user_id, 'name', public.dispatch_actor_name(a.user_id),
                   'approval', a.approval, 'active', a.is_active) order by a.assigned_at)
                   from public.vehicle_user_assignment a
                  where a.vehicle_id = v.id and a.role <> 'owner'), '[]'::jsonb)) order by v.created_at)
      from public.vehicle v
     where v.dispatch_fleet_id = p_group
        or (v.dispatch_fleet_id is null
            and (v.auth_user_id = auth.uid()
                 or exists (select 1 from public.partners pa where pa.id = v.owner_partner_id
                               and pa.auth_user_id = auth.uid())))), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_fleet_vehicles(uuid) from public, anon;
grant execute on function public.dispatch_fleet_vehicles(uuid) to authenticated;

-- claim_vehicle (0186): an assignment waiting for an admin drives nothing.
create or replace function public.claim_vehicle(p_vehicle_id uuid, p_user_id uuid)
 RETURNS vehicle_active_session
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_assignment public.vehicle_user_assignment%rowtype;
  v_session    public.vehicle_active_session%rowtype;
  v_partner_id uuid;
  v_is_owner   boolean := false;
  v_ctx        jsonb;
  v_fit        jsonb;
begin
  if p_user_id is distinct from auth.uid() and not public.caller_admin_can_write('rpc:claim_vehicle') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Active explicit assignment?
  select * into v_assignment
    from public.vehicle_user_assignment
   where vehicle_id = p_vehicle_id
     and user_id    = p_user_id
     and is_active  = true
     -- A fleet's assignment drives once an admin approved it (0251).
     and approval   = 'approved'
   limit 1;

  if not found then
    -- Owner of the vehicle counts as an implicit active assignee.
    select true into v_is_owner
      from public.vehicle
     where id = p_vehicle_id
       and auth_user_id = p_user_id
     limit 1;

    -- No row leaves v_is_owner NULL, and `not NULL` is not true, so 0035's
    -- `if not v_is_owner` let every caller through.
    if not coalesce(v_is_owner, false) then
      raise exception 'not_assigned'
        using hint = 'User is not an active assignee or owner of this vehicle.';
    end if;
  end if;

  -- Only an approved vehicle is driven (the app offers no other; a direct
  -- call no longer gets round it).
  if not public.caller_admin_can_write('rpc:claim_vehicle') and not exists (
    select 1 from public.vehicle
     where id = p_vehicle_id and status::text in ('approved', 'permit-verified')
  ) then
    raise exception 'vehicle_not_approved'
      using hint = 'This vehicle is not approved to drive.';
  end if;

  -- The partner type's vehicle age limit (0245), for the driver's types.
  if not public.caller_admin_can_write('rpc:claim_vehicle') then
    v_ctx := public.ptr_vehicle_context(p_vehicle_id);
    v_fit := public.ptr_vehicle_fits_types(
      (select p.partner_types from public.partners p where p.auth_user_id = p_user_id order by p.created_at limit 1),
      v_ctx ->> 'year',
      public.ptr_text_array(v_ctx -> 'countries'), public.ptr_text_array(v_ctx -> 'states'),
      public.ptr_text_array(v_ctx -> 'cities'), false);
    if not coalesce((v_fit ->> 'ok')::boolean, true) then
      raise exception 'vehicle_too_old' using hint = v_fit ->> 'reason';
    end if;
  end if;

  -- Vehicle already in use?
  select * into v_session
    from public.vehicle_active_session
   where vehicle_id = p_vehicle_id
   limit 1;

  if found then
    if v_session.user_id = p_user_id then
      update public.vehicle_active_session
         set last_seen_at = now(),
             status       = 'online'
       where id = v_session.id
      returning * into v_session;
      return v_session;
    end if;
    raise exception 'vehicle_in_use'
      using hint = 'Vehicle is currently used by another user.';
  end if;

  -- User already driving something else?
  if exists (
    select 1 from public.vehicle_active_session where user_id = p_user_id
  ) then
    raise exception 'user_busy'
      using hint = 'User is already in an active session on another vehicle.';
  end if;

  v_partner_id := v_assignment.partner_id;

  insert into public.vehicle_active_session (vehicle_id, user_id, partner_id)
       values (p_vehicle_id, p_user_id, v_partner_id)
    returning * into v_session;

  return v_session;
end;
$$;

-- ---- Normal-booking machinery that must leave stand orders alone --------------------------------
-- The insert push to every driver nearby: a stand order is pushed by
-- dispatch_push only, to the drivers it is offered to.
create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  cfg      jsonb;
  v_raised boolean := tg_op = 'UPDATE';
  v_msg    jsonb;
  v_radius double precision;
  v_driver uuid;
  v_told   int := 0;
begin
  -- Only ever notify about requests that are still open (biddable).
  if new.status is distinct from 'open' then
    return new;
  end if;
  -- Held for the airport's waiting drivers (0249).
  if new.airport_hold then
    return new;
  end if;

  -- A stand order goes to the drivers it is offered to (dispatch_push, 0251).
  if new.stand_id is not null and new.dispatch_mode is distinct from 'nearby' then
    return new;
  end if;

  -- On UPDATE, fire only when the passenger raised their fare on the open row.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  -- Inside the favourites / direct window: the targeted drivers, wherever they are.
  if public.ride_request_targeting(new.target_driver_ids, new.targeted_until) then
    v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                              case when v_raised then 'raised'
                                                   when new.direct_driver_id is not null then 'direct'
                                                   else 'my_ride' end);
    if v_raised then
      foreach v_driver in array new.target_driver_ids loop
        continue when v_driver = new.rider_id;
        perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      end loop;
    else
      perform public.ride_request_push_targets(new.id, new.target_driver_ids, v_msg);
    end if;
    return new;
  end if;

  -- Open to all: the drivers near the pickup — the service's min radius,
  -- or its max once widened.
  cfg := public.vehicle_service_dispatch_config(new.service);
  v_radius := case when new.widened_pushed_at is not null
                   then (cfg->>'search_radius_max_km')::double precision
                   else (cfg->>'search_radius_min_km')::double precision end;
  v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                            case when v_raised then 'raised' else 'new' end);
  v_told := public.ride_request_push_nearby(new.id, new.rider_id, new.pickup_lat, new.pickup_lng, v_radius, v_msg,
                                            case when v_raised then 'raised' else 'nearby' end, false);

  -- Nobody known nearby: every driver, as before.
  if v_told = 0 then
    perform public.ride_request_push_everyone(new.id, v_msg, case when v_raised then 'raised' else 'everyone' end);
  end if;

  return new;
exception when others then
  -- Never let a notification failure block the ride request write.
  return new;
end;
$$;

-- The normal widening ticks (0249's, airport holds left out): not for stand
-- orders, but for the Call centre's nearby bookings.
create or replace function public.ride_requests_dispatch_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := 0;
begin
  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and (stand_id is null or dispatch_mode = 'nearby')
       and created_at > now() - interval '15 minutes'
       and targeted_until is not null and targeted_until <= now()
       and fallback_pushed_at is null
       and direct_driver_id is null
       and not airport_hold
  loop
    if public.ride_request_open_to_all(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and (stand_id is null or dispatch_mode = 'nearby')
       and created_at > now() - interval '15 minutes'
       and widened_pushed_at is null
       and (targeted_until is null or fallback_pushed_at is not null)
       and not airport_hold
  loop
    if public.ride_request_widen(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  delete from public.ride_request_pushes where at < now() - interval '1 day';
  return n;
end;
$$;

-- Open requests expire after 7 minutes; a stand order waits 30 minutes from
-- when it was last sent, so the stand can re-send it.
create or replace function public.expire_open_ride_requests()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  update public.ride_requests
     set status = 'expired'
   where status = 'open'
     and (((stand_id is null or dispatch_mode = 'nearby') and created_at < now() - interval '7 minutes')
          or (stand_id is not null and dispatch_mode is distinct from 'nearby'
              and coalesce(dispatch_offered_at, created_at) < now() - interval '30 minutes'));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- What a driver keeps: a booking fee they bear comes off too.
create or replace function public.ride_net_earnings(r public.ride_requests)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, round(public.ride_amount_due(r) - coalesce(r.commission_amount, 0) - coalesce((
    select sum(round((e->>'value')::numeric, 2))
      from jsonb_array_elements(case when jsonb_typeof(r.charges) = 'array' then r.charges else '[]'::jsonb end) e
     where (e->>'platform')::boolean is true and e->>'charge' = 'fixed'
       and jsonb_typeof(e->'value') = 'number' and (e->>'value')::numeric > 0), 0)
    - case when r.stand_fee_bearer = 'driver' then coalesce(r.stand_fee_amount, 0) else 0 end, 2));
$$;

-- ---- Live --------------------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['dispatch_stands', 'dispatch_groups', 'dispatch_group_members',
                             'dispatch_stand_people', 'dispatch_fleet_owners', 'dispatch_order_events'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ---- The Call centre ---------------------------------------------------------------------------
-- Admins' own pickup for customers who phone, text or WhatsApp: each order
-- has its own pickup address; nobody but admins sees it.
insert into public.dispatch_stands (name, kind, code, admin_only, allow_fixed_fare, settlement, fee_type)
select 'Call centre · phone & text bookings', 'call_centre', 'CALL', true, true, 'wallet', 'none'
 where not exists (select 1 from public.dispatch_stands where admin_only and kind = 'call_centre');
