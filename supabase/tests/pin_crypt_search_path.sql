-- ============================================================================
-- Regression test for migration 0138: setting and checking a PIN reaches
-- pgcrypto, wherever the extension lives.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pin_crypt_search_path.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000138a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000138a1') on conflict do nothing;
update public.profiles set phone = '+60100000138' where id = '00000000-0000-0000-0000-0000000138a1';

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000138a1","role":"authenticated"}', true);
set local role authenticated;
select public.set_login_pin('246810', null);
reset role;

do $$
begin
  if (select pin_hash from public.profiles where id = '00000000-0000-0000-0000-0000000138a1') is null then
    raise exception 'FAILED: set_login_pin should store a hash';
  end if;
  if public.verify_pin_for_login('+60100000138', '246810') is distinct from '00000000-0000-0000-0000-0000000138a1'::uuid then
    raise exception 'FAILED: the right PIN should match';
  end if;
  if public.verify_pin_for_login('+60100000138', '111111') is not null then
    raise exception 'FAILED: a wrong PIN should not match';
  end if;
end
$$;

rollback;

select 'pin_crypt_search_path: all passed';
