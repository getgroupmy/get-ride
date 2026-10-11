-- ============================================================================
-- Regression test for migration 0145: driver presence and the drivers a new
-- request is pushed to.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_presence.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000145a1'),  -- driver near KLCC
  ('00000000-0000-0000-0000-0000000145a2'),  -- driver in Johor (far)
  ('00000000-0000-0000-0000-0000000145a3'),  -- driver near KLCC, offline
  ('00000000-0000-0000-0000-0000000145b1')   -- a passenger
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000145%'
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000000145a1', 'Near', '+60100000001'),
  ('00000000-0000-0000-0000-0000000145a2', 'Far', '+60100000002'),
  ('00000000-0000-0000-0000-0000000145a3', 'Off', '+60100000003');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

-- Each driver reports in through the app.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000145a1');
select public.set_driver_presence(true, 3.1579, 101.7116);
select pg_temp.as_user('00000000-0000-0000-0000-0000000145a2');
select public.set_driver_presence(true, 1.4927, 103.7414);
select pg_temp.as_user('00000000-0000-0000-0000-0000000145a3');
select public.set_driver_presence(true, 3.1500, 101.7100);
select public.set_driver_presence(false);
-- A passenger has no presence.
select pg_temp.as_user('00000000-0000-0000-0000-0000000145b1');
select public.set_driver_presence(true, 3.1579, 101.7116);
select pg_temp.check((select count(*) = 0 from public.driver_presence), 'a passenger sees no presence rows');
select pg_temp.as_user('00000000-0000-0000-0000-0000000145a1');
select pg_temp.check((select count(*) = 1 from public.driver_presence), 'a driver sees only their own row');
reset role;

select pg_temp.check((select count(*) = 3 from public.driver_presence), 'three drivers, no passenger');
select pg_temp.check((select lat = 3.15 and not online from public.driver_presence
                       where profile_id = '00000000-0000-0000-0000-0000000145a3'),
  'going offline keeps the last position');

-- 1. Only the online driver near the pickup is told.
select pg_temp.check(
  (select array_agg(id) = array['00000000-0000-0000-0000-0000000145a1'::uuid]
     from public.nearby_online_drivers(3.1390, 101.6869, null) id),
  'the nearby online driver, not the far one or the offline one');

-- 2. A driver not seen for 3 minutes is not counted.
update public.driver_presence set updated_at = now() - interval '4 minutes'
 where profile_id = '00000000-0000-0000-0000-0000000145a1';
select pg_temp.check((select count(*) = 0 from public.nearby_online_drivers(3.1390, 101.6869, null)),
  'a stale driver is not told');

-- 3. No pickup position: nobody nearby (the trigger then tells every driver).
select pg_temp.check((select count(*) = 0 from public.nearby_online_drivers(null, null, null)), 'no position, no one');

-- 4. A new request still goes in when nobody is near (the push falls back).
insert into public.ride_requests (id, rider_id, status, fare, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000145e1', '00000000-0000-0000-0000-0000000145b1', 'open', 12, 3.139, 101.6869);
select pg_temp.check((select count(*) = 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000145e1'),
  'the request is written whoever is told');

select 'driver_presence: all passed';
rollback;
