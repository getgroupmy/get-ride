-- ============================================================================
-- 0418: index the nearby-driver search by position
--
-- nearby_online_drivers (0145) is called for every new ride request and at
-- every ring of the dispatch ladder (0417). It measured the great-circle
-- distance to EVERY online driver: driver_presence was indexed only by
-- updated_at, so the cost grew with the number of drivers online anywhere.
--
--   * driver_presence_online_geo: a partial btree on (lat, lng) for online
--     drivers with a position;
--   * nearby_online_drivers first keeps drivers inside a lat/lng box around
--     the pickup (which the index answers), then applies the exact haversine
--     distance as before. The box is never smaller than the circle, so the
--     same drivers come back; only the search is cheaper.
--
-- No PostGIS needed. Additive: same signature, same results.
-- ============================================================================

create index if not exists driver_presence_online_geo
  on public.driver_presence (lat, lng)
  where online and lat is not null and lng is not null;

create or replace function public.nearby_online_drivers(
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision default null
)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with q as (
    select coalesce(p_radius_km, public.ride_request_push_radius_km()) as r
  ), box as (
    select q.r,
           q.r / 111.0 as dlat,
           -- Degrees of longitude per km shrink with latitude; near the poles
           -- (or for a huge radius) skip the longitude limit altogether.
           case when abs(p_lat) + q.r / 111.0 >= 89 then null
                else q.r / (111.0 * cos(radians(abs(p_lat) + q.r / 111.0)))
           end as dlng
      from q
  )
  select d.profile_id
    from public.driver_presence d, box b
   where d.online
     and d.lat is not null and d.lng is not null
     and p_lat is not null and p_lng is not null
     and d.updated_at > now() - interval '3 minutes'
     and d.lat between p_lat - b.dlat and p_lat + b.dlat
     and (b.dlng is null
          or b.dlng >= 180
          or d.lng between p_lng - b.dlng and p_lng + b.dlng
          -- A box that crosses the 180th meridian wraps round.
          or d.lng + 360 between p_lng - b.dlng and p_lng + b.dlng
          or d.lng - 360 between p_lng - b.dlng and p_lng + b.dlng)
     and 2 * 6371 * asin(sqrt(
           power(sin(radians(d.lat - p_lat) / 2), 2)
           + cos(radians(p_lat)) * cos(radians(d.lat)) * power(sin(radians(d.lng - p_lng) / 2), 2)
         )) <= b.r;
$$;

revoke execute on function public.nearby_online_drivers(double precision, double precision, double precision)
  from public, anon, authenticated;
