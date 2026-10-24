-- ============================================================================
-- Regression test for migration 0287: new passenger and new driver sign-up
-- switches (Admin › Display › Sign-in Screen), enforced on the server: the
-- PIN that finishes a new account, a new partner application, and Supabase
-- Auth's Before User Created hook (no SMS code with both closed).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/registration_switches_0287.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000287a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000287a2'),  -- sub-admin, EDIT on Display
  ('00000000-0000-0000-0000-0000000287a3'),  -- sub-admin, READ on Display
  ('00000000-0000-0000-0000-0000000287b1'),  -- new account (passenger)
  ('00000000-0000-0000-0000-0000000287b2'),  -- new account (driver)
  ('00000000-0000-0000-0000-0000000287b3'),  -- new account (an app that sends no role)
  ('00000000-0000-0000-0000-0000000287c1'),  -- passenger with a PIN, no partner row
  ('00000000-0000-0000-0000-0000000287c2')   -- driver part-way through registration
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000287%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000287a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000287a2', 'admin-settings-display', 'edit'),
  ('00000000-0000-0000-0000-0000000287a3', 'admin-settings-display', 'read')
on conflict do nothing;
-- An account made long ago with a PIN already: never "new".
update public.profiles set created_at = now() - interval '30 days', pin_hash = 'x'
 where id = '00000000-0000-0000-0000-0000000287c1';
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000287c2', 'Part Way', '+60110000287', 'unapproved');

-- Starts from no stored keys: everything open.
insert into public.admin_display_settings (id, settings) values ('global', '{}'::jsonb)
on conflict (id) do update set settings = public.admin_display_settings.settings
  - 'registrationEnabled' - 'passengerRegistrationEnabled' - 'driverRegistrationEnabled';

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    if sqlerrm not like p_like then
      raise exception 'FAILED: % refused for the wrong reason: %', p_what, sqlerrm;
    end if;
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
create or replace function pg_temp.set_switches(p jsonb) returns void language sql as $$
  update public.admin_display_settings set settings = settings || p where id = 'global';
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text),
  pg_temp.refused(text, text, text), pg_temp.set_switches(jsonb) to authenticated;

-- 1. Defaults and how flags read -------------------------------------------------------------------
select pg_temp.check(public.registration_open('passenger') and public.registration_open('driver')
                     and public.registration_open(null), 'no keys: everything open');
select pg_temp.check(public.display_setting_flag('{"a": "off"}', 'a') = false
                     and public.display_setting_flag('{"a": 0}', 'a') = false
                     and public.display_setting_flag('{"a": "nonsense"}', 'a')
                     and public.display_setting_flag('{}', 'a'), 'flags read as the apps read them');
select pg_temp.set_switches('{"registrationEnabled": false}');
select pg_temp.check(not public.registration_open('passenger') and not public.registration_open('driver')
                     and not public.registration_open(null), 'the old switch off closes both');
select pg_temp.set_switches('{"registrationEnabled": true}');

-- 2. Who may change them: the Display page's editors ------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000287b1');
select pg_temp.refused($q$update public.admin_display_settings
  set settings = settings || '{"passengerRegistrationEnabled": false}' where id = 'global'$q$, 'a rider closing sign-up');
select pg_temp.as_user('00000000-0000-0000-0000-0000000287a3');
select pg_temp.refused($q$update public.admin_display_settings
  set settings = settings || '{"passengerRegistrationEnabled": false}' where id = 'global'$q$,
  'a read-only sub-admin closing sign-up');
select pg_temp.as_user('00000000-0000-0000-0000-0000000287a2');
update public.admin_display_settings
   set settings = settings || '{"passengerRegistrationEnabled": false, "registrationEnabled": true}'
 where id = 'global';
reset role;
select pg_temp.check(not public.registration_open('passenger'), 'the Display editor closed passenger sign-up');
select pg_temp.check(public.registration_open('driver') and public.registration_open(null), 'driver still open');

-- 3. Passenger closed: a new passenger account is refused at its PIN, a driver one is not ------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000287b1');
select pg_temp.refused($q$select public.set_login_pin('246810', null, null, 'passenger')$q$,
  'a new passenger while passenger sign-up is closed', '%REGISTRATION_CLOSED:passenger%');
select pg_temp.refused($q$select public.set_login_pin('246810', null, null, 'boss')$q$,
  'an unknown role', '%Unknown sign-up role%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000287b2');
select pg_temp.check(public.set_login_pin('246810', null, null, 'driver'), 'a new driver while driver sign-up is open');
select pg_temp.as_user('00000000-0000-0000-0000-0000000287b3');
select pg_temp.check(public.set_login_pin('246810', null), 'an app that sends no role, while one role is open');
reset role;

-- The hook lets a number through while one role is open.
select pg_temp.check(public.before_user_created_hook('{"user": {"phone": "60123000287"}}') = '{}'::jsonb,
  'one role open: a new number gets its code');

-- 4. Driver closed too: nothing new ---------------------------------------------------------------
select pg_temp.set_switches('{"driverRegistrationEnabled": false, "registrationEnabled": false}');
delete from public.profiles where id in ('00000000-0000-0000-0000-0000000287b2', '00000000-0000-0000-0000-0000000287b3');
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000287b2'), ('00000000-0000-0000-0000-0000000287b3');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000287b2');
select pg_temp.refused($q$select public.set_login_pin('246810', null, null, 'driver')$q$,
  'a new driver with both closed', '%REGISTRATION_CLOSED:driver%');
select pg_temp.as_user('00000000-0000-0000-0000-0000000287b3');
select pg_temp.refused($q$select public.set_login_pin('246810', null)$q$,
  'an app that sends no role, with both closed', '%REGISTRATION_CLOSED:any%');
-- An existing account still changes its PIN (with proof): not "new".
select pg_temp.as_user('00000000-0000-0000-0000-0000000287c1');
select pg_temp.refused($q$select public.set_login_pin('246810', null)$q$,
  'an existing account without proof', '%PIN_PROOF_REQUIRED%');
reset role;

-- The hook: no user, so no SMS code, for a phone sign-up; admin-made and
-- e-mail users pass.
select pg_temp.check(public.before_user_created_hook('{"user": {"phone": "60123000287"}}') -> 'error' ->> 'message'
                     like 'REGISTRATION_CLOSED%', 'both closed: a new number is refused');
select pg_temp.check((public.before_user_created_hook('{"user": {"phone": "60123000287"}}') -> 'error' ->> 'http_code')::int = 403,
  'refused as 403');
select pg_temp.check(public.before_user_created_hook(
  '{"user": {"phone": "60123000287", "phone_confirmed_at": "2026-10-24T00:00:00Z"}}') = '{}'::jsonb,
  'an account an admin makes (phone confirmed) passes');
select pg_temp.check(public.before_user_created_hook('{"user": {"email": "a@example.com"}}') = '{}'::jsonb,
  'an e-mail user passes');
select pg_temp.check(has_function_privilege('authenticated', 'public.before_user_created_hook(jsonb)', 'execute') = false
                     and has_function_privilege('anon', 'public.before_user_created_hook(jsonb)', 'execute') = false,
  'the apps cannot call the hook');

-- 5. Driver closed, passenger open: no new partner application ----------------------------------
select pg_temp.set_switches('{"passengerRegistrationEnabled": true, "driverRegistrationEnabled": false, "registrationEnabled": true}');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000287c1');
-- my_ride_code is given: its column default (gen_my_ride_code) is not the
-- apps' to run, and runs before any trigger.
select pg_temp.refused($q$insert into public.partners (auth_user_id, name, phone, status, my_ride_code)
  values ('00000000-0000-0000-0000-0000000287c1', 'New Partner', '+60110000288', 'unapproved', 'RS0287AA')$q$,
  'a passenger starting a partner application while driver sign-up is closed', '%REGISTRATION_CLOSED:driver%');
-- One part-way through may carry on.
select pg_temp.as_user('00000000-0000-0000-0000-0000000287c2');
update public.partners set address = 'Somewhere' where auth_user_id = '00000000-0000-0000-0000-0000000287c2';
reset role;
select pg_temp.check((select address from public.partners where auth_user_id = '00000000-0000-0000-0000-0000000287c2') = 'Somewhere',
  'an application part-way through is still saved');

-- 6. Driver open again: the application may start --------------------------------------------------
-- Inserted as the table owner with the passenger's claims: the gate reads
-- the claims, and the 0160 my_ride trigger (gen_my_ride_code, not granted
-- to the apps) does not stand in the way of what is tested here.
select pg_temp.set_switches('{"driverRegistrationEnabled": true}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000287c1');
insert into public.partners (auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000287c1', 'New Partner', '+60110000288', 'unapproved');
select pg_temp.set_switches('{"driverRegistrationEnabled": false}');
select pg_temp.refused($q$insert into public.partners (auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000287c1', 'Second', '+60110000289', 'unapproved')$q$,
  'the same insert with driver sign-up closed', '%REGISTRATION_CLOSED:driver%');
-- An admin adding a partner for someone is not limited.
select pg_temp.as_user('00000000-0000-0000-0000-0000000287a1');
insert into public.partners (auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000287a1', 'Admin Self', '+60110000290', 'unapproved');
select pg_temp.check((select count(*) from public.partners where auth_user_id = '00000000-0000-0000-0000-0000000287c1') = 1,
  'with driver sign-up open, the application starts (once)');

rollback;
