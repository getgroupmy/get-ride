-- ============================================================================
-- Regression test for migration 0208: Admin → Settings → Maps keeps each
-- profile's locate list (where Google's Autocomplete suggestions are, for
-- their distance), OpenStreetMap by default.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_locate.sql
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000208a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000208a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

select pg_temp.check((select bool_and(e.value->'locate' = '["nominatim"]')
                        from jsonb_each(public.map_config_clean('{}')->'profiles') e),
  'OpenStreetMap for every profile by default');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.web": {"locate": ["google", "bogus", "google",
    "amazon", "osrm", "here", "tomtom"]}}}')->'profiles'->'rider.web'->'locate' = '["google", "amazon", "here"]',
  'unknown and repeated dropped, three at most');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.web": {"locate": []}}}')
                     ->'profiles'->'rider.web'->'locate' = '["nominatim"]', 'an empty list falls back');
select pg_temp.check(public.map_config_clean('{"profiles": {"rider.web": {"locate": "google"}}}')
                     ->'profiles'->'rider.web'->'locate' = '["nominatim"]', 'not a list: default');
select pg_temp.check(public.map_config_clean('{"googleSearch": "autocomplete", "smartAddress": "all", "profiles":
    {"rider.web": {"distance": ["straight"], "search": ["amazon"]}}}') @> '{"googleSearch": "autocomplete",
    "smartAddress": "all", "profiles": {"rider.web": {"distance": ["straight"], "search": ["amazon"]}}}',
  '0205 to 0207 kept');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000208a1');
select pg_temp.check(public.set_map_config('{"profiles": {"rider.web": {"locate": ["google", "nominatim"]}}}')
  ->'profiles'->'rider.web'->'locate' = '["google", "nominatim"]', 'saved');
select pg_temp.check(public.map_config()->'profiles'->'rider.web'->'locate' = '["google", "nominatim"]', 'read back');

rollback;
