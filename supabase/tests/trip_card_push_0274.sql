-- ============================================================================
-- Regression test for migration 0274: the trip card push.
--   * a ride's new status calls trip-card-push at once, with the push
--     webhook secret and nothing else in the headers;
--   * the driver's position calls it at most once every 30 seconds per
--     ride, on the way to the pickup or on the trip only;
--   * another driver (reopened, handed over) calls it with the former one;
--   * nothing is called when nobody on the ride has an Android phone;
--   * the snapshot has the card's columns and the amount due, the admin's
--     Trip card switches, and never the trip code;
--   * only the service role reads the snapshot; nobody but the definer
--     functions touches trip_card_pushes or calls the kick.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trip_card_push_0274.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', what; end if;
end $$;

-- The project's URL is set by hand on the live project; the test sets its own.
delete from vault.secrets where name = 'project_url';
select vault.create_secret('https://example.invalid', 'project_url');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000274a1'),  -- rider with an Android phone
  ('00000000-0000-0000-0000-0000000274a2'),  -- rider with an iPhone only
  ('00000000-0000-0000-0000-0000000274d1'),  -- driver with an Android phone
  ('00000000-0000-0000-0000-0000000274d2'),  -- driver with an iPhone only
  ('00000000-0000-0000-0000-0000000274d3')   -- driver who takes over
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000274%'
on conflict do nothing;
insert into public.push_tokens (profile_id, token, platform) values
  ('00000000-0000-0000-0000-0000000274a1', 'tok-274-a1', 'android'),
  ('00000000-0000-0000-0000-0000000274a2', 'tok-274-a2', 'ios'),
  ('00000000-0000-0000-0000-0000000274d1', 'tok-274-d1', 'android'),
  ('00000000-0000-0000-0000-0000000274d2', 'tok-274-d2', 'ios');

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, currency, toll_charges,
    pickup_name, pickup_lat, pickup_lng, drop_name, drop_lat, drop_lng, partner_live_lat, partner_live_lng,
    rider_name, partner_name, otp) values
  ('00000000-0000-0000-0000-0000000274e1', '00000000-0000-0000-0000-0000000274a1', '00000000-0000-0000-0000-0000000274d1',
   'accepted', 18.5, 18.5, 'MYR', 2, 'Mid Valley 274', 3.118, 101.677, 'KLCC 274', 3.1579, 101.7116, 3.09, 101.677,
   'Aina Test', 'Ali Test', '4719'),
  ('00000000-0000-0000-0000-0000000274e2', '00000000-0000-0000-0000-0000000274a2', '00000000-0000-0000-0000-0000000274d2',
   'accepted', 10, 10, 'MYR', null, 'A 274', 3.1, 101.6, 'B 274', 3.2, 101.7, 3.09, 101.6, 'Mei Test', 'Raj Test', null);

create temp table q0 as select coalesce(max(id), 0) as id from net.http_request_queue;
create function pg_temp.calls(p_ride uuid) returns bigint language sql as $$
  select count(*) from net.http_request_queue q
   where q.id > (select id from q0)
     and q.url = 'https://example.invalid/functions/v1/trip-card-push'
     and convert_from(q.body, 'utf8')::jsonb ->> 'rideId' = p_ride::text
$$;

-- 1. A new status: at once, with the webhook secret and nothing else.
update public.ride_requests set status = 'arrived' where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 1, 'a new status calls trip-card-push');
select pg_temp.check((select q.headers = jsonb_build_object(
                        'Content-Type', 'application/json',
                        'x-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_webhook_secret'))
                        and convert_from(q.body, 'utf8')::jsonb = '{"rideId": "00000000-0000-0000-0000-0000000274e1"}'::jsonb
                        from net.http_request_queue q where q.id > (select id from q0)
                         and q.url like '%/trip-card-push' order by q.id limit 1),
                     'only the webhook secret in the headers; the ride in the body');

-- 2. The driver's position while arrived (waiting): nothing.
update public.ride_requests set partner_live_lat = 3.11 where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 1, 'no push for a move while waiting');

-- 3. On the trip: the status at once, then moves at most every 30 seconds.
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 2, 'on the trip: at once');
update public.ride_requests set partner_live_lat = 3.12 where id = '00000000-0000-0000-0000-0000000274e1';
update public.ride_requests set partner_live_lat = 3.13 where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 2, 'a move within 30 s of the last push waits');
update public.trip_card_pushes set sent_at = now() - interval '31 seconds'
 where ride_id = '00000000-0000-0000-0000-0000000274e1';
update public.ride_requests set partner_live_lat = 3.14 where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 3, 'a move 30 s after the last push goes');
update public.ride_requests set partner_live_lng = 101.68 where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 3, 'and the next waits again');
update public.ride_requests set note = 'n' where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 3, 'other columns call nothing');

-- 4. Another driver: at once, naming the one who had it.
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000274d3'
 where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e1') = 4, 'a new driver calls at once');
select pg_temp.check((select convert_from(q.body, 'utf8')::jsonb ->> 'formerPartnerId' from net.http_request_queue q
                       where q.id > (select id from q0) and q.url like '%/trip-card-push' order by q.id desc limit 1)
                     = '00000000-0000-0000-0000-0000000274d1', 'with the former driver');

-- 5. Nobody on the ride has an Android phone: nothing at all.
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000274e2';
update public.ride_requests set partner_live_lat = 3.15 where id = '00000000-0000-0000-0000-0000000274e2';
select pg_temp.check(pg_temp.calls('00000000-0000-0000-0000-0000000274e2') = 0, 'iPhones only: no push');

-- 6. The snapshot: the card's columns, the amount due, the switches, no trip code.
update public.admin_display_settings
   set settings = coalesce(settings, '{}'::jsonb) || '{"tripCard": {"ride": false, "doneMinutes": 7}}'::jsonb
 where id = 'global';
select pg_temp.check((select s -> 'ride' ->> 'pickup_name' = 'Mid Valley 274'
                         and (s -> 'ride' ->> 'total_due')::numeric = 20.5
                         and s -> 'ride' ->> 'partner_id' = '00000000-0000-0000-0000-0000000274d3'
                         and not (s -> 'ride' ? 'otp')
                         and position('4719' in s::text) = 0
                         and s -> 'settings' = '{"ride": false, "doneMinutes": 7}'::jsonb
                        from public.trip_card_push_snapshot('00000000-0000-0000-0000-0000000274e1') s),
                     'snapshot: the card''s columns, the amount due, the switches, never the trip code');
select pg_temp.check(public.trip_card_push_snapshot(gen_random_uuid()) is null, 'no such ride: null');

-- 7. Who may.
select pg_temp.check(has_function_privilege('service_role', 'public.trip_card_push_snapshot(uuid)', 'execute'), 'service role reads the snapshot');
select pg_temp.check(not has_function_privilege('authenticated', 'public.trip_card_push_snapshot(uuid)', 'execute'), 'a user does not');
select pg_temp.check(not has_function_privilege('anon', 'public.trip_card_push_snapshot(uuid)', 'execute'), 'nor anon');
select pg_temp.check(not has_function_privilege('authenticated', 'public.trip_card_push_kick(uuid, uuid)', 'execute'), 'a user cannot call the kick');
select pg_temp.check(not has_function_privilege('anon', 'public.trip_card_push_kick(uuid, uuid)', 'execute'), 'nor anon');
select pg_temp.check(not has_table_privilege('authenticated', 'public.trip_card_pushes', 'select'), 'a user cannot read trip_card_pushes');
select pg_temp.check(not has_table_privilege('authenticated', 'public.trip_card_pushes', 'insert'), 'nor write it');
select pg_temp.check(not has_table_privilege('anon', 'public.trip_card_pushes', 'select'), 'nor anon');

-- 8. The ride goes, and its row with it.
delete from public.ride_requests where id = '00000000-0000-0000-0000-0000000274e1';
select pg_temp.check(not exists (select 1 from public.trip_card_pushes where ride_id = '00000000-0000-0000-0000-0000000274e1'),
                     'trip_card_pushes goes with the ride');

rollback;

select 'trip_card_push_0274: all passed';
