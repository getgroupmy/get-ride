-- ============================================================================
-- Regression test for migration 0316: Premium service rules and GET.Plus.
--   * the rules by place: built-in defaults, Default, a region key by key,
--     bad values refused, who writes them;
--   * Premium: the flag on a Vehicle Service, a driver's car age, model,
--     rating and trips against the rules (the reasons), rules off at a
--     place, an offer refused (PREMIUM_NOT_ELIGIBLE), the read rule's
--     check, the driver's own status;
--   * GET.Plus: join from GET.wallet (receipt, price check, a short
--     wallet), cancel and resume, a member's ride stamped (and the app kept
--     out of those columns), the discount settled on completion (the driver
--     credited, the cap, what is left to pay), free cancels (fee waived, the
--     driver credited, the count, the terms), renewal, grace, expiry and
--     end; members and revenue for admins only; the three edits in place.
-- The same rule, model and price cases are in test/premium_plus_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/premium_getplus_0316.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000316a1'),  -- admin, EDIT on Premium and GET.Plus
  ('00000000-0000-0000-0000-0000000316a2'),  -- admin, READ on it
  ('00000000-0000-0000-0000-0000000316b1'),  -- driver: new car on the list, 4.9, 500 trips
  ('00000000-0000-0000-0000-0000000316b2'),  -- driver: 9-year-old car off the list, 4.2, 20 trips
  ('00000000-0000-0000-0000-0000000316b3'),  -- driver: no car
  ('00000000-0000-0000-0000-0000000316c1'),  -- rider, joins GET.Plus
  ('00000000-0000-0000-0000-0000000316c2')   -- rider, empty wallet
on conflict do nothing;
insert into public.profiles (id, name) values
  ('00000000-0000-0000-0000-0000000316a1', 'Test Admin 316'),
  ('00000000-0000-0000-0000-0000000316a2', 'Test Reader 316'),
  ('00000000-0000-0000-0000-0000000316b1', 'Test Driver 3161'),
  ('00000000-0000-0000-0000-0000000316b2', 'Test Driver 3162'),
  ('00000000-0000-0000-0000-0000000316b3', 'Test Driver 3163'),
  ('00000000-0000-0000-0000-0000000316c1', 'Test Rider 3161'),
  ('00000000-0000-0000-0000-0000000316c2', 'Test Rider 3162')
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000316a1', 'admin-settings-premium-plus', 'edit'),
  ('00000000-0000-0000-0000-0000000316a2', 'admin-settings-premium-plus', 'read')
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
-- What [p_sql] does as [p_user]: 'ok' with the rows it touched, or the error and its hint.
create or replace function pg_temp.run_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare
  n integer;
  h text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  perform pg_temp.as_server();
  return sqlerrm || ' | ' || coalesce(h, '');
end $$;
-- [p_sql]'s jsonb answer as [p_user] (raises on error).
create or replace function pg_temp.json_as(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return v;
exception when others then
  perform pg_temp.as_server();
  raise;
end $$;
create or replace function pg_temp.balance(p uuid) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = 'get_wallet'), 0);
$$;

-- ---- The rules by place ------------------------------------------------------------------------------
select pg_temp.check((public.premium_plus_rules_at('Nowhere 316', null, null, null)->>'premiumMaxCarAge')::int = 5
                     and (public.premium_plus_rules_at('Nowhere 316', null, null, null)->>'plusOn')::boolean = false,
                     'the Default row and the built-in defaults agree');
select pg_temp.check(not public.premium_plus_rules_valid('{"plusDiscountPct": 95}'), 'a discount over 90 % is refused');
select pg_temp.check(not public.premium_plus_rules_valid('{"premiumMaxCarAge": 2.5}'), 'car age is whole years');
select pg_temp.check(not public.premium_plus_rules_valid('{"premiumModels": [""]}'), 'a blank model is refused');
select pg_temp.check(not public.premium_plus_rules_valid('{"surprise": 1}'), 'an unknown key is refused');
select pg_temp.check(public.premium_plus_rules_valid('{"premiumModels": ["Toyota Camry", "Lexus"], "plusOn": true}'),
                     'models and a switch are fine');

select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316a2',
  $$insert into public.premium_plus_places (level, country, rules) values ('country', 'Testland 316', '{}')$$)
  like '%row-level security%', 'an admin who can only read can''t add a rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1',
  $$update public.premium_plus_places set rules = rules || '{"plusPrice": 1}' where level = 'default'$$) = 'ok 0',
  'a rider can''t change the rules');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316a1',
  $$update public.premium_plus_places set rules = rules || '{"plusOn": true, "premiumModels": ["Testmake Alpha", "Lux 316"]}'
     where level = 'default'$$) = 'ok 1', 'the admin turns GET.Plus on and lists models');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316a1',
  $$insert into public.premium_plus_places (level, country, rules) values ('country', 'Testland 316',
      '{"plusPrice": 9.5, "plusDiscountPct": 20, "plusFreeCancels": 1, "premiumMaxCarAge": 3}')$$) = 'ok 1',
  'the admin adds a region rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316a1',
  $$insert into public.premium_plus_places (level, country, state, rules) values ('state', 'Testland 316', 'North 316',
      '{"premiumOn": false, "plusOn": false}')$$) = 'ok 1', 'and a state rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316a1',
  $$delete from public.premium_plus_places where level = 'default'$$) = 'ok 0', 'Default can''t be removed');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316a1',
  $$insert into public.premium_plus_places (level, country, rules) values ('country', 'Badland 316', '{"plusPrice": -1}')$$)
  like '%premium_plus_places_valid%', 'a bad value is refused');

select pg_temp.check((select (v->>'plusPrice')::numeric = 9.5 and (v->>'plusDiscountPct')::numeric = 20
                             and (v->>'premiumMaxCarAge')::int = 3 and (v->>'premiumMinRating')::numeric = 4.8
                             and (v->>'plusOn')::boolean and v->'premiumModels' = '["Testmake Alpha", "Lux 316"]'
                        from public.premium_plus_rules_at('Testland 316', 'South 316', 'Town 316', null) v),
                     'a region rule overrides only what it sets');
select pg_temp.check((select not (v->>'plusOn')::boolean and not (v->>'premiumOn')::boolean
                             and (v->>'plusPrice')::numeric = 9.5
                        from public.premium_plus_rules_at('testland 316', 'NORTH 316', null, null) v),
                     'the smaller place wins, names compared without case');

-- ---- Premium -------------------------------------------------------------------------------------
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000031601', 'vehicle-services', '{"name": "Premium 316", "premium": true, "status": true}', 9301),
  ('00000000-0000-0000-0000-000000031602', 'vehicle-services', '{"name": "Ride 316", "status": true}', 9302);
select pg_temp.check(public.vehicle_service_is_premium('premium 316') and public.vehicle_service_is_premium('00000000-0000-0000-0000-000000031601')
                     and not public.vehicle_service_is_premium('Ride 316') and not public.vehicle_service_is_premium(null),
                     'the Premium flag, by name or id');
select pg_temp.check('premium 316' = any (public.premium_service_keys()), 'the Premium names for the read rule');

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, rating, total_rides) values
  ('00000000-0000-0000-0000-0000000316e1', '00000000-0000-0000-0000-0000000316b1', 'Test Driver 3161', '+60100031601',
   'approved', '{eHailing}', '{Testland 316}', 4.9, 500),
  ('00000000-0000-0000-0000-0000000316e2', '00000000-0000-0000-0000-0000000316b2', 'Test Driver 3162', '+60100031602',
   'approved', '{eHailing}', '{Testland 316}', 4.2, 20),
  ('00000000-0000-0000-0000-0000000316e3', '00000000-0000-0000-0000-0000000316b3', 'Test Driver 3163', '+60100031603',
   'approved', '{eHailing}', '{Testland 316}', 5, 900);
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, year, registration_date, status) values
  ('00000000-0000-0000-0000-0000000316d1', '00000000-0000-0000-0000-0000000316b1', '00000000-0000-0000-0000-0000000316e1',
   'TST 3161', 'Testmake', 'Alpha', extract(year from current_date)::text, current_date - 100, 'approved'),
  ('00000000-0000-0000-0000-0000000316d2', '00000000-0000-0000-0000-0000000316b2', '00000000-0000-0000-0000-0000000316e2',
   'TST 3162', 'Oldmake', 'Beta', (extract(year from current_date)::int - 9)::text, null, 'approved');
insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000316d1', '00000000-0000-0000-0000-0000000316b1');

-- Default rules (5 years) in Otherland; Testland's 3 years.
select pg_temp.check((select (c->>'ok')::boolean and (c->>'carAge')::int = 0
                        from public.premium_driver_check('00000000-0000-0000-0000-0000000316b1', 'Premium 316',
                                                         'Testland 316', null, null, null) c),
                     'a new listed car, 4.9 and 500 trips qualify');
select pg_temp.check((select not (c->>'ok')::boolean and jsonb_array_length(c->'reasons') = 4
                             and c->>'reasons' like '%9 years old. Premium takes cars 3 years old or newer%'
                             and c->>'reasons' like '%your Oldmake Beta isn''t on the list%'
                             and c->>'reasons' like '%Your rating is 4.2. Premium needs 4.8 or more%'
                             and c->>'reasons' like '%You have 20 trips. Premium needs 200 or more%'
                        from public.premium_driver_check('00000000-0000-0000-0000-0000000316b2', 'Premium 316',
                                                         'Testland 316', null, null, null) c),
                     'an old car off the list, a low rating and few trips: four reasons');
select pg_temp.check((select not (c->>'ok')::boolean and c->>'reasons' like '%Choose the car you''re driving first%'
                        from public.premium_driver_check('00000000-0000-0000-0000-0000000316b3', 'Premium 316',
                                                         'Otherland 316', null, null, null) c),
                     'no car: choose one first');
select pg_temp.check((select (c->>'ok')::boolean and not (c->>'rulesOn')::boolean
                        from public.premium_driver_check('00000000-0000-0000-0000-0000000316b2', 'Premium 316',
                                                         'Testland 316', 'North 316', null, null) c),
                     'Premium rules off at a place: anyone');
select pg_temp.check((select (c->>'ok')::boolean and not (c->>'premium')::boolean
                        from public.premium_driver_check('00000000-0000-0000-0000-0000000316b2', 'Ride 316',
                                                         'Testland 316', null, null, null) c),
                     'not a Premium service: no rules');
select pg_temp.check(public.premium_model_allowed('["Lux 316"]', 'LUX 316', 'Anything')
                     and public.premium_model_allowed('["Testmake  Alpha"]', 'testmake', 'alpha')
                     and not public.premium_model_allowed('["Testmake Alpha"]', 'Testmake', 'Alphaville')
                     and public.premium_model_allowed('[]', null, null),
                     'a make allows its models; make and model match whole; an empty list allows all');

select pg_temp.check(pg_temp.json_as('00000000-0000-0000-0000-0000000316b2',
                       'select public.my_premium_status()')->0->>'service' = 'Premium 316'
                     and not (pg_temp.json_as('00000000-0000-0000-0000-0000000316b2',
                       'select public.my_premium_status()')->0->>'ok')::boolean,
                     'the driver sees why they don''t qualify');

-- An offer on a Premium request: the trigger decides before anything else
-- (the insert grant and policy are the test's, rolled back with it).
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, service) values
  ('00000000-0000-0000-0000-000000031681', '00000000-0000-0000-0000-0000000316c2', 'open', 40, 40, 'Testland 316', 'Premium 316');
grant insert on public.ride_offers to authenticated;
create policy "ride_offers test 316" on public.ride_offers for insert to authenticated with check (true);
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316b2',
  $$insert into public.ride_offers (request_id, partner_id, amount, expires_at)
    values ('00000000-0000-0000-0000-000000031681', '00000000-0000-0000-0000-0000000316b2', 40, now() + interval '15 seconds')$$)
  like 'PREMIUM_NOT_ELIGIBLE | You can''t take Premium requests yet. Your car is 9 years old.%',
  'an offer from a driver who doesn''t qualify is refused with the reasons');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316b1',
  $$insert into public.ride_offers (request_id, partner_id, amount, expires_at)
    values ('00000000-0000-0000-0000-000000031681', '00000000-0000-0000-0000-0000000316b1', 40, now() + interval '15 seconds')$$)
  not like 'PREMIUM_NOT_ELIGIBLE%', 'an offer from one who does is not refused for Premium');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316b2',
  $$select 1 from public.ride_requests where id = '00000000-0000-0000-0000-000000031681'$$) = 'ok 0',
  'a driver who doesn''t qualify doesn''t see the open Premium request');
-- A take written on the row (older apps): the read rules are set aside so
-- the trigger is reached (rolled back with the test).
alter table public.ride_requests disable row level security;
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316b2',
  $$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000316b2'
     where id = '00000000-0000-0000-0000-000000031681'$$) like 'PREMIUM_NOT_ELIGIBLE | %Oldmake Beta%',
  'nor can that driver take it on the row');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316b1',
  $$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000316b1'
     where id = '00000000-0000-0000-0000-000000031681'$$) not like 'PREMIUM_NOT_ELIGIBLE%',
  'a driver who qualifies is not refused for Premium');
alter table public.ride_requests enable row level security;
select pg_temp.check(pg_temp.json_as('00000000-0000-0000-0000-0000000316b2',
                       $$select to_jsonb(public.premium_caller_sees('Premium 316', null, null, 'Testland 316', null, null))$$) = 'false'
                     and pg_temp.json_as('00000000-0000-0000-0000-0000000316b1',
                       $$select to_jsonb(public.premium_caller_sees('Premium 316', null, null, 'Testland 316', null, null))$$) = 'true',
                     'the read rule''s check');
select pg_temp.check(exists (select 1 from pg_policies where tablename = 'ride_requests' and policyname = 'ride_requests premium'
                              and permissive = 'RESTRICTIVE'), 'the read rule is restrictive');

-- ---- GET.Plus: join ------------------------------------------------------------------------------
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000316c1', 'get_wallet', 'topup', 100, 'admin', 'Test top-up 316');

select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.plus_join(null, null, 'Testland 316', null, null, 19.9)$$) like 'PLUS_PRICE_CHANGED | 9.50%',
  'a price the rider wasn''t shown is refused with the price');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c2',
  $$select public.plus_join(null, null, 'Testland 316', null, null, 9.5)$$) like 'insufficient_balance | Top up GET.wallet%',
  'a short wallet can''t join');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.plus_join(null, null, 'Testland 316', 'North 316', null, null)$$) like 'PLUS_OFF%',
  'nor where GET.Plus is off');
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.plus_join(null, null, 'Testland 316', null, null, 9.5)$$)->>'charged')::numeric = 9.5,
  'the rider joins for RM 9.50');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000316c1') = 90.5
                     and exists (select 1 from public.wallet_transactions where user_id = '00000000-0000-0000-0000-0000000316c1'
                                  and kind = 'plus_fee' and amount = -9.5)
                     and exists (select 1 from public.plus_charges where rider_id = '00000000-0000-0000-0000-0000000316c1'
                                  and kind = 'join' and status = 'paid' and amount = 9.5 and wallet_tx_id is not null)
                     and exists (select 1 from public.plus_memberships where rider_id = '00000000-0000-0000-0000-0000000316c1'
                                  and status = 'active' and auto_renew and month_price = 9.5 and country = 'Testland 316'
                                  and period_end between now() + interval '27 days' and now() + interval '32 days'),
                     'paid from GET.wallet, with a receipt, a month');
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.plus_join(null, null, 'Testland 316', null, null, 9.5)$$)->>'charged')::numeric = 0
  and pg_temp.balance('00000000-0000-0000-0000-0000000316c1') = 90.5, 'joining again while paid up charges nothing');
select pg_temp.check(not (pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.plus_set_auto_renew(false)$$)->>'autoRenew')::boolean, 'cancel: it runs to the end of the month');
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.premium_plus_terms(null, null, 'Testland 316', null, null)$$)->'membership'->>'live')::boolean,
  'still a member after cancelling');
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.plus_join(null, null, 'Testland 316', null, null, 9.5)$$)->'membership'->>'autoRenew')::boolean
  and pg_temp.balance('00000000-0000-0000-0000-0000000316c1') = 90.5, 'resumed without a charge');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c2',
  $$select 1 from public.plus_memberships$$) = 'ok 0'
  and pg_temp.run_as('00000000-0000-0000-0000-0000000316c2', $$select 1 from public.plus_charges$$) = 'ok 0',
  'another rider sees nothing of it');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1', $$select 1 from public.plus_charges$$) = 'ok 1',
  'the member reads their receipt');
select pg_temp.check((select (t->'benefits'->>'pct')::numeric = 20 and (t->'benefits'->>'freeCancelsLeft')::int = 1
                             and (t->'premium'->>'maxCarAge')::int = 3 and (t->'premium'->>'modelsListed')::boolean
                             and (t->'plus'->>'price')::numeric = 9.5
                        from pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
                               $$select public.premium_plus_terms(null, null, 'Testland 316', null, null)$$) t),
                     'the terms the app shows');

-- ---- GET.Plus: a member's ride -------------------------------------------------------------------
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, service, plus_pct, plus_discount) values
  ('00000000-0000-0000-0000-000000031691', '00000000-0000-0000-0000-0000000316c1', 'open', 30, 30, 'Testland 316', 'Ride 316', 90, 99),
  ('00000000-0000-0000-0000-000000031692', '00000000-0000-0000-0000-0000000316c2', 'open', 30, 30, 'Testland 316', 'Ride 316', null, null);
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, state, service) values
  ('00000000-0000-0000-0000-000000031693', '00000000-0000-0000-0000-0000000316c1', 'open', 30, 30, 'Testland 316', 'North 316',
   'Ride 316');
select pg_temp.check((select plus_pct = 20 and plus_priority and plus_discount is null and plus_max_discount is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031691'),
                     'a member''s request is stamped by the server, whatever was sent');
select pg_temp.check((select plus_pct is null and not plus_priority from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000031692'), 'not a member: nothing');
select pg_temp.check((select plus_pct is null from public.ride_requests where id = '00000000-0000-0000-0000-000000031693'),
                     'a member picked up where GET.Plus is off: nothing');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1',
  $$update public.ride_requests set plus_pct = 90 where id = '00000000-0000-0000-0000-000000031691'$$)
  like 'RIDE_SERVER_ONLY%', 'the app can''t change GET.Plus on a ride');

-- The trip: driver b1, completed at RM 30.
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000316b1', status = 'accepted', accepted_at = now()
 where id = '00000000-0000-0000-0000-000000031691';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-000000031691';
update public.ride_requests set status = 'completed', completed_at = now() where id = '00000000-0000-0000-0000-000000031691';
select pg_temp.check((select plus_discount = 6 and plus_settled_at is not null
                             and public.ride_left_to_pay(r) = round(public.ride_amount_due(r) - 6, 2)
                        from public.ride_requests r where id = '00000000-0000-0000-0000-000000031691'),
                     'completed: 20 % off, taken off what the rider pays');
select pg_temp.check((select count(*) = 1 and sum(amount) = 6 from public.wallet_transactions
                       where ride_id = '00000000-0000-0000-0000-000000031691' and kind = 'plus_credit'
                         and user_id = '00000000-0000-0000-0000-0000000316b1'),
                     'and the driver is credited the discount, once');
select public.plus_settle_ride('00000000-0000-0000-0000-000000031691');
select pg_temp.check((select count(*) = 1 from public.wallet_transactions
                       where ride_id = '00000000-0000-0000-0000-000000031691' and kind = 'plus_credit'), 'settled once only');

-- A cap of RM 4.
update public.premium_plus_places set rules = rules || '{"plusMaxDiscount": 4}' where place_key = 'testland 316';
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, service) values
  ('00000000-0000-0000-0000-000000031694', '00000000-0000-0000-0000-0000000316c1', 'open', 30, 30, 'Testland 316', 'Ride 316');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000316b1', status = 'accepted', accepted_at = now()
 where id = '00000000-0000-0000-0000-000000031694';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-000000031694';
update public.ride_requests set status = 'completed', completed_at = now() where id = '00000000-0000-0000-0000-000000031694';
select pg_temp.check((select plus_discount = 4 from public.ride_requests where id = '00000000-0000-0000-0000-000000031694'),
                     'the cap holds');

-- ---- GET.Plus: free cancels -----------------------------------------------------------------------
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, country, service) values
  ('00000000-0000-0000-0000-000000031695', '00000000-0000-0000-0000-0000000316c1', 'open', 30, 30, 'Testland 316', 'Ride 316'),
  ('00000000-0000-0000-0000-000000031696', '00000000-0000-0000-0000-0000000316c1', 'open', 30, 30, 'Testland 316', 'Ride 316');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000316b1', status = 'accepted',
                                accepted_at = now() - interval '10 minutes'
 where id in ('00000000-0000-0000-0000-000000031695', '00000000-0000-0000-0000-000000031696');
select pg_temp.check((select (t->>'lateFee')::numeric = 0 and (t->>'plusFreeCancelsLeft')::int = 1
                        from pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
                               $$select public.ride_cancel_terms('00000000-0000-0000-0000-000000031695')$$) t),
                     'the cancel terms say it is free, one left');
update public.ride_requests set status = 'cancelled', cancel_requested_by = 'rider', cancelled_at = now()
 where id = '00000000-0000-0000-0000-000000031695';
select pg_temp.check((select cancel_fee = 0 and cancel_fee_status = 'none' and plus_waived_fee > 0
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031695'),
                     'a late cancel is free for a member');
select pg_temp.check(exists (select 1 from public.wallet_transactions where ride_id = '00000000-0000-0000-0000-000000031695'
                              and kind = 'plus_cancel_credit' and user_id = '00000000-0000-0000-0000-0000000316b1'
                              and amount > 0),
                     'the driver is credited what the fee would have paid');
select pg_temp.check((select free_cancels_used = 1 from public.plus_memberships
                       where rider_id = '00000000-0000-0000-0000-0000000316c1'), 'one free cancel used');
select pg_temp.check((select (t->>'lateFee')::numeric > 0 and not t ? 'plusFreeCancelsLeft'
                        from pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
                               $$select public.ride_cancel_terms('00000000-0000-0000-0000-000000031696')$$) t),
                     'none left: the terms show the fee again');
update public.ride_requests set status = 'cancelled', cancel_requested_by = 'rider', cancelled_at = now()
 where id = '00000000-0000-0000-0000-000000031696';
select pg_temp.check((select cancel_fee > 0 and cancel_fee_status = 'charged' and plus_waived_fee is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000031696'),
                     'the next one is charged');

-- ---- GET.Plus: renewal, grace, expiry, end ---------------------------------------------------------
update public.plus_memberships set period_end = now() - interval '1 hour', period_start = now() - interval '1 month'
 where rider_id = '00000000-0000-0000-0000-0000000316c1';
select pg_temp.check((public.plus_renew_due()->>'renewed')::int >= 1, 'the job renews a member whose month ended');
select pg_temp.check((select status = 'active' and free_cancels_used = 0 and period_end > now() + interval '27 days'
                        from public.plus_memberships where rider_id = '00000000-0000-0000-0000-0000000316c1')
                     and exists (select 1 from public.plus_charges where rider_id = '00000000-0000-0000-0000-0000000316c1'
                                  and kind = 'renewal' and status = 'paid' and amount = 9.5),
                     'renewed on time: the next month, a receipt, the free cancels back');

-- The wallet is short.
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
select '00000000-0000-0000-0000-0000000316c1', 'get_wallet', 'payment', -pg_temp.balance('00000000-0000-0000-0000-0000000316c1'),
       'admin', 'Test 316 empties the wallet';
update public.plus_memberships set period_end = now() - interval '1 hour' where rider_id = '00000000-0000-0000-0000-0000000316c1';
select public.plus_renew_due();
select pg_temp.check((select status = 'grace' and grace_until between now() + interval '2 days' and now() + interval '3 days'
                        from public.plus_memberships where rider_id = '00000000-0000-0000-0000-0000000316c1')
                     and exists (select 1 from public.plus_charges where rider_id = '00000000-0000-0000-0000-0000000316c1'
                                  and status = 'failed'),
                     'short: grace for 3 days, a failed receipt');
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.premium_plus_terms(null, null, 'Testland 316', null, null)$$)->'benefits') is not null,
  'benefits kept in grace');
update public.plus_memberships set grace_until = now() - interval '1 minute' where rider_id = '00000000-0000-0000-0000-0000000316c1';
select public.plus_renew_due();
select pg_temp.check((select status = 'expired' and ended_at is not null from public.plus_memberships
                       where rider_id = '00000000-0000-0000-0000-0000000316c1'), 'grace over: expired');
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.premium_plus_terms(null, null, 'Testland 316', null, null)$$)->'benefits') = 'null'::jsonb
  or (pg_temp.json_as('00000000-0000-0000-0000-0000000316c1',
  $$select public.premium_plus_terms(null, null, 'Testland 316', null, null)$$)->'benefits') is null,
  'no benefits once expired');

-- Paid again, then not renewing: ended.
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000316c1', 'get_wallet', 'topup', 20, 'admin', 'Test top-up 316');
select pg_temp.json_as('00000000-0000-0000-0000-0000000316c1', $$select public.plus_join(null, null, 'Testland 316', null, null, 9.5)$$);
select pg_temp.json_as('00000000-0000-0000-0000-0000000316c1', $$select public.plus_set_auto_renew(false)$$);
update public.plus_memberships set period_end = now() - interval '1 hour' where rider_id = '00000000-0000-0000-0000-0000000316c1';
select pg_temp.check((public.plus_renew_due()->>'ended')::int >= 1, 'the job ends a cancelled membership');
select pg_temp.check((select status = 'ended' from public.plus_memberships
                           where rider_id = '00000000-0000-0000-0000-0000000316c1')
                     and pg_temp.balance('00000000-0000-0000-0000-0000000316c1') = 10.5,
                     'not renewing: it ends, nothing charged');

-- ---- Admin ---------------------------------------------------------------------------------------
select pg_temp.check((pg_temp.json_as('00000000-0000-0000-0000-0000000316a2',
  $$select public.admin_plus_members(null, 'rider 3161')$$)->>'total')::int = 1, 'an admin finds a member');
select pg_temp.check((select (m->'rows'->0->>'paid')::numeric = 28.5 and (m->'rows'->0->>'saved')::numeric = 10
                        from pg_temp.json_as('00000000-0000-0000-0000-0000000316a1',
                               $$select public.admin_plus_members('ended')$$) m),
                     'with what they paid and saved');
select pg_temp.check((select (v->>'fees')::numeric >= 28.5 and (v->>'discounts')::numeric >= 10
                             and (v->>'failed')::int >= 1
                        from pg_temp.json_as('00000000-0000-0000-0000-0000000316a1',
                               $$select public.admin_plus_revenue(30)$$) v),
                     'revenue: fees, discounts funded, failed renewals');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1', $$select public.admin_plus_members()$$)
                     like 'Only admins%', 'riders can''t list members');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000316c1', $$select public.admin_plus_revenue()$$)
                     like 'Only admins%', 'nor see revenue');

-- ---- The edits in place --------------------------------------------------------------------------
select pg_temp.check(pg_get_functiondef('public.ride_left_to_pay(public.ride_requests)'::regprocedure) like '%r.plus_discount%',
                     'ride_left_to_pay takes the discount off');
select pg_temp.check(pg_get_functiondef('public.ride_requests_city_cancel_fee()'::regprocedure) like '%plus_cancel_waive%',
                     'the cancel fee asks for a free cancel');
select pg_temp.check(pg_get_functiondef('public.ride_cancel_terms(uuid)'::regprocedure) like '%plus_cancel_terms%',
                     'the cancel terms say so');

rollback;
