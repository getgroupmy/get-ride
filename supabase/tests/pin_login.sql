-- ============================================================================
-- Regression test for migration 0172: the PIN check pin-login calls is the
-- service role's alone, keeps the per-address limit on the address it is
-- handed, and the lockout; the apps' verify_pin_for_login still works.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pin_login.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

-- Who may call what.
select pg_temp.check(
  not has_function_privilege('anon', 'public.pin_login_check(text, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.pin_login_check(text, text, text)', 'execute'),
  'pin_login_check is not for the apps');
select pg_temp.check(
  has_function_privilege('service_role', 'public.pin_login_check(text, text, text)', 'execute'),
  'the service role (pin-login) may call pin_login_check');
select pg_temp.check(
  not has_function_privilege('anon', 'public.pin_check(text, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.pin_check(text, text, text)', 'execute')
  and not has_function_privilege('service_role', 'public.pin_check(text, text, text)', 'execute'),
  'pin_check is internal');
select pg_temp.check(
  has_function_privilege('anon', 'public.verify_pin_for_login(text, text)', 'execute'),
  'verify_pin_for_login stays callable by the signed-out apps');

-- An account with a PIN.
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000172a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000172a1') on conflict do nothing;
update public.profiles set phone = '+60100000172' where id = '00000000-0000-0000-0000-0000000172a1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000172a1","role":"authenticated"}', true);
set local role authenticated;
select public.set_login_pin('246810', null);
reset role;
select set_config('request.jwt.claims', '', true);

-- The right PIN answers the account, in any spelling of the number.
select pg_temp.check(
  public.pin_login_check('+60100000172', '246810', '198.51.100.1') = '00000000-0000-0000-0000-0000000172a1'::uuid,
  'the right PIN answers the account');
select pg_temp.check(
  public.pin_login_check('60100000172', '246810', '198.51.100.1') = '00000000-0000-0000-0000-0000000172a1'::uuid,
  'the number matches without its plus');
select pg_temp.check(public.pin_login_check('+60100000172', '111111', '198.51.100.1') is null, 'a wrong PIN answers nothing');
select pg_temp.check(public.pin_login_check('+60199999999', '246810', '198.51.100.1') is null, 'an unknown number answers nothing');
select pg_temp.check(public.verify_pin_for_login('+60100000172', '246810') = '00000000-0000-0000-0000-0000000172a1'::uuid,
  'verify_pin_for_login still matches');

-- Five wrong PINs lock the account, whichever route they came in by.
do $$
begin
  for i in 1..5 loop
    perform public.pin_login_check('+60100000172', '000000', '198.51.100.' || i);
  end loop;
  begin
    perform public.pin_login_check('+60100000172', '246810', '198.51.100.9');
    raise exception 'FAILED: a locked account should refuse even the right PIN';
  exception when others then
    if sqlerrm not like 'PIN_LOCKED:%' then raise; end if;
  end;
end $$;

-- The address pin-login hands over is what is limited: 30 checks, then refused.
update public.profiles set pin_locked_until = null, pin_failed_attempts = 0
 where id = '00000000-0000-0000-0000-0000000172a1';
do $$
begin
  for i in 1..30 loop
    perform public.pin_login_check('+60199999999', '000000', '203.0.113.72');
  end loop;
  begin
    perform public.pin_login_check('+60199999999', '000000', '203.0.113.72');
    raise exception 'FAILED: the 31st check from one address should be refused';
  exception when others then
    if sqlerrm not like 'RATE_LIMITED:%' then raise; end if;
  end;
  -- Another address is not held up by it.
  perform public.pin_login_check('+60199999999', '000000', '203.0.113.73');
end $$;

rollback;

select 'pin_login: all passed';
