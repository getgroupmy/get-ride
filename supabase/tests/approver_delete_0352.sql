-- ============================================================================
-- Regression test for migration 0352: an approver deletes a document.
--   * can_delete is required; the scope (approver_covers) is re-checked at
--     write time.
--   * soft (default): partner/vehicle images cleared and set Pending Review;
--     identity set Rejected with a note — the owner re-uploads.
--   * hard (delete_hard): the record is permanently removed.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_delete_0352.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000352a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000352b1')   -- the owner
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000352a1', 'Approver', '+60100003521'),
  ('00000000-0000-0000-0000-0000000352b1', 'Owner', '+60100003522')
on conflict (id) do update set name = excluded.name;
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000003521b1', '00000000-0000-0000-0000-0000000352b1', 'Owner', '+60100003522')
on conflict (id) do nothing;

insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url, file_url_back) values
  ('00000000-0000-0000-0000-0000003522d1', '00000000-0000-0000-0000-0000003521b1', '00000000-0000-0000-0000-0000000352b1', 'dreg', 'Licence', false, 'Approved', 'u/d1.jpg', 'u/d1b.jpg'),
  ('00000000-0000-0000-0000-0000003522d2', '00000000-0000-0000-0000-0000003521b1', '00000000-0000-0000-0000-0000000352b1', 'dreg', 'Licence', false, 'Pending Review', 'u/d2.jpg', null),
  ('00000000-0000-0000-0000-0000003522d3', '00000000-0000-0000-0000-0000003521b1', '00000000-0000-0000-0000-0000000352b1', 'dreg', 'Licence', false, 'Pending Review', 'u/d3.jpg', null)
on conflict (id) do nothing;
insert into public.identity_checks (id, user_id, kind, doc_type, purpose, status, mismatch, file_url) values
  ('00000000-0000-0000-0000-0000003523c1', '00000000-0000-0000-0000-0000000352b1', 'id', 'passport', 'first', 'Pending Review', '{}'::text[], 'id/c1.jpg'),
  ('00000000-0000-0000-0000-0000003523c2', '00000000-0000-0000-0000-0000000352b1', 'id', 'passport', 'first', 'Pending Review', '{}'::text[], 'id/c2.jpg')
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
create or replace function pg_temp.grant_approver(p_can_delete boolean, p_hard boolean, p_scope text) returns void language plpgsql security definer as $$
begin
  insert into public.approvers (profile_id, can_delete, delete_hard, scope, conflict_guard, use_own_region)
  values ('00000000-0000-0000-0000-0000000352a1', p_can_delete, p_hard, p_scope, false, false)
  on conflict (profile_id) do update set
    active = true, ends_at = null, can_delete = excluded.can_delete, delete_hard = excluded.delete_hard,
    scope = excluded.scope, conflict_guard = false, use_own_region = false;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text),
  pg_temp.grant_approver(boolean, boolean, text) to authenticated;

-- 1. Soft delete (send back for re-upload).
select pg_temp.grant_approver(true, false, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000352a1');
select pg_temp.check((public.approver_delete_document('partner', '00000000-0000-0000-0000-0000003522d1', 'Wrong file') ->> 'mode') = 'soft',
  'a soft delete reports soft');
select pg_temp.check((public.approver_delete_document('identity', '00000000-0000-0000-0000-0000003523c1', 'Wrong file') ->> 'mode') = 'soft',
  'a soft identity delete reports soft');
reset role;
select pg_temp.check((select file_url is null and file_url_back is null and status = 'Pending Review'
                        and reviewer_notes = 'Wrong file'
                      from public.provider_documents where id = '00000000-0000-0000-0000-0000003522d1'),
  'the partner document is cleared and sent back to Pending Review');
select pg_temp.check((select status = 'Rejected' and reject_note = 'Wrong file'
                      from public.identity_checks where id = '00000000-0000-0000-0000-0000003523c1'),
  'the identity submission is rejected with the note');

-- 2. Hard delete (permanent).
select pg_temp.grant_approver(true, true, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000352a1');
select pg_temp.check((public.approver_delete_document('partner', '00000000-0000-0000-0000-0000003522d2') ->> 'mode') = 'hard',
  'a hard delete reports hard');
select public.approver_delete_document('identity', '00000000-0000-0000-0000-0000003523c2');
reset role;
select pg_temp.check((select count(*) = 0 from public.provider_documents where id = '00000000-0000-0000-0000-0000003522d2'),
  'the hard-deleted partner document is gone');
select pg_temp.check((select count(*) = 0 from public.identity_checks where id = '00000000-0000-0000-0000-0000003523c2'),
  'the hard-deleted identity submission is gone');

-- 3. Without can_delete, refused.
select pg_temp.grant_approver(false, false, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000352a1');
select pg_temp.check(pg_temp.errored($q$select public.approver_delete_document('partner', '00000000-0000-0000-0000-0000003522d3')$q$),
  'without can_delete the action is refused');

-- 4. Out of scope (referral, no referral) is refused.
reset role;
select pg_temp.grant_approver(true, false, 'referral');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000352a1');
select pg_temp.check(pg_temp.errored($q$select public.approver_delete_document('partner', '00000000-0000-0000-0000-0000003522d3')$q$),
  'a document outside the scope is refused');
reset role;
select pg_temp.check((select status = 'Pending Review' and file_url = 'u/d3.jpg'
                      from public.provider_documents where id = '00000000-0000-0000-0000-0000003522d3'),
  'the refused document is untouched');

rollback;
