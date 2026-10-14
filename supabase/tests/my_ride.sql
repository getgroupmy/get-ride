-- ============================================================================
-- Regression test for migration 0160: My Ride (favourite drivers, booking to
-- them first, widening dispatch radii).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/my_ride.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000160a1'),  -- rider Aminah
  ('00000000-0000-0000-0000-0000000160a2'),  -- rider Badrul
  ('00000000-0000-0000-0000-0000000160a3'),  -- rider who guesses codes
  ('00000000-0000-0000-0000-0000000160b1'),  -- driver Dan (approved)
  ('00000000-0000-0000-0000-0000000160b2'),  -- driver Eve (approved, nobody's favourite)
  ('00000000-0000-0000-0000-0000000160b3'),  -- driver Fay (blocked)
  ('00000000-0000-0000-0000-0000000160b4')   -- driver Gus (approved, far away)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000160%'
on conflict do nothing;
update public.profiles set name = 'Aminah Binti Abu' where id = '00000000-0000-0000-0000-0000000160a1';
insert into public.partners (auth_user_id, name, phone, status, plate) values
  ('00000000-0000-0000-0000-0000000160b1', 'Dan', '+60110000161', 'approved', 'WXY 1600'),
  ('00000000-0000-0000-0000-0000000160b2', 'Eve', '+60110000162', 'approved', null),
  ('00000000-0000-0000-0000-0000000160b3', 'Fay', '+60110000163', 'blocked', null),
  ('00000000-0000-0000-0000-0000000160b4', 'Gus', '+60110000164', 'approved', null);

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, anon;

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
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

-- Codes, read as the server (the tests below sign in as each party).
create temp table codes as
  select auth_user_id as uid, my_ride_code as code from public.partners
   where auth_user_id::text like '00000000-0000-0000-0000-0000000160%';
grant select on codes to authenticated;

-- 1. Every partner has a code: 8 characters of the unambiguous alphabet, unique.
select pg_temp.check((select bool_and(code ~ '^[2-9A-HJ-NP-Z]{8}$') and count(*) = 4 from codes),
                     'new partners get a code');
select pg_temp.check(not exists (select my_ride_code from public.partners where my_ride_code is not null
                                  group by my_ride_code having count(*) > 1),
                     'codes are unique');
select pg_temp.check(not exists (select 1 from public.partners where my_ride_code is null), 'every partner is backfilled');

-- 2. Clients: no direct writes, and anon can call none of it ----------------------------------
select pg_temp.check(not has_function_privilege('anon', f, 'execute'), 'anon cannot execute ' || f)
  from unnest(array[
    'public.my_ride_code()', 'public.rotate_my_ride_code()', 'public.add_favourite_driver(text)',
    'public.remove_favourite_driver(uuid)', 'public.my_favourite_drivers(double precision, double precision)',
    'public.hide_favourite_rider(uuid, boolean)', 'public.my_favourite_riders()', 'public.my_favourite_rider_ids()',
    'public.ride_request_offer_to_all(uuid)', 'public.ride_request_add_targets(uuid, uuid[])',
    'public.ride_requests_dispatch_tick()'
  ]) f;
select pg_temp.check(not has_function_privilege('authenticated', f, 'execute'), 'clients cannot execute ' || f)
  from unnest(array[
    'public.ride_requests_dispatch_tick()', 'public.ride_request_open_to_all(uuid)', 'public.ride_request_widen(uuid)',
    'public.gen_my_ride_code()', 'public.my_ride_valid_targets(uuid, uuid[], double precision, double precision, double precision)'
  ]) f;
select pg_temp.check(not has_table_privilege('authenticated', 'public.ride_request_pushes', 'select'),
                     'the push log is the server''s');

set local role anon;
select pg_temp.refused($q$select public.add_favourite_driver('ABCDEFGH')$q$, 'anon adding a favourite');
select pg_temp.refused($q$select count(*) from public.favourite_drivers$q$, 'anon reading favourites');
reset role;

set local role authenticated;

-- 3. The driver's own code ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
select pg_temp.check(public.my_ride_code() = (select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'),
                     'my_ride_code() is the caller''s code');
update public.partners set my_ride_code = 'AAAAAAAA' where auth_user_id = '00000000-0000-0000-0000-0000000160b1';
select pg_temp.check(public.my_ride_code() = (select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'),
                     'a driver cannot choose their own code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a3');
select pg_temp.check(public.my_ride_code() is null, 'a rider has no code');
select pg_temp.refused($q$select public.rotate_my_ride_code()$q$, 'a rider rotating a code');

-- Rotating: the old code stops working.
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b4');
select pg_temp.check(public.rotate_my_ride_code() is distinct from
                       (select code from codes where uid = '00000000-0000-0000-0000-0000000160b4'),
                     'rotate gives a new code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a3');
select pg_temp.check(public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b4'))
                       ->>'error' = 'not_found',
                     'the old code no longer finds the driver');

-- 4. Adding by code ------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
select pg_temp.check((public.add_favourite_driver('  ' || lower((select code from codes where uid = '00000000-0000-0000-0000-0000000160b1')) || ' ')
                       #>> '{driver,driver_id}') = '00000000-0000-0000-0000-0000000160b1',
                     'a code is matched case-insensitively, spaces trimmed');
select pg_temp.check((public.add_favourite_driver('getride://myride/' || (select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'))
                       ->>'ok')::boolean,
                     'the QR payload works and adding again is fine');
select pg_temp.check((select count(*) = 1 from public.favourite_drivers), 'adding twice keeps one row');
select pg_temp.check(not (public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'))
                            #> '{driver}' ? 'phone'),
                     'no phone number comes back');
select pg_temp.check(public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'))
                       #>> '{driver,plate}' = 'WXY 1600',
                     'the plate comes back');
select pg_temp.check(public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b3'))
                       ->>'error' = 'unavailable',
                     'a blocked driver cannot be added');
select pg_temp.check(public.add_favourite_driver('O0I1') ->>'error' = 'invalid_code', 'a malformed code');
select pg_temp.refused($q$insert into public.favourite_drivers (rider_id, driver_id)
                          values ('00000000-0000-0000-0000-0000000160a1', '00000000-0000-0000-0000-0000000160b2')$q$,
                       'writing favourites directly');
update public.favourite_drivers set hidden_by_driver = true;  -- matches nothing the rider may write
delete from public.favourite_drivers;
reset role;
select pg_temp.check((select count(*) = 1 and not bool_or(hidden_by_driver) from public.favourite_drivers),
                     'direct updates / deletes change nothing');
set local role authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
select pg_temp.check(public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'))
                       ->>'error' = 'own_code',
                     'a driver cannot favourite themselves');

-- Badrul also has Dan.
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a2');
select public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'));

-- Guessing: 10 misses an hour, then no lookups at all.
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a3');
select public.add_favourite_driver('ZZZZZZZ' || n) from generate_series(2, 9) n;  -- 8 more misses (1 above)
select pg_temp.check(public.add_favourite_driver('ZZZZZZZY')->>'error' = 'not_found', 'the 10th miss');
select pg_temp.check(public.add_favourite_driver((select code from codes where uid = '00000000-0000-0000-0000-0000000160b1'))
                       ->>'error' = 'rate_limited',
                     'after 10 misses even a real code is not looked up');

-- 5. Lists -----------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
select pg_temp.check((select count(*) = 1 and bool_and(available) and min(name) = 'Dan'
                        from public.my_favourite_drivers(null, null)),
                     'the rider''s list');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
select pg_temp.check((select count(*) = 2 from public.my_favourite_riders()), 'the driver sees who added them');
select pg_temp.check((select name = 'Aminah A.' from public.my_favourite_riders()
                       where rider_id = '00000000-0000-0000-0000-0000000160a1'),
                     'rider names are masked');
select pg_temp.check((select count(*) = 2 from public.my_favourite_rider_ids()), 'both riders are starred');

-- 6. A targeted request ------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_name, pickup_lat, pickup_lng, target_driver_ids,
                                  targeted_until, fallback_pushed_at)
values ('00000000-0000-0000-0000-0000000160e1', '00000000-0000-0000-0000-0000000160a1', 'open', 20, 'Car', 'KLCC', 3.1579, 101.7116,
        array['00000000-0000-0000-0000-0000000160b1', '00000000-0000-0000-0000-0000000160b2',
              '00000000-0000-0000-0000-0000000160b3']::uuid[],
        now() + interval '1 day', now());
reset role;
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000160b1']::uuid[]
                             and targeted_until between now() + interval '59 seconds' and now() + interval '61 seconds'
                             and fallback_pushed_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'only the rider''s own favourite stays targeted, for the service''s 60 s');
select pg_temp.check(exists (select 1 from public.ride_request_pushes
                              where request_id = '00000000-0000-0000-0000-0000000160e1'
                                and profile_id = '00000000-0000-0000-0000-0000000160b1' and kind = 'my_ride'),
                     'the favourite is pushed');
select pg_temp.check((select count(*) = 1 from public.ride_request_pushes
                       where request_id = '00000000-0000-0000-0000-0000000160e1'),
                     'nobody else is pushed during the window');
set local role authenticated;

select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'the targeted driver sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b2');
select pg_temp.check(not exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'another driver does not');
-- ...and cannot bid or take it.
update public.ride_requests set offered_fare = 15, partner_id = '00000000-0000-0000-0000-0000000160b2'
 where id = '00000000-0000-0000-0000-0000000160e1' and status = 'open';
select pg_temp.refused($q$update public.ride_requests set offered_fare = 15,
                            partner_id = '00000000-0000-0000-0000-0000000160b2'$q$,
                       'a non-targeted driver bidding during the window');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'
                                                              and partner_id is null and offered_fare is null),
                     'the rider sees it, with no bid on it');
-- The rider cannot stretch the window or retarget it by hand.
update public.ride_requests set targeted_until = now() + interval '1 day',
                                target_driver_ids = array['00000000-0000-0000-0000-0000000160b2']::uuid[]
 where id = '00000000-0000-0000-0000-0000000160e1';
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000160b1']::uuid[]
                             and targeted_until < now() + interval '61 seconds'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'the My Ride columns are the server''s');
-- The rider's own updates still work.
update public.ride_requests set note = 'gate B' where id = '00000000-0000-0000-0000-0000000160e1';
select pg_temp.check((select note = 'gate B' from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'the rider can still update their request');
reset role;
select set_config('request.jwt.claims', '{"role": "anon"}', true), set_config('request.jwt.claim.sub', '', true);
set local role anon;
-- Signed out, nobody sees it (since 0182 the table refuses them outright).
do $$
begin
  if exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1') then
    raise exception 'FAILED: signed out, nobody sees it';
  end if;
exception when insufficient_privilege then
  null;
end $$;
reset role;
set local role authenticated;

-- The targeted driver bids.
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
update public.ride_requests set offered_fare = 18, partner_id = '00000000-0000-0000-0000-0000000160b1'
 where id = '00000000-0000-0000-0000-0000000160e1' and status = 'open';
select pg_temp.check((select offered_fare = 18 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'the targeted driver can bid');

-- 7. "Offer to all nearby" -----------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b2');
select pg_temp.refused($q$select public.ride_request_offer_to_all('00000000-0000-0000-0000-0000000160e1')$q$,
                       'somebody else ending the window');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
select pg_temp.check((public.ride_request_offer_to_all('00000000-0000-0000-0000-0000000160e1')->>'opened')::boolean,
                     'the rider opens it to all');
select pg_temp.check(not (public.ride_request_offer_to_all('00000000-0000-0000-0000-0000000160e1')->>'opened')::boolean,
                     'opening again does nothing');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b2');
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'now every driver sees it');
update public.ride_requests set offered_fare = 17, partner_id = '00000000-0000-0000-0000-0000000160b2'
 where id = '00000000-0000-0000-0000-0000000160e1' and status = 'open';
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000160b2'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'and may bid');
reset role;
select pg_temp.check((select fallback_pushed_at is not null and targeted_until <= now()
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e1'),
                     'the fallback is stamped');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000160e1';

-- 8. The window ends on its own --------------------------------------------------------------------------
-- Eve is online near KLCC, so the fallback push reaches her.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b2');
select public.set_driver_presence(true, 3.1580, 101.7110);
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_name, pickup_lat, pickup_lng, target_driver_ids)
values ('00000000-0000-0000-0000-0000000160e2', '00000000-0000-0000-0000-0000000160a1', 'open', 20, 'Car', 'KLCC', 3.1579, 101.7116,
        array['00000000-0000-0000-0000-0000000160b1']::uuid[]);
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b2');
select pg_temp.check(not exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e2'),
                     'hidden from others during the window');
reset role;
update public.ride_requests set targeted_until = now() - interval '1 second'
 where id = '00000000-0000-0000-0000-0000000160e2';
set local role authenticated;
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e2'),
                     'everybody sees it once the window is over');
reset role;
select pg_temp.check(public.ride_requests_dispatch_tick() >= 1, 'the tick picks it up');
select pg_temp.check((select fallback_pushed_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000160e2'),
                     'the fallback push is stamped');
select pg_temp.check(exists (select 1 from public.ride_request_pushes
                              where request_id = '00000000-0000-0000-0000-0000000160e2'
                                and profile_id = '00000000-0000-0000-0000-0000000160b2' and kind = 'fallback'),
                     'the nearby driver is pushed at the fallback');
select public.ride_requests_dispatch_tick();
select pg_temp.check((select count(*) = 1 from public.ride_request_pushes
                       where request_id = '00000000-0000-0000-0000-0000000160e2'
                         and profile_id = '00000000-0000-0000-0000-0000000160b2'),
                     'nobody is pushed twice');
-- Widening after searchWidenAfterSec: Gus, 10 km out, is told then.
update public.driver_presence set online = true, lat = 3.2479, lng = 101.7116, updated_at = now()
 where profile_id = '00000000-0000-0000-0000-0000000160b4';
insert into public.driver_presence (profile_id, online, lat, lng)
select '00000000-0000-0000-0000-0000000160b4', true, 3.2479, 101.7116
 where not exists (select 1 from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000160b4');
update public.ride_requests set fallback_pushed_at = now() - interval '31 seconds'
 where id = '00000000-0000-0000-0000-0000000160e2';
select public.ride_requests_dispatch_tick();
select pg_temp.check((select widened_pushed_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000160e2'),
                     'widened after 30 s');
select pg_temp.check(exists (select 1 from public.ride_request_pushes
                              where request_id = '00000000-0000-0000-0000-0000000160e2'
                                and profile_id = '00000000-0000-0000-0000-0000000160b4' and kind = 'widened'),
                     'the driver in the wider ring is pushed');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000160e2';

-- 9. Normal requests use the service's radii ---------------------------------------------------------------
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000160e3', '00000000-0000-0000-0000-0000000160a2', 'open', 20, 'Car', 3.1579, 101.7116);
select pg_temp.check((select target_driver_ids is null and targeted_until is null and widened_pushed_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e3'),
                     'a request without targets is not targeted (someone within 3 km)');
select pg_temp.check((select array_agg(profile_id) = array['00000000-0000-0000-0000-0000000160b2']::uuid[]
                        from public.ride_request_pushes where request_id = '00000000-0000-0000-0000-0000000160e3'),
                     'only the driver within the min radius is pushed at first');
update public.ride_requests set created_at = now() - interval '31 seconds'
 where id = '00000000-0000-0000-0000-0000000160e3';
select public.ride_requests_dispatch_tick();
select pg_temp.check((select array_agg(profile_id order by profile_id)
                             = array['00000000-0000-0000-0000-0000000160b2', '00000000-0000-0000-0000-0000000160b4']::uuid[]
                        from public.ride_request_pushes where request_id = '00000000-0000-0000-0000-0000000160e3'),
                     'then the max radius, without repeating');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000160e3';
-- Nobody within the min radius: straight to the max; nobody there either: every driver.
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000160e4', '00000000-0000-0000-0000-0000000160a2', 'open', 20, 'Car', 1.4927, 103.7414);
select pg_temp.check((select widened_pushed_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000160e4'),
                     'nobody near: widened at once');
select pg_temp.check(exists (select 1 from public.ride_request_pushes
                              where request_id = '00000000-0000-0000-0000-0000000160e4' and profile_id is null),
                     'nobody within the max: every driver, as before');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000160e4';

-- 10. The service's own window and distance cap ------------------------------------------------------------
insert into public.settings_entries (category, values)
values ('vehicle-services', '{"name": "Car", "myRideWindowSec": 90, "myRideMaxKm": 5}');
select pg_temp.check((select (c->>'my_ride_window_sec')::int = 90 and (c->>'my_ride_max_km')::numeric = 5
                             and (c->>'search_radius_min_km')::numeric = 3 and (c->>'search_radius_max_km')::numeric = 15
                        from public.vehicle_service_dispatch_config(' car ') c),
                     'the service''s settings, defaults filled in, matched by name');
-- Dan is known to be in Johor: farther than 5 km, so not targeted.
insert into public.driver_presence (profile_id, online, lat, lng)
values ('00000000-0000-0000-0000-0000000160b1', true, 1.4927, 103.7414)
on conflict (profile_id) do update set online = true, lat = 1.4927, lng = 103.7414, updated_at = now();
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng, target_driver_ids, my_ride_max_km)
values ('00000000-0000-0000-0000-0000000160e5', '00000000-0000-0000-0000-0000000160a1', 'open', 20, 'Car', 3.1579, 101.7116,
        array['00000000-0000-0000-0000-0000000160b1']::uuid[], 50);
select pg_temp.check((select target_driver_ids is null and my_ride_max_km = 5
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e5'),
                     'the smaller cap (service 5 km) drops a favourite known to be farther');
-- Within the cap (or position unknown): targeted for the service's 90 s.
reset role;
delete from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000160b1';
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000160e5';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng, target_driver_ids)
values ('00000000-0000-0000-0000-0000000160e6', '00000000-0000-0000-0000-0000000160a1', 'open', 20, 'Car', 3.1579, 101.7116,
        array['00000000-0000-0000-0000-0000000160b1']::uuid[]);
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000160b1']::uuid[]
                             and targeted_until > now() + interval '89 seconds'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e6'),
                     'a favourite whose position is unknown stays targeted, for 90 s');

-- 11. Adding targets while searching -------------------------------------------------------------------------
select pg_temp.check(public.ride_request_add_targets('00000000-0000-0000-0000-0000000160e6',
                       array['00000000-0000-0000-0000-0000000160b2', '00000000-0000-0000-0000-0000000160b1']::uuid[])
                       = array['00000000-0000-0000-0000-0000000160b1']::uuid[],
                     'only the rider''s own favourites are added (Eve is not one)');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a2');
select pg_temp.refused($q$select public.ride_request_add_targets('00000000-0000-0000-0000-0000000160e6',
                            array['00000000-0000-0000-0000-0000000160b1']::uuid[])$q$,
                       'adding targets to somebody else''s request');

-- 12. The driver hides a rider ----------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
select pg_temp.check(public.hide_favourite_rider('00000000-0000-0000-0000-0000000160a1', true), 'Dan hides Aminah');
select pg_temp.check((select array_agg(id) = array['00000000-0000-0000-0000-0000000160a2']::uuid[]
                        from public.my_favourite_rider_ids() id),
                     'a hidden rider is not starred');
reset role;
select pg_temp.check((select target_driver_ids is null and fallback_pushed_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e6'),
                     'hiding takes the driver off her open request, which opens to all');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000160e6';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng, target_driver_ids)
values ('00000000-0000-0000-0000-0000000160e7', '00000000-0000-0000-0000-0000000160a1', 'open', 20, 'Car', 3.1579, 101.7116,
        array['00000000-0000-0000-0000-0000000160b1']::uuid[]);
select pg_temp.check((select target_driver_ids is null and targeted_until is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000160e7'),
                     'a hidden rider cannot target the driver');
select pg_temp.check(coalesce(cardinality(public.ride_request_add_targets('00000000-0000-0000-0000-0000000160e7',
                       array['00000000-0000-0000-0000-0000000160b1']::uuid[])), 0) = 0,
                     'nor add them while searching');
select pg_temp.check((select not available and not online and distance_km is null
                        from public.my_favourite_drivers(3.1579, 101.7116)),
                     'she sees him only as unavailable');
select pg_temp.check(not exists (select 1 from public.favourite_drivers), 'a hidden row is not in her direct reads');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160b1');
select pg_temp.check(public.hide_favourite_rider('00000000-0000-0000-0000-0000000160a1', false), 'Dan shows her again');
select pg_temp.as_user('00000000-0000-0000-0000-0000000160a1');
select pg_temp.check((select available from public.my_favourite_drivers(null, null)), 'available again');

-- 13. Removing --------------------------------------------------------------------------------------------------
select pg_temp.check(public.remove_favourite_driver('00000000-0000-0000-0000-0000000160b1'), 'Aminah removes Dan');
select pg_temp.check(not exists (select 1 from public.my_favourite_drivers(null, null)), 'gone from her list');

reset role;

rollback;

select 'my_ride: all passed';
