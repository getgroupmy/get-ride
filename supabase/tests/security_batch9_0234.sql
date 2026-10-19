-- ============================================================================
-- Regression test for migration 0234 (security tester batch 9):
--   1. fare_ai_key_states is read only by the Fare AI page's admins;
--   2. rate limits slide, so a burst straddling two windows gets the limit,
--      not twice it;
--   3. anon only reads claude_access_rules.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_batch9_0234.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000234a1'),  -- sub-admin, READ on the Fare AI page
  ('00000000-0000-0000-0000-0000000234a2'),  -- sub-admin, READ on the Settings hub
  ('00000000-0000-0000-0000-0000000234a3'),  -- full admin
  ('00000000-0000-0000-0000-0000000234a4'),  -- sub-admin, EDIT on another page only
  ('00000000-0000-0000-0000-0000000234b1')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000234%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000234a1', 'admin-settings-fare-ai', 'read'),
  ('00000000-0000-0000-0000-0000000234a2', 'admin-settings', 'read'),
  ('00000000-0000-0000-0000-0000000234a3', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000234a4', 'admin-users', 'edit')
on conflict do nothing;
insert into public.fare_ai_key_states (key_id, provider, last_error)
values ('t234-key', 'test', 'raw provider answer')
on conflict (key_id) do update set last_error = excluded.last_error;

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
-- Whether the caller sees the test key's row.
create or replace function pg_temp.sees_key() returns boolean language plpgsql as $$
begin
  return exists (select 1 from public.fare_ai_key_states where key_id = 't234-key');
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.sees_key()
  to anon, authenticated;

-- 1. fare_ai_key_states --------------------------------------------------------------------------------
select pg_temp.check(
  not has_table_privilege('anon', 'public.fare_ai_key_states', 'select')
  and not has_table_privilege('anon', 'public.fare_ai_key_states', 'insert')
  and not has_table_privilege('anon', 'public.fare_ai_key_states', 'update')
  and not has_table_privilege('anon', 'public.fare_ai_key_states', 'delete'),
  'anon has no grant on fare_ai_key_states');
select pg_temp.check(
  has_table_privilege('authenticated', 'public.fare_ai_key_states', 'select')
  and not has_table_privilege('authenticated', 'public.fare_ai_key_states', 'insert')
  and not has_table_privilege('authenticated', 'public.fare_ai_key_states', 'update')
  and not has_table_privilege('authenticated', 'public.fare_ai_key_states', 'delete')
  and not has_table_privilege('authenticated', 'public.fare_ai_key_states', 'truncate'),
  'authenticated may only select fare_ai_key_states');
select pg_temp.check(
  not exists (select 1 from pg_policy where polrelid = 'public.fare_ai_key_states'::regclass
                and pg_get_expr(polqual, polrelid) = 'true'),
  'no policy lets everyone read fare_ai_key_states');

set local role anon;
select set_config('request.jwt.claims', '{"role": "anon"}', true);
do $$
begin
  perform 1 from public.fare_ai_key_states;
  raise exception 'FAILED: anon read fare_ai_key_states';
exception when insufficient_privilege then null;
end $$;
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000234b1');
select pg_temp.check(not pg_temp.sees_key(), 'a rider does not see the AI keys');
select pg_temp.as_user('00000000-0000-0000-0000-0000000234a4');
select pg_temp.check(not pg_temp.sees_key(), 'a sub-admin of another page does not see the AI keys');
select pg_temp.as_user('00000000-0000-0000-0000-0000000234a1');
select pg_temp.check(pg_temp.sees_key(), 'READ on the Fare AI page sees the AI keys');
select pg_temp.as_user('00000000-0000-0000-0000-0000000234a2');
select pg_temp.check(pg_temp.sees_key(), 'READ on the Settings hub sees the AI keys');
select pg_temp.as_user('00000000-0000-0000-0000-0000000234a3');
select pg_temp.check(pg_temp.sees_key(), 'a full admin sees the AI keys');
select pg_temp.check(
  (select last_error from public.fare_ai_key_states where key_id = 't234-key') = 'raw provider answer',
  'the admin page reads every column it shows');
do $$
begin
  update public.fare_ai_key_states set usage_count = 99 where key_id = 't234-key';
  raise exception 'FAILED: an admin wrote fare_ai_key_states from the app';
exception when insufficient_privilege then null;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- 2. Sliding rate limits ---------------------------------------------------------------------------------
-- The weighing itself: limit 5 over 600 s.
select pg_temp.check(public.auth_rate_retry_after(4, 0, 5, 600, 300) = 0, '4 of 5, nothing before: passes');
select pg_temp.check(public.auth_rate_retry_after(5, 0, 5, 600, 300) = 300,
  '5 of 5: waits for the window to end');
select pg_temp.check(public.auth_rate_retry_after(0, 5, 5, 600, 1) = 0,
  '1 s into a window after a full one: 5 x 599/600 < 5, one passes');
select pg_temp.check(public.auth_rate_retry_after(1, 5, 5, 600, 1) = 119,
  'then the next waits until 1 + 5 x (1 - f) < 5, at f = 0.2 (120 s)');
select pg_temp.check(public.auth_rate_retry_after(2, 5, 5, 600, 300) = 0,
  'half way: 2 + 2.5 < 5 passes');
select pg_temp.check(public.auth_rate_retry_after(3, 5, 5, 600, 300) = 60,
  'half way: 3 + 2.5 >= 5 waits until f = 0.6');
select pg_temp.check(public.auth_rate_retry_after(0, 0, 0, 600, 100) = 500, 'a limit of none waits for the window');

do $$
declare
  w       integer;
  passed  integer := 0;
  -- A window whose start is 1-2 s ago: its length is the whole seconds since
  -- the epoch, less one, so it started at that many seconds (now / length is
  -- between 1 and 2) and the window before it started at the epoch.
  v_secs  integer := floor(extract(epoch from now()))::integer - 1;
  v_win   interval := make_interval(secs => v_secs);
begin
  -- 5 tries at the very end of the previous window ...
  insert into public.auth_rate_counts (bucket, key, window_s, window_start, hits)
  values ('t234', '203.0.113.34', v_secs, to_timestamp(0), 5);
  -- ... then a burst of 10 just after the boundary.
  for i in 1..10 loop
    w := public.auth_rate_take('t234', '203.0.113.34', 5, v_win);
    if w = 0 then
      passed := passed + 1;
    end if;
  end loop;
  perform pg_temp.check(passed = 1,
    format('a burst straddling the boundary gets 1 more try, not 5 (got %s)', passed));
  perform pg_temp.check(w >= 1, 'the refused try is told to wait');
  perform pg_temp.check(public.auth_rate_wait('t234', '203.0.113.34', 5, v_win) >= 1,
    'the peek weighs the previous window too');
  perform pg_temp.check(
    (select hits from public.auth_rate_counts
      where bucket = 't234' and key = '203.0.113.34' and window_start = to_timestamp(v_secs)) = 1,
    'refused tries are not counted');

  -- With nothing before, the whole limit passes in the window.
  passed := 0;
  for i in 1..7 loop
    if public.auth_rate_take('t234', '203.0.113.35', 5, v_win) = 0 then
      passed := passed + 1;
    end if;
  end loop;
  perform pg_temp.check(passed = 5, format('a fresh key gets its 5 (got %s)', passed));

  -- Two windows back no longer counts.
  insert into public.auth_rate_counts (bucket, key, window_s, window_start, hits)
  values ('t234', '203.0.113.36', 600, date_trunc('hour', now()) - interval '1 day', 5);
  perform pg_temp.check(public.auth_rate_take('t234', '203.0.113.36', 5, interval '10 minutes') = 0,
    'tries from long ago do not count');
end
$$;

select pg_temp.check(
  not has_function_privilege('anon', 'public.auth_rate_retry_after(integer, integer, integer, integer, double precision)', 'execute')
  and not has_function_privilege('authenticated', 'public.auth_rate_retry_after(integer, integer, integer, integer, double precision)', 'execute')
  and not has_function_privilege('anon', 'public.auth_rate_take(text, text, integer, interval)', 'execute')
  and not has_function_privilege('authenticated', 'public.auth_rate_wait(text, text, integer, interval)', 'execute'),
  'the limiter is not callable from the apps');
select pg_temp.check(
  not exists (select 1 from pg_extension where extname = 'pg_cron')
  or exists (select 1 from cron.job where jobname = 'purge-auth-rate-counts'
               and command like '%2 * make_interval(secs => window_s)%'),
  'the purge keeps the previous window');

-- 3. claude_access_rules -----------------------------------------------------------------------------------
select pg_temp.check(
  has_table_privilege('anon', 'public.claude_access_rules', 'select')
  and not has_table_privilege('anon', 'public.claude_access_rules', 'insert')
  and not has_table_privilege('anon', 'public.claude_access_rules', 'update')
  and not has_table_privilege('anon', 'public.claude_access_rules', 'delete')
  and not has_table_privilege('anon', 'public.claude_access_rules', 'truncate')
  and not has_table_privilege('anon', 'public.claude_access_rules', 'trigger')
  and not has_table_privilege('anon', 'public.claude_access_rules', 'references'),
  'anon only reads claude_access_rules');
select pg_temp.check(
  has_table_privilege('authenticated', 'public.claude_access_rules', 'select')
  and has_table_privilege('authenticated', 'public.claude_access_rules', 'insert')
  and has_table_privilege('authenticated', 'public.claude_access_rules', 'update')
  and has_table_privilege('authenticated', 'public.claude_access_rules', 'delete')
  and not has_table_privilege('authenticated', 'public.claude_access_rules', 'truncate'),
  'the admin page still writes through the policies');

rollback;

select 'security_batch9_0234: all passed';
