-- ============================================================================
-- Regression test for migration 0426: the driver's fix a second.
--   * ride_live_fix() takes a fix only from the ride's own driver, only while
--     the ride is under way, and keeps what the GPS measured (never a made-up
--     course or speed).
--   * Two fixes that crossed on the way: the older is dropped. A phone whose
--     clock was put right is not held up.
--   * The fix can be read by the ride's passenger and by nobody else — not the
--     driver's other passengers, not another driver, not a stranger, not a
--     visitor who is not signed in — and not by the passenger either once the
--     ride has ended or passed to another driver.
--   * Nobody writes the table except through the function.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_live_fixes_0426.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000426a1'),  -- passenger A
  ('00000000-0000-0000-0000-0000000426a2'),  -- passenger B
  ('00000000-0000-0000-0000-0000000426a3'),  -- passenger C
  ('00000000-0000-0000-0000-0000000426b1'),  -- driver D
  ('00000000-0000-0000-0000-0000000426b2'),  -- driver E
  ('00000000-0000-0000-0000-0000000426c1')   -- a stranger
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000426%'
on conflict do nothing;

-- A ride's driver is their own account (ride_requests.partner_id is the
-- driver's profile id, as the app writes it when they accept).
--   R1  A's trip with D, under way
--   R2  B's trip with D, finished
--   R3  B's trip with E, on the way to pickup
--   R5  C's trip with D, waiting at pickup (D's next passenger)
insert into public.ride_requests (id, rider_id, partner_id, status) values
  ('00000000-0000-0000-0000-000000426001', '00000000-0000-0000-0000-0000000426a1',
   '00000000-0000-0000-0000-0000000426b1', 'on_trip'),
  ('00000000-0000-0000-0000-000000426002', '00000000-0000-0000-0000-0000000426a2',
   '00000000-0000-0000-0000-0000000426b1', 'completed'),
  ('00000000-0000-0000-0000-000000426003', '00000000-0000-0000-0000-0000000426a2',
   '00000000-0000-0000-0000-0000000426b2', 'accepted'),
  ('00000000-0000-0000-0000-000000426005', '00000000-0000-0000-0000-0000000426a3',
   '00000000-0000-0000-0000-0000000426b1', 'arrived')
on conflict (id) do nothing;

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

-- [p_sql] changed or returned nothing, or was refused outright.
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

-- [p_sql] was refused outright.
create or replace function pg_temp.raised(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was accepted', p_what;
end $$;
grant execute on function pg_temp.raised(text, text) to authenticated, anon;

-- The fixes a signed-in caller can read, as (driver, ride) pairs.
create or replace function pg_temp.seen() returns text language sql as $$
  select coalesce(string_agg(right(driver_id::text, 2) || '>' || coalesce(right(ride_id::text, 2), '--'), ','
                             order by driver_id), '')
    from public.ride_live_fixes;
$$;
grant execute on function pg_temp.seen() to authenticated, anon;

-- ---------------------------------------------------------------------------
-- 1. The ride's driver sends a fix; it is kept as the GPS gave it.
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.1390, 101.6869, 87.5, 12.4, 4.0,
                       '2026-11-22 10:00:00+00'),
  'the driver''s fix for their own ride under way is taken');
reset role;
select pg_temp.check(
  (select ride_id = '00000000-0000-0000-0000-000000426001' and lat = 3.1390 and lng = 101.6869
          and heading = 87.5 and speed = 12.4 and accuracy = 4.0
          and fixed_at = '2026-11-22 10:00:00+00' and sent_at is not null
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'kept with its position, course, speed, accuracy and the phone''s time');
select pg_temp.check((select count(*) from public.ride_live_fixes) = 1, 'one row a driver');

-- ---------------------------------------------------------------------------
-- 2. Nobody else writes one, and not for a ride that is not under way.
-- ---------------------------------------------------------------------------
set local role authenticated;
-- The driver, for a ride of theirs that has finished.
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426002', 1.0, 100.0, 0, 5, 5, '2026-11-22 10:00:01+00'),
  'a finished ride takes no fix');
-- The driver, for another driver's ride.
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426003', 1.0, 100.0, 0, 5, 5, '2026-11-22 10:00:01+00'),
  'another driver''s ride takes no fix from this one');
-- A ride that does not exist.
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-0000004260ff', 1.0, 100.0, 0, 5, 5, '2026-11-22 10:00:01+00'),
  'a ride that does not exist takes no fix');
-- The passenger, for their own ride.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 1.0, 100.0, 0, 5, 5, '2026-11-22 10:00:01+00'),
  'the passenger cannot say where the car is');
-- A stranger.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426c1');
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 1.0, 100.0, 0, 5, 5, '2026-11-22 10:00:01+00'),
  'a stranger cannot say where the car is');
-- Straight into the table, as the driver.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.raised(
  $q$insert into public.ride_live_fixes (driver_id, ride_id, lat, lng, fixed_at)
     values ('00000000-0000-0000-0000-0000000426b2', '00000000-0000-0000-0000-000000426003', 1, 100, now())$q$,
  'an insert straight into the table');
select pg_temp.raised(
  $q$update public.ride_live_fixes set lat = 1.0$q$,
  'an update straight to the table');
select pg_temp.raised(
  $q$delete from public.ride_live_fixes$q$,
  'a delete straight from the table');
-- Not signed in at all.
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select set_config('request.jwt.claim.sub', '', true);
select pg_temp.raised(
  $q$select public.ride_live_fix('00000000-0000-0000-0000-000000426001', 1.0, 100.0, 0, 5, 5, now())$q$,
  'a fix from a visitor who is not signed in');
select pg_temp.raised($q$select count(*) from public.ride_live_fixes$q$, 'a read by a visitor who is not signed in');
select pg_temp.raised(
  $q$select public.ride_live_fix_reader('00000000-0000-0000-0000-000000426001',
                                        '00000000-0000-0000-0000-0000000426b1')$q$,
  'the reader check by a visitor who is not signed in');
reset role;
select pg_temp.check(
  (select lat = 3.1390 and lng = 101.6869 and ride_id = '00000000-0000-0000-0000-000000426001'
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1')
  and (select count(*) from public.ride_live_fixes) = 1,
  'and none of that moved the fix or added one');

-- ---------------------------------------------------------------------------
-- 3. Numbers no GPS gives: a position that is not one is refused; a course,
--    speed or accuracy that is not one is kept as "not known".
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 91, 101.0, 0, 5, 5, '2026-11-22 10:00:02+00')
  and not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.0, 181, 0, 5, 5, '2026-11-22 10:00:02+00')
  and not public.ride_live_fix('00000000-0000-0000-0000-000000426001', null, 101.0, 0, 5, 5, '2026-11-22 10:00:02+00')
  and not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 'NaN', 101.0, 0, 5, 5, '2026-11-22 10:00:02+00')
  and not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.0, 'Infinity', 0, 5, 5, '2026-11-22 10:00:02+00')
  and not public.ride_live_fix(null, 3.0, 101.0, 0, 5, 5, '2026-11-22 10:00:02+00'),
  'a position off the globe, or none, is refused');
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.1400, 101.6900, -1, -3, -8, '2026-11-22 10:00:03+00'),
  'a fix with no course, speed or accuracy is still a fix');
reset role;
select pg_temp.check(
  (select lat = 3.1400 and heading is null and speed is null and accuracy is null
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'the "none" a phone reports (-1) is kept as not known');
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.1401, 101.6901, 'NaN', 'Infinity', 'NaN',
                       '2026-11-22 10:00:04+00'),
  'nor does a number that is not one stop the fix');
reset role;
select pg_temp.check(
  (select lat = 3.1401 and heading is null and speed is null and accuracy is null
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'not-a-number and infinity are kept as not known');
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.1402, 101.6902, 360, 400, 5,
                       '2026-11-22 10:00:05+00'),
  'a course of 360 is north');
reset role;
select pg_temp.check(
  (select heading = 0 and speed is null and accuracy = 5
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  '360 degrees is kept as 0, and a speed no car does as not known');
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.1403, 101.6903, 361, 0, 0,
                       '2026-11-22 10:00:06+00'),
  'a car standing still');
reset role;
select pg_temp.check(
  (select heading is null and speed = 0 and accuracy = 0
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'standing still is a speed of 0, not "not known"; a course past 360 is not one');

-- ---------------------------------------------------------------------------
-- 4. Order: the newest fix by the phone's own clock stands.
-- ---------------------------------------------------------------------------
set local role authenticated;
-- Two that crossed on the way: the older arrives second.
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.2000, 101.7000, 10, 10, 5, '2026-11-22 10:00:10+00')
  and public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.1999, 101.6999, 10, 10, 5, '2026-11-22 10:00:09+00'),
  'both are answered: the ride takes fixes');
reset role;
select pg_temp.check(
  (select lat = 3.2000 and fixed_at = '2026-11-22 10:00:10+00'
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'the older of two that crossed is dropped');
-- The same fix again changes nothing.
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.3000, 101.8000, 10, 10, 5, '2026-11-22 10:00:10+00'),
  'a second fix stamped the same moment is answered');
reset role;
select pg_temp.check(
  (select lat = 3.2000 from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'and is not news');
-- The phone's clock was put back by a minute: its fixes are taken at once.
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.2100, 101.7100, 10, 10, 5, '2026-11-22 09:59:11+00'),
  'a fix from a clock put back');
reset role;
select pg_temp.check(
  (select lat = 3.2100 and fixed_at = '2026-11-22 09:59:11+00'
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'more than ten seconds older than the one held: the clock moved, and it is taken');
-- A little older than a fix that has stood for a while: taken too.
update public.ride_live_fixes set sent_at = now() - interval '11 seconds'
 where driver_id = '00000000-0000-0000-0000-0000000426b1';
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.2200, 101.7200, 10, 10, 5, '2026-11-22 09:59:08+00'),
  'a fix a little older than one that has stood for eleven seconds');
reset role;
select pg_temp.check(
  (select lat = 3.2200 and sent_at > now() - interval '5 seconds'
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'is taken: nothing newer was coming');
-- With no time from the phone, it is stamped here.
set local role authenticated;
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.2300, 101.7300),
  'a fix with only a position');
reset role;
select pg_temp.check(
  (select lat = 3.2300 and heading is null and speed is null and accuracy is null
          and fixed_at > now() - interval '1 minute'
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1'),
  'is kept with this server''s time');

-- ---------------------------------------------------------------------------
-- 5. Reading: the ride's passenger, and nobody else.
-- ---------------------------------------------------------------------------
-- E is on the way to B.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b2');
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426003', 5.4000, 100.3000, 200, 8, 6, '2026-11-22 10:00:00+00'),
  'driver E''s fix for the ride to B');

select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = 'b1>01', 'passenger A reads D''s fix for their ride, and only that: ' || pg_temp.seen());
select pg_temp.check(
  (select lat = 3.2300 and lng = 101.7300 from public.ride_live_fixes
    where ride_id = '00000000-0000-0000-0000-000000426001'),
  'asked for by ride, as the app asks');
select pg_temp.check(
  public.ride_live_fix_reader('00000000-0000-0000-0000-000000426001', '00000000-0000-0000-0000-0000000426b1')
  and not public.ride_live_fix_reader('00000000-0000-0000-0000-000000426003', '00000000-0000-0000-0000-0000000426b2')
  and not public.ride_live_fix_reader('00000000-0000-0000-0000-000000426001', '00000000-0000-0000-0000-0000000426b2')
  and not public.ride_live_fix_reader(null, '00000000-0000-0000-0000-0000000426b1')
  and not public.ride_live_fix_reader('00000000-0000-0000-0000-000000426001', null),
  'the reader check answers for the caller''s own ride and its own driver only');

-- B rode with D earlier (finished) and is waiting for E now.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a2');
select pg_temp.check(pg_temp.seen() = 'b2>03', 'passenger B reads E''s fix, and not D''s from the finished ride: ' || pg_temp.seen());

-- C is D's next passenger: D's fix is for A's ride, not theirs.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a3');
select pg_temp.check(pg_temp.seen() = '', 'D''s next passenger reads nothing while the fix is for A''s ride: ' || pg_temp.seen());

-- The drivers themselves, and a stranger.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.check(pg_temp.seen() = '', 'driver D reads nothing: ' || pg_temp.seen());
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b2');
select pg_temp.check(pg_temp.seen() = '', 'driver E reads nothing, their own or another''s: ' || pg_temp.seen());
select pg_temp.as_user('00000000-0000-0000-0000-0000000426c1');
select pg_temp.check(pg_temp.seen() = '', 'a stranger reads nothing: ' || pg_temp.seen());

-- ---------------------------------------------------------------------------
-- 6. The driver goes on to their next ride: the row is that ride's, at once,
--    whatever the time on its fix.
-- ---------------------------------------------------------------------------
-- (The fix held was stamped a moment ago, in step 4; this one three seconds
-- before it, which for the same ride would be two that crossed.)
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426005', 3.3000, 101.5000, 45, 0, 5,
                       now() - interval '3 seconds'),
  'D''s fix for C''s ride');
reset role;
select pg_temp.check(
  (select ride_id = '00000000-0000-0000-0000-000000426005' and lat = 3.3000
     from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b1')
  and (select count(*) from public.ride_live_fixes) = 2,
  'the driver''s one row is the new ride''s, though its fix is stamped a little earlier');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a3');
select pg_temp.check(pg_temp.seen() = 'b1>05', 'C reads it: ' || pg_temp.seen());
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = '', 'A no longer reads where D is: ' || pg_temp.seen());
-- Back to A's ride.
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.2400, 101.7400, 10, 10, 5, '2026-11-22 10:01:00+00'),
  'D''s fix for A''s ride again');
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = 'b1>01', 'A reads it again: ' || pg_temp.seen());

-- ---------------------------------------------------------------------------
-- 7. The ride passes to another driver: the first driver's fix cannot be
--    read, and the second's can once there is one.
-- ---------------------------------------------------------------------------
reset role;
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000426b2'
 where id = '00000000-0000-0000-0000-000000426001';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = '', 'A no longer reads the first driver''s fix: ' || pg_temp.seen());
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b1');
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.25, 101.75, 10, 10, 5, '2026-11-22 10:02:00+00'),
  'the first driver''s fixes for it are no longer taken');
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b2');
select pg_temp.check(
  public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.26, 101.76, 10, 10, 5, '2026-11-22 10:02:00+00'),
  'the second driver''s are');
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = 'b2>01', 'A reads the second driver''s fix: ' || pg_temp.seen());
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a2');
select pg_temp.check(pg_temp.seen() = '', 'B, whom E was on the way to, reads nothing now E''s fix is for A''s ride: ' || pg_temp.seen());

-- ---------------------------------------------------------------------------
-- 8. The ride ends: the fix stays where it is and nobody can read it.
-- ---------------------------------------------------------------------------
reset role;
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-000000426001';
select pg_temp.check(
  (select ride_id = '00000000-0000-0000-0000-000000426001' from public.ride_live_fixes
    where driver_id = '00000000-0000-0000-0000-0000000426b2'),
  'nothing is deleted when a ride ends');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = '', 'the passenger of a ride that has ended reads nothing: ' || pg_temp.seen());
select pg_temp.as_user('00000000-0000-0000-0000-0000000426b2');
select pg_temp.check(
  not public.ride_live_fix('00000000-0000-0000-0000-000000426001', 3.27, 101.77, 10, 10, 5, '2026-11-22 10:03:00+00'),
  'and its driver''s fixes are no longer taken');

-- ---------------------------------------------------------------------------
-- 9. A ride that is removed leaves the row with no ride; an account that is
--    removed takes its row with it.
-- ---------------------------------------------------------------------------
reset role;
delete from public.ride_requests where id = '00000000-0000-0000-0000-000000426001';
select pg_temp.check(
  (select ride_id is null from public.ride_live_fixes where driver_id = '00000000-0000-0000-0000-0000000426b2'),
  'the removed ride''s fix is left with no ride');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000426a1');
select pg_temp.check(pg_temp.seen() = '', 'which nobody reads: ' || pg_temp.seen());
reset role;

-- ---------------------------------------------------------------------------
-- 10. How it is set up: live, and locked down.
-- ---------------------------------------------------------------------------
select pg_temp.check(
  exists (select 1 from pg_publication_tables
           where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ride_live_fixes'),
  'the table is in the realtime publication');
select pg_temp.check(
  (select relrowsecurity from pg_class where oid = 'public.ride_live_fixes'::regclass),
  'row level security is on');
select pg_temp.check(
  not has_table_privilege('anon', 'public.ride_live_fixes', 'select')
  and has_table_privilege('authenticated', 'public.ride_live_fixes', 'select')
  and not has_table_privilege('authenticated', 'public.ride_live_fixes', 'insert')
  and not has_table_privilege('authenticated', 'public.ride_live_fixes', 'update')
  and not has_table_privilege('authenticated', 'public.ride_live_fixes', 'delete'),
  'a signed-in account may only read; a visitor nothing');
select pg_temp.check(
  (select count(*) = 1 and bool_and(cmd = 'SELECT') from pg_policies
    where schemaname = 'public' and tablename = 'ride_live_fixes'),
  'one policy, and it is for reading');
select pg_temp.check(
  not has_function_privilege('anon',
    'public.ride_live_fix(uuid, double precision, double precision, double precision, double precision, double precision, timestamptz)',
    'execute')
  and not has_function_privilege('anon', 'public.ride_live_fix_reader(uuid, uuid)', 'execute'),
  'a visitor who is not signed in can call neither function');

rollback;
