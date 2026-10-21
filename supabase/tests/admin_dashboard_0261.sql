-- ============================================================================
-- Regression test for migration 0261: the admin dashboard. Only an admin who
-- may view the dashboard reads it; the period figures add the fixtures up in
-- hourly and daily buckets, for the period and the one before; the funnel
-- narrows in order; the live panel counts what is happening now.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/admin_dashboard_0261.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.admin_dashboard_summary(timestamptz, timestamptz, timestamptz, timestamptz, text)', 'execute')
     or has_function_privilege('anon', 'public.admin_dashboard_live()', 'execute')
     or has_function_privilege('authenticated', 'public.admin_dashboard_period(timestamptz, timestamptz, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_dashboard_summary(timestamptz, timestamptz, timestamptz, timestamptz, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_dashboard_live()', 'execute') then
    raise exception 'FAILED: dashboard function grants';
  end if;
end
$$;

-- What the live panel and "needs attention" counted before the fixtures.
create temp table base0261 as
select public.admin_dashboard_live() as live,
       (public.admin_dashboard_summary('2021-03-10 00:00+08', '2021-03-11 00:00+08',
                                       '2021-03-09 00:00+08', '2021-03-10 00:00+08', 'hour')) -> 'attention' as attention;
grant select on base0261 to authenticated;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000261a1', '60126100001'),  -- full admin
  ('00000000-0000-0000-0000-0000000261a2', '60126100002'),  -- sub-admin: read on the Dashboard
  ('00000000-0000-0000-0000-0000000261a3', '60126100003'),  -- sub-admin: another page
  ('00000000-0000-0000-0000-0000000261b1', '60126100011'),  -- riders
  ('00000000-0000-0000-0000-0000000261b2', '60126100012'),
  ('00000000-0000-0000-0000-0000000261b3', '60126100013'),
  ('00000000-0000-0000-0000-0000000261b4', '60126100014'),
  ('00000000-0000-0000-0000-0000000261d1', '60126100021'),  -- drivers
  ('00000000-0000-0000-0000-0000000261d2', '60126100022'),
  ('00000000-0000-0000-0000-0000000261d3', '60126100023')
on conflict do nothing;
insert into public.profiles (id, name) select id, 'P' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000261%'
on conflict (id) do update set name = excluded.name;
-- One new rider in the period (10 March 2021, Malaysia), one the day before.
update public.profiles set created_at = '2021-03-10 08:00+08' where id = '00000000-0000-0000-0000-0000000261b1';
update public.profiles set created_at = '2021-03-09 08:00+08' where id = '00000000-0000-0000-0000-0000000261b2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000261a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000261a2', 'admin-dashboard', 'read'),
  ('00000000-0000-0000-0000-0000000261a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status, rating, display_id, created_at) values
  ('00000000-0000-0000-0000-0000000261e1', '00000000-0000-0000-0000-0000000261d1', 'Ahmad', '60126100021', 'approved', 4.9, 'D-2611', '2020-01-01 00:00+08'),
  ('00000000-0000-0000-0000-0000000261e2', '00000000-0000-0000-0000-0000000261d2', 'Siti', '60126100022', 'approved', 4.7, 'D-2612', '2021-03-10 10:00+08'),
  ('00000000-0000-0000-0000-0000000261e3', '00000000-0000-0000-0000-0000000261d3', 'Wong', '60126100023', 'unapproved', 0, 'D-2613', '2020-01-01 00:00+08');
insert into public.airport_areas (id, values, position, active, kind) values
  ('00000000-0000-0000-0000-0000000261f1', '{"name": "KLIA T1 261"}', 0, true, 'airport');

-- The period: 10 March 2021 (Malaysia). The one before: 9 March.
--   r1 Ahmad, Ride, cash, 20, Petaling Jaya, 09:00-09:30, rated 5
--   r2 Ahmad, Comfort, Get Pay, final fare 30 (25 asked), Kuala Lumpur, 09:10-09:50
--   r3 Siti, Ride, cash, 10, "petaling jaya", from the airport, 18:00-18:20, rated 4
--   r4 taken at 12:01, then cancelled by the driver
--   r5 cancelled by the rider before anyone took it
--   r6 expired, but a driver had it on screen
--   p1 (9 March) Ahmad, Ride, cash, 15, Petaling Jaya;  p2 (9 March) cancelled by the rider
insert into public.ride_requests (id, rider_id, partner_id, status, service, payment_mode, fare, ride_fare, commission_amount,
    suburb, city, airport_pickup_id, cancel_requested_by,
    created_at, accepted_at, arrived_at, started_at, completed_at) values
  ('00000000-0000-0000-0000-000000026101', '00000000-0000-0000-0000-0000000261b1', '00000000-0000-0000-0000-0000000261d1',
   'completed', 'Ride', 'Cash', 20, 20, 2, 'Petaling Jaya', 'Petaling Jaya', null, null,
   '2021-03-10 09:00+08', '2021-03-10 09:01+08', '2021-03-10 09:05+08', '2021-03-10 09:06+08', '2021-03-10 09:30+08'),
  ('00000000-0000-0000-0000-000000026102', '00000000-0000-0000-0000-0000000261b2', '00000000-0000-0000-0000-0000000261d1',
   'completed', 'Comfort', 'Get Pay', 25, 30, 3, null, 'Kuala Lumpur', null, null,
   '2021-03-10 09:10+08', '2021-03-10 09:11+08', '2021-03-10 09:20+08', '2021-03-10 09:21+08', '2021-03-10 09:50+08'),
  ('00000000-0000-0000-0000-000000026103', '00000000-0000-0000-0000-0000000261b1', '00000000-0000-0000-0000-0000000261d2',
   'completed', 'Ride', 'Cash', 10, null, 1, 'petaling jaya', 'Petaling Jaya', '00000000-0000-0000-0000-0000000261f1', null,
   '2021-03-10 18:00+08', '2021-03-10 18:02+08', '2021-03-10 18:05+08', '2021-03-10 18:06+08', '2021-03-10 18:20+08'),
  ('00000000-0000-0000-0000-000000026104', '00000000-0000-0000-0000-0000000261b3', '00000000-0000-0000-0000-0000000261d2',
   'cancelled', 'Ride', 'Cash', 12, 12, null, null, null, null, 'partner',
   '2021-03-10 12:00+08', '2021-03-10 12:01+08', null, null, null),
  ('00000000-0000-0000-0000-000000026105', '00000000-0000-0000-0000-0000000261b4', null,
   'cancelled', 'Ride', 'Cash', 12, 12, null, null, null, null, null,
   '2021-03-10 12:30+08', null, null, null, null),
  ('00000000-0000-0000-0000-000000026106', '00000000-0000-0000-0000-0000000261b4', null,
   'expired', 'Ride', 'Cash', 12, 12, null, null, null, null, null,
   '2021-03-10 13:00+08', null, null, null, null),
  ('00000000-0000-0000-0000-000000026111', '00000000-0000-0000-0000-0000000261b1', '00000000-0000-0000-0000-0000000261d1',
   'completed', 'Ride', 'Cash', 15, 15, 1.5, 'Petaling Jaya', 'Petaling Jaya', null, null,
   '2021-03-09 10:00+08', '2021-03-09 10:01+08', '2021-03-09 10:05+08', '2021-03-09 10:06+08', '2021-03-09 10:30+08'),
  ('00000000-0000-0000-0000-000000026112', '00000000-0000-0000-0000-0000000261b2', null,
   'cancelled', 'Ride', 'Cash', 12, 12, null, null, null, null, null,
   '2021-03-09 11:00+08', null, null, null, null);
-- The airport is stamped from the pickup's position on insert; set it after.
update public.ride_requests set airport_pickup_id = '00000000-0000-0000-0000-0000000261f1'
 where id = '00000000-0000-0000-0000-000000026103';
insert into public.ride_request_views (request_id, viewer_id, first_seen_at, last_seen_at) values
  ('00000000-0000-0000-0000-000000026106', '00000000-0000-0000-0000-0000000261d2', '2021-03-10 13:01+08', '2021-03-10 13:02+08');
insert into public.ride_ratings (request_id, rater_id, partner_id, stars, created_at) values
  ('00000000-0000-0000-0000-000000026101', '00000000-0000-0000-0000-0000000261b1', '00000000-0000-0000-0000-0000000261d1', 5, '2021-03-10 10:00+08'),
  ('00000000-0000-0000-0000-000000026103', '00000000-0000-0000-0000-0000000261b1', '00000000-0000-0000-0000-0000000261d2', 4, '2021-03-10 19:00+08');
insert into public.support_tickets (profile_id, subject, status, created_at) values
  ('00000000-0000-0000-0000-0000000261b2', 'Lost umbrella', 'open', '2021-03-10 20:00+08');
insert into public.partner_online_sessions (profile_id, started_at, last_seen_at, ended_at) values
  ('00000000-0000-0000-0000-0000000261d1', '2021-03-10 07:00+08', '2021-03-10 10:00+08', '2021-03-10 10:00+08'),
  -- Started the evening before: only the part inside the period counts.
  ('00000000-0000-0000-0000-0000000261d1', '2021-03-09 23:00+08', '2021-03-10 01:00+08', '2021-03-10 01:00+08');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
create or replace function pg_temp.day_summary() returns jsonb language sql as $$
  select public.admin_dashboard_summary('2021-03-10 00:00+08', '2021-03-11 00:00+08',
                                        '2021-03-09 00:00+08', '2021-03-10 00:00+08', 'hour');
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.day_summary() to authenticated;

set local role authenticated;

-- 1. Who may read it ---------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000261b1');
select pg_temp.refused($q$select pg_temp.day_summary()$q$, 'a rider reading the dashboard');
select pg_temp.refused($q$select public.admin_dashboard_live()$q$, 'a rider reading the live panel');
select pg_temp.as_user('00000000-0000-0000-0000-0000000261a3');
select pg_temp.refused($q$select pg_temp.day_summary()$q$, 'a sub-admin of another page reading the dashboard');
select pg_temp.refused($q$select public.admin_dashboard_live()$q$, 'a sub-admin of another page reading the live panel');
select pg_temp.refused($q$select public.admin_dashboard_period(now() - interval '1 day', now(), 'hour')$q$,
  'calling the inner period function');
select pg_temp.as_user('00000000-0000-0000-0000-0000000261a2');
select pg_temp.check(pg_temp.day_summary() ? 'current', 'a sub-admin with the Dashboard page reads it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000261a1');
select pg_temp.refused($q$select public.admin_dashboard_summary(now(), now() - interval '1 day', now() - interval '2 days', now() - interval '1 day', 'hour')$q$,
  'a period that ends before it starts');
select pg_temp.refused($q$select public.admin_dashboard_summary(now() - interval '30 days', now(), now() - interval '60 days', now() - interval '30 days', 'hour')$q$,
  'hourly buckets over a month');
select pg_temp.refused($q$select public.admin_dashboard_summary(now() - interval '1 day', now(), now() - interval '2 days', now() - interval '1 day', 'week')$q$,
  'a bucket other than hour or day');

-- 2. One day, hourly ---------------------------------------------------------------------------------------
create temp table s0261 as select pg_temp.day_summary() as s;
select pg_temp.check((select s->'current'->'kpis' @> '{"trips": 3, "bookings": 60, "commission": 6, "riders_active": 2,
                                                      "requests": 6, "accepted": 4, "cancelled": 2, "expired": 1,
                                                      "new_riders": 1, "new_partners": 1}' from s0261),
  'the day''s KPIs: ' || (select s->'current'->>'kpis' from s0261));
select pg_temp.check((select s->'previous'->'kpis' @> '{"trips": 1, "bookings": 15, "commission": 1.5,
                                                       "requests": 2, "accepted": 1, "cancelled": 1, "new_riders": 1,
                                                       "new_partners": 0}' from s0261),
  'the day before''s KPIs: ' || (select s->'previous'->>'kpis' from s0261));
select pg_temp.check((select jsonb_array_length(s->'current'->'buckets') = 24
                         and jsonb_array_length(s->'previous'->'buckets') = 24 from s0261), '24 hourly buckets a day');
select pg_temp.check((select s->'current'->'buckets'->9 @> '{"start": "2021-03-10T09:00", "trips": 2, "bookings": 50, "requests": 2}'
                         and s->'current'->'buckets'->18 @> '{"start": "2021-03-10T18:00", "trips": 1, "bookings": 10}'
                         and s->'current'->'buckets'->12 @> '{"requests": 2, "accepted": 1, "cancelled": 2}'
                         and s->'current'->'buckets'->0 @> '{"start": "2021-03-10T00:00", "trips": 0}'
                         and s->'previous'->'buckets'->10 @> '{"start": "2021-03-09T10:00", "trips": 1}' from s0261),
  'hourly buckets in Malaysia''s hours: ' || (select s->'current'->>'buckets' from s0261));
-- Cancellation rate: 2 of 6 requests; the rider 1, the driver 1 (of 4 taken).
select pg_temp.check((select s->'current'->'quality' @> '{"driver_cancels": 1, "rider_cancels": 1, "complaints": 1,
                                                         "rating_avg": 4.5, "ratings": 2}' from s0261),
  'quality: ' || (select s->'current'->>'quality' from s0261));
select pg_temp.check((select (s->'current'->'quality'->>'pickup_min')::numeric = 5.3 from s0261),
  'the average time to the pickup (4, 9 and 3 minutes)');
-- The funnel narrows in order.
select pg_temp.check((select s->'current'->'funnel' = '{"requests": 6, "offered": 5, "accepted": 4, "picked_up": 3, "completed": 3}'
                        from s0261),
  'the funnel: ' || (select s->'current'->>'funnel' from s0261));
select pg_temp.check((select (f->>'requests')::int >= (f->>'offered')::int and (f->>'offered')::int >= (f->>'accepted')::int
                         and (f->>'accepted')::int >= (f->>'picked_up')::int and (f->>'picked_up')::int >= (f->>'completed')::int
                        from (select s->'current'->'funnel' as f from s0261) x), 'the funnel narrows');
select pg_temp.check((select s->'current'->'services' = '[{"name": "Ride", "trips": 2, "bookings": 30}, {"name": "Comfort", "trips": 1, "bookings": 30}]'
                        from s0261),
  'the service mix: ' || (select s->'current'->>'services' from s0261));
select pg_temp.check((select s->'current'->'payments' @> '[{"name": "Cash", "trips": 2, "bookings": 30}, {"name": "Get Pay", "trips": 1, "bookings": 30}]'
                        from s0261), 'the payment mix');
select pg_temp.check((select s->'current'->'heat' @> '[{"dow": 3, "hour": 9, "n": 2}, {"dow": 3, "hour": 12, "n": 2}]' from s0261),
  'demand by hour (10 March 2021 was a Wednesday): ' || (select s->'current'->>'heat' from s0261));
select pg_temp.check((select s->'areas'->0 @> '{"name": "Petaling Jaya", "trips": 2, "bookings": 30, "prev_trips": 1}'
                         and s->'areas'->1 @> '{"name": "Kuala Lumpur", "trips": 1, "bookings": 30, "prev_trips": 0}'
                         and jsonb_array_length(s->'areas') = 2 from s0261),
  'top areas: ' || (select s->>'areas' from s0261));
select pg_temp.check((select s->'drivers'->0 @> '{"name": "Ahmad", "trips": 2, "earned": 45, "rating": 4.9,
                                                  "partner_id": "00000000-0000-0000-0000-0000000261e1", "online_seconds": 14400}'
                         and s->'drivers'->1 @> '{"name": "Siti", "trips": 1, "earned": 9, "online_seconds": 0}'
                         and (s->>'online_recorded')::boolean from s0261),
  'top drivers: ' || (select s->>'drivers' from s0261));
select pg_temp.check((select exists (select 1 from jsonb_array_elements(s->'airports') a
                                      where a @> '{"name": "KLIA T1 261", "pickups": 1, "prev_pickups": 0, "waiting": 0}') from s0261),
  'the airport''s pickups: ' || (select s->>'airports' from s0261));
select pg_temp.check((select (s->'attention'->>'partners_pending')::int - (b.attention->>'partners_pending')::int = 1
                         and (s->'attention'->>'tickets_open')::int - (b.attention->>'tickets_open')::int = 1
                        from s0261, base0261 b), 'needs attention: one partner and one ticket more');

-- 3. Two days, daily ---------------------------------------------------------------------------------------
select pg_temp.check((select x->'current'->'buckets' @> '[{"start": "2021-03-09T00:00", "trips": 1, "bookings": 15},
                                                         {"start": "2021-03-10T00:00", "trips": 3, "bookings": 60}]'
                         and jsonb_array_length(x->'current'->'buckets') = 2
                         and x->'current'->'kpis' @> '{"trips": 4, "requests": 8, "cancelled": 3}'
                         and x->'previous'->'kpis' @> '{"trips": 0}'
                         and jsonb_array_length(x->'current'->'heat') = 6
                        from (select public.admin_dashboard_summary('2021-03-09 00:00+08', '2021-03-11 00:00+08',
                                                                    '2021-03-07 00:00+08', '2021-03-09 00:00+08', 'day') as x) y),
  'daily buckets over two days');

-- 4. Right now -----------------------------------------------------------------------------------------------
reset role;
insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, created_at, accepted_at) values
  ('00000000-0000-0000-0000-000000026121', '00000000-0000-0000-0000-0000000261b3', null, 'open', 'Ride', 12,
   now() - interval '30 seconds', null),
  ('00000000-0000-0000-0000-000000026122', '00000000-0000-0000-0000-0000000261b4', '00000000-0000-0000-0000-0000000261d1',
   'accepted', 'Ride', 12, now() - interval '2 minutes', now() - interval '1 minute');
insert into public.driver_presence (profile_id, online, updated_at) values
  ('00000000-0000-0000-0000-0000000261d1', true, now()),
  ('00000000-0000-0000-0000-0000000261d3', true, now() - interval '10 minutes')
on conflict (profile_id) do update set online = excluded.online, updated_at = excluded.updated_at;
insert into public.airport_queue (airport_id, driver_id, place_at) values
  ('00000000-0000-0000-0000-0000000261f1', '00000000-0000-0000-0000-0000000261d2', now());
insert into public.safety_incidents (reporter_id, reporter_role, status, track_until) values
  ('00000000-0000-0000-0000-0000000261b1', 'rider', 'open', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-0000000261b2', 'rider', 'resolved', now() + interval '1 hour');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000261a2');
create temp table l0261 as select public.admin_dashboard_live() as l;
select pg_temp.check((select (l.l->>'drivers_online')::int - (b.live->>'drivers_online')::int = 1
                         and (l.l->>'open_requests')::int - (b.live->>'open_requests')::int = 1
                         and (l.l->>'rides_in_progress')::int - (b.live->>'rides_in_progress')::int = 1
                         and (l.l->>'queue_waiting')::int - (b.live->>'queue_waiting')::int = 1
                         and (l.l->>'sos_open')::int - (b.live->>'sos_open')::int = 1
                        from l0261 l, base0261 b),
  'the live counts: ' || (select l::text from l0261));
select pg_temp.check((select exists (select 1 from jsonb_array_elements(l->'queues') q
                                      where q @> '{"name": "KLIA T1 261", "waiting": 1}') from l0261), 'the queue by airport');
select pg_temp.check((select (l->>'first_offer_seconds')::int between 55 and 65 or (l->>'first_offer_samples')::int > 1
                        from l0261), 'time to first offer today: ' || (select l::text from l0261));
select pg_temp.check((select pg_temp.day_summary()->'airports' @> '[{"name": "KLIA T1 261", "waiting": 1}]'),
  'the airport''s queue in the summary');

reset role;
rollback;

select 'admin_dashboard_0261: all passed';
