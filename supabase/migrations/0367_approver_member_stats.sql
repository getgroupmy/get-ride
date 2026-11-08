-- ============================================================================
-- 0367: approver_member_stats — the Statistics tab of My Team's Member screen.
--
-- The driver KPIs the mockup shows, for one covered member over a period:
--   in-app jobs, myGiG jobs, earnings, avg earning/km, minutes online,
--   online km, total km on jobs, cancellations (by driver / by user).
--
-- Aggregated from data that already exists:
--   ride_requests            completed in-app jobs, fares, distance, cancels
--   mygig_bookings           myGiG jobs + their price
--   partner_online_sessions  time online
--   telematics_online_km     km driven online
-- Scoped by approver_covers; read-only.
--
--   approver_member_stats(member, period) → jsonb, period in
--     'month' (this calendar month, default), 'last_month', 'all'.
-- ============================================================================
create or replace function public.approver_member_stats(p_member uuid, p_period text default 'month')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from       timestamptz;
  v_to         timestamptz := now();
  v_in_app     int := 0;
  v_mygig      int := 0;
  v_fare       numeric := 0;
  v_km         numeric := 0;
  v_minutes    numeric := 0;
  v_online_km  numeric := 0;
  v_canc_drv   int := 0;
  v_canc_usr   int := 0;
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;

  v_from := case p_period
              when 'all' then '-infinity'::timestamptz
              when 'last_month' then date_trunc('month', now()) - interval '1 month'
              else date_trunc('month', now())
            end;
  if p_period = 'last_month' then
    v_to := date_trunc('month', now());
  end if;

  -- In-app jobs (completed), fares, distance, cancellations.
  select
    count(*) filter (where r.status = 'completed'),
    coalesce(sum(coalesce(r.ride_fare, r.fare, 0)) filter (where r.status = 'completed'), 0),
    coalesce(sum(coalesce(r.distance_km, 0)) filter (where r.status = 'completed'), 0),
    count(*) filter (where r.status = 'cancelled' and r.cancel_requested_by = r.partner_id),
    count(*) filter (where r.status = 'cancelled' and (r.cancel_requested_by is null or r.cancel_requested_by <> r.partner_id))
  into v_in_app, v_fare, v_km, v_canc_drv, v_canc_usr
  from public.ride_requests r
  where r.partner_id = p_member
    and coalesce(r.completed_at, r.created_at) >= v_from
    and coalesce(r.completed_at, r.created_at) < v_to;

  -- myGiG jobs + their price, added to the in-app earning (the table may be
  -- empty; the count and sum stay 0 then).
  select count(*), v_fare + coalesce(sum(coalesce(m.price, 0)), 0)
    into v_mygig, v_fare
  from public.mygig_bookings m
  where m.driver_id = p_member and m.cancelled_at is null
    and m.created_at >= v_from and m.created_at < v_to;

  -- Minutes online (sessions that started in the period).
  select coalesce(sum(extract(epoch from (coalesce(s.ended_at, s.last_seen_at, now()) - s.started_at)) / 60.0), 0)
    into v_minutes
  from public.partner_online_sessions s
  where s.profile_id = p_member and s.started_at >= v_from and s.started_at < v_to;

  -- Online km driven.
  select coalesce(sum(coalesce(t.capped_km, t.km, 0)), 0) into v_online_km
  from public.telematics_online_km t
  where t.driver_id = p_member and t.hour_start >= v_from and t.hour_start < v_to;

  return jsonb_build_object(
    'period', p_period,
    'in_app_jobs', v_in_app,
    'mygig_jobs', v_mygig,
    'earning', round(v_fare, 2),
    'avg_per_km', case when v_km > 0 then round(v_fare / v_km, 2) end,
    'minutes_online', round(v_minutes),
    'online_km', round(v_online_km),
    'total_km', round(v_km),
    'cancelled_by_driver', v_canc_drv,
    'cancelled_by_user', v_canc_usr);
end;
$$;
revoke execute on function public.approver_member_stats(uuid, text) from public, anon;
grant execute on function public.approver_member_stats(uuid, text) to authenticated;

notify pgrst, 'reload schema';
