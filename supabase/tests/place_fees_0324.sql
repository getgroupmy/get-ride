-- ============================================================================
-- Regression test for migration 0324: place fees — who may read and write
-- them, a fixed pickup fee, a percentage with its least and most, "either
-- end" against "each end" with both ends in one place, the service filter,
-- days and hours (one past midnight too), a date range, stops counted as
-- drop-offs, who the fee goes to, the cap on one ride, fees a client sends
-- dropped, the preview the same as what is stamped, a scheduled ride's fee
-- locked at booking and kept at release, an old airport charge carried over,
-- statements and the commission base.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/place_fees_0324.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000324a1'),  -- admin, EDIT on Airport Areas
  ('00000000-0000-0000-0000-0000000324a2'),  -- admin, EDIT on Multi-Gate Places only
  ('00000000-0000-0000-0000-0000000324c1'),  -- riders
  ('00000000-0000-0000-0000-0000000324c2'),
  ('00000000-0000-0000-0000-0000000324c3'),
  ('00000000-0000-0000-0000-0000000324c4')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000324%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000324a1', 'admin-settings-airport-areas', 'edit'),
  ('00000000-0000-0000-0000-0000000324a2', 'admin-settings-multi-gate-places', 'edit')
on conflict do nothing;

-- A country (lat 40..50, lng 140..150) the rides are booked in.
insert into public.countries (name, values, geofence) values
  ('Feeland 324', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":50,"south":40,"east":150,"west":140}}'));

-- Airport A 45.0..45.2 / 145.0..145.2 and airport B 46.0..46.2 / 146.0..146.2,
-- with no doors and no own fares (the fare stays the app's). Points: A1
-- 45.05,145.05 and A2 45.15,145.15 in A; B1 46.1,146.1 in B; TOWN 43,143.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000324e1', jsonb_build_object('name', 'Airport A 324',
    'boundary', '{"bbox":{"north":45.2,"south":45.0,"east":145.2,"west":145.0}}')),
  ('00000000-0000-0000-0000-0000000324e2', jsonb_build_object('name', 'Airport B 324',
    'boundary', '{"bbox":{"north":46.2,"south":46.0,"east":146.2,"west":146.0}}'));
update public.airport_settings set fares_on = false, pick_door_required = false, drop_door_required = false,
       fares = '{"roundUp": false}'
 where airport_id in ('00000000-0000-0000-0000-0000000324e1', '00000000-0000-0000-0000-0000000324e2');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
-- Refused: an error, or no row written.
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED (not refused): %', p_what;
  end if;
end $$;
-- Books a ride as [p_rider]; answers its id.
create or replace function pg_temp.book(p_rider uuid, p_plat float8, p_plng float8, p_dlat float8, p_dlng float8,
                                        p_service text default 'Comfort', p_fare numeric default 30,
                                        p_charges jsonb default null, p_stops jsonb default '[]')
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, distance_km,
                                    pickup_lat, pickup_lng, drop_lat, drop_lng, charges, stops)
  values (v, p_rider, 'open', p_service, p_fare, p_fare, 5, p_plat, p_plng, p_dlat, p_dlng, p_charges, p_stops);
  return v;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.book(uuid, float8, float8, float8, float8, text, numeric, jsonb, jsonb) to authenticated;

-- The settings, saved as the server.
create or replace function pg_temp.cfg(p jsonb) returns jsonb language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  return public.set_place_fees_config(p);
end $$;
-- A trip's lines (A = airport A, B = airport B) at a time, in the settings' zone (Kuala Lumpur).
create or replace function pg_temp.fees(p_pick uuid, p_drop uuid, p_stops uuid[] default null,
                                        p_service text default 'Comfort', p_fare numeric default 30,
                                        p_at timestamptz default now())
returns jsonb language sql as $$ select public.place_ride_charges(p_pick, p_drop, p_stops, p_service, p_fare, p_at) $$;
create or replace function pg_temp.sum(p jsonb) returns numeric language sql as $$
  select coalesce(sum((e->>'value')::numeric), 0) from jsonb_array_elements(p) e $$;
create or replace function pg_temp.ends(p jsonb) returns text language sql as $$
  select coalesce(string_agg(e->>'airport', ',' order by n), '') from jsonb_array_elements(p) with ordinality t(e, n) $$;

-- ---- 1. Who reads and writes them -------------------------------------------------------------------
select pg_temp.check(exists (select 1 from public.app_settings where key = 'place_fees'), 'the settings row is there');
select pg_temp.check(public.place_fees_config() @> '{"lockScheduled": true, "timeZone": "Asia/Kuala_Lumpur", "percentOf": "fare",
  "showMapLabel": true, "showAddressHint": true, "showCardBadge": true, "badgeText": "incl. place fee",
  "addressHintText": "{name} {amount} applies here", "maxTotal": null}', 'the defaults');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000324a1');
insert into public.place_fees (id, area_id, name, rider_note, applies_to, amount)
values ('00000000-0000-0000-0000-0000000324f1', '00000000-0000-0000-0000-0000000324e1', 'KLIA kerbside fee',
        'For the kerbside lane', 'pickup', 5);
select pg_temp.check((select count(*) from public.place_fees where area_id = '00000000-0000-0000-0000-0000000324e1') = 1,
  'the Airport Areas admin adds and reads an airport''s fee');
select pg_temp.check((public.set_place_fees_config('{"badgeText": "with fee", "timeZone": "Nowhere/Here"}')
                      @> '{"badgeText": "with fee", "timeZone": "Asia/Kuala_Lumpur", "lockScheduled": true}'),
  'the admin saves the settings; an unknown time zone is the default');
select public.set_place_fees_config('{}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000324a2');
select pg_temp.refused($q$insert into public.place_fees (area_id, name, amount) values ('00000000-0000-0000-0000-0000000324e1', 'X', 1)$q$,
  'a Places-only admin adding an airport''s fee');
select pg_temp.refused($q$update public.place_fees set amount = 1 where id = '00000000-0000-0000-0000-0000000324f1'$q$,
  'a Places-only admin changing an airport''s fee');
select pg_temp.as_user('00000000-0000-0000-0000-0000000324c1');
select pg_temp.check((select count(*) from public.place_fees) = 0, 'a rider reads no fee');
select pg_temp.refused($q$insert into public.place_fees (area_id, name, amount) values ('00000000-0000-0000-0000-0000000324e1', 'X', 1)$q$,
  'a rider adding a fee');
select pg_temp.refused($q$select public.set_place_fees_config('{"maxTotal": 1}')$q$, 'a rider changing the settings');
select pg_temp.refused($q$select public.place_ride_charges(null, null, null, null, null, now())$q$,
  'a rider calling the server''s own function');
reset role;
select pg_temp.refused($q$insert into public.place_fees (area_id, name, amount, amount_kind) values ('00000000-0000-0000-0000-0000000324e1', 'X', 120, 'percent')$q$,
  'a percentage over 100');
select pg_temp.refused($q$insert into public.place_fees (area_id, name, amount, min_amount, max_amount) values ('00000000-0000-0000-0000-0000000324e1', 'X', 1, 5, 2)$q$,
  'a least over the most');
select pg_temp.refused($q$insert into public.place_fees (area_id, name, amount, days) values ('00000000-0000-0000-0000-0000000324e1', 'X', 1, '{7}')$q$,
  'a day that isn''t one');

-- ---- 2. A fixed pickup fee ----------------------------------------------------------------------------
select pg_temp.check(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)
  = '[{"kind":"surcharge","charge":"fixed","name":"KLIA kerbside fee","value":5,"airport":"pick",
       "place_fee":"00000000-0000-0000-0000-0000000324f1","area":"00000000-0000-0000-0000-0000000324e1",
       "goes_to":"pass","note":"For the kerbside lane"}]'::jsonb,
  'a pickup in the place: one line, tagged so a client can''t send it');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1') = '[]', 'a drop-off there: no pickup fee');
select pg_temp.check(public.airport_ride_charges('00000000-0000-0000-0000-0000000324e1', null) @> '[{"value":5,"airport":"pick"}]',
  'the old airport_ride_charges answers from the fees');

-- ---- 3. A percentage with its least and most ---------------------------------------------------------
update public.place_fees set amount_kind = 'percent', amount = 10, min_amount = 3, max_amount = 8
 where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check((pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null, null, 'Comfort', 20)->0->>'value')::numeric = 3,
  '10% of 20 is raised to the least, 3');
select pg_temp.check((pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null, null, 'Comfort', 55)->0->>'value')::numeric = 5.5,
  '10% of 55 is 5.50');
select pg_temp.check((pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null, null, 'Comfort', 200)->0->>'value')::numeric = 8,
  '10% of 200 is cut to the most, 8');
update public.place_fees set amount_kind = 'fixed', amount = 5, min_amount = null, max_amount = null
 where id = '00000000-0000-0000-0000-0000000324f1';

-- ---- 4. Either end against each end, both ends in the place ------------------------------------------
update public.place_fees set applies_to = 'either' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(pg_temp.ends(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', '00000000-0000-0000-0000-0000000324e1')) = 'once',
  'either end: charged once with both ends in the place');
select pg_temp.check(pg_temp.ends(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1')) = 'once',
  'either end: a drop-off alone is charged too');
update public.place_fees set applies_to = 'each' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(pg_temp.ends(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', '00000000-0000-0000-0000-0000000324e1')) = 'pick,drop',
  'each end: the pickup''s line and the drop-off''s');
select pg_temp.check(pg_temp.sum(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', '00000000-0000-0000-0000-0000000324e1')) = 10,
  'each end: 5 + 5');
update public.place_fees set applies_to = 'dropoff' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(pg_temp.ends(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', '00000000-0000-0000-0000-0000000324e1')) = 'drop',
  'a drop-off fee: the drop-off''s line only');

-- ---- 5. The service ---------------------------------------------------------------------------------
update public.place_fees set services = '{Comfort, Premium}' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, ' comfort ')) = 1,
  'a service it is for (any case)');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Ride') = '[]',
  'a service it isn''t for');
update public.place_fees set services = '{}' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Ride')) = 1,
  'no services: every service');

-- ---- 6. Days and hours (Kuala Lumpur time) ------------------------------------------------------------
-- 2026-11-02 is a Monday.
update public.place_fees set days = '{1}', time_from = '08:00', time_to = '10:00'
 where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(extract(dow from date '2026-11-02') = 1, '2026-11-02 is a Monday');
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30,
                                                     '2026-11-02 09:00+08')) = 1, 'Monday 09:00: in the window');
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30,
                                                     '2026-11-02 01:00+00')) = 1, 'the time zone''s hour, not UTC''s (09:00 there)');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2026-11-02 10:00+08') = '[]',
  'Monday 10:00: the window has ended');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2026-11-03 09:00+08') = '[]',
  'Tuesday 09:00: not its day');
-- Friday 22:00 to 02:00 (2026-11-06 is a Friday).
update public.place_fees set days = '{5}', time_from = '22:00', time_to = '02:00'
 where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30,
                                                     '2026-11-06 23:00+08')) = 1, 'Friday 23:00');
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30,
                                                     '2026-11-07 01:30+08')) = 1, 'Saturday 01:30: Friday''s night still');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2026-11-07 23:00+08') = '[]',
  'Saturday 23:00: not its night');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2026-11-06 01:00+08') = '[]',
  'Friday 01:00: Thursday''s night, not its');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2026-11-06 12:00+08') = '[]',
  'Friday noon: outside the window');
update public.place_fees set days = '{0,1,2,3,4,5,6}', time_from = null, time_to = null
 where id = '00000000-0000-0000-0000-0000000324f1';

-- ---- 7. A date range ------------------------------------------------------------------------------------
update public.place_fees set date_from = '2026-12-01', date_to = '2026-12-31' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2026-11-30 12:00+08') = '[]',
  'before its dates');
select pg_temp.check(jsonb_array_length(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30,
                                                     '2026-12-31 23:30+08')) = 1, 'its last day (local)');
select pg_temp.check(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1', null, 'Comfort', 30, '2027-01-01 00:30+08') = '[]',
  'after its dates');
update public.place_fees set date_from = null, date_to = null where id = '00000000-0000-0000-0000-0000000324f1';

-- ---- 8. Stops counted as drop-offs -----------------------------------------------------------------------
select pg_temp.check(pg_temp.ends(pg_temp.fees(null, null, array['00000000-0000-0000-0000-0000000324e1'::uuid,
                                                                 '00000000-0000-0000-0000-0000000324e1'::uuid])) = '',
  'without count_stops a stop is not charged');
update public.place_fees set count_stops = true where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(pg_temp.ends(pg_temp.fees(null, '00000000-0000-0000-0000-0000000324e1',
                                               array['00000000-0000-0000-0000-0000000324e1'::uuid,
                                                     '00000000-0000-0000-0000-0000000324e1'::uuid])) = 'stop,stop,drop',
  'with count_stops: one line per stop in the place, then the drop-off');
select pg_temp.check(public.place_stop_areas('[{"name":"s","lat":45.05,"lng":145.05},{"lat":43,"lng":143},{"lat":"x"}]')
  = array['00000000-0000-0000-0000-0000000324e1'::uuid], 'the stops'' places, from the stored stops');
update public.place_fees set applies_to = 'either' where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.check(pg_temp.ends(pg_temp.fees(null, null, array['00000000-0000-0000-0000-0000000324e1'::uuid])) = 'once',
  'either end, with count_stops: a stop alone is charged once');
update public.place_fees set applies_to = 'pickup', count_stops = false where id = '00000000-0000-0000-0000-0000000324f1';

-- ---- 9. Who it goes to --------------------------------------------------------------------------------
insert into public.place_fees (id, area_id, name, applies_to, amount, goes_to, sort_order) values
  ('00000000-0000-0000-0000-0000000324f2', '00000000-0000-0000-0000-0000000324e1', 'Platform fee', 'pickup', 2, 'platform', 1),
  ('00000000-0000-0000-0000-0000000324f3', '00000000-0000-0000-0000-0000000324e1', 'Driver fee', 'pickup', 3, 'driver', 2);
select pg_temp.check(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)
  @> '[{"name":"Platform fee","goes_to":"platform","platform":true},{"name":"Driver fee","goes_to":"driver","earning":true}]'
  and not (pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)->0 ? 'platform')
  and not (pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)->0 ? 'earning'),
  'platform: platform true; driver: earning true; passed on: neither');
select pg_temp.check(pg_temp.ends(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)) = 'pick,pick,pick'
  and pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)->2->>'name' = 'Driver fee', 'in the admin''s order');
update public.place_fees set enabled = false where id = '00000000-0000-0000-0000-0000000324f3';
select pg_temp.check(jsonb_array_length(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)) = 2, 'a fee switched off');
update public.place_fees set enabled = true where id = '00000000-0000-0000-0000-0000000324f3';

-- ---- 10. The most all place fees add to one ride -------------------------------------------------------
select pg_temp.cfg('{"maxTotal": 6}');
select pg_temp.check(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null) @> '[{"name":"KLIA kerbside fee","value":5},{"name":"Platform fee","value":1}]'
  and jsonb_array_length(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null)) = 2,
  'capped at 6: 5, then 1 of the 2, and the last left out');
select pg_temp.cfg('{"maxTotal": 0}');
select pg_temp.check(pg_temp.fees('00000000-0000-0000-0000-0000000324e1', null) = '[]', 'a cap of 0: no place fee');
select pg_temp.cfg('{}');
delete from public.place_fees where id in ('00000000-0000-0000-0000-0000000324f2', '00000000-0000-0000-0000-0000000324f3');

-- ---- 11. A ride: stamped by the server, what a client sent dropped; the preview the same --------------
update public.place_fees set applies_to = 'each', count_stops = true where id = '00000000-0000-0000-0000-0000000324f1';
insert into public.place_fees (id, area_id, name, applies_to, amount, goes_to) values
  ('00000000-0000-0000-0000-0000000324f4', '00000000-0000-0000-0000-0000000324e2', 'B drop-off fee', 'dropoff', 4, 'driver');
set local role authenticated;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
insert into rides values ('a', pg_temp.book('00000000-0000-0000-0000-0000000324c1', 45.05, 145.05, 46.1, 146.1, 'Comfort', 30,
  '[{"kind":"surcharge","name":"Free money","charge":"fixed","value":-50,"airport":"pick","place_fee":"x"},
    {"kind":"surcharge","name":"Night surcharge","charge":"fixed","value":2,"earning":true,"locked":true}]',
  '[{"name":"Stop","lat":45.15,"lng":145.15}]'));
reset role;
select pg_temp.check((select charges from public.ride_requests where id = (select id from rides where k = 'a'))
  = '[{"kind":"surcharge","name":"Night surcharge","charge":"fixed","value":2}]'::jsonb
    || (public.place_fees_quote(45.05, 145.05, 46.1, 146.1, '[{"name":"Stop","lat":45.15,"lng":145.15}]', 'Comfort', 30)->'lines'),
  'the client''s place fee is dropped, its own charge can''t say it is the driver''s, and the server''s fees are what the preview showed');
select pg_temp.check(pg_temp.ends((select charges from public.ride_requests where id = (select id from rides where k = 'a'))) = 'pick,stop,drop',
  'the pickup''s fee, the stop''s and the drop-off''s at B');
select pg_temp.check(public.place_fees_quote(45.05, 145.05, 46.1, 146.1, '[{"name":"Stop","lat":45.15,"lng":145.15}]', 'Comfort', 30)
  @> '{"total": 14, "pickup": {"area_id": "00000000-0000-0000-0000-0000000324e1", "name": "Airport A 324",
       "fees": [{"name": "KLIA kerbside fee", "amount": 5}]},
       "drop": {"area_id": "00000000-0000-0000-0000-0000000324e2", "name": "Airport B 324",
       "fees": [{"name": "B drop-off fee", "amount": 4}]},
       "settings": {"showMapLabel": true, "showAddressHint": true, "showCardBadge": true,
                    "badgeText": "incl. place fee", "addressHintText": "{name} {amount} applies here"}}',
  'the preview: lines, total 5 + 5 + 4, each end''s place and fees, the display settings');
select pg_temp.check(public.place_fees_quote(43, 143, 43.1, 143.1, null, 'Comfort', 30)
  @> '{"lines": [], "total": 0, "pickup": null, "drop": null}', 'no place: nothing');
select pg_temp.check((public.airport_fare_quote(45.05, 145.05, 43, 143, 'Comfort', 5, 30)->>'charge')::numeric = 5
  and (public.airport_fare_quote(45.05, 145.05, 43, 143, 'Comfort', 5, 30, p_stops => '[{"lat":45.15,"lng":145.15}]')->>'charge')::numeric = 10,
  'the airport fare quote adds the fees, with its stops (each end, stops counted: 5 + 5)');
-- The rider can't take a fee off or add one afterwards.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000324c1');
select pg_temp.refused($q$update public.ride_requests set charges = '[]' where id = (select id from rides where k = 'a')$q$,
  'the rider removing the fees');
reset role;
select pg_temp.check(pg_temp.sum((select charges from public.ride_requests where id = (select id from rides where k = 'a'))) = 16,
  'the place fees stay as stamped');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'a');

-- ---- 12. Booked for later: locked at booking, kept at release -----------------------------------------
create or replace function pg_temp.schedule(p_rider uuid, p_charges jsonb default '[]') returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng, fare)
  values (p_rider, now() + interval '2 hours',
          jsonb_build_object('service', 'Comfort', 'pickup_lat', 45.05, 'pickup_lng', 145.05, 'drop_lat', 43, 'drop_lng', 143,
                             'fare', 30, 'ride_fare', 30, 'distance_km', 5, 'charges', p_charges),
          'Comfort', 45.05, 145.05, 43, 143, 30)
  returning id into v;
  return v;
end $$;
create temp table sched as select pg_temp.schedule('00000000-0000-0000-0000-0000000324c2',
  '[{"kind":"surcharge","name":"Fake fee","charge":"fixed","value":1,"airport":"pick"},
    {"kind":"surcharge","name":"Night surcharge","charge":"fixed","value":2}]') as id;
select pg_temp.check((select place_fees_locked
                             and request->'charges' @> '[{"name":"Night surcharge","value":2},{"name":"KLIA kerbside fee","value":5,"airport":"pick","locked":true}]'
                             and not request->'charges' @> '[{"name":"Fake fee"}]'
                        from public.scheduled_rides where id = (select id from sched)),
  'the booking drops the app''s fee and locks the server''s for the pickup time');
update public.place_fees set amount = 9 where id = '00000000-0000-0000-0000-0000000324f1';
create temp table rel as select public.scheduled_ride_release((select id from sched)) as id;
select pg_temp.check((select charges @> '[{"name":"KLIA kerbside fee","value":5,"airport":"pick","locked":true}]'
                             and not charges @> '[{"value":9}]' and pg_temp.sum(charges) = 7
                        from public.ride_requests where id = (select id from rel)),
  'released at the fee the rider saw (5), though it is 9 now');
update public.ride_requests set status = 'cancelled' where id = (select id from rel);
-- Locking switched off: a booking keeps no fee, and its release charges today's.
select pg_temp.cfg('{"lockScheduled": false}');
create temp table sched2 as select pg_temp.schedule('00000000-0000-0000-0000-0000000324c3') as id;
select pg_temp.check((select not place_fees_locked and request->'charges' = '[]' from public.scheduled_rides where id = (select id from sched2)),
  'not locked: nothing kept');
create temp table rel2 as select public.scheduled_ride_release((select id from sched2)) as id;
select pg_temp.check((select charges @> '[{"name":"KLIA kerbside fee","value":9}]' from public.ride_requests where id = (select id from rel2)),
  'not locked: released at today''s fee');
update public.ride_requests set status = 'cancelled' where id = (select id from rel2);
-- Switched off after a locked booking: its release charges today's too.
select pg_temp.cfg('{}');
create temp table sched3 as select pg_temp.schedule('00000000-0000-0000-0000-0000000324c4') as id;
update public.place_fees set amount = 6 where id = '00000000-0000-0000-0000-0000000324f1';
select pg_temp.cfg('{"lockScheduled": false}');
create temp table rel3 as select public.scheduled_ride_release((select id from sched3)) as id;
select pg_temp.check((select charges @> '[{"name":"KLIA kerbside fee","value":6}]' and not charges @> '[{"locked":true}]'
                        from public.ride_requests where id = (select id from rel3)),
  'locking switched off before the release: today''s fee');
update public.ride_requests set status = 'cancelled' where id = (select id from rel3);
select pg_temp.cfg('{}');

-- ---- 13. Statements and the commission base -----------------------------------------------------------
create or replace function pg_temp.ride(p_charges jsonb) returns public.ride_requests language sql as $$
  select jsonb_populate_record(null::public.ride_requests,
           jsonb_build_object('fare', 20, 'ride_fare', 20, 'charges', p_charges, 'status', 'completed')) $$;
select pg_temp.check(public.statement_ride_lines(pg_temp.ride(
    '[{"kind":"surcharge","name":"Driver fee","charge":"fixed","value":3,"earning":true,"airport":"pick"},
      {"kind":"surcharge","name":"Platform fee","charge":"fixed","value":2,"platform":true,"airport":"pick"},
      {"kind":"surcharge","name":"Passed fee","charge":"fixed","value":4,"airport":"drop"}]'), '{}')
  @> '{"surcharges": 3, "platformCollected": 2, "surchargesPass": 4}',
  'a statement: the driver''s fee is an earning, the platform''s collected, the passed-on one passed');
select pg_temp.check(public.commission_base(pg_temp.ride(
    '[{"kind":"surcharge","name":"Driver fee","charge":"fixed","value":3,"earning":true,"airport":"pick"},
      {"kind":"surcharge","name":"Platform fee","charge":"fixed","value":2,"platform":true,"airport":"pick"},
      {"kind":"surcharge","name":"Passed fee","charge":"fixed","value":4,"airport":"drop"}]')) = 23,
  'the commission base: the fare and the driver''s fee only (20 + 3)');

-- ---- 14. An old airport charge carries over -------------------------------------------------------------
delete from public.place_fees;
update public.airport_settings set pick_fee_on = true, pick_fee_name = 'Old pickup fee', pick_fee_amount = 7,
       drop_fee_on = true, drop_fee_name = 'Old drop fee', drop_fee_amount = 0
 where airport_id = '00000000-0000-0000-0000-0000000324e2';
delete from public.app_settings where key = 'place_fees';
\ir ../migrations/0324_place_fees.sql
\ir ../migrations/0324_place_fees.sql
select pg_temp.check((select count(*) from public.place_fees where area_id = '00000000-0000-0000-0000-0000000324e2') = 1
                     and exists (select 1 from public.place_fees where area_id = '00000000-0000-0000-0000-0000000324e2'
                                    and name = 'Old pickup fee' and applies_to = 'pickup' and amount_kind = 'fixed'
                                    and amount = 7 and goes_to = 'pass' and enabled),
  'the old pickup charge is a fee, once; an old charge of 0 is not');
set local role authenticated;
insert into rides values ('old', pg_temp.book('00000000-0000-0000-0000-0000000324c1', 46.1, 146.1, 43, 143));
reset role;
select pg_temp.check((select charges @> '[{"name":"Old pickup fee","value":7,"airport":"pick"}]'
                        from public.ride_requests where id = (select id from rides where k = 'old')),
  'and it is still charged');

rollback;
select 'place_fees_0324: all passed';
