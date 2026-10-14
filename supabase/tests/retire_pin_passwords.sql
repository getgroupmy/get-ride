-- ============================================================================
-- Regression test for migration 0175: no phone account keeps a password a
-- PIN could produce.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/retire_pin_passwords.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- A phone account still on the old derived password, and an email account
-- with a password of its own.
insert into auth.users (id, phone, encrypted_password) values
  ('00000000-0000-0000-0000-0000000175a1', '60120000175',
   extensions.crypt('teksi-pin-v1-246810', extensions.gen_salt('bf')));
insert into auth.users (id, email, encrypted_password) values
  ('00000000-0000-0000-0000-0000000175b1', 'ops-0175@example.com',
   extensions.crypt('a-real-password', extensions.gen_salt('bf')));

-- The migration's statement, run again on these rows.
update auth.users
   set encrypted_password = extensions.crypt(
         encode(extensions.gen_random_bytes(32), 'base64'),
         extensions.gen_salt('bf')
       ),
       updated_at = now()
 where coalesce(phone, '') <> ''
   and coalesce(email, '') = '';

do $$
declare
  v_phone text;
  v_email text;
begin
  select encrypted_password into v_phone from auth.users where id = '00000000-0000-0000-0000-0000000175a1';
  select encrypted_password into v_email from auth.users where id = '00000000-0000-0000-0000-0000000175b1';
  if v_phone = extensions.crypt('teksi-pin-v1-246810', v_phone) then
    raise exception 'FAILED: the PIN-derived password still works';
  end if;
  if v_phone is null or v_phone not like '$2%' then
    raise exception 'FAILED: the phone account was left without a bcrypt password';
  end if;
  if v_email <> extensions.crypt('a-real-password', v_email) then
    raise exception 'FAILED: an email account''s own password was replaced';
  end if;
end $$;

select 'retire_pin_passwords: all passed';
rollback;
