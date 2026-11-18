-- ============================================================================
-- Regression test for migration 0420: each region's boundary_box. The box
-- must follow the outline whoever changes it, and regions_at / the coverage
-- guard must answer exactly as a full outline test would -- including at a
-- point inside a region's box but outside its (concave or split) outline.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_boundary_box_0420.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Only this test's regions, so the guard's answers depend on nothing else.
alter table public.countries disable trigger user;
alter table public.states disable trigger user;
alter table public.cities disable trigger user;
alter table public.suburbs disable trigger user;
delete from public.suburbs; delete from public.cities; delete from public.states; delete from public.countries;
alter table public.countries enable trigger user;
alter table public.states enable trigger user;
alter table public.cities enable trigger user;
alter table public.suburbs enable trigger user;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

-- A geofence whose boundary is one or more rings of [lat, lng] pairs.
create or replace function pg_temp.fence(p_rings jsonb) returns jsonb language sql as $$
  select jsonb_build_object('boundary', jsonb_build_object('polygons', (
    select jsonb_agg((select jsonb_agg(jsonb_build_object('latitude', (pt->>0)::float8, 'longitude', (pt->>1)::float8))
                        from jsonb_array_elements(r) pt))
      from jsonb_array_elements(p_rings) r))::text);
$$;

insert into public.countries (name, geofence) values
  ('Boxland 420', pg_temp.fence('[[[60,60],[60,70],[70,70],[70,60]]]'));
insert into public.states (country, name, values, geofence) values
  -- An L-shape: its box holds (68, 68), its outline does not.
  ('Boxland 420', 'L 420', '{}',
   pg_temp.fence('[[[60,60],[70,60],[70,62],[62,62],[62,70],[60,70]]]')),
  -- Two separate squares: the box spans the gap between them.
  ('Boxland 420', 'Split 420', '{"blocked": true}',
   pg_temp.fence('[[[63,63],[63,64],[64,64],[64,63]],[[67,67],[67,68],[68,68],[68,67]]]'));

-- 1. The boxes, from the outlines.
select pg_temp.check((select boundary_box ~= box(point(60, 60), point(70, 70)) from public.countries where name = 'Boxland 420'),
                     'country box');
select pg_temp.check((select boundary_box ~= box(point(63, 63), point(68, 68)) from public.states where name = 'Split 420'),
                     'a box spans every ring');
insert into public.cities (country, state, name) values ('Boxland 420', 'L 420', 'No outline 420');
select pg_temp.check((select boundary_box is null from public.cities where name = 'No outline 420'), 'no outline, no box');

-- 2. regions_at: inside / area exactly as the full outline test, on a grid
--    over the country and around it.
select pg_temp.check(
  (select count(*) = 0
     from generate_series(58.5, 71.5, 0.5) lat, generate_series(58.5, 71.5, 0.5) lng,
          lateral (select * from public.regions_at(lat, lng) where country = 'Boxland 420') r
          join lateral (
            select case when coalesce(cardinality(x.boundary_polys), 0) = 0 then null
                        else public.region_holding_area(x.boundary_polys, point(lng, lat)) end as held
              from (select boundary_polys from public.countries where r.region_table = 'countries' and name = r.country
                    union all
                    select boundary_polys from public.states where r.region_table = 'states' and country = r.country and name = r.state) x
          ) want on true
    where r.area is distinct from want.held
       or r.inside is distinct from (want.held is not null)),
  'regions_at unchanged on the grid');
select pg_temp.check((select not inside from public.regions_at(68, 68) where state = 'L 420'),
                     'inside the L box, outside the L');
select pg_temp.check((select not inside from public.regions_at(65.5, 65.5) where state = 'Split 420'),
                     'in the gap between the two squares');
select pg_temp.check((select inside from public.regions_at(67.5, 67.5) where state = 'Split 420'),
                     'in the second square');

-- 3. The coverage guard.
select pg_temp.check(public.ride_point_gap(61, 61) is null, 'in the L: served');
select pg_temp.check(public.ride_point_gap(67.5, 67.5) = 'blocked:Split 420', 'in a blocked square');
select pg_temp.check(public.ride_point_gap(65.5, 65.5) = 'outside:Boxland 420',
                     'in the box gap of Split and outside the L: no state holds it');
select pg_temp.check(public.ride_point_gap(80, 80) like 'outside:%', 'outside the country');

-- 4. The box follows a changed outline.
update public.states set geofence = pg_temp.fence('[[[65,65],[65,66],[66,66],[66,65]]]') where name = 'Split 420';
select pg_temp.check((select boundary_box ~= box(point(65, 65), point(66, 66)) from public.states where name = 'Split 420'),
                     'box moved with the outline');
select pg_temp.check(public.ride_point_gap(65.5, 65.5) = 'blocked:Split 420', 'found at its new place');
select pg_temp.check(public.ride_point_gap(67.5, 67.5) = 'outside:Boxland 420', 'gone from the old place');

rollback;

select 'region_boundary_box_0420: all passed';
