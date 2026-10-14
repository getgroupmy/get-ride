-- ============================================================================
-- Regression test for migration 0149: the sign-in SMS hook keeps to the
-- admin's limits and hands allowed codes to the gateway phone.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sms_signin_limits.sql
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
create or replace function pg_temp.ask(p_phone text, p_code text default '123456') returns jsonb language sql as $$
  select public.send_sms_hook(jsonb_build_object(
    'user', jsonb_build_object('id', '00000000-0000-0000-0000-0000000149a1', 'phone', p_phone),
    'sms', jsonb_build_object('otp', p_code)));
$$;

-- A clean slate for the test: default limits, nothing logged, one gateway phone.
delete from public.sms_log;
update public.sms_settings set enabled = true, per_phone_per_hour = 3, per_phone_per_day = 10,
  min_resend_seconds = 60, global_per_hour = 500, allowed_prefixes = '{+60}', blocked_numbers = '{}',
  message_template = 'Your GET.ride code is {code}. Do not share it.';
delete from public.messaging_routes where channel = 'otp';

-- 1. No gateway phone: refused, not queued for nobody -----------------------------
select pg_temp.check(pg_temp.ask('+60123456789') #>> '{error,http_code}' = '503', 'no gateway phone, no code');
select pg_temp.check((select reason = 'gateway_offline' from public.sms_log order by id desc limit 1), 'logged as gateway_offline');

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000149d1') on conflict do nothing;
insert into public.messaging_devices (id, user_id, device_id, label, kind, capabilities, last_seen_at)
values ('00000000-0000-0000-0000-0000000149e1', '00000000-0000-0000-0000-0000000149d1', 'gw-149', 'Gateway', 'gateway',
        '{sms}', now());
insert into public.messaging_routes (channel, direction, transport, enabled, device_ids)
values ('otp', 'outbound', 'sms', true, array['00000000-0000-0000-0000-0000000149e1'::uuid]);

-- 2. Allowed: queued on the otp channel with the code in the template --------------
select pg_temp.check(pg_temp.ask('+60 12-345 6789', '654321') = '{}'::jsonb, 'an allowed code is accepted');
select pg_temp.check((select o.to_phone = '+60123456789' and o.channel = 'otp' and o.status = 'queued'
                             and o.body = 'Your GET.ride code is ••••••. Do not share it.'
                             and s.body = 'Your GET.ride code is 654321. Do not share it.'
                        from public.sms_outbox o join public.sms_otp_secret s on s.outbox_id = o.id
                       order by o.created_at desc limit 1),
  'the code is queued for the gateway (kept apart, masked in the queue), number normalised');
select pg_temp.check((select status = 'queued' and outbox_id is not null from public.sms_log order by id desc limit 1),
  'and logged as queued');

-- 3. Too soon: refused with the wait ------------------------------------------------
select pg_temp.check(pg_temp.ask('+60123456789') #>> '{error,http_code}' = '429', 'a second code within a minute is refused');
select pg_temp.check(pg_temp.ask('+60123456789') #>> '{error,message}' like 'Please wait 60 seconds%', 'and says how long to wait');

-- 4. Per hour per number ---------------------------------------------------------------
update public.sms_log set created_at = created_at - interval '2 minutes';
select pg_temp.ask('+60123456789');
update public.sms_log set created_at = created_at - interval '2 minutes';
select pg_temp.ask('+60123456789');
update public.sms_log set created_at = created_at - interval '2 minutes';
select pg_temp.check((select count(*) = 3 from public.sms_log where phone = '+60123456789' and status = 'queued'),
  'three codes in the hour');
select pg_temp.check((select pg_temp.ask('+60123456789') #>> '{error,message}') like 'Too many SMS codes for this number. Try again in % minutes.',
  'the fourth is refused, saying when to try again');

-- 5. Country prefix, blocked number, switched off ------------------------------------------
select pg_temp.check(pg_temp.ask('+6591234567') #>> '{error,http_code}' = '403', 'a number outside +60 is refused');
update public.sms_settings set blocked_numbers = '{+60 11-1111 1111}';
select pg_temp.check(pg_temp.ask('+601111111111') #>> '{error,http_code}' = '403', 'a blocked number is refused');
update public.sms_settings set enabled = false;
select pg_temp.check(pg_temp.ask('+60199999999') #>> '{error,http_code}' = '503', 'switched off, nothing is sent');
update public.sms_settings set enabled = true, allowed_prefixes = '{}';
select pg_temp.check(pg_temp.ask('+6591234567') = '{}'::jsonb, 'an empty prefix list allows every country');

-- 6. A gateway phone gone quiet ----------------------------------------------------------
update public.messaging_devices set last_seen_at = now() - interval '11 minutes'
 where id = '00000000-0000-0000-0000-0000000149e1';
select pg_temp.check(pg_temp.ask('+60188888888') #>> '{error,http_code}' = '503', 'a silent gateway sends nothing');

-- 7. Settings: limits checked, admins only --------------------------------------------------
do $$
begin
  begin
    update public.sms_settings set per_phone_per_hour = 5, per_phone_per_day = 2;
    raise exception 'FAILED: a daily limit under the hourly one was accepted';
  exception when check_violation then
    null;
  end;
  begin
    update public.sms_settings set message_template = 'No code here';
    raise exception 'FAILED: a template without {code} was accepted';
  exception when check_violation then
    null;
  end;
end $$;

select pg_temp.check(not has_function_privilege('authenticated', 'public.send_sms_hook(jsonb)', 'execute')
                 and not has_function_privilege('anon', 'public.send_sms_hook(jsonb)', 'execute'),
  'only Auth calls the hook');
select pg_temp.check(not has_table_privilege('anon', 'public.sms_log', 'select'), 'anon reads no SMS log');

select 'sms_signin_limits: all passed';
rollback;
