-- ============================================================================
-- Regression test for migration 0236: the admin sets the longest a sign-in
-- code waits for the gateway phone (sms_settings.gateway_poll_max_seconds,
-- 5-60, default 15) and the paired phone reads it from its device-key
-- heartbeat, never from the settings table.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gateway_poll_wait_0236.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000236a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000236a2')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000236a%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000236a1', '*', 'edit')
on conflict do nothing;

-- A paired gateway with the key 'poll-wait-key'.
insert into public.messaging_devices (id, user_id, device_id, label, kind, capabilities)
values ('00000000-0000-0000-0000-0000000236d1', '00000000-0000-0000-0000-0000000236a1',
        'phone-0236', 'Gateway 0236', 'gateway', '{sms}');
insert into public.gateway_keys (device_row, key_hash)
values ('00000000-0000-0000-0000-0000000236d1', public.gateway_secret_hash('poll-wait-key'));

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

-- Start from the default, whatever the database holds.
update public.sms_settings set gateway_poll_max_seconds = default where id = 1;

-- 1. Default 15 s, answered by the heartbeat -----------------------------------------------------
select pg_temp.check((select gateway_poll_max_seconds = 15 from public.sms_settings where id = 1), 'the default is 15 s');
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.gateway_key_heartbeat('poll-wait-key') ->> 'poll_max_seconds' = '15',
  'the heartbeat answers the default');
select pg_temp.check(public.gateway_key_heartbeat('poll-wait-key') ->> 'id' = '00000000-0000-0000-0000-0000000236d1',
  'the heartbeat still answers the device row');
select pg_temp.refused($q$select public.gateway_key_heartbeat('not-a-key')$q$, 'a heartbeat with a made-up key');
reset role;

-- 2. The admin changes it; the next heartbeat carries it -----------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000236a1');
update public.sms_settings set gateway_poll_max_seconds = 8 where id = 1;
select pg_temp.refused($q$update public.sms_settings set gateway_poll_max_seconds = 4 where id = 1$q$, 'under 5 s');
select pg_temp.refused($q$update public.sms_settings set gateway_poll_max_seconds = 61 where id = 1$q$, 'over 60 s');
reset role;
select pg_temp.check((select gateway_poll_max_seconds = 8 from public.sms_settings where id = 1), 'the admin saved 8 s');

set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.gateway_key_heartbeat('poll-wait-key') ->> 'poll_max_seconds' = '8',
  'the next heartbeat answers the new value');
reset role;

-- 3. Nobody else reads or writes the setting ---------------------------------------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.refused($q$select gateway_poll_max_seconds from public.sms_settings$q$, 'anon reading sms_settings');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000236a2');
select pg_temp.check((select count(*) = 0 from public.sms_settings), 'a rider sees no settings row');
update public.sms_settings set gateway_poll_max_seconds = 60 where id = 1;
reset role;
select pg_temp.check((select gateway_poll_max_seconds = 8 from public.sms_settings where id = 1),
  'a rider can not change it');

select 'gateway_poll_wait_0236: all passed';
rollback;
