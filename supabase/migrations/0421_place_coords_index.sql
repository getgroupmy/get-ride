-- ============================================================================
-- 0421: find the place at a point with an index, not a scan
--
-- place_type_at (0264) runs for the pickup and the drop of every ride
-- request. To find a nearby entrance (80 m) or place (150 m) it read every
-- row of multi_gate (2,193 live), regex-tested and parsed the text
-- coordinates in its JSON, then measured the distance -- ~7 ms a call, with
-- no index able to help.
--
--   * multi_gate gets geo_lat / geo_lng: the coordinates as numbers, STORED
--     generated columns from values->>'lat' / 'lon' (null where the text is
--     not a plain decimal -- the same test 0264 used), so they are always in
--     step with the JSON whoever writes it;
--   * a partial index on (kind, geo_lat, geo_lng) for active rows;
--   * place_type_at finds candidates through the index, then applies the
--     same distance rules and order as before.
--
-- Also ptr_point_place (0245, partner-type rules), which tests every region
-- outline at each level, now skips a region whose boundary_box (0420) does
-- not hold the point, as regions_at does.
--
-- Same answers throughout: only rows that could never match are skipped.
-- ============================================================================

-- A JSON coordinate as a number: null unless it is a plain decimal (spaces
-- round it allowed), as 0264's regex test.
create or replace function public.multi_gate_coord(p text)
returns float8
language sql
immutable
parallel safe
set search_path to ''
as $$
  select case when p ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then pg_catalog.btrim(p)::float8 end;
$$;

revoke all on function public.multi_gate_coord(text) from public;
grant execute on function public.multi_gate_coord(text) to anon, authenticated, service_role;

alter table public.multi_gate add column if not exists geo_lat float8
  generated always as (public.multi_gate_coord(values->>'lat')) stored;
alter table public.multi_gate add column if not exists geo_lng float8
  generated always as (public.multi_gate_coord(values->>'lon')) stored;

create index if not exists multi_gate_active_geo
  on public.multi_gate (kind, geo_lat, geo_lng)
  where active and geo_lat is not null and geo_lng is not null;

-- 0264's place_type_at, finding candidates by the numeric coordinates.
-- The 0.002 / 0.003 degree windows (~220 / ~330 m) are wider than the 80 /
-- 150 m limits applied after them, exactly as before.
create or replace function public.place_type_at(p_area uuid, p_door uuid, p_lat float8, p_lng float8)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kind text;
  v_place uuid;
  v_type text;
  kx float8;
begin
  if p_area is not null then
    select a.kind, a.place_id into v_kind, v_place from public.airport_areas a where a.id = p_area;
    if v_kind = 'airport' then
      return 'airport';
    end if;
  end if;
  if v_place is null and p_door is not null then
    select coalesce(g.values->>'parentKey', ''), (g.values->>'placeId')::uuid
      into v_kind, v_place
      from public.multi_gate g
     where g.id = p_door and g.kind = 'gate'
       and g.values->>'placeId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if v_kind = 'airport-areas' then
      return 'airport';
    end if;
  end if;
  if v_place is null and p_lat is not null and p_lng is not null then
    kx := 111320 * cos(radians(p_lat));
    -- A gate of an active place, within 80 m.
    select (g.values->>'placeId')::uuid into v_place
      from public.multi_gate g
      join public.multi_gate p on p.kind = 'place' and p.active
                              and p.id::text = g.values->>'placeId'
     where g.kind = 'gate' and g.active
       and g.geo_lat is not null and g.geo_lng is not null
       and g.geo_lat > p_lat - 0.002 and g.geo_lat < p_lat + 0.002
       and g.geo_lng > p_lng - 0.002 and g.geo_lng < p_lng + 0.002
       and coalesce(nullif(g.values->>'parentKey', ''), 'multi-gate-places') = 'multi-gate-places'
       and sqrt(power((g.geo_lat - p_lat) * 110540, 2) + power((g.geo_lng - p_lng) * kx, 2)) <= 80
     order by power((g.geo_lat - p_lat) * 110540, 2) + power((g.geo_lng - p_lng) * kx, 2)
     limit 1;
    if v_place is null then
      -- The place itself, within 150 m.
      select p.id into v_place
        from public.multi_gate p
       where p.kind = 'place' and p.active
         and p.geo_lat is not null and p.geo_lng is not null
         and p.geo_lat > p_lat - 0.003 and p.geo_lat < p_lat + 0.003
         and p.geo_lng > p_lng - 0.003 and p.geo_lng < p_lng + 0.003
         and lower(coalesce(p.values->>'active', 'true')) not in ('false', '0', 'no', 'off')
         and sqrt(power((p.geo_lat - p_lat) * 110540, 2) + power((p.geo_lng - p_lng) * kx, 2)) <= 150
       order by power((p.geo_lat - p_lat) * 110540, 2) + power((p.geo_lng - p_lng) * kx, 2)
       limit 1;
    end if;
  end if;
  if v_place is null then
    return null;
  end if;
  select coalesce(nullif(btrim(g.values->>'placeType'), ''), 'point_of_interest') into v_type
    from public.multi_gate g where g.id = v_place and g.kind = 'place';
  return v_type;
end;
$$;

revoke execute on function public.place_type_at(uuid, uuid, float8, float8) from public, anon, authenticated;
grant execute on function public.place_type_at(uuid, uuid, float8, float8) to service_role;

-- 0245's ptr_point_place, testing a region's outlines only when its box
-- (0420) holds the point.
create or replace function public.ptr_point_place(p_lat double precision, p_lng double precision)
returns table (country text, state text, city text, suburb text)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  pt point;
  v_country text := '';
  v_state text := '';
  v_city text := '';
  v_suburb text := '';
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return query select '', '', '', '';
    return;
  end if;
  pt := point(p_lng, p_lat);
  select c.name into v_country from public.countries c
   where coalesce(cardinality(c.boundary_polys), 0) > 0
     and (c.boundary_box is null or c.boundary_box @> pt)
     and public.region_holding_area(c.boundary_polys, pt) is not null
   order by public.region_holding_area(c.boundary_polys, pt) limit 1;
  if coalesce(v_country, '') <> '' then
    select s.name into v_state from public.states s
     where public.ptr_name(s.country) = public.ptr_name(v_country)
       and coalesce(cardinality(s.boundary_polys), 0) > 0
       and (s.boundary_box is null or s.boundary_box @> pt)
       and public.region_holding_area(s.boundary_polys, pt) is not null
     order by public.region_holding_area(s.boundary_polys, pt) limit 1;
  end if;
  if coalesce(v_state, '') <> '' then
    select c.name into v_city from public.cities c
     where public.ptr_name(c.country) = public.ptr_name(v_country)
       and public.ptr_name(c.state) = public.ptr_name(v_state)
       and coalesce(cardinality(c.boundary_polys), 0) > 0
       and (c.boundary_box is null or c.boundary_box @> pt)
       and public.region_holding_area(c.boundary_polys, pt) is not null
     order by public.region_holding_area(c.boundary_polys, pt) limit 1;
  end if;
  if coalesce(v_city, '') <> '' then
    select b.name into v_suburb from public.suburbs b
     where public.ptr_name(b.country) = public.ptr_name(v_country)
       and public.ptr_name(b.state) = public.ptr_name(v_state)
       and public.ptr_name(b.city) = public.ptr_name(v_city)
       and coalesce(cardinality(b.boundary_polys), 0) > 0
       and (b.boundary_box is null or b.boundary_box @> pt)
       and public.region_holding_area(b.boundary_polys, pt) is not null
     order by public.region_holding_area(b.boundary_polys, pt) limit 1;
  end if;
  return query select coalesce(v_country, ''), coalesce(v_state, ''), coalesce(v_city, ''), coalesce(v_suburb, '');
end;
$$;

revoke all on function public.ptr_point_place(double precision, double precision) from public, anon;
grant execute on function public.ptr_point_place(double precision, double precision) to authenticated, service_role;

notify pgrst, 'reload schema';
