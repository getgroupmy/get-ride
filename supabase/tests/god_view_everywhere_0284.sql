-- ============================================================================
-- Regression test for migration 0284: a God View grant set to Everywhere sees
-- everyone; one with no region still sees nobody; one with a region stays
-- limited to it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_everywhere_0284.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000284a1', '60128400001'),  -- God View, Everywhere
  ('00000000-0000-0000-0000-0000000284a2', '60128400002'),  -- God View, no region
  ('00000000-0000-0000-0000-0000000284a3', '60128400003'),  -- God View, a region
  ('00000000-0000-0000-0000-0000000284a4', '60128400004')   -- another page only
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'GV284 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000284%'
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000284a1', 'admin-god-view', 'read', '{"everywhere": true}'),
  ('00000000-0000-0000-0000-0000000284a2', 'admin-god-view', 'read', null),
  ('00000000-0000-0000-0000-0000000284a3', 'admin-god-view', 'read', '{"country": "Malaysia", "state": "Selangor"}'),
  ('00000000-0000-0000-0000-0000000284a4', 'admin-users', 'read', null)
on conflict (profile_id, page) do update set region = excluded.region;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FAILED: %', p_what; end if;
end $$;

do $$
declare c record;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000284a1');
  select * into c from public.god_view_caller();
  perform pg_temp.check(c.ok and not c.scoped and c.region is null, 'Everywhere: sees everyone');

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000284a2');
  select * into c from public.god_view_caller();
  perform pg_temp.check(c.ok and c.scoped and c.region is null, 'no region: still limited (sees nobody)');

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000284a3');
  select * into c from public.god_view_caller();
  perform pg_temp.check(c.ok and c.scoped and c.region ->> 'state' = 'Selangor', 'a region: limited to it');

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000284a4');
  select * into c from public.god_view_caller();
  perform pg_temp.check(not c.ok, 'another page only: no God View');
end $$;

select 'god_view_everywhere_0284: all passed';
rollback;
