-- ============================================================================
-- Region boundary guard (migration 0410)
--
-- A region's mapped boundary (geofence) is what the coverage guard tests a
-- pickup against (boundary_polys, migration 0125). Losing one silently takes a
-- whole state or city offline -- which is exactly what happened to Malacca: a
-- region save that reached the row without the boundary blanked its geofence,
-- and the state stopped covering any pickup.
--
-- This makes that impossible from any writer (either app, or direct SQL): an
-- UPDATE that would null a geofence that is set keeps the stored one (and its
-- boundary_polys) instead. The one sanctioned way to remove a boundary is the
-- region_clear_boundary() RPC, which raises a per-transaction flag the guard
-- honours. INSERTs and ordinary boundary saves (a non-null geofence) are not
-- touched.
-- ============================================================================

create or replace function public.region_geofence_guard()
  returns trigger
  language plpgsql
as $function$
begin
  -- Only the clear path (region_clear_boundary) sets this; everything else
  -- that blanks a stored boundary is treated as an accident and undone.
  if TG_OP = 'UPDATE'
     and OLD.geofence is not null
     and NEW.geofence is null
     and coalesce(current_setting('app.allow_geofence_clear', true), '') <> '1'
  then
    NEW.geofence := OLD.geofence;
    NEW.boundary_polys := OLD.boundary_polys;
  end if;
  return NEW;
end;
$function$;

-- Runs after trg_<table>_boundary (name order: 'boundary' < 'geofence_guard'),
-- so when it restores the geofence it also restores the matching boundary_polys
-- the boundary trigger just recomputed from the null.
create or replace trigger trg_countries_geofence_guard
  before update on public.countries
  for each row execute function public.region_geofence_guard();
create or replace trigger trg_states_geofence_guard
  before update on public.states
  for each row execute function public.region_geofence_guard();
create or replace trigger trg_cities_geofence_guard
  before update on public.cities
  for each row execute function public.region_geofence_guard();
create or replace trigger trg_suburbs_geofence_guard
  before update on public.suburbs
  for each row execute function public.region_geofence_guard();

-- The only sanctioned way to remove a region's boundary: an admin, one row,
-- with the flag the guard honours. boundary_polys and the geofence_source /
-- geofence_updated_at generated columns fall to null with the geofence.
create or replace function public.region_clear_boundary(p_table text, p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path to ''
as $function$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized';
  end if;
  if p_table not in ('countries', 'states', 'cities', 'suburbs') then
    raise exception 'bad_table';
  end if;
  -- Raise the flag only around the one clear, so the rest of the transaction
  -- is guarded again (PostgREST runs each request in its own transaction, but
  -- this keeps the window to a single statement regardless).
  perform set_config('app.allow_geofence_clear', '1', true);
  execute format('update public.%I set geofence = null where id = $1', p_table) using p_id;
  perform set_config('app.allow_geofence_clear', '0', true);
end;
$function$;

grant execute on function public.region_clear_boundary(text, uuid) to authenticated;
