-- ============================================================================
-- Regression test for migration 0397: an on-behalf upload never leaves an orphan.
--   * approver_create_document / approver_create_vehicle_document create the
--     Pending Review row with file_url = NULL (no placeholder), so a cancelled
--     upload leaves an honest "no image" row, not a broken link.
--   * approver_upload_target mints a fresh write path for a partner/vehicle
--     document that has no image yet (instead of refusing), so the first
--     on-behalf upload and the Replace button both work.
--   * approver_upload_commit persists that written path into file_url, so the
--     URL only ever appears once the object exists.
--   * the orphan-detection predicate (a placeholder path with no storage object)
--     nulls the orphan and keeps an anchored document.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_onbehalf_orphan_0397.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- Row lookups are done on the owner role (reset role); the RPCs run as the
-- approver (set role authenticated), since RLS hides the documents otherwise.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000397a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000397b1')   -- the covered member
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000397a1', 'Approver Seven', '+60100003971'),
  ('00000000-0000-0000-0000-0000000397b1', 'Member Seven',   '+60100003972')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000039701b1', '00000000-0000-0000-0000-0000000397b1', 'Member Seven', '+60100003972')
on conflict (id) do nothing;
insert into public.vehicle (id, auth_user_id, plate, make, model) values
  ('00000000-0000-0000-0000-000003970101', '00000000-0000-0000-0000-0000000397b1', 'WXY 7397', 'Proton', 'Saga')
on conflict (id) do nothing;

-- A required partner document (docTypes not a vehicle category) and a required
-- vehicle document (docTypes names the Vehicle category).
insert into public.required_document (id, values) values
  ('00000000-0000-0000-0000-0000039702d1',
   '{"name": "Test Partner Doc 397", "active": true, "required": true}'),
  ('00000000-0000-0000-0000-0000039702d2',
   '{"name": "Test Vehicle Doc 397", "active": true, "required": true, "docTypes": "[\"a7d71867-ac2a-4c0c-ae07-87e5d500693c\"]"}')
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.grant_approver() returns void language plpgsql security definer as $$
begin
  insert into public.approvers (profile_id, can_upload, scope, conflict_guard, use_own_region)
  values ('00000000-0000-0000-0000-0000000397a1', true, 'all', false, false)
  on conflict (profile_id) do update set
    active = true, ends_at = null, can_upload = true, scope = 'all',
    conflict_guard = false, use_own_region = false;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.grant_approver() to authenticated;

select pg_temp.grant_approver();
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000397a1');

-- 1. Creating an on-behalf partner document leaves file_url NULL (no placeholder).
select public.approver_create_document(
  '00000000-0000-0000-0000-0000000397b1', '00000000-0000-0000-0000-0000039702d1', 'Test Partner Doc 397');
reset role;
select set_config('my.partner_doc',
  (select id::text from public.provider_documents
    where auth_user_id = '00000000-0000-0000-0000-0000000397b1' and doc_id = '00000000-0000-0000-0000-0000039702d1'), true);
select pg_temp.check(
  (select file_url is null and status = 'Pending Review'
     from public.provider_documents where id = current_setting('my.partner_doc')::uuid),
  'an on-behalf partner document is created with no file_url');

-- 2. approver_upload_target mints a fresh provider-documents write path for it
--    (rather than refusing a document with no image).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000397a1');
select pg_temp.check(
  (select (t ->> 'ok') = 'true'
          and (t ->> 'file_url') is null
          and (t ->> 'pending') = 'false'
          and (t ->> 'upload_url') like '%/provider-documents/00000000-0000-0000-0000-0000000397b1/approver-%'
     from (select public.approver_upload_target('partner', current_setting('my.partner_doc')::uuid) t) s),
  'target mints a fresh write path for a partner document with no image');

-- 3. Creating an on-behalf vehicle document leaves file_url NULL.
select public.approver_create_vehicle_document(
  '00000000-0000-0000-0000-000003970101', '00000000-0000-0000-0000-0000039702d2', 'Test Vehicle Doc 397');
reset role;
select set_config('my.vehicle_doc',
  (select id::text from public.vehicle_documents
    where vehicle_id = '00000000-0000-0000-0000-000003970101' and doc_id = '00000000-0000-0000-0000-0000039702d2'), true);
select pg_temp.check(
  (select file_url is null and status = 'Pending Review'
     from public.vehicle_documents where id = current_setting('my.vehicle_doc')::uuid),
  'an on-behalf vehicle document is created with no file_url');

-- 4. target mints a vehicle-documents path keyed by the vehicle id.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000397a1');
select pg_temp.check(
  (select (t ->> 'ok') = 'true'
          and (t ->> 'upload_url') like '%/vehicle-documents/00000000-0000-0000-0000-000003970101/approver-%'
     from (select public.approver_upload_target('vehicle', current_setting('my.vehicle_doc')::uuid) t) s),
  'target mints a fresh vehicle path keyed by the vehicle id');

-- 5. commit persists the written path into file_url (the URL appears only now).
do $$
declare v_doc uuid; v_url text;
begin
  v_doc := current_setting('my.partner_doc')::uuid;
  v_url := (public.approver_upload_target('partner', v_doc)) ->> 'upload_url';
  perform public.approver_upload_commit('partner', v_doc, v_url);
  perform set_config('my.committed_url', v_url, true);
end $$;
reset role;
select pg_temp.check(
  (select file_url = current_setting('my.committed_url', true)
     from public.provider_documents where id = current_setting('my.partner_doc')::uuid),
  'commit persists the written path into file_url');

-- 6. The orphan-detection predicate nulls a placeholder with no object and keeps
--    an anchored document. (Same predicate the migration's one-time cleanup uses.)
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, status, file_url) values
  ('00000000-0000-0000-0000-0000039703d1', '00000000-0000-0000-0000-0000039701b1', '00000000-0000-0000-0000-0000000397b1',
   'orphan-doc', 'Orphan', 'Pending Review',
   'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object/public/provider-documents/00000000-0000-0000-0000-0000000397b1/approver-dead0000-0000-0000-0000-000000000000'),
  ('00000000-0000-0000-0000-0000039703d2', '00000000-0000-0000-0000-0000039701b1', '00000000-0000-0000-0000-0000000397b1',
   'anchored-doc', 'Anchored', 'Pending Review',
   'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object/public/provider-documents/00000000-0000-0000-0000-0000000397b1/approver-live0000-0000-0000-0000-000000000000')
on conflict (id) do nothing;
-- Give only the anchored row a real storage object.
insert into storage.objects (bucket_id, name) values
  ('provider-documents', '00000000-0000-0000-0000-0000000397b1/approver-live0000-0000-0000-0000-000000000000')
on conflict do nothing;

update public.provider_documents d
   set file_url = null
 where d.id in ('00000000-0000-0000-0000-0000039703d1', '00000000-0000-0000-0000-0000039703d2')
   and d.file_url ~ '/(approver|pending)-[0-9a-f-]+$'
   and not exists (
     select 1 from storage.objects o
      where o.bucket_id = split_part(split_part(d.file_url, '/object/public/', 2), '/', 1)
        and o.name = substr(split_part(d.file_url, '/object/public/', 2),
                            length(split_part(split_part(d.file_url, '/object/public/', 2), '/', 1)) + 2));

select pg_temp.check(
  (select file_url is null from public.provider_documents where id = '00000000-0000-0000-0000-0000039703d1'),
  'an orphan placeholder (no storage object) has its file_url cleared');
select pg_temp.check(
  (select file_url is not null from public.provider_documents where id = '00000000-0000-0000-0000-0000039703d2'),
  'an anchored document (object present) keeps its file_url');

rollback;
