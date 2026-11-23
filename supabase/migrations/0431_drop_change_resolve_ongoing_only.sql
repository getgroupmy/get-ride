-- ============================================================================
-- 0431 — A held drop-off change is answered only while the ride is under way.
--
-- The rider's half, ride_drop_change_request (0341), takes a change only while
-- the ride is accepted, arrived or on_trip, and raises not_ongoing otherwise.
-- The driver's half, ride_drop_change_resolve, now has the same rule: once the
-- ride is no longer under way, its driver's answer (accept or reject) is
-- refused with not_ongoing, and the ride is left as it is.
--
-- The check comes after the driver check and before no_pending:
--
--   * a caller who is not the ride's driver is told not_authorized, as before,
--     whatever the ride's status;
--   * the ride's driver is told not_ongoing once the ride has ended, whether
--     or not a change is still held on it.
--
-- The app asks the driver only while the ride is under way
-- (partner_trip_screen.dart, _askAboutDropChange), and is not touched.
--
-- The function is recreated from its body in 0428 with only that check added:
-- same signature, same grants, no DROP. supabase/tests/drop_change_0341.sql
-- now ends two rides while a change is held on them, one completed and one
-- cancelled, and has the driver answer after.
-- ============================================================================

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
  select * into v_ride from public.ride_requests where id = p_ride;
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
