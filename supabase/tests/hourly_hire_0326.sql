-- ============================================================================
-- Regression test for migration 0326: hourly hire.
--   1. The quote: off until the admin turns it on, the least hours, the
--      hours' range and step, a service without hire, a tariff card's
--      override (and a city switching it off), cash refused unless allowed.
--   2. A hire booked now: the server's price over the app's, bidding off,
--      'hire' on its add-ons, a place fee at the pickup, the terms fixed.
--   3. The GET.wallet hold at booking, returned when it is cancelled.
--   4. Extensions: the driver's waits for the rider (approve, decline), the
--      rider's is approved at once, and every one with the setting off.
--   5. The end: overtime in started steps up to what was approved, extra km
--      past the km included, the place fee kept; early-end modes.
--   6. Booked for later: priced and quoted at booking, the quote kept at
--      release; the driver clash with the hire's real span both ways.
--   7. The minute's tick: the reminder and the auto-end.
--   8. A 12-hour hire still counts as on the go after 12 hours.
--   9. Drivers: only those who take hire; no counter-offer.
--  10. Family: the 'hire' module, the hold from the host's GET.wallet and
--      back to the host.
--  11. Statements carry the hire lines.
-- All names, places and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/hourly_hire_0326.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000326a1'),  -- rider, GET.wallet
  ('00000000-0000-0000-0000-0000000326a2'),  -- rider, cash
  ('00000000-0000-0000-0000-0000000326a3'),  -- rider
  ('00000000-0000-0000-0000-0000000326a4'),  -- rider
  ('00000000-0000-0000-0000-0000000326b1'),  -- driver who takes hire
  ('00000000-0000-0000-0000-0000000326b2'),  -- driver who doesn't
  ('00000000-0000-0000-0000-0000000326f1'),  -- family host
  ('00000000-0000-0000-0000-0000000326f2')   -- family member
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000326a1', 'Aina Contoh', '+60100032601'),
  ('00000000-0000-0000-0000-0000000326a2', 'Badrul Contoh', '+60100032602'),
  ('00000000-0000-0000-0000-0000000326a3', 'Chen Sample', '+60100032603'),
  ('00000000-0000-0000-0000-0000000326a4', 'Devi Sample', '+60100032604'),
  ('00000000-0000-0000-0000-0000000326b1', 'Eddy Pemandu', '+60100032611'),
  ('00000000-0000-0000-0000-0000000326b2', 'Farid Pemandu', '+60100032612'),
  ('00000000-0000-0000-0000-0000000326f1', 'Gopal Contoh', '+60100032621'),
  ('00000000-0000-0000-0000-0000000326f2', 'Hana Contoh', '+60100032622')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

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
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return coalesce(nullif(v, ''), 'ok');
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.bal(p_user uuid) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = 'get_wallet'), 0);
$$;
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric) returns void language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, 'get_wallet', 'test_adjust', p_to - pg_temp.bal(p_user), 'test 0326');
  end if;
end $$;
create or replace function pg_temp.cfg(p jsonb) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_server();
  return public.set_hourly_hire_config(p);
end $$;
create or replace function pg_temp.q(p_hours numeric, p_service text default 'Hire Saloon 325',
                                     p_city text default null, p_payment text default null) returns jsonb
language sql as $$
  select public.hire_quote(3.10, 101.60, null, null, p_service, p_hours, null, 'Hireland 325', 'Negeri 325',
                           p_city, null, p_payment);
$$;
-- A hire booked by [p_rider] as the app books it ([p_fare] is the app's price).
create or replace function pg_temp.book_sql(p_rider uuid, p_hours numeric, p_pay text default 'Get Pay',
                                            p_fare numeric default 1) returns text
language sql as $$
  select format($f$insert into public.ride_requests (rider_id, status, service, payment_mode, pickup_lat, pickup_lng,
                     pickup_name, fare, ride_fare, offer_me, country, state, hire_package, hire_hours)
                   values (%L, 'open', 'Hire Saloon 325', %L, 3.10, 101.60, 'Hire Plaza 325', %s, %s, true,
                           'Hireland 325', 'Negeri 325', 'hourly', %s) returning id::text$f$,
                p_rider, p_pay, p_fare, p_fare, p_hours);
$$;
create temp table t (k text primary key, id uuid);
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;
create or replace function pg_temp.ride(p_k text) returns public.ride_requests language sql as $$
  select * from public.ride_requests where id = pg_temp.id(p_k) $$;

-- The place, the services and a fee at the pickup (lat 3.0..3.2, lng 101.5..101.7).
insert into public.countries (name, values) values ('Hireland 325', '{}');
insert into public.settings_entries (category, values, position) values
  ('vehicle-services', '{"name": "Hire Saloon 325", "status": true, "costPerKm": 2, "costPerMin": 0.3,
     "minFareAmount": 5, "hireEnabled": true, "hirePerHour": 40, "hireKmPerHour": 15,
     "hireOvertimePerHour": 50, "hireExtraKm": 1.2}', 9001),
  ('vehicle-services', '{"name": "No Hire 325", "status": true, "costPerKm": 1, "costPerMin": 0.2,
     "minFareAmount": 5}', 9002);
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000326e1', jsonb_build_object('name', 'Hire Plaza 325',
    'boundary', '{"bbox":{"north":3.2,"south":3.0,"east":101.7,"west":101.5}}'));
update public.airport_settings set fares_on = false, pick_door_required = false, drop_door_required = false,
       restrict_pickups = false
 where airport_id = '00000000-0000-0000-0000-0000000326e1';
delete from public.place_fees where area_id = '00000000-0000-0000-0000-0000000326e1';
insert into public.place_fees (area_id, name, applies_to, amount) values
  ('00000000-0000-0000-0000-0000000326e1', 'Plaza pickup fee', 'pickup', 5);

-- ---- 1. The quote --------------------------------------------------------------------------------------
select pg_temp.check(public.hourly_hire_config() @> '{"enabled": false, "allowNow": true, "allowLater": true,
  "minHours": 2, "maxHours": 12, "hourStep": 1, "stepMinutes": 30, "extendChoices": [30, 60, 120],
  "extendNeedsRider": true, "riderCanEndEarly": true, "earlyEndPays": "booked", "holdInWallet": true,
  "holdBufferPercent": 0, "allowCash": false, "kmPerHourDefault": 20, "reminderBeforeEndMin": 15,
  "autoEndAfterMin": 30, "tileTitle": "Hire a driver",
  "panelLabels": {"trip": "Go somewhere", "hire": "Hire by time"}}', 'the defaults');
select pg_temp.check(pg_temp.q(4)->>'reason' = 'HIRE_OFF', 'off until the admin turns it on');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a1',
  $q$select public.set_hourly_hire_config('{"enabled": true}')::text$q$) like 'NOT_ALLOWED%',
  'a rider can''t change the settings');
select pg_temp.cfg('{"enabled": true, "maxHours": 99, "hourStep": 0.3, "extendChoices": [30, 60, 120, 1]}');
select pg_temp.check(public.hourly_hire_config() @> '{"enabled": true, "maxHours": 72, "hourStep": 1,
  "extendChoices": [30, 60, 120]}', 'saved within the safe limits');
select pg_temp.cfg('{"enabled": true}');
select pg_temp.check(pg_temp.q(null) @> '{"available": true, "hours": 2, "rate": 40, "base": 80, "kmIncluded": 30,
  "overtimePerHour": 50, "extraKm": 1.2, "stepMinutes": 30}', 'the least hours: 2 × 40');
select pg_temp.check(pg_temp.q(4) @> '{"available": true, "base": 160, "placeFeesTotal": 5, "total": 165, "hold": 165}'
                     and pg_temp.q(4)->'placeFees' @> '[{"name": "Plaza pickup fee", "value": 5}]',
  'four hours, with the place fee at the pickup');
select pg_temp.check(pg_temp.q(1)->>'reason' = 'HIRE_HOURS' and pg_temp.q(13)->>'reason' = 'HIRE_HOURS'
                     and pg_temp.q(2.5)->>'reason' = 'HIRE_HOURS'
                     and pg_temp.q(1)->>'hint' = 'Choose between 2 and 12 hours.', 'hours out of range or step');
select pg_temp.check(pg_temp.q(4, 'No Hire 325')->>'reason' = 'HIRE_SERVICE_OFF', 'a service without hire');
select pg_temp.check(pg_temp.q(4, p_payment => 'Cash')->>'reason' = 'HIRE_CASH'
                     and (pg_temp.q(4, p_payment => 'Get Pay')->>'available')::boolean, 'cash refused');
update public.settings_entries set values = values || '{"hireMinHours": 3}'
 where category = 'vehicle-services' and values->>'name' = 'Hire Saloon 325';
select pg_temp.check(pg_temp.q(null) @> '{"hours": 3, "minHours": 3}' and pg_temp.q(2)->>'reason' = 'HIRE_HOURS',
  'the service''s own least hours');
update public.settings_entries set values = values - 'hireMinHours'
 where category = 'vehicle-services' and values->>'name' = 'Hire Saloon 325';
insert into public.fare_tariffs (level, country, hire_per_hour, hire_km_per_hour) values ('country', 'Hireland 325', 60, 10);
insert into public.fare_tariffs (level, country, state, city, hire_enabled) values ('city', 'Hireland 325', 'Negeri 325', 'Off Town 325', false);
select pg_temp.check(pg_temp.q(4) @> '{"rate": 60, "base": 240, "kmIncluded": 40, "overtimePerHour": 50}',
  'the country card''s rate over the service''s');
select pg_temp.check(pg_temp.q(4, p_city => 'Off Town 325')->>'reason' = 'HIRE_SERVICE_OFF', 'a city card switches it off');
delete from public.fare_tariffs where country = 'Hireland 325';

-- ---- 2. Booked now --------------------------------------------------------------------------------------
select pg_temp.set_bal('00000000-0000-0000-0000-0000000326a1', 500);
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a2', 4, 'Cash')) like 'HIRE_CASH%', 'booked in cash: refused');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a2', 1)) like 'HIRE_HOURS%', 'one hour: refused');
insert into t values ('h1', pg_temp.value_as('00000000-0000-0000-0000-0000000326a1',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a1', 4))::uuid);
select pg_temp.check((select fare = 160 and ride_fare = 160 and not offer_me and auto_accept_fare is null
                             and hire_hours = 4 and hire_rate = 40 and hire_km_included = 60
                             and hire_overtime_rate = 50 and hire_step_min = 30 and hire_extra_km_rate = 1.2
                             and (hire_quote->>'total')::numeric = 165 and option_names ? 'hire'
                             and charges @> '[{"name": "Plaza pickup fee", "value": 5}]'
                        from pg_temp.ride('h1')), 'the server''s price (160), not the app''s (1)');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a1',
  format('update public.ride_requests set fare = 2, ride_fare = 2 where id = %L returning 1', pg_temp.id('h1')))
  like 'HIRE_FIXED_FARE%', 'the rider can''t change the price');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a1',
  format('update public.ride_requests set hire_hours = 12, hire_rate = 1 where id = %L returning hire_hours::text',
         pg_temp.id('h1'))) = '4.0', 'nor the hours or rate');
select pg_temp.check(public.ride_amount_due(pg_temp.ride('h1')) = 165, 'due: the base and the place fee');

-- ---- 3. The hold ----------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000326a1') = 335
                     and (select amount = 165 and status = 'held' from public.hire_holds where ride_id = pg_temp.id('h1')),
  'the quote held from the GET.wallet: ' || pg_temp.bal('00000000-0000-0000-0000-0000000326a1'));
select pg_temp.check((select count(*) = 1 from public.wallet_transactions
                       where ride_id = pg_temp.id('h1') and kind = 'hire_hold' and amount = -165), 'the hold names the trip');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('h1');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000326a1') = 500
                     and (select status = 'returned' from public.hire_holds where ride_id = pg_temp.id('h1')),
  'cancelled: the hold comes back');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000326a1', 100);
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a1',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a1', 4)) like 'HIRE_BALANCE%', 'a short wallet: refused');
select pg_temp.cfg('{"enabled": true, "holdBufferPercent": 10}');
select pg_temp.check((pg_temp.q(4)->>'hold')::numeric = 181.5, 'the buffer on the hold');
select pg_temp.cfg('{"enabled": true, "allowCash": true}');

-- ---- 4. Extensions ---------------------------------------------------------------------------------------
insert into t values ('h2', pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a2', 4, 'Cash'))::uuid);
select pg_temp.check(not exists (select 1 from public.hire_holds where ride_id = pg_temp.id('h2')), 'cash: nothing held');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000326b1', status = 'accepted'
 where id = pg_temp.id('h2');
update public.ride_requests set status = 'on_trip' where id = pg_temp.id('h2');
select pg_temp.check((select hire_started_at is not null and hire_ends_at = hire_started_at + interval '4 hours'
                        from pg_temp.ride('h2')), 'the clock starts with the trip: four hours');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.hire_extend_ask(%L, 45)::text', pg_temp.id('h2'))) like 'HIRE_EXTEND_CHOICE%',
  'only the times offered');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a3',
  format('select public.hire_extend_ask(%L, 30)::text', pg_temp.id('h2'))) like 'not_authorized%',
  'a stranger can''t ask');
insert into t values ('e1', (pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.hire_extend_ask(%L, 30)::text', pg_temp.id('h2')))::jsonb->>'id')::uuid);
select pg_temp.check((select hire_extensions @> '[{"minutes": 30, "amount": 25, "asked_by": "driver", "status": "pending"}]'
                             and hire_ends_at = hire_started_at + interval '4 hours' from pg_temp.ride('h2')),
  'the driver''s ask waits for the rider (30 min: 25)');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000326a2'
                                and event_id = 'hire-ask-' || pg_temp.id('e1')), 'the rider is told');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.hire_extend_ask(%L, 60)::text', pg_temp.id('h2'))) like 'HIRE_EXTEND_PENDING%',
  'one waiting at a time');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.hire_extend_answer(%L, %L, true)::text', pg_temp.id('h2'), pg_temp.id('e1')))
  like 'not_authorized%', 'the driver can''t answer their own ask');
select pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  format('select public.hire_extend_answer(%L, %L, true)::text', pg_temp.id('h2'), pg_temp.id('e1')));
select pg_temp.check((select hire_ends_at = hire_started_at + interval '4 hours 30 minutes'
                             and hire_extensions @> '[{"status": "approved"}]' from pg_temp.ride('h2')),
  'approved: thirty minutes longer');
insert into t values ('e2', (pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.hire_extend_ask(%L, 60)::text', pg_temp.id('h2')))::jsonb->>'id')::uuid);
select pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  format('select public.hire_extend_answer(%L, %L, false)::text', pg_temp.id('h2'), pg_temp.id('e2')));
select pg_temp.check((select hire_ends_at = hire_started_at + interval '4 hours 30 minutes'
                             and hire_extensions @> '[{"minutes": 60, "status": "declined"}]' from pg_temp.ride('h2')),
  'declined: the end stays');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  format('select public.hire_extend_ask(%L, 60)::jsonb->>''status''', pg_temp.id('h2'))) = 'approved',
  'the rider''s own ask is approved at once');
select pg_temp.cfg('{"enabled": true, "allowCash": true, "extendNeedsRider": false}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.hire_extend_ask(%L, 30)::jsonb->>''status''', pg_temp.id('h2'))) = 'approved',
  'with the setting off, the driver''s too');
select pg_temp.check((select hire_ends_at = hire_started_at + interval '6 hours' from pg_temp.ride('h2')),
  'four hours and two approved');
select pg_temp.cfg('{"enabled": true, "allowCash": true}');

-- ---- 5. The end ------------------------------------------------------------------------------------------
select pg_temp.check(public.hire_overtime_amount(30, 30, 50) = 25 and public.hire_overtime_amount(31, 30, 50) = 50
                     and public.hire_overtime_amount(1, 30, 50) = 25 and public.hire_overtime_amount(0, 30, 50) = 0,
  'overtime in started steps');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('update public.ride_requests set status = ''completed'' where id = %L returning 1', pg_temp.id('h2')))
  like 'HIRE_END_USE%', 'the app ends a hire with End hire, not a plain completion');
-- Five hours ten minutes in: 70 minutes past the four hours, billed as 90.
update public.ride_requests set hire_started_at = now() - interval '5 hours 10 minutes',
       hire_ends_at = now() + interval '50 minutes' where id = pg_temp.id('h2');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a3',
  format('select public.hire_end(%L, 10)::text', pg_temp.id('h2'))) like 'not_authorized%', 'a stranger can''t end it');
select pg_temp.value_as('00000000-0000-0000-0000-0000000326b1', format('select public.hire_end(%L, 102.5)::text', pg_temp.id('h2')));
-- km included: 4 × 15 + 2 approved hours × 15 = 90; 12.5 more at 1.2 = 15.
select pg_temp.check((select status = 'completed' and completed_at is not null and fare = 250 and ride_fare = 250
                             and hire_km_used = 102.5
                             and hire_settled @> '{"base": 160, "overtimeMinutes": 90, "overtime": 75,
                                                   "kmIncluded": 90, "extraKm": 12.5, "extraKmAmount": 15,
                                                   "endedBy": "driver", "earlyEnd": false}'
                             and hire_settled->'lines' @> '[{"label": "Hourly hire 4 hr", "amount": 160},
                                                            {"label": "Overtime 90 min", "amount": 75},
                                                            {"label": "Extra km 12.5 km", "amount": 15}]'
                        from pg_temp.ride('h2')), 'settled: 160 + 75 overtime + 15 extra km');
select pg_temp.check(public.ride_amount_due(pg_temp.ride('h2')) = 255, 'the place fee is still charged');
select pg_temp.check(public.statement_ride_lines(pg_temp.ride('h2'), '{}')->'hire'
                     @> '[{"label": "Overtime 90 min", "amount": 75}]', 'statements carry the hire lines');
-- Early ends: one hour into four, least two.
insert into t values ('h3', pg_temp.value_as('00000000-0000-0000-0000-0000000326a3',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a3', 4, 'Cash'))::uuid);
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000326b1', status = 'accepted' where id = pg_temp.id('h3');
update public.ride_requests set status = 'on_trip' where id = pg_temp.id('h3');
update public.ride_requests set hire_started_at = now() - interval '1 hour' where id = pg_temp.id('h3');
select pg_temp.check((public.hire_settle(pg_temp.ride('h3'), 10, now(), 'x')->>'fare')::numeric = 160, 'early end: the booked hours');
select pg_temp.cfg('{"enabled": true, "allowCash": true, "earlyEndPays": "minimum"}');
select pg_temp.check((public.hire_settle(pg_temp.ride('h3'), 10, now(), 'x')->>'fare')::numeric = 80, 'early end: the least hours');
select pg_temp.cfg('{"enabled": true, "allowCash": true, "earlyEndPays": "used"}');
select pg_temp.check((public.hire_settle(pg_temp.ride('h3'), 10, now(), 'x')->>'fare')::numeric = 40, 'early end: the hours used');
select pg_temp.value_as('00000000-0000-0000-0000-0000000326a3', format('select public.hire_end(%L, 999)::text', pg_temp.id('h3')));
select pg_temp.check((select status = 'completed' and fare = 40 and ended_early_at is not null
                             and hire_settled @> '{"endedBy": "rider", "kmUsed": 0}' from pg_temp.ride('h3')),
  'the rider ends it early; their km figure is not taken');
select pg_temp.cfg('{"enabled": true, "allowCash": true, "riderCanEndEarly": false}');

-- ---- 6. Booked for later ----------------------------------------------------------------------------------
create or replace function pg_temp.schedule(p_rider uuid, p_at timestamptz, p_hire boolean, p_partner uuid default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, fare, status,
                                      partner_id)
  values (p_rider, p_at,
          jsonb_build_object('service', 'Hire Saloon 325', 'pickup_lat', 3.10, 'pickup_lng', 101.60, 'fare', 7,
                             'ride_fare', 7, 'payment_mode', 'Cash', 'country', 'Hireland 325', 'state', 'Negeri 325')
          || case when p_hire then '{"hire_package": "hourly", "hire_hours": 3}'::jsonb else '{}'::jsonb end,
          'Hire Saloon 325', 3.10, 101.60, 7, case when p_partner is null then 'scheduled' else 'assigned' end, p_partner)
  returning id into v;
  return v;
end $$;
insert into t values ('s1', pg_temp.schedule('00000000-0000-0000-0000-0000000326a4', now() + interval '2 hours', true));
select pg_temp.check((select fare = 120 and hire_package = 'hourly' and hire_hours = 3
                             and request @> '{"fare": 120, "offer_me": false, "hire_hours": 3}'
                             and request->'hire_quote' @> '{"base": 120, "total": 125}'
                             and request->'option_names' ? 'hire'
                        from public.scheduled_rides where id = pg_temp.id('s1')), 'booked for later at the server''s price');
update public.settings_entries set values = values || '{"hirePerHour": 99}'
 where category = 'vehicle-services' and values->>'name' = 'Hire Saloon 325';
insert into t values ('r1', public.scheduled_ride_release(pg_temp.id('s1')));
select pg_temp.check((select fare = 120 and hire_rate = 40 and hire_quote @> '{"base": 120}' and hire_package = 'hourly'
                        from pg_temp.ride('r1')), 'released at the price it was booked at, though the rate is 99 now');
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('r1');
update public.settings_entries set values = values || '{"hirePerHour": 40}'
 where category = 'vehicle-services' and values->>'name' = 'Hire Saloon 325';
-- The driver's hire from +10h to +13h; a ride at +13h30 clashes (half an hour after it ends), +14h30 doesn't.
insert into t values ('s2', pg_temp.schedule('00000000-0000-0000-0000-0000000326a4', now() + interval '10 hours', true,
                                             '00000000-0000-0000-0000-0000000326b1'));
insert into t values ('s3', pg_temp.schedule('00000000-0000-0000-0000-0000000326a3', now() + interval '13 hours 30 minutes', false));
insert into t values ('s4', pg_temp.schedule('00000000-0000-0000-0000-0000000326a3', now() + interval '14 hours 30 minutes', false));
select pg_temp.check(public.scheduled_partner_clash('00000000-0000-0000-0000-0000000326b1',
                       now() + interval '13 hours 30 minutes', pg_temp.id('s3'))
                     and not public.scheduled_partner_clash('00000000-0000-0000-0000-0000000326b1',
                       now() + interval '14 hours 30 minutes', pg_temp.id('s4')),
  'a ride after the hire clashes within an hour of its end');
-- The other way: a ride at +20h taken; a three-hour hire from +17h30 runs into it.
update public.scheduled_rides set partner_id = '00000000-0000-0000-0000-0000000326b2', status = 'assigned',
       pickup_at = now() + interval '20 hours' where id = pg_temp.id('s4');
insert into t values ('s5', pg_temp.schedule('00000000-0000-0000-0000-0000000326a2', now() + interval '17 hours 30 minutes', true));
insert into t values ('s6', pg_temp.schedule('00000000-0000-0000-0000-0000000326a2', now() + interval '15 hours', true));
select pg_temp.check(public.scheduled_partner_clash('00000000-0000-0000-0000-0000000326b2',
                       now() + interval '17 hours 30 minutes', pg_temp.id('s5'))
                     and not public.scheduled_partner_clash('00000000-0000-0000-0000-0000000326b2',
                       now() + interval '15 hours', pg_temp.id('s6')),
  'a hire that would run into a ride clashes; one that ends an hour before doesn''t');
select pg_temp.check(not public.scheduled_partner_clash('00000000-0000-0000-0000-0000000326b2',
                       now() + interval '18 hours 30 minutes', '00000000-0000-0000-0000-000000000000')
                     and public.scheduled_partner_clash('00000000-0000-0000-0000-0000000326b2',
                       now() + interval '19 hours 30 minutes', '00000000-0000-0000-0000-000000000000'),
  'two plain rides: an hour apart, as before');
select pg_temp.cfg('{"enabled": true, "allowCash": true, "allowLater": false}');
do $$
begin
  perform pg_temp.schedule('00000000-0000-0000-0000-0000000326a4', now() + interval '3 hours', true);
  raise exception 'FAILED: later switched off';
exception when others then
  if sqlerrm not like 'HIRE_LATER_OFF%' then
    raise;
  end if;
end $$;
select pg_temp.cfg('{"enabled": true, "allowCash": true, "allowNow": false}');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a4',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a4', 4, 'Cash')) like 'HIRE_NOW_OFF%', 'now switched off');
select pg_temp.cfg('{"enabled": true, "allowCash": true}');

-- The drivers' lists keep 0325's place_fees and add the hire's package and hours.
select pg_temp.check((select array_agg(column_name order by column_name)
                        from (select unnest(proargnames) as column_name from pg_proc
                               where proname = p.n and pronamespace = 'public'::regnamespace) x
                       where column_name in ('place_fees', 'hire_package', 'hire_hours'))
                     = '{hire_hours,hire_package,place_fees}', p.n || ' carries place_fees and the hire columns')
  from (values ('scheduled_rides_open'), ('scheduled_rides_upcoming'), ('scheduled_ride_offers_open')) p(n);

-- ---- 7. The tick -----------------------------------------------------------------------------------------
insert into t values ('h4', pg_temp.value_as('00000000-0000-0000-0000-0000000326a4',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a4', 2, 'Cash'))::uuid);
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000326b1', status = 'accepted' where id = pg_temp.id('h4');
update public.ride_requests set status = 'on_trip' where id = pg_temp.id('h4');
update public.ride_requests set hire_started_at = now() - interval '1 hour 50 minutes',
       hire_ends_at = now() + interval '10 minutes' where id = pg_temp.id('h4');
select public.hire_tick();
select pg_temp.check((select hire_reminded_at is not null and status = 'on_trip' from pg_temp.ride('h4'))
                     and (select count(*) = 2 from public.notification_outbox where event_id like 'hire-remind-' || pg_temp.id('h4') || '%'),
  'both told ten minutes before the end');
update public.ride_requests set hire_started_at = now() - interval '2 hours 31 minutes',
       hire_ends_at = now() - interval '31 minutes' where id = pg_temp.id('h4');
select pg_temp.check(public.hire_tick() >= 1, 'the tick ends it');
select pg_temp.check((select status = 'completed' and fare = 80 and hire_settled->>'endedBy' = 'auto' from pg_temp.ride('h4')),
  'ended by the server at the booked hours');

-- ---- 8. Twelve hours on the go -----------------------------------------------------------------------------
insert into t values ('h5', pg_temp.value_as('00000000-0000-0000-0000-0000000326a4',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a4', 12, 'Cash'))::uuid);
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000326b2', status = 'accepted' where id = pg_temp.id('h5');
update public.ride_requests set status = 'on_trip' where id = pg_temp.id('h5');
alter table public.ride_requests disable trigger trg_ride_requests_updated_at;
update public.ride_requests set updated_at = now() - interval '13 hours', hire_started_at = now() - interval '11 hours 30 minutes',
       hire_ends_at = now() + interval '30 minutes' where id = pg_temp.id('h5');
alter table public.ride_requests enable trigger trg_ride_requests_updated_at;
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326a4',
  $q$insert into public.ride_requests (rider_id, status, service, payment_mode, pickup_lat, pickup_lng, fare, ride_fare, country)
     values ('00000000-0000-0000-0000-0000000326a4', 'open', 'Hire Saloon 325', 'Cash', 3.1, 101.6, 10, 10, 'Hireland 325')
     returning 1$q$) like 'RIDE_REQUEST_DUPLICATE%', 'a 12-hour hire is still on the go after 12 hours');
select pg_temp.check(public.dispatch_driver_busy('00000000-0000-0000-0000-0000000326b2'), 'its driver is busy');
alter table public.ride_requests disable trigger trg_ride_requests_updated_at;
update public.ride_requests set updated_at = now() - interval '13 hours', hire_ends_at = now() - interval '31 minutes'
 where id = pg_temp.id('h5');
alter table public.ride_requests enable trigger trg_ride_requests_updated_at;
select pg_temp.check(not public.dispatch_driver_busy('00000000-0000-0000-0000-0000000326b2'),
  'past its end and the auto-end: not held');

-- ---- 9. Drivers --------------------------------------------------------------------------------------------
select pg_temp.check(not public.driver_takes_hire('00000000-0000-0000-0000-0000000326b1'), 'off by default');
insert into public.driver_ride_extras (driver_id, takes_hire) values ('00000000-0000-0000-0000-0000000326b1', true);
select pg_temp.check(public.driver_takes_hire('00000000-0000-0000-0000-0000000326b1')
                     and not public.driver_takes_hire('00000000-0000-0000-0000-0000000326b2'), 'the driver''s switch');
select pg_temp.check(public.ride_extra_keys(null, null, '{"hire": "Hourly hire"}', 1) = '{hire}'
                     and public.driver_takes_extras('00000000-0000-0000-0000-0000000326b1', '{hire}')
                     and not public.driver_takes_extras('00000000-0000-0000-0000-0000000326b2', '{hire}'),
  'offered only to drivers who take hire');
do $$
begin
  update public.scheduled_rides set partner_id = '00000000-0000-0000-0000-0000000326b2', status = 'assigned'
   where id = (select id from t where k = 's6');
  raise exception 'FAILED: a driver who doesn''t take hire took a booked hire';
exception when others then
  if sqlerrm not like 'HIRE_DRIVER_OFF%' then
    raise;
  end if;
end $$;
insert into t values ('h6', pg_temp.value_as('00000000-0000-0000-0000-0000000326a3',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326a3', 3, 'Cash'))::uuid);
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326b1',
  format('select public.my_takes_hire()::text')) = 'true', 'the driver reads their switch');
do $$
begin
  insert into public.ride_offers (request_id, partner_id, amount, expires_at)
  values ((select id from t where k = 'h6'), '00000000-0000-0000-0000-0000000326b1', 50, now() + interval '1 minute');
  raise exception 'FAILED: a counter-offer on a hire';
exception when others then
  if sqlerrm not like 'HIRE_FIXED_FARE%' then
    raise;
  end if;
end $$;
insert into t values ('n1', pg_temp.value_as('00000000-0000-0000-0000-0000000326a2',
  $q$insert into public.ride_requests (rider_id, status, service, payment_mode, pickup_lat, pickup_lng,
       fare, ride_fare, country, option_names, hire_hours)
     values ('00000000-0000-0000-0000-0000000326a2', 'open', 'Hire Saloon 325', 'Cash', 3.1, 101.6,
             10, 10, 'Hireland 325', '{"hire": "x"}', 4) returning id::text$q$)::uuid);
select pg_temp.check((select option_names is null and hire_hours is null and fare = 10 from pg_temp.ride('n1')),
  'a normal ride can''t ask for hire drivers or carry hire terms');

-- ---- 10. Family -------------------------------------------------------------------------------------------
select pg_temp.check(exists (select 1 from public.booking_modules where key = 'hire'), 'the hire module is registered');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326f1',
  $q$select public.family_invite('{"country": "Hireland 325"}', '+60100032622', 'Hana', 'daughter')->>'id'$q$)
  ~ '^[0-9a-f-]{36}$', 'the host invites the member');
insert into t select 'm', id from public.family_members
 where family_id = (select id from public.families where host_id = '00000000-0000-0000-0000-0000000326f1');
select pg_temp.value_as('00000000-0000-0000-0000-0000000326f2',
  format('select public.family_respond(%L, true, ''{"shown": ["payments"]}'')', pg_temp.id('m')));
insert into public.family_module_rules (level, module_key, family_pays, book_for_member, child_allowed, live_share)
values ('default', 'hire', true, true, false, true)
on conflict (place_key, module_key) do update set family_pays = true, book_for_member = true;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000326f1', 400);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000326f2', 0);
insert into t values ('h7', pg_temp.value_as('00000000-0000-0000-0000-0000000326f2',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326f2', 2, 'Family'))::uuid);
select pg_temp.check((select module_key = 'hire' and family_pays from public.family_trips where trip_id = pg_temp.id('h7')),
  'the member''s hire is the family''s, module hire');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000326f1') = 315
                     and pg_temp.bal('00000000-0000-0000-0000-0000000326f2') = 0
                     and (select sum(amount) = 85 from public.family_spend where trip_id = pg_temp.id('h7')),
  'the hold from the host''s GET.wallet: ' || pg_temp.bal('00000000-0000-0000-0000-0000000326f1'));
update public.ride_requests set status = 'cancelled' where id = pg_temp.id('h7');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000326f1') = 400
                     and pg_temp.bal('00000000-0000-0000-0000-0000000326f2') = 0,
  'cancelled: back to the host');
-- Paid at the end: the hold back, then the settled amount from the host.
insert into t values ('h8', pg_temp.value_as('00000000-0000-0000-0000-0000000326f2',
  pg_temp.book_sql('00000000-0000-0000-0000-0000000326f2', 2, 'Family'))::uuid);
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000326b1', status = 'accepted' where id = pg_temp.id('h8');
update public.ride_requests set status = 'on_trip' where id = pg_temp.id('h8');
select public.hire_finish(pg_temp.id('h8'), 20, 'driver');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000326f2',
  format('select public.ride_pay(%L, ''family'')::text', pg_temp.id('h8'))) like '{%', 'the member pays with Family');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000326f1') = 315
                     and pg_temp.bal('00000000-0000-0000-0000-0000000326f2') = 0
                     and (select status = 'returned' from public.hire_holds where ride_id = pg_temp.id('h8')),
  'paid: the hold back and 85 from the host: ' || pg_temp.bal('00000000-0000-0000-0000-0000000326f1'));

rollback;
