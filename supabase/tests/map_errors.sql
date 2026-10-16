-- ============================================================================
-- Regression test for migration 0209: the geo function's failed calls, kept
-- with their reason, read newest first by admins only, 30 at a time.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/map_errors.sql
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

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000209a1'), ('00000000-0000-0000-0000-0000000209b2')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000209a1', 'admin-settings-maps', 'edit')
on conflict do nothing;

select public.geo_log_error('google', 'tiles', 'rider', 'web', 'light map: 403 from tile.googleapis.com (SERVICE_DISABLED)')
  from generate_series(1, 45);
select public.geo_log_error('google', 'search', 'partner', 'android', '');
select public.geo_log_error('here', 'tiles', 'rider', 'ios', 'x');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000209a1');
select pg_temp.check((select count(*) = 30 from public.map_errors('google', 'tiles')), 'the latest 30');
select pg_temp.check((select bool_and(detail like 'light map: 403%' and role = 'rider' and device = 'web')
                        from public.map_errors('google', 'tiles')), 'with the reason and the device');
select pg_temp.check((select count(*) = 15 from public.map_errors('google', 'tiles',
    (select min(id) from public.map_errors('google', 'tiles')))), 'then the 15 older');
select pg_temp.check((select count(*) = 45 from public.map_errors('google', 'tiles', null, 500)), 'at most 100 a time');
select pg_temp.check((select detail = 'Failed' from public.map_errors('google', 'search')), 'an empty reason');
select pg_temp.check((select (array_agg(id order by ord))[1] > (array_agg(id order by ord))[2]
                        from (select id, row_number() over () ord from public.map_errors('google', 'tiles')) x),
  'newest first');

select pg_temp.as_user('00000000-0000-0000-0000-0000000209b2');
do $$
begin
  perform public.map_errors('google', 'tiles');
  raise exception 'FAILED: a non-admin read the errors';
exception when insufficient_privilege then null;
end $$;
do $$
begin
  perform public.geo_log_error('google', 'tiles', null, null, 'spoof');
  raise exception 'FAILED: a user logged an error';
exception when insufficient_privilege then null;
end $$;

rollback;
