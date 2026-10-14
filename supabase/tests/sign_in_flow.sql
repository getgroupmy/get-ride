-- ============================================================================
-- Regression test for migration 0192: the admin's PIN policy, tries left
-- after a wrong PIN, whether an account still has to choose a PIN, and a
-- refused sign-in SMS saying when to try again.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sign_in_flow.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
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

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000192a1'),  -- has a PIN
  ('00000000-0000-0000-0000-0000000192a2'),  -- no PIN yet
  ('00000000-0000-0000-0000-0000000192c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000192%'
on conflict do nothing;
update public.profiles set phone = '+60100000192' where id = '00000000-0000-0000-0000-0000000192a1';
update public.profiles set phone = '+60100000193' where id = '00000000-0000-0000-0000-0000000192a2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000192c1', '*', 'edit')
on conflict do nothing;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000192a1","role":"authenticated"}', true);
set local role authenticated;
select public.set_login_pin('135790', null);

-- 1. The account says whether it still needs a PIN -------------------------------------------
select pg_temp.check((public.my_sign_in_state()->>'pinSet')::boolean, 'an account with a PIN is done');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000192a2","role":"authenticated"}', true);
select pg_temp.check(not (public.my_sign_in_state()->>'pinSet')::boolean
                     and (public.my_sign_in_state()->>'pinRequired')::boolean,
  'an account without a PIN must choose one');

-- 2. The policy is the admin's, within limits ----------------------------------------------------
select pg_temp.refused($q$select public.set_pin_policy('{"maxAttempts":3}')$q$, 'a user changing the PIN policy');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000192c1","role":"authenticated"}', true);
select pg_temp.check((public.set_pin_policy('{"maxAttempts":1,"lockMinutes":0}')->>'maxAttempts')::int = 3,
  'at least 3 tries');
select pg_temp.check((public.pin_policy()->>'lockMinutes')::int = 1, 'at least a minute locked');
select public.set_pin_policy('{"maxAttempts":4,"lockMinutes":20}');
reset role;
select set_config('request.jwt.claims', '', true);

-- 3. Tries left, then the lock, as the policy says --------------------------------------------------
select pg_temp.check(public.pin_attempts_left('+60100000192') = 4, 'four tries to start with');
select pg_temp.check(public.pin_login_check('+60100000192', '000000', '198.51.100.1') is null, 'a wrong PIN');
select pg_temp.check(public.pin_attempts_left('60100000192') = 3, 'three left after one wrong PIN');
select public.pin_login_check('+60100000192', '000000', '198.51.100.2');
select public.pin_login_check('+60100000192', '000000', '198.51.100.3');
select pg_temp.check(public.pin_attempts_left('+60100000192') = 1, 'one left');
select public.pin_login_check('+60100000192', '000000', '198.51.100.4');
select pg_temp.check(public.pin_attempts_left('+60100000192') = 0, 'none left once locked');
select pg_temp.check((select pin_locked_until between now() + interval '19 minutes' and now() + interval '21 minutes'
                        from public.profiles where id = '00000000-0000-0000-0000-0000000192a1'),
  'locked for the admin''s 20 minutes');
select pg_temp.check(public.pin_attempts_left('+60100000193') is null, 'nothing said about an account without a PIN');
select pg_temp.check(public.pin_attempts_left('+60199999999') is null, 'nothing said about an unknown number');
select pg_temp.check(not has_function_privilege('anon', 'public.pin_attempts_left(text)', 'execute')
                 and not has_function_privilege('authenticated', 'public.pin_attempts_left(text)', 'execute')
                 and has_function_privilege('service_role', 'public.pin_attempts_left(text)', 'execute'),
  'only pin-login asks how many tries are left');
select pg_temp.check(not has_function_privilege('anon', 'public.my_sign_in_state()', 'execute'),
  'signed out, there is no account to ask about');

-- 4. A refused sign-in SMS says when -------------------------------------------------------------------
select pg_temp.check(public.sms_refusal_message('per_phone_hour', 170)#>>'{error,message}'
                     = 'Too many SMS codes for this number. Try again in 3 minutes.', 'hourly limit in minutes');
select pg_temp.check(public.sms_refusal_message('per_phone_day', 7200)#>>'{error,message}' like '%2 hours.',
  'daily limit in hours');
select pg_temp.check(public.sms_refusal_message('global_hour', 40)#>>'{error,message}' like '%1 minute.',
  'busy, in a minute');
update public.sms_settings set enabled = true, per_phone_per_hour = 2, min_resend_seconds = 30 where id = 1;
insert into public.sms_log (phone, status, created_at) values
  ('+60100000192', 'queued', now() - interval '50 minutes'),
  ('+60100000192', 'queued', now() - interval '10 minutes');
select pg_temp.check(public.sms_otp_wait_seconds('+60100000192', 'per_phone_hour') between 590 and 610,
  'the hourly limit lifts when the oldest code drops out of the hour');

select 'sign_in_flow: all passed';
rollback;
