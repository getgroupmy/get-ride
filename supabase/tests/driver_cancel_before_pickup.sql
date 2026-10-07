-- ============================================================================
-- Regression test for migration 0106: a driver may cancel a ride only before
-- the passenger is on board.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_cancel_before_pickup.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000006a1'),  -- rider
  ('00000000-0000-0000-0000-0000000006b1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000006%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, cancel_requested_by) values
  ('00000000-0000-0000-0000-0000000006c1', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000006b1', 'accepted', null),
  ('00000000-0000-0000-0000-0000000006c2', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000006b1', 'arrived',  null),
  ('00000000-0000-0000-0000-0000000006c3', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000006b1', 'on_trip',  null),
  ('00000000-0000-0000-0000-0000000006c4', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000006b1', 'on_trip',  'rider'),
  ('00000000-0000-0000-0000-0000000006c5', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000006b1', 'on_trip',  'partner');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

create or replace function pg_temp.expect_status(p_id uuid, p_status text) returns void language plpgsql as $$
begin
  if (select status from public.ride_requests where id = p_id) is distinct from p_status then
    raise exception 'FAILED: ride % should be %', p_id, p_status;
  end if;
end $$;
grant execute on function pg_temp.expect_status(uuid, text) to authenticated;

set local role authenticated;

-- 1. Before pickup the driver cancels outright ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000006b1');
update public.ride_requests set status = 'cancelled', cancel_reason = 'passenger_no_show', cancel_requested_by = 'partner'
 where id in ('00000000-0000-0000-0000-0000000006c1', '00000000-0000-0000-0000-0000000006c2');
select pg_temp.expect_status('00000000-0000-0000-0000-0000000006c1', 'cancelled');
select pg_temp.expect_status('00000000-0000-0000-0000-0000000006c2', 'cancelled');

-- 2. With the passenger on board the driver cannot ---------------------------
select pg_temp.refused(
  $q$update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000006c3'$q$,
  'a driver cancelling a trip in progress');
select pg_temp.refused(
  $q$update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000006c5'$q$,
  'a driver approving their own cancellation request mid-trip');

-- 3. ...unless the passenger asked for it ------------------------------------
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000006c4';
select pg_temp.expect_status('00000000-0000-0000-0000-0000000006c4', 'cancelled');

-- 4. The trip itself still ends normally -------------------------------------
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000006c3';
select pg_temp.expect_status('00000000-0000-0000-0000-0000000006c3', 'completed');

reset role;
select 'driver_cancel_before_pickup: all passed';
rollback;
