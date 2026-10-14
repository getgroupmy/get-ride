-- ============================================================================
-- Regression test for migration 0183: a sign-in code is readable by the
-- gateway that sends it and nobody else, admins included; admins can't queue
-- codes; a code that waited too long is failed, not sent.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sms_code_privacy.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000183a1'),  -- runs the gateway phone (an admin)
  ('00000000-0000-0000-0000-0000000183a2')   -- a sub-admin with one read-only page
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000183a%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000183a1', 'admin-settings-messaging', 'edit'),
  ('00000000-0000-0000-0000-0000000183a2', 'admin-help', 'read')
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
select pg_temp.as_user('00000000-0000-0000-0000-0000000183a1');
insert into ids
select 'gateway', (public.messaging_heartbeat('gw-183', 'Gateway', 'android', 'gateway', '{sms}', '+60111')).id;
reset role;
insert into public.messaging_routes (channel, direction, transport, device_ids)
values ('otp', 'outbound', 'sms', array[(select id from ids where name = 'gateway')]);

-- Queued the way the sign-in hook does (as the server); one stale code too.
insert into public.sms_outbox (channel, to_phone, body) values ('otp', '+60123450183', 'Your GET.ride code is 246813.');
insert into public.sms_outbox (channel, to_phone, body, created_at)
values ('otp', '+60123450184', 'Your GET.ride code is 999999.', now() - interval '20 minutes');

-- 1. Admins see the job, not the code ------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000183a2');
do $$
begin
  if not exists (select 1 from public.sms_outbox where to_phone = '+60123450183') then
    raise exception 'FAILED: the admin panel lost the job';
  end if;
  if exists (select 1 from public.sms_outbox where body ~ '[0-9]' and channel = 'otp') then
    raise exception 'FAILED: an admin read a sign-in code';
  end if;
end $$;
select pg_temp.refused($q$select * from public.sms_otp_secret$q$, 'an admin reading the codes table');
select pg_temp.refused(
  $q$insert into public.sms_outbox (channel, to_phone, body) values ('otp', '+60123456789', 'Your code is 1')$q$,
  'an admin queuing a sign-in code by hand');

-- 2. The gateway gets the real text; the stale code is failed --------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000183a1');
do $$
declare
  jobs public.sms_outbox[];
begin
  select array_agg(j) into jobs from public.gateway_claim_sms((select id from ids where name = 'gateway')) j;
  if coalesce(array_length(jobs, 1), 0) <> 1 or jobs[1].body <> 'Your GET.ride code is 246813.' then
    raise exception 'FAILED: the gateway claimed %', jobs;
  end if;
end $$;

reset role;
do $$
begin
  if (select status from public.sms_outbox where to_phone = '+60123450184') is distinct from 'failed' then
    raise exception 'FAILED: a 20-minute-old code was not failed';
  end if;
  if (select body from public.sms_outbox where to_phone = '+60123450183') <> 'Your GET.ride code is ••••••.' then
    raise exception 'FAILED: the queue row was not masked';
  end if;
end $$;

select 'sms_code_privacy: all passed';
rollback;
