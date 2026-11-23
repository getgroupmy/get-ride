-- ============================================================================
-- 0428 — The driver can answer a held drop-off change.
--
-- 0341's ride_drop_change_resolve decided whether the caller is the ride's
-- driver with
--
--   exists (select 1 from public.partners p
--            where p.id = v_ride.partner_id and p.auth_user_id = auth.uid())
--
-- as if ride_requests.partner_id held a partners.id. It does not: it holds the
-- driver's own account id (their auth uid, which is profiles.id).
--
--   * A ride is claimed under the policy "ride_requests claim open", whose
--     check is partner_id = auth.uid(); the other policies and the guards on
--     the table compare partner_id with auth.uid() too.
--   * The server's own lookups go the same way: ride_partner_card reads
--     partners.auth_user_id = <the ride's partner_id>, and start_trip (0152)
--     refuses when partner_id is distinct from auth.uid().
--   * The column has no foreign key to partners.
--
-- So the lookup found no row for the driver of a real ride, and both of their
-- answers were refused with not_authorized:
--
--   * A drop-off change dearer than the admin's auto-approve threshold is held
--     for the driver, who is shown Accept and Reject (partner_trip_screen.dart,
--     resolveDropChange). Neither went through.
--   * The held change could only lapse, when the passenger's app withdrew it at
--     the end of the response window. So a change that needed the driver's
--     answer never applied.
--
-- The request and withdraw halves (the rider's, rider_id = auth.uid()) were
-- right and are not changed. There was no regression test for 0341; there is
-- one now (supabase/tests/drop_change_0341.sql), with rides that carry the
-- driver's account id in partner_id, as the app writes it.
--
-- The driver is now the caller whose account id is the ride's partner_id, and
-- nobody else. The partners.id form is dropped rather than kept beside it:
-- nothing writes that id on a ride, so a match on it could only be somebody
-- who is not the ride's driver.
--
-- The function is recreated from its body in 0341 with only that check
-- changed: same signature, same grants, no DROP. The app is not touched.
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
