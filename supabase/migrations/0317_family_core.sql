-- ============================================================================
-- 0317 — Family: one shared layer every booking module uses, today's and any
-- added later (the owner's key requirement), and the owner's privacy rules.
--
-- Version 20261028100000 (0317_family_core). Re-runnable: tables, columns and
-- indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, seed rows only where missing.
--
-- Privacy (owner's rules, non-negotiable). Only three disclosed ways exist to
-- see a member, nothing hidden or covert:
--   (1) the Family viewer: the host sees a member's ride (and, only when the
--       admin allows it and the member turns it on, their phone's last place)
--       while the member's app shows "Shared with family" and who can see.
--       The member is told before joining, can leave at any time and sharing
--       stops at once. A host never sees a member who has not accepted, and a
--       host's raise of what is shared waits for the member to accept it.
--   (2) a logged admin view (God View): only with a reason; every look is
--       logged with who, when and why (family_view_log, admin_audit_log); the
--       member reads their log (family_my_view_log).
--   (3) the admin's location rule per region: never / while on a ride /
--       always if the member allows. The host picks at most that per member.
-- Children without a phone are rows under the host (family_members, kind
-- 'child', no profile, no device): the host books their trips.
--
-- 1. The module registry: booking_modules (key, name). Every booking module
--    is registered here (family_register_module, harmless to repeat): ride,
--    scheduled_ride, city_to_city, freight, courier, tips, and the keys of
--    modules being built (seat_trip, get_plus, business_account,
--    freight_addons, courier_addons). A module not in the table, or with no
--    rule, is all off until the admin turns it on.
-- 2. family_places: the Family values per place (Default, country, state,
--    city, suburb; place_key as ride_option_places, 0253); each key from the
--    smallest place that sets it (family_settings_at): enabled, children,
--    maxMembers, inviteDays, aloneAge, codeTries, monthCap, perRideChoices,
--    womenDriversForChildren, locationRule (never | ride | always).
-- 3. family_module_rules: per place and module, four switches (null =
--    inherit): family_pays, book_for_member, child_allowed, live_share
--    (family_module_rule_at). Default rows for today's modules follow the
--    approved matrix; placeholders have none (off).
-- 4. families (one per host; the host's region; member cap raised by an
--    admin), family_members (invited / active / declined / left / removed /
--    expired; members by phone, children without one; limits, services,
--    location choice, a raise waiting for the member), family_cap_requests,
--    family_trips (every booking made with Family, any module, keyed by the
--    trip's id), family_spend (what the host paid for a member),
--    family_pickup_codes (children), family_view_log (admin looks).
--    Nobody reads or writes them directly: only the functions below.
-- 5. The functions every module calls:
--      family_payer_for(module, booking owner, passenger, amount, place,
--        options) -> {ok, payer, ...} or a refusal code: FAMILY_NOT_MEMBER,
--        FAMILY_OFF, FAMILY_MODULE_OFF, FAMILY_SERVICE_NOT_ALLOWED,
--        FAMILY_RIDE_LIMIT, FAMILY_LIMIT_REACHED, FAMILY_NOT_HOST,
--        FAMILY_BOOK_FOR_OFF, FAMILY_CHILD_NOT_ALLOWED, FAMILY_CHILD_TOO_YOUNG,
--        FAMILY_CHILDREN_OFF.
--      family_attach_trip(module, trip id, owner, passenger, amount, place,
--        options, family pays) -> registers the trip (raises the code).
--      family_charge(trip, amount, kind) -> records spend within the limits.
--      family_wallet_owner(trip, user, amount) -> whose GET.wallet pays.
--      family_can_view_location(viewer, member).
--      family_child_code / _new / family_verify_pickup_code /
--      family_driver_child (children).
-- 6. The payment layer, generic: a GET.wallet row (wallet_transactions)
--    tagged with a trip (ride_id) of a family-paid trip and charged to the
--    member goes to the host's wallet instead, within the member's per-ride
--    and monthly limits (trigger trg_wallet_tx_00_family), and a refund on
--    it goes back the same way. So every charge on a trip, today's (fare,
--    waiting, luggage, add-ons, tolls, cancel and no-show fees, owed fees
--    carried on the fare) and any added later, goes to whoever paid the trip,
--    as long as it names the trip. ride_pay (method 'family'; any other
--    method means the member pays this trip themselves), ride_fee_take and
--    c2c_fee_take are redefined, as before, plus the trip tag and the payer's
--    balance check. A refund goes back to the host up to what the family
--    paid on the trip, even after the member left; money that is the
--    member's own (cash on delivery, a cover claim, a driver's give-up
--    compensation) stays theirs. Section 9 tags the later modules' rows.
-- 7. Wired into the modules on main: ride_requests (city ride, scheduled
--    ride once released, Freight, Courier) and scheduled_rides through a
--    `family` column ({passenger, withAdult}) and payment_mode 'Family';
--    c2c_bookings through `family` and payment 'family' (module 'seat_trip'
--    for a seat on a posted trip, else 'city_to_city'). Each booking is
--    checked with family_payer_for and registered; a child's trip can't start
--    without the pickup code; women drivers for children where the admin
--    says so; the host is told at pickup and drop-off of a child. A trip
--    booked for a member or child with a name and no phone gets a contact
--    phone (family_contact_phone: the member's, else the booker's, else the
--    host's), so 0107's booked-for shape holds when a driver takes it.
--    scheduled_request_clean keeps 0312's and 0313's keys plus 'family'.
-- 8. Admin › People › Family (page admin-settings-family): the values and the
--    module matrix (table writes), families, member caps, requests, and the
--    logged God View look.
-- 9. Modules after 0308 (0309 to 0316), each function the latest definition
--    with only what Family needs:
--    City to City money (0309): payment 'family' is paid as 'in_app' from
--    the host's GET.wallet (held or after, by c2c_pay_rule_for; get_wallet
--    only, never the host's coins; the member's limits checked, their
--    FAMILY_* code): c2c_take_fare, c2c_accept_offer_pay, c2c_pay,
--    c2c_driver_progress, c2c_pay_info; every row names the trip
--    (c2c_hold_refund, c2c_hold_release, c2c_settle_due), so a refund or
--    release goes back the same way, and a cancel fee owed on a family-paid
--    trip is the family's (c2c_collect_rider_dues checks the payer's
--    balance). c2c_switch_to_cash: the member's own trip from then on.
--    Seat trips (0310): c2c_book_seat takes payment 'family' and p_family
--    ({passenger, withAdult}, a new last argument with a default; the old
--    signature is dropped and every call to it works unchanged).
--    Tips (0314): ride_tip charges a GET.wallet tip naming the trip where
--    the family pays the trip and the 'tips' module (family_tip_paid_by_
--    family), from the host's GET.wallet. Waiting and luggage (0314) and the
--    Freight and Courier add-ons (0312) are on the fare, paid by ride_pay.
--    GET.Plus (0316) and business trips (0313) credit only the driver; a
--    booking can't be both business-paid and family-paid (FAMILY_BUSINESS,
--    trg_ride_requests_b_family_not_business and
--    trg_scheduled_rides_0_family_not_business).
-- ============================================================================

-- ---- 1. The module registry ---------------------------------------------------------------------
create table if not exists public.booking_modules (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  description text check (description is null or char_length(description) <= 300),
  position    integer not null default 0,
  created_at  timestamptz not null default now()
);
comment on table public.booking_modules is
  'Every booking module (0317). Family reads its rules per module from here; a module with no rule is all off.';

-- Registers a module; changes nothing when it is there. Modules call this in
-- their own migration (CLAUDE.md, "Every booking module works with Family").
create or replace function public.family_register_module(p_key text, p_name text, p_description text default null)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.booking_modules (key, name, description, position)
  values (p_key, p_name, p_description,
          coalesce((select max(position) from public.booking_modules), 0) + 1)
  on conflict (key) do nothing;
$$;
revoke execute on function public.family_register_module(text, text, text) from public, anon, authenticated;

do $reg$
begin
  perform public.family_register_module('ride', 'Ride', 'City ride, now');
  perform public.family_register_module('scheduled_ride', 'Scheduled ride', 'A ride booked for later');
  perform public.family_register_module('city_to_city', 'City to City', 'A whole car to another city');
  perform public.family_register_module('freight', 'Freight', 'Goods by van or lorry');
  perform public.family_register_module('courier', 'Courier', 'Parcels');
  perform public.family_register_module('tips', 'Tips', 'A tip after the trip');
  -- Being built in parallel: registered so their rules exist from the start.
  perform public.family_register_module('seat_trip', 'Seat trip', 'A seat on a trip a driver posts');
  perform public.family_register_module('get_plus', 'GET.Plus', 'Membership');
  perform public.family_register_module('business_account', 'Business account', 'Trips billed to a business');
  perform public.family_register_module('freight_addons', 'Freight add-ons', 'Floors, cold truck and other add-ons');
  perform public.family_register_module('courier_addons', 'Courier add-ons', 'Parcel cover, cash on delivery');
end
$reg$;

-- ---- 2. Family values by place ------------------------------------------------------------------
create or replace function public.family_rules_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'object'
     and not exists (
       select 1 from jsonb_each(p) e
        where not coalesce(case e.key
          when 'enabled' then jsonb_typeof(e.value) = 'boolean'
          when 'children' then jsonb_typeof(e.value) = 'boolean'
          when 'womenDriversForChildren' then jsonb_typeof(e.value) = 'boolean'
          when 'maxMembers' then jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric between 1 and 50
          when 'inviteDays' then jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric between 1 and 60
          when 'aloneAge' then jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric between 6 and 18
          when 'codeTries' then jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric between 1 and 10
          when 'monthCap' then jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric between 0 and 100000
          when 'locationRule' then e.value #>> '{}' in ('never', 'ride', 'always')
          when 'perRideChoices' then jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) <= 10
            and not exists (select 1 from jsonb_array_elements(e.value) x
                             where jsonb_typeof(x) <> 'number' or (x #>> '{}')::numeric not between 1 and 100000)
          else false end, false));
$$;

create table if not exists public.family_places (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  rules      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint family_places_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)),
  constraint family_places_valid check (public.family_rules_valid(rules))
);
create unique index if not exists family_places_key_uidx on public.family_places (place_key);
comment on table public.family_places is
  'Family values by place (0317), keyed as ride_option_places: each key from the smallest place that sets it.';

drop trigger if exists trg_family_places_updated_at on public.family_places;
create trigger trg_family_places_updated_at before update on public.family_places
  for each row execute function public.set_updated_at();

insert into public.family_places (level, rules)
values ('default', jsonb_build_object(
  'enabled', true, 'children', true, 'maxMembers', 6, 'inviteDays', 7, 'aloneAge', 12, 'codeTries', 3,
  'monthCap', 1000, 'perRideChoices', jsonb_build_array(20, 50, 100, 200), 'womenDriversForChildren', true,
  'locationRule', 'ride'))
on conflict (place_key) do nothing;

-- The place keys from Default down to [p_place] ({country, state, city, suburb}).
create or replace function public.family_place_keys(p_place jsonb)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_place->>'country', '')));
  s text := lower(btrim(coalesce(p_place->>'state', '')));
  t text := lower(btrim(coalesce(p_place->>'city', '')));
  b text := lower(btrim(coalesce(p_place->>'suburb', '')));
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
  return k;
end;
$$;

create or replace function public.family_level_rank(p_level text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_level when 'default' then 0 when 'country' then 1 when 'state' then 2 when 'city' then 3 else 4 end;
$$;

-- The values at a place: built in, then Default, then each smaller place.
create or replace function public.family_settings_at(p_place jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := jsonb_build_object(
    'enabled', true, 'children', true, 'maxMembers', 6, 'inviteDays', 7, 'aloneAge', 12, 'codeTries', 3,
    'monthCap', 1000, 'perRideChoices', jsonb_build_array(20, 50, 100, 200), 'womenDriversForChildren', true,
    'locationRule', 'ride');
  r record;
begin
  for r in
    select p.rules from public.family_places p
     where p.place_key = any (public.family_place_keys(coalesce(p_place, '{}'::jsonb)))
     order by public.family_level_rank(p.level)
  loop
    v := v || r.rules;
  end loop;
  return v;
end;
$$;
revoke execute on function public.family_settings_at(jsonb) from public, anon;
grant execute on function public.family_settings_at(jsonb) to authenticated;

-- ---- 3. The module rules ------------------------------------------------------------------------
create table if not exists public.family_module_rules (
  id              uuid primary key default gen_random_uuid(),
  level           text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country         text check (country is null or char_length(btrim(country)) between 1 and 120),
  state           text check (state is null or char_length(btrim(state)) between 1 and 120),
  city            text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb          text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key       text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  module_key      text not null references public.booking_modules(key) on delete cascade,
  -- null: as the place above (none anywhere: off).
  family_pays     boolean,
  book_for_member boolean,
  child_allowed   boolean,
  live_share      boolean,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint family_module_rules_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null))
);
create unique index if not exists family_module_rules_uidx on public.family_module_rules (place_key, module_key);
comment on table public.family_module_rules is
  'Family per booking module and place (0317): four switches, null inherits; a module with none is off.';

drop trigger if exists trg_family_module_rules_updated_at on public.family_module_rules;
create trigger trg_family_module_rules_updated_at before update on public.family_module_rules
  for each row execute function public.set_updated_at();

-- The approved matrix for today's modules (Admin board, 28 Oct 2026).
insert into public.family_module_rules (level, module_key, family_pays, book_for_member, child_allowed, live_share)
values ('default', 'ride', true, true, true, true),
       ('default', 'scheduled_ride', true, true, true, true),
       ('default', 'city_to_city', true, true, false, true),
       ('default', 'courier', true, true, false, false),
       ('default', 'freight', false, false, false, false),
       ('default', 'tips', true, false, false, false)
on conflict (place_key, module_key) do nothing;

-- A module's switches at a place; all false for a module not registered.
create or replace function public.family_module_rule_at(p_module text, p_place jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := jsonb_build_object('familyPays', false, 'bookForMember', false, 'childAllowed', false,
                                'liveShare', false);
  r public.family_module_rules;
begin
  if p_module is null or not exists (select 1 from public.booking_modules where key = p_module) then
    return v;
  end if;
  for r in
    select * from public.family_module_rules m
     where m.module_key = p_module
       and m.place_key = any (public.family_place_keys(coalesce(p_place, '{}'::jsonb)))
     order by public.family_level_rank(m.level)
  loop
    if r.family_pays is not null then v := v || jsonb_build_object('familyPays', r.family_pays); end if;
    if r.book_for_member is not null then v := v || jsonb_build_object('bookForMember', r.book_for_member); end if;
    if r.child_allowed is not null then v := v || jsonb_build_object('childAllowed', r.child_allowed); end if;
    if r.live_share is not null then v := v || jsonb_build_object('liveShare', r.live_share); end if;
  end loop;
  return v;
end;
$$;
revoke execute on function public.family_module_rule_at(text, jsonb) from public, anon;
grant execute on function public.family_module_rule_at(text, jsonb) to authenticated;

-- Every registered module with its switches at a place (the app's list, the admin's preview).
create or replace function public.family_modules_at(p_place jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name)
                            || public.family_module_rule_at(m.key, p_place)
                            order by m.position, m.key), '[]'::jsonb)
    from public.booking_modules m;
$$;
revoke execute on function public.family_modules_at(jsonb) from public, anon;
grant execute on function public.family_modules_at(jsonb) to authenticated;

-- ---- 4. Families --------------------------------------------------------------------------------
create table if not exists public.families (
  id         uuid primary key default gen_random_uuid(),
  host_id    uuid not null unique references public.profiles(id) on delete cascade,
  -- The host's region, for the Family values.
  country    text,
  state      text,
  city       text,
  suburb     text,
  timezone   text not null default 'Asia/Kuala_Lumpur',
  -- An admin's raise of the most members; null: the region's.
  member_cap integer check (member_cap is null or member_cap between 1 and 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.families is 'Family (0317): one per host. Read and written through the family_* functions only.';

create table if not exists public.family_members (
  id                uuid primary key default gen_random_uuid(),
  family_id         uuid not null references public.families(id) on delete cascade,
  kind              text not null default 'member' check (kind in ('member', 'child')),
  -- The member's account once they join; never set for a child.
  profile_id        uuid references public.profiles(id) on delete set null,
  status            text not null default 'invited'
                      check (status in ('invited', 'active', 'declined', 'left', 'removed', 'expired')),
  name              text not null check (char_length(btrim(name)) between 1 and 80),
  relation          text check (relation is null or char_length(relation) <= 40),
  -- The invited number, digits only with the country code.
  phone_digits      text check (phone_digits is null or phone_digits ~ '^[0-9]{6,15}$'),
  birth_date        date,
  photo_url         text check (photo_url is null or char_length(photo_url) <= 1000),
  -- Limits the host sets: null monthly = the region's highest; null per ride = none.
  monthly_limit     numeric(10,2) check (monthly_limit is null or monthly_limit >= 0),
  per_ride_limit    numeric(10,2) check (per_ride_limit is null or per_ride_limit > 0),
  -- The modules the host allows; null = every module the admin allows.
  services          text[],
  -- What the host may see: at most the admin's rule.
  location_choice   text not null default 'ride' check (location_choice in ('never', 'ride', 'always')),
  -- A raise the member has not accepted yet; until then the old choice stands.
  location_pending  text check (location_pending is null or location_pending in ('ride', 'always')),
  -- "Always" also needs the member to turn it on.
  share_always_ok   boolean not null default false,
  -- What the member was shown when they joined.
  terms             jsonb,
  invited_at        timestamptz not null default now(),
  expires_at        timestamptz,
  joined_at         timestamptz,
  left_at           timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint family_members_child check (kind = 'member' or (profile_id is null and birth_date is not null)),
  constraint family_members_phone check (kind = 'child' or phone_digits is not null or profile_id is not null)
);
create index if not exists family_members_family_idx on public.family_members (family_id);
create index if not exists family_members_phone_idx on public.family_members (phone_digits) where status = 'invited';
-- A person is a member of one family at a time.
create unique index if not exists family_members_one_family
  on public.family_members (profile_id) where status = 'active' and profile_id is not null;
comment on table public.family_members is
  'Family (0317): members (by phone, joined with consent) and children (no phone, no device) under a host.';

create table if not exists public.family_cap_requests (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  wanted     integer not null check (wanted between 2 and 200),
  reason     text check (reason is null or char_length(reason) <= 300),
  status     text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  decided_by uuid,
  decided_at timestamptz,
  note       text check (note is null or char_length(note) <= 300),
  created_at timestamptz not null default now()
);
create unique index if not exists family_cap_requests_one_open on public.family_cap_requests (family_id)
  where status = 'pending';

create table if not exists public.family_trips (
  trip_id     uuid primary key,
  module_key  text not null,
  family_id   uuid not null references public.families(id) on delete cascade,
  member_id   uuid not null references public.family_members(id) on delete cascade,
  child       boolean not null default false,
  payer_id    uuid not null,
  booked_by   uuid not null,
  -- The member books and the host pays (the payment layer moves the charges).
  family_pays boolean not null default false,
  live_share  boolean not null default false,
  with_adult  boolean not null default false,
  -- The member paid this trip themselves (another method): nothing more moves.
  released_at timestamptz,
  ended_at    timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists family_trips_member_idx on public.family_trips (member_id, created_at desc);
create index if not exists family_trips_family_idx on public.family_trips (family_id, created_at desc);

create table if not exists public.family_spend (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  member_id   uuid not null references public.family_members(id) on delete cascade,
  trip_id     uuid,
  module_key  text,
  -- Spent: positive; a refund: negative.
  amount      numeric(12,2) not null,
  kind        text,
  wallet_tx   uuid,
  created_at  timestamptz not null default now()
);
create index if not exists family_spend_member_idx on public.family_spend (member_id, created_at);
create index if not exists family_spend_trip_idx on public.family_spend (trip_id);

create table if not exists public.family_pickup_codes (
  trip_id     uuid primary key,
  member_id   uuid not null references public.family_members(id) on delete cascade,
  code        text not null check (code ~ '^[0-9]{4}$'),
  tries       integer not null default 0,
  locked_at   timestamptz,
  verified_at timestamptz,
  created_at  timestamptz not null default now()
);

create table if not exists public.family_view_log (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  member_ids  uuid[] not null default '{}',
  admin_id    uuid,
  reason_kind text not null check (reason_kind in ('report', 'sos', 'legal', 'support')),
  reason      text not null check (char_length(btrim(reason)) between 10 and 500),
  viewed_at   timestamptz not null default now()
);
create index if not exists family_view_log_family_idx on public.family_view_log (family_id, viewed_at desc);

do $rls$
declare
  t text;
begin
  foreach t in array array['families', 'family_members', 'family_cap_requests', 'family_trips', 'family_spend',
                           'family_pickup_codes', 'family_view_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
  -- The registry and the values: everyone signed in reads; the Family page's admins write.
  foreach t in array array['booking_modules', 'family_places', 'family_module_rules'] loop
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
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin insert', t, t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.caller_admin_can_write(%L))) with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin update', t, t, t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.caller_admin_can_write(%L)))',
                   t || ' admin delete', t, t);
  end loop;
end
$rls$;

insert into public.admin_table_pages (target, page) values
  ('booking_modules', 'admin-settings-family'),
  ('family_places', 'admin-settings-family'),
  ('family_module_rules', 'admin-settings-family'),
  ('rpc:family_admin_write', 'admin-settings-family')
on conflict do nothing;

-- ---- Helpers ------------------------------------------------------------------------------------
-- A phone number as digits with the country code (a Malaysian 0… gets 60).
create or replace function public.family_phone_digits(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when d = '' then null when d like '0%' then '60' || substr(d, 2) else d end
    from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') d) x;
$$;

create or replace function public.family_place_of(f public.families)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('country', f.country, 'state', f.state, 'city', f.city, 'suburb', f.suburb);
$$;

create or replace function public.family_settings_for(p_family uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.family_settings_at(public.family_place_of(f)) from public.families f where f.id = p_family;
$$;
revoke execute on function public.family_settings_for(uuid) from public, anon, authenticated;

create or replace function public.family_cap(p_family uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(f.member_cap, (public.family_settings_at(public.family_place_of(f))->>'maxMembers')::integer, 6)
    from public.families f where f.id = p_family;
$$;
revoke execute on function public.family_cap(uuid) from public, anon, authenticated;

-- Members and children who count toward the cap: active, and invites not yet expired.
create or replace function public.family_count(p_family uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from public.family_members m
   where m.family_id = p_family
     and (m.status = 'active' or (m.status = 'invited' and coalesce(m.expires_at, now()) > now()));
$$;
revoke execute on function public.family_count(uuid) from public, anon, authenticated;

-- The start of this month in the family's time zone.
create or replace function public.family_month_start(p_family uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select date_trunc('month', now() at time zone coalesce(f.timezone, 'Asia/Kuala_Lumpur'))
           at time zone coalesce(f.timezone, 'Asia/Kuala_Lumpur')
    from public.families f where f.id = p_family;
$$;
revoke execute on function public.family_month_start(uuid) from public, anon, authenticated;

create or replace function public.family_month_spent(p_member uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(s.amount), 0)
    from public.family_spend s
    join public.family_members m on m.id = s.member_id
   where s.member_id = p_member and s.created_at >= public.family_month_start(m.family_id);
$$;
revoke execute on function public.family_month_spent(uuid) from public, anon, authenticated;

-- The member's monthly limit: their own, never above the region's highest.
create or replace function public.family_month_limit(p_member uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select least(coalesce(m.monthly_limit, (s->>'monthCap')::numeric), (s->>'monthCap')::numeric)
    from public.family_members m
    cross join lateral (select public.family_settings_for(m.family_id) s) x
   where m.id = p_member;
$$;
revoke execute on function public.family_month_limit(uuid) from public, anon, authenticated;

create or replace function public.family_month_left(p_member uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, round(public.family_month_limit(p_member) - public.family_month_spent(p_member), 2));
$$;
revoke execute on function public.family_month_left(uuid) from public, anon, authenticated;

-- The location rule in force for a member: the host's choice, never above the
-- admin's rule; "always" only while the member has turned it on, else "ride".
create or replace function public.family_location_rule(p_member uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.family_members;
  v_admin text;
  v_rank integer;
begin
  select * into m from public.family_members where id = p_member;
  if not found or m.status <> 'active' then
    return 'never';
  end if;
  v_admin := coalesce(public.family_settings_for(m.family_id)->>'locationRule', 'ride');
  v_rank := least(case v_admin when 'never' then 0 when 'ride' then 1 else 2 end,
                  case m.location_choice when 'never' then 0 when 'ride' then 1 else 2 end);
  if v_rank = 2 and m.kind = 'member' and not m.share_always_ok then
    v_rank := 1;
  end if;
  return case v_rank when 0 then 'never' when 1 then 'ride' else 'always' end;
end;
$$;
revoke execute on function public.family_location_rule(uuid) from public, anon, authenticated;

-- A refusal for the app: {ok false, code, message}.
create or replace function public.family_no(p_code text, p_message text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('ok', false, 'code', p_code, 'message', p_message);
$$;

create or replace function public.family_money(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'RM ' || case when p = trunc(p) then trunc(p)::text else to_char(p, 'FM999999990.00') end;
$$;

-- ---- 5. Who pays --------------------------------------------------------------------------------
-- [p_owner] books on [p_module] at [p_place] for [p_passenger] (a
-- family_members id; null: themselves) for about [p_amount]. Options:
-- {withAdult: true} when an adult rides with a child.
create or replace function public.family_payer_for(p_module text, p_owner uuid, p_passenger uuid,
                                                   p_amount numeric, p_place jsonb default '{}'::jsonb,
                                                   p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.family_members;
  f public.families;
  s jsonb;
  rule jsonb := public.family_module_rule_at(p_module, p_place);
  v_left numeric;
  v_age integer;
  v_host text;
begin
  if p_owner is null then
    return public.family_no('FAMILY_NOT_MEMBER', 'Sign in to use Family.');
  end if;
  if p_passenger is null then
    select * into m from public.family_members
     where profile_id = p_owner and status = 'active' and kind = 'member' limit 1;
    if not found then
      return public.family_no('FAMILY_NOT_MEMBER', 'You are not in a family that pays for you.');
    end if;
  else
    select * into m from public.family_members where id = p_passenger and status = 'active';
    if not found then
      return public.family_no('FAMILY_NOT_MEMBER', 'This person is not in your family now.');
    end if;
  end if;
  select * into f from public.families where id = m.family_id;
  s := public.family_settings_at(public.family_place_of(f));
  select coalesce(nullif(btrim(p.name), ''), 'Your family host') into v_host from public.profiles p where p.id = f.host_id;
  if not coalesce((s->>'enabled')::boolean, true) then
    return public.family_no('FAMILY_OFF', 'Family isn''t available in your area.');
  end if;
  if m.services is not null and not (p_module = any (m.services)) then
    return public.family_no('FAMILY_SERVICE_NOT_ALLOWED', 'Your family doesn''t cover this service.');
  end if;

  if p_passenger is null then
    if f.host_id = p_owner then
      return public.family_no('FAMILY_NOT_MEMBER', 'Pay with your own GET.wallet.');
    end if;
    if not coalesce((rule->>'familyPays')::boolean, false) then
      return public.family_no('FAMILY_MODULE_OFF', 'Family payment isn''t available for this service.');
    end if;
    if m.per_ride_limit is not null and coalesce(p_amount, 0) > m.per_ride_limit then
      return public.family_no('FAMILY_RIDE_LIMIT',
        format('Family pays up to %s a trip for you.', public.family_money(m.per_ride_limit)));
    end if;
    v_left := public.family_month_left(m.id);
    if coalesce(p_amount, 0) > v_left then
      return public.family_no('FAMILY_LIMIT_REACHED',
        format('Your family limit has %s left this month.', public.family_money(v_left)));
    end if;
    return jsonb_build_object('ok', true, 'payer', f.host_id, 'familyId', f.id, 'memberId', m.id,
                              'child', false, 'familyPays', true, 'hostName', v_host, 'left', v_left,
                              'liveShare', coalesce((rule->>'liveShare')::boolean, false));
  end if;

  -- The host books for a member or a child and pays as for themselves.
  if f.host_id is distinct from p_owner then
    return public.family_no('FAMILY_NOT_HOST', 'Only the family host books for family members.');
  end if;
  if m.kind = 'child' then
    if not coalesce((s->>'children')::boolean, true) then
      return public.family_no('FAMILY_CHILDREN_OFF', 'Rides for children aren''t available in your area.');
    end if;
    if not coalesce((rule->>'childAllowed')::boolean, false) then
      return public.family_no('FAMILY_CHILD_NOT_ALLOWED', 'Children can''t be booked on this service.');
    end if;
    v_age := extract(year from age(current_date, m.birth_date))::integer;
    if v_age < coalesce((s->>'aloneAge')::integer, 12) and not coalesce((p_options->>'withAdult')::boolean, false) then
      return public.family_no('FAMILY_CHILD_TOO_YOUNG',
        format('Children under %s ride with an adult.', coalesce((s->>'aloneAge')::integer, 12)));
    end if;
  elsif not coalesce((rule->>'bookForMember')::boolean, false) then
    return public.family_no('FAMILY_BOOK_FOR_OFF', 'Booking for a family member isn''t available for this service.');
  end if;
  return jsonb_build_object('ok', true, 'payer', p_owner, 'familyId', f.id, 'memberId', m.id,
                            'child', m.kind = 'child', 'familyPays', false, 'hostName', v_host,
                            'age', v_age, 'withAdult', coalesce((p_options->>'withAdult')::boolean, false),
                            'liveShare', coalesce((rule->>'liveShare')::boolean, false));
end;
$$;
revoke execute on function public.family_payer_for(text, uuid, uuid, numeric, jsonb, jsonb) from public, anon;
grant execute on function public.family_payer_for(text, uuid, uuid, numeric, jsonb, jsonb) to authenticated;

-- A new 4-digit pickup code for a child's trip (tries reset).
create or replace function public.family_new_code(p_trip uuid, p_member uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := lpad((floor(random() * 10000))::integer::text, 4, '0');
begin
  insert into public.family_pickup_codes as c (trip_id, member_id, code)
  values (p_trip, p_member, v_code)
  on conflict (trip_id) do update set code = excluded.code, tries = 0, locked_at = null, created_at = now()
    where c.verified_at is null;
  return v_code;
end;
$$;
revoke execute on function public.family_new_code(uuid, uuid) from public, anon, authenticated;

-- Registers [p_trip] of [p_module] as a Family booking, or raises the refusal
-- code (hint: the words for the rider). [p_family_pays]: the booker asked the
-- family to pay (the member's own trip); with a passenger the host books.
-- Nothing to do (no Family asked): null.
create or replace function public.family_attach_trip(p_module text, p_trip uuid, p_owner uuid, p_passenger uuid,
                                                     p_amount numeric, p_place jsonb, p_options jsonb,
                                                     p_family_pays boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_name text;
begin
  if p_trip is null or (p_passenger is null and not coalesce(p_family_pays, false)) then
    return null;
  end if;
  if p_passenger is not null and coalesce(p_family_pays, false) then
    raise exception 'FAMILY_ONLY_FOR_MEMBER' using errcode = 'P0001',
      hint = 'Family payment is for a member''s own trip. The host pays a trip they book for someone.';
  end if;
  v := public.family_payer_for(p_module, p_owner, p_passenger, p_amount, p_place, coalesce(p_options, '{}'::jsonb));
  if not coalesce((v->>'ok')::boolean, false) then
    raise exception '%', v->>'code' using errcode = 'P0001', hint = v->>'message';
  end if;
  insert into public.family_trips (trip_id, module_key, family_id, member_id, child, payer_id, booked_by,
                                   family_pays, live_share, with_adult)
  values (p_trip, p_module, (v->>'familyId')::uuid, (v->>'memberId')::uuid, (v->>'child')::boolean,
          (v->>'payer')::uuid, p_owner, (v->>'familyPays')::boolean, (v->>'liveShare')::boolean,
          coalesce((v->>'withAdult')::boolean, false))
  on conflict (trip_id) do nothing;
  if (v->>'child')::boolean then
    perform public.family_new_code(p_trip, (v->>'memberId')::uuid);
  elsif p_passenger is not null then
    -- A member the host booked for is told.
    select coalesce(nullif(btrim(p.name), ''), 'Your family host') into v_name
      from public.profiles p where p.id = p_owner;
    perform public.enqueue_notification(
      (select profile_id from public.family_members where id = p_passenger),
      'family:' || p_trip || ':booked', 'family', 'normal',
      'A trip booked for you', v_name || ' booked a trip for you with Family.',
      jsonb_build_object('route', '/account/family', 'trip', p_trip), null);
  end if;
  return v;
end;
$$;
revoke execute on function public.family_attach_trip(text, uuid, uuid, uuid, numeric, jsonb, jsonb, boolean)
  from public, anon, authenticated;

-- Whether the family can still pay [p_amount] more on [p_trip] for
-- [p_user]: 'ok', or the reason it can't ('FAMILY_NOT_FAMILY_TRIP' when the
-- trip isn't one the family pays for this user, or the member paid it
-- themselves).
create or replace function public.family_trip_state(p_trip uuid, p_user uuid, p_amount numeric)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  m public.family_members;
  v_trip numeric;
begin
  select * into t from public.family_trips where trip_id = p_trip;
  if not found or not t.family_pays or t.released_at is not null then
    return 'FAMILY_NOT_FAMILY_TRIP';
  end if;
  select * into m from public.family_members where id = t.member_id;
  if m.profile_id is distinct from p_user then
    return 'FAMILY_NOT_FAMILY_TRIP';
  end if;
  if m.status <> 'active' then
    return 'FAMILY_NOT_MEMBER';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return 'ok';
  end if;
  if m.per_ride_limit is not null then
    select coalesce(sum(amount), 0) into v_trip from public.family_spend where trip_id = p_trip;
    if v_trip + p_amount > m.per_ride_limit + 0.005 then
      return 'FAMILY_RIDE_LIMIT';
    end if;
  end if;
  if p_amount > public.family_month_left(m.id) + 0.005 then
    return 'FAMILY_LIMIT_REACHED';
  end if;
  return 'ok';
end;
$$;
revoke execute on function public.family_trip_state(uuid, uuid, numeric) from public, anon, authenticated;

-- Whose GET.wallet pays [p_amount] on [p_trip] that [p_user] would pay: the
-- host's while the family pays and it is within the limits, else theirs.
create or replace function public.family_wallet_owner(p_trip uuid, p_user uuid, p_amount numeric)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case when public.family_trip_state(p_trip, p_user, p_amount) = 'ok'
              then (select payer_id from public.family_trips where trip_id = p_trip) else p_user end;
$$;
revoke execute on function public.family_wallet_owner(uuid, uuid, numeric) from public, anon, authenticated;

-- Records [p_amount] spent by the family on [p_trip] (negative: a refund).
-- Raises the limit code when it doesn't fit. {payer, left}.
create or replace function public.family_charge(p_trip uuid, p_amount numeric, p_kind text default null,
                                                p_wallet_tx uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  m public.family_members;
  v_state text;
begin
  select * into t from public.family_trips where trip_id = p_trip;
  if not found then
    raise exception 'FAMILY_NOT_FAMILY_TRIP' using errcode = 'P0001';
  end if;
  select * into m from public.family_members where id = t.member_id;
  v_state := public.family_trip_state(p_trip, m.profile_id, p_amount);
  if v_state <> 'ok' then
    raise exception '%', v_state using errcode = 'P0001',
      hint = case v_state when 'FAMILY_LIMIT_REACHED' then 'The family limit for this month is used up.'
                          when 'FAMILY_RIDE_LIMIT' then 'This is over the family limit for one trip.'
                          else 'The family doesn''t pay for this trip.' end;
  end if;
  insert into public.family_spend (family_id, member_id, trip_id, module_key, amount, kind, wallet_tx)
  values (t.family_id, t.member_id, p_trip, t.module_key, round(p_amount, 2), p_kind, p_wallet_tx);
  return jsonb_build_object('payer', t.payer_id, 'left', public.family_month_left(m.id));
end;
$$;
revoke execute on function public.family_charge(uuid, numeric, text, uuid) from public, anon, authenticated;

-- The member pays this trip themselves from now on.
create or replace function public.family_release_trip(p_trip uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.family_trips set released_at = coalesce(released_at, now()) where trip_id = p_trip and family_pays;
$$;
revoke execute on function public.family_release_trip(uuid) from public, anon, authenticated;

-- ---- 6. The payment layer: charges on a family-paid trip go to the host ------------------------
create or replace function public.family_wallet_redirect()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  v_member uuid;
  v_name text;
  v_paid numeric;
begin
  if new.wallet_type <> 'get_wallet' or new.ride_id is null or coalesce(new.amount, 0) = 0 then
    return new;
  end if;
  select * into t from public.family_trips where trip_id = new.ride_id and family_pays and released_at is null;
  if not found then
    return new;
  end if;
  select profile_id, name into v_member, v_name from public.family_members where id = t.member_id;
  if v_member is distinct from new.user_id then
    return new;
  end if;
  if new.amount < 0 then
    if public.family_trip_state(new.ride_id, new.user_id, -new.amount) <> 'ok' then
      return new;  -- over the limits, or no longer a member: the member's own wallet
    end if;
    perform public.family_charge(new.ride_id, -new.amount, coalesce(new.method, new.kind), new.id);
  else
    -- Money that is the member's own, not a refund of what the family paid:
    -- the cash on delivery for their item (0312), a cover claim on it (0312),
    -- what a driver pays them for giving their trip up (0309).
    if new.kind in ('cod_payout', 'cover_claim', 'c2c_giveup_comp') then
      return new;
    end if;
    -- A refund goes back to whoever paid, up to what the family paid on the
    -- trip, even when the member has left the family since.
    select coalesce(sum(amount), 0) into v_paid from public.family_spend where trip_id = new.ride_id;
    if v_paid + 0.005 < new.amount then
      return new;
    end if;
    insert into public.family_spend (family_id, member_id, trip_id, module_key, amount, kind, wallet_tx)
    values (t.family_id, t.member_id, new.ride_id, t.module_key, -round(new.amount, 2),
            coalesce(new.method, new.kind), new.id);
  end if;
  new.user_id := t.payer_id;
  new.note := left('Family · ' || coalesce(v_name, 'member') || ' · ' || coalesce(new.note, new.kind), 500);
  return new;
end;
$$;
revoke execute on function public.family_wallet_redirect() from public, anon, authenticated;

-- Before the frozen-account guard (trg_wallet_tx_0_frozen) and the balance (trg_wallet_tx_apply).
drop trigger if exists trg_wallet_tx_00_family on public.wallet_transactions;
create trigger trg_wallet_tx_00_family
  before insert on public.wallet_transactions
  for each row execute function public.family_wallet_redirect();

-- As 0174, plus: 'family' pays from the family host's GET.wallet within the
-- member's limits (FAMILY_LIMIT_REACHED, FAMILY_RIDE_LIMIT, FAMILY_NOT_MEMBER,
-- FAMILY_NOT_FAMILY_TRIP); any other method on a family-paid trip means the
-- member pays it themselves (the trip is released). Rows name the trip.
create or replace function public.ride_pay(p_ride uuid, p_method text, p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_due numeric;
  v_rate numeric;
  v_coins numeric;
  v_balance numeric;
  v_owner uuid;
  v_state text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_method not in ('get_wallet', 'get_coin', 'family') then
    raise exception 'invalid_method';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized';
  end if;
  if r.status <> 'completed' then
    raise exception 'ride_not_completed';
  end if;
  if r.payment_status = 'paid' then
    return jsonb_build_object('paid', coalesce(r.paid_amount, 0), 'method', r.paid_method, 'already', true);
  end if;
  if r.partner_id is null then
    raise exception 'no_driver';
  end if;

  v_due := public.ride_left_to_pay(r);
  if not public.ride_money_ok(v_due) then
    raise exception 'invalid_amount';
  end if;

  if p_expected is not null and abs(round(p_expected, 2) - v_due) > 0.005 then
    raise exception 'amount_changed' using hint = v_due::text;
  end if;

  v_owner := r.rider_id;
  if p_method = 'family' then
    v_state := public.family_trip_state(r.id, r.rider_id, v_due);
    if v_state <> 'ok' then
      raise exception '%', v_state using errcode = 'P0001',
        hint = case v_state when 'FAMILY_LIMIT_REACHED' then 'The family limit for this month doesn''t cover this trip.'
                            when 'FAMILY_RIDE_LIMIT' then 'This trip is over the family limit for one trip.'
                            when 'FAMILY_NOT_MEMBER' then 'You are no longer in the family.'
                            else 'The family doesn''t pay for this trip.' end;
    end if;
    v_owner := public.family_wallet_owner(r.id, r.rider_id, v_due);
  else
    perform public.family_release_trip(r.id);
  end if;

  if v_due > 0 and p_method in ('get_wallet', 'family') then
    insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
      on conflict (user_id, wallet_type) do nothing;
    select balance into v_balance from public.wallets
     where user_id = v_owner and wallet_type = 'get_wallet' for update;
    if coalesce(v_balance, 0) < v_due then
      raise exception 'insufficient_balance';
    end if;
    -- Charged to the rider and tagged with the trip: the family layer moves it to the host.
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
      (r.rider_id, 'get_wallet', 'ride_payment', -v_due, 'ride',
       'Ride paid — RM' || to_char(v_due, 'FM999999990.00'), r.id),
      (r.partner_id, 'get_wallet', 'ride_earning', v_due, 'ride',
       'Ride fare received — RM' || to_char(v_due, 'FM999999990.00'), r.id);
  elsif v_due > 0 and p_method = 'get_coin' then
    select coins_per_currency into v_rate from public.get_coin_settings where id = 'master';
    if coalesce(v_rate, 0) <= 0 then
      raise exception 'coins_unavailable';
    end if;
    v_coins := ceil(v_due * v_rate * 100) / 100;
    insert into public.wallets (user_id, wallet_type, balance) values (r.rider_id, 'get_coin', 0)
      on conflict (user_id, wallet_type) do nothing;
    select balance into v_balance from public.wallets
     where user_id = r.rider_id and wallet_type = 'get_coin' for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_balance';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
      (r.rider_id, 'get_coin', 'redeem', -v_coins, 'ride_fare',
       'Ride fare — RM' || to_char(v_due, 'FM999999990.00') || ' paid with coins'),
      (r.partner_id, 'get_wallet', 'ride_coin_payout', v_due, 'ride_fare',
       'Ride fare paid with GET.coin — RM' || to_char(v_due, 'FM999999990.00'));
  end if;

  update public.ride_requests
     set payment_status = 'paid',
         paid_method = case when p_method = 'family' then 'get_wallet' else p_method end,
         paid_amount = v_due,
         paid_at = now(),
         fare_coins_value = case when p_method = 'get_coin' then coalesce(fare_coins_value, 0) + v_due else fare_coins_value end,
         fare_coins_used = case when p_method = 'get_coin' then coalesce(fare_coins_used, 0) + coalesce(v_coins, 0) else fare_coins_used end,
         fare_coins_redeemed_at = coalesce(fare_coins_redeemed_at, now())
   where id = p_ride;

  return jsonb_build_object('paid', v_due, 'method', p_method, 'coins', coalesce(v_coins, 0),
                            'family', p_method = 'family');
end;
$$;
revoke execute on function public.ride_pay(uuid, text, numeric) from public, anon;
grant execute on function public.ride_pay(uuid, text, numeric) to authenticated;

-- As 0269, with the payer's wallet (the family host's on a family-paid trip)
-- checked and the trip named on the rider's row.
create or replace function public.ride_fee_take(r public.ride_requests, p_amount numeric, p_kind text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric := case when r.commission_rate >= 0 and r.commission_rate < 1 then r.commission_rate else 0 end;
  v_balance numeric;
  v_owner uuid;
  v_label text := case p_kind when 'no_show' then 'No-show fee'
                              when 'arrived_cancel' then 'Cancelled after the driver arrived'
                              else 'Late cancellation fee' end;
begin
  if v_amount <= 0 or r.rider_id is null or r.partner_id is null then
    return 'none';
  end if;
  v_owner := public.family_wallet_owner(r.id, r.rider_id, v_amount);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_balance from public.wallets w
   where w.user_id = v_owner and w.wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_amount then
    insert into public.rider_fee_dues (rider_id, partner_id, ride_id, kind, amount, commission_rate)
    values (r.rider_id, r.partner_id, r.id, p_kind, v_amount, v_rate)
    on conflict (ride_id) do nothing;
    return 'due';
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
    (r.rider_id, 'get_wallet', 'payment', -v_amount, 'cancellation_fee', v_label, r.id),
    (r.partner_id, 'get_wallet', 'cancellation_fee', round(v_amount * (1 - v_rate), 2), 'cancellation_fee',
     v_label || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end, r.id);
  return 'charged';
end;
$$;
revoke execute on function public.ride_fee_take(public.ride_requests, numeric, text) from public, anon, authenticated;

-- As 0307, the same way.
create or replace function public.c2c_fee_take(b public.c2c_bookings, p_amount numeric)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric := case when b.commission_rate >= 0 and b.commission_rate < 1 then b.commission_rate else 0 end;
  v_balance numeric;
  v_owner uuid;
  v_label text := 'City to City cancellation fee ' || b.ref;
begin
  if v_amount <= 0 or b.rider_id is null or b.driver_id is null then
    return 'none';
  end if;
  v_owner := public.family_wallet_owner(b.id, b.rider_id, v_amount);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_balance from public.wallets w
   where w.user_id = v_owner and w.wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_amount then
    return 'due';
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
    (b.rider_id, 'get_wallet', 'payment', -v_amount, 'cancellation_fee', v_label, b.id),
    (b.driver_id, 'get_wallet', 'cancellation_fee', round(v_amount * (1 - v_rate), 2), 'cancellation_fee',
     v_label || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end, b.id);
  return 'charged';
end;
$$;
revoke execute on function public.c2c_fee_take(public.c2c_bookings, numeric) from public, anon, authenticated;

-- ---- 7. The modules on main ---------------------------------------------------------------------
-- {passenger: family_members id, withAdult: bool} on a booking; null: none.
alter table public.ride_requests add column if not exists family jsonb;
alter table public.c2c_bookings add column if not exists family jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_family_check;
alter table public.ride_requests add constraint ride_requests_family_check
  check (family is null or (jsonb_typeof(family) = 'object' and pg_column_size(family) <= 512));
alter table public.c2c_bookings drop constraint if exists c2c_bookings_family_check;
alter table public.c2c_bookings add constraint c2c_bookings_family_check
  check (family is null or (jsonb_typeof(family) = 'object' and pg_column_size(family) <= 512));
-- City to City: Family is an in-app way to pay.
alter table public.c2c_bookings drop constraint if exists c2c_bookings_payment_check;
alter table public.c2c_bookings add constraint c2c_bookings_payment_check
  check (payment in ('in_app', 'cash', 'family'));

create or replace function public.family_passenger_of(p jsonb)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case when coalesce(p->>'passenger', '') ~ '^[0-9a-fA-F-]{36}$' then (p->>'passenger')::uuid end;
$$;

-- Which module a ride_requests row is.
create or replace function public.family_ride_module(r public.ride_requests)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
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

-- The phone the driver calls for a family trip booked with a name and no
-- phone: a member's own, else the booker's, else the host's (a child has no
-- phone of their own). Null when none of them has one that fits 0107's
-- booked_for_phone (6 to 32 characters).
create or replace function public.family_contact_phone(p_member uuid, p_booker uuid, p_booker_phone text default null)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select x.phone
    from (select 1 as o, nullif(btrim(p.phone), '') as phone
            from public.family_members m join public.profiles p on p.id = m.profile_id
           where m.id = p_member and m.kind = 'member'
          union all
          select 2, nullif(btrim(p_booker_phone), '')
          union all
          select 3, nullif(btrim(p.phone), '') from public.profiles p where p.id = p_booker
          union all
          select 4, nullif(btrim(p.phone), '')
            from public.family_members m join public.families f on f.id = m.family_id
            join public.profiles p on p.id = f.host_id
           where m.id = p_member) x
   where char_length(x.phone) between 6 and 32
   order by x.o
   limit 1;
$$;
revoke execute on function public.family_contact_phone(uuid, uuid, text) from public, anon, authenticated;

-- Fills the contact phone of a family trip booked with a name and no phone,
-- so the request still meets 0107's ride_requests_booked_for_shape when the
-- driver takes it. Runs after trg_ride_requests_zz_privacy (0195/0220): an
-- open request keeps the name and phone aside in ride_request_private, which
-- puts them back on the row at accept, so that is where the phone goes.
create or replace function public.family_fill_contact_phone(r public.ride_requests, p_member uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pv public.ride_request_private;
  v_phone text;
begin
  if r.status = 'open' then
    select * into pv from public.ride_request_private where request_id = r.id;
    if not found or pv.booked_for_name is null or nullif(btrim(pv.booked_for_phone), '') is not null then
      return null;
    end if;
    v_phone := public.family_contact_phone(p_member, r.rider_id, pv.rider_phone);
    if v_phone is not null then
      update public.ride_request_private set booked_for_phone = v_phone, updated_at = now()
       where request_id = r.id;
    end if;
    return v_phone;
  end if;
  if r.booked_for_name is null or nullif(btrim(r.booked_for_phone), '') is not null then
    return null;
  end if;
  return public.family_contact_phone(p_member, r.rider_id, r.rider_phone);
end;
$$;
revoke execute on function public.family_fill_contact_phone(public.ride_requests, uuid) from public, anon, authenticated;

-- A new ride (now, a released booking, Freight, Courier): checked and registered.
create or replace function public.ride_requests_family()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place jsonb := jsonb_build_object('country', new.country, 'state', new.state, 'city', new.city,
                                      'suburb', new.suburb);
  v_pays boolean := lower(btrim(coalesce(new.payment_mode, ''))) = 'family';
  v_passenger uuid := public.family_passenger_of(new.family);
  v_member uuid;
  v_phone text;
  s public.family_trips;
  m public.family_members;
begin
  -- Booked for a member or a child with a name and no phone: the driver
  -- calls the member, else whoever booked it, else the host.
  v_member := coalesce(v_passenger,
    (select t.member_id from public.family_trips t where t.trip_id = new.scheduled_ride_id));
  if v_member is not null then
    v_phone := public.family_fill_contact_phone(new, v_member);
    if v_phone is not null then
      new.booked_for_other := true;
      if new.status is distinct from 'open' then
        new.booked_for_phone := v_phone;
      end if;
    end if;
  end if;
  if new.scheduled_ride_id is not null then
    -- The booking was checked when it was made; its ride carries it on while
    -- the member is still in the family.
    select * into s from public.family_trips where trip_id = new.scheduled_ride_id;
    if found then
      select * into m from public.family_members where id = s.member_id;
      if m.status = 'active' then
        insert into public.family_trips (trip_id, module_key, family_id, member_id, child, payer_id, booked_by,
                                         family_pays, live_share, with_adult)
        values (new.id, s.module_key, s.family_id, s.member_id, s.child, s.payer_id, s.booked_by,
                s.family_pays, s.live_share, s.with_adult)
        on conflict (trip_id) do nothing;
        if s.child then
          perform public.family_new_code(new.id, s.member_id);
        end if;
      end if;
    end if;
    return new;
  end if;
  if not v_pays and v_passenger is null then
    return new;
  end if;
  -- The app books a member or child as for someone else (booked_for_name /
  -- phone, which 0195 keeps aside while the request is open).
  perform public.family_attach_trip(public.family_ride_module(new), new.id, new.rider_id, v_passenger,
                                    coalesce(new.ride_fare, new.fare), v_place, new.family, v_pays);
  return new;
end;
$$;
revoke execute on function public.ride_requests_family() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_zzzzz_family on public.ride_requests;
create trigger trg_ride_requests_zzzzz_family
  before insert on public.ride_requests
  for each row execute function public.ride_requests_family();

-- A scheduled booking: checked and registered when it is made (its ride, at release).
create or replace function public.scheduled_rides_family()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_pays boolean := lower(btrim(coalesce(q->>'payment_mode', ''))) = 'family';
  v_passenger uuid := public.family_passenger_of(q->'family');
  v_module text := case when q ? 'parcel_size' then 'courier'
                        when q ? 'cargo_description' then 'freight' else 'scheduled_ride' end;
begin
  if not v_pays and v_passenger is null then
    return null;
  end if;
  perform public.family_attach_trip(v_module, new.id, new.rider_id, v_passenger, new.fare,
                                    jsonb_build_object('country', q->>'country', 'state', q->>'state',
                                                       'city', q->>'city', 'suburb', q->>'suburb'),
                                    q->'family', v_pays);
  return null;
end;
$$;
revoke execute on function public.scheduled_rides_family() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_family on public.scheduled_rides;
create trigger trg_scheduled_rides_family
  after insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_family();

-- City to City: after its own check (trg_c2c_bookings_check). A seat on a
-- trip a driver posted (0310: trip_id set, made by c2c_book_seat) is the
-- 'seat_trip' module; a whole car, 'city_to_city'.
create or replace function public.c2c_bookings_family()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pays boolean := new.payment = 'family';
  v_passenger uuid := public.family_passenger_of(new.family);
begin
  if not v_pays and v_passenger is null then
    return new;
  end if;
  if v_pays and not coalesce((select pay_in_app from public.city_to_city_settings where id = 1), true) then
    raise exception 'C2C_PAYMENT_NOT_ALLOWED' using errcode = '22023', hint = 'Pay in cash for City to City trips.';
  end if;
  perform public.family_attach_trip(case when new.trip_id is not null then 'seat_trip' else 'city_to_city' end,
                                    new.id, new.rider_id, v_passenger, new.fare,
                                    coalesce(new.pickup_place, '{}'::jsonb), new.family, v_pays);
  return new;
end;
$$;
revoke execute on function public.c2c_bookings_family() from public, anon, authenticated;
drop trigger if exists trg_c2c_bookings_family on public.c2c_bookings;
create trigger trg_c2c_bookings_family
  before insert on public.c2c_bookings
  for each row execute function public.c2c_bookings_family();

-- On any booking table: a child's trip starts only with the pickup code, takes
-- a woman driver where the admin says so, and the family column stays as booked.
create or replace function public.family_trip_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  n jsonb;
  o jsonb;
  v_driver uuid;
  v_old_driver uuid;
  v_status text;
  v_old_status text;
begin
  if new.family is distinct from old.family and auth.uid() is not null then
    raise exception 'FAMILY_FIXED' using errcode = '42501', hint = 'Who the trip is for can''t be changed.';
  end if;
  -- Every update passes here (a driver's position too): only a child's trip reads on.
  select * into t from public.family_trips where trip_id = new.id and child;
  if not found then
    return new;
  end if;
  n := to_jsonb(new);
  o := to_jsonb(old);
  v_status := n->>'status';
  v_old_status := o->>'status';
  v_driver := coalesce((n->>'partner_id')::uuid, (n->>'driver_id')::uuid);
  v_old_driver := coalesce((o->>'partner_id')::uuid, (o->>'driver_id')::uuid);
  if v_driver is not null and v_driver is distinct from v_old_driver
     and coalesce((public.family_settings_for(t.family_id)->>'womenDriversForChildren')::boolean, false)
     and coalesce((select p.gender::text from public.profiles p where p.id = v_driver), '') <> 'female' then
    raise exception 'FAMILY_WOMEN_DRIVERS_ONLY' using errcode = 'P0001',
      hint = 'This is a child''s trip: only women drivers take it.';
  end if;
  if v_status = 'on_trip' and v_old_status is distinct from 'on_trip'
     and not exists (select 1 from public.family_pickup_codes c where c.trip_id = new.id and c.verified_at is not null) then
    raise exception 'FAMILY_PICKUP_CODE_NEEDED' using errcode = 'P0001',
      hint = 'Ask the child for the 4-digit pickup code before the trip starts.';
  end if;
  return new;
end;
$$;
revoke execute on function public.family_trip_guard() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_zzzzz_family_guard on public.ride_requests;
create trigger trg_ride_requests_zzzzz_family_guard
  before update on public.ride_requests
  for each row execute function public.family_trip_guard();
drop trigger if exists trg_c2c_bookings_family_guard on public.c2c_bookings;
create trigger trg_c2c_bookings_family_guard
  before update on public.c2c_bookings
  for each row execute function public.family_trip_guard();

-- The host hears of a child's trip: driver on the way, picked up, dropped
-- off, cancelled. A trip that ends stops sharing.
create or replace function public.family_trip_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  v_status text := to_jsonb(new)->>'status';
  v_name text;
  v_title text;
  v_body text;
begin
  select * into t from public.family_trips where trip_id = new.id;
  if not found or v_status is not distinct from (to_jsonb(old)->>'status') then
    return null;
  end if;
  -- 'declined': a seat request the driver turned down (0310).
  if v_status in ('completed', 'cancelled', 'expired', 'declined') then
    update public.family_trips set ended_at = coalesce(ended_at, now()) where trip_id = new.id;
  end if;
  if not t.child then
    return null;
  end if;
  select split_part(name, ' ', 1) into v_name from public.family_members where id = t.member_id;
  case v_status
    when 'accepted', 'booked' then v_title := v_name || '''s driver is on the way';
      v_body := 'Give ' || v_name || ' the pickup code. The trip can''t start without it.';
    when 'on_trip' then v_title := v_name || ' was picked up';
      v_body := 'You can follow the trip in the app until drop-off.';
    when 'completed' then v_title := v_name || ' was dropped off';
      v_body := 'The trip has ended.';
    when 'cancelled', 'expired', 'declined' then v_title := v_name || '''s trip was cancelled';
      v_body := 'Book again if they still need a ride.';
    else return null;
  end case;
  perform public.enqueue_notification(t.payer_id, 'family:' || new.id || ':' || v_status, 'family',
                                      case when v_status in ('on_trip', 'completed') then 'critical' else 'normal' end,
                                      v_title, v_body, jsonb_build_object('route', '/account/family', 'trip', new.id),
                                      case when tg_table_name = 'ride_requests' then new.id end);
  return null;
end;
$$;
revoke execute on function public.family_trip_events() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_family_events on public.ride_requests;
create trigger trg_ride_requests_family_events
  after update of status on public.ride_requests
  for each row execute function public.family_trip_events();
drop trigger if exists trg_c2c_bookings_family_events on public.c2c_bookings;
create trigger trg_c2c_bookings_family_events
  after update of status on public.c2c_bookings
  for each row execute function public.family_trip_events();

-- As 0313 (0268, 0312's add-ons and 0313's business keys), plus 'family'
-- (who the booking is for), so a scheduled booking keeps it.
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
       'stand_platform_fee_value', 'dispatch_booked_via', 'share_token',
       -- 0267: the cargo of a freight booking, its declared value and
       -- the recipient told when the trip starts.
       'cargo_description', 'cargo_photo_path', 'declared_value', 'prohibited_ack',
       'recipient_name', 'recipient_phone',
       -- 0268: a courier booking's parcel size and who pays.
       'parcel_size', 'payer',
       -- 0312: the add-ons booked (the server's own columns are set at release).
       'parcel_cover', 'round_trip', 'stairs_pickup', 'stairs_drop', 'cold_level', 'cod_amount',
       -- 0313: the business account it is charged to, and its note (the
       -- approval is the server's: scheduled_rides_business sets it).
       'business_account_id', 'business_note', 'business_approval_id',
       -- 0317: who it is for in the family.
       'family'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- ---- Children: the pickup code ------------------------------------------------------------------
-- The host reads their child's code (and how many tries are left).
create or replace function public.family_child_code(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  c public.family_pickup_codes;
begin
  select * into t from public.family_trips where trip_id = p_trip and child;
  if not found or t.payer_id is distinct from auth.uid() then
    return null;
  end if;
  select * into c from public.family_pickup_codes where trip_id = p_trip;
  return jsonb_build_object('code', c.code, 'verified', c.verified_at is not null, 'locked', c.locked_at is not null,
                            'tries', c.tries,
                            'triesLeft', greatest(0, coalesce((public.family_settings_for(t.family_id)->>'codeTries')::integer, 3) - c.tries),
                            'name', (select name from public.family_members where id = t.member_id));
end;
$$;
revoke execute on function public.family_child_code(uuid) from public, anon;
grant execute on function public.family_child_code(uuid) to authenticated;

-- The host makes a new code (after a lock, or if the child forgot it).
create or replace function public.family_child_code_new(p_trip uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.family_trips;
begin
  select * into t from public.family_trips where trip_id = p_trip and child;
  if not found or t.payer_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if exists (select 1 from public.family_pickup_codes where trip_id = p_trip and verified_at is not null) then
    raise exception 'FAMILY_CODE_USED' using errcode = 'P0001', hint = 'The child was already picked up.';
  end if;
  perform public.family_new_code(p_trip, t.member_id);
  return public.family_child_code(p_trip);
end;
$$;
revoke execute on function public.family_child_code_new(uuid) from public, anon;
grant execute on function public.family_child_code_new(uuid) to authenticated;

-- The trip's driver: who the child is (name, age, photo, who booked).
create or replace function public.family_trip_driver(p_trip uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select partner_id from public.ride_requests where id = p_trip),
                  (select driver_id from public.c2c_bookings where id = p_trip));
$$;
revoke execute on function public.family_trip_driver(uuid) from public, anon, authenticated;

create or replace function public.family_driver_child(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  m public.family_members;
  c public.family_pickup_codes;
begin
  select * into t from public.family_trips where trip_id = p_trip and child;
  if not found or auth.uid() is null or public.family_trip_driver(p_trip) is distinct from auth.uid() then
    return null;
  end if;
  select * into m from public.family_members where id = t.member_id;
  select * into c from public.family_pickup_codes where trip_id = p_trip;
  return jsonb_build_object(
    'name', m.name, 'age', extract(year from age(current_date, m.birth_date))::integer, 'photoUrl', m.photo_url,
    'bookedBy', (select coalesce(nullif(btrim(p.name), ''), 'Parent') from public.profiles p where p.id = t.payer_id),
    'relation', m.relation, 'withAdult', t.with_adult,
    'verified', c.verified_at is not null, 'locked', c.locked_at is not null,
    'triesLeft', greatest(0, coalesce((public.family_settings_for(t.family_id)->>'codeTries')::integer, 3) - coalesce(c.tries, 0)));
end;
$$;
revoke execute on function public.family_driver_child(uuid) from public, anon;
grant execute on function public.family_driver_child(uuid) to authenticated;

-- The driver enters the child's code: {ok, triesLeft, locked}. After the
-- last wrong try the code locks, the host is called and the trip waits.
create or replace function public.family_verify_pickup_code(p_trip uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  c public.family_pickup_codes;
  v_max integer;
  v_name text;
begin
  select * into t from public.family_trips where trip_id = p_trip and child;
  if not found or auth.uid() is null or public.family_trip_driver(p_trip) is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into c from public.family_pickup_codes where trip_id = p_trip for update;
  v_max := coalesce((public.family_settings_for(t.family_id)->>'codeTries')::integer, 3);
  if c.verified_at is not null then
    return jsonb_build_object('ok', true, 'triesLeft', greatest(0, v_max - c.tries), 'locked', false);
  end if;
  if c.locked_at is not null then
    return jsonb_build_object('ok', false, 'triesLeft', 0, 'locked', true);
  end if;
  if btrim(coalesce(p_code, '')) = c.code then
    update public.family_pickup_codes set verified_at = now() where trip_id = p_trip;
    return jsonb_build_object('ok', true, 'triesLeft', greatest(0, v_max - c.tries), 'locked', false);
  end if;
  update public.family_pickup_codes set tries = tries + 1,
         locked_at = case when tries + 1 >= v_max then now() end
   where trip_id = p_trip returning * into c;
  if c.locked_at is not null then
    select split_part(name, ' ', 1) into v_name from public.family_members where id = t.member_id;
    perform public.enqueue_notification(t.payer_id, 'family:' || p_trip || ':code-locked:' || c.tries, 'family',
      'critical', 'Call the driver about ' || v_name,
      'The pickup code was wrong ' || c.tries || ' times. The trip waits; give the driver a new code from the app.',
      jsonb_build_object('route', '/account/family', 'trip', p_trip),
      case when exists (select 1 from public.ride_requests where id = p_trip) then p_trip end);
  end if;
  return jsonb_build_object('ok', false, 'triesLeft', greatest(0, v_max - c.tries), 'locked', c.locked_at is not null);
end;
$$;
revoke execute on function public.family_verify_pickup_code(uuid, text) from public, anon;
grant execute on function public.family_verify_pickup_code(uuid, text) to authenticated;

-- ---- Location: the three disclosed ways only ----------------------------------------------------
-- Whether a trip is under way (any module on main).
create or replace function public.family_trip_live(p_trip uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select status in ('open', 'accepted', 'arrived', 'on_trip') from public.ride_requests where id = p_trip),
                  (select status in ('booked', 'driver_arriving', 'on_trip') from public.c2c_bookings where id = p_trip),
                  false);
$$;
revoke execute on function public.family_trip_live(uuid) from public, anon, authenticated;

-- The member's trip the host may follow now (live share on, rule allows).
create or replace function public.family_shared_trip(p_member uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select t.trip_id from public.family_trips t
   where t.member_id = p_member and t.live_share and t.ended_at is null and public.family_trip_live(t.trip_id)
   order by t.created_at desc limit 1;
$$;
revoke execute on function public.family_shared_trip(uuid) from public, anon, authenticated;

-- [p_viewer] may see where [p_member] (a profile) is: themselves; else only
-- their family host, while the member has joined and the rule in force
-- allows it (ride: a shared trip under way; always: the member turned it on).
create or replace function public.family_can_view_location(p_viewer uuid, p_member uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.family_members;
  v_rule text;
begin
  if p_viewer is null or p_member is null then
    return false;
  end if;
  if p_viewer = p_member then
    return true;
  end if;
  select fm.* into m from public.family_members fm
    join public.families f on f.id = fm.family_id
   where fm.profile_id = p_member and fm.status = 'active' and fm.kind = 'member' and f.host_id = p_viewer;
  if not found then
    return false;
  end if;
  v_rule := public.family_location_rule(m.id);
  return v_rule = 'always' or (v_rule = 'ride' and public.family_shared_trip(m.id) is not null);
end;
$$;
revoke execute on function public.family_can_view_location(uuid, uuid) from public, anon, authenticated;

-- What a member's or host's trip screen shows: {family, shared, payer,
-- viewers [{name, what}], left, child}. The chip shows exactly when the host can see.
create or replace function public.family_trip_status(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  m public.family_members;
  v_uid uuid := auth.uid();
  v_host text;
  v_shared boolean;
begin
  select * into t from public.family_trips where trip_id = p_trip;
  if not found or v_uid is null then
    return jsonb_build_object('family', false);
  end if;
  select * into m from public.family_members where id = t.member_id;
  if v_uid is distinct from m.profile_id and v_uid is distinct from t.payer_id and v_uid is distinct from t.booked_by then
    return jsonb_build_object('family', false);
  end if;
  select coalesce(nullif(btrim(p.name), ''), 'Your family host') into v_host
    from public.profiles p join public.families f on f.host_id = p.id where f.id = t.family_id;
  v_shared := m.kind = 'member' and public.family_can_view_location(t.payer_id, m.profile_id)
              and public.family_shared_trip(m.id) = p_trip;
  return jsonb_build_object(
    'family', true, 'child', t.child, 'familyPays', t.family_pays and t.released_at is null,
    'payer', v_host, 'shared', coalesce(v_shared, false),
    'left', case when t.family_pays then public.family_month_left(m.id) end,
    'viewers', case when coalesce(v_shared, false)
                    then jsonb_build_array(jsonb_build_object('name', v_host, 'role', 'host',
                                                              'what', 'Live location until drop-off'))
                    else '[]'::jsonb end);
end;
$$;
revoke execute on function public.family_trip_status(uuid) from public, anon;
grant execute on function public.family_trip_status(uuid) to authenticated;

-- The host's Family viewer: each member they may see now, with the trip or
-- (always) the phone's last place; children's trips under way.
create or replace function public.family_live()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.families;
  m public.family_members;
  v jsonb := '[]'::jsonb;
  v_trip uuid;
  v_item jsonb;
begin
  select * into f from public.families where host_id = auth.uid();
  if not found then
    return v;
  end if;
  for m in select * from public.family_members where family_id = f.id and status = 'active' order by created_at loop
    if m.kind = 'member' and not public.family_can_view_location(f.host_id, m.profile_id) then
      continue;
    end if;
    v_trip := public.family_shared_trip(m.id);
    if m.kind = 'child' and v_trip is null then
      select t.trip_id into v_trip from public.family_trips t
       where t.member_id = m.id and t.ended_at is null and public.family_trip_live(t.trip_id)
       order by t.created_at desc limit 1;
    end if;
    v_item := jsonb_build_object('memberId', m.id, 'name', m.name, 'kind', m.kind);
    if v_trip is not null then
      v_item := v_item || coalesce((
        select jsonb_build_object('trip', r.id, 'status', r.status, 'pickup', r.pickup_name, 'drop', r.drop_name,
                                  'driver', r.partner_name, 'plate', r.partner_plate,
                                  'lat', r.partner_live_lat, 'lng', r.partner_live_lng, 'at', r.partner_live_at)
          from public.ride_requests r where r.id = v_trip),
        (select jsonb_build_object('trip', b.id, 'status', b.status, 'pickup', b.pickup_name, 'drop', b.drop_name)
           from public.c2c_bookings b where b.id = v_trip), '{}'::jsonb);
    elsif m.kind = 'member' and public.family_location_rule(m.id) = 'always' then
      v_item := v_item || coalesce((
        select jsonb_build_object('lat', pt.last_lat, 'lng', pt.last_lng, 'at', pt.located_at,
                                  'area', concat_ws(', ', pt.area_suburb, pt.area_city))
          from public.push_tokens pt
         where pt.profile_id = m.profile_id and pt.located_at is not null
         order by pt.located_at desc limit 1), '{}'::jsonb);
    else
      continue;
    end if;
    v := v || jsonb_build_array(v_item);
  end loop;
  return v;
end;
$$;
revoke execute on function public.family_live() from public, anon;
grant execute on function public.family_live() to authenticated;

-- ---- The app: host and member -------------------------------------------------------------------
create or replace function public.family_member_json(m public.family_members)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', m.id, 'kind', m.kind, 'status',
    case when m.status = 'invited' and m.expires_at <= now() then 'expired' else m.status end,
    'name', m.name, 'relation', m.relation, 'birthDate', m.birth_date, 'photoUrl', m.photo_url,
    'phone', case when m.phone_digits is not null then '+' || m.phone_digits end,
    'monthlyLimit', m.monthly_limit, 'perRideLimit', m.per_ride_limit, 'services', to_jsonb(m.services),
    'location', m.location_choice, 'locationPending', m.location_pending, 'shareAlways', m.share_always_ok,
    'locationNow', public.family_location_rule(m.id),
    'spent', public.family_month_spent(m.id), 'limit', public.family_month_limit(m.id),
    'left', public.family_month_left(m.id),
    'expiresAt', m.expires_at, 'joinedAt', m.joined_at,
    'onTrip', public.family_shared_trip(m.id) is not null
              or (m.kind = 'child' and exists (select 1 from public.family_trips t where t.member_id = m.id
                                                and t.ended_at is null and public.family_trip_live(t.trip_id))));
$$;
revoke execute on function public.family_member_json(public.family_members) from public, anon, authenticated;

-- The caller's family: {role: host | member | none, family, members, me,
-- settings, modules}. [p_place]: the app's area, for someone with no family yet.
create or replace function public.family_mine(p_place jsonb default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  f public.families;
  me public.family_members;
  v_role text := 'none';
  v_place jsonb := public.family_default_place(coalesce(p_place, '{}'::jsonb));
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into f from public.families where host_id = v_uid;
  if found then
    v_role := 'host';
  else
    select * into me from public.family_members where profile_id = v_uid and status = 'active' limit 1;
    if found then
      v_role := 'member';
      select * into f from public.families where id = me.family_id;
    end if;
  end if;
  if f.id is not null then
    v_place := public.family_place_of(f);
  end if;
  return jsonb_build_object(
    'role', v_role,
    'family', case when f.id is null then null else jsonb_build_object(
      'id', f.id, 'hostName', (select coalesce(nullif(btrim(name), ''), 'Family host') from public.profiles where id = f.host_id),
      'cap', public.family_cap(f.id), 'count', public.family_count(f.id),
      'spent', (select coalesce(sum(s.amount), 0) from public.family_spend s
                 where s.family_id = f.id and s.created_at >= public.family_month_start(f.id)),
      'capRequest', (select jsonb_build_object('id', r.id, 'wanted', r.wanted, 'status', r.status, 'note', r.note)
                       from public.family_cap_requests r where r.family_id = f.id order by r.created_at desc limit 1),
      'place', v_place) end,
    'members', case when v_role = 'host' then coalesce((
      select jsonb_agg(public.family_member_json(m) order by m.kind, m.created_at)
        from public.family_members m
       where m.family_id = f.id and m.status in ('invited', 'active')), '[]'::jsonb) else '[]'::jsonb end,
    'me', case when v_role = 'member' then public.family_member_json(me) end,
    'settings', public.family_settings_at(v_place),
    'modules', public.family_modules_at(v_place));
end;
$$;
revoke execute on function public.family_mine(jsonb) from public, anon;
grant execute on function public.family_mine(jsonb) to authenticated;

-- The caller's area when the app gives none: the phone's last area
-- (push_set_location, 0168), else the profile's country, else Malaysia.
create or replace function public.family_default_place(p_place jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when coalesce(btrim(p_place->>'country'), '') <> '' then p_place
    else coalesce(
      (select jsonb_build_object('country', t.area_country, 'state', t.area_state, 'city', t.area_city,
                                 'suburb', t.area_suburb)
         from public.push_tokens t
        where t.profile_id = auth.uid() and coalesce(t.area_country, '') <> ''
        order by t.located_at desc nulls last limit 1),
      jsonb_build_object('country', coalesce(nullif(btrim((select nationality from public.profiles
                                                            where id = auth.uid())), ''), 'Malaysia')))
  end;
$$;
revoke execute on function public.family_default_place(jsonb) from public, anon, authenticated;

-- The caller's family as host, made on first use in [p_place].
create or replace function public.family_host_family(p_place jsonb)
returns public.families
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.families;
  v_place jsonb;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into f from public.families where host_id = auth.uid();
  if found then
    return f;
  end if;
  if exists (select 1 from public.family_members where profile_id = auth.uid() and status = 'active') then
    raise exception 'FAMILY_ALREADY_MEMBER' using errcode = 'P0001',
      hint = 'You are a member of a family. Leave it first to start your own.';
  end if;
  v_place := public.family_default_place(coalesce(p_place, '{}'::jsonb));
  insert into public.families (host_id, country, state, city, suburb)
  values (auth.uid(), nullif(btrim(v_place->>'country'), ''), nullif(btrim(v_place->>'state'), ''),
          nullif(btrim(v_place->>'city'), ''), nullif(btrim(v_place->>'suburb'), ''))
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.family_host_family(jsonb) from public, anon, authenticated;

-- Checks the host's limits, services and location choice against the region's values.
create or replace function public.family_check_member_values(p_family uuid, p_monthly numeric, p_per_ride numeric,
                                                             p_services text[], p_location text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s jsonb := public.family_settings_for(p_family);
begin
  if p_monthly is not null and (p_monthly < 0 or p_monthly > (s->>'monthCap')::numeric) then
    raise exception 'FAMILY_MONTH_CAP' using errcode = 'P0001',
      hint = format('The monthly limit can be up to %s.', public.family_money((s->>'monthCap')::numeric));
  end if;
  if p_per_ride is not null and not exists (select 1 from jsonb_array_elements(s->'perRideChoices') x
                                             where (x #>> '{}')::numeric = p_per_ride) then
    raise exception 'FAMILY_PER_RIDE_CHOICE' using errcode = 'P0001', hint = 'Pick one of the per-trip limits offered.';
  end if;
  if p_services is not null and exists (select 1 from unnest(p_services) k
                                         where not exists (select 1 from public.booking_modules b where b.key = k)) then
    raise exception 'FAMILY_UNKNOWN_SERVICE' using errcode = 'P0001';
  end if;
  if coalesce(p_location, 'ride') not in ('never', 'ride', 'always')
     or (case p_location when 'never' then 0 when 'ride' then 1 else 2 end)
        > (case s->>'locationRule' when 'never' then 0 when 'ride' then 1 else 2 end) then
    raise exception 'FAMILY_LOCATION_NOT_ALLOWED' using errcode = 'P0001',
      hint = 'Your area doesn''t allow that much location sharing.';
  end if;
end;
$$;
revoke execute on function public.family_check_member_values(uuid, numeric, numeric, text[], text) from public, anon, authenticated;

create or replace function public.family_check_room(p_family uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.family_count(p_family) >= public.family_cap(p_family) then
    raise exception 'FAMILY_FULL' using errcode = 'P0001',
      hint = format('Your family has %s members, the most allowed. Ask for more from the Family page.',
                    public.family_cap(p_family));
  end if;
end;
$$;
revoke execute on function public.family_check_room(uuid) from public, anon, authenticated;

-- The host invites someone by phone. They join only by accepting.
create or replace function public.family_invite(p_place jsonb, p_phone text, p_name text, p_relation text default null,
                                                p_monthly numeric default null, p_per_ride numeric default null,
                                                p_services text[] default null, p_location text default 'ride')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.families;
  v_digits text := public.family_phone_digits(p_phone);
  v_days integer;
  v_profile uuid;
  m public.family_members;
  v_host text;
begin
  f := public.family_host_family(p_place);
  if not coalesce((public.family_settings_for(f.id)->>'enabled')::boolean, true) then
    raise exception 'FAMILY_OFF' using errcode = 'P0001', hint = 'Family isn''t available in your area.';
  end if;
  if v_digits is null or v_digits !~ '^[0-9]{6,15}$' then
    raise exception 'FAMILY_BAD_PHONE' using errcode = 'P0001', hint = 'Enter their phone number.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'FAMILY_NAME_NEEDED' using errcode = 'P0001', hint = 'Enter their name.';
  end if;
  if v_digits = public.family_phone_digits((select phone from public.profiles where id = f.host_id)) then
    raise exception 'FAMILY_CANT_INVITE' using errcode = 'P0001', hint = 'That is your own number.';
  end if;
  if exists (select 1 from public.family_members where family_id = f.id and phone_digits = v_digits
              and (status = 'active' or (status = 'invited' and expires_at > now()))) then
    raise exception 'FAMILY_ALREADY_INVITED' using errcode = 'P0001', hint = 'This number is already in your family.';
  end if;
  perform public.family_check_room(f.id);
  perform public.family_check_member_values(f.id, p_monthly, p_per_ride, p_services, p_location);
  v_days := coalesce((public.family_settings_for(f.id)->>'inviteDays')::integer, 7);
  insert into public.family_members (family_id, kind, status, name, relation, phone_digits, monthly_limit,
                                     per_ride_limit, services, location_choice, expires_at)
  values (f.id, 'member', 'invited', btrim(p_name), nullif(btrim(p_relation), ''), v_digits, p_monthly, p_per_ride,
          p_services, coalesce(p_location, 'ride'), now() + make_interval(days => v_days))
  returning * into m;
  select id into v_profile from public.profiles
   where public.family_phone_digits(phone) = v_digits and id <> f.host_id limit 1;
  if v_profile is not null then
    select coalesce(nullif(btrim(name), ''), 'Someone') into v_host from public.profiles where id = f.host_id;
    perform public.enqueue_notification(v_profile, 'family:invite:' || m.id, 'family', 'normal',
      v_host || ' added you to their family',
      'Read what joining means. Nothing is shared until you tap Join.',
      jsonb_build_object('route', '/account/family'), null);
  end if;
  return public.family_member_json(m);
end;
$$;
revoke execute on function public.family_invite(jsonb, text, text, text, numeric, numeric, text[], text) from public, anon;
grant execute on function public.family_invite(jsonb, text, text, text, numeric, numeric, text[], text) to authenticated;

-- The host adds a child without a phone (a profile under the host, no device).
create or replace function public.family_add_child(p_place jsonb, p_name text, p_birth_date date,
                                                   p_photo_url text default null, p_relation text default null,
                                                   p_services text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.families;
  m public.family_members;
begin
  f := public.family_host_family(p_place);
  if not coalesce((public.family_settings_for(f.id)->>'children')::boolean, true)
     or not coalesce((public.family_settings_for(f.id)->>'enabled')::boolean, true) then
    raise exception 'FAMILY_CHILDREN_OFF' using errcode = 'P0001', hint = 'Children can''t be added in your area.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'FAMILY_NAME_NEEDED' using errcode = 'P0001', hint = 'Enter the child''s name.';
  end if;
  if p_birth_date is null or p_birth_date > current_date or age(current_date, p_birth_date) >= interval '18 years' then
    raise exception 'FAMILY_CHILD_AGE' using errcode = 'P0001', hint = 'A child is under 18. Invite an adult by phone.';
  end if;
  perform public.family_check_room(f.id);
  perform public.family_check_member_values(f.id, null, null, p_services, 'ride');
  insert into public.family_members (family_id, kind, status, name, relation, birth_date, photo_url, services,
                                     location_choice, joined_at)
  values (f.id, 'child', 'active', btrim(p_name), nullif(btrim(p_relation), ''), p_birth_date,
          nullif(btrim(p_photo_url), ''), p_services, 'ride', now())
  returning * into m;
  return public.family_member_json(m);
end;
$$;
revoke execute on function public.family_add_child(jsonb, text, date, text, text, text[]) from public, anon;
grant execute on function public.family_add_child(jsonb, text, date, text, text, text[]) to authenticated;

-- The host changes a member's values: {monthlyLimit, perRideLimit, services,
-- location, name, relation, birthDate, photoUrl} (null clears a limit). Less
-- location applies at once; more waits for the member to accept it.
create or replace function public.family_update_member(p_member uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.family_members;
  f public.families;
  v_monthly numeric;
  v_per_ride numeric;
  v_services text[];
  v_location text;
  v_rank_old integer;
  v_rank_new integer;
begin
  select fm.* into m from public.family_members fm join public.families x on x.id = fm.family_id
   where fm.id = p_member and x.host_id = auth.uid() and fm.status in ('invited', 'active') for update of fm;
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into f from public.families where id = m.family_id;
  v_monthly := case when p_patch ? 'monthlyLimit' then (p_patch->>'monthlyLimit')::numeric else m.monthly_limit end;
  v_per_ride := case when p_patch ? 'perRideLimit' then (p_patch->>'perRideLimit')::numeric else m.per_ride_limit end;
  v_services := case when p_patch ? 'services' then
                  case when jsonb_typeof(p_patch->'services') = 'array'
                       then array(select jsonb_array_elements_text(p_patch->'services')) end
                else m.services end;
  v_location := coalesce(p_patch->>'location', m.location_choice);
  perform public.family_check_member_values(f.id, v_monthly, v_per_ride, v_services, v_location);
  v_rank_old := case m.location_choice when 'never' then 0 when 'ride' then 1 else 2 end;
  v_rank_new := case v_location when 'never' then 0 when 'ride' then 1 else 2 end;
  update public.family_members set
    monthly_limit = v_monthly,
    per_ride_limit = v_per_ride,
    services = v_services,
    location_choice = case when m.status = 'active' and m.kind = 'member' and v_rank_new > v_rank_old
                           then m.location_choice else v_location end,
    location_pending = case when m.status = 'active' and m.kind = 'member' and v_rank_new > v_rank_old
                            then v_location
                            when v_rank_new <= v_rank_old then null else location_pending end,
    name = case when p_patch ? 'name' and btrim(p_patch->>'name') <> '' then left(btrim(p_patch->>'name'), 80) else name end,
    relation = case when p_patch ? 'relation' then nullif(left(btrim(p_patch->>'relation'), 40), '') else relation end,
    birth_date = case when kind = 'child' and p_patch ? 'birthDate' then (p_patch->>'birthDate')::date else birth_date end,
    photo_url = case when kind = 'child' and p_patch ? 'photoUrl' then nullif(btrim(p_patch->>'photoUrl'), '') else photo_url end,
    updated_at = now()
   where id = p_member
  returning * into m;
  if m.kind = 'member' and m.status = 'active' then
    perform public.enqueue_notification(m.profile_id, 'family:changed:' || m.id || ':' || extract(epoch from now())::bigint,
      'family', 'normal', 'Your family settings changed',
      case when m.location_pending is not null then 'Your family host asks to see more. Nothing changes until you accept.'
           else 'See what your family covers and who can see you.' end,
      jsonb_build_object('route', '/account/family'), null);
  end if;
  return public.family_member_json(m);
end;
$$;
revoke execute on function public.family_update_member(uuid, jsonb) from public, anon;
grant execute on function public.family_update_member(uuid, jsonb) to authenticated;

-- The host removes a member or a child, or cancels an invite. Sharing and
-- family payment stop at once.
create or replace function public.family_remove_member(p_member uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.family_members;
begin
  select fm.* into m from public.family_members fm join public.families x on x.id = fm.family_id
   where fm.id = p_member and x.host_id = auth.uid() and fm.status in ('invited', 'active');
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.family_members set status = 'removed', left_at = now(), location_pending = null,
         share_always_ok = false, updated_at = now() where id = p_member;
  if m.status = 'active' and m.profile_id is not null then
    perform public.enqueue_notification(m.profile_id, 'family:removed:' || m.id, 'family', 'normal',
      'You are no longer in the family', 'Nothing is shared and the family no longer pays for you.',
      jsonb_build_object('route', '/account/family'), null);
  end if;
end;
$$;
revoke execute on function public.family_remove_member(uuid) from public, anon;
grant execute on function public.family_remove_member(uuid) to authenticated;

-- The host asks the admin for more members.
create or replace function public.family_request_cap(p_wanted integer, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.families;
  r public.family_cap_requests;
begin
  select * into f from public.families where host_id = auth.uid();
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_wanted is null or p_wanted <= public.family_cap(f.id) or p_wanted > 200 then
    raise exception 'FAMILY_CAP_WANTED' using errcode = 'P0001', hint = 'Ask for more than you have now.';
  end if;
  insert into public.family_cap_requests (family_id, wanted, reason)
  values (f.id, p_wanted, nullif(left(btrim(p_reason), 300), ''))
  on conflict (family_id) where status = 'pending' do update set wanted = excluded.wanted, reason = excluded.reason
  returning * into r;
  return jsonb_build_object('id', r.id, 'wanted', r.wanted, 'status', r.status);
end;
$$;
revoke execute on function public.family_request_cap(integer, text) from public, anon;
grant execute on function public.family_request_cap(integer, text) to authenticated;

-- Invites for the caller's phone number: what joining means, in full.
create or replace function public.family_my_invites()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_digits text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_digits := public.family_phone_digits((select phone from public.profiles where id = auth.uid()));
  if v_digits is null then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(public.family_member_json(m) || jsonb_build_object(
             'hostName', (select coalesce(nullif(btrim(p.name), ''), 'Someone') from public.profiles p where p.id = f.host_id),
             'adminLocationRule', public.family_settings_at(public.family_place_of(f))->>'locationRule',
             'modules', (select coalesce(jsonb_agg(x->>'name'), '[]'::jsonb)
                           from jsonb_array_elements(public.family_modules_at(public.family_place_of(f))) x
                          where (x->>'familyPays')::boolean
                            and (m.services is null or x->>'key' = any (m.services))))
           order by m.invited_at desc)
      from public.family_members m join public.families f on f.id = m.family_id
     where m.phone_digits = v_digits and m.status = 'invited' and m.expires_at > now() and f.host_id <> auth.uid()),
    '[]'::jsonb);
end;
$$;
revoke execute on function public.family_my_invites() from public, anon;
grant execute on function public.family_my_invites() to authenticated;

-- Join or Not now. Joining records what the member was shown.
create or replace function public.family_respond(p_member uuid, p_join boolean, p_terms jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.family_members;
  f public.families;
  v_name text;
begin
  select * into m from public.family_members
   where id = p_member and status = 'invited' and expires_at > now()
     and phone_digits = public.family_phone_digits((select phone from public.profiles where id = auth.uid()))
   for update;
  if not found then
    raise exception 'FAMILY_INVITE_GONE' using errcode = 'P0001', hint = 'This invitation has ended.';
  end if;
  select * into f from public.families where id = m.family_id;
  select coalesce(nullif(btrim(name), ''), 'Your invitee') into v_name from public.profiles where id = auth.uid();
  if not p_join then
    update public.family_members set status = 'declined', updated_at = now() where id = p_member;
    return jsonb_build_object('status', 'declined');
  end if;
  if f.host_id = auth.uid() then
    raise exception 'FAMILY_CANT_INVITE' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.families where host_id = auth.uid())
     or exists (select 1 from public.family_members where profile_id = auth.uid() and status = 'active') then
    raise exception 'FAMILY_ALREADY_MEMBER' using errcode = 'P0001',
      hint = 'You are already in a family. Leave it first.';
  end if;
  update public.family_members set status = 'active', profile_id = auth.uid(), joined_at = now(),
         terms = coalesce(p_terms, '{}'::jsonb) || jsonb_build_object('acceptedAt', now()), updated_at = now()
   where id = p_member returning * into m;
  perform public.enqueue_notification(f.host_id, 'family:joined:' || m.id, 'family', 'normal',
    v_name || ' joined your family', 'They can see what you share and can leave at any time.',
    jsonb_build_object('route', '/account/family'), null);
  return jsonb_build_object('status', 'active', 'member', public.family_member_json(m));
end;
$$;
revoke execute on function public.family_respond(uuid, boolean, jsonb) from public, anon;
grant execute on function public.family_respond(uuid, boolean, jsonb) to authenticated;

-- The member leaves: sharing and family payment stop at once.
create or replace function public.family_leave()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.family_members;
begin
  select * into m from public.family_members where profile_id = auth.uid() and status = 'active';
  if not found then
    return;
  end if;
  update public.family_members set status = 'left', left_at = now(), share_always_ok = false,
         location_pending = null, updated_at = now() where id = m.id;
  perform public.enqueue_notification((select host_id from public.families where id = m.family_id),
    'family:left:' || m.id, 'family', 'normal', m.name || ' left your family',
    'Nothing is shared with you any more and the family no longer pays for them.',
    jsonb_build_object('route', '/account/family'), null);
end;
$$;
revoke execute on function public.family_leave() from public, anon;
grant execute on function public.family_leave() to authenticated;

-- The member's own switches: accept or refuse the host's raise, and "Share
-- with family" for the "always" rule.
create or replace function public.family_member_consent(p_accept_raise boolean default null,
                                                        p_share_always boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.family_members;
begin
  select * into m from public.family_members where profile_id = auth.uid() and status = 'active' for update;
  if not found then
    raise exception 'FAMILY_NOT_MEMBER' using errcode = 'P0001';
  end if;
  update public.family_members set
    location_choice = case when p_accept_raise is true and location_pending is not null then location_pending
                           else location_choice end,
    location_pending = case when p_accept_raise is not null then null else location_pending end,
    share_always_ok = coalesce(p_share_always, share_always_ok),
    updated_at = now()
   where id = m.id returning * into m;
  return public.family_member_json(m);
end;
$$;
revoke execute on function public.family_member_consent(boolean, boolean) from public, anon;
grant execute on function public.family_member_consent(boolean, boolean) to authenticated;

-- The "Family · <host>'s GET.wallet" row of a booking screen for the caller.
create or replace function public.family_pay_option(p_module text, p_place jsonb, p_amount numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if auth.uid() is null or not exists (select 1 from public.family_members where profile_id = auth.uid()
                                                                             and status = 'active' and kind = 'member') then
    return null;
  end if;
  v := public.family_payer_for(p_module, auth.uid(), null, p_amount, p_place, '{}'::jsonb);
  return jsonb_build_object(
    'available', coalesce((v->>'ok')::boolean, false), 'code', v->>'code', 'message', v->>'message',
    'hostName', (select coalesce(nullif(btrim(p.name), ''), 'Family host') from public.profiles p
                   join public.families f on f.host_id = p.id
                   join public.family_members m on m.family_id = f.id
                  where m.profile_id = auth.uid() and m.status = 'active' limit 1),
    'left', (select public.family_month_left(m.id) from public.family_members m
              where m.profile_id = auth.uid() and m.status = 'active' limit 1));
end;
$$;
revoke execute on function public.family_pay_option(text, jsonb, numeric) from public, anon;
grant execute on function public.family_pay_option(text, jsonb, numeric) to authenticated;

-- Who the host may book [p_module] for at [p_place]: [{id, name, kind, age,
-- allowed, code, message, needsAdult}].
create or replace function public.family_passengers(p_module text, p_place jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.families;
  m public.family_members;
  v jsonb := '[]'::jsonb;
  r jsonb;
  ra jsonb;
begin
  select * into f from public.families where host_id = auth.uid();
  if not found then
    return v;
  end if;
  for m in select * from public.family_members where family_id = f.id and status = 'active' order by kind, created_at loop
    r := public.family_payer_for(p_module, auth.uid(), m.id, null, p_place, '{}'::jsonb);
    ra := case when r->>'code' = 'FAMILY_CHILD_TOO_YOUNG'
               then public.family_payer_for(p_module, auth.uid(), m.id, null, p_place, '{"withAdult": true}'::jsonb) end;
    v := v || jsonb_build_array(jsonb_build_object(
      'id', m.id, 'name', m.name, 'kind', m.kind, 'phone', case when m.phone_digits is not null then '+' || m.phone_digits end,
      'age', case when m.birth_date is not null then extract(year from age(current_date, m.birth_date))::integer end,
      'allowed', coalesce((r->>'ok')::boolean, false) or coalesce((ra->>'ok')::boolean, false),
      'needsAdult', ra is not null and coalesce((ra->>'ok')::boolean, false),
      'code', r->>'code', 'message', r->>'message'));
  end loop;
  return v;
end;
$$;
revoke execute on function public.family_passengers(text, jsonb) from public, anon;
grant execute on function public.family_passengers(text, jsonb) to authenticated;

-- The host moves the family's region (the values follow it).
create or replace function public.family_set_place(p_place jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.families set country = nullif(btrim(p_place->>'country'), ''), state = nullif(btrim(p_place->>'state'), ''),
         city = nullif(btrim(p_place->>'city'), ''), suburb = nullif(btrim(p_place->>'suburb'), ''), updated_at = now()
   where host_id = auth.uid();
end;
$$;
revoke execute on function public.family_set_place(jsonb) from public, anon;
grant execute on function public.family_set_place(jsonb) to authenticated;

-- The trips the family paid for or the host booked, with what was spent:
-- the host sees all, a member their own.
create or replace function public.family_trip_list(p_member uuid default null, p_limit integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_family uuid;
begin
  select id into v_family from public.families where host_id = v_uid;
  return coalesce((
    select jsonb_agg(jsonb_build_object('trip', t.trip_id, 'module', t.module_key, 'member', m.name,
                                        'memberId', m.id, 'child', t.child, 'familyPays', t.family_pays,
                                        'at', t.created_at, 'ended', t.ended_at is not null,
                                        'spent', (select coalesce(sum(s.amount), 0) from public.family_spend s
                                                   where s.trip_id = t.trip_id))
                     order by t.created_at desc)
      from (select * from public.family_trips t
             where (t.family_id = v_family and (p_member is null or t.member_id = p_member))
                or t.member_id in (select id from public.family_members where profile_id = v_uid and status = 'active')
             order by t.created_at desc
             limit least(greatest(coalesce(p_limit, 30), 1), 100)) t
      join public.family_members m on m.id = t.member_id), '[]'::jsonb);
end;
$$;
revoke execute on function public.family_trip_list(uuid, integer) from public, anon;
grant execute on function public.family_trip_list(uuid, integer) to authenticated;

-- The member's (or host's) log of admin looks at their family.
create or replace function public.family_my_view_log()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('at', l.viewed_at, 'kind', l.reason_kind, 'reason', l.reason,
                                               'by', 'GET.ride admin')
                            order by l.viewed_at desc), '[]'::jsonb)
    from public.family_view_log l
   where auth.uid() is not null
     and (l.family_id in (select id from public.families where host_id = auth.uid())
          or exists (select 1 from public.family_members m
                      where m.profile_id = auth.uid() and m.id = any (l.member_ids)));
$$;
revoke execute on function public.family_my_view_log() from public, anon;
grant execute on function public.family_my_view_log() to authenticated;

-- ---- 8. Admin › People › Family -----------------------------------------------------------------
-- Reading families: any admin with the Family page, the Settings hub, God
-- View, or a full admin. Writing: EDIT on the Family page (caller_admin_can_write).
create or replace function public.family_admin_reader()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  return exists (select 1 from public.admin_access a
                  where a.profile_id = auth.uid()
                    and a.page in ('*', 'admin-settings', 'admin-settings-family', 'admin-god-view'));
end;
$$;
revoke execute on function public.family_admin_reader() from public, anon, authenticated;

create or replace function public.family_admin_list(p_search text default null, p_limit integer default 50,
                                                    p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.family_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by x->>'createdAt' desc)
      from (select jsonb_build_object(
                     'id', f.id, 'hostId', f.host_id, 'hostName', coalesce(p.name, ''), 'hostPhone', p.phone,
                     'place', public.family_place_of(f), 'cap', public.family_cap(f.id), 'capOwn', f.member_cap,
                     'count', public.family_count(f.id),
                     'children', (select count(*) from public.family_members m
                                   where m.family_id = f.id and m.kind = 'child' and m.status = 'active'),
                     'pending', (select count(*) from public.family_cap_requests r
                                  where r.family_id = f.id and r.status = 'pending'),
                     'createdAt', f.created_at) x
              from public.families f join public.profiles p on p.id = f.host_id
             where q = '' or lower(coalesce(p.name, '')) like '%' || q || '%' or coalesce(p.phone, '') like '%' || q || '%'
             order by f.created_at desc
             limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) s),
    '[]'::jsonb);
end;
$$;
revoke execute on function public.family_admin_list(text, integer, integer) from public, anon;
grant execute on function public.family_admin_list(text, integer, integer) to authenticated;

create or replace function public.family_admin_set_cap(p_family uuid, p_cap integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:family_admin_write') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_cap is not null and (p_cap < 1 or p_cap > 200) then
    raise exception 'FAMILY_CAP_WANTED' using errcode = 'P0001', hint = 'Between 1 and 200.';
  end if;
  update public.families set member_cap = p_cap, updated_at = now() where id = p_family;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'family.cap', (select host_id from public.families where id = p_family),
          jsonb_build_object('family', p_family, 'cap', p_cap));
end;
$$;
revoke execute on function public.family_admin_set_cap(uuid, integer) from public, anon;
grant execute on function public.family_admin_set_cap(uuid, integer) to authenticated;

create or replace function public.family_admin_requests(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.family_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'familyId', r.family_id, 'hostName', coalesce(p.name, ''),
                                        'hostPhone', p.phone, 'cap', public.family_cap(r.family_id),
                                        'count', public.family_count(r.family_id), 'wanted', r.wanted,
                                        'reason', r.reason, 'status', r.status, 'note', r.note, 'at', r.created_at)
                     order by r.created_at)
      from public.family_cap_requests r
      join public.families f on f.id = r.family_id
      join public.profiles p on p.id = f.host_id
     where p_status is null or r.status = p_status), '[]'::jsonb);
end;
$$;
revoke execute on function public.family_admin_requests(text) from public, anon;
grant execute on function public.family_admin_requests(text) to authenticated;

create or replace function public.family_admin_decide(p_request uuid, p_approve boolean, p_note text default null,
                                                      p_cap integer default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.family_cap_requests;
  v_host uuid;
begin
  if not public.caller_admin_can_write('rpc:family_admin_write') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.family_cap_requests where id = p_request and status = 'pending' for update;
  if not found then
    raise exception 'FAMILY_REQUEST_GONE' using errcode = 'P0001';
  end if;
  update public.family_cap_requests set status = case when p_approve then 'approved' else 'declined' end,
         decided_by = auth.uid(), decided_at = now(), note = nullif(left(btrim(p_note), 300), '')
   where id = p_request;
  if p_approve then
    update public.families set member_cap = coalesce(p_cap, r.wanted), updated_at = now() where id = r.family_id;
  end if;
  select host_id into v_host from public.families where id = r.family_id;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'family.cap_request', v_host,
          jsonb_build_object('request', p_request, 'approve', p_approve, 'cap', coalesce(p_cap, r.wanted)));
  perform public.enqueue_notification(v_host, 'family:cap:' || p_request, 'family', 'normal',
    case when p_approve then 'More family members allowed' else 'Family request declined' end,
    case when p_approve then format('Your family can now have %s members.', coalesce(p_cap, r.wanted))
         else coalesce(nullif(btrim(p_note), ''), 'Your request for more members was declined.') end,
    jsonb_build_object('route', '/account/family'), null);
end;
$$;
revoke execute on function public.family_admin_decide(uuid, boolean, text, integer) from public, anon;
grant execute on function public.family_admin_decide(uuid, boolean, text, integer) to authenticated;

-- God View, logged: an admin opens a family only with a reason. Every look
-- is logged (who, when, why) and the members can read their log.
create or replace function public.family_admin_view(p_family uuid, p_reason_kind text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.families;
  v_members uuid[];
begin
  if not public.family_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into f from public.families where id = p_family;
  if not found then
    raise exception 'FAMILY_GONE' using errcode = 'P0001';
  end if;
  if not public.god_view_may_see(f.host_id) then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Your God View grant doesn''t cover this family.';
  end if;
  if coalesce(p_reason_kind, '') not in ('report', 'sos', 'legal', 'support')
     or char_length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'FAMILY_REASON_NEEDED' using errcode = 'P0001',
      hint = 'Give the reason: a report, an SOS, a legal request or support, in at least 10 characters.';
  end if;
  select coalesce(array_agg(id), '{}') into v_members from public.family_members
   where family_id = f.id and status = 'active';
  insert into public.family_view_log (family_id, member_ids, admin_id, reason_kind, reason)
  values (f.id, v_members, auth.uid(), p_reason_kind, left(btrim(p_reason), 500));
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'family.view', f.host_id,
          jsonb_build_object('family', f.id, 'kind', p_reason_kind, 'reason', left(btrim(p_reason), 500)));
  return jsonb_build_object(
    'id', f.id, 'hostName', (select name from public.profiles where id = f.host_id),
    'members', coalesce((select jsonb_agg(public.family_member_json(m) order by m.kind, m.created_at)
                           from public.family_members m where m.family_id = f.id and m.status in ('invited', 'active')),
                        '[]'::jsonb),
    'trips', coalesce((select jsonb_agg(jsonb_build_object('trip', t.trip_id, 'module', t.module_key,
                                                           'member', (select name from public.family_members where id = t.member_id),
                                                           'at', t.created_at, 'ended', t.ended_at is not null,
                                                           'lat', r.partner_live_lat, 'lng', r.partner_live_lng,
                                                           'status', coalesce(r.status, b.status))
                                         order by t.created_at desc)
                         from (select * from public.family_trips where family_id = f.id
                                order by created_at desc limit 20) t
                         left join public.ride_requests r on r.id = t.trip_id
                         left join public.c2c_bookings b on b.id = t.trip_id), '[]'::jsonb));
end;
$$;
revoke execute on function public.family_admin_view(uuid, text, text) from public, anon;
grant execute on function public.family_admin_view(uuid, text, text) to authenticated;

create or replace function public.family_admin_view_log(p_family uuid default null, p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.family_admin_reader() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', l.id, 'familyId', l.family_id, 'hostName', coalesce(hp.name, ''),
                                        'admin', coalesce(ap.name, ap.email, 'Admin'), 'kind', l.reason_kind,
                                        'reason', l.reason, 'members', cardinality(l.member_ids), 'at', l.viewed_at)
                     order by l.viewed_at desc)
      from (select * from public.family_view_log
             where p_family is null or family_id = p_family
             order by viewed_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) l
      join public.families f on f.id = l.family_id
      left join public.profiles hp on hp.id = f.host_id
      left join public.profiles ap on ap.id = l.admin_id), '[]'::jsonb);
end;
$$;
revoke execute on function public.family_admin_view_log(uuid, integer) from public, anon;
grant execute on function public.family_admin_view_log(uuid, integer) to authenticated;

-- ---- 9. Modules after 0308 ----------------------------------------------------------------------
-- 0309 to 0316 landed after this layer was first written. Each function below
-- is the latest definition (named in its comment) with only what Family
-- needs: every GET.wallet row that is a charge or a refund on a trip names
-- the trip (ride_id), so the payment layer (section 6) sends it to whoever
-- paid; balances are checked on family_wallet_owner. Payment 'family' on City
-- to City (whole car and seats) is an in-app payment from the host's
-- GET.wallet: method get_wallet only, never the host's coins.

-- As 0309, with each row naming the trip the fee is owed on: a fee owed on a
-- family-paid trip is the family's, from the host's GET.wallet (within the
-- member's limits).
create or replace function public.c2c_settle_due(d public.c2c_bookings, p_via text, p_debit boolean,
                                                 p_collector uuid default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(d.cancel_fee, 0), 2);
  v_rate numeric := case when d.commission_rate >= 0 and d.commission_rate < 1 then d.commission_rate else 0 end;
  v_label text := 'City to City cancellation fee ' || d.ref || ' (owed)';
begin
  if v_amount <= 0 or d.cancel_fee_status is distinct from 'due' then
    return 0;
  end if;
  if p_debit then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (d.rider_id, 'get_wallet', 'payment', -v_amount, 'cancellation_fee',
            v_label || case p_via when 'topup' then ', taken from your top-up'
                                  when 'pay_now' then ', paid in Wallet' else '' end, d.id);
  end if;
  if p_via = 'cash' and p_collector is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (p_collector, 'get_credit', 'c2c_fee_collected', -v_amount, 'cancellation_fee',
            v_label || ', collected by you in cash', d.id);
  end if;
  if d.driver_id is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (d.driver_id, 'get_wallet', 'cancellation_fee', round(v_amount * (1 - v_rate), 2), 'cancellation_fee',
            v_label || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end,
            d.id);
  end if;
  update public.c2c_bookings
     set cancel_fee_status = 'charged', cancel_fee_paid_at = now(), cancel_fee_paid_via = p_via
   where id = d.id;
  return v_amount;
end;
$$;
revoke execute on function public.c2c_settle_due(public.c2c_bookings, text, boolean, uuid) from public, anon, authenticated;

-- As 0309, with each fee's payer checked (family_wallet_owner).
create or replace function public.c2c_collect_rider_dues(p_rider uuid, p_via text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.c2c_bookings;
  v_balance numeric;
  v_owner uuid;
  v_paid numeric := 0;
begin
  for d in
    select * from public.c2c_bookings
     where rider_id = p_rider and cancel_fee_status = 'due' and cancel_fee > 0
     order by cancelled_at, id
     for update
  loop
    v_owner := public.family_wallet_owner(d.id, p_rider, d.cancel_fee);
    select w.balance into v_balance from public.wallets w
     where w.user_id = v_owner and w.wallet_type = 'get_wallet' for update;
    continue when coalesce(v_balance, 0) < d.cancel_fee;
    v_paid := v_paid + public.c2c_settle_due(d, p_via, true, null);
  end loop;
  return v_paid;
end;
$$;
revoke execute on function public.c2c_collect_rider_dues(uuid, text) from public, anon, authenticated;

-- As 0309, and: rows name the trip; payment 'family' takes the fare from the
-- family host's GET.wallet (the member's limits checked: their FAMILY_* code)
-- and each fee owed with it from whoever pays the trip it is owed on.
create or replace function public.c2c_take_fare(b public.c2c_bookings, p_fare numeric, p_method text,
                                                p_expected numeric, pr public.c2c_pay_rules, p_hold boolean)
returns public.c2c_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.city_to_city_settings;
  v_fare numeric := round(coalesce(p_fare, 0), 2);
  v_dues numeric := 0;
  v_due_ids uuid[] := '{}';
  v_total numeric;
  v_rate numeric;
  v_wallet numeric;
  v_coins numeric;
  sp record;
  v_fare_cv numeric;
  v_fare_wallet numeric;
  v_due_wallet numeric;
  d public.c2c_bookings;
  p public.c2c_payments;
  v_family boolean := b.payment = 'family';
  v_method text := p_method;
  v_owner uuid;
  v_state text;
  v_cash boolean;
begin
  if v_family then
    -- Family: the host's GET.wallet, never the host's coins.
    if coalesce(v_method, 'get_wallet') not in ('get_wallet', 'family') or not coalesce(pr.pay_wallet, true) then
      raise exception 'C2C_PAY_WAY' using errcode = '22023',
        hint = 'Family pays from your family host''s GET.wallet. Pick another way to pay.';
    end if;
    v_method := 'get_wallet';
  end if;
  if v_method is null or v_method not in ('get_wallet', 'get_coin', 'mix')
     or (v_method = 'get_wallet' and not pr.pay_wallet)
     or (v_method = 'get_coin' and not pr.pay_coin)
     or (v_method = 'mix' and not pr.pay_mix) then
    raise exception 'C2C_PAY_WAY' using errcode = '22023', hint = 'That way to pay isn''t offered here. Pick another.';
  end if;
  if v_fare <= 0 then
    raise exception 'invalid_amount';
  end if;
  select * into s from public.city_to_city_settings where id = 1;
  if coalesce(s.owed_next_in_app, false) then
    select coalesce(sum(x.cancel_fee), 0), coalesce(array_agg(x.id order by x.cancelled_at, x.id), '{}')
      into v_dues, v_due_ids
      from public.c2c_bookings x
     where x.rider_id = b.rider_id and x.cancel_fee_status = 'due' and x.cancel_fee > 0;
  end if;
  v_total := v_fare + v_dues;
  -- The rider agreed to pay what they were shown.
  if p_expected is not null and abs(round(p_expected, 2) - v_total) > 0.005 then
    raise exception 'C2C_AMOUNT_CHANGED' using errcode = '22023',
      hint = 'The amount is now ' || public.c2c_money(v_total, b.currency) || '. Check it and try again.';
  end if;

  select g.coins_per_currency into v_rate from public.get_coin_settings g where g.id = 'master';

  if v_family then
    v_state := public.family_trip_state(b.id, b.rider_id, v_fare);
    if v_state <> 'ok' then
      raise exception '%', v_state using errcode = 'P0001',
        hint = case v_state when 'FAMILY_LIMIT_REACHED' then 'The family limit for this month doesn''t cover this trip.'
                            when 'FAMILY_RIDE_LIMIT' then 'This trip is over the family limit for one trip.'
                            when 'FAMILY_NOT_MEMBER' then 'You are no longer in the family.'
                            else 'The family doesn''t pay for this trip.' end;
    end if;
    v_cash := coalesce(pr.offer_cash, false) and coalesce(s.pay_cash, true);
    v_owner := public.family_wallet_owner(b.id, b.rider_id, v_fare);
    insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
    select w.balance into v_wallet from public.wallets w
     where w.user_id = v_owner and w.wallet_type = 'get_wallet' for update;
    if coalesce(v_wallet, 0) < v_fare then
      raise exception 'C2C_WALLET_SHORT' using errcode = '22023',
        hint = 'Your family host''s GET wallet is ' || public.c2c_money(v_fare - coalesce(v_wallet, 0), b.currency)
               || ' short. Ask them to top up' || case when v_cash then ', or switch this trip to cash.' else '.' end;
    end if;
    -- Charged to the member, naming the trip: the payment layer moves it to the host.
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.rider_id, 'get_wallet', case when p_hold then 'c2c_hold' else 'c2c_payment' end, -v_fare, 'c2c_fare',
            case when p_hold then 'City to City fare held ' || b.ref || ' (paid to the driver when the trip is complete)'
                 else 'City to City fare paid ' || b.ref end, b.id);
    -- Each fee owed, from whoever pays the trip it is owed on.
    for d in select * from public.c2c_bookings where id = any(v_due_ids) order by cancelled_at, id for update loop
      v_owner := public.family_wallet_owner(d.id, b.rider_id, d.cancel_fee);
      insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
      on conflict (user_id, wallet_type) do nothing;
      select w.balance into v_wallet from public.wallets w
       where w.user_id = v_owner and w.wallet_type = 'get_wallet' for update;
      if coalesce(v_wallet, 0) < d.cancel_fee then
        raise exception 'C2C_WALLET_SHORT' using errcode = '22023',
          hint = case when v_owner = b.rider_id then 'Your GET wallet' else 'Your family host''s GET wallet' end
                 || ' is ' || public.c2c_money(d.cancel_fee - coalesce(v_wallet, 0), b.currency)
                 || ' short for the cancel fees owed. Top up first.';
      end if;
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (b.rider_id, 'get_wallet', 'payment', -d.cancel_fee, 'cancellation_fee',
              'City to City cancel fee owed ' || d.ref || ', paid with ' || b.ref, d.id);
      perform public.c2c_settle_due(d, 'in_app', false, null);
    end loop;
    insert into public.c2c_payments (booking_id, rider_id, driver_id, mode, status, method, amount, wallet_amount,
                                     coin_value, coins, coin_rate, dues_amount, due_ids, settled_at)
    values (b.id, b.rider_id, b.driver_id, case when p_hold then 'hold' else 'after' end,
            case when p_hold then 'held' else 'paid' end, 'get_wallet', v_fare, v_fare, 0, 0, v_rate,
            v_dues, v_due_ids, case when p_hold then null else now() end)
    returning * into p;
    return p;
  end if;

  if v_method = 'get_coin' and coalesce(v_rate, 0) <= 0 then
    raise exception 'C2C_PAY_WAY' using errcode = '22023', hint = 'Paying with coins isn''t available now.';
  end if;
  insert into public.wallets (user_id, wallet_type, balance)
  values (b.rider_id, 'get_wallet', 0), (b.rider_id, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_wallet from public.wallets w
   where w.user_id = b.rider_id and w.wallet_type = 'get_wallet' for update;
  select w.balance into v_coins from public.wallets w
   where w.user_id = b.rider_id and w.wallet_type = 'get_coin' for update;
  select * into sp from public.c2c_pay_split(v_total, v_method, v_wallet, v_coins, v_rate);
  if sp.short > 0 then
    raise exception 'C2C_WALLET_SHORT' using errcode = '22023',
      hint = public.c2c_short_hint(sp.short, v_method, b.currency, pr.offer_topup,
                                   pr.offer_cash and coalesce(s.pay_cash, true));
  end if;

  -- Coins pay the fare first, then the fees owed.
  v_fare_cv := least(sp.coin_value, v_fare);
  v_fare_wallet := v_fare - v_fare_cv;
  v_due_wallet := v_dues - (sp.coin_value - v_fare_cv);
  if sp.coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.rider_id, 'get_coin', 'redeem', -sp.coins, 'c2c_fare',
            'City to City ' || b.ref || ': ' || public.c2c_money(sp.coin_value, b.currency) || ' paid with coins', b.id);
  end if;
  if v_fare_wallet > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.rider_id, 'get_wallet', case when p_hold then 'c2c_hold' else 'c2c_payment' end, -v_fare_wallet,
            'c2c_fare',
            case when p_hold then 'City to City fare held ' || b.ref || ' (paid to the driver when the trip is complete)'
                 else 'City to City fare paid ' || b.ref end, b.id);
  end if;
  if v_due_wallet > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_wallet', 'payment', -v_due_wallet, 'cancellation_fee',
            'City to City cancel fees owed, paid with ' || b.ref);
  end if;
  for d in select * from public.c2c_bookings where id = any(v_due_ids) for update loop
    perform public.c2c_settle_due(d, 'in_app', false, null);
  end loop;

  insert into public.c2c_payments (booking_id, rider_id, driver_id, mode, status, method, amount, wallet_amount,
                                   coin_value, coins, coin_rate, dues_amount, due_ids, settled_at)
  values (b.id, b.rider_id, b.driver_id, case when p_hold then 'hold' else 'after' end,
          case when p_hold then 'held' else 'paid' end, v_method, v_fare, v_fare_wallet, v_fare_cv, sp.coins, v_rate,
          v_dues, v_due_ids, case when p_hold then null else now() end)
  returning * into p;
  return p;
end;
$$;
revoke execute on function public.c2c_take_fare(public.c2c_bookings, numeric, text, numeric, public.c2c_pay_rules, boolean)
  from public, anon, authenticated;

-- As 0309, with the rows naming the trip: a held fare the family paid goes
-- back to the host.
create or replace function public.c2c_hold_refund(b public.c2c_bookings, p_fee numeric default 0)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.c2c_payments;
  v_fee numeric;
  v_fee_wallet numeric;
  v_fee_cv numeric;
  v_back_wallet numeric;
  v_back_coins numeric := 0;
  v_rate numeric := case when b.commission_rate >= 0 and b.commission_rate < 1 then b.commission_rate else 0 end;
begin
  select * into p from public.c2c_payments where booking_id = b.id and status = 'held' for update;
  if p.id is null then
    return 0;
  end if;
  v_fee := least(round(greatest(coalesce(p_fee, 0), 0), 2), p.amount);
  v_fee_wallet := least(v_fee, p.wallet_amount);
  v_fee_cv := least(v_fee - v_fee_wallet, p.coin_value);
  v_back_wallet := p.wallet_amount - v_fee_wallet;
  if p.coin_value - v_fee_cv > 0 and coalesce(p.coin_rate, 0) > 0 then
    v_back_coins := least(floor((p.coin_value - v_fee_cv) * p.coin_rate * 100) / 100, p.coins);
  end if;
  if v_back_wallet > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.rider_id, 'get_wallet', 'c2c_refund', v_back_wallet, 'c2c_fare',
            'City to City fare ' || b.ref || ' given back'
            || case when v_fee > 0 then ' (less the ' || public.c2c_money(v_fee, b.currency) || ' cancel fee)' else '' end,
            b.id);
  end if;
  if v_back_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.rider_id, 'get_coin', 'c2c_refund', v_back_coins, 'c2c_fare',
            'City to City fare ' || b.ref || ': coins given back', b.id);
  end if;
  if v_fee > 0 and b.driver_id is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (b.driver_id, 'get_wallet', 'cancellation_fee', round(v_fee * (1 - v_rate), 2), 'cancellation_fee',
            'City to City cancellation fee ' || b.ref
            || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end, b.id);
  end if;
  update public.c2c_payments
     set status = 'refunded', fee_kept = v_fee, refund_wallet = v_back_wallet, refund_coins = v_back_coins,
         driver_id = b.driver_id, settled_at = now()
   where id = p.id;
  return v_fee;
end;
$$;
revoke execute on function public.c2c_hold_refund(public.c2c_bookings, numeric) from public, anon, authenticated;

-- As 0309, with the rows naming the trip.
create or replace function public.c2c_hold_release(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  p public.c2c_payments;
  c record;
  v_rate numeric;
  v_amount numeric(12,2) := 0;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  select * into p from public.c2c_payments where booking_id = p_booking and status = 'held' for update;
  if b.id is null or p.id is null or b.status <> 'completed' or b.driver_id is null then
    return;
  end if;
  select * into c from public.c2c_commission_of(b);
  v_rate := case when c.rate >= 0 and c.rate < 1 then c.rate end;
  if v_rate is not null and b.commission_charged_at is null then
    v_amount := round(p.amount * v_rate, 2);
  end if;
  -- One statement: the fare lands before the commission comes off it, and
  -- an owed give-up fee (trg_wallet_tx_c2c_collect) is taken after both.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  select x.u, x.w, x.k, x.a, x.m, x.n, b.id from (values
    (b.driver_id, 'get_wallet', 'c2c_earning', p.amount, 'c2c_fare',
     'City to City fare ' || b.ref || ', paid in the app'),
    (b.driver_id, 'get_wallet', 'commission', -v_amount, 'c2c_fare',
     'City to City commission ' || round(coalesce(v_rate, 0) * 100, 1) || '% of '
     || public.c2c_money(p.amount, b.currency) || ' (' || b.ref || ')')) x(u, w, k, a, m, n)
   where x.a <> 0;
  update public.c2c_payments
     set status = 'released', driver_id = b.driver_id, commission = v_amount, settled_at = now()
   where id = p.id;
  update public.c2c_bookings
     set pay_status = 'paid', paid_at = now(),
         commission_rate = coalesce(commission_rate, v_rate),
         commission_rule_id = coalesce(commission_rule_id, c.rule_id),
         commission_tier_id = coalesce(commission_tier_id, c.tier_id),
         commission_promotion_id = coalesce(commission_promotion_id, c.promotion_id),
         commission_amount = case when commission_charged_at is null then v_amount else commission_amount end,
         commission_charged_at = coalesce(commission_charged_at, now())
   where id = b.id;
end;
$$;
revoke execute on function public.c2c_hold_release(uuid) from public, anon, authenticated;

-- As 0309, with payment 'family' paid as 'in_app' (held or after, by the
-- pickup's rule) from the host's GET.wallet.
create or replace function public.c2c_accept_offer_pay(p_offer uuid, p_method text default null,
                                                       p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.c2c_offers;
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  p public.c2c_payments;
  v_collect_ids uuid[];
  v_collect numeric;
  v_mode text;
  v_status text;
begin
  select * into o from public.c2c_offers where id = p_offer;
  if o.id is null then
    raise exception 'C2C_OFFER_GONE' using errcode = '22023', hint = 'This offer is no longer available.';
  end if;
  select * into b from public.c2c_bookings where id = o.booking_id for update;
  if b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status in ('open', 'offered') and b.expires_at <= now() then
    perform public.c2c_expire_due();
    raise exception 'C2C_EXPIRED' using errcode = '22023',
      hint = 'This request has expired. Plan the trip again.';
  end if;
  if b.status not in ('open', 'offered') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023',
      hint = 'This trip already has a driver, or it was cancelled.';
  end if;
  select * into o from public.c2c_offers where id = p_offer for update;
  if o.status <> 'open' then
    raise exception 'C2C_OFFER_GONE' using errcode = '22023', hint = 'This offer is no longer available.';
  end if;
  if not coalesce((public.c2c_driver_eligibility(o.driver_id, b.pickup_place, b.drop_place)->>'ok')::boolean, false) then
    raise exception 'C2C_OFFER_GONE' using errcode = '22023', hint = 'This driver can no longer take the trip.';
  end if;
  if exists (select 1 from public.c2c_bookings x
              where x.driver_id = o.driver_id and x.id <> b.id
                and x.status in ('booked', 'driver_arriving', 'on_trip')
                and abs(extract(epoch from coalesce(x.driver_leave_at, x.leave_at) - o.leave_at))
                    < (greatest(x.duration_min, b.duration_min) + 120) * 60) then
    raise exception 'C2C_DRIVER_BUSY' using errcode = '22023',
      hint = 'This driver has just been booked for another trip at that time.';
  end if;

  if b.payment in ('in_app', 'family') then
    select * into pr from public.c2c_pay_rule_for(b.pickup_place);
    v_mode := coalesce(pr.when_mode, 'hold');
    if v_mode = 'hold' then
      p := public.c2c_take_fare(b, o.price,
                                case when b.payment = 'family' then coalesce(p_method, 'get_wallet')
                                     else coalesce(p_method, case when pr.pay_mix then 'mix'
                                                                  when pr.pay_wallet then 'get_wallet'
                                                                  else 'get_coin' end) end,
                                p_expected, pr, true);
      v_status := 'held';
    end if;
  else
    select x.ids, x.total into v_collect_ids, v_collect from public.c2c_dues_to_collect(b.rider_id) x;
  end if;

  update public.c2c_offers set status = 'accepted' where id = o.id;
  update public.c2c_offers set status = 'declined', declined_reason = 'taken'
   where booking_id = b.id and id <> o.id and status = 'open';
  update public.c2c_bookings
     set status = 'booked', driver_id = o.driver_id, offer_id = o.id, agreed_fare = o.price,
         driver_leave_at = o.leave_at, booked_at = now(),
         pay_mode = v_mode, pay_status = v_status,
         paid_method = p.method, paid_amount = p.amount,
         collect_fee_ids = v_collect_ids, collect_amount = v_collect, collected_at = null
   where id = b.id
  returning * into b;
  update public.c2c_payments set driver_id = o.driver_id where id = p.id;
  return jsonb_build_object('id', b.id, 'status', b.status, 'agreedFare', b.agreed_fare,
                            'payMode', b.pay_mode, 'payStatus', b.pay_status,
                            'held', p.amount, 'dues', coalesce(p.dues_amount, 0));
end;
$$;
revoke execute on function public.c2c_accept_offer_pay(uuid, text, numeric) from public, anon;
grant execute on function public.c2c_accept_offer_pay(uuid, text, numeric) to authenticated, service_role;

-- As 0309, with a 'family' trip paid after it, as 'in_app'.
create or replace function public.c2c_driver_progress(p_booking uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or b.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not ((b.status = 'booked' and p_status in ('driver_arriving', 'on_trip'))
          or (b.status = 'driver_arriving' and p_status = 'on_trip')
          or (b.status = 'on_trip' and p_status = 'completed')) then
    raise exception 'C2C_BAD_STEP' using errcode = '22023', hint = 'This trip can''t move to that step now.';
  end if;
  update public.c2c_bookings
     set status = p_status,
         arriving_at = case when p_status = 'driver_arriving' then now() else arriving_at end,
         started_at = case when p_status = 'on_trip' then now() else started_at end,
         completed_at = case when p_status = 'completed' then now() else completed_at end,
         pay_status = case when p_status = 'completed' and payment in ('in_app', 'family') and pay_mode = 'after'
                                and pay_status is null then 'unpaid' else pay_status end
   where id = b.id;
  if p_status = 'completed' then
    if b.pay_status = 'held' then
      perform public.c2c_hold_release(b.id);
    else
      perform public.c2c_charge_commission(b.id);
    end if;
    if b.payment in ('in_app', 'family') and b.pay_mode = 'after' then
      begin
        perform public.enqueue_notification(
          b.rider_id, 'c2c-pay:' || b.id, 'c2c_pay', 'normal', 'Pay for your trip',
          'Your trip to ' || coalesce(b.drop_place->>'city', b.drop_place->>'state', b.drop_name) || ' is complete. Pay '
          || public.c2c_money(coalesce(b.agreed_fare, b.fare), b.currency) || ' in the app'
          || case when b.payment = 'family' then ' with Family.' else '.' end,
          jsonb_build_object('type', 'c2c_pay', 'c2c_booking_id', b.id, 'role', 'rider'), null);
      exception when others then
        null;
      end;
    end if;
  end if;
end;
$$;
revoke execute on function public.c2c_driver_progress(uuid, text) from public, anon;
grant execute on function public.c2c_driver_progress(uuid, text) to authenticated, service_role;

-- As 0309, with a 'family' trip paid as 'in_app' and the driver's row naming the trip.
create or replace function public.c2c_pay(p_booking uuid, p_method text, p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  p public.c2c_payments;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.pay_status = 'paid' then
    return jsonb_build_object('paid', b.paid_amount, 'method', b.paid_method, 'already', true);
  end if;
  if b.status <> 'completed' then
    raise exception 'C2C_NOT_DONE' using errcode = '22023', hint = 'Pay once the trip is complete.';
  end if;
  if b.payment not in ('in_app', 'family') or b.pay_mode is distinct from 'after'
     or b.pay_status is distinct from 'unpaid' or b.driver_id is null then
    raise exception 'C2C_NOTHING_TO_PAY' using errcode = '22023', hint = 'There is nothing to pay in the app for this trip.';
  end if;
  select * into pr from public.c2c_pay_rule_for(b.pickup_place);
  p := public.c2c_take_fare(b, coalesce(b.agreed_fare, b.fare), p_method, p_expected, pr, false);
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (b.driver_id, 'get_wallet', 'c2c_earning', p.amount, 'c2c_fare',
          'City to City fare ' || b.ref || ', paid in the app', b.id);
  update public.c2c_bookings
     set pay_status = 'paid', paid_method = p.method, paid_amount = p.amount, paid_at = now()
   where id = b.id;
  return jsonb_build_object('paid', p.amount, 'method', p.method, 'coins', p.coins, 'dues', p.dues_amount,
                            'family', b.payment = 'family');
end;
$$;
revoke execute on function public.c2c_pay(uuid, text, numeric) from public, anon;
grant execute on function public.c2c_pay(uuid, text, numeric) to authenticated, service_role;

-- As 0309; a 'family' trip switched to cash is the member's own from then on.
create or replace function public.c2c_switch_to_cash(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.payment = 'cash' then
    return jsonb_build_object('payment', 'cash');
  end if;
  select * into pr from public.c2c_pay_rule_for(b.pickup_place);
  if not coalesce(pr.offer_cash, false)
     or not coalesce((select s.pay_cash from public.city_to_city_settings s where s.id = 1), true) then
    raise exception 'C2C_PAYMENT_NOT_ALLOWED' using errcode = '22023', hint = 'Cash isn''t offered for this trip.';
  end if;
  if b.status in ('open', 'offered') then
    update public.c2c_bookings set payment = 'cash' where id = b.id;
  elsif b.status = 'completed' and b.pay_status = 'unpaid' then
    update public.c2c_bookings set payment = 'cash', pay_status = 'cash' where id = b.id;
  else
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip''s payment can''t change now.';
  end if;
  if b.payment = 'family' then
    perform public.family_release_trip(b.id);
  end if;
  return jsonb_build_object('payment', 'cash');
end;
$$;
revoke execute on function public.c2c_switch_to_cash(uuid) from public, anon;
grant execute on function public.c2c_switch_to_cash(uuid) to authenticated, service_role;

-- As 0309; on a 'family' trip the pay sheet offers the GET.wallet only and
-- shows the balance of the wallet that pays (the host's).
create or replace function public.c2c_pay_info(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  s public.city_to_city_settings;
  v_items jsonb;
  v_family boolean;
  v_payer uuid;
begin
  select * into b from public.c2c_bookings where id = p_booking;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into pr from public.c2c_pay_rule_for(b.pickup_place);
  select * into s from public.city_to_city_settings where id = 1;
  v_family := b.payment = 'family';
  v_payer := case when v_family
                  then public.family_wallet_owner(b.id, b.rider_id, coalesce(b.agreed_fare, b.fare))
                  else b.rider_id end;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'ref', x.ref, 'fee', x.cancel_fee,
                                               'cancelledAt', x.cancelled_at) order by x.cancelled_at, x.id), '[]')
    into v_items
    from public.c2c_bookings x
   where coalesce(s.owed_next_in_app, false) and x.rider_id = b.rider_id
     and x.cancel_fee_status = 'due' and x.cancel_fee > 0;
  return jsonb_build_object(
    'when', coalesce(b.pay_mode, pr.when_mode, 'hold'),
    'wallet', coalesce(pr.pay_wallet, true),
    'coin', coalesce(pr.pay_coin, true) and not v_family,
    'mix', coalesce(pr.pay_mix, true) and not v_family,
    'offerTopup', coalesce(pr.offer_topup, true),
    'offerCash', coalesce(pr.offer_cash, true) and coalesce(s.pay_cash, true),
    'walletBalance', coalesce((select w.balance from public.wallets w
                                where w.user_id = v_payer and w.wallet_type = 'get_wallet'), 0),
    'coinBalance', case when v_family then 0
                        else coalesce((select w.balance from public.wallets w
                                        where w.user_id = b.rider_id and w.wallet_type = 'get_coin'), 0) end,
    'coinRate', (select g.coins_per_currency from public.get_coin_settings g where g.id = 'master'),
    'dues', v_items,
    'family', v_family,
    'payStatus', b.pay_status);
end;
$$;
revoke execute on function public.c2c_pay_info(uuid) from public, anon;
grant execute on function public.c2c_pay_info(uuid) to authenticated, service_role;

-- As 0310, plus payment 'family' (the member's own seats on the host's
-- GET.wallet, as 'in_app') and [p_family] ({passenger, withAdult}: the host
-- books for a family member or a child), kept in c2c_bookings.family; the
-- booking is checked and registered as module 'seat_trip' by
-- c2c_bookings_family. One more defaulted argument: the old 9-argument
-- signature is replaced, and every call to it works unchanged.
drop function if exists public.c2c_book_seat(uuid, integer, jsonb, text, jsonb, text, numeric, jsonb, text);
create or replace function public.c2c_book_seat(
  p_trip uuid,
  p_seats integer,
  p_pickup jsonb,
  p_payment text,
  p_passengers jsonb default null,
  p_method text default null,
  p_expected numeric default null,
  p_parcel jsonb default null,
  p_note text default null,
  p_family jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  t public.c2c_trips;
  s public.city_to_city_settings;
  v_terms jsonb;
  k record;
  v_parcel boolean := p_parcel is not null and jsonb_typeof(p_parcel) = 'object';
  v_seats integer;
  v_max integer;
  v_names jsonb;
  v_kind text;
  v_mp jsonb;
  v_index integer;
  v_pname text;
  v_paddr text;
  v_plat double precision;
  v_plng double precision;
  v_pplace jsonb;
  v_leave timestamptz;
  v_km numeric;
  v_extra numeric := 0;
  v_fare numeric;
  v_sizes text[] := array['small', 'medium', 'large'];
  v_where text;
  pl record;
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  p public.c2c_payments;
  v_collect_ids uuid[];
  v_collect numeric;
  v_mode text;
  v_status text;
  v_family jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- The trip first, locked: every booking on it waits here, so its seats are
  -- counted one booking at a time.
  select * into t from public.c2c_trips where id = p_trip for update;
  if t.id is null or t.status <> 'scheduled' then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip is no longer taking bookings.';
  end if;
  if t.driver_id = v_uid then
    raise exception 'C2C_OWN_TRIP' using errcode = '22023', hint = 'You can''t book a seat on your own trip.';
  end if;
  if public.c2c_seat_blocked(v_uid, t.driver_id) then
    raise exception 'DRIVER_BLOCKED' using errcode = '22023',
      hint = 'You blocked this driver. Unblock them in Settings › Blocked drivers to book them.';
  end if;
  v_terms := public.c2c_seat_terms_for(t.from_place);
  v_where := coalesce(t.from_place->>'city', t.from_place->>'state', t.from_place->>'country', 'here');
  if not coalesce((v_terms->>'seats_on')::boolean, false) or not public.c2c_available_at(t.from_place) then
    raise exception 'C2C_SEATS_OFF' using errcode = '22023',
      hint = 'Per-seat trips aren''t offered from ' || v_where || ' now.';
  end if;
  if now() > t.leave_at - make_interval(mins => coalesce((v_terms->>'cutoff_min')::integer, 60)) then
    raise exception 'C2C_BOOKING_CLOSED' using errcode = '22023',
      hint = 'Booking closed ' || coalesce((v_terms->>'cutoff_min')::integer, 60) || ' minutes before leaving.';
  end if;
  if t.women_only and not public.c2c_verified_woman(v_uid) then
    raise exception 'C2C_WOMEN_ONLY' using errcode = '22023',
      hint = 'This trip is for women only. Verify your ID in your profile to book it.';
  end if;
  if exists (select 1 from public.c2c_bookings x
              where x.trip_id = t.id and x.rider_id = v_uid
                and x.status in ('requested', 'booked', 'driver_arriving', 'on_trip')
                and (x.item = 'parcel') = v_parcel) then
    raise exception 'C2C_ALREADY_BOOKED' using errcode = '22023',
      hint = case when v_parcel then 'You already sent a parcel on this trip.'
                  else 'You already have seats on this trip. Cancel them to book again.' end;
  end if;
  select * into k from public.c2c_trip_taken(t.id);

  -- Seats and who rides, or the parcel.
  if v_parcel then
    v_seats := 1;
    if t.parcel_slots - k.parcels < 1 then
      raise exception 'C2C_NO_PARCELS' using errcode = '22023', hint = 'This trip has no parcel space left.';
    end if;
    if coalesce(array_position(v_sizes, p_parcel->>'size'), 99) > coalesce(array_position(v_sizes, t.parcel_max_size), 0)
    then
      raise exception 'C2C_NO_PARCELS' using errcode = '22023',
        hint = 'This trip takes parcels up to ' || coalesce(t.parcel_max_size, 'small') || '.';
    end if;
    if char_length(btrim(coalesce(p_parcel->>'recipientName', ''))) not between 1 and 120
       or coalesce(p_parcel->>'recipientPhone', '') !~ '^\+?[0-9 ]{6,20}$'
       or char_length(coalesce(p_parcel->>'note', '')) > 200 then
      raise exception 'C2C_NAMES' using errcode = '22023', hint = 'Give the recipient''s name and phone number.';
    end if;
    v_names := null;
  else
    v_seats := coalesce(p_seats, 0);
    v_max := case when coalesce((v_terms->>'coriders_on')::boolean, false)
                  then coalesce((v_terms->>'max_per_booking')::integer, 1) else 1 end;
    if v_seats < 1 or v_seats > v_max then
      raise exception 'C2C_TOO_MANY_SEATS' using errcode = '22023',
        hint = case when v_max = 1 then 'Book 1 seat at a time here.' else 'Book 1 to ' || v_max || ' seats.' end;
    end if;
    if t.seats_total - k.seats < v_seats then
      raise exception 'C2C_NO_SEATS' using errcode = '22023',
        hint = case when t.seats_total - k.seats <= 0 then 'This trip is full.'
                    when t.seats_total - k.seats = 1 then 'Only 1 seat is left.'
                    else 'Only ' || (t.seats_total - k.seats) || ' seats are left.' end;
    end if;
    if v_seats > 1 then
      if coalesce(jsonb_typeof(p_passengers), '') <> 'array' or jsonb_array_length(p_passengers) <> v_seats
         or exists (select 1 from jsonb_array_elements(p_passengers) e
                     where char_length(btrim(coalesce(e->>'name', ''))) not between 1 and 80) then
        raise exception 'C2C_NAMES' using errcode = '22023', hint = 'Name each passenger, one a seat.';
      end if;
    end if;
    v_names := case when coalesce(jsonb_typeof(p_passengers), '') = 'array' and jsonb_array_length(p_passengers) > 0 then
      (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'name', left(btrim(e->>'name'), 80),
                'familyMemberId', nullif(btrim(coalesce(e->>'familyMemberId', '')), ''))) order by n)
         from jsonb_array_elements(p_passengers) with ordinality x(e, n) where n <= v_seats) end;
  end if;

  -- Where.
  v_kind := coalesce(p_pickup->>'kind', 'meeting');
  if v_kind = 'door' then
    if not t.door_pickup or not coalesce((v_terms->>'door_on')::boolean, false) then
      raise exception 'C2C_DOOR_OFF' using errcode = '22023', hint = 'This trip has no door pickup. Pick a meeting point.';
    end if;
    if coalesce(jsonb_typeof(p_pickup->'lat'), '') <> 'number' or coalesce(jsonb_typeof(p_pickup->'lng'), '') <> 'number'
       or char_length(btrim(coalesce(p_pickup->>'name', ''))) not between 1 and 200 then
      raise exception 'C2C_BAD_TRIP' using errcode = '22023', hint = 'Pick your pickup address again.';
    end if;
    v_plat := (p_pickup->>'lat')::double precision;
    v_plng := (p_pickup->>'lng')::double precision;
    -- Off the route: the straight line to the nearest meeting point.
    select min(public.km_between(v_plat, v_plng, (e->>'lat')::double precision, (e->>'lng')::double precision)),
           (array_agg((e->>'minutes')::integer
                      order by public.km_between(v_plat, v_plng, (e->>'lat')::double precision,
                                                 (e->>'lng')::double precision)))[1]
      into v_km, v_index
      from jsonb_array_elements(t.meeting_points) e;
    v_km := round(v_km::numeric, 1);
    if v_km > t.door_max_km then
      raise exception 'C2C_DOOR_TOO_FAR' using errcode = '22023',
        hint = 'Your address is ' || v_km || ' km off the route; door pickup is up to ' || t.door_max_km
               || ' km. Pick a meeting point.';
    end if;
    v_extra := public.c2c_door_extra(v_km, t.door_per_km);
    v_pname := btrim(p_pickup->>'name');
    v_paddr := left(nullif(btrim(coalesce(p_pickup->>'address', '')), ''), 400);
    v_leave := t.leave_at + make_interval(mins => coalesce(v_index, 0));
    v_index := null;
  else
    v_kind := 'meeting';
    v_index := coalesce((p_pickup->>'index')::integer, 0);
    v_mp := t.meeting_points->v_index;
    if v_mp is null or v_index < 0 then
      raise exception 'C2C_BAD_TRIP' using errcode = '22023', hint = 'Pick a meeting point.';
    end if;
    v_plat := (v_mp->>'lat')::double precision;
    v_plng := (v_mp->>'lng')::double precision;
    v_pname := v_mp->>'name';
    v_paddr := v_mp->>'address';
    v_leave := t.leave_at + make_interval(mins => (v_mp->>'minutes')::integer);
  end if;
  select * into pl from public.commission_places(v_plat, v_plng, t.from_place->>'country', t.from_place->>'state',
                                                 t.from_place->>'city', t.from_place->>'suburb');
  v_pplace := jsonb_strip_nulls(jsonb_build_object('country', pl.place_country, 'state', pl.place_state,
                                                   'city', pl.place_city, 'suburb', pl.place_suburb));

  -- How to pay. Family is an in-app way (the host's GET.wallet).
  select * into s from public.city_to_city_settings where id = 1;
  if p_payment not in ('in_app', 'cash', 'family')
     or (p_payment in ('in_app', 'family') and not coalesce(s.pay_in_app, true))
     or (p_payment = 'cash' and not coalesce(s.pay_cash, true)) then
    raise exception 'C2C_PAYMENT_NOT_ALLOWED' using errcode = '22023',
      hint = case when coalesce(s.pay_cash, true) then 'Pay in cash for City to City trips.'
                  else 'Pay in the app for City to City trips.' end;
  end if;
  -- Who it is for in the family: {passenger, withAdult}; nothing else is kept.
  if p_family is not null and jsonb_typeof(p_family) = 'object' and public.family_passenger_of(p_family) is not null then
    v_family := jsonb_build_object('passenger', public.family_passenger_of(p_family))
                || case when coalesce((p_family->>'withAdult')::boolean, false)
                        then '{"withAdult": true}'::jsonb else '{}'::jsonb end;
  end if;
  v_fare := case when v_parcel then t.parcel_price else round(t.seat_price * v_seats + v_extra, 2) end;
  if coalesce(v_fare, 0) <= 0 then
    raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023', hint = 'This trip has no price set.';
  end if;

  insert into public.c2c_bookings (rider_id, service, trip_kind, trip_id, item, pickup_name, pickup_address, pickup_lat,
                                   pickup_lng, pickup_place, drop_name, drop_address, drop_lat, drop_lng, drop_place,
                                   distance_km, duration_min, leave_at, flexible, timezone, passengers, luggage, note,
                                   fare, currency, quote, payment, status, expires_at, driver_id, seat_price,
                                   pickup_kind, meeting_index, door_km, door_extra, passenger_names, parcel, family)
  values (v_uid, 'City to City', 'per_seat', t.id, case when v_parcel then 'parcel' else 'seat' end, v_pname, v_paddr,
          v_plat, v_plng, v_pplace, t.to_name, t.to_address, t.to_lat, t.to_lng, t.to_place, t.distance_km,
          t.duration_min, v_leave, false, t.timezone, v_seats, case when t.luggage = 'suitcase' then 'suitcases' else 'small' end,
          left(nullif(btrim(coalesce(p_note, '')), ''), 300), v_fare, t.currency,
          jsonb_build_object('seatPrice', t.seat_price, 'seats', v_seats, 'doorExtra', v_extra, 'tripRef', t.ref),
          p_payment, 'requested',
          case when t.join_mode = 'approve'
               then least(now() + make_interval(hours => coalesce((v_terms->>'approve_hours')::integer, 2)),
                          t.leave_at - make_interval(mins => coalesce((v_terms->>'approve_before_min')::integer, 60))) end,
          t.driver_id, case when v_parcel then null else t.seat_price end, v_kind, v_index,
          case when v_kind = 'door' then v_km end, case when v_kind = 'door' then v_extra end, v_names,
          case when v_parcel then jsonb_strip_nulls(jsonb_build_object(
                 'size', p_parcel->>'size', 'note', nullif(btrim(coalesce(p_parcel->>'note', '')), ''),
                 'recipientName', btrim(p_parcel->>'recipientName'),
                 'recipientPhone', btrim(p_parcel->>'recipientPhone'))) end,
          v_family)
  returning * into b;
  if b.expires_at is not null and b.expires_at <= now() then
    raise exception 'C2C_BOOKING_CLOSED' using errcode = '22023',
      hint = 'It is too close to leaving for the driver to approve a request.';
  end if;

  -- The money, as 0309's accept: held now, paid after, or the fees owed for
  -- a cash trip's driver to collect.
  if p_payment in ('in_app', 'family') then
    select * into pr from public.c2c_pay_rule_for(t.from_place);
    v_mode := coalesce(pr.when_mode, 'hold');
    if v_mode = 'hold' then
      p := public.c2c_take_fare(b, v_fare,
                                case when p_payment = 'family' then coalesce(p_method, 'get_wallet')
                                     else coalesce(p_method, case when pr.pay_mix then 'mix'
                                                                  when pr.pay_wallet then 'get_wallet'
                                                                  else 'get_coin' end) end,
                                p_expected, pr, true);
      v_status := 'held';
    end if;
  else
    select x.ids, x.total into v_collect_ids, v_collect from public.c2c_dues_to_collect(v_uid) x;
  end if;
  update public.c2c_bookings
     set pay_mode = v_mode, pay_status = v_status, paid_method = p.method, paid_amount = p.amount,
         collect_fee_ids = v_collect_ids, collect_amount = v_collect
   where id = b.id
  returning * into b;

  if t.join_mode = 'instant' then
    b := public.c2c_seat_confirm(b.id);
    perform public.c2c_seat_notify(t.driver_id, 'c2c-seat:' || b.id || ':booked',
      case when v_parcel then 'A parcel on your trip' else 'Seat booked on your trip' end,
      public.c2c_short_name((select name from public.profiles where id = v_uid))
      || case when v_parcel then ' sends a ' || (p_parcel->>'size') || ' parcel'
              else ' booked ' || v_seats || case when v_seats = 1 then ' seat' else ' seats' end end
      || ', ' || public.c2c_clock(t.leave_at, t.timezone) || ' to ' || coalesce(t.to_place->>'city', t.to_name) || '.',
      b, 'partner');
  else
    perform public.c2c_seat_notify(t.driver_id, 'c2c-seat:' || b.id || ':requested', 'New seat request',
      public.c2c_short_name((select name from public.profiles where id = v_uid))
      || case when v_parcel then ' asks to send a parcel' else ' asks for ' || v_seats
              || case when v_seats = 1 then ' seat' else ' seats' end end
      || '. Approve or decline before ' || public.c2c_clock(b.expires_at, t.timezone) || '.',
      b, 'partner');
  end if;
  return jsonb_build_object('id', b.id, 'ref', b.ref, 'status', b.status, 'fare', b.fare, 'payStatus', b.pay_status,
                            'held', p.amount, 'dues', coalesce(p.dues_amount, 0), 'expiresAt', b.expires_at);
end;
$$;
revoke execute on function public.c2c_book_seat(uuid, integer, jsonb, text, jsonb, text, numeric, jsonb, text, jsonb)
  from public, anon;
grant execute on function public.c2c_book_seat(uuid, integer, jsonb, text, jsonb, text, numeric, jsonb, text, jsonb)
  to authenticated, service_role;

-- Whether the family pays a tip on ride [r]: a trip the family pays (not
-- paid by the member themselves), the 'tips' module's Family payment on at
-- the ride's place, and tips among the services the host allows the member.
create or replace function public.family_tip_paid_by_family(r public.ride_requests)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.family_trips t join public.family_members m on m.id = t.member_id
     where t.trip_id = r.id and t.family_pays and t.released_at is null
       and (m.services is null or 'tips' = any (m.services))
       and coalesce((public.family_module_rule_at('tips', jsonb_build_object(
             'country', r.country, 'state', r.state, 'city', r.city, 'suburb', r.suburb))->>'familyPays')::boolean, false));
$$;
revoke execute on function public.family_tip_paid_by_family(public.ride_requests) from public, anon, authenticated;

-- As 0314, with a GET.wallet tip on a trip the family pays (and where the
-- admin lets the family pay tips: the 'tips' module, the member's services)
-- charged naming the trip, the payer's balance checked: it comes from the
-- host's GET.wallet within the member's limits. Coins are always the
-- rider's own.
create or replace function public.ride_tip(p_ride uuid, p_amount numeric, p_method text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  x jsonb;
  t public.ride_tips;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric;
  v_driver numeric;
  v_coin_rate numeric;
  v_coins numeric;
  v_balance numeric;
  v_money text;
  v_rider text;
  v_trip uuid;
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_method not in ('get_wallet', 'get_coin') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' then
    raise exception 'TIP_NOT_COMPLETED' using errcode = '42501', hint = 'You can tip once the trip is complete.';
  end if;
  if r.partner_id is null or r.partner_id = r.rider_id then
    raise exception 'TIP_OWN_TRIP' using errcode = '42501', hint = 'You can''t tip your own trip.';
  end if;
  -- Once per ride: a second call (a retry) answers with the first.
  select * into t from public.ride_tips where ride_id = r.id and method <> 'cash';
  if found then
    return jsonb_build_object('already', true, 'amount', t.amount, 'method', t.method,
                              'driverAmount', t.driver_amount);
  end if;
  x := public.city_ride_extras_for(r)->'tips';
  if not public.city_ride_extras_on(x) then
    raise exception 'TIP_OFF' using errcode = '42501', hint = 'Tips aren''t taken here.';
  end if;
  if now() > coalesce(r.completed_at, now())
             + make_interval(days => public.city_ride_extras_num(x, 'days', 3)::integer) then
    raise exception 'TIP_EXPIRED' using errcode = '42501', hint = 'The time to tip this trip has passed.';
  end if;
  if not public.ride_money_ok(v_amount) or v_amount < public.city_ride_extras_num(x, 'min', 1)
     or v_amount > public.city_ride_extras_num(x, 'max', 100) then
    raise exception 'TIP_AMOUNT' using errcode = '22023',
      hint = format('Tip from %s to %s.', trim_scale(public.city_ride_extras_num(x, 'min', 1)),
                    trim_scale(public.city_ride_extras_num(x, 'max', 100)));
  end if;
  v_rate := least(0.5, greatest(0, public.city_ride_extras_num(x, 'commissionPercent', 0) / 100));
  v_driver := round(v_amount * (1 - v_rate), 2);
  v_money := coalesce(r.currency, 'RM') || ' ' || to_char(v_amount, 'FM999999990.00');
  v_rider := coalesce(nullif(split_part(btrim(coalesce(r.rider_name, '')), ' ', 1), ''), 'Your rider');

  if p_method = 'get_wallet' then
    -- Family: the trip is named only where the family pays the tip too.
    if public.family_tip_paid_by_family(r) then
      v_trip := r.id;
    end if;
    v_owner := case when v_trip is null then v_uid else public.family_wallet_owner(r.id, v_uid, v_amount) end;
    insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
    select w.balance into v_balance from public.wallets w
     where w.user_id = v_owner and w.wallet_type = 'get_wallet' for update;
    if coalesce(v_balance, 0) < v_amount then
      raise exception 'insufficient_balance' using errcode = '22023',
        hint = case when v_owner = v_uid then 'Top up GET.wallet, or tip with GET.coin.'
                    else 'Your family host''s GET.wallet is short. Tip with GET.coin, or ask them to top up.' end;
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (v_uid, 'get_wallet', 'tip', -v_amount, 'tip', 'Tip for ' || coalesce(r.partner_name, 'your driver'), v_trip);
  else
    select s.coins_per_currency into v_coin_rate from public.get_coin_settings s where s.id = 'master';
    if coalesce(v_coin_rate, 0) <= 0 then
      raise exception 'coins_unavailable' using errcode = '22023';
    end if;
    v_coins := ceil(v_amount * v_coin_rate * 100) / 100;
    insert into public.wallets (user_id, wallet_type, balance) values (v_uid, 'get_coin', 0)
    on conflict (user_id, wallet_type) do nothing;
    select w.balance into v_balance from public.wallets w
     where w.user_id = v_uid and w.wallet_type = 'get_coin' for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_balance' using errcode = '22023', hint = 'Not enough GET.coin for this tip.';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_uid, 'get_coin', 'redeem', -v_coins, 'tip',
            'Tip for ' || coalesce(r.partner_name, 'your driver') || ' (' || v_money || ')');
  end if;
  if v_driver > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (r.partner_id, 'get_wallet', 'tip', v_driver, 'tip',
            'Tip from ' || v_rider || case when v_rate > 0
              then ' (less ' || trim_scale(round(v_rate * 100, 1)) || '% commission)' else '' end, r.id);
  end if;
  insert into public.ride_tips (ride_id, rider_id, partner_id, method, amount, commission_rate, driver_amount,
                                coins_used, currency)
  values (r.id, v_uid, r.partner_id, p_method, v_amount, v_rate, v_driver, v_coins, r.currency)
  returning * into t;

  begin
    perform public.enqueue_notification(r.partner_id, 'ride_tip:' || t.id, 'ride_tip', 'normal',
      'You got a tip', v_rider || ' tipped you ' || v_money || '.',
      jsonb_build_object('type', 'ride_tip', 'rideId', r.id), r.id);
  exception when others then
    raise warning 'tip push for % not sent: %', t.id, sqlerrm;
  end;

  return jsonb_build_object('already', false, 'amount', t.amount, 'method', t.method,
                            'driverAmount', t.driver_amount, 'coins', coalesce(v_coins, 0),
                            'family', v_trip is not null and v_owner is distinct from v_uid);
end;
$$;
revoke execute on function public.ride_tip(uuid, numeric, text) from public, anon;
grant execute on function public.ride_tip(uuid, numeric, text) to authenticated;

-- Business accounts (0313): a trip the company pays is not one the family
-- pays. A booking with both is refused (FAMILY_BUSINESS) before 0313's
-- trigger (trg_ride_requests_c_business, trg_scheduled_rides_a_business)
-- turns its payment into the company's. Booking for a family member on a
-- business account stays as 0313 allows it (the company pays).
create or replace function public.family_not_business()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business boolean;
  v_family boolean;
begin
  if tg_table_name = 'scheduled_rides' then
    v_business := coalesce(new.request->>'business_account_id', '') <> '' and new.stand_id is null;
    v_family := lower(btrim(coalesce(new.request->>'payment_mode', ''))) = 'family';
  else
    v_business := new.business_account_id is not null;
    v_family := lower(btrim(coalesce(new.payment_mode, ''))) = 'family';
  end if;
  if v_business and v_family then
    raise exception 'FAMILY_BUSINESS' using errcode = 'P0001',
      hint = 'A business trip is paid by the company. Pay with Family or the business account, not both.';
  end if;
  return new;
end;
$$;
revoke execute on function public.family_not_business() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_b_family_not_business on public.ride_requests;
create trigger trg_ride_requests_b_family_not_business
  before insert on public.ride_requests
  for each row execute function public.family_not_business();
drop trigger if exists trg_scheduled_rides_0_family_not_business on public.scheduled_rides;
create trigger trg_scheduled_rides_0_family_not_business
  before insert on public.scheduled_rides
  for each row execute function public.family_not_business();

-- ---- Live in the apps and the admin page --------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['booking_modules', 'family_places', 'family_module_rules'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
