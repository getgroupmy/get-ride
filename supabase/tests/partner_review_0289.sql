-- ============================================================================
-- Regression test for migration 0289: the admin's line-by-line review of a
-- partner application and the driver's "Changes needed".
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_review_0289.sql
--
-- Only an admin with EDIT on the Partners pages decides lines, sends back
-- and approves (caller_admin_can_write); a reason is required to reject; an
-- edit writes the real column; the driver sees the lines only once sent
-- back; what they change is marked fixed by the server; "Send for review
-- again" waits for every rejected line; approving takes the vehicle along.
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people and documents only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000289a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000289a2'),  -- sub-admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000289a3'),  -- sub-admin, READ on Partners
  ('00000000-0000-0000-0000-0000000289a4'),  -- sub-admin, EDIT on IP access only
  ('00000000-0000-0000-0000-0000000289b1'),  -- the driver
  ('00000000-0000-0000-0000-0000000289b2')   -- someone else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000289%'
on conflict do nothing;
update public.profiles
   set name = 'Test Driver', address = 'No. 1, Jalan Ujian', id_image = 'https://x.test/id-front-1.jpg'
 where id = '00000000-0000-0000-0000-0000000289b1';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000289a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000289a2', 'admin-partners', 'edit'),
  ('00000000-0000-0000-0000-0000000289a3', 'admin-partners', 'read'),
  ('00000000-0000-0000-0000-0000000289a4', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

insert into public.vehicle (id, auth_user_id, plate, year, color, status, documents_ok) values
  ('00000000-0000-0000-0000-0000000289f1', '00000000-0000-0000-0000-0000000289b1', 'TST 289', '2018', 'GREY',
   'unapproved', true);
insert into public.partners (id, auth_user_id, name, phone, status, documents_ok, partner_types, registration_vehicle_id) values
  ('00000000-0000-0000-0000-000000028901', '00000000-0000-0000-0000-0000000289b1', 'Test Driver', '+60110000389',
   'unapproved', true, array['TEKSI', 'DEALER'], '00000000-0000-0000-0000-0000000289f1');
update public.vehicle set owner_partner_id = '00000000-0000-0000-0000-000000028901'
 where id = '00000000-0000-0000-0000-0000000289f1';
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, file_url) values
  ('00000000-0000-0000-0000-0000000289d1', '00000000-0000-0000-0000-000000028901',
   '00000000-0000-0000-0000-0000000289b1', 'doc-licence', 'Driving License', 'https://x.test/licence-1.jpg');
insert into public.vehicle_documents (id, vehicle_id, partner_id, auth_user_id, doc_id, doc_name, file_url) values
  ('00000000-0000-0000-0000-0000000289d2', '00000000-0000-0000-0000-0000000289f1', '00000000-0000-0000-0000-000000028901',
   '00000000-0000-0000-0000-0000000289b1', 'doc-inspection', 'Inspection', 'https://x.test/inspection-1.jpg');

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
create or replace function pg_temp.raises(p_sql text, p_code text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like '%' || p_code || '%' then
      raise exception 'FAILED: % raised "%" instead of %', p_what, sqlerrm, p_code;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.raises(text, text, text) to authenticated;

-- 0. The push says "Changes needed" ---------------------------------------------------------------
select pg_temp.check(public.approval_push_message('partner', 'changes-needed', null, null) ->> 'title' = 'Changes needed',
  'the status push for changes-needed');
select pg_temp.check(public.partner_review_edit_type('details.birth_date') = 'date', 'a birth date edits as a date');
select pg_temp.check(public.partner_review_edit_type('id.front') is null, 'an ID photo is not edited, only rejected');

set local role authenticated;

-- 1. Only an admin with EDIT on Partners decides a line ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000289a3');
select pg_temp.refused($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.name',
  'details', 'Full name', 'approved')$q$, 'a read-only Partners sub-admin deciding a line');
select pg_temp.as_user('00000000-0000-0000-0000-0000000289a4');
select pg_temp.refused($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.name',
  'details', 'Full name', 'approved')$q$, 'an IP-access sub-admin deciding a line');
select pg_temp.as_user('00000000-0000-0000-0000-0000000289b1');
select pg_temp.refused($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.name',
  'details', 'Full name', 'approved')$q$, 'the driver deciding their own line');
select pg_temp.refused($q$select public.partner_review_send_back('00000000-0000-0000-0000-000000028901')$q$,
  'the driver sending their own application back');
select pg_temp.refused($q$select public.partner_review_approve('00000000-0000-0000-0000-000000028901')$q$,
  'the driver approving themselves');
select pg_temp.refused($q$insert into public.partner_review_items (partner_id, item_key, item_group, label, state)
  values ('00000000-0000-0000-0000-000000028901', 'details.name', 'details', 'Full name', 'approved')$q$,
  'the driver writing a line directly');

-- 2. The Partners sub-admin reviews -----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000289a2');
select pg_temp.refused($q$insert into public.partner_review_items (partner_id, item_key, item_group, label, state)
  values ('00000000-0000-0000-0000-000000028901', 'details.name', 'details', 'Full name', 'approved')$q$,
  'an admin writing a line directly (only through the functions)');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.name', 'details', 'Full name', 'approved');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'id.front',
  'national_id', 'MyKad front photo', 'rejected', '  ')$q$, 'REVIEW_REASON_NEEDED', 'a rejection without a reason');
-- 0296: a line with a document is decided only once the admin has viewed it.
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'id.front',
  'national_id', 'MyKad front photo', 'rejected', 'Photo blurry')$q$, 'REVIEW_VIEW_FIRST', 'deciding a document unseen');
select public.partner_review_view('00000000-0000-0000-0000-000000028901', 'id.front');
select public.partner_review_view('00000000-0000-0000-0000-000000028901', 'doc:provider:doc-licence');
select public.partner_review_view('00000000-0000-0000-0000-000000028901', 'doc:vehicle:doc-inspection');
select pg_temp.check(public.partner_review_view('00000000-0000-0000-0000-000000028901', 'id.front') = 2,
  'every view is counted');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'id.front', 'national_id', 'MyKad front photo',
  'rejected', 'Photo blurry: retake it in good light.');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'doc:provider:doc-licence', 'service_documents',
  'Driving License', 'rejected', 'Expired');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'doc:vehicle:doc-inspection', 'vehicle_documents',
  'Inspection', 'approved');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'id.front',
  'national_id', 'MyKad front photo', 'edited', 'Fixed', '"x"')$q$, 'REVIEW_NOT_EDITABLE', 'editing a photo');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'vpermit:abc',
  'vehicle_permits', 'EVP', 'rejected', 'Wrong')$q$, 'REVIEW_NOT_DRIVERS', 'rejecting GET.ride''s own permit upload');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.birth_date',
  'details', 'Date of birth', 'edited', 'From the ID', '"31-31-1990"')$q$, 'REVIEW_BAD_VALUE', 'an edit with no real date');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.address',
  'details', 'Address', 'edited', null, '"x"')$q$, 'REVIEW_NOTE_NEEDED', 'an edit without a note');

-- An edit writes the real column, and keeps what was there.
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.address', 'details', 'Address',
  'edited', 'Postcode added from your ID.', '"No. 1, Jalan Ujian, 47300 Petaling Jaya"');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'vehicle.color', 'vehicle', 'Colour',
  'edited', 'Colour corrected to match the grant.', '"SILVER"');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'services', 'services', 'Services',
  'edited', 'Dealer is for registered businesses.', '["TEKSI"]');
reset role;
select pg_temp.check((select address from public.profiles where id = '00000000-0000-0000-0000-0000000289b1')
  = 'No. 1, Jalan Ujian, 47300 Petaling Jaya', 'the admin''s address is on the profile');
select pg_temp.check((select address from public.partners where id = '00000000-0000-0000-0000-000000028901')
  = 'No. 1, Jalan Ujian, 47300 Petaling Jaya', 'and on the partner row (0277)');
select pg_temp.check((select color from public.vehicle where id = '00000000-0000-0000-0000-0000000289f1') = 'SILVER',
  'the admin''s colour is on the vehicle');
select pg_temp.check((select partner_types = array['TEKSI'] and partner_type = 'TEKSI' from public.partners
  where id = '00000000-0000-0000-0000-000000028901'), 'the admin''s services are on the partner row');
select pg_temp.check((select old_value = '"No. 1, Jalan Ujian"'::jsonb and new_value = '"No. 1, Jalan Ujian, 47300 Petaling Jaya"'::jsonb
  from public.partner_review_items where item_key = 'details.address'), 'the line keeps the value before and after');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log
  where action = 'partner.review_item' and detail ->> 'item_key' = 'vehicle.color'
    and actor_id = '00000000-0000-0000-0000-0000000289a2'), 'the edit is in the audit log');
set local role authenticated;

-- 3. The driver doesn't see a review in progress -------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000289b1');
select pg_temp.check((select count(*) = 0 from public.partner_review_items), 'nothing shown before it is sent back');

-- 4. Not approved with a rejected line; sent back instead ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000289a2');
select pg_temp.raises($q$select public.partner_review_approve('00000000-0000-0000-0000-000000028901')$q$,
  'REVIEW_REJECTED_LINES', 'approving with rejected lines');
select public.partner_review_send_back('00000000-0000-0000-0000-000000028901');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.name',
  'details', 'Full name', 'rejected', 'x')$q$, 'REVIEW_WITH_DRIVER', 'changing a line while it is with the driver');
reset role;
select pg_temp.check((select status::text = 'changes-needed' from public.partners
  where id = '00000000-0000-0000-0000-000000028901'), 'the partner is changes-needed');
select pg_temp.check((select status = 'Rejected' and reviewer_notes = 'Expired' from public.provider_documents
  where id = '00000000-0000-0000-0000-0000000289d1'), 'the rejected document is rejected with the reason');
select pg_temp.check((select status = 'Approved' from public.vehicle_documents
  where id = '00000000-0000-0000-0000-0000000289d2'), 'the approved document is approved');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log where action = 'partner.review_send_back'),
  'sending back is in the audit log');
set local role authenticated;

-- 5. The driver sees the lines and fixes them -----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000289b2');
select pg_temp.check((select count(*) = 0 from public.partner_review_items), 'someone else sees none of it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000289b1');
select pg_temp.check((select count(*) = 7 from public.partner_review_items), 'the driver sees every line sent');
select pg_temp.raises($q$select public.partner_review_resubmit()$q$, 'REVIEW_ITEMS_LEFT',
  'sending again with rejected lines left');
update public.profiles set id_image = 'https://x.test/id-front-2.jpg' where id = '00000000-0000-0000-0000-0000000289b1';
select pg_temp.check((select fixed_at is not null from public.partner_review_items where item_key = 'id.front'),
  'a new ID photo fixes its line');
update public.provider_documents set file_url = 'https://x.test/licence-2.jpg' where id = '00000000-0000-0000-0000-0000000289d1';
select pg_temp.check((select fixed_at is not null from public.partner_review_items where item_key = 'doc:provider:doc-licence'),
  'a new upload fixes its line');
select pg_temp.check((select fixed_at is null from public.partner_review_items where item_key = 'details.name'),
  'an untouched line stays as it was');
select public.partner_review_keep('details.address');
select pg_temp.check((select kept_at is not null from public.partner_review_items where item_key = 'details.address'),
  'the driver keeps the admin''s edit');
select public.partner_review_resubmit();
reset role;
select pg_temp.check((select status::text = 'unapproved' and resubmitted_at is not null from public.partners
  where id = '00000000-0000-0000-0000-000000028901'), 'sent again: waiting for review');
select pg_temp.check((select count(*) = 0 from public.partner_review_items
  where partner_id = '00000000-0000-0000-0000-000000028901' and item_key in ('id.front', 'doc:provider:doc-licence')),
  'the fixed lines go back unreviewed');
select pg_temp.check((select count(*) = 5 from public.partner_review_items
  where partner_id = '00000000-0000-0000-0000-000000028901'), 'the other decisions stay');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log where action = 'partner.review_resubmit'),
  'sending again is in the audit log');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000289b1');
select pg_temp.raises($q$select public.partner_review_resubmit()$q$, 'PARTNER_NOT_CHANGES_NEEDED', 'sending twice');

-- 6. Approved, with the vehicle -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000289a2');
-- Sent again, the fixed lines went back to pending: viewed again first.
select pg_temp.check((select count(*) >= 1 from public.partner_review_log
   where partner_id = '00000000-0000-0000-0000-000000028901' and action = 'pending'),
  'lines sent again are logged back to pending');
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'id.front',
  'national_id', 'MyKad front photo', 'approved')$q$, 'REVIEW_VIEW_FIRST', 'a view from before pending does not count');
select public.partner_review_view('00000000-0000-0000-0000-000000028901', 'id.front');
select public.partner_review_view('00000000-0000-0000-0000-000000028901', 'doc:provider:doc-licence');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'id.front', 'national_id', 'MyKad front photo', 'approved');
select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'doc:provider:doc-licence', 'service_documents',
  'Driving License', 'approved');
select public.partner_review_approve('00000000-0000-0000-0000-000000028901');
select pg_temp.check((select approved_by = '00000000-0000-0000-0000-0000000289a2' and approved_at is not null
   from public.partners where id = '00000000-0000-0000-0000-000000028901'), 'the approver is recorded');
select pg_temp.check((select count(*) = 1 from public.partner_review_log
   where partner_id = '00000000-0000-0000-0000-000000028901' and action = 'partner_approved'
     and actor_id = '00000000-0000-0000-0000-0000000289a2'), 'the approval is logged with who');
select pg_temp.check((select count(*) >= 3 from public.partner_review_log
   where partner_id = '00000000-0000-0000-0000-000000028901' and action in ('approved', 'rejected')),
  'decisions are logged');
reset role;
select pg_temp.check((select status::text = 'approved' from public.partners where id = '00000000-0000-0000-0000-000000028901'),
  'the partner is approved');
select pg_temp.check((select status::text = 'approved' and documents_ok from public.vehicle
  where id = '00000000-0000-0000-0000-0000000289f1'), 'the registration vehicle is approved with them');
select pg_temp.check((select status = 'Approved' from public.provider_documents
  where id = '00000000-0000-0000-0000-0000000289d1'), 'the approved document line approves the document');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log where action = 'partner.review_approve'),
  'approving is in the audit log');
set local role authenticated;
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000028901', 'details.name',
  'details', 'Full name', 'rejected', 'x')$q$, 'REVIEW_CLOSED', 'reviewing an approved partner');

select 'partner_review_0289: all passed';
rollback;
