-- ============================================================================
-- Regression test for migration 0259: partner type services -- who writes
-- the rules (the page's EDIT grant, not any admin), the server's stamps, and
-- which partners see an open request of each service (any of their types
-- allows it; a type without a row sees every service; the rider always
-- sees their own).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_type_services_0259.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000259a1'),  -- admin, EDIT on Partner type services
  ('00000000-0000-0000-0000-0000000259a2'),  -- admin, READ on Partner type services
  ('00000000-0000-0000-0000-0000000259a3'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000259c1'),  -- riders
  ('00000000-0000-0000-0000-0000000259c2'),
  ('00000000-0000-0000-0000-0000000259d1'),  -- partner: Teksi (partner_type only)
  ('00000000-0000-0000-0000-0000000259d2'),  -- partner: Teksi + pHailing
  ('00000000-0000-0000-0000-0000000259d3'),  -- partner: a type with no row
  ('00000000-0000-0000-0000-0000000259d4')   -- partner: " E-Hailing " (key ehailing)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000259%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000259a1', 'admin-settings-partner-type-services', 'edit'),
  ('00000000-0000-0000-0000-0000000259a2', 'admin-settings-partner-type-services', 'read'),
  ('00000000-0000-0000-0000-0000000259a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status, partner_type, partner_types)
select u.id, 'Driver ' || right(u.id::text, 2), '6013000' || right(u.id::text, 4), 'approved', t.single, t.many
  from auth.users u
  join (values ('d1', 'TEKSI',          '{}'::text[]),
               ('d2', null,             array['Teksi', 'pHailing']),
               ('d3', 'Unlisted 259',   '{}'::text[]),
               ('d4', null,             array[' E-Hailing ', ' '])) t(k, single, many)
    on right(u.id::text, 2) = t.k
 where u.id::text like '00000000-0000-0000-0000-0000000259d%';

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
create or replace function pg_temp.book(p_rider uuid, p_service text)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng,
                                    drop_lat, drop_lng)
  values (v, p_rider, 'open', p_service, 30, 30, 25.0, 115.0, 25.1, 115.1);
  return v;
end $$;
create or replace function pg_temp.sees(p_ride uuid) returns integer language sql as $$
  select count(*)::int from public.ride_requests where id = p_ride;
$$;
create temp table rides (k text primary key, id uuid);
grant all on rides to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.book(uuid, text), pg_temp.sees(uuid) to authenticated;

-- ---- 0. The live rules are there -------------------------------------------------------------------
select pg_temp.check((select count(*) from public.partner_type_services
                       where type_key in ('ehailing', 'teksi', 'phailing', 'delivery', 'dealer', 'fleet',
                                          'serviceprovider')) = 7, 'the seven seeded types');
select pg_temp.check(not exists (select 1 from pg_policies where schemaname = 'public'
                                   and tablename = 'partner_type_services' and policyname = 'pts admin write'),
  'the any-admin write policy is gone');
select pg_temp.check(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                               and schemaname = 'public' and tablename = 'partner_type_services'),
  'followed live');

-- ---- 1. Who writes ---------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000259c1');
select pg_temp.check((select count(*) from public.partner_type_services) >= 7, 'a rider reads the rules');
select pg_temp.refused($q$insert into public.partner_type_services (type_key, type_name) values ('rider259', 'Rider')$q$,
  'a rider adding a rule');
select pg_temp.refused($q$update public.partner_type_services set all_services = true where type_key = 'teksi'$q$,
  'a rider opening Teksi up');
select pg_temp.refused($q$delete from public.partner_type_services where type_key = 'teksi'$q$,
  'a rider removing a rule');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259a2');
select pg_temp.refused($q$update public.partner_type_services set all_services = true where type_key = 'teksi'$q$,
  'an admin with READ on the page changing a rule');
select pg_temp.refused($q$insert into public.partner_type_services (type_key, type_name) values ('read259', 'Read')$q$,
  'an admin with READ on the page adding a rule');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259a3');
select pg_temp.refused($q$delete from public.partner_type_services where type_key = 'teksi'$q$,
  'another page''s admin removing a rule');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259a1');
insert into public.partner_type_services (type_key, type_name, all_services, services)
values ('test259', 'Test 259', false, array['Ride']);
update public.partner_type_services set note = 'Checked 259', updated_at = '2000-01-01', updated_by = null
 where type_key = 'teksi';
select pg_temp.refused($q$insert into public.partner_type_services (type_key, type_name) values ('Bad Key', 'Bad')$q$,
  'a key not in ptr_key form');
reset role;
select pg_temp.check((select note from public.partner_type_services where type_key = 'teksi') = 'Checked 259',
  'the page''s EDIT admin changes a rule');
select pg_temp.check((select updated_by from public.partner_type_services where type_key = 'teksi')
                       = '00000000-0000-0000-0000-0000000259a1', 'updated_by is the editor');
select pg_temp.check((select updated_at from public.partner_type_services where type_key = 'teksi') > '2020-01-01',
  'updated_at is the server''s');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000259a1');
delete from public.partner_type_services where type_key = 'test259';
reset role;
select pg_temp.check(not exists (select 1 from public.partner_type_services where type_key = 'test259'),
  'the page''s EDIT admin removes a rule');

-- ---- 2. The rule -----------------------------------------------------------------------------------
select pg_temp.check(public.partner_type_allows_service('TEKSI', 'ride'), 'Teksi: ride, any case');
select pg_temp.check(public.partner_type_allows_service(' Te-ksi ', '6 Seater'), 'Teksi: 6-seater, spaces and dashes');
select pg_temp.check(not public.partner_type_allows_service('Teksi', 'Delivery'), 'Teksi: not Delivery');
select pg_temp.check(public.partner_type_allows_service('Fleet', 'Anything 259'), 'Fleet: all services');
select pg_temp.check(public.partner_type_allows_service('Unlisted 259', 'Delivery'), 'no row: every service');

-- ---- 3. Who sees an open request -------------------------------------------------------------------
set local role authenticated;
insert into rides values ('ride', pg_temp.book('00000000-0000-0000-0000-0000000259c1', 'Ride'));
insert into rides values ('delivery', pg_temp.book('00000000-0000-0000-0000-0000000259c2', 'Delivery'));
-- A Teksi partner books a Delivery for themselves.
insert into rides values ('own', pg_temp.book('00000000-0000-0000-0000-0000000259d1', 'Delivery'));

select pg_temp.as_user('00000000-0000-0000-0000-0000000259d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'ride')) = 1, 'Teksi sees an open Ride');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 0, 'Teksi does not see an open Delivery');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'own')) = 1,
  'the rider sees their own request, even of a service their type does not take');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259d2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'ride')) = 1, 'Teksi + pHailing sees a Ride');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 1, 'Teksi + pHailing sees a Delivery');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259d3');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'ride')) = 1, 'a type with no row sees a Ride');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 1, 'a type with no row sees a Delivery');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259d4');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'ride')) = 1, '" E-Hailing " is eHailing: sees a Ride');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 0, '" E-Hailing " does not see a Delivery');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259c2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 1, 'the rider sees their own Delivery');

select pg_temp.as_user('00000000-0000-0000-0000-0000000259a2');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 1, 'an admin sees every open request');

-- A rule opened up applies at once.
reset role;
update public.partner_type_services set all_services = true where type_key = 'teksi';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000259d1');
select pg_temp.check(pg_temp.sees((select id from rides where k = 'delivery')) = 1, 'Teksi on All services sees a Delivery');
reset role;

rollback;

select 'partner_type_services_0259: all passed';
