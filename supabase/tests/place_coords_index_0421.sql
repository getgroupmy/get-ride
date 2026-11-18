-- ============================================================================
-- Regression test for migration 0421: multi_gate's numeric coordinates and
-- the place lookup that uses them. place_type_at must answer exactly as
-- 0264's scan did -- around entrances and places whose coordinates are plain,
-- padded with spaces, not numbers, or missing -- and the numbers must follow
-- an edited JSON. ptr_point_place must still name the region at a point.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/place_coords_index_0421.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

-- 0264's lookup by point (no area, no door), as it was.
create or replace function pg_temp.old_place_at(p_lat float8, p_lng float8) returns text
language plpgsql stable as $$
declare
  v_place uuid;
  kx float8 := 111320 * cos(radians(p_lat));
begin
  select (g.values->>'placeId')::uuid into v_place
    from public.multi_gate g
    join public.multi_gate p on p.kind = 'place' and p.active and p.id::text = g.values->>'placeId'
   where g.kind = 'gate' and g.active
     and coalesce(nullif(g.values->>'parentKey', ''), 'multi-gate-places') = 'multi-gate-places'
     and g.values->>'lat' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' and g.values->>'lon' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
     and abs(btrim(g.values->>'lat')::float8 - p_lat) < 0.002
     and abs(btrim(g.values->>'lon')::float8 - p_lng) < 0.002
     and sqrt(power((btrim(g.values->>'lat')::float8 - p_lat) * 110540, 2)
            + power((btrim(g.values->>'lon')::float8 - p_lng) * kx, 2)) <= 80
   order by power((btrim(g.values->>'lat')::float8 - p_lat) * 110540, 2)
          + power((btrim(g.values->>'lon')::float8 - p_lng) * kx, 2)
   limit 1;
  if v_place is null then
    select p.id into v_place
      from public.multi_gate p
     where p.kind = 'place' and p.active
       and lower(coalesce(p.values->>'active', 'true')) not in ('false', '0', 'no', 'off')
       and p.values->>'lat' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' and p.values->>'lon' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
       and abs(btrim(p.values->>'lat')::float8 - p_lat) < 0.003
       and abs(btrim(p.values->>'lon')::float8 - p_lng) < 0.003
       and sqrt(power((btrim(p.values->>'lat')::float8 - p_lat) * 110540, 2)
              + power((btrim(p.values->>'lon')::float8 - p_lng) * kx, 2)) <= 150
     order by power((btrim(p.values->>'lat')::float8 - p_lat) * 110540, 2)
            + power((btrim(p.values->>'lon')::float8 - p_lng) * kx, 2)
     limit 1;
  end if;
  if v_place is null then return null; end if;
  return (select coalesce(nullif(btrim(g.values->>'placeType'), ''), 'point_of_interest')
            from public.multi_gate g where g.id = v_place and g.kind = 'place');
end $$;

-- Places and entrances round (52.00, 142.00), 0.001 degrees ~ 110 m apart.
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000421f1', 'place', '{"name":"Mall 421","lat":"52.0000","lon":"142.0000","placeType":"shopping_mall","placeTypeSet":true}'),
  ('00000000-0000-0000-0000-0000000421f2', 'place', '{"name":"Station 421","lat":" 52.0020 ","lon":" 142.0020 ","placeType":"train_station","placeTypeSet":true}'),
  ('00000000-0000-0000-0000-0000000421f3', 'place', '{"name":"Off 421","lat":"52.0040","lon":"142.0000","active":"false","placeType":"hospital","placeTypeSet":true}'),
  ('00000000-0000-0000-0000-0000000421f4', 'place', '{"name":"Bad 421","lat":"near the mall","lon":"142.001","placeType":"lodging","placeTypeSet":true}'),
  ('00000000-0000-0000-0000-0000000421f5', 'place', '{"name":"No point 421","placeType":"mosque","placeTypeSet":true}');
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000421e1', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000421f2","lat":"52.0010","lon":"142.0010"}'),
  ('00000000-0000-0000-0000-0000000421e2', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000421f1","lat":"52.0035","lon":"142.0035"}'),
  ('00000000-0000-0000-0000-0000000421e3', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000421f1","lat":"x","lon":"142.0030"}'),
  ('00000000-0000-0000-0000-0000000421e4', 'gate', '{"placeId":"00000000-0000-0000-0000-0000000421f2","parentKey":"airport-areas","lat":"52.0005","lon":"142.0005"}');

-- 1. The numbers, from the JSON.
select pg_temp.check((select geo_lat = 52.002 and geo_lng = 142.002 from public.multi_gate
                       where id = '00000000-0000-0000-0000-0000000421f2'), 'spaces round a coordinate');
select pg_temp.check((select geo_lat is null and geo_lng = 142.001 from public.multi_gate
                       where id = '00000000-0000-0000-0000-0000000421f4'), 'text that is not a number');
select pg_temp.check((select geo_lat is null and geo_lng is null from public.multi_gate
                       where id = '00000000-0000-0000-0000-0000000421f5'), 'no coordinates');

-- 2. Same answers as 0264's scan on a grid round them (~11 m steps).
select pg_temp.check(
  (select count(*) = 0
     from generate_series(51.9960::numeric, 52.0080, 0.0001) lat,
          generate_series(141.9960::numeric, 142.0080, 0.0001) lng
    where public.place_type_at(null, null, lat::float8, lng::float8)
          is distinct from pg_temp.old_place_at(lat::float8, lng::float8)),
  'place_type_at unchanged on the grid');
select pg_temp.check(public.place_type_at(null, null, 52.0010, 142.0010) = 'train_station', 'at the station''s entrance');
select pg_temp.check(public.place_type_at(null, null, 52.0000, 142.0000) = 'shopping_mall', 'at the mall');
select pg_temp.check(public.place_type_at(null, null, 52.0040, 142.0000) is null, 'a switched-off place is not found');
select pg_temp.check(public.place_type_at(null, null, 53.0, 143.0) is null, 'far away: nothing');

-- 3. The numbers follow an edited JSON.
update public.multi_gate set values = values || '{"lat":"52.0500","lon":"142.0500"}'
 where id = '00000000-0000-0000-0000-0000000421f1';
select pg_temp.check((select geo_lat = 52.05 from public.multi_gate where id = '00000000-0000-0000-0000-0000000421f1'),
                     'moved with the JSON');
select pg_temp.check(public.place_type_at(null, null, 52.0500, 142.0500) = 'shopping_mall', 'found at its new place');

-- 4. ptr_point_place still names the region (box test from 0420).
insert into public.countries (name, geofence) values ('Ptrland 421', jsonb_build_object('boundary',
  '{"coords":[{"latitude":50,"longitude":140},{"latitude":50,"longitude":145},{"latitude":55,"longitude":145},{"latitude":55,"longitude":140}]}'));
select pg_temp.check((select country = 'Ptrland 421' from public.ptr_point_place(52, 142)), 'inside the country');
select pg_temp.check((select country is distinct from 'Ptrland 421' from public.ptr_point_place(56, 142)), 'outside it');

rollback;

select 'place_coords_index_0421: all passed';
