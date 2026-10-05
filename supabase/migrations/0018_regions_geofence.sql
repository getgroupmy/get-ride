-- ============================================================================
-- Migration 0018: add `geofence` column to regions tables
-- ----------------------------------------------------------------------------
-- The admin-settings-country-states-cities screen lets you draw / fetch a
-- polygon boundary for each region. Previously the polygon JSON, source, and
-- updated-at timestamp were stuffed into the row's generic `values` jsonb. We
-- now promote that to a dedicated `geofence` jsonb column on each level table
-- so it can be queried, indexed, and consumed by other clients without having
-- to know the legacy `boundary` key.
--
-- Shape of the new column:
--   {
--     "boundary":       "<stringified BoundaryShape>",
--     "source":         "osm" | "google" | "geonames" | "bbox" | "manual",
--     "updatedAt":      "<ISO timestamp>"
--   }
--
-- The migration also seeds the column from any existing rows that still carry
-- the boundary in `values`, then strips those legacy keys so they only live in
-- one place going forward.
--
-- Safe to re-run.
-- ============================================================================

-- 1. Add the column to all four region tables -------------------------------
alter table public.countries add column if not exists geofence jsonb;
alter table public.states    add column if not exists geofence jsonb;
alter table public.cities    add column if not exists geofence jsonb;
alter table public.suburbs   add column if not exists geofence jsonb;

create index if not exists countries_geofence_idx on public.countries using gin (geofence);
create index if not exists states_geofence_idx    on public.states    using gin (geofence);
create index if not exists cities_geofence_idx    on public.cities    using gin (geofence);
create index if not exists suburbs_geofence_idx   on public.suburbs   using gin (geofence);

-- 2. Backfill / seed from existing `values.boundary` ------------------------
do $$
declare tbl text;
begin
  foreach tbl in array array['countries','states','cities','suburbs'] loop
    execute format($f$
      update public.%1$I
      set geofence = jsonb_strip_nulls(jsonb_build_object(
            'boundary',  values->>'boundary',
            'source',    values->>'boundarySource',
            'updatedAt', values->>'boundaryUpdatedAt'
          ))
      where geofence is null
        and values ? 'boundary'
        and coalesce(nullif(trim(values->>'boundary'), ''), '') <> '';
    $f$, tbl);

    -- Strip the legacy keys from `values` now that they live in `geofence`.
    execute format($f$
      update public.%1$I
      set values = (values - 'boundary' - 'boundarySource' - 'boundaryUpdatedAt')
      where values ?| array['boundary','boundarySource','boundaryUpdatedAt'];
    $f$, tbl);
  end loop;
end $$;
