-- ============================================================================
-- Regression test for migration 0207: Admin → Settings → Maps keeps the
-- Google search mode (Text Search or Autocomplete), the smart address
-- option, the Address Validation key slot, and lets Google's results be
-- shown over any map.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_autocomplete.sql
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000207a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000207a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

select pg_temp.check(public.map_config_clean('{}') @> '{"googleSearch": "text", "smartAddress": "normal",
    "keys": {"google_address": "google/address_validation"}}', 'Text Search, plain results by default');
select pg_temp.check(public.map_config_clean('{"googleSearch": "autocomplete"}')->>'googleSearch' = 'autocomplete',
  'Autocomplete');
select pg_temp.check(public.map_config_clean('{"googleSearch": "bogus"}')->>'googleSearch' = 'text', 'unknown mode');
select pg_temp.check((select bool_and(public.map_config_clean(jsonb_build_object('smartAddress', o))->>'smartAddress' = o)
                        from unnest(array['normal', 'a', 'b', 'c', 'all']) o), 'each smart option kept');
select pg_temp.check(public.map_config_clean('{"smartAddress": "d"}')->>'smartAddress' = 'normal', 'unknown option');
select pg_temp.check(public.map_config_clean('{"keys": {"google_address": "google/validation#v1"}}')->'keys'
                     ->>'google_address' = 'google/validation#v1', 'a chosen key kept');
select pg_temp.check(public.map_config_clean('{"amazonRegion": "ap-southeast-1", "googleApi": "old"}')
                     @> '{"amazonRegion": "ap-southeast-1", "googleApi": "old"}', 'earlier settings kept');

-- Google over any map, saved by an admin.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000207a1');
select pg_temp.check((select v @> '{"googleSearch": "autocomplete", "smartAddress": "all", "profiles": {"rider.android":
                         {"search": ["google"], "reverse": ["google"], "distance": ["google"]}}}'
                        from (select public.set_map_config('{"googleSearch": "autocomplete", "smartAddress": "all",
                          "profiles": {"rider.android": {"tiles": {"light": "osm"}, "search": ["google"],
                          "reverse": ["google"], "distance": ["google"]}}}') v) s),
  'Google search, address lookup and distances saved over OpenStreetMap');
reset role;

rollback;
