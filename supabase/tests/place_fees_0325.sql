-- ============================================================================
-- Regression test for migration 0325: place fees follow-ups — the
-- showOutline setting (default on, kept, sent with the quote), and the
-- driver's scheduled rides with the place fees a booking locked
-- (place_fee_lines; scheduled_rides_open, scheduled_rides_upcoming,
-- scheduled_ride_offers_open and My rides' computed column), nothing else
-- of the rider's request.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/place_fees_0325.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000325a1'),  -- admin
  ('00000000-0000-0000-0000-0000000325c1'),  -- rider
  ('00000000-0000-0000-0000-0000000325b1'),  -- driver
  ('00000000-0000-0000-0000-0000000325b2')   -- another driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000325%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000325a1', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000325b1', 'Driver 325', '+60110000325', 'approved'),
  ('00000000-0000-0000-0000-0000000325b2', 'Other 325', '+60110000326', 'approved');

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
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text) to authenticated;

-- ---- 1. showOutline ---------------------------------------------------------------------------------
select pg_temp.check(public.place_fees_config() @> '{"showOutline": true}', 'the outline is on by default');
select pg_temp.check(public.place_fees_normalize('{"showOutline": "no"}') @> '{"showOutline": true}',
  'a wrong value is the default');
select pg_temp.as_user('00000000-0000-0000-0000-0000000325a1');
select pg_temp.check(public.set_place_fees_config('{"showOutline": false}') @> '{"showOutline": false, "showMapLabel": true}',
  'the admin turns it off');
select pg_temp.check(public.place_fees_config() @> '{"showOutline": false}', 'and it is kept');
select pg_temp.check(public.place_fees_quote(43, 143, 43.1, 143.1, null, 'car', 30)->'settings' @> '{"showOutline": false}',
  'the quote sends it');
select public.set_place_fees_config('{}');
select pg_temp.check(public.place_fees_quote(43, 143, 43.1, 143.1, null, 'car', 30)->'settings' @> '{"showOutline": true}',
  'and back on');

-- ---- 2. A booking with a locked fee ------------------------------------------------------------------
-- Airport C 47.0..47.2 / 147.0..147.2 with a 5 pickup fee (passed on) and a
-- 3 drop-off fee for the driver.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000325e1', jsonb_build_object('name', 'Airport C 325',
    'boundary', '{"bbox":{"north":47.2,"south":47.0,"east":147.2,"west":147.0}}'));
update public.airport_settings set fares_on = false, pick_door_required = false, drop_door_required = false
 where airport_id = '00000000-0000-0000-0000-0000000325e1';
insert into public.place_fees (area_id, name, rider_note, applies_to, amount, goes_to, sort_order) values
  ('00000000-0000-0000-0000-0000000325e1', 'Kerb fee 325', 'A secret note 325', 'pickup', 5, 'pass', 0),
  ('00000000-0000-0000-0000-0000000325e1', 'Driver fee 325', '', 'dropoff', 3, 'driver', 1);

select public.set_scheduled_rides_config(jsonb_build_object(
  'enabled', true, 'minLeadMinutes', 30, 'maxDaysAhead', 7, 'feeFixed', 0, 'feePercent', 0,
  'feeTo', 'platform', 'mode', 'advance', 'releaseMinutes', 20, 'reminderMinutes', 60));
select set_config('request.jwt.claims', '', true);

create temp table sched (k text primary key, id uuid);
grant all on sched to authenticated;
-- From the airport to town, and from town to the airport, for the rider.
with x as (
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                      fare, pickup_address, drop_address, currency)
  values ('00000000-0000-0000-0000-0000000325c1', now() + interval '3 hours',
          jsonb_build_object('service', 'car', 'fare', 30, 'ride_fare', 30, 'notes', 'Private words 325',
                             'charges', '[{"kind":"surcharge","name":"Night 325","charge":"fixed","value":2}]'::jsonb),
          'car', 47.1, 147.1, 43, 143, 30, 'Airport C', 'Town', 'RM')
  returning id)
insert into sched select 'out', id from x;
with x as (
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                      fare, pickup_address, drop_address, currency)
  values ('00000000-0000-0000-0000-0000000325c1', now() + interval '5 hours',
          jsonb_build_object('service', 'car', 'fare', 30, 'ride_fare', 30),
          'car', 43, 143, 47.1, 147.1, 30, 'Town', 'Airport C', 'RM')
  returning id)
insert into sched select 'in', id from x;

select pg_temp.check((select place_fees_locked from public.scheduled_rides where id = (select id from sched where k = 'out')),
  'the booking locked its fees');
select pg_temp.check((select l @>'[{"name":"Kerb fee 325","value":5,"airport":"pick","goes_to":"pass","locked":true}]'
             and jsonb_array_length(l) = 1 and not l::text like '%secret%' and not l::text like '%Night 325%'
             and not l->0 ? 'note' and not l->0 ? 'area'
        from (select public.place_fee_lines(s) l from public.scheduled_rides s
               where id = (select id from sched where k = 'out')) x),
  'its lines: the locked fee only, without the rider''s note or the other charges');
select pg_temp.check((select public.place_fee_lines(s) @> '[{"name":"Driver fee 325","value":3,"airport":"drop","goes_to":"driver"}]'
                        from public.scheduled_rides s where id = (select id from sched where k = 'in')),
  'the drop-off fee of the other booking, the driver''s');

-- ---- 3. What the driver sees --------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000325b1');
select pg_temp.check((select place_fees @> '[{"name":"Kerb fee 325","value":5,"goes_to":"pass"}]'
                        from public.scheduled_rides_upcoming() where id = (select id from sched where k = 'out')),
  'Upcoming has the locked fee');
select pg_temp.check((select place_fees @> '[{"name":"Driver fee 325","value":3,"goes_to":"driver"}]'
                        from public.scheduled_rides_upcoming() where id = (select id from sched where k = 'in')),
  'and the other booking''s');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_upcoming()
                                  where place_fees::text like '%secret%' or place_fees::text like '%Private words%'),
  'nothing else of the request');
-- The open list (advance booking) has the column, whatever this driver may book.
select pg_temp.check((select bool_and(jsonb_typeof(place_fees) = 'array') is not false from public.scheduled_rides_open()),
  'the open list answers its place fees');
select pg_temp.check(pg_get_function_result('public.scheduled_rides_open()'::regprocedure) like '%place_fees jsonb%',
  'the open list returns place_fees');
select pg_temp.check((select count(*) from public.scheduled_rides) = 0, 'the driver still reads no booking itself');
reset role;

-- The rider asks this driver to take the ride: Requests for you.
insert into public.scheduled_ride_offers (scheduled_ride_id, kind, rider_id, from_id, to_partner_id, expires_at)
values ((select id from sched where k = 'out'), 'assign', '00000000-0000-0000-0000-0000000325c1',
        '00000000-0000-0000-0000-0000000325c1', '00000000-0000-0000-0000-0000000325b1', now() + interval '1 hour');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000325b1');
select pg_temp.check((select incoming and place_fees @> '[{"name":"Kerb fee 325","value":5,"goes_to":"pass"}]'
                        from public.scheduled_ride_offers_open()
                       where scheduled_ride_id = (select id from sched where k = 'out')),
  'Requests for you has the locked fee');
select pg_temp.as_user('00000000-0000-0000-0000-0000000325c1');
select pg_temp.check((select not incoming and place_fees @> '[{"name":"Kerb fee 325"}]'
                        from public.scheduled_ride_offers_open()
                       where scheduled_ride_id = (select id from sched where k = 'out')),
  'and the rider''s own request shows it too');
reset role;

-- My rides: the driver's own booking, its place fees as a computed column.
update public.scheduled_ride_offers set status = 'cancelled' where scheduled_ride_id = (select id from sched where k = 'out');
update public.scheduled_rides set partner_id = '00000000-0000-0000-0000-0000000325b1', status = 'assigned'
 where id = (select id from sched where k = 'out');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000325b1');
select pg_temp.check((select s.place_fee_lines @> '[{"name":"Kerb fee 325","value":5,"locked":true}]'
                        from public.scheduled_rides s where s.id = (select id from sched where k = 'out')),
  'My rides reads the place fees of the driver''s own booking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000325b2');
select pg_temp.check(not exists (select 1 from public.scheduled_rides s where s.id = (select id from sched where k = 'out')),
  'another driver reads none of it');
reset role;

-- Not locked (switched off when booked): no lines.
select pg_temp.as_user('00000000-0000-0000-0000-0000000325a1');
select public.set_place_fees_config('{"lockScheduled": false}');
select set_config('request.jwt.claims', '', true);
with x as (
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng, fare)
  values ('00000000-0000-0000-0000-0000000325c1', now() + interval '6 hours',
          jsonb_build_object('service', 'car', 'fare', 30), 'car', 47.1, 147.1, 43, 143, 30)
  returning id)
insert into sched select 'free', id from x;
select pg_temp.check((select public.place_fee_lines(s) = '[]'::jsonb from public.scheduled_rides s
                       where id = (select id from sched where k = 'free')), 'a booking that locked none has no lines');

rollback;
select 'place_fees_0325: all passed';
