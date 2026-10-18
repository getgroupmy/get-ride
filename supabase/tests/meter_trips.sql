-- ============================================================================
-- Regression test for migration 0219: meter / TEKSI hires sent from the
-- phone, kept once, charged commission only when the switch is on, on the
-- fare plus what is ticked, at the place's rate and the driver's tiers.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/meter_trips.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000219b1'),  -- driver
  ('00000000-0000-0000-0000-0000000219b2'),  -- another driver
  ('00000000-0000-0000-0000-0000000219a1')   -- a rider (not a partner)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000219%'
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000219b1', 'Meter Driver', '60120000291', 'approved'),
  ('00000000-0000-0000-0000-0000000219b2', 'Other Driver', '60120000292', 'approved');

delete from public.commission_rates;
delete from public.commission_tiers;
insert into public.commission_rates (level, rate) values ('master', 0.10);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

create or replace function pg_temp.refused(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like p_like then
      raise exception 'FAILED: % refused for the wrong reason: %', p_what, sqlerrm;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;

create or replace function pg_temp.hire(p_id text, p_ago interval default interval '1 hour') returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p_id,
    'startedAt', (extract(epoch from now() - p_ago - interval '20 minutes') * 1000)::bigint,
    'endedAt', (extract(epoch from now() - p_ago) * 1000)::bigint,
    'distanceM', 8400, 'elapsedMs', 1200000, 'waitingMs', 60000,
    'rateLabel', 'Kuala Lumpur', 'period', 'day', 'currency', 'RM',
    'fare', 20, 'extra', 5, 'airportSurcharge', 3, 'cardSurcharge', 2, 'total', 30,
    'pax', 2, 'luggage', 1,
    'pickup', jsonb_build_object('at', 0, 'latitude', 3.15, 'longitude', 101.71, 'place', 'KLCC'),
    'dropoff', jsonb_build_object('at', 0, 'latitude', 3.13, 'longitude', 101.68, 'place', null),
    'plate', 'WXY 219');
$$;

grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text),
  pg_temp.hire(text, interval) to authenticated;

set local role authenticated;

-- 1. Only an approved partner sends hires -------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000219a1');
select pg_temp.refused(
  format($q$select public.meter_trip_record(%L)$q$, pg_temp.hire('00000000-0000-0000-0000-0000000219e9')),
  'a rider sending a hire', '%METER_TRIP_NOT_PARTNER%');

-- 2. Switch off: kept, not charged ------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000219b1');
select pg_temp.check(
  (select (r->>'recorded')::boolean and not (r->>'charged')::boolean
     from public.meter_trip_record(pg_temp.hire('00000000-0000-0000-0000-0000000219e1')) r),
  'with the switch off a hire is kept and not charged');
select pg_temp.check(
  (select distance_km = 8.4 and fare = 20 and pickup_place = 'KLCC' and commission_charged_at is null
     from public.meter_trips where id = '00000000-0000-0000-0000-0000000219e1'),
  'the hire is stored as sent');

-- Impossible hires are refused.
select pg_temp.refused(
  format($q$select public.meter_trip_record(%L)$q$,
    pg_temp.hire('00000000-0000-0000-0000-0000000219e8', interval '200 days')),
  'a hire from 200 days ago', '%METER_TRIP_INVALID%');
select pg_temp.refused(
  format($q$select public.meter_trip_record(%L)$q$,
    pg_temp.hire('00000000-0000-0000-0000-0000000219e7') || '{"fare": -5}'),
  'a negative fare', '%METER_TRIP_INVALID%');
reset role;

-- 3. Switch on, Airport surcharge and tolls ticked: 10% of 20 + 5 + 3 = 2.80 -------------
update public.app_settings
   set value = value || '{"meterCommission": true, "baseTolls": true, "baseSurcharges": ["Airport surcharge"]}'
 where key = 'commission';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000219b1');
select pg_temp.check(
  (select (r->>'charged')::boolean and (r->>'amount')::numeric = 2.80
     from public.meter_trip_record(pg_temp.hire('00000000-0000-0000-0000-0000000219e2')) r),
  'charged 10% of fare + tolls + airport');

-- Sent again: answered as it stands, charged once.
select pg_temp.check(
  (select (r->>'amount')::numeric = 2.80 from public.meter_trip_record(pg_temp.hire('00000000-0000-0000-0000-0000000219e2')) r),
  'a hire sent twice is answered as it stands');
select pg_temp.check(
  (select count(*) = 1 from public.wallet_transactions
    where user_id = '00000000-0000-0000-0000-0000000219b1' and kind = 'commission'),
  'and charged once');

-- A hire sent before the switch was on stays uncharged.
select pg_temp.check(
  (select commission_charged_at is null from public.meter_trips where id = '00000000-0000-0000-0000-0000000219e1'),
  'turning the switch on does not charge hires already sent');

-- 4. Another driver can't read or reuse it ---------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000219b2');
select pg_temp.check((select count(*) = 0 from public.meter_trips), 'another driver sees none of them');
select pg_temp.refused(
  format($q$select public.meter_trip_record(%L)$q$, pg_temp.hire('00000000-0000-0000-0000-0000000219e2')),
  'another driver sending a hire with the same id', '%METER_TRIP_INVALID%');
select pg_temp.refused(
  $q$insert into public.meter_trips (id, partner_id, started_at, ended_at, fare, total)
     values (gen_random_uuid(), '00000000-0000-0000-0000-0000000219b2', now(), now(), 1, 1)$q$,
  'writing the table directly');
reset role;

select 'meter_trips: all passed';
rollback;
