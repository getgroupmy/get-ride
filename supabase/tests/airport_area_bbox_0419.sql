-- ============================================================================
-- Regression test for migration 0419: the stored lat/lng box on Airport
-- Areas. area_at and place_in_airport must give exactly the answer they gave
-- before (the 0266 / 0264 outline check over every row), the box must follow
-- an edited outline, and a row with no usable box is never skipped.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/airport_area_bbox_0419.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.ring(p jsonb) returns jsonb language sql as $$
  select jsonb_build_object('coords', (
    select jsonb_agg(jsonb_build_object('latitude', (e->>0)::float8, 'longitude', (e->>1)::float8))
      from jsonb_array_elements(p) e));
$$;

-- What area_at answered before 0419: the outline check on every active row.
create or replace function pg_temp.old_area_at(p_lat float8, p_lng float8) returns uuid language sql stable as $$
  with holding as (
    select a.id, a.kind, a.size_m2, a.position, a.created_at,
           public.area_part_of_key(case when a.kind = 'place' then g.values->>'partOf' else a.values->>'partOf' end) as part_of
      from public.airport_areas a
      left join public.multi_gate g on a.kind = 'place' and g.id = a.place_id
     where a.active and p_lat is not null and p_lng is not null
       and public.airport_in_rings(p_lat, p_lng,
             public.airport_rings(case when a.kind = 'place' then a.shape else a.values->'boundary' end))
  ),
  place as (select * from holding where kind = 'place' order by coalesce(size_m2, 'infinity'::float8), position, created_at limit 1),
  airport as (select * from holding where kind = 'airport' order by position, created_at limit 1)
  select case
           when p.id is null then a.id
           when a.id is null then p.id
           when m.mode = 'airport' then a.id
           when m.mode = 'place' then p.id
           when p.part_of <> '' and p.part_of = a.part_of then a.id
           else p.id
         end
    from (select coalesce((select mode from public.area_precedence_settings where id = 1), 'part_of') as mode) m
    left join place p on true
    left join airport a on true;
$$;
create or replace function pg_temp.old_in_airport(p_lat float8, p_lng float8) returns boolean language sql stable as $$
  select p_lat is not null and p_lng is not null and exists (
    select 1 from public.airport_areas a
     where a.kind = 'airport' and a.active
       and public.airport_in_rings(p_lat, p_lng, public.airport_rings(a.values->'boundary')));
$$;

-- Three airports far apart: a triangle, an L-shape (concave, so the box holds
-- points outside the outline) and a two-ring airport; a place with its own
-- outline inside the triangle; an airport whose boundary is only a bbox.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000419a1', jsonb_build_object('name', 'Tri 419', 'boundary',
     pg_temp.ring('[[47.0,137.0],[47.4,137.2],[47.0,137.4]]'))),
  ('00000000-0000-0000-0000-0000000419a2', jsonb_build_object('name', 'L 419', 'boundary',
     pg_temp.ring('[[48.0,138.0],[48.4,138.0],[48.4,138.1],[48.1,138.1],[48.1,138.4],[48.0,138.4]]'))),
  ('00000000-0000-0000-0000-0000000419a3', jsonb_build_object('name', 'Two 419', 'boundary', jsonb_build_object('polygons', jsonb_build_array(
     (pg_temp.ring('[[49.0,139.0],[49.1,139.0],[49.1,139.1],[49.0,139.1]]'))->'coords',
     (pg_temp.ring('[[49.3,139.3],[49.4,139.3],[49.4,139.4],[49.3,139.4]]'))->'coords')))),
  ('00000000-0000-0000-0000-0000000419a4', jsonb_build_object('name', 'Bbox 419', 'boundary',
     jsonb_build_object('bbox', jsonb_build_object('north', 50.2, 'south', 50.0, 'east', 140.2, 'west', 140.0))));
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000419f1', 'place', jsonb_build_object('name', 'Mall 419', 'lat', '47.1', 'lon', '137.2',
     'areaOn', true, 'boundary', pg_temp.ring('[[47.05,137.15],[47.15,137.15],[47.15,137.25],[47.05,137.25]]')));

-- 1. Every new row got its box from its outline.
select pg_temp.check((select min_lat = 47.0 and max_lat = 47.4 and min_lng = 137.0 and max_lng = 137.4
                        from public.airport_areas where id = '00000000-0000-0000-0000-0000000419a1'), 'triangle box');
select pg_temp.check((select min_lat = 49.0 and max_lat = 49.4 and min_lng = 139.0 and max_lng = 139.4
                        from public.airport_areas where id = '00000000-0000-0000-0000-0000000419a3'), 'two-ring box spans both rings');
select pg_temp.check((select min_lat = 50.0 and max_lng = 140.2
                        from public.airport_areas where id = '00000000-0000-0000-0000-0000000419a4'), 'bbox-only boundary box');
select pg_temp.check((select count(*) = 1 from public.airport_areas
                       where kind = 'place' and place_id = '00000000-0000-0000-0000-0000000419f1'
                         and min_lat = 47.05 and max_lng = 137.25), 'place area box from its shape');

-- 2. Same answers as before on a grid over and around every area (inside,
--    on edges, inside a box but outside a concave outline, far away).
select pg_temp.check(
  (select count(*) = 0 from (
     select lat, lng from generate_series(46.9, 50.3, 0.025) lat, generate_series(136.9, 140.3, 0.025) lng
      where public.area_at(lat, lng) is distinct from pg_temp.old_area_at(lat, lng)
         or public.place_in_airport(lat, lng) is distinct from pg_temp.old_in_airport(lat, lng)) d),
  'area_at and place_in_airport unchanged on the grid');
select pg_temp.check(public.area_at(47.1, 137.2) = (select id from public.airport_areas where place_id = '00000000-0000-0000-0000-0000000419f1'),
                     'the mall inside the triangle');
select pg_temp.check(public.area_at(48.3, 138.3) is null, 'inside the L box, outside the L');
select pg_temp.check(public.area_at(48.05, 138.3) = '00000000-0000-0000-0000-0000000419a2', 'inside the L');
select pg_temp.check(public.place_in_airport(49.35, 139.35), 'second ring of the two-ring airport');

-- 3. The box follows an edited outline.
update public.airport_areas
   set values = jsonb_set(values, '{boundary}', pg_temp.ring('[[51.0,141.0],[51.2,141.0],[51.2,141.2],[51.0,141.2]]'))
 where id = '00000000-0000-0000-0000-0000000419a1';
select pg_temp.check((select min_lat = 51.0 and max_lng = 141.2
                        from public.airport_areas where id = '00000000-0000-0000-0000-0000000419a1'), 'box moved with the outline');
select pg_temp.check(public.area_at(51.1, 141.1) = '00000000-0000-0000-0000-0000000419a1', 'found at its new place');

-- 4. No usable box (straddles the 180th meridian): never skipped.
select pg_temp.check(public.airport_rings_bbox(
  '[[{"latitude":1,"longitude":179.9},{"latitude":2,"longitude":-179.9},{"latitude":2,"longitude":179.8}]]') is null,
  'a ring across the 180th meridian has no box');
select pg_temp.check(public.airport_rings_bbox('[]') is null, 'no ring, no box');

rollback;
