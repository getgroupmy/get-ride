-- ============================================================================
-- 0310 — City to City per-seat trips (docs/KIV.md L8, part C5): a driver posts
-- a trip they are making anyway and riders book seats on it (the approved
-- boards 15 Admin, 16 Post a trip and 17 Book a seat).
--
-- Version 20261028030000 (0310_city_to_city_seats). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- constraints, policies and triggers dropped first, seed rows only where
-- missing.
--
-- Why seat bookings are c2c_bookings rows (trip_kind 'per_seat', trip_id
-- set): everything 0307 to 0309 built for a booking then works for each
-- seat booking unchanged: the commission lock and charge (City to City's
-- own commission settings, 0306), the cancel fee (c2c_cancel), in-app
-- payment held or paid after (c2c_take_fare, c2c_hold_refund,
-- c2c_hold_release, c2c_pay), cancel fees owed, the reminders, the chat
-- (ride_messages.c2c_booking_id, 0308: one thread per booking, so a seat
-- booking's thread needs no change), Call (c2c_contact), the rating and the
-- rider's My trips. The trip a driver posts is its own table, c2c_trips.
--
-- 1. c2c_seat_rules: a Default rule (place null, always there, never
--    deleted) and a rule per region (country, state, city or suburb). The
--    trip's start (its From place) picks: the most specific active region
--    rule wins, and a region rule overrides only what it sets (a null column
--    is taken from the next, less specific rule, at last the Default). Parts,
--    each set or left to the rule above as a whole: Per-seat trips on/off;
--    how riders join (instant, driver approves, or the driver picks per
--    trip; a request lapses after N hours or N minutes before leaving); the
--    seat price (a range, fixed by the admin, or the driver's own; the range
--    as a % of the whole-car fare or RM min and max); limits (seats a trip,
--    seats a booking, the cut-off before leaving, how far ahead to post);
--    door pickup (on/off, up to N km off the route, RM a km); women-only
--    trips; repeat trips (up to N weeks); co-riders (several seats with
--    names, and seeing who else rides); parcels (slots, the biggest size,
--    the price range). c2c_seat_terms_for(place) merges them. The Default
--    seeds with Per-seat trips OFF, so nothing changes until an admin turns
--    it on (the board's other choices are its values).
--    Seat price by route: 0306's c2c_route_rules rows with trip_kind
--    'per_seat' (kept for this) give one route a fixed seat price
--    (fare_mode 'fixed', fixed_fare) or an RM range (range_mode 'set',
--    range_low and range_high); matched as 0306 matches whole-car rules
--    (c2c_seat_route_rule_for). The whole-car fare is 0306's c2c_quote.
-- 2. c2c_trips: the posted trip: From and To (point, name and places; the
--    From places as the server reads them, 0224's commission_places), the
--    distance and time, when it leaves, 1 to 5 meeting points (each a
--    number of minutes after leaving), the seats, the seat price, instant or
--    approve, women only, door pickup (the km and RM a km as posted),
--    parcel slots (the biggest size, the price), luggage, a note, the
--    driver as riders see them, and a repeat series (series_id).
-- 3. c2c_post_trip (the driver): approved partner; Per-seat trips on at
--    the start; City to City on there (0306's c2c_available_at); the years
--    and permits (0306/0307's c2c_driver_eligibility, the country permits);
--    leaving 1 hour to the rule's days ahead; seats within the limit; the
--    price inside the limits (c2c_seat_limits) or the fixed price; instant
--    or approve as the rule says; women only only for a verified woman
--    driver and where the rule allows it; door pickup, repeat and parcels
--    only where the rule allows them, parcel slots, size and price within
--    the limits; not when the driver has another trip or a whole-car
--    booking at that time (C2C_DRIVER_BUSY). Repeat: daily, weekdays or
--    weekly until a date, up to the rule's weeks (at most 60 trips); the
--    instances are made at once (c2c_repeat_dates), one at a busy time is
--    skipped and counted. c2c_post_terms tells the post screen the rule,
--    the price limits, the commission rate now and whether the driver may
--    post.
-- 4. Riders: c2c_search_trips(from, to, day, seats) lists the trips
--    (seats left, the driver, the tags, the meeting points, door pickup);
--    c2c_book_seat books 1 or more seats (with each passenger's name when
--    more than 1, co-riders on) at a meeting point or the rider's door, or a
--    parcel slot. The trip row is locked first (FOR UPDATE), so seats are
--    never overbooked: requests waiting for the driver hold their seats
--    until they lapse. Refused with a code and the rider's words in the
--    hint: C2C_SEATS_OFF, C2C_BOOKING_CLOSED (the cut-off), C2C_NO_SEATS,
--    C2C_WOMEN_ONLY, C2C_DOOR_OFF, C2C_DOOR_TOO_FAR, C2C_NO_PARCELS,
--    C2C_TOO_MANY_SEATS, C2C_NAMES, C2C_ALREADY_BOOKED, C2C_OWN_TRIP,
--    C2C_PAYMENT_NOT_ALLOWED (and 0309's C2C_FEES_OWED, C2C_WALLET_SHORT,
--    C2C_AMOUNT_CHANGED). The fare: seat price x seats, plus door pickup
--    (km off the route, to 0.1 km, x the RM a km; the km is the straight
--    line to the nearest meeting point), or the parcel price. In app: the
--    pickup's pay rule (0309): held now (also for a request waiting for the
--    driver; back in full if declined or lapsed) or paid after the trip.
--    Instant: booked at once. Approve: 'requested' until the driver
--    approves (c2c_seat_decide) or it lapses (c2c_expire_due, every 5
--    minutes: 'expired', the held fare back). c2c_coriders(booking): who
--    else rides (first name, rating, where they are picked up), booked
--    riders only, where the rule shows co-riders. c2c_seat_pay_info(trip):
--    the pay sheet before booking.
-- 5. Drivers: c2c_seat_decide(booking, approve, reason) (approve: booked,
--    the commission locked; decline: 'declined', the held fare back);
--    c2c_driver_seat_trips() (their trips with the requests and passengers);
--    c2c_trip_progress(trip, on_trip | completed): start moves every booked
--    seat on the trip (0309's c2c_driver_progress, so each is charged and
--    paid as a booking is) and declines the requests still waiting; finish
--    completes them. c2c_trip_cancel(trip, reason, whole series): before
--    leaving; each booked rider gets the give-up fee of their pickup's rule
--    (0309's c2c_giveup_rules: the driver charged once per affected rider)
--    and a held fare back; requests are declined. An admin with EDIT may
--    cancel too, free. A seat booking can't be given up alone
--    (c2c_driver_cancel refuses it: C2C_SEAT_TRIP).
-- 6. Women only: a verified woman is a profile with gender 'female' and an
--    ID verified (profiles.id_verified 'Verified') or an approved partner
--    (whose IC was checked). So that a verified ID's gender can't be
--    changed by its owner, trg_profiles_d_verified_gender lets only admins
--    and the server change it then.
-- 7. Chat (0308): a seat request waiting for the driver may already be
--    chatted on (the insert policy also takes 'requested').
-- 8. Admins with EDIT on admin-settings-city-to-city-seats (or on City to
--    City) write the seat rules (admin_table_pages); everyone signed in
--    reads them. Trips: their driver, riders booked on them, admins, and
--    anyone signed in while scheduled (a trip is a public offer); only these
--    functions write. None of the functions here is on 0223's rewrite list.
--    Redefined, behaviour kept: 0307's c2c_bookings_check (a per-seat row
--    is checked by c2c_book_seat) and its insert policy (whole car only),
--    c2c_expire_due (also lapses seat requests), 0309's c2c_driver_cancel
--    (refuses a seat booking) and c2c_send_reminders (the driver's name from
--    the trip), and 0308's chat insert policy.
-- 9. Rider blocks (0311's rider_blocks, looked up when it runs, so 0310
--    works before or after 0311): a rider doesn't see or book the trips of a
--    driver they blocked (DRIVER_BLOCKED); the driver doesn't see, approve
--    or chat on their seat requests (restrictive "c2c_bookings seat request
--    blocks", c2c_driver_seat_trips, c2c_seat_decide: C2C_NOT_OPEN), and
--    c2c_expire_due withdraws such a request with the held fare back.
--    0311's in-place edit of c2c_driver_requests is untouched (0310 doesn't
--    redefine it; seat rows are never open requests).
-- ============================================================================

-- ---- 1. Seat rules ----------------------------------------------------------------------------------------
create table if not exists public.c2c_seat_rules (
  id                 uuid primary key default gen_random_uuid(),
  -- Null: the Default, for every start without a region rule.
  place              jsonb check (public.c2c_place_valid(place)),
  active             boolean not null default true,
  -- Each part below: null on a region rule takes it from the rule above.
  seats_on           boolean,
  join_mode          text check (join_mode in ('instant', 'approve', 'driver_picks')),
  approve_hours      integer check (approve_hours between 1 and 72),
  approve_before_min integer check (approve_before_min between 0 and 1440),
  price_mode         text check (price_mode in ('range', 'fixed', 'free')),
  range_mode         text check (range_mode in ('percent', 'amount')),
  pct_low            numeric(6,2) check (pct_low between 1 and 100),
  pct_high           numeric(6,2) check (pct_high between 1 and 100),
  amount_low         numeric(10,2) check (amount_low between 1 and 100000),
  amount_high        numeric(10,2) check (amount_high between 1 and 100000),
  max_seats          integer check (max_seats between 1 and 8),
  max_per_booking    integer check (max_per_booking between 1 and 6),
  cutoff_min         integer check (cutoff_min between 0 and 1440),
  post_ahead_days    integer check (post_ahead_days between 1 and 90),
  door_on            boolean,
  door_max_km        numeric(6,2) check (door_max_km between 0.5 and 50),
  door_per_km        numeric(10,2) check (door_per_km between 0 and 1000),
  women_on           boolean,
  repeat_on          boolean,
  repeat_max_weeks   integer check (repeat_max_weeks between 1 and 12),
  coriders_on        boolean,
  parcels_on         boolean,
  parcel_max_slots   integer check (parcel_max_slots between 1 and 6),
  parcel_max_size    text check (parcel_max_size in ('small', 'medium', 'large')),
  parcel_min_price   numeric(10,2) check (parcel_min_price between 0 and 10000),
  parcel_max_price   numeric(10,2) check (parcel_max_price between 0 and 10000),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  -- A part is set whole or not at all; the Default sets every part.
  constraint c2c_seat_rules_join check (num_nulls(join_mode, approve_hours, approve_before_min) in (0, 3)),
  constraint c2c_seat_rules_price check (num_nulls(price_mode, range_mode, pct_low, pct_high, amount_low, amount_high) in (0, 6)),
  constraint c2c_seat_rules_limits check (num_nulls(max_seats, max_per_booking, cutoff_min, post_ahead_days) in (0, 4)),
  constraint c2c_seat_rules_door check (num_nulls(door_on, door_max_km, door_per_km) in (0, 3)),
  constraint c2c_seat_rules_repeat check (num_nulls(repeat_on, repeat_max_weeks) in (0, 2)),
  constraint c2c_seat_rules_parcels check (num_nulls(parcels_on, parcel_max_slots, parcel_max_size, parcel_min_price,
                                                     parcel_max_price) in (0, 5)),
  constraint c2c_seat_rules_ranges check ((pct_low is null or pct_low <= pct_high)
                                          and (amount_low is null or amount_low <= amount_high)
                                          and (parcel_min_price is null or parcel_min_price <= parcel_max_price)),
  constraint c2c_seat_rules_default check (place is not null or num_nulls(
    seats_on, join_mode, price_mode, max_seats, door_on, women_on, repeat_on, coriders_on, parcels_on) = 0)
);
create unique index if not exists c2c_seat_rules_default on public.c2c_seat_rules ((true)) where place is null;
create unique index if not exists c2c_seat_rules_place on public.c2c_seat_rules (lower(place::text)) where place is not null;
comment on table public.c2c_seat_rules is
  'City to City per-seat trips (0310): the Default (place null) and region rules; the trip start''s most specific region wins, a region rule overriding only what it sets.';

insert into public.c2c_seat_rules (id, place, seats_on, join_mode, approve_hours, approve_before_min, price_mode, range_mode,
                                   pct_low, pct_high, amount_low, amount_high, max_seats, max_per_booking, cutoff_min,
                                   post_ahead_days, door_on, door_max_km, door_per_km, women_on, repeat_on, repeat_max_weeks,
                                   coriders_on, parcels_on, parcel_max_slots, parcel_max_size, parcel_min_price, parcel_max_price)
select '63326331-0000-4000-8000-000000000310', null, false, 'driver_picks', 2, 60, 'range', 'percent',
       25, 40, 30, 60, 4, 4, 60, 30, true, 5, 1, true, true, 8, true, false, 2, 'medium', 5, 30
 where not exists (select 1 from public.c2c_seat_rules where place is null)
on conflict (id) do nothing;

do $rls$
begin
  drop trigger if exists trg_c2c_seat_rules_stamp on public.c2c_seat_rules;
  create trigger trg_c2c_seat_rules_stamp before insert or update on public.c2c_seat_rules
    for each row execute function public.c2c_stamp();
  -- 0309's guard: the Default is never removed nor given a region.
  drop trigger if exists trg_c2c_seat_rules_guard on public.c2c_seat_rules;
  create trigger trg_c2c_seat_rules_guard before update or delete on public.c2c_seat_rules
    for each row execute function public.c2c_region_rule_guard();
  alter table public.c2c_seat_rules enable row level security;
  revoke all on public.c2c_seat_rules from anon;
  grant select, insert, update, delete on public.c2c_seat_rules to authenticated;
  grant all on public.c2c_seat_rules to service_role;
  drop policy if exists "c2c_seat_rules read" on public.c2c_seat_rules;
  create policy "c2c_seat_rules read" on public.c2c_seat_rules for select to authenticated
    using ((select auth.uid()) is not null);
  drop policy if exists "c2c_seat_rules admin insert" on public.c2c_seat_rules;
  create policy "c2c_seat_rules admin insert" on public.c2c_seat_rules for insert to authenticated
    with check ((select public.caller_admin_can_write('c2c_seat_rules')));
  drop policy if exists "c2c_seat_rules admin update" on public.c2c_seat_rules;
  create policy "c2c_seat_rules admin update" on public.c2c_seat_rules for update to authenticated
    using ((select public.caller_admin_can_write('c2c_seat_rules')))
    with check ((select public.caller_admin_can_write('c2c_seat_rules')));
  drop policy if exists "c2c_seat_rules admin delete" on public.c2c_seat_rules;
  create policy "c2c_seat_rules admin delete" on public.c2c_seat_rules for delete to authenticated
    using ((select public.caller_admin_can_write('c2c_seat_rules')));
end
$rls$;

-- The rule merged for a trip starting at [p_place] ({country, state, city,
-- suburb}): each column from the most specific active rule that sets it,
-- the Default last. The columns by name, and 'ruleIds' (most specific first).
-- lib/src/core/city_to_city_seats.dart's c2cSeatTermsFor is its twin.
create or replace function public.c2c_seat_terms_for(p_place jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with r as (
    select x.*, case when x.place is null then 0
                     else public.c2c_place_rank(x.place, coalesce(p_place, '{}'::jsonb)) end as rk
      from public.c2c_seat_rules x
     where x.place is null or x.active)
  select jsonb_build_object(
    'seats_on', (array_agg(seats_on order by rk desc, created_at, id) filter (where seats_on is not null))[1],
    'join_mode', (array_agg(join_mode order by rk desc, created_at, id) filter (where join_mode is not null))[1],
    'approve_hours', (array_agg(approve_hours order by rk desc, created_at, id) filter (where join_mode is not null))[1],
    'approve_before_min', (array_agg(approve_before_min order by rk desc, created_at, id) filter (where join_mode is not null))[1],
    'price_mode', (array_agg(price_mode order by rk desc, created_at, id) filter (where price_mode is not null))[1],
    'range_mode', (array_agg(range_mode order by rk desc, created_at, id) filter (where price_mode is not null))[1],
    'pct_low', (array_agg(pct_low order by rk desc, created_at, id) filter (where price_mode is not null))[1],
    'pct_high', (array_agg(pct_high order by rk desc, created_at, id) filter (where price_mode is not null))[1],
    'amount_low', (array_agg(amount_low order by rk desc, created_at, id) filter (where price_mode is not null))[1],
    'amount_high', (array_agg(amount_high order by rk desc, created_at, id) filter (where price_mode is not null))[1],
    'max_seats', (array_agg(max_seats order by rk desc, created_at, id) filter (where max_seats is not null))[1],
    'max_per_booking', (array_agg(max_per_booking order by rk desc, created_at, id) filter (where max_seats is not null))[1],
    'cutoff_min', (array_agg(cutoff_min order by rk desc, created_at, id) filter (where max_seats is not null))[1],
    'post_ahead_days', (array_agg(post_ahead_days order by rk desc, created_at, id) filter (where max_seats is not null))[1],
    'door_on', (array_agg(door_on order by rk desc, created_at, id) filter (where door_on is not null))[1],
    'door_max_km', (array_agg(door_max_km order by rk desc, created_at, id) filter (where door_on is not null))[1],
    'door_per_km', (array_agg(door_per_km order by rk desc, created_at, id) filter (where door_on is not null))[1],
    'women_on', (array_agg(women_on order by rk desc, created_at, id) filter (where women_on is not null))[1],
    'repeat_on', (array_agg(repeat_on order by rk desc, created_at, id) filter (where repeat_on is not null))[1],
    'repeat_max_weeks', (array_agg(repeat_max_weeks order by rk desc, created_at, id) filter (where repeat_on is not null))[1],
    'coriders_on', (array_agg(coriders_on order by rk desc, created_at, id) filter (where coriders_on is not null))[1],
    'parcels_on', (array_agg(parcels_on order by rk desc, created_at, id) filter (where parcels_on is not null))[1],
    'parcel_max_slots', (array_agg(parcel_max_slots order by rk desc, created_at, id) filter (where parcels_on is not null))[1],
    'parcel_max_size', (array_agg(parcel_max_size order by rk desc, created_at, id) filter (where parcels_on is not null))[1],
    'parcel_min_price', (array_agg(parcel_min_price order by rk desc, created_at, id) filter (where parcels_on is not null))[1],
    'parcel_max_price', (array_agg(parcel_max_price order by rk desc, created_at, id) filter (where parcels_on is not null))[1],
    'ruleIds', coalesce(jsonb_agg(id order by rk desc, created_at, id), '[]'::jsonb))
    from r
   where r.place is null or r.rk > 0;
$$;
revoke execute on function public.c2c_seat_terms_for(jsonb) from public, anon;
grant execute on function public.c2c_seat_terms_for(jsonb) to authenticated, service_role;

-- The per-seat route rule (0306's c2c_route_rules, trip_kind 'per_seat')
-- for a trip from [p_pickup] to [p_drop], in 0306's order; none: no row.
create or replace function public.c2c_seat_route_rule_for(p_pickup jsonb, p_drop jsonb)
returns setof public.c2c_route_rules
language sql
stable
security definer
set search_path = public
as $$
  select (x.r).*
    from (select r, public.c2c_side_rank(r.from_places, p_pickup) as fr, public.c2c_side_rank(r.to_places, p_drop) as tr
            from public.c2c_route_rules r
           where r.active and r.trip_kind = 'per_seat') x
   where x.fr > 0 and x.tr > 0
   order by x.fr + x.tr desc, x.fr desc, (x.r).position asc, (x.r).created_at asc, (x.r).id asc
   limit 1;
$$;
revoke execute on function public.c2c_seat_route_rule_for(jsonb, jsonb) from public, anon;
grant execute on function public.c2c_seat_route_rule_for(jsonb, jsonb) to authenticated, service_role;

-- The seat price limits under terms [p_terms] (c2c_seat_terms_for), the
-- route's per-seat rule [rr] (null: none) and the whole-car fare
-- [p_whole]: {mode: range | fixed | free, low, high, price, wholeCar,
-- routeRuleId}. Free: any price from 1. A route rule's fixed price or RM
-- range wins over the region's (not over Driver free); a region's fixed
-- price is the middle of its range. Whole units. c2cSeatLimits is its twin.
create or replace function public.c2c_seat_limits_of(p_terms jsonb, rr public.c2c_route_rules, p_whole numeric)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_mode text := coalesce(p_terms->>'price_mode', 'range');
  v_low numeric;
  v_high numeric;
begin
  if v_mode = 'free' then
    return jsonb_build_object('mode', 'free', 'low', 1, 'high', null, 'price', null, 'wholeCar', p_whole,
                              'routeRuleId', null);
  end if;
  if rr.id is not null and rr.fare_mode = 'fixed' and rr.fixed_fare is not null then
    return jsonb_build_object('mode', 'fixed', 'low', rr.fixed_fare, 'high', rr.fixed_fare, 'price', rr.fixed_fare,
                              'wholeCar', p_whole, 'routeRuleId', rr.id);
  end if;
  if rr.id is not null and rr.range_mode = 'set' and rr.range_low is not null then
    v_low := rr.range_low;
    v_high := rr.range_high;
  elsif p_terms->>'range_mode' = 'amount' then
    v_low := (p_terms->>'amount_low')::numeric;
    v_high := (p_terms->>'amount_high')::numeric;
  else
    v_low := greatest(round(coalesce(p_whole, 0) * (p_terms->>'pct_low')::numeric / 100), 1);
    v_high := greatest(round(coalesce(p_whole, 0) * (p_terms->>'pct_high')::numeric / 100), v_low);
  end if;
  if v_mode = 'fixed' then
    return jsonb_build_object('mode', 'fixed', 'low', round((v_low + v_high) / 2), 'high', round((v_low + v_high) / 2),
                              'price', round((v_low + v_high) / 2), 'wholeCar', p_whole, 'routeRuleId', rr.id);
  end if;
  return jsonb_build_object('mode', 'range', 'low', v_low, 'high', v_high, 'price', null, 'wholeCar', p_whole,
                            'routeRuleId', rr.id);
end;
$$;
revoke execute on function public.c2c_seat_limits_of(jsonb, public.c2c_route_rules, numeric) from public, anon;
grant execute on function public.c2c_seat_limits_of(jsonb, public.c2c_route_rules, numeric) to authenticated, service_role;

-- The limits for a trip from (p_lat, p_lng) named [p_from] to [p_to], [p_km]
-- km and [p_min] minutes, under [p_terms]: the whole-car fare from 0306's
-- c2c_quote, and the per-seat route rule.
create or replace function public.c2c_seat_limits(p_terms jsonb, p_lat double precision, p_lng double precision,
                                                  p_from jsonb, p_to jsonb, p_km numeric, p_min numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q jsonb;
  rr public.c2c_route_rules;
begin
  q := public.c2c_quote(p_lat, p_lng, p_from, p_to, p_km, p_min, 'City to City');
  select * into rr from public.c2c_seat_route_rule_for(coalesce(q->'pickup', p_from), p_to);
  return public.c2c_seat_limits_of(p_terms, rr, (q->>'suggested')::numeric)
         || jsonb_build_object('currency', coalesce(q->>'currency', 'MYR'));
end;
$$;
revoke execute on function public.c2c_seat_limits(jsonb, double precision, double precision, jsonb, jsonb, numeric, numeric)
  from public, anon, authenticated;

-- Door pickup's extra: [p_km] off the route to 0.1 km, at [p_per_km] a km,
-- in cents (c2cDoorExtra's twin).
create or replace function public.c2c_door_extra(p_km numeric, p_per_km numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(round(greatest(coalesce(p_km, 0), 0), 1) * greatest(coalesce(p_per_km, 0), 0), 2);
$$;

-- The repeats of a trip leaving at local time [p_start]: 'daily' every day,
-- 'weekdays' Monday to Friday, 'weekly' the same weekday; after the first,
-- up to the end of [p_until], at most [p_max] (c2cRepeatDates' twin).
create or replace function public.c2c_repeat_dates(p_start timestamp, p_mode text, p_until date, p_max integer default 60)
returns setof timestamp
language sql
immutable
set search_path = ''
as $$
  select d from (
    select p_start + make_interval(days => n) as d
      from generate_series(1, greatest(least(coalesce(p_until, p_start::date) - p_start::date, 400), 0)) n) x
   where case p_mode
           when 'daily' then true
           when 'weekdays' then extract(isodow from d) between 1 and 5
           when 'weekly' then extract(isodow from d) = extract(isodow from p_start)
           else false end
   order by d
   limit greatest(coalesce(p_max, 60), 0);
$$;

-- ---- 2. Trips ------------------------------------------------------------------------------------------------
create sequence if not exists public.c2c_trip_ref_seq start 5001;

-- 1 to 5 meeting points: {name 1..200, address, lat, lng, minutes 0..240 after leaving}.
create or replace function public.c2c_meeting_points_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p) = 'array', false)
     and jsonb_array_length(p) between 1 and 5
     and not exists (
       select 1 from jsonb_array_elements(p) e
        where case when jsonb_typeof(e) <> 'object' or coalesce(jsonb_typeof(e->'lat'), '') <> 'number'
                        or coalesce(jsonb_typeof(e->'lng'), '') <> 'number'
                        or coalesce(jsonb_typeof(e->'minutes'), '') <> 'number' then true
                   else char_length(btrim(coalesce(e->>'name', ''))) not between 1 and 200
                        or char_length(coalesce(e->>'address', '')) > 400
                        or (e->>'lat')::numeric not between -90 and 90
                        or (e->>'lng')::numeric not between -180 and 180
                        or (e->>'minutes')::numeric <> trunc((e->>'minutes')::numeric)
                        or (e->>'minutes')::numeric not between 0 and 240 end);
$$;

create table if not exists public.c2c_trips (
  id              uuid primary key default gen_random_uuid(),
  ref             text not null unique default ('CT-' || nextval('public.c2c_trip_ref_seq')),
  driver_id       uuid not null references public.profiles(id) on delete cascade,
  -- The first trip of a repeat; null when posted once.
  series_id       uuid,
  repeat_mode     text check (repeat_mode in ('daily', 'weekdays', 'weekly')),
  service         text not null default 'City to City',
  from_name       text not null check (char_length(btrim(from_name)) between 1 and 200),
  from_address    text check (from_address is null or char_length(from_address) <= 400),
  from_lat        double precision not null check (from_lat between -90 and 90),
  from_lng        double precision not null check (from_lng between -180 and 180),
  from_place      jsonb not null default '{}'::jsonb,
  to_name         text not null check (char_length(btrim(to_name)) between 1 and 200),
  to_address      text check (to_address is null or char_length(to_address) <= 400),
  to_lat          double precision not null check (to_lat between -90 and 90),
  to_lng          double precision not null check (to_lng between -180 and 180),
  to_place        jsonb not null default '{}'::jsonb,
  distance_km     numeric(8,2) not null check (distance_km > 0 and distance_km <= 5000),
  duration_min    numeric(8,1) not null check (duration_min >= 0 and duration_min <= 10000),
  leave_at        timestamptz not null,
  timezone        text check (timezone is null or char_length(timezone) <= 64),
  meeting_points  jsonb not null check (public.c2c_meeting_points_valid(meeting_points)),
  seats_total     smallint not null check (seats_total between 1 and 8),
  seat_price      numeric(10,2) not null check (seat_price > 0 and seat_price <= 100000),
  currency        text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  join_mode       text not null check (join_mode in ('instant', 'approve')),
  women_only      boolean not null default false,
  door_pickup     boolean not null default false,
  door_max_km     numeric(6,2),
  door_per_km     numeric(10,2),
  parcel_slots    smallint not null default 0 check (parcel_slots between 0 and 6),
  parcel_max_size text check (parcel_max_size in ('small', 'medium', 'large')),
  parcel_price    numeric(10,2) check (parcel_price is null or parcel_price between 0 and 10000),
  luggage         text not null default 'small' check (luggage in ('small', 'suitcase')),
  note            text check (note is null or char_length(note) <= 300),
  -- The price limits it was posted under (c2c_seat_limits).
  limits          jsonb not null default '{}'::jsonb,
  driver_name     text,
  driver_rating   numeric(3,2),
  car             text,
  plate           text,
  status          text not null default 'scheduled' check (status in ('scheduled', 'on_trip', 'completed', 'cancelled')),
  started_at      timestamptz,
  completed_at    timestamptz,
  cancelled_at    timestamptz,
  cancelled_by    text check (cancelled_by is null or cancelled_by in ('driver', 'admin')),
  cancel_reason   text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint c2c_trips_door check (not door_pickup or (door_max_km is not null and door_per_km is not null)),
  constraint c2c_trips_parcels check (parcel_slots = 0 or (parcel_max_size is not null and parcel_price is not null))
);
create index if not exists c2c_trips_driver_idx on public.c2c_trips (driver_id, leave_at desc);
create index if not exists c2c_trips_open_idx on public.c2c_trips (leave_at) where status = 'scheduled';
create index if not exists c2c_trips_series_idx on public.c2c_trips (series_id) where series_id is not null;
comment on table public.c2c_trips is
  'City to City (0310): a trip a driver posts; riders book seats on it (c2c_bookings with trip_id).';

drop trigger if exists trg_c2c_trips_stamp on public.c2c_trips;
create trigger trg_c2c_trips_stamp before update on public.c2c_trips
  for each row execute function public.c2c_offers_stamp();

-- ---- 2. Seat bookings on c2c_bookings ----------------------------------------------------------------------
alter table public.c2c_bookings add column if not exists trip_id uuid references public.c2c_trips(id) on delete cascade;
alter table public.c2c_bookings add column if not exists item text;
alter table public.c2c_bookings add column if not exists seat_price numeric(10,2);
alter table public.c2c_bookings add column if not exists pickup_kind text;
alter table public.c2c_bookings add column if not exists meeting_index smallint;
alter table public.c2c_bookings add column if not exists door_km numeric(6,2);
alter table public.c2c_bookings add column if not exists door_extra numeric(10,2);
-- [{name, familyMemberId?}]: who rides, the booker first. familyMemberId is
-- left for the Family module to fill from the rider's family members.
alter table public.c2c_bookings add column if not exists passenger_names jsonb;
-- {size, note, recipientName, recipientPhone}.
alter table public.c2c_bookings add column if not exists parcel jsonb;
alter table public.c2c_bookings add column if not exists declined_at timestamptz;
alter table public.c2c_bookings drop constraint if exists c2c_bookings_trip_kind_check;
alter table public.c2c_bookings add constraint c2c_bookings_trip_kind_check check (trip_kind in ('whole_car', 'per_seat'));
alter table public.c2c_bookings drop constraint if exists c2c_bookings_status_check;
alter table public.c2c_bookings add constraint c2c_bookings_status_check
  check (status in ('open', 'offered', 'requested', 'booked', 'driver_arriving', 'on_trip', 'completed', 'cancelled',
                    'expired', 'declined'));
alter table public.c2c_bookings drop constraint if exists c2c_bookings_seat;
alter table public.c2c_bookings add constraint c2c_bookings_seat check (
  case when trip_kind = 'per_seat'
       then trip_id is not null and driver_id is not null and item in ('seat', 'parcel')
            and pickup_kind in ('meeting', 'door')
       else trip_id is null and item is null and status not in ('requested', 'declined') end);
alter table public.c2c_bookings drop constraint if exists c2c_bookings_names;
alter table public.c2c_bookings add constraint c2c_bookings_names check (
  passenger_names is null or (jsonb_typeof(passenger_names) = 'array' and jsonb_array_length(passenger_names) <= 6));
create index if not exists c2c_bookings_trip_idx on public.c2c_bookings (trip_id, status) where trip_id is not null;
create index if not exists c2c_bookings_requested_idx on public.c2c_bookings (expires_at) where status = 'requested';
comment on column public.c2c_bookings.trip_id is
  'A seat or parcel booked on a trip a driver posted (0310); trip_kind is per_seat then.';

-- ---- Reading the trips ---------------------------------------------------------------------------------------
alter table public.c2c_trips enable row level security;
revoke all on public.c2c_trips from anon, authenticated;
grant select on public.c2c_trips to authenticated;
grant all on public.c2c_trips to service_role;
grant usage on sequence public.c2c_trip_ref_seq to service_role;
drop policy if exists "c2c_trips read" on public.c2c_trips;
create policy "c2c_trips read" on public.c2c_trips for select to authenticated
  using (driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (status = 'scheduled' and (select auth.uid()) is not null)
         or exists (select 1 from public.c2c_bookings b
                     where b.trip_id = c2c_trips.id and b.rider_id = (select auth.uid())));

insert into public.admin_table_pages (target, page) values
  ('c2c_seat_rules', 'admin-settings-city-to-city-seats'),
  ('c2c_seat_rules', 'admin-settings-city-to-city'),
  ('c2c_trips', 'admin-settings-city-to-city-seats'),
  ('c2c_trips', 'admin-settings-city-to-city')
on conflict do nothing;

-- ---- 0307's checks on insert: a per-seat row is c2c_book_seat's -------------------------------------------
-- As 0307; a per-seat row (inserted only by c2c_book_seat, which checked
-- it; the insert policy below keeps riders to whole-car rows) passes.
create or replace function public.c2c_bookings_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.city_to_city_settings;
  v_uid uuid := auth.uid();
  pl record;
  v_pick jsonb;
  v_drop jsonb;
  q jsonb;
  v_days integer;
  v_low numeric;
  v_high numeric;
  v_where text;
  v_line numeric;
begin
  if new.trip_kind = 'per_seat' and new.trip_id is not null then
    return new;
  end if;
  if v_uid is not null then
    new.rider_id := v_uid;
  end if;
  if new.rider_id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- What only the server sets.
  new.service := 'City to City';
  new.trip_kind := 'whole_car';
  new.trip_id := null;
  new.item := null;
  new.seat_price := null;
  new.pickup_kind := null;
  new.meeting_index := null;
  new.door_km := null;
  new.door_extra := null;
  new.passenger_names := null;
  new.parcel := null;
  new.declined_at := null;
  new.status := 'open';
  new.driver_id := null;
  new.offer_id := null;
  new.agreed_fare := null;
  new.driver_leave_at := null;
  new.booked_at := null;
  new.arriving_at := null;
  new.started_at := null;
  new.completed_at := null;
  new.cancelled_at := null;
  new.expired_at := null;
  new.cancelled_by := null;
  new.cancel_reason := null;
  new.cancel_fee := null;
  new.cancel_fee_status := null;
  new.rider_stars := null;
  new.rider_comment := null;
  new.rated_at := null;
  new.commission_rate := null;
  new.commission_base_rate := null;
  new.commission_rule_id := null;
  new.commission_tier_id := null;
  new.commission_promotion_id := null;
  new.commission_locked_at := null;
  new.commission_amount := null;
  new.commission_charged_at := null;
  new.created_at := now();
  new.updated_at := now();

  select * into s from public.city_to_city_settings where id = 1;
  if (new.payment = 'in_app' and not coalesce(s.pay_in_app, true))
     or (new.payment = 'cash' and not coalesce(s.pay_cash, true)) then
    raise exception 'C2C_PAYMENT_NOT_ALLOWED' using errcode = '22023',
      hint = case when coalesce(s.pay_cash, true) then 'Pay in cash for City to City trips.'
                  else 'Pay in the app for City to City trips.' end;
  end if;

  -- Where: the pickup as the server reads it, the drop-off as named.
  select * into pl from public.commission_places(new.pickup_lat, new.pickup_lng, new.pickup_place->>'country',
                                                 new.pickup_place->>'state', new.pickup_place->>'city',
                                                 new.pickup_place->>'suburb');
  v_pick := jsonb_strip_nulls(jsonb_build_object('country', pl.place_country, 'state', pl.place_state,
                                                 'city', pl.place_city, 'suburb', pl.place_suburb));
  v_drop := jsonb_strip_nulls(jsonb_build_object(
    'country', nullif(btrim(coalesce(new.drop_place->>'country', '')), ''),
    'state', nullif(btrim(coalesce(new.drop_place->>'state', '')), ''),
    'city', nullif(btrim(coalesce(new.drop_place->>'city', '')), ''),
    'suburb', nullif(btrim(coalesce(new.drop_place->>'suburb', '')), '')));
  new.pickup_place := v_pick;
  new.drop_place := v_drop;
  v_where := coalesce(v_pick->>'city', v_pick->>'state', v_pick->>'country');
  if not public.c2c_available_at(v_pick) then
    raise exception 'C2C_NOT_AVAILABLE' using errcode = '22023',
      hint = 'City to City isn''t available from ' || coalesce(v_where, 'this pickup') || ' yet.';
  end if;
  if v_drop->>'country' is null then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023', hint = 'Pick the drop-off address again.';
  end if;

  -- The trip: never shorter than the straight line between the two points.
  v_line := public.km_between(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng);
  if new.distance_km < v_line * 0.95 - 1 then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023',
      hint = 'The distance doesn''t match the addresses. Pick them again.';
  end if;
  q := public.c2c_quote(new.pickup_lat, new.pickup_lng, v_pick, v_drop, new.distance_km, new.duration_min,
                        'City to City');

  -- When.
  v_days := coalesce((q->>'bookAheadDays')::integer, 14);
  if new.leave_at < now() + interval '1 hour' then
    raise exception 'C2C_TOO_SOON' using errcode = '22023', hint = 'Leave at least 1 hour from now.';
  end if;
  if new.leave_at > now() + make_interval(days => v_days) then
    raise exception 'C2C_TOO_FAR_AHEAD' using errcode = '22023',
      hint = 'Book up to ' || v_days || case when v_days = 1 then ' day' else ' days' end || ' ahead on this route.';
  end if;

  -- The fare: the fixed fare, or within the range.
  new.currency := coalesce(q->>'currency', s.currency, 'MYR');
  if q->>'fareMode' = 'fixed' then
    if round(new.fare, 2) <> round((q->>'suggested')::numeric, 2) then
      raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
        hint = 'This route has a fixed fare of ' || public.c2c_money((q->>'suggested')::numeric, new.currency) || '.';
    end if;
  else
    v_low := (q->>'low')::numeric;
    v_high := (q->>'high')::numeric;
    if new.fare < v_low or new.fare > v_high then
      raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
        hint = 'Your fare must be between ' || public.c2c_money(v_low, new.currency) || ' and '
               || public.c2c_money(v_high, new.currency) || '.';
    end if;
  end if;

  -- At most 3 under way.
  if (select count(*) from public.c2c_bookings b
       where b.rider_id = new.rider_id and b.trip_kind = 'whole_car'
         and b.status in ('open', 'offered', 'booked', 'driver_arriving', 'on_trip')) >= 3 then
    raise exception 'C2C_TOO_MANY' using errcode = '22023',
      hint = 'You have 3 City to City trips under way. Finish or cancel one first.';
  end if;

  new.quote := q - 'pickup';
  new.rule_id := (q->>'ruleId')::uuid;
  new.expires_at := new.leave_at;
  return new;
end;
$$;
revoke execute on function public.c2c_bookings_check() from public, anon, authenticated;

-- Riders insert whole-car requests only; seats are booked with c2c_book_seat.
drop policy if exists "c2c_bookings rider insert" on public.c2c_bookings;
create policy "c2c_bookings rider insert" on public.c2c_bookings for insert to authenticated
  with check (rider_id = (select auth.uid()) and trip_kind = 'whole_car' and trip_id is null);

-- ---- 6. Women only ------------------------------------------------------------------------------------------
-- Whether [p_uid] is a verified woman: gender female, and an ID verified or
-- an approved partner (their IC checked).
create or replace function public.c2c_verified_woman(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = p_uid and p.gender::text = 'female'
       and (coalesce(p.id_verified::text, '') = 'Verified'
            or exists (select 1 from public.partners pa
                        where pa.auth_user_id = p_uid and pa.status::text = 'approved')));
$$;
revoke execute on function public.c2c_verified_woman(uuid) from public, anon, authenticated;

-- A verified ID's gender (and an approved partner's) is changed by admins
-- or the server only.
create or replace function public.profiles_guard_verified_gender()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.gender is distinct from old.gender
     and (coalesce(old.id_verified::text, '') = 'Verified'
          or exists (select 1 from public.partners pa
                      where pa.auth_user_id = new.id
                        and (pa.status::text = 'approved' or pa.status::text like 'permit-%'))) then
    raise exception 'PROFILE_PROTECTED_COLUMN:gender' using errcode = '42501',
      hint = 'Your ID is verified, so support changes your gender.';
  end if;
  return new;
end;
$$;
revoke execute on function public.profiles_guard_verified_gender() from public, anon, authenticated;
drop trigger if exists trg_profiles_d_verified_gender on public.profiles;
create trigger trg_profiles_d_verified_gender
  before update of gender on public.profiles
  for each row execute function public.profiles_guard_verified_gender();

-- ---- Shared -------------------------------------------------------------------------------------------------
-- Seats and parcel slots held on trip [p_trip] (requests waiting included).
create or replace function public.c2c_trip_taken(p_trip uuid)
returns table (seats integer, parcels integer)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(b.passengers) filter (where b.item = 'seat'), 0)::integer,
         count(*) filter (where b.item = 'parcel')::integer
    from public.c2c_bookings b
   where b.trip_id = p_trip
     and b.status in ('requested', 'booked', 'driver_arriving', 'on_trip', 'completed');
$$;
revoke execute on function public.c2c_trip_taken(uuid) from public, anon, authenticated;

-- Whether rider [p_rider] blocked driver [p_driver] (0311's rider_blocks):
-- such a driver's trips aren't listed for the rider nor bookable, and he
-- doesn't see or take the rider's seat requests. False until 0311 is in
-- (the check is looked up when it runs, so this migration doesn't need it).
create or replace function public.c2c_seat_blocked(p_rider uuid, p_driver uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_rider is null or p_driver is null
     or to_regprocedure('public.rider_blocks_driver(uuid, uuid)') is null then
    return false;
  end if;
  return coalesce(public.rider_blocks_driver(p_rider, p_driver), false);
end;
$$;
revoke execute on function public.c2c_seat_blocked(uuid, uuid) from public, anon, authenticated;

-- For the policies: whether rider [p_rider] blocked the caller (as 0311's
-- caller_blocked_by; only ever about the caller, so it tells no one else).
create or replace function public.c2c_seat_caller_blocked_by(p_rider uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.c2c_seat_blocked(p_rider, auth.uid());
$$;
revoke execute on function public.c2c_seat_caller_blocked_by(uuid) from public, anon;
grant execute on function public.c2c_seat_caller_blocked_by(uuid) to authenticated, service_role;

-- Whether the trip end [p_have] is in the place searched [p_want] ({country,
-- state, city}): its city when one is named, else its state, else its country.
create or replace function public.c2c_trip_end_matches(p_want jsonb, p_have jsonb)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case
    when coalesce(btrim(p_want->>'city'), '') <> '' then
      public.commission_place_matches(p_want->>'city', p_have->>'city')
      and public.commission_parent_ok(p_want->>'country', p_have->>'country')
    when coalesce(btrim(p_want->>'state'), '') <> '' then
      public.commission_place_matches(p_want->>'state', p_have->>'state')
      and public.commission_parent_ok(p_want->>'country', p_have->>'country')
    when coalesce(btrim(p_want->>'country'), '') <> '' then
      public.commission_place_matches(p_want->>'country', p_have->>'country')
    else false
  end;
$$;

-- "8:15" for the meeting point [p_minutes] after [p_leave] in [p_tz].
create or replace function public.c2c_clock(p_at timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_at at time zone coalesce(p_tz, 'Asia/Kuala_Lumpur'), 'FMHH24:MI');
$$;

-- A push to [p_to] about seat booking [b]; never stands in the way.
create or replace function public.c2c_seat_notify(p_to uuid, p_event text, p_title text, p_body text, b public.c2c_bookings,
                                                  p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.enqueue_notification(p_to, p_event, 'c2c_seat', 'normal', p_title, p_body,
                                      jsonb_build_object('type', 'c2c_seat', 'c2c_booking_id', b.id,
                                                         'c2c_trip_id', b.trip_id, 'role', p_role),
                                      null);
exception when others then
  raise warning 'c2c seat push % not sent: %', p_event, sqlerrm;
end;
$$;
revoke execute on function public.c2c_seat_notify(uuid, text, text, text, public.c2c_bookings, text)
  from public, anon, authenticated;

-- ---- 3. Posting -----------------------------------------------------------------------------------------------
-- What the post screen needs for a trip from (p_lat, p_lng) named [p_from]
-- to [p_to], [p_km] km, [p_min] minutes: {terms, limits, commissionRate,
-- eligibility, approved, verifiedWoman, from}. The caller's own.
create or replace function public.c2c_post_terms(p_lat double precision, p_lng double precision, p_from jsonb,
                                                 p_to jsonb, p_km numeric, p_min numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  pl record;
  v_from jsonb;
  v_terms jsonb;
  b public.c2c_bookings;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into pl from public.commission_places(p_lat, p_lng, p_from->>'country', p_from->>'state',
                                                 p_from->>'city', p_from->>'suburb');
  v_from := jsonb_strip_nulls(jsonb_build_object('country', pl.place_country, 'state', pl.place_state,
                                                 'city', pl.place_city, 'suburb', pl.place_suburb));
  v_terms := public.c2c_seat_terms_for(v_from);
  b.pickup_lat := p_lat;
  b.pickup_lng := p_lng;
  b.pickup_place := v_from;
  b.service := 'City to City';
  return jsonb_build_object(
    'terms', v_terms,
    'limits', public.c2c_seat_limits(v_terms, p_lat, p_lng, v_from, p_to, greatest(coalesce(p_km, 0), 0),
                                     greatest(coalesce(p_min, 0), 0)),
    'commissionRate', public.c2c_commission_now(v_uid, b),
    'eligibility', public.c2c_driver_eligibility(v_uid, v_from, p_to) - 'ruleId',
    'approved', exists (select 1 from public.partners p where p.auth_user_id = v_uid and p.status::text = 'approved'),
    'verifiedWoman', public.c2c_verified_woman(v_uid),
    'available', public.c2c_available_at(v_from),
    'from', v_from);
end;
$$;
revoke execute on function public.c2c_post_terms(double precision, double precision, jsonb, jsonb, numeric, numeric)
  from public, anon;
grant execute on function public.c2c_post_terms(double precision, double precision, jsonb, jsonb, numeric, numeric)
  to authenticated, service_role;

-- Whether driver [p_uid] has another trip or a whole-car booking within the
-- longer trip's time plus 2 hours of [p_leave] ([p_min] minutes long).
create or replace function public.c2c_driver_busy_at(p_uid uuid, p_leave timestamptz, p_min numeric,
                                                     p_skip uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.c2c_trips t
                  where t.driver_id = p_uid and t.id is distinct from p_skip
                    and t.status in ('scheduled', 'on_trip')
                    and abs(extract(epoch from t.leave_at - p_leave)) < (greatest(t.duration_min, p_min) + 120) * 60)
      or exists (select 1 from public.c2c_bookings x
                  where x.driver_id = p_uid and x.trip_kind = 'whole_car'
                    and x.status in ('booked', 'driver_arriving', 'on_trip')
                    and abs(extract(epoch from coalesce(x.driver_leave_at, x.leave_at) - p_leave))
                        < (greatest(x.duration_min, p_min) + 120) * 60);
$$;
revoke execute on function public.c2c_driver_busy_at(uuid, timestamptz, numeric, uuid) from public, anon, authenticated;

-- Posts a trip (see item 3). {ids, ref, posted, skipped}.
create or replace function public.c2c_post_trip(
  p_from jsonb,
  p_to jsonb,
  p_km numeric,
  p_min numeric,
  p_leave_at timestamptz,
  p_meeting_points jsonb,
  p_seats integer,
  p_seat_price numeric,
  p_join text default null,
  p_women_only boolean default false,
  p_door boolean default false,
  p_parcel_slots integer default 0,
  p_parcel_size text default null,
  p_parcel_price numeric default null,
  p_repeat text default null,
  p_repeat_until date default null,
  p_luggage text default 'small',
  p_note text default null,
  p_timezone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  pa record;
  pl record;
  v_from jsonb;
  v_to jsonb;
  v_terms jsonb;
  v_limits jsonb;
  v_where text;
  v_cur text;
  v_join text;
  v_price numeric;
  v_days integer;
  v_line numeric;
  v_tz text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'Asia/Kuala_Lumpur');
  v_sizes text[] := array['small', 'medium', 'large'];
  v_first public.c2c_trips;
  v_ids uuid[] := '{}';
  v_skipped integer := 0;
  v_at timestamptz;
  v_local timestamp;
  v_id uuid;
  chk jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select p.name, p.rating, nullif(btrim(concat_ws(' ', p.make, p.model)), '') as car,
         nullif(btrim(coalesce(p.plate, '')), '') as plate
    into pa
    from public.partners p
   where p.auth_user_id = v_uid and p.status::text = 'approved'
   order by p.created_at limit 1;
  if not found then
    raise exception 'C2C_NOT_A_DRIVER' using errcode = '42501', hint = 'Only approved drivers can post a trip.';
  end if;
  if p_from is null or p_to is null or jsonb_typeof(p_from) <> 'object' or jsonb_typeof(p_to) <> 'object'
     or coalesce(jsonb_typeof(p_from->'lat'), '') <> 'number' or coalesce(jsonb_typeof(p_from->'lng'), '') <> 'number'
     or coalesce(jsonb_typeof(p_to->'lat'), '') <> 'number' or coalesce(jsonb_typeof(p_to->'lng'), '') <> 'number'
     or char_length(btrim(coalesce(p_from->>'name', ''))) not between 1 and 200
     or char_length(btrim(coalesce(p_to->>'name', ''))) not between 1 and 200 then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023', hint = 'Pick where the trip starts and ends again.';
  end if;
  if not public.c2c_meeting_points_valid(p_meeting_points) then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023',
      hint = 'Add 1 to 5 meeting points, each up to 4 hours after leaving.';
  end if;

  -- Where: the start as the server reads it, the end as named.
  select * into pl from public.commission_places((p_from->>'lat')::double precision, (p_from->>'lng')::double precision,
                                                 p_from->'place'->>'country', p_from->'place'->>'state',
                                                 p_from->'place'->>'city', p_from->'place'->>'suburb');
  v_from := jsonb_strip_nulls(jsonb_build_object('country', pl.place_country, 'state', pl.place_state,
                                                 'city', pl.place_city, 'suburb', pl.place_suburb));
  v_to := jsonb_strip_nulls(jsonb_build_object(
    'country', nullif(btrim(coalesce(p_to->'place'->>'country', '')), ''),
    'state', nullif(btrim(coalesce(p_to->'place'->>'state', '')), ''),
    'city', nullif(btrim(coalesce(p_to->'place'->>'city', '')), ''),
    'suburb', nullif(btrim(coalesce(p_to->'place'->>'suburb', '')), '')));
  v_where := coalesce(v_from->>'city', v_from->>'state', v_from->>'country', 'here');
  if v_to->>'country' is null then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023', hint = 'Pick where the trip ends again.';
  end if;
  v_terms := public.c2c_seat_terms_for(v_from);
  if not coalesce((v_terms->>'seats_on')::boolean, false) or not public.c2c_available_at(v_from) then
    raise exception 'C2C_SEATS_OFF' using errcode = '22023',
      hint = 'Per-seat trips aren''t offered from ' || v_where || ' yet.';
  end if;
  chk := public.c2c_driver_eligibility(v_uid, v_from, v_to);
  if not coalesce((chk->>'ok')::boolean, false) then
    raise exception 'C2C_DRIVER_NOT_ELIGIBLE' using errcode = '22023',
      hint = case when not coalesce((chk->>'experienceOk')::boolean, false)
                  then 'This route needs ' || (chk->>'minYears') || ' years of driving.'
                  else 'This route needs ' || coalesce((select string_agg(e->>'name', ', ')
                                                          from jsonb_array_elements(chk->'needs') e), 'a permit')
                       || '.' end;
  end if;

  -- The trip: never shorter than the straight line.
  v_line := public.km_between((p_from->>'lat')::double precision, (p_from->>'lng')::double precision,
                              (p_to->>'lat')::double precision, (p_to->>'lng')::double precision);
  if p_km is null or p_km <= 0 or p_km > 5000 or p_km < v_line * 0.95 - 1
     or p_min is null or p_min < 0 or p_min > 10000 then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023',
      hint = 'The distance doesn''t match the places. Pick them again.';
  end if;

  -- When.
  v_days := coalesce((v_terms->>'post_ahead_days')::integer, 30);
  if p_leave_at is null or p_leave_at < now() + interval '1 hour' then
    raise exception 'C2C_TOO_SOON' using errcode = '22023', hint = 'Leave at least 1 hour from now.';
  end if;
  if p_leave_at > now() + make_interval(days => v_days) then
    raise exception 'C2C_TOO_FAR_AHEAD' using errcode = '22023',
      hint = 'Post up to ' || v_days || case when v_days = 1 then ' day' else ' days' end || ' ahead.';
  end if;

  -- Seats, join, price.
  if p_seats is null or p_seats < 1 or p_seats > coalesce((v_terms->>'max_seats')::integer, 4) then
    raise exception 'C2C_TOO_MANY_SEATS' using errcode = '22023',
      hint = 'Offer 1 to ' || coalesce((v_terms->>'max_seats')::integer, 4) || ' seats.';
  end if;
  v_join := case v_terms->>'join_mode'
              when 'instant' then 'instant'
              when 'approve' then 'approve'
              else case when p_join in ('instant', 'approve') then p_join else 'instant' end end;
  v_limits := public.c2c_seat_limits(v_terms, (p_from->>'lat')::double precision, (p_from->>'lng')::double precision,
                                     v_from, v_to, p_km, p_min);
  v_cur := coalesce(v_limits->>'currency', 'MYR');
  if v_limits->>'mode' = 'fixed' then
    v_price := (v_limits->>'price')::numeric;
  else
    v_price := round(coalesce(p_seat_price, 0), 2);
    if v_price < (v_limits->>'low')::numeric
       or (v_limits->>'high' is not null and v_price > (v_limits->>'high')::numeric) or v_price > 100000 then
      raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
        hint = case when v_limits->>'high' is null
                    then 'Price a seat from ' || public.c2c_money((v_limits->>'low')::numeric, v_cur) || '.'
                    else 'Price a seat between ' || public.c2c_money((v_limits->>'low')::numeric, v_cur) || ' and '
                         || public.c2c_money((v_limits->>'high')::numeric, v_cur) || '.' end;
    end if;
  end if;

  -- The extras.
  if coalesce(p_women_only, false) then
    if not coalesce((v_terms->>'women_on')::boolean, false) then
      raise exception 'C2C_WOMEN_ONLY' using errcode = '22023', hint = 'Women-only trips aren''t offered here.';
    end if;
    if not public.c2c_verified_woman(v_uid) then
      raise exception 'C2C_WOMEN_ONLY' using errcode = '22023',
        hint = 'Only a woman driver with a verified ID can post a women-only trip.';
    end if;
  end if;
  if coalesce(p_door, false) and not coalesce((v_terms->>'door_on')::boolean, false) then
    raise exception 'C2C_DOOR_OFF' using errcode = '22023', hint = 'Door pickup isn''t offered here.';
  end if;
  if coalesce(p_parcel_slots, 0) > 0 then
    if not coalesce((v_terms->>'parcels_on')::boolean, false) then
      raise exception 'C2C_NO_PARCELS' using errcode = '22023', hint = 'Parcels aren''t carried on trips from here.';
    end if;
    if p_parcel_slots > coalesce((v_terms->>'parcel_max_slots')::integer, 0)
       or coalesce(array_position(v_sizes, p_parcel_size), 99)
          > coalesce(array_position(v_sizes, v_terms->>'parcel_max_size'), 0)
       or p_parcel_price is null
       or p_parcel_price < (v_terms->>'parcel_min_price')::numeric
       or p_parcel_price > (v_terms->>'parcel_max_price')::numeric then
      raise exception 'C2C_NO_PARCELS' using errcode = '22023',
        hint = 'Take up to ' || (v_terms->>'parcel_max_slots') || ' parcels, up to ' || (v_terms->>'parcel_max_size')
               || ', priced ' || public.c2c_money((v_terms->>'parcel_min_price')::numeric, v_cur) || ' to '
               || public.c2c_money((v_terms->>'parcel_max_price')::numeric, v_cur) || '.';
    end if;
  end if;
  if coalesce(p_repeat, 'none') <> 'none' then
    if not coalesce((v_terms->>'repeat_on')::boolean, false) then
      raise exception 'C2C_NO_REPEAT' using errcode = '22023', hint = 'Repeat trips aren''t offered here.';
    end if;
    if p_repeat not in ('daily', 'weekdays', 'weekly') or p_repeat_until is null
       or p_repeat_until <= (p_leave_at at time zone v_tz)::date
       or p_repeat_until > (p_leave_at at time zone v_tz)::date
                           + coalesce((v_terms->>'repeat_max_weeks')::integer, 8) * 7 then
      raise exception 'C2C_NO_REPEAT' using errcode = '22023',
        hint = 'Repeat up to ' || coalesce((v_terms->>'repeat_max_weeks')::integer, 8) || ' weeks ahead.';
    end if;
  end if;
  if public.c2c_driver_busy_at(v_uid, p_leave_at, p_min) then
    raise exception 'C2C_DRIVER_BUSY' using errcode = '22023', hint = 'You already have a trip at that time.';
  end if;

  -- The first trip, then its repeats.
  insert into public.c2c_trips (driver_id, repeat_mode, from_name, from_address, from_lat, from_lng, from_place,
                                to_name, to_address, to_lat, to_lng, to_place, distance_km, duration_min, leave_at,
                                timezone, meeting_points, seats_total, seat_price, currency, join_mode, women_only,
                                door_pickup, door_max_km, door_per_km, parcel_slots, parcel_max_size, parcel_price,
                                luggage, note, limits, driver_name, driver_rating, car, plate)
  values (v_uid, nullif(coalesce(p_repeat, 'none'), 'none'), btrim(p_from->>'name'),
          left(nullif(btrim(coalesce(p_from->>'address', '')), ''), 400),
          (p_from->>'lat')::double precision, (p_from->>'lng')::double precision, v_from,
          btrim(p_to->>'name'), left(nullif(btrim(coalesce(p_to->>'address', '')), ''), 400),
          (p_to->>'lat')::double precision, (p_to->>'lng')::double precision, v_to,
          round(p_km, 2), round(p_min, 1), p_leave_at, v_tz,
          (select jsonb_agg(jsonb_build_object('name', btrim(e->>'name'),
                                               'address', nullif(btrim(coalesce(e->>'address', '')), ''),
                                               'lat', (e->>'lat')::numeric, 'lng', (e->>'lng')::numeric,
                                               'minutes', (e->>'minutes')::integer)
                            order by (e->>'minutes')::integer)
             from jsonb_array_elements(p_meeting_points) e),
          p_seats, v_price, v_cur, v_join, coalesce(p_women_only, false),
          coalesce(p_door, false),
          case when coalesce(p_door, false) then (v_terms->>'door_max_km')::numeric end,
          case when coalesce(p_door, false) then (v_terms->>'door_per_km')::numeric end,
          coalesce(p_parcel_slots, 0),
          case when coalesce(p_parcel_slots, 0) > 0 then p_parcel_size end,
          case when coalesce(p_parcel_slots, 0) > 0 then round(p_parcel_price, 2) end,
          case when p_luggage = 'suitcase' then 'suitcase' else 'small' end,
          left(nullif(btrim(coalesce(p_note, '')), ''), 300), v_limits,
          coalesce(nullif(btrim(pa.name), ''), (select nullif(btrim(name), '') from public.profiles where id = v_uid),
                   'Driver'),
          pa.rating, pa.car, pa.plate)
  returning * into v_first;
  v_ids := array[v_first.id];

  if v_first.repeat_mode is not null then
    update public.c2c_trips set series_id = v_first.id where id = v_first.id;
    for v_local in select d from public.c2c_repeat_dates((p_leave_at at time zone v_tz)::timestamp, v_first.repeat_mode,
                                                         p_repeat_until, 60) d loop
      v_at := v_local at time zone v_tz;
      if public.c2c_driver_busy_at(v_uid, v_at, p_min) then
        v_skipped := v_skipped + 1;
        continue;
      end if;
      insert into public.c2c_trips (driver_id, series_id, repeat_mode, from_name, from_address, from_lat, from_lng,
                                    from_place, to_name, to_address, to_lat, to_lng, to_place, distance_km,
                                    duration_min, leave_at, timezone, meeting_points, seats_total, seat_price,
                                    currency, join_mode, women_only, door_pickup, door_max_km, door_per_km,
                                    parcel_slots, parcel_max_size, parcel_price, luggage, note, limits, driver_name,
                                    driver_rating, car, plate)
      select driver_id, v_first.id, repeat_mode, from_name, from_address, from_lat, from_lng, from_place, to_name,
             to_address, to_lat, to_lng, to_place, distance_km, duration_min, v_at, timezone, meeting_points,
             seats_total, seat_price, currency, join_mode, women_only, door_pickup, door_max_km, door_per_km,
             parcel_slots, parcel_max_size, parcel_price, luggage, note, limits, driver_name, driver_rating, car, plate
        from public.c2c_trips where id = v_first.id
      returning id into v_id;
      v_ids := v_ids || v_id;
    end loop;
  end if;
  return jsonb_build_object('ids', to_jsonb(v_ids), 'ref', v_first.ref, 'posted', cardinality(v_ids),
                            'skipped', v_skipped, 'seatPrice', v_price, 'joinMode', v_join);
end;
$$;
revoke execute on function public.c2c_post_trip(jsonb, jsonb, numeric, numeric, timestamptz, jsonb, integer, numeric, text,
                                                boolean, boolean, integer, text, numeric, text, date, text, text, text)
  from public, anon;
grant execute on function public.c2c_post_trip(jsonb, jsonb, numeric, numeric, timestamptz, jsonb, integer, numeric, text,
                                               boolean, boolean, integer, text, numeric, text, date, text, text, text)
  to authenticated, service_role;

-- ---- 4. Riders ---------------------------------------------------------------------------------------------
-- A trip as riders see it: the row without the limits, with what is left,
-- the driver as "Hafiz R.", and whether the caller may book it.
create or replace function public.c2c_trip_view(t public.c2c_trips, p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  k record;
  v_terms jsonb := public.c2c_seat_terms_for(t.from_place);
begin
  select * into k from public.c2c_trip_taken(t.id);
  return (to_jsonb(t) - array['limits', 'driver_name', 'cancel_reason', 'cancelled_by'])
         || jsonb_build_object(
              'driver_name', public.c2c_short_name(t.driver_name),
              'seats_left', greatest(t.seats_total - k.seats, 0),
              'parcels_left', greatest(t.parcel_slots - k.parcels, 0),
              'closes_at', t.leave_at - make_interval(mins => coalesce((v_terms->>'cutoff_min')::integer, 60)),
              'max_per_booking', case when coalesce((v_terms->>'coriders_on')::boolean, false)
                                      then coalesce((v_terms->>'max_per_booking')::integer, 1) else 1 end,
              'coriders_on', coalesce((v_terms->>'coriders_on')::boolean, false),
              'door_on', t.door_pickup and coalesce((v_terms->>'door_on')::boolean, false),
              'may_book', t.driver_id <> p_uid and (not t.women_only or public.c2c_verified_woman(p_uid))
                          and not public.c2c_seat_blocked(p_uid, t.driver_id));
end;
$$;
revoke execute on function public.c2c_trip_view(public.c2c_trips, uuid) from public, anon, authenticated;

-- The trips from [p_from] to [p_to] ({country, state, city}) on [p_day] in
-- [p_tz] (null: the next 14 days) with [p_seats] seats left (0: parcels),
-- soonest first, where Per-seat trips are on at the start and booking is
-- still open. Women-only trips are listed with may_book false for others.
create or replace function public.c2c_search_trips(p_from jsonb, p_to jsonb, p_day date default null, p_seats integer default 1,
                                                   p_tz text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_tz text := coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Asia/Kuala_Lumpur');
  v_list jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(x.v order by x.leave_at, x.id), '[]'::jsonb) into v_list
    from (
      select t.id, t.leave_at, public.c2c_trip_view(t, v_uid) as v
        from public.c2c_trips t
       where t.status = 'scheduled'
         and t.driver_id <> v_uid
         and not public.c2c_seat_blocked(v_uid, t.driver_id)
         and public.c2c_trip_end_matches(p_from, t.from_place)
         and public.c2c_trip_end_matches(p_to, t.to_place)
         and case when p_day is null then t.leave_at < now() + interval '14 days'
                  else (t.leave_at at time zone v_tz)::date = p_day end
       order by t.leave_at, t.id
       limit 200) x
   where (x.v->>'closes_at')::timestamptz > now()
     and case when coalesce(p_seats, 1) <= 0 then (x.v->>'parcels_left')::integer > 0
              else (x.v->>'seats_left')::integer >= coalesce(p_seats, 1) end
     and coalesce((public.c2c_seat_terms_for((x.v->>'from_place')::jsonb)->>'seats_on')::boolean, false);
  return v_list;
end;
$$;
revoke execute on function public.c2c_search_trips(jsonb, jsonb, date, integer, text) from public, anon;
grant execute on function public.c2c_search_trips(jsonb, jsonb, date, integer, text) to authenticated, service_role;

-- One trip as riders see it (null when they may not read it).
create or replace function public.c2c_trip_for_rider(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.c2c_trips;
begin
  select * into t from public.c2c_trips where id = p_trip;
  if t.id is null or auth.uid() is null
     or not (t.status = 'scheduled' or t.driver_id = auth.uid()
             or exists (select 1 from public.c2c_bookings b where b.trip_id = t.id and b.rider_id = auth.uid())) then
    return null;
  end if;
  return public.c2c_trip_view(t, auth.uid());
end;
$$;
revoke execute on function public.c2c_trip_for_rider(uuid) from public, anon;
grant execute on function public.c2c_trip_for_rider(uuid) to authenticated, service_role;

-- What the pay sheet needs before booking on trip [p_trip]: as 0309's
-- c2c_pay_info, for the trip's start.
create or replace function public.c2c_seat_pay_info(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  t public.c2c_trips;
  pr public.c2c_pay_rules;
  s public.city_to_city_settings;
  v_items jsonb;
begin
  select * into t from public.c2c_trips where id = p_trip;
  if v_uid is null or t.id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into pr from public.c2c_pay_rule_for(t.from_place);
  select * into s from public.city_to_city_settings where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'ref', x.ref, 'fee', x.cancel_fee,
                                               'cancelledAt', x.cancelled_at) order by x.cancelled_at, x.id), '[]')
    into v_items
    from public.c2c_bookings x
   where coalesce(s.owed_next_in_app, false) and x.rider_id = v_uid
     and x.cancel_fee_status = 'due' and x.cancel_fee > 0;
  return jsonb_build_object(
    'when', coalesce(pr.when_mode, 'hold'),
    'wallet', coalesce(pr.pay_wallet, true), 'coin', coalesce(pr.pay_coin, true), 'mix', coalesce(pr.pay_mix, true),
    'offerTopup', coalesce(pr.offer_topup, true),
    'offerCash', coalesce(pr.offer_cash, true) and coalesce(s.pay_cash, true),
    'payInApp', coalesce(s.pay_in_app, true), 'payCash', coalesce(s.pay_cash, true),
    'walletBalance', coalesce((select w.balance from public.wallets w
                                where w.user_id = v_uid and w.wallet_type = 'get_wallet'), 0),
    'coinBalance', coalesce((select w.balance from public.wallets w
                              where w.user_id = v_uid and w.wallet_type = 'get_coin'), 0),
    'coinRate', (select g.coins_per_currency from public.get_coin_settings g where g.id = 'master'),
    'dues', v_items,
    'payStatus', null);
end;
$$;
revoke execute on function public.c2c_seat_pay_info(uuid) from public, anon;
grant execute on function public.c2c_seat_pay_info(uuid) to authenticated, service_role;

-- A seat request is booked: the driver's time, booked_at (the commission
-- is locked by 0307's trigger).
create or replace function public.c2c_seat_confirm(p_booking uuid)
returns public.c2c_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  update public.c2c_bookings
     set status = 'booked', booked_at = now(), agreed_fare = fare, driver_leave_at = leave_at, expires_at = null
   where id = p_booking and status = 'requested'
  returning * into b;
  return b;
end;
$$;
revoke execute on function public.c2c_seat_confirm(uuid) from public, anon, authenticated;

-- Books [p_seats] seats on trip [p_trip] (see item 4), or a parcel slot
-- when [p_parcel] is given ({size, note, recipientName, recipientPhone}).
-- [p_pickup]: {kind: 'meeting', index} or {kind: 'door', name, address,
-- lat, lng}. [p_passengers]: [{name, familyMemberId?}], the booker first,
-- one a seat (needed for more than 1 seat). In app: [p_method] and the
-- total the rider saw [p_expected], as 0309's accept. {id, ref, status,
-- fare, payStatus, held, dues}.
create or replace function public.c2c_book_seat(
  p_trip uuid,
  p_seats integer,
  p_pickup jsonb,
  p_payment text,
  p_passengers jsonb default null,
  p_method text default null,
  p_expected numeric default null,
  p_parcel jsonb default null,
  p_note text default null
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

  -- How to pay.
  select * into s from public.city_to_city_settings where id = 1;
  if p_payment not in ('in_app', 'cash') or (p_payment = 'in_app' and not coalesce(s.pay_in_app, true))
     or (p_payment = 'cash' and not coalesce(s.pay_cash, true)) then
    raise exception 'C2C_PAYMENT_NOT_ALLOWED' using errcode = '22023',
      hint = case when coalesce(s.pay_cash, true) then 'Pay in cash for City to City trips.'
                  else 'Pay in the app for City to City trips.' end;
  end if;
  v_fare := case when v_parcel then t.parcel_price else round(t.seat_price * v_seats + v_extra, 2) end;
  if coalesce(v_fare, 0) <= 0 then
    raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023', hint = 'This trip has no price set.';
  end if;

  insert into public.c2c_bookings (rider_id, service, trip_kind, trip_id, item, pickup_name, pickup_address, pickup_lat,
                                   pickup_lng, pickup_place, drop_name, drop_address, drop_lat, drop_lng, drop_place,
                                   distance_km, duration_min, leave_at, flexible, timezone, passengers, luggage, note,
                                   fare, currency, quote, payment, status, expires_at, driver_id, seat_price,
                                   pickup_kind, meeting_index, door_km, door_extra, passenger_names, parcel)
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
                 'recipientPhone', btrim(p_parcel->>'recipientPhone'))) end)
  returning * into b;
  if b.expires_at is not null and b.expires_at <= now() then
    raise exception 'C2C_BOOKING_CLOSED' using errcode = '22023',
      hint = 'It is too close to leaving for the driver to approve a request.';
  end if;

  -- The money, as 0309's accept: held now, paid after, or the fees owed for
  -- a cash trip's driver to collect.
  if p_payment = 'in_app' then
    select * into pr from public.c2c_pay_rule_for(t.from_place);
    v_mode := coalesce(pr.when_mode, 'hold');
    if v_mode = 'hold' then
      p := public.c2c_take_fare(b, v_fare,
                                coalesce(p_method, case when pr.pay_mix then 'mix' when pr.pay_wallet then 'get_wallet'
                                                        else 'get_coin' end),
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
revoke execute on function public.c2c_book_seat(uuid, integer, jsonb, text, jsonb, text, numeric, jsonb, text)
  from public, anon;
grant execute on function public.c2c_book_seat(uuid, integer, jsonb, text, jsonb, text, numeric, jsonb, text)
  to authenticated, service_role;

-- Who else rides on the trip of booking [p_booking]: first name, rider
-- rating, where they are picked up, seats; for its rider once booked, and
-- only where the rule shows co-riders. [] otherwise.
create or replace function public.c2c_coriders(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  t public.c2c_trips;
begin
  select * into b from public.c2c_bookings where id = p_booking;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into t from public.c2c_trips where id = b.trip_id;
  if t.id is null or b.status not in ('booked', 'driver_arriving', 'on_trip', 'completed')
     or not coalesce((public.c2c_seat_terms_for(t.from_place)->>'coriders_on')::boolean, false) then
    return '[]'::jsonb;
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
                   'name', split_part(public.c2c_short_name(pr.name), ' ', 1),
                   'rating', pr.rider_rating,
                   'pickup', coalesce(x.pickup_place->>'suburb', x.pickup_place->>'city', x.pickup_name),
                   'seats', x.passengers) order by x.leave_at, x.created_at), '[]'::jsonb)
            from public.c2c_bookings x
            left join public.profiles pr on pr.id = x.rider_id
           where x.trip_id = t.id and x.id <> b.id and x.item = 'seat'
             and x.status in ('booked', 'driver_arriving', 'on_trip', 'completed'));
end;
$$;
revoke execute on function public.c2c_coriders(uuid) from public, anon;
grant execute on function public.c2c_coriders(uuid) to authenticated, service_role;

-- ---- 5. Drivers -------------------------------------------------------------------------------------------
-- The driver approves or declines seat request [p_booking]. {status}.
create or replace function public.c2c_seat_decide(p_booking uuid, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  t public.c2c_trips;
begin
  select * into b from public.c2c_bookings where id = p_booking;
  if b.id is null or auth.uid() is null or b.driver_id is distinct from auth.uid() or b.trip_id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- The trip first, then the booking, as c2c_book_seat locks them.
  select * into t from public.c2c_trips where id = b.trip_id for update;
  select * into b from public.c2c_bookings where id = p_booking for update;
  -- A rider who blocked the driver: their request is gone for him (0311).
  if public.c2c_seat_blocked(b.rider_id, b.driver_id) then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This request is no longer open.';
  end if;
  if b.status = 'requested' and b.expires_at <= now() then
    perform public.c2c_expire_due();
    raise exception 'C2C_EXPIRED' using errcode = '22023', hint = 'This request has lapsed.';
  end if;
  if b.status <> 'requested' or t.status <> 'scheduled' then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This request was already answered or cancelled.';
  end if;
  if coalesce(p_approve, false) then
    b := public.c2c_seat_confirm(b.id);
    perform public.c2c_seat_notify(b.rider_id, 'c2c-seat:' || b.id || ':approved', 'Your seat is booked',
      coalesce(public.c2c_short_name(t.driver_name), 'Your driver') || ' approved your request: '
      || public.c2c_clock(b.leave_at, t.timezone) || ' from ' || b.pickup_name || '.', b, 'rider');
  else
    if b.pay_status = 'held' then
      perform public.c2c_hold_refund(b, 0);
    end if;
    update public.c2c_bookings
       set status = 'declined', declined_at = now(),
           cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300),
           pay_status = case when pay_status = 'held' then 'refunded' else pay_status end
     where id = b.id
    returning * into b;
    perform public.c2c_seat_notify(b.rider_id, 'c2c-seat:' || b.id || ':declined', 'Seat request declined',
      'The driver can''t take you on this trip.'
      || case when b.pay_status = 'refunded' then ' The fare held came back to you.' else '' end, b, 'rider');
  end if;
  return jsonb_build_object('status', b.status);
end;
$$;
revoke execute on function public.c2c_seat_decide(uuid, boolean, text) from public, anon;
grant execute on function public.c2c_seat_decide(uuid, boolean, text) to authenticated, service_role;

-- The driver's posted trips: those not ended, and the last 10 that did,
-- each with its bookings (the rider as "Farah T." with their rating, the
-- seats, names, pickup, fare, payment, the request's lapse time).
create or replace function public.c2c_driver_seat_trips()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(x.v order by x.ended, case when x.ended then -x.at else x.at end), '[]'::jsonb)
      from (
        select t.status in ('completed', 'cancelled') as ended, extract(epoch from t.leave_at) as at,
               public.c2c_trip_view(t, v_uid)
               || jsonb_build_object('driver_name', t.driver_name, 'bookings', (
                    select coalesce(jsonb_agg(jsonb_build_object(
                             'id', b.id, 'ref', b.ref, 'status', b.status, 'item', b.item, 'seats', b.passengers,
                             'rider_name', public.c2c_short_name(pr.name), 'rider_rating', pr.rider_rating,
                             'passenger_names', b.passenger_names, 'pickup_kind', b.pickup_kind,
                             'pickup_name', b.pickup_name, 'pickup_address', b.pickup_address,
                             'leave_at', b.leave_at, 'door_km', b.door_km, 'door_extra', b.door_extra,
                             'fare', b.fare, 'currency', b.currency, 'payment', b.payment, 'pay_status', b.pay_status,
                             'pay_mode', b.pay_mode, 'expires_at', b.expires_at, 'parcel', b.parcel, 'note', b.note,
                             'commission_rate', b.commission_rate)
                             order by b.leave_at, b.created_at), '[]'::jsonb)
                      from public.c2c_bookings b
                      left join public.profiles pr on pr.id = b.rider_id
                     where b.trip_id = t.id
                       and not (b.status = 'requested' and public.c2c_seat_blocked(b.rider_id, v_uid)))) as v
          from public.c2c_trips t
         where t.driver_id = v_uid
           and (t.status in ('scheduled', 'on_trip')
                or t.id in (select d.id from public.c2c_trips d
                             where d.driver_id = v_uid and d.status in ('completed', 'cancelled')
                             order by d.leave_at desc limit 10))) x);
end;
$$;
revoke execute on function public.c2c_driver_seat_trips() from public, anon;
grant execute on function public.c2c_driver_seat_trips() to authenticated, service_role;

-- The driver starts (on_trip) or finishes (completed) trip [p_trip]. Start:
-- every booked seat on the way (0309's c2c_driver_progress, one by one);
-- requests still waiting are declined. Finish: every seat on the trip
-- completed (each charged and paid as a booking is). {status, moved}.
create or replace function public.c2c_trip_progress(p_trip uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.c2c_trips;
  b public.c2c_bookings;
  v_n integer := 0;
begin
  select * into t from public.c2c_trips where id = p_trip for update;
  if t.id is null or auth.uid() is null or t.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not ((t.status = 'scheduled' and p_status = 'on_trip') or (t.status = 'on_trip' and p_status = 'completed')) then
    raise exception 'C2C_BAD_STEP' using errcode = '22023', hint = 'This trip can''t move to that step now.';
  end if;
  if p_status = 'on_trip' then
    perform public.c2c_expire_due();
    for b in select * from public.c2c_bookings where trip_id = t.id and status = 'requested' order by created_at loop
      perform public.c2c_seat_decide(b.id, false, 'The trip left.');
    end loop;
    for b in select * from public.c2c_bookings
              where trip_id = t.id and status in ('booked', 'driver_arriving') order by leave_at, created_at loop
      perform public.c2c_driver_progress(b.id, 'on_trip');
      v_n := v_n + 1;
    end loop;
    update public.c2c_trips set status = 'on_trip', started_at = now() where id = t.id;
  else
    for b in select * from public.c2c_bookings where trip_id = t.id and status = 'on_trip' order by leave_at, created_at loop
      perform public.c2c_driver_progress(b.id, 'completed');
      v_n := v_n + 1;
    end loop;
    update public.c2c_trips set status = 'completed', completed_at = now() where id = t.id;
  end if;
  return jsonb_build_object('status', p_status, 'moved', v_n);
end;
$$;
revoke execute on function public.c2c_trip_progress(uuid, text) from public, anon;
grant execute on function public.c2c_trip_progress(uuid, text) to authenticated, service_role;

-- The driver (or an admin with EDIT, free) cancels trip [p_trip], and with
-- [p_series] the later trips of its repeat. Each booked rider: the give-up
-- fee of their pickup's rule (0309) charged to the driver, the held fare
-- back; requests declined. Before the time to leave. {cancelled, fees, riders}.
create or replace function public.c2c_trip_cancel(p_trip uuid, p_reason text default null, p_series boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t0 public.c2c_trips;
  t public.c2c_trips;
  b public.c2c_bookings;
  r public.c2c_giveup_rules;
  f record;
  v_by text;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
  v_trips integer := 0;
  v_fees numeric := 0;
  v_riders integer := 0;
begin
  select * into t0 from public.c2c_trips where id = p_trip;
  if t0.id is null or auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if t0.driver_id = auth.uid() then
    v_by := 'driver';
  elsif public.caller_admin_can_write('c2c_trips') then
    v_by := 'admin';
  else
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if t0.status = 'on_trip' then
    raise exception 'C2C_ON_TRIP' using errcode = '22023', hint = 'The trip has started. Finish it, or contact support.';
  end if;
  if t0.status <> 'scheduled' then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip has already ended.';
  end if;
  if v_by = 'driver' and now() >= t0.leave_at then
    raise exception 'C2C_TOO_LATE' using errcode = '22023',
      hint = 'It is past the time to leave. Contact support to cancel this trip.';
  end if;

  for t in
    select * from public.c2c_trips x
     where x.id = t0.id
        or (coalesce(p_series, false) and t0.series_id is not null and x.series_id = t0.series_id
            and x.leave_at > t0.leave_at and x.status = 'scheduled')
     order by x.leave_at
     for update
  loop
    for b in select * from public.c2c_bookings
              where trip_id = t.id and status in ('requested', 'booked', 'driver_arriving')
              order by created_at for update loop
      if b.status <> 'requested' and v_by = 'driver' then
        select * into r from public.c2c_giveup_rule_for(b.pickup_place);
        select * into f from public.c2c_giveup_fee(r, b.leave_at, now());
        if f.fee > 0 then
          perform public.c2c_giveup_charge(b, r, f.fee, f.to_rider, f.to_platform);
          v_fees := v_fees + f.fee;
        end if;
      end if;
      if b.pay_status = 'held' then
        perform public.c2c_hold_refund(b, 0);
      end if;
      update public.c2c_bookings
         set status = case when b.status = 'requested' then 'declined' else 'cancelled' end,
             declined_at = case when b.status = 'requested' then now() end,
             cancelled_at = case when b.status <> 'requested' then now() end,
             cancelled_by = case when b.status <> 'requested' then v_by end,
             cancel_reason = coalesce(v_reason, 'The driver cancelled the trip.'),
             cancel_fee = case when b.status <> 'requested' then 0 end,
             cancel_fee_status = case when b.status <> 'requested' then 'none' end,
             pay_status = case when b.pay_status = 'held' then 'refunded' else b.pay_status end
       where id = b.id;
      perform public.c2c_seat_notify(b.rider_id, 'c2c-seat:' || b.id || ':trip-cancelled', 'Trip cancelled',
        'Your trip to ' || coalesce(t.to_place->>'city', t.to_name) || ' on '
        || to_char(t.leave_at at time zone coalesce(t.timezone, 'Asia/Kuala_Lumpur'), 'FMDy FMDD Mon')
        || ' was cancelled.' || case when b.pay_status = 'held' then ' The fare held came back to you.' else '' end,
        b, 'rider');
      v_riders := v_riders + 1;
    end loop;
    update public.c2c_trips
       set status = 'cancelled', cancelled_at = now(), cancelled_by = v_by, cancel_reason = v_reason
     where id = t.id;
    v_trips := v_trips + 1;
  end loop;
  return jsonb_build_object('cancelled', v_trips, 'fees', v_fees, 'riders', v_riders);
end;
$$;
revoke execute on function public.c2c_trip_cancel(uuid, text, boolean) from public, anon;
grant execute on function public.c2c_trip_cancel(uuid, text, boolean) to authenticated, service_role;

-- ---- 4. Lapsed requests ---------------------------------------------------------------------------------------
-- As 0307, and seat requests the driver didn't answer in time, or to a
-- driver the rider has since blocked (0311): 'expired', the held fare back
-- in full.
create or replace function public.c2c_expire_due()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  b public.c2c_bookings;
  v_n integer := 0;
begin
  with gone as (
    update public.c2c_bookings
       set status = 'expired', expired_at = now()
     where status in ('open', 'offered') and expires_at <= now()
    returning id)
  select coalesce(array_agg(id), '{}') into v_ids from gone;
  update public.c2c_offers set status = 'expired' where booking_id = any(v_ids) and status = 'open';
  for b in select * from public.c2c_bookings
            where status = 'requested'
              and (expires_at <= now() or public.c2c_seat_blocked(rider_id, driver_id))
            order by expires_at
            for update skip locked loop
    if b.pay_status = 'held' then
      perform public.c2c_hold_refund(b, 0);
    end if;
    update public.c2c_bookings
       set status = 'expired', expired_at = now(),
           pay_status = case when pay_status = 'held' then 'refunded' else pay_status end
     where id = b.id;
    perform public.c2c_seat_notify(b.rider_id, 'c2c-seat:' || b.id || ':lapsed', 'Seat request lapsed',
      case when b.expires_at <= now() then 'The driver didn''t answer in time.'
           else 'You blocked this driver, so your request was withdrawn.' end
      || case when b.pay_status = 'held' then ' The fare held came back to you.' else '' end, b, 'rider');
    v_n := v_n + 1;
  end loop;
  return cardinality(v_ids) + v_n;
end;
$$;
revoke execute on function public.c2c_expire_due() from public, anon, authenticated;

-- ---- 5. A seat booking isn't given up alone ---------------------------------------------------------------
-- As 0309; a seat on a posted trip is refused (the trip is cancelled with
-- c2c_trip_cancel, a request declined with c2c_seat_decide).
create or replace function public.c2c_driver_cancel(p_booking uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  r public.c2c_giveup_rules;
  f record;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.trip_kind = 'per_seat' then
    raise exception 'C2C_SEAT_TRIP' using errcode = '22023',
      hint = 'This is a seat on your posted trip. Cancel the trip, or decline the request.';
  end if;
  if b.status = 'on_trip' then
    raise exception 'C2C_ON_TRIP' using errcode = '22023',
      hint = 'The rider is on board. Finish the trip, or contact support.';
  end if;
  if b.status not in ('booked', 'driver_arriving') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip has already ended.';
  end if;
  if now() >= b.leave_at then
    raise exception 'C2C_TOO_LATE' using errcode = '22023',
      hint = 'It is past the time to leave. Contact support to cancel this trip.';
  end if;

  select * into r from public.c2c_giveup_rule_for(b.pickup_place);
  select * into f from public.c2c_giveup_fee(r, b.leave_at, now());
  if f.fee > 0 then
    perform public.c2c_giveup_charge(b, r, f.fee, f.to_rider, f.to_platform);
  end if;
  if b.pay_status = 'held' then
    perform public.c2c_hold_refund(b, 0);
  end if;

  update public.c2c_offers set status = 'withdrawn'
   where booking_id = b.id and driver_id = b.driver_id and status = 'accepted';
  update public.c2c_bookings
     set status = 'open', driver_id = null, offer_id = null, agreed_fare = null, driver_leave_at = null,
         booked_at = null, arriving_at = null,
         commission_rate = null, commission_base_rate = null, commission_rule_id = null,
         commission_tier_id = null, commission_promotion_id = null, commission_locked_at = null,
         pay_mode = null, pay_status = null, paid_method = null, paid_amount = null, paid_at = null,
         collect_fee_ids = null, collect_amount = null, collected_at = null,
         driver_dropped_at = now(), driver_drop_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300)
   where id = b.id;
  return jsonb_build_object('status', 'open', 'fee', coalesce(f.fee, 0));
end;
$$;
revoke execute on function public.c2c_driver_cancel(uuid, text) from public, anon;
grant execute on function public.c2c_driver_cancel(uuid, text) to authenticated, service_role;

-- ---- Reminders ----------------------------------------------------------------------------------------------
-- As 0309, each seat booking reminded as a booking is; the driver's name,
-- car and plate from the trip when there is no offer.
create or replace function public.c2c_send_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.city_to_city_settings;
  b record;
  e record;
  v_due timestamptz;
  v_to uuid;
  v_role text;
  v_when text;
  v_clock text;
  v_drop text;
  v_title text;
  v_body text;
  v_event text;
  v_n integer := 0;
  f public.sms_fallback_settings;
  r public.notification_outbox;
  v_phone text;
  v_reason text;
  v_sms uuid;
begin
  select * into s from public.city_to_city_settings where id = 1;
  if s.id is null or not s.reminders_on or jsonb_array_length(coalesce(s.reminders, '[]')) = 0 then
    return 0;
  end if;

  for b in
    select x.*, coalesce(x.driver_leave_at, x.leave_at) as leaves,
           coalesce(o.driver_name, tr.driver_name) as driver_name,
           nullif(btrim(concat_ws(', ', coalesce(o.car, tr.car), coalesce(o.plate, tr.plate))), '') as car_line,
           (select pr.name from public.profiles pr where pr.id = x.rider_id) as rider_name
      from public.c2c_bookings x
      left join public.c2c_offers o on o.id = x.offer_id
      left join public.c2c_trips tr on tr.id = x.trip_id
     where x.status in ('booked', 'driver_arriving') and x.driver_id is not null
       and coalesce(x.driver_leave_at, x.leave_at) > now()
     order by coalesce(x.driver_leave_at, x.leave_at)
  loop
    for e in
      select (j->>'minutes')::integer as minutes, j->>'to' as who
        from jsonb_array_elements(s.reminders) j
       order by (j->>'minutes')::integer desc
    loop
      v_due := b.leaves - make_interval(mins => e.minutes);
      continue when now() < v_due;
      foreach v_role in array array['rider', 'partner'] loop
        continue when (v_role = 'rider' and e.who = 'driver') or (v_role = 'partner' and e.who = 'rider');
        v_to := case when v_role = 'rider' then b.rider_id else b.driver_id end;
        continue when exists (select 1 from public.c2c_reminder_log l
                               where l.booking_id = b.id and l.minutes = e.minutes and l.profile_id = v_to);
        -- Its time had passed when the trip was booked, or it is late.
        if v_due < coalesce(b.booked_at, b.created_at) or now() > v_due + interval '30 minutes' then
          insert into public.c2c_reminder_log (booking_id, minutes, profile_id, skipped)
          values (b.id, e.minutes, v_to, true) on conflict do nothing;
          continue;
        end if;
        insert into public.c2c_reminder_log (booking_id, minutes, profile_id) values (b.id, e.minutes, v_to)
        on conflict do nothing;

        v_when := public.c2c_reminder_when(e.minutes);
        v_clock := to_char(b.leaves at time zone coalesce(b.timezone, 'Asia/Kuala_Lumpur'), 'FMHH24:MI');
        v_drop := coalesce(b.drop_place->>'city', b.drop_place->>'state', b.drop_name);
        if v_role = 'rider' then
          v_title := 'Your trip to ' || v_drop || ' is in ' || v_when;
          v_body := public.c2c_short_name(b.driver_name) || ' picks you up at ' || v_clock || ' from ' || b.pickup_name
                    || '.' || coalesce(' ' || b.car_line || '.', '') || ' Tap to see the trip or chat.';
        else
          v_title := 'City to City trip in ' || v_when;
          v_body := 'Pick up ' || public.c2c_short_name(b.rider_name) || ' at ' || v_clock || ', ' || b.pickup_name
                    || ', to ' || v_drop || '. ' || public.c2c_money(coalesce(b.agreed_fare, b.fare), b.currency) || ', '
                    || case when b.payment = 'cash' then 'cash'
                            when b.pay_status = 'held' then 'paid in app'
                            else 'in app, paid after the trip' end
                    || '. Tap to start On my way.';
        end if;
        v_event := 'c2c-rem:' || b.id || ':' || e.minutes;
        begin
          if s.reminder_push then
            perform public.enqueue_notification(
              v_to, v_event, 'c2c_reminder', 'normal', v_title, v_body,
              jsonb_build_object('type', 'c2c_reminder', 'c2c_booking_id', b.id, 'role', v_role,
                                 'minutes', e.minutes, 'event_id', v_event, 'inbox', s.reminder_inbox),
              null);
          elsif s.reminder_inbox then
            insert into public.user_notifications (profile_id, title, body, data, kind, mode, event_id)
            values (v_to, v_title, v_body,
                    jsonb_build_object('type', 'c2c_reminder', 'c2c_booking_id', b.id, 'role', v_role,
                                       'minutes', e.minutes),
                    'c2c_reminder', v_role, v_event)
            on conflict (profile_id, event_id) do nothing;
          end if;
          v_n := v_n + 1;
        exception when others then
          raise warning 'c2c reminder % not sent: %', v_event, sqlerrm;
        end;
      end loop;
    end loop;
  end loop;

  -- SMS when the push wasn't confirmed (0150's number, refusals and gateway).
  if s.reminder_push and s.reminder_sms then
    begin
      select * into f from public.sms_fallback_settings where id = 1;
      if public.sms_gateway_online(coalesce(f.channel, 'otp')) then
        for r in
          select * from public.notification_outbox o
           where o.kind = 'c2c_reminder' and o.delivered_at is null and o.sms_at is null
             and o.created_at <= now() - interval '2 minutes' and o.created_at > now() - interval '30 minutes'
           order by o.created_at
           limit 50
           for update skip locked
        loop
          v_phone := public.sms_fallback_phone(r);
          v_reason := public.sms_fallback_refusal(r, v_phone);
          if v_reason is null and not exists (
               select 1 from public.c2c_bookings x
                where x.id::text = r.data->>'c2c_booking_id' and x.status in ('booked', 'driver_arriving')) then
            v_reason := 'moved_on';
          end if;
          if v_reason is not null then
            update public.notification_outbox
               set sms_status = 'skipped', sms_reason = v_reason, sms_at = now(), sms_phone = v_phone
             where id = r.id;
            continue;
          end if;
          insert into public.sms_outbox (channel, to_phone, body, created_by)
          values (coalesce(f.channel, 'otp'), v_phone, left('GET.ride: ' || r.title || '. ' || r.body, 300), null)
          returning id into v_sms;
          update public.notification_outbox
             set sms_status = 'queued', sms_reason = null, sms_at = now(), sms_phone = v_phone, sms_outbox_id = v_sms
           where id = r.id;
        end loop;
      end if;
    exception when others then
      raise warning 'c2c reminder SMS not sent: %', sqlerrm;
    end;
  end if;
  return v_n;
end;
$$;
revoke execute on function public.c2c_send_reminders() from public, anon, authenticated;

-- ---- 7. Chat on a seat request -------------------------------------------------------------------------------
-- As 0308, and a seat request waiting for the driver.
drop policy if exists "ride_messages c2c insert" on public.ride_messages;
create policy "ride_messages c2c insert" on public.ride_messages for insert to authenticated
  with check (c2c_booking_id is not null and request_id is null
              and sender_id = (select auth.uid())
              and exists (select 1 from public.c2c_bookings b
                           where b.id = ride_messages.c2c_booking_id
                             and (b.status in ('booked', 'driver_arriving', 'on_trip')
                                  or (b.status = 'requested' and b.trip_kind = 'per_seat'))
                             and ((ride_messages.sender_role = 'rider' and b.rider_id = (select auth.uid()))
                                  or (ride_messages.sender_role = 'partner' and b.driver_id = (select auth.uid())
                                      and (b.status <> 'requested'
                                           or not public.c2c_seat_caller_blocked_by(b.rider_id))))));

-- ---- Rider blocks (0311) on seat requests ------------------------------------------------------------------
-- 0311 hides a rider's open whole-car requests from the drivers they blocked
-- (restrictive "c2c_bookings rider blocks"); a seat request carries its
-- trip's driver from the start, so it is hidden from him the same way here,
-- restrictive beside 0307's read policy. He can't approve it
-- (c2c_seat_decide), it isn't in his trip's list (c2c_driver_seat_trips),
-- he can't write on its chat, and c2c_expire_due withdraws it (the held
-- fare back). The rider can't list or book his trips (c2c_search_trips,
-- c2c_book_seat: DRIVER_BLOCKED).
drop policy if exists "c2c_bookings seat request blocks" on public.c2c_bookings;
create policy "c2c_bookings seat request blocks" on public.c2c_bookings as restrictive for select to authenticated
  using (status <> 'requested'
         or rider_id = (select auth.uid())
         or (select public.caller_is_admin())
         or not public.c2c_seat_caller_blocked_by(rider_id));

-- ---- Live in the apps and the admin pages ----------------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['c2c_seat_rules', 'c2c_trips'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
