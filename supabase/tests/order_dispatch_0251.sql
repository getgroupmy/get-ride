-- ============================================================================
-- Regression test for migration 0251: order dispatch. Stand people see and
-- act on their own stands only, within their access; an order reaches only
-- the drivers it is offered to (assign window, closed group, open group's
-- members first, fleet); joining a group needs an admin (or, for a fleet,
-- its owner); a fleet's driver–vehicle assignment waits for an admin; the
-- money lands in the ledger once, as the stand is set up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_dispatch_0251.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('authenticated', 'public.dispatch_grant(uuid, uuid, text, text, text, uuid[], uuid, jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.dispatch_settle(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.dispatch_profile_by_phone(text)', 'execute')
     or has_function_privilege('anon', 'public.dispatch_create_order(uuid, jsonb)', 'execute') then
    raise exception 'FAILED: a server-only dispatch function is callable by the app';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000251a1', '60100000001'),  -- full admin
  ('00000000-0000-0000-0000-0000000251a2', '60100000002'),  -- sub-admin: read on Stands
  ('00000000-0000-0000-0000-0000000251a3', '60100000003'),  -- stand admin, Pavilion
  ('00000000-0000-0000-0000-0000000251a4', '60100000004'),  -- staff, broadcast only
  ('00000000-0000-0000-0000-0000000251a5', '60100000005'),  -- staff, all access
  ('00000000-0000-0000-0000-0000000251a6', '60100000006'),  -- stand admin, TBS
  ('00000000-0000-0000-0000-0000000251a7', '60100000007'),  -- fleet owner
  ('00000000-0000-0000-0000-0000000251d1', '60100000011'),  -- driver, closed group member
  ('00000000-0000-0000-0000-0000000251d2', '60100000012'),  -- driver, in no group
  ('00000000-0000-0000-0000-0000000251d3', '60100000013'),  -- driver, open group member
  ('00000000-0000-0000-0000-0000000251d4', '60100000014')   -- driver, joins the fleet
on conflict do nothing;
insert into public.profiles (id, name) select id, 'P' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000251%'
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000251a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000251a2', 'admin-dispatch-stands', 'read')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status, plate, vehicle_type) values
  ('00000000-0000-0000-0000-0000000251d1', 'Ali', '60100000011', 'approved', 'WXY 1234', 'Taxi'),
  ('00000000-0000-0000-0000-0000000251d2', 'Hafiz', '60100000012', 'approved', 'WWQ 507', 'Taxi'),
  ('00000000-0000-0000-0000-0000000251d3', 'Siti', '60100000013', 'approved', 'VDE 4471', 'Taxi'),
  ('00000000-0000-0000-0000-0000000251d4', 'Wong', '60100000014', 'approved', 'WTT 9902', 'Taxi');

insert into public.dispatch_stands (id, name, kind, code, lat, lng, allow_fixed_fare, settlement,
                                    fee_type, fee_value, fee_bearer, platform_fee_type, platform_fee_value, owner_id) values
  ('00000000-0000-0000-0000-0000000251e1', 'Pavilion KL', 'mall', 'pav', 3.149, 101.713, true, 'wallet',
   'fixed', 2, 'customer', 'percent', 20, '00000000-0000-0000-0000-0000000251a3'),
  ('00000000-0000-0000-0000-0000000251e2', 'TBS Counter 3', 'bus_terminal', 'TBS', 3.076, 101.711, true, 'outside',
   'none', 0, 'customer', 'percent', 0, null);

-- 0. The split: fixed / % fee x customer / driver x platform % / fixed (lib/src/core/dispatch.dart)
do $$
begin
  if public.dispatch_split(25, 'fixed', 3, 'customer', 'percent', 20)
       <> '{"fare": 25, "fee": 3, "platform": 0.60, "stand": 2.40, "customer": 28, "driver": 25}'::jsonb
     or public.dispatch_split(40, 'percent', 10, 'driver', 'fixed', 0.5)
       <> '{"fare": 40, "fee": 4.00, "platform": 0.5, "stand": 3.50, "customer": 40, "driver": 36.00}'::jsonb
     or public.dispatch_split(25, 'fixed', 3, 'driver', 'fixed', 5)
       <> '{"fare": 25, "fee": 3, "platform": 3, "stand": 0, "customer": 25, "driver": 22}'::jsonb
     or public.dispatch_split(33.33, 'percent', 15, 'customer', 'percent', 50)
       <> '{"fare": 33.33, "fee": 5.00, "platform": 2.50, "stand": 2.50, "customer": 38.33, "driver": 33.33}'::jsonb
     or public.dispatch_split(25, 'none', 0, 'customer', 'fixed', 1)
       <> '{"fare": 25, "fee": 0, "platform": 0, "stand": 0, "customer": 25, "driver": 25}'::jsonb then
    raise exception 'FAILED: dispatch_split %', public.dispatch_split(25, 'fixed', 3, 'customer', 'percent', 20);
  end if;
end
$$;
insert into public.dispatch_groups (id, name, kind, members_first_sec) values
  ('00000000-0000-0000-0000-0000000251f1', 'Pavilion stand drivers', 'closed', 0),
  ('00000000-0000-0000-0000-0000000251f2', 'KL city open pool', 'open', 30),
  ('00000000-0000-0000-0000-0000000251f3', 'Sunlight Taxi', 'fleet', 0);
insert into public.dispatch_stand_groups (stand_id, group_id) values
  ('00000000-0000-0000-0000-0000000251e1', '00000000-0000-0000-0000-0000000251f1'),
  ('00000000-0000-0000-0000-0000000251e1', '00000000-0000-0000-0000-0000000251f2'),
  ('00000000-0000-0000-0000-0000000251e1', '00000000-0000-0000-0000-0000000251f3'),
  ('00000000-0000-0000-0000-0000000251e2', '00000000-0000-0000-0000-0000000251f1');
insert into public.dispatch_group_members (group_id, driver_id, status) values
  ('00000000-0000-0000-0000-0000000251f1', '00000000-0000-0000-0000-0000000251d1', 'approved'),
  ('00000000-0000-0000-0000-0000000251f2', '00000000-0000-0000-0000-0000000251d3', 'approved');

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
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
create or replace function pg_temp.sees(p_id uuid) returns bigint language sql as $$
  select count(*) from public.ride_requests where id = p_id;
$$;
create or replace function pg_temp.accept(p_id uuid, p_driver uuid) returns void language sql as $$
  update public.ride_requests set status = 'accepted', partner_id = p_driver, partner_name = 'Driver'
   where id = p_id and status = 'open';
$$;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from ids where k = p_k $$;
create or replace function pg_temp.order_as(p_k text, p_stand uuid, p_order jsonb) returns void language sql as $$
  insert into ids values (p_k, (public.dispatch_create_order(p_stand, p_order)->>'id')::uuid);
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.sees(uuid), pg_temp.accept(uuid, uuid), pg_temp.id(text), pg_temp.order_as(text, uuid, jsonb)
  to authenticated;

-- 1. IDs: admins make stand admins and fleet owners; stand admins their staff --------------------
select pg_temp.check(public.dispatch_may_grant('00000000-0000-0000-0000-0000000251a1', 'stand_admin',
  array['00000000-0000-0000-0000-0000000251e1'::uuid], null), 'an admin makes a stand admin');
select pg_temp.check(not public.dispatch_may_grant('00000000-0000-0000-0000-0000000251a2', 'stand_admin',
  array['00000000-0000-0000-0000-0000000251e1'::uuid], null), 'a read-only sub-admin makes no IDs');
select public.dispatch_grant('00000000-0000-0000-0000-0000000251a1', '00000000-0000-0000-0000-0000000251a3',
  'stand_admin', 'Pavilion Mall Mgmt', '+60100000003', array['00000000-0000-0000-0000-0000000251e1'::uuid]);
select public.dispatch_grant('00000000-0000-0000-0000-0000000251a1', '00000000-0000-0000-0000-0000000251a6',
  'stand_admin', 'TBS Operations', '+60100000006', array['00000000-0000-0000-0000-0000000251e2'::uuid]);
select public.dispatch_grant('00000000-0000-0000-0000-0000000251a1', '00000000-0000-0000-0000-0000000251a7',
  'fleet_owner', 'Sunlight Taxi Sdn Bhd', '+60100000007', '{}', '00000000-0000-0000-0000-0000000251f3');
select pg_temp.check(not public.dispatch_may_grant('00000000-0000-0000-0000-0000000251a3', 'stand_admin',
  array['00000000-0000-0000-0000-0000000251e1'::uuid], null), 'a stand admin makes no stand admins');
select pg_temp.check(not public.dispatch_may_grant('00000000-0000-0000-0000-0000000251a6', 'staff',
  array['00000000-0000-0000-0000-0000000251e1'::uuid], null), 'a stand admin makes no staff for another stand');
select public.dispatch_grant('00000000-0000-0000-0000-0000000251a3', '00000000-0000-0000-0000-0000000251a4',
  'staff', 'Rizal', '+60100000004', array['00000000-0000-0000-0000-0000000251e1'::uuid], null,
  '{"broadcast": true}');
select public.dispatch_grant('00000000-0000-0000-0000-0000000251a3', '00000000-0000-0000-0000-0000000251a5',
  'staff', 'Aina', '+60100000005', array['00000000-0000-0000-0000-0000000251e1'::uuid], null,
  '{"assign": true, "broadcast": true, "fixed_fare": true, "cancel": true, "reassign": true, "reports": true}');
do $$
begin
  begin
    perform public.dispatch_grant('00000000-0000-0000-0000-0000000251a3', '00000000-0000-0000-0000-0000000251a6',
      'staff', 'x', null, array['00000000-0000-0000-0000-0000000251e2'::uuid]);
  exception when others then
    return;
  end;
  raise exception 'FAILED: a stand admin made staff at another stand';
end $$;
select pg_temp.check(public.dispatch_profile_by_phone('+60 10-000 0004') = '00000000-0000-0000-0000-0000000251a4',
  'the account is found by its phone, whatever the format');
select pg_temp.check((select count(*) = 3 from public.sms_outbox where to_phone in ('+60100000003', '+60100000004', '+60100000007')),
  'each new ID is told by SMS how to sign in');

set local role authenticated;
-- The app's own path: a phone without an account needs the function.
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a3');
select pg_temp.check(public.dispatch_grant_existing('staff', 'New', '+60 19-999 9999',
  array['00000000-0000-0000-0000-0000000251e1'::uuid]) = '{"needs_account": true}'::jsonb,
  'a phone with no account asks for one');
select pg_temp.refused($q$select public.dispatch_grant_existing('stand_admin', 'X', '+60100000012',
  array['00000000-0000-0000-0000-0000000251e1'::uuid])$q$, 'a stand admin making a stand admin from the app');
-- A stand admin changes their staff's access, nothing else.
update public.dispatch_stand_people set can_cancel = false
 where user_id = '00000000-0000-0000-0000-0000000251a4' and stand_id = '00000000-0000-0000-0000-0000000251e1';
select pg_temp.refused($q$update public.dispatch_stand_people set role = 'admin'
   where user_id = '00000000-0000-0000-0000-0000000251a4'$q$, 'a stand admin promoting staff');
select pg_temp.refused($q$update public.dispatch_stand_people set can_cancel = true
   where user_id = '00000000-0000-0000-0000-0000000251a6'$q$, 'a stand admin changing another stand''s admin');
select pg_temp.refused($q$insert into public.dispatch_stand_people (stand_id, user_id, role)
   values ('00000000-0000-0000-0000-0000000251e1', '00000000-0000-0000-0000-0000000251d2', 'admin')$q$,
  'a stand admin writing a stand admin row');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a4');
select pg_temp.refused($q$update public.dispatch_stand_people set can_assign = true
   where user_id = '00000000-0000-0000-0000-0000000251a4'$q$, 'staff giving themselves access');
select pg_temp.check(not (public.dispatch_my_stands()->0->'perms'->>'assign')::boolean
                     and (public.dispatch_my_stands()->0->'perms'->>'broadcast')::boolean,
  'the broadcast-only staff member''s stand says so');

-- 2. Staff act within their access, on their own stand ------------------------------------------
select pg_temp.refused($q$select pg_temp.order_as('x1', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "KLCC", "mode": "assign", "driver_id": "00000000-0000-0000-0000-0000000251d2"}')$q$,
  'broadcast-only staff assigning a driver');
select pg_temp.refused($q$select pg_temp.order_as('x2', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "KLCC", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1",
    "fare_mode": "fixed", "fare": 20}')$q$, 'staff without Fixed fare setting one');
select pg_temp.refused($q$select pg_temp.order_as('x3', '00000000-0000-0000-0000-0000000251e2',
  '{"drop_name": "KLCC", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1"}')$q$,
  'staff ordering at another stand');
select pg_temp.order_as('closed', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Mid Valley", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1",
    "customer_name": "Mr Tan", "customer_phone": "+60 12-555 0001", "payment": "counter"}');
select pg_temp.check((select ticket_no = 'PAV-0001' from public.ride_requests where id = pg_temp.id('closed')),
  'the ticket number starts with the stand''s code');
select pg_temp.refused($q$select public.dispatch_order_action(pg_temp.id('closed'), 'cancel')$q$,
  'staff without Cancel cancelling');
reset role;
select pg_temp.check((select count(*) = 1 from public.sms_outbox where to_phone = '+60125550001'),
  'the customer is sent their ticket');
set local role authenticated;

-- 3. Each stand sees its own orders ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a6');
select pg_temp.order_as('tbs', '00000000-0000-0000-0000-0000000251e2',
  '{"drop_name": "Cheras", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1",
    "fare_mode": "fixed", "fare": 35, "payment": "counter"}');
select pg_temp.check(pg_temp.sees(pg_temp.id('closed')) = 0, 'the other stand''s admin does not see Pavilion''s order');
select pg_temp.refused($q$select public.dispatch_board('00000000-0000-0000-0000-0000000251e1')$q$,
  'the other stand''s admin reading Pavilion''s board');
select pg_temp.refused($q$select public.dispatch_order_action(pg_temp.id('closed'), 'cancel')$q$,
  'the other stand''s admin cancelling Pavilion''s order');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a4');
select pg_temp.check(pg_temp.sees(pg_temp.id('tbs')) = 0 and pg_temp.sees(pg_temp.id('closed')) = 1,
  'staff see their own stand''s orders only');
select pg_temp.check(jsonb_array_length(public.dispatch_board()) = 1, 'the board holds their stand only');

-- The car Ali drives today (his active session): colour, make, model, plate.
reset role;
insert into public.vehicle (id, plate, color, make, model, status) values
  ('00000000-0000-0000-0000-0000000251c2', 'VBA 8821', 'Silver', 'Toyota', 'Vios', 'approved');
insert into public.vehicle_active_session (vehicle_id, user_id)
values ('00000000-0000-0000-0000-0000000251c2', '00000000-0000-0000-0000-0000000251d1');
insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
values ('00000000-0000-0000-0000-0000000251d1', true, 3.1491, 101.7131, now())
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng, updated_at = now();
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.check((select d->>'vehicle' = 'Silver Toyota Vios' and d->>'plate' = 'VBA 8821' and d->>'state' = 'at_stand'
                        from jsonb_array_elements(public.dispatch_drivers('00000000-0000-0000-0000-0000000251e1')) d
                       where d->>'id' = '00000000-0000-0000-0000-0000000251d1'),
  'the driver list shows the car the driver is driving, not just their record''s');

-- 4. A closed group's order: its members only ----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('closed')) = 0, 'a driver outside the closed group does not see it');
select pg_temp.refused($q$update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000251d2' where id = pg_temp.id('closed') and status = 'open'$q$,
  'a driver outside the closed group taking it');
select pg_temp.refused($q$update public.ride_requests set dispatch_widened_at = now() where id = pg_temp.id('closed')$q$,
  'a driver widening an order');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, stand_id, ticket_no, dispatch_mode)
  values ('00000000-0000-0000-0000-0000000251d2', 'open', '00000000-0000-0000-0000-0000000251e1', 'PAV-9999', 'assign')$q$,
  'an app making a stand order directly');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
select pg_temp.check(pg_temp.sees(pg_temp.id('closed')) = 1, 'the closed group''s member sees it');
select pg_temp.accept(pg_temp.id('closed'), '00000000-0000-0000-0000-0000000251d1');
select pg_temp.check((select status = 'accepted' from public.ride_requests where id = pg_temp.id('closed')),
  'the member takes it');
reset role;
select pg_temp.check((select partner_vehicle = 'Silver Toyota Vios' and partner_plate = 'VBA 8821'
                        from public.ride_requests where id = pg_temp.id('closed')),
  'the order carries the car the driver is driving');
select pg_temp.check(exists (select 1 from public.sms_outbox where to_phone = '+60125550001'
                               and body like '%your driver is Ali, Silver Toyota Vios, VBA 8821%'),
  'the customer is texted the driver, the car and the plate');
set local role authenticated;

-- 5. Assigned: the driver, for 30 seconds, then back to the stand ---------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.order_as('assign', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Bangsar", "mode": "assign", "driver_id": "00000000-0000-0000-0000-0000000251d2", "payment": "cash"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(pg_temp.sees(pg_temp.id('assign')) = 0, 'another driver does not see an assigned order');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('assign')) = 1, 'the assigned driver sees it');
reset role;
update public.ride_requests set dispatch_offer_until = now() - interval '1 second' where id = pg_temp.id('assign');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('assign')) = 0, 'after 30 s the order is no longer offered');
select pg_temp.refused($q$update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000251d2' where id = pg_temp.id('assign') and status = 'open'$q$,
  'taking an assigned order after its window');
reset role;
select public.dispatch_tick();
select pg_temp.check((select dispatch_returned_at is not null from public.ride_requests where id = pg_temp.id('assign'))
  and exists (select 1 from public.dispatch_order_events where request_id = pg_temp.id('assign') and action = 'no_answer'),
  'the clock puts it back with the stand, logged');

-- 6. An open group: members first, then anyone ------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.order_as('open', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "KL Sentral", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f2"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(pg_temp.sees(pg_temp.id('open')) = 1, 'an open group''s member sees it at once');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('open')) = 0, 'a non-member waits the members'' time');
reset role;
update public.ride_requests set dispatch_open_after = now() - interval '1 second' where id = pg_temp.id('open');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('open')) = 1, 'after the members'' time anyone sees it');
-- Re-send widens a closed group's waiting order to anyone.
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select public.dispatch_order_action(pg_temp.id('assign'), 'widen');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(pg_temp.sees(pg_temp.id('assign')) = 1, 'a widened order reaches any driver');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a4');
select pg_temp.check((select bool_or(e->>'actor' = 'Aina')
                        from jsonb_array_elements(public.dispatch_order(pg_temp.id('assign'))->'events') e
                       where e->>'action' = 'widened'), 'the action log names who widened it');

-- 7. Joining: an admin approves groups, the owner their fleet ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
insert into public.dispatch_group_members (group_id, driver_id, status)
values ('00000000-0000-0000-0000-0000000251f1', '00000000-0000-0000-0000-0000000251d2', 'approved');
select pg_temp.check((select status = 'pending' from public.dispatch_group_members
                       where group_id = '00000000-0000-0000-0000-0000000251f1'
                         and driver_id = '00000000-0000-0000-0000-0000000251d2'), 'a driver''s own row is a request');
select pg_temp.refused($q$update public.dispatch_group_members set status = 'approved'
   where driver_id = '00000000-0000-0000-0000-0000000251d2'$q$, 'a driver approving themself');
insert into public.dispatch_group_members (group_id, driver_id)
values ('00000000-0000-0000-0000-0000000251f3', '00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(not public.dispatch_member_of('00000000-0000-0000-0000-0000000251f1',
  '00000000-0000-0000-0000-0000000251d2'), 'a request is no membership');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a7');
select pg_temp.refused($q$update public.dispatch_group_members set status = 'approved'
   where group_id = '00000000-0000-0000-0000-0000000251f1'$q$, 'a fleet owner approving for a closed group');
update public.dispatch_group_members set status = 'rejected'
 where group_id = '00000000-0000-0000-0000-0000000251f3' and driver_id = '00000000-0000-0000-0000-0000000251d2';
select public.dispatch_fleet_add('00000000-0000-0000-0000-0000000251f3', 'wtt 9902');
select pg_temp.check(public.dispatch_member_of('00000000-0000-0000-0000-0000000251f3',
  '00000000-0000-0000-0000-0000000251d4'), 'the fleet owner adds a driver by plate');
select pg_temp.refused($q$select public.dispatch_fleet('00000000-0000-0000-0000-0000000251f2')$q$,
  'a fleet owner reading another group');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
update public.dispatch_group_members set status = 'approved'
 where group_id = '00000000-0000-0000-0000-0000000251f1' and driver_id = '00000000-0000-0000-0000-0000000251d2';
select pg_temp.check(public.dispatch_member_of('00000000-0000-0000-0000-0000000251f1',
  '00000000-0000-0000-0000-0000000251d2'), 'an admin''s approval makes the member');

-- 8. A fleet's order reaches its drivers -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.order_as('fleet', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Cheras", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f3"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d4');
select pg_temp.check(pg_temp.sees(pg_temp.id('fleet')) = 1, 'the fleet''s driver sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(pg_temp.sees(pg_temp.id('fleet')) = 0, 'a driver outside the fleet does not');

-- 9. Money: paid at the counter into the wallet; cash with a driver-borne fee; settled outside --------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select public.dispatch_order_action(pg_temp.id('closed'), 'picked_up');
select public.dispatch_order_action(pg_temp.id('closed'), 'complete', '{"fare": 30}');
reset role;
select pg_temp.check((select count(*) = 1 and sum(amount) = 30 from public.wallet_transactions
                       where ride_id = pg_temp.id('closed') and kind = 'stand_payout'
                         and user_id = '00000000-0000-0000-0000-0000000251d1' and wallet_type = 'get_wallet'),
  'the counter fare is paid into the driver''s wallet');
select pg_temp.check((select payment_status = 'paid' and paid_method = 'counter' and paid_amount = 32
                             and stand_fee_amount = 2 and dispatch_settled_at is not null
                        from public.ride_requests where id = pg_temp.id('closed')),
  'the customer paid the fare and the booking fee at the counter');
select pg_temp.check((select amount = -30 from public.wallet_transactions where ride_id = pg_temp.id('closed')
                        and kind = 'stand_payout_due' and user_id = '00000000-0000-0000-0000-0000000251a3')
  and (select amount = -0.40 from public.wallet_transactions where ride_id = pg_temp.id('closed')
        and kind = 'stand_platform_fee' and user_id = '00000000-0000-0000-0000-0000000251a3')
  and (select stand_platform_fee = 0.40 from public.ride_requests where id = pg_temp.id('closed')),
  'the stand owes the driver''s fare and the platform''s 20% of its RM 2 fee, and keeps RM 1.60');
select public.dispatch_settle(pg_temp.id('closed'));
select pg_temp.check((select count(*) = 3 from public.wallet_transactions where ride_id = pg_temp.id('closed')
                        and kind like 'stand%'), 'settled once');

-- The fee: the admin's unless the admin lets the stand set it; never staff's.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a3');
select pg_temp.refused($q$select public.dispatch_set_stand_fee('00000000-0000-0000-0000-0000000251e1', 'fixed', 9, 'customer')$q$,
  'a stand admin changing a fee the admin sets');
select pg_temp.refused($q$update public.dispatch_stands set platform_fee_value = 0 where id = '00000000-0000-0000-0000-0000000251e1'$q$,
  'a stand admin changing the platform fee');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
update public.dispatch_stands set fee_set_by = 'stand', platform_fee_type = 'fixed', platform_fee_value = 0.5
 where id = '00000000-0000-0000-0000-0000000251e1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.refused($q$select public.dispatch_set_stand_fee('00000000-0000-0000-0000-0000000251e1', 'fixed', 9, 'customer')$q$,
  'staff changing the stand fee');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a3');
select public.dispatch_set_stand_fee('00000000-0000-0000-0000-0000000251e1', 'percent', 10, 'driver');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.order_as('cash', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Ampang", "mode": "assign", "driver_id": "00000000-0000-0000-0000-0000000251d4",
    "fare_mode": "fixed", "fare": 50, "payment": "cash"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d4');
select pg_temp.accept(pg_temp.id('cash'), '00000000-0000-0000-0000-0000000251d4');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select public.dispatch_order_action(pg_temp.id('cash'), 'picked_up');
select public.dispatch_order_action(pg_temp.id('cash'), 'complete');
reset role;
select pg_temp.check((select amount = -5 and wallet_type = 'get_credit' from public.wallet_transactions
                       where ride_id = pg_temp.id('cash') and kind = 'stand_fee'
                         and user_id = '00000000-0000-0000-0000-0000000251d4'),
  'the driver who took the cash pays the 10% fee from GET.credit');
select pg_temp.check((select amount = 4.50 from public.wallet_transactions
                       where ride_id = pg_temp.id('cash') and kind = 'stand_fee_earning'
                         and user_id = '00000000-0000-0000-0000-0000000251a3'),
  'the stand earns its fee less the platform''s RM 0.50');
select pg_temp.check((select (t->>'platform')::numeric = 0.90 and (t->>'stand')::numeric = 6.10
                        from (select public.dispatch_statement('00000000-0000-0000-0000-0000000251e1',
                                now() - interval '1 day', now() + interval '1 day')->'totals' t) x),
  'the stand''s statement adds up its fees and the platform''s');
select pg_temp.check((select paid_amount = 50 and public.ride_net_earnings(r) = 45 - coalesce(r.commission_amount, 0)
                        from public.ride_requests r where id = pg_temp.id('cash')),
  'the customer paid the fare; the driver keeps it less the fee');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
select pg_temp.accept(pg_temp.id('tbs'), '00000000-0000-0000-0000-0000000251d1');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a6');
select public.dispatch_order_action(pg_temp.id('tbs'), 'picked_up');
select public.dispatch_order_action(pg_temp.id('tbs'), 'complete');
reset role;
select pg_temp.check(not exists (select 1 from public.wallet_transactions where ride_id = pg_temp.id('tbs'))
  and (select payment_status = 'paid' and paid_method = 'counter' from public.ride_requests where id = pg_temp.id('tbs')),
  'settled outside the app: paid, and no wallet moves');

-- A metered order: the driver completes it at the meter's fare.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.order_as('meter', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Sentul", "mode": "assign", "driver_id": "00000000-0000-0000-0000-0000000251d2", "payment": "cash"}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.accept(pg_temp.id('meter'), '00000000-0000-0000-0000-0000000251d2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select public.dispatch_order_action(pg_temp.id('meter'), 'picked_up');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.refused($q$select public.dispatch_driver_complete(pg_temp.id('meter'), 22)$q$,
  'another driver completing the trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select public.dispatch_driver_complete(pg_temp.id('meter'), 22);
reset role;
select pg_temp.check((select status = 'completed' and ride_fare = 22 and dispatch_settled_at is not null
                        from public.ride_requests where id = pg_temp.id('meter')),
  'the metered trip is done at the meter''s fare and settled');

-- 10. Reports need the access -----------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a4');
select pg_temp.refused($q$select public.dispatch_report('00000000-0000-0000-0000-0000000251e1')$q$,
  'staff without See reports reading the report');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.check((public.dispatch_report('00000000-0000-0000-0000-0000000251e1')->>'done')::int = 3,
  'staff with See reports read it');

-- 11. A fleet vehicle's driver waits for an admin -------------------------------------------------------
reset role;
insert into public.vehicle (id, auth_user_id, plate, status) values
  ('00000000-0000-0000-0000-0000000251c1', '00000000-0000-0000-0000-0000000251a7', 'FLT 1', 'unapproved');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a7');
select public.dispatch_fleet_link_vehicle('00000000-0000-0000-0000-0000000251f3', '00000000-0000-0000-0000-0000000251c1');
select pg_temp.refused($q$update public.vehicle set status = 'approved' where id = '00000000-0000-0000-0000-0000000251c1'$q$,
  'a fleet owner approving their vehicle');
select public.dispatch_fleet_assign('00000000-0000-0000-0000-0000000251f3', '00000000-0000-0000-0000-0000000251c1',
  '00000000-0000-0000-0000-0000000251d4');
select pg_temp.refused($q$select public.dispatch_fleet_assign('00000000-0000-0000-0000-0000000251f3',
  '00000000-0000-0000-0000-0000000251c1', '00000000-0000-0000-0000-0000000251d3')$q$, 'assigning a driver not in the fleet');
select pg_temp.check((select v->'drivers'->0->>'approval' = 'pending'
                        from jsonb_array_elements(public.dispatch_fleet_vehicles('00000000-0000-0000-0000-0000000251f3')) v),
  'the fleet owner sees the assignment waiting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a6');
select pg_temp.refused($q$select public.dispatch_fleet_vehicles('00000000-0000-0000-0000-0000000251f3')$q$,
  'someone else reading the fleet''s vehicles');
reset role;
update public.vehicle set status = 'approved' where id = '00000000-0000-0000-0000-0000000251c1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d4');
select pg_temp.refused($q$select public.claim_vehicle('00000000-0000-0000-0000-0000000251c1', '00000000-0000-0000-0000-0000000251d4')$q$,
  'driving on an assignment an admin has not approved');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
update public.vehicle_user_assignment set approval = 'approved'
 where vehicle_id = '00000000-0000-0000-0000-0000000251c1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d4');
select public.claim_vehicle('00000000-0000-0000-0000-0000000251c1', '00000000-0000-0000-0000-0000000251d4');

-- 12. Admin pages: read is not write -----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a2');
select pg_temp.refused($q$insert into public.dispatch_stands (name, code, lat, lng) values ('X', 'XX', 1, 1)$q$,
  'a read-only sub-admin adding a stand');
select pg_temp.refused($q$select public.dispatch_create_order('00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "X", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1"}')$q$,
  'a read-only sub-admin ordering');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
insert into public.dispatch_stands (name, code, lat, lng) values ('Hilton', 'hil', 3.1, 101.6);
select pg_temp.check((select code = 'HIL' from public.dispatch_stands where name = 'Hilton'), 'an admin adds a stand');
reset role;

-- 13. The Call centre: admins only; a customer's own account, or a guest ------------------------------
reset role;
insert into auth.users (id, phone) values ('00000000-0000-0000-0000-0000000251b1', '60100000021')
on conflict do nothing;
insert into public.profiles (id, name, phone) values ('00000000-0000-0000-0000-0000000251b1', 'Nur Aisyah', '60100000021')
on conflict (id) do update set name = excluded.name;
insert into ids select 'call', id from public.dispatch_stands where admin_only and kind = 'call_centre';
select pg_temp.check(pg_temp.id('call') is not null, 'the Call centre pickup exists');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.dispatch_my_stands()) x
                                  where x->>'id' = pg_temp.id('call')::text),
  'stand staff don''t see the Call centre');
select pg_temp.check((select count(*) = 0 from public.dispatch_stands where id = pg_temp.id('call')),
  'stand staff can''t read the Call centre row');
select pg_temp.refused($q$select public.dispatch_lookup_customer('+60100000021')$q$, 'staff looking up a customer');
select pg_temp.refused($q$select public.dispatch_create_order(pg_temp.id('call'),
  '{"drop_name": "KLCC", "mode": "nearby", "customer_name": "X", "customer_phone": "+60100000021",
    "booked_via": "phone", "pickup_name": "Home", "pickup_lat": 3.1, "pickup_lng": 101.7}')$q$,
  'staff booking from the Call centre');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a3');
select pg_temp.refused($q$select public.dispatch_grant_existing('staff', 'X', '+60100000012', array[pg_temp.id('call')])$q$,
  'a stand admin putting staff on the Call centre');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a2');
select pg_temp.refused($q$select public.dispatch_lookup_customer('+60100000021')$q$, 'a read-only sub-admin looking up a customer');

select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
select pg_temp.check(exists (select 1 from jsonb_array_elements(public.dispatch_my_stands()) x
                              where x->>'id' = pg_temp.id('call')::text and (x->>'admin_only')::boolean),
  'admins have the Call centre');
select pg_temp.check(public.dispatch_lookup_customer('+60 10-000 0021') = '{"found": true, "name": "Nur Aisyah"}'::jsonb,
  'the console finds the customer''s account by phone');
select pg_temp.refused($q$select public.dispatch_create_order(pg_temp.id('call'),
  '{"drop_name": "KLCC", "mode": "nearby", "customer_phone": "+60100000021", "booked_via": "phone",
    "pickup_name": "Home", "pickup_lat": 3.1, "pickup_lng": 101.7}')$q$, 'a phone booking without the customer''s name');
select pg_temp.order_as('acct', pg_temp.id('call'),
  '{"drop_name": "KLCC", "mode": "nearby", "customer_name": "Nur Aisyah", "customer_phone": "+60 10-000 0021",
    "booked_via": "whatsapp", "pickup_name": "Menara A", "pickup_address": "Jalan Ampang", "pickup_lat": 3.155,
    "pickup_lng": 101.715, "fare_mode": "estimate", "fare": 18}');
select pg_temp.refused($q$select pg_temp.order_as('acct2', pg_temp.id('call'),
  '{"drop_name": "KLCC", "mode": "nearby", "customer_name": "Nur Aisyah", "customer_phone": "+60100000021",
    "booked_via": "phone", "pickup_name": "Menara A", "pickup_lat": 3.155, "pickup_lng": 101.715}')$q$,
  'a second ride on the go for the same customer');
reset role;
select pg_temp.check((select rider_id = '00000000-0000-0000-0000-0000000251b1'
                             and dispatch_created_by = '00000000-0000-0000-0000-0000000251a1'
                             and dispatch_booked_via = 'whatsapp' and ticket_no = 'CALL-0001'
                             and payment_mode = 'Cash' and stand_fee_amount is null and pickup_name = 'Menara A'
                        from public.ride_requests where id = pg_temp.id('acct')),
  'booked on the customer''s own account, by the admin, cash, no stand fee');
select pg_temp.check(not exists (select 1 from public.sms_outbox where to_phone = '+60100000021'),
  'an account holder is not texted: their app has it');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251b1');
select pg_temp.check(pg_temp.sees(pg_temp.id('acct')) = 1, 'the customer sees the ride in their app');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('acct')) = 1, 'a nearby booking reaches any approved driver');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, rider_name)
  values ('00000000-0000-0000-0000-0000000251b1', 'open', 'Nur')$q$, 'booking as someone else from the app');

select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
select pg_temp.order_as('guest', pg_temp.id('call'),
  '{"drop_name": "Bangsar", "mode": "nearby", "customer_name": "Mr Lim", "customer_phone": "+60 19-888 7777",
    "booked_via": "phone", "pickup_name": "Taman Tun", "pickup_lat": 3.14, "pickup_lng": 101.63}');
reset role;
select pg_temp.check((select rider_id is null and stand_id = pg_temp.id('call') from public.ride_requests where id = pg_temp.id('guest'))
  and exists (select 1 from public.sms_outbox where to_phone = '+60198887777' and body like '%CALL-0002%'),
  'no account: a guest, texted the ticket and the tracking link');

-- 14. Booked ahead: the scheduled-rides machinery ---------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
insert into ids values ('ahead', ((public.dispatch_create_order('00000000-0000-0000-0000-0000000251e1',
  jsonb_build_object('drop_name', 'KLIA', 'mode', 'assign', 'driver_id', '00000000-0000-0000-0000-0000000251d3',
                     'fare_mode', 'fixed', 'fare', 95, 'pickup_at', now() + interval '3 hours', 'lead_minutes', 30)))->>'id')::uuid);
select pg_temp.check((select b->>'kind' = 'scheduled' and b->>'trip_code' is not null
                        from jsonb_array_elements(public.dispatch_board('00000000-0000-0000-0000-0000000251e1')) b
                       where b->>'id' = pg_temp.id('ahead')::text),
  'a booking ahead is on the board, with its trip code');
select pg_temp.refused($q$select public.dispatch_create_order('00000000-0000-0000-0000-0000000251e1',
  jsonb_build_object('drop_name', 'KLIA', 'mode', 'broadcast', 'group_id', '00000000-0000-0000-0000-0000000251f1',
                     'pickup_at', now() + interval '20 minutes', 'lead_minutes', 30))$q$, 'a pickup sooner than its lead time');
reset role;
select pg_temp.check((select stand_id = '00000000-0000-0000-0000-0000000251e1' and rider_id is null and lead_minutes = 30
                             and request->>'ticket_no' like 'PAV-%' and status = 'scheduled'
                        from public.scheduled_rides where id = pg_temp.id('ahead')),
  'it is a scheduled ride of the stand''s, with no rider');
insert into ids select 'offer', id from public.scheduled_ride_offers where scheduled_ride_id = pg_temp.id('ahead') and status = 'pending';
select pg_temp.check(pg_temp.id('offer') is not null, 'the assigned driver is asked to confirm now');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.refused($q$select public.scheduled_ride_accept(pg_temp.id('ahead'))$q$, 'another driver taking a stand''s booking');
select pg_temp.check(not exists (select 1 from public.scheduled_rides_open() o where o.id = pg_temp.id('ahead'))
  and not exists (select 1 from public.scheduled_rides_upcoming() o where o.id = pg_temp.id('ahead')),
  'a stand''s booking is not on drivers'' open lists');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select public.scheduled_ride_offer_respond(pg_temp.id('offer'), true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a4');
select pg_temp.refused($q$select public.dispatch_scheduled_action(pg_temp.id('ahead'), 'cancel')$q$, 'staff without Cancel cancelling it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.check((select b->>'driver_confirmed' = 'true'
                        from jsonb_array_elements(public.dispatch_board('00000000-0000-0000-0000-0000000251e1')) b
                       where b->>'id' = pg_temp.id('ahead')::text), 'the board says the driver confirmed');
select public.dispatch_scheduled_action(pg_temp.id('ahead'), 'reschedule',
  jsonb_build_object('pickup_at', now() + interval '4 hours', 'lead_minutes', 60));
insert into ids values ('ahead_ride', (public.dispatch_scheduled_action(pg_temp.id('ahead'), 'release')->>'id')::uuid);
reset role;
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000251d3'
                             and stand_id = '00000000-0000-0000-0000-0000000251e1' and ticket_no like 'PAV-%'
                             and scheduled_ride_id = pg_temp.id('ahead') and fare = 95
                        from public.ride_requests where id = pg_temp.id('ahead_ride')),
  'sent out now: the confirmed driver has the stand''s order');
select pg_temp.check((select count(*) >= 3 from public.dispatch_order_events
                       where scheduled_ride_id = pg_temp.id('ahead')), 'the booking''s log');

-- A broadcast booking goes out at pickup less its lead time, to the group.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
insert into ids values ('ahead2', ((public.dispatch_create_order('00000000-0000-0000-0000-0000000251e1',
  jsonb_build_object('drop_name', 'Sunway', 'mode', 'broadcast', 'group_id', '00000000-0000-0000-0000-0000000251f1',
                     'pickup_at', now() + interval '2 hours', 'lead_minutes', 15)))->>'id')::uuid);
reset role;
select public.scheduled_rides_tick();
select pg_temp.check((select status = 'scheduled' from public.scheduled_rides where id = pg_temp.id('ahead2')),
  'not yet: two hours to go');
update public.scheduled_rides set pickup_at = now() + interval '10 minutes' where id = pg_temp.id('ahead2');
select public.scheduled_rides_tick();
insert into ids select 'ahead2_ride', ride_id from public.scheduled_rides where id = pg_temp.id('ahead2');
select pg_temp.check((select status = 'open' and dispatch_offered_at is not null and dispatch_mode = 'broadcast'
                        from public.ride_requests where id = pg_temp.id('ahead2_ride')),
  'released at pickup less 15 minutes, to the group');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d1');
select pg_temp.check(pg_temp.sees(pg_temp.id('ahead2_ride')) = 1, 'the group''s member sees the released order');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d3');
select pg_temp.check(pg_temp.sees(pg_temp.id('ahead2_ride')) = 0, 'a driver outside the group does not');

-- A stand booking can be cancelled before it goes out.
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
insert into ids values ('ahead3', ((public.dispatch_create_order('00000000-0000-0000-0000-0000000251e1',
  jsonb_build_object('drop_name', 'Mont Kiara', 'mode', 'broadcast', 'group_id', '00000000-0000-0000-0000-0000000251f1',
                     'pickup_at', now() + interval '5 hours', 'lead_minutes', 30)))->>'id')::uuid);
select public.dispatch_scheduled_action(pg_temp.id('ahead3'), 'cancel');
reset role;
select pg_temp.check((select status = 'cancelled' and cancelled_by = 'admin' from public.scheduled_rides
                       where id = pg_temp.id('ahead3')), 'cancelled at the stand');

-- A rider can't slip a stand's fields into their own booking.
insert into public.app_settings (key, value) values ('scheduled_rides', '{"enabled": true}')
on conflict (key) do update set value = excluded.value;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251b1');
insert into ids values ('mine', (public.schedule_ride(jsonb_build_object(
  'fare', 30, 'pickup_lat', 3.1, 'pickup_lng', 101.6, 'drop_name', 'KLCC',
  'stand_id', '00000000-0000-0000-0000-0000000251e1', 'ticket_no', 'PAV-9999', 'dispatch_mode', 'broadcast'),
  now() + interval '2 hours')).id);
reset role;
select pg_temp.check((select stand_id is null and not (request ? 'stand_id') and not (request ? 'ticket_no')
                        from public.scheduled_rides where id = pg_temp.id('mine')),
  'a rider''s booking keeps no stand fields');

-- 15. The service order (0250) and a stand at an airport (0249) -------------------------------------
reset role;
insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000251d5', '60100000015'),  -- driver, Ride 251 vehicle
  ('00000000-0000-0000-0000-0000000251d6', '60100000016')   -- driver, Premium 251 vehicle
on conflict do nothing;
insert into public.profiles (id, name) values
  ('00000000-0000-0000-0000-0000000251d5', 'Kumar'), ('00000000-0000-0000-0000-0000000251d6', 'Lina')
on conflict (id) do update set name = excluded.name;
insert into public.partners (auth_user_id, name, phone, status, plate, vehicle_type) values
  ('00000000-0000-0000-0000-0000000251d5', 'Kumar', '60100000015', 'approved', 'BKR 15', 'Ride 251'),
  ('00000000-0000-0000-0000-0000000251d6', 'Lina', '60100000016', 'approved', 'BLN 16', 'Premium 251');
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000025161', 'vehicle-services', '{"name":"Ride 251"}', 1),
  ('00000000-0000-0000-0000-000000025164', 'vehicle-services', '{"name":"Premium 251"}', 4);
delete from public.vehicle_service_order;
insert into public.vehicle_service_order (service_id, rank) values
  ('00000000-0000-0000-0000-000000025161', 1), ('00000000-0000-0000-0000-000000025164', 4);
insert into public.vehicle (auth_user_id, plate, make, model, color, status, service_id, service_approved_id) values
  ('00000000-0000-0000-0000-0000000251d5', 'BKR 15', 'Perodua', 'Bezza', 'White', 'approved',
   '00000000-0000-0000-0000-000000025161', '00000000-0000-0000-0000-000000025161'),
  ('00000000-0000-0000-0000-0000000251d6', 'BLN 16', 'Toyota', 'Camry', 'Black', 'approved',
   '00000000-0000-0000-0000-000000025164', '00000000-0000-0000-0000-000000025164');
insert into public.dispatch_group_members (group_id, driver_id, status) values
  ('00000000-0000-0000-0000-0000000251f1', '00000000-0000-0000-0000-0000000251d5', 'approved'),
  ('00000000-0000-0000-0000-0000000251f1', '00000000-0000-0000-0000-0000000251d6', 'approved')
on conflict do nothing;
insert into public.driver_presence (profile_id, online, lat, lng)
select id, true, 3.149, 101.713 from auth.users
 where id in ('00000000-0000-0000-0000-0000000251d5', '00000000-0000-0000-0000-0000000251d6')
on conflict (profile_id) do update set online = true, lat = 3.149, lng = 101.713, updated_at = now();
update public.service_order_settings set enforce_all = true where id = 1;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.check((select x->>'service' = 'Premium 251' from jsonb_array_elements(
                        public.dispatch_drivers('00000000-0000-0000-0000-0000000251e1')) x
                       where x->>'id' = '00000000-0000-0000-0000-0000000251d6'),
  'the driver list shows the vehicle''s approved service');
select pg_temp.refused($q$select pg_temp.order_as('so_low', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "KLCC", "service": "Premium 251", "mode": "assign", "driver_id": "00000000-0000-0000-0000-0000000251d5"}')$q$,
  'assigning a Premium order to a Ride vehicle');
select pg_temp.order_as('so_bc', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "KLCC", "service": "Premium 251", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1"}');
select pg_temp.check(pg_temp.sees(pg_temp.id('so_bc')) = 1, 'the stand''s staff see the order the service order hides');
select pg_temp.refused($q$select public.dispatch_order_action(pg_temp.id('so_bc'), 'resend',
  '{"driver_id": "00000000-0000-0000-0000-0000000251d5"}')$q$, 're-sending a Premium order to a Ride vehicle');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d5');
select pg_temp.check(pg_temp.sees(pg_temp.id('so_bc')) = 0, 'a lower-service group member does not see it');
select pg_temp.refused($q$update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000251d5',
  partner_name = 'Kumar' where id = pg_temp.id('so_bc') and status = 'open'$q$, 'a lower-service group member taking it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d6');
select pg_temp.check(pg_temp.sees(pg_temp.id('so_bc')) = 1, 'a Premium group member sees it');
reset role;
select pg_temp.check(not exists (select 1 from public.ride_request_pushes
                                  where request_id = pg_temp.id('so_bc') and profile_id = '00000000-0000-0000-0000-0000000251d5'),
  'the lower-service member is not pushed');
update public.ride_requests set status = 'cancelled', cancelled_at = now() where id = pg_temp.id('so_bc');
update public.service_order_settings set enforce_all = false where id = 1;

-- The stand is inside an airport whose pickups go to its queue, and no one waits there.
insert into public.airport_areas (id, values) values
  ('00000000-0000-0000-0000-0000000251e9', jsonb_build_object('name', 'Stand Airport', 'code', 'SAP',
    'boundary', '{"coords":[{"latitude":3.16,"longitude":101.70},{"latitude":3.16,"longitude":101.72},{"latitude":3.14,"longitude":101.72},{"latitude":3.14,"longitude":101.70}],"bbox":{"north":3.16,"south":3.14,"east":101.72,"west":101.70}}'));
update public.airport_settings set restrict_pickups = true, pickup_from = '{queue}', empty_action = 'decline',
                                   pick_door_required = false
 where airport_id = '00000000-0000-0000-0000-0000000251e9';
select set_config('dispatch_test.before', coalesce(current_setting('getride.airport_server', true), ''), true);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a5');
select pg_temp.order_as('ap_fixed', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Bangsar", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-0000000251f1",
    "fare_mode": "fixed", "fare": 21}');
select pg_temp.order_as('ap_assign', '00000000-0000-0000-0000-0000000251e1',
  '{"drop_name": "Cheras", "mode": "assign", "driver_id": "00000000-0000-0000-0000-0000000251d6"}');
reset role;
select pg_temp.check((select bool_and(status = 'open' and not airport_hold and airport_open_at is null
                                      and airport_pickup_id = '00000000-0000-0000-0000-0000000251e9'
                                      and airport_fare is null)
                        from public.ride_requests where id in (pg_temp.id('ap_fixed'), pg_temp.id('ap_assign'))),
  'a stand''s own orders at an airport are not held for its queue');
select pg_temp.check((select fare = 21 from public.ride_requests where id = pg_temp.id('ap_fixed')),
  'and keep the stand''s fare');
select pg_temp.check(coalesce(current_setting('getride.airport_server', true), '') = current_setting('dispatch_test.before'),
  'the airport step is left as it was');
update public.airport_settings set empty_action = 'wait' where airport_id = '00000000-0000-0000-0000-0000000251e9';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000251a1');
select pg_temp.order_as('ap_near', pg_temp.id('call'),
  '{"drop_name": "Ampang", "mode": "nearby", "customer_name": "Mr Tan", "customer_phone": "+60 19-777 1234",
    "booked_via": "sms", "pickup_name": "Arrival hall", "pickup_lat": 3.15, "pickup_lng": 101.71}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000251d2');
select pg_temp.check(pg_temp.sees(pg_temp.id('ap_near')) = 0, 'a nearby booking at the airport is held for its queue');
reset role;
select pg_temp.check((select airport_hold from public.ride_requests where id = pg_temp.id('ap_near')),
  'the Call centre''s nearby booking follows the airport''s rules');

select 'order_dispatch_0251: all passed';
rollback;
