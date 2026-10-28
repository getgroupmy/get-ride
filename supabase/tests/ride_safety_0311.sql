-- ============================================================================
-- Regression test for migration 0311: city ride safety.
--   * settings and the seeded report categories; the admin's tables read by
--     everyone signed in and written by admins only;
--   * trip_report_create: the rider's own ended trip, within the window, a
--     category; the ticket with the trip linked and its first message; one
--     open report per trip; an urgent report alerts the on-duty admins; also
--     blocking the driver; the apps can't set the report columns;
--   * blocks: only a driver the rider rode with, the admin's limit; the
--     favourite removed and refused, open offers withdrawn; the blocked
--     driver no longer reads the rider's open city and City to City
--     requests (another driver still does), can't offer or take; GET.now to
--     him refused; the feeds and pushes edited in place; the driver can't
--     read the block; unblocking;
--   * the driver's request filters kept within the admin's limits;
--   * passenger cover: the most specific rule wins, only real details show;
--     trip_safety_info on the receipt (cover, permits, the switch);
--   * admins: the flags, one driver's reports and blocks, marking reviewed;
--   * the grants.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_safety_0311.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000311a1'),  -- rider
  ('00000000-0000-0000-0000-0000000311a2'),  -- another rider
  ('00000000-0000-0000-0000-0000000311b1'),  -- driver, to be blocked
  ('00000000-0000-0000-0000-0000000311b2'),  -- another driver
  ('00000000-0000-0000-0000-0000000311d1'),  -- full admin (on call)
  ('00000000-0000-0000-0000-0000000311d2')   -- sub-admin, read only
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test 311' from auth.users
 where id::text like '00000000-0000-0000-0000-0000000311%'
on conflict (id) do update set name = excluded.name;  -- the sign-up trigger may have made the row
update public.profiles set name = 'Rider Satu Contoh' where id = '00000000-0000-0000-0000-0000000311a1';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000311d1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000311d2', 'admin-partners', 'read')
on conflict do nothing;

-- The on-duty admins: SOS's on-call list (0193).
insert into public.app_settings (key, value)
values ('sos_ops', '{"onCall": ["00000000-0000-0000-0000-0000000311d1"]}')
on conflict (key) do update set value = coalesce(public.app_settings.value, '{}'::jsonb) || excluded.value;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- What [p_sql] does as [p_user]: 'ok' with the rows it touched, or the error (and its hint).
create or replace function pg_temp.run_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare
  n integer;
  h text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  perform pg_temp.as_server();
  return sqlerrm || coalesce(' | ' || nullif(h, ''), '');
end $$;
-- A value [p_sql] (a select of one value) gives [p_user], as text.
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return v;
exception when others then
  perform pg_temp.as_server();
  return 'ERROR ' || sqlerrm;
end $$;
-- [p_sql] run as the server but with [p_user]'s claims (auth.uid() is them):
-- what a SECURITY DEFINER function they call sees.
create or replace function pg_temp.run_claims(p_user uuid, p_sql text) returns text language plpgsql as $$
declare
  n integer;
begin
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;

-- ---- The settings and categories --------------------------------------------------------------------
select pg_temp.check((select report_window_days = 30 and max_blocks_per_rider = 20 and block_flag_riders = 3
                             and filter_min_fare_cap = 30 and filter_distance_min_km = 1 and filter_distance_max_km = 10
                        from public.ride_safety_settings where id = 1), 'the default settings');
select pg_temp.check((select count(*) >= 7 from public.trip_report_categories where active), 'seven categories');
select pg_temp.check((select urgent and sos_reminder from public.trip_report_categories where label = 'Safety' and active),
                     'Safety is urgent and shows the SOS reminder');
select pg_temp.check((select not urgent from public.trip_report_categories where label = 'Fare' and active), 'Fare is normal');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
                       'select count(*)::text from public.trip_report_categories')::int >= 7, 'riders read the categories');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
                       'update public.ride_safety_settings set report_window_days = 1') = 'ok 0', 'a rider can''t change the settings');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311d2',
                       'update public.ride_safety_settings set report_window_days = 1') = 'ok 0', 'a read-only admin can''t either');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311d1',
                       'update public.ride_safety_settings set report_window_days = 30') = 'ok 1', 'a full admin can');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
                       $q$insert into public.trip_report_categories (label) values ('Mine 311')$q$) like '%row-level security%',
                     'a rider can''t add a category');

-- ---- Trips ----------------------------------------------------------------------------------------------
insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000311e1', '00000000-0000-0000-0000-0000000311b1', 'Hafiz Rahman 311', '+60100031101', 'approved'),
  ('00000000-0000-0000-0000-0000000311e2', '00000000-0000-0000-0000-0000000311b2', 'Driver Dua 311', '+60100031102', 'approved');

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name, drop_name,
                                  partner_name, partner_plate, country, state, completed_at) values
  ('00000000-0000-0000-0000-0000000311f1', '00000000-0000-0000-0000-0000000311a1', '00000000-0000-0000-0000-0000000311b1',
   'completed', 18.40, 18.40, 'Mid Valley 311', 'KLCC 311', 'Hafiz Rahman 311', 'WXY 3111',
   'Negara 311', 'Negeri 311', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000311f2', '00000000-0000-0000-0000-0000000311a1', '00000000-0000-0000-0000-0000000311b2',
   'completed', 12, 12, 'Old 311', 'Older 311', 'Driver Dua 311', 'WXY 3112',
   'Negara 311', null, now() - interval '40 days'),
  ('00000000-0000-0000-0000-0000000311f4', '00000000-0000-0000-0000-0000000311a2', '00000000-0000-0000-0000-0000000311b1',
   'completed', 15, 15, 'Elsewhere 311', 'There 311', 'Hafiz Rahman 311', 'WXY 3111',
   'Negara 311', null, now() - interval '2 days');
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000311f3', '00000000-0000-0000-0000-0000000311a1', 'open', 3.11, 101.61, 20, 20);

-- ---- The apps can't set the report columns -----------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$insert into public.support_tickets (id, profile_id, subject, priority, reported_driver_id, request_id)
     values ('00000000-0000-0000-0000-0000000311c9', '00000000-0000-0000-0000-0000000311a1', 'Help', 'urgent',
             '00000000-0000-0000-0000-0000000311b1', '00000000-0000-0000-0000-0000000311f1')$q$) = 'ok 1',
  'a rider''s own ticket');
select pg_temp.check((select priority = 'normal' and reported_driver_id is null and request_id is null
                        from public.support_tickets where id = '00000000-0000-0000-0000-0000000311c9'),
                     'the report columns are the server''s');

-- ---- Reporting --------------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a2',
  $q$select public.trip_report_create('00000000-0000-0000-0000-0000000311f1',
       (select id from public.trip_report_categories where label = 'Fare' and active))$q$) like 'REPORT_NOT_YOURS%',
  'only the trip''s rider reports it');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_report_create('00000000-0000-0000-0000-0000000311f3',
       (select id from public.trip_report_categories where label = 'Fare' and active))$q$) like 'REPORT_NO_DRIVER%',
  'a request with no driver');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_report_create('00000000-0000-0000-0000-0000000311f2',
       (select id from public.trip_report_categories where label = 'Fare' and active))$q$) like 'REPORT_WINDOW_CLOSED%30 days%',
  'past the report window');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_report_create('00000000-0000-0000-0000-0000000311f1', gen_random_uuid())$q$) like 'REPORT_CATEGORY%',
  'an unknown category');

-- The receipt before reporting.
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text$q$)::jsonb->>'can_report')::boolean,
  'the receipt offers a report');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select coalesce(public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text, 'none')$q$) = 'none',
  'the driver gets no report part');

create temp table t_report as select null::jsonb as r;
grant all on t_report to authenticated;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$update t_report set r = public.trip_report_create('00000000-0000-0000-0000-0000000311f1',
       (select id from public.trip_report_categories where label = 'Safety' and active), '  He drove too fast. ', false)$q$)
  = 'ok 1', 'a Safety report');
select pg_temp.check((select (r->>'urgent')::boolean and not (r->>'blocked')::boolean from t_report), 'urgent, not blocked');
select pg_temp.check((select t.profile_id = '00000000-0000-0000-0000-0000000311a1' and t.priority = 'urgent'
                             and t.request_id = '00000000-0000-0000-0000-0000000311f1'
                             and t.reported_driver_id = '00000000-0000-0000-0000-0000000311b1'
                             and t.report_category = 'Safety' and t.reported_at is not null and t.status = 'open'
                             and t.subject like 'Trip report: Safety%' and t.unread_admin = 1
                        from public.support_tickets t, t_report where t.id = (t_report.r->>'ticket_id')::uuid),
                     'the ticket with the trip linked');
select pg_temp.check((select m.sender_role = 'user' and m.body like 'Trip report: Safety%' and m.body like '%Mid Valley 311 to KLCC 311%'
                             and m.body like '%Hafiz R.%' and m.body like '%He drove too fast.%'
                        from public.support_messages m, t_report where m.ticket_id = (t_report.r->>'ticket_id')::uuid),
                     'the first message carries the trip, the route, the driver and the note');
select pg_temp.check((select count(*) >= 1 from public.notification_outbox o, t_report
                       where o.profile_id = '00000000-0000-0000-0000-0000000311d1' and o.kind = 'trip_report'
                         and o.priority = 'critical' and o.data->>'ticket_id' = t_report.r->>'ticket_id'),
                     'the on-duty admins are alerted');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_report_create('00000000-0000-0000-0000-0000000311f1',
       (select id from public.trip_report_categories where label = 'Fare' and active))$q$) like 'REPORT_ALREADY%',
  'one open report per trip');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text$q$)::jsonb->'report'->>'category') = 'Safety',
  'the receipt shows the earlier report');

-- ---- Blocking ---------------------------------------------------------------------------------------------
-- Before: driver b1 reads the rider's open request, a favourite and an offer stand.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select count(*)::text from public.ride_requests where id = '00000000-0000-0000-0000-0000000311f3'$q$) = '1',
  'before: the driver sees the open request');
insert into public.favourite_drivers (rider_id, driver_id)
values ('00000000-0000-0000-0000-0000000311a1', '00000000-0000-0000-0000-0000000311b1');
insert into public.ride_offers (id, request_id, partner_id, amount, expires_at)
values ('00000000-0000-0000-0000-0000000311c1', '00000000-0000-0000-0000-0000000311f3',
        '00000000-0000-0000-0000-0000000311b1', 22, now() + interval '1 minute');

select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.rider_block_driver('00000000-0000-0000-0000-0000000311b1')$q$) = 'ok 1',
  'the rider blocks a driver they rode with');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a2',
  $q$select public.rider_block_driver('00000000-0000-0000-0000-0000000311b2')$q$) like 'BLOCK_BAD%',
  'not a driver they never rode with');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.rider_block_driver(null, '00000000-0000-0000-0000-0000000311f4')$q$) like 'BLOCK_BAD%',
  'not through someone else''s trip');
select pg_temp.check(not exists (select 1 from public.favourite_drivers
                                  where rider_id = '00000000-0000-0000-0000-0000000311a1'
                                    and driver_id = '00000000-0000-0000-0000-0000000311b1'), 'the favourite is removed');
select pg_temp.check((select status = 'withdrawn' from public.ride_offers where id = '00000000-0000-0000-0000-0000000311c1'),
                     'his open offer is withdrawn');

-- Who sees the open request.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select count(*)::text from public.ride_requests where id = '00000000-0000-0000-0000-0000000311f3'$q$) = '0',
  'the blocked driver no longer sees it');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b2',
  $q$select count(*)::text from public.ride_requests where id = '00000000-0000-0000-0000-0000000311f3'$q$) = '1',
  'another driver still does');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select count(*)::text from public.ride_requests where id = '00000000-0000-0000-0000-0000000311f1'$q$) = '1',
  'his finished trip with the rider stays his');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select count(*)::text from public.rider_blocks$q$) = '0', 'the driver isn''t told: he can''t read the block');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select count(*)::text from public.rider_blocks$q$) = '1', 'the rider reads their own');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311d1',
  $q$select count(*)::text from public.rider_blocks where driver_id = '00000000-0000-0000-0000-0000000311b1'$q$) = '1',
  'admins see the blocks');

-- Offering, taking, favourites, GET.now.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311b1',
  $q$insert into public.ride_offers (request_id, partner_id, amount, expires_at)
     values ('00000000-0000-0000-0000-0000000311f3', '00000000-0000-0000-0000-0000000311b1', 25, now() + interval '1 minute')$q$)
  not like 'ok%', 'he can''t offer');
do $$
begin
  insert into public.ride_offers (request_id, partner_id, amount, expires_at)
  values ('00000000-0000-0000-0000-0000000311f3', '00000000-0000-0000-0000-0000000311b1', 25, now() + interval '1 minute');
  raise exception 'FAILED: an offer from a blocked driver went in';
exception when others then
  if sqlerrm <> 'OFFER_REQUEST_CLOSED' then
    raise;
  end if;
end $$;
insert into public.ride_offers (request_id, partner_id, amount, expires_at)
values ('00000000-0000-0000-0000-0000000311f3', '00000000-0000-0000-0000-0000000311b2', 25, now() + interval '1 minute');
select pg_temp.check(pg_temp.run_claims('00000000-0000-0000-0000-0000000311b1',
  $q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000311b1', status = 'accepted'
      where id = '00000000-0000-0000-0000-0000000311f3'$q$) not like 'ok%', 'he can''t take it');
select pg_temp.check(pg_temp.run_claims('00000000-0000-0000-0000-0000000311a1',
  $q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000311b1', status = 'accepted'
      where id = '00000000-0000-0000-0000-0000000311f3'$q$) not like 'ok%', 'nor the rider give it him');
select pg_temp.check((select partner_id is null and status = 'open' from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000311f3'), 'still open, no driver');
do $$
begin
  insert into public.favourite_drivers (rider_id, driver_id)
  values ('00000000-0000-0000-0000-0000000311a1', '00000000-0000-0000-0000-0000000311b1');
  raise exception 'FAILED: a blocked driver made a favourite';
exception when others then
  if sqlerrm <> 'DRIVER_BLOCKED' then
    raise;
  end if;
end $$;
-- The trigger after My Ride's: a GET.now driver blocked is refused; a
-- blocked favourite is left out of the request's targets.
select pg_temp.check(pg_temp.run_claims('00000000-0000-0000-0000-0000000311a1',
  $q$update public.ride_requests set direct_driver_id = '00000000-0000-0000-0000-0000000311b1'
      where id = '00000000-0000-0000-0000-0000000311f3'$q$) not like 'ok%',
  'GET.now to a blocked driver refused');
update public.ride_requests
   set target_driver_ids = array['00000000-0000-0000-0000-0000000311b1', '00000000-0000-0000-0000-0000000311b2']::uuid[],
       targeted_until = now() + interval '1 minute'
 where id = '00000000-0000-0000-0000-0000000311f3';
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000311b2']::uuid[]
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000311f3'),
                     'a blocked driver is left out of the favourites asked first');
update public.ride_requests set target_driver_ids = null, targeted_until = null
 where id = '00000000-0000-0000-0000-0000000311f3';

-- The feeds and pushes are edited in place.
select pg_temp.check((select bool_and(position('rider_block' in pg_get_functiondef(p.oid)) > 0)
                        from pg_proc p
                       where p.pronamespace = 'public'::regnamespace
                         and p.proname in ('ride_request_push_nearby', 'ride_request_push_everyone', 'scheduled_rides_open',
                                           'scheduled_rides_upcoming', 'ride_extras_hidden_count', 'c2c_driver_requests'))
                     and (select count(*) = 6 from pg_proc p
                           where p.pronamespace = 'public'::regnamespace
                             and p.proname in ('ride_request_push_nearby', 'ride_request_push_everyone', 'scheduled_rides_open',
                                               'scheduled_rides_upcoming', 'ride_extras_hidden_count', 'c2c_driver_requests')),
                     'the feeds and pushes leave blocked drivers out');
select pg_temp.check(public.rider_blocked_driver_ids('00000000-0000-0000-0000-0000000311a1')
                       = '["00000000-0000-0000-0000-0000000311b1"]'::jsonb, 'the push''s exclude list');

-- City to City: the blocked driver doesn't read the rider's open request.
do $$
begin
  if exists (select 1 from pg_trigger where tgname = 'trg_c2c_bookings_check') then
    execute 'alter table public.c2c_bookings disable trigger trg_c2c_bookings_check';
  end if;
end $$;
insert into public.c2c_bookings (id, rider_id, pickup_name, pickup_lat, pickup_lng, drop_name, drop_lat, drop_lng,
                                 distance_km, duration_min, leave_at, fare, payment, status, expires_at)
select '00000000-0000-0000-0000-0000000311c2', '00000000-0000-0000-0000-0000000311a1', 'KL 311', 3.1, 101.6, 'Ipoh 311',
       4.6, 101.1, 200, 150, now() + interval '2 days', 120, 'cash', 'open', now() + interval '2 days'
 where exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'c2c_bookings' and column_name = 'payment');
insert into public.c2c_bookings (id, rider_id, status)
select '00000000-0000-0000-0000-0000000311c2', '00000000-0000-0000-0000-0000000311a1', 'open'
 where not exists (select 1 from public.c2c_bookings where id = '00000000-0000-0000-0000-0000000311c2');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select count(*)::text from public.c2c_bookings where id = '00000000-0000-0000-0000-0000000311c2'$q$) = '0',
  'City to City: hidden from the blocked driver');
do $$
begin
  insert into public.c2c_offers (booking_id, driver_id, price, leave_at)
  select '00000000-0000-0000-0000-0000000311c2', '00000000-0000-0000-0000-0000000311b1', 120, now() + interval '2 days'
   where exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'c2c_offers' and column_name = 'leave_at');
  insert into public.c2c_offers (booking_id, driver_id, price)
  select '00000000-0000-0000-0000-0000000311c2', '00000000-0000-0000-0000-0000000311b1', 120
   where not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'c2c_offers' and column_name = 'leave_at');
  raise exception 'FAILED: a City to City offer from a blocked driver went in';
exception when others then
  if sqlerrm <> 'C2C_NOT_OPEN' then
    raise;
  end if;
end $$;

-- The limit.
update public.ride_safety_settings set max_blocks_per_rider = 1 where id = 1;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.rider_block_driver('00000000-0000-0000-0000-0000000311b2')$q$) like 'BLOCK_LIMIT%up to 1 drivers%',
  'at most the admin''s number of blocks');
update public.ride_safety_settings set max_blocks_per_rider = 20 where id = 1;

-- The rider's list.
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  'select public.my_blocked_drivers()::text')::jsonb->0->>'name') = 'Hafiz R.', 'the list says "Hafiz R."');

-- ---- Admins -------------------------------------------------------------------------------------------------
update public.ride_safety_settings set block_flag_riders = 1 where id = 1;
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311d1',
  $q$select (reports = 1 and urgent = 1 and blocks = 1 and flagged)::text from public.admin_driver_safety_flags()
      where partner_id = '00000000-0000-0000-0000-0000000311b1'$q$) = 'true', 'the Partners list flag');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  'select count(*)::text from public.admin_driver_safety_flags()') like 'ERROR%not_authorized%', 'admins only');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311d2',
  $q$select public.admin_driver_safety('00000000-0000-0000-0000-0000000311b1')::text$q$)::jsonb->'blocks'->0->>'rider_name')
  = 'Rider Satu Contoh', 'the partner sheet shows who blocked him');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311d2',
  $q$select public.admin_driver_block_review('00000000-0000-0000-0000-0000000311b1')$q$) not like 'ok%',
  'a read-only admin can''t mark it reviewed');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311d1',
  $q$select public.admin_driver_block_review('00000000-0000-0000-0000-0000000311b1')$q$) = 'ok 1', 'a full admin can');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311d1',
  $q$select (blocks_since_review = 0 and not flagged)::text from public.admin_driver_safety_flags()
      where partner_id = '00000000-0000-0000-0000-0000000311b1'$q$) = 'true', 'reviewed: the flag counts afresh');
update public.ride_safety_settings set block_flag_riders = 3 where id = 1;

-- ---- Report and block together; unblocking -------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.rider_unblock_driver('00000000-0000-0000-0000-0000000311b1')$q$) = 'ok 1', 'unblocking');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  $q$select count(*)::text from public.ride_requests where id = '00000000-0000-0000-0000-0000000311f3'$q$) = '1',
  'unblocked: he sees the request again');
update public.support_tickets set status = 'closed' where id = (select (r->>'ticket_id')::uuid from t_report);
update t_report set r = null;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311a1',
  $q$update t_report set r = public.trip_report_create('00000000-0000-0000-0000-0000000311f1',
       (select id from public.trip_report_categories where label = 'Fare' and active), null, true)$q$) = 'ok 1',
  'a Fare report that also blocks');
select pg_temp.check((select not (r->>'urgent')::boolean and (r->>'blocked')::boolean from t_report), 'normal, blocked');
select pg_temp.check((select source = 'report' and request_id = '00000000-0000-0000-0000-0000000311f1' from public.rider_blocks
                       where rider_id = '00000000-0000-0000-0000-0000000311a1'
                         and driver_id = '00000000-0000-0000-0000-0000000311b1'), 'the block says where it came from');
select pg_temp.check(not exists (select 1 from public.notification_outbox o, t_report
                                  where o.data->>'ticket_id' = t_report.r->>'ticket_id'), 'a normal report alerts nobody');

-- ---- Driver request filters ----------------------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311b2',
  $q$insert into public.driver_request_filters (driver_id, min_fare, max_km, sort)
     values ('00000000-0000-0000-0000-0000000311b2', 80, 25, 'price')$q$) = 'ok 1', 'a driver saves their filters');
select pg_temp.check((select min_fare = 30 and max_km = 10 and sort = 'price' from public.driver_request_filters
                       where driver_id = '00000000-0000-0000-0000-0000000311b2'), 'kept within the admin''s limits');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000311b2',
  $q$update public.driver_request_filters set max_km = 0.2 where driver_id = '00000000-0000-0000-0000-0000000311b2'$q$) = 'ok 1',
  'a driver changes their filters');
select pg_temp.check((select max_km = 1 from public.driver_request_filters
                       where driver_id = '00000000-0000-0000-0000-0000000311b2'), 'no closer than the admin''s minimum');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000311b1',
  'select count(*)::text from public.driver_request_filters') = '0', 'one driver doesn''t read another''s');

-- ---- Cover and permits ------------------------------------------------------------------------------------------
insert into public.passenger_cover_rules (country, enabled, insurer, policy_no, cover_amount, claim_days, hotline) values
  ('Negara 311', true, 'Contoh Takaful 311', 'PA-311', 50000, 30, '1-300-00-0311');
insert into public.passenger_cover_rules (country, state, enabled, insurer, policy_no, cover_amount) values
  ('Negara 311', 'Negeri 311', false, 'Off Takaful 311', 'PA-OFF', 1000);
insert into public.passenger_cover_rules (country, enabled, insurer, policy_no, cover_amount) values
  ('Kosong 311', true, 'Half 311', '', 1000);
select pg_temp.check((public.passenger_cover_for('Negara 311', 'Lain 311')->>'insurer') = 'Contoh Takaful 311'
                     and (public.passenger_cover_for('Negara 311', 'Lain 311')->>'shown')::boolean, 'the country rule');
select pg_temp.check(not (public.passenger_cover_for('Negara 311', 'Negeri 311')->>'shown')::boolean,
                     'a state rule that is off wins over its country');
select pg_temp.check(not (public.passenger_cover_for('Kosong 311')->>'shown')::boolean, 'no policy number: not shown');
update public.ride_requests set state = null where id = '00000000-0000-0000-0000-0000000311f1';
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text$q$)::jsonb->'cover'->>'policy_no') = 'PA-311',
  'the receipt: you were covered');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text$q$)::jsonb->>'blocked')::boolean,
  'the receipt knows the driver is blocked');
select pg_temp.check(jsonb_typeof(pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text$q$)::jsonb->'permits') = 'array',
  'the permits are a list');
update public.ride_safety_settings set show_driver_permit = false where id = 1;
select pg_temp.check(jsonb_array_length(pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  $q$select public.trip_safety_info('00000000-0000-0000-0000-0000000311f1')::text$q$)::jsonb->'permits') = 0,
  'the admin''s switch hides the permit');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000311a1',
  'select public.passenger_cover_mine()::text')::jsonb->>'insurer') = 'Contoh Takaful 311', 'the Safety page');

-- ---- Grants ------------------------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.trip_report_create(uuid, uuid, text, boolean, uuid)', 'execute')
                     and has_function_privilege('authenticated', 'public.trip_report_create(uuid, uuid, text, boolean, uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'public.rider_blocks_driver(uuid, uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'public.rider_block_insert(uuid, uuid, uuid, uuid, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.ride_safety_alert_admins(text, text, text, jsonb)', 'execute')
                     and not has_function_privilege('anon', 'public.rider_block_driver(uuid, uuid, uuid, text)', 'execute'),
                     'the grants');

rollback;
