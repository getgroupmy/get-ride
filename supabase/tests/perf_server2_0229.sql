-- ============================================================================
-- Regression test for migration 0229: rate limits count in one row per key
-- per window, the Bluetooth handshake keeps one row per ride side and writes
-- it only when something changed, and messaging_devices is out of realtime
-- while commission_tiers is in.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/perf_server2_0229.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

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

-- 1. The rate limit counter ----------------------------------------------------------
select pg_temp.check(not has_function_privilege(r, 'public.auth_rate_take(text, text, integer, interval)', 'execute')
                     and not has_function_privilege(r, 'public.auth_rate_wait(text, text, integer, interval)', 'execute')
                     and not has_table_privilege(r, 'public.auth_rate_counts', 'select')
                     and not has_table_privilege(r, 'public.auth_rate_counts', 'insert'),
                     r || ' can''t touch the counters')
  from unnest(array['anon', 'authenticated']) as r;

do $$
declare
  w int;
  v_hits_before bigint := (select count(*) from public.auth_rate_hits);
begin
  for i in 1..5 loop
    perform pg_temp.check(public.auth_rate_take('t229', '203.0.113.29', 5, interval '10 minutes') = 0,
                          format('try %s of 5 passes', i));
  end loop;
  perform pg_temp.check(public.auth_rate_wait('t229', '203.0.113.29', 5, interval '10 minutes') between 1 and 600,
                        'the peek sees the window full');
  w := public.auth_rate_take('t229', '203.0.113.29', 5, interval '10 minutes');
  perform pg_temp.check(w between 1 and 600, format('the 6th waits for the window to end (%s)', w));
  perform pg_temp.check((select count(*) = 1 and sum(hits) = 5 from public.auth_rate_counts
                          where bucket = 't229' and key = '203.0.113.29'),
                        'one row per key and window, and a refused try is not counted');
  perform pg_temp.check(public.auth_rate_wait('t229', '203.0.113.29', 6, interval '10 minutes') = 0,
                        'the peek counts nothing');
  perform pg_temp.check(public.auth_rate_take('t229', '203.0.113.30', 5, interval '10 minutes') = 0,
                        'another key has its own count');
  perform pg_temp.check(public.auth_rate_take('t229', '203.0.113.29', 5, interval '1 hour') = 0,
                        'another window length has its own count');
  perform pg_temp.check(public.auth_rate_take('t229', null, 0, interval '10 minutes') = 0
                        and public.auth_rate_take('t229', '', 0, interval '10 minutes') = 0
                        and public.auth_rate_wait('t229', null, 0, interval '10 minutes') = 0,
                        'no key, no limit');
  perform pg_temp.check(public.auth_rate_take('t229', '203.0.113.31', 0, interval '10 minutes') > 0,
                        'a limit of none refuses');
  -- Two windows on (0234: the window before the current one still weighs in;
  -- security_batch9_0234.sql tests that).
  update public.auth_rate_counts set window_start = window_start - interval '20 minutes' where bucket = 't229';
  perform pg_temp.check(public.auth_rate_take('t229', '203.0.113.29', 5, interval '10 minutes') = 0,
                        'a new window starts afresh');
  perform pg_temp.check((select count(*) from public.auth_rate_hits) = v_hits_before,
                        'auth_rate_hits is no longer written');
end
$$;

select pg_temp.check(not exists (select 1 from pg_extension where extname = 'pg_cron')
                     or exists (select 1 from cron.job where jobname = 'purge-auth-rate-counts'),
                     'old windows are purged by pg_cron');

-- The functions that peeked at auth_rate_hits read the counter.
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000229a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000229a1') on conflict do nothing;
select public.auth_rate_take('my_ride_code_miss', '00000000-0000-0000-0000-0000000229a1', 10, interval '1 hour')
  from generate_series(1, 10);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000229a1');
select pg_temp.check(public.add_favourite_driver('ABCDEFGH')->>'error' = 'rate_limited',
                     'ten unknown My Ride codes: no lookups for a while');
reset role;
select public.auth_rate_take('my_qr_miss', '00000000-0000-0000-0000-0000000229a1', 20, interval '1 hour')
  from generate_series(1, 20);
select pg_temp.check(public.personal_qr_miss_wait('00000000-0000-0000-0000-0000000229a1', null) > 0,
                     'twenty unknown QR tokens: no lookups for a while');
select pg_temp.check(not exists (select 1 from pg_proc
                                  where pronamespace = 'public'::regnamespace and prosrc like '%auth_rate_hits%'),
                     'no function reads or writes auth_rate_hits');

-- 2. The Bluetooth handshake ------------------------------------------------------------
select pg_temp.check(exists (select 1 from pg_index i
                              where i.indexrelid = 'public.ride_proximity_events_request_side'::regclass
                                and i.indisunique),
                     'one row per ride side, by a unique index');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000229b1'),  -- rider
  ('00000000-0000-0000-0000-0000000229b2')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000229b%'
on conflict do nothing;
insert into public.settings_entries (id, category, values)
values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging', '{"ble_enabled": true}')
on conflict (id) do update set values = excluded.values;
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000229e1', '00000000-0000-0000-0000-0000000229b1',
   '00000000-0000-0000-0000-0000000229b2', 'arrived', 20, 20, 'KLCC');

create or replace function pg_temp.token(p_side text, p_back int default 0) returns text
language sql as $$
  select public.ble_token(b.secret, '00000000-0000-0000-0000-0000000229e1', p_side, public.ble_window() - p_back)
    from public.ride_ble_secrets b where b.request_id = '00000000-0000-0000-0000-0000000229e1';
$$;
create or replace function pg_temp.row_of(p_side text) returns public.ride_proximity_events
language sql as $$
  select * from public.ride_proximity_events
   where request_id = '00000000-0000-0000-0000-0000000229e1' and side = p_side;
$$;
create or replace function pg_temp.proof(p_as uuid, p_token text, p_rssi int, p_ms int,
                                         p_lat double precision default 3.1579,
                                         p_lng double precision default 101.7116) returns text
language plpgsql as $$
begin
  perform pg_temp.as_user(p_as);
  return public.ble_handshake_proof('00000000-0000-0000-0000-0000000229e1', p_token, p_rssi, p_ms, p_lat, p_lng);
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000229b1');
select public.get_trip_ble_token('00000000-0000-0000-0000-0000000229e1');

do $$
declare
  v_rider uuid := '00000000-0000-0000-0000-0000000229b1';
  v_driver uuid := '00000000-0000-0000-0000-0000000229b2';
  v_sees_driver text := pg_temp.token('driver');
  v_sees_rider text := pg_temp.token('rider');
  v_ctid tid;
begin
  -- A miss is recorded once; repeats that say nothing new are not written.
  perform pg_temp.check(pg_temp.proof(v_rider, 'ffffffffffffffff', -60, 6000) = 'no_match', 'a wrong token');
  v_ctid := (select ctid from public.ride_proximity_events
              where request_id = '00000000-0000-0000-0000-0000000229e1' and side = 'rider');
  perform pg_temp.check(pg_temp.proof(v_rider, 'eeeeeeeeeeeeeeee', -61, 6100) = 'no_match', 'another wrong token');
  perform pg_temp.check((select ctid from public.ride_proximity_events
                          where request_id = '00000000-0000-0000-0000-0000000229e1' and side = 'rider') = v_ctid,
                        'a miss like the last is not written again');

  -- The rider sees the driver: one side alone waits; the match replaces the miss.
  perform pg_temp.check(pg_temp.proof(v_rider, v_sees_driver, -60, 6000) = 'waiting', 'one side alone waits');
  perform pg_temp.check((pg_temp.row_of('rider')).matched, 'the match replaces the miss');
  perform pg_temp.check((pg_temp.row_of('rider')).token_digest = md5(v_sees_driver)
                        and (pg_temp.row_of('rider')).token_digest <> v_sees_driver,
                        'the token is kept only as a digest');
  perform pg_temp.check(pg_temp.proof(v_rider, 'ffffffffffffffff', -60, 6000) = 'no_match', 'a miss after a match');
  perform pg_temp.check((pg_temp.row_of('rider')).matched, 'a miss never replaces a match');

  -- Same token, nothing new: the answer without a write (and without the HMACs).
  v_ctid := (select ctid from public.ride_proximity_events
              where request_id = '00000000-0000-0000-0000-0000000229e1' and side = 'rider');
  perform pg_temp.check(pg_temp.proof(v_rider, upper(v_sees_driver), -58, 9000) = 'waiting', 'the same token again');
  perform pg_temp.check((select ctid from public.ride_proximity_events
                          where request_id = '00000000-0000-0000-0000-0000000229e1' and side = 'rider') = v_ctid,
                        'nothing new: not written');
  -- Crossing the threshold is written.
  perform pg_temp.check(pg_temp.proof(v_rider, v_sees_driver, -85, 9000) = 'waiting', 'too weak');
  perform pg_temp.check((pg_temp.row_of('rider')).rssi = -85, 'falling below the threshold is written');
  perform pg_temp.check(pg_temp.proof(v_rider, v_sees_driver, -60, 9000) = 'waiting', 'close again');

  -- The driver sees the rider: matched (autostart off), and the pair remembered.
  perform pg_temp.check(pg_temp.proof(v_driver, v_sees_rider, -55, 7000) = 'matched', 'both sides: matched');
  perform pg_temp.check((select matched_at is not null from public.ride_ble_secrets
                          where request_id = '00000000-0000-0000-0000-0000000229e1'), 'the match is remembered');
  perform pg_temp.check((select count(*) = 2 from public.ride_proximity_events
                          where request_id = '00000000-0000-0000-0000-0000000229e1'), 'two rows: one per side');

  -- The rider has gone quiet (new builds stop after 'matched'): the driver,
  -- still close, is still told 'matched'; weak, 'waiting'.
  update public.ride_proximity_events set at = now() - interval '5 minutes'
   where request_id = '00000000-0000-0000-0000-0000000229e1' and side = 'rider';
  perform pg_temp.check(pg_temp.proof(v_driver, v_sees_rider, -55, 7000) = 'matched', 'matched before, still close');
  perform pg_temp.check(pg_temp.proof(v_driver, v_sees_rider, -90, 7000) = 'waiting', 'matched before, but weak now');

  -- Autostart needs both phones fresh, not just the remembered match.
  update public.settings_entries set values = '{"ble_enabled": true, "ble_autostart_no_pin": true}'
   where id = '72656c69-6162-4c69-8000-000000000001';
  perform pg_temp.check(pg_temp.proof(v_driver, v_sees_rider, -55, 7000) = 'matched', 'a stale rider: not started');
  perform pg_temp.check((select status = 'arrived' from public.ride_requests
                          where id = '00000000-0000-0000-0000-0000000229e1'), 'still waiting for the code');
  perform pg_temp.check(pg_temp.proof(v_rider, v_sees_driver, -60, 9000) = 'on_trip', 'both fresh: started');
  perform pg_temp.check((select status = 'on_trip' and start_method = 'ble' from public.ride_requests
                          where id = '00000000-0000-0000-0000-0000000229e1'), 'started by Bluetooth');
  perform pg_temp.check(pg_temp.proof(v_driver, v_sees_rider, -55, 7000) = 'on_trip', 'on the trip: said so');
end
$$;

-- 3. Realtime ---------------------------------------------------------------------------
select pg_temp.check(not exists (select 1 from pg_publication_tables
                                  where pubname = 'supabase_realtime' and schemaname = 'public'
                                    and tablename = 'messaging_devices'),
                     'messaging_devices is out of supabase_realtime (the admin page polls it)');
select pg_temp.check(not exists (select 1 from pg_publication where pubname = 'supabase_realtime')
                     or exists (select 1 from pg_publication_tables
                                 where pubname = 'supabase_realtime' and schemaname = 'public'
                                   and tablename = 'commission_tiers'),
                     'commission_tiers is in supabase_realtime');

rollback;

select 'perf_server2_0229: all passed';
