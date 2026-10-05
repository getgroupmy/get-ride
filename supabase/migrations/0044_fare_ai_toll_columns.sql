-- ============================================================================
-- 0044_fare_ai_toll_columns.sql
-- ----------------------------------------------------------------------------
-- Persist the toll information parsed from each AI fare estimate so it can be
-- shown per row in the admin Response Log alongside distance/duration.
--
--   * toll_count  — number of toll booths/plazas the model reported.
--   * toll_total  — sum of all toll charges in local currency.
--   * tolls       — jsonb array of { name, charge } per booth.
-- ============================================================================

alter table public.fare_ai_responses
  add column if not exists toll_count integer,
  add column if not exists toll_total double precision,
  add column if not exists tolls jsonb;
