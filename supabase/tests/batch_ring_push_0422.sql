-- ============================================================================
-- Regression test for migration 0422: a ring of the dispatch ladder tells
-- all its drivers in one call to send-push (`profileIds`), not one call per
-- driver -- the same drivers as before, each recorded once, the rider never,
-- a driver already told not told again (p_once), and a ring of over 1,000
-- drivers split into calls of 1,000, a driver the rider blocked never told;
-- and the "everyone" step judges only the approved partners its push can reach.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/batch_ring_push_0422.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

-- Record what would go to send-push instead of calling it.
create temp table calls (n serial, body jsonb);
create or replace function public.send_push_webhook(p_body jsonb) returns void
language sql as $$ insert into pg_temp.calls (body) values (p_body) $$;

-- A rider (online as a driver too), two drivers near the pickup, one far.
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000422c1'),
  ('00000000-0000-0000-0000-0000000422d1'),
  ('00000000-0000-0000-0000-0000000422d2'),
  ('00000000-0000-0000-0000-0000000422d3')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000422%'
on conflict do nothing;

alter table public.driver_presence disable trigger user;
delete from public.driver_presence;
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000422c1', true, 33.000, 123.000, now()),
  ('00000000-0000-0000-0000-0000000422d1', true, 33.001, 123.001, now()),
  ('00000000-0000-0000-0000-0000000422d2', true, 33.010, 123.010, now()),
  ('00000000-0000-0000-0000-0000000422d3', true, 34.000, 124.000, now());
alter table public.driver_presence enable trigger user;

-- A request to push for, written straight in (its own triggers would push).
alter table public.ride_requests disable trigger user;
insert into public.ride_requests (id, rider_id, status, service, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000422e1', '00000000-0000-0000-0000-0000000422c1', 'open', 'Ride', 33.0, 123.0);
alter table public.ride_requests enable trigger user;

-- 1. The ring: both near drivers in ONE call; the rider and the far driver never.
select pg_temp.check(public.ride_request_push_nearby('00000000-0000-0000-0000-0000000422e1',
  '00000000-0000-0000-0000-0000000422c1', 33.0, 123.0, 5, '{"title":"New ride","body":"Pickup"}', 'ladder', true) = 2,
  'two drivers told');
select pg_temp.check((select count(*) = 1 from calls), 'in one call');
select pg_temp.check(
  (select array(select jsonb_array_elements_text(body->'profileIds') order by 1) from calls where n = 1)
    = array['00000000-0000-0000-0000-0000000422d1', '00000000-0000-0000-0000-0000000422d2'],
  'the call names both near drivers, not the rider or the far one');
select pg_temp.check((select body->>'profileId' = body->'profileIds'->>0 from calls where n = 1),
  'the first driver also in profileId, for an older send-push');
select pg_temp.check((select body->>'title' = 'New ride' and body->>'body' = 'Pickup' from calls where n = 1),
  'the message is carried');
select pg_temp.check((select count(*) = 2 from public.ride_request_pushes
                       where request_id = '00000000-0000-0000-0000-0000000422e1' and kind = 'ladder'),
  'each driver recorded once');

-- 2. The next ring, once only: the same drivers are not told again.
select pg_temp.check(public.ride_request_push_nearby('00000000-0000-0000-0000-0000000422e1',
  '00000000-0000-0000-0000-0000000422c1', 33.0, 123.0, 5, '{"title":"t","body":"b"}', 'ladder', true) = 0,
  'nobody new');
select pg_temp.check((select count(*) = 1 from calls), 'and no call');

-- 3. Not once-only (a fare raise): told again, in one call.
select pg_temp.check(public.ride_request_push_nearby('00000000-0000-0000-0000-0000000422e1',
  '00000000-0000-0000-0000-0000000422c1', 33.0, 123.0, 5, '{"title":"t","body":"b"}', 'raised', false) = 2,
  'both told again');
select pg_temp.check((select count(*) = 2 from calls), 'in one more call');

-- 4. Nobody in the ring: no call at all.
select pg_temp.check(public.ride_request_push_nearby('00000000-0000-0000-0000-0000000422e1',
  null, 10.0, 10.0, 5, '{"title":"t","body":"b"}', 'ladder', true) = 0, 'an empty ring');
select pg_temp.check((select count(*) = 2 from calls), 'sends nothing');

-- 5. The "everyone" step of a courier ride: one call to the approved
--    partners; it leaves out an approved partner who cannot carry it, and no
--    longer judges (or lists) a partner the push cannot reach anyway.
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000422d1', 'Approved 422', '+60104220001', 'approved'),
  ('00000000-0000-0000-0000-0000000422d2', 'Applicant 422', '+60104220002', 'unapproved');
alter table public.ride_requests disable trigger user;
insert into public.ride_requests (id, rider_id, status, service, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000422e2', '00000000-0000-0000-0000-0000000422c1', 'open', 'Courier Car', 33.0, 123.0);
alter table public.ride_requests enable trigger user;
select public.ride_request_push_everyone('00000000-0000-0000-0000-0000000422e2', '{"title":"t","body":"b"}', 'everyone');
select pg_temp.check((select count(*) = 3 from calls), 'one call for everyone');
select pg_temp.check((select body->>'audience' = 'partners' and (body->>'approvedOnly')::boolean from calls where n = 3),
  'to approved partners');
select pg_temp.check((select body->'excludeProfileIds' ? '00000000-0000-0000-0000-0000000422c1' from calls where n = 3),
  'never the rider');
select pg_temp.check((select body->'excludeProfileIds' ? '00000000-0000-0000-0000-0000000422d1' from calls where n = 3),
  'an approved partner with no courier vehicle is left out');
select pg_temp.check((select not (body->'excludeProfileIds' ? '00000000-0000-0000-0000-0000000422d2') from calls where n = 3),
  'an applicant is not judged: the push cannot reach them anyway');

-- 6. A driver the rider blocked (0311) is never told, by a ring or by the
--    "everyone" step.
alter table public.rider_blocks disable trigger user;
insert into public.rider_blocks (rider_id, driver_id, source)
values ('00000000-0000-0000-0000-0000000422c1', '00000000-0000-0000-0000-0000000422d2', 'settings');
alter table public.rider_blocks enable trigger user;
alter table public.ride_requests disable trigger user;
insert into public.ride_requests (id, rider_id, status, service, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000422e3', '00000000-0000-0000-0000-0000000422c1', 'open', 'Ride', 33.0, 123.0);
alter table public.ride_requests enable trigger user;
select pg_temp.check(public.ride_request_push_nearby('00000000-0000-0000-0000-0000000422e3',
  '00000000-0000-0000-0000-0000000422c1', 33.0, 123.0, 5, '{"title":"t","body":"b"}', 'ladder', true) = 1,
  'only the driver not blocked is told');
select pg_temp.check((select body->'profileIds' = '["00000000-0000-0000-0000-0000000422d1"]'::jsonb from calls where n = 4),
  'the blocked driver is not in the call');
select public.ride_request_push_everyone('00000000-0000-0000-0000-0000000422e3', '{"title":"t","body":"b"}', 'everyone');
select pg_temp.check((select body->'excludeProfileIds' ? '00000000-0000-0000-0000-0000000422d2' from calls where n = 5),
  'the "everyone" step leaves the blocked driver out');

-- 7. Over 1,000 drivers: calls of at most 1,000, each driver once.
insert into auth.users (id)
select ('00000000-0000-0000-0422-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, 1205) n
on conflict do nothing;
insert into public.profiles (id) select id from auth.users where id::text like '00000000-0000-0000-0422-%'
on conflict do nothing;
alter table public.driver_presence disable trigger user;
insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
select id, true, 35.0, 125.0, now() from auth.users where id::text like '00000000-0000-0000-0422-%';
alter table public.driver_presence enable trigger user;
select pg_temp.check(public.ride_request_push_nearby('00000000-0000-0000-0000-0000000422e1',
  null, 35.0, 125.0, 5, '{"title":"t","body":"b"}', 'ladder', true) = 1205, '1,205 drivers told');
select pg_temp.check((select array_agg(jsonb_array_length(body->'profileIds') order by n) from calls where n > 5)
                       = array[1000, 205], 'in a call of 1,000 and one of 205');
select pg_temp.check((select count(distinct x) = 1205 from calls, jsonb_array_elements_text(body->'profileIds') x where n > 5),
                     'each driver once');

rollback;

select 'batch_ring_push_0422: all passed';
