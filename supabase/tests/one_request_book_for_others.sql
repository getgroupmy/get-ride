-- ============================================================================
-- Regression test for migration 0107: one request of their own at a time,
-- any number booked for other people (one per passenger).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/one_request_book_for_others.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000007a1'),  -- rider
  ('00000000-0000-0000-0000-0000000007a2')   -- another rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000007%'
on conflict do nothing;

-- A stale open request the app never expired, and a finished ride.
insert into public.ride_requests (rider_id, status, created_at) values
  ('00000000-0000-0000-0000-0000000007a1', 'open', now() - interval '20 minutes'),
  ('00000000-0000-0000-0000-0000000007a1', 'completed', now() - interval '1 hour');

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
    if sqlerrm <> 'RIDE_REQUEST_DUPLICATE' then
      raise exception 'FAILED: % was refused for the wrong reason: %', p_what, sqlerrm;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

create or replace function pg_temp.count_open(p uuid) returns int language sql as $$
  select count(*)::int from public.ride_requests
   where rider_id = p and status = 'open' and created_at > now() - interval '7 minutes'
$$;
grant execute on function pg_temp.count_open(uuid) to authenticated;

set local role authenticated;

-- 1. The first request goes through; stale and finished rows don't block it --
select pg_temp.as_user('00000000-0000-0000-0000-0000000007a1');
insert into public.ride_requests (rider_id, status) values ('00000000-0000-0000-0000-0000000007a1', 'open');

-- 2. A second one of their own is a duplicate, and is not stored -------------
select pg_temp.refused(
  $q$insert into public.ride_requests (rider_id, status) values ('00000000-0000-0000-0000-0000000007a1', 'open')$q$,
  'a second request of their own');
do $$
begin
  if pg_temp.count_open('00000000-0000-0000-0000-0000000007a1') <> 1 then
    raise exception 'FAILED: the duplicate was stored';
  end if;
end $$;

-- 3. Rides for other people: several at once, one per passenger -------------
insert into public.ride_requests (rider_id, status, booked_for_name, booked_for_phone) values
  ('00000000-0000-0000-0000-0000000007a1', 'open', 'Mak', '+60 12-345 6789'),
  ('00000000-0000-0000-0000-0000000007a1', 'open', 'Adik', '+60 19-888 7777');
select pg_temp.refused(
  $q$insert into public.ride_requests (rider_id, status, booked_for_name, booked_for_phone)
     values ('00000000-0000-0000-0000-0000000007a1', 'open', 'Mak', '60123456789')$q$,
  'a second ride for the same passenger');

-- 4. Once the own ride is under way it still counts; once done it doesn't ---
reset role;
update public.ride_requests set status = 'on_trip'
 where rider_id = '00000000-0000-0000-0000-0000000007a1' and status = 'open' and booked_for_phone is null
   and created_at > now() - interval '7 minutes';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000007a1');
select pg_temp.refused(
  $q$insert into public.ride_requests (rider_id, status) values ('00000000-0000-0000-0000-0000000007a1', 'open')$q$,
  'a request while their own ride is under way');
reset role;
update public.ride_requests set status = 'completed'
 where rider_id = '00000000-0000-0000-0000-0000000007a1' and status = 'on_trip';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000007a1');
insert into public.ride_requests (rider_id, status) values ('00000000-0000-0000-0000-0000000007a1', 'open');

-- 5. Another rider is unaffected --------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000007a2');
insert into public.ride_requests (rider_id, status) values ('00000000-0000-0000-0000-0000000007a2', 'open');

-- 6. A passenger name needs a phone ------------------------------------------
do $$
begin
  begin
    insert into public.ride_requests (rider_id, status, booked_for_name)
    values ('00000000-0000-0000-0000-0000000007a2', 'cancelled', 'Mak');
  exception when check_violation then
    return;
  end;
  raise exception 'FAILED: a passenger name without a phone was stored';
end $$;

reset role;
select 'one_request_book_for_others: all passed';
rollback;
