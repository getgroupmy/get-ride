-- ============================================================================
-- Regression test for migration 0254: permits per country.
--   * a vehicle's status: with / without / expired / bypass, and a bypass
--     that ends by itself;
--   * only an admin uploads an admin-only permit or sets a bypass;
--   * enforcement only where the country requires permits: kept offline,
--     open requests hidden, a bid refused; a vehicle with its permit works;
--   * the ride carries the vehicle, its energy and plate colours;
--   * ride_permits and the permit files: the ride's rider from acceptance to
--     the end of the trip, nobody else; a vehicle on bypass shows none;
--   * expiry reminders are sent once, and on the day.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/vehicle_permits_0254.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.ride_permits(uuid)', 'execute') then
    raise exception 'FAILED: anon must not call ride_permits';
  end if;
  if has_function_privilege('authenticated', 'public.driver_permit_problem(uuid)', 'execute') then
    raise exception 'FAILED: driver_permit_problem is the server''s own';
  end if;
  if has_function_privilege('authenticated', 'public.document_expiry_reminders_run(date)', 'execute') then
    raise exception 'FAILED: the reminder job is the server''s own';
  end if;
  if not exists (select 1 from public.permit_types where country = 'Malaysia' and key = 'evp' and required
                    and applies_to = 'vehicle' and uploader = 'admin' and shown_to_passengers) then
    raise exception 'FAILED: the Malaysian vehicle permit is seeded';
  end if;
  if (select days from public.document_reminder_days where scope = 'default') <> '{45,30,15,3,1}' then
    raise exception 'FAILED: the default reminder days';
  end if;
end
$$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000254a1'),  -- rider
  ('00000000-0000-0000-0000-0000000254a2'),  -- another rider
  ('00000000-0000-0000-0000-0000000254b1'),  -- driver with a permitted vehicle
  ('00000000-0000-0000-0000-0000000254b2'),  -- driver whose vehicle has no permit
  ('00000000-0000-0000-0000-0000000254c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000254%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000254c1', '*', 'edit') on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries) values
  ('00000000-0000-0000-0000-0000000254e1', '00000000-0000-0000-0000-0000000254b1', 'Test Driver One', '+60100000001',
   'approved', '{eHailing,TEKSI}', '{Malaysia}'),
  ('00000000-0000-0000-0000-0000000254e2', '00000000-0000-0000-0000-0000000254b2', 'Test Driver Two', '+60100000002',
   'approved', '{eHailing}', '{Malaysia}');

insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status,
                            service_countries, partner_types, energy_type, joined_at) values
  ('00000000-0000-0000-0000-0000000254f1', '00000000-0000-0000-0000-0000000254b1', '00000000-0000-0000-0000-0000000254e1',
   'TST 2541', 'Testmake', 'Alpha', 'Silver', 'approved', '{Malaysia}', '{eHailing,TEKSI}', 'EV', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000254f2', '00000000-0000-0000-0000-0000000254b2', '00000000-0000-0000-0000-0000000254e2',
   'TST 2542', 'Testmake', 'Beta', 'Blue', 'approved', '{Malaysia}', '{eHailing}', 'Diesel', now());
insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000254f1', '00000000-0000-0000-0000-0000000254b1'),
  ('00000000-0000-0000-0000-0000000254f2', '00000000-0000-0000-0000-0000000254b2');

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
-- [p_sql] fails, with [p_why] in its message or hint.
create or replace function pg_temp.refused(p_sql text, p_why text, p_what text) returns void language plpgsql as $$
declare
  v_msg text;
  v_hint text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
    if p_why is not null and position(p_why in coalesce(v_msg, '') || ' ' || coalesce(v_hint, '')) = 0 then
      raise exception 'FAILED: % was refused for another reason: % (%)', p_what, v_msg, v_hint;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
create or replace function pg_temp.sees(p_bucket text, p_name text) returns bigint language sql as $$
  select count(*) from storage.objects where bucket_id = p_bucket and name = p_name;
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text),
  pg_temp.sees(text, text) to authenticated;

-- 1. Status ------------------------------------------------------------------------------------
select pg_temp.check(public.vehicle_permit_status('00000000-0000-0000-0000-0000000254f2') = 'without',
  'a vehicle with no permit is without');

insert into public.vehicle_documents (id, vehicle_id, doc_id, doc_name, permit_type_id, status, start_date, expiry_date,
                                      document_number, file_url, permit_fields)
select '00000000-0000-0000-0000-0000000254d1', '00000000-0000-0000-0000-0000000254f1', 'permit:evp', t.name, t.id,
       'Approved', current_date - 100, current_date + 15, 'TE-TST2541',
       'https://example.supabase.co/storage/v1/object/public/vehicle-documents/00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf',
       '{"ref_primary": "TE-TST2541", "ref_sub": "111 222", "plate": "TST2541", "seats": "5"}'
  from public.permit_types t where t.country = 'Malaysia' and t.key = 'evp';
select pg_temp.check(public.vehicle_permit_status('00000000-0000-0000-0000-0000000254f1') = 'with',
  'an approved permit in date is with');

update public.vehicle_documents set expiry_date = current_date - 1 where id = '00000000-0000-0000-0000-0000000254d1';
select pg_temp.check(public.vehicle_permit_status('00000000-0000-0000-0000-0000000254f1') = 'expired',
  'a permit past its valid-until date is expired');

-- Bypass: an admin only, for the country's days; it ends by itself.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b1');
select pg_temp.refused($q$select public.vehicle_permit_bypass('00000000-0000-0000-0000-0000000254f1', true)$q$,
  'not_authorized', 'a driver setting their own bypass');
select pg_temp.refused(
  $q$update public.vehicle set permit_bypass_until = now() + interval '9 days' where id = '00000000-0000-0000-0000-0000000254f1'$q$,
  'VEHICLE_PROTECTED_COLUMN', 'a driver writing the bypass column');
select pg_temp.refused(
  $q$insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, permit_type_id, auth_user_id)
     select '00000000-0000-0000-0000-0000000254f2', 'permit:evp', 'x', id, '00000000-0000-0000-0000-0000000254b1'
       from public.permit_types where country = 'Malaysia' and key = 'evp'$q$,
  null, 'a driver uploading an admin-only permit');
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b2');
select pg_temp.refused(
  $q$insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, permit_type_id, auth_user_id)
     select '00000000-0000-0000-0000-0000000254f2', 'permit:evp', 'x', id, '00000000-0000-0000-0000-0000000254b2'
       from public.permit_types where country = 'Malaysia' and key = 'evp'$q$,
  'PERMIT_ADMIN_ONLY', 'the vehicle''s own driver uploading an admin-only permit');
select pg_temp.as_user('00000000-0000-0000-0000-0000000254c1');
select pg_temp.check(
  public.vehicle_permit_bypass('00000000-0000-0000-0000-0000000254f1', true) between now() + interval '71 hours' and now() + interval '73 hours',
  'the bypass lasts the country''s 3 days');
reset role;
select pg_temp.check(public.vehicle_permit_status('00000000-0000-0000-0000-0000000254f1') = 'bypass',
  'a vehicle on bypass is bypass');
update public.vehicle set permit_bypass_until = now() - interval '1 minute' where id = '00000000-0000-0000-0000-0000000254f1';
select pg_temp.check(public.vehicle_permit_status('00000000-0000-0000-0000-0000000254f1') = 'expired',
  'when the pass ends the vehicle is back to its own status');
update public.vehicle set permit_bypass_until = null where id = '00000000-0000-0000-0000-0000000254f1';
update public.vehicle_documents set expiry_date = current_date + 15, status = 'Approved'
 where id = '00000000-0000-0000-0000-0000000254d1';

-- 2. Enforcement off: nobody is held up ----------------------------------------------------------
update public.permit_country_settings set enforce = false where country in ('Malaysia', '*');
select pg_temp.check(public.driver_permit_problem('00000000-0000-0000-0000-0000000254b2') is null,
  'with the switch off a vehicle without a permit is not held up');
insert into public.driver_presence (profile_id, online, lat, lng) values
  ('00000000-0000-0000-0000-0000000254b2', true, 3.1, 101.6)
on conflict (profile_id) do update set online = true;
select pg_temp.check((select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000254b2'),
  'with the switch off the driver goes online');

-- 3. Enforcement on ---------------------------------------------------------------------------------
update public.permit_country_settings set enforce = true where country = 'Malaysia';
select pg_temp.check(public.driver_permit_problem('00000000-0000-0000-0000-0000000254b2') like '%TST 2542 is missing%',
  'without a permit the driver is held up, and told which permit');
select pg_temp.check(public.driver_permit_problem('00000000-0000-0000-0000-0000000254b1') is null,
  'a vehicle with its permit is not held up');
update public.driver_presence set online = true, updated_at = now() where profile_id = '00000000-0000-0000-0000-0000000254b2';
select pg_temp.check(not (select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000254b2'),
  'without a permit the driver is kept offline');
insert into public.driver_presence (profile_id, online, lat, lng) values
  ('00000000-0000-0000-0000-0000000254b1', true, 3.1, 101.6)
on conflict (profile_id) do update set online = true;
select pg_temp.check((select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000254b1'),
  'with a permit the driver goes online');

insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare) values
  ('00000000-0000-0000-0000-000000025401', '00000000-0000-0000-0000-0000000254a1', 'open', 3.1, 101.6, 20);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b2');
select pg_temp.check((select count(*) from public.ride_requests where id = '00000000-0000-0000-0000-000000025401') = 0,
  'an open request is hidden from a driver without a permit');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000254b2', offered_fare = 20
 where id = '00000000-0000-0000-0000-000000025401';
reset role;
select pg_temp.check((select partner_id is null from public.ride_requests where id = '00000000-0000-0000-0000-000000025401'),
  'a driver without a permit can''t reach the request to bid');
-- Even when the request can be seen (an older rule set), the bid itself is refused.
drop policy "ride_requests vehicle permit" on public.ride_requests;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b2');
select pg_temp.refused(
  $q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000254b2', offered_fare = 20
      where id = '00000000-0000-0000-0000-000000025401'$q$,
  'VEHICLE_PERMIT_REQUIRED', 'a bid from a driver without a permit');
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b1');
select pg_temp.check((select count(*) from public.ride_requests where id = '00000000-0000-0000-0000-000000025401') = 1,
  'the open request is shown to a driver with a permit');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000254b1', offered_fare = 20
 where id = '00000000-0000-0000-0000-000000025401';
reset role;

-- Bypass lets the vehicle work, and ends on its own.
update public.vehicle set permit_bypass_until = now() + interval '1 day' where id = '00000000-0000-0000-0000-0000000254f2';
select pg_temp.check(public.driver_permit_problem('00000000-0000-0000-0000-0000000254b2') is null,
  'a vehicle on bypass may take rides');
update public.vehicle set permit_bypass_until = now() - interval '1 second' where id = '00000000-0000-0000-0000-0000000254f2';
select pg_temp.check(public.driver_permit_problem('00000000-0000-0000-0000-0000000254b2') is not null,
  'after the pass the vehicle is held up again');

-- 4. The ride carries the vehicle -------------------------------------------------------------------
select pg_temp.check(
  (select partner_vehicle_id = '00000000-0000-0000-0000-0000000254f1' and partner_energy = 'EV'
          and partner_vehicle_types @> '{TEKSI}' and partner_plate_colours->>'bg' = '#ffffff'
     from public.ride_requests where id = '00000000-0000-0000-0000-000000025401'),
  'the bid stamps the vehicle, its energy and its plate colours (a taxi type first)');
select pg_temp.check(public.permit_plate_colours('Malaysia', '{eHailing}', 'ev') = '{"bg": "#1e8e3e", "fg": "#ffffff"}',
  'an EV plate, energy matched without case');
select pg_temp.check(public.permit_plate_colours('Malaysia', '{eHailing}', 'Something new')->>'bg' = '#111111',
  'an unknown energy takes the "other" colours');

-- 5. What the passenger sees -------------------------------------------------------------------------
insert into storage.objects (bucket_id, name)
values ('vehicle-documents', '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254a1');
select pg_temp.check(public.ride_permits('00000000-0000-0000-0000-000000025401') is null,
  'nothing before the driver is accepted');
select pg_temp.check(pg_temp.sees('vehicle-documents', '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf') = 0,
  'no file before the driver is accepted');
reset role;
update public.ride_requests set status = 'accepted' where id = '00000000-0000-0000-0000-000000025401';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254a1');
select pg_temp.check(
  (select jsonb_array_length(p->'permits') = 1
          and p->'permits'->0->>'name' = 'E-hailing vehicle permit (eVP)'
          and jsonb_array_length(p->'permits'->0->'fields') = 4
          and p->'permits'->0->'fields'->0->>'label' = 'Permit Reference No. (Primary)'
          and p->'permits'->0->'fields'->0->>'label_local' = 'No. Rujukan Permit (Induk)'
          and p->'permits'->0->'fields'->0->>'value' = 'TE-TST2541'
          and p->'permits'->0->'fields'->3->>'value' = (current_date + 15)::text
          and p->'permits'->0->>'path' = '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf'
          and p->>'plate' is not distinct from (select partner_plate from public.ride_requests
                                                 where id = '00000000-0000-0000-0000-000000025401')
     from public.ride_permits('00000000-0000-0000-0000-000000025401') p),
  'the rider of an accepted ride sees the permit''s passenger fields in both languages, and its file');
select pg_temp.check(pg_temp.sees('vehicle-documents', '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf') = 1,
  'the rider reads the permit file during the ride');
select pg_temp.as_user('00000000-0000-0000-0000-0000000254a2');
select pg_temp.check(public.ride_permits('00000000-0000-0000-0000-000000025401') is null,
  'another rider sees nothing');
select pg_temp.check(pg_temp.sees('vehicle-documents', '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf') = 0,
  'another rider reads no file');
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b2');
select pg_temp.check(public.ride_permits('00000000-0000-0000-0000-000000025401') is null,
  'another driver sees nothing');
reset role;

-- A vehicle on bypass, without its permit: nothing to show.
update public.vehicle_documents set status = 'Rejected' where id = '00000000-0000-0000-0000-0000000254d1';
update public.vehicle set permit_bypass_until = now() + interval '1 day' where id = '00000000-0000-0000-0000-0000000254f1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254a1');
select pg_temp.check(
  (select jsonb_array_length(p->'permits') = 0 from public.ride_permits('00000000-0000-0000-0000-000000025401') p),
  'a vehicle on bypass shows no permit');
select pg_temp.check(pg_temp.sees('vehicle-documents', '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf') = 0,
  'nor its file');
reset role;
update public.vehicle_documents set status = 'Approved' where id = '00000000-0000-0000-0000-0000000254d1';

update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-000000025401';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000254a1');
select pg_temp.check(public.ride_permits('00000000-0000-0000-0000-000000025401') is null,
  'nothing after the trip ends');
select pg_temp.check(pg_temp.sees('vehicle-documents', '00000000-0000-0000-0000-0000000254f1/permits/evp-1.pdf') = 0,
  'no file after the trip ends');

-- The driver sees their own permits any time.
select pg_temp.as_user('00000000-0000-0000-0000-0000000254b1');
select pg_temp.check(
  (select p->'vehicles'->0->>'status' = 'with' and p->'vehicles'->0->'permits'->0->>'state' = 'with'
          and jsonb_array_length(p->'vehicles'->0->'permits'->0->'fields') = 6
          and (p->'vehicles'->0->'permits'->0->>'warn_days')::int = 45
     from public.my_permits() p),
  'the driver sees their vehicle''s permit with every field and the warning days');
select pg_temp.refused($q$select public.admin_vehicle_permits('Malaysia')$q$, 'not_authorized', 'a driver reading the admin list');
select pg_temp.as_user('00000000-0000-0000-0000-0000000254c1');
select pg_temp.check(
  (select count(*) = 2 from jsonb_array_elements(public.admin_vehicle_permits('Malaysia')) c
    where c->>'plate' like 'TST 254%'),
  'the admin lists the country''s vehicles');
reset role;

-- 6. Expiry reminders: once each, and on the day ------------------------------------------------------
delete from public.document_expiry_reminders where doc_id = '00000000-0000-0000-0000-0000000254d1';
select pg_temp.check(
  (select count(*) from public.document_expiry_reminders where doc_id = '00000000-0000-0000-0000-0000000254d1') = 0,
  'no reminder yet');
select public.document_expiry_reminders_run();
select pg_temp.check(
  (select count(*) = 1 and min(days_before) = 15 from public.document_expiry_reminders
    where doc_id = '00000000-0000-0000-0000-0000000254d1'),
  'a permit 15 days from expiry is reminded');
select pg_temp.check(
  (select body like 'Your E-hailing vehicle permit (eVP) for TST 2541 expires in 15 days (%). GET.ride is renewing it with APAD.'
     from public.notification_outbox
    where profile_id = '00000000-0000-0000-0000-0000000254b1' and kind = 'document_expiry'),
  'the driver is told, with the issuer');
select public.document_expiry_reminders_run();
select pg_temp.check(
  (select count(*) from public.document_expiry_reminders where doc_id = '00000000-0000-0000-0000-0000000254d1') = 1,
  'a reminder is never sent twice');
select public.document_expiry_reminders_run(current_date + 1);
select pg_temp.check(
  (select count(*) from public.document_expiry_reminders where doc_id = '00000000-0000-0000-0000-0000000254d1') = 1,
  '14 days out is not a reminder day');
insert into public.document_reminder_days (scope, scope_key, days)
select 'permit_type', id::text, '{14}' from public.permit_types where country = 'Malaysia' and key = 'evp';
select public.document_expiry_reminders_run(current_date + 1);
select pg_temp.check(
  (select count(*) from public.document_expiry_reminders where doc_id = '00000000-0000-0000-0000-0000000254d1') = 2,
  'a permit type''s own days replace the default');
select public.document_expiry_reminders_run(current_date + 15);
select pg_temp.check(
  (select count(*) from public.document_expiry_reminders
    where doc_id = '00000000-0000-0000-0000-0000000254d1' and days_before = 0) = 1,
  'the day it expires is reminded too');

rollback;

select 'vehicle_permits_0254: all passed';
