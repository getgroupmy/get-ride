-- ============================================================================
-- Regression test for migration 0159: post-trip star ratings.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_ratings.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000159a1'),  -- rider
  ('00000000-0000-0000-0000-0000000159a2'),  -- another rider
  ('00000000-0000-0000-0000-0000000159b1'),  -- driver
  ('00000000-0000-0000-0000-0000000159c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000159%'
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000000159b1', 'Dan', '+60110000159');

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

-- e1, e2: completed rides with Dan (one per rider); e3: still on the trip;
-- e4: completed 8 days ago.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name, completed_at) values
  ('00000000-0000-0000-0000-0000000159e1', '00000000-0000-0000-0000-0000000159a1',
   '00000000-0000-0000-0000-0000000159b1', 'completed', 20, 20, 'KLCC', now()),
  ('00000000-0000-0000-0000-0000000159e2', '00000000-0000-0000-0000-0000000159a2',
   '00000000-0000-0000-0000-0000000159b1', 'completed', 20, 20, 'Mid Valley', now()),
  ('00000000-0000-0000-0000-0000000159e3', '00000000-0000-0000-0000-0000000159a1',
   '00000000-0000-0000-0000-0000000159b1', 'on_trip', 20, 20, 'Bangsar', null),
  ('00000000-0000-0000-0000-0000000159e4', '00000000-0000-0000-0000-0000000159a1',
   '00000000-0000-0000-0000-0000000159b1', 'completed', 20, 20, 'Old', now() - interval '8 days');

-- Nobody signed out can rate, and the table is read-only to clients.
select pg_temp.check(not has_function_privilege('anon', 'public.rate_ride(uuid, integer, text)', 'execute'),
                     'anon cannot execute rate_ride');
select pg_temp.check(has_function_privilege('authenticated', 'public.rate_ride(uuid, integer, text)', 'execute'),
                     'a signed-in account can');
select pg_temp.check(not has_table_privilege('authenticated', 'public.ride_ratings', 'insert')
                       and not has_table_privilege('authenticated', 'public.ride_ratings', 'update')
                       and not has_table_privilege('anon', 'public.ride_ratings', 'select'),
                     'writes only go through rate_ride');

set local role authenticated;

-- 1. The passenger rates a completed ride --------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000159a1');
select pg_temp.check((public.rate_ride('00000000-0000-0000-0000-0000000159e1', 4, '  Smooth drive  ')->>'stars')::int = 4,
                     'the passenger rates a completed ride');
select pg_temp.check((select stars = 4 and comment = 'Smooth drive' and partner_id = '00000000-0000-0000-0000-0000000159b1'
                        from public.ride_ratings where request_id = '00000000-0000-0000-0000-0000000159e1'),
                     'stored with the trimmed comment, against the ride''s own driver');

-- 2. Rating again changes it, still one row ---------------------------------------------------
select public.rate_ride('00000000-0000-0000-0000-0000000159e1', 5, '');
select pg_temp.check((select count(*) = 1 and min(stars) = 5 and bool_and(comment is null)
                        from public.ride_ratings where request_id = '00000000-0000-0000-0000-0000000159e1'),
                     're-rating updates the one rating (an empty comment clears it)');

-- 3. Refusals --------------------------------------------------------------------------------
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e3', 5, null)$q$,
                       'rating a ride that is not completed');
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e4', 5, null)$q$,
                       'rating a ride after the 7-day window');
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e1', 0, null)$q$, '0 stars');
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e1', 6, null)$q$, '6 stars');
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e1', null, null)$q$, 'no stars');
select pg_temp.refused($q$insert into public.ride_ratings (request_id, rater_id, partner_id, stars)
                          values ('00000000-0000-0000-0000-0000000159e2', '00000000-0000-0000-0000-0000000159a1',
                                  '00000000-0000-0000-0000-0000000159b1', 5)$q$,
                       'writing the table directly');

select pg_temp.as_user('00000000-0000-0000-0000-0000000159b1');
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e1', 1, null)$q$,
                       'the driver rating the passenger''s ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000000159c1');
select pg_temp.refused($q$select public.rate_ride('00000000-0000-0000-0000-0000000159e1', 1, null)$q$,
                       'somebody else rating the ride');
select pg_temp.check(not exists (select 1 from public.ride_ratings), 'somebody else sees no ratings');

-- 4. The average follows -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000159a2');
select pg_temp.check((public.rate_ride('00000000-0000-0000-0000-0000000159e2', 2, null)->>'partner_rating')::numeric = 3.5,
                     'the second rating brings the average to (5 + 2) / 2');
select pg_temp.check((select count(*) = 1 from public.ride_ratings), 'a passenger sees only their own rating');

select pg_temp.as_user('00000000-0000-0000-0000-0000000159b1');
select pg_temp.check((select count(*) = 2 from public.ride_ratings), 'the driver sees the ratings about them');

reset role;
select pg_temp.check((select rating = 3.50 from public.partners
                       where auth_user_id = '00000000-0000-0000-0000-0000000159b1'),
                     'the driver''s average is on partners.rating');

rollback;

select 'ride_ratings: all passed';
