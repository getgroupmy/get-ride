-- ============================================================================
-- 0177: charge the commission rides completed before 0174 never paid
--
-- Until 0174 the driver's app charged its own commission after completing a
-- trip, best effort: when that call failed (or the build predated it) the
-- ride stayed uncharged. 0174 charges it in the database on completion; this
-- catches up the rides completed before then, exactly as 0174 would have:
-- from the fare stored on the ride, at the rate commission_resolve_rate
-- gives the driver and the ride's area, once per ride
-- (ride_charge_commission skips any already charged, so running this again
-- changes nothing).
--
-- On live at the time of writing: four rides, one driver, RM173 of fares,
-- RM25.95 at the default 15%.
-- ============================================================================

do $$
declare
  r record;
begin
  for r in
    select id
      from public.ride_requests
     where status = 'completed'
       and partner_id is not null
       and commission_charged_at is null
     order by completed_at nulls first
  loop
    perform public.ride_charge_commission(r.id);
  end loop;
end
$$;
