-- ============================================================================
-- Regression test for migration 0243: meter_digital_settings.meter_at_sign_in
-- defaults to 'off' (so every card keeps what auto_launch alone did), takes
-- only 'off' / 'ask' / 'always', is readable by a signed-in driver, and only
-- an administrator can change it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/meter_at_sign_in_0243.sql
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
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to anon, authenticated;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to anon, authenticated;

-- 1. The column ------------------------------------------------------------------------
select pg_temp.check(
  (select data_type = 'text' and is_nullable = 'NO' and column_default like '''off''%'
     from information_schema.columns
    where table_schema = 'public' and table_name = 'meter_digital_settings' and column_name = 'meter_at_sign_in'),
  'meter_at_sign_in is a non-null text column defaulting to off');

-- 2. A new card is off; the three choices are taken; anything else is refused ----------
insert into public.meter_digital_settings (id, level, country, city, label)
values ('00000000-0000-0000-0000-0000000243c1', 'city', 'Malaysia', 'Zz Test City 0243', 'Test 0243');

select pg_temp.check(
  (select meter_at_sign_in = 'off' from public.meter_digital_settings where id = '00000000-0000-0000-0000-0000000243c1'),
  'a card written without the field is off');

update public.meter_digital_settings set meter_at_sign_in = 'ask' where id = '00000000-0000-0000-0000-0000000243c1';
select pg_temp.check(
  (select meter_at_sign_in = 'ask' from public.meter_digital_settings where id = '00000000-0000-0000-0000-0000000243c1'),
  'ask is stored');
update public.meter_digital_settings set meter_at_sign_in = 'always' where id = '00000000-0000-0000-0000-0000000243c1';
select pg_temp.check(
  (select meter_at_sign_in = 'always' from public.meter_digital_settings where id = '00000000-0000-0000-0000-0000000243c1'),
  'always is stored');

select pg_temp.refused(
  $q$update public.meter_digital_settings set meter_at_sign_in = 'sometimes' where id = '00000000-0000-0000-0000-0000000243c1'$q$,
  'an unknown choice');
select pg_temp.refused(
  $q$update public.meter_digital_settings set meter_at_sign_in = null where id = '00000000-0000-0000-0000-0000000243c1'$q$,
  'a null choice');

-- 3. A driver reads it but cannot change it --------------------------------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000243a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000243a1') on conflict do nothing;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000243a1');

select pg_temp.check(
  (select meter_at_sign_in = 'always' from public.meter_digital_settings where id = '00000000-0000-0000-0000-0000000243c1'),
  'a signed-in driver reads the card''s choice');

update public.meter_digital_settings set meter_at_sign_in = 'off' where id = '00000000-0000-0000-0000-0000000243c1';
reset role;

select pg_temp.check(
  (select meter_at_sign_in = 'always' from public.meter_digital_settings where id = '00000000-0000-0000-0000-0000000243c1'),
  'a driver who is not an administrator cannot change it');

rollback;
