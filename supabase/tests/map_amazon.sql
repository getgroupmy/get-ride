-- ============================================================================
-- Regression test for migration 0206: Admin → Settings → Maps keeps Amazon
-- Location (GrabMaps) for place search, address lookup, routes and
-- distances, its browser-drawn map on the web, its two key slots and region.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_amazon.sql
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000206a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000206a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

-- Every list may name Amazon, by the same rules.
select pg_temp.check((select v->'profiles'->'rider.android' @> '{"search": ["amazon", "nominatim"],
                         "reverse": ["amazon"], "routing": ["amazon", "osrm"], "distance": ["amazon", "straight"]}'
                        from (select public.map_config_clean('{"profiles": {"rider.android": {
                          "search": ["amazon", "bogus", "amazon", "nominatim"], "reverse": ["amazon"],
                          "routing": ["amazon", "osrm"], "distance": ["amazon", "straight"]}}}') v) s),
  'Amazon in each list, unknown and repeated dropped');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.ios": {"search": ["here", "tomtom", "google",
    "amazon"]}}}')->'profiles'->'rider.ios'->'search' = '["here", "tomtom", "google"]', 'three at most');
select pg_temp.check((select v->'profiles'->'partner.ios' @> '{"search": ["nominatim"], "routing": ["osrm"],
                         "distance": ["osrm"]}' from (select public.map_config_clean('{}') v) s), 'defaults kept');

-- Its map on the web only, light and dark, never satellite.
select pg_temp.check((select v->'profiles'->'rider.web'->'tiles' @> '{"light": "amazon_js", "dark": "amazon_js",
                         "satellite": "app"}' from (select public.map_config_clean('{"profiles": {"rider.web": {"tiles":
                         {"light": "amazon_js", "dark": "amazon_js", "satellite": "amazon_js"}}}}') v) s),
  'web: Amazon''s map for Map and Map (dark mode)');
select pg_temp.check((select v->'profiles'->'rider.android'->'tiles'->>'light' = 'app'
                        from (select public.map_config_clean('{"profiles": {"rider.android": {"tiles":
                          {"light": "amazon_js"}}}}') v) s), 'not on the phone apps');

-- Keys and region.
select pg_temp.check(public.map_config_clean('{}')->'keys' @> '{"amazon": "amazon/location", "amazon_maps": "amazon/maps"}',
  'key slots by default');
select pg_temp.check(public.map_config_clean('{"keys": {"amazon": "aws/places#k1", "amazon_maps": "bad ref"}}')->'keys'
                     @> '{"amazon": "aws/places#k1", "amazon_maps": "amazon/maps"}', 'chosen kept, a bad one falls back');
select pg_temp.check(public.map_config_clean('{}')->>'amazonRegion' = 'ap-southeast-5', 'Malaysia by default');
select pg_temp.check(public.map_config_clean('{"amazonRegion": "ap-southeast-1"}')->>'amazonRegion' = 'ap-southeast-1',
  'Singapore');
select pg_temp.check(public.map_config_clean('{"amazonRegion": "us-east-1"}')->>'amazonRegion' = 'ap-southeast-5',
  'only GrabMaps regions');
select pg_temp.check(public.map_config_clean('{"googleApi": "old", "profiles": {"rider.web": {"tiles": {"light":
    "google_js"}, "distance": ["here"]}}}') @> '{"googleApi": "old", "profiles": {"rider.web": {"tiles": {"light":
    "google_js"}, "distance": ["here"]}}}', 'earlier settings kept');

-- Saved and read back by an admin.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000206a1');
select pg_temp.check(public.set_map_config('{"amazonRegion": "ap-southeast-1", "profiles": {"partner.web": {"tiles":
    {"light": "amazon_js", "dark": "amazon_js"}, "search": ["amazon"], "distance": ["amazon", "osrm"]}}}')
  ->'profiles'->'partner.web'->'search' = '["amazon"]', 'saved');
select pg_temp.check((select v->>'amazonRegion' = 'ap-southeast-1' and v->'profiles'->'partner.web'->'tiles'->>'dark'
                        = 'amazon_js' from (select public.map_config() v) s), 'read back');
reset role;

rollback;
