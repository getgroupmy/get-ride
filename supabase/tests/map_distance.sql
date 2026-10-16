-- ============================================================================
-- Regression test for migration 0205: Admin → Settings → Maps keeps each
-- profile's distance providers (place search results' distance), OSRM by
-- default, and Google's only on a Google map.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_distance.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, true),
         set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
$$;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000205a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000205a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

-- Defaults, and the list cleaned like the others.
select pg_temp.check((select bool_and(e.value->'distance' = '["osrm"]')
                        from jsonb_each(public.map_config_clean('{}')->'profiles') e),
  'OpenStreetMap routing for every profile by default');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.ios": {"distance": ["tomtom", "bogus", "tomtom",
    "straight", "here", "mapbox"]}}}')->'profiles'->'rider.ios'->'distance' = '["tomtom", "straight", "here"]',
  'unknown and repeated dropped, three at most');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.ios": {"distance": []}}}')
                     ->'profiles'->'rider.ios'->'distance' = '["osrm"]', 'an empty list falls back');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.ios": {"distance": "osrm"}}}')
                     ->'profiles'->'rider.ios'->'distance' = '["osrm"]', 'not a list: default');
select pg_temp.check(public.map_config_clean('{"profiles": {"partner.web": {"tiles": {"light": "google_js"}}},
    "googleApi": "old"}') @> '{"googleApi": "old", "profiles": {"partner.web": {"tiles": {"light": "google_js"}}},
    "keys": {"google_js": "google/maps_js"}}', '0203 and 0204 kept');
select pg_temp.check((select count(*) = 8 from jsonb_object_keys(public.map_config_clean('{}')->'profiles')),
  'eight profiles');

-- Google's distances on any map (0207 lifted the Google-map-only rule).
select pg_temp.check(public.map_config_google_conflicts(public.map_config_clean('{"profiles": {"rider.android": {
    "distance": ["google", "osrm"]}}}')) is null, 'over OpenStreetMap too');

-- Counted under its own kind.
select public.geo_count('osrm', 'distance', true, false);
select pg_temp.check((select calls = 1 from public.geo_usage_daily where provider = 'osrm' and kind = 'distance'),
  'usage counted');

-- Saved and read back by an admin, Google's over OpenStreetMap too.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000205a1');
select pg_temp.check(public.set_map_config('{"profiles": {"rider.web": {"distance": ["mapbox", "straight"]}}}')
  ->'profiles'->'rider.web'->'distance' = '["mapbox", "straight"]', 'saved');
select pg_temp.check(public.map_config()->'profiles'->'rider.web'->'distance' = '["mapbox", "straight"]', 'read back');
select pg_temp.check(public.set_map_config('{"profiles": {"rider.web": {"distance": ["google"]}}}')
  ->'profiles'->'rider.web'->'distance' = '["google"]', 'Google distances over OpenStreetMap saved');
reset role;

rollback;
