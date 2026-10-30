-- ============================================================================
-- Regression test for migration 0329: myGiG, part A.
--   1. Access: all drivers, selected drivers only, nobody, one driver
--      blocked; the partner type's switch; TEKSI never.
--   2. Charges to drivers: per trip (RM and %), a pass bought from GET.credit
--      or GET.wallet that runs to its end and then ends, a driver's own
--      charge, no charge.
--   3. The phone: latest app, older app, not registered, blocked; the name
--      and ID masked as the admin says; a number with many rides flagged;
--      only an online driver with access; rate-limited.
--   4. The price: own fare within the limits, luggage with free bags (the
--      cheapest first), coming to the pickup (capped, waived), busy times,
--      place fees, the region's tax, rounding up, the price guard.
--   5. Places where myGiG isn't allowed; the daily limit.
--   6. Sending and accepting: in the app, on the trip link (token), on the
--      driver's phone; an unanswered request ends with nothing saved.
--   7. The ride: arrived, the waiting charge at the pickup and at a stop,
--      start without a trip code, change destination (accepted, declined),
--      complete with tolls.
--   8. No-show and cancellation fees only for a registered passenger paying
--      in the app.
--   9. Collecting: cash, pay by link (paid, or cash instead), Family (the
--      host's GET.wallet), business (its own settlement); the per-trip fee.
--  10. Blocking a number; who reads what (RLS), the server's columns.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mygig_0329.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000329d1'),  -- driver Hafiz (myGiG type)
  ('00000000-0000-0000-0000-0000000329d2'),  -- driver Lee (myGiG type)
  ('00000000-0000-0000-0000-0000000329d3'),  -- driver Tan (TEKSI only)
  ('00000000-0000-0000-0000-0000000329a1'),  -- passenger Aisha: latest app
  ('00000000-0000-0000-0000-0000000329a2'),  -- passenger Ravi: older app, business
  ('00000000-0000-0000-0000-0000000329f1'),  -- Family host Farid
  ('00000000-0000-0000-0000-0000000329e1')   -- admin
on conflict do nothing;
insert into public.profiles (id, name, phone, ic, id_type, app_version, app_platform) values
  ('00000000-0000-0000-0000-0000000329d1', 'Hafiz Contoh', '+60100329001', null, null, '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000329d2', 'Lee Sample', '+60100329002', null, null, '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000329d3', 'Tan Sample', '+60100329003', null, null, '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000329a1', 'Aisha Rahman', '+60100329011', '900101-14-5678', 'mykad', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000329a2', 'Ravi Kumar', '+60100329012', 'A12345678', 'passport', '0.0.1', 'android'),
  ('00000000-0000-0000-0000-0000000329f1', 'Farid Contoh', '+60100329021', null, null, '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000329e1', 'Admin 329', '+60100329031', null, null, null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone, ic = excluded.ic, id_type = excluded.id_type,
  app_version = excluded.app_version, app_platform = excluded.app_platform;
insert into public.partners (auth_user_id, name, phone, status, partner_types, plate, vehicle) values
  ('00000000-0000-0000-0000-0000000329d1', 'Hafiz Contoh', '+60100329001', 'approved', '{"Gig Car 329"}', 'WXY 2481', 'Perodua Bezza'),
  ('00000000-0000-0000-0000-0000000329d2', 'Lee Sample', '+60100329002', 'approved', '{"Gig Car 329"}', 'VBC 7720', 'Toyota Innova'),
  ('00000000-0000-0000-0000-0000000329d3', 'Tan Sample', '+60100329003', 'approved', '{TEKSI}', 'WRT 1189', 'Proton Saga');
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000329d1', true, 3.11, 101.66, now()),
  ('00000000-0000-0000-0000-0000000329d2', true, 3.11, 101.66, now()),
  ('00000000-0000-0000-0000-0000000329d3', true, 3.11, 101.66, now())
on conflict (profile_id) do update set online = true, updated_at = now();
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000329e1', 'admin-mygig', 'edit');
-- The partner type with myGiG on, and a published app version.
insert into public.settings_entries (category, values, position, active) values
  ('partner-type', '{"name": "Gig Car 329", "vehicleRequired": true,
                     "rules": {"mygig": {"allowed": true, "all": true, "regions": []}}}', 9329, true),
  ('app-version-setting', '{"version": "9.0.0", "platform": "All"}', 9329, true);

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
-- [p_sql] as [p_user] (the app's role): its value as text, or the error.
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  if p_user is null then
    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  else
    perform set_config('role', 'authenticated', true);
    perform pg_temp.as_user(p_user);
  end if;
  execute p_sql into v;
  perform pg_temp.as_server();
  return coalesce(nullif(v, ''), 'ok');
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.j(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v text := pg_temp.value_as(p_user, p_sql);
begin
  return v::jsonb;
exception when others then
  raise exception 'FAILED: % gave %', p_sql, v;
end $$;
create or replace function pg_temp.bal(p_user uuid, p_type text default 'get_wallet') returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = p_type), 0);
$$;
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric, p_type text default 'get_wallet') returns void
language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user, p_type) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, p_type, 'test_adjust', p_to - pg_temp.bal(p_user, p_type), 'test 0329');
  end if;
end $$;
create or replace function pg_temp.rule(p jsonb) returns void language sql as $$
  update public.mygig_rules set settings = public.mygig_merge(settings, p) where level = 'default';
$$;
create temp table t (k text primary key, id uuid, v jsonb);
grant all on t to authenticated, anon;
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create or replace function pg_temp.ride(p_k text) returns public.ride_requests language sql as $$
  select * from public.ride_requests where id = pg_temp.id(p_k) $$;

-- A trip: Bangsar-ish to KL Sentral-ish, about 6 km.
create or replace function pg_temp.trip(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object(
    'pickup', jsonb_build_object('lat', 3.110, 'lng', 101.660, 'name', 'Bangsar South 329', 'here', false),
    'drop', jsonb_build_object('lat', 3.134, 'lng', 101.686, 'name', 'Sentral 329'),
    'stops', '[]'::jsonb, 'km', 6, 'min', 15, 'pax', 1, 'bags', jsonb_build_object('small', 0, 'medium', 0, 'large', 0),
    'pay', 'cash') || p_extra;
$$;
create or replace function pg_temp.send_sql(p_trip jsonb, p_phone text, p_name text, p_way text) returns text
language sql as $$
  select format('select public.mygig_create(%L, 3.11, 101.66)::text',
                jsonb_build_object('trip', p_trip, 'phone', p_phone, 'name', p_name, 'way', p_way));
$$;
create or replace function pg_temp.reset_state() returns void language plpgsql as $$
begin
  perform pg_temp.as_server();
  update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_fee_status = 'none'
   where partner_id in ('00000000-0000-0000-0000-0000000329d1', '00000000-0000-0000-0000-0000000329d2')
     and status in ('accepted', 'arrived', 'on_trip');
end $$;

select pg_temp.rule('{"dailyLimit": 50}');
select set_config('app.d1', '00000000-0000-0000-0000-0000000329d1', true);

-- ---- 1. Access ------------------------------------------------------------------------------------------
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'ok')::boolean,
  'a driver of a myGiG type may, with everyone allowed and no charge');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d3', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'TYPE',
  'TEKSI never gets myGiG (it has the meter)');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329a1', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'NOT_DRIVER',
  'a passenger is no driver');
select public.set_mygig_global('{"who": "none"}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'NOBODY',
  'nobody: off for every driver');
select public.set_mygig_global('{"who": "selected"}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'NOT_SELECTED',
  'selected drivers only: a driver not selected can''t');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_admin_driver_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329d1', '{"allowed": true}'))
  like 'NOT_ALLOWED%', 'a driver can''t select themselves');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_driver_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329d1', '{"allowed": true}'));
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'ok')::boolean,
  'the admin selects the driver');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d2', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'NOT_SELECTED',
  'the other driver is still not selected');
select public.set_mygig_global('{"who": "all"}');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_driver_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329d2', '{"allowed": false}'));
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d2', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'BLOCKED',
  'all drivers, one blocked');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  pg_temp.send_sql(pg_temp.trip(), null, null, 'here')) like 'MYGIG_BLOCKED%', 'and the server refuses them');
select pg_temp.check(jsonb_array_length(pg_temp.j('00000000-0000-0000-0000-0000000329e1',
  'select public.mygig_admin_drivers(''Lee'')::text')) = 1, 'the admin finds drivers by name');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a1',
  'select public.mygig_admin_drivers()::text') like 'not_authorized%', 'nobody else lists them');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_driver_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329d2', '{}'));

-- ---- 2. Charges to drivers --------------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d1', 10, 'get_credit');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d1', 100, 'get_wallet');
select public.set_mygig_global('{"who": "all", "fee": {"mode": "month", "amount": 30, "unit": "RM"}}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'PASS_NEEDED',
  'a monthly charge: a pass first');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_buy_pass(''credit'')::text')
  like 'MYGIG_BALANCE%', 'not enough GET.credit');
insert into t values ('pass', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_buy_pass(''wallet'')::text'));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000329d1') = 70
  and ((select v from t where k = 'pass')->>'endsAt')::timestamptz between now() + interval '29 days' and now() + interval '31 days',
  'the pass from GET.wallet, for a month');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_buy_pass(''wallet'')::text')->>'already')::boolean
  and pg_temp.bal('00000000-0000-0000-0000-0000000329d1') = 70, 'a pass running is not bought twice');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'ok')::boolean,
  'with the pass the driver may');
select public.set_mygig_global('{"who": "all", "fee": {"mode": "week", "amount": 10}}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'code' is null,
  'a pass already bought runs to its end when the charge changes');
update public.mygig_passes set ends_at = now() - interval '1 minute', starts_at = now() - interval '31 days'
 where driver_id = '00000000-0000-0000-0000-0000000329d1';
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'PASS_NEEDED',
  'an ended pass asks again');
select public.set_mygig_global('{"who": "all", "fee": {"mode": "day", "amount": 3}}');
insert into t values ('pass2', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_buy_pass(''credit'')::text'));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000329d1', 'get_credit') = 7
  and (((select v from t where k = 'pass2')->>'endsAt')::timestamptz at time zone 'Asia/Kuala_Lumpur')::time = '23:59',
  'a day pass from GET.credit lasts until 11:59 pm');
-- The driver's own charge, and none.
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_driver_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329d2',
         '{"charge": "custom", "custom": {"mode": "trip", "amount": 5, "unit": "%"}}'));
select pg_temp.check(public.mygig_fee_for('00000000-0000-0000-0000-0000000329d2') @> '{"mode": "trip", "amount": 5, "unit": "%", "own": true}',
  'a driver''s own charge');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_driver_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329d2', '{"charge": "none"}'));
select pg_temp.check(public.mygig_fee_for('00000000-0000-0000-0000-0000000329d2')->>'mode' = 'none'
  and (pg_temp.j('00000000-0000-0000-0000-0000000329d2', 'select public.mygig_config(3.11, 101.66)::text')->>'ok')::boolean,
  'no charge: no pass needed');
select pg_temp.check(public.mygig_trip_fee('{"mode": "trip", "amount": 5, "unit": "%"}', 20) = 1
  and public.mygig_trip_fee('{"mode": "trip", "amount": 1.5, "unit": "RM"}', 20) = 1.5
  and public.mygig_trip_fee('{"mode": "month", "amount": 30}', 20) = 0, 'the per-trip fee, RM or % of the fare');
select public.set_mygig_global('{"who": "all", "fee": {"mode": "trip", "amount": 1, "unit": "RM"}}');

-- ---- 3. The phone -------------------------------------------------------------------------------------------
insert into t values ('lk1', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text'));
select pg_temp.check((select v from t where k = 'lk1') @> '{"state": "latest", "name": "Ai**a", "idType": "MyKad", "id": "•••• 5678"}',
  'registered on the latest app: the name partly hidden, the ID''s last 4 (the default)');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''+60 10-032 9012'', 3.11, 101.66)::text') @> '{"state": "old", "name": "Ra*i"}',
  'registered on an older app');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''0100329099'', 3.11, 101.66)::text')->>'state' = 'none', 'not registered');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''1003'', 3.11, 101.66)::text')->>'state' = 'short', 'not a whole number yet');
select pg_temp.rule('{"nameMode": "full", "idMode": "hide"}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text') @> '{"name": "Aisha Rahman", "id": null}',
  'the admin shows the full name and hides the ID');
select pg_temp.rule('{"nameMode": "hide", "idMode": "full"}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text') @> '{"name": "Registered passenger", "id": "900101-14-5678"}',
  'or hides the name and shows the whole ID');
select pg_temp.rule('{"nameMode": "partial", "idMode": "last4"}');
select pg_temp.check(public.mygig_mask_name('Siti Aminah', 'partial') = 'Si*i' and public.mygig_mask_name('Ali', 'partial') = 'A**'
  and public.mygig_mask_id('A12345678', 'last4') = '•••• 5678', 'masking');
update public.driver_presence set online = false where profile_id = '00000000-0000-0000-0000-0000000329d1';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text') like 'MYGIG_OFFLINE%', 'only while online');
update public.driver_presence set online = true where profile_id = '00000000-0000-0000-0000-0000000329d1';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d3',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text') like 'MYGIG_TYPE%', 'only with myGiG access');
select pg_temp.rule('{"lookupPer10Min": 5}');
do $$
declare v text; n int := 0;
begin
  for i in 1..8 loop
    v := pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', 'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text');
    if v like 'RATE_LIMITED%' then n := n + 1; end if;
  end loop;
  perform pg_temp.check(n = 3, 'five numbers in ten minutes, then refused (' || n || ')');
end $$;
select pg_temp.rule('{"lookupPer10Min": 30}');

-- ---- 4. The price -----------------------------------------------------------------------------------------
-- get.ride's fare: 4 + 0.95 × 6 + 0.25 × 15 = 13.45; no tax here.
insert into t values ('q1', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_quote(%L)::text', pg_temp.trip())));
select pg_temp.check((select v from t where k = 'q1') @> '{"fare": 13.45, "total": 13.45, "ownFare": false, "tax": 0, "guard": false}',
  'get.ride''s myGiG fare');
-- The driver's own fare, kept within the limits (per km at most 2.50).
select pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_save_prefs(''{"ownFare": true, "fare": {"base": 50, "perKm": 9, "perMin": 0.25, "min": 8}}'')::text');
select pg_temp.check((select prefs @> '{"ownFare": true, "fare": {"base": 10, "perKm": 2.5}}' from public.mygig_driver_prefs
                       where driver_id = '00000000-0000-0000-0000-0000000329d1'), 'own fare within the admin''s limits');
-- 10 + 2.5 × 6 + 3.75 = 28.75; the app price 13.45 × 1.5 = 20.18: over the guard.
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_quote(%L)::text', pg_temp.trip()))
  @> '{"fare": 28.75, "ownFare": true, "appPrice": 13.45, "guard": true}', 'the price guard warns');
select pg_temp.rule('{"allowOwnFare": false}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_quote(%L)::text', pg_temp.trip()))
  @> '{"fare": 13.45, "ownFare": false}', 'own fares switched off by the admin: get.ride''s');
select pg_temp.rule('{"allowOwnFare": true}');
-- Luggage: small free, medium 2, large 4; one free bag goes to the cheapest.
select pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_save_prefs(''{"lug": {"small": 1, "medium": 2, "large": 40}, "freeBags": 1,
     "approach": {"mode": "perkm", "perKm": 3, "freeKm": 1}, "busy": {"on": true, "night": 20, "peak": 2, "weekend": 10},
     "roundUp": true, "noShow": {"on": true, "amount": 5}, "cancel": {"on": true, "amount": 50}}'')::text');
select pg_temp.check((select prefs @> '{"lug": {"large": 10}, "cancel": {"amount": 10}}' from public.mygig_driver_prefs
                       where driver_id = '00000000-0000-0000-0000-0000000329d1'), 'per bag and the fees at most the admin''s');
-- Bags: 1 small (free), 2 medium (4), 1 large (10) = 14.
insert into t values ('q2', null, public.mygig_price('00000000-0000-0000-0000-0000000329d1',
  public.mygig_trip_clean(pg_temp.trip('{"bags": {"small": 1, "medium": 2, "large": 1}}'), public.mygig_settings_at('', '', '', '')),
  public.mygig_settings_at('', '', '', ''), public.mygig_prefs_of('00000000-0000-0000-0000-0000000329d1', public.mygig_settings_at('', '', '', '')),
  '{}', '2026-10-28 10:00+08'));
select pg_temp.check((select v from t where k = 'q2') @> '{"luggage": 14, "busy": 0, "roundUp": true}'
  and ((select v from t where k = 'q2')->>'total')::numeric = ceil(((select v from t where k = 'q2')->>'exact')::numeric),
  'luggage with the free bag on the cheapest; rounded up to whole ringgit');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_quote(%L)::text', pg_temp.trip('{"bags": {"small": 6}}'))) like 'MYGIG_BAGS%', 'at most the admin''s bags');
-- Coming to the pickup: 12 km, the first free, 3 a km = 33, capped at 30; waived on this ride.
insert into t values ('q3', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_quote(%L)::text',
  pg_temp.trip('{"approachKm": 12, "pickup": {"lat": 3.2, "lng": 101.7, "name": "Mall 329", "here": false}}'))));
select pg_temp.check((select v from t where k = 'q3') @> '{"approach": 30, "approachFull": 30}', 'coming to the pickup, at most the cap');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_quote(%L)::text',
  pg_temp.trip('{"approachKm": 12, "waiveApproach": true, "pickup": {"lat": 3.2, "lng": 101.7, "name": "Mall 329", "here": false}}')))
  @> '{"approach": 0, "approachFull": 30, "approachWaived": true}', 'waived for this ride');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_quote(%L)::text',
  pg_temp.trip('{"approachKm": 12, "pickup": {"lat": 3.110, "lng": 101.660, "name": "Here 329", "here": true}}')))
  @> '{"approach": 0}', 'nothing when the pickup is where the driver is');
-- Busy times: Saturday 1 am is night (20 %); Wednesday 6 pm peak (RM2); Saturday noon the weekend (10 %).
select pg_temp.check((public.mygig_price('00000000-0000-0000-0000-0000000329d1', pg_temp.trip(), public.mygig_settings_at('', '', '', ''),
   public.mygig_prefs_of('00000000-0000-0000-0000-0000000329d1', public.mygig_settings_at('', '', '', '')), '{}', '2026-10-31 01:00+08')
   ->>'busy')::numeric = 2.69, 'night (prefs saved again: get.ride''s fare, 13.45)');
select pg_temp.check((public.mygig_price('00000000-0000-0000-0000-0000000329d1', pg_temp.trip(), public.mygig_settings_at('', '', '', ''),
   public.mygig_prefs_of('00000000-0000-0000-0000-0000000329d1', public.mygig_settings_at('', '', '', '')), '{}', '2026-10-28 18:00+08')
   ->>'busy')::numeric = 2, 'peak');
select pg_temp.check((public.mygig_price('00000000-0000-0000-0000-0000000329d1', pg_temp.trip(), public.mygig_settings_at('', '', '', ''),
   public.mygig_prefs_of('00000000-0000-0000-0000-0000000329d1', public.mygig_settings_at('', '', '', '')), '{}', '2026-10-31 12:00+08')
   ->>'busy')::numeric = 1.35, 'the weekend');
-- The region's tax and whole fares; a region rule only changes what it sets.
insert into public.countries (name, values) values ('Gigland 329', '{"taxEnabled": true, "taxName": "SST", "taxAmount": 6, "taxType": "percent"}');
insert into public.mygig_rules (level, country, settings) values ('country', 'Gigland 329', '{"fare": {"base": 5}, "guard": 2}');
select pg_temp.check(public.mygig_settings_at('Gigland 329', '', '', '') @> '{"fare": {"base": 5, "perKm": 0.95}, "guard": 2, "dailyLimit": 50}',
  'a region rule overrides only what it sets');
insert into t values ('q4', null, public.mygig_price('00000000-0000-0000-0000-0000000329d2', pg_temp.trip(),
  public.mygig_settings_at('Gigland 329', '', '', ''), public.mygig_prefs_of('00000000-0000-0000-0000-0000000329d2',
  public.mygig_settings_at('Gigland 329', '', '', '')), '{"country": "Gigland 329"}', '2026-10-28 10:00+08'));
-- 5 + 5.7 + 3.75 = 14.45; SST 6 % = 0.87; 15.32.
select pg_temp.check((select v from t where k = 'q4') @> '{"fare": 14.45, "taxName": "SST", "tax": 0.87, "total": 15.32}',
  'the region''s tax');
-- Place fees at the pickup (0324).
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000329b1', jsonb_build_object('name', 'Gig Plaza 329',
    'boundary', '{"bbox":{"north":3.31,"south":3.29,"east":101.81,"west":101.79}}'));
update public.airport_settings set fares_on = false, pick_door_required = false, drop_door_required = false,
       restrict_pickups = false
 where airport_id = '00000000-0000-0000-0000-0000000329b1';
delete from public.place_fees where area_id = '00000000-0000-0000-0000-0000000329b1';
insert into public.place_fees (area_id, name, applies_to, amount) values
  ('00000000-0000-0000-0000-0000000329b1', 'Plaza pickup fee', 'pickup', 5);
create or replace function pg_temp.plaza_trip(p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.trip('{"pickup": {"lat": 3.30, "lng": 101.80, "name": "Gig Plaza 329", "here": true},
                        "drop": {"lat": 3.33, "lng": 101.82, "name": "Town 329"}}' || p_extra);
$$;
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_quote(%L)::text', pg_temp.plaza_trip()))
  @> '{"pickupFee": 5, "placeFees": 5}', 'a place fee at the pickup');

-- ---- 5. Places and the daily limit ---------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  format('select public.mygig_admin_place_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329b1', 'pickup')) like 'NOT_ALLOWED%',
  'a driver sets no place');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_place_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329b1', 'pickup'));
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_quote(%L)::text', pg_temp.plaza_trip()))
  #>> '{problem,code}' = 'MYGIG_NO_PICKUP', 'no myGiG pickups there: the driver sees why');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.plaza_trip(), null, null, 'here'))
  like 'MYGIG_NO_PICKUP%', 'and can''t send');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_place_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329b1', 'drop'));
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  pg_temp.send_sql(pg_temp.trip('{"drop": {"lat": 3.30, "lng": 101.80, "name": "Gig Plaza 329"}}'), null, null, 'here'))
  like 'MYGIG_NO_DROP%', 'no drop-offs there');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  format('select public.mygig_admin_place_set(%L, %L)::text', '00000000-0000-0000-0000-0000000329b1', 'allowed'));
select pg_temp.check(not exists (select 1 from public.mygig_place_rules where area_id = '00000000-0000-0000-0000-0000000329b1'),
  'allowed again');
-- A ride from the plaza carries its fee once (in the agreed price, not again on top).
insert into t values ('op', null, pg_temp.j('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.plaza_trip(), null, null, 'here')));
update t set id = (v->>'offerId')::uuid where k = 'op';
insert into t values ('rp', null, pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_accept_here(%L)::text', pg_temp.id('op'))));
update t set id = (v->>'rideId')::uuid where k = 'rp';
select pg_temp.check((select public.ride_amount_due(r) = (r.mygig #>> '{quote,total}')::numeric and (r.mygig #>> '{quote,pickupFee}')::numeric = 5
                        from public.ride_requests r where r.id = pg_temp.id('rp')), 'the place fee is in the price once');
select pg_temp.check((select status = 'arrived' and arrived_at is not null and waiting_from is not null
                        from pg_temp.ride('rp')), 'picked up where the driver is: arrived, the waiting clock running');
select pg_temp.reset_state();

-- ---- 6. Sending and accepting ---------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip(), '0100329099', '', 'sms'))
  like 'MYGIG_NAME%', 'a number that isn''t registered needs a name');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip('{"pay": "wallet"}'),
  '0100329099', 'Ben', 'sms')) like 'MYGIG_PAY%', 'GET.wallet needs a registered passenger');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip(), '0100329099', 'Ben', 'app'))
  like 'MYGIG_WAY%', 'the app only for the latest app');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip('{"pay": "link"}'), null, null, 'here'))
  like 'MYGIG_PAY%', 'pay by link needs a phone');
select pg_temp.rule('{"phoneRequired": true}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip(), null, null, 'here'))
  like 'MYGIG_PHONE%', 'the admin requires the phone');
select pg_temp.rule('{"phoneRequired": false, "ways": {"sms": false}}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip(), '0100329099', 'Ben', 'sms'))
  like 'MYGIG_WAY%', 'a way the admin switched off');
select pg_temp.rule('{"ways": {"sms": true}}');

-- In the app: Aisha (latest app) on GET.wallet.
insert into t values ('o1', null, pg_temp.j('00000000-0000-0000-0000-0000000329d2',
  pg_temp.send_sql(pg_temp.trip('{"pay": "wallet"}'), '10 032 9011', null, 'app')));
update t set id = (v->>'offerId')::uuid where k = 'o1';
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000329a1'
                              and data->>'type' = 'mygig_offer' and data->>'offer_id' = pg_temp.id('o1')::text),
  'a push to their app');
select pg_temp.check(not exists (select 1 from public.ride_requests where mygig->>'offerId' = pg_temp.id('o1')::text),
  'nothing is a ride until accepted');
select pg_temp.check(jsonb_array_length(pg_temp.j('00000000-0000-0000-0000-0000000329a1', 'select public.mygig_my_offers()::text')) = 1
  and pg_temp.j('00000000-0000-0000-0000-0000000329a1', 'select public.mygig_my_offers()::text') -> 0 ->> 'phone' is null,
  'it waits in their app');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a2',
  format('select public.mygig_accept(%L)::text', pg_temp.id('o1'))) like 'MYGIG_NOT_FOUND%', 'nobody else accepts it');
insert into t values ('r1', null, pg_temp.j('00000000-0000-0000-0000-0000000329a1',
  format('select public.mygig_accept(%L)::text', pg_temp.id('o1'))));
update t set id = (v->>'rideId')::uuid where k = 'r1';
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000329d2'
                        and rider_id = '00000000-0000-0000-0000-0000000329a1' and payment_mode = 'Get Pay'
                        and mygig->>'way' = 'app' and mygig->>'via' = 'app'
                        and exists (select 1 from public.ride_request_private x where x.request_id = r.id and x.share_token is not null)
                        and partner_plate = 'VBC 7720'
                        and public.ride_amount_due(r) = (mygig #>> '{quote,total}')::numeric
                        and (mygig #>> '{terms,canCharge}')::boolean
                      from public.ride_requests r where id = pg_temp.id('r1')),
  'accepted in the app: a normal ride with the driver, at the agreed price');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a1',
  format('select public.mygig_accept(%L)::text', pg_temp.id('o1'))) like 'MYGIG_ENDED%', 'accepted once');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000329d2'
                              and data->>'type' = 'mygig_answer'), 'the driver is told');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329a1',
  format('select count(*) from public.ride_requests where id = %L', pg_temp.id('r1'))))::text = '1',
  'the passenger reads their ride');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a2',
  format('select count(*)::text from public.ride_requests where id = %L', pg_temp.id('r1'))) = '0',
  'nobody else does');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d2', 'select public.mygig_config(3.11, 101.66)::text')->>'code' = 'ACTIVE_TRIP',
  'no new myGiG while on a ride');

-- ---- 7. The ride ----------------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  format('update public.ride_requests set mygig = mygig || ''{"stopWaitMin": 99}'' where id = %L returning 1', pg_temp.id('r1')))
  like 'RIDE_SERVER_ONLY%', 'the terms are the server''s');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  format('update public.ride_requests set fare = 1 where id = %L returning 1', pg_temp.id('r1'))) similar to 'RIDE_(SERVER_ONLY|FARE_LOCKED)%',
  'so is the price');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  format('update public.ride_requests set status = ''on_trip'' where id = %L returning 1', pg_temp.id('r1'))) like 'RIDE_SERVER_ONLY%',
  'start goes through myGiG');
select pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_arrived(%L)::text', pg_temp.id('r1')));
select pg_temp.check((select status = 'arrived' and waiting_from is not null and (waiting_terms->>'freeMinutes')::numeric = 3
                        and (waiting_terms->>'perMinute')::numeric = 0.3 from pg_temp.ride('r1')),
  'I''ve arrived: the clock on get.ride''s waiting charge');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_no_show(%L)::text', pg_temp.id('r1')))
  like 'MYGIG_TOO_SOON%', 'no-show only after the free minutes');
update public.ride_requests set waiting_from = now() - interval '10 minutes', arrived_at = now() - interval '10 minutes'
 where id = pg_temp.id('r1');
select pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_start(%L)::text', pg_temp.id('r1')));
select pg_temp.check((select status = 'on_trip' and start_method = 'none' and waiting_minutes = 10 and waiting_charge = 2.1
                        from pg_temp.ride('r1')), 'started without a code; 7 minutes past the free 3 at RM0.30');
-- A stop: 4 minutes.
select pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_stop_wait(%L, true)::text', pg_temp.id('r1')));
update public.ride_requests set mygig = mygig || jsonb_build_object('stopWaitSince', now() - interval '4 minutes')
 where id = pg_temp.id('r1');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d2',
  format('select public.mygig_stop_wait(%L, false)::text', pg_temp.id('r1')))->>'stopWaitMin')::int = 4, 'minutes at a stop count');
-- Change destination: declined keeps the route, accepted takes the new one.
insert into t values ('c1', null, pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_reprice(%L, %L)::text',
  pg_temp.id('r1'), '{"drop": {"lat": 3.20, "lng": 101.75, "name": "Far 329"}, "km": 16, "min": 30}')));
update t set id = (v->>'id')::uuid where k = 'c1';
select pg_temp.check((select v->>'kind' = 'change' and v->>'way' = 'app' from t where k = 'c1'), 'back to the passenger the same way');
select pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_accept(%L, false)::text', pg_temp.id('c1')));
select pg_temp.check((select drop_name = 'Sentral 329' from pg_temp.ride('r1')), 'declined: the accepted route stays');
insert into t values ('c2', null, pg_temp.j('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_reprice(%L, %L)::text',
  pg_temp.id('r1'), '{"drop": {"lat": 3.20, "lng": 101.75, "name": "Far 329"}, "km": 16, "min": 30}')));
update t set id = (v->>'id')::uuid where k = 'c2';
select pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_accept(%L)::text', pg_temp.id('c2')));
-- 4 + 0.95 × 16 + 0.25 × 30 = 26.70.
select pg_temp.check((select drop_name = 'Far 329' and (mygig #>> '{quote,total}')::numeric = 26.7 and fare = 26.7
                        and jsonb_array_length(mygig->'changes') = 1 from pg_temp.ride('r1')), 'accepted: the new route and price');
-- Complete: 26.70 + 2.10 + 1.20 waiting = 30.00, tolls 3.
insert into t values ('done1', null, pg_temp.j('00000000-0000-0000-0000-0000000329d2',
  format('select public.mygig_complete(%L, 3, 0)::text', pg_temp.id('r1'))));
select pg_temp.check((select status = 'completed' and fare = 30 and toll_charges = 3 and public.ride_amount_due(r) = 33
                        and (mygig #>> '{final,waiting}')::numeric = 3.3 and payment_status = 'due'
                      from public.ride_requests r where id = pg_temp.id('r1')),
  'the price with the waiting, and the tolls');
select pg_temp.check((select (v->>'tripFee')::numeric = 0 from t where k = 'done1'), 'Lee pays no myGiG fee');
-- The passenger pays with GET.wallet in their app (ride_pay).
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329a1', 100);
select pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.ride_pay(%L, ''get_wallet'')::text', pg_temp.id('r1')));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000329a1') = 67, 'paid from GET.wallet');

-- On the trip link: an unregistered passenger, by SMS.
insert into t values ('o2', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip(), '0100329099', 'Ben Tamu', 'sms')));
update t set id = (v->>'offerId')::uuid where k = 'o2';
select pg_temp.check(exists (select 1 from public.sms_outbox where to_phone = '+60100329099' and channel = 'trip_share'
                              and body like '%getride.my/gig/%'), 'the SMS link is queued on the gateway');
select pg_temp.check((select v->>'link' like 'https://getride.my/gig/%' from t where k = 'o2'), 'the link');
insert into t values ('lv', null, pg_temp.j(null, format('select public.mygig_link_view(%L)::text', (select v->>'token' from t where k = 'o2'))));
select pg_temp.check((select v->>'status' = 'waiting' and v->>'name' = 'Ben' and v->'ride' = 'null'::jsonb
                        and v::text not like '%0100329099%' and v::text not like '%100329099%' from t where k = 'lv'),
  'the link page: the trip and price, no phone number');
select pg_temp.check(pg_temp.value_as(null, 'select public.mygig_link_view(''nope'')::text') like 'MYGIG_LINK%', 'a wrong token');
-- Resend: a new token; the old one no longer answers.
insert into t values ('rs', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_resend(%L)::text', pg_temp.id('o2'))));
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_link_answer(%L, true)::text', (select v->>'token' from t where k = 'o2')))
  like 'MYGIG_LINK%', 'resent: the old link is gone');
insert into t values ('r2', null, pg_temp.j(null, format('select public.mygig_link_answer(%L, true)::text', (select v->>'token' from t where k = 'rs'))));
update t set id = (v->>'rideId')::uuid where k = 'r2';
select pg_temp.check((select rider_id is null and rider_name = 'Ben Tamu' and mygig->>'via' = 'link'
                        and not (mygig #>> '{terms,canCharge}')::boolean and (mygig #>> '{terms,noShowFee}')::numeric = 0
                        and (mygig #>> '{terms,cancelFee}')::numeric = 0 from pg_temp.ride('r2')),
  'accepted on the link, no sign-in; no fee can apply');
select pg_temp.check((pg_temp.j(null, format('select public.mygig_link_view(%L)::text', (select v->>'token' from t where k = 'rs')))
  #>> '{ride,shareToken}') is not null, 'the link follows the ride');
-- A new route goes back to the passenger the same way: the first link shows and answers it.
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_reprice(%L, %L)::text',
  pg_temp.id('r2'), '{"stops": [{"lat": 3.12, "lng": 101.67, "name": "Stop 329"}], "km": 8, "min": 20}'));
select pg_temp.check((pg_temp.j(null, format('select public.mygig_link_view(%L)::text', (select v->>'token' from t where k = 'rs')))
  ->>'kind') = 'change', 'the first link shows the new price');
select pg_temp.j(null, format('select public.mygig_link_answer(%L, true)::text', (select v->>'token' from t where k = 'rs')));
select pg_temp.check((select jsonb_array_length(stops) = 1 and (mygig #>> '{quote,km}')::numeric = 8 from pg_temp.ride('r2')),
  'accepted on the link: the stop is on the ride');
-- 8. Cancel on the link: no fee (no account to charge).
update public.ride_requests set accepted_at = now() - interval '10 minutes' where id = pg_temp.id('r2');
select pg_temp.check((pg_temp.j(null, format('select public.mygig_cancel_ride(null, %L)::text', (select v->>'token' from t where k = 'rs')))
  ->>'fee')::numeric = 0 and (select status = 'cancelled' and cancel_fee_status = 'none' and coalesce(cancel_fee, 0) = 0
                                from pg_temp.ride('r2')), 'cancelled on the link: no fee');

-- On the driver's phone; and one that ends unanswered.
insert into t values ('o3', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', pg_temp.send_sql(pg_temp.trip(), null, null, 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o3';
update public.mygig_offers set expires_at = now() - interval '1 second' where id = pg_temp.id('o3');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o3')))
  like 'MYGIG_ENDED%' and (pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_offer_status(%L)::text', pg_temp.id('o3')))
  ->>'status') = 'expired', 'unanswered in time: it ends');
select pg_temp.check(not exists (select 1 from public.ride_requests where mygig->>'offerId' = pg_temp.id('o3')::text), 'nothing saved');
insert into t values ('o4', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', pg_temp.send_sql(pg_temp.trip(), null, null, 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o4';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', format('select public.mygig_offer_status(%L)::text', pg_temp.id('o4')))
  like 'MYGIG_NOT_FOUND%', 'another driver can''t read it');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', 'select count(*)::text from public.mygig_offers')
  like '%permission denied%', 'offers are read through the functions only');
insert into t values ('r4', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o4'))));
update t set id = (v->>'rideId')::uuid where k = 'r4';
select pg_temp.check((select mygig->>'via' = 'here' and payment_mode = 'Cash' and rider_id is null from pg_temp.ride('r4')),
  'accepted on the driver''s phone');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r4')));
insert into t values ('done4', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_complete(%L, 0, 2, ''Parking'')::text', pg_temp.id('r4'))));
select pg_temp.check((select (v->>'tripFee')::numeric = 1 from t where k = 'done4')
  and exists (select 1 from public.wallet_transactions where user_id = '00000000-0000-0000-0000-0000000329d1'
                and wallet_type = 'get_credit' and kind = 'mygig_fee' and amount = -1 and ride_id = pg_temp.id('r4')),
  'the per-trip fee from GET.credit');
-- Cash collected.
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select to_jsonb(public.ride_confirm_cash(%L))::text', pg_temp.id('r4')));
select pg_temp.check((select payment_status = 'paid' and paid_method = 'cash' and other_charges = 2 from pg_temp.ride('r4')),
  'cash received');
-- The daily limit.
select pg_temp.rule('{"dailyLimit": 1}');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_config(3.11, 101.66)::text')
  @> '{"code": "LIMIT", "today": 2, "limit": 1}', 'at the daily limit the button explains (two taken today)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', pg_temp.send_sql(pg_temp.trip(), null, null, 'here'))
  like 'MYGIG_LIMIT%', 'and the server stops it');
select pg_temp.rule('{"dailyLimit": 50}');

-- ---- 8. No-show and cancellation fees --------------------------------------------------------------------------
-- A registered passenger on GET.wallet: the no-show fee (Hafiz's RM5).
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329a1', 50);
insert into t values ('o5', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "wallet"}'), '10 032 9011', null, 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o5';
insert into t values ('r5', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o5'))));
update t set id = (v->>'rideId')::uuid where k = 'r5';
select pg_temp.check((select (mygig #>> '{terms,noShowFee}')::numeric = 5 and (mygig #>> '{terms,cancelFee}')::numeric = 10
                        from pg_temp.ride('r5')), 'the fees are the driver''s, within the admin''s most');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_arrived(%L)::text', pg_temp.id('r5')));
update public.ride_requests set arrived_at = now() - interval '6 minutes' where id = pg_temp.id('r5');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d1', 0);
insert into t values ('ns', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_no_show(%L)::text', pg_temp.id('r5'))));
select pg_temp.check((select v->>'feeStatus' = 'charged' from t where k = 'ns') and pg_temp.bal('00000000-0000-0000-0000-0000000329a1') = 45
  and pg_temp.bal('00000000-0000-0000-0000-0000000329d1') > 0
  and (select status = 'cancelled' and cancel_reason = 'passenger_no_show' and cancel_fee = 5 from pg_temp.ride('r5')),
  'no-show: RM5 from the passenger''s GET.wallet to the driver');
-- The same passenger paying cash: no fee.
insert into t values ('o6', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip(), '10 032 9011', null, 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o6';
insert into t values ('r6', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o6'))));
update t set id = (v->>'rideId')::uuid where k = 'r6';
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_arrived(%L)::text', pg_temp.id('r6')));
update public.ride_requests set arrived_at = now() - interval '6 minutes' where id = pg_temp.id('r6');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_no_show(%L)::text', pg_temp.id('r6')))
  ->>'fee')::numeric = 0 and pg_temp.bal('00000000-0000-0000-0000-0000000329a1') = 45, 'paying cash: no no-show fee');
-- Cancelled in the app after the free minutes: the cancellation fee (GET.wallet).
insert into t values ('o7', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "wallet"}'), '10 032 9011', null, 'app')));
update t set id = (v->>'offerId')::uuid where k = 'o7';
insert into t values ('r7', null, pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_accept(%L)::text', pg_temp.id('o7'))));
update t set id = (v->>'rideId')::uuid where k = 'r7';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a2', format('select public.mygig_cancel_ride(%L)::text', pg_temp.id('r7')))
  like 'MYGIG_NOT_FOUND%', 'only the passenger cancels');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a1',
  format('update public.ride_requests set status = ''cancelled'' where id = %L returning 1', pg_temp.id('r7'))) like 'RIDE_SERVER_ONLY%',
  'not around the agreed terms');
update public.ride_requests set accepted_at = now() - interval '5 minutes' where id = pg_temp.id('r7');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_cancel_ride(%L)::text', pg_temp.id('r7')))
  ->>'fee')::numeric = 10 and pg_temp.bal('00000000-0000-0000-0000-0000000329a1') = 35
  and (select cancel_fee_status = 'charged' and cancel_requested_by = 'rider' from pg_temp.ride('r7')),
  'cancelled after accepting, past the free minutes: the fee');
-- Within the free minutes: no fee.
insert into t values ('o8', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "wallet"}'), '10 032 9011', null, 'app')));
update t set id = (v->>'offerId')::uuid where k = 'o8';
insert into t values ('r8', null, pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_accept(%L)::text', pg_temp.id('o8'))));
update t set id = (v->>'rideId')::uuid where k = 'r8';
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_cancel_ride(%L)::text', pg_temp.id('r8')))
  ->>'fee')::numeric = 0 and pg_temp.bal('00000000-0000-0000-0000-0000000329a1') = 35, 'within the free minutes: no fee');

-- ---- 9. Collecting -------------------------------------------------------------------------------------------
-- ---- No losses to get.ride or the driver (owner's rule) -------------------------------------------------
-- A paid link on a ride (as the payments function settles one).
create or replace function pg_temp.link_pay(p_ride uuid, p_amount numeric, p_n int) returns void language plpgsql as $$
begin
  insert into public.payment_intents (id, user_id, purpose, purpose_ref, provider, amount)
  values (('00000000-0000-0000-0000-0000003290' || lpad(p_n::text, 2, '0'))::uuid, null, 'ride_card', p_ride::text, 'stripe', p_amount);
  perform public.payment_ride_card_paid(('00000000-0000-0000-0000-0000003290' || lpad(p_n::text, 2, '0'))::uuid, p_ride::text);
end $$;
-- 1. Pay by link: the agreed price is paid when they accept, before the trip.
insert into t values ('o9', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "link"}'), '0100329099', 'Ben Tamu', 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o9';
insert into t values ('r9', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o9'))));
update t set id = (v->>'rideId')::uuid where k = 'r9';
select pg_temp.check((select payment_mode = 'Pay by link' and public.mygig_owed(r) = (r.mygig #>> '{quote,total}')::numeric
                        from public.ride_requests r where r.id = pg_temp.id('r9')), 'pay by link: the agreed price is owed at once');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r9')))
  like 'MYGIG_PAY_FIRST%', 'no trip before it is paid');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  format('select public.payment_mygig_link_allowed(%L)::text', pg_temp.id('r9'))) in ('true', 'false'),
  'the driver may ask for its link (where a gateway is set)');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d1', 0);
select pg_temp.link_pay(pg_temp.id('r9'), (select public.mygig_owed(r) from pg_temp.ride('r9') r), 1);
select public.payment_ride_card_paid('00000000-0000-0000-0000-000000329001', pg_temp.id('r9')::text);
select pg_temp.check((select public.mygig_owed(r) = 0 from pg_temp.ride('r9') r)
  and pg_temp.bal('00000000-0000-0000-0000-0000000329d1') = (select (mygig #>> '{quote,total}')::numeric from pg_temp.ride('r9')),
  'paid by link, once, into the driver''s GET.wallet');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r9')));
-- What is added later is paid before the trip can end: Complete waits.
insert into t values ('c9', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_complete(%L, 2, 0)::text', pg_temp.id('r9'))));
select pg_temp.check((select (v->>'needsPayment')::boolean and (v->>'owed')::numeric = 2 from t where k = 'c9')
  and (select status = 'on_trip' from pg_temp.ride('r9')), 'the tolls first: Complete stays blocked');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_complete(%L)::text', pg_temp.id('r9')))
  ->>'needsPayment' = 'true', 'still blocked until it is paid');
select pg_temp.link_pay(pg_temp.id('r9'), 2, 2);
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_complete(%L)::text', pg_temp.id('r9')));
select pg_temp.check((select status = 'completed' and payment_status = 'paid' and paid_method = 'gateway' and toll_charges = 2
                        and public.ride_amount_due(r) = (r.mygig->>'linkPaid')::numeric from public.ride_requests r where r.id = pg_temp.id('r9')),
  'the second link paid: the trip ends, all of it paid');
-- Or the passenger pays the driver in cash instead (before, and what is added).
insert into t values ('o10', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "link"}'), '0100329099', 'Ben Tamu', 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o10';
insert into t values ('r10', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o10'))));
update t set id = (v->>'rideId')::uuid where k = 'r10';
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_take_cash(%L)::text', pg_temp.id('r10')));
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r10')));
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_complete(%L, 0, 3, ''Parking'')::text', pg_temp.id('r10')))->>'owed')::numeric = 3, 'parking owed');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_take_cash(%L)::text', pg_temp.id('r10')));
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_complete(%L)::text', pg_temp.id('r10')));
select pg_temp.check((select status = 'completed' and payment_status = 'paid' and paid_method = 'cash' and other_charges = 3
                        and (mygig->>'linkUnpaid')::boolean from pg_temp.ride('r10')),
  'didn''t pay by link: cash before the trip and for the parking');
-- The driver cancels a ride paid by link: all of it back to the passenger.
insert into t values ('o13', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "link"}'), '0100329099', 'Ben Tamu', 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o13';
insert into t values ('r13', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o13'))));
update t set id = (v->>'rideId')::uuid where k = 'r13';
select pg_temp.link_pay(pg_temp.id('r13'), (select public.mygig_owed(r) from pg_temp.ride('r13') r), 3);
select pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  format('update public.ride_requests set status = ''cancelled'', cancel_reason = ''driver_changed_mind'', cancelled_at = now() where id = %L returning 1', pg_temp.id('r13')));
select pg_temp.check((select status = 'cancelled' and (mygig->>'refundDue')::numeric = (mygig->>'linkPaid')::numeric from pg_temp.ride('r13'))
  and exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('r13') and kind = 'mygig_refund'
                and wallet_type = 'get_credit'), 'the driver cancels: refunded in full, from the driver''s side');
-- 2. Coming to the pickup elsewhere: paid with the link; the passenger who
-- walks away leaves it paid (the rest goes back).
insert into t values ('o14', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "link", "approachKm": 5}'), '0100329099', 'Ben Tamu', 'sms')));
update t set id = (v->>'offerId')::uuid where k = 'o14';
insert into t values ('r14', null, pg_temp.j(null, format('select public.mygig_link_answer(%L, true)::text', (select v->>'token' from t where k = 'o14'))));
update t set id = (v->>'rideId')::uuid where k = 'r14';
select pg_temp.check((select (mygig #>> '{quote,approach}')::numeric = 12 and public.mygig_owed(r) = (mygig #>> '{quote,total}')::numeric
                        from public.ride_requests r where r.id = pg_temp.id('r14')), 'coming to the pickup is in what is paid at acceptance');
select pg_temp.link_pay(pg_temp.id('r14'), (select public.mygig_owed(r) from pg_temp.ride('r14') r), 4);
select pg_temp.j(null, format('select public.mygig_cancel_ride(null, %L)::text', (select v->>'token' from t where k = 'o14')));
select pg_temp.check((select (mygig->>'kept')::numeric = 12 and (mygig->>'refundDue')::numeric = (mygig->>'linkPaid')::numeric - 12
                        and coalesce(cancel_fee, 0) = 0 from pg_temp.ride('r14')),
  'the passenger walks away: the driver keeps what they drove, no other fee');
-- A cash passenger pays for coming to the pickup at the pickup, before Start trip.
insert into t values ('o15', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"approachKm": 5}'), '0100329099', 'Ben Tamu', 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o15';
insert into t values ('r15', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o15'))));
update t set id = (v->>'rideId')::uuid where k = 'r15';
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r15')))
  like 'MYGIG_APPROACH_CASH%', 'cash: coming to the pickup is collected first');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_approach_cash(%L)::text', pg_temp.id('r15')));
-- 3. Cash: no start below the GET.credit minimum (the commission and the fee come off it).
insert into public.app_settings (key, value) values ('commission', '{"allowNegativeCredit": true, "negativeLimit": 10}')
on conflict (key) do update set value = public.app_settings.value || excluded.value;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d1', -20, 'get_credit');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r15')))
  like 'GET_CREDIT_TOO_LOW%', 'a cash myGiG doesn''t start below the GET.credit minimum');
select pg_temp.reset_state();
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d2', -20, 'get_credit');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip(), '0100329099', 'Ben Tamu', 'here'))
  like 'GET_CREDIT_TOO_LOW%', 'nor is one sent');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2', pg_temp.send_sql(pg_temp.trip('{"pay": "link"}'), '0100329099', 'Ben Tamu', 'here'))
  ~ '^\{', 'paid by link it can go (nothing is owed on GET.credit up front)');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d2', 0, 'get_credit');
update public.ride_requests set status = 'arrived', cancelled_at = null, cancel_fee_status = null where id = pg_temp.id('r15');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329d1', 50, 'get_credit');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r15')));
insert into t values ('c15', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_complete(%L)::text', pg_temp.id('r15'))));
select pg_temp.check((select commission_amount > 0 from pg_temp.ride('r15'))
  and exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('r15') and kind = 'mygig_fee' and wallet_type = 'get_credit')
  and (select (mygig->>'cashPaid')::numeric = 12 from pg_temp.ride('r15')),
  'cash: the commission and the myGiG fee off GET.credit; the pickup''s cash recorded');
-- 5. No setting makes get.ride or the driver absorb an unpaid amount.
select pg_temp.check(not exists (select 1 from jsonb_object_keys(public.mygig_defaults()) k
                                  where k ilike '%cover%' or k ilike '%absorb%' or k ilike '%writeoff%'),
  'no "get.ride covers" or "driver covers" setting');
select pg_temp.reset_state();

-- Family: Aisha is Farid's member; the host's GET.wallet pays, within her limits.
select pg_temp.check(exists (select 1 from public.booking_modules where key = 'mygig'), 'the mygig module is registered');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329f1',
  $q$select public.family_invite('{"country": "Gigland 329"}', '+60100329011', 'Aisha', 'sister')->>'id'$q$);
insert into t select 'm', id, null from public.family_members
 where family_id = (select id from public.families where host_id = '00000000-0000-0000-0000-0000000329f1');
select pg_temp.value_as('00000000-0000-0000-0000-0000000329a1',
  format('select public.family_respond(%L, true, ''{"shown": ["payments"]}'')', pg_temp.id('m')));
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text')->'family' = 'null'::jsonb,
  'Family is off for myGiG until the admin turns it on');
insert into public.family_module_rules (level, module_key, family_pays, book_for_member, child_allowed, live_share)
values ('default', 'mygig', true, false, false, true)
on conflict (place_key, module_key) do update set family_pays = true;
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9011'', 3.11, 101.66)::text') #>> '{family,host}' = 'Farid',
  'then the passenger''s Family is offered');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "family"}'), '10 032 9011', null, 'here')) like 'MYGIG_WAY%',
  'a Family ride is accepted in the member''s app');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329f1', 200);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000329a1', 0);
insert into t values ('o11', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "family"}'), '10 032 9011', null, 'app')));
update t set id = (v->>'offerId')::uuid where k = 'o11';
insert into t values ('r11', null, pg_temp.j('00000000-0000-0000-0000-0000000329a1', format('select public.mygig_accept(%L)::text', pg_temp.id('o11'))));
update t set id = (v->>'rideId')::uuid where k = 'r11';
select pg_temp.check((select module_key = 'mygig' and family_pays from public.family_trips where trip_id = pg_temp.id('r11')),
  'the ride is the family''s, module mygig (family_attach_trip on insert)');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r11')));
insert into t values ('done11', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  format('select public.mygig_complete(%L)::text', pg_temp.id('r11'))));
select pg_temp.check((select v->>'family' = 'paid' from t where k = 'done11')
  and (select payment_status = 'paid' from pg_temp.ride('r11'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000329f1') = 200 - (select paid_amount from pg_temp.ride('r11'))
  and pg_temp.bal('00000000-0000-0000-0000-0000000329a1') = 0, 'paid at once from the host''s GET.wallet');

-- Business: Ravi books on his company's account; its settlement pays the driver.
insert into public.business_accounts (id, name, reg_no, status) values
  ('00000000-0000-0000-0000-0000000329b9', 'Gig Corp 329', '202901032900', 'active');
insert into public.business_members (account_id, profile_id, phone, name, role, status) values
  ('00000000-0000-0000-0000-0000000329b9', '00000000-0000-0000-0000-0000000329a2', '+60100329012', 'Ravi', 'rider', 'active');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''10 032 9012'', 3.11, 101.66)::text') #>> '{businesses,0,name}' = 'Gig Corp 329',
  'the passenger''s business account is offered');
insert into t values ('o12', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip('{"pay": "business", "businessId": "00000000-0000-0000-0000-0000000329b9"}'), '10 032 9012', null, 'here')));
update t set id = (v->>'offerId')::uuid where k = 'o12';
insert into t values ('r12', null, pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_accept_here(%L)::text', pg_temp.id('o12'))));
update t set id = (v->>'rideId')::uuid where k = 'r12';
select pg_temp.check((select business_account_id is not null and payment_mode like 'Business:%' from pg_temp.ride('r12')),
  'a business ride');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_start(%L)::text', pg_temp.id('r12')));
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_complete(%L)::text', pg_temp.id('r12')));
select pg_temp.check((select payment_status = 'paid' and paid_method = 'business' from pg_temp.ride('r12')),
  'paid by the business account on its own');

-- ---- 10. Blocking and who reads what ----------------------------------------------------------------------------
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', format('select public.mygig_block(null, %L)::text', pg_temp.id('r10')));
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''0100329099'', 3.11, 101.66)::text')->>'state' = 'blocked', 'blocked');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  pg_temp.send_sql(pg_temp.trip(), '0100329099', 'Ben', 'here')) like 'MYGIG_BLOCKED_NUMBER%', 'can''t be sent');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d2',
  'select public.mygig_lookup_phone(''0100329099'', 3.11, 101.66)::text')->>'state' = 'none', 'only for the driver who blocked it');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d2',
  'select count(*)::text from public.mygig_blocked_numbers') = '0', 'nobody else reads the blocked list');
select pg_temp.j('00000000-0000-0000-0000-0000000329d1', 'select public.mygig_unblock(''0100329099'')::text');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''0100329099'', 3.11, 101.66)::text')->>'state' = 'none', 'unblocked');
-- A number with many rides this week is flagged.
select pg_temp.rule('{"repeatFlag": 3}');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000329d1',
  'select public.mygig_lookup_phone(''0100329099'', 3.11, 101.66)::text')->>'flagged')::boolean, 'flagged to the admin');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329a1',
  'insert into public.ride_requests (rider_id, status, payment_mode, mygig) values (''00000000-0000-0000-0000-0000000329a1'', ''open'', ''Cash'', ''{}'') returning 1')
  like 'RIDE_SERVER_ONLY%', 'the app can''t make a myGiG ride');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1', 'select count(*)::text from public.mygig_driver_access')
  = '0', 'drivers don''t read the access list');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  'update public.mygig_rules set settings = ''{}'' returning 1') in ('ok', '0') or pg_temp.value_as('00000000-0000-0000-0000-0000000329d1',
  'update public.mygig_rules set settings = ''{}'' returning 1') like '%denied%', 'drivers change no settings');
select pg_temp.check(public.mygig_settings_at('', '', '', '')->>'dailyLimit' is not null, 'the settings are still there');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  'delete from public.mygig_rules where level = ''default'' returning 1') like 'MYGIG_DEFAULT_STAYS%', 'the Default stays');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  'update public.mygig_rules set settings = settings || ''{"busy": {"nightFrom": "25:00"}}'' where level = ''default'' returning 1')
  like 'MYGIG_SETTINGS_INVALID%', 'a time of day is checked');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  'update public.mygig_rules set settings = settings || ''{"waiting": {"perMin": -1}}'' where level = ''default'' returning 1')
  like 'MYGIG_SETTINGS_INVALID%', 'no negative amounts');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000329e1',
  'update public.mygig_rules set settings = settings || ''{"guard": 2}'' where level = ''default'' returning 1') = '1',
  'an EDIT admin of the myGiG page changes a rule');
select pg_temp.check(public.mygig_version_ge('1.4.11', '1.4.6') and not public.mygig_version_ge('1.4.6', '1.4.11')
  and public.mygig_version_ge('v2.0', '1.9.9+3'), 'versions compare as numbers');
select pg_temp.check(public.mygig_phone_digits('012-345 6789') = '60123456789' and public.mygig_phone_digits('12 345 6789') = '60123456789'
  and public.mygig_phone_digits('+60 12 345 6789') = '60123456789', 'phone numbers as typed');

rollback;
