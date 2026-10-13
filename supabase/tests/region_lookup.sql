-- ============================================================================
-- Regression test for migration 0169: regions_at answers which regions'
-- mapped boundaries hold a point, without sending the boundaries.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_lookup.sql
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

-- Two islands as `polygons` (a point in either is inside), a state by
-- `coords`, a city by `bbox` only, and one with no boundary at all.
insert into public.countries (name, values, geofence) values
  ('Testland 169', '{"wholeFare": true}', jsonb_build_object('boundary',
    '{"coords":[{"latitude":0,"longitude":0},{"latitude":0,"longitude":10},{"latitude":10,"longitude":10}],'
    '"polygons":[[{"latitude":0,"longitude":0},{"latitude":0,"longitude":10},{"latitude":10,"longitude":10},{"latitude":10,"longitude":0}],'
    '[{"latitude":20,"longitude":20},{"latitude":20,"longitude":30},{"latitude":30,"longitude":30},{"latitude":30,"longitude":20}]]}'));
insert into public.states (country, name, values, geofence) values
  ('Testland 169', 'West 169', '{"pricingOverride": true, "boundary": "stale copy"}', jsonb_build_object('boundary',
    '{"coords":[{"latitude":0,"longitude":0},{"latitude":0,"longitude":5},{"latitude":10,"longitude":5},{"latitude":10,"longitude":0}]}')),
  ('Testland 169', 'Nameless 169', '{"biddingEnabled": false}', null);
insert into public.cities (country, state, name, geofence) values
  ('Testland 169', 'West 169', 'Box 169', jsonb_build_object('boundary',
    '{"bbox":{"north":3,"south":1,"east":3,"west":1}}'));

create temp table at_point as
  select * from public.regions_at(2, 2) where country = 'Testland 169';

select pg_temp.check((select inside from at_point where region_table = 'countries'), 'country holds (2,2)');
select pg_temp.check((select inside from at_point where state = 'West 169' and city = ''), 'state (coords) holds (2,2)');
select pg_temp.check((select inside from at_point where city = 'Box 169'), 'city (bbox) holds (2,2)');
select pg_temp.check((select inside is null and not has_boundary from at_point where state = 'Nameless 169'),
  'a region without a boundary is left to its names');
select pg_temp.check((select not ("values" ? 'boundary') and "values"->>'pricingOverride' = 'true'
                        from at_point where state = 'West 169' and city = ''),
  'settings come back, the boundary does not');

select pg_temp.check((select inside from public.regions_at(25, 25) where region_table = 'countries' and country = 'Testland 169'),
  'the second island counts');
select pg_temp.check((select not inside from public.regions_at(2, 7) where state = 'West 169' and city = ''),
  'outside the state');
select pg_temp.check((select not inside from public.regions_at(15, 15) where region_table = 'countries' and country = 'Testland 169'),
  'between the islands is outside');
select pg_temp.check((select inside is null and has_boundary from public.regions_at() where region_table = 'countries' and country = 'Testland 169'),
  'no point, no answer');

-- The shapes follow the admin's edits.
update public.cities set geofence = null where name = 'Box 169';
select pg_temp.check((select not has_boundary from public.regions_at(2, 2) where city = 'Box 169'), 'cleared boundary dropped');
select pg_temp.check(has_function_privilege('anon', 'public.regions_at(double precision, double precision)', 'execute'),
  'anon cannot ask regions_at');

rollback;

select 'region_lookup: all passed';
