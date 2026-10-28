-- ============================================================================
-- Regression test for migration 0321: the office NAS's test database and
-- visitor stats.
-- The settings (normalised; who may change them; scrambling off for full
-- admins only); trying a PR's migrations (queued once, cancelled, refresh
-- now); pairing the runner with a one-time code; its check-in, claim and
-- report; the tab's state; the visitor stats settings; who may read what;
-- the runner's calls belong to the edge function only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/nas_testdb_stats_0321.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- p_sql must fail with p_state (42501 not allowed, 22023 bad value …).
create or replace function pg_temp.fails(p_sql text, p_state text, p_what text) returns void language plpgsql as $$
declare
  v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'FAILED: % was allowed', p_what;
  elsif v_state <> p_state then
    raise exception 'FAILED: % failed with % instead of %', p_what, v_state, p_state;
  end if;
end $$;

delete from public.app_settings where key in ('nas_testdb', 'nas_stats');
delete from public.testdb_runs;
delete from public.testdb_runners;

-- 1. Settings: defaults and normalising ------------------------------------------------------
select pg_temp.check(public.nas_testdb_config() = '{"refreshAt": "02:30", "scramble": true}'::jsonb,
  'nightly at 02:30, scrambled, by default');
select pg_temp.check(public.nas_testdb_normalize('{"refreshAt": "7:05", "scramble": false}')
                       = '{"refreshAt": "07:05", "scramble": false}'::jsonb, 'a one-digit hour is padded');
select pg_temp.check((public.nas_testdb_normalize('{"refreshAt": "24:10"}') ->> 'refreshAt') = '02:30'
                     and (public.nas_testdb_normalize('{"refreshAt": "x"}') ->> 'refreshAt') = '02:30'
                     and (public.nas_testdb_normalize('{"scramble": "no"}') ->> 'scramble')::boolean,
  'a wrong time or switch falls back to the default');

-- 2. Who may change them ------------------------------------------------------------------------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000321a01'),  -- full admin
  ('00000000-0000-0000-0000-000000321a02'),  -- sub-admin, Office NAS edit
  ('00000000-0000-0000-0000-000000321a03'),  -- sub-admin, Office NAS read
  ('00000000-0000-0000-0000-000000321a04')   -- rider
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-000000321a01'), ('00000000-0000-0000-0000-000000321a02'),
  ('00000000-0000-0000-0000-000000321a03'), ('00000000-0000-0000-0000-000000321a04')
on conflict (id) do update set id = excluded.id;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-000000321a01', '*', 'edit'),
  ('00000000-0000-0000-0000-000000321a02', 'admin-settings-office-nas', 'edit'),
  ('00000000-0000-0000-0000-000000321a03', 'admin-settings-office-nas', 'read')
on conflict do nothing;

select pg_temp.as_user('00000000-0000-0000-0000-000000321a02');
select pg_temp.check((public.admin_testdb_set('{"refreshAt": "03:15", "scramble": true}') ->> 'refreshAt') = '03:15',
  'a sub-admin with the page sets the time');
select pg_temp.fails($q$select public.admin_testdb_set('{"refreshAt": "03:15", "scramble": false}')$q$, '42501',
  'a sub-admin turning scrambling off');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a01');
select pg_temp.check(not (public.admin_testdb_set('{"refreshAt": "03:15", "scramble": false}') ->> 'scramble')::boolean,
  'a full admin turns scrambling off');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a02');
select pg_temp.check((public.admin_testdb_set('{"refreshAt": "03:15", "scramble": true}') ->> 'scramble')::boolean,
  'anyone who may edit turns it back on');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a03');
select pg_temp.check((public.admin_testdb_state() -> 'settings' ->> 'refreshAt') = '03:15', 'a read grant sees the tab');
select pg_temp.fails($q$select public.admin_testdb_set('{}')$q$, '42501', 'a read grant changing the time');
select pg_temp.fails($q$select public.admin_testdb_try(554, null)$q$, '42501', 'a read grant trying a migration');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a04');
select pg_temp.fails($q$select public.admin_testdb_state()$q$, '42501', 'a rider reading the tab');
select pg_temp.fails($q$select public.admin_office_nas_services()$q$, '42501', 'a rider reading NAS services');
select pg_temp.fails($q$select public.admin_nas_stats_config()$q$, '42501', 'a rider reading stats settings');

-- 3. Trying a PR's migrations ------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000321a02');
create temp table run_t on commit drop as select public.admin_testdb_try(554, null) as r;
select pg_temp.check((select r ->> 'status' = 'queued' and (r ->> 'pr_number')::int = 554 and r ->> 'kind' = 'migration'
                        from run_t), 'PR #554 is queued');
select pg_temp.check((public.admin_testdb_try(554, null) ->> 'id') = (select r ->> 'id' from run_t),
  'asking again gives the same waiting run');
select pg_temp.fails($q$select public.admin_testdb_try(null, null)$q$, '22023', 'neither a PR nor a branch');
select pg_temp.fails($q$select public.admin_testdb_try(1, 'main')$q$, '22023', 'both a PR and a branch');
select pg_temp.fails($q$select public.admin_testdb_try(null, 'a/../b')$q$, '22023', 'a branch with ..');
select pg_temp.fails($q$select public.admin_testdb_try(null, 'x; drop')$q$, '22023', 'a branch with spaces');
create temp table branch_t on commit drop as select public.admin_testdb_try(null, 'claude/nas-n4') as r;
select pg_temp.check((select r ->> 'branch' = 'claude/nas-n4' from branch_t), 'a branch is queued');
select pg_temp.check((public.admin_testdb_cancel((select (r ->> 'id')::uuid from branch_t)) ->> 'status') = 'cancelled',
  'a waiting run is cancelled');
select pg_temp.fails(format('select public.admin_testdb_cancel(%L)', (select r ->> 'id' from branch_t)), '22023',
  'cancelling it twice');
select pg_temp.check((public.admin_testdb_refresh() ->> 'kind') = 'refresh', 'a fresh copy is asked for');
select pg_temp.check((public.admin_testdb_refresh() ->> 'id')
                       = (select id::text from public.testdb_runs where kind = 'refresh'),
  'asked twice, one refresh');

-- 4. Pairing the runner ------------------------------------------------------------------------
select pg_temp.fails($q$select public.admin_testdb_pairing_code('Office')$q$, '42501', 'a sub-admin connecting the runner');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a01');
create temp table code_t on commit drop as select public.admin_testdb_pairing_code('DS224+') ->> 'code' as code;
select pg_temp.check((select code ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$' from code_t), 'code shown as XXXX-XXXX');
select pg_temp.as_db();
select pg_temp.check((public.testdb_pair('WRONG-CODE', 'nas-1') ->> 'error') = 'TESTDB_PAIR_CODE', 'a wrong code');
create temp table key_t on commit drop as
  select public.testdb_pair((select lower(code) from code_t), 'nas-1', null, 'DS224+ J4125', '1.0.0') as r;
select pg_temp.check((select r ? 'key' and r ->> 'label' = 'DS224+' from key_t), 'the code gives a key, with the label');
select pg_temp.check((public.testdb_pair((select code from code_t), 'nas-2') ->> 'error') = 'TESTDB_PAIR_CODE',
  'a code works once');
select pg_temp.check((select key_hash <> (select r ->> 'key' from key_t) from public.testdb_runners where device_id = 'nas-1'),
  'only the key''s hash is kept');

-- 5. Check-in, claim, report ------------------------------------------------------------------
select pg_temp.check(
  (select (h -> 'settings' ->> 'refreshAt') = '03:15' and (h ->> 'waiting')::int = 2
     from (select public.testdb_heartbeat((select r ->> 'key' from key_t), null, '1.0.0',
                  '{"refreshed_at": "2026-10-28T03:20:00Z", "size_bytes": 1800000000, "scrambled": true}') as h) x),
  'check-in hears the settings and that two runs wait');
select pg_temp.check((select status = 'ok' and (detail ->> 'scrambled')::boolean from public.nas_services where service = 'testdb'),
  'the check-in shows on the Overview');
select pg_temp.fails($q$select public.testdb_heartbeat('not-a-key')$q$, '42501', 'a made-up key');

create temp table claim_t on commit drop as select public.testdb_claim((select r ->> 'key' from key_t)) as c;
select pg_temp.check((select c ->> 'id' = (select r ->> 'id' from run_t) and c ->> 'status' = 'running' from claim_t),
  'the oldest waiting run is claimed: PR #554');
select pg_temp.check(
  (select x ->> 'status' = 'passed' and (x ->> 'ms')::int = 4200 and x -> 'files' ->> 0 = 'supabase/migrations/0321_x.sql'
          and x ->> 'head_sha' = 'abc123'
     from (select public.testdb_report((select r ->> 'key' from key_t), (select (c ->> 'id')::uuid from claim_t),
                  'migration', true, null, 4200, '{"rerun": "ok"}', 'abc123',
                  array['supabase/migrations/0321_x.sql']) as x) y),
  'the run passed in 4.2 s with its file and commit');
select pg_temp.fails(
  format('select public.testdb_report(%L, %L, %L, true)', (select r ->> 'key' from key_t), (select c ->> 'id' from claim_t), 'migration'),
  '22023', 'reporting a finished run again');
select pg_temp.check((select (c ->> 'kind') = 'refresh'
                        from (select public.testdb_claim((select r ->> 'key' from key_t)) as c) x),
  'next, the refresh asked for');
select pg_temp.check((select (x ->> 'status') = 'failed' and x ->> 'error' = 'disk full'
                        from (select public.testdb_report((select r ->> 'key' from key_t),
                                     (select id from public.testdb_runs where kind = 'refresh'),
                                     'refresh', false, 'disk full', 1000) as x) y),
  'a failed refresh keeps its error');
select pg_temp.check(public.testdb_claim((select r ->> 'key' from key_t)) is null, 'nothing else waits');
select pg_temp.check((public.testdb_report((select r ->> 'key' from key_t), null, 'refresh', true, null, 360000,
                       '{"source": "pg_dump"}') ->> 'status') = 'passed',
  'the nightly refresh is recorded');
select pg_temp.fails(format('select public.testdb_report(%L, null, %L, true)', (select r ->> 'key' from key_t), 'migration'),
  '22023', 'a migration result for no run');

select pg_temp.as_user('00000000-0000-0000-0000-000000321a03');
select pg_temp.check(
  (select s -> 'last_migration' ->> 'status' = 'passed' and (s -> 'last_migration' ->> 'pr_number')::int = 554
          and s -> 'last_refresh' ->> 'status' = 'passed' and jsonb_array_length(s -> 'waiting') = 0
          and (s -> 'runners' -> 0 ->> 'online')::boolean and jsonb_array_length(s -> 'recent') = 4
     from (select public.admin_testdb_state() as s) x),
  'the tab: last migration and refresh, nothing waiting, the runner online');
select pg_temp.check(jsonb_array_length(public.admin_office_nas_services()) >= 1, 'a read grant sees the NAS services');

-- 6. Visitor stats settings -----------------------------------------------------------------
select pg_temp.check(public.admin_nas_stats_config() = '{"on": true, "websiteId": null}'::jsonb, 'stats on, no website yet');
select pg_temp.fails($q$select public.admin_nas_stats_set('{"on": true}')$q$, '42501', 'a read grant changing stats');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a02');
select pg_temp.fails($q$select public.admin_nas_stats_set('{"websiteId": "not-an-id"}')$q$, '22023', 'a wrong website ID');
select pg_temp.check(
  (public.admin_nas_stats_set('{"on": false, "websiteId": " 3F2504E0-4F89-11D3-9A0C-0305E82C3301 "}') ->> 'websiteId')
    = '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
  'the website ID is kept, tidied');

-- 7. Removing the runner ends its key; its calls are the edge function's only ----------------
select pg_temp.as_user('00000000-0000-0000-0000-000000321a02');
select pg_temp.fails(format('select public.admin_testdb_runner_remove(%L)', (select id from public.testdb_runners limit 1)),
  '42501', 'a sub-admin disconnecting the runner');
select pg_temp.as_user('00000000-0000-0000-0000-000000321a01');
select public.admin_testdb_runner_remove((select id from public.testdb_runners where device_id = 'nas-1'));
select pg_temp.as_db();
select pg_temp.fails(format('select public.testdb_claim(%L)', (select r ->> 'key' from key_t)), '42501',
  'a removed runner''s key');
select pg_temp.check(not has_function_privilege('authenticated', 'public.testdb_pair(text, text, text, text, text)', 'execute')
                     and not has_function_privilege('anon', 'public.testdb_claim(text)', 'execute')
                     and not has_function_privilege('authenticated',
                           'public.testdb_report(text, uuid, text, boolean, text, integer, jsonb, text, text[])', 'execute'),
  'the runner''s calls are not open to the apps');
select pg_temp.check(not has_table_privilege('authenticated', 'public.testdb_runs', 'select')
                     and not has_table_privilege('anon', 'public.nas_services', 'select'),
  'the tables are not open to the apps');

rollback;
