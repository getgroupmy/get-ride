-- ============================================================================
-- Regression test for migration 0212: Block for pickups, drop-offs or both.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_block_at.sql
--
-- Runs in a transaction it rolls back. A failed assertion raises.
-- ============================================================================
begin;

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
  if not public.region_blocks('{"blocked": true}', true) or not public.region_blocks('{"blocked": true}', false)
     or public.region_blocks('{}', true) or public.region_blocks('{"blockAt": "none", "blocked": false}', false) then
    raise exception 'FAILED: the old Block is both, none is open';
  end if;
  if not public.region_blocks('{"blockAt": "pickup"}', true) or public.region_blocks('{"blockAt": "pickup"}', false)
     or public.region_blocks('{"blockAt": "drop"}', true) or not public.region_blocks('{"blockAt": "drop"}', false)
     or not public.region_blocks('{"blockAt": "both"}', true) or not public.region_blocks('{"blockAt": "both"}', false) then
    raise exception 'FAILED: pickup, drop and both';
  end if;

  insert into public.countries (name) values ('Malaysia');
  insert into public.states (country, name, values) values
    ('Malaysia', 'Johor', '{"blockAt": "pickup"}'),
    ('Malaysia', 'Penang', '{"blockAt": "drop"}'),
    ('Malaysia', 'Kedah', '{"blockAt": "both", "blocked": true}'),
    ('Malaysia', 'Selangor', '{}');

  g := public.ride_point_gap(1.49, 103.74, 'Malaysia', 'Johor');
  if g is distinct from 'blocked:Johor' then raise exception 'FAILED: no pickup in Johor, got %', g; end if;
  g := public.ride_point_gap(1.49, 103.74, 'Malaysia', 'Johor', null, null, false);
  if g is not null then raise exception 'FAILED: drop-offs in Johor, got %', g; end if;

  g := public.ride_point_gap(5.41, 100.33, 'Malaysia', 'Penang');
  if g is not null then raise exception 'FAILED: pickups in Penang, got %', g; end if;
  g := public.ride_point_gap(5.41, 100.33, 'Malaysia', 'Penang', null, null, false);
  if g is distinct from 'blocked:Penang' then raise exception 'FAILED: no drop-off in Penang, got %', g; end if;

  if public.ride_point_gap(6.12, 100.37, 'Malaysia', 'Kedah') is distinct from 'blocked:Kedah'
     or public.ride_point_gap(6.12, 100.37, 'Malaysia', 'Kedah', null, null, false) is distinct from 'blocked:Kedah' then
    raise exception 'FAILED: Kedah blocked both ways';
  end if;
  if public.ride_point_gap(3.07, 101.52, 'Malaysia', 'Selangor', null, null, false) is not null then
    raise exception 'FAILED: Selangor open';
  end if;
end $$;

rollback;
