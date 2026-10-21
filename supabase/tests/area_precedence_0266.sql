-- ============================================================================
-- Regression test for migration 0266: places inside an airport. A mall with
-- its own boundary inside an airport's (Mitsui Outlet Park in KLIA) and a
-- station "Part of" the airport's group (KLIA T2 (ERL), part of KLIA), under
-- each setting: part_of (the default), place and airport, through area_at
-- and airport_at; who may change the setting.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/area_precedence_0266.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000266a1'),  -- admin, EDIT on Airport Areas
  ('00000000-0000-0000-0000-0000000266a2'),  -- admin, READ on Airport Areas
  ('00000000-0000-0000-0000-0000000266a3'),  -- admin, EDIT on Places
  ('00000000-0000-0000-0000-0000000266c1')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000266%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000266a1', 'admin-settings-airport-areas', 'edit'),
  ('00000000-0000-0000-0000-0000000266a2', 'admin-settings-airport-areas', 'read'),
  ('00000000-0000-0000-0000-0000000266a3', 'admin-settings-multi-gate-places', 'edit')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.box(n float8, s float8, e float8, w float8) returns jsonb language sql as $$
  select jsonb_build_object('coords', jsonb_build_array(
           jsonb_build_object('latitude', n, 'longitude', w), jsonb_build_object('latitude', n, 'longitude', e),
           jsonb_build_object('latitude', s, 'longitude', e), jsonb_build_object('latitude', s, 'longitude', w)),
         'bbox', jsonb_build_object('north', n, 'south', s, 'east', e, 'west', w));
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text),
  pg_temp.box(float8, float8, float8, float8) to authenticated;

-- An airport 46.0..46.4 / 136.0..136.4, "Part of" KLIA 266 (any case and
-- spacing); in it a mall 46.10..46.12 / 136.10..136.12 (its own place) and a
-- station 46.30..46.32 / 136.30..136.32, part of the airport's group.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000266e0', jsonb_build_object('name', 'KLIA 266', 'partOf', '  klia   266 ',
    'boundary', pg_temp.box(46.4, 46.0, 136.4, 136.0)));
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000266f1', 'place', jsonb_build_object('name', 'Mitsui 266', 'lat', '46.11', 'lon', '136.11',
     'areaOn', true, 'boundary', pg_temp.box(46.12, 46.10, 136.12, 136.10))),
  ('00000000-0000-0000-0000-0000000266f2', 'place', jsonb_build_object('name', 'KLIA 266 T2 (ERL)', 'lat', '46.31',
     'lon', '136.31', 'partOf', 'KLIA 266', 'areaOn', true, 'boundary', pg_temp.box(46.32, 46.30, 136.32, 136.30)));
insert into public.multi_gate (id, kind, values) values
  ('00000000-0000-0000-0000-0000000266b1', 'gate',
   '{"placeId":"00000000-0000-0000-0000-0000000266f1","parentKey":"multi-gate-places","name":"Entrance 1","mode":"both","lat":"46.119","lon":"136.11"}');

-- ---- 1. The setting: one row, part_of to start ---------------------------------------------------
select pg_temp.check((select count(*) = 1 and min(mode) = 'part_of' from public.area_precedence_settings),
  'one row, the default');

-- ---- 2. Where a point is, in each mode -----------------------------------------------------------
create temp table expect (mode text, lat float8, lng float8, area uuid, what text);
insert into expect values
  ('part_of', 46.11, 136.11, '00000000-0000-0000-0000-0000000266f1', 'part_of: the mall'),
  ('part_of', 46.31, 136.31, '00000000-0000-0000-0000-0000000266e0', 'part_of: the station part of KLIA is KLIA''s'),
  ('part_of', 46.2, 136.2, '00000000-0000-0000-0000-0000000266e0', 'part_of: the airport alone'),
  ('place', 46.11, 136.11, '00000000-0000-0000-0000-0000000266f1', 'place: the mall'),
  ('place', 46.31, 136.31, '00000000-0000-0000-0000-0000000266f2', 'place: the station'),
  ('place', 46.2, 136.2, '00000000-0000-0000-0000-0000000266e0', 'place: the airport alone'),
  ('airport', 46.11, 136.11, '00000000-0000-0000-0000-0000000266e0', 'airport: the mall is KLIA''s'),
  ('airport', 46.31, 136.31, '00000000-0000-0000-0000-0000000266e0', 'airport: the station is KLIA''s'),
  ('airport', 46.2, 136.2, '00000000-0000-0000-0000-0000000266e0', 'airport: the airport alone');
do $$
declare r record;
begin
  for r in select * from expect loop
    update public.area_precedence_settings set mode = r.mode where id = 1;
    perform pg_temp.check(public.area_at(r.lat, r.lng) = r.area, r.what);
    perform pg_temp.check(public.airport_at(r.lat, r.lng) = r.area, r.what || ' (airport_at)');
  end loop;
end $$;
select pg_temp.check(public.area_at(10, 10) is null, 'outside every area');

-- No row (an old database): the default.
delete from public.area_precedence_settings;
select pg_temp.check(public.area_at(46.11, 136.11) = '00000000-0000-0000-0000-0000000266f1', 'no row: part_of');
insert into public.area_precedence_settings (id) values (1);

-- A station's "Part of" cleared: its own place again.
update public.multi_gate set values = values - 'partOf' where id = '00000000-0000-0000-0000-0000000266f2';
select pg_temp.check(public.area_at(46.31, 136.31) = '00000000-0000-0000-0000-0000000266f2',
  'part_of: a place part of nothing is its own');

-- ---- 3. Who may change it ------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000266c1');
select pg_temp.check((select mode from public.area_precedence_settings) = 'part_of', 'a rider reads it');
update public.area_precedence_settings set mode = 'airport' where id = 1;
select pg_temp.as_user('00000000-0000-0000-0000-0000000266a2');
update public.area_precedence_settings set mode = 'airport' where id = 1;
select pg_temp.as_user('00000000-0000-0000-0000-0000000266a3');
update public.area_precedence_settings set mode = 'airport' where id = 1;
select pg_temp.check((select mode from public.area_precedence_settings) = 'part_of',
  'a rider, a read-only admin and the Places page can''t change it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000266a1');
update public.area_precedence_settings set mode = 'place' where id = 1;
select pg_temp.check((select mode = 'place' and updated_by = '00000000-0000-0000-0000-0000000266a1'
                        from public.area_precedence_settings), 'Airport Areas EDIT changes it, stamped');
reset role;
do $$
begin
  update public.area_precedence_settings set mode = 'sideways' where id = 1;
  raise exception 'FAILED (not refused): an unknown mode';
exception when check_violation then
  null;
end $$;
select pg_temp.check(not has_table_privilege('anon', 'public.area_precedence_settings', 'select'), 'anon can''t read it');
select pg_temp.check(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                              and schemaname = 'public' and tablename = 'area_precedence_settings'), 'live');

select 'area_precedence_0266: all passed';
rollback;
