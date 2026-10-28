-- ============================================================================
-- Regression test for migration 0314: city ride extras, part 1.
--   0. the grants;
--   1. settings by place: the admin's rows, each card's checker, a region
--      rule laying only its own keys over Default, Default kept;
--   2. luggage at booking: too many bags, a changed charge, the line that
--      matches, bags fixed afterwards, none on Freight;
--   3. the waiting charge: Arrived checked within the radius, the clock and
--      its terms stamped, nothing without a position, the scheduled ride's
--      booked time, the charge at pickup (and its cap), the columns the
--      server's;
--   4. tips: from GET.wallet and GET.coin less the commission, once per
--      ride, the limits, the days, not completed, short balance,
--      the driver's cash mark and who reads it;
--   5. the tips on the driver's earnings and statement totals.
-- All names and numbers are made up. The pickup is in a made-up country in
-- the South Pacific (-40, -140).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tips_waiting_luggage_0314.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- ---- 0. Grants ----------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.ride_tip(uuid, numeric, text)', 'public.ride_tip_terms(uuid)',
    'public.ride_cash_tip(uuid, boolean, numeric)',
    'public.city_ride_extras_here(double precision, double precision, text, text, text)'] loop
    if not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is for signed-in callers only', f;
    end if;
    if not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAILED: % is security definer', f;
    end if;
  end loop;
  foreach f in array array[
    'public.city_ride_extras_at(text, text, text, text)', 'public.city_ride_extras_for(public.ride_requests)',
    'public.city_ride_extras_problem(jsonb)',
    'public.ride_luggage_problem(integer, jsonb, boolean, double precision, double precision, text, text, text)',
    'public.ride_requests_city_waiting()', 'public.ride_requests_city_luggage()'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is the server''s own', f;
    end if;
  end loop;
end
$$;

-- ---- People -------------------------------------------------------------------------------------
update public.permit_country_settings set enforce = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000314a1'),  -- rider who books with bags
  ('00000000-0000-0000-0000-0000000314a2'),  -- rider with an empty wallet
  ('00000000-0000-0000-0000-0000000314a3'),  -- rider who waits and tips
  ('00000000-0000-0000-0000-0000000314a4'),  -- rider whose driver is far
  ('00000000-0000-0000-0000-0000000314a5'),  -- rider of a scheduled ride
  ('00000000-0000-0000-0000-0000000314a6'),  -- rider who keeps the driver 30 minutes
  ('00000000-0000-0000-0000-0000000314a7'),  -- rider who tips in GET.coin
  ('00000000-0000-0000-0000-0000000314a8'),  -- rider with no position check
  ('00000000-0000-0000-0000-0000000314b1'),  -- driver one
  ('00000000-0000-0000-0000-0000000314b2'),  -- driver two
  ('00000000-0000-0000-0000-0000000314c1')   -- admin of City ride extras
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test ' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000314%'
on conflict (id) do update set name = excluded.name;
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries) values
  ('00000000-0000-0000-0000-0000000314e1', '00000000-0000-0000-0000-0000000314b1', 'Test Driver One', '+60100003141',
   'approved', '{eHailing}', '{Tipland 314}'),
  ('00000000-0000-0000-0000-0000000314e2', '00000000-0000-0000-0000-0000000314b2', 'Test Driver Two', '+60100003142',
   'approved', '{eHailing}', '{Tipland 314}');
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000314c1', 'admin-settings-city-ride-extras', 'edit');

-- The pickup's country.
insert into public.countries (name, values, geofence) values
  ('Tipland 314', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":-38,"south":-42,"east":-138,"west":-142}}'));
-- Default as built in (whatever the meter's numbers were).
update public.city_ride_extra_places set rules = '{}' where level = 'default';
insert into public.city_ride_extra_places (level) values ('default') on conflict (place_key) do nothing;

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
-- [p_sql] must fail with an error naming [p_like].
create or replace function pg_temp.refused(p_sql text, p_like text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_like || '%' then
      return;
    end if;
    raise exception 'FAILED: % refused with "%" instead of %', p_what, sqlerrm, p_like;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
create or replace function pg_temp.wallet(p uuid, p_type text default 'get_wallet') returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = p_type), 0);
$$;
-- A ride taken by [p_driver] at the pickup, [p_status], fare 20.
create or replace function pg_temp.ride(p_id uuid, p_rider uuid, p_driver uuid, p_status text) returns void
language sql as $$
  insert into public.ride_requests (id, rider_id, rider_name, status, partner_id, partner_name, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, fare, ride_fare, accepted_at, completed_at, currency)
  values (p_id, p_rider, 'Farah Test', p_status, p_driver, 'Hafiz Test', -40.0, -140.0, -40.05, -140.05, 20, 20,
          now() - interval '20 minutes', case when p_status = 'completed' then now() end, 'MYR');
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text),
  pg_temp.wallet(uuid, text) to authenticated;

-- ---- 1. Settings by place -----------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000314c1');
insert into public.city_ride_extra_places (level, country, rules) values
  ('country', 'Tipland 314', '{"waiting": {"perMinute": 0.5}, "tips": {"commissionPercent": 10},
                               "luggage": {"freeBags": 1, "perBag": 3}}');
with d as (delete from public.city_ride_extra_places where level = 'default' returning 1)
select pg_temp.check(not exists (select 1 from d), 'Default can''t be removed');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314b1');
select pg_temp.refused($q$insert into public.city_ride_extra_places (level, country) values ('country', 'Otherland 314')$q$,
  'row-level security', 'a driver adding a rule');
select pg_temp.check((select count(*) from public.city_ride_extra_places where country = 'Tipland 314') = 1,
  'everyone signed in reads the rules');
select pg_temp.check((public.city_ride_extras_here(-40.0, -140.0)->'waiting')
                     = '{"on": true, "cap": 6, "radiusM": 150, "perMinute": 0.5, "freeMinutes": 3}'::jsonb,
  'the country''s rate over Default''s other waiting values: '
  || (public.city_ride_extras_here(-40.0, -140.0)->'waiting')::text);
select pg_temp.check((public.city_ride_extras_here(10.0, 10.0)->'waiting'->>'perMinute')::numeric = 0.3,
  'elsewhere Default holds');
reset role;
select pg_temp.refused($q$insert into public.city_ride_extra_places (level, country, rules)
  values ('country', 'Badland 314', '{"waiting": {"perMinute": 9}}')$q$, 'CITY_RIDE_EXTRAS_INVALID', 'a rate over the limit');
select pg_temp.refused($q$insert into public.city_ride_extra_places (level, country, rules)
  values ('country', 'Badland 314', '{"bogus": {}}')$q$, 'CITY_RIDE_EXTRAS_INVALID', 'a card that doesn''t exist');
select pg_temp.refused($q$insert into public.city_ride_extra_places (level, country, rules)
  values ('country', 'Badland 314', '{"tips": {"min": 50, "max": 10}}')$q$, 'CITY_RIDE_EXTRAS_INVALID',
  'a smallest tip over the largest');
select pg_temp.refused($q$insert into public.city_ride_extra_places (level, country, rules)
  values ('country', 'Badland 314', '{"luggage": {"on": "yes"}}')$q$, 'CITY_RIDE_EXTRAS_INVALID', 'on that isn''t a switch');
select pg_temp.check((select array['luggage', 'tips', 'waiting'] <@ public.city_ride_extras_sections()),
  'the cards are found by their functions');

-- ---- 2. Luggage at booking ----------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a1');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, pickup_lat, pickup_lng,
    drop_lat, drop_lng, luggage) values ('00000000-0000-0000-0000-0000000314a1', 'open', 30, 30, -40.0, -140.0,
    -40.05, -140.05, 6)$q$, 'RIDE_LUGGAGE_TOO_MANY', 'six bags where five is the most');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, pickup_lat, pickup_lng,
    drop_lat, drop_lng, luggage, option_charges) values ('00000000-0000-0000-0000-0000000314a1', 'open', 30, 30,
    -40.0, -140.0, -40.05, -140.05, 3, '[{"kind": "luggage", "name": "Luggage: 3 bags (2 free)", "amount": 2}]')$q$,
  'RIDE_LUGGAGE_CHARGE_CHANGED', 'the Default charge where the country''s is due');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, pickup_lat, pickup_lng,
    drop_lat, drop_lng, luggage) values ('00000000-0000-0000-0000-0000000314a1', 'open', 30, 30, -40.0, -140.0,
    -40.05, -140.05, 2)$q$, 'RIDE_LUGGAGE_CHARGE_CHANGED', 'an extra bag without its charge');
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                  luggage, option_charges)
values ('00000000-0000-0000-0000-000000031401', '00000000-0000-0000-0000-0000000314a1', 'open', 30, 30, -40.0, -140.0,
        -40.05, -140.05, 3, '[{"kind": "luggage", "name": "Luggage: 3 bags (1 free)", "amount": 6}]');
select pg_temp.check((select luggage = 3 from public.ride_requests where id = '00000000-0000-0000-0000-000000031401'),
  'three bags booked with their charge (two extra at 3)');
select pg_temp.refused($q$update public.ride_requests set luggage = 1 where id = '00000000-0000-0000-0000-000000031401'$q$,
  'RIDE_LUGGAGE_FIXED', 'fewer bags after booking');
reset role;
select pg_temp.check(public.ride_luggage_problem(0, '[{"kind": "luggage", "name": "Luggage", "amount": 2}]', true,
                                                -40.0, -140.0, null, null, null)
                     = array['RIDE_LUGGAGE_NOT_HERE', 'Luggage is for rides. Describe what you send instead.'],
  'no luggage line on Freight or Courier');
select pg_temp.check(public.ride_luggage_problem(1, null, false, -40.0, -140.0, null, null, null) is null,
  'the free bag costs nothing');
update public.city_ride_extra_places set rules = '{"luggage": {"on": false}}' where country = 'Tipland 314';
select pg_temp.check(public.ride_luggage_problem(7, null, false, -40.0, -140.0, null, null, null) is null,
  'luggage off: the bags are only said');
update public.city_ride_extra_places
   set rules = '{"waiting": {"perMinute": 0.5}, "tips": {"commissionPercent": 10}, "luggage": {"freeBags": 1, "perBag": 3}}'
 where country = 'Tipland 314';

-- ---- 3. The waiting charge ----------------------------------------------------------------------
select pg_temp.ride('00000000-0000-0000-0000-000000031411', '00000000-0000-0000-0000-0000000314a3',
                    '00000000-0000-0000-0000-0000000314b1', 'accepted');
select pg_temp.ride('00000000-0000-0000-0000-000000031412', '00000000-0000-0000-0000-0000000314a4',
                    '00000000-0000-0000-0000-0000000314b2', 'accepted');
select pg_temp.ride('00000000-0000-0000-0000-000000031413', '00000000-0000-0000-0000-0000000314a8',
                    '00000000-0000-0000-0000-0000000314b2', 'accepted');
select pg_temp.ride('00000000-0000-0000-0000-000000031414', '00000000-0000-0000-0000-0000000314a6',
                    '00000000-0000-0000-0000-0000000314b1', 'accepted');
insert into public.scheduled_rides (id, rider_id, pickup_at, status, request, fare, partner_id) values
  ('00000000-0000-0000-0000-0000000314d5', '00000000-0000-0000-0000-0000000314a5', now() + interval '10 minutes',
   'released', '{}', 20, '00000000-0000-0000-0000-0000000314b1');
select pg_temp.ride('00000000-0000-0000-0000-000000031415', '00000000-0000-0000-0000-0000000314a5',
                    '00000000-0000-0000-0000-0000000314b1', 'accepted');
update public.ride_requests set scheduled_ride_id = '00000000-0000-0000-0000-0000000314d5'
 where id = '00000000-0000-0000-0000-000000031415';
delete from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000314b2';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000314b2');
select pg_temp.refused($q$update public.ride_requests set status = 'arrived', partner_arrive_lat = -40.01,
    partner_arrive_lng = -140.0 where id = '00000000-0000-0000-0000-000000031412'$q$,
  'RIDE_ARRIVED_TOO_FAR', 'Arrived over a kilometre from the pickup');
update public.ride_requests set status = 'arrived' where id = '00000000-0000-0000-0000-000000031413';
select pg_temp.check((select status = 'arrived' and waiting_from is null from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000031413'),
  'no position to check: arrived, without a clock');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314b1');
update public.ride_requests set status = 'arrived', partner_arrive_lat = -40.0005, partner_arrive_lng = -140.0
 where id = '00000000-0000-0000-0000-000000031411';
select pg_temp.check((select waiting_from between now() - interval '5 seconds' and now() + interval '5 seconds'
                             and waiting_terms = '{"freeMinutes": 3, "perMinute": 0.5, "cap": 6}'::jsonb
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031411'),
  'within 150 m: the clock starts now with the place''s terms');
select pg_temp.refused($q$update public.ride_requests set waiting_from = now() - interval '1 hour'
    where id = '00000000-0000-0000-0000-000000031411'$q$, 'RIDE_SERVER_ONLY', 'the driver moving the clock');
update public.ride_requests set status = 'arrived', partner_arrive_lat = -40.0, partner_arrive_lng = -140.0
 where id = '00000000-0000-0000-0000-000000031415';
select pg_temp.check((select waiting_from = (select pickup_at from public.scheduled_rides
                                               where id = '00000000-0000-0000-0000-0000000314d5')
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031415'),
  'a scheduled ride the driver reached early counts from the booked time');
update public.ride_requests set status = 'arrived', partner_arrive_lat = -40.0, partner_arrive_lng = -140.0
 where id = '00000000-0000-0000-0000-000000031414';
reset role;
-- The rider kept them 9 minutes 30 seconds, and the other 30 minutes.
update public.ride_requests set waiting_from = now() - interval '9 minutes 30 seconds'
 where id = '00000000-0000-0000-0000-000000031411';
update public.ride_requests set waiting_from = now() - interval '30 minutes'
 where id = '00000000-0000-0000-0000-000000031414';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000314b1');
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-000000031411';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-000000031414';
reset role;
select pg_temp.check((select waiting_minutes = 9 and waiting_charge = 3 and fare = 23 and ride_fare = 23
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031411'),
  'picked up: 6 minutes past the free 3, at 0.50, added to the fare: '
  || (select format('%s min, %s, fare %s', waiting_minutes, waiting_charge, fare)
        from public.ride_requests where id = '00000000-0000-0000-0000-000000031411'));
select pg_temp.check((select waiting_minutes = 30 and waiting_charge = 6 and fare = 26
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031414'),
  'at most the cap');
select pg_temp.check((select (m, c) = (9, 3.00) from public.ride_waiting_charge(
                        '{"freeMinutes": 3, "perMinute": 0.5, "cap": 6}', now() - interval '9 minutes 59 seconds', now()) as w(m, c)),
  'whole minutes only');

-- ---- 4. Tips ------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000314b1');
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-000000031411';
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-000000031414';
reset role;
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note) values
  ('00000000-0000-0000-0000-0000000314a3', 'get_wallet', 'topup', 50, 'Test top-up'),
  ('00000000-0000-0000-0000-0000000314a7', 'get_coin', 'reward', 100, 'Test coins');
update public.get_coin_settings set coins_per_currency = 10 where id = 'master';
select pg_temp.ride('00000000-0000-0000-0000-000000031421', '00000000-0000-0000-0000-0000000314a7',
                    '00000000-0000-0000-0000-0000000314b1', 'completed');
select pg_temp.ride('00000000-0000-0000-0000-000000031422', '00000000-0000-0000-0000-0000000314a2',
                    '00000000-0000-0000-0000-0000000314b1', 'completed');
update public.ride_requests set completed_at = now() - interval '4 days' where id = '00000000-0000-0000-0000-000000031414';
create temporary table t_before as select pg_temp.wallet('00000000-0000-0000-0000-0000000314b1') as driver;
grant select on t_before to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a3');
select pg_temp.check((select (t->>'canTip')::boolean and t->'presets' = '[2, 5, 10]'::jsonb
                             and (t->>'commissionPercent')::numeric = 10 and t->>'driverName' = 'Hafiz Test'
                        from public.ride_tip_terms('00000000-0000-0000-0000-000000031411') t),
  'the rider may tip: presets, commission, the driver');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031411', 0.2, 'get_wallet')$q$,
  'TIP_AMOUNT', 'under the smallest tip');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031411', 101, 'get_wallet')$q$,
  'TIP_AMOUNT', 'over the largest tip');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031411', 5, 'cash')$q$,
  'invalid_method', 'cash through the app');
select pg_temp.check((public.ride_tip('00000000-0000-0000-0000-000000031411', 5, 'get_wallet')->>'driverAmount')::numeric = 4.5,
  'a tip of 5 less 10% commission');
select pg_temp.check((public.ride_tip('00000000-0000-0000-0000-000000031411', 5, 'get_wallet')->>'already')::boolean,
  'a second call answers with the first');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000314a3') = 45, 'paid once from GET.wallet');
select pg_temp.check((select t->>'why' = 'tipped' and (t->'tip'->>'amount')::numeric = 5
                        from public.ride_tip_terms('00000000-0000-0000-0000-000000031411') t),
  'the receipt shows the tip given');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031414', 5, 'get_wallet')$q$,
  'not_authorized', 'tipping someone else''s trip');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031413', 5, 'get_wallet')$q$,
  'not_authorized', 'tipping a ride of someone else not finished');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a8');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031413', 5, 'get_wallet')$q$,
  'TIP_NOT_COMPLETED', 'tipping before the trip is complete');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a6');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031414', 5, 'get_wallet')$q$,
  'TIP_EXPIRED', 'tipping after the days');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a2');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031422', 5, 'get_wallet')$q$,
  'insufficient_balance', 'a tip from an empty wallet');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a7');
select pg_temp.check((public.ride_tip('00000000-0000-0000-0000-000000031421', 2, 'get_coin')->>'coins')::numeric = 20,
  'a tip of 2 in GET.coin at 10 coins each');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000314a7', 'get_coin') = 80, 'the coins are spent');

select pg_temp.as_user('00000000-0000-0000-0000-0000000314b1');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000314b1') = (select driver from t_before) + 4.5 + 1.8,
  'the driver''s GET.wallet got both tips less commission');
select pg_temp.refused($q$select public.ride_tip('00000000-0000-0000-0000-000000031411', 5, 'get_wallet')$q$,
  'not_authorized', 'the driver tipping');
select public.ride_cash_tip('00000000-0000-0000-0000-000000031414', true, 3);
select public.ride_cash_tip('00000000-0000-0000-0000-000000031414', true, 4);
select pg_temp.check((select (t->'cashTip'->>'amount')::numeric = 4 and t->>'why' = 'expired'
                        from public.ride_tip_terms('00000000-0000-0000-0000-000000031414') t),
  'the driver''s cash mark, once, with what they noted');
select pg_temp.as_user('00000000-0000-0000-0000-0000000314a6');
select pg_temp.check((select t->'cashTip' = 'null'::jsonb from public.ride_tip_terms('00000000-0000-0000-0000-000000031414') t),
  'the rider never sees the cash mark');
select pg_temp.check(not exists (select 1 from public.ride_tips where method = 'cash'), 'nor reads it');
select pg_temp.refused($q$select public.ride_cash_tip('00000000-0000-0000-0000-000000031414', true, 3)$q$,
  'not_authorized', 'the rider marking a cash tip');
select pg_temp.refused($q$insert into public.ride_tips (ride_id, partner_id, method, amount, driver_amount)
    values ('00000000-0000-0000-0000-000000031414', '00000000-0000-0000-0000-0000000314b1', 'get_wallet', 9, 9)$q$,
  'permission denied', 'writing a tip by hand');
reset role;

-- ---- 5. Earnings and statements -----------------------------------------------------------------
select pg_temp.check((select (t->>'tips')::numeric = 6.3 and (t->>'cashTips')::numeric = 4
                             and (t->>'cashTipCount')::int = 1
                             and (t->>'totalEarnings')::numeric
                                 = coalesce((t->>'fare')::numeric, 0) + coalesce((t->>'surcharges')::numeric, 0)
                                   + coalesce((t->>'platformCollected')::numeric, 0) + (t->>'incentives')::numeric
                                   + (t->>'handoverIn')::numeric + 6.3
                        from public.partner_statement_totals('00000000-0000-0000-0000-0000000314b1',
                                                             now() - interval '1 day', now() + interval '1 day') t),
  'the tips in the earnings, the cash marks beside them: '
  || public.partner_statement_totals('00000000-0000-0000-0000-0000000314b1', now() - interval '1 day',
                                     now() + interval '1 day')::text);
select pg_temp.check(not (public.partner_statement_totals('00000000-0000-0000-0000-0000000314b2',
                                                          now() - interval '1 day', now() + interval '1 day') ? 'tips'),
  'no tips: no key, as before');
select pg_temp.check(exists (select 1 from pg_publication_tables
                              where pubname = 'supabase_realtime' and tablename = 'city_ride_extra_places')
                     or not exists (select 1 from pg_publication where pubname = 'supabase_realtime'),
  'the settings are live in the apps');

rollback;
