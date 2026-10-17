-- ============================================================================
-- Regression test for migration 0214: Apple's own map on iOS, nowhere else.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_apple_native.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create temp table t as select public.map_config_clean('{"profiles": {
  "rider.ios": {"tiles": {"light": "apple_native", "dark": "apple_native", "satellite": "apple_native"}},
  "partner.ios": {"tiles": {"light": "apple_native", "dark": "google_native", "satellite": "google_js"}},
  "rider.android": {"tiles": {"light": "apple_native"}},
  "rider.web": {"tiles": {"light": "apple_native"}},
  "rider.desktop": {"tiles": {"light": "apple_native"}}
}}') v;

select pg_temp.check((select v->'profiles'->'rider.ios'->'tiles' @> '{"light": "apple_native", "dark": "apple_native",
  "satellite": "apple_native"}' from t), 'iOS: Apple''s map for every style');
select pg_temp.check((select v->'profiles'->'partner.ios'->'tiles' @> '{"light": "apple_native", "dark": "google_native",
  "satellite": "google_js"}' from t), 'iOS: beside either Google map');
select pg_temp.check((select v->'profiles'->'rider.android'->'tiles'->>'light' = 'app'
                         and v->'profiles'->'rider.web'->'tiles'->>'light' = 'app'
                         and v->'profiles'->'rider.desktop'->'tiles'->>'light' = 'app' from t), 'iOS only');

rollback;
