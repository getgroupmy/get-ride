-- ============================================================================
-- Regression test for migration 0240: pg_net (net.*) is not callable by the
-- API roles, and the database's own push path still is.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/net_grants.sql
--
-- Needs public.net_api_roles_revoke() to have been run by the superuser,
-- which a migration (run as postgres) cannot do: backend.yml runs it as
-- supabase_admin before the tests, as Supabase support does on the hosted
-- project. Runs in one transaction and is rolled back.
-- ============================================================================
begin;

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
  exception when insufficient_privilege then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.refused(text, text) to anon, authenticated;

-- 1. No net.* function, table or the schema itself for anon or authenticated ---------------------
do $$
declare
  r record;
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated', 'public'] loop
    if v_role <> 'public' then
      perform pg_temp.check(not has_schema_privilege(v_role, 'net', 'usage'), v_role || ' has no USAGE on schema net');
    end if;
    for r in select p.oid::regprocedure as fn from pg_proc p where p.pronamespace = 'net'::regnamespace loop
      if v_role = 'public' then
        perform pg_temp.check(not exists (
          select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
           where p.oid = r.fn and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
          'PUBLIC has no EXECUTE on ' || r.fn);
      else
        perform pg_temp.check(not has_function_privilege(v_role, r.fn, 'execute'), v_role || ' cannot execute ' || r.fn);
      end if;
    end loop;
    if v_role <> 'public' then
      for r in select c.oid::regclass as t from pg_class c where c.relnamespace = 'net'::regnamespace and c.relkind in ('r', 'p') loop
        perform pg_temp.check(not has_table_privilege(v_role, r.t, 'select, insert, update, delete, truncate'),
          v_role || ' has no access to ' || r.t);
      end loop;
    end if;
  end loop;
end $$;

set local role anon;
select pg_temp.refused($q$select net.http_post('https://example.com/')$q$, 'anon calling net.http_post');
select pg_temp.refused($q$select net.http_get('https://example.com/')$q$, 'anon calling net.http_get');
reset role;
set local role authenticated;
select pg_temp.refused($q$select net.http_post('https://example.com/')$q$, 'authenticated calling net.http_post');
select pg_temp.refused($q$select count(*) from net._http_response$q$, 'authenticated reading net._http_response');
reset role;

-- 2. The roles that use pg_net keep it -----------------------------------------------------------
select pg_temp.check(has_function_privilege('postgres', 'net.http_post(text, jsonb, jsonb, jsonb, integer)', 'execute'), 'postgres keeps net.http_post');
select pg_temp.check(has_function_privilege('service_role', 'net.http_post(text, jsonb, jsonb, jsonb, integer)', 'execute'), 'service_role keeps net.http_post');
select pg_temp.check(has_schema_privilege('postgres', 'net', 'usage'), 'postgres keeps USAGE on net');
select pg_temp.check(has_schema_privilege('service_role', 'net', 'usage'), 'service_role keeps USAGE on net');
select pg_temp.check(has_table_privilege('postgres', 'net._http_response', 'select'), 'postgres still reads responses');

-- 3. Every app function that calls net.* is a definer whose owner may, and no API role may call it
do $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select p.oid::regprocedure as fn, p.prosecdef, pg_get_userbyid(p.proowner) as owner
      from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.prosrc ~ '\mnet\.http_'
  loop
    n := n + 1;
    perform pg_temp.check(r.prosecdef, r.fn || ' is security definer');
    perform pg_temp.check(has_function_privilege(r.owner, 'net.http_post(text, jsonb, jsonb, jsonb, integer)', 'execute')
                          and has_schema_privilege(r.owner, 'net', 'usage'), r.fn || ': its owner can call net');
    perform pg_temp.check(not has_function_privilege('anon', r.fn, 'execute')
                          and not has_function_privilege('authenticated', r.fn, 'execute'), r.fn || ' is not for the API roles');
  end loop;
  perform pg_temp.check(n >= 1, 'send_push_webhook is found');
end $$;

-- 4. A push still goes out: a definer app path, triggered by a signed-in user, queues the request
-- 0128 makes push_webhook_secret; the project's URL is set by hand, so
-- the test sets its own (rolled back with the rest).
delete from vault.secrets where name = 'project_url';
select vault.create_secret('https://example.invalid', 'project_url');
create function pg_temp.app_trigger_path() returns void language sql security definer
  set search_path = public as $$ select public.send_push_webhook('{"test": "0240"}'::jsonb) $$;
grant execute on function pg_temp.app_trigger_path() to authenticated;
create temp table before_queue as select coalesce(max(id), 0) as id from net.http_request_queue;

set local role authenticated;
select pg_temp.app_trigger_path();
reset role;

select pg_temp.check((select count(*) = 1 from net.http_request_queue q
                       where q.id > (select id from before_queue)
                         and q.url = 'https://example.invalid/functions/v1/send-push'
                         and q.headers->>'x-push-secret' =
                             (select decrypted_secret from vault.decrypted_secrets where name = 'push_webhook_secret')),
                     'send_push_webhook queued its request');

rollback;

select 'net_grants: all passed';
