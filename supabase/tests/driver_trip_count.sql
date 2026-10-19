-- ============================================================================
-- Regression test for migration 0237: the driver's completed trips
-- (partners.total_rides) are backfilled, counted once per completion, and
-- stamped on the ride as partner_trips, which only the server writes.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_trip_count.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000237a1'),  -- rider
  ('00000000-0000-0000-0000-0000000237b1'),  -- driver Dina (approved)
  ('00000000-0000-0000-0000-0000000237b2')   -- driver Eli (approved)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000237%'
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, rating, status) values
  ('00000000-0000-0000-0000-0000000237d1', '00000000-0000-0000-0000-0000000237b1', 'Dina', '+60110000237', 4.8, 'approved'),
  ('00000000-0000-0000-0000-0000000237d2', '00000000-0000-0000-0000-0000000237b2', 'Eli', '+60110000238', 4.5, 'approved');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to anon, authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to anon, authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;

create or replace function pg_temp.trips(p uuid) returns integer language sql as $$
  select total_rides from public.partners where auth_user_id = p;
$$;
grant execute on function pg_temp.trips(uuid) to anon, authenticated;

-- 1. The backfill ------------------------------------------------------------------------
-- Rides from before 0237: completed with the counter off, and the counts stale.
alter table public.ride_requests disable trigger trg_ride_requests_count_trips;
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000237e1', '00000000-0000-0000-0000-0000000237a1', '00000000-0000-0000-0000-0000000237b1', 'completed', 20, 20),
  ('00000000-0000-0000-0000-0000000237e2', '00000000-0000-0000-0000-0000000237a1', '00000000-0000-0000-0000-0000000237b1', 'completed', 20, 20),
  ('00000000-0000-0000-0000-0000000237e3', '00000000-0000-0000-0000-0000000237a1', '00000000-0000-0000-0000-0000000237b1', 'cancelled', 20, 20),
  ('00000000-0000-0000-0000-0000000237e4', '00000000-0000-0000-0000-0000000237a1', '00000000-0000-0000-0000-0000000237b2', 'completed', 20, 20);
alter table public.ride_requests enable trigger trg_ride_requests_count_trips;
update public.partners set total_rides = 0 where id = '00000000-0000-0000-0000-0000000237d1';
update public.partners set total_rides = 7 where id = '00000000-0000-0000-0000-0000000237d2';

select public.partner_trips_recount();
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b1') = 2, 'backfill: Dina has her 2 completed trips');
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b2') = 1, 'backfill: Eli has his 1, not the stale 7');
select pg_temp.check(public.partner_trips_recount() = 0, 'the recount is idempotent');
select pg_temp.check(not has_function_privilege('authenticated', 'public.partner_trips_recount()', 'execute'),
                     'clients can''t run the recount');

-- 2. An open ride: Dina bids, and the card carries her count ------------------------------
insert into public.ride_requests (id, rider_id, status, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000237e5', '00000000-0000-0000-0000-0000000237a1', 'open', 20, 20);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000237b1');
select pg_temp.check((select trips = 2 from public.ride_partner_card('00000000-0000-0000-0000-0000000237b1')),
                     'the driver''s card has her trips');
update public.ride_requests
   set offered_fare = 25, partner_id = '00000000-0000-0000-0000-0000000237b1', partner_trips = 9999, partner_rating = 5
 where id = '00000000-0000-0000-0000-0000000237e5' and status = 'open';
select pg_temp.check((select partner_trips = 2 and partner_rating = 4.8
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e5'),
                     'the offer is stamped with her real count, not the one she sent');
update public.ride_requests set partner_trips = 9999 where id = '00000000-0000-0000-0000-0000000237e5';
select pg_temp.check((select partner_trips = 2 from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e5'),
                     'the driver can''t rewrite it');
select pg_temp.refused(
  $q$update public.partners set total_rides = 1000 where auth_user_id = '00000000-0000-0000-0000-0000000237b1'$q$,
  'a driver writing their own trip count');

-- 3. The rider can't forge it ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000237a1');
update public.ride_requests set partner_trips = 5000 where id = '00000000-0000-0000-0000-0000000237e5';
select pg_temp.check((select partner_trips = 2 from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e5'),
                     'the rider can''t rewrite it');
-- Declining the bid clears it with the rest of the card.
update public.ride_requests
   set offered_fare = null, partner_id = null, partner_name = null, partner_rating = null, partner_trips = null
 where id = '00000000-0000-0000-0000-0000000237e5';
select pg_temp.check((select partner_id is null and partner_trips is null and partner_rating is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e5'),
                     'declining the bid clears the count');
update public.ride_requests set partner_trips = 5000 where id = '00000000-0000-0000-0000-0000000237e5';
select pg_temp.check((select partner_trips is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e5'),
                     'no count on a ride without a driver');
reset role;

-- 4. Completing a trip counts it, once --------------------------------------------------------
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, started_at) values
  ('00000000-0000-0000-0000-0000000237e6', '00000000-0000-0000-0000-0000000237a1', '00000000-0000-0000-0000-0000000237b1',
   'on_trip', 20, 20, now() - interval '20 minutes');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000237b1');
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000237e6';
reset role;
select pg_temp.check((select status = 'completed' from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e6'),
                     'the driver ended the trip');
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b1') = 3, 'completing the trip counts it');

-- Writing the completed ride again, or its status again, doesn't.
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000237e6';
update public.ride_requests set note = 'thanks' where id = '00000000-0000-0000-0000-0000000237e6';
update public.ride_requests set payment_status = 'paid' where id = '00000000-0000-0000-0000-0000000237e6';
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b1') = 3, 'no double count');
select pg_temp.check(public.partner_trips_recount() = 0, 'the running count matches a recount');

-- A completed ride taken off completed (only the server or an admin can) comes off the count,
-- and one moved to another driver moves with it.
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000237e6';
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b1') = 2, 'leaving completed takes it off');
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000237e6';
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b1') = 3, 'completed again counts again');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000237b2' where id = '00000000-0000-0000-0000-0000000237e6';
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b1') = 2
                     and pg_temp.trips('00000000-0000-0000-0000-0000000237b2') = 2, 'a re-credited trip moves');
delete from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e6';
select pg_temp.check(pg_temp.trips('00000000-0000-0000-0000-0000000237b2') = 1, 'a deleted trip comes off');
select pg_temp.check(public.partner_trips_recount() = 0, 'still matches a recount');

-- 5. The next offer carries the new count ------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000237b2');
update public.ride_requests
   set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000237b2'
 where id = '00000000-0000-0000-0000-0000000237e5' and status = 'open';
reset role;
select pg_temp.check((select partner_trips = 1 and status = 'accepted'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000237e5'),
                     'taking a ride stamps the driver''s count');

-- 6. The other places partner_rating is stamped carry it too ------------------------------------
select pg_temp.check((select count(*) = 4 and bool_and(prosrc like '%partner_trips%') from pg_proc
                       where pronamespace = 'public'::regnamespace
                         and proname in ('ride_requests_guard_sides', 'scheduled_ride_release',
                                         'ride_requests_scheduled_reopen', 'trip_handover_accept')),
  'release, reopen and handover stamp or clear the count');
select pg_temp.check((select prosrc like '%driver_credit_assert%' from pg_proc
                       where pronamespace = 'public'::regnamespace and proname = 'trip_handover_accept'),
  'the handover keeps 0223''s GET.credit check');

select 'driver_trip_count: all passed';
rollback;
