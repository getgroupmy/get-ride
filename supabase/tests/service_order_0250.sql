-- ============================================================================
-- Regression test for migration 0250: the vehicle service order for every
-- booking — the admin switch, who reads and takes an open request, who is
-- pushed, GET.now and My Ride, scheduled rides, and nothing changes while
-- the switch is off.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/service_order_0250.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000251a1'),  -- admin, EDIT on Vehicle Services
  ('00000000-0000-0000-0000-0000000251a2'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000251c1'),  -- riders
  ('00000000-0000-0000-0000-0000000251c2'),
  ('00000000-0000-0000-0000-0000000251c3'),
  ('00000000-0000-0000-0000-0000000251c4'),
  ('00000000-0000-0000-0000-0000000251d1'),  -- driver, Ride vehicle
  ('00000000-0000-0000-0000-0000000251d2'),  -- driver, Comfort vehicle
  ('00000000-0000-0000-0000-0000000251d3'),  -- driver, Premium vehicle
  ('00000000-0000-0000-0000-0000000251d4')   -- driver, vehicle without an approved service
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000251%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000251a1', 'admin-settings-vehicle-services', 'edit'),
  ('00000000-0000-0000-0000-0000000251a2', 'admin-settings-ip-access', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status)
select u.id, 'Driver ' || right(u.id::text, 2), '6012000' || right(u.id::text, 4), 'approved'
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000251d%';

insert into public.countries (name, values, geofence) values
  ('Orderland 251', '{"timezone": "Asia/Kuala_Lumpur"}', jsonb_build_object('boundary',
    '{"bbox":{"north":30,"south":20,"east":120,"west":110}}'));

-- Ride < Comfort < Six < Premium.
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000025151', 'vehicle-services', '{"name":"Ride 251"}', 1),
  ('00000000-0000-0000-0000-000000025152', 'vehicle-services', '{"name":"Comfort 251"}', 2),
  ('00000000-0000-0000-0000-000000025153', 'vehicle-services', '{"name":"Six 251"}', 3),
  ('00000000-0000-0000-0000-000000025154', 'vehicle-services', '{"name":"Premium 251"}', 4);
delete from public.vehicle_service_order;
insert into public.vehicle_service_order (service_id, rank) values
  ('00000000-0000-0000-0000-000000025151', 1), ('00000000-0000-0000-0000-000000025152', 2),
  ('00000000-0000-0000-0000-000000025153', 3), ('00000000-0000-0000-0000-000000025154', 4);
insert into public.vehicle (auth_user_id, plate, make, model, status, service_id, service_approved_id)
select u.id, 'SO' || right(u.id::text, 2), 'Make', 'Model', 'approved', s.sid, s.approved
  from auth.users u
  join (values ('d1', '00000000-0000-0000-0000-000000025151', '00000000-0000-0000-0000-000000025151'),
               ('d2', '00000000-0000-0000-0000-000000025152', '00000000-0000-0000-0000-000000025152'),
               ('d3', '00000000-0000-0000-0000-000000025154', '00000000-0000-0000-0000-000000025154'),
               ('d4', '00000000-0000-0000-0000-000000025152', null)) s(k, sid, approved)
    on right(u.id::text, 2) = s.k
 where u.id::text like '00000000-0000-0000-0000-0000000251d%';
-- Every driver online at the pickup.
insert into public.driver_presence (profile_id, online, lat, lng)
select id, true, 25.0, 115.0 from auth.users where id::text like '00000000-0000-0000-0000-0000000251d%'
on conflict (profile_id) do update set online = true, lat = 25.0, lng = 115.0, updated_at = now();

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
create or replace function pg_temp.refused_with(p_sql text, p_code text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_code in sqlerrm) > 0 then
      return;
    end if;
    raise exception 'FAILED: % refused with "%", not %', p_what, sqlerrm, p_code;
  end;
  raise exception 'FAILED (not refused): %', p_what;
end $$;
create or replace function pg_temp.book(p_rider uuid, p_service text, p_token text default null)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng, direct_qr_token)
  values (v, p_rider, 'open', p_service, 30, 30, 25.0, 115.0, 25.1, 115.1, p_token);
  return v;
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.refused_with(text, text, text), pg_temp.book(uuid, text, text), pg_temp.sees(uuid) to authenticated;

-- ---- 1. The switch: off by default, the Vehicle Services page's -----------------------------------
select pg_temp.check(not public.service_order_enforced(), 'off by default');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a2');
select pg_temp.refused($q$update public.service_order_settings set enforce_all = true where id = 1$q$,
  'another page''s admin switching it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251c1');
select pg_temp.refused($q$update public.service_order_settings set enforce_all = true where id = 1$q$,
  'a rider switching it');

-- ---- 2. Off: every driver as today ------------------------------------------------------------------
insert into rides values ('off', pg_temp.book('00000000-0000-0000-0000-0000000251c1', 'Premium 251'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'off')) = 1, 'off: a Ride driver sees a Premium order');
reset role;
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'off');

-- ---- 3. On: who reads an open request ---------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
update public.service_order_settings set enforce_all = true where id = 1;
select pg_temp.check(public.service_order_enforced(), 'the Vehicle Services editor switches it on');
insert into rides values ('comfort', pg_temp.book('00000000-0000-0000-0000-0000000251c1', 'Comfort 251'));
insert into rides values ('other', pg_temp.book('00000000-0000-0000-0000-0000000251c2', 'Tuk-tuk 251'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000251c1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'comfort')) = 1, 'the rider sees their own');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'comfort')) = 0, 'a Ride driver never sees a Comfort order');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'other')) = 1, 'an order of an unknown service: anyone');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'comfort')) = 1, 'a Comfort driver sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'comfort')) = 1, 'a Premium driver sees a lower order');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d4');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'comfort')) = 0, 'no approved service: not a ranked order');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'other')) = 1, 'no approved service: an unknown service''s order');

-- ---- 4. Who takes it --------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
select pg_temp.refused($q$update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000251d1' where id = (select id from rides where k = 'comfort')$q$,
  'a Ride driver taking a Comfort order');
select pg_temp.check(public.service_order_driver_allows('00000000-0000-0000-0000-0000000251d1', 'Comfort 251') is false
                     and public.service_order_driver_allows('00000000-0000-0000-0000-0000000251d3', 'Ride 251'),
  'the rule for one driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000251d3'
 where id = (select id from rides where k = 'comfort');
reset role;
select pg_temp.check((select partner_id from public.ride_requests where id = (select id from rides where k = 'comfort'))
  = '00000000-0000-0000-0000-0000000251d3', 'a Premium driver takes the Comfort order');
-- The claim check itself, behind the read policy: row-level security is
-- off for this statement only (rolled back with the test).
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'comfort');
set local role authenticated;
insert into rides values ('claim', pg_temp.book('00000000-0000-0000-0000-0000000251c3', 'Six 251'));
reset role;
alter table public.ride_requests disable row level security;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.refused_with($q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000251d2', offered_fare = 31
  where id = (select id from rides where k = 'claim')$q$,
  'SERVICE_ORDER_REFUSED', 'the claim check refuses a lower service');
reset role;
alter table public.ride_requests enable row level security;

-- ---- 5. Who is pushed --------------------------------------------------------------------------------
select pg_temp.check((select coalesce(string_agg(right(profile_id::text, 2), ',' order by profile_id), '')
                        from public.ride_request_pushes
                       where request_id = (select id from rides where k = 'claim') and profile_id is not null)
  = 'd3',
  'the Six order is pushed to the Premium driver only');
select pg_temp.check(not exists (select 1 from public.ride_request_pushes
                                  where request_id = (select id from rides where k = 'claim')
                                    and profile_id in ('00000000-0000-0000-0000-0000000251d1', '00000000-0000-0000-0000-0000000251d2',
                                                       '00000000-0000-0000-0000-0000000251d4')),
  'never to a lower service, or a vehicle without one');
update public.ride_requests set status = 'cancelled' where id in (select id from rides where k in ('claim', 'other'));

-- ---- 6. GET.now and My Ride --------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
create temp table qr as select (public.generate_my_qr('now', 3600))->'qr'->>'token' as token;
select pg_temp.refused_with($q$select pg_temp.book('00000000-0000-0000-0000-0000000251c4', 'Premium 251', (select token from qr))$q$,
  'SERVICE_ORDER_DIRECT', 'a GET.now code of a lower service''s driver');
insert into rides values ('direct', pg_temp.book('00000000-0000-0000-0000-0000000251c4', 'Ride 251', (select token from qr)));
reset role;
select pg_temp.check((select direct_driver_id from public.ride_requests where id = (select id from rides where k = 'direct'))
  = '00000000-0000-0000-0000-0000000251d1', 'the same code books a ride of its own service');
update public.ride_requests set status = 'cancelled' where id = (select id from rides where k = 'direct');
-- My Ride: a favourite who may not take it is left out.
insert into public.favourite_drivers (rider_id, driver_id) values
  ('00000000-0000-0000-0000-0000000251c4', '00000000-0000-0000-0000-0000000251d1'),
  ('00000000-0000-0000-0000-0000000251c4', '00000000-0000-0000-0000-0000000251d3');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251c4');
insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng,
                                  target_driver_ids)
values ('00000000-0000-0000-0000-0000000251e1', '00000000-0000-0000-0000-0000000251c4', 'open', 'Comfort 251', 30, 30,
        25.0, 115.0, 25.1, 115.1,
        array['00000000-0000-0000-0000-0000000251d1', '00000000-0000-0000-0000-0000000251d3']::uuid[]);
reset role;
select pg_temp.check((select coalesce(target_driver_ids, '{}') <@ array['00000000-0000-0000-0000-0000000251d3']::uuid[]
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000251e1'),
  'My Ride: the Ride favourite is left out of a Comfort order');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000251e1';

-- ---- 7. Scheduled rides ------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);
select public.set_scheduled_rides_config('{"enabled": true, "mode": "advance"}');
insert into public.scheduled_rides (id, rider_id, pickup_at, request, service, pickup_lat, pickup_lng, drop_lat, drop_lng, fare)
values ('00000000-0000-0000-0000-0000000251f1', '00000000-0000-0000-0000-0000000251c1', now() + interval '2 hours',
        '{"service":"Premium 251","pickup_lat":25.0,"pickup_lng":115.0,"fare":30}', 'Premium 251', 25.0, 115.0, 25.1, 115.1, 30);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_open() where id = '00000000-0000-0000-0000-0000000251f1'),
  'a Comfort driver doesn''t see a Premium booking');
select pg_temp.refused_with($q$select public.scheduled_ride_set_interest('00000000-0000-0000-0000-0000000251f1', true)$q$,
  'SERVICE_ORDER_REFUSED', 'nor shows interest in it');
select pg_temp.refused($q$select public.scheduled_ride_accept('00000000-0000-0000-0000-0000000251f1')$q$,
  'nor accepts it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(exists (select 1 from public.scheduled_rides_open() where id = '00000000-0000-0000-0000-0000000251f1'),
  'the Premium driver sees it');
select (public.scheduled_ride_accept('00000000-0000-0000-0000-0000000251f1')).id;
reset role;
select pg_temp.check((select partner_id from public.scheduled_rides where id = '00000000-0000-0000-0000-0000000251f1')
  = '00000000-0000-0000-0000-0000000251d3', 'and takes it');
select pg_temp.refused_with($q$insert into public.scheduled_ride_offers (scheduled_ride_id, kind, rider_id, from_id, to_partner_id, expires_at)
  values ('00000000-0000-0000-0000-0000000251f1', 'transfer', '00000000-0000-0000-0000-0000000251c1',
          '00000000-0000-0000-0000-0000000251d3', '00000000-0000-0000-0000-0000000251d1', now() + interval '1 hour')$q$,
  'SERVICE_ORDER_REFUSED', 'handing it to a lower service');

-- ---- 8. Off again: as today --------------------------------------------------------------------------
update public.service_order_settings set enforce_all = false where id = 1;
set local role authenticated;
insert into rides values ('off2', pg_temp.book('00000000-0000-0000-0000-0000000251c2', 'Premium 251'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d4');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'off2')) = 1, 'off: a driver without a service sees everything');
reset role;

rollback;
select 'service_order_0250: all passed';
