-- ============================================================================
-- 0300 — A car job needs a car, and a service without a fare tariff is
-- priced on its own rates (docs/KIV.md H3, H4).
--
-- Version 20261027150000 (0300_type_services_vehicle_fares). Re-runnable:
-- functions "create or replace", triggers dropped first.
--
-- 1. H3: a driver who isn't driving a vehicle (no vehicle_active_session)
--    can't bid on, take or send an offer on a request whose service needs
--    one (VEHICLE_REQUIRED, with the reason). A service needs a vehicle for
--    a driver unless one of their partner types that takes it has "Vehicle
--    required" off (partner_type_rules, 0245): Delivery takes Courier Walker
--    on foot, eHailing needs a car for Comfort. A partner with no type, a
--    request with no service, street hail and add-ons are not held, and
--    neither are bookings for later (the car is chosen on the day). The app
--    asks for a vehicle before an offer already; this is the server's half,
--    for older apps and direct calls. The services a NEW partner type takes
--    are picked when it is added (Admin → Partner Type, required).
-- 2. H4: the airport fare's rate per km (airport_per_km, 0249) with no fare
--    tariff for the service is the service's own Cost per km, as the app's
--    quote now is (km × Cost per km + minutes × Cost per min, never below
--    the Minimum fare). A metered taxi keeps the built-in TEKSI rate. Every
--    live ride service has a tariff, so no live fare changes.
-- ============================================================================

-- ---- 1. H3: a car job needs a car ----------------------------------------------------------------
-- Whether [p_service] needs a vehicle for [p_driver]: not when one of their
-- partner types that takes it has "Vehicle required" off. Not a partner, no
-- type, no service, street hail or an add-on: false.
create or replace function public.driver_service_needs_vehicle(p_driver uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_types text[];
begin
  if p_driver is null or coalesce(btrim(p_service), '') = '' or lower(btrim(p_service)) ~ '^(extra|hail):' then
    return false;
  end if;
  select array(select btrim(t)
                 from unnest(case when coalesce(cardinality(p.partner_types), 0) > 0
                                  then p.partner_types else array[p.partner_type] end) as t
                where coalesce(btrim(t), '') <> '')
    into v_types
    from public.partners p
   where p.auth_user_id = p_driver
   order by p.created_at
   limit 1;
  if coalesce(cardinality(v_types), 0) = 0 then
    return false;
  end if;
  return not exists (select 1 from unnest(v_types) as t
                      where public.partner_type_allows_service(t, p_service)
                        and not coalesce((public.partner_type_rules(t) ->> 'vehicleRequired')::boolean, false));
end;
$$;
revoke execute on function public.driver_service_needs_vehicle(uuid, text) from public, anon, authenticated;
grant execute on function public.driver_service_needs_vehicle(uuid, text) to service_role;

-- Why [p_driver] can't offer on [p_service] now for want of a vehicle, or
-- null: it needs one and they aren't driving one.
create or replace function public.driver_vehicle_missing(p_driver uuid, p_service text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select format('%s requests need a vehicle. Pick the vehicle you''re driving in Partner, '
                'then you can offer on these jobs.', btrim(p_service))
   where public.driver_session_vehicle(p_driver) is null
     and public.driver_service_needs_vehicle(p_driver, p_service);
$$;
revoke execute on function public.driver_vehicle_missing(uuid, text) from public, anon, authenticated;
grant execute on function public.driver_vehicle_missing(uuid, text) to service_role;

-- As 0299, and a bid or take on a service that needs a vehicle, with none
-- in session, is refused (VEHICLE_REQUIRED).
create or replace function public.ride_requests_driver_services()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated');
  v_keep uuid[];
  l public.driver_service_locks;
  v_block jsonb;
  v_why text;
begin
  if tg_op = 'INSERT' then
    if coalesce(btrim(new.service), '') = '' then
      return new;
    end if;
    if v_app and new.status = 'open' and new.direct_driver_id is not null
       and not public.driver_takes_service(new.direct_driver_id, new.service) then
      raise exception 'DRIVER_SERVICE_OFF_DIRECT' using errcode = '42501',
        hint = format('This driver doesn''t take %s requests right now. Choose another service, or book without the code.',
                      new.service);
    end if;
    if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0 then
      select coalesce(array_agg(d), '{}') into v_keep
        from unnest(new.target_driver_ids) d
       where public.driver_takes_service(d, new.service);
      if cardinality(v_keep) = 0 then
        new.target_driver_ids := null;
        new.targeted_until := null;
      else
        new.target_driver_ids := v_keep;
      end if;
    end if;
    return new;
  end if;
  -- A driver's own bid or take from the app.
  if not (v_app and old.status = 'open'
          and new.partner_id is not null and new.partner_id is distinct from old.partner_id
          and new.partner_id = auth.uid()) then
    return new;
  end if;
  -- 0299: not a service of the driver's partner types.
  if not public.driver_partner_service_ok(new.partner_id, old.service) then
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = format('Your Partner Service types don''t take %s requests.', old.service);
  end if;
  -- 0300: a car job with no car in session.
  v_why := public.driver_vehicle_missing(new.partner_id, old.service);
  if v_why is not null then
    raise exception 'VEHICLE_REQUIRED' using errcode = '42501', hint = v_why;
  end if;
  if not public.driver_takes_service(new.partner_id, old.service) then
    -- 0288: paused for this vehicle.
    v_block := public.vehicle_service_block(public.driver_session_vehicle(new.partner_id), old.service);
    if v_block is not null then
      raise exception 'VEHICLE_SERVICE_PAUSED' using errcode = '42501',
        hint = public.vehicle_service_block_text(v_block);
    end if;
    l := public.driver_service_lock(new.partner_id, public.driver_session_vehicle(new.partner_id), old.service);
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = case when l.id is not null
                  then format('get.ride keeps %s off for you. Contact support to change it.', old.service)
                  else format('You turned %s off in Services. Turn it on to take these requests.', old.service) end;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_driver_services() from public, anon, authenticated;

-- An offer (ride_offer_make, 0269) on a service that needs a vehicle, with
-- none in session, is refused the same way.
create or replace function public.ride_offers_vehicle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why text;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated') then
    return new;
  end if;
  select public.driver_vehicle_missing(new.partner_id, r.service) into v_why
    from public.ride_requests r
   where r.id = new.request_id;
  if v_why is not null then
    raise exception 'VEHICLE_REQUIRED' using errcode = '42501', hint = v_why;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_offers_vehicle() from public, anon, authenticated;

drop trigger if exists trg_ride_offers_vehicle on public.ride_offers;
create trigger trg_ride_offers_vehicle
  before insert on public.ride_offers
  for each row execute function public.ride_offers_vehicle();

-- ---- 2. H4: the service's own rate per km without a tariff -------------------------------------------
-- As 0249, and with no tariff: the service's Cost per km (a metered taxi:
-- the built-in TEKSI rate × the service's multiplier, as before).
create or replace function public.airport_per_km(p_service text, p_country text, p_state text, p_city text,
                                                 p_suburb text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sid  text;
  v_cost numeric;
  v_mult numeric := 1;
  v_taxi boolean := false;
  t public.fare_tariffs;
  eq text := '';
begin
  select e.id::text,
         case when e.values->>'costPerKm' ~ '^[0-9]+(\.[0-9]+)?$' then (e.values->>'costPerKm')::numeric end,
         lower(coalesce(e.values->>'name', '') || ' ' || coalesce(e.values->>'serviceTypes', '')) ~ '(teksi|taxi)'
    into v_sid, v_cost, v_taxi
    from public.settings_entries e
   where e.category = 'vehicle-services'
     and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_service, '')))
   order by e.position
   limit 1;
  if v_cost is not null and v_cost > 0 then
    v_mult := v_cost / 1.5;
  end if;
  select f.* into t
    from public.fare_tariffs f
   where f.active and f.service_type is null
     and (f.vehicle_service is null or f.vehicle_service = v_sid)
     and (f.level = 'master'
          or (f.level = 'country' and lower(f.country) = lower(coalesce(p_country, eq)))
          or (f.level = 'state' and lower(f.country) = lower(coalesce(p_country, eq))
              and lower(f.state) = lower(coalesce(p_state, eq)))
          or (f.level = 'city' and lower(f.country) = lower(coalesce(p_country, eq))
              and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq)))
          or (f.level = 'suburb' and lower(f.country) = lower(coalesce(p_country, eq))
              and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq))
              and lower(f.suburb) = lower(coalesce(p_suburb, eq))))
   order by case f.level when 'suburb' then 0 when 'city' then 1 when 'state' then 2 when 'country' then 3 else 4 end,
            (f.vehicle_service is null)
   limit 1;
  if t.id is not null then
    return round(t.per_km * case when t.vehicle_service is null then v_mult else 1 end, 4);
  end if;
  -- 0300: the service's own Cost per km.
  if v_cost is not null and v_cost > 0 and not coalesce(v_taxi, false) then
    return round(v_cost, 4);
  end if;
  return round(1.75 * v_mult, 4);
end;
$$;
revoke execute on function public.airport_per_km(text, text, text, text, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
