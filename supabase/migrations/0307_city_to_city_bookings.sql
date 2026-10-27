-- ============================================================================
-- 0307 — City to City bookings (docs/KIV.md L8, part C2): the rider's trip
-- request, drivers' offers, the booking, the cancel fee and the commission
-- lock, on the server. The rider app (C2) books on it; the driver app (C3)
-- offers and drives on it with the functions in item 6, already here.
--
-- Version 20261028000000 (0307_city_to_city_bookings). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first.
--
-- Why its own tables and not ride_requests: a City to City request is open
-- for days (until the time to leave), not minutes; its lifecycle (open,
-- offered, booked, driver_arriving, on_trip, completed, cancelled, expired),
-- its cancel fee (0306's settings, counted from the time to leave) and who
-- may see it (drivers with the years and permits, 0306) are its own, and a
-- row in ride_requests would reach every city driver's request feed, push
-- and expiry job before the driver app (C3) knows it. The money paths are
-- shared all the same: commission_resolve with the service (0306), tiers
-- (0218) and promotions (0224), and the GET wallet for the cancel fee (0269).
--
-- 1. c2c_bookings: the request and, once a driver is picked, the booking.
--    Pickup and drop-off (name, address, point, and the places {country,
--    state, city, suburb}: the pickup's as the server reads it, 0224's
--    commission_places), the distance and time, when to leave (and whether
--    ± 30 minutes is fine), passengers (1 to 6), luggage, the rider's fare,
--    the quote it was checked against, In app or Cash, the status, the
--    driver, the agreed fare, the cancel fee and the commission. A ref
--    ("CC-20481") for people.
-- 2. On insert (trigger c2c_bookings_check), whoever inserts it: the rider is
--    the caller; the service must be on at the pickup (c2c_available_at,
--    0306): C2C_NOT_AVAILABLE; the distance can't be shorter than the
--    straight line: C2C_BAD_TRIP; leave at least 1 hour from now and within
--    the rule's book-ahead days: C2C_TOO_SOON, C2C_TOO_FAR_AHEAD; the fare
--    within the quote's range (c2c_quote, 0306), or the fixed fare:
--    C2C_FARE_OUT_OF_RANGE; a payment method the settings allow:
--    C2C_PAYMENT_NOT_ALLOWED; at most 3 trips under way: C2C_TOO_MANY. Each
--    raises its code with the words for the rider in the hint. The request
--    stays open until the time to leave (expires_at).
-- 3. c2c_offers: a driver's price and the time they can leave (within ±
--    30 minutes of the rider's when flexible, else the rider's), with the
--    driver's name, rating, trips, car and plate as they were. One open
--    offer per driver and request; offering again changes it.
-- 4. The rider: c2c_accept_offer (atomic: the request locked, the offer
--    accepted, every other open offer declined, the booking booked with the
--    driver and the agreed fare; the commission locked as it is booked),
--    c2c_decline_offer, c2c_set_fare (raise or lower within the range while
--    no driver is picked), c2c_cancel (with the fee), c2c_contact (the
--    driver's name and phone once booked), c2c_rate_driver (after the trip).
-- 5. The cancel fee (0306's settings): none while no driver is picked; once
--    booked, free until cancel_free_hours before the time to leave, then
--    cancel_fee_amount; nothing when the fee is off. From the rider's GET
--    wallet to the driver's, less the trip's commission ('charged'); when the
--    wallet is short it is kept on the booking as 'due' (collecting it later
--    is not built yet). An admin's cancel is free.
--    (0306's c2c_driver_check is redefined with the same answers and caller
--    check, its body moved to c2c_driver_eligibility so the rider's accept
--    can ask about the driver; see "Shared" below.)
-- 6. The driver (for C3): c2c_make_offer, c2c_withdraw_offer and
--    c2c_driver_progress (booked, driver_arriving, on_trip, completed; the
--    commission charged at completion as rides are, 0224/0306).
-- 7. Expiry: c2c_expire_due() closes requests whose time to leave passed
--    with no driver (status expired, open offers expired); every 5 minutes
--    with pg_cron, and an accept or an offer on one refuses it at once.
-- 8. Who reads: the rider their own; the driver booked on it; an admin; and
--    a driver an open request only when they may take it (c2c_driver_ok,
--    0306: years and permits) and it is in reach. In reach, kept simple: the
--    driver is an approved partner whose service area holds the pickup's
--    state ('Country|State' in partners.service_states), or, when they list
--    no states, its country (service_countries). Offers: the driver who made
--    it, the rider of the request, an admin. Nobody writes the tables
--    directly but the rider's insert; everything else goes through the
--    functions above. An admin with EDIT on City to City may cancel.
-- 9. Live: both tables are in supabase_realtime (the app follows them,
--    lib/src/data/live_tables.dart; supabase/tests/live_admin_changes.sql).
-- ============================================================================

-- ---- Shared: money as riders read it ------------------------------------------------------------------
-- "RM 130", "RM 135.50", "SGD 40".
create or replace function public.c2c_money(p_amount numeric, p_currency text default 'MYR')
returns text
language sql
immutable
set search_path = ''
as $$
  select case when upper(coalesce(p_currency, 'MYR')) = 'MYR' then 'RM' else upper(p_currency) end || ' '
         || case when p_amount = trunc(p_amount) then trunc(p_amount)::text
                 else to_char(p_amount, 'FM999999990.00') end;
$$;

-- ---- Shared: a driver's eligibility, asked by the server ----------------------------------------------------
-- 0306's c2c_driver_check refuses any caller but the driver or an admin, so
-- the rider's accept (item 4) could not ask whether the driver they pick may
-- still take the trip. Its body moves, unchanged, to c2c_driver_eligibility
-- (the server's alone); c2c_driver_check keeps its caller check and answers
-- with it, so what it returns and who may call it are as in 0306.
create or replace function public.c2c_driver_eligibility(p_driver uuid, p_pickup jsonb, p_drop jsonb,
                                                         p_via text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.c2c_route_rules;
  v_min integer;
  v_since date;
  v_years integer;
  v_exp boolean;
  v_needs jsonb;
  v_countries text[];
begin
  select * into r from public.c2c_rule_for(p_pickup, p_drop);
  v_min := public.c2c_min_years(r);
  v_since := public.c2c_driving_since(p_driver);
  v_years := case when v_since is null then null else extract(year from age(current_date, v_since))::integer end;
  v_exp := v_min is null or (v_years is not null and v_years >= v_min);
  select array_agg(distinct btrim(c)) into v_countries
    from unnest(array[p_pickup->>'country', p_drop->>'country'] || coalesce(p_via, '{}')) c
   where coalesce(btrim(c), '') <> '';
  select coalesce(jsonb_agg(jsonb_build_object('permitTypeId', x.id, 'name', x.name, 'shortName', x.short_name,
                                               'appliesTo', x.applies_to, 'country', x.country)
                            order by x.country, x.position, x.name), '[]'::jsonb)
    into v_needs
    from (select distinct on (t.id) t.id, t.name, t.short_name, t.applies_to, cp.country, cp.position
            from public.c2c_country_permits cp
            join public.permit_types t on t.id = cp.permit_type_id and t.active
           where exists (select 1 from unnest(coalesce(v_countries, '{}')) c
                          where public.commission_place_matches(cp.country, c))
             and not public.c2c_holds_permit(p_driver, t.id)
           order by t.id, cp.position) x;
  return jsonb_build_object(
    'ok', v_exp and jsonb_array_length(v_needs) = 0,
    'minYears', v_min,
    'years', v_years,
    'drivingSince', v_since,
    'experienceOk', v_exp,
    'needs', v_needs,
    'ruleId', r.id);
end;
$$;
revoke execute on function public.c2c_driver_eligibility(uuid, jsonb, jsonb, text[]) from public, anon, authenticated;

create or replace function public.c2c_driver_check(p_driver uuid, p_pickup jsonb, p_drop jsonb,
                                                   p_via text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and auth.uid() is distinct from p_driver and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.c2c_driver_eligibility(p_driver, p_pickup, p_drop, p_via);
end;
$$;
revoke execute on function public.c2c_driver_check(uuid, jsonb, jsonb, text[]) from public, anon;
grant execute on function public.c2c_driver_check(uuid, jsonb, jsonb, text[]) to authenticated, service_role;

-- ---- 1. Bookings -----------------------------------------------------------------------------------------
create sequence if not exists public.c2c_booking_ref_seq start 20001;

create table if not exists public.c2c_bookings (
  id                      uuid primary key default gen_random_uuid(),
  ref                     text not null unique default ('CC-' || nextval('public.c2c_booking_ref_seq')),
  rider_id                uuid not null references public.profiles(id) on delete cascade,
  service                 text not null default 'City to City',
  trip_kind               text not null default 'whole_car' check (trip_kind = 'whole_car'),
  pickup_name             text not null check (char_length(btrim(pickup_name)) between 1 and 200),
  pickup_address          text check (pickup_address is null or char_length(pickup_address) <= 400),
  pickup_lat              double precision not null check (pickup_lat between -90 and 90),
  pickup_lng              double precision not null check (pickup_lng between -180 and 180),
  pickup_place            jsonb not null default '{}'::jsonb,
  drop_name               text not null check (char_length(btrim(drop_name)) between 1 and 200),
  drop_address            text check (drop_address is null or char_length(drop_address) <= 400),
  drop_lat                double precision not null check (drop_lat between -90 and 90),
  drop_lng                double precision not null check (drop_lng between -180 and 180),
  drop_place              jsonb not null default '{}'::jsonb,
  distance_km             numeric(8,2) not null check (distance_km > 0 and distance_km <= 5000),
  duration_min            numeric(8,1) not null check (duration_min >= 0 and duration_min <= 10000),
  leave_at                timestamptz not null,
  -- The rider is fine with ± 30 minutes.
  flexible                boolean not null default true,
  timezone                text check (timezone is null or char_length(timezone) <= 64),
  passengers              smallint not null default 1 check (passengers between 1 and 6),
  luggage                 text not null default 'small' check (luggage in ('none', 'small', 'suitcases', 'many')),
  note                    text check (note is null or char_length(note) <= 300),
  -- The rider's fare for the whole car, and the quote it was checked against.
  fare                    numeric(10,2) not null check (fare > 0 and fare <= 100000),
  currency                text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  quote                   jsonb not null default '{}'::jsonb,
  rule_id                 uuid,
  payment                 text not null check (payment in ('in_app', 'cash')),
  status                  text not null default 'open'
                            check (status in ('open', 'offered', 'booked', 'driver_arriving', 'on_trip',
                                              'completed', 'cancelled', 'expired')),
  -- No driver by then: expired.
  expires_at              timestamptz,
  driver_id               uuid references public.profiles(id) on delete set null,
  offer_id                uuid,
  agreed_fare             numeric(10,2),
  driver_leave_at         timestamptz,
  booked_at               timestamptz,
  arriving_at             timestamptz,
  started_at              timestamptz,
  completed_at            timestamptz,
  cancelled_at            timestamptz,
  expired_at              timestamptz,
  cancelled_by            text check (cancelled_by is null or cancelled_by in ('rider', 'driver', 'admin')),
  cancel_reason           text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  cancel_fee              numeric(10,2),
  cancel_fee_status       text check (cancel_fee_status is null or cancel_fee_status in ('charged', 'due', 'none')),
  rider_stars             smallint check (rider_stars is null or rider_stars between 1 and 5),
  rider_comment           text check (rider_comment is null or char_length(rider_comment) <= 500),
  rated_at                timestamptz,
  commission_rate         numeric(6,4),
  commission_base_rate    numeric(6,4),
  commission_rule_id      uuid,
  commission_tier_id      uuid,
  commission_promotion_id uuid,
  commission_locked_at    timestamptz,
  commission_amount       numeric(12,2),
  commission_charged_at   timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint c2c_bookings_driver check (status in ('open', 'offered', 'cancelled', 'expired') or driver_id is not null)
);
create index if not exists c2c_bookings_rider_idx on public.c2c_bookings (rider_id, created_at desc);
create index if not exists c2c_bookings_driver_idx on public.c2c_bookings (driver_id, leave_at) where driver_id is not null;
create index if not exists c2c_bookings_open_idx on public.c2c_bookings (expires_at) where status in ('open', 'offered');
comment on table public.c2c_bookings is
  'City to City (0307): a rider''s whole-car trip request and, once a driver is picked, the booking.';

-- ---- 3. Offers ---------------------------------------------------------------------------------------------
create table if not exists public.c2c_offers (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null references public.c2c_bookings(id) on delete cascade,
  driver_id       uuid not null references public.profiles(id) on delete cascade,
  price           numeric(10,2) not null check (price > 0 and price <= 100000),
  -- When the driver can leave.
  leave_at        timestamptz not null,
  note            text check (note is null or char_length(note) <= 200),
  -- The driver as the rider sees them, as they were when offering.
  driver_name     text,
  driver_rating   numeric(3,2),
  driver_trips    integer,
  car             text,
  plate           text,
  status          text not null default 'open' check (status in ('open', 'accepted', 'declined', 'withdrawn', 'expired')),
  -- Declined: by the rider, because another offer was taken, or the request was cancelled.
  declined_reason text check (declined_reason is null or declined_reason in ('rider', 'taken', 'cancelled')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index if not exists c2c_offers_one_open on public.c2c_offers (booking_id, driver_id) where status = 'open';
create index if not exists c2c_offers_booking_idx on public.c2c_offers (booking_id, created_at);
create index if not exists c2c_offers_driver_idx on public.c2c_offers (driver_id, created_at desc);
comment on table public.c2c_offers is
  'City to City (0307): drivers'' offers on a request: price and when they can leave.';

-- ---- 2. Checked on insert ------------------------------------------------------------------------------------
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
  if v_uid is not null then
    new.rider_id := v_uid;
  end if;
  if new.rider_id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- What only the server sets.
  new.service := 'City to City';
  new.trip_kind := 'whole_car';
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
       where b.rider_id = new.rider_id
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
drop trigger if exists trg_c2c_bookings_check on public.c2c_bookings;
create trigger trg_c2c_bookings_check
  before insert on public.c2c_bookings
  for each row execute function public.c2c_bookings_check();

-- ---- Commission locked as it is booked (0224's lock, with the service, 0306) --------------------------------
create or replace function public.c2c_bookings_lock_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
  t record;
  pm record;
begin
  new.updated_at := now();
  if new.driver_id is null or new.status not in ('booked', 'driver_arriving', 'on_trip') then
    return new;
  end if;
  if new.commission_locked_at is not null and old.driver_id is not distinct from new.driver_id then
    return new;
  end if;
  begin
    select * into v from public.commission_resolve(
      new.driver_id, new.pickup_lat, new.pickup_lng, new.pickup_place->>'country', new.pickup_place->>'state',
      new.pickup_place->>'city', new.pickup_place->>'suburb', new.service);
    select * into t from public.commission_apply_tiers(new.driver_id, v.rate, v.level);
    select * into pm from public.commission_apply_promotions(
      new.driver_id, t.rate, v.level, now(), coalesce(new.timezone, 'Asia/Kuala_Lumpur'), new.service,
      new.pickup_lat, new.pickup_lng, new.pickup_place->>'country', new.pickup_place->>'state',
      new.pickup_place->>'city', new.pickup_place->>'suburb');
    new.commission_base_rate := v.rate;
    new.commission_rate := pm.rate;
    new.commission_tier_id := case when pm.promotion_id is null then t.tier_id end;
    new.commission_promotion_id := pm.promotion_id;
    new.commission_rule_id := v.rule_id;
    new.commission_locked_at := now();
  exception when others then
    -- Never holds up the booking: the rate is found again at completion.
    raise warning 'c2c booking % commission not locked: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function public.c2c_bookings_lock_commission() from public, anon, authenticated;
drop trigger if exists trg_c2c_bookings_lock_commission on public.c2c_bookings;
create trigger trg_c2c_bookings_lock_commission
  before update on public.c2c_bookings
  for each row execute function public.c2c_bookings_lock_commission();

drop trigger if exists trg_c2c_offers_stamp on public.c2c_offers;
create or replace function public.c2c_offers_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.c2c_offers_stamp() from public, anon, authenticated;
create trigger trg_c2c_offers_stamp
  before update on public.c2c_offers
  for each row execute function public.c2c_offers_stamp();

-- ---- 8. Who may see an open request ------------------------------------------------------------------------
-- Whether the pickup [p_pickup] is in reach of driver [p_uid]: an approved
-- partner whose service area holds its state, or, listing no states, its
-- country.
create or replace function public.c2c_driver_in_reach(p_uid uuid, p_pickup jsonb)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.partners p
     where p.auth_user_id = p_uid
       and p.status = 'approved'
       and case
         when cardinality(coalesce(p.service_states, '{}')) > 0 then exists (
           select 1 from unnest(p.service_states) e
            where public.commission_place_matches(split_part(e, '|', 1), p_pickup->>'country')
              and public.commission_place_matches(split_part(e, '|', 2), p_pickup->>'state'))
         else exists (
           select 1 from unnest(coalesce(p.service_countries, '{}')) c
            where public.commission_place_matches(c, p_pickup->>'country'))
       end);
$$;
revoke execute on function public.c2c_driver_in_reach(uuid, jsonb) from public, anon, authenticated;

-- Whether the caller, as a driver, may see an open request from
-- [p_pickup] to [p_drop]: in reach, and the years and permits (0306).
create or replace function public.c2c_driver_can_see(p_pickup jsonb, p_drop jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not public.c2c_driver_in_reach(v_uid, p_pickup) then
    return false;
  end if;
  return public.c2c_driver_ok(v_uid, p_pickup, p_drop);
end;
$$;
revoke execute on function public.c2c_driver_can_see(jsonb, jsonb) from public, anon;
grant execute on function public.c2c_driver_can_see(jsonb, jsonb) to authenticated, service_role;

-- ---- Reading and writing -----------------------------------------------------------------------------------
alter table public.c2c_bookings enable row level security;
alter table public.c2c_offers enable row level security;
revoke all on public.c2c_bookings from anon, authenticated;
revoke all on public.c2c_offers from anon, authenticated;
grant select, insert on public.c2c_bookings to authenticated;
grant select on public.c2c_offers to authenticated;
grant all on public.c2c_bookings to service_role;
grant all on public.c2c_offers to service_role;
grant usage on sequence public.c2c_booking_ref_seq to authenticated, service_role;

drop policy if exists "c2c_bookings read" on public.c2c_bookings;
create policy "c2c_bookings read" on public.c2c_bookings for select to authenticated
  using (rider_id = (select auth.uid())
         or driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (status in ('open', 'offered') and expires_at > now()
             and public.c2c_driver_can_see(pickup_place, drop_place)));
drop policy if exists "c2c_bookings rider insert" on public.c2c_bookings;
create policy "c2c_bookings rider insert" on public.c2c_bookings for insert to authenticated
  with check (rider_id = (select auth.uid()));

drop policy if exists "c2c_offers read" on public.c2c_offers;
create policy "c2c_offers read" on public.c2c_offers for select to authenticated
  using (driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or exists (select 1 from public.c2c_bookings b
                     where b.id = booking_id and b.rider_id = (select auth.uid())));

-- An admin with EDIT on City to City may cancel a booking (c2c_cancel).
insert into public.admin_table_pages (target, page) values
  ('c2c_bookings', 'admin-settings-city-to-city'),
  ('c2c_offers', 'admin-settings-city-to-city')
on conflict do nothing;

-- ---- 7. Expiry ---------------------------------------------------------------------------------------------
-- Closes requests whose time to leave passed with no driver; how many.
create or replace function public.c2c_expire_due()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  with gone as (
    update public.c2c_bookings
       set status = 'expired', expired_at = now()
     where status in ('open', 'offered') and expires_at <= now()
    returning id)
  select coalesce(array_agg(id), '{}') into v_ids from gone;
  update public.c2c_offers set status = 'expired' where booking_id = any(v_ids) and status = 'open';
  return cardinality(v_ids);
end;
$$;
revoke execute on function public.c2c_expire_due() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'c2c-expire-due';
    perform cron.schedule('c2c-expire-due', '*/5 * * * *', $job$select public.c2c_expire_due()$job$);
  end if;
end $$;

-- ---- 4. The rider --------------------------------------------------------------------------------------------
-- Accepts offer [p_offer]: the request locked, the offer accepted, every
-- other open offer declined, the booking booked (the commission is locked
-- by trg_c2c_bookings_lock_commission). {id, status, agreedFare}.
create or replace function public.c2c_accept_offer(p_offer uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.c2c_offers;
  b public.c2c_bookings;
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

  update public.c2c_offers set status = 'accepted' where id = o.id;
  update public.c2c_offers set status = 'declined', declined_reason = 'taken'
   where booking_id = b.id and id <> o.id and status = 'open';
  update public.c2c_bookings
     set status = 'booked', driver_id = o.driver_id, offer_id = o.id, agreed_fare = o.price,
         driver_leave_at = o.leave_at, booked_at = now()
   where id = b.id
  returning * into b;
  return jsonb_build_object('id', b.id, 'status', b.status, 'agreedFare', b.agreed_fare);
end;
$$;
revoke execute on function public.c2c_accept_offer(uuid) from public, anon;
grant execute on function public.c2c_accept_offer(uuid) to authenticated, service_role;

-- Declines offer [p_offer]; the request is open again when none is left.
create or replace function public.c2c_decline_offer(p_offer uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.c2c_offers;
  b public.c2c_bookings;
begin
  select * into o from public.c2c_offers where id = p_offer;
  if o.id is null then
    return;
  end if;
  select * into b from public.c2c_bookings where id = o.booking_id for update;
  if b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.c2c_offers set status = 'declined', declined_reason = 'rider' where id = o.id and status = 'open';
  if b.status = 'offered' and not exists (select 1 from public.c2c_offers
                                           where booking_id = b.id and status = 'open') then
    update public.c2c_bookings set status = 'open' where id = b.id;
  end if;
end;
$$;
revoke execute on function public.c2c_decline_offer(uuid) from public, anon;
grant execute on function public.c2c_decline_offer(uuid) to authenticated, service_role;

-- Changes the rider's fare on request [p_booking] (no driver picked yet)
-- within the range of the quote it was made with, or not at all on a
-- fixed fare.
create or replace function public.c2c_set_fare(p_booking uuid, p_fare numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status not in ('open', 'offered') or b.expires_at <= now() then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023',
      hint = 'This trip already has a driver, or it was cancelled.';
  end if;
  if b.quote->>'fareMode' = 'fixed' then
    raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
      hint = 'This route has a fixed fare of ' || public.c2c_money((b.quote->>'suggested')::numeric, b.currency) || '.';
  end if;
  if p_fare is null or p_fare < (b.quote->>'low')::numeric or p_fare > (b.quote->>'high')::numeric then
    raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
      hint = 'Your fare must be between ' || public.c2c_money((b.quote->>'low')::numeric, b.currency) || ' and '
             || public.c2c_money((b.quote->>'high')::numeric, b.currency) || '.';
  end if;
  update public.c2c_bookings set fare = round(p_fare, 2) where id = b.id;
end;
$$;
revoke execute on function public.c2c_set_fare(uuid, numeric) from public, anon;
grant execute on function public.c2c_set_fare(uuid, numeric) to authenticated, service_role;

-- ---- 5. The cancel fee -----------------------------------------------------------------------------------
-- The fee to cancel at [p_at] a booked trip leaving at [p_leave_at] (the
-- settings, 0306): 0 until cancel_free_hours before, then the amount; 0
-- when the fee is off.
create or replace function public.c2c_cancel_fee(p_leave_at timestamptz, p_at timestamptz default now())
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
    when s.id is null or not s.cancel_fee_on then 0::numeric
    when p_at < p_leave_at - make_interval(hours => s.cancel_free_hours) then 0::numeric
    else round(s.cancel_fee_amount, 2)
  end
  from (select 1) one
  left join public.city_to_city_settings s on s.id = 1;
$$;
revoke execute on function public.c2c_cancel_fee(timestamptz, timestamptz) from public, anon;
grant execute on function public.c2c_cancel_fee(timestamptz, timestamptz) to authenticated, service_role;

-- The fee's money: the rider's GET wallet to the driver's, less the trip's
-- commission. 'charged', or 'due' when the wallet is short.
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
  v_label text := 'City to City cancellation fee ' || b.ref;
begin
  if v_amount <= 0 or b.rider_id is null or b.driver_id is null then
    return 'none';
  end if;
  insert into public.wallets (user_id, wallet_type, balance) values (b.rider_id, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_balance from public.wallets w
   where w.user_id = b.rider_id and w.wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_amount then
    return 'due';
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
    (b.rider_id, 'get_wallet', 'payment', -v_amount, 'cancellation_fee', v_label),
    (b.driver_id, 'get_wallet', 'cancellation_fee', round(v_amount * (1 - v_rate), 2), 'cancellation_fee',
     v_label || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end);
  return 'charged';
end;
$$;
revoke execute on function public.c2c_fee_take(public.c2c_bookings, numeric) from public, anon, authenticated;

-- Cancels [p_booking]: the rider (with the fee once booked) or an admin
-- with EDIT on City to City (free). {status, fee, feeStatus}.
create or replace function public.c2c_cancel(p_booking uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  v_by text;
  v_fee numeric := 0;
  v_fee_status text := 'none';
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null then
    raise exception 'C2C_NOT_FOUND' using errcode = '22023', hint = 'This trip was not found.';
  end if;
  if b.rider_id = auth.uid() then
    v_by := 'rider';
  elsif auth.uid() is not null and public.caller_admin_can_write('c2c_bookings') then
    v_by := 'admin';
  else
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status in ('completed', 'cancelled', 'expired') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip has already ended.';
  end if;
  if b.status = 'on_trip' then
    raise exception 'C2C_ON_TRIP' using errcode = '22023',
      hint = 'The trip has started. Talk to your driver, or contact support.';
  end if;
  if v_by = 'rider' and b.status in ('booked', 'driver_arriving') then
    v_fee := public.c2c_cancel_fee(b.leave_at, now());
  end if;
  if v_fee > 0 then
    v_fee_status := public.c2c_fee_take(b, v_fee);
  end if;
  update public.c2c_offers set status = 'declined', declined_reason = 'cancelled'
   where booking_id = b.id and status = 'open';
  update public.c2c_bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_by,
         cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300),
         cancel_fee = v_fee, cancel_fee_status = v_fee_status
   where id = b.id;
  return jsonb_build_object('status', 'cancelled', 'fee', v_fee, 'feeStatus', v_fee_status);
end;
$$;
revoke execute on function public.c2c_cancel(uuid, text) from public, anon;
grant execute on function public.c2c_cancel(uuid, text) to authenticated, service_role;

-- The other party of a booked trip, for Call and Chat: the rider gets the
-- driver's {name, phone}, the driver the rider's; null before booking and
-- after the trip.
create or replace function public.c2c_contact(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  v_other uuid;
begin
  select * into b from public.c2c_bookings where id = p_booking;
  if b.id is null or auth.uid() is null or auth.uid() not in (b.rider_id, coalesce(b.driver_id, b.rider_id)) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status not in ('booked', 'driver_arriving', 'on_trip') then
    return null;
  end if;
  v_other := case when auth.uid() = b.rider_id then b.driver_id else b.rider_id end;
  return (
    select jsonb_build_object(
      'name', coalesce(nullif(btrim(pa.name), ''), nullif(btrim(pr.name), ''), 'Your driver'),
      'phone', coalesce(nullif(btrim(pa.phone), ''), nullif(btrim(pr.phone), '')))
      from public.profiles pr
      left join lateral (select p.name, p.phone from public.partners p
                          where p.auth_user_id = pr.id and v_other = b.driver_id
                          order by p.created_at limit 1) pa on true
     where pr.id = v_other);
end;
$$;
revoke execute on function public.c2c_contact(uuid) from public, anon;
grant execute on function public.c2c_contact(uuid) to authenticated, service_role;

-- The rider's stars (1 to 5) and words for the driver of a completed trip, once.
create or replace function public.c2c_rate_driver(p_booking uuid, p_stars integer, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status <> 'completed' then
    raise exception 'C2C_NOT_DONE' using errcode = '22023', hint = 'Rate the driver after the trip.';
  end if;
  if b.rated_at is not null then
    raise exception 'C2C_RATED' using errcode = '22023', hint = 'You have already rated this trip.';
  end if;
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'C2C_BAD_RATING' using errcode = '22023', hint = 'Pick 1 to 5 stars.';
  end if;
  update public.c2c_bookings
     set rider_stars = p_stars, rider_comment = left(nullif(btrim(coalesce(p_comment, '')), ''), 500), rated_at = now()
   where id = b.id;
end;
$$;
revoke execute on function public.c2c_rate_driver(uuid, integer, text) from public, anon;
grant execute on function public.c2c_rate_driver(uuid, integer, text) to authenticated, service_role;

-- ---- 6. The driver (the driver app, C3) ---------------------------------------------------------------------
-- Offers [p_price] on request [p_booking], leaving at [p_leave_at] (the
-- rider's time when null): within ± 30 minutes of it when the rider is
-- flexible, else at it. Offering again changes the open offer. Its id.
create or replace function public.c2c_make_offer(p_booking uuid, p_price numeric, p_leave_at timestamptz default null,
                                                 p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  b public.c2c_bookings;
  chk jsonb;
  v_leave timestamptz;
  v_slack interval;
  v_id uuid;
  pa record;
  v_tz text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or b.status not in ('open', 'offered') or b.expires_at <= now() then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This request is no longer open.';
  end if;
  if b.rider_id = v_uid then
    raise exception 'C2C_OWN_TRIP' using errcode = '22023', hint = 'You can''t offer on your own trip.';
  end if;
  if not public.c2c_driver_in_reach(v_uid, b.pickup_place) then
    raise exception 'C2C_NOT_FOR_YOU' using errcode = '22023', hint = 'This trip starts outside your service area.';
  end if;
  chk := public.c2c_driver_check(v_uid, b.pickup_place, b.drop_place);
  if not coalesce((chk->>'ok')::boolean, false) then
    raise exception 'C2C_DRIVER_NOT_ELIGIBLE' using errcode = '22023',
      hint = case when not coalesce((chk->>'experienceOk')::boolean, false)
                  then 'This route needs ' || (chk->>'minYears') || ' years of driving.'
                  else 'This route needs ' || coalesce((select string_agg(e->>'name', ', ')
                                                          from jsonb_array_elements(chk->'needs') e), 'a permit')
                       || '.' end;
  end if;
  if b.quote->>'fareMode' = 'fixed' then
    if round(p_price, 2) <> round((b.quote->>'suggested')::numeric, 2) then
      raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
        hint = 'This route has a fixed fare of ' || public.c2c_money((b.quote->>'suggested')::numeric, b.currency) || '.';
    end if;
  elsif p_price is null or p_price < (b.quote->>'low')::numeric or p_price > (b.quote->>'high')::numeric then
    raise exception 'C2C_FARE_OUT_OF_RANGE' using errcode = '22023',
      hint = 'Offer between ' || public.c2c_money((b.quote->>'low')::numeric, b.currency) || ' and '
             || public.c2c_money((b.quote->>'high')::numeric, b.currency) || '.';
  end if;
  v_leave := coalesce(p_leave_at, b.leave_at);
  v_slack := case when b.flexible then interval '30 minutes' else interval '0' end;
  if v_leave < b.leave_at - v_slack or v_leave > b.leave_at + v_slack then
    v_tz := coalesce(b.timezone, 'Asia/Kuala_Lumpur');
    raise exception 'C2C_LEAVE_OUT_OF_WINDOW' using errcode = '22023',
      hint = case when b.flexible
                  then 'Offer to leave between ' || to_char((b.leave_at - v_slack) at time zone v_tz, 'FMHH24:MI')
                       || ' and ' || to_char((b.leave_at + v_slack) at time zone v_tz, 'FMHH24:MI') || '.'
                  else 'Offer to leave at ' || to_char(b.leave_at at time zone v_tz, 'FMHH24:MI') || '.' end;
  end if;

  select p.name, p.rating, p.total_rides, nullif(btrim(concat_ws(' ', p.make, p.model)), '') as car,
         nullif(btrim(coalesce(p.plate, '')), '') as plate
    into pa
    from public.partners p where p.auth_user_id = v_uid order by p.created_at limit 1;
  update public.c2c_offers
     set price = round(p_price, 2), leave_at = v_leave, note = left(nullif(btrim(coalesce(p_note, '')), ''), 200)
   where booking_id = b.id and driver_id = v_uid and status = 'open'
  returning id into v_id;
  if v_id is null then
    insert into public.c2c_offers (booking_id, driver_id, price, leave_at, note, driver_name, driver_rating,
                                   driver_trips, car, plate)
    values (b.id, v_uid, round(p_price, 2), v_leave, left(nullif(btrim(coalesce(p_note, '')), ''), 200),
            coalesce(nullif(btrim(pa.name), ''), (select nullif(btrim(name), '') from public.profiles where id = v_uid),
                     'Driver'),
            pa.rating, pa.total_rides, pa.car, pa.plate)
    returning id into v_id;
  end if;
  if b.status = 'open' then
    update public.c2c_bookings set status = 'offered' where id = b.id;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.c2c_make_offer(uuid, numeric, timestamptz, text) from public, anon;
grant execute on function public.c2c_make_offer(uuid, numeric, timestamptz, text) to authenticated, service_role;

-- Takes back the driver's open offer [p_offer].
create or replace function public.c2c_withdraw_offer(p_offer uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.c2c_offers;
  b public.c2c_bookings;
begin
  select * into o from public.c2c_offers where id = p_offer;
  if o.id is null or o.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into b from public.c2c_bookings where id = o.booking_id for update;
  update public.c2c_offers set status = 'withdrawn' where id = o.id and status = 'open';
  if b.status = 'offered' and not exists (select 1 from public.c2c_offers
                                           where booking_id = b.id and status = 'open') then
    update public.c2c_bookings set status = 'open' where id = b.id;
  end if;
end;
$$;
revoke execute on function public.c2c_withdraw_offer(uuid) from public, anon;
grant execute on function public.c2c_withdraw_offer(uuid) to authenticated, service_role;

-- The commission of a completed trip (0224's charge, with the service): the
-- locked rate, else the rate found now, on the agreed fare, from the
-- driver's GET credit.
create or replace function public.c2c_charge_commission(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  v_fare numeric;
  v_rate numeric;
  v_amount numeric(12,2);
  v record;
  t record;
  pm record;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or b.status <> 'completed' or b.driver_id is null or b.commission_charged_at is not null then
    return;
  end if;
  v_fare := round(coalesce(b.agreed_fare, b.fare, 0), 2);
  if v_fare <= 0 then
    return;
  end if;
  if b.commission_locked_at is not null and b.commission_rate is not null then
    v_rate := b.commission_rate;
  else
    select * into v from public.commission_resolve(
      b.driver_id, b.pickup_lat, b.pickup_lng, b.pickup_place->>'country', b.pickup_place->>'state',
      b.pickup_place->>'city', b.pickup_place->>'suburb', b.service);
    select * into t from public.commission_apply_tiers(b.driver_id, v.rate, v.level);
    select * into pm from public.commission_apply_promotions(
      b.driver_id, t.rate, v.level, coalesce(b.booked_at, now()), coalesce(b.timezone, 'Asia/Kuala_Lumpur'), b.service,
      b.pickup_lat, b.pickup_lng, b.pickup_place->>'country', b.pickup_place->>'state',
      b.pickup_place->>'city', b.pickup_place->>'suburb');
    v_rate := pm.rate;
    b.commission_rule_id := v.rule_id;
    b.commission_tier_id := case when pm.promotion_id is null then t.tier_id end;
    b.commission_promotion_id := pm.promotion_id;
  end if;
  if v_rate is null or v_rate < 0 or v_rate >= 1 then
    return;
  end if;
  v_amount := round(v_fare * v_rate, 2);
  if v_amount > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (b.driver_id, 'get_credit', 'commission', -v_amount,
            'City to City commission ' || round(v_rate * 100, 1) || '% of ' || public.c2c_money(v_fare, b.currency)
            || ' (' || b.ref || ')');
  end if;
  update public.c2c_bookings
     set commission_rate = v_rate, commission_rule_id = b.commission_rule_id,
         commission_tier_id = b.commission_tier_id, commission_promotion_id = b.commission_promotion_id,
         commission_amount = v_amount, commission_charged_at = now()
   where id = b.id;
end;
$$;
revoke all on function public.c2c_charge_commission(uuid) from public, anon, authenticated, service_role;

-- The booked driver moves trip [p_booking] on: driver_arriving, on_trip,
-- completed (the commission charged).
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
         completed_at = case when p_status = 'completed' then now() else completed_at end
   where id = b.id;
  if p_status = 'completed' then
    perform public.c2c_charge_commission(b.id);
  end if;
end;
$$;
revoke execute on function public.c2c_driver_progress(uuid, text) from public, anon;
grant execute on function public.c2c_driver_progress(uuid, text) to authenticated, service_role;

-- ---- 9. Live in the apps and the admin pages ----------------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['c2c_bookings', 'c2c_offers'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
