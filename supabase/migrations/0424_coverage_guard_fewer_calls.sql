-- ============================================================================
-- 0424: the coverage guard stops calling the outline test where it can't help
--
-- ride_point_gap (0420) runs twice per ride request (pickup and drop). At each
-- level it sorts every candidate region by region_holding_area -- including
-- the ~250 countries and other regions with no outline at all, where the
-- answer is always "no area" -- and works out every candidate's Block rule
-- (region_blocks) though only the region it settles on needs it. Profiled on
-- the live project: ~560 region_holding_area and ~556 region_blocks calls per
-- booking. Timed without the profiler (whose own per-call cost inflated this
-- at first): 11.7 -> 8.8 ms a call, ~6 ms a booking. Small, but free.
--
-- Now a region with no outline sorts as "no area" without the call (exactly
-- what the call returned), and Block is read only for the region found. Same
-- order, same answers.
-- ============================================================================

create or replace function public.ride_point_gap(
  p_lat float8,
  p_lng float8,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null,
  p_pickup boolean default true
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
    for r in
      select c.name, c.polys as boundary_polys, c.v, c.bx
        from (
          select name, boundary_polys polys, boundary_box bx, values v
            from public.countries where lvl = 1
          union all
          select name, boundary_polys, boundary_box, values
            from public.states where lvl = 2 and lower(btrim(country)) = path[1]
          union all
          select name, boundary_polys, boundary_box, values
            from public.cities where lvl = 3 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
          union all
          select name, boundary_polys, boundary_box, values
            from public.suburbs where lvl = 4 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
                                  and lower(btrim(city)) = path[3]
        ) c
       -- No outline, or a box that doesn't hold the point: no area, without a call.
       order by case when coalesce(cardinality(c.polys), 0) = 0 then null
                     when c.bx is not null and not (c.bx @> pt) then null
                     else public.region_holding_area(c.polys, pt) end nulls last
    loop
      any_candidate := true;
      if r.boundary_polys is not null and cardinality(r.boundary_polys) > 0 then
        holds := (r.bx is null or r.bx @> pt)
                 and exists (select 1 from unnest(r.boundary_polys) as g(poly) where g.poly @> pt);
      elsif public.region_name_norm(names[lvl]) !~ '[a-z]' then
        holds := null;
      else
        holds := public.region_name_matches(r.name, names[lvl]);
      end if;
      if holds then
        found_name := r.name;
        found_blocked := public.region_blocks(r.v, p_pickup);
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


revoke all on function public.ride_point_gap(float8, float8, text, text, text, text, boolean) from public, anon;
grant execute on function public.ride_point_gap(float8, float8, text, text, text, text, boolean)
  to authenticated, service_role;
