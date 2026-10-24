-- ============================================================================
-- Regression test for migration 0288: partner registration, part 2.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_registration_0288.sql
--
-- The ID number mismatch is the server's; "Needs a closer look" and the
-- selfie's liveness are the server's; per-vehicle service statuses are the
-- owner's while the vehicle is a draft, then a vehicles sub-admin's
-- (caller_admin_can_write), and an approved vehicle permit turns a waiting
-- service on; a too-old registration vehicle is never refused; the Kad
-- Pemandu read in registration counts as the permit; every document with
-- the person's photo is queued for a face match against their live selfie
-- (not checked without one), and a low score flags the partner; the
-- id-read function's own-file check and daily cap.
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people and documents only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000288a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000288a2'),  -- sub-admin, EDIT on Vehicles
  ('00000000-0000-0000-0000-0000000288a3'),  -- sub-admin, EDIT on IP access only
  ('00000000-0000-0000-0000-0000000288b1'),  -- the driver registering
  ('00000000-0000-0000-0000-0000000288b2')   -- someone else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000288%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000288a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000288a2', 'admin-vehicles', 'edit'),
  ('00000000-0000-0000-0000-0000000288a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, avatar_url) values
  ('00000000-0000-0000-0000-000000028801', '00000000-0000-0000-0000-0000000288b1', 'Test Driver', '+60110000288',
   'unapproved', 'https://x.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000288b1/a.jpg'),
  ('00000000-0000-0000-0000-000000028802', '00000000-0000-0000-0000-0000000288b2', 'Other', '+60110000289',
   'unapproved', null);
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, year) values
  ('00000000-0000-0000-0000-0000000288f1', '00000000-0000-0000-0000-0000000288b1',
   '00000000-0000-0000-0000-000000028801', 'TST 288', '2005');
insert into public.required_document (id, values) values
  ('00000000-0000-0000-0000-0000000288d1', '{"name": "Driving License"}'),
  ('00000000-0000-0000-0000-0000000288d2', '{"name": "Vehicle Insurance"}'),
  ('00000000-0000-0000-0000-0000000288d3', '{"name": "Vehicle Insurance", "hasPhoto": true}');

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
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

-- 0. Has the person's photo, by the admin's switch or by name --------------------------------------
select pg_temp.check(public.required_document_has_photo('{"name": "Driving License"}'), 'a licence has a photo');
select pg_temp.check(public.required_document_has_photo('{"name": "PSV Lesen"}'), 'a lesen has a photo');
select pg_temp.check(not public.required_document_has_photo('{"name": "Vehicle Insurance"}'), 'insurance has none');
select pg_temp.check(not public.required_document_has_photo('{"name": "Driving License", "hasPhoto": false}'),
  'the admin''s switch wins');
select pg_temp.check(public.required_document_has_photo('{"name": "Insurance", "hasPhoto": "true"}'), 'as text too');

set local role authenticated;

-- 1. The National ID: the mismatch is the server's ------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000288b1');
update public.profiles set id_type = 'mykad', id_number_typed = '900101-14-5678', ic = '900101-14-5678',
       id_number_read = '900101145678', id_mismatch = true
 where id = '00000000-0000-0000-0000-0000000288b1';
select pg_temp.check((select not id_mismatch from public.profiles where id = '00000000-0000-0000-0000-0000000288b1'),
  'the same number written two ways is no mismatch, whatever the app says');
update public.profiles set id_number_read = '900101-14-5679' where id = '00000000-0000-0000-0000-0000000288b1';
select pg_temp.check((select id_mismatch from public.profiles where id = '00000000-0000-0000-0000-0000000288b1'),
  'a different number read is a mismatch');
select pg_temp.refused($q$update public.profiles set id_type = 'driving-licence' where id = '00000000-0000-0000-0000-0000000288b1'$q$,
  'an unknown ID type');

-- 2. Needs a closer look, and the selfie: the server's --------------------------------------------
select pg_temp.check((select needs_closer_look and 'id_number_mismatch' = any (closer_look_reasons)
                        from public.partners where id = '00000000-0000-0000-0000-000000028801'),
  'the mismatch flags the application');
update public.partners set needs_closer_look = false, closer_look_reasons = '{}', selfie_liveness = 'passed'
 where id = '00000000-0000-0000-0000-000000028801';
select pg_temp.check((select needs_closer_look and selfie_liveness is null
                        from public.partners where id = '00000000-0000-0000-0000-000000028801'),
  'the app can''t clear the flag or claim a live selfie');
select pg_temp.check(public.my_live_selfie_ok() = false, 'no live selfie yet');

-- A document with the person's photo before any live selfie: not checked, flagged.
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, file_url) values
  ('00000000-0000-0000-0000-0000000288e1', '00000000-0000-0000-0000-000000028801',
   '00000000-0000-0000-0000-0000000288b1', '00000000-0000-0000-0000-0000000288d1', 'Driving License',
   'https://x.supabase.co/storage/v1/object/public/provider-documents/00000000-0000-0000-0000-000000028801/d1/front-1.jpg'),
  ('00000000-0000-0000-0000-0000000288e2', '00000000-0000-0000-0000-000000028801',
   '00000000-0000-0000-0000-0000000288b1', '00000000-0000-0000-0000-0000000288d2', 'Vehicle Insurance',
   'https://x.supabase.co/storage/v1/object/public/provider-documents/00000000-0000-0000-0000-000000028801/d2/front-1.jpg');
select pg_temp.check((select state = 'not_checked' and reason = 'no_live_selfie' from public.document_face_checks
                        where doc_kind = 'provider_document' and doc_id = '00000000-0000-0000-0000-0000000288e1'),
  'a licence without a live selfie is not checked');
select pg_temp.check(not exists (select 1 from public.document_face_checks
                                  where doc_id = '00000000-0000-0000-0000-0000000288e2'),
  'insurance carries no photo: not compared');
select pg_temp.check((select 'selfie_not_live' = any (closer_look_reasons) from public.partners
                        where id = '00000000-0000-0000-0000-000000028801'),
  'a photo document without a live selfie flags the application');

-- The live selfie (as the app records it): the profile photo counts as live,
-- and the documents that waited are queued for a comparison.
select public.identity_check_submit(jsonb_build_object(
  'kind', 'selfie', 'purpose', 'profile', 'liveness', 'passed', 'liveness_detail', 'blink',
  'file_url', 'https://x.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-0000000288b1/a.jpg'));
select pg_temp.check((select selfie_liveness = 'passed' from public.partners where id = '00000000-0000-0000-0000-000000028801'),
  'the profile photo was taken live');
select pg_temp.check(public.my_live_selfie_ok(), 'a live selfie on record');
select pg_temp.check((select state = 'pending' and selfie_url like '%/avatars/%' from public.document_face_checks
                        where doc_id = '00000000-0000-0000-0000-0000000288e1'),
  'the licence waits for its comparison');
select pg_temp.check(not exists (select 1 from public.document_face_checks where user_id = '00000000-0000-0000-0000-0000000288b2'),
  'nobody else''s');

-- The National ID and the Kad Pemandu are queued as they are added.
update public.profiles set id_image = 'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000288b1/id_front_1.jpg'
 where id = '00000000-0000-0000-0000-0000000288b1';
update public.partners set driver_permit_front_url =
       'https://x.supabase.co/storage/v1/object/public/provider-documents/00000000-0000-0000-0000-000000028801/driver-permit/front-1.jpg'
 where id = '00000000-0000-0000-0000-000000028801';
select pg_temp.check((select count(*) = 2 from public.document_face_checks
                       where doc_kind in ('national_id', 'driver_permit') and state = 'pending'
                         and user_id = '00000000-0000-0000-0000-0000000288b1'),
  'the National ID and the driver permit wait for their comparison');
select pg_temp.refused($q$update public.document_face_checks set state = 'match', score = 99$q$, 'the app writing its own score');
select pg_temp.refused($q$select public.document_face_check_store('provider_document', '00000000-0000-0000-0000-0000000288e1', 'match', 99, 'aws', null, null)$q$,
  'the app storing a score');

-- 3. The vehicle's services: the owner while a draft, then the admins --------------------------------
insert into public.vehicle_service_status (vehicle_id, service, status, max_age_years, permit_name, permit_type) values
  ('00000000-0000-0000-0000-0000000288f1', 'eHailing', 'waiting_permit', 15, 'EVP', null),
  ('00000000-0000-0000-0000-0000000288f1', 'Teksi', 'paused_age', 20, null, null);
select pg_temp.check((select count(*) = 2 from public.vehicle_service_status where vehicle_id = '00000000-0000-0000-0000-0000000288f1'),
  'the owner keeps the draft''s statuses');
select pg_temp.as_user('00000000-0000-0000-0000-0000000288b2');
select pg_temp.check((select count(*) = 0 from public.vehicle_service_status), 'someone else sees none');
select pg_temp.refused($q$insert into public.vehicle_service_status (vehicle_id, service, status) values ('00000000-0000-0000-0000-0000000288f1', 'X', 'active')$q$,
  'someone else writing a status');
select pg_temp.refused($q$select public.registration_file_owned('00000000-0000-0000-0000-0000000288b2', 'ID_Image', 'x/y.jpg')$q$,
  'the app asking whose file it is');

-- The registration vehicle: too old for its type, never refused.
select pg_temp.as_user('00000000-0000-0000-0000-0000000288b1');
update public.partners set registration_vehicle_id = '00000000-0000-0000-0000-0000000288f1'
 where id = '00000000-0000-0000-0000-000000028801';
update public.vehicle set year = '1990' where id = '00000000-0000-0000-0000-0000000288f1';
select pg_temp.check((select year = '1990' from public.vehicle where id = '00000000-0000-0000-0000-0000000288f1'),
  'a registration vehicle over a limit is kept (the service is paused instead)');
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000288f1';
select pg_temp.refused($q$update public.vehicle_service_status set status = 'active' where vehicle_id = '00000000-0000-0000-0000-0000000288f1'$q$,
  'the owner changing a status once the vehicle is sent');

select pg_temp.as_user('00000000-0000-0000-0000-0000000288a3');
select pg_temp.refused($q$update public.vehicle_service_status set status = 'active' where vehicle_id = '00000000-0000-0000-0000-0000000288f1'$q$,
  'a sub-admin without the vehicles page');
select pg_temp.as_user('00000000-0000-0000-0000-0000000288a2');
update public.vehicle_service_status set status = 'active'
 where vehicle_id = '00000000-0000-0000-0000-0000000288f1' and service = 'Teksi';
select pg_temp.check((select status = 'active' from public.vehicle_service_status
                       where vehicle_id = '00000000-0000-0000-0000-0000000288f1' and service = 'Teksi'),
  'a vehicles sub-admin changes a status');

reset role;

-- An approved vehicle permit turns the waiting service on.
insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, status, permit_type_id, expiry_date)
select '00000000-0000-0000-0000-0000000288f1', 'permit', 'EVP', 'Approved', t.id, current_date + 300
  from public.permit_types t limit 1;
select pg_temp.check(
  not exists (select 1 from public.permit_types)
  or (select status = 'active' from public.vehicle_service_status
       where vehicle_id = '00000000-0000-0000-0000-0000000288f1' and service = 'eHailing'),
  'the permit turns eHailing on for this vehicle');

-- 4. The face-compare function's score; a low one flags the application ------------------------
select public.document_face_check_store('national_id', '00000000-0000-0000-0000-0000000288b1', 'no_match', 41.5, 'aws', null, null);
select pg_temp.check((select state = 'no_match' and score = 41.5 from public.document_face_checks
                       where doc_kind = 'national_id' and doc_id = '00000000-0000-0000-0000-0000000288b1'),
  'the score is kept per document');
select pg_temp.check((select needs_closer_look and 'face_low' = any (closer_look_reasons)
                        from public.partners where id = '00000000-0000-0000-0000-000000028801'),
  'a low face match flags the application');
select public.document_face_check_source('national_id', '00000000-0000-0000-0000-0000000288b1');
select pg_temp.check((public.document_face_check_source('national_id', '00000000-0000-0000-0000-0000000288b1') ->> 'selfie_url') like '%/avatars/%',
  'the function is given the live selfie');

-- 5. The Kad Pemandu counts as the permit at submit ------------------------------------------------
select pg_temp.check(not public.ptr_partner_has_permit('00000000-0000-0000-0000-000000028801'), 'no card number yet');
update public.partners set driver_permit_card_no = 'KP/T/0000/0000001', driver_permit_valid_until = current_date + 200
 where id = '00000000-0000-0000-0000-000000028801';
select pg_temp.check(public.ptr_partner_has_permit('00000000-0000-0000-0000-000000028801'), 'the card read in registration');
update public.partners set driver_permit_valid_until = current_date - 1 where id = '00000000-0000-0000-0000-000000028801';
select pg_temp.check(not public.ptr_partner_has_permit('00000000-0000-0000-0000-000000028801'), 'not once it has run out');

-- 6. The id-read function's own-file check and daily cap ------------------------------------------
select pg_temp.check(public.registration_file_owned('00000000-0000-0000-0000-0000000288b1', 'ID_Image',
  '00000000-0000-0000-0000-0000000288b1/id_front_1.jpg'), 'their ID folder');
select pg_temp.check(public.registration_file_owned('00000000-0000-0000-0000-0000000288b1', 'provider-documents',
  '00000000-0000-0000-0000-000000028801/company/front-1.jpg'), 'their partner folder');
select pg_temp.check(public.registration_file_owned('00000000-0000-0000-0000-0000000288b1', 'vehicle-documents',
  '00000000-0000-0000-0000-0000000288f1/grant/front-1.jpg'), 'their vehicle folder');
select pg_temp.check(not public.registration_file_owned('00000000-0000-0000-0000-0000000288b1', 'vehicle-documents',
  '00000000-0000-0000-0000-0000000288f1/permits/evp.jpg'), 'not the permits GET.ride uploads');
select pg_temp.check(not public.registration_file_owned('00000000-0000-0000-0000-0000000288b1', 'provider-documents',
  '00000000-0000-0000-0000-000000028802/company/front-1.jpg'), 'not someone else''s');
select pg_temp.check(not public.registration_file_owned('00000000-0000-0000-0000-0000000288b1', 'ID_Image',
  '00000000-0000-0000-0000-0000000288b1/../x.jpg'), 'no path tricks');
select pg_temp.check(public.registration_text_read_spend('00000000-0000-0000-0000-0000000288b1', 2), 'read 1');
select pg_temp.check(public.registration_text_read_spend('00000000-0000-0000-0000-0000000288b1', 2), 'read 2');
select pg_temp.check(not public.registration_text_read_spend('00000000-0000-0000-0000-0000000288b1', 2), 'the cap');

-- 7. Re-runnable, and the admin write policies are page-scoped ----------------------------------------
select pg_temp.check(not exists (
  select 1 from pg_policies where tablename in ('vehicle_service_status', 'document_face_checks')
     and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     and (coalesce(qual, '') ~ 'caller_is_admin\(\)' or coalesce(with_check, '') ~ 'caller_is_admin\(\)')),
  'no write policy allows any admin');
select pg_temp.check(exists (select 1 from public.admin_table_pages where target = 'vehicle_service_status'),
  'vehicle_service_status is mapped to admin pages');

select 'partner_registration_0288: all passed';
rollback;
