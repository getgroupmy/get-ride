-- ============================================================================
-- Regression test for migration 0410: a region's mapped boundary cannot be
-- silently cleared; only region_clear_boundary() removes it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_boundary_guard.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- A state with a real boundary (boundary_polys built by the 0125 trigger).
insert into public.states (id, country, name, geofence)
values (
  '00000000-0000-0000-0000-0000000000aa',
  'Testland', 'Teststate',
  jsonb_build_object(
    'boundary', '{"polygons":[[{"latitude":1,"longitude":1},{"latitude":1,"longitude":3},{"latitude":3,"longitude":3},{"latitude":3,"longitude":1},{"latitude":1,"longitude":1}]]}',
    'source', 'osm',
    'updatedAt', '2026-01-01T00:00:00.000Z'
  )
);

do $$
declare v_polys integer;
begin
  select cardinality(boundary_polys) into v_polys from public.states where id = '00000000-0000-0000-0000-0000000000aa';
  if v_polys is null or v_polys < 1 then raise exception 'FAILED: boundary_polys not built on insert (%)', v_polys; end if;
end $$;

-- 1. A direct UPDATE that nulls the geofence is undone (the silent-clear case).
update public.states set geofence = null where id = '00000000-0000-0000-0000-0000000000aa';
do $$
declare r public.states;
begin
  select * into r from public.states where id = '00000000-0000-0000-0000-0000000000aa';
  if r.geofence is null then raise exception 'FAILED: geofence was silently cleared'; end if;
  if (r.geofence->>'source') <> 'osm' then raise exception 'FAILED: geofence changed: %', r.geofence; end if;
  if cardinality(r.boundary_polys) < 1 then raise exception 'FAILED: boundary_polys lost'; end if;
end $$;

-- 2. An ordinary data edit (touching values, not the geofence) keeps it.
update public.states set values = jsonb_build_object('timezone', 'Asia/Kuala_Lumpur')
  where id = '00000000-0000-0000-0000-0000000000aa';
do $$
begin
  if (select geofence from public.states where id = '00000000-0000-0000-0000-0000000000aa') is null then
    raise exception 'FAILED: a data edit cleared the boundary';
  end if;
end $$;

-- 3. Replacing it with a new boundary still works (a non-null geofence).
update public.states set geofence = jsonb_build_object(
    'boundary', '{"polygons":[[{"latitude":5,"longitude":5},{"latitude":5,"longitude":7},{"latitude":7,"longitude":7},{"latitude":5,"longitude":5}]]}',
    'source', 'ai')
  where id = '00000000-0000-0000-0000-0000000000aa';
do $$
begin
  if (select geofence->>'source' from public.states where id = '00000000-0000-0000-0000-0000000000aa') <> 'ai' then
    raise exception 'FAILED: a new boundary was not saved';
  end if;
end $$;

-- 4. The RPC is the one sanctioned clear: it removes the boundary and polys.
select public.region_clear_boundary('states', '00000000-0000-0000-0000-0000000000aa');
do $$
declare r public.states;
begin
  select * into r from public.states where id = '00000000-0000-0000-0000-0000000000aa';
  if r.geofence is not null then raise exception 'FAILED: region_clear_boundary did not clear'; end if;
  if r.boundary_polys is not null then raise exception 'FAILED: boundary_polys left after clear'; end if;
  if r.geofence_source is not null then raise exception 'FAILED: geofence_source left after clear'; end if;
end $$;

-- 5. The flag is per-statement: a later accidental null is guarded again.
update public.states set geofence = jsonb_build_object(
    'boundary', '{"polygons":[[{"latitude":1,"longitude":1},{"latitude":1,"longitude":3},{"latitude":3,"longitude":3},{"latitude":1,"longitude":1}]]}',
    'source', 'osm') where id = '00000000-0000-0000-0000-0000000000aa';
update public.states set geofence = null where id = '00000000-0000-0000-0000-0000000000aa';
do $$
begin
  if (select geofence from public.states where id = '00000000-0000-0000-0000-0000000000aa') is null then
    raise exception 'FAILED: guard did not re-arm after a clear';
  end if;
end $$;

-- 6. A non-admin cannot clear.
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000bb","role":"authenticated"}', true);
  begin
    perform public.region_clear_boundary('states', '00000000-0000-0000-0000-0000000000aa');
    reset role;
    raise exception 'FAILED: a non-admin cleared a boundary';
  exception when insufficient_privilege or others then
    reset role;
  end;
end $$;

rollback;
