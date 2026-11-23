-- ============================================================================
-- 0435 — The drop-off change withdraw reads the ride under its row lock.
--
-- ride_drop_change_withdraw (0341) is the rider taking back a drop-off change
-- that is held for the driver: their own cancel, or the passenger's app when
-- the response window runs out. It reads the ride, checks the caller and that
-- a change is held, and then clears it. That read now takes the ride's row
-- lock (select ... for update), as the request and the answer have it since
-- 0434, so the held change it checks is the one it writes to.
--
-- The function is recreated from its body in 0341 with only that change: same
-- signature, same grants, same search_path, no DROP. The app is not touched.
--
-- supabase/tests/drop_change_0341.sql had nothing on the withdraw. It now has
-- the rider withdrawing a held change, nobody else doing it for them, and a
-- withdraw with nothing held leaving the ride as it is. One transaction cannot
-- show two calls overlapping, so for the lock it checks what it can see: that
-- the function reads the ride for update.
-- ============================================================================

-- ---- Rider withdraws a pending change (cancel, or client-side timeout) (0341) -------------------
create or replace function public.ride_drop_change_withdraw(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.ride_requests;
begin
  -- The ride is read under its row lock (0435), so the held change checked
  -- below is the one the write clears.
  select * into v_ride from public.ride_requests where id = p_ride for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ride.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.drop_change_requested_at is null then
    return jsonb_build_object('withdrawn', false);
  end if;
  update public.ride_requests set
    drop_change_requested_at = null,
    drop_change_requested_by = null,
    drop_change_name = null, drop_change_address = null,
    drop_change_lat = null, drop_change_lng = null,
    drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
    drop_change_outcome = 'expired',
    drop_change_outcome_by = 'rider',
    drop_change_outcome_at = now()
  where id = p_ride;
  return jsonb_build_object('withdrawn', true);
end;
$$;
revoke execute on function public.ride_drop_change_withdraw(uuid) from public, anon;
grant execute on function public.ride_drop_change_withdraw(uuid) to authenticated;

notify pgrst, 'reload schema';
