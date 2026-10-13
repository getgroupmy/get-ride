-- ============================================================================
-- Regression test for migration 0171: Admin -> App Settings -> Backend
-- network lives on app_branding, readable by every app (it is needed before
-- sign-in) and writable only by admins, in a fixed shape.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/backend_network.sql
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

insert into public.app_branding (id) values ('global') on conflict (id) do nothing;
update public.app_branding
   set network = '{"backends": ["https://api2.getride.my"], "doh": ["https://1.1.1.1/dns-query"]}'
 where id = 'global';

-- Every app reads it, signed in or not.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select pg_temp.check(
  (select network->'backends'->>0 from public.app_branding where id = 'global') = 'https://api2.getride.my',
  'anon can read the backend network');
-- ...and cannot change it.
update public.app_branding set network = '{"backends": ["https://evil.example"]}' where id = 'global';
reset role;
select pg_temp.check(
  (select network->'backends'->>0 from public.app_branding where id = 'global') = 'https://api2.getride.my',
  'anon changed the backend network');

-- The shape is enforced.
do $$
begin
  update public.app_branding set network = '{"backends": "https://api2.getride.my"}' where id = 'global';
  raise exception 'FAILED: a non-list backends value was accepted';
exception when check_violation then null;
end $$;

rollback;

select 'backend_network: all passed';
