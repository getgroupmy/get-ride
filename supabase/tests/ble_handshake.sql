-- ============================================================================
-- Regression test for migration 0153: the phones find each other at the kerb.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ble_handshake.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000153a1'),  -- rider
  ('00000000-0000-0000-0000-0000000153b1'),  -- driver
  ('00000000-0000-0000-0000-0000000153c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000153%'
on conflict do nothing;

delete from public.settings_entries where id = '72656c69-6162-4c69-8000-000000000001';

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000153e1', '00000000-0000-0000-0000-0000000153a1',
   '00000000-0000-0000-0000-0000000153b1', 'arrived', 20, 20, 'KLCC'),
  ('00000000-0000-0000-0000-0000000153e2', '00000000-0000-0000-0000-0000000153a1',
   '00000000-0000-0000-0000-0000000153b1', 'arrived', 20, 20, 'KLCC');

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

-- A token for a ride's side, [p_back] windows ago. Run as postgres.
create or replace function pg_temp.token(p_request uuid, p_side text, p_back int default 0) returns text
language sql as $$
  select public.ble_token(b.secret, p_request, p_side, public.ble_window() - p_back)
    from public.ride_ble_secrets b where b.request_id = p_request;
$$;

-- 1. Off, as shipped: no tokens, proofs answered 'off' --------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000153b1');
select pg_temp.check((public.get_trip_ble_token('00000000-0000-0000-0000-0000000153e1')->>'enabled')::boolean = false,
                     'off: no token is handed out');
select pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', 'ab', -50, 6000, 3.1579, 101.7116) = 'off',
                     'off: a proof is not looked at');
reset role;

insert into public.settings_entries (id, category, values)
values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging', '{"ble_enabled": true}')
on conflict (id) do update set values = excluded.values;

-- 2. Strangers get nothing ----------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000153c1');
select pg_temp.refused($q$select public.get_trip_ble_token('00000000-0000-0000-0000-0000000153e1')$q$, 'a stranger reading the tokens');
select pg_temp.refused($q$select public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', 'ab', -50, 6000, 3.1579, 101.7116)$q$,
                       'a stranger sending a proof');
select pg_temp.check(not has_table_privilege('authenticated', 'public.ride_ble_secrets', 'select'), 'the ride keys are not readable');

-- 3. Each side gets its own token and the other's -------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000153b1');
do $$
declare
  d jsonb := public.get_trip_ble_token('00000000-0000-0000-0000-0000000153e1');
  r jsonb;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153a1');
  r := public.get_trip_ble_token('00000000-0000-0000-0000-0000000153e1');
  perform pg_temp.check(d->>'side' = 'driver' and r->>'side' = 'rider', 'each side is told which it is');
  perform pg_temp.check(d->>'token' ~ '^[0-9a-f]{16}$', 'a token is 8 bytes in hex');
  perform pg_temp.check(d->>'token' = r->>'peer_token' and r->>'token' = d->>'peer_token', 'the two sides agree');
  perform pg_temp.check(d->>'token' <> r->>'token', 'the two sides differ');
end $$;
reset role;

-- (Blocks that make tokens with pg_temp.token run as postgres; the functions
-- still check the caller by auth.uid().)

-- 4. What doesn't match --------------------------------------------------------------------
-- (the driver reporting the rider's token from 2 windows ago, the other ride's, its own)
select pg_temp.as_user('00000000-0000-0000-0000-0000000153b1');
select public.get_trip_ble_token('00000000-0000-0000-0000-0000000153e2');
do $$
declare
  v_old text := pg_temp.token('00000000-0000-0000-0000-0000000153e1', 'rider', 2);
  v_other text := pg_temp.token('00000000-0000-0000-0000-0000000153e2', 'rider');
  v_own text := pg_temp.token('00000000-0000-0000-0000-0000000153e1', 'driver');
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153b1');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_old, -50, 6000, 3.1579, 101.7116) = 'no_match',
                        'a replayed old token');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_other, -50, 6000, 3.1579, 101.7116) = 'no_match',
                        'another trip''s token');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_own, -50, 6000, 3.1579, 101.7116) = 'no_match',
                        'its own token');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1',
                        pg_temp.token('00000000-0000-0000-0000-0000000153e1', 'rider', 1), -50, 6000, 3.1579, 101.7116) = 'waiting',
                        'last window''s token still matches; one side alone waits');
end $$;
select pg_temp.check((select count(*) = 4 from public.ride_proximity_events where request_id = '00000000-0000-0000-0000-0000000153e1'),
                     'every proof is recorded');

-- 5. Both sides, but too far apart, too weak or too short: waiting ----------------------------
do $$
declare
  v_rider_sees text := pg_temp.token('00000000-0000-0000-0000-0000000153e1', 'driver');
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153a1');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_rider_sees, -85, 6000, 3.15805, 101.7117) = 'waiting',
                        'too weak a signal');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_rider_sees, -50, 2000, 3.15805, 101.7117) = 'waiting',
                        'seen too briefly');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_rider_sees, -50, 6000, 3.16150, 101.7116) = 'waiting',
                        'GPS fixes 400 m apart');
  -- 6. Close, strong, long enough: the right car (autostart off, so not started) ----------
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1', v_rider_sees, -60, 6000, 3.15805, 101.7117) = 'matched',
                        'both sides, close: matched');
end $$;
select pg_temp.check((select status = 'arrived' from public.ride_requests where id = '00000000-0000-0000-0000-0000000153e1'),
                     'autostart off: the trip still waits for the code');

-- 7. Autostart on: the trip starts by Bluetooth ------------------------------------------------
update public.settings_entries set values = '{"ble_enabled": true, "ble_autostart_no_pin": true}'
 where id = '72656c69-6162-4c69-8000-000000000001';
do $$
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153b1');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e1',
                        pg_temp.token('00000000-0000-0000-0000-0000000153e1', 'rider'), -55, 7000, 3.1579, 101.7116) = 'on_trip',
                        'autostart on: matched and started');
end $$;
select pg_temp.check((select status = 'on_trip' and start_method = 'ble' and started_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000153e1'),
                     'started by Bluetooth, and stamped');

-- 8. Not from 'accepted': the driver isn't at the kerb yet --------------------------------------
update public.ride_requests set status = 'accepted' where id = '00000000-0000-0000-0000-0000000153e2';
do $$
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153a1');
  perform public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e2',
          pg_temp.token('00000000-0000-0000-0000-0000000153e2', 'driver'), -55, 7000, 3.1579, 101.7116);
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153b1');
  perform pg_temp.check(public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e2',
                        pg_temp.token('00000000-0000-0000-0000-0000000153e2', 'rider'), -55, 7000, 3.1579, 101.7116) = 'matched',
                        'accepted: matched but not started');
end $$;
select pg_temp.check((select status = 'accepted' from public.ride_requests where id = '00000000-0000-0000-0000-0000000153e2'),
                     'accepted: not started');

-- 9. Rate limited, clients can't run the helpers ------------------------------------------------
set local role authenticated;
do $$
declare
  i int;
  v text;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000153a1');
  for i in 1..40 loop
    v := public.ble_handshake_proof('00000000-0000-0000-0000-0000000153e2', 'ff', -55, 7000, 3.1579, 101.7116);
  end loop;
  perform pg_temp.check(v like 'rate_limited:%', 'a flood of proofs is slowed down');
end $$;
reset role;
select pg_temp.check(not has_function_privilege('authenticated', 'public.ble_token(bytea, uuid, text, bigint)', 'execute'),
                     'no client makes tokens');
select pg_temp.check(not has_function_privilege('anon', 'public.get_trip_ble_token(uuid)', 'execute'), 'anon gets no tokens');

rollback;

select 'ble_handshake: all passed';
