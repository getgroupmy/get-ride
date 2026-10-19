-- ============================================================================
-- Regression test for migration 0242: rider promo codes — every rule, the
-- rider RPCs (offers, a typed code, the zone bar), the re-check at booking,
-- the settlement (limits and budget under a double settle, an early end, a
-- cancelled trip, the wallet credit once per ride, a failure that never
-- holds up the completion), what is left to pay, and RLS.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rider_promo_codes_0242.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000242a1'),  -- rider, female
  ('00000000-0000-0000-0000-0000000242a2'),  -- rider, male, has a completed trip
  ('00000000-0000-0000-0000-0000000242a3'),  -- rider, no gender
  ('00000000-0000-0000-0000-0000000242a4'),  -- rider, for the limits
  ('00000000-0000-0000-0000-0000000242b1'),  -- driver
  ('00000000-0000-0000-0000-0000000242b2'),  -- another driver
  ('00000000-0000-0000-0000-0000000242c1'),  -- admin, Promocode edit
  ('00000000-0000-0000-0000-0000000242c2'),  -- admin, Promocode read
  ('00000000-0000-0000-0000-0000000242c3')   -- admin, another page only
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000242%'
on conflict do nothing;
update public.profiles set gender = 'female' where id = '00000000-0000-0000-0000-0000000242a1';
update public.profiles set gender = 'male' where id = '00000000-0000-0000-0000-0000000242a2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000242c1', 'admin-settings-promocode', 'edit'),
  ('00000000-0000-0000-0000-0000000242c2', 'admin-settings-promocode', 'read'),
  ('00000000-0000-0000-0000-0000000242c3', 'admin-settings-commission', 'edit');
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000242b1', 'Promo Driver', '60120000242', 'approved'),
  ('00000000-0000-0000-0000-0000000242b2', 'Other Driver', '60120000243', 'approved');

-- A country (0..10) with a city in it (1..3), on Malaysia's clock.
insert into public.countries (name, values, geofence) values
  ('Promoland 242', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":10,"south":0,"east":10,"west":0}}'));
insert into public.cities (country, state, name, geofence) values
  ('Promoland 242', '', 'Promo City 242', jsonb_build_object('boundary',
    '{"bbox":{"north":3,"south":1,"east":3,"west":1}}'));

delete from public.promo_codes;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED (not refused): %', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

-- Why a code doesn't apply (the rules alone, without promo_check's rate limit).
create or replace function pg_temp.why(p_code text, p_rider uuid, p_plat float8, p_plng float8,
                                       p_dlat float8, p_dlng float8, p_service text, p_fare numeric,
                                       p_at timestamptz default now())
returns text language sql as $$
  select coalesce(public.promo_reason(c, p_rider, p_at, 'Asia/Kuala_Lumpur',
                    public.promo_places(p_plat, p_plng), public.promo_places(p_dlat, p_dlng),
                    p_dlat is not null, p_service, p_fare), 'ok')
    from public.promo_codes c where c.code = p_code;
$$;

create or replace function pg_temp.amount(p_code text, p_fare numeric) returns numeric language sql as $$
  select public.promo_amount(c, p_fare) from public.promo_codes c where c.code = p_code;
$$;

-- Points: in the city; in the country but not the city; nowhere.
-- city (2, 2), country (8, 8), far (50, 50).

-- ---- 1. Discount types --------------------------------------------------------------------------
insert into public.promo_codes (code, discount_type, discount_value, max_discount) values
  ('FIX5', 'fixed', 5, null),
  ('PCT10', 'percent', 10, null),
  ('PCT10CAP', 'percent', 10, 3);
select pg_temp.check(pg_temp.amount('FIX5', 20) = 5, 'fixed RM5 off RM20');
select pg_temp.check(pg_temp.amount('FIX5', 3) = 3, 'fixed never more than the fare');
select pg_temp.check(pg_temp.amount('PCT10', 25) = 2.5, '10% of RM25');
select pg_temp.check(pg_temp.amount('PCT10CAP', 50) = 3, '10% capped at RM3');
select pg_temp.check(pg_temp.amount('PCT10CAP', 20) = 2, '10% under the cap');
select pg_temp.refused($$insert into public.promo_codes (code, discount_type, discount_value) values ('PCT200', 'percent', 200)$$,
                       'a percentage over 100');
select pg_temp.refused($$insert into public.promo_codes (code, discount_type, discount_value, max_discount) values ('FIXCAP', 'fixed', 5, 2)$$,
                       'a cap on a fixed amount');
select pg_temp.refused($$insert into public.promo_codes (code, discount_value) values ('bad code', 5)$$, 'a code with a space');

-- ---- 2. Limits, expiry, minimum fare ------------------------------------------------------------
insert into public.promo_codes (code, discount_value, min_fare, starts_at, ends_at, max_uses, budget, max_uses_per_rider) values
  ('MIN15', 5, 15, null, null, null, null, null),
  ('SOON', 5, null, now() + interval '1 day', null, null, null, null),
  ('GONE', 5, null, now() - interval '2 days', now() - interval '1 day', null, null, null),
  ('USEDUP', 5, null, null, null, 1, null, null),
  ('NOBUDGET', 5, null, null, null, null, 10, null),
  ('ONCEEACH', 5, null, null, null, null, null, 1);
update public.promo_codes set uses_count = 1 where code = 'USEDUP';
update public.promo_codes set discount_total = 10 where code = 'NOBUDGET';
insert into public.promo_redemptions (ride_id, code_id, code, rider_id, fare, discount, payable, driver_credit)
select gen_random_uuid(), id, code, '00000000-0000-0000-0000-0000000242a1', 20, 5, 15, 5
  from public.promo_codes where code = 'ONCEEACH';

select pg_temp.check(pg_temp.why('MIN15', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 10) = 'min_fare', 'minimum fare');
select pg_temp.check(pg_temp.why('MIN15', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 15) = 'ok', 'minimum fare met');
select pg_temp.check(pg_temp.why('SOON', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'not_started', 'not started');
select pg_temp.check(pg_temp.why('GONE', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'expired', 'expired');
select pg_temp.check(pg_temp.why('USEDUP', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'used_up', 'max uses');
select pg_temp.check(pg_temp.why('NOBUDGET', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'used_up', 'budget spent');
select pg_temp.check(pg_temp.why('ONCEEACH', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'used_by_you', 'per rider');
select pg_temp.check(pg_temp.why('ONCEEACH', '00000000-0000-0000-0000-0000000242a3', 2, 2, null, null, 'Car', 20) = 'ok', 'per rider: another rider');
update public.promo_codes set active = false where code = 'FIX5';
select pg_temp.check(pg_temp.why('FIX5', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'inactive', 'inactive');
update public.promo_codes set active = true where code = 'FIX5';

-- ---- 3. Location --------------------------------------------------------------------------------
insert into public.promo_codes (code, discount_value, applies_to, regions) values
  ('CITYPICK', 5, 'pickup', '[{"country": "Promoland 242", "city": "Promo City 242"}]'),
  ('CITYDROP', 5, 'dropoff', '[{"country": "Promoland 242", "city": "Promo City 242"}]'),
  ('CITYBOTH', 5, 'both', '[{"country": "Promoland 242", "city": "Promo City 242"}]'),
  ('TWOPLACES', 5, 'pickup', '[{"country": "Elsewhere"}, {"country": "promoland 242"}]');
select pg_temp.check(pg_temp.why('CITYPICK', '00000000-0000-0000-0000-0000000242a1', 2, 2, 50, 50, 'Car', 20) = 'ok', 'pickup in');
select pg_temp.check(pg_temp.why('CITYPICK', '00000000-0000-0000-0000-0000000242a1', 8, 8, 2, 2, 'Car', 20) = 'outside_area', 'pickup out');
select pg_temp.check(pg_temp.why('CITYDROP', '00000000-0000-0000-0000-0000000242a1', 8, 8, 2, 2, 'Car', 20) = 'ok', 'drop-off in');
select pg_temp.check(pg_temp.why('CITYDROP', '00000000-0000-0000-0000-0000000242a1', 2, 2, 8, 8, 'Car', 20) = 'outside_area', 'drop-off out');
select pg_temp.check(pg_temp.why('CITYDROP', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'outside_area', 'drop-off unknown');
select pg_temp.check(pg_temp.why('CITYBOTH', '00000000-0000-0000-0000-0000000242a1', 2, 2, 2.5, 2.5, 'Car', 20) = 'ok', 'both in');
select pg_temp.check(pg_temp.why('CITYBOTH', '00000000-0000-0000-0000-0000000242a1', 2, 2, 8, 8, 'Car', 20) = 'outside_area', 'both: drop-off out');
select pg_temp.check(pg_temp.why('CITYBOTH', '00000000-0000-0000-0000-0000000242a1', 8, 8, 2, 2, 'Car', 20) = 'outside_area', 'both: pickup out');
select pg_temp.check(pg_temp.why('TWOPLACES', '00000000-0000-0000-0000-0000000242a1', 8, 8, null, null, 'Car', 20) = 'ok', 'second of two regions, any case');
select pg_temp.check(pg_temp.why('TWOPLACES', '00000000-0000-0000-0000-0000000242a1', 50, 50, null, null, 'Car', 20) = 'outside_area', 'no region holds it');
select pg_temp.check(pg_temp.why('FIX5', '00000000-0000-0000-0000-0000000242a1', 50, 50, null, null, 'Car', 20) = 'ok', 'no regions: everywhere');

-- ---- 4. Time frame (Malaysia time) -----------------------------------------------------------
insert into public.promo_codes (code, discount_value, time_from, time_to, weekdays, date_from, date_to) values
  ('NIGHT', 5, '22:00', '06:00', '{}', null, null),
  ('MONDAY', 5, null, null, '{1}', null, null),
  ('OCTOBER', 5, null, null, '{}', '2026-10-01', '2026-10-31');
-- 2026-10-19 is a Monday.
select pg_temp.check(pg_temp.why('NIGHT', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-19 23:30+08') = 'ok', 'night window before midnight');
select pg_temp.check(pg_temp.why('NIGHT', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-20 02:00+08') = 'ok', 'night window after midnight');
select pg_temp.check(pg_temp.why('NIGHT', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-20 12:00+08') = 'not_now', 'night window at noon');
select pg_temp.check(pg_temp.why('NIGHT', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-19 15:30+00') = 'ok', '15:30 UTC is 23:30 in Malaysia');
select pg_temp.check(pg_temp.why('MONDAY', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-19 10:00+08') = 'ok', 'a Monday');
select pg_temp.check(pg_temp.why('MONDAY', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-20 10:00+08') = 'not_now', 'a Tuesday');
select pg_temp.check(pg_temp.why('MONDAY', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-19 17:00+00') = 'not_now', 'Monday 17:00 UTC is Tuesday in Malaysia');
select pg_temp.check(pg_temp.why('OCTOBER', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-31 23:00+08') = 'ok', 'last day of the range');
select pg_temp.check(pg_temp.why('OCTOBER', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20,
  '2026-10-31 17:00+00') = 'not_now', 'the day after in Malaysia');
select pg_temp.refused($$insert into public.promo_codes (code, discount_value, time_from) values ('HALF', 5, '10:00')$$,
                       'a window with one end');

-- ---- 5. Who ------------------------------------------------------------------------------------
insert into public.promo_codes (code, discount_value, genders, rider_ids, first_ride_only, services) values
  ('LADIES', 5, '{female}', '{}', false, '{}'),
  ('JUSTA1', 5, '{}', '{00000000-0000-0000-0000-0000000242a1}', false, '{}'),
  ('FIRST', 5, '{}', '{}', true, '{}'),
  ('CARONLY', 5, '{}', '{}', false, '{car}');
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare) values
  ('00000000-0000-0000-0000-0000000242e0', '00000000-0000-0000-0000-0000000242a2',
   '00000000-0000-0000-0000-0000000242b1', 'completed', 10, 10);
select pg_temp.refused($$insert into public.promo_codes (code, discount_value, genders) values ('ROBOTS', 5, '{robot}')$$,
                       'a gender profiles do not have');
select pg_temp.check(pg_temp.why('LADIES', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'ok', 'gender: female');
select pg_temp.check(pg_temp.why('LADIES', '00000000-0000-0000-0000-0000000242a2', 2, 2, null, null, 'Car', 20) = 'not_for_you', 'gender: male');
select pg_temp.check(pg_temp.why('LADIES', '00000000-0000-0000-0000-0000000242a3', 2, 2, null, null, 'Car', 20) = 'not_for_you', 'gender: not given');
select pg_temp.check(pg_temp.why('JUSTA1', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'ok', 'listed rider');
select pg_temp.check(pg_temp.why('JUSTA1', '00000000-0000-0000-0000-0000000242a3', 2, 2, null, null, 'Car', 20) = 'not_for_you', 'unlisted rider');
select pg_temp.check(pg_temp.why('FIRST', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Car', 20) = 'ok', 'first ride');
select pg_temp.check(pg_temp.why('FIRST', '00000000-0000-0000-0000-0000000242a2', 2, 2, null, null, 'Car', 20) = 'first_ride_only', 'not a first ride');
select pg_temp.check(pg_temp.why('CARONLY', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'CAR', 20) = 'ok', 'service, any case');
select pg_temp.check(pg_temp.why('CARONLY', '00000000-0000-0000-0000-0000000242a1', 2, 2, null, null, 'Bike', 20) = 'service', 'another service');

-- ---- 6. Rider RPCs ----------------------------------------------------------------------------
-- Only a few codes left on for the offers.
update public.promo_codes set active = false;
update public.promo_codes set active = true, auto_apply = true where code in ('CITYPICK', 'PCT10CAP');
update public.promo_codes set active = true where code in ('LADIES', 'CARONLY', 'SOON');
update public.promo_codes set active = true, auto_apply = true where code = 'JUSTA1';
update public.promo_codes set rider_ids = '{00000000-0000-0000-0000-0000000242a3}' where code = 'JUSTA1';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a1');
create temp table offers_a1 as select * from public.promo_offers(2, 2, 50, 50, 'Car', 40);
select pg_temp.check((select count(*) from offers_a1) = 4, 'four codes apply to A1 in the city');
select pg_temp.check(not exists (select 1 from offers_a1 where code in ('JUSTA1', 'SOON')), 'codes A1 does not qualify for are not listed');
select pg_temp.check((select code from offers_a1 where auto_apply) = 'CITYPICK', 'the larger auto-apply discount is flagged');
select pg_temp.check((select count(*) from offers_a1 where auto_apply) = 1, 'one auto-apply');
select pg_temp.check((select pickup_only from offers_a1 where code = 'CITYPICK'), 'about the pickup');
select pg_temp.check((select estimated_discount from offers_a1 where code = 'PCT10CAP') = 3, 'estimate capped');
select pg_temp.check((select estimated_payable from offers_a1 where code = 'CITYPICK') = 35, 'estimated payable');
select pg_temp.check((select count(*) from public.promo_offers(8, 8, null, null, 'Bike', 40)) = 2, 'outside the city, not a car');
select pg_temp.check(public.promo_zone_here(2, 2), 'in the promo zone');
select pg_temp.check(not public.promo_zone_here(8, 8), 'out of the promo zone');
select pg_temp.check((select count(*) from public.promo_codes) = 0, 'riders never read the table');

select pg_temp.check((public.promo_check('cityPick', 2, 2, 50, 50, 'Car', 40))->>'ok' = 'true', 'typed code, any case');
select pg_temp.check((public.promo_check('CITYPICK', 8, 8, 50, 50, 'Car', 40))->>'reason' = 'outside_area', 'typed code outside');
select pg_temp.check((public.promo_check('NOPE', 2, 2, 50, 50, 'Car', 40))->>'reason' = 'not_found', 'unknown code');
select pg_temp.check((public.promo_check('FIX5', 2, 2, 50, 50, 'Car', 40))->>'reason' = 'not_found', 'an inactive code reads as unknown');
select pg_temp.check((public.promo_check('SOON', 2, 2, 50, 50, 'Car', 40))->>'reason' = 'not_started', 'not started yet');
select pg_temp.check((public.promo_check('JUSTA1', 2, 2, 50, 50, 'Car', 40))->>'message' = 'This code isn''t available on your account.', 'plain reason');
select pg_temp.check((public.promo_check('CARONLY', 2, 2, 50, 50, 'Bike', 40))->>'message' = 'This code doesn''t apply to Bike.', 'service reason');

select pg_temp.as_user('00000000-0000-0000-0000-0000000242a2');
select pg_temp.check(not exists (select 1 from public.promo_offers(2, 2, 50, 50, 'Car', 40) where code = 'LADIES'),
                     'a code for women is not offered to a man');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a3');
select pg_temp.check(exists (select 1 from public.promo_offers(2, 2, 50, 50, 'Car', 40) where code = 'JUSTA1'), 'listed rider sees the code');
reset role;

-- Rate limit: 20 tries in 10 minutes, then refused.
delete from public.auth_rate_hits where bucket = 'promo_check';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a2');
select public.promo_check('GUESS' || g, 2, 2, null, null, 'Car', 20) from generate_series(1, 20) g;
select pg_temp.check((public.promo_check('CITYPICK', 2, 2, null, null, 'Car', 20))->>'reason' = 'rate_limited', 'rate limited');
reset role;

-- ---- 7. RLS on the codes ------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a1');
select pg_temp.refused($$insert into public.promo_codes (code, discount_value) values ('RIDERS', 5)$$, 'a rider adds a code');
select pg_temp.check((select count(*) from public.promo_redemptions) = 1, 'a rider reads their own redemption');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242c3');
select pg_temp.check((select count(*) from public.promo_codes) = 0, 'an admin of another page does not read codes');
select pg_temp.refused($$insert into public.promo_codes (code, discount_value) values ('OTHERPAGE', 5)$$, 'another page adds a code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242c2');
select pg_temp.check((select count(*) from public.promo_codes) > 10, 'a read-only admin reads codes');
select pg_temp.check((select count(*) from public.promo_redemptions) = 1, 'a read-only admin reads redemptions');
select pg_temp.refused($$insert into public.promo_codes (code, discount_value) values ('READONLY', 5)$$, 'a read-only admin adds a code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242c1');
insert into public.promo_codes (code, discount_value, uses_count, discount_total) values ('admin1', 5, 99, 99);
select pg_temp.check((select uses_count = 0 and discount_total = 0 from public.promo_codes where code = 'ADMIN1'),
                     'the counters are the server''s; the code is upper-cased');
update public.promo_codes set description = 'Edited', uses_count = 50 where code = 'ADMIN1';
select pg_temp.check((select description = 'Edited' and uses_count = 0 from public.promo_codes where code = 'ADMIN1'),
                     'an editor edits, but not the counters');
reset role;

-- ---- 8. Booking: the server checks the code again ----------------------------------------------
update public.promo_codes set active = true, auto_apply = false, max_uses = null, budget = null,
                              max_uses_per_rider = null, discount_total = 0, uses_count = 0
 where code in ('CITYPICK', 'FIX5');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a1');
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                  promo_code_id, promo_estimate, promo_discount)
select '00000000-0000-0000-0000-0000000242e1', '00000000-0000-0000-0000-0000000242a1', 'open', 'Car', 30, 30, 2, 2, 8, 8,
       code_id, 99, 99 from public.promo_offers(2, 2, 50, 50, 'Car', 30) where code = 'CITYPICK';
select pg_temp.check((select promo_code = 'CITYPICK' and promo_estimate = 5 and promo_discount is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242e1'),
                     'a valid code is kept with the server''s estimate');
update public.ride_requests set fare = 40, ride_fare = 40 where id = '00000000-0000-0000-0000-0000000242e1';
select pg_temp.refused($$update public.ride_requests set promo_estimate = 30 where id = '00000000-0000-0000-0000-0000000242e1'$$,
                       'a rider sets the estimate');
select pg_temp.refused($$update public.ride_requests set promo_code_id = null where id = '00000000-0000-0000-0000-0000000242e1'$$,
                       'a rider changes the code on the ride');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000242e1';
-- A code the ride doesn't qualify for is dropped and the booking goes ahead.
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng, promo_code_id)
select '00000000-0000-0000-0000-0000000242e2', '00000000-0000-0000-0000-0000000242a1', 'open', 'Car', 30, 30, 8, 8, 8.5, 8.5, code_id
  from public.promo_offers(2, 2, 50, 50, 'Car', 30) where code = 'CITYPICK';
select pg_temp.check((select promo_code_id is null and promo_error = 'outside_area'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242e2'),
                     'a code outside its area is dropped from the booking');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000242e2';
reset role;

-- ---- 9. Settlement ------------------------------------------------------------------------------
create or replace function pg_temp.ride(p_id uuid, p_rider uuid, p_code text, p_fare numeric, p_driver uuid
                                        default '00000000-0000-0000-0000-0000000242b1')
returns void language plpgsql as $$
begin
  -- Booked as the server would (no caller), on the trip already.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  insert into public.ride_requests (id, rider_id, partner_id, status, service, fare, ride_fare,
                                    pickup_lat, pickup_lng, drop_lat, drop_lng, promo_code_id)
  select p_id, p_rider, p_driver, 'on_trip', 'Car', p_fare, p_fare, 2, 2, 2.5, 2.5,
         (select id from public.promo_codes where code = p_code);
  perform pg_temp.check((select promo_code_id is not null from public.ride_requests where id = p_id),
                        'booked under ' || p_code);
end $$;
create or replace function pg_temp.complete(p_id uuid, p_driver uuid default '00000000-0000-0000-0000-0000000242b1')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_driver, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_driver::text, true);
  execute 'set local role authenticated';
  update public.ride_requests set status = 'completed' where id = p_id;
  execute 'reset role';
end $$;
create or replace function pg_temp.credits(p_ride uuid) returns bigint language sql as $$
  select count(*) from public.wallet_transactions where ride_id = p_ride and kind = 'promo_credit';
$$;

-- A full trip.
select pg_temp.ride('00000000-0000-0000-0000-0000000242f1', '00000000-0000-0000-0000-0000000242a1', 'FIX5', 20);
select pg_temp.check((select promo_estimate from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f1') = 5,
                     'estimate stored');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f1');
select pg_temp.check((select status = 'completed' and promo_discount = 5 and promo_payable = 15 and promo_settled_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f1'), 'settled on completion');
select pg_temp.check((select discount = 5 and payable = 15 and driver_credit = 5 and fare = 20
                             and driver_id = '00000000-0000-0000-0000-0000000242b1' and wallet_tx_id is not null
                        from public.promo_redemptions where ride_id = '00000000-0000-0000-0000-0000000242f1'), 'redemption recorded');
select pg_temp.check((select amount = 5 and wallet_type = 'get_wallet' and user_id = '00000000-0000-0000-0000-0000000242b1'
                        from public.wallet_transactions where ride_id = '00000000-0000-0000-0000-0000000242f1' and kind = 'promo_credit'),
                     'the driver''s wallet credited');
select pg_temp.check((select balance from public.wallets where user_id = '00000000-0000-0000-0000-0000000242b1'
                         and wallet_type = 'get_wallet') = 5, 'the balance moved');
select pg_temp.check((select uses_count = 1 and discount_total = 5 from public.promo_codes where code = 'FIX5'), 'code counters');
select pg_temp.check((select body from public.notification_outbox
                       where event_id = '00000000-0000-0000-0000-0000000242f1:promo')
                     = 'Promo FIX5 saved you RM5.00 · you paid RM15.00', 'the rider is told');
select pg_temp.check((select public.ride_left_to_pay(r) from public.ride_requests r
                       where id = '00000000-0000-0000-0000-0000000242f1') = 15, 'left to pay is after the promo');

-- Settling again does nothing: one redemption, one credit.
select pg_temp.check((public.promo_settle_ride('00000000-0000-0000-0000-0000000242f1'))->>'settled' = 'false', 'second settle');
update public.ride_requests set promo_settled_at = null where id = '00000000-0000-0000-0000-0000000242f1';
select pg_temp.check((public.promo_settle_ride('00000000-0000-0000-0000-0000000242f1'))->>'reason' = 'already', 'settle after a reset');
select pg_temp.check(pg_temp.credits('00000000-0000-0000-0000-0000000242f1') = 1, 'the wallet credit is once per ride');
select pg_temp.check((select uses_count from public.promo_codes where code = 'FIX5') = 1, 'counted once');
select pg_temp.refused($$insert into public.wallet_transactions (user_id, wallet_type, kind, amount, ride_id)
                         values ('00000000-0000-0000-0000-0000000242b1', 'get_wallet', 'promo_credit', 5,
                                 '00000000-0000-0000-0000-0000000242f1')$$, 'a second promo credit for the ride');

-- The rider pays what is left with GET.wallet: RM15, not RM20.
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000242a1', 'get_wallet', 'topup', 50, 'test', 'test');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a1');
select public.ride_pay('00000000-0000-0000-0000-0000000242f1', 'get_wallet', 15);
select pg_temp.check((select count(*) from public.promo_redemptions where ride_id = '00000000-0000-0000-0000-0000000242f1') = 1,
                     'the rider reads the redemption of their trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242b1');
select pg_temp.check((select count(*) from public.promo_redemptions where ride_id = '00000000-0000-0000-0000-0000000242f1') = 1,
                     'the driver reads the redemption of their trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242b2');
select pg_temp.check((select count(*) from public.promo_redemptions) = 0, 'another driver reads none');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a3');
select pg_temp.check((select count(*) from public.promo_redemptions) = 0, 'another rider reads none');
reset role;
select pg_temp.check((select paid_amount from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f1') = 15,
                     'paid after the promo');
select pg_temp.check((select balance from public.wallets where user_id = '00000000-0000-0000-0000-0000000242b1'
                         and wallet_type = 'get_wallet') = 20, 'the driver has the whole fare');

-- Ended early: no promo.
select pg_temp.ride('00000000-0000-0000-0000-0000000242f2', '00000000-0000-0000-0000-0000000242a3', 'FIX5', 20);
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000242b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000242b1', true);
set local role authenticated;
update public.ride_requests set status = 'completed', ride_fare = 12, ended_early_at = now()
 where id = '00000000-0000-0000-0000-0000000242f2';
reset role;
select pg_temp.check((select status = 'completed' and promo_discount = 0 and promo_error = 'ended_early'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f2'), 'an early end gets no promo');
select pg_temp.check(pg_temp.credits('00000000-0000-0000-0000-0000000242f2') = 0, 'no credit for an early end');
select pg_temp.check(not exists (select 1 from public.promo_redemptions where ride_id = '00000000-0000-0000-0000-0000000242f2'),
                     'no redemption for an early end');
select pg_temp.check((select public.ride_left_to_pay(r) from public.ride_requests r
                       where id = '00000000-0000-0000-0000-0000000242f2') = 12, 'an early end pays its fare');

-- Cancelled after pickup (a cancellation request granted, 0191): nothing.
select pg_temp.ride('00000000-0000-0000-0000-0000000242f3', '00000000-0000-0000-0000-0000000242a4', 'FIX5', 20);
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000242f3';
select pg_temp.check((select promo_settled_at is null and promo_discount is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f3'), 'a cancelled trip gets nothing');
select pg_temp.check((public.promo_settle_ride('00000000-0000-0000-0000-0000000242f3'))->>'reason' = 'not_completed',
                     'a cancelled trip never settles');

-- Max uses under a double settle: two trips booked under a code with one use left.
insert into public.promo_codes (code, discount_value, max_uses) values ('ONEUSE', 4, 1);
select pg_temp.ride('00000000-0000-0000-0000-0000000242f4', '00000000-0000-0000-0000-0000000242a3', 'ONEUSE', 20);
select pg_temp.ride('00000000-0000-0000-0000-0000000242f5', '00000000-0000-0000-0000-0000000242a4', 'ONEUSE', 20,
                    '00000000-0000-0000-0000-0000000242b2');
select pg_temp.check((select count(*) from public.ride_requests where promo_code = 'ONEUSE') = 2, 'both booked under it');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f4');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f5', '00000000-0000-0000-0000-0000000242b2');
select pg_temp.check((select promo_discount from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f4') = 4, 'first trip gets it');
select pg_temp.check((select promo_discount = 0 and promo_error = 'used_up'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f5'), 'second trip: used up');
select pg_temp.check((select uses_count from public.promo_codes where code = 'ONEUSE') = 1, 'never over the uses');
select pg_temp.check((select public.ride_left_to_pay(r) from public.ride_requests r
                       where id = '00000000-0000-0000-0000-0000000242f5') = 20, 'the second rider pays in full');

-- Budget: RM10 at RM6 a trip gives RM6, then the RM4 left, then nothing.
insert into public.promo_codes (code, discount_value, budget) values ('BUDGET10', 6, 10);
select pg_temp.ride('00000000-0000-0000-0000-0000000242f6', '00000000-0000-0000-0000-0000000242a3', 'BUDGET10', 20);
select pg_temp.ride('00000000-0000-0000-0000-0000000242f7', '00000000-0000-0000-0000-0000000242a4', 'BUDGET10', 20,
                    '00000000-0000-0000-0000-0000000242b2');
select pg_temp.ride('00000000-0000-0000-0000-0000000242f8', '00000000-0000-0000-0000-0000000242a1', 'BUDGET10', 20,
                    '00000000-0000-0000-0000-0000000242b2');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f6');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f7', '00000000-0000-0000-0000-0000000242b2');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f8', '00000000-0000-0000-0000-0000000242b2');
select pg_temp.check((select promo_discount from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f6') = 6, 'budget: first');
select pg_temp.check((select promo_discount from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f7') = 4, 'budget: the rest');
select pg_temp.check((select promo_error from public.ride_requests where id = '00000000-0000-0000-0000-0000000242f8') = 'used_up', 'budget: spent');
select pg_temp.check((select discount_total from public.promo_codes where code = 'BUDGET10') = 10, 'never over the budget');

-- Per rider, at settlement.
insert into public.promo_codes (code, discount_value, max_uses_per_rider) values ('ONCE', 2, 1);
select pg_temp.ride('00000000-0000-0000-0000-0000000242f9', '00000000-0000-0000-0000-0000000242a3', 'ONCE', 20);
select pg_temp.ride('00000000-0000-0000-0000-0000000242fa', '00000000-0000-0000-0000-0000000242a3', 'ONCE', 20,
                    '00000000-0000-0000-0000-0000000242b2');
select pg_temp.complete('00000000-0000-0000-0000-0000000242f9');
select pg_temp.complete('00000000-0000-0000-0000-0000000242fa', '00000000-0000-0000-0000-0000000242b2');
select pg_temp.check((select promo_error from public.ride_requests where id = '00000000-0000-0000-0000-0000000242fa') = 'used_by_you',
                     'per rider at settlement');

-- The discount is on the final fare: a percentage of a fare lowered on completion is not possible
-- without ending early, so check a percentage of the stored fare with tolls on top.
insert into public.promo_codes (code, discount_type, discount_value, max_discount) values ('TENPC', 'percent', 10, 50);
select pg_temp.ride('00000000-0000-0000-0000-0000000242fb', '00000000-0000-0000-0000-0000000242a4', 'TENPC', 33);
update public.ride_requests set toll_charges = 2 where id = '00000000-0000-0000-0000-0000000242fb';
select pg_temp.complete('00000000-0000-0000-0000-0000000242fb');
select pg_temp.check((select promo_discount = 3.3 and promo_payable = 31.7
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242fb'),
                     'a percentage of the fare; tolls still paid');

-- A failure never holds up the completion.
select pg_temp.ride('00000000-0000-0000-0000-0000000242fc', '00000000-0000-0000-0000-0000000242a4', 'TENPC', 20);
alter table public.promo_redemptions rename to promo_redemptions_away;
select pg_temp.complete('00000000-0000-0000-0000-0000000242fc');
alter table public.promo_redemptions_away rename to promo_redemptions;
select pg_temp.check((select status = 'completed' and promo_discount = 0 and promo_error like 'failed:%'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000242fc'),
                     'completed without the promo when settling fails');
select pg_temp.check(pg_temp.credits('00000000-0000-0000-0000-0000000242fc') = 0, 'no credit when settling fails');

-- ---- 10. Admin totals ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000242c2');
select pg_temp.check((select uses = 2 and discount = 10 from public.admin_promo_redemption_stats() s
                        join public.promo_codes c on c.id = s.code_id where c.code = 'BUDGET10'), 'admin totals');
select pg_temp.as_user('00000000-0000-0000-0000-0000000242a1');
select pg_temp.check((select count(*) from public.admin_promo_redemption_stats()) = 0, 'riders get no totals');
reset role;

rollback;
