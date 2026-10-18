-- ============================================================================
-- Regression test for migration 0216: who may read and write commission
-- rates, which rate wins, place names matched as regions are, the rate
-- locked when the driver accepts, change history, and charging what failed.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/commission_foundations.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000216a1'),  -- rider
  ('00000000-0000-0000-0000-0000000216b1'),  -- driver
  ('00000000-0000-0000-0000-0000000216b2'),  -- another driver
  ('00000000-0000-0000-0000-0000000216c1'),  -- admin (edit)
  ('00000000-0000-0000-0000-0000000216c2')   -- admin (view only)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000216%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000216c1', 'admin-settings-commission', 'edit'),
  ('00000000-0000-0000-0000-0000000216c2', 'admin-settings-commission', 'read');

-- Only this test's rates count.
delete from public.commission_rates;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, anon;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n int;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

-- 1. Writing needs edit access to the Commission page ------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000216c2');
select pg_temp.refused(
  $q$insert into public.commission_rates (level, rate) values ('master', 0.5)$q$,
  'a view-only admin adding a rate');

select pg_temp.as_user('00000000-0000-0000-0000-0000000216c1');
insert into public.commission_rates (id, level, rate, note) values
  ('00000000-0000-0000-0000-0000000216f1', 'master', 0.20, 'base'),
  ('00000000-0000-0000-0000-0000000216f2', 'state', 0.12, null);
update public.commission_rates set state = 'Selangor', country = 'Malaysia'
 where id = '00000000-0000-0000-0000-0000000216f2';
-- One rate per exact place; an overlapping one (no country named) with a
-- higher priority beats the one naming more parents.
insert into public.commission_rates (id, level, state, rate, priority) values
  ('00000000-0000-0000-0000-0000000216f3', 'state', 'Selangor', 0.11, 5);
insert into public.commission_rates (id, level, city, state, country, rate) values
  ('00000000-0000-0000-0000-0000000216f4', 'city', 'Kajang', 'Selangor', 'Malaysia', 0.08);
insert into public.commission_rates (id, level, user_id, user_label, rate) values
  ('00000000-0000-0000-0000-0000000216f5', 'user', '00000000-0000-0000-0000-0000000216b2', 'Driver B2', 0);

select pg_temp.check(
  (select created_by = '00000000-0000-0000-0000-0000000216c1' from public.commission_rates
    where id = '00000000-0000-0000-0000-0000000216f1'),
  'a new rate records who added it');
select pg_temp.check(
  (select count(*) = 2 from public.commission_rate_history where rate_id = '00000000-0000-0000-0000-0000000216f2'),
  'adding then editing a rate leaves two history rows');
select pg_temp.check(
  (select new_row->>'state' = 'Selangor' and old_row->>'state' is null and changed_by = '00000000-0000-0000-0000-0000000216c1'
     from public.commission_rate_history
    where rate_id = '00000000-0000-0000-0000-0000000216f2' and op = 'update'),
  'the history row has the before, the after and who');

-- 2. A driver's own rate is theirs to read, nobody else's -------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000216b1');
select pg_temp.check(
  (select count(*) = 0 from public.commission_rates where level = 'user'),
  'another driver''s rate hidden from a driver');
select pg_temp.check(
  (select count(*) = 4 from public.commission_rates where level <> 'user'),
  'place rates readable by a driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000216b2');
select pg_temp.check(
  (select count(*) = 1 from public.commission_rates where level = 'user'),
  'a driver reads their own rate');
reset role;
set local role anon;
select pg_temp.refused($q$select * from public.commission_rates$q$, 'anyone reading rates without signing in');
reset role;

-- 3. Which rate wins --------------------------------------------------------
select pg_temp.check(
  (select rate = 0.11 and rule_id = '00000000-0000-0000-0000-0000000216f3'
     from public.commission_resolve(null, null, null, 'Malaysia', 'Selangor', 'Petaling Jaya', null)),
  'of two Selangor rates, the higher priority wins over more named parents');
select pg_temp.check(
  (select rate = 0.08 from public.commission_resolve(null, null, null, 'Malaysia', 'Selangor', 'Kajang Municipal Council', null)),
  'the geocoder''s "Kajang Municipal Council" matches the Kajang rate');
select pg_temp.check(
  (select rate = 0.20 and level = 'master' from public.commission_resolve(null, null, null, 'Malaysia', 'Johor', 'Johor Bahru', null)),
  'elsewhere the master rate');
select pg_temp.check(
  (select rate = 0 and level = 'user' from public.commission_resolve('00000000-0000-0000-0000-0000000216b2', null, null, 'Malaysia', 'Selangor', 'Kajang', null)),
  'a driver''s own 0% rate beats the place');
select pg_temp.check(
  public.commission_resolve_rate(null, 'Malaysia', 'Selangor', 'Kajang', null) = 0.08,
  'the old entry point answers the same');

-- 4. Locked when the driver accepts -----------------------------------------
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, state, city) values
  ('00000000-0000-0000-0000-0000000216e1', '00000000-0000-0000-0000-0000000216a1', 'open', 50, 50, 'Malaysia', 'Selangor', 'Kajang'),
  ('00000000-0000-0000-0000-0000000216e2', '00000000-0000-0000-0000-0000000216a1', 'open', 40, 40, 'Malaysia', 'Selangor', 'Kajang');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000216b1', accepted_at = now()
 where id = '00000000-0000-0000-0000-0000000216e1';
select pg_temp.check(
  (select commission_rate = 0.08 and commission_rule_id = '00000000-0000-0000-0000-0000000216f4' and commission_locked_at is not null
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000216e1'),
  'accepting locks the rate and its rule');

-- The admin changes Kajang mid-trip: the accepted trip keeps 8%.
update public.commission_rates set rate = 0.30 where id = '00000000-0000-0000-0000-0000000216f4';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000216e1';
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000216e1';
select pg_temp.check(
  (select commission_amount = 4.00 and commission_rate = 0.08 and commission_charged_at is not null
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000216e1'),
  'a rate changed mid-trip does not change the trip');

-- A handover to a 0% driver locks again; the trip is marked charged at 0.
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000216b1', accepted_at = now()
 where id = '00000000-0000-0000-0000-0000000216e2';
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000216b2'
 where id = '00000000-0000-0000-0000-0000000216e2';
select pg_temp.check(
  (select commission_rate = 0 and commission_rule_id = '00000000-0000-0000-0000-0000000216f5'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000216e2'),
  'a new driver on the trip locks their own rate');
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000216e2';
select pg_temp.check(
  (select commission_amount = 0 and commission_charged_at is not null
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000216e2'),
  'a 0% trip is marked charged at 0');

-- 5. Uncharged trips are listed and charged by an editing admin -------------
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, country, state) values
  ('00000000-0000-0000-0000-0000000216e3', '00000000-0000-0000-0000-0000000216a1', '00000000-0000-0000-0000-0000000216b1', 'completed', 10, 10, 'Malaysia', 'Johor');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000216c2');
select pg_temp.check(
  exists (select 1 from public.admin_uncharged_commissions() where ride_id = '00000000-0000-0000-0000-0000000216e3'),
  'admins see the uncharged trip');
select pg_temp.refused($q$select public.admin_charge_uncharged_commissions()$q$, 'a view-only admin charging');
select pg_temp.as_user('00000000-0000-0000-0000-0000000216c1');
select pg_temp.check(
  (select (public.admin_charge_uncharged_commissions()->>'charged')::int >= 1),
  'an editing admin charges it');
reset role;
select pg_temp.check(
  (select commission_amount = 2.00 from public.ride_requests where id = '00000000-0000-0000-0000-0000000216e3'),
  'charged at the master 20%');

-- 6. Deleting a rate is kept too --------------------------------------------
delete from public.commission_rates where id = '00000000-0000-0000-0000-0000000216f2';
select pg_temp.check(
  exists (select 1 from public.commission_rate_history
           where rate_id = '00000000-0000-0000-0000-0000000216f2' and op = 'delete' and old_row->>'rate' = '0.1200'),
  'a deleted rate stays in the history');

rollback;
