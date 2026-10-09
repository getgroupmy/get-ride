-- ============================================================================
-- Regression test for migrations 0120 / 0121: devices register themselves,
-- only an admin's gateway carries SMS, a gateway gets only the jobs routed to
-- it, and the routes are the admin's.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/messaging_gateway.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000120a1'),  -- runs the gateway phone
  ('00000000-0000-0000-0000-0000000120a2')   -- someone else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id in ('00000000-0000-0000-0000-0000000120a1', '00000000-0000-0000-0000-0000000120a2')
on conflict do nothing;
-- The gateway phone is signed in as an admin (0121).
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000120a1', 'admin-settings-messaging', 'edit')
on conflict do nothing;

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

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

set local role authenticated;

-- 1. Devices register; an app install never carries SMS ---------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000120a1');
insert into ids
select 'gateway', (public.messaging_heartbeat('phone-1', 'Gateway phone', 'android', 'gateway', '{sms}', '+60111')).id;
do $$
declare d public.messaging_devices;
begin
  d := public.messaging_heartbeat('laptop-1', null, 'web', 'app', '{sms,voip}');
  if d.capabilities <> '{voip}' then raise exception 'FAILED: an app install claimed %', d.capabilities; end if;
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000120a2');
select pg_temp.refused($q$insert into public.messaging_routes (channel, direction, transport) values ('otp', 'outbound', 'sms')$q$,
  'a non-admin writing a route');

-- 2. The admin routes outbound OTP to the gateway, and queues two jobs --------
reset role;
insert into public.messaging_routes (channel, direction, transport, device_ids)
values ('otp', 'outbound', 'sms', array[(select id from ids where name = 'gateway')]),
       ('support_message', 'inbound', 'sms', array[(select id from ids where name = 'gateway')]);
insert into public.sms_outbox (channel, to_phone, body) values
  ('otp', '+60123456789', 'Your code is 1234'),
  ('marketing', '+60123456789', 'Not routed to this gateway');
set local role authenticated;

-- 3. The gateway claims only its channel, then reports it sent ----------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000120a1');
do $$
declare
  jobs public.sms_outbox[];
  dev uuid := (select id from ids where name = 'gateway');
begin
  select array_agg(j) into jobs from public.gateway_claim_sms(dev) j;
  if coalesce(array_length(jobs, 1), 0) <> 1 or jobs[1].channel <> 'otp' or jobs[1].status <> 'sending' then
    raise exception 'FAILED: claimed %', jobs;
  end if;
  perform public.gateway_report_sms(dev, jobs[1].id, true);
  if (public.gateway_receive_sms(dev, '+60199999999', 'Hello support')).channel is distinct from 'support_message' then
    raise exception 'FAILED: an inbound SMS was not filed under its channel';
  end if;
end $$;

-- 4. Someone else cannot act as the gateway, nor stand one up (0121) ---------
select pg_temp.as_user('00000000-0000-0000-0000-0000000120a2');
select pg_temp.refused(
  format('select * from public.gateway_claim_sms(%L)', (select id from ids where name = 'gateway')),
  'claiming jobs as another user''s gateway');
select pg_temp.refused($q$select public.messaging_heartbeat('phone-2', null, 'android', 'gateway', '{sms}')$q$,
  'a non-admin registering a gateway');
-- An app install is still anyone's (it only takes calls once routed).
select public.messaging_heartbeat('phone-2', null, 'android', 'app', '{voip}');

-- 5. A gateway whose admin access is removed stops taking jobs ---------------
reset role;
delete from public.admin_access where profile_id = '00000000-0000-0000-0000-0000000120a1';
insert into public.sms_outbox (channel, to_phone, body) values ('otp', '+60123456789', 'Your code is 5678');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000120a1');
select pg_temp.refused(
  format('select * from public.gateway_claim_sms(%L)', (select id from ids where name = 'gateway')),
  'a former admin''s gateway claiming jobs');

reset role;
do $$
begin
  if (select status from public.sms_outbox where body = 'Your code is 1234') <> 'sent' then
    raise exception 'FAILED: the OTP job is not sent';
  end if;
  if (select status from public.sms_outbox where body = 'Your code is 5678') <> 'queued' then
    raise exception 'FAILED: a former admin''s gateway took a job';
  end if;
  if (select status from public.sms_outbox where channel = 'marketing') <> 'queued' then
    raise exception 'FAILED: an unrouted job was taken';
  end if;
  if has_function_privilege('anon', 'public.gateway_claim_sms(uuid, integer)', 'execute') then
    raise exception 'FAILED: anon can claim SMS jobs';
  end if;
end $$;

rollback;
