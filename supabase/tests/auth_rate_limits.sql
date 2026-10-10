-- ============================================================================
-- Regression test for migration 0137: the pre-login checks are limited per
-- network address, and the owner can lift their own PIN lock.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/auth_rate_limits.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

do $$
begin
  if has_function_privilege('anon', 'public.auth_rate_take(text, text, integer, interval)', 'execute')
     or has_function_privilege('authenticated', 'public.auth_rate_take(text, text, integer, interval)', 'execute')
     or has_function_privilege('anon', 'public.request_client_ip()', 'execute')
     or has_function_privilege('anon', 'public.clear_my_pin_lock()', 'execute')
     or not has_function_privilege('authenticated', 'public.clear_my_pin_lock()', 'execute')
     or not has_function_privilege('anon', 'public.profile_phone_lookup(text)', 'execute')
     or not has_function_privilege('anon', 'public.verify_pin_for_login(text, text)', 'execute') then
    raise exception 'FAILED: grants on the 0137 functions';
  end if;
  if has_table_privilege('anon', 'public.auth_rate_hits', 'select')
     or has_table_privilege('authenticated', 'public.auth_rate_hits', 'insert') then
    raise exception 'FAILED: auth_rate_hits must be closed to clients';
  end if;
end
$$;

begin;

-- The limiter: within the limit it records, over it it answers the wait.
do $$
declare
  w integer;
begin
  for i in 1..3 loop
    if public.auth_rate_take('t137', '203.0.113.9', 3, interval '10 minutes') <> 0 then
      raise exception 'FAILED: try % of 3 should pass', i;
    end if;
  end loop;
  w := public.auth_rate_take('t137', '203.0.113.9', 3, interval '10 minutes');
  if w < 1 or w > 600 then
    raise exception 'FAILED: the 4th try should wait up to 10 minutes, got %', w;
  end if;
  if public.auth_rate_take('t137', '203.0.113.10', 3, interval '10 minutes') <> 0 then
    raise exception 'FAILED: another address has its own count';
  end if;
  if public.auth_rate_take('t137', null, 0, interval '10 minutes') <> 0 then
    raise exception 'FAILED: a request without an address is not limited';
  end if;
  -- Tries that left the window no longer count.
  update public.auth_rate_hits set at = now() - interval '11 minutes' where bucket = 't137';
  if public.auth_rate_take('t137', '203.0.113.9', 3, interval '10 minutes') <> 0 then
    raise exception 'FAILED: old tries should have left the window';
  end if;
end
$$;

-- The address comes from the gateway's headers.
select set_config('request.headers', '{"x-forwarded-for":"198.51.100.7, 10.0.0.1"}', true);
do $$
begin
  if public.request_client_ip() <> '198.51.100.7' then
    raise exception 'FAILED: forwarded-for address: %', public.request_client_ip();
  end if;
end
$$;
select set_config('request.headers', '{"cf-connecting-ip":"192.0.2.44","x-forwarded-for":"6.6.6.6"}', true);
do $$
begin
  if public.request_client_ip() <> '192.0.2.44' then
    raise exception 'FAILED: Cloudflare address first: %', public.request_client_ip();
  end if;
end
$$;

-- The phone lookup answers 60 times in 10 minutes from one address.
set local role anon;
do $$
begin
  for i in 1..60 loop
    perform * from public.profile_phone_lookup('+60100000137');
  end loop;
end
$$;
reset role;
do $$
begin
  begin
    perform * from public.profile_phone_lookup('+60100000137');
    raise exception 'FAILED: the 61st lookup should be refused';
  exception when others then
    if sqlerrm not like 'RATE_LIMITED:%' then
      raise;
    end if;
  end;
end
$$;

-- The PIN check from a fresh address: 30 tries, then refused.
select set_config('request.headers', '{"cf-connecting-ip":"192.0.2.45"}', true);
set local role anon;
do $$
begin
  for i in 1..30 loop
    perform public.verify_pin_for_login('+60100000137', '000000');
  end loop;
end
$$;
reset role;
do $$
begin
  begin
    perform public.verify_pin_for_login('+60100000137', '000000');
    raise exception 'FAILED: the 31st PIN check should be refused';
  exception when others then
    if sqlerrm not like 'RATE_LIMITED:%' then
      raise;
    end if;
  end;
end
$$;

-- The owner, signed in by SMS, lifts their own lock.
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000137a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000137a1') on conflict do nothing;
update public.profiles
   set pin_failed_attempts = 0, pin_locked_until = now() + interval '15 minutes'
 where id = '00000000-0000-0000-0000-0000000137a1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000137a1","role":"authenticated"}', true);
set local role authenticated;
select public.clear_my_pin_lock();
reset role;
do $$
begin
  if (select pin_locked_until from public.profiles where id = '00000000-0000-0000-0000-0000000137a1') is not null then
    raise exception 'FAILED: clear_my_pin_lock should lift the lock';
  end if;
end
$$;

rollback;

select 'auth_rate_limits: all passed';
