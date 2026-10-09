-- ============================================================================
-- Regression test for migration 0117: App Settings are one row every app can
-- read and only an admin can change, and a bad value is refused.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/app_settings_global.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to anon, authenticated;

-- 1. The row exists, with nothing overridden ---------------------------------
do $$
declare r public.app_branding;
begin
  select * into r from public.app_branding where id = 'global';
  if r.id is null then raise exception 'FAILED: no global app_branding row'; end if;
  if r.theme <> '{}'::jsonb or r.start_lat is not null or r.splash_bg_light is not null then
    raise exception 'FAILED: a fresh row overrides something: %', row_to_json(r);
  end if;
end $$;

-- 2. Bad values are refused, good ones kept ----------------------------------
select pg_temp.refused($q$update public.app_branding set splash_bg_dark = 'black' where id = 'global'$q$,
  'a splash colour that is not hex');
select pg_temp.refused($q$update public.app_branding set start_lat = 3.1 where id = 'global'$q$,
  'a latitude without a longitude');
select pg_temp.refused($q$update public.app_branding set start_lat = 95, start_lng = 1 where id = 'global'$q$,
  'a latitude past the pole');
select pg_temp.refused($q$update public.app_branding set theme = '[]' where id = 'global'$q$,
  'a theme that is not an object');
update public.app_branding
   set splash_bg_light = '#2DABE2', theme = '{"light": {"accent": "#000"}}', start_lat = 1.5, start_lng = 103.7
 where id = 'global';

-- 3. Anyone reads it; nobody but an admin changes it -------------------------
set local role anon;
do $$
begin
  if (select start_lng from public.app_branding where id = 'global') is distinct from 103.7 then
    raise exception 'FAILED: anon cannot read the app settings';
  end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000117a1', 'role', 'authenticated')::text, true);
update public.app_branding set start_lat = null, start_lng = null where id = 'global';
reset role;
do $$
begin
  if (select start_lat from public.app_branding where id = 'global') is distinct from 1.5 then
    raise exception 'FAILED: a non-admin changed the app settings';
  end if;
end $$;

rollback;
