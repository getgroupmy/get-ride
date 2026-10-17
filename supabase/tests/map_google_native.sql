-- ============================================================================
-- Regression test for migration 0210: Google's own map on Android and iOS,
-- its JavaScript map on desktop, and Google's traffic with either.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_google_native.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create temp table t as select public.map_config_clean('{"profiles": {
  "rider.android": {"tiles": {"light": "google_native", "dark": "google_native", "satellite": "google_native",
                              "traffic": "google"}},
  "partner.ios": {"tiles": {"light": "google_native", "dark": "osm", "traffic": "google"}},
  "rider.desktop": {"tiles": {"light": "google_js", "dark": "google_js", "satellite": "google_js", "traffic": "google"}},
  "rider.web": {"tiles": {"light": "google_native", "dark": "google_js"}},
  "partner.desktop": {"tiles": {"light": "google_native"}},
  "partner.android": {"tiles": {"light": "google_js"}}
}}') v;

select pg_temp.check((select v->'profiles'->'rider.android'->'tiles' = '{"light": "google_native",
  "dark": "google_native", "satellite": "google_native", "traffic": "google"}' from t), 'Android: native, traffic');
select pg_temp.check((select v->'profiles'->'partner.ios'->'tiles'->>'light' = 'google_native'
                         and v->'profiles'->'partner.ios'->'tiles'->>'traffic' = 'app' from t),
  'iOS: native; Google traffic only with Google on both maps');
select pg_temp.check((select v->'profiles'->'rider.desktop'->'tiles' = '{"light": "google_js", "dark": "google_js",
  "satellite": "google_js", "traffic": "google"}' from t), 'desktop: the JavaScript map');
select pg_temp.check((select v->'profiles'->'rider.web'->'tiles'->>'light' = 'app'
                         and v->'profiles'->'rider.web'->'tiles'->>'dark' = 'google_js' from t), 'web: no native map');
select pg_temp.check((select v->'profiles'->'partner.desktop'->'tiles'->>'light' = 'app' from t),
  'desktop: no native map');
-- Phones have the JavaScript map too since 0213 (map_google_js_phones.sql).
select pg_temp.check((select v->'profiles'->'partner.android'->'tiles'->>'light' = 'google_js' from t),
  'phones: the JavaScript map too (0213)');
select pg_temp.check((select v->'profiles'->'rider.android'->'distance' = '["osrm"]'
                         and v->'profiles'->'rider.android'->'locate' = '["nominatim"]' from t), '0205 to 0208 kept');

rollback;
