-- ============================================================================
-- Regression test for migration 0109: booking tariffs are read by anyone and
-- written by admins only, one card per place.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fare_tariffs.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000009a1'),  -- admin
  ('00000000-0000-0000-0000-0000000009a2')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000009%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000009a1', '*', 'edit')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare
  n int;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n = 0 then return; end if;  -- RLS hid the row: nothing was changed
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

set local role authenticated;

-- 1. An admin writes cards ----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000009a1');
insert into public.fare_tariffs (level, currency, base_fare, per_km, per_minute)
  values ('master', 'MYR', 4, 1, 0.3);
insert into public.fare_tariffs (level, country, currency, base_fare, per_km, per_minute, minimum_fare)
  values ('country', 'Singapore', 'SGD', 3.9, 0.7, 0.2, 6);
select pg_temp.refused(
  $q$insert into public.fare_tariffs (level, country, currency) values ('country', 'singapore', 'SGD')$q$,
  'a second card for the same place');
select pg_temp.refused(
  $q$insert into public.fare_tariffs (level, country, city, currency) values ('city', 'Malaysia', 'Ipoh', 'MYR')$q$,
  'a city card without its state');
select pg_temp.refused(
  $q$insert into public.fare_tariffs (level, currency) values ('master', 'ringgit')$q$,
  'a currency that is not a code');

-- 2. A rider reads them but cannot write ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000009a2');
do $$
begin
  if (select count(*) from public.fare_tariffs where currency in ('MYR', 'SGD')) < 2 then
    raise exception 'FAILED: a rider cannot read the cards';
  end if;
end $$;
select pg_temp.refused(
  $q$insert into public.fare_tariffs (level, country, currency) values ('country', 'Thailand', 'THB')$q$,
  'a rider adding a card');
select pg_temp.refused(
  $q$update public.fare_tariffs set base_fare = 0 where level = 'master'$q$,
  'a rider changing a card');
select pg_temp.refused(
  $q$delete from public.fare_tariffs where level = 'master'$q$,
  'a rider deleting a card');

-- 3. Anon reads them too -------------------------------------------------------
reset role;
set local role anon;
do $$
begin
  if not exists (select 1 from public.fare_tariffs where level = 'master') then
    raise exception 'FAILED: anon cannot read the cards';
  end if;
end $$;

reset role;
select 'fare_tariffs: all passed';
rollback;
