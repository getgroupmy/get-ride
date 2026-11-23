-- ============================================================================
-- 0432 — The drop-off change functions read the ride under its row lock.
--
-- ride_drop_change_request (the rider's half, 0341) and
-- ride_drop_change_resolve (the driver's half, last recreated in 0431) each
-- read the ride, check the caller and that the ride is accepted, arrived or
-- on_trip, and then write to the ride. That read now takes the ride's row
-- lock (select ... for update), so the ride's status cannot change between
-- the check and the write. The other functions that check a ride and then
-- write to it read it the same way (start_trip in 0152, for one).
--
-- Both functions are recreated from their latest bodies with only that
-- change: ride_drop_change_request from 0341, ride_drop_change_resolve from
-- 0431. Same signatures, same grants, same search_path, no DROP. The app is
-- not touched.
--
-- ride_drop_change_withdraw (0341) is not changed: it checks no status.
--
-- One transaction cannot show two calls overlapping, so
-- supabase/tests/drop_change_0341.sql checks what it can see: that both
-- functions read the ride for update, so that a later migration which
-- recreates one of them from its body keeps the lock.
-- ============================================================================

-- ---- Rider requests a new drop (0341) ---------------------------------------------------------
-- Returns {applied, pending, fare}. Applied at once when cheaper or within the
-- admin threshold; otherwise held pending for the driver.
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
  v_ride public.ride_requests;
  v_cfg jsonb;
  v_old numeric;
  v_delta numeric;
  v_thresh numeric;
  v_auto boolean;
begin
  -- The ride is read under its row lock (0432), so its status cannot change
  -- between the checks below and the write.
  select * into v_ride from public.ride_requests where id = p_ride for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ride.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'not_ongoing' using errcode = '22023';
  end if;
  if p_new_fare is null or p_new_fare < 0 or p_lat is null or p_lng is null then
    raise exception 'bad_request' using errcode = '22023';
  end if;

  v_cfg := public.city_ride_config()->'dropChange';
  if not (v_cfg->>'allow')::boolean then
    raise exception 'drop_change_off' using errcode = '22023';
  end if;
  if coalesce(v_ride.drop_change_count, 0) >= (v_cfg->>'maxChangesPerRide')::int then
    raise exception 'drop_change_limit' using errcode = '22023';
  end if;

  v_old := coalesce(v_ride.ride_fare, v_ride.fare, 0);
  v_delta := p_new_fare - v_old;
  v_thresh := greatest((v_cfg->>'autoApproveRm')::numeric, v_old * (v_cfg->>'autoApprovePct')::numeric / 100.0);
  v_auto := (v_delta <= 0 and (v_cfg->>'autoApproveCheaper')::boolean)
            or (v_delta > 0 and v_delta <= v_thresh);

  if v_auto then
    update public.ride_requests set
      drop_name = p_name,
      drop_address = p_address,
      drop_lat = p_lat,
      drop_lng = p_lng,
      distance_km = coalesce(p_distance_km, distance_km),
      duration_min = coalesce(round(p_duration_min)::int, duration_min),
      ride_fare = p_new_fare,
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
    return jsonb_build_object('applied', true, 'pending', false, 'fare', p_new_fare);
  end if;

  update public.ride_requests set
    drop_change_requested_at = now(),
    drop_change_requested_by = 'rider',
    drop_change_name = p_name,
    drop_change_address = p_address,
    drop_change_lat = p_lat,
    drop_change_lng = p_lng,
    drop_change_distance_km = p_distance_km,
    drop_change_duration_min = p_duration_min,
    drop_change_fare = p_new_fare,
    drop_change_outcome = null,
    drop_change_outcome_by = null,
    drop_change_outcome_at = null
  where id = p_ride;
  return jsonb_build_object('applied', false, 'pending', true, 'fare', p_new_fare);
end;
$$;
revoke execute on function public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric) from public, anon;
grant execute on function public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric) to authenticated;

-- ---- Driver accepts or rejects a pending change (0341) -------------------------------------------
create or replace function public.ride_drop_change_resolve(p_ride uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.ride_requests;
begin
  -- The ride is read under its row lock (0432), so its status cannot change
  -- between the checks below and the write.
  select * into v_ride from public.ride_requests where id = p_ride for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  -- The ride's driver: ride_requests.partner_id is the driver's account id
  -- (0428), not a partners.id.
  if v_ride.partner_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- Only while the ride is under way (0431), as ride_drop_change_request has it.
  if v_ride.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'not_ongoing' using errcode = '22023';
  end if;
  if v_ride.drop_change_requested_at is null then
    raise exception 'no_pending' using errcode = '22023';
  end if;

  if p_accept then
    update public.ride_requests set
      drop_name = drop_change_name,
      drop_address = drop_change_address,
      drop_lat = drop_change_lat,
      drop_lng = drop_change_lng,
      distance_km = coalesce(drop_change_distance_km, distance_km),
      duration_min = coalesce(round(drop_change_duration_min)::int, duration_min),
      ride_fare = coalesce(drop_change_fare, ride_fare),
      drop_change_count = coalesce(drop_change_count, 0) + 1,
      drop_change_requested_at = null,
      drop_change_requested_by = null,
      drop_change_name = null, drop_change_address = null,
      drop_change_lat = null, drop_change_lng = null,
      drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
      drop_change_outcome = 'accepted',
      drop_change_outcome_by = 'partner',
      drop_change_outcome_at = now()
    where id = p_ride;
    return jsonb_build_object('accepted', true);
  end if;

  update public.ride_requests set
    drop_change_requested_at = null,
    drop_change_requested_by = null,
    drop_change_name = null, drop_change_address = null,
    drop_change_lat = null, drop_change_lng = null,
    drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
    drop_change_outcome = 'declined',
    drop_change_outcome_by = 'partner',
    drop_change_outcome_at = now()
  where id = p_ride;
  return jsonb_build_object('accepted', false);
end;
$$;
revoke execute on function public.ride_drop_change_resolve(uuid, boolean) from public, anon;
grant execute on function public.ride_drop_change_resolve(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
