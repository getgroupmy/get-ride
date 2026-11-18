-- ============================================================================
-- Regression test for migration 0425: ptr_point_place remembers a point's
-- place for the transaction. A repeat gives the same answer; a change to a
-- region's outline or name later in the same transaction is seen, not the
-- remembered answer; a point outside every region stays blank; and on a grid
-- every answer equals the one worked out afresh.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/point_place_memo_0425.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;
create or replace function pg_temp.fence(s float8, w float8, n float8, e float8) returns jsonb language sql as $$
  select jsonb_build_object('boundary', format(
    '{"coords":[{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s}]}',
    s, w, s, e, n, e, n, w));
$$;
create or replace function pg_temp.place(lat float8, lng float8) returns text language sql as $$
  select concat_ws('/', country, state, city, suburb) from public.ptr_point_place(lat, lng);
$$;

insert into public.countries (name, geofence) values ('Memoland 425', pg_temp.fence(60, 60, 70, 70));
insert into public.states (country, name, values, geofence) values
  ('Memoland 425', 'North 425', '{}', pg_temp.fence(65, 60, 70, 70)),
  ('Memoland 425', 'South 425', '{}', pg_temp.fence(60, 60, 65, 70));

-- 1. Asked twice: the same answer.
select pg_temp.check(pg_temp.place(67, 65) = 'Memoland 425/North 425//', 'first lookup');
select pg_temp.check(pg_temp.place(67, 65) = 'Memoland 425/North 425//', 'the remembered answer is the same');

-- 2. A point outside every region: blank, and still blank when asked again.
select pg_temp.check(pg_temp.place(10, 10) = '///', 'outside: blank');
select pg_temp.check(pg_temp.place(10, 10) = '///', 'outside, again: still blank');

-- 3. An outline change later in the same transaction is seen.
update public.states set geofence = pg_temp.fence(60, 60, 68, 70) where name = 'South 425';
update public.states set geofence = pg_temp.fence(68, 60, 70, 70) where name = 'North 425';
select pg_temp.check(pg_temp.place(67, 65) = 'Memoland 425/South 425//', 'a moved outline is seen, not remembered');

-- 4. A rename is seen too.
update public.states set name = 'Middle 425' where name = 'South 425';
select pg_temp.check(pg_temp.place(67, 65) = 'Memoland 425/Middle 425//', 'a renamed state is seen');

-- 5. A new region is seen.
insert into public.countries (name, geofence) values ('Late 425', pg_temp.fence(5, 5, 15, 15));
select pg_temp.check(pg_temp.place(10, 10) = 'Late 425///', 'a region added later is seen');

-- 6. On a grid, each answer -- asked twice, the second from memory -- equals
--    the answer worked out afresh under a new revision.
create temp table first_pass as
  select lat, lng, pg_temp.place(lat, lng) a, pg_temp.place(lat, lng) b
    from generate_series(59.5, 70.5, 0.5) lat, generate_series(59.5, 70.5, 0.5) lng;
select pg_temp.check((select bool_and(a = b) from first_pass), 'remembered answers equal the first');
update public.countries set values = values where name = 'Memoland 425';  -- moves the revision
select pg_temp.check((select bool_and(f.a = pg_temp.place(f.lat, f.lng)) from first_pass f),
                     'every answer equals one worked out afresh');

rollback;

select 'point_place_memo_0425: all passed';
