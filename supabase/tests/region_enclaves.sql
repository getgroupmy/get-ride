-- ============================================================================
-- Regression test for migration 0170: where two regions of the same level
-- both hold a point (an enclave inside a neighbour whose saved outline has no
-- hole for it), the smaller one decides -- in regions_at and in the
-- coverage guard alike.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_enclaves.sql
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

create or replace function pg_temp.square(p_s float8, p_w float8, p_n float8, p_e float8) returns jsonb
language sql as $$
  select jsonb_build_object('boundary', format(
    '{"coords":[{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s}]}',
    p_s, p_w, p_s, p_e, p_n, p_e, p_n, p_w));
$$;

-- The outer state is added first, so the old row-order pick lands on it.
insert into public.countries (name, geofence) values ('Enclavia 170', pg_temp.square(0, 0, 20, 20));
insert into public.states (country, name, values, geofence) values
  ('Enclavia 170', 'Outer 170', '{"biddingEnabled": true}', pg_temp.square(0, 0, 10, 10));
insert into public.states (country, name, values, geofence) values
  ('Enclavia 170', 'Inner 170', '{"blocked": true, "biddingEnabled": false}', pg_temp.square(4, 4, 6, 6));

create temp table at_enclave as
  select * from public.regions_at(5, 5) where country = 'Enclavia 170' and region_table = 'states';

select pg_temp.check((select count(*) from at_enclave where inside) = 2, 'both states hold the enclave point');
select pg_temp.check(
  (select area from at_enclave where state = 'Inner 170') < (select area from at_enclave where state = 'Outer 170'),
  'the enclave reports the smaller area');
select pg_temp.check((select area from at_enclave where state = 'Inner 170') = 4, 'area of a 2x2 square');
select pg_temp.check(
  (select area is null and not inside from public.regions_at(1, 1) where state = 'Inner 170'),
  'no area where the outline does not hold the point');

-- The coverage guard tries the smallest holding state first.
select pg_temp.check(public.ride_point_gap(5, 5) = 'blocked:Inner 170', 'the enclave''s Block applies inside it');
select pg_temp.check(public.ride_point_gap(1, 1) is null, 'the rest of the outer state is served');

rollback;

select 'region_enclaves: all passed';
