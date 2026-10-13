-- ============================================================================
-- 0170: where two regions both hold a point, the smaller one decides
--
-- Region outlines are saved without their holes (Admin -> Country / States /
-- Cities keeps each OSM polygon's outer ring), so a state's outline still
-- covers the enclave inside it: a pickup in central Kuala Lumpur is "in"
-- both Kuala Lumpur and Selangor. Both are states, so neither was more
-- specific, and which one decided bidding, tax, services, rules or Block
-- came down to row order.
--
-- Now the smaller holding outline wins a tie, as an enclave should:
-- regions_at reports the area of the smallest outline of each region that
-- holds the point (the app breaks ties on it), and the coverage guard
-- (ride_point_gap) tries the smallest holding region first. Areas are in
-- square degrees -- only ever compared with each other.
-- ============================================================================

-- The area of the smallest of [p_polys] holding [p_pt]; null when none does.
create or replace function public.region_holding_area(p_polys polygon[], p_pt point)
returns double precision
language sql
immutable
set search_path to ''
as $$
  select min(pg_catalog.area(pg_catalog.path(g.poly)))
    from unnest(p_polys) g(poly)
   where g.poly operator(pg_catalog.@>) p_pt;
$$;

revoke all on function public.region_holding_area(polygon[], point) from public;
grant execute on function public.region_holding_area(polygon[], point) to anon, authenticated, service_role;

-- regions_at gains `area`, so it is dropped and made again.
drop function if exists public.regions_at(double precision, double precision);

-- Every region with its settings (without any boundary); whether its mapped
-- boundary holds (p_lat, p_lng) -- null when it has none, or no point was
-- given; and, when it does, the area of the smallest outline holding it.
create function public.regions_at(
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
  inside boolean,
  area double precision
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
  ),
  judged as (
    select r.*,
           case
             when coalesce(cardinality(r.polys), 0) = 0 or p_lat is null or p_lng is null then null
             else public.region_holding_area(r.polys, point(p_lng, p_lat))
           end held
      from regions r
  )
  select j.t, j.country, j.state, j.city, j.suburb,
         coalesce(j.v, '{}'::jsonb) - 'boundary',
         coalesce(cardinality(j.polys), 0) > 0,
         case
           when coalesce(cardinality(j.polys), 0) = 0 or p_lat is null or p_lng is null then null
           else j.held is not null
         end,
         j.held
    from judged j;
$$;

revoke all on function public.regions_at(double precision, double precision) from public;
grant execute on function public.regions_at(double precision, double precision) to anon, authenticated;

-- The coverage guard, as 0126 left it, but trying the smallest holding
-- region of each level first.
create or replace function public.ride_point_gap(
  p_lat float8,
  p_lng float8,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
) returns text
  language plpgsql
  stable
  set search_path to ''
as $function$
declare
  pt point := point(p_lng, p_lat);
  names text[] := array[coalesce(p_country, ''), coalesce(p_state, ''), coalesce(p_city, ''), coalesce(p_suburb, '')];
  lvl int;
  path text[] := array[]::text[];
  parent_name text := null;
  blocked_name text := null;
  found_name text;
  found_blocked boolean;
  unknown boolean;
  any_candidate boolean;
  r record;
  holds boolean;
begin
  if p_lat is null or p_lng is null then
    return null;
  end if;
  if not exists (select 1 from public.countries) then
    return null;
  end if;
  for lvl in 1..4 loop
    found_name := null;
    found_blocked := false;
    unknown := false;
    any_candidate := false;
    -- Smallest holding outline first: an enclave (Kuala Lumpur) wins over
    -- the neighbour whose saved outline still covers it (Selangor), as
    -- region outlines are kept without their holes.
    for r in
      select c.name, c.polys as boundary_polys, c.blocked
        from (
          select name, boundary_polys polys, coalesce((values->>'blocked')::boolean, false) as blocked
            from public.countries where lvl = 1
          union all
          select name, boundary_polys, coalesce((values->>'blocked')::boolean, false)
            from public.states where lvl = 2 and lower(btrim(country)) = path[1]
          union all
          select name, boundary_polys, coalesce((values->>'blocked')::boolean, false)
            from public.cities where lvl = 3 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
          union all
          select name, boundary_polys, coalesce((values->>'blocked')::boolean, false)
            from public.suburbs where lvl = 4 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
                                  and lower(btrim(city)) = path[3]
        ) c
       order by public.region_holding_area(c.polys, pt) nulls last
    loop
      any_candidate := true;
      if r.boundary_polys is not null and cardinality(r.boundary_polys) > 0 then
        holds := exists (select 1 from unnest(r.boundary_polys) as g(poly) where g.poly @> pt);
      elsif public.region_name_norm(names[lvl]) !~ '[a-z]' then
        -- No name, or one in another script ("吉隆坡" from a phone in
        -- Chinese): it can't be compared, so this level can't be told.
        holds := null;
      else
        holds := public.region_name_matches(r.name, names[lvl]);
      end if;
      if holds then
        found_name := r.name;
        found_blocked := r.blocked;
        exit;
      elsif holds is null then
        unknown := true;
      end if;
    end loop;
    exit when not any_candidate;
    if found_name is null then
      if unknown then
        exit;
      end if;
      return 'outside:' || coalesce(parent_name, '');
    end if;
    path := path || lower(btrim(found_name));
    parent_name := found_name;
    if found_blocked then
      blocked_name := found_name;
    end if;
  end loop;
  return case when blocked_name is null then null else 'blocked:' || blocked_name end;
end;
$function$;


revoke all on function public.ride_point_gap(float8, float8, text, text, text, text) from public, anon;
grant execute on function public.ride_point_gap(float8, float8, text, text, text, text) to authenticated, service_role;
