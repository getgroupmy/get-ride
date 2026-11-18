-- ============================================================================
-- 0420: skip far-away regions before the outline test
--
-- regions_at (0170) and the coverage guard ride_point_gap (0212) run on
-- every ride request. Both tested the point against the full boundary_polys
-- of every mapped country / state / city / suburb -- on the live project
-- ~58 outlines, ~4.7 MB of polygons -- so each call read and walked every
-- outline, however far away. Timed live: regions_at ~18 ms, ride_point_gap
-- ~9 ms, per call.
--
--   * each region table gets boundary_box: the box round all its outlines,
--     a STORED generated column, so it is always exactly in step with
--     boundary_polys whoever writes it (the geofence trigger, 0410's guard,
--     a backfill);
--   * regions_at and ride_point_gap only test the outlines of a region whose
--     box holds the point. A region whose box does not hold it cannot hold
--     it, so every answer is unchanged.
-- ============================================================================

-- The box round every polygon of [p_polys]; null when there are none.
create or replace function public.region_polys_box(p_polys polygon[])
returns box
language sql
immutable
parallel safe
set search_path to ''
as $$
  select case when coalesce(cardinality(p_polys), 0) = 0 then null
         else (select pg_catalog.box(pg_catalog.point(min(((b)[1])[0]), min(((b)[1])[1])),
                                     pg_catalog.point(max(((b)[0])[0]), max(((b)[0])[1])))
                 from (select pg_catalog.box(g.poly) as b from unnest(p_polys) g(poly)) x)
         end;
$$;

revoke all on function public.region_polys_box(polygon[]) from public;
grant execute on function public.region_polys_box(polygon[]) to anon, authenticated, service_role;

alter table public.countries add column if not exists boundary_box box
  generated always as (public.region_polys_box(boundary_polys)) stored;
alter table public.states add column if not exists boundary_box box
  generated always as (public.region_polys_box(boundary_polys)) stored;
alter table public.cities add column if not exists boundary_box box
  generated always as (public.region_polys_box(boundary_polys)) stored;
alter table public.suburbs add column if not exists boundary_box box
  generated always as (public.region_polys_box(boundary_polys)) stored;

-- 0170's regions_at, testing a region's outlines only when its box holds
-- the point. Same columns, same answers.
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
           c.values v, c.boundary_polys polys, c.boundary_box bx
      from public.countries c
    union all
    select 'states', s.country, s.name, '', '', s.values, s.boundary_polys, s.boundary_box from public.states s
    union all
    select 'cities', c.country, c.state, c.name, '', c.values, c.boundary_polys, c.boundary_box from public.cities c
    union all
    select 'suburbs', b.country, b.state, b.city, b.name, b.values, b.boundary_polys, b.boundary_box from public.suburbs b
  ),
  judged as (
    select r.*,
           case
             when coalesce(cardinality(r.polys), 0) = 0 or p_lat is null or p_lng is null then null
             when r.bx is not null and not (r.bx operator(pg_catalog.@>) point(p_lng, p_lat)) then null
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

-- 0212's ride_point_gap, with the same box test ahead of every outline test.
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
      select c.name, c.polys as boundary_polys, c.blocked, c.bx
        from (
          select name, boundary_polys polys, boundary_box bx, public.region_blocks(values, p_pickup) as blocked
            from public.countries where lvl = 1
          union all
          select name, boundary_polys, boundary_box, public.region_blocks(values, p_pickup)
            from public.states where lvl = 2 and lower(btrim(country)) = path[1]
          union all
          select name, boundary_polys, boundary_box, public.region_blocks(values, p_pickup)
            from public.cities where lvl = 3 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
          union all
          select name, boundary_polys, boundary_box, public.region_blocks(values, p_pickup)
            from public.suburbs where lvl = 4 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
                                  and lower(btrim(city)) = path[3]
        ) c
       order by case when c.bx is not null and not (c.bx @> pt) then null
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

revoke all on function public.ride_point_gap(float8, float8, text, text, text, text, boolean) from public, anon;
grant execute on function public.ride_point_gap(float8, float8, text, text, text, text, boolean)
  to authenticated, service_role;

notify pgrst, 'reload schema';
