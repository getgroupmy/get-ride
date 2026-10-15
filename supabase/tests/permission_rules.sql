-- ============================================================================
-- Regression test for migration 0196: the permission rules riders and
-- partners are held to, read by everyone signed in, changed by admins only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/permission_rules.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000196a1'),  -- rider
  ('00000000-0000-0000-0000-0000000196c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000196%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000196c1', '*', 'edit')
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
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

-- 1. Everything enforced, the card shown, out of the box ------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000196a1');
select pg_temp.check((select r #>> '{user,notifications}' = 'true' and r #>> '{partner,locationAlways}' = 'true'
                             and r ->> 'showPermissionsCard' = 'true'
                        from (select public.permission_rules() r) s), 'all enforced by default');

-- 2. A rider can read them but not change them ---------------------------------------------
select pg_temp.refused($q$select public.set_permission_rules('{"user":{"notifications":false}}')$q$,
  'a rider changing the rules');

-- 3. An admin bypasses one check; the rest keep their values ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000196c1');
select pg_temp.check((select r #>> '{user,notifications}' = 'false' and r #>> '{partner,notifications}' = 'true'
                             and r #>> '{user,location}' = 'true'
                        from (select public.set_permission_rules('{"user":{"notifications":false}}') r) s),
  'only the rider notification check is bypassed');
select pg_temp.check((select r ->> 'showPermissionsCard' = 'false' and r #>> '{user,notifications}' = 'false'
                        from (select public.set_permission_rules('{"showPermissionsCard":"off"}') r) s),
  'the card hidden, the earlier change kept');
select pg_temp.refused($q$select public.set_permission_rules('[1]')$q$, 'rules that are not an object');

-- 4. What the rider now reads --------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000196a1');
select pg_temp.check((select r #>> '{user,notifications}' = 'false' and r ->> 'showPermissionsCard' = 'false'
                        from (select public.permission_rules() r) s), 'riders read the new rules');

reset role;
select 'permission_rules: all passed';
rollback;
