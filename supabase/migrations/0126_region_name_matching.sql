-- 0126: Region names are matched the way people write them.
--
-- 0125's guard (and the rider app's check) matched a region with no mapped
-- boundary by its exact name. The geocoder doesn't use the admin's names:
-- it says "Kajang Municipal Council" for Kajang and "Wilayah Persekutuan
-- Kuala Lumpur" for Kuala Lumpur. Checked against the last 97 live rides,
-- exact matching would have refused 26 Kajang pickups that GET.ride does
-- serve.
--
-- A name now matches when, lower-cased, with punctuation and the
-- geocoder's administrative wording dropped, the region's name appears as
-- whole words in the geocoder's ("kajang" in "kajang"). A name in another
-- script (the geocoder answers in the phone's language: "吉隆坡") can't be
-- compared, so that level counts as unknown and the point is served, as
-- any level that can't be told is. The app does the same (placeNameKey /
-- placeNameMatches / comparablePlaceName in lib/src/core/ride_bidding.dart).
--
-- The guard trigger itself is created here too: 0125 was applied to the
-- live database without it until names matched this way.

create or replace function public.region_name_norm(p_name text)
  returns text
  language sql
  immutable
  set search_path to ''
as $function$
  select btrim(regexp_replace(regexp_replace(regexp_replace(lower(coalesce(p_name, '')),
    '[^[:alnum:][:space:]]', ' ', 'g'),
    '\m(municipal council|city council|district council|town council|municipality|majlis perbandaran|majlis bandaraya|majlis daerah|wilayah persekutuan|federal territory of|federal territory|district|daerah|city of)\M',
    ' ', 'g'),
    '\s+', ' ', 'g'))
$function$;

create or replace function public.region_name_matches(p_region text, p_place text)
  returns boolean
  language sql
  immutable
  set search_path to ''
as $function$
  select r <> '' and p <> '' and (' ' || p || ' ') like ('% ' || r || ' %')
    from (select public.region_name_norm(p_region) as r, public.region_name_norm(p_place) as p) s
$function$;

-- 0125's rule, matching names with region_name_matches.
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

-- (Unchanged from 0125; repeated so a database that got 0125 without its
-- guard ends up with it.)
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

create or replace trigger trg_ride_requests_0_coverage before insert on public.ride_requests
  for each row execute function public.ride_requests_guard_coverage();
