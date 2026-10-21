-- ============================================================================
-- 0266 — Where a point is: a place inside an airport's boundary is the place.
--
-- 0258's area_at answered an airport first, then the smallest place. A mall
-- with its own boundary and doors inside an airport's (Mitsui Outlet Park,
-- inside KLIA's) was then the airport: the rider's pin went to the airport's
-- doors, kilometres away, and the mall's doors were refused
-- (AIRPORT_DOOR_INVALID). Now the smallest place boundary holding the point
-- comes first, then an airport (the first by position, as before). A point
-- in an airport and in no place is the airport's, as before.
--
-- The app matches points the same way (lib/src/core/airport_areas.dart,
-- areasByPrecedence). Everything that asks airport_at (the ride trigger, the
-- fare quote, the scheduled doors, the driver's state) follows.
-- ============================================================================

create or replace function public.area_at(p_lat float8, p_lng float8)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select a.id
    from public.airport_areas a
   where a.active and p_lat is not null and p_lng is not null
     and public.airport_in_rings(p_lat, p_lng,
           public.airport_rings(case when a.kind = 'place' then a.shape else a.values->'boundary' end))
   order by (a.kind <> 'place'),
            case when a.kind = 'place' then coalesce(a.size_m2, 'infinity'::float8) else 0 end,
            a.position, a.created_at
   limit 1;
$$;
revoke execute on function public.area_at(float8, float8) from public, anon;
grant execute on function public.area_at(float8, float8) to authenticated, service_role;
