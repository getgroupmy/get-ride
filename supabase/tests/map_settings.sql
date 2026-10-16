-- ============================================================================
-- Regression test for migration 0200: Admin → Settings → Maps. The setting
-- is cleaned (eight profiles, known providers only, key references), Google
-- search or geocoding over any map (Google tiles only until 0207), only an admin reads or writes it,
-- and the geo function's rate limit and usage counts work.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_settings.sql
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

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was allowed', p_what;
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.refused(text, text)
  to authenticated;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000200a1'),  -- admin
  ('00000000-0000-0000-0000-0000000200b1')   -- anyone else
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000200a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

-- 1. Cleaning -------------------------------------------------------------------------------
select pg_temp.check((select count(*) = 8 from jsonb_object_keys(public.map_config_clean('{}')->'profiles')),
  'eight profiles: rider and partner on android, ios, web and desktop');
-- (Later migrations add more lists, such as 0205's distance; these check 0200's own.)
select pg_temp.check((public.map_config_clean('{}')->'profiles'->'rider.android') - 'distance'
                     = '{"tiles": {"light": "app", "dark": "app", "satellite": "app", "traffic": "app"},
                         "search": ["nominatim"], "reverse": ["nominatim"], "routing": ["osrm"]}'::jsonb,
  'by default everything stays as the app was built');
select pg_temp.check((select (v->'profiles'->'partner.web') - 'distance' = '{"tiles": {"light": "mapbox", "dark": "app",
                         "satellite": "esri", "traffic": "app"}, "search": ["here", "nominatim"],
                         "reverse": ["nominatim"], "routing": ["tomtom", "osrm", "google"]}'::jsonb
                        from (select public.map_config_clean('{"profiles": {"partner.web": {
                          "tiles": {"light": "mapbox", "dark": "esri", "satellite": "esri", "traffic": "bogus"},
                          "search": ["here", "here", "nominatim", "bogus"],
                          "reverse": [],
                          "routing": ["tomtom", "osrm", "google", "mapbox"]}}}') v) s),
  'unknown providers dropped, duplicates removed, at most three, an empty list gets the free default, '
  'esri only for satellite');
select pg_temp.check((select v->'keys'->>'mapbox' = 'mapbox/tiles#k1' and v->'keys'->>'here' = 'here/api'
                         and v->'keys'->>'google_places' = 'google/places'
                        from (select public.map_config_clean('{"keys": {"mapbox": "mapbox/tiles#k1",
                          "here": "not a reference; drop table x"}}') v) s),
  'key references kept when well formed, defaults otherwise');

-- 2. Google's terms: once Google-map-only, any map since 0207 (the admin's choice) --------------
select pg_temp.check(public.map_config_google_conflicts(public.map_config_clean('{"profiles": {
    "rider.ios": {"search": ["google", "nominatim"]},
    "partner.ios": {"tiles": {"light": "google", "dark": "google"}, "reverse": ["google"]}}}'))
  is null, 'Google search over OSM tiles is allowed');

-- 3. Admin only ----------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000200b1');
select pg_temp.refused($q$select public.map_config()$q$, 'a non-admin reading the map settings');
select pg_temp.refused($q$select public.set_map_config('{}')$q$, 'a non-admin saving the map settings');
select pg_temp.refused($q$select public.map_usage(7)$q$, 'a non-admin reading usage');
select pg_temp.refused($q$select * from public.geo_cache$q$, 'reading the geo cache');
select pg_temp.refused($q$select public.geo_take('x', 1)$q$, 'taking from the rate limit');

select pg_temp.as_user('00000000-0000-0000-0000-0000000200a1');
select pg_temp.check(public.set_map_config('{"profiles": {"rider.web": {"search": ["google"]}}}')
  ->'profiles'->'rider.web'->'search' = '["google"]', 'saving Google search on OSM tiles');
select pg_temp.check((select public.set_map_config('{"profiles": {"rider.web": {"tiles": {"light": "google",
                       "dark": "google"}, "search": ["google", "nominatim"]}}}')->'profiles'->'rider.web'->'search'
                      = '["google", "nominatim"]'::jsonb),
  'saved with Google tiles');
select pg_temp.check((select public.map_config()->'profiles'->'rider.web'->'tiles'->>'light' = 'google'),
  'and read back');
reset role;

-- 4. Rate limit and usage --------------------------------------------------------------------------
select pg_temp.check(public.geo_take('ip:1.2.3.4', 2) and public.geo_take('ip:1.2.3.4', 2)
                     and not public.geo_take('ip:1.2.3.4', 2), 'the third call in a minute is over a limit of 2');
update public.geo_rate set window_start = now() - interval '2 minutes' where bucket = 'ip:1.2.3.4';
select pg_temp.check(public.geo_take('ip:1.2.3.4', 2), 'a new minute starts again');

select public.geo_count('google', 'search', true, false);
select public.geo_count('google', 'search', false, false);
select public.geo_count('google', 'search', true, true);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000200a1');
select pg_temp.check((select calls = 3 and cached = 1 and failures = 1 from public.map_usage(7)
                       where provider = 'google' and kind = 'search'), 'usage counted for the admin');
reset role;

select 'map_settings: all passed';
rollback;
