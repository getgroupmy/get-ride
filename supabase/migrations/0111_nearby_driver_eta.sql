-- 0111: how far the nearest online driver is, for the confirm sheet's
-- "• 4 min" beside each vehicle (inDrive shows the same).
--
-- Riders can't read drivers' positions (online_driver_locations runs under
-- the caller's policies, i.e. admins only), and shouldn't: this hands out
-- only, per vehicle type, how far the nearest online driver is and how many
-- are within the radius. No ids, no coordinates, no names. A fix older than
-- five minutes doesn't count: that driver may be anywhere by now.

create or replace function public.nearby_driver_etas(
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision default 15
)
returns table (vehicle_type text, nearest_km double precision, drivers integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  radius double precision := least(greatest(coalesce(p_radius_km, 15), 1), 30);
begin
  if auth.uid() is null or p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return;
  end if;
  return query
    with fixes as (
      select coalesce(nullif(trim(p.vehicle_type), ''), '') as vtype,
             2 * 6371 * asin(sqrt(
               power(sin(radians(ulh.latitude - p_lat) / 2), 2)
               + cos(radians(p_lat)) * cos(radians(ulh.latitude))
                 * power(sin(radians(ulh.longitude - p_lng) / 2), 2)
             )) as km
        from public.vehicle_active_session vas
        join public.partners p on p.id = vas.partner_id
        join lateral (
          select l.latitude, l.longitude, l.captured_at
            from public.user_location_history l
           where l.user_id = vas.user_id
           order by l.captured_at desc
           limit 1
        ) ulh on true
       where vas.status = 'online'
         and ulh.captured_at > now() - interval '5 minutes'
         and vas.user_id <> auth.uid()
    )
    select f.vtype, round(min(f.km)::numeric, 2)::double precision, count(*)::integer
      from fixes f
     where f.km <= radius
     group by f.vtype;
end;
$$;

revoke all on function public.nearby_driver_etas(double precision, double precision, double precision) from public;
revoke execute on function public.nearby_driver_etas(double precision, double precision, double precision) from anon;
grant execute on function public.nearby_driver_etas(double precision, double precision, double precision) to authenticated;
