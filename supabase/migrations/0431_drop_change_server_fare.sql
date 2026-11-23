-- ============================================================================
-- 0431 — The server prices a mid-ride drop-off change itself.
--
-- When a passenger moves the drop-off of a ride under way (0341), the new fare
-- is now worked out here, from what the server itself holds:
--
--   * The fare card. Admin → Fare tariffs for the ride's pickup area and
--     service: the narrowest place with a card for the service, and there the
--     vehicle's own card, then its type's, then one for every service, with
--     the service's multiplier (Cost per km / 1.5) unless the card is the
--     vehicle's own. With no card, the service's own rates; with none of
--     those, the built-in TEKSI tariff. This is how the booking sheet quotes a
--     ride (lib/src/core/fare_tariff.dart, quoteFare), now in the database:
--     ride_card_fare. The fare is rounded as the ride's region books fares.
--   * The route. The distance and time the route service measured from the
--     ride's pickup to the new drop-off in the last 15 minutes
--     (fare_ai_responses, which only ai-route-proxy writes):
--     ride_route_measured. The app asks for that route to show the fare, so
--     it is there when the change is sent. An answer a phone worked out by
--     itself (Apple Maps on an iPhone, logged as apple_device) is the
--     phone's, not the server's, and is not taken.
--
-- The fare the app sends with the change (p_new_fare) is the fare the rider
-- was shown, and nothing more: a change whose fare here is higher (a cent of
-- rounding aside) is refused (DROP_CHANGE_FARE, the hint says the fare), so
-- nobody pays more than they agreed to, and the app shows the fare again. The
-- distance and time it sends are kept with the ride only where the server
-- has no route of its own; they price nothing.
--
-- What applies at once and what waits for the driver (ride_drop_change_terms):
--
--   * Dearer: at once within the admin's threshold, else the driver. As 0341.
--   * The same fare: at once when "Auto-approve when it is cheaper" is on. As
--     0341.
--   * Cheaper: at once only when that switch is on and the trip got shorter
--     to match: the fare falls by no bigger a share than the straight line
--     from the pickup to the drop-off did. A lower fare for a trip that is
--     not that much shorter waits for the driver, who sees both fares.
--   * Where the server cannot price the change, the fare stays as it is and
--     the driver is asked about the new drop-off. That is a change with no
--     route of the server's own (none measured, or a ride with stops, whose
--     route is not pickup to drop-off), and a ride the fare card does not
--     price (hire, myGiG, an airport fare, Freight, Courier, an operator's
--     booking).
--
-- ride_drop_change_quote answers the same thing without changing the ride:
-- the app shows the server's fare, and whether the driver will be asked,
-- before the rider confirms.
--
-- ride_drop_change_request is recreated from its body in 0341: same
-- arguments, same answer ({applied, pending, fare}), same grants, no DROP. An
-- app from before this migration keeps working: it is answered with the
-- server's fare. The driver's half (ride_drop_change_resolve, 0428) and the
-- rider's withdraw are not changed.
--
-- A drop-off is moved only through these RPCs, which are security definer. So
-- a guard (ride_requests_guard_drop_change) keeps the drop_change_* columns
-- and the service server-only on a client update: the held change and the
-- service a ride is priced on are the server's, not a column a client writes.
-- The RPCs run as the owner and pass it, as they pass the older fare and route
-- guards (0174, 0223).
--
-- Checked in supabase/tests/drop_change_0341.sql.
-- ============================================================================

-- ---- 1. The fare card's price for a trip ----------------------------------------------------------
-- What [p_service] costs for [p_km] km and [p_min] minutes from a pickup in
-- [p_country] / [p_state] / [p_city] / [p_suburb], to the cent: on the fare
-- card for that place and service, else on the service's own rates, else on
-- the built-in TEKSI tariff. The service is looked up by its name, as a ride
-- carries it (ride_requests.service). Not rounded to whole amounts: the
-- caller does that where the region books whole fares.
create or replace function public.ride_card_fare(
  p_service text,
  p_country text,
  p_state text,
  p_city text,
  p_suburb text,
  p_km numeric,
  p_min numeric
) returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_km      numeric := greatest(coalesce(p_km, 0), 0);
  v_min     numeric := greatest(coalesce(p_min, 0), 0);
  v_country text := lower(btrim(coalesce(p_country, '')));
  v_state   text := lower(btrim(coalesce(p_state, '')));
  v_city    text := lower(btrim(coalesce(p_city, '')));
  v_suburb  text := lower(btrim(coalesce(p_suburb, '')));
  v_sid     text;
  v_vals    jsonb;
  v_types   text[];
  v_cost    numeric;
  v_mult    numeric := 1;
  v_taxi    boolean;
  t         public.fare_tariffs;
begin
  -- The Vehicle Services entry of that name (one in use before one switched
  -- off), and the Service Settings types it belongs to (cards are keyed by
  -- their ids, 0123).
  select e.id::text, e.values into v_sid, v_vals
    from public.settings_entries e
   where e.category = 'vehicle-services'
     and btrim(coalesce(p_service, '')) <> ''
     and lower(btrim(e.values->>'name')) = lower(btrim(p_service))
   order by e.active desc, e.position, e.created_at, e.id
   limit 1;
  select array_agg(m.id::text) into v_types
    from public.settings_entries m
   where m.category = 'service-settings'
     and lower(btrim(m.values->>'name')) in (
       select lower(btrim(x)) from jsonb_array_elements_text(
         case when jsonb_typeof(v_vals->'serviceTypes') = 'array' then v_vals->'serviceTypes' else '[]'::jsonb end) x);
  v_types := coalesce(v_types, '{}');
  -- The service's multiplier: its Cost per km over the base 1.5 (0300).
  v_cost := case when v_vals->>'costPerKm' ~ '^[0-9]+(\.[0-9]+)?$' then (v_vals->>'costPerKm')::numeric end;
  if v_cost is not null and v_cost > 0 then
    v_mult := v_cost / 1.5;
  end if;

  select f.* into t
    from public.fare_tariffs f
   where f.active
     and ((f.vehicle_service is not null and f.vehicle_service = v_sid
           and (f.service_type is null or cardinality(v_types) = 0 or f.service_type = any(v_types)))
          or (f.vehicle_service is null and f.service_type is not null and f.service_type = any(v_types))
          or (f.vehicle_service is null and f.service_type is null))
     and case f.level
       when 'suburb' then v_suburb <> '' and lower(btrim(f.suburb)) = v_suburb and lower(btrim(f.city)) = v_city
                          and lower(btrim(f.state)) = v_state and lower(btrim(f.country)) = v_country
       when 'city' then v_city <> '' and lower(btrim(f.city)) = v_city and lower(btrim(f.state)) = v_state
                        and lower(btrim(f.country)) = v_country
       when 'state' then v_state <> '' and lower(btrim(f.state)) = v_state and lower(btrim(f.country)) = v_country
       when 'country' then v_country <> '' and lower(btrim(f.country)) = v_country
       when 'master' then true
       else false
     end
   order by case f.level when 'suburb' then 0 when 'city' then 1 when 'state' then 2 when 'country' then 3 else 4 end,
            case when f.vehicle_service is not null then 0 when f.service_type is not null then 1 else 2 end,
            f.created_at, f.id
   limit 1;
  if t.id is not null then
    -- A vehicle's own card is its fare: no multiplier on top (0123).
    return round(greatest(t.minimum_fare,
                          (t.base_fare + t.per_km * v_km + t.per_minute * v_min)
                          * case when t.vehicle_service is null then v_mult else 1 end)
                 + t.booking_fee, 2);
  end if;

  -- The service's own rates (0300); a metered taxi has none.
  v_taxi := lower(coalesce(v_vals->>'name', '') || ' ' || coalesce(v_vals->>'serviceTypes', '')) ~ '(teksi|taxi)';
  if v_cost is not null and v_cost > 0 and not coalesce(v_taxi, false) then
    return round(greatest(
      case when v_vals->>'minFareAmount' ~ '^[0-9]+(\.[0-9]+)?$' then (v_vals->>'minFareAmount')::numeric else 0 end,
      v_km * v_cost
        + v_min * case when v_vals->>'costPerMin' ~ '^[0-9]+(\.[0-9]+)?$' then (v_vals->>'costPerMin')::numeric else 0 end), 2);
  end if;
  -- The built-in TEKSI tariff (0306), at the service's multiplier.
  return round(public.c2c_teksi_fare(v_km, v_min) * v_mult, 2);
end;
$$;
revoke execute on function public.ride_card_fare(text, text, text, text, text, numeric, numeric) from public, anon, authenticated;

-- ---- 2. The route the server measured ---------------------------------------------------------------
-- The distance (km) and time (minutes) the route service last measured from
-- one point straight to another, within the last 15 minutes; no row when it
-- measured none. A trip asked about through stops is another trip, and an
-- answer a phone worked out by itself (apple_device) is not the server's:
-- neither is taken.
create or replace function public.ride_route_measured(
  p_from_lat double precision,
  p_from_lng double precision,
  p_to_lat double precision,
  p_to_lng double precision
) returns table (km numeric, minutes numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select f.distance_km::numeric, f.duration_min::numeric
    from public.fare_ai_responses f
   where f.success
     and f.provider <> 'apple_device'
     and f.created_at > now() - interval '15 minutes'
     and abs(f.origin_lat - p_from_lat) < 0.00001
     and abs(f.origin_lng - p_from_lng) < 0.00001
     and abs(f.dest_lat - p_to_lat) < 0.00001
     and abs(f.dest_lng - p_to_lng) < 0.00001
     and f.extra->'stops' is null
     and f.distance_km > 0 and f.distance_km <= 5000
     and f.duration_min > 0 and f.duration_min <= 10000
   order by f.created_at desc, f.id desc
   limit 1;
$$;
revoke execute on function public.ride_route_measured(double precision, double precision, double precision, double precision) from public, anon, authenticated;

-- ---- 3. The terms of a change ------------------------------------------------------------------------
-- What moving [p_ride]'s drop-off to (p_lat, p_lng) comes to:
--   {fare, distance_km, duration_min, instant, priced, measured}
-- the fare, the distance and time the change is recorded with, whether it
-- applies at once (else the driver is asked), whether the fare card prices
-- this kind of ride, and whether the server has a route of its own for it.
-- The fare is the card's over that route when both hold; otherwise it is the
-- fare the ride has, and the driver is asked. [p_distance_km] and
-- [p_duration_min] are what the app sent: recorded when the server has no
-- route of its own, and never priced. Raises drop_change_off and
-- drop_change_limit, as 0341.
create or replace function public.ride_drop_change_terms(
  p_ride public.ride_requests,
  p_lat double precision,
  p_lng double precision,
  p_distance_km numeric,
  p_duration_min numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cfg      jsonb;
  v_old      numeric;
  v_thresh   numeric;
  v_delta    numeric;
  -- Straight lines from the pickup, in km: to the drop-off as it is, and to
  -- the new one. The server's own measure of how far the trip goes.
  v_line_old double precision;
  v_line_new double precision;
  v_priced   boolean;
  v_measured boolean := false;
  v_km       numeric;
  v_min      numeric;
  v_fare     numeric;
  v_instant  boolean;
begin
  v_cfg := public.city_ride_config()->'dropChange';
  if not (v_cfg->>'allow')::boolean then
    raise exception 'drop_change_off' using errcode = '22023';
  end if;
  if coalesce(p_ride.drop_change_count, 0) >= (v_cfg->>'maxChangesPerRide')::int then
    raise exception 'drop_change_limit' using errcode = '22023';
  end if;

  -- Rides priced another way are not for the fare card.
  v_priced := p_ride.hire_package is null and p_ride.mygig is null and p_ride.airport_fare is null
              and p_ride.cargo_description is null and p_ride.parcel_size is null and p_ride.fare_mode is null;

  -- The route: the server's own measurement of pickup → new drop-off. A ride
  -- with stops goes through them, so that measurement is not its route.
  if v_priced and p_ride.pickup_lat is not null and p_ride.pickup_lng is not null
     and coalesce(jsonb_array_length(case when jsonb_typeof(p_ride.stops) = 'array' then p_ride.stops end), 0) = 0 then
    select r.km, r.minutes into v_km, v_min
      from public.ride_route_measured(p_ride.pickup_lat, p_ride.pickup_lng, p_lat, p_lng) r;
    v_measured := found;
  end if;

  -- Nothing to price it on: the fare stays, and the driver is asked.
  if not v_measured then
    return jsonb_build_object('fare', coalesce(p_ride.ride_fare, p_ride.fare),
                              'distance_km', p_distance_km, 'duration_min', p_duration_min,
                              'instant', false, 'priced', v_priced, 'measured', false);
  end if;

  v_fare := public.ride_card_fare(p_ride.service, p_ride.country, p_ride.state, p_ride.city, p_ride.suburb, v_km, v_min);
  v_fare := case when v_fare is null or v_fare <= 0 then 0
                 when p_ride.whole_fare then ceil(v_fare)
                 else round(v_fare, 2) end;

  v_old := coalesce(p_ride.ride_fare, p_ride.fare, 0);
  v_delta := v_fare - v_old;
  v_thresh := greatest((v_cfg->>'autoApproveRm')::numeric, v_old * (v_cfg->>'autoApprovePct')::numeric / 100.0);
  if v_delta > 0 then
    v_instant := v_delta <= v_thresh;
  elsif v_delta = 0 then
    v_instant := (v_cfg->>'autoApproveCheaper')::boolean;
  else
    -- Cheaper: only when the trip got shorter to match, the fare falling by
    -- no bigger a share than the straight line did.
    v_line_new := public.geo_distance_m(p_ride.pickup_lat, p_ride.pickup_lng, p_lat, p_lng) / 1000.0;
    if p_ride.drop_lat is not null and p_ride.drop_lng is not null then
      v_line_old := public.geo_distance_m(p_ride.pickup_lat, p_ride.pickup_lng, p_ride.drop_lat, p_ride.drop_lng) / 1000.0;
    end if;
    v_instant := (v_cfg->>'autoApproveCheaper')::boolean
                 and v_line_old is not null and v_line_new < v_line_old
                 and v_fare * v_line_old::numeric >= v_old * v_line_new::numeric;
  end if;

  return jsonb_build_object('fare', v_fare, 'distance_km', round(v_km, 2), 'duration_min', round(v_min, 1),
                            'instant', coalesce(v_instant, false), 'priced', true, 'measured', true);
end;
$$;
revoke execute on function public.ride_drop_change_terms(public.ride_requests, double precision, double precision, numeric, numeric) from public, anon, authenticated;

-- ---- 4. The rider asks what a change would come to ------------------------------------------------
-- Returns {fare, instant}: the fare for the ride with its drop-off at
-- (p_lat, p_lng), and whether the change would apply at once (else the driver
-- is asked). Changes nothing. The rider's own ride only, under way, as the
-- request itself.
create or replace function public.ride_drop_change_quote(
  p_ride uuid,
  p_lat double precision,
  p_lng double precision,
  p_distance_km numeric,
  p_duration_min numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ride  public.ride_requests;
  v_terms jsonb;
begin
  select * into v_ride from public.ride_requests where id = p_ride;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ride.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'not_ongoing' using errcode = '22023';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_distance_km not between 0 and 5000 or p_duration_min not between 0 and 10000 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  v_terms := public.ride_drop_change_terms(v_ride, p_lat, p_lng, p_distance_km, p_duration_min);
  return jsonb_build_object('fare', v_terms->'fare', 'instant', v_terms->'instant');
end;
$$;
revoke execute on function public.ride_drop_change_quote(uuid, double precision, double precision, numeric, numeric) from public, anon;
grant execute on function public.ride_drop_change_quote(uuid, double precision, double precision, numeric, numeric) to authenticated;

-- ---- 5. Rider requests a new drop (0341) ------------------------------------------------------------
-- Returns {applied, pending, fare}, the fare being the server's
-- (ride_drop_change_terms). [p_new_fare] is the fare the rider was shown: the
-- change is refused when the server's fare is higher. [p_distance_km] and
-- [p_duration_min] are kept with the ride when the server has no route of
-- its own, and price nothing.
create or replace function public.ride_drop_change_request(
  p_ride uuid,
  p_name text,
  p_address text,
  p_lat double precision,
  p_lng double precision,
  p_distance_km numeric,
  p_duration_min numeric,
  p_new_fare numeric
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride  public.ride_requests;
  v_terms jsonb;
  v_fare  numeric;
  v_km    numeric;
  v_min   numeric;
begin
  select * into v_ride from public.ride_requests where id = p_ride;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ride.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'not_ongoing' using errcode = '22023';
  end if;
  if p_new_fare is null or not public.ride_money_ok(p_new_fare)
     or p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_distance_km not between 0 and 5000 or p_duration_min not between 0 and 10000 then
    raise exception 'bad_request' using errcode = '22023';
  end if;

  v_terms := public.ride_drop_change_terms(v_ride, p_lat, p_lng, p_distance_km, p_duration_min);
  v_fare := (v_terms->>'fare')::numeric;
  v_km := (v_terms->>'distance_km')::numeric;
  v_min := (v_terms->>'duration_min')::numeric;

  -- Nobody pays more than the fare they were shown (a cent aside: an app's
  -- own rounding of a fare may fall a cent under the server's).
  if v_fare > p_new_fare + 0.01 then
    raise exception 'DROP_CHANGE_FARE' using errcode = '22023',
      hint = format('The fare for this drop-off is %s, more than the fare shown, so nothing was changed. '
                    'Try again, and update the app if it happens again.', to_char(v_fare, 'FM999999990.00'));
  end if;

  if (v_terms->>'instant')::boolean then
    update public.ride_requests set
      drop_name = p_name,
      drop_address = p_address,
      drop_lat = p_lat,
      drop_lng = p_lng,
      distance_km = coalesce(v_km, distance_km),
      duration_min = coalesce(round(v_min)::int, duration_min),
      ride_fare = v_fare,
      drop_change_count = coalesce(drop_change_count, 0) + 1,
      drop_change_requested_at = null,
      drop_change_requested_by = null,
      drop_change_name = null, drop_change_address = null,
      drop_change_lat = null, drop_change_lng = null,
      drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
      drop_change_outcome = 'accepted',
      drop_change_outcome_by = 'auto',
      drop_change_outcome_at = now()
    where id = p_ride;
    return jsonb_build_object('applied', true, 'pending', false, 'fare', v_fare);
  end if;

  update public.ride_requests set
    drop_change_requested_at = now(),
    drop_change_requested_by = 'rider',
    drop_change_name = p_name,
    drop_change_address = p_address,
    drop_change_lat = p_lat,
    drop_change_lng = p_lng,
    drop_change_distance_km = v_km,
    drop_change_duration_min = v_min,
    drop_change_fare = v_fare,
    drop_change_outcome = null,
    drop_change_outcome_by = null,
    drop_change_outcome_at = null
  where id = p_ride;
  return jsonb_build_object('applied', false, 'pending', true, 'fare', v_fare);
end;
$$;
revoke execute on function public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric) from public, anon;
grant execute on function public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric) to authenticated;

-- ---- 6. The held change and the service are the server's -------------------------------------------
-- The pricing above is reached only through the three drop-change RPCs, which
-- are security definer. A participant can also update their own
-- ride_requests row directly ("ride_requests participant update"), and the
-- older guards (0174 ride_requests_guard_fare, 0223
-- ride_requests_guard_client_columns) fix the fare, the pricing, the route and
-- the place once a ride is under way — this adds the drop_change_* columns and
-- the service to what a client can't write. The held change is the server's
-- (it is priced and staged by ride_drop_change_request, applied by
-- ride_drop_change_resolve), and so is the service a ride is priced on. For a
-- client (not a security definer function, not an admin) neither can change on
-- an update; the RPCs run as the owner and pass, as the other guards let them.
create or replace function public.ride_requests_guard_drop_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  -- The held-change columns are written only by the drop-change RPCs (0341,
  -- 0428, 0431).
  if (new.drop_change_requested_at, new.drop_change_requested_by, new.drop_change_name,
      new.drop_change_address, new.drop_change_lat, new.drop_change_lng,
      new.drop_change_distance_km, new.drop_change_duration_min, new.drop_change_fare,
      new.drop_change_outcome, new.drop_change_outcome_by, new.drop_change_outcome_at,
      new.drop_change_count)
     is distinct from
     (old.drop_change_requested_at, old.drop_change_requested_by, old.drop_change_name,
      old.drop_change_address, old.drop_change_lat, old.drop_change_lng,
      old.drop_change_distance_km, old.drop_change_duration_min, old.drop_change_fare,
      old.drop_change_outcome, old.drop_change_outcome_by, old.drop_change_outcome_at,
      old.drop_change_count) then
    raise exception 'RIDE_DROP_CHANGE_SERVER_ONLY' using errcode = '42501',
      hint = 'Move the drop-off through the app''s Change button; the server prices it.';
  end if;
  -- The service a ride was booked on is what it is priced on, so it is fixed.
  if new.service is distinct from old.service then
    raise exception 'RIDE_SERVICE_LOCKED' using errcode = '42501',
      hint = 'The service a ride was booked on can''t be changed.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_drop_change() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_guard_drop_change on public.ride_requests;
create trigger trg_ride_requests_b_guard_drop_change
  before update on public.ride_requests
  for each row execute function public.ride_requests_guard_drop_change();

notify pgrst, 'reload schema';
