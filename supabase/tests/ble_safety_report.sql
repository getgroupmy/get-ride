-- ============================================================================
-- Regression test for migration 0158: the Bluetooth & safety report.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ble_safety_report.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000158a1'),  -- rider
  ('00000000-0000-0000-0000-0000000158b1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000158%'
on conflict do nothing;
update public.profiles set name = 'Rina' where id = '00000000-0000-0000-0000-0000000158a1';
update public.profiles set name = 'Dan' where id = '00000000-0000-0000-0000-0000000158b1';

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

-- Only this test's rides count: compare against what was there before.
create temp table before as select public.ble_safety_report(7) as r;

-- Three trips started today: one by Bluetooth (both phones saw each other),
-- one by code (flagged far apart, then separated, then answered "I'm OK"),
-- and one 20 days ago (outside the week).
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name,
                                  started_at, start_method, start_flag, start_flag_at, separated_at, safety_ack_at) values
  ('00000000-0000-0000-0000-0000000158e1', '00000000-0000-0000-0000-0000000158a1',
   '00000000-0000-0000-0000-0000000158b1', 'on_trip', 20, 20, 'KLCC',
   now(), 'ble', null, null, null, null),
  ('00000000-0000-0000-0000-0000000158e2', '00000000-0000-0000-0000-0000000158a1',
   '00000000-0000-0000-0000-0000000158b1', 'on_trip', 20, 20, 'Mid Valley',
   now(), 'pin', 'far_apart', now(), now(), now()),
  ('00000000-0000-0000-0000-0000000158e3', '00000000-0000-0000-0000-0000000158a1',
   '00000000-0000-0000-0000-0000000158b1', 'completed', 20, 20, 'Old',
   now() - interval '20 days', 'pin', null, null, null, null);

insert into public.ride_ble_secrets (request_id, secret, rider_seen_at, driver_seen_at) values
  ('00000000-0000-0000-0000-0000000158e1', '\x00', now(), now());
insert into public.ride_proximity_events (request_id, profile_id, side, matched, rssi, seen_ms) values
  ('00000000-0000-0000-0000-0000000158e1', '00000000-0000-0000-0000-0000000158a1', 'rider', true, -60, 6000),
  ('00000000-0000-0000-0000-0000000158e1', '00000000-0000-0000-0000-0000000158b1', 'driver', true, -62, 6000),
  ('00000000-0000-0000-0000-0000000158e1', '00000000-0000-0000-0000-0000000158b1', 'driver', false, -90, 1000);

insert into public.ride_lost_items (request_id, rider_id, partner_id, description, status) values
  ('00000000-0000-0000-0000-0000000158e2', '00000000-0000-0000-0000-0000000158a1',
   '00000000-0000-0000-0000-0000000158b1', 'Blue umbrella', 'open');

do $$
declare
  b jsonb := (select r from before);
  a jsonb := public.ble_safety_report(7);
  d jsonb;
  n int;
begin
  perform pg_temp.check((a->'starts'->>'ble')::int - (b->'starts'->>'ble')::int = 1, 'one trip started by Bluetooth');
  perform pg_temp.check((a->'starts'->>'pin')::int - (b->'starts'->>'pin')::int = 1,
                        'one trip started by code this week (the one 20 days ago is outside it)');
  perform pg_temp.check(jsonb_array_length(a->'daily') = 7, 'a row for every day of the week, empty or not');
  d := a->'daily'->6;
  perform pg_temp.check(d->>'day' = (now() at time zone 'Asia/Kuala_Lumpur')::date::text, 'the last row is today in Malaysia');
  perform pg_temp.check((d->>'ble')::int >= 1 and (d->>'pin')::int >= 1, 'today counts both');
  perform pg_temp.check((a->'handshake'->>'rides')::int - (b->'handshake'->>'rides')::int = 1, 'one ride used the handshake');
  perform pg_temp.check((a->'handshake'->>'seen_both_ways')::int - (b->'handshake'->>'seen_both_ways')::int = 1,
                        'both phones saw each other');
  perform pg_temp.check((a->'handshake'->>'matched_reports')::int - (b->'handshake'->>'matched_reports')::int = 2,
                        'two matched reports (the weak one is not)');
  perform pg_temp.check((a->'safety'->>'far_apart')::int - (b->'safety'->>'far_apart')::int = 1, 'one started far apart');
  perform pg_temp.check((a->'safety'->>'separations')::int - (b->'safety'->>'separations')::int = 1, 'one separated');
  perform pg_temp.check((a->'safety'->>'lost_open')::int - (b->'safety'->>'lost_open')::int = 1, 'one lost item open');

  select count(*) into n from public.ble_safety_report_trips(7, 50) t
   where t.request_id = '00000000-0000-0000-0000-0000000158e2';
  perform pg_temp.check(n = 3, 'the flagged trip appears for its flag, its separation and its lost item');
  perform pg_temp.check(exists (select 1 from public.ble_safety_report_trips(7, 50) t
                                 where t.request_id = '00000000-0000-0000-0000-0000000158e2' and t.kind = 'separated'
                                   and t.rider_name = 'Rina' and t.driver_name = 'Dan' and t.answered_ok),
                        'with both names, and the passenger''s answer');
  perform pg_temp.check(exists (select 1 from public.ble_safety_report_trips(7, 50) t
                                 where t.kind = 'lost_item' and t.detail = 'open: Blue umbrella'),
                        'the lost item says what and how it stands');
end $$;

-- Only admins read it.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000158a1',
                                                          'role', 'authenticated')::text, true);
do $$
begin
  perform public.ble_safety_report(7);
  raise exception 'FAILED: a passenger read the report';
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;
do $$
begin
  perform * from public.ble_safety_report_trips(7, 50);
  raise exception 'FAILED: a passenger read the trips';
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;
reset role;

rollback;

select 'ble_safety_report: all passed';
