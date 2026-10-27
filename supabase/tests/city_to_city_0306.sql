-- ============================================================================
-- Regression test for migration 0306: City to City, the server half.
--   * which rule: the most specific place on each end (several places per
--     end), the sum of both ends, then the pickup end, then the list order;
--     inactive rules skipped; Kuala Lumpur (a federal territory) is not in
--     Selangor; no rule: the default;
--   * the fare card (the service's own card beats every service's, the
--     service's own rates without a card, the TEKSI tariff without either),
--     the add-on (RM and %), a fixed fare, Auto ± % and a set range;
--   * where it is offered: the vehicle service active and On at the pickup
--     by the region service switches (0302);
--   * drivers: years of driving (driving_since, else an approved licence)
--     against the rule's minimum (default, own, off, the switch), and the
--     permits for each country the trip touches (driver and vehicle,
--     expired ones not counted);
--   * commission: the driver's own rate, then the service's, then the place
--     rate; tiers and a lower promotion still apply, locked at accept;
--   * who reads and writes.
-- The same rule, fare and range cases are in test/city_to_city_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/city_to_city_0306.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000306a1'),  -- admin, EDIT on City to City
  ('00000000-0000-0000-0000-0000000306a2'),  -- admin, EDIT on Commission
  ('00000000-0000-0000-0000-0000000306a3'),  -- admin, READ on City to City
  ('00000000-0000-0000-0000-0000000306b1'),  -- driver: 10 years, every permit
  ('00000000-0000-0000-0000-0000000306b2'),  -- driver: 1 year, an expired permit
  ('00000000-0000-0000-0000-0000000306b3'),  -- driver: an approved licence 6 years old
  ('00000000-0000-0000-0000-0000000306b4'),  -- driver: nothing on file
  ('00000000-0000-0000-0000-0000000306c1')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000306%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000306a1', 'admin-settings-city-to-city', 'edit'),
  ('00000000-0000-0000-0000-0000000306a2', 'admin-settings-commission', 'edit'),
  ('00000000-0000-0000-0000-0000000306a3', 'admin-settings-city-to-city', 'read')
on conflict do nothing;

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
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- What [p_sql] does as [p_user]: 'ok' with the rows it touched, or the error.
create or replace function pg_temp.run_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare n integer;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
-- A place {country, state, city, suburb}.
create or replace function pg_temp.at(p_country text, p_state text default null, p_city text default null,
                                      p_suburb text default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('country', p_country, 'state', p_state, 'city', p_city, 'suburb', p_suburb));
$$;
-- A rule's place: level and names.
create or replace function pg_temp.p(p_level text, p_country text, p_state text default null, p_city text default null,
                                     p_suburb text default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('level', p_level, 'country', p_country, 'state', p_state,
                                              'city', p_city, 'suburb', p_suburb));
$$;
create or replace function pg_temp.rule(p_from jsonb, p_to jsonb) returns uuid language sql as $$
  select id from public.c2c_rule_for(p_from, p_to);
$$;
-- The quote from [p_from] to [p_to], 205 km and 160 minutes, City to City.
create or replace function pg_temp.quote(p_from jsonb, p_to jsonb) returns jsonb language sql as $$
  select public.c2c_quote(null, null, p_from, p_to, 205, 160, 'City to City');
$$;

-- ---- Places ----------------------------------------------------------------------------------------
-- Semenanjung 306: Selatan 306 (a state, with Petaling 306), Kuala Lumpur
-- 306 (a federal territory: its own state and city, with Bangsar 306),
-- Putrajaya 306, Perak 306 (Ipoh 306), Pinang 306, Pahang 306 (Kuantan 306).
-- Pulau 306: another country.
create or replace function pg_temp.kl() returns jsonb language sql as $$
  select pg_temp.at('Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306');
$$;
create or replace function pg_temp.petaling() returns jsonb language sql as $$
  select pg_temp.at('Semenanjung 306', 'Selatan 306', 'Petaling 306');
$$;
create or replace function pg_temp.ipoh() returns jsonb language sql as $$
  select pg_temp.at('Semenanjung 306', 'Perak 306', 'Ipoh 306');
$$;
create or replace function pg_temp.kuantan() returns jsonb language sql as $$
  select pg_temp.at('Semenanjung 306', 'Pahang 306', 'Kuantan 306');
$$;
create or replace function pg_temp.pulau() returns jsonb language sql as $$
  select pg_temp.at('Pulau 306', 'Utara 306', 'Kota 306');
$$;

-- ---- Rules -----------------------------------------------------------------------------------------
delete from public.c2c_route_rules;
insert into public.c2c_route_rules (id, from_places, to_places, fare_mode, add_on_amount, add_on_percent, fixed_fare,
                                    range_mode, range_percent, range_low, range_high, book_ahead_days,
                                    min_years_mode, min_years, active, position) values
  -- R1: Kuala Lumpur, Selatan, Putrajaya to Perak: the card + RM 20, RM 130 to 150.
  ('00000000-0000-0000-0000-000000030601',
   jsonb_build_array(pg_temp.p('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306'),
                     pg_temp.p('state', 'Semenanjung 306', 'Selatan 306'),
                     pg_temp.p('city', 'Semenanjung 306', 'Putrajaya 306', 'Putrajaya 306')),
   jsonb_build_array(pg_temp.p('state', 'Semenanjung 306', 'Perak 306')),
   'card', 20, 0, null, 'set', 8, 130, 150, 14, 'default', null, true, 1),
  -- R2: Kuala Lumpur to Pinang: RM 190 a car, RM 180 to 210, any driver.
  ('00000000-0000-0000-0000-000000030602',
   jsonb_build_array(pg_temp.p('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306')),
   jsonb_build_array(pg_temp.p('state', 'Semenanjung 306', 'Pinang 306')),
   'fixed', 0, 0, 190, 'set', 8, 180, 210, 30, 'off', null, true, 2),
  -- R5: Selatan to Pulau: the card + 15 %, Auto ± 8 %, 5 years.
  ('00000000-0000-0000-0000-000000030605',
   jsonb_build_array(pg_temp.p('state', 'Semenanjung 306', 'Selatan 306')),
   jsonb_build_array(pg_temp.p('country', 'Pulau 306')),
   'card', 0, 15, null, 'auto', 8, null, null, 14, 'set', 5, true, 3),
  -- R3: anywhere in Semenanjung to anywhere in it: the card + RM 10.
  ('00000000-0000-0000-0000-000000030603',
   jsonb_build_array(pg_temp.p('country', 'Semenanjung 306')),
   jsonb_build_array(pg_temp.p('country', 'Semenanjung 306')),
   'card', 10, 0, null, 'auto', 8, null, null, 14, 'default', null, true, 4),
  -- R4: Bangsar to Kuantan, the most specific of all, but off.
  ('00000000-0000-0000-0000-000000030604',
   jsonb_build_array(pg_temp.p('suburb', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 'Bangsar 306')),
   jsonb_build_array(pg_temp.p('city', 'Semenanjung 306', 'Pahang 306', 'Kuantan 306')),
   'fixed', 0, 0, 200, 'set', 8, 185, 220, 14, 'off', null, false, 5),
  -- R6 and R7 tie on the sum (city + country, country + city); R8 ties R6 exactly, later in the list.
  ('00000000-0000-0000-0000-000000030606',
   jsonb_build_array(pg_temp.p('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306')),
   jsonb_build_array(pg_temp.p('country', 'Semenanjung 306')),
   'card', 1, 0, null, 'auto', 8, null, null, 14, 'default', null, true, 6),
  ('00000000-0000-0000-0000-000000030607',
   jsonb_build_array(pg_temp.p('country', 'Semenanjung 306')),
   jsonb_build_array(pg_temp.p('city', 'Semenanjung 306', 'Pahang 306', 'Kuantan 306')),
   'card', 2, 0, null, 'auto', 8, null, null, 14, 'default', null, true, 7),
  ('00000000-0000-0000-0000-000000030608',
   jsonb_build_array(pg_temp.p('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306')),
   jsonb_build_array(pg_temp.p('country', 'Semenanjung 306')),
   'card', 3, 0, null, 'auto', 8, null, null, 14, 'default', null, true, 8);

-- ---- 1. Which rule ---------------------------------------------------------------------------------
select pg_temp.check(pg_temp.rule(pg_temp.kl(), pg_temp.ipoh()) = '00000000-0000-0000-0000-000000030601',
  'Kuala Lumpur to Ipoh: R1 (city + state) beats R3 (country + country)');
select pg_temp.check(pg_temp.rule(pg_temp.petaling(), pg_temp.ipoh()) = '00000000-0000-0000-0000-000000030601',
  'Petaling to Ipoh: R1 by its second place, Selatan');
select pg_temp.check(pg_temp.rule(pg_temp.at('Semenanjung 306', 'Putrajaya 306', 'Putrajaya 306'), pg_temp.ipoh())
                     = '00000000-0000-0000-0000-000000030601',
  'Putrajaya to Ipoh: R1 by its third place');
select pg_temp.check(pg_temp.rule(pg_temp.at('semenanjung 306', 'Wilayah Persekutuan Kuala Lumpur 306', 'KUALA LUMPUR 306'),
                                  pg_temp.at('Semenanjung 306', 'Perak 306'))
                     = '00000000-0000-0000-0000-000000030601',
  'the geocoder''s long name for the territory and any case still match');
select pg_temp.check(pg_temp.rule(pg_temp.kl(), pg_temp.pulau()) is null,
  'Kuala Lumpur is not in Selatan: R5 does not take it, no rule does');
select pg_temp.check(pg_temp.rule(pg_temp.petaling(), pg_temp.pulau()) = '00000000-0000-0000-0000-000000030605',
  'Petaling to Pulau: R5');
select pg_temp.check(pg_temp.rule(pg_temp.at('Semenanjung 306', 'Pahang 306', 'Temerloh 306'), pg_temp.ipoh())
                     = '00000000-0000-0000-0000-000000030603',
  'Temerloh to Ipoh: only the country rule');
select pg_temp.check(pg_temp.rule(pg_temp.at('Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 'Bangsar 306'),
                                  pg_temp.kuantan()) = '00000000-0000-0000-0000-000000030606',
  'Bangsar to Kuantan: R4 is off; R6 and R7 tie on the sum, the pickup end decides, R8 is later in the list');
update public.c2c_route_rules set active = true where id = '00000000-0000-0000-0000-000000030604';
select pg_temp.check(pg_temp.rule(pg_temp.at('Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 'Bangsar 306'),
                                  pg_temp.kuantan()) = '00000000-0000-0000-0000-000000030604',
  'switched on, the suburb rule wins');
update public.c2c_route_rules set active = false where id = '00000000-0000-0000-0000-000000030604';
update public.c2c_route_rules set position = 0 where id = '00000000-0000-0000-0000-000000030608';
select pg_temp.check(pg_temp.rule(pg_temp.kl(), pg_temp.kuantan()) = '00000000-0000-0000-0000-000000030608',
  'an exact tie goes to the rule higher in the list');
update public.c2c_route_rules set position = 8 where id = '00000000-0000-0000-0000-000000030608';
select pg_temp.check(pg_temp.rule(pg_temp.pulau(), pg_temp.kl()) is null, 'Pulau to Kuala Lumpur: the default');
select pg_temp.check(public.c2c_side_rank(
    jsonb_build_array(pg_temp.p('country', 'Semenanjung 306'), pg_temp.p('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306')),
    pg_temp.kl()) = 3,
  'a side takes its most specific place that matches');

-- ---- 2. The fare card, the add-on and the range --------------------------------------------------------
delete from public.fare_tariffs;
insert into public.fare_tariffs (level, country, state, city, base_fare, per_km, per_minute, vehicle_service) values
  -- Every service in Semenanjung: 2 + 0.45 a km + 0.15 a minute.
  ('country', 'Semenanjung 306', null, null, 2, 0.45, 0.15, null),
  -- Every service from Kuala Lumpur, and City to City's own card there.
  ('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 10, 0.5, 0, null),
  ('city', 'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 3, 0.4, 0.2,
   (select id::text from public.settings_entries where category = 'vehicle-services' and values->>'name' = 'City to City'
     order by position limit 1));
update public.city_to_city_settings
   set default_add_on_amount = 5, default_add_on_percent = 0, default_range_mode = 'auto', default_range_percent = 10,
       min_years_on = true, min_years = 3, currency = 'MYR'
 where id = 1;
update public.settings_entries set values = values || '{"costPerKm": 0.45, "costPerMin": 0.15, "minFareAmount": 50}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';

select pg_temp.check((select fare = 117.00 from public.c2c_fare_card('City to City', pg_temp.kl(), 205, 160)),
  'Kuala Lumpur: City to City''s own card (3 + 82 + 32) beats every service''s');
select pg_temp.check((select fare = 112.50 from public.c2c_fare_card('Another 306', pg_temp.kl(), 205, 160)),
  'another service in Kuala Lumpur: every service''s card there');
select pg_temp.check((select fare = 118.25 from public.c2c_fare_card('City to City', pg_temp.petaling(), 205, 160)),
  'Petaling: the country card (2 + 92.25 + 24)');
select pg_temp.check((select fare = 116.25 and tariff_id is null
                        from public.c2c_fare_card('City to City', pg_temp.pulau(), 205, 160)),
  'Pulau has no card: the service''s own rates (92.25 + 24)');
select pg_temp.check((select fare = 19.75 from public.c2c_fare_card('Unknown 306', pg_temp.pulau(), 10, 20)),
  'no card, no rates: the TEKSI tariff');

select pg_temp.check((select q->>'ruleId' = '00000000-0000-0000-0000-000000030601'
                             and (q->>'fareCard')::numeric = 117 and (q->>'addOn')::numeric = 20
                             and (q->>'suggested')::numeric = 137 and (q->>'low')::numeric = 130
                             and (q->>'high')::numeric = 150 and q->>'fareMode' = 'card' and q->>'rangeMode' = 'set'
                             and (q->>'minYears')::int = 3 and (q->>'bookAheadDays')::int = 14
                        from pg_temp.quote(pg_temp.kl(), pg_temp.ipoh()) q),
  'Kuala Lumpur to Ipoh: card 117 + RM 20 = 137, set range 130 to 150, the default 3 years');
select pg_temp.check((select (q->>'suggested')::numeric = 138.25 from pg_temp.quote(pg_temp.petaling(), pg_temp.ipoh()) q),
  'Petaling to Ipoh: card 118.25 + RM 20');
select pg_temp.check((select q->>'fareMode' = 'fixed' and q->'fareCard' = 'null'::jsonb and (q->>'suggested')::numeric = 190
                             and (q->>'low')::numeric = 180 and (q->>'high')::numeric = 210 and q->'minYears' = 'null'::jsonb
                             and (q->>'bookAheadDays')::int = 30
                        from pg_temp.quote(pg_temp.kl(), pg_temp.at('Semenanjung 306', 'Pinang 306', 'George 306')) q),
  'Kuala Lumpur to Pinang: RM 190 a car, its own range, no minimum');
select pg_temp.check((select (q->>'suggested')::numeric = 135.99 and (q->>'addOn')::numeric = 17.74
                             and (q->>'low')::numeric = 125 and (q->>'high')::numeric = 147 and (q->>'minYears')::int = 5
                        from pg_temp.quote(pg_temp.petaling(), pg_temp.pulau()) q),
  'Petaling to Pulau: card 118.25 + 15 % = 135.99, Auto ± 8 % = 125 to 147, 5 years');
select pg_temp.check((select q->'ruleId' = 'null'::jsonb and (q->>'suggested')::numeric = 121.25
                             and (q->>'low')::numeric = 109 and (q->>'high')::numeric = 133 and (q->>'minYears')::int = 3
                        from pg_temp.quote(pg_temp.pulau(), pg_temp.kl()) q),
  'the default: own rates 116.25 + RM 5, Auto ± 10 %');
update public.city_to_city_settings set min_years_on = false where id = 1;
select pg_temp.check((select q->'minYears' = 'null'::jsonb from pg_temp.quote(pg_temp.petaling(), pg_temp.pulau()) q),
  'the experience switch off: no minimum anywhere, even a rule''s own');
update public.city_to_city_settings set min_years_on = true where id = 1;
do $$
begin
  perform public.c2c_quote(null, null, pg_temp.kl(), pg_temp.ipoh(), -1, 10);
  raise exception 'FAILED: a negative distance was quoted';
exception when others then
  if sqlerrm not like 'C2C_BAD_TRIP%' then raise; end if;
end $$;

-- ---- 3. Where it is offered ------------------------------------------------------------------------
insert into public.countries (name, values) values
  ('Semenanjung 306', jsonb_build_object('subServices', jsonb_build_object(
     (select id::text from public.settings_entries where category = 'vehicle-services' and values->>'name' = 'City to City'
       order by position limit 1), true)));
insert into public.states (country, name, values) values
  ('Semenanjung 306', 'Pahang 306', jsonb_build_object('subServices', jsonb_build_object(
     (select id::text from public.settings_entries where category = 'vehicle-services' and values->>'name' = 'City to City'
       order by position limit 1), false))),
  ('Semenanjung 306', 'Kuala Lumpur 306', '{}');
update public.settings_entries set values = values || '{"status": false}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
select pg_temp.check(not public.c2c_available_at(pg_temp.kl()), 'the service switched off in Vehicle Services: nowhere');
update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
-- The master service City to City is On by default where no region says otherwise.
select pg_temp.check(public.c2c_available_at(pg_temp.kl()), 'Kuala Lumpur: On from the country');
select pg_temp.check(not public.c2c_available_at(pg_temp.kuantan()), 'Pahang: Off in the state');
select pg_temp.check(public.c2c_available_at(pg_temp.at('Nowhere 306')), 'a place the regions don''t know: on');

-- ---- 4. Drivers ------------------------------------------------------------------------------------
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries) values
  ('00000000-0000-0000-0000-0000000306e1', '00000000-0000-0000-0000-0000000306b1', 'Test Driver 3061', '+60100030601',
   'approved', '{eHailing}', '{Semenanjung 306}'),
  ('00000000-0000-0000-0000-0000000306e2', '00000000-0000-0000-0000-0000000306b2', 'Test Driver 3062', '+60100030602',
   'approved', '{eHailing}', '{Semenanjung 306}'),
  ('00000000-0000-0000-0000-0000000306e3', '00000000-0000-0000-0000-0000000306b3', 'Test Driver 3063', '+60100030603',
   'approved', '{eHailing}', '{Semenanjung 306}'),
  ('00000000-0000-0000-0000-0000000306e4', '00000000-0000-0000-0000-0000000306b4', 'Test Driver 3064', '+60100030604',
   'approved', '{eHailing}', '{Semenanjung 306}');
update public.partners set driving_since = current_date - interval '10 years' where id = '00000000-0000-0000-0000-0000000306e1';
update public.partners set driving_since = current_date - interval '1 year' where id = '00000000-0000-0000-0000-0000000306e2';
insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, status, start_date, read_fields) values
  ('00000000-0000-0000-0000-0000000306e3', '00000000-0000-0000-0000-0000000306b3', 'licence', 'Driving licence', 'Approved',
   current_date - interval '6 years', '{"kind": "licence", "fields": {}}'),
  ('00000000-0000-0000-0000-0000000306e4', '00000000-0000-0000-0000-0000000306b4', 'licence', 'Driving licence',
   'Pending Review', current_date - interval '9 years', '{"kind": "licence", "fields": {}}');

-- Permits: a driver card and a vehicle permit in Semenanjung, a driver pass in Pulau.
insert into public.permit_types (id, country, key, name, short_name, applies_to, document_id, active) values
  ('00000000-0000-0000-0000-0000000306f1', 'Semenanjung 306', 'card-306', 'Driver card 306', 'Card', 'driver', 'card-306', true),
  ('00000000-0000-0000-0000-0000000306f2', 'Semenanjung 306', 'van-306', 'Vehicle permit 306', 'VP', 'vehicle', null, true),
  ('00000000-0000-0000-0000-0000000306f3', 'Pulau 306', 'pass-306', 'Border pass 306', 'Pass', 'driver', 'pass-306', true);
insert into public.c2c_country_permits (country, permit_type_id, applies_to, position) values
  ('Semenanjung 306', '00000000-0000-0000-0000-0000000306f1', 'vehicle', 1),  -- the type's own kind is kept
  ('Semenanjung 306', '00000000-0000-0000-0000-0000000306f2', 'driver', 2),
  ('Pulau 306', '00000000-0000-0000-0000-0000000306f3', 'driver', 1);
select pg_temp.check((select applies_to = 'driver' from public.c2c_country_permits
                       where permit_type_id = '00000000-0000-0000-0000-0000000306f1')
                     and (select applies_to = 'vehicle' from public.c2c_country_permits
                           where permit_type_id = '00000000-0000-0000-0000-0000000306f2'),
  'driver or vehicle comes from the permit type');
insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, status, expiry_date) values
  ('00000000-0000-0000-0000-0000000306e1', '00000000-0000-0000-0000-0000000306b1', 'card-306', 'Driver card 306',
   'Approved', current_date + 100),
  ('00000000-0000-0000-0000-0000000306e2', '00000000-0000-0000-0000-0000000306b2', 'card-306', 'Driver card 306',
   'Approved', current_date - 1);
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status,
                            service_countries, partner_types, energy_type, joined_at) values
  ('00000000-0000-0000-0000-0000000306d1', '00000000-0000-0000-0000-0000000306b1', '00000000-0000-0000-0000-0000000306e1',
   'TST 3061', 'Testmake', 'Alpha', 'Silver', 'approved', '{Semenanjung 306}', '{eHailing}', 'Petrol', now());
insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000306d1', '00000000-0000-0000-0000-0000000306b1');
insert into public.vehicle_documents (vehicle_id, permit_type_id, status, doc_id, doc_name, expiry_date) values
  ('00000000-0000-0000-0000-0000000306d1', '00000000-0000-0000-0000-0000000306f2', 'Approved', 'permit:van-306',
   'Vehicle permit 306', current_date + 100);

select pg_temp.check((select (c->>'ok')::boolean and (c->>'years')::int = 10 and (c->>'minYears')::int = 3
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b1', pg_temp.kl(), pg_temp.ipoh()) c),
  'driver 1, Kuala Lumpur to Ipoh: 10 years and both permits');
select pg_temp.check((select not (c->>'ok')::boolean and (c->>'experienceOk')::boolean
                             and jsonb_array_length(c->'needs') = 1 and c->'needs'->0->>'name' = 'Border pass 306'
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b1', pg_temp.petaling(), pg_temp.pulau()) c),
  'driver 1, into Pulau: needs its border pass');
select pg_temp.check((select (c->>'ok')::boolean
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b1', pg_temp.kl(), pg_temp.ipoh(),
                                                     array['Semenanjung 306']) c)
                     and not public.c2c_driver_ok('00000000-0000-0000-0000-0000000306b1', pg_temp.kl(), pg_temp.ipoh(),
                                                  array['Pulau 306']),
  'a country the trip goes through counts');
select pg_temp.check((select not (c->>'ok')::boolean and not (c->>'experienceOk')::boolean and (c->>'years')::int = 1
                             and jsonb_array_length(c->'needs') = 2
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b2', pg_temp.kl(), pg_temp.ipoh()) c),
  'driver 2: 1 year, an expired card and no vehicle permit');
select pg_temp.check((select (c->>'experienceOk')::boolean and (c->>'years')::int = 6
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b3', pg_temp.kl(), pg_temp.ipoh()) c),
  'driver 3: no date given, an approved licence 6 years old');
select pg_temp.check((select not (c->>'experienceOk')::boolean and c->'years' = 'null'::jsonb
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b4', pg_temp.kl(), pg_temp.ipoh()) c),
  'driver 4: a licence still in review and no date: experience unknown, not enough');
select pg_temp.check((select (c->>'experienceOk')::boolean
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b4', pg_temp.kl(),
                                                     pg_temp.at('Semenanjung 306', 'Pinang 306')) c),
  'a rule with no restriction: any driver');
select pg_temp.check((select (c->>'experienceOk')::boolean and (c->>'minYears')::int = 5
                        from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b3', pg_temp.petaling(), pg_temp.pulau()) c)
                     and (select not (c->>'experienceOk')::boolean
                            from public.c2c_driver_check('00000000-0000-0000-0000-0000000306b2', pg_temp.petaling(), pg_temp.pulau()) c),
  'a rule''s own 5 years: 6 is enough, 1 is not');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306b2',
    $q$select public.c2c_driver_check('00000000-0000-0000-0000-0000000306b1', '{}', '{}')$q$) like '%not_authorized%',
  'a driver can''t check another driver');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306b2',
    $q$select public.c2c_driver_check('00000000-0000-0000-0000-0000000306b2', '{}', '{}')$q$) like 'ok%',
  'a driver checks themself');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a3',
    $q$select public.c2c_driver_check('00000000-0000-0000-0000-0000000306b1', '{}', '{}')$q$) like 'ok%',
  'an admin checks any driver');

-- ---- 5. Commission ---------------------------------------------------------------------------------
delete from public.commission_rates;
delete from public.commission_tiers;
delete from public.commission_promotions;
delete from public.commission_service_rates;
update public.app_settings
   set value = value || '{"allowNegativeCredit": true, "negativeLimit": 10}'
 where key = 'commission';
insert into public.commission_rates (level, rate) values ('master', 0.20);
insert into public.commission_rates (level, country, rate) values ('country', 'Semenanjung 306', 0.15);
insert into public.commission_rates (level, user_id, rate) values ('user', '00000000-0000-0000-0000-0000000306b1', 0.10);
insert into public.commission_service_rates (service_id, service_name, rate)
select id::text, 'City to City', 0.12 from public.settings_entries
 where category = 'vehicle-services' and values->>'name' = 'City to City' order by position limit 1;

select pg_temp.check((select rate = 0.12 and level = 'service' from public.commission_resolve(
    '00000000-0000-0000-0000-0000000306b2', null, null, 'Semenanjung 306', 'Selatan 306', null, null, 'City to City')),
  'the service''s rate beats the place rate');
select pg_temp.check((select rate = 0.12 and level = 'service' from public.commission_resolve(
    '00000000-0000-0000-0000-0000000306b2', null, null, 'Semenanjung 306', 'Selatan 306', null, null,
    (select id::text from public.settings_entries where category = 'vehicle-services' and values->>'name' = 'City to City'
      order by position limit 1))),
  'the service named by its id');
select pg_temp.check((select rate = 0.15 and level = 'country' from public.commission_resolve(
    '00000000-0000-0000-0000-0000000306b2', null, null, 'Semenanjung 306', 'Selatan 306', null, null, 'Another 306')),
  'a service without its own rate: the place rate');
select pg_temp.check((select rate = 0.15 and level = 'country' from public.commission_resolve(
    '00000000-0000-0000-0000-0000000306b2', null, null, 'Semenanjung 306', 'Selatan 306', null, null)),
  'the 7-argument form is as before');
select pg_temp.check((select rate = 0.10 and level = 'user' from public.commission_resolve(
    '00000000-0000-0000-0000-0000000306b1', null, null, 'Semenanjung 306', 'Selatan 306', null, null, 'City to City')),
  'the driver''s own rate beats the service''s');
update public.commission_service_rates set active = false;
select pg_temp.check((select rate = 0.15 from public.commission_resolve(
    '00000000-0000-0000-0000-0000000306b2', null, null, 'Semenanjung 306', null, null, null, 'City to City')),
  'a service rate switched off: the place rate');
update public.commission_service_rates set active = true;

-- Locked at accept: the service rate, a tier on it, a lower promotion over both.
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, state, city, service) values
  ('00000000-0000-0000-0000-000000030681', '00000000-0000-0000-0000-0000000306c1', 'open', 140, 140,
   'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 'City to City'),
  ('00000000-0000-0000-0000-000000030682', '00000000-0000-0000-0000-0000000306c1', 'open', 140, 140,
   'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 'City to City'),
  ('00000000-0000-0000-0000-000000030683', '00000000-0000-0000-0000-0000000306c1', 'open', 140, 140,
   'Semenanjung 306', 'Kuala Lumpur 306', 'Kuala Lumpur 306', 'City to City');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000306b2', accepted_at = now()
 where id = '00000000-0000-0000-0000-000000030681';
select pg_temp.check((select commission_rate = 0.12 and commission_base_rate = 0.12 and commission_promotion_id is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000030681'),
  'accepted: the service''s 12 % is locked');
insert into public.commission_tiers (id, name, metric, window_days, threshold, adjust, value) values
  ('00000000-0000-0000-0000-0000000306d9', 'Everyone 306', 'trips', 7, 0, 'minus', 0.01);
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000306b2', accepted_at = now()
 where id = '00000000-0000-0000-0000-000000030682';
select pg_temp.check((select commission_rate = 0.11 and commission_tier_id = '00000000-0000-0000-0000-0000000306d9'
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000030682'),
  'a tier lowers the service rate as it lowers a place rate');
insert into public.commission_promotions (id, name, rate, starts_at, ends_at, services) values
  ('00000000-0000-0000-0000-0000000306d8', 'Intercity week 306', 0.08, now() - interval '1 day', now() + interval '1 day',
   '{city to city}');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000306b2', accepted_at = now()
 where id = '00000000-0000-0000-0000-000000030683';
select pg_temp.check((select commission_rate = 0.08 and commission_promotion_id = '00000000-0000-0000-0000-0000000306d8'
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000030683'),
  'a running promotion lower than the service rate wins');

-- ---- 6. Who reads and writes -----------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306c1',
    $q$select 1 from public.c2c_route_rules where id = '00000000-0000-0000-0000-000000030601'$q$) = 'ok 1',
  'a rider reads the rules');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306c1',
    $q$select 1 from public.city_to_city_settings$q$) = 'ok 1',
  'a rider reads the settings');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306c1',
    $q$update public.c2c_route_rules set add_on_amount = 0$q$) = 'ok 0',
  'a rider changes no rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306c1',
    $q$insert into public.c2c_route_rules (from_places, to_places)
       values ('[{"level":"country","country":"X"}]', '[{"level":"country","country":"Y"}]')$q$) like '%row-level security%',
  'a rider adds no rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a3',
    $q$update public.city_to_city_settings set cancel_fee_amount = 1$q$) = 'ok 0',
  'an admin with READ on City to City changes nothing');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a2',
    $q$update public.c2c_route_rules set add_on_amount = 0$q$) = 'ok 0',
  'an admin of another page changes no rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a1',
    $q$update public.city_to_city_settings set cancel_fee_amount = 25, cancel_free_hours = 12$q$) = 'ok 1',
  'an admin with EDIT on City to City changes the settings');
select pg_temp.check((select updated_by = '00000000-0000-0000-0000-0000000306a1' and cancel_fee_amount = 25
                        from public.city_to_city_settings),
  'and is stamped as who changed them');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a1',
    $q$update public.city_to_city_settings set pay_in_app = false, pay_cash = false$q$) like '%city_to_city_settings_pay%',
  'at least one payment method stays on');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a1',
    $q$insert into public.c2c_route_rules (from_places, to_places, fare_mode)
       values ('[{"level":"city","country":"Semenanjung 306"}]', '[{"level":"country","country":"Y"}]', 'card')$q$)
    like '%c2c_route_rules_from_places_check%',
  'a place without its own name is refused');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a1',
    $q$insert into public.c2c_route_rules (from_places, to_places, fare_mode)
       values ('[{"level":"country","country":"X"}]', '[{"level":"country","country":"Y"}]', 'fixed')$q$)
    like '%c2c_route_rules_fixed%',
  'a fixed fare needs its amount');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a1',
    $q$insert into public.c2c_country_permits (country, permit_type_id)
       values ('Pulau 306', '00000000-0000-0000-0000-0000000306f1')$q$) = 'ok 1',
  'an admin with EDIT on City to City adds a permit');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306c1',
    $q$select 1 from public.commission_service_rates$q$) = 'ok 0',
  'a rider reads no service rates');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a1',
    $q$update public.commission_service_rates set rate = 0.01$q$) = 'ok 0',
  'an admin without Commission changes no service rate');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306a2',
    $q$update public.commission_service_rates set rate = 0.13$q$) = 'ok 1',
  'an admin with EDIT on Commission changes a service rate');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000306c1',
    $q$select public.c2c_quote(null, null, '{"country":"Semenanjung 306"}', '{"country":"Semenanjung 306"}', 100, 60)$q$)
    like 'ok%',
  'a rider gets a quote');
select pg_temp.check(not has_function_privilege('anon', 'public.c2c_quote(double precision, double precision, jsonb, jsonb, numeric, numeric, text)', 'execute')
                     and not has_function_privilege('authenticated',
                       'public.commission_resolve(uuid, double precision, double precision, text, text, text, text, text)', 'execute'),
  'no quote signed out; the service-aware commission is the server''s');

select 'city_to_city_0306: all passed';
rollback;
