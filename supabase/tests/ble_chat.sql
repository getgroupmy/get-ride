-- ============================================================================
-- Regression test for migration 0155: the chat key for Bluetooth chat.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ble_chat.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000155a1'),  -- rider
  ('00000000-0000-0000-0000-0000000155b1'),  -- driver
  ('00000000-0000-0000-0000-0000000155c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000155%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000155e1', '00000000-0000-0000-0000-0000000155a1',
   '00000000-0000-0000-0000-0000000155b1', 'arrived', 20, 20, 'KLCC'),
  ('00000000-0000-0000-0000-0000000155e2', '00000000-0000-0000-0000-0000000155a1',
   '00000000-0000-0000-0000-0000000155b1', 'arrived', 20, 20, 'KLCC');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;

create or replace function pg_temp.ticket(p_user uuid, p_ride uuid) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user(p_user);
  return public.get_trip_ble_token(p_ride);
end $$;

-- 1. Bluetooth on, chat off: no chat key ---------------------------------------------------
insert into public.settings_entries (id, category, values)
values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging', '{"ble_enabled": true}')
on conflict (id) do update set values = excluded.values;
select pg_temp.check((public.reliability_ble()->>'chat')::boolean = false, 'chat is off by default');
select pg_temp.check(pg_temp.ticket('00000000-0000-0000-0000-0000000155a1', '00000000-0000-0000-0000-0000000155e1')->>'chat_key' is null,
                     'chat off: no key handed out');

-- 2. Chat on: both sides get the same key, unlike anything advertised, and unlike another ride's
update public.settings_entries set values = '{"ble_enabled": true, "ble_chat": true}'
 where id = '72656c69-6162-4c69-8000-000000000001';
do $$
declare
  r jsonb := pg_temp.ticket('00000000-0000-0000-0000-0000000155a1', '00000000-0000-0000-0000-0000000155e1');
  d jsonb := pg_temp.ticket('00000000-0000-0000-0000-0000000155b1', '00000000-0000-0000-0000-0000000155e1');
  other jsonb := pg_temp.ticket('00000000-0000-0000-0000-0000000155b1', '00000000-0000-0000-0000-0000000155e2');
begin
  perform pg_temp.check(r->>'chat_key' ~ '^[0-9a-f]{64}$', 'the key is 32 bytes in hex');
  perform pg_temp.check(r->>'chat_key' = d->>'chat_key', 'both sides hold the same key');
  perform pg_temp.check(position(r->>'token' in r->>'chat_key') = 0 and position(d->>'token' in r->>'chat_key') = 0,
                        'the key is not the advertised tokens');
  perform pg_temp.check(other->>'chat_key' <> r->>'chat_key', 'another ride has another key');
end $$;

-- 3. Strangers still get nothing ----------------------------------------------------------------
do $$
begin
  perform pg_temp.ticket('00000000-0000-0000-0000-0000000155c1', '00000000-0000-0000-0000-0000000155e1');
  raise exception 'FAILED: a stranger got a ticket';
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;

-- 4. Not once the trip is under way ---------------------------------------------------------------
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000155e2';
select pg_temp.check(pg_temp.ticket('00000000-0000-0000-0000-0000000155b1', '00000000-0000-0000-0000-0000000155e2')->>'chat_key' is null,
                     'on the trip: no key');

rollback;

select 'ble_chat: all passed';
