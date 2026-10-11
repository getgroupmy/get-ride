-- ============================================================================
-- Regression test for migration 0151: a PIN is only ever checked against its
-- hash, and a plain-text PIN can't be stored.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/no_plaintext_pin.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000151a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000151a1') on conflict do nothing;
update public.profiles set phone = '+60100000151' where id = '00000000-0000-0000-0000-0000000151a1';

-- 1. A client can't write a PIN column, plain text or hash; the owner's
--    functions still can (below).
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000151a1","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  w text;
begin
  foreach w in array array[
    'update public.profiles set pin = ''123456'' where id = ''00000000-0000-0000-0000-0000000151a1''',
    'update public.profiles set login_pin = ''123456'' where id = ''00000000-0000-0000-0000-0000000151a1''',
    'update public.profiles set pin_hash = ''x'' where id = ''00000000-0000-0000-0000-0000000151a1''',
    'update public.profiles set pin_locked_until = now() where id = ''00000000-0000-0000-0000-0000000151a1'''
  ] loop
    begin
      execute w;
    exception when insufficient_privilege then
      continue;
    end;
    raise exception 'FAILED: a client wrote a PIN column: %', w;
  end loop;
end $$;
reset role;

do $$
begin
  -- 2. The plain-text columns can't hold a PIN even for the owner.
  begin
    alter table public.profiles disable trigger trg_profiles_hash_pin;
    update public.profiles set pin = '123456' where id = '00000000-0000-0000-0000-0000000151a1';
    raise exception 'FAILED: a plain-text pin was stored';
  exception when check_violation then
    null;
  end;
  alter table public.profiles enable trigger trg_profiles_hash_pin;

  -- With no hash there is no PIN: the lookup says so and nothing matches.
  if (select has_pin from public.profile_phone_lookup('+60100000151')) then
    raise exception 'FAILED: no hash should mean no PIN';
  end if;
  if public.verify_pin_for_login('+60100000151', '123456') is not null then
    raise exception 'FAILED: nothing should match without a hash';
  end if;
end $$;

-- 3. The hashed PIN still signs in, and a wrong one doesn't.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000151a1","role":"authenticated"}', true);
set local role authenticated;
select public.set_login_pin('246810', null);
reset role;

do $$
begin
  if not (select has_pin from public.profile_phone_lookup('+60100000151')) then
    raise exception 'FAILED: a hashed PIN should count as a PIN';
  end if;
  if public.verify_pin_for_login('+60100000151', '246810') is distinct from '00000000-0000-0000-0000-0000000151a1'::uuid then
    raise exception 'FAILED: the right PIN should match';
  end if;
  if public.verify_pin_for_login('+60100000151', '111111') is not null then
    raise exception 'FAILED: a wrong PIN should not match';
  end if;
  if (select pin_failed_attempts from public.profiles where id = '00000000-0000-0000-0000-0000000151a1') <> 1 then
    raise exception 'FAILED: a wrong PIN should count as a failed attempt';
  end if;
end $$;

rollback;

select 'no_plaintext_pin: all passed';
