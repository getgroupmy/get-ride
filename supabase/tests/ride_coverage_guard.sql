-- ============================================================================
-- Regression test for migration 0125: the database refuses a ride whose
-- pickup, stop or destination GET.ride doesn't serve — outside every region
-- at some level, or in a blocked one — level by level, like the app.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_coverage_guard.sql
--
-- Runs in a transaction it rolls back. A failed assertion raises.
-- ============================================================================
begin;

-- Its own regions, in place of whatever the database holds.
alter table public.countries disable trigger user;
alter table public.states disable trigger user;
alter table public.cities disable trigger user;
alter table public.suburbs disable trigger user;
delete from public.suburbs; delete from public.cities; delete from public.states; delete from public.countries;
alter table public.countries enable trigger user;
alter table public.states enable trigger user;
alter table public.cities enable trigger user;
alter table public.suburbs enable trigger user;

do $$
declare
  g text;
begin
  -- With no regions at all, everything is served.
  if public.ride_point_gap(3.15, 101.71, 'Malaysia', 'Kuala Lumpur', 'Kuala Lumpur') is not null then
    raise exception 'FAILED: no regions should serve everywhere';
  end if;

  -- Malaysia with a boundary box; Selangor with one (the KL valley);
  -- Perak by name only, listing Ipoh; Thailand with nothing below it.
  insert into public.countries (name, geofence) values
    ('Malaysia', '{"boundary": "{\"bbox\":{\"north\":7.5,\"south\":0.8,\"east\":119.5,\"west\":99.5}}"}'),
    ('Thailand', null);
  insert into public.states (country, name, geofence) values
    ('Malaysia', 'Selangor', '{"boundary": "{\"coords\":[{\"latitude\":2.6,\"longitude\":101.0},{\"latitude\":2.6,\"longitude\":102.0},{\"latitude\":3.8,\"longitude\":102.0},{\"latitude\":3.8,\"longitude\":101.0}]}"}'),
    ('Malaysia', 'Perak', null);
  insert into public.cities (country, state, name) values
    ('Malaysia', 'Perak', 'Ipoh'),
    ('Malaysia', 'Selangor', 'Shah Alam');

  if (select cardinality(boundary_polys) from public.countries where name = 'Malaysia') is distinct from 1
     or (select cardinality(boundary_polys) from public.states where name = 'Selangor') is distinct from 1 then
    raise exception 'FAILED: boundaries were not built into polygons on insert';
  end if;

  -- Served: inside Selangor's shape, in a listed city.
  g := public.ride_point_gap(3.07, 101.52, 'Malaysia', 'Selangor', 'Shah Alam');
  if g is not null then raise exception 'FAILED: Shah Alam should be served, got %', g; end if;

  -- Ipoh by name, inside Malaysia's box.
  g := public.ride_point_gap(4.6, 101.08, 'Malaysia', 'Perak', 'Ipoh');
  if g is not null then raise exception 'FAILED: Ipoh should be served, got %', g; end if;

  -- Gerik: Perak doesn't list it.
  g := public.ride_point_gap(5.43, 101.13, 'Malaysia', 'Perak', 'Gerik');
  if g is distinct from 'outside:Perak' then raise exception 'FAILED: Gerik should be outside Perak, got %', g; end if;

  -- A Malaysian state not listed (Kelantan): outside, named by the country.
  g := public.ride_point_gap(6.1, 102.2, 'Malaysia', 'Kelantan', 'Kota Bharu');
  if g is distinct from 'outside:Malaysia' then raise exception 'FAILED: Kelantan should be outside, got %', g; end if;

  -- Named Selangor but outside its shape: the shape decides.
  g := public.ride_point_gap(5.0, 100.5, 'Malaysia', 'Selangor', 'Shah Alam');
  if g is distinct from 'outside:Malaysia' then raise exception 'FAILED: a boundary should beat a name, got %', g; end if;

  -- Thailand lists nothing below it: served.
  g := public.ride_point_gap(13.75, 100.5, 'Thailand', 'Bangkok');
  if g is not null then raise exception 'FAILED: Thailand should be served, got %', g; end if;

  -- An unknown country, named: outside.
  g := public.ride_point_gap(4.9, 114.9, 'Brunei');
  -- (Brunei sits inside Malaysia's test box, so use a point outside it.)
  g := public.ride_point_gap(-6.2, 106.8, 'Indonesia');
  if g is distinct from 'outside:' then raise exception 'FAILED: Indonesia should be outside, got %', g; end if;

  -- Can't tell: no names and no shape at that level → served.
  g := public.ride_point_gap(5.43, 101.13);
  if g is not null then raise exception 'FAILED: an unnamed point in a name-only state should be served, got %', g; end if;
  g := public.ride_point_gap(5.43, 101.13, 'Malaysia', 'Perak');
  if g is not null then raise exception 'FAILED: no city name should stop at the state, got %', g; end if;

  -- Blocks, at any level, named by the most specific blocked one.
  update public.cities set values = '{"blocked": true}' where name = 'Shah Alam';
  g := public.ride_point_gap(3.07, 101.52, 'Malaysia', 'Selangor', 'Shah Alam');
  if g is distinct from 'blocked:Shah Alam' then raise exception 'FAILED: blocked city, got %', g; end if;
  update public.cities set values = '{}' where name = 'Shah Alam';
  update public.countries set values = '{"blocked": true}' where name = 'Malaysia';
  g := public.ride_point_gap(4.6, 101.08, 'Malaysia', 'Perak', 'Ipoh');
  if g is distinct from 'blocked:Malaysia' then raise exception 'FAILED: blocked country, got %', g; end if;
  update public.countries set values = '{}' where name = 'Malaysia';

  -- A boundary edit rebuilds the polygons.
  update public.states set geofence = null where name = 'Selangor';
  if (select boundary_polys from public.states where name = 'Selangor') is not null then
    raise exception 'FAILED: clearing a boundary should clear its polygons';
  end if;
end
$$;

-- The polygon builder: polygons, coords, bbox, garbage.
do $$
begin
  if cardinality(public.region_boundary_polygons(
       '{"polygons":[[{"latitude":0,"longitude":0},{"latitude":0,"longitude":1},{"latitude":1,"longitude":1}],'
       || '[{"latitude":5,"longitude":5},{"latitude":5,"longitude":6},{"latitude":6,"longitude":6}]]}')) <> 2 then
    raise exception 'FAILED: two polygons';
  end if;
  if public.region_boundary_polygons('not json') is not null
     or public.region_boundary_polygons('{"coords":[{"latitude":0,"longitude":0}]}') is not null
     or public.region_boundary_polygons('') is not null then
    raise exception 'FAILED: an unusable boundary should give no polygons';
  end if;
end
$$;

-- The trigger is on ride_requests, before insert, ahead of the other guards.
do $$
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.ride_requests'::regclass and tgname = 'trg_ride_requests_0_coverage' and not tgisinternal
  ) then
    raise exception 'FAILED: trg_ride_requests_0_coverage missing';
  end if;
end
$$;

rollback;

select 'ride_coverage_guard: all passed';
