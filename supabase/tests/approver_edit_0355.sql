-- ============================================================================
-- Regression test for migration 0355: an approver sees and corrects a
-- document's captured fields (document number, start date, expiry date).
--   * can_upload is required; the scope (approver_covers) is re-checked at
--     write time, not trusted from the app.
--   * approver_pending_documents() returns the captured values and the
--     requires_* flags resolved from the required_document settings entry.
--   * only the required fields are written; a required field can't be blanked;
--     a past expiry date is refused; identity and out-of-scope are refused.
--   * the vehicle branch is line-identical to partner.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_edit_0355.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000355a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000355b1')   -- the owner
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000355a1', 'Approver', '+60100003551'),
  ('00000000-0000-0000-0000-0000000355b1', 'Owner', '+60100003552')
on conflict (id) do update set name = excluded.name;
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000003551b1', '00000000-0000-0000-0000-0000000355b1', 'Owner', '+60100003552')
on conflict (id) do nothing;

-- A required-document type that asks for all three captured fields, and one
-- that asks for none. doc_id on the document is the settings entry's id.
insert into public.settings_entries (id, category, values, active) values
  ('00000000-0000-0000-0000-0000003550f1', 'required_document',
   '{"name":"Driving Licence","requireDocumentNumber":true,"requireStartDate":true,"requireExpiryDate":true}'::jsonb, true),
  ('00000000-0000-0000-0000-0000003550f2', 'required_document',
   '{"name":"Photo only"}'::jsonb, true)
on conflict (id) do nothing;

-- Two pending partner documents for the owner: one with captured fields, one
-- with no captured fields configured.
-- A future expiry so the auto-expire trigger leaves it Pending Review (an
-- already-expired document is flipped to Expired and never reaches the inbox).
insert into public.provider_documents
  (id, partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url, document_number, start_date, expiry_date) values
  ('00000000-0000-0000-0000-0000003552d1', '00000000-0000-0000-0000-0000003551b1', '00000000-0000-0000-0000-0000000355b1',
   '00000000-0000-0000-0000-0000003550f1', 'Driving Licence', false, 'Pending Review', 'u/d1.jpg', 'OLD123', '2024-01-01', '2030-06-01'),
  ('00000000-0000-0000-0000-0000003552d2', '00000000-0000-0000-0000-0000003551b1', '00000000-0000-0000-0000-0000000355b1',
   '00000000-0000-0000-0000-0000003550f2', 'Photo only', false, 'Pending Review', 'u/d2.jpg', null, null, null)
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
-- SECURITY DEFINER so the fixture seeds with the privileged test role (authenticated has only SELECT on approvers).
create or replace function pg_temp.grant_approver(p_can_upload boolean, p_scope text) returns void language plpgsql security definer as $$
begin
  insert into public.approvers (profile_id, can_upload, scope, conflict_guard, use_own_region)
  values ('00000000-0000-0000-0000-0000000355a1', p_can_upload, p_scope, false, false)
  on conflict (profile_id) do update set
    active = true, ends_at = null, can_upload = excluded.can_upload, scope = excluded.scope,
    conflict_guard = false, use_own_region = false;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text),
  pg_temp.grant_approver(boolean, text) to authenticated;

select pg_temp.grant_approver(true, 'all');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000355a1');

-- 1. The inbox surfaces the captured fields and the requires_* flags.
select pg_temp.check(
  (select requires_number and requires_start and requires_expiry
     and document_number = 'OLD123' and expiry_date = date '2030-06-01'
     from public.approver_pending_documents()
    where doc_pk = '00000000-0000-0000-0000-0000003552d1'),
  'the inbox returns the captured fields and requires_* flags');

-- 2. The no-fields document reports requires_* = false.
select pg_temp.check(
  (select not requires_number and not requires_start and not requires_expiry
     from public.approver_pending_documents()
    where doc_pk = '00000000-0000-0000-0000-0000003552d2'),
  'a type with no captured fields reports no requirements');

-- 3. Correcting the fields succeeds.
select pg_temp.check(
  (public.approver_edit_document('partner', '00000000-0000-0000-0000-0000003552d1',
     'NEW999', date '2026-01-01', date '2031-12-31') ->> 'ok') = 'true',
  'the approver corrects the captured fields');

-- 4. A required field left blank is refused.
select pg_temp.check(pg_temp.errored(
  $q$select public.approver_edit_document('partner', '00000000-0000-0000-0000-0000003552d1', '  ', date '2026-01-01', date '2031-12-31')$q$),
  'a blank required document number is refused');

-- 5. A past expiry date is refused.
select pg_temp.check(pg_temp.errored(
  $q$select public.approver_edit_document('partner', '00000000-0000-0000-0000-0000003552d1', 'NEW999', date '2026-01-01', date '2000-01-01')$q$),
  'a past expiry date is refused');

-- 6. A type with no captured fields has nothing to edit.
select pg_temp.check(pg_temp.errored(
  $q$select public.approver_edit_document('partner', '00000000-0000-0000-0000-0000003552d2', 'X', null, null)$q$),
  'editing a no-fields document is refused');

-- 7. identity is not editable here.
select pg_temp.check(pg_temp.errored(
  $q$select public.approver_edit_document('identity', '00000000-0000-0000-0000-0000003552d1', 'X', null, date '2031-01-01')$q$),
  'identity source is refused');

reset role;
-- The correction landed; nothing else changed and the document stays pending.
select pg_temp.check(
  (select document_number = 'NEW999' and start_date = date '2026-01-01' and expiry_date = date '2031-12-31'
     and status = 'Pending Review'
     from public.provider_documents where id = '00000000-0000-0000-0000-0000003552d1'),
  'the correction was written and the document is still pending');

-- 8. Without can_upload, the edit is refused.
select pg_temp.grant_approver(false, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000355a1');
select pg_temp.check(pg_temp.errored(
  $q$select public.approver_edit_document('partner', '00000000-0000-0000-0000-0000003552d1', 'NEW999', date '2026-01-01', date '2031-12-31')$q$),
  'without can_upload the edit is refused');

-- 9. Out of scope (referral, with no referral) is refused — re-checked at write time.
reset role;
select pg_temp.grant_approver(true, 'referral');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000355a1');
select pg_temp.check(pg_temp.errored(
  $q$select public.approver_edit_document('partner', '00000000-0000-0000-0000-0000003552d1', 'NEW999', date '2026-01-01', date '2031-12-31')$q$),
  'a document outside the scope is refused');

rollback;
