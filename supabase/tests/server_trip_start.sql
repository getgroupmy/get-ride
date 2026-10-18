-- ============================================================================
-- Regression test for migration 0152: the server checks the trip code and
-- starts the trip; the driver can't read the code.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/server_trip_start.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000152a1'),  -- rider
  ('00000000-0000-0000-0000-0000000152b1'),  -- driver
  ('00000000-0000-0000-0000-0000000152c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000152%'
on conflict do nothing;

-- Off, as shipped.
delete from public.settings_entries where id = '72656c69-6162-4c69-8000-000000000001';

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, otp, pickup_name) values
  ('00000000-0000-0000-0000-0000000152e1', '00000000-0000-0000-0000-0000000152a1',
   '00000000-0000-0000-0000-0000000152b1', 'arrived', 20, 20, '4821', 'KLCC'),
  ('00000000-0000-0000-0000-0000000152e2', '00000000-0000-0000-0000-0000000152a1',
   '00000000-0000-0000-0000-0000000152b1', 'arrived', 20, 20, null, 'KLCC');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

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

-- 1. Every ride has a code: the rider's, else one made by the server --------------
select pg_temp.check((select code = '4821' from public.ride_trip_codes where request_id = '00000000-0000-0000-0000-0000000152e1'),
                     'the code the rider''s app sent is kept');
select pg_temp.check((select code ~ '^[0-9]{4}$' from public.ride_trip_codes where request_id = '00000000-0000-0000-0000-0000000152e2'),
                     'a ride without one gets a 4-digit code');
select pg_temp.check((select otp = '4821' from public.ride_requests where id = '00000000-0000-0000-0000-0000000152e1'),
                     'switch off: older builds still find the code on the ride');

set local role authenticated;

-- 2. Only the rider reads the code ----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000152a1');
select pg_temp.check((select count(*) = 2 from public.ride_trip_codes), 'the rider reads their codes');
select pg_temp.as_user('00000000-0000-0000-0000-0000000152b1');
select pg_temp.check((select count(*) = 0 from public.ride_trip_codes), 'the driver reads no code');

-- 3. Only the ride's driver starts it, and only with the code ---------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000152c1');
select pg_temp.refused($q$select public.start_trip('00000000-0000-0000-0000-0000000152e1', '4821')$q$, 'a stranger starting the trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000152a1');
select pg_temp.refused($q$select public.start_trip('00000000-0000-0000-0000-0000000152e1', '4821')$q$, 'the rider starting the trip');

select pg_temp.as_user('00000000-0000-0000-0000-0000000152b1');
select pg_temp.check(public.start_trip('00000000-0000-0000-0000-0000000152e1', '0000') = 'wrong_code', 'a wrong code is refused');
select pg_temp.check((select status = 'arrived' from public.ride_requests where id = '00000000-0000-0000-0000-0000000152e1'),
                     'a wrong code leaves the trip waiting');
select pg_temp.check(public.start_trip('00000000-0000-0000-0000-0000000152e1', ' 4821 ') = 'on_trip', 'the right code starts it');
select pg_temp.check(public.start_trip('00000000-0000-0000-0000-0000000152e1', null) = 'on_trip', 'a retry is answered, not refused');
reset role;
select pg_temp.check((select status = 'on_trip' and start_method = 'pin' and started_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000152e1'),
                     'started by PIN, and stamped');

-- 4. Five tries per trip, then a wait, right code or not ------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000152b1');
do $$
declare
  v_code text := (select code from public.ride_trip_codes where request_id = '00000000-0000-0000-0000-0000000152e2');
  i int;
begin
  for i in 1..5 loop
    perform pg_temp.check(public.start_trip('00000000-0000-0000-0000-0000000152e2', 'xxxx') = 'wrong_code', 'tries 1-5 answered');
  end loop;
  perform pg_temp.check(public.start_trip('00000000-0000-0000-0000-0000000152e2', v_code) like 'rate_limited:%',
                        'the sixth try waits, even with the right code');
end $$;
reset role;

-- 5. Switched on: no code on the ride row, and no starting a trip with a status update ------
insert into public.settings_entries (id, category, values)
values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging', '{"server_trip_start": true}')
on conflict (id) do update set values = excluded.values;

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, otp, pickup_name) values
  ('00000000-0000-0000-0000-0000000152e3', '00000000-0000-0000-0000-0000000152a1',
   '00000000-0000-0000-0000-0000000152b1', 'arrived', 20, 20, '7711', 'KLCC');
select pg_temp.check((select otp is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000152e3'),
                     'switch on: the code is not written on the ride');
select pg_temp.check((select code = '7711' from public.ride_trip_codes where request_id = '00000000-0000-0000-0000-0000000152e3'),
                     'switch on: the code is kept for the rider');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000152b1');
select pg_temp.refused($q$update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000152e3'$q$,
                       'a driver starting the trip with a status update');
select pg_temp.check(public.start_trip('00000000-0000-0000-0000-0000000152e3', '7711') = 'on_trip', 'start_trip still starts it');
reset role;

-- 6. The shared page shows the code to the person the ride was booked for -------------------
update public.ride_requests
   set booked_for_phone = '+60123450152', status = 'arrived'
 where id = '00000000-0000-0000-0000-0000000152e2';
-- The link is kept aside (0220), not on the ride row.
insert into public.ride_request_private (request_id, share_token)
values ('00000000-0000-0000-0000-0000000152e2', '00000000-0000-0000-0000-0000000152f1')
on conflict (request_id) do update set share_token = excluded.share_token;
select pg_temp.check((public.ride_share_view('00000000-0000-0000-0000-0000000152f1')->>'otp')
                       = (select code from public.ride_trip_codes where request_id = '00000000-0000-0000-0000-0000000152e2'),
                     'the shared page reads the code from ride_trip_codes');

-- 7. Clients can't run the helpers ------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.new_trip_code()', 'execute'), 'no client makes codes');
select pg_temp.check(not has_function_privilege('anon', 'public.start_trip(uuid, text)', 'execute'), 'anon can''t start trips');

rollback;

select 'server_trip_start: all passed';
