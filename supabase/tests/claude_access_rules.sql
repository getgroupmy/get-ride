-- ============================================================================
-- Regression test for migration 0228: Admin -> Security & integrations ->
-- Claude Code access. Anyone reads the list (the hook uses the publishable
-- key); only an admin with EDIT on the page, connected from an enabled office
-- IP, changes it; the last enabled office IP stays.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/claude_access_rules.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000228a1'),  -- sub-admin, EDIT on Claude Code access
  ('00000000-0000-0000-0000-0000000228a2'),  -- full admin
  ('00000000-0000-0000-0000-0000000228a3'),  -- sub-admin, READ on Claude Code access
  ('00000000-0000-0000-0000-0000000228b1')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000228%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000228a1', 'admin-settings-claude-access', 'edit'),
  ('00000000-0000-0000-0000-0000000228a2', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000228a3', 'admin-settings-claude-access', 'read')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- Where the request comes from, as PostgREST reports it.
create or replace function pg_temp.from_ip(p text) returns void language plpgsql as $$
begin
  perform set_config('request.headers', json_build_object('x-forwarded-for', p)::text, true);
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
grant execute on function pg_temp.as_user(uuid), pg_temp.as_anon(), pg_temp.from_ip(text),
  pg_temp.check(boolean, text), pg_temp.refused(text, text) to anon, authenticated;

-- 0. Seeded ------------------------------------------------------------------------------------
select pg_temp.check(
  (select count(*) from public.claude_access_rules where kind = 'ip' and enabled and value = '202.188.231.237') = 1,
  'the office IP is seeded');
select pg_temp.check(
  (select count(*) from public.claude_access_rules where kind = 'session' and enabled) >= 5,
  'the approved sessions are seeded');
select pg_temp.check(
  (select count(*) from public.admin_table_pages where target = 'claude_access_rules' and page = 'admin-settings-claude-access') = 1,
  'the table is mapped to its admin page');

-- 1. The hook reads with the publishable key; it writes nothing ----------------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.check((select count(*) from public.claude_access_rules where enabled) >= 6,
  'anon reads the enabled rules');
select pg_temp.refused(
  $q$insert into public.claude_access_rules (kind, value) values ('session', 'anon0000000000000000000a')$q$,
  'anon adding a session');
reset role;

set local role authenticated;

-- 2. Not an admin, even from the office ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000228b1');
select pg_temp.from_ip('202.188.231.237');
select pg_temp.refused(
  $q$insert into public.claude_access_rules (kind, value) values ('session', 'rider000000000000000000a')$q$,
  'a rider adding a session');

-- 3. READ on the page writes nothing -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000228a3');
select pg_temp.refused(
  $q$insert into public.claude_access_rules (kind, value) values ('session', 'reader00000000000000000a')$q$,
  'a read-only sub-admin adding a session');

-- 4. EDIT on the page, but away from the office ------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000228a1');
select pg_temp.from_ip('203.0.113.9');
select pg_temp.refused(
  $q$insert into public.claude_access_rules (kind, value) values ('session', 'remote00000000000000000a')$q$,
  'an editor away from the office adding a session');
select pg_temp.refused(
  $q$update public.claude_access_rules set enabled = false where kind = 'session' and value = '01D5UkQNkT4wNjAS45j7F4ej'$q$,
  'an editor away from the office disabling a session');
select pg_temp.refused(
  $q$delete from public.claude_access_rules where kind = 'session' and value = '01D5UkQNkT4wNjAS45j7F4ej'$q$,
  'an editor away from the office removing a session');
-- The headers say nothing about where the call came from: not the office.
select set_config('request.headers', '', true);
select pg_temp.refused(
  $q$insert into public.claude_access_rules (kind, value) values ('session', 'nohead00000000000000000a')$q$,
  'an editor with no client address adding a session');

-- 5. EDIT on the page, from the office -------------------------------------------------------------------
select pg_temp.from_ip('202.188.231.237');
insert into public.claude_access_rules (kind, value, label) values ('session', 'test000000000000000000a1', 'Test session');
select pg_temp.check(
  (select label from public.claude_access_rules where kind = 'session' and value = 'test000000000000000000a1') = 'Test session',
  'an editor at the office adds a session');
select pg_temp.check(
  (select created_by from public.claude_access_rules where value = 'test000000000000000000a1') = '00000000-0000-0000-0000-0000000228a1',
  'created_by is the caller');
update public.claude_access_rules set enabled = false where kind = 'session' and value = 'test000000000000000000a1';
select pg_temp.check(
  (select not enabled from public.claude_access_rules where kind = 'session' and value = 'test000000000000000000a1'),
  'an editor at the office disables a session');
delete from public.claude_access_rules where kind = 'session' and value = 'test000000000000000000a1';
select pg_temp.check(
  not exists (select 1 from public.claude_access_rules where value = 'test000000000000000000a1'),
  'an editor at the office removes a session');

-- 6. The last enabled office IP stays ----------------------------------------------------------------------
do $$
begin
  update public.claude_access_rules set enabled = false where kind = 'ip' and value = '202.188.231.237';
  raise exception 'FAILED: the last office IP was disabled';
exception when check_violation then null;
end $$;
do $$
begin
  delete from public.claude_access_rules where kind = 'ip' and value = '202.188.231.237';
  raise exception 'FAILED: the last office IP was removed';
exception when check_violation then null;
end $$;
select pg_temp.check(
  (select enabled from public.claude_access_rules where kind = 'ip' and value = '202.188.231.237'),
  'the office IP is still enabled');

-- 7. With a second office IP the first can go; the caller is then no longer at the office ----------
insert into public.claude_access_rules (kind, value, label) values ('ip', '203.0.113.10', 'Second office');
update public.claude_access_rules set enabled = false where kind = 'ip' and value = '202.188.231.237';
select pg_temp.check(
  (select count(*) from public.claude_access_rules where kind = 'ip' and enabled) = 1,
  'the first office IP is disabled once a second one exists');
select pg_temp.refused(
  $q$update public.claude_access_rules set enabled = true where kind = 'ip' and value = '202.188.231.237'$q$,
  'an editor at a disabled office IP re-enabling it');

-- 8. A full admin needs no page grant, only the office ---------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000228a2');
select pg_temp.refused(
  $q$update public.claude_access_rules set enabled = true where kind = 'ip' and value = '202.188.231.237'$q$,
  'a full admin at a disabled office IP re-enabling it');
select pg_temp.from_ip('203.0.113.10');
update public.claude_access_rules set enabled = true where kind = 'ip' and value = '202.188.231.237';
select pg_temp.check(
  (select count(*) from public.claude_access_rules where kind = 'ip' and enabled) = 2,
  'a full admin at the second office re-enables the first');

-- 9. A duplicate is refused by the unique key, not silently merged ----------------------------------------
do $$
begin
  insert into public.claude_access_rules (kind, value) values ('ip', '203.0.113.10');
  raise exception 'FAILED: a duplicate office IP was accepted';
exception when unique_violation then null;
end $$;

rollback;

select 'claude_access_rules: all passed';
