-- ============================================================================
-- Regression test for migration 0157: a ticket carries the next 30 minutes of
-- tokens, so phones without signal keep finding each other.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ble_tokens_ahead.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000157a1'),  -- rider
  ('00000000-0000-0000-0000-0000000157b1')   -- driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000157%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000157e1', '00000000-0000-0000-0000-0000000157a1',
   '00000000-0000-0000-0000-0000000157b1', 'arrived', 20, 20, 'KLCC');

insert into public.settings_entries (id, category, values)
values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging', '{"ble_enabled": true}')
on conflict (id) do update set values = excluded.values;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

create or replace function pg_temp.ticket(p_user uuid, p_ride uuid) returns jsonb language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  return public.get_trip_ble_token(p_ride);
end $$;

do $$
declare
  r jsonb := pg_temp.ticket('00000000-0000-0000-0000-0000000157a1', '00000000-0000-0000-0000-0000000157e1');
  d jsonb := pg_temp.ticket('00000000-0000-0000-0000-0000000157b1', '00000000-0000-0000-0000-0000000157e1');
  v_secret bytea := (select secret from public.ride_ble_secrets where request_id = '00000000-0000-0000-0000-0000000157e1');
  w bigint := public.ble_window();
  i int;
begin
  perform pg_temp.check(jsonb_array_length(r->'ahead') = 6, 'six windows ahead');
  for i in 0..5 loop
    perform pg_temp.check((r->'ahead'->i->>'token') = public.ble_token(v_secret, '00000000-0000-0000-0000-0000000157e1', 'rider', w + 1 + i),
                          'the rider''s token for each window ahead is the one the server will expect then');
    perform pg_temp.check((r->'ahead'->i->>'peer_token') = (d->'ahead'->i->>'token'),
                          'each side looks for what the other will be advertising');
    perform pg_temp.check((r->'ahead'->i->>'expires_at')::timestamptz = to_timestamp((w + 2 + i) * 300),
                          'each window ends five minutes after the last');
  end loop;
  perform pg_temp.check((r->'ahead'->0->>'token') <> (r->>'token'), 'the next window has a new token');
end $$;

-- A token issued ahead can't be reported early.
do $$
declare
  d jsonb := pg_temp.ticket('00000000-0000-0000-0000-0000000157b1', '00000000-0000-0000-0000-0000000157e1');
  v text;
begin
  v := public.ble_handshake_proof('00000000-0000-0000-0000-0000000157e1', d->'ahead'->1->>'peer_token', -50, 8000, null, null);
  perform pg_temp.check(v = 'no_match', 'a future window''s token is refused now (' || v || ')');
end $$;

-- Nothing ahead once the trip is under way.
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000157e1';
select pg_temp.check(pg_temp.ticket('00000000-0000-0000-0000-0000000157a1', '00000000-0000-0000-0000-0000000157e1')->'ahead' is null,
                     'on the trip: nothing ahead');

rollback;

select 'ble_tokens_ahead: all passed';
