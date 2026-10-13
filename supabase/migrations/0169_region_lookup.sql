-- ============================================================================
-- 0169: which regions hold a point, answered by the server
--
-- Bidding, whole fares, taxes, services and scheduled rules all follow the
-- admin region the pickup is in (Admin -> Country / States / Cities). The
-- app worked that out itself, so every check read every region with its
-- mapped boundary: about 14 MB of polygons (Malaysia alone is 2.4 MB, the
-- states 12 MB). Those reads now time out (500 / 504) more often than not,
-- and a region list that cannot be read is no region at all: fares lost
-- their rounding and tax, and bidding fell back to its default. The
-- retries kept the database busy on top.
--
-- The boundaries are already kept as native polygons for the coverage
-- guard (boundary_polys, 0125, rebuilt by trigger from geofence.boundary),
-- so regions_at(lat, lng) answers from those: every region's settings and,
-- instead of its boundary, whether that boundary holds the point. A few
-- kilobytes instead of megabytes.
-- ============================================================================

-- Every region with its settings (without any boundary), and whether its
-- mapped boundary holds (p_lat, p_lng): null when it has none, or no point
-- was given. The same rows anyone can already read from the region tables.
create or replace function public.regions_at(
  p_lat double precision default null,
  p_lng double precision default null
)
returns table (
  region_table text,
  country text,
  state text,
  city text,
  suburb text,
  "values" jsonb,
  has_boundary boolean,
  inside boolean
)
language sql
stable
security definer
set search_path to ''
as $$
  with regions as (
    select 'countries'::text t, c.name::text country, ''::text state, ''::text city, ''::text suburb,
           c.values v, c.boundary_polys polys
      from public.countries c
    union all
    select 'states', s.country, s.name, '', '', s.values, s.boundary_polys from public.states s
    union all
    select 'cities', c.country, c.state, c.name, '', c.values, c.boundary_polys from public.cities c
    union all
    select 'suburbs', b.country, b.state, b.city, b.name, b.values, b.boundary_polys from public.suburbs b
  )
  select r.t, r.country, r.state, r.city, r.suburb,
         coalesce(r.v, '{}'::jsonb) - 'boundary',
         coalesce(cardinality(r.polys), 0) > 0,
         case
           when coalesce(cardinality(r.polys), 0) = 0 or p_lat is null or p_lng is null then null
           else exists (select 1 from unnest(r.polys) g(poly) where g.poly @> point(p_lng, p_lat))
         end
    from regions r;
$$;

revoke all on function public.regions_at(double precision, double precision) from public;
grant execute on function public.regions_at(double precision, double precision) to anon, authenticated;
