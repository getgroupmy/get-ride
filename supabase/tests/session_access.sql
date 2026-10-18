-- ============================================================================
-- Regression test for migration 0226: session access. A full admin gives a
-- test session a key scoped to one phone number; the session texts that
-- number, reads what went out (sign-in codes in clear only with `codes`),
-- reads what came in from it, and the relay learns which phone carries its
-- internet. Removed or expired keys are refused; nobody else adds one.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/session_access.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000223a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000223a2')   -- sub-admin (messaging page)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id in ('00000000-0000-0000-0000-0000000223a1', '00000000-0000-0000-0000-0000000223a2')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000223a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000223a2', 'admin-settings-messaging', 'edit')
on conflict do nothing;

-- A paired gateway phone (0190), seen just now.
insert into public.messaging_devices (id, user_id, device_id, label, platform, kind, capabilities, sim_number)
values ('00000000-0000-0000-0000-0000002230d1', '00000000-0000-0000-0000-0000000223a1', 'phone-223', 'Office gateway',
        'android', 'gateway', '{sms}', '+60111111111');
insert into public.gateway_keys (device_row, key_hash, paired_by)
values ('00000000-0000-0000-0000-0000002230d1', public.gateway_secret_hash('device-key-223'),
        '00000000-0000-0000-0000-0000000223a1');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
grant execute on function pg_temp.as_anon() to authenticated, anon;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

create temp table keys (name text primary key, id uuid, key text);
grant all on keys to authenticated, anon;

set local role authenticated;

-- 1. Only a full admin adds one, and only a usable one ------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a2');
select pg_temp.refused($q$select public.admin_session_key_create('CI', '+60123456789')$q$, 'a sub-admin adding a session');

select pg_temp.as_user('00000000-0000-0000-0000-0000000223a1');
select pg_temp.refused($q$select public.admin_session_key_create('CI', '0123456789')$q$, 'a number without its country code');
select pg_temp.refused($q$select public.admin_session_key_create('', '+60123456789')$q$, 'a session without a name');
select pg_temp.refused($q$select public.admin_session_key_create('CI', '+60123456789', '{nothing}')$q$, 'no usable scope');
select pg_temp.refused($q$select public.admin_session_key_create('CI', '+60123456789', '{proxy}')$q$,
  'internet through no phone');

do $$
declare
  r jsonb;
begin
  r := public.admin_session_key_create('  Cloud session  ', '+60 12-345 6789', '{sms,codes,proxy,proxy}', 48,
         '00000000-0000-0000-0000-0000002230d1');
  if length(r->>'key') <> 64 then raise exception 'FAILED: key %', r; end if;
  insert into keys values ('full', (r->>'id')::uuid, r->>'key');
  r := public.admin_session_key_create('Sub only', '+60123456789', '{sms}', 9999);
  insert into keys values ('sms', (r->>'id')::uuid, r->>'key');
  if (select count(*) from public.admin_session_keys()) <> 2 then raise exception 'FAILED: list'; end if;
  if (select label from public.admin_session_keys() where id = (select id from keys where name = 'full')) <> 'Cloud session'
     or (select test_phone from public.admin_session_keys() where id = (select id from keys where name = 'full')) <> '+60123456789'
     or (select scopes from public.admin_session_keys() where id = (select id from keys where name = 'full')) <> '{codes,proxy,sms}'
     or (select proxy_label from public.admin_session_keys() where id = (select id from keys where name = 'full')) <> 'Office gateway' then
    raise exception 'FAILED: the list shows the key as added';
  end if;
  -- Hours are clamped to 30 days.
  if (select expires_at from public.admin_session_keys() where id = (select id from keys where name = 'sms'))
     > now() + interval '30 days 1 minute' then
    raise exception 'FAILED: a key may not outlast 30 days';
  end if;
end $$;

-- A sub-admin sees the list but cannot remove.
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a2');
do $$
begin
  if (select count(*) from public.admin_session_keys()) <> 2 then raise exception 'FAILED: a sub-admin sees the list'; end if;
end $$;
select pg_temp.refused(format('select public.admin_session_key_revoke(%L)', (select id from keys where name = 'full')),
  'a sub-admin removing a session');

-- 2. The session uses the key signed out ---------------------------------------
set local role anon;
select pg_temp.as_anon();
do $$
declare
  k text := (select key from keys where name = 'full');
  r jsonb;
begin
  r := public.session_key_info(k);
  if r->>'label' <> 'Cloud session' or r->>'test_phone' <> '+60123456789'
     or (r->'proxy'->>'online')::boolean is not true or r->'proxy'->>'label' <> 'Office gateway' then
    raise exception 'FAILED: info %', r;
  end if;

  r := public.session_key_send_sms(k, '  Hello from CI  ');
  if r->>'status' <> 'queued' or r->>'to' <> '+60123456789' or r->>'channel' <> 'support_message' then
    raise exception 'FAILED: send %', r;
  end if;
  perform public.session_key_send_sms(k, 'Promo', 'marketing');
end $$;
select pg_temp.refused(format('select public.session_key_send_sms(%L, %L, %L)', (select key from keys where name = 'full'),
  'Your code is 0000', 'otp'), 'a session queuing a sign-in code');
select pg_temp.refused(format('select public.session_key_send_sms(%L, %L)', (select key from keys where name = 'full'), '   '),
  'an empty message');
select pg_temp.refused($q$select public.session_key_send_sms('0000000000000000000000000000000000000000000000000000000000000000', 'x')$q$,
  'an unknown key');

-- The sign-in hook queues a code for the test number, and the gateway hears
-- back from it; another number's traffic is none of the session's business.
reset role;
insert into public.sms_outbox (channel, to_phone, body) values
  ('otp', '+60123456789', 'Your GET.ride code is 4321'),
  ('otp', '+60199999999', 'Your GET.ride code is 8765');
-- Rows made in one transaction share a created_at: spread them out so the
-- order is the one asserted below.
update public.sms_outbox set created_at = created_at - interval '2 minutes' where body = 'Hello from CI';
update public.sms_outbox set created_at = created_at - interval '1 minute' where body = 'Promo';
insert into public.sms_inbox (device_id, channel, from_phone, body, received_at) values
  ('00000000-0000-0000-0000-0000002230d1', 'support_message', '+60123456789', 'Reply from the test phone', now()),
  ('00000000-0000-0000-0000-0000002230d1', 'support_message', '+60199999999', 'Somebody else', now());
set local role anon;
select pg_temp.as_anon();

do $$
declare
  full_key text := (select key from keys where name = 'full');
  sms_key text := (select key from keys where name = 'sms');
  r jsonb;
begin
  -- Queued as the admin's, to the test number, text trimmed.
  if (select count(*) from public.sms_outbox where to_phone = '+60123456789' and body in ('Hello from CI', 'Promo')
        and created_by = '00000000-0000-0000-0000-0000000223a1' and status = 'queued') <> 2 then
    raise exception 'FAILED: the session''s SMS are not queued as the admin''s';
  end if;

  r := public.session_key_outbox(full_key);
  if jsonb_array_length(r) <> 3 then raise exception 'FAILED: outbox %', r; end if;
  if r->0->>'body' <> 'Your GET.ride code is 4321' then raise exception 'FAILED: codes in clear: %', r->0; end if;
  if r->1->>'body' <> 'Promo' or r->2->>'body' <> 'Hello from CI' then raise exception 'FAILED: outbox order %', r; end if;
  if exists (select 1 from jsonb_array_elements(r) e where e->>'to' <> '+60123456789') then
    raise exception 'FAILED: another number''s SMS shown';
  end if;

  -- Without `codes` the code is masked, as to a sub-admin.
  r := public.session_key_outbox(sms_key);
  if r->0->>'body' <> 'Your GET.ride code is ••••' then raise exception 'FAILED: masked code: %', r->0; end if;

  r := public.session_key_inbox(full_key);
  if jsonb_array_length(r) <> 1 or r->0->>'body' <> 'Reply from the test phone' or r->0->>'from' <> '+60123456789' then
    raise exception 'FAILED: inbox %', r;
  end if;
  if jsonb_array_length(public.session_key_inbox(full_key, now() + interval '1 minute')) <> 0 then
    raise exception 'FAILED: since';
  end if;

  r := public.session_key_proxy_check(full_key);
  if (r->>'ok')::boolean is not true or r->>'device' <> '00000000-0000-0000-0000-0000002230d1'
     or (r->>'online')::boolean is not true then
    raise exception 'FAILED: proxy check %', r;
  end if;
  if (public.gateway_key_check('device-key-223'))->>'id' <> '00000000-0000-0000-0000-0000002230d1' then
    raise exception 'FAILED: the relay cannot tell which phone a device key is';
  end if;
end $$;
select pg_temp.refused(format('select public.session_key_proxy_check(%L)', (select key from keys where name = 'sms')),
  'internet through a key without proxy');
select pg_temp.refused($q$select public.gateway_key_check('not-a-device-key')$q$, 'an unknown device key');

-- 3. Removed or expired: refused everywhere --------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a1');
select public.admin_session_key_revoke((select id from keys where name = 'full'));
reset role;
update public.session_keys set expires_at = now() - interval '1 second' where id = (select id from keys where name = 'sms');
set local role anon;
select pg_temp.as_anon();
select pg_temp.refused(format('select public.session_key_info(%L)', (select key from keys where name = 'full')), 'a removed key');
select pg_temp.refused(format('select public.session_key_outbox(%L)', (select key from keys where name = 'full')), 'a removed key reading');
select pg_temp.refused(format('select public.session_key_info(%L)', (select key from keys where name = 'sms')), 'an expired key');
select pg_temp.refused(format('select public.session_key_proxy_check(%L)', (select key from keys where name = 'full')),
  'a removed key''s internet');

reset role;
do $$
begin
  if (select revoked_at from public.session_keys where id = (select id from keys where name = 'full')) is null then
    raise exception 'FAILED: not revoked';
  end if;
  if (select uses from public.session_keys where id = (select id from keys where name = 'full')) < 5 then
    raise exception 'FAILED: uses are counted';
  end if;
  -- Grants: the session's calls are anon's; the admin's are not; the lookup is nobody's.
  if not has_function_privilege('anon', 'public.session_key_send_sms(text, text, text)', 'execute')
     or not has_function_privilege('anon', 'public.session_key_proxy_check(text)', 'execute')
     or not has_function_privilege('anon', 'public.gateway_key_check(text)', 'execute') then
    raise exception 'FAILED: a session needs no sign-in';
  end if;
  if has_function_privilege('anon', 'public.admin_session_key_create(text, text, text[], integer, uuid)', 'execute')
     or has_function_privilege('anon', 'public.admin_session_keys()', 'execute')
     or has_function_privilege('authenticated', 'public.session_by_key(text, text)', 'execute')
     or has_table_privilege('authenticated', 'public.session_keys', 'select') then
    raise exception 'FAILED: grants';
  end if;
end $$;

rollback;
