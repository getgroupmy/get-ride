-- ============================================================================
-- Regression test for migration 0341: the mid-ride drop-off change (driver
-- check corrected in 0428; answered only while the ride is under way, 0431;
-- the ride read under its row lock, 0432).
--   * A change within the admin's threshold applies at once; a dearer one is
--     held for the driver.
--   * The ride's driver accepts a held change (the drop and the fare change)
--     or declines it (the ride stays as booked), and nobody else answers for
--     them: not the rider, not a stranger, not another driver.
--   * The driver of a ride is ride_requests.partner_id = the driver's own
--     account id (their auth uid), as the app writes it when a ride is taken.
--     It is never a partners.id: 0341 looked the driver up by that, which no
--     real ride holds, so the driver's own answer was refused (0428).
--   * With nothing held there is nothing to answer.
--   * A held change is answered only while the ride is under way, the rule the
--     request already has: once the ride is completed or cancelled, its
--     driver's accept and decline are refused with not_ongoing and the ride is
--     left as it is (0431).
--   * The request and the answer both read the ride under its row lock, so its
--     status cannot change between the check and the write (0432). One
--     transaction cannot show two calls overlapping, so this file checks that
--     each function reads the ride for update.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/drop_change_0341.sql
--
-- Runs in one transaction and is rolled back. Made-up people only. A failed
-- assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000341a1'),  -- rider
  ('00000000-0000-0000-0000-0000000341b1'),  -- driver, on the rides
  ('00000000-0000-0000-0000-0000000341b2'),  -- another driver, on none of them
  ('00000000-0000-0000-0000-0000000341c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000341%'
on conflict do nothing;

-- The driver's partner row. Its id (…0341d1) is not the driver's account id
-- (…0341b1), as for every real partner. The other driver's partner row has the
-- rides' partner_id as its id, the id 0341 looked up: on 0341's check that made
-- them the rides' driver. They are on none of these rides.
insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000341d1', '00000000-0000-0000-0000-0000000341b1', 'Test Driver 0341', '+60100003411',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000341b1', '00000000-0000-0000-0000-0000000341b2', 'Other Driver 0341', '+60100003412',
   'approved', '{Ride}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;

-- The admin's rules, as shipped: a dearer drop applies at once when it adds no
-- more than RM 3 or 15 % of the fare, whichever is more.
insert into public.app_settings (key, value) values
  ('drop_change_rules', '{"allow": true, "autoApproveCheaper": true, "autoApproveRm": 3, "autoApprovePct": 15,
                          "responseWindowSec": 30, "maxChangesPerRide": 2}')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- Five rides under way, booked to Mid Valley at 20.00. Each carries the
-- driver's account id in partner_id, as a ride the app has taken does. The
-- first three stay on the trip. The last two end with a change still held
-- (section 7): one is on the trip and is completed, the other is cancelled
-- with the driver still on the way.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  drop_name, drop_address, drop_lat, drop_lng, distance_km, duration_min) values
  ('00000000-0000-0000-0000-0000000341e1', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20),
  ('00000000-0000-0000-0000-0000000341e2', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20),
  ('00000000-0000-0000-0000-0000000341e3', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20),
  ('00000000-0000-0000-0000-0000000341e4', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'on_trip', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20),
  ('00000000-0000-0000-0000-0000000341e5', '00000000-0000-0000-0000-0000000341a1',
   '00000000-0000-0000-0000-0000000341b1', 'accepted', 20, 20, 'KLCC',
   'Mid Valley', 'Lingkaran Syed Putra, Kuala Lumpur', 3.1177, 101.6774, 8.0, 20)
on conflict (id) do nothing;

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

-- The call must be refused, and with this error.
create or replace function pg_temp.refused(p_sql text, p_error text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm = p_error then
      return;
    end if;
    raise exception 'FAILED: % raised "%", not "%"', p_what, sqlerrm, p_error;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text, text) to authenticated;

-- 0. The rides above are the driver's as the app itself sees them -----------------------------------
-- Signed in, the driver reads the rides that carry their account id; the other
-- driver reads none of them. A fixture with the wrong id in partner_id fails
-- here, whatever the functions under test do with it.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check((select count(*) = 5 from public.ride_requests
                       where id::text like '00000000-0000-0000-0000-0000000341e%'),
  'signed in, the driver reads the rides that carry their account id');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b2');
select pg_temp.check((select count(*) = 0 from public.ride_requests
                       where id::text like '00000000-0000-0000-0000-0000000341e%'),
  'the other driver reads none of them: to the app they are not theirs');

-- 1. A change within the threshold applies at once --------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e1', 'Bangsar Village',
                                  'Jalan Telawi 1, Kuala Lumpur', 3.1302, 101.6712, 9.5, 24, 22)
    = '{"applied": true, "pending": false, "fare": 22}'::jsonb,
  'RM 2 more on a RM 20 ride is within the threshold: applied at once');
reset role;
select pg_temp.check((select drop_name = 'Bangsar Village' and drop_address = 'Jalan Telawi 1, Kuala Lumpur'
                         and drop_lat = 3.1302 and drop_lng = 101.6712
                         and distance_km = 9.5 and duration_min = 24
                         and ride_fare = 22 and fare = 20
                         and drop_change_count = 1
                         and drop_change_requested_at is null and drop_change_fare is null
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'auto'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e1'),
  'the ride goes to the new drop at the new fare, accepted by the rules, with nothing left waiting');

-- 2. A dearer one is held for the driver ------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e2', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'RM 15 more is over the threshold: held for the driver');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e3', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'and held on the other ride');
reset role;
select pg_temp.check((select count(*) = 2 from public.ride_requests
                       where id in ('00000000-0000-0000-0000-0000000341e2', '00000000-0000-0000-0000-0000000341e3')
                         and drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
                         and drop_lat = 3.1177 and drop_lng = 101.6774
                         and distance_km = 8.0 and duration_min = 20
                         and ride_fare = 20 and fare = 20
                         and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
                         and drop_change_name = 'Sunway Pyramid'
                         and drop_change_address = 'Jalan PJS 11/15, Subang Jaya'
                         and drop_change_lat = 3.0733 and drop_change_lng = 101.6078
                         and drop_change_distance_km = 21.5 and drop_change_duration_min = 38
                         and drop_change_fare = 35
                         and drop_change_outcome is null and drop_change_outcome_by is null
                         and drop_change_outcome_at is null),
  'a held change leaves the ride as booked, with the drop and fare asked for kept beside it');

-- 3. The ride's driver accepts ----------------------------------------------------------------------
-- The driver is the ride's partner_id, their account id (0428). On 0341's check
-- (partner_id = a partners.id) this call was refused with not_authorized.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e2', true) = '{"accepted": true}'::jsonb,
  'the ride''s driver accepts the held change');
reset role;
select pg_temp.check((select drop_name = 'Sunway Pyramid' and drop_address = 'Jalan PJS 11/15, Subang Jaya'
                         and drop_lat = 3.0733 and drop_lng = 101.6078
                         and distance_km = 21.5 and duration_min = 38
                         and ride_fare = 35 and fare = 20
                         and drop_change_count = 1
                         and drop_change_requested_at is null and drop_change_requested_by is null
                         and drop_change_name is null and drop_change_address is null
                         and drop_change_lat is null and drop_change_lng is null
                         and drop_change_distance_km is null and drop_change_duration_min is null
                         and drop_change_fare is null
                         and drop_change_outcome = 'accepted' and drop_change_outcome_by = 'partner'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e2'),
  'accepted: the ride goes to the new drop at the new fare, and the answer is recorded as the driver''s');

-- 4. Nobody else answers for the driver -------------------------------------------------------------
-- On the ride still waiting. The other driver's partners.id is the ride's
-- partner_id: 0341's check took them for the ride's driver.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'not_authorized', 'the rider accepting their own change');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false)$q$,
                       'not_authorized', 'the rider declining for the driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'not_authorized', 'a stranger accepting the change');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false)$q$,
                       'not_authorized', 'a stranger declining the change');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b2');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'not_authorized', 'a driver whose partners.id is the ride''s partner_id accepting the change');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false)$q$,
                       'not_authorized', 'a driver whose partners.id is the ride''s partner_id declining the change');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and ride_fare = 20 and drop_change_count = 0
                         and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
                         and drop_change_name = 'Sunway Pyramid' and drop_change_fare = 35
                         and drop_change_outcome is null and drop_change_outcome_by is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e3'),
  'the refused answers changed nothing: the change is still waiting for the driver');

-- 5. The ride's driver declines ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.check(
  public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', false) = '{"accepted": false}'::jsonb,
  'the ride''s driver declines the held change');
reset role;
select pg_temp.check((select drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
                         and drop_lat = 3.1177 and drop_lng = 101.6774
                         and distance_km = 8.0 and duration_min = 20
                         and ride_fare = 20 and fare = 20
                         and drop_change_count = 0
                         and drop_change_requested_at is null and drop_change_requested_by is null
                         and drop_change_name is null and drop_change_address is null
                         and drop_change_lat is null and drop_change_lng is null
                         and drop_change_distance_km is null and drop_change_duration_min is null
                         and drop_change_fare is null
                         and drop_change_outcome = 'declined' and drop_change_outcome_by = 'partner'
                         and drop_change_outcome_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000341e3'),
  'declined: the ride stays as booked, and the answer is recorded as the driver''s');

-- 6. With nothing held there is nothing to answer ---------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e1', true)$q$,
                       'no_pending', 'answering a change that was applied at once');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e2', true)$q$,
                       'no_pending', 'accepting a change a second time');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e3', true)$q$,
                       'no_pending', 'accepting a change that was declined');
reset role;
select pg_temp.check((select count(*) = 3 from public.ride_requests
                       where (id = '00000000-0000-0000-0000-0000000341e1' and ride_fare = 22 and drop_change_count = 1)
                          or (id = '00000000-0000-0000-0000-0000000341e2' and ride_fare = 35 and drop_change_count = 1)
                          or (id = '00000000-0000-0000-0000-0000000341e3' and ride_fare = 20 and drop_change_count = 0)),
  'and the rides are left as they were');

-- 7. Once the ride is no longer under way, a held change is not answered ----------------------------
-- The request is taken only while the ride is accepted, arrived or on_trip
-- (ride_drop_change_request, not_ongoing otherwise), and the answer has the
-- same rule (0431). A change is held on each of the last two rides; the ride
-- then ends the way the app ends it, signed in as its driver.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e4', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'a dearer drop is held on a ride that is on the trip');
select pg_temp.check(
  public.ride_drop_change_request('00000000-0000-0000-0000-0000000341e5', 'Sunway Pyramid',
                                  'Jalan PJS 11/15, Subang Jaya', 3.0733, 101.6078, 21.5, 38, 35)
    = '{"applied": false, "pending": true, "fare": 35}'::jsonb,
  'and on a ride whose driver is still on the way');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
update public.ride_requests set status = 'completed', completed_at = now()
 where id = '00000000-0000-0000-0000-0000000341e4';
update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_reason = 'vehicle_issue',
                                cancel_requested_by = 'partner', cancel_requested_at = now()
 where id = '00000000-0000-0000-0000-0000000341e5' and status in ('accepted', 'arrived');
reset role;

-- The two rides once they have ended: as booked, with the drop and fare asked
-- for still held beside them and no answer recorded.
create or replace function pg_temp.ended_with_change_held() returns boolean language sql as $$
  select count(*) = 2 from public.ride_requests
   where ((id = '00000000-0000-0000-0000-0000000341e4' and status = 'completed')
       or (id = '00000000-0000-0000-0000-0000000341e5' and status = 'cancelled'))
     and drop_name = 'Mid Valley' and drop_address = 'Lingkaran Syed Putra, Kuala Lumpur'
     and drop_lat = 3.1177 and drop_lng = 101.6774
     and distance_km = 8.0 and duration_min = 20
     and ride_fare = 20 and fare = 20
     and drop_change_count = 0
     and drop_change_requested_at is not null and drop_change_requested_by = 'rider'
     and drop_change_name = 'Sunway Pyramid'
     and drop_change_address = 'Jalan PJS 11/15, Subang Jaya'
     and drop_change_lat = 3.0733 and drop_change_lng = 101.6078
     and drop_change_distance_km = 21.5 and drop_change_duration_min = 38
     and drop_change_fare = 35
     and drop_change_outcome is null and drop_change_outcome_by is null
     and drop_change_outcome_at is null
$$;
select pg_temp.check(pg_temp.ended_with_change_held(),
  'one ride is completed and one cancelled, each as booked with its change still held');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000341b1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e4', true)$q$,
                       'not_ongoing', 'the ride''s driver accepting a held change after the ride was completed');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e4', false)$q$,
                       'not_ongoing', 'the ride''s driver declining a held change after the ride was completed');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e5', true)$q$,
                       'not_ongoing', 'the ride''s driver accepting a held change after the ride was cancelled');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e5', false)$q$,
                       'not_ongoing', 'the ride''s driver declining a held change after the ride was cancelled');
-- Anybody else is still told only that the ride is not theirs to answer for.
select pg_temp.as_user('00000000-0000-0000-0000-0000000341a1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e4', true)$q$,
                       'not_authorized', 'the rider accepting their own change after the ride was completed');
select pg_temp.as_user('00000000-0000-0000-0000-0000000341c1');
select pg_temp.refused($q$select public.ride_drop_change_resolve('00000000-0000-0000-0000-0000000341e5', false)$q$,
                       'not_authorized', 'a stranger declining the change after the ride was cancelled');
reset role;
select pg_temp.check(pg_temp.ended_with_change_held(),
  'the refused answers changed nothing: the fare, the drop and the held change are as they were');

-- 8. Still for signed-in callers only, as 0341 granted it -------------------------------------------
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_resolve(uuid, boolean)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_resolve(uuid, boolean)', 'execute'),
  'ride_drop_change_resolve is open to signed-in callers and not to anon');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=""']
                        from pg_proc p
                       where p.oid = 'public.ride_drop_change_resolve(uuid, boolean)'::regprocedure),
  'ride_drop_change_resolve is security definer with an empty search_path');
-- And the request, recreated in 0432.
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)', 'execute')
  and not has_function_privilege('anon', 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)', 'execute'),
  'ride_drop_change_request is open to signed-in callers and not to anon');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=""']
                        from pg_proc p
                       where p.oid = 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)'::regprocedure),
  'ride_drop_change_request is security definer with an empty search_path');

-- 9. Both functions read the ride under its row lock (0432) -----------------------------------------
-- Each reads the ride, checks the caller and the ride's status, and then
-- writes to the ride. The read is "for update", so the status cannot change
-- between the check and the write. One transaction cannot show two calls
-- overlapping, so this looks at the functions as they are stored: a later
-- migration that recreates one of them from its body has to keep the lock.
select pg_temp.check(
  (select p.prosrc ~* 'from\s+public\.ride_requests\s+where\s+id\s*=\s*p_ride\s+for\s+update\s*;'
     from pg_proc p
    where p.oid = 'public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric)'::regprocedure),
  'ride_drop_change_request reads the ride for update');
select pg_temp.check(
  (select p.prosrc ~* 'from\s+public\.ride_requests\s+where\s+id\s*=\s*p_ride\s+for\s+update\s*;'
     from pg_proc p
    where p.oid = 'public.ride_drop_change_resolve(uuid, boolean)'::regprocedure),
  'ride_drop_change_resolve reads the ride for update');

rollback;

select 'drop_change_0341: all passed';
