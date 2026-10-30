-- ============================================================================
-- Regression test for migration 0332: myGiG, part D (myGiG Delivery).
--   1. Settings: the delivery part and its checks; which vehicles may.
--   2. The driver's Delivery settings: own rates, waiting and return % kept
--      within the admin's limits; item types they don't take.
--   3. The price: get.ride's card by vehicle and km, size, weight over the
--      free kg, fragile, each extra drop-off, cover (fee, then a % above
--      the free amount), rounding up; the return fares and failed fees; the
--      deposit's parts.
--   4. What can be sent: sizes per vehicle, the vehicle's most kg, the
--      declared value, photos, the no-prohibited tick, the longest delivery;
--      the sender's and recipients' phones and names; the most drop-offs.
--   5. Every payment path: sender cash (with the deposit), by link, GET.wallet
--      (balance checked), recipient pays (guaranteed by the deposit or the
--      in-app sender); COD (registered senders only, cash blocked when
--      GET.credit can't cover it, by link); the accept tick.
--   6. Pickup, start, waiting (the deposit's allowance, the in-app sender),
--      the proof rules, refusing the item (nothing charged, refunds).
--   7. Returns: failed (fee once, from the deposit or the app) and asked
--      (recipient by link or cash with both confirmations; sender in the
--      app or by link); no start without payment, the payer's ack, a photo
--      and the sender's ack; the return code; support when nobody answers.
--   8. No losses: the driver is paid what was earned, nothing is owed by
--      anyone without in-app payment, deposits within their parts; the
--      ride can't be moved around the delivery functions; RLS.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mygig_delivery_0332.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000332d1'),  -- driver Hafiz (sedan: a car)
  ('00000000-0000-0000-0000-0000000332d2'),  -- driver Lee (motorcycle: a bike)
  ('00000000-0000-0000-0000-0000000332a1'),  -- sender Aisha: latest app
  ('00000000-0000-0000-0000-0000000332a2'),  -- recipient Ravi: latest app
  ('00000000-0000-0000-0000-0000000332e1')   -- admin
on conflict do nothing;
insert into public.profiles (id, name, phone, app_version, app_platform) values
  ('00000000-0000-0000-0000-0000000332d1', 'Hafiz Contoh', '+60100332001', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000332d2', 'Lee Sample', '+60100332002', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000332a1', 'Aisha Rahman', '+60100332011', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000332a2', 'Ravi Kumar', '+60100332012', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000332e1', 'Admin 332', '+60100332031', null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone,
  app_version = excluded.app_version, app_platform = excluded.app_platform;
insert into public.partners (auth_user_id, name, phone, status, partner_types, plate, vehicle, vehicle_type) values
  ('00000000-0000-0000-0000-0000000332d1', 'Hafiz Contoh', '+60100332001', 'approved', '{"Gig Car 332"}', 'WXY 2481', 'Perodua Bezza', 'Sedan'),
  ('00000000-0000-0000-0000-0000000332d2', 'Lee Sample', '+60100332002', 'approved', '{"Gig Car 332"}', 'WQA 3381', 'Honda Wave', 'Motorcycle');
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000332d1', true, 3.11, 101.66, now()),
  ('00000000-0000-0000-0000-0000000332d2', true, 3.11, 101.66, now())
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng, updated_at = now();
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000332e1', 'admin-mygig', 'edit');
insert into public.settings_entries (category, values, position, active) values
  ('partner-type', '{"name": "Gig Car 332", "vehicleRequired": true,
                     "rules": {"mygig": {"allowed": true, "all": true, "regions": []}}}', 9332, true),
  ('app-version-setting', '{"version": "9.0.0", "platform": "All"}', 9332, true);

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
-- [p_sql] as [p_user] (the app's role): its value as text, or the error and its hint.
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text; h text;
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
  get stacked diagnostics h = pg_exception_hint;
  perform pg_temp.as_server();
  return sqlerrm || coalesce(' | ' || nullif(h, ''), '');
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
    values (p_user, p_type, 'test_adjust', p_to - pg_temp.bal(p_user, p_type), 'test 0332');
  end if;
end $$;
create or replace function pg_temp.rule(p jsonb) returns void language sql as $$
  update public.mygig_rules set settings = public.mygig_merge(settings, p) where level = 'default';
$$;
create temp table t (k text primary key, id uuid, v jsonb);
grant all on t to authenticated, anon;
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create or replace function pg_temp.v(p_k text) returns jsonb language sql as $$ select v from t where k = p_k $$;
create or replace function pg_temp.dv(p_k text) returns public.mygig_deliveries language sql as $$
  select * from public.mygig_deliveries where ride_id = pg_temp.id(p_k) $$;

-- A delivery: Bangsar South (here) to Sentral, 6 km; [p] is merged in.
create or replace function pg_temp.dl(p jsonb default '{}') returns jsonb language sql as $$
  select public.mygig_merge(jsonb_build_object(
    'parcel', jsonb_build_object('type', 'Parcel', 'size', 'small', 'kg', 2, 'value', 0, 'fragile', false,
                                 'photos', jsonb_build_array('00000000-0000-0000-0000-0000000332d1/item-1.jpg'),
                                 'noProhibited', true),
    'pickup', jsonb_build_object('lat', 3.110, 'lng', 101.660, 'name', 'Bangsar South 332', 'here', true),
    'drops', jsonb_build_array(jsonb_build_object('lat', 3.134, 'lng', 101.686, 'name', 'Sentral 332',
                                                  'phone', '0100332088', 'recipient', 'Mei Ling')),
    'km', 6, 'min', 15,
    'sender', jsonb_build_object('phone', '0100332099', 'name', 'Ben Tamu'),
    'payer', 'sender', 'pay', 'cash', 'retPayer', 'recipient', 'way', 'here'), p);
$$;
create or replace function pg_temp.create_sql(p jsonb) returns text language sql as $$
  select format('select public.mygig_delivery_create(%L, 3.11, 101.66)::text', p);
$$;
-- Sends [p] as driver Hafiz and accepts it on his phone (the sender's tick); [k] keeps the ride.
create or replace function pg_temp.send_accept(p_k text, p jsonb, p_driver uuid default '00000000-0000-0000-0000-0000000332d1')
returns jsonb language plpgsql as $$
declare
  o jsonb := pg_temp.j(p_driver, pg_temp.create_sql(p));
  a jsonb;
begin
  a := pg_temp.j(p_driver, format('select public.mygig_delivery_answer(%L, null, true, true)::text', o->>'offerId'));
  insert into t values (p_k, (a->>'rideId')::uuid, a || jsonb_build_object('offer', o))
  on conflict (k) do update set id = excluded.id, v = excluded.v;
  return a;
end $$;
create or replace function pg_temp.drv(p_k text, p_sql text, p_driver uuid default '00000000-0000-0000-0000-0000000332d1')
returns jsonb language sql as $$
  select pg_temp.j(p_driver, format(p_sql, pg_temp.id(p_k)));
$$;
create or replace function pg_temp.drv_err(p_k text, p_sql text, p_driver uuid default '00000000-0000-0000-0000-0000000332d1')
returns text language sql as $$
  select pg_temp.value_as(p_driver, format(p_sql, pg_temp.id(p_k)));
$$;
-- A paid link part (as the payments function settles one).
create or replace function pg_temp.link_pay(p_part uuid, p_n int) returns void language plpgsql as $$
begin
  insert into public.payment_intents (id, user_id, purpose, purpose_ref, provider, amount)
  values (('00000000-0000-0000-0000-0000003320' || lpad(p_n::text, 2, '0'))::uuid, null, 'ride_card', p_part::text, 'stripe',
          (select amount from public.mygig_pay_parts where id = p_part));
  perform public.payment_ride_card_paid(('00000000-0000-0000-0000-0000003320' || lpad(p_n::text, 2, '0'))::uuid, p_part::text);
end $$;
create or replace function pg_temp.part(p_k text, p_purpose text) returns uuid language sql as $$
  select p.id from public.mygig_pay_parts p join public.mygig_deliveries d on d.id = p.delivery_id
   where d.ride_id = pg_temp.id(p_k) and p.purpose = p_purpose and p.cancelled_at is null order by p.created_at desc limit 1;
$$;
-- The pickup check done (a photo, matches, sealed).
create or replace function pg_temp.pickup_ok(p_k text) returns void language sql as $$
  select pg_temp.drv(p_k, 'select public.mygig_delivery_pickup(%L, ''["00000000-0000-0000-0000-0000000332d1/pick-1.jpg"]'', true, true)::text');
$$;
create or replace function pg_temp.code(p_k text, p_n int) returns text language sql as $$
  select x.code from public.mygig_delivery_drops x join public.mygig_deliveries d on d.id = x.delivery_id
   where d.ride_id = pg_temp.id(p_k) and x.n = p_n;
$$;
-- Ends anything left going (so the driver is free).
create or replace function pg_temp.reset_state() returns void language plpgsql as $$
begin
  perform pg_temp.as_server();
  perform set_config('getride.mygig_delivery', '1', true);
  update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_fee_status = 'none'
   where partner_id in ('00000000-0000-0000-0000-0000000332d1', '00000000-0000-0000-0000-0000000332d2')
     and status in ('accepted', 'arrived', 'on_trip');
  perform set_config('getride.mygig_delivery', '', true);
end $$;

select pg_temp.rule('{"dailyLimit": 50}');
select public.set_mygig_global('{"who": "all", "fee": {"mode": "none"}}');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 100, 'get_credit');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0, 'get_wallet');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d2', 100, 'get_credit');

-- ---- 1. Settings ------------------------------------------------------------------------------------------
select pg_temp.check((select settings ? 'delivery' from public.mygig_rules where level = 'default'),
  'the Default rule shows the delivery part');
select pg_temp.check(public.mygig_settings_problem('{"delivery": {"proof": "fingerprint"}}') like 'Proof of delivery%'
  and public.mygig_settings_problem('{"delivery": {"senderPhone": "maybe"}}') like 'The sender%'
  and public.mygig_settings_problem('{"delivery": {"maxDrops": 9}}') like 'A delivery has 1 to 5%'
  and public.mygig_settings_problem('{"delivery": {"returnPctMax": 150}}') like 'Percentages%'
  and public.mygig_settings_problem('{"delivery": {"itemTypes": []}}') like 'Keep at least one%'
  and public.mygig_settings_problem('{"delivery": {"ownLimits": {"perKmMin": 5, "perKmMax": 3}}}') like 'The lowest own%'
  and public.mygig_settings_problem(public.mygig_defaults()) is null, 'the delivery part is checked as it is saved');
select pg_temp.check(public.mygig_delivery_class('00000000-0000-0000-0000-0000000332d1') = 'car'
  and public.mygig_delivery_class('00000000-0000-0000-0000-0000000332d2') = 'bike', 'a sedan is a car, a motorcycle a bike');
insert into t values ('cfg', null, pg_temp.j('00000000-0000-0000-0000-0000000332d1', 'select public.mygig_delivery_config(3.11, 101.66)::text'));
select pg_temp.check(pg_temp.v('cfg') @> '{"ok": true, "offered": true, "vehicle": "car", "gcard": {"base": 6, "perKm": 1, "min": 9}}',
  'deliveries are offered to a car with get.ride''s car rates');
select pg_temp.rule('{"delivery": {"vehicles": {"bike": {"on": false}}}}');
select pg_temp.check(not (pg_temp.j('00000000-0000-0000-0000-0000000332d2', 'select public.mygig_delivery_config(3.11, 101.66)::text')->>'offered')::boolean,
  'the admin switches deliveries off for bikes');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d2', pg_temp.create_sql(pg_temp.dl())) like 'MYGIG_DELIVERY_OFF%',
  'and the server refuses a bike''s delivery');
select pg_temp.rule('{"delivery": {"vehicles": {"bike": {"on": true}}}}');

-- ---- 2. The driver's Delivery settings ---------------------------------------------------------------------
insert into t values ('pr', null, pg_temp.j('00000000-0000-0000-0000-0000000332d1',
  'select public.mygig_delivery_save_prefs(''{"own": true, "rates": {"base": 99, "perKm": 0.1, "min": 8, "medium": 99, "freeKg": 3},
     "waitOwn": true, "waitPerMin": 5, "waitFree": 2, "returnPct": 150, "offTypes": ["Food", "Nonsense"], "maxKm": 40}'', 3.11, 101.66)::text'));
select pg_temp.check(pg_temp.v('pr') @> '{"own": true, "rates": {"base": 20, "perKm": 0.5, "min": 8, "medium": 30, "freeKg": 3},
     "waitOwn": true, "waitPerMin": 1, "waitFree": 2, "returnPct": 100, "offTypes": ["Food"], "maxKm": 40}',
  'own rates, waiting and the return % within the admin''s limits; only known item types');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1',
  pg_temp.create_sql(pg_temp.dl('{"parcel": {"type": "Food"}}'))) like 'MYGIG_DELIVERY_TYPE%', 'an item type the driver doesn''t take');
-- Own card: 20 + 0.5 × 6 = 23.
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000332d1',
  format('select public.mygig_delivery_quote(%L, 3.11, 101.66)::text', pg_temp.dl()))->>'fare')::numeric = 23,
  'the driver''s own rates price it');
select pg_temp.rule('{"delivery": {"allowOwnRates": false, "allowOwnWait": false}}');
insert into t values ('qg', null, pg_temp.j('00000000-0000-0000-0000-0000000332d1',
  format('select public.mygig_delivery_quote(%L, 3.11, 101.66)::text', pg_temp.dl())));
select pg_temp.check(pg_temp.v('qg') @> '{"fare": 12, "own": false, "wait": {"freeMin": 5, "perMin": 0.3, "own": false}}',
  'own rates and waiting switched off by the admin: get.ride''s (6 + 1 × 6)');
select pg_temp.rule('{"delivery": {"allowOwnRates": true, "allowOwnWait": true}}');
select pg_temp.j('00000000-0000-0000-0000-0000000332d1', 'select public.mygig_delivery_save_prefs(''{"returnPct": 50}'', 3.11, 101.66)::text');

-- ---- 3. The price -------------------------------------------------------------------------------------------
-- Medium +2, 7 kg (2 over 5 at 0.50) +1, fragile +3, a second drop-off +3, worth 500: cover 0.50 + 1 % of 200 = 2.50.
insert into t values ('q', null, pg_temp.j('00000000-0000-0000-0000-0000000332d1', format('select public.mygig_delivery_quote(%L, 3.11, 101.66)::text',
  pg_temp.dl('{"parcel": {"size": "medium", "kg": 7, "value": 500, "fragile": true},
              "drops": [{"lat": 3.120, "lng": 101.670, "name": "Mid 332", "phone": "0100332088", "recipient": "Mei Ling"},
                        {"lat": 3.134, "lng": 101.686, "name": "Sentral 332", "phone": "0100332077", "recipient": "Kumar"}]}'))));
select pg_temp.check(pg_temp.v('q') @> '{"fare": 12, "size": 2, "kg": 1, "fragile": 3, "extraDrops": 3, "cover": 2.5, "sub": 23.5,
                                         "tax": 0, "total": 23.5, "drops": 2, "retPct": 50}', 'every line of the price');
select pg_temp.check(jsonb_array_length(pg_temp.v('q')->'returns') = 2
  and (select bool_and((r->>'failFee')::numeric = round((r->>'fare')::numeric * 0.5, 2) and (r->>'fare')::numeric >= 9)
         from jsonb_array_elements(pg_temp.v('q')->'returns') r)
  and (pg_temp.v('q')->>'maxFail')::numeric = (select max((r->>'failFee')::numeric) from jsonb_array_elements(pg_temp.v('q')->'returns') r),
  'each drop-off''s return fare (at least the minimum) and failed fee (50 %)');
select pg_temp.check(pg_temp.v('q')->'deposit' @> jsonb_build_object('ret', pg_temp.v('q')->'maxFail', 'wait', 4.5, 'fare', 0, 'fee', 0.5)
  and ((pg_temp.v('q') #>> '{deposit,total}')::numeric = (pg_temp.v('q')->>'maxFail')::numeric + 5),
  'a sender without the app: the deposit is the most a return costs + 15 min waiting + the 0.50 guarantee fee');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000332d1', format('select public.mygig_delivery_quote(%L, 3.11, 101.66)::text',
  pg_temp.dl('{"payer": "recipient"}')))#>>'{deposit,fare}')::numeric = 12.5, 'recipient pays: the deposit holds the fare (12 + the 0.50 cover) too');
select pg_temp.j('00000000-0000-0000-0000-0000000332d1', 'select public.mygig_delivery_save_prefs(''{"returnPct": 50, "roundUp": true}'', 3.11, 101.66)::text');
select pg_temp.check(pg_temp.j('00000000-0000-0000-0000-0000000332d1', format('select public.mygig_delivery_quote(%L, 3.11, 101.66)::text',
  pg_temp.dl('{"parcel": {"value": 400}}'))) @> '{"cover": 1.5, "exact": 13.5, "total": 14, "rounded": 0.5, "roundUp": true}',
  'rounded up to whole ringgit');
select pg_temp.j('00000000-0000-0000-0000-0000000332d1', 'select public.mygig_delivery_save_prefs(''{"returnPct": 50}'', 3.11, 101.66)::text');

-- ---- 4. What can be sent ----------------------------------------------------------------------------------
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d2', pg_temp.create_sql(pg_temp.dl(
  '{"parcel": {"size": "large", "photos": ["00000000-0000-0000-0000-0000000332d2/a.jpg"]}}'))) like '%can''t carry this size%',
  'a bike can''t take a large parcel (the admin''s sizes per vehicle)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d2', pg_temp.create_sql(pg_temp.dl(
  '{"parcel": {"kg": 11, "photos": ["00000000-0000-0000-0000-0000000332d2/a.jpg"]}}'))) like '%Too heavy for your motorbike (up to 10 kg)%',
  'the vehicle''s most kg');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"parcel": {"value": 2500}}')))
  like 'MYGIG_DELIVERY_VALUE%', 'the highest declared value');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"parcel": {"photos": []}}')))
  like 'MYGIG_DELIVERY_PHOTO%', 'a photo is required');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1',
  pg_temp.create_sql(pg_temp.dl('{"parcel": {"photos": ["00000000-0000-0000-0000-0000000332d2/not-mine.jpg"]}}')))
  like 'MYGIG_DELIVERY_PHOTO%', 'only photos from the driver''s own folder');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"parcel": {"noProhibited": false}}')))
  like 'MYGIG_DELIVERY_PROHIBITED%', 'the sender confirms there are no prohibited items');
select pg_temp.j('00000000-0000-0000-0000-0000000332d1', 'select public.mygig_delivery_save_prefs(''{"returnPct": 50, "maxKm": 5}'', 3.11, 101.66)::text');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl()))
  like 'MYGIG_TOO_FAR%Longer than your 5 km limit%', 'longer than the driver''s longest delivery');
select pg_temp.j('00000000-0000-0000-0000-0000000332d1', 'select public.mygig_delivery_save_prefs(''{"returnPct": 50}'', 3.11, 101.66)::text');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"sender": {"phone": ""}}')))
  like '%Enter the sender''s phone%', 'the sender''s phone is required (the admin''s default)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"sender": {"name": ""}}')))
  like 'MYGIG_NAME%', 'a sender who isn''t registered gives a name');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl(
  '{"drops": [{"lat": 3.134, "lng": 101.686, "name": "Sentral 332", "phone": "0100332088"}]}'))) like '%recipient''s name for drop-off%',
  'a recipient who isn''t registered gives a name');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl(
  '{"drops": [{"lat": 3.134, "lng": 101.686, "name": "Sentral 332"}]}'))) like '%recipient''s phone%', 'every recipient has a phone');
select pg_temp.rule('{"delivery": {"maxDrops": 1}}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl(
  '{"drops": [{"lat": 3.120, "lng": 101.670, "name": "A", "phone": "0100332088", "recipient": "Mei"},
              {"lat": 3.134, "lng": 101.686, "name": "B", "phone": "0100332077", "recipient": "Kumar"}]}'))) like '%Up to 1 drop-offs%',
  'the admin''s most drop-offs');
select pg_temp.rule('{"delivery": {"maxDrops": 4}}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"pay": "wallet"}')))
  like 'MYGIG_PAY%', 'GET.wallet needs a registered sender');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', pg_temp.create_sql(pg_temp.dl('{"cod": 50}')))
  like 'MYGIG_DELIVERY_COD_SENDER%', 'COD needs a registered sender (paid into their GET.wallet)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1',
  pg_temp.create_sql(pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "business", "payer": "recipient"}')))
  like 'MYGIG_PAY%', 'business needs the sender''s own business account');

-- ---- 5a. Sender cash, without the app: the deposit by link, cash at the pickup ----------------------------------
select pg_temp.send_accept('c1', pg_temp.dl());
select pg_temp.check((select status = 'arrived' and mygig->>'kind' = 'delivery' and payment_mode = 'Cash'
                         and (select bool_or(c->>'name' = 'Delivery cover' and (c->>'platform')::boolean) from jsonb_array_elements(charges) c)
                        from public.ride_requests where id = pg_temp.id('c1')),
  'accepted: a myGiG ride marked delivery, at the pickup, with the cover as a platform line');
select pg_temp.check((pg_temp.dv('c1')).deposit = (pg_temp.v('c1')->>'payNow')::numeric and (pg_temp.dv('c1')).deposit > 0
  and (select split @> jsonb_build_object('fare', 0, 'deposit', (pg_temp.dv('c1')).deposit)
         from public.mygig_pay_parts where id = (pg_temp.v('c1')->>'payRequest')::uuid),
  'the sender pays the deposit by link when accepting');
select pg_temp.pickup_ok('c1');
select pg_temp.check(pg_temp.drv_err('c1', 'select public.mygig_delivery_start(%L)::text') like 'MYGIG_PAY_FIRST%',
  'no start before the deposit is paid');
select pg_temp.link_pay(pg_temp.part('c1', 'accept'), 1);
select pg_temp.check(pg_temp.drv_err('c1', 'select public.mygig_delivery_start(%L)::text') like 'MYGIG_DELIVERY_CASH%',
  'nor before the sender''s cash');
select pg_temp.drv('c1', 'select public.mygig_delivery_sender_cash(%L)::text');
insert into t values ('c1s', null, pg_temp.drv('c1', 'select public.mygig_delivery_start(%L)::text'));
select pg_temp.check(pg_temp.v('c1s')->>'status' = 'delivering' and jsonb_array_length(pg_temp.v('c1s')->'recipients') = 1
  and pg_temp.v('c1s') #>> '{recipients,0,link}' like 'https://getride.my/gig/d/%'
  and exists (select 1 from public.sms_outbox where to_phone = '+60100332088' and body like '%getride.my/gig/d/%'),
  'started: the recipient is texted their tracking link');
update t set v = jsonb_build_object('token', split_part(pg_temp.v('c1s') #>> '{recipients,0,link}', '/gig/d/', 2)) where k = 'c1s';
-- The recipient's page has their code; the driver's doesn't.
insert into t values ('c1r', null, pg_temp.j(null, format('select public.mygig_delivery_link_view(%L)::text', pg_temp.v('c1s')->>'token')));
select pg_temp.check(pg_temp.v('c1r')->>'role' = 'recipient' and pg_temp.v('c1r') #>> '{delivery,drops,0,code}' = pg_temp.code('c1', 1)
  and pg_temp.v('c1r') #>> '{delivery,drops,0,phone}' is null and pg_temp.v('c1r') #> '{delivery,quote}' = 'null'::jsonb,
  'the recipient sees their delivery code, not the money or phones');
select pg_temp.check(pg_temp.drv('c1', 'select public.mygig_delivery_view(%L)::text') #>> '{drops,0,code}' is null,
  'the driver never sees the delivery code');
select pg_temp.check(pg_temp.drv_err('c1', 'select public.mygig_delivery_handover(%L, 1, ''1234'')::text') like 'MYGIG_STATE%',
  'arrive first');
select pg_temp.drv('c1', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.check(pg_temp.drv_err('c1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text',
  case when pg_temp.code('c1', 1) = '0000' then '1111' else '0000' end)) like 'MYGIG_DELIVERY_CODE%', 'a wrong code');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0);
insert into t values ('c1f', null, pg_temp.drv('c1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('c1', 1))));
select pg_temp.check((pg_temp.v('c1f')->>'finished')::boolean and (select status from public.ride_requests where id = pg_temp.id('c1')) = 'completed',
  'delivered with the code: the delivery ends');
select pg_temp.check((pg_temp.dv('c1')).earned = (pg_temp.dv('c1')).total and (pg_temp.dv('c1')).cash_driver = (pg_temp.dv('c1')).total
  and (pg_temp.dv('c1')).paid_out = 0 and (pg_temp.dv('c1')).refund_due = (pg_temp.dv('c1')).deposit - 0.5
  and pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = 0,
  'cash: the driver has the fare; the deposit is refunded but the 0.50 guarantee fee');
select pg_temp.check((select ride_amount_due(r) = (pg_temp.dv('c1')).total and fare = (pg_temp.dv('c1')).total - (pg_temp.dv('c1')).cover
                             and payment_status = 'paid' from public.ride_requests r where r.id = pg_temp.id('c1')),
  'the ride''s amount is the price (fare + the cover line)');
select pg_temp.check(exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('c1') and kind = 'platform_fee'
                               and amount = -(pg_temp.dv('c1')).cover)
  or (select platform_fees_charged_at is not null from public.ride_requests where id = pg_temp.id('c1')),
  'the cover fee comes back off GET.credit as a platform fee');

-- ---- 5b. Sender pays by link: the fare and the deposit first; get.ride holds it for the driver ---------------
select public.set_mygig_global('{"who": "all", "fee": {"mode": "trip", "amount": 1, "unit": "RM"}}');
select pg_temp.send_accept('l1', pg_temp.dl('{"pay": "link"}'));
select pg_temp.check((pg_temp.v('l1')->>'payNow')::numeric = (pg_temp.dv('l1')).total + (pg_temp.dv('l1')).deposit,
  'by link: the fare and the deposit together');
select pg_temp.check(public.payment_mygig_link_by_token(pg_temp.v('l1') #>> '{offer,token}', pg_temp.part('l1', 'accept'))
  = (public.payment_gateway_for('ride_card') is not null)
  and pg_temp.value_as('00000000-0000-0000-0000-0000000332a2', format('select public.payment_mygig_link_allowed(%L)::text',
  pg_temp.part('l1', 'accept'))) = 'false', 'the sender''s link may ask for it; a stranger may not');
select pg_temp.check(public.mygig_delivery_token_may_pay(public.mygig_token_hash(pg_temp.v('l1') #>> '{offer,token}'),
  (select p from public.mygig_pay_parts p where p.id = pg_temp.part('l1', 'accept')))
  and not public.mygig_delivery_token_may_pay(public.mygig_token_hash('nonsense'),
  (select p from public.mygig_pay_parts p where p.id = pg_temp.part('l1', 'accept'))), 'only the sender''s token pays the accept part');
select pg_temp.link_pay(pg_temp.part('l1', 'accept'), 2);
select pg_temp.check((pg_temp.dv('l1')).held = (pg_temp.dv('l1')).total and (pg_temp.dv('l1')).fare_paid_by = 'sender_link'
  and (pg_temp.dv('l1')).deposit_paid = (pg_temp.dv('l1')).deposit and pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = 0,
  'paid: get.ride holds the fare and the deposit');
select public.payment_ride_card_paid('00000000-0000-0000-0000-000000332002',
  (select id::text from public.mygig_pay_parts where delivery_id = (pg_temp.dv('l1')).id and purpose = 'accept'));
select pg_temp.check((pg_temp.dv('l1')).held = (pg_temp.dv('l1')).total, 'a payment is applied once');
select pg_temp.pickup_ok('l1');
select pg_temp.drv('l1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('l1', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 100, 'get_credit');
select pg_temp.drv('l1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('l1', 1)));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = (pg_temp.dv('l1')).total
  and (pg_temp.dv('l1')).paid_out = (pg_temp.dv('l1')).total
  and (pg_temp.dv('l1')).refund_due = (pg_temp.dv('l1')).deposit - 0.5
  and exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('l1') and kind = 'mygig_fee' and amount = -1),
  'the driver is paid what get.ride held; the myGiG fee off GET.credit; the deposit refunded less the fee');
select public.set_mygig_global('{"who": "all", "fee": {"mode": "none"}}');

-- ---- 5c. GET.wallet (a registered sender in the app): no deposit; charged at the end -------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332a1', 5);
insert into t values ('w0', null, pg_temp.j('00000000-0000-0000-0000-0000000332d1',
  pg_temp.create_sql(pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "wallet", "way": "app"}'))));
select pg_temp.check((pg_temp.v('w0') #> '{quote,deposit}') = 'null'::jsonb and pg_temp.v('w0') #>> '{delivery,inApp}' = 'true',
  'in the app: no deposit');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332a1',
  format('select public.mygig_accept(%L)::text', pg_temp.v('w0')->>'offerId')) like 'MYGIG_DELIVERY_ACK%',
  'the plain ride answer doesn''t accept a delivery (the tick is needed)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332a1',
  format('select public.mygig_delivery_answer(%L, null, true, false)::text', pg_temp.v('w0')->>'offerId')) like 'MYGIG_DELIVERY_ACK%',
  'nor without the sender''s tick');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332a1',
  format('select public.mygig_delivery_answer(%L, null, true, true)::text', pg_temp.v('w0')->>'offerId')) like 'MYGIG_WALLET_LOW%',
  'GET.wallet must hold the delivery and a possible return');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332a1', 100);
insert into t values ('w1', null, pg_temp.j('00000000-0000-0000-0000-0000000332a1',
  format('select public.mygig_delivery_answer(%L, null, true, true)::text', pg_temp.v('w0')->>'offerId')));
update t set id = (v->>'rideId')::uuid where k = 'w1';
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000332a1', format('select public.mygig_delivery_mine(%L)::text', pg_temp.id('w1')))
  ->>'role') = 'sender', 'the sender follows it in the app');
select pg_temp.pickup_ok('w1');
-- Waited 20 minutes at the pickup: 15 over the 5 free at 0.30 = 4.50, the in-app sender's.
update public.mygig_deliveries set pickup_arrived_at = now() - interval '20 minutes' where ride_id = pg_temp.id('w1');
select pg_temp.drv('w1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.check((pg_temp.dv('w1')).wait_in_app = 4.5 and (pg_temp.dv('w1')).fare_paid_by = 'sender_app',
  'waiting at the pickup is the in-app sender''s');
select pg_temp.drv('w1', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0);
select pg_temp.drv('w1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('w1', 1)));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000332a1') = 100 - (pg_temp.dv('w1')).total - 4.5
  and pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = (pg_temp.dv('w1')).total + 4.5
  and (pg_temp.dv('w1')).earned = (pg_temp.dv('w1')).total + 4.5 and (pg_temp.dv('w1')).in_app_short = 0,
  'the sender''s GET.wallet pays the fare and the waiting; the driver gets it all');

-- ---- 5d. Recipient pays, guaranteed by the deposit: paid in cash at the door; COD by link ----------------------
insert into t values ('cod0', null, pg_temp.j('00000000-0000-0000-0000-0000000332d1',
  pg_temp.create_sql(pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "cash", "payer": "recipient", "cod": 40, "way": "here"}'))));
select pg_temp.check((pg_temp.v('cod0') #>> '{quote,deposit,fare}')::numeric = (pg_temp.v('cod0')->>'total')::numeric
  and (pg_temp.v('cod0') #>> '{quote,codFee}')::numeric = 0.6,
  'recipient pays and the sender has no in-app payment: the deposit holds the fare; COD fee 1.5 %');
select pg_temp.j('00000000-0000-0000-0000-0000000332d1', format('select public.mygig_delivery_answer(%L, null, true, true)::text',
  pg_temp.v('cod0')->>'offerId'));
insert into t values ('r1', (select ride_id from public.mygig_offers where id = (pg_temp.v('cod0')->>'offerId')::uuid), null)
on conflict (k) do update set id = excluded.id;
select pg_temp.link_pay(pg_temp.part('r1', 'accept'), 3);
select pg_temp.pickup_ok('r1');
select pg_temp.drv('r1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('r1', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.check((pg_temp.drv('r1', 'select public.mygig_delivery_view(%L)::text') #> '{drops,0,due}')
  @> jsonb_build_object('fare', (pg_temp.dv('r1')).total, 'cod', 40, 'wait', 0),
  'at the door: the fare and the COD are due');
select pg_temp.check(pg_temp.drv_err('r1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('r1', 1)))
  like 'MYGIG_DELIVERY_UNPAID%', 'nothing handed over before it is paid');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 30, 'get_credit');
select pg_temp.check(pg_temp.drv_err('r1', 'select public.mygig_delivery_door_cash(%L, 1)::text') like 'MYGIG_COD_CREDIT%',
  'cash COD is blocked when GET.credit can''t cover it');
insert into t values ('r1d', null, pg_temp.drv('r1', 'select public.mygig_delivery_door_link(%L, 1)::text'));
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332a1', 0);
select pg_temp.link_pay((pg_temp.v('r1d')->>'requestId')::uuid, 4);
select pg_temp.check((pg_temp.dv('r1')).cod_status = 'link' and (pg_temp.dv('r1')).fare_paid_by = 'recipient_link'
  and pg_temp.bal('00000000-0000-0000-0000-0000000332a1') = 39.4,
  'paid by link at the door: the COD is in the sender''s GET.wallet less the fee');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0);
select pg_temp.drv('r1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('r1', 1)));
select pg_temp.check((pg_temp.dv('r1')).paid_out = (pg_temp.dv('r1')).total and (pg_temp.dv('r1')).deposit_used = 0
  and (pg_temp.dv('r1')).refund_due = (pg_temp.dv('r1')).deposit - 0.5,
  'the recipient paid: the whole deposit but the fee goes back');

-- Cash COD, with enough GET.credit: off the driver's GET.credit at once.
select pg_temp.send_accept('r2', pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "cash", "cod": 40}'));
select pg_temp.link_pay(pg_temp.part('r2', 'accept'), 5);
select pg_temp.pickup_ok('r2');
select pg_temp.drv('r2', 'select public.mygig_delivery_sender_cash(%L)::text');
select pg_temp.drv('r2', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('r2', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 100, 'get_credit');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332a1', 0);
select pg_temp.drv('r2', 'select public.mygig_delivery_door_cash(%L, 1)::text');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000332d1', 'get_credit') = 60
  and pg_temp.bal('00000000-0000-0000-0000-0000000332a1') = 39.4 and (pg_temp.dv('r2')).cod_status = 'cash',
  'cash COD: off GET.credit, into the sender''s GET.wallet less the fee');
select pg_temp.drv('r2', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('r2', 1)));

-- ---- 6. Waiting allowance, proof rules, refusing ------------------------------------------------------------
-- A recipient not there: 30 min, 25 over the free at 0.30 = 7.50, but the deposit allows 15 min (4.50).
select pg_temp.send_accept('a1', pg_temp.dl());
select pg_temp.link_pay(pg_temp.part('a1', 'accept'), 6);
select pg_temp.pickup_ok('a1');
select pg_temp.drv('a1', 'select public.mygig_delivery_sender_cash(%L)::text');
select pg_temp.drv('a1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('a1', 'select public.mygig_delivery_arrived(%L, 1)::text');
update public.mygig_delivery_drops set arrived_at = now() - interval '30 minutes'
 where delivery_id = (pg_temp.dv('a1')).id;
select pg_temp.check((pg_temp.drv('a1', 'select public.mygig_delivery_view(%L)::text') #>> '{drops,0,wait,charge}')::numeric = 7.5
  and (pg_temp.drv('a1', 'select public.mygig_delivery_view(%L)::text') #>> '{deposit,waitLeft}')::numeric = 4.5,
  'the waiting clock and what the deposit can still pay');
-- Proof: code or a photo with a name.
-- The admin changes the proof rule meanwhile: this delivery keeps the one agreed at the start (the code).
select pg_temp.rule('{"delivery": {"proof": "photo"}}');
insert into t values ('a1f', null, pg_temp.drv('a1', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('a1', 1))));
select pg_temp.rule('{"delivery": {"proof": "code"}}');
select pg_temp.check((pg_temp.dv('a1')).wait_deposit = 4.5 and (pg_temp.dv('a1')).wait_amount = 4.5
  and (pg_temp.dv('a1')).paid_out = 4.5 and (pg_temp.dv('a1')).refund_due = (pg_temp.dv('a1')).deposit - 4.5 - 0.5,
  'waiting is paid from the deposit, up to its allowance; never unpaid');
select pg_temp.rule('{"delivery": {"proof": "codeOrPhoto"}}');
select pg_temp.send_accept('p1', pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "wallet", "way": "here"}'));
select pg_temp.pickup_ok('p1');
select pg_temp.drv('p1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('p1', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.check(pg_temp.drv_err('p1', 'select public.mygig_delivery_handover(%L, 1, null, ''Guard Ali'')::text')
  like 'MYGIG_DELIVERY_PROOF%', 'someone else: a name and a photo');
select pg_temp.drv('p1', 'select public.mygig_delivery_handover(%L, 1, null, ''Guard Ali'', ''00000000-0000-0000-0000-0000000332d1/hand.jpg'')::text');
select pg_temp.check((select proof @> '{"kind": "photo", "name": "Guard Ali"}' from public.mygig_delivery_drops
                       where delivery_id = (pg_temp.dv('p1')).id), 'handed to a guard, with a photo');
select pg_temp.rule('{"delivery": {"proof": "photo"}}');
select pg_temp.send_accept('p2', pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "wallet", "way": "here"}'));
select pg_temp.pickup_ok('p2');
select pg_temp.drv('p2', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('p2', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.check(pg_temp.drv_err('p2', format('select public.mygig_delivery_handover(%%L, 1, %L)::text', pg_temp.code('p2', 1)))
  like 'MYGIG_DELIVERY_PROOF%', 'photo only: the code isn''t enough');
select pg_temp.drv('p2', 'select public.mygig_delivery_handover(%L, 1, null, null, ''00000000-0000-0000-0000-0000000332d1/h2.jpg'')::text');
select pg_temp.rule('{"delivery": {"proof": "code"}}');
-- The driver refuses the item: nothing charged; the link money back (refund_due) but the guarantee fee.
select pg_temp.send_accept('x1', pg_temp.dl('{"pay": "link"}'));
select pg_temp.link_pay(pg_temp.part('x1', 'accept'), 7);
insert into t values ('x1r', null, pg_temp.drv('x1', 'select public.mygig_delivery_refuse(%L, ''Looks like a prohibited item'')::text'));
select pg_temp.check((pg_temp.dv('x1')).status = 'refused' and (pg_temp.dv('x1')).refund_due = (pg_temp.dv('x1')).total + (pg_temp.dv('x1')).deposit - 0.5
  and (select status = 'cancelled' and cancel_fee = 0 from public.ride_requests where id = pg_temp.id('x1')),
  'refused at the pickup: nothing charged, everything paid by link goes back but the guarantee fee');

-- ---- 7. Returns -----------------------------------------------------------------------------------------------
-- Failed: nobody there at two drop-offs (sender without the app, deposit): the largest fee, once.
select pg_temp.send_accept('f1', pg_temp.dl('{"drops": [
  {"lat": 3.120, "lng": 101.670, "name": "Mid 332", "phone": "0100332088", "recipient": "Mei Ling"},
  {"lat": 3.134, "lng": 101.686, "name": "Sentral 332", "phone": "0100332077", "recipient": "Kumar"}]}'));
select pg_temp.link_pay(pg_temp.part('f1', 'accept'), 8);
select pg_temp.pickup_ok('f1');
select pg_temp.drv('f1', 'select public.mygig_delivery_sender_cash(%L)::text');
select pg_temp.drv('f1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('f1', 'select public.mygig_delivery_arrived(%L, 1)::text');
insert into t values ('f1a', null, pg_temp.drv('f1', 'select public.mygig_delivery_return_failed(%L, 1)::text'));
select pg_temp.check(pg_temp.v('f1a') #>> '{ask,link}' like 'https://getride.my/gig/d/%'
  and exists (select 1 from public.sms_outbox where to_phone = '+60100332099' and body like '%coming back%'),
  'the sender is asked to acknowledge (SMS link)');
update t set v = v || jsonb_build_object('token', split_part(pg_temp.v('f1a') #>> '{ask,link}', '/gig/d/', 2)) where k = 'f1a';
select pg_temp.check(pg_temp.drv_err('f1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('f1a')->>'returnId'))
  like 'MYGIG_DELIVERY_RETURN_CHECKS%', 'no return before the photo and the sender''s acknowledgement');
select pg_temp.drv('f1', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/back.jpg'')::text',
  pg_temp.v('f1a')->>'returnId'));
select pg_temp.check(pg_temp.drv_err('f1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('f1a')->>'returnId'))
  like '%sender hasn''t acknowledged%', 'still the sender''s acknowledgement');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_delivery_return_ack(null, %L, false)::text', pg_temp.v('f1a')->>'token'))
  like 'MYGIG_DELIVERY_ACK%', 'the sender ticks they''ll be there');
select pg_temp.check(pg_temp.j(null, format('select public.mygig_delivery_link_view(%L)::text', pg_temp.v('f1a')->>'token'))
  #>> '{delivery,returnCode}' = (pg_temp.dv('f1')).return_code, 'the sender''s page shows the return code');
select pg_temp.j(null, format('select public.mygig_delivery_return_ack(null, %L, true)::text', pg_temp.v('f1a')->>'token'));
select pg_temp.drv('f1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('f1a')->>'returnId'));
select pg_temp.drv('f1', 'select public.mygig_delivery_arrived(%L, 2)::text');
insert into t values ('f1b', null, pg_temp.drv('f1', 'select public.mygig_delivery_return_failed(%L, 2)::text'));
select pg_temp.drv('f1', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/back2.jpg'')::text',
  pg_temp.v('f1b')->>'returnId'));
select pg_temp.j(null, format('select public.mygig_delivery_return_ack(null, %L, true)::text',
  split_part(pg_temp.v('f1b') #>> '{ask,link}', '/gig/d/', 2)));
select pg_temp.drv('f1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('f1b')->>'returnId'));
select pg_temp.check(pg_temp.drv_err('f1', format('select public.mygig_delivery_return_done(%%L, %L, ''x'')::text', pg_temp.v('f1a')->>'returnId'))
  like 'MYGIG_DELIVERY_CODE%', 'finished only with the sender''s return code');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0);
select pg_temp.drv('f1', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('f1a')->>'returnId',
  (pg_temp.dv('f1')).return_code));
insert into t values ('f1d', null, pg_temp.drv('f1', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text',
  pg_temp.v('f1b')->>'returnId', (pg_temp.dv('f1')).return_code)));
select pg_temp.check((pg_temp.v('f1d')->>'finished')::boolean
  and (pg_temp.dv('f1')).fail_fee = greatest((select fail_fee from public.mygig_delivery_drops where delivery_id = (pg_temp.dv('f1')).id and n = 1),
                                             (select fail_fee from public.mygig_delivery_drops where delivery_id = (pg_temp.dv('f1')).id and n = 2))
  and (pg_temp.dv('f1')).deposit_used = (pg_temp.dv('f1')).fail_fee
  and pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = (pg_temp.dv('f1')).fail_fee
  and (pg_temp.dv('f1')).refund_due = (pg_temp.dv('f1')).deposit - (pg_temp.dv('f1')).fail_fee - 0.5,
  'one trip back: the largest failed fee once, from the deposit, to the driver; the rest refunded');
select pg_temp.check((select count(*) = 2 from jsonb_array_elements((pg_temp.dv('f1')).history) h where h->>'step' = 'return_sender_ack'),
  'every acknowledgement is in the history');

-- 7b. Asked: the recipient sends it back and pays by link (they were chosen at the start).
select pg_temp.send_accept('k1', pg_temp.dl());
select pg_temp.link_pay(pg_temp.part('k1', 'accept'), 9);
select pg_temp.pickup_ok('k1');
select pg_temp.drv('k1', 'select public.mygig_delivery_sender_cash(%L)::text');
insert into t values ('k1s', null, pg_temp.drv('k1', 'select public.mygig_delivery_start(%L)::text'));
update t set v = jsonb_build_object('token', split_part(pg_temp.v('k1s') #>> '{recipients,0,link}', '/gig/d/', 2)) where k = 'k1s';
select pg_temp.drv('k1', 'select public.mygig_delivery_arrived(%L, 1)::text');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_delivery_return_ask(%L, null, null, ''Damaged'', ''link'', false)::text',
  pg_temp.v('k1s')->>'token')) like 'MYGIG_DELIVERY_ACK%', 'the recipient ticks too');
insert into t values ('k1a', null, pg_temp.j(null, format('select public.mygig_delivery_return_ask(%L, null, null, ''Damaged'', ''link'', true)::text',
  pg_temp.v('k1s')->>'token')));
select pg_temp.check(pg_temp.v('k1a') @> '{"payer": "recipient", "method": "link"}' and pg_temp.v('k1a')->>'payRequest' is not null
  and (pg_temp.v('k1a')->>'amount')::numeric = (select return_fare from public.mygig_delivery_drops where delivery_id = (pg_temp.dv('k1')).id),
  'the full return fare, by link, from the recipient');
select pg_temp.drv('k1', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/k.jpg'')::text',
  pg_temp.v('k1a')->>'returnId'));
-- The sender acknowledges on their own delivery link.
select pg_temp.j(null, format('select public.mygig_delivery_return_ack(null, %L, true)::text', pg_temp.v('k1') #>> '{offer,token}'));
select pg_temp.check(pg_temp.drv_err('k1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k1a')->>'returnId'))
  like '%isn''t paid yet%', 'not before the recipient pays');
select pg_temp.check(public.mygig_delivery_token_may_pay(public.mygig_token_hash(pg_temp.v('k1s')->>'token'),
  (select p from public.mygig_pay_parts p where p.id = (pg_temp.v('k1a')->>'payRequest')::uuid)), 'the recipient''s link pays it');
select pg_temp.link_pay((pg_temp.v('k1a')->>'payRequest')::uuid, 10);
select pg_temp.drv('k1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k1a')->>'returnId'));
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0);
select pg_temp.drv('k1', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('k1a')->>'returnId',
  (pg_temp.dv('k1')).return_code));
select pg_temp.check((pg_temp.dv('k1')).status = 'done'
  and pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = (pg_temp.v('k1a')->>'amount')::numeric
  and (pg_temp.dv('k1')).earned = (pg_temp.dv('k1')).total + (pg_temp.v('k1a')->>'amount')::numeric,
  'the driver earns the fare (cash) and the return fare (paid by link)');

-- 7c. Asked, cash: counted only when both the driver and the recipient confirm.
select pg_temp.send_accept('k2', pg_temp.dl());
select pg_temp.link_pay(pg_temp.part('k2', 'accept'), 11);
select pg_temp.pickup_ok('k2');
select pg_temp.drv('k2', 'select public.mygig_delivery_sender_cash(%L)::text');
insert into t values ('k2s', null, pg_temp.drv('k2', 'select public.mygig_delivery_start(%L)::text'));
update t set v = jsonb_build_object('token', split_part(pg_temp.v('k2s') #>> '{recipients,0,link}', '/gig/d/', 2)) where k = 'k2s';
select pg_temp.drv('k2', 'select public.mygig_delivery_arrived(%L, 1)::text');
-- Asked at the door, before the hand-over, on the driver's phone.
insert into t values ('k2a', null, pg_temp.drv('k2', 'select public.mygig_delivery_return_ask(null, %L, 1, ''Wrong item'', ''cash'', true)::text'));
select pg_temp.drv('k2', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/k2.jpg'')::text',
  pg_temp.v('k2a')->>'returnId'));
select pg_temp.j(null, format('select public.mygig_delivery_return_ack(null, %L, true)::text', pg_temp.v('k2') #>> '{offer,token}'));
select pg_temp.drv('k2', format('select public.mygig_delivery_return_cash(%%L, %L)::text', pg_temp.v('k2a')->>'returnId'));
select pg_temp.check(pg_temp.drv_err('k2', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k2a')->>'returnId'))
  like '%isn''t paid yet%', 'the driver''s word alone isn''t enough');
select pg_temp.j(null, format('select public.mygig_delivery_return_cash_ack(%L)::text', pg_temp.v('k2s')->>'token'));
select pg_temp.drv('k2', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k2a')->>'returnId'));
select pg_temp.drv('k2', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('k2a')->>'returnId',
  (pg_temp.dv('k2')).return_code));
select pg_temp.check((pg_temp.dv('k2')).cash_driver = (pg_temp.dv('k2')).total + (pg_temp.v('k2a')->>'amount')::numeric
  and (pg_temp.dv('k2')).earned = (pg_temp.dv('k2')).cash_driver,
  'both confirmed: the return fare in cash is the driver''s');

-- 7d. Asked, the sender pays (chosen at the start): in the app when they acknowledge.
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332a1', 100);
select pg_temp.send_accept('k3', pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "wallet", "retPayer": "sender"}'));
select pg_temp.pickup_ok('k3');
select pg_temp.drv('k3', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('k3', 'select public.mygig_delivery_arrived(%L, 1)::text');
insert into t values ('k3a', null, pg_temp.drv('k3', 'select public.mygig_delivery_return_ask(null, %L, 1, ''Don''''t want it'', null, true)::text'));
select pg_temp.check(pg_temp.v('k3a') @> '{"payer": "sender", "method": "app"}', 'the sender pays in the app');
select pg_temp.drv('k3', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/k3.jpg'')::text',
  pg_temp.v('k3a')->>'returnId'));
select pg_temp.check(pg_temp.drv_err('k3', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k3a')->>'returnId'))
  like '%isn''t paid yet%', 'not before the sender pays');
select pg_temp.j('00000000-0000-0000-0000-0000000332a1', format('select public.mygig_delivery_return_ack(%L, null, true)::text', pg_temp.v('k3a')->>'returnId'));
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000332a1') = 100 - (pg_temp.v('k3a')->>'amount')::numeric,
  'charged when they acknowledge, before it leaves');
select pg_temp.drv('k3', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k3a')->>'returnId'));
select pg_temp.drv('k3', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('k3a')->>'returnId',
  (pg_temp.dv('k3')).return_code));
select pg_temp.check((pg_temp.dv('k3')).status = 'done' and (pg_temp.dv('k3')).in_app_short = 0
  and pg_temp.bal('00000000-0000-0000-0000-0000000332a1') = 100 - (pg_temp.v('k3a')->>'amount')::numeric - (pg_temp.dv('k3')).total,
  'and the delivery fare at the end');

-- 7e. Recipient pays, the in-app sender guarantees it: nobody there, so the sender pays the fare and the failed fee.
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332a1', 100);
select pg_temp.send_accept('g1', pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "wallet", "payer": "recipient"}'));
select pg_temp.pickup_ok('g1');
select pg_temp.drv('g1', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('g1', 'select public.mygig_delivery_arrived(%L, 1)::text');
insert into t values ('g1a', null, pg_temp.drv('g1', 'select public.mygig_delivery_return_failed(%L, 1, ''Refused at the door'')::text'));
select pg_temp.drv('g1', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/g.jpg'')::text',
  pg_temp.v('g1a')->>'returnId'));
-- Support: the sender doesn't answer in time.
update public.mygig_delivery_returns set answer_by = now() - interval '1 minute' where id = (pg_temp.v('g1a')->>'returnId')::uuid;
select pg_temp.check((pg_temp.drv('g1', 'select public.mygig_delivery_view(%L)::text') #>> '{returns,0,status}') = 'support',
  'no answer in time: support is told');
select pg_temp.check(pg_temp.drv_err('g1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('g1a')->>'returnId'))
  like '%support is deciding%', 'and decides; the driver waits');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1',
  format('select public.mygig_admin_delivery_decide(%L, ''Called the sender'')::text', pg_temp.v('g1a')->>'returnId')) like 'not_authorized%',
  'only an admin decides');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332e1',
  format('select public.mygig_admin_delivery_decide(%L, '''')::text', pg_temp.v('g1a')->>'returnId')) like 'MYGIG_NOTE%', 'with a note');
select pg_temp.j('00000000-0000-0000-0000-0000000332e1',
  format('select public.mygig_admin_delivery_decide(%L, ''Called the sender: bring it back'')::text', pg_temp.v('g1a')->>'returnId'));
select pg_temp.drv('g1', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('g1a')->>'returnId'));
select pg_temp.drv('g1', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('g1a')->>'returnId',
  (pg_temp.dv('g1')).return_code));
select pg_temp.check((pg_temp.dv('g1')).fare_paid_by = 'sender_app_guarantee'
  and pg_temp.bal('00000000-0000-0000-0000-0000000332a1') = 100 - (pg_temp.dv('g1')).total - (pg_temp.dv('g1')).fail_fee
  and (pg_temp.dv('g1')).fail_fee > 0,
  'the recipient didn''t pay: the in-app sender pays the fare and the failed-return fee');

-- 7f. Recipient pays, guaranteed by the deposit: nobody there, the deposit pays the fare and the fee.
select pg_temp.send_accept('g2', pg_temp.dl('{"payer": "recipient"}'));
select pg_temp.link_pay(pg_temp.part('g2', 'accept'), 12);
select pg_temp.pickup_ok('g2');
select pg_temp.drv('g2', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('g2', 'select public.mygig_delivery_arrived(%L, 1)::text');
insert into t values ('g2a', null, pg_temp.drv('g2', 'select public.mygig_delivery_return_failed(%L, 1)::text'));
select pg_temp.drv('g2', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/g2.jpg'')::text',
  pg_temp.v('g2a')->>'returnId'));
select pg_temp.j(null, format('select public.mygig_delivery_return_ack(null, %L, true)::text', pg_temp.v('g2') #>> '{offer,token}'));
select pg_temp.drv('g2', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('g2a')->>'returnId'));
select pg_temp.set_bal('00000000-0000-0000-0000-0000000332d1', 0);
select pg_temp.drv('g2', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('g2a')->>'returnId',
  (pg_temp.dv('g2')).return_code));
select pg_temp.check((pg_temp.dv('g2')).fare_paid_by = 'deposit'
  and (pg_temp.dv('g2')).deposit_used = (pg_temp.dv('g2')).total + (pg_temp.dv('g2')).fail_fee
  and pg_temp.bal('00000000-0000-0000-0000-0000000332d1') = (pg_temp.dv('g2')).total + (pg_temp.dv('g2')).fail_fee
  and (pg_temp.dv('g2')).refund_due = (pg_temp.dv('g2')).deposit - (pg_temp.dv('g2')).deposit_used - 0.5,
  'the deposit pays the driver the fare and the fee; the rest is refunded');

-- 7g. Asked, the sender pays without the app: by link when they acknowledge.
select pg_temp.send_accept('k4', pg_temp.dl('{"retPayer": "sender"}'));
select pg_temp.link_pay(pg_temp.part('k4', 'accept'), 13);
select pg_temp.pickup_ok('k4');
select pg_temp.drv('k4', 'select public.mygig_delivery_sender_cash(%L)::text');
select pg_temp.drv('k4', 'select public.mygig_delivery_start(%L)::text');
select pg_temp.drv('k4', 'select public.mygig_delivery_arrived(%L, 1)::text');
insert into t values ('k4a', null, pg_temp.drv('k4', 'select public.mygig_delivery_return_ask(null, %L, 1, ''Other'', null, true)::text'));
insert into t values ('k4k', null, pg_temp.j(null, format('select public.mygig_delivery_return_ack(null, %L, true)::text', pg_temp.v('k4') #>> '{offer,token}')));
select pg_temp.check(pg_temp.v('k4k')->>'payRequest' is not null and (pg_temp.v('k4k')->>'amount')::numeric = (pg_temp.v('k4a')->>'amount')::numeric
  and (pg_temp.j(null, format('select public.mygig_delivery_pay_request(%L, ''return'')::text', pg_temp.v('k4') #>> '{offer,token}'))->>'requestId')
      = pg_temp.v('k4k')->>'payRequest',
  'the sender pays the return by link from their page');
select pg_temp.drv('k4', format('select public.mygig_delivery_return_photo(%%L, %L, ''00000000-0000-0000-0000-0000000332d1/k4.jpg'')::text',
  pg_temp.v('k4a')->>'returnId'));
select pg_temp.check(pg_temp.drv_err('k4', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k4a')->>'returnId'))
  like '%isn''t paid yet%', 'acknowledged but not paid: no start');
select pg_temp.link_pay((pg_temp.v('k4k')->>'payRequest')::uuid, 14);
select pg_temp.drv('k4', format('select public.mygig_delivery_return_start(%%L, %L)::text', pg_temp.v('k4a')->>'returnId'));
select pg_temp.drv('k4', format('select public.mygig_delivery_return_done(%%L, %L, %L)::text', pg_temp.v('k4a')->>'returnId',
  (pg_temp.dv('k4')).return_code));

-- ---- 8. No losses, the ride's guard, RLS ----------------------------------------------------------------------
select pg_temp.check(not exists (
  select 1 from public.mygig_deliveries d
   where d.driver_id = '00000000-0000-0000-0000-0000000332d1' and d.status = 'done'
     and (d.earned <> round(d.cash_driver + d.paid_out, 2)
          or (not d.in_app and d.in_app_short > 0)
          or d.deposit_used > greatest(0, d.deposit_paid - d.guarantee_fee)
          or d.refund_due < 0)),
  'every delivery: the driver got all they earned (cash + paid out), nobody without the app owes anything, deposits within their parts');
select pg_temp.check(not exists (select 1 from public.mygig_deliveries d where d.status = 'done' and not d.in_app
                                   and d.fare_paid_by in ('sender_app', 'sender_app_guarantee')),
  'nothing is charged after the fact to a sender without in-app payment');
-- The ride can't move around the delivery functions.
select pg_temp.send_accept('z1', pg_temp.dl('{"sender": {"phone": "0100332011"}, "pay": "wallet"}'));
select pg_temp.check(pg_temp.drv_err('z1', 'select public.mygig_start(%L)::text') like 'MYGIG_DELIVERY%',
  'the ride''s Start refuses a delivery');
select pg_temp.check(pg_temp.drv_err('z1', 'select public.mygig_complete(%L)::text') like 'MYGIG_DELIVERY%',
  'and its Complete');
select pg_temp.check(pg_temp.drv_err('l1', 'select public.payment_mygig_link_allowed(%L)::text') = 'false'
  and not public.mygig_pays_first((select r from public.ride_requests r where r.id = pg_temp.id('l1'))),
  'no ride-level pay link for a delivery (it is paid on its own parts)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1',
  format('update public.ride_requests set status = ''cancelled'' where id = %L returning ''x''', pg_temp.id('z1'))) like 'MYGIG_DELIVERY%',
  'nor can the driver cancel it on the table');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_cancel_ride(null, %L)::text', pg_temp.v('z1') #>> '{offer,token}'))
  not like 'ok%' and (select status from public.ride_requests where id = pg_temp.id('z1')) <> 'cancelled',
  'nor the ride''s cancel by the link');
select pg_temp.j('00000000-0000-0000-0000-0000000332a1', format('select public.mygig_delivery_cancel(%L)::text', pg_temp.id('z1')));
select pg_temp.check((pg_temp.dv('z1')).status = 'cancelled' and pg_temp.bal('00000000-0000-0000-0000-0000000332a1') >= 0
  and (select status = 'cancelled' from public.ride_requests where id = pg_temp.id('z1')),
  'the sender cancels before the pickup, free');
-- RLS: the tables are read through the functions.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d1', 'select count(*)::text from public.mygig_deliveries')
  like '%permission denied%' and pg_temp.value_as('00000000-0000-0000-0000-0000000332d1',
  'select count(*)::text from public.mygig_delivery_drops') like '%permission denied%'
  and pg_temp.value_as(null, 'select count(*)::text from public.mygig_delivery_returns') like '%permission denied%',
  'the delivery tables aren''t read directly (codes and tokens stay on the server)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d2', format('select public.mygig_delivery_view(%L)::text', pg_temp.id('c1')))
  like 'MYGIG_NOT_FOUND%' and pg_temp.value_as('00000000-0000-0000-0000-0000000332a2',
  format('select public.mygig_delivery_mine(%L)::text', pg_temp.id('w1'))) like 'MYGIG_NOT_FOUND%',
  'another driver or a stranger sees nothing');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332d2', 'select count(*)::text from public.mygig_delivery_prefs') = '0',
  'a driver reads only their own Delivery settings');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000332a1', 'select public.mygig_admin_deliveries()::text') like 'not_authorized%'
  and (pg_temp.j('00000000-0000-0000-0000-0000000332e1', 'select public.mygig_admin_delivery_stats()::text')->>'deliveries')::int >= 10
  and jsonb_array_length(pg_temp.j('00000000-0000-0000-0000-0000000332e1', 'select public.mygig_admin_deliveries(''all'')::text')) >= 10,
  'the admin''s numbers and list (myGiG page only)');
select pg_temp.check(pg_temp.value_as(null, 'select public.mygig_delivery_link_view(''no-such-token'')::text') like 'MYGIG_LINK%',
  'an unknown link shows nothing');

select pg_temp.reset_state();
rollback;
