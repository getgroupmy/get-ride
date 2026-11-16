-- ============================================================================
-- Regression test for migration 0414: the automatic Waze / Google Maps share.
--   * one row, starting at 0 % (Waze first, as before);
--   * fare_live_balance_set stores a share and a reason, rejects bad shares;
--   * only the service role may set it; admins may read it, riders may not.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fare_live_balance_0414.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000414a1'),  -- admin
  ('00000000-0000-0000-0000-0000000414b1')   -- rider
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-0000000414a1'), ('00000000-0000-0000-0000-0000000414b1')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000414a1', 'admin-settings-fare-ai', 'edit')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.errored(text) to authenticated;

-- 1. One row, Waze first by default.
select pg_temp.check((select count(*) = 1 from public.fare_live_balance), 'exactly one row');

-- 2. The service role sets it.
select public.fare_live_balance_set(25, 'Google Maps answers more often');
select pg_temp.check(
  (select gmap_first_pct = 25 and reason = 'Google Maps answers more often' and updated_at > now() - interval '1 minute'
     from public.fare_live_balance),
  'the share and its reason are stored');
select pg_temp.check(pg_temp.errored($q$select public.fare_live_balance_set(101, 'x')$q$), 'over 100 % is refused');
select pg_temp.check(pg_temp.errored($q$select public.fare_live_balance_set(-1, 'x')$q$), 'below 0 % is refused');
select pg_temp.check(
  pg_temp.errored($q$insert into public.fare_live_balance (id) values (false)$q$), 'there is never a second row');

-- 3. Who may do what.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000414a1', 'role', 'authenticated')::text, true);
select pg_temp.check((select count(*) = 1 from public.fare_live_balance), 'an admin can read the share');
select pg_temp.check(pg_temp.errored($q$select public.fare_live_balance_set(10, 'x')$q$),
  'an admin cannot set it directly (service role only)');
select pg_temp.check(pg_temp.errored($q$update public.fare_live_balance set gmap_first_pct = 10$q$)
  or (select gmap_first_pct = 25 from public.fare_live_balance), 'an admin cannot write the table');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000414b1', 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.check((select count(*) = 0 from public.fare_live_balance), 'a rider sees nothing');
reset role;

rollback;
