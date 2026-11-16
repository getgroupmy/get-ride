-- ============================================================================
-- Regression test for migration 0416: Apple Maps' automatic share.
--   * the one row starts at 0 % for Apple Maps;
--   * fare_live_balance_set_apple stores a share and a reason, rejects bad
--     shares, and leaves the Google Maps share (0414) alone, and the other way;
--   * only the service role may set it; admins may read it, riders may not.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fare_live_balance_apple_0416.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000416a1'),  -- admin
  ('00000000-0000-0000-0000-0000000416b1')   -- rider
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-0000000416a1'), ('00000000-0000-0000-0000-0000000416b1')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000416a1', 'admin-settings-fare-ai', 'edit')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.errored(text) to authenticated;

-- 1. One row; Apple Maps starts at 0 %.
select pg_temp.check((select count(*) = 1 from public.fare_live_balance), 'exactly one row');
select pg_temp.check((select apple_first_pct = 0 from public.fare_live_balance), 'Apple Maps starts at 0 %');

-- 2. The service role sets it; the Google Maps share is untouched, and the other way.
select public.fare_live_balance_set(25, 'Google Maps answers more often');
select public.fare_live_balance_set_apple(15, 'Apple Maps answers more often');
select pg_temp.check(
  (select apple_first_pct = 15 and apple_reason = 'Apple Maps answers more often'
          and apple_updated_at > now() - interval '1 minute'
          and gmap_first_pct = 25 and reason = 'Google Maps answers more often'
     from public.fare_live_balance),
  'the Apple share and its reason are stored; the Google Maps share stays');
select public.fare_live_balance_set(30, 'again');
select pg_temp.check((select apple_first_pct = 15 from public.fare_live_balance),
  'setting the Google Maps share leaves the Apple share');
select pg_temp.check(pg_temp.errored($q$select public.fare_live_balance_set_apple(101, 'x')$q$), 'over 100 % is refused');
select pg_temp.check(pg_temp.errored($q$select public.fare_live_balance_set_apple(-1, 'x')$q$), 'below 0 % is refused');

-- 3. Who may do what.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000416a1', 'role', 'authenticated')::text, true);
select pg_temp.check((select apple_first_pct = 15 from public.fare_live_balance), 'an admin can read the Apple share');
select pg_temp.check(pg_temp.errored($q$select public.fare_live_balance_set_apple(10, 'x')$q$),
  'an admin cannot set it directly (service role only)');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-0000-0000-0000000416b1', 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.check((select count(*) = 0 from public.fare_live_balance), 'a rider sees nothing');
reset role;

rollback;
