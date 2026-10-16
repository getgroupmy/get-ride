-- ============================================================================
-- 0212 · Admin → Country / States / Cities → Block: pickups, drop-offs or both.
--
--   values.blockAt  "pickup"  no ride starts here; rides may stop and end here
--                   "drop"    rides may start here; none stops or ends here
--                   "both"    none starts, stops or ends here (the old Block)
--   values.blocked  still true for "both" alone, so apps from before this
--                   check the old way and this guard catches the rest.
--   Neither set: open, as before; blocked true without blockAt is "both".
--
-- ride_point_gap gets p_pickup (default true, as the pickup was checked
-- before); the ride guard asks it for the pickup, and with false for each
-- stop and the destination.
-- ============================================================================

-- Whether a region's Block stops a ride at this point: its pickup
-- ([p_pickup]) or a stop or the destination.
create or replace function public.region_blocks(p_values jsonb, p_pickup boolean)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select case coalesce(p_values->>'blockAt', '')
    when 'both' then true
    when 'pickup' then p_pickup
    when 'drop' then not p_pickup
    else coalesce((p_values->>'blocked')::boolean, false)
  end;
$$;

drop function if exists public.ride_point_gap(float8, float8, text, text, text, text);

-- 0170's, with the Block read for the pickup or for a drop-off.
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
      select c.name, c.polys as boundary_polys, c.blocked
        from (
          select name, boundary_polys polys, public.region_blocks(values, p_pickup) as blocked
            from public.countries where lvl = 1
          union all
          select name, boundary_polys, public.region_blocks(values, p_pickup)
            from public.states where lvl = 2 and lower(btrim(country)) = path[1]
          union all
          select name, boundary_polys, public.region_blocks(values, p_pickup)
            from public.cities where lvl = 3 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
          union all
          select name, boundary_polys, public.region_blocks(values, p_pickup)
            from public.suburbs where lvl = 4 and lower(btrim(country)) = path[1] and lower(btrim(state)) = path[2]
                                  and lower(btrim(city)) = path[3]
        ) c
       order by public.region_holding_area(c.polys, pt) nulls last
    loop
      any_candidate := true;
      if r.boundary_polys is not null and cardinality(r.boundary_polys) > 0 then
        holds := exists (select 1 from unnest(r.boundary_polys) as g(poly) where g.poly @> pt);
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

-- 0125's guard: the pickup checked as a pickup, the stops and destination
-- as drop-offs.
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
  gap := public.ride_point_gap(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city, new.suburb, true);
  if gap is not null then
    raise exception 'SERVICE_UNAVAILABLE:pickup:%', gap using errcode = 'P0001',
      hint = 'GET.ride is not available at this pickup.';
  end if;
  if jsonb_typeof(new.stops) = 'array' then
    for s in select value from jsonb_array_elements(new.stops) loop
      if jsonb_typeof(s->'lat') = 'number' and jsonb_typeof(s->'lng') = 'number' then
        gap := public.ride_point_gap((s->>'lat')::float8, (s->>'lng')::float8, null, null, null, null, false);
        if gap is not null then
          raise exception 'SERVICE_UNAVAILABLE:stop%:%', i, gap using errcode = 'P0001',
            hint = 'GET.ride is not available at one of the stops.';
        end if;
      end if;
      i := i + 1;
    end loop;
  end if;
  gap := public.ride_point_gap(new.drop_lat, new.drop_lng, null, null, null, null, false);
  if gap is not null then
    raise exception 'SERVICE_UNAVAILABLE:drop:%', gap using errcode = 'P0001',
      hint = 'GET.ride is not available at this destination.';
  end if;
  return new;
end;
$function$;

notify pgrst, 'reload schema';
