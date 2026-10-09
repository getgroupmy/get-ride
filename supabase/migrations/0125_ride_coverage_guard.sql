-- 0125: GET.ride only takes rides it serves — enforced by the database.
--
-- The rider app (lib/src/core/ride_bidding.dart, coverageGap) already
-- refuses a pickup, stop or destination outside Admin → Country / States /
-- Cities, or in a region switched to Block. This repeats the same rule on
-- every new ride_requests row, so a modified client can't book one anyway.
--
-- The rule, level by level: the point must be in one of the countries; if
-- that country lists states, in one of them; and so on through cities and
-- suburbs. A region is matched by its mapped boundary where it has one,
-- else by name. A block on any region it is in blocks it. It errs towards
-- serving: with no regions, or where a level can't be told (no boundary
-- holds the point and there is no name for that level), the point passes.
-- The pickup is judged with the place names on the row; stops and the
-- destination have none stored, so only boundaries judge them.
--
-- Boundaries are JSON of up to megabytes (OSM outlines), far too slow to
-- parse per booking, so each region row keeps them pre-built as native
-- polygons (boundary_polys, refreshed by trigger when its geofence
-- changes) and the check is Postgres' own polygon @> point.
--
-- Refused rows raise SERVICE_UNAVAILABLE:<at>:<gap>:<region>, e.g.
-- SERVICE_UNAVAILABLE:pickup:outside:Perak, which the app turns into its
-- "currently unavailable" sheet.

-- ---- Pre-built boundary polygons -------------------------------------------

-- A region's boundary (geofence.boundary: {"polygons": [[{latitude,
-- longitude}]]}, {"coords": [...]} or {"bbox": {north,south,east,west}})
-- as polygons of (longitude, latitude); null without a usable one.
create or replace function public.region_boundary_polygons(p_boundary text)
  returns polygon[]
  language plpgsql
  immutable
  set search_path to ''
as $function$
declare
  j jsonb;
  rings jsonb;
  ring jsonb;
  out polygon[] := '{}';
  pts text;
begin
  if p_boundary is null or btrim(p_boundary) = '' then
    return null;
  end if;
  begin
    j := p_boundary::jsonb;
  exception when others then
    return null;
  end;
  if jsonb_typeof(j) <> 'object' then
    return null;
  end if;
  if jsonb_typeof(j->'polygons') = 'array' and jsonb_array_length(j->'polygons') > 0 then
    rings := j->'polygons';
  elsif jsonb_typeof(j->'coords') = 'array' then
    rings := jsonb_build_array(j->'coords');
  elsif jsonb_typeof(j->'bbox') = 'object' then
    begin
      return array[polygon(format('((%s,%s),(%s,%s),(%s,%s),(%s,%s))',
        (j#>>'{bbox,west}')::float8, (j#>>'{bbox,north}')::float8,
        (j#>>'{bbox,east}')::float8, (j#>>'{bbox,north}')::float8,
        (j#>>'{bbox,east}')::float8, (j#>>'{bbox,south}')::float8,
        (j#>>'{bbox,west}')::float8, (j#>>'{bbox,south}')::float8))];
    exception when others then
      return null;
    end;
  else
    return null;
  end if;
  for ring in select value from jsonb_array_elements(rings) loop
    if jsonb_typeof(ring) <> 'array' then
      continue;
    end if;
    select string_agg(format('(%s,%s)', (p->>'longitude')::float8, (p->>'latitude')::float8), ',' order by ord)
      into pts
      from jsonb_array_elements(ring) with ordinality as e(p, ord)
     where jsonb_typeof(p->'latitude') = 'number' and jsonb_typeof(p->'longitude') = 'number';
    if pts is not null and (length(pts) - length(replace(pts, '(', ''))) >= 3 then
      out := out || polygon('(' || pts || ')');
    end if;
  end loop;
  return case when cardinality(out) = 0 then null else out end;
end;
$function$;

alter table public.countries add column if not exists boundary_polys polygon[];
alter table public.states add column if not exists boundary_polys polygon[];
alter table public.cities add column if not exists boundary_polys polygon[];
alter table public.suburbs add column if not exists boundary_polys polygon[];

create or replace function public.regions_build_boundary()
  returns trigger
  language plpgsql
  set search_path to ''
as $function$
begin
  new.boundary_polys := public.region_boundary_polygons(new.geofence->>'boundary');
  return new;
end;
$function$;

create or replace trigger trg_countries_boundary before insert or update of geofence on public.countries
  for each row execute function public.regions_build_boundary();
create or replace trigger trg_states_boundary before insert or update of geofence on public.states
  for each row execute function public.regions_build_boundary();
create or replace trigger trg_cities_boundary before insert or update of geofence on public.cities
  for each row execute function public.regions_build_boundary();
create or replace trigger trg_suburbs_boundary before insert or update of geofence on public.suburbs
  for each row execute function public.regions_build_boundary();

update public.countries set boundary_polys = public.region_boundary_polygons(geofence->>'boundary') where geofence ? 'boundary';
update public.states set boundary_polys = public.region_boundary_polygons(geofence->>'boundary') where geofence ? 'boundary';
update public.cities set boundary_polys = public.region_boundary_polygons(geofence->>'boundary') where geofence ? 'boundary';
update public.suburbs set boundary_polys = public.region_boundary_polygons(geofence->>'boundary') where geofence ? 'boundary';

-- ---- The rule ------------------------------------------------------------

-- Why GET.ride can't serve (p_lat, p_lng): null when it can, else
-- 'outside:<region it is in, or empty>' or 'blocked:<most specific blocked
-- region>'. The names are the geocoder's for that point (null when unknown).
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
  names text[] := array[lower(btrim(coalesce(p_country, ''))), lower(btrim(coalesce(p_state, ''))),
                        lower(btrim(coalesce(p_city, ''))), lower(btrim(coalesce(p_suburb, '')))];
  lvl int;
  -- The path matched so far (lower-cased names), and the region rows'.
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
      select name, boundary_polys, coalesce((values->>'blocked')::boolean, false) as blocked
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
    loop
      any_candidate := true;
      if r.boundary_polys is not null and cardinality(r.boundary_polys) > 0 then
        holds := exists (select 1 from unnest(r.boundary_polys) as g(poly) where g.poly @> pt);
      elsif names[lvl] = '' then
        holds := null;
      else
        holds := lower(btrim(r.name)) = names[lvl];
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

-- ---- The guard -------------------------------------------------------------

create or replace function public.ride_requests_guard_coverage()
  returns trigger
  language plpgsql
  security definer
  set search_path to ''
as $function$
declare
  gap text;
  s jsonb;
  i int := 0;
begin
  gap := public.ride_point_gap(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city, new.suburb);
  if gap is not null then
    raise exception 'SERVICE_UNAVAILABLE:pickup:%', gap using errcode = 'P0001',
      hint = 'GET.ride is not available at this pickup.';
  end if;
  if jsonb_typeof(new.stops) = 'array' then
    for s in select value from jsonb_array_elements(new.stops) loop
      if jsonb_typeof(s->'lat') = 'number' and jsonb_typeof(s->'lng') = 'number' then
        gap := public.ride_point_gap((s->>'lat')::float8, (s->>'lng')::float8);
        if gap is not null then
          raise exception 'SERVICE_UNAVAILABLE:stop%:%', i, gap using errcode = 'P0001',
            hint = 'GET.ride is not available at one of the stops.';
        end if;
      end if;
      i := i + 1;
    end loop;
  end if;
  gap := public.ride_point_gap(new.drop_lat, new.drop_lng);
  if gap is not null then
    raise exception 'SERVICE_UNAVAILABLE:drop:%', gap using errcode = 'P0001',
      hint = 'GET.ride is not available at this destination.';
  end if;
  return new;
end;
$function$;

-- Named to run first among the insert guards.
create or replace trigger trg_ride_requests_0_coverage before insert on public.ride_requests
  for each row execute function public.ride_requests_guard_coverage();
