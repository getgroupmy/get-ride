-- ============================================================================
-- Regression test for migration 0310: City to City per-seat trips.
--   * seat rules: the Default always there, a region rule overriding only
--     what it sets, the most specific active region wins, the grants (the
--     seats page and City to City's), the Default never removed;
--   * the seat price limits (% of the whole-car fare, RM, a route's fixed
--     price or range, the region's fixed price, driver free), door pickup's
--     extra and the repeat dates, the app's twins' cases;
--   * posting: off where Per-seat trips are off, approved drivers only, the
--     price inside the limits, women only for a verified woman where
--     allowed, door pickup and parcels where allowed, busy, repeats;
--   * search and booking: seats left, the cut-off, women only, names for
--     several seats, door pickup's extra and its limit, parcels, no
--     overbooking, one booking a rider and trip, the instant booking's
--     commission locked, in-app payment held at request and given back when
--     declined or lapsed;
--   * the trip: approve and decline, start and finish (each seat charged
--     and paid), the driver cancelling (the give-up fee per booked rider),
--     a single seat not given up alone, reminders naming the driver, chat on
--     a request, co-riders;
--   * a verified ID's gender locked; riders can't insert seat rows;
--   * rider blocks (0311): the blocked driver doesn't see, approve or chat
--     on the request, it's withdrawn, the rider can't find or book his trips.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/city_to_city_seats_0310.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000310a1'),  -- admin, EDIT on per-seat trips
  ('00000000-0000-0000-0000-0000000310a2'),  -- admin, READ on per-seat trips
  ('00000000-0000-0000-0000-0000000310b1'),  -- driver, a man
  ('00000000-0000-0000-0000-0000000310b2'),  -- driver, a verified woman
  ('00000000-0000-0000-0000-0000000310c1'),  -- rider, a man
  ('00000000-0000-0000-0000-0000000310c2'),  -- rider, a verified woman
  ('00000000-0000-0000-0000-0000000310c3'),  -- rider, a woman, ID not verified
  ('00000000-0000-0000-0000-0000000310c4')   -- rider
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test 310' from auth.users
 where id::text like '00000000-0000-0000-0000-0000000310%'
on conflict (id) do update set name = excluded.name;  -- the sign-up trigger may have made the row
update public.profiles set name = 'Hafiz Rahman', gender = 'male' where id = '00000000-0000-0000-0000-0000000310b1';
update public.profiles set name = 'Nurul Aina', gender = 'female' where id = '00000000-0000-0000-0000-0000000310b2';
update public.profiles set name = 'Wei Ming Contoh', gender = 'male', phone = '+60100031001'
 where id = '00000000-0000-0000-0000-0000000310c1';
update public.profiles set name = 'Aina Contoh', gender = 'female', id_verified = 'Verified', phone = '+60100031002'
 where id = '00000000-0000-0000-0000-0000000310c2';
update public.profiles set name = 'Siti Contoh', gender = 'female' where id = '00000000-0000-0000-0000-0000000310c3';
update public.profiles set name = 'Kumar Contoh', gender = 'male' where id = '00000000-0000-0000-0000-0000000310c4';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000310a1', 'admin-settings-city-to-city-seats', 'edit'),
  ('00000000-0000-0000-0000-0000000310a2', 'admin-settings-city-to-city-seats', 'read')
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
create or replace function pg_temp.value_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql into v;
  perform pg_temp.as_server();
  return v;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create or replace function pg_temp.bal(p_user uuid, p_type text default 'get_wallet') returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p_user and wallet_type = p_type), 0);
$$;
create or replace function pg_temp.set_bal(p_user uuid, p_to numeric, p_type text default 'get_wallet') returns void
language plpgsql as $$
begin
  if p_to <> pg_temp.bal(p_user, p_type) then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (p_user, p_type, 'test_adjust', p_to - pg_temp.bal(p_user, p_type), 'test 0310');
  end if;
end $$;

-- ---- Places, the service, drivers ----------------------------------------------------------------------
create or replace function pg_temp.kl() returns jsonb language sql as $$
  select '{"country": "Semenanjung 310", "state": "Kuala Lumpur 310", "city": "Kuala Lumpur 310", "suburb": "Cheras 310"}'::jsonb;
$$;
create or replace function pg_temp.ipoh() returns jsonb language sql as $$
  select '{"country": "Semenanjung 310", "state": "Perak 310", "city": "Ipoh 310"}'::jsonb;
$$;
-- A trip as c2c_post_trip takes it.
create or replace function pg_temp.from_end() returns jsonb language sql as $$
  select jsonb_build_object('name', 'Kuala Lumpur 310', 'lat', 3.15, 'lng', 101.71, 'place', pg_temp.kl());
$$;
create or replace function pg_temp.to_end() returns jsonb language sql as $$
  select jsonb_build_object('name', 'Ipoh 310', 'lat', 4.60, 'lng', 101.09, 'place', pg_temp.ipoh());
$$;
create or replace function pg_temp.points() returns jsonb language sql as $$
  select '[{"name": "Petrol station 310", "lat": 3.13, "lng": 101.72, "minutes": 0},
           {"name": "Bus stop 310", "lat": 3.15, "lng": 101.70, "minutes": 15}]'::jsonb;
$$;
-- Posts a trip as [p_driver] leaving at [p_at]; the call's text.
create or replace function pg_temp.post(p_driver uuid, p_at timestamptz, p_extra text default '', p_price numeric default 45)
returns text language sql as $$
  select pg_temp.value_as(p_driver, format(
    'select public.c2c_post_trip(%L::jsonb, %L::jsonb, 205, 150, %L::timestamptz, %L::jsonb, 3, %s%s)::text',
    pg_temp.from_end(), pg_temp.to_end(), p_at, pg_temp.points(), p_price, p_extra));
$$;

update public.settings_entries set values = values || '{"status": true}'
 where category = 'vehicle-services' and values->>'name' = 'City to City';
insert into public.countries (name, values) values ('Semenanjung 310', '{}');
update public.city_to_city_settings
   set cancel_fee_on = true, cancel_fee_amount = 20, cancel_free_hours = 24, pay_in_app = true, pay_cash = true,
       min_years_on = true, min_years = 3, default_book_ahead_days = 14,
       owed_from_topup = false, owed_next_in_app = false, owed_cash_collect = false, owed_block = false,
       reminders_on = true, reminder_push = true, reminder_inbox = true, reminder_sms = false,
       reminders = '[{"minutes": 120, "to": "both"}]'
 where id = 1;
-- The whole car, Kuala Lumpur to Perak: a fixed RM 140, as on the board.
insert into public.c2c_route_rules (from_places, to_places, fare_mode, fixed_fare, range_mode, book_ahead_days, position)
values ('[{"level": "city", "country": "Semenanjung 310", "state": "Kuala Lumpur 310", "city": "Kuala Lumpur 310"}]',
        '[{"level": "state", "country": "Semenanjung 310", "state": "Perak 310"}]', 'fixed', 140, 'auto', 14, 1);
insert into public.commission_service_rates (service_id, service_name, rate)
select id::text, 'City to City', 0.12 from public.settings_entries
 where category = 'vehicle-services' and values->>'name' = 'City to City'
on conflict (service_id) do update set rate = 0.12, active = true;
update public.get_coin_settings set coins_per_currency = 100 where id = 'master';
insert into public.get_coin_settings (id, coins_per_currency) select 'master', 100
 where not exists (select 1 from public.get_coin_settings where id = 'master');

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries, service_states,
                             rating, total_rides, make, model, plate) values
  ('00000000-0000-0000-0000-0000000310e1', '00000000-0000-0000-0000-0000000310b1', 'Hafiz Rahman', '+60100031091',
   'approved', '{eHailing}', '{Semenanjung 310}', '{Semenanjung 310|Kuala Lumpur 310}', 4.9, 300, 'Honda', 'City', 'VKB 5512'),
  ('00000000-0000-0000-0000-0000000310e2', '00000000-0000-0000-0000-0000000310b2', 'Nurul Aina', '+60100031092',
   'approved', '{eHailing}', '{Semenanjung 310}', '{Semenanjung 310|Kuala Lumpur 310}', 4.9, 120, 'Perodua', 'Bezza', 'WA 310');
update public.partners set driving_since = current_date - interval '10 years'
 where id in ('00000000-0000-0000-0000-0000000310e1', '00000000-0000-0000-0000-0000000310e2');

create temp table t (k text primary key, id uuid);
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from t where k = p_k $$;

-- ==== 1. Seat rules ======================================================================================
select pg_temp.check((select count(*) = 1 from public.c2c_seat_rules where place is null), 'the Default is seeded');
select pg_temp.check((public.c2c_seat_terms_for(pg_temp.kl())->>'seats_on')::boolean = false,
                     'Per-seat trips start off');
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days') like 'C2C_SEATS_OFF%',
                     'no posting while off');

-- Only admins with EDIT (the seats page, or City to City's) write.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310c1',
  $q$update public.c2c_seat_rules set seats_on = true where place is null$q$) = 'ok 0', 'a rider can''t change the rules');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310a2',
  $q$update public.c2c_seat_rules set seats_on = true where place is null$q$) = 'ok 0', 'READ can''t change the rules');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310a1',
  $q$update public.c2c_seat_rules set seats_on = true where place is null$q$) = 'ok 1', 'EDIT on the seats page can');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310a1',
  $q$delete from public.c2c_seat_rules where place is null$q$) like 'C2C_DEFAULT_RULE%', 'the Default stays');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310a1',
  $q$insert into public.c2c_seat_rules (place, join_mode) values ('{"level": "state", "country": "Semenanjung 310", "state": "Kuala Lumpur 310"}', 'approve')$q$)
  like '%c2c_seat_rules_join%', 'a part is set whole');

-- A state rule sets only how riders join; a suburb rule only the cut-off; an
-- inactive city rule is skipped.
insert into public.c2c_seat_rules (place, join_mode, approve_hours, approve_before_min) values
  ('{"level": "state", "country": "Semenanjung 310", "state": "Kuala Lumpur 310"}', 'approve', 3, 90);
insert into public.c2c_seat_rules (place, max_seats, max_per_booking, cutoff_min, post_ahead_days) values
  ('{"level": "suburb", "country": "Semenanjung 310", "state": "Kuala Lumpur 310", "city": "Kuala Lumpur 310", "suburb": "Cheras 310"}',
   3, 2, 30, 20);
insert into public.c2c_seat_rules (place, active, seats_on) values
  ('{"level": "city", "country": "Semenanjung 310", "state": "Kuala Lumpur 310", "city": "Kuala Lumpur 310"}', false, false);
do $$
declare
  v jsonb := public.c2c_seat_terms_for(pg_temp.kl());
begin
  perform pg_temp.check((v->>'seats_on')::boolean, 'the inactive city rule is skipped: on from the Default');
  perform pg_temp.check(v->>'join_mode' = 'approve' and (v->>'approve_hours')::int = 3
                        and (v->>'approve_before_min')::int = 90, 'join from the state rule');
  perform pg_temp.check((v->>'cutoff_min')::int = 30 and (v->>'max_seats')::int = 3, 'limits from the suburb rule');
  perform pg_temp.check(v->>'price_mode' = 'range' and (v->>'pct_low')::numeric = 25, 'price from the Default');
  perform pg_temp.check(jsonb_array_length(v->'ruleIds') = 3, 'three rules apply, most specific first');
  v := public.c2c_seat_terms_for(pg_temp.ipoh());
  perform pg_temp.check(v->>'join_mode' = 'driver_picks' and (v->>'max_seats')::int = 4, 'elsewhere: the Default');
end $$;
-- The rest of the test runs on the Default's own choices.
delete from public.c2c_seat_rules where place is not null;
update public.c2c_seat_rules set seats_on = true, women_on = false where place is null;

-- ==== 2. Limits, door pickup, repeats (the app's twins' cases) ============================================
do $$
declare
  rr public.c2c_route_rules;
  terms jsonb := public.c2c_seat_terms_for(pg_temp.kl());
  v jsonb;
begin
  v := public.c2c_seat_limits(terms, 3.15, 101.71, pg_temp.kl(), pg_temp.ipoh(), 205, 150);
  perform pg_temp.check(v->>'mode' = 'range' and (v->>'low')::numeric = 35 and (v->>'high')::numeric = 56
                        and (v->>'wholeCar')::numeric = 140, '25% to 40% of RM 140: RM 35 to RM 56 ' || v::text);
  v := public.c2c_seat_limits_of(terms || '{"range_mode": "amount"}', rr, 140);
  perform pg_temp.check((v->>'low')::numeric = 30 and (v->>'high')::numeric = 60, 'RM min and max');
  v := public.c2c_seat_limits_of(terms || '{"price_mode": "fixed"}', rr, 140);
  perform pg_temp.check(v->>'mode' = 'fixed' and (v->>'price')::numeric = 46, 'the region''s fixed price: the middle');
  v := public.c2c_seat_limits_of(terms || '{"price_mode": "free"}', rr, 140);
  perform pg_temp.check(v->>'mode' = 'free' and (v->>'low')::numeric = 1 and v->'high' = 'null'::jsonb, 'driver free');
  rr.id := gen_random_uuid(); rr.fare_mode := 'card'; rr.range_mode := 'set'; rr.range_low := 40; rr.range_high := 50;
  v := public.c2c_seat_limits_of(terms, rr, 140);
  perform pg_temp.check((v->>'low')::numeric = 40 and (v->>'high')::numeric = 50, 'a route''s RM range');
  rr.fare_mode := 'fixed'; rr.fixed_fare := 45;
  v := public.c2c_seat_limits_of(terms, rr, 140);
  perform pg_temp.check(v->>'mode' = 'fixed' and (v->>'price')::numeric = 45, 'a route''s fixed price');
  v := public.c2c_seat_limits_of(terms || '{"price_mode": "free"}', rr, 140);
  perform pg_temp.check(v->>'mode' = 'free', 'driver free stays free');
  v := public.c2c_seat_limits_of(terms, rr, 0);
  perform pg_temp.check(v->>'mode' = 'fixed', 'a fixed route with no fare card');
  rr := null;
  v := public.c2c_seat_limits_of(terms, rr, 2);
  perform pg_temp.check((v->>'low')::numeric = 1 and (v->>'high')::numeric = 1, 'never below RM 1');
end $$;
select pg_temp.check(public.c2c_door_extra(2.44, 1) = 2.40 and public.c2c_door_extra(2.45, 1) = 2.50
                     and public.c2c_door_extra(3.1, 1.5) = 4.65 and public.c2c_door_extra(0, 1) = 0, 'door extra');
select pg_temp.check((select array_agg(d order by d) from public.c2c_repeat_dates('2026-10-31 08:00', 'weekly', '2026-11-21') d)
                     = array['2026-11-07 08:00', '2026-11-14 08:00', '2026-11-21 08:00']::timestamp[], 'weekly');
select pg_temp.check((select array_agg(d order by d) from public.c2c_repeat_dates('2026-10-30 07:30', 'weekdays', '2026-11-04') d)
                     = array['2026-11-02 07:30', '2026-11-03 07:30', '2026-11-04 07:30']::timestamp[], 'weekdays');
select pg_temp.check((select count(*) from public.c2c_repeat_dates('2026-10-30 07:30', 'daily', '2026-11-01')) = 2, 'daily');
select pg_temp.check((select count(*) from public.c2c_repeat_dates('2026-10-30 07:30', 'daily', '2027-12-01', 60)) = 60,
                     'at most 60');

-- ==== 3. Posting ===========================================================================================
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310c1', now() + interval '3 days') like 'C2C_NOT_A_DRIVER%',
                     'riders can''t post');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_post_trip(%L::jsonb, %L::jsonb, 205, 150, now() + interval ''3 days'', %L::jsonb, 3, 60)::text',
  pg_temp.from_end(), pg_temp.to_end(), pg_temp.points())) like 'C2C_FARE_OUT_OF_RANGE%', 'the price inside RM 35 to 56');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_post_trip(%L::jsonb, %L::jsonb, 205, 150, now() + interval ''3 days'', %L::jsonb, 9, 45)::text',
  pg_temp.from_end(), pg_temp.to_end(), pg_temp.points())) like 'C2C_TOO_MANY_SEATS%', 'seats within the limit');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_post_trip(%L::jsonb, %L::jsonb, 20, 150, now() + interval ''3 days'', %L::jsonb, 3, 45)::text',
  pg_temp.from_end(), pg_temp.to_end(), pg_temp.points())) like 'C2C_BAD_TRIP%', 'not shorter than the straight line');
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b2', now() + interval '3 days', ', p_women_only => true')
                     like 'C2C_WOMEN_ONLY%', 'women only off in the rule');
update public.c2c_seat_rules set women_on = true where place is null;
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days', ', p_women_only => true')
                     like 'C2C_WOMEN_ONLY%', 'a man can''t post women only');
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days',
                                  ', p_parcel_slots => 1, p_parcel_size => ''small'', p_parcel_price => 10')
                     like 'C2C_NO_PARCELS%', 'parcels off in the rule');
update public.c2c_seat_rules set door_on = false where place is null;
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days', ', p_door => true')
                     like 'C2C_DOOR_OFF%', 'door pickup off in the rule');
update public.c2c_seat_rules set door_on = true, parcels_on = true where place is null;
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days',
                                  ', p_parcel_slots => 1, p_parcel_size => ''large'', p_parcel_price => 10')
                     like 'C2C_NO_PARCELS%', 'parcels up to the biggest size');

-- Trip A: instant, door pickup, a parcel slot (Hafiz). Trip B: driver
-- approves, women only (Nurul).
insert into t select 'A', (pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days',
  ', p_join => ''instant'', p_door => true, p_parcel_slots => 1, p_parcel_size => ''small'', p_parcel_price => 15')::jsonb->'ids'->>0)::uuid;
insert into t select 'B', (pg_temp.post('00000000-0000-0000-0000-0000000310b2', now() + interval '4 days',
  ', p_join => ''approve'', p_women_only => true', 40)::jsonb->'ids'->>0)::uuid;
select pg_temp.check(pg_temp.id('A') is not null and pg_temp.id('B') is not null, 'two trips posted');
select pg_temp.check((select seat_price = 45 and join_mode = 'instant' and door_pickup and door_max_km = 5
                             and door_per_km = 1 and from_place->>'city' = 'Kuala Lumpur 310'
                             and driver_name = 'Hafiz Rahman' and plate = 'VKB 5512'
                        from public.c2c_trips where id = pg_temp.id('A')), 'trip A as posted');
select pg_temp.check((select seat_price = 40 and join_mode = 'approve' and women_only
                        from public.c2c_trips where id = pg_temp.id('B')), 'trip B as posted');
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '3 days 1 hour')
                     like 'C2C_DRIVER_BUSY%', 'not two trips at once');
-- A weekly repeat: 3 more trips.
select pg_temp.check((pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '10 days',
  format(', p_repeat => ''weekly'', p_repeat_until => %L::date',
         ((now() + interval '31 days') at time zone 'Asia/Kuala_Lumpur')::date))::jsonb->>'posted')::int = 4, 'weekly x 4');
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '20 days',
  format(', p_repeat => ''weekly'', p_repeat_until => %L::date',
         ((now() + interval '200 days') at time zone 'Asia/Kuala_Lumpur')::date)) like 'C2C_NO_REPEAT%', 'repeat within the weeks');
select pg_temp.check(pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '50 days')
                     like 'C2C_TOO_FAR_AHEAD%', 'post up to 30 days ahead');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_post_trip(%L::jsonb, %L::jsonb, 205, 150, now() + interval ''3 days'', %L::jsonb, 3, 45)::text',
  pg_temp.from_end(), pg_temp.to_end(), '[{"name": "No point"}]')) like 'C2C_BAD_TRIP%', 'meeting points need a point');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310b1',
  format($q$update public.c2c_trips set seat_price = 1 where id = %L$q$, pg_temp.id('A'))) like '%permission denied%',
  'trips are written by the functions only');

-- ==== 4. Search ==============================================================================================
do $$
declare
  v jsonb;
  d date := ((now() + interval '3 days') at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310c1', format(
    'select public.c2c_search_trips(%L::jsonb, %L::jsonb, %L::date, 1)::text',
    '{"country": "Semenanjung 310", "city": "Kuala Lumpur 310"}', '{"city": "Ipoh 310"}', d))::jsonb;
  perform pg_temp.check(jsonb_array_length(v) = 1 and (v->0->>'id')::uuid = pg_temp.id('A')
                        and (v->0->>'seats_left')::int = 3 and v->0->>'driver_name' = 'Hafiz R.'
                        and (v->0->>'may_book')::boolean, 'search: trip A ' || v::text);
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310c1', format(
    'select public.c2c_search_trips(%L::jsonb, %L::jsonb, %L::date, 4)::text',
    '{"city": "Kuala Lumpur 310"}', '{"state": "Perak 310"}', d))::jsonb;
  perform pg_temp.check(jsonb_array_length(v) = 0, 'not 4 seats');
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310c1', format(
    'select public.c2c_search_trips(%L::jsonb, %L::jsonb, null, 1)::text',
    '{"city": "Kuala Lumpur 310"}', '{"state": "Perak 310"}'))::jsonb;
  perform pg_temp.check(jsonb_array_length(v) = 3
                        and not (select bool_and((e->>'may_book')::boolean) from jsonb_array_elements(v) e),
                        'the next 14 days: women only listed, not bookable by a man');
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
    'select public.c2c_search_trips(%L::jsonb, %L::jsonb, null, 1)::text',
    '{"city": "Kuala Lumpur 310"}', '{"state": "Perak 310"}'))::jsonb;
  perform pg_temp.check(jsonb_array_length(v) = 1, 'a driver doesn''t see their own trip');
end $$;

-- ==== 5. Booking ===============================================================================================
-- Riders can't insert seat rows themselves.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310c1', format(
  $q$insert into public.c2c_bookings (rider_id, trip_kind, trip_id, item, pickup_kind, driver_id, pickup_name, pickup_lat, pickup_lng,
     drop_name, drop_lat, drop_lng, distance_km, duration_min, leave_at, fare, payment, status)
     values (%L, 'per_seat', %L, 'seat', 'meeting', %L, 'x', 3.1, 101.7, 'y', 4.6, 101.1, 200, 150, now() + interval '3 days', 1, 'cash', 'booked')$q$,
  '00000000-0000-0000-0000-0000000310c1', pg_temp.id('A'), '00000000-0000-0000-0000-0000000310b1'))
  like '%row-level security%', 'seat rows come from c2c_book_seat only');

create or replace function pg_temp.book(p_user uuid, p_trip uuid, p_args text) returns text language sql as $$
  select pg_temp.value_as(p_user, format('select public.c2c_book_seat(%L::uuid, %s)::text', p_trip, p_args));
$$;
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310b1', pg_temp.id('A'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_OWN_TRIP%', 'not on your own trip');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('A'),
  '2, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_NAMES%', 'two seats need two names');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('A'),
  '5, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_TOO_MANY_SEATS%', 'up to 4 a booking');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('A'),
  '1, ''{"kind": "door", "name": "Far 310", "lat": 3.30, "lng": 101.72}'', ''cash''') like 'C2C_DOOR_TOO_FAR%',
  'door pickup up to 5 km off');
-- Wei: 2 seats at the bus stop, cash, instant: booked, commission locked.
insert into t select 'wei', (pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('A'),
  '2, ''{"kind": "meeting", "index": 1}'', ''cash'', ''[{"name": "Wei Ming"}, {"name": "Mei Ling", "familyMemberId": "f-310"}]''')::jsonb->>'id')::uuid;
select pg_temp.check((select status = 'booked' and fare = 90 and agreed_fare = 90 and passengers = 2
                             and pickup_name = 'Bus stop 310' and leave_at = (select leave_at + interval '15 minutes'
                                                                               from public.c2c_trips where id = pg_temp.id('A'))
                             and commission_rate = 0.12 and commission_locked_at is not null
                             and passenger_names->1->>'familyMemberId' = 'f-310' and booked_at is not null
                        from public.c2c_bookings where id = pg_temp.id('wei')), 'Wei booked 2 seats');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('A'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_ALREADY_BOOKED%', 'one booking a rider and trip');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c4', pg_temp.id('A'),
  '2, ''{"kind": "meeting", "index": 0}'', ''cash'', ''[{"name": "A"}, {"name": "B"}]''') like 'C2C_NO_SEATS%',
  'never overbooked: 1 seat left');
-- Kumar: the last seat, door pickup, in app held from his wallet.
select pg_temp.set_bal('00000000-0000-0000-0000-0000000310c4', 100);
insert into t select 'kumar', (pg_temp.book('00000000-0000-0000-0000-0000000310c4', pg_temp.id('A'),
  format('1, %L, ''in_app'', null, ''get_wallet'', %s',
         '{"kind": "door", "name": "Home 310", "lat": 3.15, "lng": 101.74}',
         45 + public.c2c_door_extra(round(public.km_between(3.15, 101.74, 3.13, 101.72)::numeric, 1), 1)))::jsonb->>'id')::uuid;
select pg_temp.check((select status = 'booked' and pickup_kind = 'door' and door_extra > 0 and fare = 45 + door_extra
                             and pay_status = 'held' and door_km = round(public.km_between(3.15, 101.74, 3.13, 101.72)::numeric, 1)
                        from public.c2c_bookings where id = pg_temp.id('kumar')), 'door pickup with its extra, held');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310c4')
                     = 100 - (select fare from public.c2c_bookings where id = pg_temp.id('kumar')), 'the fare held');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c3', pg_temp.id('A'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_NO_SEATS%', 'full');
-- A parcel takes a parcel slot, not a seat.
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c3', pg_temp.id('A'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash'', null, null, null, ''{"size": "medium", "recipientName": "Ali", "recipientPhone": "+60100031099"}''')
  like 'C2C_NO_PARCELS%', 'parcels up to the trip''s size');
insert into t select 'parcel', (pg_temp.book('00000000-0000-0000-0000-0000000310c3', pg_temp.id('A'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash'', null, null, null, ''{"size": "small", "recipientName": "Ali", "recipientPhone": "+60100031099"}''')::jsonb->>'id')::uuid;
select pg_temp.check((select status = 'booked' and item = 'parcel' and fare = 15 and parcel->>'recipientName' = 'Ali'
                        from public.c2c_bookings where id = pg_temp.id('parcel')), 'a parcel booked');
select pg_temp.check((select seats = 3 and parcels = 1 from public.c2c_trip_taken(pg_temp.id('A'))), 'taken: 3 seats, 1 parcel');

-- Women only, driver approves.
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c3', pg_temp.id('B'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_WOMEN_ONLY%', 'women only: an ID not verified');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('B'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_WOMEN_ONLY%', 'women only: a man');
select pg_temp.set_bal('00000000-0000-0000-0000-0000000310c2', 100);
insert into t select 'aina', (pg_temp.book('00000000-0000-0000-0000-0000000310c2', pg_temp.id('B'),
  '1, ''{"kind": "meeting", "index": 0}'', ''in_app'', null, ''get_wallet'', 40')::jsonb->>'id')::uuid;
select pg_temp.check((select status = 'requested' and pay_status = 'held' and commission_locked_at is null
                             and expires_at <= now() + interval '2 hours' and expires_at > now()
                        from public.c2c_bookings where id = pg_temp.id('aina')), 'a request, held, lapsing in 2 hours');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310c2') = 60, 'held at request');
-- Chat on a request.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310c2', format(
  $q$insert into public.ride_messages (c2c_booking_id, sender_id, sender_role, type, body) values (%L, %L, 'rider', 'text', 'Hi, 2 bags?')$q$,
  pg_temp.id('aina'), '00000000-0000-0000-0000-0000000310c2')) = 'ok 1', 'chat on a seat request');
-- Only the trip's driver decides; declined: the fare back.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_seat_decide(%L, true)::text', pg_temp.id('aina'))) like 'not_authorized%', 'not another driver');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b2', format(
  'select public.c2c_seat_decide(%L, false, ''Full car'')::text', pg_temp.id('aina'))) like '%declined%', 'declined');
select pg_temp.check((select status = 'declined' and pay_status = 'refunded' from public.c2c_bookings
                       where id = pg_temp.id('aina')), 'declined and refunded');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310c2') = 100, 'the fare back');
-- Again: lapsed (expired, the fare back).
insert into t select 'aina2', (pg_temp.book('00000000-0000-0000-0000-0000000310c2', pg_temp.id('B'),
  '1, ''{"kind": "meeting", "index": 0}'', ''in_app'', null, ''get_wallet'', 40')::jsonb->>'id')::uuid;
update public.c2c_bookings set expires_at = now() - interval '1 minute' where id = pg_temp.id('aina2');
select public.c2c_expire_due();
select pg_temp.check((select status = 'expired' and pay_status = 'refunded' from public.c2c_bookings
                       where id = pg_temp.id('aina2')), 'lapsed and refunded');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310c2') = 100, 'the fare back again');
-- And approved: booked, the commission locked.
insert into t select 'aina3', (pg_temp.book('00000000-0000-0000-0000-0000000310c2', pg_temp.id('B'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''')::jsonb->>'id')::uuid;
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b2', format(
  'select public.c2c_seat_decide(%L, true)::text', pg_temp.id('aina3'))) like '%booked%', 'approved');
select pg_temp.check((select status = 'booked' and commission_rate = 0.12 from public.c2c_bookings
                       where id = pg_temp.id('aina3')), 'approved: booked, commission locked');

-- The cut-off: 60 minutes before leaving.
update public.c2c_trips set leave_at = now() + interval '50 minutes' where id = pg_temp.id('B');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c4', pg_temp.id('B'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'C2C_BOOKING_CLOSED%', 'closed before leaving');
update public.c2c_trips set leave_at = now() + interval '4 days' where id = pg_temp.id('B');

-- ==== 6. Co-riders, reminders, cancelling a seat ===========================================================
do $$
declare
  v jsonb;
begin
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310c1', format('select public.c2c_coriders(%L)::text',
                                                                        pg_temp.id('wei')))::jsonb;
  perform pg_temp.check(jsonb_array_length(v) = 1 and v->0->>'name' = 'Kumar', 'co-riders: Kumar ' || v::text);
end $$;
update public.c2c_bookings set booked_at = now() - interval '1 day', created_at = now() - interval '1 day'
 where id = pg_temp.id('wei');
update public.c2c_trips set leave_at = now() + interval '100 minutes' where id = pg_temp.id('A');
update public.c2c_bookings set leave_at = now() + interval '115 minutes', driver_leave_at = now() + interval '115 minutes'
 where id = pg_temp.id('wei');
select public.c2c_send_reminders();
select pg_temp.check(exists (select 1 from public.notification_outbox o
                              where o.profile_id = '00000000-0000-0000-0000-0000000310c1'
                                and o.body like 'Hafiz R. picks you up at%Bus stop 310%'), 'the reminder names the driver');
update public.c2c_trips set leave_at = now() + interval '3 days' where id = pg_temp.id('A');
-- A seat isn't given up alone.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_driver_cancel(%L)::text', pg_temp.id('wei'))) like 'C2C_SEAT_TRIP%', 'a seat isn''t given up alone');
-- The parcel sender cancels (free, more than 24 h ahead): the slot frees up.
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310c3', format(
  'select public.c2c_cancel(%L)::text', pg_temp.id('parcel'))) like '%cancelled%', 'cancelled');
select pg_temp.check((select parcels = 0 from public.c2c_trip_taken(pg_temp.id('A'))), 'the slot is free again');

-- ==== 7. The driver cancels the trip: the give-up fee per booked rider ================================
-- Trip C (Hafiz): Wei booked, Siti requested.
update public.c2c_giveup_rules set charge = true, amount = 10, when_mode = 'always', dest = 'rider', short_mode = 'negative'
 where place is null;
insert into t select 'C', (pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '6 days',
  ', p_join => ''approve''')::jsonb->'ids'->>0)::uuid;
insert into t select 'weiC', (pg_temp.book('00000000-0000-0000-0000-0000000310c1', pg_temp.id('C'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''')::jsonb->>'id')::uuid;
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_seat_decide(%L, true)::text', pg_temp.id('weiC'))) like '%booked%', 'Wei approved on trip C');
insert into t select 'sitiC', (pg_temp.book('00000000-0000-0000-0000-0000000310c3', pg_temp.id('C'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''')::jsonb->>'id')::uuid;
select pg_temp.set_bal('00000000-0000-0000-0000-0000000310b1', 50);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000310c1', 0);
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310c1', format(
  'select public.c2c_trip_cancel(%L)::text', pg_temp.id('C'))) like 'not_authorized%', 'only its driver or an admin');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_trip_cancel(%L, ''Car trouble'')::text', pg_temp.id('C')))::jsonb->>'fees')::numeric = 10,
  'one fee: one booked rider');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310b1') = 40
                     and pg_temp.bal('00000000-0000-0000-0000-0000000310c1') = 10, 'the fee to the rider');
select pg_temp.check((select status = 'cancelled' and cancelled_by = 'driver' from public.c2c_bookings
                       where id = pg_temp.id('weiC'))
                     and (select status = 'declined' from public.c2c_bookings where id = pg_temp.id('sitiC'))
                     and (select status = 'cancelled' from public.c2c_trips where id = pg_temp.id('C')),
                     'the trip cancelled, the seat cancelled, the request declined');

-- ==== 8. Start and finish: each seat charged and paid ======================================================
select pg_temp.set_bal('00000000-0000-0000-0000-0000000310b1', 0);
select pg_temp.set_bal('00000000-0000-0000-0000-0000000310b1', 0, 'get_credit');
select pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_trip_progress(%L, ''completed'')::text', pg_temp.id('A'))) like 'C2C_BAD_STEP%', 'start first');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_trip_progress(%L, ''on_trip'')::text', pg_temp.id('A')))::jsonb->>'moved')::int = 2, 'two bookings on board');
select pg_temp.check((select bool_and(status = 'on_trip') from public.c2c_bookings
                       where id in (pg_temp.id('wei'), pg_temp.id('kumar'))), 'both on the trip');
select pg_temp.check((pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
  'select public.c2c_trip_progress(%L, ''completed'')::text', pg_temp.id('A')))::jsonb->>'moved')::int = 2, 'finished');
select pg_temp.check((select bool_and(status = 'completed' and commission_charged_at is not null)
                        from public.c2c_bookings where id in (pg_temp.id('wei'), pg_temp.id('kumar'))),
                     'both completed, commission charged');
-- Kumar's held fare to Hafiz less 12%; Wei's cash: 12% of RM 90 off GET.credit.
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310b1')
                     = round((select fare from public.c2c_bookings where id = pg_temp.id('kumar')) * 0.88, 2),
                     'the held fare paid less commission');
select pg_temp.check(pg_temp.bal('00000000-0000-0000-0000-0000000310b1', 'get_credit') = -10.80, 'cash: commission on credit');
select pg_temp.check((select status = 'completed' from public.c2c_trips where id = pg_temp.id('A')), 'trip A done');

-- ==== 10. Rider blocks (0311) on seat trips ==============================================================
-- Kumar asks for a seat on Hafiz's trip D, then blocks Hafiz: Hafiz no longer
-- sees or takes the request, it is withdrawn, and Kumar can't find or book
-- Hafiz's trips. Only where 0311's rider_blocks is in.
insert into t select 'D', (pg_temp.post('00000000-0000-0000-0000-0000000310b1', now() + interval '5 days',
  ', p_join => ''approve''')::jsonb->'ids'->>0)::uuid;
insert into t select 'kumarD', (pg_temp.book('00000000-0000-0000-0000-0000000310c4', pg_temp.id('D'),
  '1, ''{"kind": "meeting", "index": 0}'', ''cash''')::jsonb->>'id')::uuid;
select pg_temp.check((select status = 'requested' from public.c2c_bookings where id = pg_temp.id('kumarD')),
                     'Kumar requested a seat on trip D');
do $$
declare
  v jsonb;
  d date := ((now() + interval '5 days') at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if to_regclass('public.rider_blocks') is null then
    raise notice 'rider_blocks (0311) not in: block checks skipped';
    return;
  end if;
  insert into public.rider_blocks (rider_id, driver_id, source)
  values ('00000000-0000-0000-0000-0000000310c4', '00000000-0000-0000-0000-0000000310b1', 'settings');
  -- The driver: not in his list, not readable, not approvable, no chat.
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', 'select public.c2c_driver_seat_trips()::text')::jsonb;
  perform pg_temp.check(not exists (select 1 from jsonb_array_elements(v) x, jsonb_array_elements(x->'bookings') b
                                     where (b->>'id')::uuid = pg_temp.id('kumarD')), 'blocked: not in the driver''s trips');
  perform pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
    'select count(*)::text from public.c2c_bookings where id = %L', pg_temp.id('kumarD'))) = '0',
    'blocked: the driver can''t read the request');
  perform pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310c4', format(
    'select count(*)::text from public.c2c_bookings where id = %L', pg_temp.id('kumarD'))) = '1',
    'the rider still reads their own');
  perform pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310b1', format(
    'select public.c2c_seat_decide(%L, true)::text', pg_temp.id('kumarD'))) like 'C2C_NOT_OPEN%',
    'blocked: the driver can''t approve');
  perform pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310b1', format(
    $q$insert into public.ride_messages (c2c_booking_id, sender_id, sender_role, type, body)
       values (%L, '00000000-0000-0000-0000-0000000310b1', 'partner', 'text', 'Hello')$q$, pg_temp.id('kumarD')))
    like '%row-level security%', 'blocked: no chat from the driver');
  -- The rider: Hafiz's trips aren't listed nor bookable.
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310c4', format(
    'select public.c2c_search_trips(%L::jsonb, %L::jsonb, %L::date, 1)::text',
    '{"city": "Kuala Lumpur 310"}', '{"state": "Perak 310"}', d))::jsonb;
  perform pg_temp.check(not exists (select 1 from jsonb_array_elements(v) e where (e->>'id')::uuid = pg_temp.id('D')),
                        'blocked: the trip isn''t listed for the rider');
  v := pg_temp.value_as('00000000-0000-0000-0000-0000000310c1', format(
    'select public.c2c_search_trips(%L::jsonb, %L::jsonb, %L::date, 1)::text',
    '{"city": "Kuala Lumpur 310"}', '{"state": "Perak 310"}', d))::jsonb;
  perform pg_temp.check(exists (select 1 from jsonb_array_elements(v) e where (e->>'id')::uuid = pg_temp.id('D')),
                        'listed for other riders');
  perform pg_temp.check(pg_temp.value_as('00000000-0000-0000-0000-0000000310c4', format(
    'select (public.c2c_trip_for_rider(%L)->>''may_book'')', pg_temp.id('D'))) = 'false', 'blocked: not bookable');
  -- Withdrawn by the 5-minute sweep; booking again is refused.
  perform public.c2c_expire_due();
  perform pg_temp.check((select status = 'expired' from public.c2c_bookings where id = pg_temp.id('kumarD')),
                        'blocked: the request withdrawn');
  perform pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000310c4', pg_temp.id('D'),
    '1, ''{"kind": "meeting", "index": 0}'', ''cash''') like 'DRIVER_BLOCKED%', 'blocked: can''t book his trip');
end $$;

-- ==== 9. A verified ID's gender =========================================================================
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310c2',
  $q$update public.profiles set gender = 'male' where id = '00000000-0000-0000-0000-0000000310c2'$q$)
  like 'PROFILE_PROTECTED_COLUMN:gender%', 'a verified ID keeps its gender');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000310c3',
  $q$update public.profiles set gender = 'other' where id = '00000000-0000-0000-0000-0000000310c3'$q$) = 'ok 1',
  'an unverified profile changes its own');

select 'city_to_city_seats_0310: all passed';
rollback;
