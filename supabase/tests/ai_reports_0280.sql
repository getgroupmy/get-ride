-- ============================================================================
-- Regression test for migration 0280: Reports. Who may run a report (a full
-- admin, the Reports page; nobody else); the plan checked against the
-- catalogue (an unknown dataset, field, op or aggregate is refused, and so
-- is a personal field without the People pages); the figures, the total
-- row and Malaysia's months; at most 50,000 rows, said so; a sub-admin's
-- region (and none without one); every run in admin_audit_log; saved
-- reports and schedules only with an edit grant; the next run (weekdays,
-- the last day of the month); the scheduled claim moving a schedule on;
-- the job run as its maker; the send log.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ai_reports_0280.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if not has_function_privilege('authenticated', 'public.ai_report_run(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.ai_report_run(jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.ai_report_catalogue()', 'execute')
     or has_function_privilege('anon', 'public.ai_report_catalogue()', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_exec(jsonb, jsonb, timestamptz)', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_scope_for(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_catalogue_all()', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_schedule_job(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.ai_report_schedule_job(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_send_log(uuid, text, integer, integer, boolean, boolean, text)', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_schedules_due()', 'execute')
     or has_function_privilege('authenticated', 'public.ai_report_email_kick(uuid[], text)', 'execute')
     or has_function_privilege('anon', 'public.ai_report_schedule_send_now(uuid)', 'execute')
     or has_table_privilege('authenticated', 'public.ai_report_v_rides', 'select')
     or has_table_privilege('authenticated', 'public.ai_report_v_users', 'select')
     or has_table_privilege('anon', 'public.ai_reports_saved', 'select') then
    raise exception 'FAILED: 0280 grants';
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and not exists (select 1 from cron.job where jobname = 'ai-report-schedules' and schedule = '*/5 * * * *') then
    raise exception 'FAILED: the schedules job every 5 minutes';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.ai_report_run(jsonb)'::regprocedure) is not true
     or not exists (select 1 from pg_proc where oid = 'public.ai_report_run(jsonb)'::regprocedure
                     and 'statement_timeout=15s' = any(proconfig)) then
    raise exception 'FAILED: ai_report_run is a 15 s SECURITY DEFINER function';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000280a1', '60128000001'),  -- full admin
  ('00000000-0000-0000-0000-0000000280a2', '60128000002'),  -- Reports read, North 280
  ('00000000-0000-0000-0000-0000000280a3', '60128000003'),  -- Reports edit, no region, + Partners read
  ('00000000-0000-0000-0000-0000000280a4', '60128000004'),  -- Dashboard only
  ('00000000-0000-0000-0000-0000000280b1', '60128000011'),  -- rider
  ('00000000-0000-0000-0000-0000000280d1', '60128000021')   -- driver
on conflict do nothing;
insert into public.profiles (id, name, phone, email)
select id, 'AR280 ' || right(id::text, 2), '+' || phone, 'ar280' || right(id::text, 2) || '@example.com'
  from auth.users where id::text like '00000000-0000-0000-0000-0000000280%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone, email = excluded.email;

insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000280a1', '*', 'edit', null),
  ('00000000-0000-0000-0000-0000000280a2', 'admin-reports', 'read', '{"country": "Testland 280", "state": "North 280"}'),
  ('00000000-0000-0000-0000-0000000280a3', 'admin-reports', 'edit', null),
  ('00000000-0000-0000-0000-0000000280a3', 'admin-partners-all', 'read', null),
  ('00000000-0000-0000-0000-0000000280a4', 'admin-dashboard', 'read', null)
on conflict do nothing;

-- Rides: three completed in North 280 (Car 10 + 20, Motor 5), one in South
-- 280 (Car 40), one cancelled in North; all on 15 Oct 2026, Malaysia time,
-- and one at 23:30 on 31 Aug Malaysia time (still August there, 15:30 UTC).
insert into public.ride_requests (id, rider_id, partner_id, status, service, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                  country, state, city, fare, ride_fare, commission_amount, partner_name, created_at,
                                  cancel_reason) values
  ('00000000-0000-0000-0000-000000028001', '00000000-0000-0000-0000-0000000280b1', '00000000-0000-0000-0000-0000000280d1',
   'completed', 'Car AR280', 50.1, 150.1, 50.2, 150.2, 'Testland 280', 'North 280', 'Alpha 280', 10, 10, 1, 'Driver AR280',
   '2026-10-15 10:00+08', null),
  ('00000000-0000-0000-0000-000000028002', '00000000-0000-0000-0000-0000000280b1', '00000000-0000-0000-0000-0000000280d1',
   'completed', 'Car AR280', 50.1, 150.1, 50.2, 150.2, 'Testland 280', 'North 280', 'Alpha 280', 20, 20, 2, 'Driver AR280',
   '2026-10-15 11:00+08', null),
  ('00000000-0000-0000-0000-000000028003', '00000000-0000-0000-0000-0000000280b1', '00000000-0000-0000-0000-0000000280d1',
   'completed', 'Motor AR280', 50.1, 150.1, 50.2, 150.2, 'Testland 280', 'North 280', 'Beta 280', 5, 5, 0.5, 'Driver AR280',
   '2026-10-15 12:00+08', null),
  ('00000000-0000-0000-0000-000000028004', '00000000-0000-0000-0000-0000000280b1', '00000000-0000-0000-0000-0000000280d1',
   'completed', 'Car AR280', 60.1, 160.1, 60.2, 160.2, 'Testland 280', 'South 280', 'Gamma 280', 40, 40, 4, 'Driver AR280',
   '2026-10-15 13:00+08', null),
  ('00000000-0000-0000-0000-000000028005', '00000000-0000-0000-0000-0000000280b1', null,
   'cancelled', 'Car AR280', 50.1, 150.1, 50.2, 150.2, 'Testland 280', 'North 280', 'Alpha 280', 15, null, null, null,
   '2026-10-15 14:00+08', 'Changed my mind'),
  ('00000000-0000-0000-0000-000000028006', '00000000-0000-0000-0000-0000000280b1', '00000000-0000-0000-0000-0000000280d1',
   'completed', 'Car AR280', 50.1, 150.1, 50.2, 150.2, 'Testland 280', 'North 280', 'Alpha 280', 7, 7, 0.7, 'Driver AR280',
   '2026-08-31 23:30+08', null);
-- ride_requests triggers may stamp the times; put them back.
update public.ride_requests r set created_at = v.at
  from (values ('00000000-0000-0000-0000-000000028001'::uuid, '2026-10-15 10:00+08'::timestamptz),
               ('00000000-0000-0000-0000-000000028002', '2026-10-15 11:00+08'),
               ('00000000-0000-0000-0000-000000028003', '2026-10-15 12:00+08'),
               ('00000000-0000-0000-0000-000000028004', '2026-10-15 13:00+08'),
               ('00000000-0000-0000-0000-000000028005', '2026-10-15 14:00+08'),
               ('00000000-0000-0000-0000-000000028006', '2026-08-31 23:30+08')) v(id, at)
 where r.id = v.id;

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
-- Refused, with an error message containing [p_like].
create or replace function pg_temp.refused(p_sql text, p_like text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not ilike '%' || p_like || '%' then
      raise exception 'FAILED: % refused with "%"', p_what, sqlerrm;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;

-- The plan the tests run: completed rides of the test services in October,
-- by service, with count, fares and average.
create or replace function pg_temp.by_service() returns jsonb language sql as $$
  select public.ai_report_run('{"dataset": "rides",
    "filters": [{"field": "status", "op": "eq", "value": "completed"},
                {"field": "service", "op": "contains", "value": "AR280"}],
    "period": {"from": "2026-10-01", "to": "2026-10-31"},
    "group_by": ["service"],
    "measures": [{"field": "*", "agg": "count"}, {"field": "fare", "agg": "sum"}, {"field": "fare", "agg": "avg"}],
    "sort": [{"field": "fare", "dir": "desc"}]}'::jsonb)
$$;

-- ---- Who may run it -----------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000280b1');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides"}')$q$, 'does not include Reports', 'a rider running a report');
select pg_temp.refused($q$select public.ai_report_catalogue()$q$, 'does not include Reports', 'a rider reading the catalogue');
select pg_temp.as_user('00000000-0000-0000-0000-0000000280a4');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides"}')$q$, 'does not include Reports', 'a Dashboard-only admin');
select pg_temp.refused($q$select * from public.ai_report_v_rides$q$, 'permission denied', 'a client reading a dataset view');
select pg_temp.check((select count(*) = 0 from public.ai_reports_saved), 'a Dashboard-only admin reads no saved reports');

-- ---- The catalogue and the checks -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000280a1');
select pg_temp.check((select bool_and(d ? 'view' = false and d ? 'area' = false)
                        from jsonb_array_elements(public.ai_report_catalogue() -> 'datasets') d),
  'the catalogue never names the views');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.ai_report_catalogue() -> 'datasets') d,
                                                 jsonb_array_elements(d -> 'fields') f
                                  where f ->> 'id' ~ '(pin|hash|id_image|token|otp|key)'),
  'no PIN, hash, ID image, token or key in the catalogue');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "people"}')$q$, 'no dataset "people"', 'an unknown dataset');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "users", "columns": ["pin_hash"]}')$q$,
  'Users has no field "pin_hash"', 'a column outside the catalogue');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "filters": [{"field": "otp", "op": "eq", "value": "1"}]}')$q$,
  'Rides has no field "otp"', 'a filter outside the catalogue');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "group_by": ["id; drop table x"]}')$q$,
  'Rides has no field', 'a made-up identifier');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "filters": [{"field": "fare", "op": "contains", "value": "1"}]}')$q$,
  'can''t be used on', 'an op that does not fit the field');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "measures": [{"field": "fare", "agg": "median"}]}')$q$,
  'not a way to sum up', 'an unknown aggregate');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "measures": [{"field": "service", "agg": "sum"}]}')$q$,
  'is not a number', 'adding up text');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "filters": [{"field": "fare", "op": "gt", "value": "1; select 1"}]}')$q$,
  'needs a number', 'a value that is not a number');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "period": {"preset": "forever"}}')$q$,
  'unknown period', 'an unknown period');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "group_by": ["a", "b", "c", "d"]}')$q$,
  'at most 3', 'too many groups');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "group_by": ["service"], "sort": [{"field": "city", "dir": "asc"}]}')$q$,
  'isn''t a column', 'sorting by a column the report has not');

-- A value is a value: quotes stay inside the literal.
select pg_temp.check((public.ai_report_run('{"dataset": "rides", "filters": [{"field": "cancel_reason", "op": "eq",
                       "value": "x'') or (1=1"}], "measures": [{"field": "*", "agg": "count"}]}') -> 'rows' -> 0 ->> 0)::int = 0,
  'a quote in a value matches nothing');

-- ---- The figures --------------------------------------------------------------------------------
do $$
declare
  v jsonb := pg_temp.by_service();
begin
  perform pg_temp.check(v -> 'rows' = '[["Car AR280", 3, 70, 23.33], ["Motor AR280", 1, 5, 5.00]]'::jsonb,
    format('completed rides by service, fares highest first: %s', v -> 'rows'));
  perform pg_temp.check(v -> 'totals' = '[4, 75, 18.75]'::jsonb, format('the total row: %s', v -> 'totals'));
  perform pg_temp.check((v ->> 'row_count')::int = 2 and not (v ->> 'truncated')::boolean, 'two rows, all of them');
  perform pg_temp.check(v -> 'period' ->> 'from' = '2026-10-01' and v -> 'period' ->> 'to' = '2026-10-31', 'the period');
  perform pg_temp.check((select array_agg(c ->> 'id') from jsonb_array_elements(v -> 'columns') c)
                        = array['service', 'count', 'sum_fare', 'avg_fare'], 'the columns');
  perform pg_temp.check(v -> 'plan' -> 'sort' = '[{"field": "sum_fare", "dir": "desc"}]', 'the sort, by the measure');
end $$;

select pg_temp.check(public.ai_report_run('{"dataset": "rides",
    "filters": [{"field": "service", "op": "contains", "value": "AR280"}, {"field": "status", "op": "eq", "value": "completed"}],
    "group_by": ["created_at:month"], "measures": [{"field": "*", "agg": "count"}]}') -> 'rows'
  = '[["2026-08", 1], ["2026-10", 4]]'::jsonb,
  '23:30 on 31 August in Malaysia is August, by month oldest first');

select pg_temp.check(public.ai_report_run('{"dataset": "rides",
    "filters": [{"field": "service", "op": "contains", "value": "AR280"}, {"field": "completed_at", "op": "is_null"},
                {"field": "cancel_reason", "op": "not_null"}],
    "columns": ["cancel_reason", "fare"]}') -> 'rows'
  = '[["Changed my mind", 15]]'::jsonb,
  'a plain list with the columns asked for');

-- At most 50,000 rows, and the answer says it was cut.
reset role;
insert into public.payment_intents (reference, purpose, provider, amount, status)
select 'AR280-' || g, 'test', 'ar280', 1, 'paid' from generate_series(1, 50001) g;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000280a1');
do $$
declare
  v jsonb := public.ai_report_run('{"dataset": "payments", "filters": [{"field": "provider", "op": "eq", "value": "ar280"}],
                                    "columns": ["amount"], "limit": 999999}');
begin
  perform pg_temp.check((v ->> 'row_count')::int = 50000 and (v ->> 'truncated')::boolean
                        and jsonb_array_length(v -> 'rows') = 50000, 'cut at 50,000 rows, said so');
  v := public.ai_report_run('{"dataset": "payments", "filters": [{"field": "provider", "op": "eq", "value": "ar280"}],
                              "columns": ["amount"], "limit": 20}');
  perform pg_temp.check((v ->> 'row_count')::int = 20 and not (v ->> 'truncated')::boolean, 'a limit asked for is not "cut"');
  v := public.ai_report_run('{"dataset": "payments", "filters": [{"field": "provider", "op": "eq", "value": "ar280"}],
                              "measures": [{"field": "amount", "agg": "sum"}]}');
  perform pg_temp.check(v -> 'rows' = '[[50001]]', 'a sum over every row, not the first 50,000');
end $$;

-- Every run is logged.
reset role;
select pg_temp.check((select count(*) >= 7 from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000280a1' and action = 'ai_report.run'
                         and detail ? 'plan' and detail ? 'rows' and detail ->> 'dataset' is not null),
  'each run in admin_audit_log with the dataset, rows and plan');
select pg_temp.check((select (detail ->> 'rows')::int = 50000 and (detail ->> 'truncated')::boolean
                        from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000280a1' and action = 'ai_report.run'
                         and detail ->> 'dataset' = 'payments' order by created_at asc, (detail ->> 'rows')::int desc limit 1),
  'the logged rows');

-- ---- A sub-admin's region and personal fields ---------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000280a2');
select pg_temp.check(pg_temp.by_service() -> 'rows' = '[["Car AR280", 2, 30, 15.00], ["Motor AR280", 1, 5, 5.00]]'::jsonb
                     and (pg_temp.by_service() ->> 'limited')::boolean,
  'North 280 only: the South ride is not counted');
select pg_temp.check(pg_temp.by_service() -> 'totals' = '[3, 35, 11.67]'::jsonb, 'the total row in the region');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.ai_report_catalogue() -> 'datasets') d,
                                                 jsonb_array_elements(d -> 'fields') f
                                  where f ->> 'personal' is not null),
  'no personal fields without a People page');
select pg_temp.check((select d -> 'hidden' ? 'Driver name' from jsonb_array_elements(public.ai_report_catalogue() -> 'datasets') d
                       where d ->> 'id' = 'rides'),
  'the catalogue says which were left out');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "columns": ["driver_name"]}')$q$,
  'Rides has no field "driver_name"', 'a personal field without the Partners pages');
select pg_temp.check((public.ai_report_run('{"dataset": "users", "measures": [{"field": "*", "agg": "count"}]}')
                      -> 'rows' -> 0 ->> 0)::int > 0,
  'a dataset without a place is not limited');
select pg_temp.refused($q$insert into public.ai_reports_saved (name, plan) values ('x', '{"dataset": "rides"}')$q$,
  'row-level security', 'a read-only Reports admin saving a report');

select pg_temp.as_user('00000000-0000-0000-0000-0000000280a3');
select pg_temp.check(pg_temp.by_service() -> 'rows' = '[]'::jsonb and pg_temp.by_service() -> 'totals' = '[0, null, null]',
  'a Reports grant without a region sees no rides');
select pg_temp.check(public.ai_report_run('{"dataset": "rides", "columns": ["driver_name"],
                                            "filters": [{"field": "service", "op": "contains", "value": "AR280"}]}') -> 'rows' = '[]',
  'with the Partners pages the driver''s name may be asked for');
select pg_temp.refused($q$select public.ai_report_run('{"dataset": "rides", "columns": ["rider_name"]}')$q$,
  'no field "rider_name"', 'a rider''s name without the Users pages');

-- ---- Saved reports and schedules ----------------------------------------------------------------
insert into public.ai_reports_saved (name, request, plan)
values ('By service AR280', 'Rides by service', '{"dataset": "rides", "group_by": ["service"], "measures": [{"field": "*", "agg": "count"}],
        "filters": [{"field": "service", "op": "contains", "value": "AR280"}]}');
select pg_temp.check((select created_by = '00000000-0000-0000-0000-0000000280a3' from public.ai_reports_saved
                       where name = 'By service AR280'), 'a saved report is the saver''s');
select pg_temp.refused($q$insert into public.ai_report_schedules (saved_id, emails)
  select id, '{not-an-email}' from public.ai_reports_saved where name = 'By service AR280'$q$,
  'ai_report_schedules_emails_check', 'a schedule to a made-up address');
select pg_temp.refused($q$insert into public.ai_report_schedules (saved_id)
  select id from public.ai_reports_saved where name = 'By service AR280'$q$,
  'ai_report_schedules_someone', 'a schedule to nobody');
insert into public.ai_report_schedules (saved_id, frequency, at_time, weekdays, emails, formats, created_by)
select id, 'weekly', '08:00', '{3,1,1}', '{boss@example.com}', '{csv,xlsx}', '00000000-0000-0000-0000-0000000280a1'
  from public.ai_reports_saved where name = 'By service AR280';
select pg_temp.check((select s.created_by = '00000000-0000-0000-0000-0000000280a3' and weekdays = '{1,3}'
                             and next_run_at > now() and next_run_at <= now() + interval '7 days'
                             and extract(isodow from next_run_at at time zone 'Asia/Kuala_Lumpur') in (1, 3)
                             and (next_run_at at time zone 'Asia/Kuala_Lumpur')::time = '08:00'
                             and (scope ->> 'scoped')::boolean
                        from public.ai_report_schedules s join public.ai_reports_saved r on r.id = s.saved_id
                       where r.name = 'By service AR280'),
  'a schedule is its maker''s, its weekdays tidied, its next run on a Monday or Wednesday at 08:00 Malaysia');
select pg_temp.as_user('00000000-0000-0000-0000-0000000280a2');
select pg_temp.check((select count(*) = 1 from public.ai_report_schedules s join public.ai_reports_saved r on r.id = s.saved_id
                       where r.name = 'By service AR280'), 'a read-only Reports admin sees the schedules');
update public.ai_report_schedules set paused = true;
reset role;
select pg_temp.check((select not paused from public.ai_report_schedules s join public.ai_reports_saved r on r.id = s.saved_id
                       where r.name = 'By service AR280'), 'and can''t pause them');

-- The next run.
select pg_temp.check(public.ai_report_next_run('monthly', '08:00', '{}', -1::smallint, '2026-02-10 12:00+08')
                     = '2026-02-28 08:00+08', 'the last day of February');
select pg_temp.check(public.ai_report_next_run('monthly', '08:00', '{}', -1::smallint, '2026-02-28 08:00+08')
                     = '2026-03-31 08:00+08', 'strictly after: then the last day of March');
select pg_temp.check(public.ai_report_next_run('monthly', '23:30', '{}', 1::smallint, '2026-10-31 23:45+08')
                     = '2026-11-01 23:30+08', 'the 1st, late at night');
select pg_temp.check(public.ai_report_next_run('weekly', '08:00', '{1,3}', 1::smallint, '2026-10-21 09:00+08')
                     = '2026-10-26 08:00+08', 'Wednesday after 08:00: next Monday');
select pg_temp.check(public.ai_report_next_run('daily', '07:00', '{}', 1::smallint, '2026-10-23 06:59+08')
                     = '2026-10-23 07:00+08', 'later today');

-- Periods.
select pg_temp.check((select d_from = '2026-10-12' and d_to = '2026-10-18'
                        from public.ai_report_period_dates('{"preset": "previous_week"}', '2026-10-21 09:00+08')),
  'the previous week, Monday to Sunday');
select pg_temp.check((select d_from = '2026-09-01' and d_to = '2026-09-30'
                        from public.ai_report_period_dates('{"preset": "previous_month"}', '2026-10-01 00:30+08')),
  'just after midnight on the 1st in Malaysia: the previous month is September');
select pg_temp.check((select d_from = '2026-10-14' and d_to = '2026-10-20'
                        from public.ai_report_period_dates('{"preset": "last_n_days", "days": 7}', '2026-10-21 09:00+08')),
  'the last 7 whole days');

-- The claim: a due schedule is handed on once and moved to its next run.
update public.ai_report_schedules s set next_run_at = now() - interval '1 minute'
  from public.ai_reports_saved r where r.id = s.saved_id and r.name = 'By service AR280';
select pg_temp.check(public.ai_report_schedules_due() >= 1, 'the due schedule is claimed');
select pg_temp.check((select next_run_at > now() and last_claimed_at is not null
                        from public.ai_report_schedules s join public.ai_reports_saved r on r.id = s.saved_id
                       where r.name = 'By service AR280'), 'and moved to its next run');
select pg_temp.check(public.ai_report_schedules_due() = 0, 'and not claimed twice');
update public.ai_report_schedules s set next_run_at = now() - interval '1 minute', paused = true
  from public.ai_reports_saved r where r.id = s.saved_id and r.name = 'By service AR280';
select pg_temp.check(public.ai_report_schedules_due() = 0, 'a paused schedule is not claimed');

-- The job: run as the schedule's maker (no region: no rides), then not at
-- all once their Reports access is gone.
select pg_temp.check((select (j ->> 'ok')::boolean and j -> 'report' -> 'rows' = '[]'
                             and j -> 'recipients' = '["boss@example.com"]'
                             and j -> 'schedule' -> 'formats' = '["csv", "xlsx"]'
                             and j -> 'report' -> 'period' ->> 'preset' = 'previous_day'
                             and jsonb_array_length(j -> 'catalogue' -> 'datasets') > 0
                             and position('ai_report_v_' in (j -> 'catalogue')::text) = 0
                        from (select public.ai_report_schedule_job(s.id) j from public.ai_report_schedules s
                                join public.ai_reports_saved r on r.id = s.saved_id where r.name = 'By service AR280') x),
  'the job runs the saved plan for the schedule''s period, as its maker');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000280a3' and action = 'ai_report.run'
                         and detail ? 'schedule_id'), 'the job''s run is logged as its maker''s');
delete from public.admin_access where profile_id = '00000000-0000-0000-0000-0000000280a3' and page = 'admin-reports';
select pg_temp.check((select not (j ->> 'ok')::boolean and j ->> 'error' like '%no longer has access%'
                        from (select public.ai_report_schedule_job(s.id) j from public.ai_report_schedules s
                                join public.ai_reports_saved r on r.id = s.saved_id where r.name = 'By service AR280') x),
  'not once the maker has lost Reports');

select public.ai_report_send_log(s.id, 'scheduled', 4, 1, true, false, null)
  from public.ai_report_schedules s join public.ai_reports_saved r on r.id = s.saved_id where r.name = 'By service AR280';
select pg_temp.check((select s.last_status = 'sent' and exists (select 1 from public.ai_report_sends x
                                                                 where x.schedule_id = s.id and x.ok and x.rows = 4)
                        from public.ai_report_schedules s join public.ai_reports_saved r on r.id = s.saved_id
                       where r.name = 'By service AR280'), 'a send is logged');

rollback;
