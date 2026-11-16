-- ============================================================================
-- Regression test for migration 0414: the advance-booking (scheduled ride)
-- surcharge overrides. Who may read/write, the global fallback, a master
-- override, a service-specific row beating an all-service one, and a region
-- level beating master.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scheduling_surcharge_0414.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000414c1'),  -- admin (edit)
  ('00000000-0000-0000-0000-0000000414c2'),  -- admin (view only)
  ('00000000-0000-0000-0000-0000000414d1')   -- ordinary rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000414%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000414c1', 'admin-settings-scheduling-surcharge', 'edit'),
  ('00000000-0000-0000-0000-0000000414c2', 'admin-settings-scheduling-surcharge', 'read')
on conflict do nothing;

-- Only this test's rows count.
delete from public.scheduling_surcharge_rates;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, anon;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n int;
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
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- 1. Global fallback: with no override rows, the fee equals the global
--    scheduled_rides_config() fee (fixed + percentage), unchanged behaviour.
-- ---------------------------------------------------------------------------
do $$
declare c jsonb := public.scheduled_rides_config();
        expected numeric := round((c->>'feeFixed')::numeric + 100 * (c->>'feePercent')::numeric / 100, 2);
begin
  perform pg_temp.check(
    public.scheduling_surcharge_fee_at('ride', 'Malaysia', 'Selangor', 'Shah Alam', null, 100) = expected,
    'no rows -> global config fee');
end $$;

-- ---------------------------------------------------------------------------
-- 2. A master all-service row overrides the global fee everywhere.
-- ---------------------------------------------------------------------------
insert into public.scheduling_surcharge_rates (level, service, fee_fixed, fee_percent)
  values ('master', null, 5, 0);
select pg_temp.check(public.scheduling_surcharge_fee_at('ride', 'Malaysia', null, null, null, 100) = 5.00,
  'master all-service fixed fee');
select pg_temp.check(public.scheduling_surcharge_fee_at('teksi', 'Thailand', null, null, null, 100) = 5.00,
  'master applies to any service / region');

-- fixed + percentage together.
update public.scheduling_surcharge_rates set fee_fixed = 3, fee_percent = 5 where level = 'master' and service is null;
select pg_temp.check(public.scheduling_surcharge_fee_at('ride', null, null, null, null, 100) = 8.00,
  'master fixed 3 + 5% of 100 = 8');

-- ---------------------------------------------------------------------------
-- 3. A service-specific master row beats the all-service master row, for that
--    service only.
-- ---------------------------------------------------------------------------
insert into public.scheduling_surcharge_rates (level, service, fee_fixed, fee_percent)
  values ('master', 'teksi', 0, 10);
select pg_temp.check(public.scheduling_surcharge_fee_at('teksi', null, null, null, null, 100) = 10.00,
  'teksi row (10% of 100) beats all-service master');
select pg_temp.check(public.scheduling_surcharge_fee_at('ride', null, null, null, null, 100) = 8.00,
  'ride still on the all-service master row');
select pg_temp.check(public.scheduling_surcharge_fee_at('TEKSI', null, null, null, null, 100) = 10.00,
  'service match is case-insensitive');

-- ---------------------------------------------------------------------------
-- 4. A country row beats master for that country; master still applies
--    elsewhere.
-- ---------------------------------------------------------------------------
insert into public.scheduling_surcharge_rates (level, country, service, fee_fixed, fee_percent)
  values ('country', 'Malaysia', null, 12, 0);
select pg_temp.check(public.scheduling_surcharge_fee_at('ride', 'Malaysia', 'Selangor', null, null, 100) = 12.00,
  'country (Malaysia) beats master');
select pg_temp.check(public.scheduling_surcharge_fee_at('ride', 'Thailand', null, null, null, 100) = 8.00,
  'country row does not apply in Thailand -> master');

-- ---------------------------------------------------------------------------
-- 5. An inactive row is ignored.
-- ---------------------------------------------------------------------------
update public.scheduling_surcharge_rates set active = false where level = 'country';
select pg_temp.check(public.scheduling_surcharge_fee_at('ride', 'Malaysia', null, null, null, 100) = 8.00,
  'inactive country row ignored -> master');
update public.scheduling_surcharge_rates set active = true where level = 'country';

-- ---------------------------------------------------------------------------
-- 6. RLS: an edit admin writes; a view-only admin and an ordinary rider cannot.
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000414c1');
insert into public.scheduling_surcharge_rates (level, service, fee_fixed) values ('master', 'courier', 7);
select pg_temp.check(
  (select count(*) from public.scheduling_surcharge_rates where service = 'courier') = 1,
  'edit admin may insert');

select pg_temp.as_user('00000000-0000-0000-0000-0000000414c2');
select pg_temp.refused(
  $q$insert into public.scheduling_surcharge_rates (level, service, fee_fixed) values ('master', 'freight', 9)$q$,
  'view-only admin insert');

select pg_temp.as_user('00000000-0000-0000-0000-0000000414d1');
select pg_temp.refused(
  $q$insert into public.scheduling_surcharge_rates (level, service, fee_fixed) values ('master', 'freight', 9)$q$,
  'ordinary rider insert');
-- but a rider may read (the device previews the fee).
select pg_temp.check((select count(*) from public.scheduling_surcharge_rates) >= 1, 'rider may read rows');

rollback;
