-- ============================================================================
-- Regression test for migration 0292: phone numbers and sign-in per country.
-- A number's country from its dial code (shared +1 and +7 by mobile digits);
-- length, mobile digits and Registration closed for new numbers only;
-- Blocked and blocked numbers (prefix, range, exact) for everyone, at the
-- phone screen, the sign-up hook, the SMS code hook, PIN sign-in and the
-- session check; test and staff numbers skip all of it; the daily limit stops
-- new numbers only; who may change the rules.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/country_phone_rules_0292.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.code(p_phone text, p_new boolean) returns text language sql as $$
  select public.phone_rule_check(p_phone, p_new)->>'code';
$$;
-- The phone screen's lookup, as its error code (null when it went on).
create or replace function pg_temp.lookup(p_phone text) returns text language plpgsql as $$
begin
  perform * from public.profile_phone_lookup(p_phone);
  return null;
exception when others then
  return split_part(sqlerrm, ':', 1);
end $$;
create or replace function pg_temp.sms(p_phone text) returns text language sql as $$
  select coalesce(public.send_sms_hook(jsonb_build_object('user', jsonb_build_object('phone', p_phone), 'sms', jsonb_build_object('otp', '123456')))
                  #>> '{error,message}', 'sent');
$$;

-- Every country with phone data has a rule, filled from the data.
select pg_temp.check((select count(*) from public.country_phone_rules) = 242, '242 countries with phone data');
select pg_temp.check(
  (select dial_code = '+60' and mobile_min = 9 and mobile_max = 10 and mobile_prefixes = '{1}' and mobile_only
     and defaults->>'min' = '9' from public.country_phone_rules where iso = 'MY'),
  'Malaysia: +60, 9 to 10 digits, mobiles start with 1');
select pg_temp.check((select not mobile_only from public.country_phone_rules where iso = 'US'),
  'the US: mobiles and landlines can''t be told apart, so no mobile-only check');

-- Shared dial codes: Canada's main is the US; Kazakhstan by its mobile digits.
select pg_temp.check((select (x.r).iso from public.phone_country_rule('+14165550123') x) = 'US', '+1 goes to the US');
select pg_temp.check((select (x.r).iso from public.phone_country_rule('+77011234567') x) = 'KZ', '+7 701 is Kazakhstan');
select pg_temp.check((select (x.r).iso from public.phone_country_rule('+79161234567') x) = 'RU', '+7 916 is Russia');
select pg_temp.check((select x.nsn from public.phone_country_rule('+600123456789') x) = '123456789',
  'the national digits lose a typed leading 0');

-- New numbers: length and mobile digits; existing accounts aren't checked for them.
select pg_temp.check(pg_temp.code('+60123456789', true) is null, 'a Malaysian mobile may sign up');
select pg_temp.check(pg_temp.code('+6012345', true) = 'PHONE_LENGTH', 'too short');
select pg_temp.check(pg_temp.code('+601234567890123', true) = 'PHONE_LENGTH', 'too long');
select pg_temp.check(pg_temp.code('+60312345678', true) = 'PHONE_NOT_MOBILE', 'a Malaysian landline');
select pg_temp.check(pg_temp.code('+60312345678', false) is null, 'an existing account with that number still signs in');
select pg_temp.check(public.phone_rule_message(public.phone_rule_check('+60312345678', true))
  like 'PHONE_NOT_MOBILE: This looks like a landline.%(starts with 01).', 'the landline words');

-- Registration closed: new numbers only.
update public.country_phone_rules set access = 'registration_closed' where iso = 'MY';
select pg_temp.check(pg_temp.code('+60123456789', true) = 'PHONE_REGISTRATION_CLOSED', 'no new Malaysian accounts');
select pg_temp.check(pg_temp.code('+60123456789', false) is null, 'existing Malaysian accounts sign in');

-- Blocked: everyone, and the lookup, sign-up hook and SMS hook all refuse.
update public.country_phone_rules set access = 'blocked' where iso = 'MY';
select pg_temp.check(pg_temp.code('+60123456789', false) = 'PHONE_BLOCKED', 'a blocked country, existing account');
select pg_temp.check(pg_temp.lookup('+60123456789') = 'PHONE_BLOCKED', 'the phone screen says blocked');
select pg_temp.check(
  public.before_user_created_hook(jsonb_build_object('user', jsonb_build_object('phone', '60123456789'))) #>> '{error,message}'
    like 'PHONE_BLOCKED:%', 'no account is made');
select pg_temp.check(pg_temp.sms('+60123456789') like 'PHONE_BLOCKED:%', 'no code is sent');
select pg_temp.check(
  exists (select 1 from public.sms_log where phone = '+60123456789' and reason = 'phone_blocked' and country_iso = 'MY'),
  'the refusal is logged with its country');

-- A test number skips it all.
insert into public.otp_safe_numbers (phone, note) values ('+60123000000', 'test');
select pg_temp.check(pg_temp.code('+60123000000', true) is null, 'a test number skips the block');
select pg_temp.check(pg_temp.lookup('+60123000000') is null, 'and the phone screen');
update public.country_phone_rules set access = 'allowed' where iso = 'MY';

-- Blocked numbers: by first digits, a range or the exact number.
insert into public.phone_number_blocks (iso, kind, value_from, value_to) values
  ('MY', 'prefix', '1150', null),
  ('MY', 'range', '123400000', '123499999'),
  ('MY', 'number', '198765432', null);
select pg_temp.check(pg_temp.code('+601150123456', false) = 'PHONE_BLOCKED', 'starts with 1150');
select pg_temp.check(pg_temp.code('+60123450000', false) = 'PHONE_BLOCKED', 'inside the range');
select pg_temp.check(pg_temp.code('+60123500000', false) is null, 'outside the range');
select pg_temp.check(pg_temp.code('+60198765432', false) = 'PHONE_BLOCKED', 'the exact number');
select pg_temp.check(pg_temp.code('+60198765433', false) is null, 'the next number');

-- PIN sign-in and the session check refuse a blocked number.
insert into auth.users (id, phone) values ('00000000-0000-0000-0000-000000292a01', '601150999999') on conflict do nothing;
insert into public.profiles (id, phone) values ('00000000-0000-0000-0000-000000292a01', '+601150999999')
on conflict (id) do update set phone = excluded.phone;
do $$
begin
  perform public.pin_check('+601150999999', '000000', null);
  raise exception 'FAILED: PIN sign-in went on for a blocked number';
exception when others then
  if sqlerrm not like 'PHONE_BLOCKED:%' then
    raise exception 'FAILED: PIN sign-in said %', sqlerrm;
  end if;
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-000000292a01');
select pg_temp.check(public.session_is_current() = false, 'a signed-in blocked number is signed out');
reset role;
select set_config('request.jwt.claims', '', true);
delete from public.phone_number_blocks where iso = 'MY';

-- Daily limit: new numbers stop at it, accounts still get their code.
update public.country_phone_rules set daily_code_limit = 1 where iso = 'SG';
insert into public.sms_log (phone, status, country_iso) values ('+6581110000', 'queued', 'SG');
select pg_temp.check(pg_temp.sms('+6581234567') like 'PHONE_DAILY_LIMIT:%', 'a new Singapore number at the limit');

-- Only admins with the page may change the rules.
insert into auth.users (id) values ('00000000-0000-0000-0000-000000292a02'), ('00000000-0000-0000-0000-000000292a03')
on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-000000292a02'), ('00000000-0000-0000-0000-000000292a03')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-000000292a02', 'admin-settings-country-states-cities', 'edit')
on conflict do nothing;
select pg_temp.as_user('00000000-0000-0000-0000-000000292a02');
select pg_temp.check((public.admin_country_phone_rule_set('TH', '{"access":"registration_closed","prefixes":["8","9","x"]}')).access
  = 'registration_closed', 'a Regions admin sets a rule');
select pg_temp.check((select mobile_prefixes from public.country_phone_rules where iso = 'TH') = '{8,9}',
  'only digit prefixes are kept');
select pg_temp.as_user('00000000-0000-0000-0000-000000292a03');
do $$
begin
  perform public.admin_country_phone_rule_set('TH', '{"access":"blocked"}');
  raise exception 'FAILED: a rider changed a country rule';
exception when insufficient_privilege then
  null;
end $$;
select pg_temp.check(not has_function_privilege('anon', 'public.phone_rule_check(text, boolean)', 'execute'),
  'the check itself is the server''s');

rollback;
