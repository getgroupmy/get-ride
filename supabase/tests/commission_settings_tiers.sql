-- ============================================================================
-- Regression test for migration 0218: commission settings (GET.credit floor,
-- what commission is charged on) and tiers.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/commission_settings_tiers.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000218a1'),  -- rider
  ('00000000-0000-0000-0000-0000000218b1'),  -- driver, busy (tier)
  ('00000000-0000-0000-0000-0000000218b2'),  -- driver, in debt
  ('00000000-0000-0000-0000-0000000218c1'),  -- admin (edit)
  ('00000000-0000-0000-0000-0000000218c2')   -- admin (view only)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000218%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000218c1', 'admin-settings-commission', 'edit'),
  ('00000000-0000-0000-0000-0000000218c2', 'admin-settings-commission', 'read');
insert into public.partners (auth_user_id, name, phone, status, rating) values
  ('00000000-0000-0000-0000-0000000218b1', 'Busy Driver', '60120000218', 'approved', 4.9),
  ('00000000-0000-0000-0000-0000000218b2', 'Debt Driver', '60120000219', 'approved', 4.2);

delete from public.commission_rates;
delete from public.commission_tiers;
insert into public.commission_rates (level, rate) values ('master', 0.20);

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
declare n int;
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
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text)
  to authenticated, anon;

-- 1. Settings: only an editing admin; cleaned ---------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000218c2');
select pg_temp.refused($q$select public.set_commission_config('{}')$q$, 'a view-only admin saving settings');
select pg_temp.check((public.commission_config()->>'allowNegativeCredit')::boolean, 'by default GET.credit may go below zero');

select pg_temp.as_user('00000000-0000-0000-0000-0000000218c1');
select public.set_commission_config(jsonb_build_object(
  'allowNegativeCredit', true, 'negativeLimit', 50,
  'baseSurcharges', jsonb_build_array('Airport', ' Airport ', ''), 'baseTolls', true, 'meterCommission', 'yes'));
select pg_temp.check(
  (select c->'baseSurcharges' = '["Airport"]'::jsonb and (c->>'negativeLimit')::numeric = 50
      and (c->>'baseTolls')::boolean and not (c->>'baseOtherCharges')::boolean and not (c->>'meterCommission')::boolean
     from public.commission_config() c),
  'settings saved and cleaned');
reset role;

-- 2. The floor: RM 50 below zero ------------------------------------------------
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note) values
  ('00000000-0000-0000-0000-0000000218b2', 'get_credit', 'commission', -60, 'old debt');
select pg_temp.check(public.commission_credit_floor() = -50, 'the floor is minus the limit');
select pg_temp.check(not public.commission_credit_ok('00000000-0000-0000-0000-0000000218b2'), 'RM -60 is under the floor');
select pg_temp.check(public.commission_credit_ok('00000000-0000-0000-0000-0000000218b1'), 'RM 0 is fine');

insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, state, city) values
  ('00000000-0000-0000-0000-0000000218e1', '00000000-0000-0000-0000-0000000218a1', 'open', 50, 50, 'Malaysia', 'Selangor', 'Kajang');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000218b2');
select pg_temp.refused(
  $q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000218b2', offered_fare = 55
      where id = '00000000-0000-0000-0000-0000000218e1'$q$,
  'a driver under the floor offering on a trip', '%GET_CREDIT_TOO_LOW%');
select pg_temp.check((public.partner_credit_status()->>'ok')::boolean is false, 'the driver is told they are under the floor');

reset role;

-- Going online under the floor stays offline.
insert into public.driver_presence (profile_id, online) values ('00000000-0000-0000-0000-0000000218b2', true)
on conflict (profile_id) do update set online = true;
select pg_temp.check(
  (select not online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000218b2'),
  'a driver under the floor is kept offline');

-- Not allowed below zero at all: the floor is 0.
update public.app_settings set value = value || '{"allowNegativeCredit": false}' where key = 'commission';
select pg_temp.check(public.commission_credit_floor() = 0, 'no going below zero: the floor is 0');
-- Allowed without a limit: no floor.
update public.app_settings set value = value || '{"allowNegativeCredit": true, "negativeLimit": 0}' where key = 'commission';
select pg_temp.check(public.commission_credit_floor() is null, 'no limit: no floor');
select pg_temp.check(public.commission_credit_ok('00000000-0000-0000-0000-0000000218b2'), 'and the indebted driver may drive');

-- 3. Tiers -----------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000218c2');
select pg_temp.refused(
  $q$insert into public.commission_tiers (name, metric, threshold, adjust, value) values ('x', 'trips', 1, 'rate', 0.1)$q$,
  'a view-only admin adding a tier');
select pg_temp.as_user('00000000-0000-0000-0000-0000000218c1');
insert into public.commission_tiers (id, name, metric, window_days, threshold, adjust, value) values
  ('00000000-0000-0000-0000-0000000218d1', 'Busy week', 'trips', 7, 3, 'minus', 0.05),
  ('00000000-0000-0000-0000-0000000218d2', 'Top rated', 'rating', 7, 4.8, 'rate', 0.12),
  ('00000000-0000-0000-0000-0000000218d3', 'Off for now', 'trips', 7, 0, 'rate', 0.01);
update public.commission_tiers set active = false where id = '00000000-0000-0000-0000-0000000218d3';
select pg_temp.check(
  (select count(*) = 4 from public.commission_rate_history where op like 'tier:%'),
  'tier changes are in the history');
reset role;

-- The busy driver: 4.9 stars (12%), and three trips this week (20% - 5% = 15%): 12% wins.
insert into public.ride_requests (rider_id, partner_id, status, fare, ride_fare, completed_at, commission_charged_at)
select '00000000-0000-0000-0000-0000000218a1', '00000000-0000-0000-0000-0000000218b1', 'completed', 10, 10,
       now() - interval '1 day', now()
  from generate_series(1, 3);
select pg_temp.check(
  (select rate = 0.12 and tier_id = '00000000-0000-0000-0000-0000000218d2'
     from public.commission_apply_tiers('00000000-0000-0000-0000-0000000218b1', 0.20, 'master')),
  'of the tiers met, the lowest rate wins');
select pg_temp.check(
  (select rate = 0.20 and tier_id is null
     from public.commission_apply_tiers('00000000-0000-0000-0000-0000000218b2', 0.20, 'master')),
  'a driver who meets none pays the rate');
select pg_temp.check(
  (select rate = 0.30 from public.commission_apply_tiers('00000000-0000-0000-0000-0000000218b1', 0.30, 'user')),
  'a personal rate is not lowered');

-- 4. Locked at accept with the tier; charged on fare + Airport + tolls ---------------------
update public.ride_requests
   set charges = '[{"kind":"surcharge","name":"Airport","charge":"fixed","value":10},
                   {"kind":"surcharge","name":"Night","charge":"percent","value":10},
                   {"kind":"tax","name":"SST","charge":"percent","value":6},
                   {"kind":"surcharge","name":"Scheduling fee","charge":"fixed","value":2,"platform":true}]'::jsonb,
       toll_charges = 4, other_charges = 3
 where id = '00000000-0000-0000-0000-0000000218e1';
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000218b1', accepted_at = now()
 where id = '00000000-0000-0000-0000-0000000218e1';
select pg_temp.check(
  (select commission_rate = 0.12 and commission_base_rate = 0.20 and commission_tier_id = '00000000-0000-0000-0000-0000000218d2'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000218e1'),
  'the tier is locked with the rate at accept');

select pg_temp.check(
  public.commission_base((select r from public.ride_requests r where id = '00000000-0000-0000-0000-0000000218e1')) = 64,
  'base: fare 50 + Airport 10 + tolls 4 (not Night, tax, the platform fee or other charges)');

update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000218e1';
select pg_temp.check(
  (select commission_amount = 7.68 and commission_base_amount = 64
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000218e1'),
  'charged 12% of 64');

-- 5. With nothing ticked the base is the fare, as before ----------------------------------
update public.app_settings set value = value || '{"baseSurcharges": [], "baseTolls": false}' where key = 'commission';
select pg_temp.check(
  public.commission_base((select r from public.ride_requests r where id = '00000000-0000-0000-0000-0000000218e1')) = 50,
  'default base is the fare only');

select 'commission_settings_tiers: all passed';
rollback;
