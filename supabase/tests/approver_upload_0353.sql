-- ============================================================================
-- Regression test for migration 0353: an approver replaces a document's image.
--   * can_upload is required; the scope (approver_covers) is re-checked.
--   * target returns the current image URL (for the edge function to overwrite);
--     a document with no image gets a fresh write path (migration 0397).
--   * commit reopens the document for review (Pending Review, reviewer fields
--     cleared).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_upload_0353.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000353a1'),
  ('00000000-0000-0000-0000-0000000353b1')
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000353a1', 'Approver', '+60100003531'),
  ('00000000-0000-0000-0000-0000000353b1', 'Owner', '+60100003532')
on conflict (id) do update set name = excluded.name;
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000003531b1', '00000000-0000-0000-0000-0000000353b1', 'Owner', '+60100003532')
on conflict (id) do nothing;
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url, reviewer_notes, reviewed_at) values
  ('00000000-0000-0000-0000-0000003532d1', '00000000-0000-0000-0000-0000003531b1', '00000000-0000-0000-0000-0000000353b1', 'dreg', 'Licence', false, 'Approved', 'u/d1.jpg', 'ok', now()),
  ('00000000-0000-0000-0000-0000003532d2', '00000000-0000-0000-0000-0000003531b1', '00000000-0000-0000-0000-0000000353b1', 'dreg', 'Licence', false, 'Approved', null, null, null)
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
create or replace function pg_temp.grant_approver(p_can_upload boolean, p_scope text) returns void language plpgsql security definer as $$
begin
  insert into public.approvers (profile_id, can_upload, scope, conflict_guard, use_own_region)
  values ('00000000-0000-0000-0000-0000000353a1', p_can_upload, p_scope, false, false)
  on conflict (profile_id) do update set
    active = true, ends_at = null, can_upload = excluded.can_upload, scope = excluded.scope,
    conflict_guard = false, use_own_region = false;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text),
  pg_temp.grant_approver(boolean, text) to authenticated;

select pg_temp.grant_approver(true, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000353a1');

-- 1. Target returns the current image URL.
select pg_temp.check((public.approver_upload_target('partner', '00000000-0000-0000-0000-0000003532d1') ->> 'file_url') = 'u/d1.jpg',
  'target returns the current image URL');

-- 2. Commit reopens the document for review.
select pg_temp.check((public.approver_upload_commit('partner', '00000000-0000-0000-0000-0000003532d1') ->> 'ok') = 'true',
  'commit succeeds');
reset role;
select pg_temp.check((select status = 'Pending Review' and reviewer_notes is null and reviewed_at is null
                      from public.provider_documents where id = '00000000-0000-0000-0000-0000003532d1'),
  'the document is reopened for review with reviewer fields cleared');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000353a1');

-- 3. A partner document with no image now gets a fresh write path, rather than
--    being refused (migration 0397: the first on-behalf upload needs one).
select pg_temp.check(
  (public.approver_upload_target('partner', '00000000-0000-0000-0000-0000003532d2') ->> 'upload_url')
    like '%/provider-documents/00000000-0000-0000-0000-0000000353b1/approver-%',
  'a partner document with no image gets a fresh write path');

-- 4. Without can_upload, refused.
reset role;
select pg_temp.grant_approver(false, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000353a1');
select pg_temp.check(pg_temp.errored($q$select public.approver_upload_target('partner', '00000000-0000-0000-0000-0000003532d1')$q$),
  'without can_upload the action is refused');

-- 5. Out of scope (referral, no referral) is refused.
reset role;
select pg_temp.grant_approver(true, 'referral');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000353a1');
select pg_temp.check(pg_temp.errored($q$select public.approver_upload_target('partner', '00000000-0000-0000-0000-0000003532d1')$q$),
  'a document outside the scope is refused');
reset role;

rollback;
