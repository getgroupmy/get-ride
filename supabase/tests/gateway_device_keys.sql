-- ============================================================================
-- Regression test for migration 0190: a gateway phone pairs once with a code
-- from a full admin and then runs on its own device key, without a sign-in.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gateway_device_keys.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000190a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000190a2')   -- sub-admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000190a%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000190a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000190a2', 'admin-messaging', 'edit')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
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
grant execute on function pg_temp.as_user(uuid), pg_temp.as_anon(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text) to anon, authenticated;

create temp table vals (k text primary key, v text);
grant all on vals to anon, authenticated;

-- 1. Only a full admin makes a pairing code -----------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000190a2');
select pg_temp.refused($q$select public.admin_gateway_pairing_code('Gateway 1')$q$, 'a sub-admin pairing a gateway');
select pg_temp.as_user('00000000-0000-0000-0000-0000000190a1');
insert into vals select 'code', public.admin_gateway_pairing_code('Gateway 1')->>'code';
select pg_temp.check((select v ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$' from vals where k = 'code'), 'the code reads XXXX-XXXX');
reset role;

-- 2. The phone pairs with it, signed out -------------------------------------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.gateway_pair('WRONGCOD', 'phone-1')->>'error' = 'GATEWAY_PAIR_CODE', 'a wrong code is refused');
insert into vals select 'key', public.gateway_pair(lower((select v from vals where k = 'code')), 'phone-1',
                                                    'Ignored label', '+60111111111', '1.2.0')->>'key';
select pg_temp.check((select length(v) = 64 from vals where k = 'key'), 'the phone gets a device key');
select pg_temp.check(public.gateway_pair((select v from vals where k = 'code'), 'phone-2')->>'error' = 'GATEWAY_PAIR_CODE',
  'a code pairs one phone only');
select pg_temp.refused($q$select * from public.gateway_keys$q$, 'reading the keys');
select pg_temp.refused($q$select * from public.gateway_pairings$q$, 'reading the pairing codes');
reset role;
select pg_temp.check(not has_function_privilege('anon', 'public.gateway_by_key(text)', 'execute')
                 and not has_function_privilege('authenticated', 'public.gateway_claim_for(uuid, integer)', 'execute')
                 and not has_function_privilege('anon', 'public.gateway_report_for(uuid, uuid, boolean, text)', 'execute')
                 and not has_function_privilege('anon', 'public.gateway_receive_for(uuid, text, text, timestamptz)', 'execute'),
  'the inner functions are not callable');

select pg_temp.check((select count(*) = 2 from public.gateway_pair_failures where at = now()), 'wrong codes are counted');
select pg_temp.check((select d.label = 'Gateway 1' and d.kind = 'gateway' and d.capabilities = '{sms}'
                             and d.user_id = '00000000-0000-0000-0000-0000000190a1'
                        from public.messaging_devices d where d.device_id = 'phone-1'),
  'the device is the admin''s gateway, under the admin''s label');
select pg_temp.check(not exists (select 1 from public.gateway_keys
                                  where key_hash = (select v from vals where k = 'key')), 'only a hash is stored');

-- 3. The key does the gateway's work -----------------------------------------------------------
insert into public.messaging_routes (channel, direction, transport, device_ids)
values ('otp', 'outbound', 'sms', array[(select id from public.messaging_devices where device_id = 'phone-1')]),
       ('support_message', 'inbound', 'sms', array[(select id from public.messaging_devices where device_id = 'phone-1')])
on conflict (channel, direction) do update set transport = 'sms', enabled = true, device_ids = excluded.device_ids;
insert into public.sms_outbox (channel, to_phone, body) values ('otp', '+60123456789', 'Your GET.ride code is 4321');

set local role anon;
select pg_temp.as_anon();
select pg_temp.check((public.gateway_key_heartbeat((select v from vals where k = 'key'), null, null, '1.2.1'))->>'label'
                     = 'Gateway 1', 'the heartbeat answers');
do $$
declare
  jobs public.sms_outbox[];
begin
  select array_agg(j) into jobs from public.gateway_key_claim((select v from vals where k = 'key'), 10) j;
  if coalesce(array_length(jobs, 1), 0) <> 1 or jobs[1].body <> 'Your GET.ride code is 4321' then
    raise exception 'FAILED: the paired phone did not get the code to send (%)', jobs;
  end if;
  perform public.gateway_key_report((select v from vals where k = 'key'), jobs[1].id, true);
  perform public.gateway_key_receive((select v from vals where k = 'key'), '+60199999999', 'Hello');
end $$;
select pg_temp.refused($q$select public.gateway_key_claim('not-a-key', 10)$q$, 'claiming with a made-up key');
reset role;

select pg_temp.check((select status = 'sent' from public.sms_outbox where to_phone = '+60123456789' and channel = 'otp'
                       order by created_at desc limit 1), 'the job is reported sent');
select pg_temp.check((select channel = 'support_message' from public.sms_inbox where from_phone = '+60199999999'),
  'an incoming SMS is filed under its channel');
select pg_temp.check((select app_version = '1.2.1' from public.messaging_devices where device_id = 'phone-1'),
  'the heartbeat records the version');

-- 4. Removing the device ends the key ------------------------------------------------------------
delete from public.messaging_devices where device_id = 'phone-1';
set local role anon;
select pg_temp.as_anon();
select pg_temp.refused(format('select public.gateway_key_heartbeat(%L)', (select v from vals where k = 'key')),
  'a removed gateway carrying on');
reset role;

-- 5. Too many wrong codes slow pairing down (0220: per address, and for everyone) ---------------
insert into public.gateway_pair_failures (at, ip) select now(), '198.51.100.7' from generate_series(1, 10);
set local role anon;
select pg_temp.as_anon();
select set_config('request.headers', '{"cf-connecting-ip":"198.51.100.7"}', true);
select pg_temp.refused($q$select public.gateway_pair('ABCDEFGH', 'phone-3')$q$, 'guessing past the limit');
select set_config('request.headers', '{"cf-connecting-ip":"198.51.100.8"}', true);
select pg_temp.check(public.gateway_pair('ABCDEFGH', 'phone-3')->>'error' = 'GATEWAY_PAIR_CODE',
  'another address still pairs while one guesses');
reset role;
select pg_temp.check((select count(*) = 1 from public.gateway_pair_failures where ip = '198.51.100.8'),
  'a wrong code is counted against its address');
insert into public.gateway_pair_failures (at) select now() from generate_series(1, 500);
set local role anon;
select pg_temp.as_anon();
select pg_temp.refused($q$select public.gateway_pair('ABCDEFGH', 'phone-3')$q$, 'guessing past the overall limit');
reset role;

select 'gateway_device_keys: all passed';
rollback;
