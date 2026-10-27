-- ============================================================================
-- Regression test for migration 0301: per-service checks for every vehicle,
-- worked out by the server (docs/KIV.md M9).
--   * a registration vehicle and a vehicle added later both get their rows
--     when submitted: the type it is too old for is paused, the type
--     waiting for its vehicle permit waits, the others are active;
--   * a registered type's larger limit covers another (ageLimitCovers);
--   * a vehicle added later that is too old for every type is submitted
--     (no VEHICLE_TOO_OLD): its services are paused;
--   * an approved permit turns the waiting service on (0299), and the
--     checks count a permit already approved;
--   * the registration wizard's own rows (older apps) are still written
--     while a draft and replaced by the server's on submit;
--   * a row an admin set is kept by the checks, and the apps can't change
--     or remove it (skipped, not refused);
--   * a changed type on a submitted vehicle is checked again; a vehicle
--     with no type is left alone;
--   * the admin's preview and apply, page-scoped.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/vehicle_service_checks_0301.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's: nobody is held up by them.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000301a1'),  -- sub-admin, EDIT on Vehicles
  ('00000000-0000-0000-0000-0000000301a2'),  -- sub-admin, EDIT on IP access only
  ('00000000-0000-0000-0000-0000000301b1'),  -- driver registering (Ride and Cab)
  ('00000000-0000-0000-0000-0000000301b2'),  -- driver with Ride and Taxi
  ('00000000-0000-0000-0000-0000000301b3')   -- someone with a vehicle and no partner row
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000301%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000301a1', 'admin-vehicles', 'edit'),
  ('00000000-0000-0000-0000-0000000301a2', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

-- Types: Ride (at most 10 years), Cab (20 years, a vehicle permit by key),
-- Taxi (20 years, covering Ride's limit), Walk (no vehicle).
delete from public.settings_entries where category = 'partner-type'
   and values ->> 'name' in ('Test301 Ride', 'Test301 Cab', 'Test301 Taxi', 'Test301 Walk');
insert into public.settings_entries (id, category, values, position, active) values
  ('00000000-0000-0000-0000-0000000301e1', 'partner-type',
   '{"name":"Test301 Ride","vehicleRequired":true,"rules":{"vehicleAge":{"required":true,"rules":[{"maxYears":10}]}}}', 0, true),
  ('00000000-0000-0000-0000-0000000301e2', 'partner-type',
   '{"name":"Test301 Cab","vehicleRequired":true,"rules":{"vehicleAge":{"required":true,"rules":[{"maxYears":20}]}},
     "vehiclePermit":{"required":true,"rules":[{"country":"Zedland","name":"Test EVP 301","permitType":"tst301-evp"}]}}', 0, true),
  ('00000000-0000-0000-0000-0000000301e3', 'partner-type',
   '{"name":"Test301 Taxi","vehicleRequired":true,"rules":{"vehicleAge":{"required":true,"rules":[{"maxYears":20}]}},
     "ageLimitCovers":[{"types":["Test301 Ride"]}]}', 0, true),
  ('00000000-0000-0000-0000-0000000301e4', 'partner-type',
   '{"name":"Test301 Walk","vehicleRequired":false}', 0, true);
insert into public.permit_types (id, country, key, name, applies_to, uploader) values
  ('00000000-0000-0000-0000-0000000301f9', 'Zedland', 'tst301-evp', 'Test EVP 301', 'vehicle', 'admin');

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000301c1', '00000000-0000-0000-0000-0000000301b1', 'Test Driver 301', '+60110003011',
   'unapproved', '{Test301 Ride,Test301 Cab,Test301 Walk}', '{Zedland}', '{}', '{}'),
  ('00000000-0000-0000-0000-0000000301c2', '00000000-0000-0000-0000-0000000301b2', 'Test Driver 302', '+60110003012',
   'approved', '{Test301 Ride,Test301 Taxi}', '{Zedland}', '{}', '{}');

-- v1: registration vehicle, 15 years old. v2: added later, 15 years old.
-- v3: added later, 30 years old. v4: Ride and Taxi, 15 years old, not sent;
-- v6: the same, approved before 0301 (no rows). v5: no type.
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, status, year, registration_date, partner_types) values
  ('00000000-0000-0000-0000-0000000301d1', '00000000-0000-0000-0000-0000000301b1', '00000000-0000-0000-0000-0000000301c1',
   'TST 3011', 'unapproved', (extract(year from current_date)::int - 15)::text,
   (current_date - interval '15 years' - interval '10 days')::date, '{Test301 Ride,Test301 Cab}'),
  ('00000000-0000-0000-0000-0000000301d2', '00000000-0000-0000-0000-0000000301b1', '00000000-0000-0000-0000-0000000301c1',
   'TST 3012', 'unapproved', (extract(year from current_date)::int - 15)::text, null, '{}'),
  ('00000000-0000-0000-0000-0000000301d3', '00000000-0000-0000-0000-0000000301b1', '00000000-0000-0000-0000-0000000301c1',
   'TST 3013', 'unapproved', (extract(year from current_date)::int - 30)::text, null, '{}'),
  ('00000000-0000-0000-0000-0000000301d4', '00000000-0000-0000-0000-0000000301b2', '00000000-0000-0000-0000-0000000301c2',
   'TST 3014', 'unapproved', (extract(year from current_date)::int - 15)::text,
   (current_date - interval '15 years' - interval '10 days')::date, '{}'),
  ('00000000-0000-0000-0000-0000000301d5', '00000000-0000-0000-0000-0000000301b3', null,
   'TST 3015', 'unapproved', (extract(year from current_date)::int - 30)::text, null, '{}'),
  ('00000000-0000-0000-0000-0000000301d6', '00000000-0000-0000-0000-0000000301b2', '00000000-0000-0000-0000-0000000301c2',
   'TST 3016', 'approved', (extract(year from current_date)::int - 15)::text,
   (current_date - interval '15 years' - interval '10 days')::date, '{}');
update public.partners set registration_vehicle_id = '00000000-0000-0000-0000-0000000301d1'
 where id = '00000000-0000-0000-0000-0000000301c1';

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- The error a statement raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
-- One row's status ('none' when there is no row).
create or replace function pg_temp.st(p_vehicle uuid, p_service text) returns text language sql as $$
  select coalesce((select status from public.vehicle_service_status where vehicle_id = p_vehicle and service = p_service), 'none');
$$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.as_db(),
  pg_temp.error_of(text), pg_temp.st(uuid, text) to authenticated;

-- 1. The checks, worked out ------------------------------------------------------------------------------
select pg_temp.check((select count(*) = 2 from public.vehicle_service_checks('00000000-0000-0000-0000-0000000301d1')),
  'one check per vehicle-required type');
select pg_temp.check((select status = 'paused_age' and max_age_years = 10 and limit_type = 'Test301 Ride'
                        from public.vehicle_service_checks('00000000-0000-0000-0000-0000000301d1') where service = 'Test301 Ride'),
  'a 15-year-old vehicle is over Ride''s 10 years');
select pg_temp.check((select status = 'waiting_permit' and max_age_years = 20 and permit_name = 'Test EVP 301'
                             and permit_type = 'tst301-evp'
                        from public.vehicle_service_checks('00000000-0000-0000-0000-0000000301d1') where service = 'Test301 Cab'),
  'Cab is within 20 years and waits for its vehicle permit');
select pg_temp.check((select status = 'active' and max_age_years = 20 and limit_type = 'Test301 Taxi'
                        from public.vehicle_service_checks('00000000-0000-0000-0000-0000000301d4') where service = 'Test301 Ride'),
  'Taxi''s 20 years cover Ride for a vehicle registered for both');
select pg_temp.check(not exists (select 1 from public.vehicle_service_checks('00000000-0000-0000-0000-0000000301d5')),
  'a vehicle with no type has no checks');

-- 2. Registration: the wizard's rows while a draft, then the server's ----------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000301b1');
-- As an older app's saveServiceStatuses: upsert, then remove what it no longer has.
insert into public.vehicle_service_status (vehicle_id, service, status, max_age_years, set_by_admin) values
  ('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride', 'active', 10, true),
  ('00000000-0000-0000-0000-0000000301d1', 'Test301 Cab', 'active', 20, false),
  ('00000000-0000-0000-0000-0000000301d1', 'Old type', 'active', null, false)
on conflict (vehicle_id, service) do update set status = excluded.status;
select pg_temp.check(pg_temp.error_of($q$insert into public.vehicle_service_status (vehicle_id, service, status)
  values ('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride', 'active')
  on conflict (vehicle_id, service) do update set status = excluded.status$q$) = 'ok',
  'the wizard upserts its rows on a draft');
select pg_temp.check(not (select set_by_admin from public.vehicle_service_status
                           where vehicle_id = '00000000-0000-0000-0000-0000000301d1' and service = 'Test301 Ride'),
  'the owner can''t mark a row as the admin''s');
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000301d1';
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride') = 'paused_age',
  'submitted: the server pauses Ride (over its age limit)');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Cab') = 'waiting_permit',
  'submitted: Cab waits for its permit');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Old type') = 'none',
  'a type the vehicle doesn''t have is removed');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Walk') = 'none',
  'a type without a vehicle gets no row');

-- 3. Vehicles added later: rows on submit, never refused ---------------------------------------------
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000301d2';
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d2', 'Test301 Ride') = 'paused_age'
                     and pg_temp.st('00000000-0000-0000-0000-0000000301d2', 'Test301 Cab') = 'waiting_permit',
  'a vehicle added later gets the same checks (from the partner''s types)');
select pg_temp.check(pg_temp.error_of($q$update public.vehicle set documents_ok = true
  where id = '00000000-0000-0000-0000-0000000301d3'$q$) = 'ok',
  'a vehicle added later that is too old for every type is submitted (no VEHICLE_TOO_OLD)');
select pg_temp.check((select documents_ok from public.vehicle where id = '00000000-0000-0000-0000-0000000301d3'),
  'it is sent for review');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d3', 'Test301 Ride') = 'paused_age'
                     and pg_temp.st('00000000-0000-0000-0000-0000000301d3', 'Test301 Cab') = 'paused_age',
  'its services are paused instead');
select pg_temp.check(pg_temp.error_of($q$update public.vehicle_service_status set status = 'active'
  where vehicle_id = '00000000-0000-0000-0000-0000000301d2'$q$) = 'ok'
  and pg_temp.st('00000000-0000-0000-0000-0000000301d2', 'Test301 Ride') = 'paused_age',
  'the owner can''t change a status once the vehicle is sent');
select pg_temp.check(pg_temp.error_of($q$select public.admin_vehicle_service_checks_preview()$q$) <> 'ok',
  'a driver can''t preview');
reset role;

-- 4. The permit turns its service on ---------------------------------------------------------------
select pg_temp.as_db();
insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, status, permit_type_id, expiry_date) values
  ('00000000-0000-0000-0000-0000000301d2', 'permit', 'Test EVP 301', 'Approved',
   '00000000-0000-0000-0000-0000000301f9', current_date + 300);
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d2', 'Test301 Cab') = 'active',
  'the approved permit turns Cab on (by key)');
select pg_temp.check((select status = 'active' from public.vehicle_service_checks('00000000-0000-0000-0000-0000000301d2')
                       where service = 'Test301 Cab'),
  'the checks count a permit already approved');

-- 5. A changed type is checked again; no type is left alone --------------------------------------------
update public.vehicle set partner_types = '{Test301 Ride}' where id = '00000000-0000-0000-0000-0000000301d2';
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d2', 'Test301 Cab') = 'none'
                     and pg_temp.st('00000000-0000-0000-0000-0000000301d2', 'Test301 Ride') = 'paused_age',
  'a type taken off a submitted vehicle loses its row');
insert into public.vehicle_service_status (vehicle_id, service, status) values
  ('00000000-0000-0000-0000-0000000301d5', 'Someone''s type', 'paused_age');
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000301d5';
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d5', 'Someone''s type') = 'paused_age',
  'a vehicle with no type keeps its rows');

-- 6. An admin's row is kept ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000301a2');
select pg_temp.check(pg_temp.error_of($q$select public.admin_vehicle_service_checks_apply('00000000-0000-0000-0000-0000000301d1')$q$) <> 'ok',
  'a sub-admin without the vehicles pages can''t apply');
select pg_temp.as_user('00000000-0000-0000-0000-0000000301a1');
update public.vehicle_service_status set status = 'active'
 where vehicle_id = '00000000-0000-0000-0000-0000000301d1' and service = 'Test301 Ride';
select pg_temp.check((select status = 'active' and set_by_admin from public.vehicle_service_status
                       where vehicle_id = '00000000-0000-0000-0000-0000000301d1' and service = 'Test301 Ride'),
  'a vehicles sub-admin sets a status, marked as the admin''s');
select pg_temp.check((select would_status = 'active' and checks_status = 'paused_age' and set_by_admin and not changes
                        from public.admin_vehicle_service_checks_preview('00000000-0000-0000-0000-0000000301d1')
                       where service = 'Test301 Ride'),
  'the preview shows the admin''s row kept');
select pg_temp.check(public.admin_vehicle_service_checks_apply('00000000-0000-0000-0000-0000000301d1') = 2,
  'apply checks both services');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride') = 'active',
  'apply keeps the admin''s row');
reset role;
select pg_temp.as_db();
select pg_temp.check(exists (select 1 from public.admin_audit_log where action = 'vehicle.service_checks_apply'
                               and detail ->> 'vehicle_id' = '00000000-0000-0000-0000-0000000301d1'),
  'apply is logged');

-- The vehicle goes back to the driver: the older wizard's writes skip the admin's row.
update public.vehicle set documents_ok = false where id = '00000000-0000-0000-0000-0000000301d1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000301b1');
select pg_temp.check(pg_temp.error_of($q$insert into public.vehicle_service_status (vehicle_id, service, status)
  values ('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride', 'paused_age')
  on conflict (vehicle_id, service) do update set status = excluded.status$q$) = 'ok',
  'the wizard''s upsert over an admin row is not refused');
select pg_temp.check(pg_temp.error_of($q$delete from public.vehicle_service_status
  where vehicle_id = '00000000-0000-0000-0000-0000000301d1' and service = 'Test301 Ride'$q$) = 'ok',
  'nor its removal');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride') = 'active',
  'the admin''s row is untouched');
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000301d1';
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Ride') = 'active'
                     and pg_temp.st('00000000-0000-0000-0000-0000000301d1', 'Test301 Cab') = 'waiting_permit',
  'submitted again: the admin''s row stays, the others are checked');
reset role;

-- 7. The preview of every vehicle; nothing filled when the migration ran ---------------------------
select pg_temp.as_db();
select pg_temp.check((select changes and current_status is null and checks_status = 'active'
                        from public.admin_vehicle_service_checks_preview()
                       where vehicle_id = '00000000-0000-0000-0000-0000000301d4' and service = 'Test301 Ride') is not true,
  'an unsubmitted vehicle is not in the all-vehicles preview');
select pg_temp.check((select changes and current_status is null and would_status = 'active'
                        from public.admin_vehicle_service_checks_preview()
                       where vehicle_id = '00000000-0000-0000-0000-0000000301d6' and service = 'Test301 Ride'),
  'an approved vehicle with no rows shows what applying would add');
select pg_temp.check(pg_temp.st('00000000-0000-0000-0000-0000000301d6', 'Test301 Ride') = 'none',
  'the preview writes nothing: vehicles are only checked when applied or sent again');
select pg_temp.check(exists (select 1 from public.admin_table_pages
                              where target = 'rpc:admin_vehicle_service_checks_apply' and page = 'admin-vehicle-edit'),
  'apply is mapped to the vehicle pages');
select pg_temp.check(not exists (select 1 from pg_trigger where tgname = 'trg_vehicle_b_partner_type_rules'),
  'the VEHICLE_TOO_OLD refusal is gone');

select 'vehicle_service_checks_0301: all passed';
rollback;
