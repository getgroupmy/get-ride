-- ============================================================================
-- Regression test for migration 0141: "Auto-accept offer of RM x" is kept by
-- the database. An offer at or under the rider's amount is taken in the
-- write that places it; anything else waits for the rider, and nobody but
-- the rider sets the amount.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_auto_accept.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000141a1'),  -- rider
  ('00000000-0000-0000-0000-0000000141b1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000141%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, status, fare, ride_fare, auto_accept_fare) values
  ('00000000-0000-0000-0000-0000000141c1', '00000000-0000-0000-0000-0000000141a1', 'open', 20, 20, 20),
  ('00000000-0000-0000-0000-0000000141c2', '00000000-0000-0000-0000-0000000141a1', 'open', 20, 20, 20),
  ('00000000-0000-0000-0000-0000000141c3', '00000000-0000-0000-0000-0000000141a1', 'open', 20, 20, null),
  ('00000000-0000-0000-0000-0000000141c4', '00000000-0000-0000-0000-0000000141a1', 'open', 15, 15, null),
  ('00000000-0000-0000-0000-0000000141c5', '00000000-0000-0000-0000-0000000141a1', 'open', 20, 20, null);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.expect(p_id uuid, p_status text, p_fare numeric) returns void language plpgsql as $$
declare
  r record;
begin
  select status, fare, ride_fare into r from public.ride_requests where id = p_id;
  if r.status is distinct from p_status or r.fare is distinct from p_fare or r.ride_fare is distinct from p_fare then
    raise exception 'FAILED: ride % should be % at %, is % at % / %', p_id, p_status, p_fare, r.status, r.fare, r.ride_fare;
  end if;
end $$;
grant execute on function pg_temp.expect(uuid, text, numeric) to authenticated;

-- 1. An offer at or under the amount is taken at once, billed at the offer.
update public.ride_requests set offered_fare = 18, partner_id = '00000000-0000-0000-0000-0000000141b1'
 where id = '00000000-0000-0000-0000-0000000141c1';
select pg_temp.expect('00000000-0000-0000-0000-0000000141c1', 'accepted', 18);
do $$
begin
  if (select accepted_at from public.ride_requests where id = '00000000-0000-0000-0000-0000000141c1') is null then
    raise exception 'FAILED: an auto-accepted ride is stamped accepted_at';
  end if;
end $$;

-- 2. Over the amount, or with auto-accept off, it waits for the rider.
update public.ride_requests set offered_fare = 25, partner_id = '00000000-0000-0000-0000-0000000141b1'
 where id = '00000000-0000-0000-0000-0000000141c2';
select pg_temp.expect('00000000-0000-0000-0000-0000000141c2', 'open', 20);
update public.ride_requests set offered_fare = 20, partner_id = '00000000-0000-0000-0000-0000000141b1'
 where id = '00000000-0000-0000-0000-0000000141c3';
select pg_temp.expect('00000000-0000-0000-0000-0000000141c3', 'open', 20);

-- 3. The rider switching it on with an offer standing takes that offer.
update public.ride_requests set offered_fare = 15, partner_id = '00000000-0000-0000-0000-0000000141b1'
 where id = '00000000-0000-0000-0000-0000000141c4';
select pg_temp.expect('00000000-0000-0000-0000-0000000141c4', 'open', 15);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000141a1');
update public.ride_requests set auto_accept_fare = 15 where id = '00000000-0000-0000-0000-0000000141c4';
reset role;
select pg_temp.expect('00000000-0000-0000-0000-0000000141c4', 'accepted', 15);

-- 4. Nobody else sets the amount.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000141b1');
update public.ride_requests set auto_accept_fare = 999 where id = '00000000-0000-0000-0000-0000000141c5';
reset role;
do $$
begin
  if (select auto_accept_fare from public.ride_requests where id = '00000000-0000-0000-0000-0000000141c5') is not null then
    raise exception 'FAILED: a driver set the rider''s auto-accept amount';
  end if;
end $$;

select 'ride_auto_accept: all passed';
rollback;
