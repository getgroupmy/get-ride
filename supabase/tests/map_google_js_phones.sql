-- ============================================================================
-- Regression test for migration 0213: Google's JavaScript map on Android and
-- iOS, beside Google's own map, and Google traffic with it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_google_js_phones.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create temp table t as select public.map_config_clean('{"profiles": {
  "rider.ios": {"tiles": {"light": "google_js", "dark": "google_js", "satellite": "google_js", "traffic": "google"}},
  "partner.android": {"tiles": {"light": "google_js", "dark": "osm", "traffic": "google"}},
  "rider.android": {"tiles": {"light": "google_native", "dark": "google_native", "traffic": "google"}},
  "partner.ios": {"tiles": {"light": "google_js", "dark": "google_native"}}
}}') v;

select pg_temp.check((select v->'profiles'->'rider.ios'->'tiles' = '{"light": "google_js", "dark": "google_js",
  "satellite": "google_js", "traffic": "google"}' from t), 'iOS: the JavaScript map, Google traffic');
select pg_temp.check((select v->'profiles'->'partner.android'->'tiles'->>'light' = 'google_js'
                         and v->'profiles'->'partner.android'->'tiles'->>'traffic' = 'app' from t),
  'Android: the JavaScript map; Google traffic only with it on both maps');
select pg_temp.check((select v->'profiles'->'rider.android'->'tiles'->>'traffic' = 'google' from t),
  'the native map and its traffic kept');
select pg_temp.check((select v->'profiles'->'partner.ios'->'tiles'->>'light' = 'google_js'
                         and v->'profiles'->'partner.ios'->'tiles'->>'dark' = 'google_native' from t),
  'either Google map per slot');

rollback;
