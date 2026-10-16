-- ============================================================================
-- Regression test for migration 0211: Google's satellite with roads and
-- names (hybrid), its terrain map, and its unofficial tiles for testing.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_google_look.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

select pg_temp.check(
  (select v->>'googleSatellite' = 'satellite' and v->>'googleMap' = 'roadmap'
     from (select public.map_config_clean('{}') v) x),
  'defaults: imagery only, the roadmap');
select pg_temp.check(
  (select v->>'googleSatellite' = 'hybrid' and v->>'googleMap' = 'terrain'
     from (select public.map_config_clean('{"googleSatellite": "hybrid", "googleMap": "terrain"}') v) x),
  'hybrid and terrain kept');
select pg_temp.check(
  (select v->>'googleSatellite' = 'satellite' and v->>'googleMap' = 'roadmap'
     from (select public.map_config_clean('{"googleSatellite": "train", "googleMap": 3}') v) x),
  'anything else: the defaults');
select pg_temp.check(
  (select v->'profiles'->'rider.android'->'tiles'->>'light' = 'google_native'
          and v->>'googleSearch' = 'autocomplete'
     from (select public.map_config_clean('{"googleSearch": "autocomplete", "googleSatellite": "hybrid",
       "profiles": {"rider.android": {"tiles": {"light": "google_native"}}}}') v) x),
  '0207 to 0210 kept');

select pg_temp.check(
  (select v->'profiles'->'rider.android'->'tiles'->>'light' = 'google_xyz'
          and v->'profiles'->'rider.android'->'tiles'->>'satellite' = 'google_xyz'
          and v->'profiles'->'partner.web'->'tiles'->>'dark' = 'google_xyz'
          and v->'profiles'->'partner.web'->'tiles'->>'traffic' = 'app'
     from (select public.map_config_clean('{"profiles": {
       "rider.android": {"tiles": {"light": "google_xyz", "satellite": "google_xyz"}},
       "partner.web": {"tiles": {"dark": "google_xyz", "traffic": "google_xyz"}}}}') v) x),
  'the unofficial tiles on any device, for the map slots only');

rollback;
