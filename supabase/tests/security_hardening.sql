-- ============================================================================
-- Regression test for migration 0147: the audit's database findings stay
-- fixed.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_hardening.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000147a1'),  -- a rider
  ('00000000-0000-0000-0000-0000000147b1'),  -- somebody else
  ('00000000-0000-0000-0000-0000000147d1')   -- an admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000147%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000147d1', '*', 'edit')
on conflict do nothing;
insert into public.wallets (user_id, wallet_type, balance) values
  ('00000000-0000-0000-0000-0000000147a1', 'get_wallet', 10),
  ('00000000-0000-0000-0000-0000000147b1', 'get_wallet', 20)
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.as_anon(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text) to anon, authenticated;

-- 1. Wallets: nobody reads anyone else's -----------------------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.check((select count(*) = 0 from public.wallets), 'anon reads no wallets');
select pg_temp.check((select count(*) = 0 from public.wallet_transactions), 'anon reads no ledger');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000147a1');
select pg_temp.check((select count(*) = 1 and bool_and(user_id = '00000000-0000-0000-0000-0000000147a1')
                        from public.wallets where user_id::text like '00000000-0000-0000-0000-0000000147%'),
  'a rider reads their own wallet only');
select pg_temp.refused(
  $q$update public.wallets set balance = 1000000 where user_id = '00000000-0000-0000-0000-0000000147a1'$q$,
  'a rider writing their own balance');
select pg_temp.as_user('00000000-0000-0000-0000-0000000147d1');
select pg_temp.check((select count(*) = 2 from public.wallets where user_id::text like '00000000-0000-0000-0000-0000000147%'),
  'an admin reads every wallet');
reset role;

-- 2. No admin finder ------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000147a1');
select pg_temp.check(not public.is_admin('00000000-0000-0000-0000-0000000147d1'),
  'a rider can''t ask whether another account is an admin');
select pg_temp.check(not public.admin_can_edit('00000000-0000-0000-0000-0000000147d1', '*'),
  'nor what it may edit');
select pg_temp.as_user('00000000-0000-0000-0000-0000000147d1');
select pg_temp.check(public.is_admin('00000000-0000-0000-0000-0000000147d1'), 'an admin is told about themselves');
select pg_temp.check(public.admin_can_edit('00000000-0000-0000-0000-0000000147d1', 'admin-settings-sub-admin'),
  'an admin''s edit rights still answer');
select pg_temp.check((select count(*) >= 3 from public.profiles where id::text like '00000000-0000-0000-0000-0000000147%'),
  'the admin still reads every profile');
reset role;

-- Signed-out reads still work (the policies calling is_admin must not error).
set local role anon;
select pg_temp.as_anon();
select pg_temp.check((select count(*) = 0 from public.profiles where id::text like '00000000-0000-0000-0000-0000000147%'),
  'anon reads no profiles, without an error');
reset role;

-- 3. Grants -------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.admin_access_bootstrap()', 'execute')
                 and not has_function_privilege('anon', 'public.admin_access_bootstrap()', 'execute'),
  'no client makes itself the first admin');
select pg_temp.check(not exists (
  select 1 from information_schema.role_table_grants
   where table_schema = 'public' and privilege_type = 'TRUNCATE' and grantee in ('anon', 'authenticated')),
  'no client role can truncate');
select pg_temp.check(not has_table_privilege('authenticated', 'public.wallets', 'insert')
                 and not has_table_privilege('authenticated', 'public.wallet_transactions', 'update'),
  'clients don''t write the ledger');
select pg_temp.check(not has_table_privilege('anon', 'public.profiles', 'update')
                 and not has_table_privilege('anon', 'public.ride_requests', 'insert'),
  'anon doesn''t write accounts or rides');
select pg_temp.check(not has_function_privilege('anon', 'public.device_guard_config()', 'execute')
                 and has_function_privilege('authenticated', 'public.device_guard_config()', 'execute'),
  'the device guard config is for signed-in callers');
select pg_temp.check(has_function_privilege('anon', 'public.push_unregister_token(text)', 'execute'),
  'sign-out can still drop its push token');
select pg_temp.check(not exists (
  select 1 from pg_policies where schemaname = 'public' and tablename = 'fare_ai_responses' and cmd = 'INSERT'),
  'clients don''t write AI responses');

-- 4. Deleted rows are not broadcast whole -----------------------------------------------
select pg_temp.check(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relreplident = 'f'),
  'no table is REPLICA IDENTITY FULL');

-- 5. documents_ok is the admin's -----------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'partners' and column_name = 'documents_ok') then
    perform set_config('test.partner_docs', 'yes', true);
  end if;
end $$;
insert into public.partners (auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000000147a1', 'Rider', '+60100000147');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000147a1');
select case when current_setting('test.partner_docs', true) = 'yes' then pg_temp.refused(
  $q$update public.partners set documents_ok = true where auth_user_id = '00000000-0000-0000-0000-0000000147a1'$q$,
  'a driver marking their own documents checked') end;
reset role;

-- 6. currency_symbol ------------------------------------------------------------------------
select pg_temp.check((select proconfig is not null from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname = 'currency_symbol'),
  'currency_symbol has a fixed search_path');

select 'security_hardening: all passed';
rollback;
