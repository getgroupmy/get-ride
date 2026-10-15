-- ============================================================================
-- Regression test for migration 0203: Admin → Settings → Maps keeps which
-- Google API answers place search and routes ("new", "old" or "new_old",
-- the default), and the rest of the setting is cleaned as before.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_google_api.sql
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000203a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000203a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

select pg_temp.check(public.map_config_clean('{}')->>'googleApi' = 'new_old', 'newer first, then older, by default');
select pg_temp.check(public.map_config_clean('{"googleApi": "old"}')->>'googleApi' = 'old', 'older only kept');
select pg_temp.check(public.map_config_clean('{"googleApi": "new"}')->>'googleApi' = 'new', 'newer only kept');
select pg_temp.check(public.map_config_clean('{"googleApi": "bogus"}')->>'googleApi' = 'new_old',
  'an unknown choice falls back to the default');
select pg_temp.check((select count(*) = 8 from jsonb_object_keys(public.map_config_clean('{"googleApi": "old"}')->'profiles')),
  'the profiles are still cleaned');
select pg_temp.check(public.map_config_clean('{}')->'keys'->>'google_places' = 'google/places', 'the keys too');

-- Saved and read back by an admin.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000203a1');
select pg_temp.check(public.set_map_config('{"googleApi": "old"}')->>'googleApi' = 'old', 'saved');
select pg_temp.check(public.map_config()->>'googleApi' = 'old', 'read back');
reset role;

rollback;
