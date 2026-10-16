-- ============================================================================
-- Regression test for migration 0204: Admin → Settings → Maps keeps Google's
-- JavaScript map (web only) and Google traffic (only on that map), the
-- google_js key slot, and lets Google search sit on either Google map.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_google_js.sql
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000204a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000204a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

-- The JavaScript map on the web, not elsewhere.
select pg_temp.check((select v->'profiles'->'rider.web'->'tiles' = '{"light": "google_js", "dark": "google_js",
                         "satellite": "google_js", "traffic": "google"}'::jsonb
                        from (select public.map_config_clean('{"profiles": {"rider.web": {"tiles": {"light": "google_js",
                          "dark": "google_js", "satellite": "google_js", "traffic": "google"}}}}') v) s),
  'web: Google''s JavaScript map for every style, with Google traffic');
select pg_temp.check((select v->'profiles'->'rider.android'->'tiles' = '{"light": "app", "dark": "app",
                         "satellite": "app", "traffic": "app"}'::jsonb
                        from (select public.map_config_clean('{"profiles": {"rider.android": {"tiles": {"light": "google_js",
                          "dark": "google_js", "satellite": "google_js", "traffic": "google"}}}}') v) s),
  'not on the phone apps: as built');
select pg_temp.check((select v->'profiles'->'partner.web'->'tiles'->>'traffic' = 'app'
                        from (select public.map_config_clean('{"profiles": {"partner.web": {"tiles": {"light": "google_js",
                          "dark": "osm", "traffic": "google"}}}}') v) s),
  'Google traffic only on Google''s JavaScript map in light and dark');
select pg_temp.check((select v->'profiles'->'partner.web'->'tiles'->>'traffic' = 'tomtom'
                        from (select public.map_config_clean('{"profiles": {"partner.web": {"tiles": {"light": "google_js",
                          "dark": "google_js", "traffic": "tomtom"}}}}') v) s),
  'other traffic still allowed on it');

-- Keys, and the rest untouched.
select pg_temp.check(public.map_config_clean('{}')->'keys'->>'google_js' = 'google/maps_js', 'browser key slot by default');
select pg_temp.check(public.map_config_clean('{"keys": {"google_js": "google/web#k2"}}')->'keys'->>'google_js'
                     = 'google/web#k2', 'a chosen key kept');
select pg_temp.check(public.map_config_clean('{"keys": {"google_js": "bad ref"}}')->'keys'->>'google_js'
                     = 'google/maps_js', 'a bad reference falls back');
select pg_temp.check(public.map_config_clean('{"googleApi": "old"}')->>'googleApi' = 'old', '0203 kept');
select pg_temp.check((select count(*) = 8 from jsonb_object_keys(public.map_config_clean('{}')->'profiles')),
  'eight profiles');

-- Google search on either Google map.
select pg_temp.check(public.map_config_google_conflicts(public.map_config_clean('{"profiles": {"rider.web": {
    "tiles": {"light": "google_js", "dark": "google_js"}, "search": ["google"]}}}')) is null,
  'Google search on Google''s JavaScript map is fine');
select pg_temp.check(public.map_config_google_conflicts(public.map_config_clean('{"profiles": {"rider.web": {
    "tiles": {"light": "google_js", "dark": "osm"}, "search": ["google"]}}}')) is null,
  'and over OpenStreetMap in dark mode too (0207 lifted the Google-map-only rule)');

-- Saved and read back by an admin.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000204a1');
select pg_temp.check(public.set_map_config('{"profiles": {"rider.web": {"tiles": {"light": "google_js",
    "dark": "google_js", "traffic": "google"}, "search": ["google"]}}}')->'profiles'->'rider.web'->'tiles'->>'traffic'
  = 'google', 'saved');
select pg_temp.check(public.map_config()->'profiles'->'rider.web'->'tiles'->>'light' = 'google_js', 'read back');
reset role;

rollback;
