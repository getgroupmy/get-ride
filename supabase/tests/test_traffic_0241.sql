-- ============================================================================
-- Regression test for migration 0241: the admin's tester accounts, and the
-- figures that label their traffic (fare AI response log, map usage).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/test_traffic_0241.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000241a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000241a2'),  -- sub-admin, EDIT on Display Settings
  ('00000000-0000-0000-0000-0000000241a3'),  -- sub-admin, READ on Display Settings
  ('00000000-0000-0000-0000-0000000241b1'),  -- a tester
  ('00000000-0000-0000-0000-0000000241b2')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000241%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000241a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000241a2', 'admin-settings-display', 'edit'),
  ('00000000-0000-0000-0000-0000000241a3', 'admin-settings-display', 'read')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

-- 0. Grants ----------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.is_test_account(uuid)', 'execute'),
  'anon can not ask who is a tester');
select pg_temp.check(not has_function_privilege('authenticated', 'public.is_test_account(uuid)', 'execute'),
  'a signed-in user can not ask who is a tester');
select pg_temp.check(has_function_privilege('service_role', 'public.is_test_account(uuid)', 'execute'),
  'the edge functions can ask');
select pg_temp.check(
  (select p.prosecdef and p.provolatile = 's'
          and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
     from pg_proc p where p.oid = 'public.is_test_account(uuid)'::regprocedure),
  'is_test_account is stable, security definer, with a fixed search_path');
select pg_temp.check(not has_function_privilege('authenticated', 'public.geo_count(text, text, boolean, boolean, boolean)', 'execute'),
  'a signed-in user can not count map calls');
select pg_temp.check(has_function_privilege('service_role', 'public.geo_count(text, text, boolean, boolean, boolean)', 'execute'),
  'the geo function counts map calls');
select pg_temp.check(not has_table_privilege('anon', 'public.test_accounts', 'select'),
  'anon can not read the tester list');

set local role authenticated;

-- 1. Who writes the list ------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000241b2');
select pg_temp.refused($q$insert into public.test_accounts (profile_id) values ('00000000-0000-0000-0000-0000000241b2')$q$,
  'a rider listing themself as a tester');
select pg_temp.check((select count(*) = 0 from public.test_accounts), 'a rider reads no tester rows');

select pg_temp.as_user('00000000-0000-0000-0000-0000000241a3');
select pg_temp.refused($q$insert into public.test_accounts (profile_id) values ('00000000-0000-0000-0000-0000000241b1')$q$,
  'a read-only sub-admin adding a tester');

select pg_temp.as_user('00000000-0000-0000-0000-0000000241a2');
insert into public.test_accounts (profile_id, note) values ('00000000-0000-0000-0000-0000000241b1', 'Claude test session');
select pg_temp.check((select count(*) = 1 from public.test_accounts where profile_id = '00000000-0000-0000-0000-0000000241b1'),
  'a Display Settings editor adds a tester');
select pg_temp.check((select added_by = '00000000-0000-0000-0000-0000000241a2' from public.test_accounts
                       where profile_id = '00000000-0000-0000-0000-0000000241b1'),
  'the row says who added it');
select pg_temp.refused($q$update public.test_accounts set note = 'x' where true$q$, 'editing a tester row');

select pg_temp.as_user('00000000-0000-0000-0000-0000000241a3');
select pg_temp.check((select count(*) = 1 from public.test_accounts), 'a read-only sub-admin reads the list');
select pg_temp.refused($q$delete from public.test_accounts where true$q$, 'a read-only sub-admin removing a tester');

select pg_temp.as_user('00000000-0000-0000-0000-0000000241a1');
insert into public.test_accounts (profile_id) values ('00000000-0000-0000-0000-0000000241a1');
delete from public.test_accounts where profile_id = '00000000-0000-0000-0000-0000000241a1';
select pg_temp.check((select count(*) = 1 from public.test_accounts), 'a full admin adds and removes a tester');

reset role;

-- 2. The check -------------------------------------------------------------------------------------
select pg_temp.check(public.is_test_account('00000000-0000-0000-0000-0000000241b1'), 'a listed tester is a tester');
select pg_temp.check(not public.is_test_account('00000000-0000-0000-0000-0000000241b2'), 'a rider is not');
select pg_temp.check(not public.is_test_account(null), 'nobody is not');

-- 3. Fare AI log: real by default --------------------------------------------------------------------
insert into public.fare_ai_responses (provider, success, latency_ms) values ('openai', true, 900);
select pg_temp.check((select not is_test from public.fare_ai_responses order by created_at desc limit 1),
  'a log row is real unless the function says otherwise');

-- 4. Map usage ---------------------------------------------------------------------------------------
delete from public.geo_usage_daily where provider = 'test0241';
select public.geo_count('test0241', 'search', true, false);           -- real (old form)
select public.geo_count('test0241', 'search', false, false, false);   -- real, failed
select public.geo_count('test0241', 'search', true, true, true);      -- test, cached
select public.geo_count('test0241', 'search', true, false, true);     -- test
select public.geo_count('test0241', 'routing', true, false, true);    -- only test
select pg_temp.check(
  (select calls = 2 and failures = 1 and cached = 0 from public.geo_usage_daily
    where provider = 'test0241' and kind = 'search' and not is_test),
  'real calls are counted in the real row');
select pg_temp.check(
  (select calls = 2 and cached = 1 from public.geo_usage_daily
    where provider = 'test0241' and kind = 'search' and is_test),
  'test calls are counted in their own row');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000241b2');
select pg_temp.refused($q$select public.map_usage(30)$q$, 'a rider reading map usage');

select pg_temp.as_user('00000000-0000-0000-0000-0000000241a1');
select pg_temp.check(
  (select calls = 2 and cached = 0 and failures = 1 and test_calls = 2
     from public.map_usage(30) where provider = 'test0241' and kind = 'search'),
  'map usage leaves test calls out by default and says how many');
select pg_temp.check(
  not exists (select 1 from public.map_usage(30) where provider = 'test0241' and kind = 'routing'),
  'a row with only test calls is left out by default');
select pg_temp.check(
  (select calls = 4 and cached = 1 and failures = 1
     from public.map_usage(p_days => 30, p_include_test => true) where provider = 'test0241' and kind = 'search'),
  'with test traffic, every call counts');
select pg_temp.check(
  (select calls = 1 from public.map_usage(p_days => 30, p_include_test => true)
    where provider = 'test0241' and kind = 'routing'),
  'with test traffic, a test-only row shows');
reset role;

-- 5. Removing the profile removes the row --------------------------------------------------------
select pg_temp.check(
  exists (select 1 from pg_constraint
           where conrelid = 'public.test_accounts'::regclass and contype = 'f'
             and confrelid = 'public.profiles'::regclass and confdeltype = 'c'),
  'a removed profile leaves the list');

rollback;

select 'test_traffic_0241: all passed';
