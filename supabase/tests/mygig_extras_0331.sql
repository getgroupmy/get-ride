-- ============================================================================
-- Regression test for migration 0331: myGiG, part C.
--   1. Settings: reassign, hotspots, after-trip and driver extras, and their checks.
--   2. Reassign eligibility: no myGiG access, smaller vehicle, too small for
--      the passengers, the admin's same-or-bigger rule.
--   3. A ride paid by link reassigned before pickup: the new driver's tick is
--      required, the passenger confirms on the link with their own tick,
--      nothing changes before that; the link's money moves, the first driver
--      keeps coming to the pickup; a later cancel refunds from each driver
--      what they hold; every step in the history.
--   4. The passenger keeps the first driver (app); cancels with no charge (on
--      the driver's phone); the new driver declines.
--   5. No answer: the new driver's runs out; the passenger's follows the
--      admin's rule (keep, cancel).
--   6. During the trip: only when the admin allows it; 0199's swap.
--   7. A booking reassigned (Scheduled myGiG): it and its cash follow.
--   8. Hotspots: counts per area, under the minimum hidden, no passenger data.
--   9. Quick trips and regulars.
--  10. After the trip: rating, tips (link, cash, app), split, e-Invoice
--      request kept for the admin, book again, the app offer, pay parts.
--  11. The admin dashboard: tiles, flags, reassigns, bookings, e-Invoices.
--  12. Part B follow-up: a late cancel of an in-app later trip takes the fee.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mygig_extras_0331.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000331d1'),  -- driver Hafiz (sedan)
  ('00000000-0000-0000-0000-0000000331d2'),  -- driver Lee (MPV)
  ('00000000-0000-0000-0000-0000000331d3'),  -- driver Tan (hatchback)
  ('00000000-0000-0000-0000-0000000331d4'),  -- driver Wong (TEKSI only: no myGiG)
  ('00000000-0000-0000-0000-0000000331a1'),  -- passenger Aisha: latest app
  ('00000000-0000-0000-0000-0000000331e1')   -- admin
on conflict do nothing;
insert into public.profiles (id, name, phone, app_version, app_platform) values
  ('00000000-0000-0000-0000-0000000331d1', 'Hafiz Contoh', '+60100331001', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000331d2', 'Lee Sample', '+60100331002', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000331d3', 'Tan Sample', '+60100331003', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000331d4', 'Wong Sample', '+60100331004', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000331a1', 'Aisha Rahman', '+60100331011', '99.0.0', 'android'),
  ('00000000-0000-0000-0000-0000000331e1', 'Admin 331', '+60100331031', null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone,
  app_version = excluded.app_version, app_platform = excluded.app_platform;
insert into public.partners (auth_user_id, name, phone, status, partner_types, plate, vehicle, vehicle_type) values
  ('00000000-0000-0000-0000-0000000331d1', 'Hafiz Contoh', '+60100331001', 'approved', '{"Gig Car 331"}', 'WXY 2481', 'Perodua Bezza', 'Sedan'),
  ('00000000-0000-0000-0000-0000000331d2', 'Lee Sample', '+60100331002', 'approved', '{"Gig Car 331"}', 'VBC 7720', 'Toyota Innova', 'MPV'),
  ('00000000-0000-0000-0000-0000000331d3', 'Tan Sample', '+60100331003', 'approved', '{"Gig Car 331"}', 'WRT 1189', 'Perodua Axia', 'Hatchback'),
  ('00000000-0000-0000-0000-0000000331d4', 'Wong Sample', '+60100331004', 'approved', '{TEKSI}', 'WTT 4410', 'Proton Saga', 'Sedan');
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000331d1', true, 3.11, 101.66, now()),
  ('00000000-0000-0000-0000-0000000331d2', true, 3.112, 101.662, now()),
  ('00000000-0000-0000-0000-0000000331d3', true, 3.113, 101.661, now()),
  ('00000000-0000-0000-0000-0000000331d4', true, 3.114, 101.663, now())
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng, updated_at = now();
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000331e1', 'admin-mygig', 'edit');
insert into public.settings_entries (category, values, position, active) values
  ('partner-type', '{"name": "Gig Car 331", "vehicleRequired": true,
                     "rules": {"mygig": {"allowed": true, "all": true, "regions": []}}}', 9331, true),
  ('app-version-setting', '{"version": "9.0.0", "platform": "All"}', 9331, true);

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
    values (p_user, p_type, 'test_adjust', p_to - pg_temp.bal(p_user, p_type), 'test 0331');
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
create or replace function pg_temp.ra(p_k text) returns public.mygig_reassigns language sql as $$
  select * from public.mygig_reassigns where id = pg_temp.id(p_k) $$;
create or replace function pg_temp.trip(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object(
    'pickup', jsonb_build_object('lat', 3.110, 'lng', 101.660, 'name', 'Bangsar South 331', 'here', false),
    'drop', jsonb_build_object('lat', 3.134, 'lng', 101.686, 'name', 'Sentral 331', 'address', 'Jalan Sentral 331'),
    'stops', '[]'::jsonb, 'km', 6, 'min', 15, 'pax', 1, 'bags', jsonb_build_object('small', 0, 'medium', 0, 'large', 0),
    'pay', 'cash') || p_extra;
$$;
create or replace function pg_temp.send_sql(p_trip jsonb, p_phone text, p_name text, p_way text, p_booking jsonb default null)
returns text language sql as $$
  select format('select public.mygig_create(%L, 3.11, 101.66)::text',
                jsonb_build_object('trip', p_trip, 'phone', p_phone, 'name', p_name, 'way', p_way, 'booking', p_booking));
$$;
-- Hafiz sends [p_trip]; the passenger accepts as [p_way] says; the ride's id is kept as [p_k].
create or replace function pg_temp.ride_now(p_k text, p_trip jsonb, p_phone text, p_name text, p_way text,
                                            p_driver uuid default '00000000-0000-0000-0000-0000000331d1')
returns void language plpgsql as $$
declare
  o jsonb := pg_temp.j(p_driver, pg_temp.send_sql(p_trip, p_phone, p_name, p_way));
  a jsonb;
begin
  if p_way = 'app' then
    a := pg_temp.j('00000000-0000-0000-0000-0000000331a1', format('select public.mygig_accept(%L)::text', o->>'offerId'));
  elsif p_way in ('sms', 'whatsapp') then
    a := pg_temp.j(null, format('select public.mygig_link_answer(%L, true)::text', o->>'token'));
  else
    a := pg_temp.j(p_driver, format('select public.mygig_accept_here(%L)::text', o->>'offerId'));
  end if;
  insert into t values (p_k, (a->>'rideId')::uuid, o || jsonb_build_object('accept', a));
end $$;
create or replace function pg_temp.book(p_k text, p_trip jsonb, p_phone text, p_name text, p_way text, p_booking jsonb)
returns void language plpgsql as $$
declare
  o jsonb := pg_temp.j('00000000-0000-0000-0000-0000000331d1', pg_temp.send_sql(p_trip, p_phone, p_name, p_way, p_booking));
  a jsonb;
begin
  if p_way = 'app' then
    a := pg_temp.j('00000000-0000-0000-0000-0000000331a1', format('select public.mygig_accept(%L)::text', o->>'offerId'));
  elsif p_way = 'sms' then
    a := pg_temp.j(null, format('select public.mygig_link_answer(%L, true)::text', o->>'token'));
  else
    a := pg_temp.j('00000000-0000-0000-0000-0000000331d1', format('select public.mygig_accept_here(%L)::text', o->>'offerId'));
  end if;
  insert into t values (p_k, (a->>'bookingId')::uuid, o || jsonb_build_object('accept', a));
end $$;
create or replace function pg_temp.link_pay(p_ref uuid, p_amount numeric, p_n int) returns void language plpgsql as $$
begin
  insert into public.payment_intents (id, user_id, purpose, purpose_ref, provider, amount)
  values (('00000000-0000-0000-0000-0000003310' || lpad(p_n::text, 2, '0'))::uuid, null, 'ride_card', p_ref::text, 'stripe', p_amount);
  perform public.payment_ride_card_paid(('00000000-0000-0000-0000-0000003310' || lpad(p_n::text, 2, '0'))::uuid, p_ref::text);
end $$;
create or replace function pg_temp.d(p_n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000331d' || p_n)::uuid $$;
-- Hafiz asks [p_to] to take [p_k] over; the reassign is kept as [p_rk].
create or replace function pg_temp.ask(p_rk text, p_k text, p_to int, p_booking boolean default false) returns void
language plpgsql as $$
declare v jsonb;
begin
  v := pg_temp.j(pg_temp.d(1), format('select public.mygig_reassign_start(%L, %L, %L, null, ''Car problem'')::text',
    case when p_booking then null else pg_temp.id(p_k) end, case when p_booking then pg_temp.id(p_k) end, pg_temp.d(p_to)));
  insert into t values (p_rk, (v->>'id')::uuid, v) on conflict (k) do update set id = excluded.id, v = excluded.v;
end $$;
create or replace function pg_temp.new_driver_ok(p_rk text, p_to int) returns jsonb language sql as $$
  select pg_temp.j(pg_temp.d(p_to), format('select public.mygig_reassign_driver_answer(%L, true, true)::text', pg_temp.id(p_rk)));
$$;
create or replace function pg_temp.free_drivers() returns void language plpgsql as $$
begin
  perform pg_temp.as_server();
  update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_fee_status = 'none',
                                  cancel_reason = 'test_reset', cancel_requested_by = 'system'
   where partner_id in (pg_temp.d(1), pg_temp.d(2), pg_temp.d(3)) and status in ('accepted', 'arrived', 'on_trip');
end $$;

select pg_temp.rule('{"dailyLimit": 50}');
select pg_temp.set_bal(pg_temp.d(1), 100, 'get_credit');
select pg_temp.set_bal(pg_temp.d(2), 100, 'get_credit');
select pg_temp.set_bal(pg_temp.d(3), 100, 'get_credit');
select pg_temp.set_bal(pg_temp.d(1), 0);
select pg_temp.set_bal(pg_temp.d(2), 0);
select pg_temp.j(pg_temp.d(1), 'select public.mygig_save_prefs(''{"approach": {"mode": "perkm", "perKm": 3, "freeKm": 1},
  "cancel": {"on": true, "amount": 5}}'', 3.11, 101.66)::text');

-- ---- 1. Settings ---------------------------------------------------------------------------------------
select pg_temp.check(public.mygig_settings_at('', '', '', '') @> '{
  "reassign": {"enabled": true, "when": "before", "answerMin": 10, "noAnswer": "keep", "sameOrBigger": true},
  "hotspots": {"enabled": true, "weeks": 4, "minCount": 3},
  "after": {"tips": true, "split": true, "splitMax": 3, "einvoice": true, "bookAgain": true},
  "driverExtras": {"quick": true, "regulars": true}}', 'the new parts and their defaults');
select pg_temp.check((select settings ? 'reassign' and settings ? 'hotspots' from public.mygig_rules where level = 'default'),
  'the Default rule shows them');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000331e1',
  'update public.mygig_rules set settings = settings || ''{"reassign": {"when": "always"}}'' where level = ''default'' returning 1')
  like 'MYGIG_SETTINGS_INVALID%', 'when: scheduled, before pickup or during');
select pg_temp.check(public.mygig_settings_problem('{"reassign": {"noAnswer": "driver"}}') is not null
  and public.mygig_settings_problem('{"after": {"splitMax": 5}}') is not null
  and public.mygig_settings_problem('{"hotspots": {"weeks": 0}}') is not null
  and public.mygig_settings_problem('{"reassign": {"noAnswer": "cancel", "when": "during"}}') is null,
  'the new values are checked');
select pg_temp.check(not exists (select 1 from jsonb_object_keys(public.mygig_defaults()->'reassign') k
                                  where k ilike '%absorb%' or k ilike '%cover%'), 'no setting makes anyone absorb an unpaid amount');

-- ---- 2. Eligibility ------------------------------------------------------------------------------------
select pg_temp.ride_now('r1', pg_temp.trip('{"pay": "link", "approachKm": 5}'), '0100331099', 'Ben Tamu', 'sms');
insert into t values ('opt', null, pg_temp.j(pg_temp.d(1), format('select public.mygig_reassign_options(%L)::text', pg_temp.id('r1'))));
select pg_temp.check((select v->'reasons' ? 'Car problem' and (v->>'answerMin')::int = 10 from t where k = 'opt'), 'the reasons, the answer time');
select pg_temp.check((select x->>'why' is null from t, jsonb_array_elements(v->'drivers') x
                       where k = 'opt' and x->>'id' = pg_temp.d(2)::text), 'Lee (MPV, myGiG) can be chosen');
select pg_temp.check((select x->>'why' = 'Smaller vehicle' from t, jsonb_array_elements(v->'drivers') x
                       where k = 'opt' and x->>'id' = pg_temp.d(3)::text), 'Tan''s hatchback is smaller: not with same-or-bigger');
select pg_temp.check((select x->>'why' = 'No myGiG access' from t, jsonb_array_elements(v->'drivers') x
                       where k = 'opt' and x->>'id' = pg_temp.d(4)::text), 'a driver without myGiG can''t be chosen');
select pg_temp.check((select x ? 'name' and x ? 'plate' and x ? 'km' and not (x ? 'phone') from t, jsonb_array_elements(v->'drivers') x
                       where k = 'opt' and x->>'id' = pg_temp.d(2)::text), 'name, car, plate and distance; no phone');
select pg_temp.rule('{"reassign": {"sameOrBigger": false}}');
select pg_temp.check(public.mygig_reassign_why_not(pg_temp.d(3), pg_temp.d(1), 3.11, 101.66, 1, 0, false, now(), now(),
  public.mygig_settings_at('', '', '', '')) is null, 'off: any car that fits');
select pg_temp.check(public.mygig_reassign_why_not(pg_temp.d(3), pg_temp.d(1), 3.11, 101.66, 5, 0, false, now(), now(),
  public.mygig_settings_at('', '', '', '')) = 'Too small for this ride', 'but not too small for the passengers');
select pg_temp.check(public.mygig_reassign_why_not(pg_temp.d(3), pg_temp.d(1), 3.11, 101.66, 1, 4, false, now(), now(),
  public.mygig_settings_at('', '', '', '')) = 'Too small for this ride', 'or the luggage');
select pg_temp.rule('{"reassign": {"sameOrBigger": true}}');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_reassign_start(%L, null, %L, null, ''Car problem'')::text',
  pg_temp.id('r1'), pg_temp.d(4))) like 'MYGIG_REASSIGN_NOT_ELIGIBLE%', 'the server refuses one who can''t be chosen');
select pg_temp.check(pg_temp.value_as(pg_temp.d(2), format('select public.mygig_reassign_start(%L, null, %L, null, ''Car problem'')::text',
  pg_temp.id('r1'), pg_temp.d(3))) like 'MYGIG_NOT_FOUND%', 'only the ride''s driver reassigns it');
select pg_temp.rule('{"reassign": {"enabled": false}}');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_reassign_options(%L)::text', pg_temp.id('r1')))
  like 'MYGIG_REASSIGN_OFF%', 'the admin switches it off');
select pg_temp.rule('{"reassign": {"enabled": true, "when": "scheduled"}}');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_reassign_options(%L)::text', pg_temp.id('r1')))
  like 'MYGIG_REASSIGN_SCHEDULED_ONLY%', 'scheduled only: not a ride now');
select pg_temp.rule('{"reassign": {"when": "before"}}');

-- ---- 3. A ride paid by link, reassigned before pickup ------------------------------------------------------
select pg_temp.link_pay(pg_temp.id('r1'), (select public.mygig_owed(r) from pg_temp.ride('r1') r), 1);
select pg_temp.j(pg_temp.d(1), format('select public.mygig_arrived(%L, 3.11, 101.66)::text', pg_temp.id('r1')));
select pg_temp.check((select (mygig #>> '{quote,approach}')::numeric = 12 and status = 'arrived'
                             and pg_temp.bal(pg_temp.d(1)) = (mygig->>'linkPaid')::numeric from pg_temp.ride('r1')),
  'paid by link (into Hafiz''s GET.wallet), Hafiz at the pickup');
select pg_temp.ask('ra1', 'r1', 2);
select pg_temp.check((select stage = 'driver' and way = 'sms' and reason = 'Car problem' from pg_temp.ra('ra1')), 'Lee is asked');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = pg_temp.d(2)
                               and data->>'type' = 'mygig_reassign_offer'), 'Lee gets a push');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_reassign_start(%L, null, %L, null, ''Emergency'')::text',
  pg_temp.id('r1'), pg_temp.d(2))) like 'MYGIG_REASSIGN_OPEN%', 'one at a time');
-- What Lee sees: the whole order, the agreed price, the money that moves, his plan.
insert into t values ('v1', null, pg_temp.j(pg_temp.d(2), format('select public.mygig_reassign_view(%L)::text', pg_temp.id('ra1'))));
select pg_temp.check((select v->>'me' = 'to' and (v->>'total')::numeric > 0 and (v->>'paidMoves')::numeric > 0
                             and v #>> '{trip,drop,name}' = 'Sentral 331' and v ? 'plan' and v->>'passenger' = 'Ben'
                             and v->>'reason' = 'Car problem' and not (v ? 'steps') from t where k = 'v1'),
  'the new driver sees the order, price, payment, money that moves and their plan');
select pg_temp.check(pg_temp.value_as(pg_temp.d(3), format('select public.mygig_reassign_view(%L)::text', pg_temp.id('ra1')))
  like 'MYGIG_NOT_FOUND%', 'nobody else sees it');
select pg_temp.check(pg_temp.value_as(pg_temp.d(2), format('select public.mygig_reassign_driver_answer(%L, true, false)::text',
  pg_temp.id('ra1'))) like 'MYGIG_REASSIGN_ACK%', 'Accept needs "I accept this ride at the agreed price"');
select pg_temp.new_driver_ok('ra1', 2);
select pg_temp.check((select stage = 'passenger' and token_hash is not null from pg_temp.ra('ra1'))
  and exists (select 1 from public.sms_outbox where to_phone = '+60100331099' and body like '%changed to Lee%'),
  'then the passenger is asked: a link by SMS');
select pg_temp.check((select partner_id = pg_temp.d(1) and status = 'arrived' from pg_temp.ride('r1')),
  'nothing changes until the passenger confirms');
select pg_temp.check((pg_temp.j(null, format('select public.mygig_link_view(%L)::text', (select v->>'token' from t where k = 'r1')))
  #>> '{reassign,to,name}') = 'Lee', 'the trip link shows the change waiting');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_reassign_answer(null, %L, ''confirm'', false)::text',
  (select v->>'token' from t where k = 'r1'))) like 'MYGIG_REASSIGN_ACK%', 'the passenger ticks "I understand my driver is now Lee"');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_reassign_answer(%L, null, ''confirm'', true)::text',
  pg_temp.id('ra1'))) like 'MYGIG_NOT_FOUND%', 'not on the driver''s phone when the way is a link');
select pg_temp.j(null, format('select public.mygig_reassign_answer(null, %L, ''confirm'', true)::text',
  (select v->>'token' from t where k = 'r1')));
select pg_temp.check((select partner_id = pg_temp.d(2) and status = 'accepted' and arrived_at is null and partner_plate = 'VBC 7720'
                             and (mygig->>'reassignKept')::numeric = 12 from pg_temp.ride('r1')),
  'confirmed: the ride is Lee''s, coming to the pickup again');
select pg_temp.check((select stage = 'done' and answered_via = 'link' and kept = 12
                             and moved = (select (mygig->>'linkPaid')::numeric - 12 from pg_temp.ride('r1')) from pg_temp.ra('ra1'))
  and pg_temp.bal(pg_temp.d(1)) = 12 and pg_temp.bal(pg_temp.d(2)) = (select (mygig->>'linkPaid')::numeric - 12 from pg_temp.ride('r1')),
  'the link''s money moves to Lee; Hafiz keeps what he earned coming to the pickup');
select pg_temp.check((select jsonb_agg(h->>'what') @> '["reassign_asked", "reassign_new_driver_accepted", "reassign_done"]'
                        from pg_temp.ride('r1') r, jsonb_array_elements(r.mygig->'history') h)
  and (select jsonb_array_length(steps) = 3 from pg_temp.ra('ra1')), 'every step in the ride''s history');
select pg_temp.check((pg_temp.j(null, format('select public.mygig_link_view(%L)::text', (select v->>'token' from t where k = 'r1')))
  #>> '{driver,name}') = 'Lee', 'the trip link shows the new driver');
-- Lee then cancels: each driver gives back what they hold.
select pg_temp.set_bal(pg_temp.d(1), 0, 'get_credit');
select pg_temp.set_bal(pg_temp.d(2), 0, 'get_credit');
update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_reason = 'driver_cancelled',
                                cancel_requested_by = 'partner', cancel_fee_status = 'none'
 where id = pg_temp.id('r1');
select pg_temp.check((select (mygig->>'refundDue')::numeric = (mygig->>'linkPaid')::numeric from pg_temp.ride('r1'))
  and pg_temp.bal(pg_temp.d(1), 'get_credit') = -12
  and pg_temp.bal(pg_temp.d(2), 'get_credit') = -(select (mygig->>'linkPaid')::numeric - 12 from pg_temp.ride('r1')),
  'refunded in full: from each driver what they hold');
select pg_temp.set_bal(pg_temp.d(1), 100, 'get_credit');
select pg_temp.set_bal(pg_temp.d(2), 100, 'get_credit');

-- ---- 4. Keep, cancel, decline ----------------------------------------------------------------------------
-- Registered: the passenger keeps Hafiz in the app.
select pg_temp.set_bal('00000000-0000-0000-0000-0000000331a1', 200);
select pg_temp.ride_now('r2', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app');
select pg_temp.ask('ra2', 'r2', 2);
select pg_temp.new_driver_ok('ra2', 2);
select pg_temp.check((select way = 'app' and passenger_id = '00000000-0000-0000-0000-0000000331a1' from pg_temp.ra('ra2'))
  and exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000331a1'
                and data->>'type' = 'mygig_reassign'), 'in the app: a push to confirm');
select pg_temp.check((pg_temp.j('00000000-0000-0000-0000-0000000331a1', 'select public.mygig_reassigns_mine()::text') -> 0 ->> 'me')
  = 'passenger', 'the passenger''s app finds it');
select pg_temp.j('00000000-0000-0000-0000-0000000331a1', format('select public.mygig_reassign_answer(%L, null, ''keep'')::text', pg_temp.id('ra2')));
select pg_temp.check((select stage = 'kept' and answered_via = 'app' from pg_temp.ra('ra2'))
  and (select partner_id = pg_temp.d(1) from pg_temp.ride('r2')), 'kept: nothing changed');
select pg_temp.free_drivers();
-- No phone: confirmed on Hafiz's phone; the passenger cancels with no charge.
select pg_temp.ride_now('r3', pg_temp.trip(), null, 'Ben', 'here');
select pg_temp.ask('ra3', 'r3', 2);
select pg_temp.new_driver_ok('ra3', 2);
select pg_temp.check((select way = 'here' and token_hash is null from pg_temp.ra('ra3')), 'no phone: on the driver''s phone');
select pg_temp.j(pg_temp.d(1), format('select public.mygig_reassign_answer(%L, null, ''cancel'')::text', pg_temp.id('ra3')));
select pg_temp.check((select status = 'cancelled' and coalesce(cancel_fee, 0) = 0 and cancel_reason = 'mygig_reassign_cancelled'
                        from pg_temp.ride('r3')) and (select stage = 'cancelled' and answered_via = 'here' from pg_temp.ra('ra3')),
  'cancelled with no charge');
-- Lee declines: the ride stays Hafiz's.
select pg_temp.ride_now('r4', pg_temp.trip(), null, 'Ben', 'here');
select pg_temp.ask('ra4', 'r4', 2);
select pg_temp.j(pg_temp.d(2), format('select public.mygig_reassign_driver_answer(%L, false)::text', pg_temp.id('ra4')));
select pg_temp.check((select stage = 'declined' from pg_temp.ra('ra4')) and (select partner_id = pg_temp.d(1) from pg_temp.ride('r4')),
  'declined: back to the first driver');
-- Hafiz stops one himself.
select pg_temp.ask('ra4b', 'r4', 2);
select pg_temp.j(pg_temp.d(1), format('select public.mygig_reassign_stop(%L)::text', pg_temp.id('ra4b')));
select pg_temp.check((select stage = 'stopped' from pg_temp.ra('ra4b')), 'stopped by the first driver');

-- ---- 5. No answer ----------------------------------------------------------------------------------------
select pg_temp.ask('ra5', 'r4', 2);
update public.mygig_reassigns set answer_by = now() - interval '1 minute' where id = pg_temp.id('ra5');
select public.mygig_reassigns_tick();
select pg_temp.check((select stage = 'expired' from pg_temp.ra('ra5')), 'the new driver didn''t answer: it lapses');
select pg_temp.ask('ra6', 'r4', 2);
select pg_temp.new_driver_ok('ra6', 2);
update public.mygig_reassigns set answer_by = now() - interval '1 minute' where id = pg_temp.id('ra6');
select public.mygig_reassigns_tick();
select pg_temp.check((select stage = 'kept' and answered_via = 'timeout' from pg_temp.ra('ra6'))
  and (select partner_id = pg_temp.d(1) and status in ('accepted', 'arrived') from pg_temp.ride('r4')),
  'the passenger didn''t answer: the first driver keeps it (the admin''s rule)');
select pg_temp.rule('{"reassign": {"noAnswer": "cancel"}}');
select pg_temp.ask('ra7', 'r4', 2);
select pg_temp.new_driver_ok('ra7', 2);
update public.mygig_reassigns set answer_by = now() - interval '1 minute' where id = pg_temp.id('ra7');
select public.mygig_reassigns_tick();
select pg_temp.check((select stage = 'cancelled' from pg_temp.ra('ra7'))
  and (select status = 'cancelled' and coalesce(cancel_fee, 0) = 0 from pg_temp.ride('r4')),
  'or, by the admin''s rule, cancelled with no charge');
select pg_temp.rule('{"reassign": {"noAnswer": "keep"}}');

-- ---- 6. During the trip ----------------------------------------------------------------------------------
select pg_temp.ride_now('r8', pg_temp.trip(), null, 'Ben', 'here');
select pg_temp.j(pg_temp.d(1), format('select public.mygig_start(%L)::text', pg_temp.id('r8')));
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_reassign_options(%L)::text', pg_temp.id('r8')))
  like 'MYGIG_REASSIGN_DURING_OFF%', 'not during the trip unless the admin allows it');
select pg_temp.rule('{"reassign": {"when": "during"}}');
select pg_temp.ask('ra8', 'r8', 2);
select pg_temp.check((select during from pg_temp.ra('ra8')), 'a hand over during the trip');
select pg_temp.new_driver_ok('ra8', 2);
select pg_temp.j(pg_temp.d(1), format('select public.mygig_reassign_answer(%L, null, ''confirm'', true)::text', pg_temp.id('ra8')));
select pg_temp.check((select partner_id = pg_temp.d(2) and status = 'on_trip' and handed_over_at is not null
                             and handover_meet_lat is not null from pg_temp.ride('r8'))
  and exists (select 1 from public.trip_handovers h where h.ride_id = pg_temp.id('r8') and h.status = 'accepted'
                and h.from_partner_id = pg_temp.d(1) and h.to_partner_id = pg_temp.d(2) and h.rider_id is null),
  '0199''s swap: Lee meets the car, Hafiz''s share when it completes');
select pg_temp.rule('{"reassign": {"when": "before"}}');
select pg_temp.free_drivers();

-- ---- 7. A booking --------------------------------------------------------------------------------------------
select pg_temp.book('b1', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '3 hours'));
-- Cash Hafiz took for it (as a daily hire's balance would be).
update public.mygig_bookings set cash_paid = 5, cash_left = 5 where id = pg_temp.id('b1');
select pg_temp.check((select x->>'why' is null from jsonb_array_elements(pg_temp.j(pg_temp.d(1),
  format('select public.mygig_reassign_options(null, %L)::text', pg_temp.id('b1')))->'drivers') x where x->>'id' = pg_temp.d(2)::text),
  'Lee can take the booking');
select pg_temp.ask('rb1', 'b1', 2, true);
select pg_temp.check((pg_temp.j(pg_temp.d(2), format('select public.mygig_reassign_view(%L)::text', pg_temp.id('rb1')))->>'kind') = 'trip',
  'Lee sees the booking');
select pg_temp.new_driver_ok('rb1', 2);
select pg_temp.j('00000000-0000-0000-0000-0000000331a1', format('select public.mygig_reassign_answer(%L, null, ''confirm'', true)::text',
  pg_temp.id('rb1')));
select pg_temp.check((select driver_id = pg_temp.d(2) and jsonb_array_length(history) >= 3 from public.mygig_bookings
                       where id = pg_temp.id('b1')), 'the booking is Lee''s, with its history');
select pg_temp.check(exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('b1') and user_id = pg_temp.d(2)
                               and kind = 'mygig_reassign_in' and amount = 5 and wallet_type = 'get_credit'),
  'the cash Hafiz took moves to Lee');
select pg_temp.check(jsonb_array_length(pg_temp.j(pg_temp.d(2), 'select public.mygig_scheduled()::text')) >= 1,
  'in Lee''s Scheduled myGiG');

-- ---- 8. Hotspots -----------------------------------------------------------------------------------------------
-- Three cash rides from the same place to the same drop-off, with the same number.
create or replace function pg_temp.done_ride(p_k text) returns void language plpgsql as $$
begin
  perform pg_temp.ride_now(p_k, pg_temp.trip(), '0100331077', 'Mei', 'here');
  perform pg_temp.j(pg_temp.d(1), format('select public.mygig_start(%L)::text', pg_temp.id(p_k)));
  perform pg_temp.j(pg_temp.d(1), format('select public.mygig_complete(%L)::text', pg_temp.id(p_k)));
end $$;
select pg_temp.done_ride('h1');
select pg_temp.done_ride('h2');
select pg_temp.done_ride('h3');
select pg_temp.check((select status = 'completed' from pg_temp.ride('h3')), 'rides done');
insert into t values ('hot', null, pg_temp.j(pg_temp.d(1), 'select public.mygig_hotspots(3.11, 101.66)::text'));
select pg_temp.check((select (v->>'enabled')::boolean and jsonb_array_length(v->'hours') = 24
                             and exists (select 1 from jsonb_array_elements(v->'areas') a where (a->>'count')::int >= 3)
                        from t where k = 'hot'), 'an area with 3 rides, and the hours of this weekday');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(v->'areas') a, jsonb_object_keys(a) k
                                          where k not in ('lat', 'lng', 'name', 'count', 'nowCount', 'km'))
                             and v::text not like '%Mei%' and v::text not like '%0100331077%' from t where k = 'hot'),
  'counts per area only: no passenger data');
select pg_temp.rule('{"hotspots": {"minCount": 50}}');
select pg_temp.check((select jsonb_array_length(v->'areas') = 0 and jsonb_array_length(v->'hours') = 0
                        from (select pg_temp.j(pg_temp.d(1), 'select public.mygig_hotspots(3.11, 101.66)::text') v) x),
  'areas under the minimum are hidden');
select pg_temp.rule('{"hotspots": {"minCount": 3, "enabled": false}}');
select pg_temp.check((pg_temp.j(pg_temp.d(1), 'select public.mygig_hotspots(3.11, 101.66)::text')->>'enabled') = 'false', 'switched off');
select pg_temp.rule('{"hotspots": {"enabled": true}}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000331a1', 'select public.mygig_hotspots(3.11, 101.66)::text')
  like 'not_authorized%', 'drivers only');

-- ---- 9. Quick trips and regulars -----------------------------------------------------------------------------
select pg_temp.check((pg_temp.j(pg_temp.d(1), 'select public.mygig_quick_trips()::text') -> 0 ->> 'name') = 'Sentral 331',
  'quick trips: the most used drop-off');
select pg_temp.check((select (v->>'trips')::int >= 3 and v #>> '{drop,name}' = 'Sentral 331'
                        from (select pg_temp.j(pg_temp.d(1), 'select public.mygig_regular(''+60100331077'')::text') v) x),
  'a regular: rode with this driver before, the usual drop-off');
select pg_temp.check(pg_temp.value_as(pg_temp.d(2), 'select public.mygig_regular(''+60100331077'')::text') = 'ok',
  'only the driver''s own riders');

-- ---- 10. After the trip ------------------------------------------------------------------------------------------
-- On the trip link: rate, tip by link and by cash.
select pg_temp.ride_now('a1', pg_temp.trip(), '0100331088', 'Siti', 'sms');
select pg_temp.j(pg_temp.d(1), format('select public.mygig_start(%L)::text', pg_temp.id('a1')));
select pg_temp.j(pg_temp.d(1), format('select public.mygig_complete(%L)::text', pg_temp.id('a1')));
insert into t values ('av', null, pg_temp.j(null, format('select public.mygig_after_view(null, %L)::text', (select v->>'token' from t where k = 'a1'))));
select pg_temp.check((select (v #>> '{can,rate}')::boolean and (v #>> '{can,tip}')::boolean and (v #>> '{can,einvoice}')::boolean
                             and v ? 'appOffer' and v #>> '{appOffer,code}' is not null and not (v #>> '{can,split}')::boolean
                        from t where k = 'av'), 'the receipt and what the link passenger may do; no split once paid in cash');
select pg_temp.j(null, format('select public.mygig_after_rate(%L, 5, ''Kind driver'')::text', (select v->>'token' from t where k = 'a1')));
select pg_temp.check((select stars = 5 from public.mygig_after where ride_id = pg_temp.id('a1')), 'rated');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_after_tip(null, %L, 500, ''link'')::text',
  (select v->>'token' from t where k = 'a1'))) like 'TIP_AMOUNT%', 'at most the admin''s tip');
insert into t values ('tp', null, pg_temp.j(null, format('select public.mygig_after_tip(null, %L, 5, ''link'')::text',
  (select v->>'token' from t where k = 'a1'))));
update t set id = (v->>'partId')::uuid where k = 'tp';
select pg_temp.check(public.payment_mygig_link_by_token((select v->>'token' from t where k = 'a1'), pg_temp.id('tp'))
  = (public.payment_gateway_for('ride_card') is not null), 'the trip link may ask for the tip''s pay link');
select pg_temp.check(not public.payment_mygig_link_by_token('not-a-token-331', pg_temp.id('tp')), 'not with another token');
select pg_temp.set_bal(pg_temp.d(1), 0);
select pg_temp.link_pay(pg_temp.id('tp'), 5, 2);
select pg_temp.check(exists (select 1 from public.ride_tips where ride_id = pg_temp.id('a1') and method = 'link' and amount = 5)
  and pg_temp.bal(pg_temp.d(1)) = 5, 'the tip paid by link goes to the driver');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_after_tip(null, %L, 2, ''cash'')::text',
  (select v->>'token' from t where k = 'a1'))) like 'TIP_DONE%', 'one tip a trip');
select pg_temp.check((select (data->>'type') = 'ride_tip' from public.notification_outbox
                       where profile_id = pg_temp.d(1) and data->>'type' = 'ride_tip' limit 1), 'the driver is told');
select pg_temp.ride_now('a2', pg_temp.trip(), '0100331088', 'Siti', 'sms');
select pg_temp.j(pg_temp.d(1), format('select public.mygig_start(%L)::text', pg_temp.id('a2')));
select pg_temp.j(pg_temp.d(1), format('select public.mygig_complete(%L)::text', pg_temp.id('a2')));
select pg_temp.j(null, format('select public.mygig_after_tip(null, %L, 2, ''cash'')::text', (select v->>'token' from t where k = 'a2')));
select pg_temp.check((select cash_tip = 2 from public.mygig_after where ride_id = pg_temp.id('a2')), 'a cash tip noted for the driver');
-- e-Invoice: kept for the admin (no MyInvois connection), and the passenger is told.
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_einvoice_request(null, %L, ''{"name": "Siti", "email": "siti@example.com"}'')::text',
  (select v->>'token' from t where k = 'a2'))) like 'MYGIG_EINVOICE%', 'a TIN or an ID is needed');
insert into t values ('ei', null, pg_temp.j(null, format('select public.mygig_einvoice_request(null, %L, %L)::text',
  (select v->>'token' from t where k = 'a2'), '{"name": "Siti Contoh", "email": "siti@example.com", "idType": "nric", "idNo": "900101145678"}')));
select pg_temp.check((select v->>'state' = 'requested' and v->>'message' like '%LHDN MyInvois%' from t where k = 'ei')
  and exists (select 1 from public.mygig_einvoice_requests where ride_id = pg_temp.id('a2') and email = 'siti@example.com'
                and amount > 0), 'stored for the admin, and the passenger is told who sends it');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_einvoice_request(null, %L, %L)::text',
  (select v->>'token' from t where k = 'a2'), '{"name": "Siti", "email": "s@example.com", "tin": "IG1234567"}'))
  like 'MYGIG_EINVOICE_DONE%', 'once a trip');
-- Book again: the link passenger gets the app offer with the driver's code.
insert into t values ('ba', null, pg_temp.j(null, format('select public.mygig_book_again(null, %L)::text', (select v->>'token' from t where k = 'a2'))));
select pg_temp.check((select not (v->>'saved')::boolean and v #>> '{appOffer,code}' ~ '^[0-9A-Z]{4,}$' from t where k = 'ba'),
  'not registered: the app offer with Hafiz''s referral code');
-- In the app: a favourite driver; the tip from GET.wallet.
select pg_temp.ride_now('a3', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app');
select pg_temp.j(pg_temp.d(1), format('select public.mygig_start(%L)::text', pg_temp.id('a3')));
select pg_temp.j(pg_temp.d(1), format('select public.mygig_complete(%L)::text', pg_temp.id('a3')));
insert into t values ('ba3', null, pg_temp.j('00000000-0000-0000-0000-0000000331a1',
  format('select public.mygig_book_again(%L)::text', pg_temp.id('a3'))));
select pg_temp.check((select (v->>'saved')::boolean from t where k = 'ba3')
  and exists (select 1 from public.favourite_drivers where rider_id = '00000000-0000-0000-0000-0000000331a1' and driver_id = pg_temp.d(1)),
  'registered: Hafiz is a favourite driver (My Ride)');
select pg_temp.check(pg_temp.value_as(pg_temp.d(2), format('select public.mygig_book_again(%L)::text', pg_temp.id('a3')))
  like 'MYGIG_NOT_FOUND%', 'only the ride''s passenger');
-- Split: only while something is owed; 2 people, a link for the other.
select pg_temp.ride_now('a4', pg_temp.trip('{"pay": "link"}'), '0100331066', 'Raju', 'sms');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_split(null, %L, 2, null)::text',
  (select v->>'token' from t where k = 'a4'))) like 'MYGIG_SPLIT_PHONES%', 'a phone for the other person');
insert into t values ('sp', null, pg_temp.j(null, format('select public.mygig_split(null, %L, 2, array[''0100331055''])::text',
  (select v->>'token' from t where k = 'a4'))));
select pg_temp.check((select (v #>> '{parts,0,amount}')::numeric + (v #>> '{parts,1,amount}')::numeric = (v->>'owed')::numeric
                        from t where k = 'sp')
  and exists (select 1 from public.sms_outbox where to_phone = '+60100331055' and body like '%gig/pay/%'),
  'split in two; the other person is texted their link');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_split(null, %L, 2, array[''0100331055''])::text',
  (select v->>'token' from t where k = 'a4'))) like 'MYGIG_SPLIT_DONE%', 'split once');
select pg_temp.link_pay((select (v #>> '{parts,0,id}')::uuid from t where k = 'sp'),
                        (select (v #>> '{parts,0,amount}')::numeric from t where k = 'sp'), 3);
select pg_temp.link_pay((select (v #>> '{parts,1,id}')::uuid from t where k = 'sp'),
                        (select (v #>> '{parts,1,amount}')::numeric from t where k = 'sp'), 4);
select pg_temp.check((select public.mygig_owed(r) = 0 from pg_temp.ride('a4') r)
  and not exists (select 1 from public.mygig_pay_parts where ride_id = pg_temp.id('a4') and paid_at is null),
  'both shares paid: nothing owed, the trip can start');
select pg_temp.check(pg_temp.value_as(null, format('select public.mygig_split(null, %L, 2, array[''0100331055''])::text',
  (select v->>'token' from t where k = 'a1'))) like 'MYGIG_SPLIT%', 'nothing to split once paid');
select pg_temp.check(pg_temp.value_as(null, 'select public.mygig_pay_part_view(''nope-331'')::text') like 'MYGIG_LINK%',
  'an unknown share link');
select pg_temp.free_drivers();

-- ---- 11. The admin dashboard ---------------------------------------------------------------------------------
select pg_temp.rule('{"repeatFlag": 3, "dailyLimit": 3}');
update public.ride_requests set mygig = mygig || '{"flagged": true}' where id = pg_temp.id('h1');
insert into t values ('dash', null, pg_temp.j('00000000-0000-0000-0000-0000000331e1', 'select public.mygig_admin_dashboard()::text'));
select pg_temp.check((select (v #>> '{tiles,completed}')::int >= 6 and (v #>> '{tiles,takings}')::numeric > 0
                             and (v #>> '{tiles,viaHere}')::int >= 3 and (v #>> '{tiles,viaLink}')::int >= 2
                             and (v #>> '{tiles,viaApp}')::int >= 2 and (v #>> '{tiles,reassigned}')::int >= 2
                        from t where k = 'dash'), 'today''s rides, takings and how passengers accepted');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(v #> '{flags,priceGuard}') x where x->>'rideId' = pg_temp.id('h1')::text)
                             and exists (select 1 from jsonb_array_elements(v #> '{flags,repeatNumbers}') x
                                          where x->>'phone' = '+60100331077' and (x->>'rides')::int >= 3)
                             and exists (select 1 from jsonb_array_elements(v #> '{flags,dailyLimit}') x
                                          where x->>'driverId' = pg_temp.d(1)::text)
                        from t where k = 'dash'), 'flagged: above the price guard, a number with many rides, a driver at the limit');
select pg_temp.check((select jsonb_array_length(v->'reassigns') >= 8 and v->'reassigns' -> 0 ? 'steps'
                             and exists (select 1 from jsonb_array_elements(v->'einvoices') e where e->>'email' = 'siti@example.com')
                        from t where k = 'dash'), 'the reassign history and the e-Invoice requests');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), 'select public.mygig_admin_dashboard()::text') like 'not_authorized%',
  'admins only');
select pg_temp.check(exists (select 1 from jsonb_array_elements(pg_temp.j('00000000-0000-0000-0000-0000000331e1',
  'select public.mygig_admin_bookings(''trip'', null, ''lee'')::text')) b where b->>'id' = pg_temp.id('b1')::text),
  'the admin''s list of myGiG bookings, filtered (kind, driver)');
select pg_temp.j('00000000-0000-0000-0000-0000000331e1', format('select public.mygig_admin_einvoice_set(%L, ''sent'', ''Emailed'')::text',
  (select id from public.mygig_einvoice_requests where ride_id = pg_temp.id('a2'))));
select pg_temp.check((select state = 'sent' and handled_by = '00000000-0000-0000-0000-0000000331e1' from public.mygig_einvoice_requests
                       where ride_id = pg_temp.id('a2')), 'the admin marks it sent');
select pg_temp.check(pg_temp.value_as(pg_temp.d(1), format('select public.mygig_admin_einvoice_set(%L, ''sent'')::text',
  (select id from public.mygig_einvoice_requests where ride_id = pg_temp.id('a2')))) like 'not_authorized%', 'admins only');
select pg_temp.rule('{"repeatFlag": 4, "dailyLimit": 50}');

-- ---- 12. A late cancel of an in-app later trip ----------------------------------------------------------------
select pg_temp.book('b2', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '4 hours'));
select pg_temp.check((select plan = 'start' and pay_now = 0 and (quote #>> '{terms,cancelFee}')::numeric = 5
                        and public.mygig_booking_late_fee(b) = 5 from public.mygig_bookings b where id = pg_temp.id('b2')),
  'nothing paid upfront; the fee agreed is 5');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000331a1', 50);
select pg_temp.set_bal(pg_temp.d(1), 0);
-- Within the free time: no fee.
insert into t values ('c2', null, pg_temp.j('00000000-0000-0000-0000-0000000331a1',
  format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b2'))));
select pg_temp.check((select (v->>'fee')::numeric = 0 from t where k = 'c2') and pg_temp.bal('00000000-0000-0000-0000-0000000331a1') = 50,
  'free before the free-cancel time');
select pg_temp.book('b3', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '4 hours'));
update public.mygig_bookings set free_cancel_until = now() - interval '1 minute' where id = pg_temp.id('b3');
select pg_temp.check((select (x->>'lateFee')::numeric = 5 from jsonb_array_elements(pg_temp.j('00000000-0000-0000-0000-0000000331a1',
  'select public.mygig_my_bookings()::text')) x where x->>'id' = pg_temp.id('b3')::text), 'the passenger''s app shows the fee first');
insert into t values ('c3', null, pg_temp.j('00000000-0000-0000-0000-0000000331a1',
  format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b3'))));
select pg_temp.check((select (v->>'fee')::numeric = 5 and v->>'feeStatus' = 'charged' from t where k = 'c3')
  and pg_temp.bal('00000000-0000-0000-0000-0000000331a1') = 45 and pg_temp.bal(pg_temp.d(1)) = 5
  and (select cancel_fee = 5 and cancel_fee_status = 'charged' from public.mygig_bookings where id = pg_temp.id('b3')),
  'late: part A''s fee from the passenger''s GET.wallet to the driver');
select pg_temp.book('b4', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '4 hours'));
update public.mygig_bookings set free_cancel_until = now() - interval '1 minute' where id = pg_temp.id('b4');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000331a1', 1);
insert into t values ('c4', null, pg_temp.j('00000000-0000-0000-0000-0000000331a1',
  format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b4'))));
select pg_temp.check((select v->>'feeStatus' = 'due' from t where k = 'c4') and pg_temp.bal(pg_temp.d(1)) = 5,
  'not enough in the GET.wallet: due, nothing paid out unbacked');
select pg_temp.book('b5', pg_temp.trip('{"pay": "wallet"}'), '10 033 1011', null, 'app',
  jsonb_build_object('kind', 'trip', 'when', 'later', 'at', now() + interval '4 hours'));
update public.mygig_bookings set free_cancel_until = now() - interval '1 minute' where id = pg_temp.id('b5');
insert into t values ('c5', null, pg_temp.j(pg_temp.d(1), format('select public.mygig_booking_cancel(%L)::text', pg_temp.id('b5'))));
select pg_temp.check((select (v->>'fee')::numeric = 0 from t where k = 'c5'), 'the driver cancelling: no fee to the passenger');

rollback;
