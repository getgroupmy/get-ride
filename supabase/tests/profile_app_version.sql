-- ============================================================================
-- Regression test for migration 0176: an account records its own app
-- version, and only a version-shaped one.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/profile_app_version.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000176a1'),
  ('00000000-0000-0000-0000-0000000176b1')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000176%'
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000176a1');
select public.record_app_version('1.4.6', '1', 'android');
-- Not a version: ignored, the last one stays.
select public.record_app_version('<script>', 'x', 'android');
reset role;

do $$
declare
  r record;
begin
  select app_version, app_build, app_platform, app_version_at into r
    from public.profiles where id = '00000000-0000-0000-0000-0000000176a1';
  if r.app_version is distinct from '1.4.6' or r.app_build is distinct from '1' or r.app_platform is distinct from 'android'
     or r.app_version_at is null then
    raise exception 'FAILED: version not recorded as sent: %', r;
  end if;
  if (select app_version from public.profiles where id = '00000000-0000-0000-0000-0000000176b1') is not null then
    raise exception 'FAILED: another account''s row was written';
  end if;
  if has_function_privilege('anon', 'public.record_app_version(text, text, text)', 'execute') then
    raise exception 'FAILED: anon may record a version';
  end if;
end $$;

select 'profile_app_version: all passed';
rollback;
