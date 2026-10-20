-- ============================================================================
-- 0255: Telematics — kilometres and trips per driver, per vehicle and per
-- driver in a vehicle, by hour, day, week or month (Malaysia's calendar).
--
-- What is counted, and where it comes from:
--
--   * Online km: what the driver drove while online in the app (the Drive
--     switch on, or a trip under way). The driver app adds up its own
--     location stream (loose fixes and jumps left out) and reports the
--     kilometres since its last report every few minutes and when it goes
--     offline (telematics_report_online); with an OBD-II reader linked, the
--     odometer's difference instead. The server caps each report at what a
--     car could drive since the last one (160 km/h, at most 6 hours back),
--     takes it only from a driver who was online or on a trip in the last
--     15 minutes, and adds it to the hour and the vehicle of the driver's
--     active vehicle session (telematics_online_km; a day is its hours).
--     Days before this migration have no online km: nothing is backfilled
--     from user_location_history, which is a security log.
--   * Per completed trip (ride_telematics, one row per ride):
--       estimated to pickup: the app's road route from where the driver
--         accepted to the pickup, sent when the trip screen first opens;
--         the straight line x 1.3 when no route came back;
--       estimated pickup to drop: the booking's own distance_km;
--       actual to pickup (accept to arrive) and pickup to drop (start to
--         complete): the app's GPS distance, or the odometer's difference
--         when a reader was linked at both ends (source 'obd' / 'gps').
--     Only the ride's driver reports, each value once, and the server cuts
--     an actual to 130 km/h over the leg's time and to three times its
--     estimate (or straight line) plus 5 km; what it cut is listed in
--     ride_telematics.capped.
--   * Trips by type: meter hires (meter_trips: their own GPS / meter
--     distance is the actual), the Call centre, stand orders, airport
--     pickups, scheduled bookings, My Ride / GET.now, then the service
--     booked (Ride, Comfort, 6-seater, ...) — telematics_trip_kind.
--
-- A ride's vehicle: the one stamped here when the driver reported, else the
-- ride's partner_vehicle_id stamped by 0254 (or a uuid in the legacy vehicle_id), else the vehicle
-- whose plate is the ride's partner_plate (older trips). Meter hires go by
-- their plate.
--
-- Who sees what (telematics_access):
--   * a driver: their own;
--   * an admin with the Telematics page (admin-telematics, read or edit) or
--     a full admin: everyone;
--   * a fleet owner (0251, dispatch_caller_runs_fleet): their fleet's
--     vehicles — the vehicles of the fleet (vehicle.dispatch_fleet_id) and
--     those its owner's partner owns — and only what was driven in them, by
--     whichever driver;
--   * a stand admin, or stand staff with "See reports" (dispatch_caller_can
--     'reports', as dispatch_report): their stand's orders only — the
--     drivers and vehicles that did them, those trips' kilometres and types.
--     No online km and no meter hires: what a driver does between a stand's
--     orders is not the stand's.
--
-- Nothing here redefines an existing function or adds a trigger to
-- ride_requests: 0254 (vehicle permits) rewrites ride stamping alongside.
-- ============================================================================

-- ---- Small pure helpers ---------------------------------------------------------------------
-- A number plate compared without spaces, dashes or case: "WXY 1234" = "wxy-1234".
create or replace function public.telematics_plate_key(p_plate text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g')), '')
$$;
revoke execute on function public.telematics_plate_key(text) from public, anon;
grant execute on function public.telematics_plate_key(text) to authenticated, service_role;

-- The trip type of a completed ride (lib/src/core/telematics.dart labels
-- them): the first that applies of the Call centre, a stand order, an
-- airport pickup, a scheduled booking, My Ride / GET.now (favourite drivers
-- first, or booked straight with one driver), else 'service:<the service
-- booked>' ('service:Ride' when none is named). Meter hires are 'meter'.
create or replace function public.telematics_trip_kind(
  p_stand_kind text, p_stand_id uuid, p_airport_pickup uuid, p_scheduled uuid,
  p_target_drivers uuid[], p_direct_driver uuid, p_direct_token text, p_service text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_stand_kind = 'call_centre' then 'call_centre'
    when p_stand_id is not null then 'stand'
    when p_airport_pickup is not null then 'airport'
    when p_scheduled is not null then 'scheduled'
    when p_direct_driver is not null or nullif(btrim(coalesce(p_direct_token, '')), '') is not null
      or coalesce(cardinality(p_target_drivers), 0) > 0 then 'my_ride'
    else 'service:' || coalesce(nullif(btrim(p_service), ''), 'Ride')
  end
$$;
revoke execute on function public.telematics_trip_kind(text, uuid, uuid, uuid, uuid[], uuid, text, text) from public, anon;
grant execute on function public.telematics_trip_kind(text, uuid, uuid, uuid, uuid[], uuid, text, text)
  to authenticated, service_role;

-- ---- Per ride ---------------------------------------------------------------------------------
create table if not exists public.ride_telematics (
  ride_id           uuid primary key references public.ride_requests(id) on delete cascade,
  driver_id         uuid not null references public.profiles(id) on delete cascade,
  vehicle_id        uuid references public.vehicle(id) on delete set null,
  est_pickup_km     numeric(8,2) check (est_pickup_km is null or est_pickup_km between 0 and 2000),
  est_pickup_source text check (est_pickup_source is null or est_pickup_source in ('route', 'line')),
  actual_pickup_km  numeric(8,2) check (actual_pickup_km is null or actual_pickup_km between 0 and 2000),
  pickup_source     text check (pickup_source is null or pickup_source in ('gps', 'obd')),
  actual_trip_km    numeric(8,2) check (actual_trip_km is null or actual_trip_km between 0 and 2000),
  trip_source       text check (trip_source is null or trip_source in ('gps', 'obd')),
  -- The odometer at each checkpoint, when a reader was linked.
  odo_accept_km     numeric(10,1) check (odo_accept_km is null or odo_accept_km between 0 and 3000000),
  odo_arrive_km     numeric(10,1) check (odo_arrive_km is null or odo_arrive_km between 0 and 3000000),
  odo_start_km      numeric(10,1) check (odo_start_km is null or odo_start_km between 0 and 3000000),
  odo_complete_km   numeric(10,1) check (odo_complete_km is null or odo_complete_km between 0 and 3000000),
  -- What the server cut down: 'est_pickup', 'actual_pickup', 'actual_trip'.
  capped            text[] not null default '{}',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists ride_telematics_driver_idx on public.ride_telematics (driver_id);
create index if not exists ride_telematics_vehicle_idx on public.ride_telematics (vehicle_id);

-- ---- Online km, per driver, vehicle and hour --------------------------------------------------
create table if not exists public.telematics_online_km (
  driver_id  uuid not null references public.profiles(id) on delete cascade,
  -- The driver's active vehicle session when they reported; null for none.
  vehicle_id uuid references public.vehicle(id) on delete cascade,
  hour_start timestamptz not null,
  km         numeric(9,3) not null default 0 check (km >= 0),
  gps_km     numeric(9,3) not null default 0 check (gps_km >= 0),
  obd_km     numeric(9,3) not null default 0 check (obd_km >= 0),
  -- Reported beyond the cap and not counted.
  capped_km  numeric(10,3) not null default 0 check (capped_km >= 0),
  reports    integer not null default 0 check (reports >= 0),
  updated_at timestamptz not null default now(),
  constraint telematics_online_km_key unique nulls not distinct (driver_id, vehicle_id, hour_start)
);
create index if not exists telematics_online_km_vehicle_idx on public.telematics_online_km (vehicle_id, hour_start);
create index if not exists telematics_online_km_hour_idx on public.telematics_online_km (hour_start);

-- When each driver last reported online km (the cap's clock). Server only.
create table if not exists public.telematics_driver_state (
  driver_id      uuid primary key references public.profiles(id) on delete cascade,
  last_report_at timestamptz not null
);

-- ---- Reading the period quickly ---------------------------------------------------------------
create index if not exists ride_requests_done_at_idx
  on public.ride_requests (completed_at) where status = 'completed';
create index if not exists ride_requests_done_partner_idx
  on public.ride_requests (partner_id, completed_at) where status = 'completed';
create index if not exists ride_requests_done_plate_idx
  on public.ride_requests (public.telematics_plate_key(partner_plate), completed_at) where status = 'completed';
create index if not exists meter_trips_ended_idx on public.meter_trips (ended_at);
create index if not exists vehicle_plate_key_idx on public.vehicle (public.telematics_plate_key(plate));

-- ---- Row-level security -----------------------------------------------------------------------
-- Read: the driver's own rows, or an admin's. Written only through the RPCs
-- below (security definer); the reports read through telematics_summary.
alter table public.ride_telematics enable row level security;
alter table public.telematics_online_km enable row level security;
alter table public.telematics_driver_state enable row level security;
revoke all on public.ride_telematics, public.telematics_online_km, public.telematics_driver_state from anon;
revoke all on public.ride_telematics, public.telematics_online_km, public.telematics_driver_state from authenticated;
grant select on public.ride_telematics, public.telematics_online_km to authenticated;

drop policy if exists "ride_telematics own or admin read" on public.ride_telematics;
create policy "ride_telematics own or admin read" on public.ride_telematics
  for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));

drop policy if exists "telematics_online_km own or admin read" on public.telematics_online_km;
create policy "telematics_online_km own or admin read" on public.telematics_online_km
  for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));

-- ---- The driver app reports ---------------------------------------------------------------------
-- A trip checkpoint of the caller's own ride: p_stage 'accept' (p_est_km,
-- the app's road route to the pickup, and the odometer), 'arrive'
-- (p_km driven since accepting, and the odometer), 'start' (the odometer)
-- or 'complete' (p_km driven since starting, and the odometer). Each value
-- is kept once; the ride must have reached the stage. Answers the row.
create or replace function public.telematics_ride_checkpoint(
  p_ride uuid, p_stage text, p_km numeric default null, p_odometer_km numeric default null,
  p_est_km numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  r     public.ride_requests;
  t     public.ride_telematics;
  v_odo numeric := case when p_odometer_km between 0 and 3000000 then round(p_odometer_km, 1) end;
  v_line double precision;
  v_hours double precision;
  v_max  numeric;
  v_base numeric;
  v_from numeric;
  v_km   numeric;
  v_src  text;
begin
  if uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_stage is null or p_stage not in ('accept', 'arrive', 'start', 'complete') then
    raise exception 'TELEMATICS_STAGE' using errcode = '22023', hint = 'accept, arrive, start or complete.';
  end if;
  if p_km is not null and (p_km < 0 or p_km > 5000) or p_est_km is not null and (p_est_km < 0 or p_est_km > 5000) then
    raise exception 'TELEMATICS_KM' using errcode = '22023', hint = 'A distance between 0 and 5000 km.';
  end if;
  select * into r from public.ride_requests where id = p_ride;
  if not found or r.partner_id is distinct from uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not (case p_stage
            when 'accept' then r.status in ('accepted', 'arrived', 'on_trip', 'completed')
            when 'arrive' then r.status in ('arrived', 'on_trip', 'completed')
            when 'start' then r.status in ('on_trip', 'completed')
            else r.status = 'completed' end)
     or coalesce(r.completed_at, r.accepted_at, r.updated_at) < now() - interval '2 days' then
    raise exception 'TELEMATICS_STAGE' using errcode = '22023', hint = 'The ride is not at that stage.';
  end if;

  insert into public.ride_telematics (ride_id, driver_id, vehicle_id)
  values (p_ride, uid, (select s.vehicle_id from public.vehicle_active_session s where s.user_id = uid limit 1))
  on conflict (ride_id) do nothing;
  select * into t from public.ride_telematics where ride_id = p_ride for update;
  -- Handed over to this driver (0199): the rest of the trip is theirs.
  if t.driver_id <> uid then
    update public.ride_telematics
       set driver_id = uid,
           vehicle_id = coalesce((select s.vehicle_id from public.vehicle_active_session s where s.user_id = uid limit 1),
                                 vehicle_id),
           updated_at = now()
     where ride_id = p_ride
    returning * into t;
  end if;

  if p_stage = 'accept' then
    if t.est_pickup_km is null then
      if r.partner_accept_lat is not null and r.partner_accept_lng is not null
         and r.pickup_lat is not null and r.pickup_lng is not null then
        v_line := public.dispatch_km(r.partner_accept_lat, r.partner_accept_lng, r.pickup_lat, r.pickup_lng);
      end if;
      if p_est_km is not null then
        v_km := p_est_km;
        -- A road is never shorter than the straight line, nor wildly longer.
        if v_line is not null and (v_km < v_line * 0.95 or v_km > v_line * 3 + 5) then
          v_km := least(greatest(v_km, v_line), v_line * 3 + 5);
          t.capped := array_append(t.capped, 'est_pickup');
        end if;
        v_src := 'route';
      elsif v_line is not null then
        v_km := v_line * 1.3;
        v_src := 'line';
      end if;
      if v_km is not null then
        t.est_pickup_km := round(least(v_km, 2000), 2);
        t.est_pickup_source := v_src;
      end if;
    end if;
    t.odo_accept_km := coalesce(t.odo_accept_km, v_odo);

  elsif p_stage = 'arrive' then
    t.odo_arrive_km := coalesce(t.odo_arrive_km, v_odo);
    if t.actual_pickup_km is null then
      v_hours := greatest(extract(epoch from (coalesce(r.arrived_at, now()) - coalesce(r.accepted_at, r.created_at))) / 3600.0, 0);
      if r.partner_accept_lat is not null and r.pickup_lat is not null then
        v_line := public.dispatch_km(r.partner_accept_lat, r.partner_accept_lng, r.pickup_lat, r.pickup_lng);
      end if;
      v_base := greatest(coalesce(t.est_pickup_km, 0), coalesce(v_line, 0)::numeric);
      v_max := least((130 * v_hours + 1)::numeric, case when v_base > 0 then v_base * 3 + 5 else 2000 end, 2000);
      v_from := t.odo_accept_km;
      if v_from is not null and t.odo_arrive_km is not null and t.odo_arrive_km >= v_from
         and t.odo_arrive_km - v_from <= v_max then
        t.actual_pickup_km := t.odo_arrive_km - v_from;
        t.pickup_source := 'obd';
      elsif p_km is not null then
        t.actual_pickup_km := round(least(p_km, v_max), 2);
        t.pickup_source := 'gps';
        if p_km > v_max then t.capped := array_append(t.capped, 'actual_pickup'); end if;
      end if;
    end if;

  elsif p_stage = 'start' then
    t.odo_start_km := coalesce(t.odo_start_km, v_odo);

  else
    t.odo_complete_km := coalesce(t.odo_complete_km, v_odo);
    if t.actual_trip_km is null then
      v_hours := greatest(extract(epoch from (coalesce(r.completed_at, now())
                                              - coalesce(r.started_at, r.arrived_at, r.accepted_at, r.created_at))) / 3600.0, 0);
      if r.pickup_lat is not null and r.drop_lat is not null then
        v_line := public.dispatch_km(r.pickup_lat, r.pickup_lng, r.drop_lat, r.drop_lng);
      end if;
      v_base := greatest(coalesce(r.distance_km, 0), coalesce(v_line, 0)::numeric);
      v_max := least((130 * v_hours + 1)::numeric, case when v_base > 0 then v_base * 3 + 5 else 2000 end, 2000);
      v_from := coalesce(t.odo_start_km, t.odo_arrive_km);
      if v_from is not null and t.odo_complete_km is not null and t.odo_complete_km >= v_from
         and t.odo_complete_km - v_from <= v_max then
        t.actual_trip_km := t.odo_complete_km - v_from;
        t.trip_source := 'obd';
      elsif p_km is not null then
        t.actual_trip_km := round(least(p_km, v_max), 2);
        t.trip_source := 'gps';
        if p_km > v_max then t.capped := array_append(t.capped, 'actual_trip'); end if;
      end if;
    end if;
  end if;

  update public.ride_telematics
     set est_pickup_km = t.est_pickup_km, est_pickup_source = t.est_pickup_source,
         actual_pickup_km = t.actual_pickup_km, pickup_source = t.pickup_source,
         actual_trip_km = t.actual_trip_km, trip_source = t.trip_source,
         odo_accept_km = t.odo_accept_km, odo_arrive_km = t.odo_arrive_km,
         odo_start_km = t.odo_start_km, odo_complete_km = t.odo_complete_km,
         capped = t.capped, updated_at = now()
   where ride_id = p_ride
  returning * into t;
  return jsonb_build_object(
    'ride_id', t.ride_id, 'vehicle_id', t.vehicle_id,
    'est_pickup_km', t.est_pickup_km, 'est_pickup_source', t.est_pickup_source,
    'actual_pickup_km', t.actual_pickup_km, 'pickup_source', t.pickup_source,
    'actual_trip_km', t.actual_trip_km, 'trip_source', t.trip_source, 'capped', to_jsonb(t.capped));
end;
$$;
revoke execute on function public.telematics_ride_checkpoint(uuid, text, numeric, numeric, numeric) from public, anon;
grant execute on function public.telematics_ride_checkpoint(uuid, text, numeric, numeric, numeric) to authenticated;

-- The kilometres the caller drove online since their last report ('gps',
-- or 'obd' from the odometer). Counted into this hour, on their active
-- vehicle; capped at 160 km/h since the last report (10 minutes' worth on
-- the first, 6 hours at most). Answers {km, capped_km}; {km: 0, reason:
-- 'offline'} when the driver was neither online nor on a trip lately.
create or replace function public.telematics_report_online(p_km numeric, p_source text default 'gps')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid     uuid := auth.uid();
  v_now   timestamptz := now();
  v_last  timestamptz;
  v_hours numeric;
  v_max   numeric;
  v_km    numeric;
  v_hour  timestamptz := date_trunc('hour', now() at time zone 'UTC') at time zone 'UTC';
  v_car   uuid;
begin
  if uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_km is null or p_km < 0 or p_km > 5000 then
    raise exception 'TELEMATICS_KM' using errcode = '22023', hint = 'A distance between 0 and 5000 km.';
  end if;
  if p_source is null or p_source not in ('gps', 'obd') then
    raise exception 'TELEMATICS_SOURCE' using errcode = '22023', hint = 'gps or obd.';
  end if;
  if not exists (select 1 from public.partners pa where pa.auth_user_id = uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- Online now or in the last 15 minutes (the report as they go offline),
  -- or on a trip.
  if not exists (select 1 from public.driver_presence d
                  where d.profile_id = uid and d.updated_at > v_now - interval '15 minutes')
     and not exists (select 1 from public.ride_requests r
                      where r.partner_id = uid and r.status in ('accepted', 'arrived', 'on_trip')) then
    return jsonb_build_object('km', 0, 'capped_km', 0, 'reason', 'offline');
  end if;

  select s.last_report_at into v_last from public.telematics_driver_state s where s.driver_id = uid for update;
  v_hours := least(greatest(extract(epoch from (v_now - coalesce(v_last, v_now - interval '10 minutes'))) / 3600.0, 0), 6);
  v_max := round(160 * v_hours, 3);
  v_km := round(least(p_km, v_max), 3);
  insert into public.telematics_driver_state (driver_id, last_report_at) values (uid, v_now)
  on conflict (driver_id) do update set last_report_at = excluded.last_report_at;

  select s.vehicle_id into v_car from public.vehicle_active_session s where s.user_id = uid limit 1;
  insert into public.telematics_online_km as o
         (driver_id, vehicle_id, hour_start, km, gps_km, obd_km, capped_km, reports, updated_at)
  values (uid, v_car, v_hour, v_km,
          case when p_source = 'gps' then v_km else 0 end,
          case when p_source = 'obd' then v_km else 0 end,
          round(p_km, 3) - v_km, 1, v_now)
  on conflict on constraint telematics_online_km_key do update
     set km = o.km + excluded.km, gps_km = o.gps_km + excluded.gps_km, obd_km = o.obd_km + excluded.obd_km,
         capped_km = o.capped_km + excluded.capped_km, reports = o.reports + 1, updated_at = excluded.updated_at;
  return jsonb_build_object('km', v_km, 'capped_km', round(p_km, 3) - v_km);
end;
$$;
revoke execute on function public.telematics_report_online(numeric, text) from public, anon;
grant execute on function public.telematics_report_online(numeric, text) to authenticated;

-- ---- Who may see what -----------------------------------------------------------------------------
create or replace function public.telematics_caller_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (public.admin_can_read(auth.uid(), 'admin-telematics') or public.caller_is_full_admin());
$$;
revoke execute on function public.telematics_caller_is_admin() from public, anon;
grant execute on function public.telematics_caller_is_admin() to authenticated;

-- How the caller looks: 'stand' (p_stand's orders), 'fleet' (p_fleet's
-- vehicles), 'admin' (everyone) or 'self' (their own, p_driver null or
-- theirs). Anything else is refused.
create or replace function public.telematics_access(p_driver uuid, p_fleet uuid, p_stand uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_stand is not null then
    if public.dispatch_caller_can(p_stand, 'reports') then
      return 'stand';
    end if;
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_fleet is not null then
    if public.dispatch_caller_runs_fleet(p_fleet)
       and exists (select 1 from public.dispatch_groups g where g.id = p_fleet and g.kind = 'fleet') then
      return 'fleet';
    end if;
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if public.telematics_caller_is_admin() then
    return 'admin';
  end if;
  if p_driver is null or p_driver = auth.uid() then
    return 'self';
  end if;
  raise exception 'not_authorized' using errcode = '42501';
end;
$$;
revoke execute on function public.telematics_access(uuid, uuid, uuid) from public, anon, authenticated;

-- A fleet's vehicles: linked to it, or owned by its owner's partner.
create or replace function public.telematics_fleet_vehicles(p_group uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(v.id), '{}')
    from public.vehicle v
   where v.dispatch_fleet_id = p_group
      or exists (select 1 from public.dispatch_groups g
                  where g.id = p_group and g.kind = 'fleet' and g.fleet_owner_partner_id is not null
                    and v.owner_partner_id = g.fleet_owner_partner_id);
$$;
revoke execute on function public.telematics_fleet_vehicles(uuid) from public, anon, authenticated;

-- A ride's vehicle: stamped here, else the ride's own vehicle_id, else by plate.
create or replace function public.telematics_vehicle_of(p_stamped uuid, p_ride_vehicle text, p_plate text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    p_stamped,
    case when p_ride_vehicle ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         then (select v.id from public.vehicle v where v.id = p_ride_vehicle::uuid) end,
    (select v.id from public.vehicle v
      where public.telematics_plate_key(p_plate) is not null
        and public.telematics_plate_key(v.plate) = public.telematics_plate_key(p_plate)
      order by v.updated_at desc
      limit 1));
$$;
revoke execute on function public.telematics_vehicle_of(uuid, text, text) from public, anon, authenticated;

-- ---- The rows a report is made of -------------------------------------------------------------------
-- Completed trips and meter hires in [p_from, p_to), narrowed to a driver,
-- a vehicle, a fleet's vehicles and / or a stand's orders (no meter hires).
create or replace function public.telematics_trips(
  p_from timestamptz, p_to timestamptz, p_driver uuid, p_vehicle uuid, p_fleet uuid, p_stand uuid)
returns table (ride_id uuid, driver_id uuid, vehicle_id uuid, done_at timestamptz, kind text,
               est_pickup_km numeric, est_trip_km numeric, act_pickup_km numeric, act_trip_km numeric,
               pickup_source text, trip_source text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key   text := (select public.telematics_plate_key(v.plate) from public.vehicle v where v.id = p_vehicle);
  v_fleet uuid[] := case when p_fleet is not null then public.telematics_fleet_vehicles(p_fleet) end;
begin
  return query
  with cand as (
    -- One vehicle: the trips stamped with it, and older ones by its plate.
    select t.ride_id as id
      from public.ride_telematics t
      join public.ride_requests r on r.id = t.ride_id
     where p_vehicle is not null and t.vehicle_id = p_vehicle
       and r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to
    union
    select r.id
      from public.ride_requests r
     where p_vehicle is not null and v_key is not null and r.status = 'completed'
       and public.telematics_plate_key(r.partner_plate) = v_key
       and r.completed_at >= p_from and r.completed_at < p_to
    union
    select r.id
      from public.ride_requests r
     where p_vehicle is null and r.status = 'completed'
       and r.completed_at >= p_from and r.completed_at < p_to
       and (p_driver is null or r.partner_id = p_driver)
       and (p_stand is null or r.stand_id = p_stand)
  ), rides as (
    select r.id, r.partner_id, r.completed_at,
           public.telematics_trip_kind(s.kind, r.stand_id, r.airport_pickup_id, r.scheduled_ride_id,
                                       r.target_driver_ids, r.direct_driver_id, r.direct_qr_token, r.service) as kind,
           public.telematics_vehicle_of(coalesce(t.vehicle_id, r.partner_vehicle_id), r.vehicle_id, r.partner_plate) as vid,
           t.est_pickup_km, r.distance_km, t.actual_pickup_km, t.actual_trip_km, t.pickup_source, t.trip_source
      from cand c
      join public.ride_requests r on r.id = c.id
      left join public.ride_telematics t on t.ride_id = r.id
      left join public.dispatch_stands s on s.id = r.stand_id
     where r.partner_id is not null
       and (p_driver is null or r.partner_id = p_driver)
       and (p_stand is null or r.stand_id = p_stand)
  )
  select x.id, x.partner_id, x.vid, x.completed_at, x.kind,
         x.est_pickup_km::numeric, x.distance_km::numeric, x.actual_pickup_km::numeric, x.actual_trip_km::numeric,
         x.pickup_source, x.trip_source
    from rides x
   where (p_vehicle is null or x.vid = p_vehicle)
     and (v_fleet is null or x.vid = any (v_fleet))
  union all
  select m.id, m.partner_id, mv.vid, m.ended_at, 'meter'::text,
         null::numeric, null::numeric, null::numeric, m.distance_km::numeric, null::text, 'meter'::text
    from public.meter_trips m
    cross join lateral (select public.telematics_vehicle_of(null, null, m.plate) as vid) mv
   where p_stand is null
     and m.ended_at >= p_from and m.ended_at < p_to
     and (p_driver is null or m.partner_id = p_driver)
     and (p_vehicle is null or mv.vid = p_vehicle)
     and (v_fleet is null or mv.vid = any (v_fleet));
end;
$$;
revoke execute on function public.telematics_trips(timestamptz, timestamptz, uuid, uuid, uuid, uuid)
  from public, anon, authenticated;

-- Online km hours in [p_from, p_to), narrowed the same way.
create or replace function public.telematics_online(
  p_from timestamptz, p_to timestamptz, p_driver uuid, p_vehicle uuid, p_fleet uuid)
returns table (driver_id uuid, vehicle_id uuid, hour_start timestamptz, km numeric, obd_km numeric)
language sql
stable
security definer
set search_path = public
as $$
  select o.driver_id, o.vehicle_id, o.hour_start, o.km::numeric, o.obd_km::numeric
    from public.telematics_online_km o
   where o.hour_start >= p_from and o.hour_start < p_to
     and (p_driver is null or o.driver_id = p_driver)
     and (p_vehicle is null or o.vehicle_id = p_vehicle)
     and (p_fleet is null or o.vehicle_id = any (public.telematics_fleet_vehicles(p_fleet)));
$$;
revoke execute on function public.telematics_online(timestamptz, timestamptz, uuid, uuid, uuid)
  from public, anon, authenticated;

-- A period the reports take: up to 366 days (and a day either side for the
-- time zone), hours for up to a week.
create or replace function public.telematics_check_period(p_from timestamptz, p_to timestamptz, p_bucket text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_bucket is null or p_bucket not in ('hour', 'day', 'week', 'month') then
    raise exception 'TELEMATICS_PERIOD' using errcode = '22023', hint = 'By hour, day, week or month.';
  end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '368 days'
     or (p_bucket = 'hour' and p_to - p_from > interval '8 days') then
    raise exception 'TELEMATICS_PERIOD' using errcode = '22023', hint = 'Pick a period of up to a year.';
  end if;
end;
$$;
revoke execute on function public.telematics_check_period(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.telematics_check_period(timestamptz, timestamptz, text) to authenticated;

-- ---- The reports ------------------------------------------------------------------------------------
-- One driver (p_driver), one vehicle (p_vehicle), a driver in a vehicle
-- (both) or the whole scope (neither) over [p_from, p_to), in p_bucket
-- buckets of Malaysia's calendar. p_fleet / p_stand look as a fleet owner /
-- stand person. To pickup and with passenger use the actual km where
-- recorded, else the estimate; "other" is the online km left over.
create or replace function public.telematics_summary(
  p_from timestamptz, p_to timestamptz, p_bucket text,
  p_driver uuid default null, p_vehicle uuid default null, p_fleet uuid default null, p_stand uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz constant text := 'Asia/Kuala_Lumpur';
  v_mode   text := public.telematics_access(p_driver, p_fleet, p_stand);
  v_driver uuid := case when v_mode = 'self' then auth.uid() else p_driver end;
  v jsonb;
begin
  perform public.telematics_check_period(p_from, p_to, p_bucket);
  with trips as materialized (
    select * from public.telematics_trips(p_from, p_to, v_driver, p_vehicle, p_fleet, p_stand)
  ), online as materialized (
    select * from public.telematics_online(p_from, p_to, v_driver, p_vehicle, p_fleet) where v_mode <> 'stand'
  ), slots as (
    select g.s
      from generate_series(date_trunc(p_bucket, p_from at time zone tz),
                           (p_to at time zone tz) - interval '1 second',
                           ('1 ' || p_bucket)::interval) as g(s)
  ), tb as (
    select date_trunc(p_bucket, x.done_at at time zone tz) as s, count(*) as n,
           sum(coalesce(x.act_pickup_km, x.est_pickup_km, 0)) as pick,
           sum(coalesce(x.act_trip_km, x.est_trip_km, 0)) as trip
      from trips x group by 1
  ), ob as (
    select date_trunc(p_bucket, o.hour_start at time zone tz) as s, sum(o.km) as km
      from online o group by 1
  )
  select jsonb_build_object(
    'mode', v_mode,
    'online_recorded', exists (select 1 from online),
    'online_km', coalesce((select round(sum(o.km), 2) from online o), 0),
    'online_obd_km', coalesce((select round(sum(o.obd_km), 2) from online o), 0),
    'trips', (select count(*) from trips),
    'km', (select jsonb_build_object(
             'est_pickup', round(sum(x.est_pickup_km), 2),
             'est_trip', round(sum(x.est_trip_km), 2),
             'act_pickup', round(sum(x.act_pickup_km), 2),
             'act_trip', round(sum(x.act_trip_km), 2),
             'pickup_pairs', count(*) filter (where x.est_pickup_km is not null and x.act_pickup_km is not null),
             'est_pickup_paired', round(sum(x.est_pickup_km) filter (where x.act_pickup_km is not null), 2),
             'act_pickup_paired', round(sum(x.act_pickup_km) filter (where x.est_pickup_km is not null), 2),
             'trip_pairs', count(*) filter (where x.est_trip_km is not null and x.act_trip_km is not null),
             'est_trip_paired', round(sum(x.est_trip_km) filter (where x.act_trip_km is not null), 2),
             'act_trip_paired', round(sum(x.act_trip_km) filter (where x.est_trip_km is not null), 2),
             'with_actual', count(*) filter (where x.act_pickup_km is not null or x.act_trip_km is not null),
             'obd', count(*) filter (where x.pickup_source = 'obd' or x.trip_source = 'obd'))
             from trips x),
    'buckets', (select coalesce(jsonb_agg(jsonb_build_object(
                  'start', to_char(sl.s, 'YYYY-MM-DD"T"HH24:MI'),
                  'trips', coalesce(tb.n, 0),
                  'pickup_km', round(coalesce(tb.pick, 0), 2),
                  'trip_km', round(coalesce(tb.trip, 0), 2),
                  'online_km', round(coalesce(ob.km, 0), 2),
                  'other_km', round(greatest(coalesce(ob.km, 0) - coalesce(tb.pick, 0) - coalesce(tb.trip, 0), 0), 2))
                  order by sl.s), '[]'::jsonb)
                  from slots sl left join tb on tb.s = sl.s left join ob on ob.s = sl.s),
    'types', (select coalesce(jsonb_agg(jsonb_build_object('kind', k.kind, 'trips', k.n) order by k.n desc, k.kind),
                              '[]'::jsonb)
                from (select x.kind, count(*) as n from trips x group by x.kind) k)
  ) into v;
  return v;
end;
$$;
revoke execute on function public.telematics_summary(timestamptz, timestamptz, text, uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function public.telematics_summary(timestamptz, timestamptz, text, uuid, uuid, uuid, uuid)
  to authenticated;

-- Every driver ('driver'), vehicle ('vehicle') or driver in a vehicle
-- ('pair') with trips or online km in [p_from, p_to), most km first (at
-- most 1000). A driver gets their own vehicles; the other scopes as above.
create or replace function public.telematics_list(
  p_from timestamptz, p_to timestamptz, p_group text, p_fleet uuid default null, p_stand uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mode   text := public.telematics_access(null, p_fleet, p_stand);
  v_driver uuid := case when v_mode = 'self' then auth.uid() end;
  v jsonb;
begin
  if p_group is null or p_group not in ('driver', 'vehicle', 'pair') then
    raise exception 'TELEMATICS_GROUP' using errcode = '22023', hint = 'driver, vehicle or pair.';
  end if;
  perform public.telematics_check_period(p_from, p_to, 'day');
  with trips as materialized (
    select * from public.telematics_trips(p_from, p_to, v_driver, null, p_fleet, p_stand)
  ), online as materialized (
    select * from public.telematics_online(p_from, p_to, v_driver, null, p_fleet) where v_mode <> 'stand'
  ), keyed as (
    select case when p_group = 'vehicle' then null else x.driver_id end as d,
           case when p_group = 'driver' then null else x.vehicle_id end as c,
           count(*) as n, sum(x.est_pickup_km) as ep, sum(x.est_trip_km) as et,
           sum(x.act_pickup_km) as ap, sum(x.act_trip_km) as at, 0::numeric as km
      from trips x group by 1, 2
    union all
    select case when p_group = 'vehicle' then null else o.driver_id end,
           case when p_group = 'driver' then null else o.vehicle_id end,
           0, null, null, null, null, sum(o.km)
      from online o group by 1, 2
  ), agg as (
    select k.d, k.c, sum(k.n) as n, sum(k.ep) as ep, sum(k.et) as et, sum(k.ap) as ap, sum(k.at) as at,
           sum(k.km) as km
      from keyed k group by k.d, k.c
     order by sum(k.km) desc, sum(k.n) desc
     limit 1000
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'driver_id', a.d,
           'driver_name', dn.name,
           'driver_code', dn.code,
           'vehicle_id', a.c,
           'plate', vv.plate,
           'vehicle', nullif(btrim(concat_ws(' ', vv.make, vv.model)), ''),
           'online_km', round(a.km, 2),
           'trips', a.n,
           'est_pickup_km', round(a.ep, 2), 'est_trip_km', round(a.et, 2),
           'act_pickup_km', round(a.ap, 2), 'act_trip_km', round(a.at, 2))
           order by a.km desc, a.n desc, dn.name, vv.plate), '[]'::jsonb)
    into v
    from agg a
    left join public.vehicle vv on vv.id = a.c
    left join lateral (
      select coalesce(nullif(btrim(pa.name), ''), nullif(btrim(pr.name), ''), pr.phone) as name,
             pa.display_id as code
        from public.profiles pr
        left join lateral (select p.name, p.display_id from public.partners p
                            where p.auth_user_id = pr.id order by p.created_at desc limit 1) pa on true
       where pr.id = a.d) dn on true;
  return v;
end;
$$;
revoke execute on function public.telematics_list(timestamptz, timestamptz, text, uuid, uuid) from public, anon;
grant execute on function public.telematics_list(timestamptz, timestamptz, text, uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
