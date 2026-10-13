-- ============================================================================
-- Regression test for migration 0165: one token per device and kind, and the
-- "every driver" ride broadcast asks for approved partners without the rider.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push_hygiene.sql
--
-- Runs in one transaction and is rolled back.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000165a1'),
  ('00000000-0000-0000-0000-0000000165a2')
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-0000000165a1'),
  ('00000000-0000-0000-0000-0000000165a2')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

create or replace function pg_temp.as_user(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id, 'role', 'authenticated')::text, true);
$$;

-- 1. A refreshed token on the same device replaces the old one ---------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000165a1');
select public.push_register_device('tok-old', 'ios', null, '{call_ui}', 'dev-1');
select public.push_register_device('voip-1', 'ios_voip', null, '{call_ui}', 'dev-1');
select public.push_register_device('tok-new', 'ios', null, '{call_ui}', 'dev-1');
select pg_temp.check(
  (select array_agg(token order by token) from public.push_tokens where device_key = 'dev-1') = '{tok-new,voip-1}',
  'the old token of the same kind should go, the VoIP token stay');

-- 2. Another account signing in on the device takes it over -----------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000165a2');
select public.push_register_device('tok-other', 'ios', null, '{}', 'dev-1');
select pg_temp.check(
  not exists (select 1 from public.push_tokens where token = 'tok-new'),
  'the first account still gets this phone''s notifications');
select pg_temp.check(
  (select profile_id from public.push_tokens where token = 'tok-other') = '00000000-0000-0000-0000-0000000165a2',
  'the new token is not the new account''s');

-- 3. No key: as before (older builds) -----------------------------------------
select public.push_register_device('tok-a', 'android', null, '{}');
select public.push_register_device('tok-b', 'android', null, '{}');
select pg_temp.check(
  (select count(*) from public.push_tokens where token in ('tok-a', 'tok-b')) = 2,
  'without a device key nothing is removed');

-- 4. Grants -------------------------------------------------------------------
select pg_temp.check(
  not has_function_privilege('anon', 'public.push_register_device(text, text, text, text[], text)', 'execute')
  and has_function_privilege('authenticated', 'public.push_register_device(text, text, text, text[], text)', 'execute')
  and not has_function_privilege('authenticated', 'public.ride_request_push_everyone(uuid, jsonb, text)', 'execute'),
  'grants');

-- 5. The broadcast asks for approved partners and leaves the rider out --------
select pg_temp.check(
  pg_get_functiondef('public.ride_request_push_everyone(uuid, jsonb, text)'::regprocedure) like '%approvedOnly%'
  and pg_get_functiondef('public.ride_request_push_everyone(uuid, jsonb, text)'::regprocedure) like '%excludeProfileIds%',
  'the everyone broadcast still reaches unapproved partners or the rider');

rollback;

select 'push_hygiene: all passed';
