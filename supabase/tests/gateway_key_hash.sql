-- ============================================================================
-- Gateway and session keys are kept as a hash only (0190, 0226; checked
-- again for the security tester's finding answered in 0240).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gateway_key_hash.sql
--
-- * no column could hold a plaintext key, and no stored value is the key;
-- * a key paired before today (a stored hash, as every key since 0190 is)
--   still claims, heartbeats and checks in; a wrong key does not;
-- * anon and authenticated read no hash, directly or through an admin list.
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
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.refused(text, text) to anon, authenticated;

-- 1. The tables hold hashes, nothing else that could be a key -----------------------------------
select pg_temp.check((select array_agg(column_name::text order by column_name) from information_schema.columns
                       where table_schema = 'public' and table_name = 'gateway_keys')
                     = array['created_at', 'device_row', 'key_hash', 'last_used_at', 'paired_by'],
                     'gateway_keys has no plaintext column');
select pg_temp.check(not exists (select 1 from information_schema.columns
                                  where table_schema = 'public' and table_name in ('session_keys', 'gateway_pairings')
                                    and column_name ~ '(^|_)(key|code|secret|token)$'),
                     'session_keys and gateway_pairings keep no plaintext key or code');
select pg_temp.check(not exists (select 1 from information_schema.columns
                                  where table_schema = 'public' and table_name = 'messaging_devices'
                                    and column_name ~ '(^|_)(key|secret|token)$'),
                     'messaging_devices keeps no key');

-- 2. A gateway paired earlier: its row is the hash of the key the phone keeps -------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000240a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000240a1') on conflict do nothing;
insert into public.messaging_devices (id, user_id, device_id, label, platform, kind, capabilities)
values ('00000000-0000-0000-0000-0000000240d1', '00000000-0000-0000-0000-0000000240a1', 'phone-0240',
        'Old gateway', 'android', 'gateway', array['sms']);
-- The key as the phone stores it: 64 hex characters, from gateway_pair.
create temp table k as select repeat('0240abcd', 8) as key;
grant select on k to anon, authenticated;
insert into public.gateway_keys (device_row, key_hash)
select '00000000-0000-0000-0000-0000000240d1', encode(extensions.digest(convert_to(key, 'UTF8'), 'sha256'), 'hex') from k;

select pg_temp.check((select key_hash ~ '^[0-9a-f]{64}$' and key_hash <> (select key from k)
                        from public.gateway_keys where device_row = '00000000-0000-0000-0000-0000000240d1'),
                     'the stored value is a sha256, not the key');
select pg_temp.check(not exists (select 1 from public.gateway_keys g
                                  where to_jsonb(g)::text like '%' || (select key from k) || '%'),
                     'the key appears nowhere in its row');

insert into public.messaging_routes (channel, direction, transport, device_ids)
values ('otp', 'outbound', 'sms', array['00000000-0000-0000-0000-0000000240d1'::uuid])
on conflict (channel, direction) do update set transport = 'sms', enabled = true, device_ids = excluded.device_ids;
insert into public.sms_outbox (channel, to_phone, body) values ('otp', '+60120000240', 'Your GET.ride code is 0240');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.check(public.gateway_key_heartbeat((select key from k))->>'label' = 'Old gateway', 'the old key heartbeats');
select pg_temp.check(public.gateway_key_check((select key from k))->>'label' = 'Old gateway', 'the old key checks in to the relay');
select pg_temp.check((select count(*) = 1 from public.gateway_key_claim((select key from k), 10) j
                       where j.to_phone = '+60120000240'), 'the old key still claims its work');

-- 3. A wrong key gets nothing ------------------------------------------------------------------------
select pg_temp.refused($q$select public.gateway_key_claim(repeat('0240abce', 8), 10)$q$, 'claiming with a wrong key');
select pg_temp.refused(format('select public.gateway_key_claim(%L, 10)', upper((select key from k))), 'claiming with the key in capitals');
select pg_temp.refused($q$select public.gateway_key_claim(
  (select key_hash from public.gateway_keys where device_row = '00000000-0000-0000-0000-0000000240d1'), 10)$q$,
  'claiming with the stored hash');
select pg_temp.refused($q$select public.gateway_key_heartbeat('')$q$, 'an empty key');

-- 4. The API roles read no hash ----------------------------------------------------------------------
select pg_temp.refused($q$select key_hash from public.gateway_keys$q$, 'anon reading gateway key hashes');
select pg_temp.refused($q$select key_hash from public.session_keys$q$, 'anon reading session key hashes');
select pg_temp.refused($q$select public.gateway_secret_hash('x')$q$, 'anon hashing through the server');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000240a1', 'role', 'authenticated')::text, true);
select pg_temp.refused($q$select key_hash from public.gateway_keys$q$, 'authenticated reading gateway key hashes');
select pg_temp.refused($q$select key_hash from public.session_keys$q$, 'authenticated reading session key hashes');
reset role;

select pg_temp.check(not exists (
  select 1 from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
     and (pg_get_function_result(p.oid) ~ 'key_hash|code_hash'
          or exists (select 1 from pg_type t where t.oid = p.prorettype
                      and t.typrelid in ('public.gateway_keys'::regclass, 'public.session_keys'::regclass,
                                         'public.gateway_pairings'::regclass)))),
  'no function the API roles may call returns a key or code hash');

rollback;

select 'gateway_key_hash: all passed';
