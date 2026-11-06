-- ============================================================================
-- Regression test for migration 0351: an approver approves / rejects a document.
--   * can_approve is required; the scope (approver_covers) is re-checked at
--     write time, not trusted from the app.
--   * partner (provider_documents) and identity (identity_checks) decisions
--     land correctly; the vehicle branch is line-identical to partner.
--   * a reject needs a reason; an approved ID flips profiles.id_verified; a
--     decided document can't be decided again (reads as not found).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_review_0351.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000351a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000351b1')   -- the owner
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000351a1', 'Approver', '+60100003511'),
  ('00000000-0000-0000-0000-0000000351b1', 'Owner', '+60100003512')
on conflict (id) do update set name = excluded.name;
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000003511b1', '00000000-0000-0000-0000-0000000351b1', 'Owner', '+60100003512')
on conflict (id) do nothing;

-- Three pending partner documents and three pending ID checks for the owner.
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url) values
  ('00000000-0000-0000-0000-0000003512d1', '00000000-0000-0000-0000-0000003511b1', '00000000-0000-0000-0000-0000000351b1', 'dreg', 'Licence', false, 'Pending Review', 'u/d1.jpg'),
  ('00000000-0000-0000-0000-0000003512d2', '00000000-0000-0000-0000-0000003511b1', '00000000-0000-0000-0000-0000000351b1', 'dreg', 'Licence', false, 'Pending Review', 'u/d2.jpg'),
  ('00000000-0000-0000-0000-0000003512d3', '00000000-0000-0000-0000-0000003511b1', '00000000-0000-0000-0000-0000000351b1', 'dreg', 'Licence', false, 'Pending Review', 'u/d3.jpg')
on conflict (id) do nothing;
insert into public.identity_checks (id, user_id, kind, doc_type, purpose, status, mismatch, file_url) values
  ('00000000-0000-0000-0000-0000003513c1', '00000000-0000-0000-0000-0000000351b1', 'id', 'passport', 'first', 'Pending Review', '{}'::text[], 'id/c1.jpg'),
  ('00000000-0000-0000-0000-0000003513c2', '00000000-0000-0000-0000-0000000351b1', 'id', 'passport', 'first', 'Pending Review', '{}'::text[], 'id/c2.jpg')
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
-- SECURITY DEFINER so the fixture seeds with the privileged test role (authenticated has only SELECT on approvers).
create or replace function pg_temp.grant_approver(p_can_approve boolean, p_scope text) returns void language plpgsql security definer as $$
begin
  insert into public.approvers (profile_id, can_approve, scope, conflict_guard, use_own_region)
  values ('00000000-0000-0000-0000-0000000351a1', p_can_approve, p_scope, false, false)
  on conflict (profile_id) do update set
    active = true, ends_at = null, can_approve = excluded.can_approve, scope = excluded.scope,
    conflict_guard = false, use_own_region = false;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text),
  pg_temp.grant_approver(boolean, text) to authenticated;

select pg_temp.grant_approver(true, 'all');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000351a1');

-- 1. Approve a partner document.
select pg_temp.check((public.approver_review_document('partner', '00000000-0000-0000-0000-0000003512d1', 'approve') ->> 'status') = 'Approved',
  'the approver approves a partner document');

-- 2. Reject an ID check with a reason.
select pg_temp.check((public.approver_review_document('identity', '00000000-0000-0000-0000-0000003513c1', 'reject', 'blurry', 'Too dark to read') ->> 'status') = 'Rejected',
  'the approver rejects an ID with a reason');

-- 3. A reject with no reason is refused.
select pg_temp.check(pg_temp.errored($q$select public.approver_review_document('partner', '00000000-0000-0000-0000-0000003512d2', 'reject', null, null)$q$),
  'a reject with no reason is refused');

-- 4. A decided document can't be decided again.
select pg_temp.check(pg_temp.errored($q$select public.approver_review_document('partner', '00000000-0000-0000-0000-0000003512d1', 'reject', null, 'again')$q$),
  'an already-decided document reads as not found');

-- 5. Approving an ID verifies the owner's profile.
select pg_temp.check((public.approver_review_document('identity', '00000000-0000-0000-0000-0000003513c2', 'approve') ->> 'status') = 'Approved',
  'the approver approves an ID');

reset role;
select pg_temp.check((select status from public.provider_documents where id = '00000000-0000-0000-0000-0000003512d1') = 'Approved',
  'the partner document is Approved');
select pg_temp.check((select status = 'Pending Review' from public.provider_documents where id = '00000000-0000-0000-0000-0000003512d2'),
  'the reason-less reject left the document pending');
select pg_temp.check((select reject_note from public.identity_checks where id = '00000000-0000-0000-0000-0000003513c1') = 'Too dark to read'
                       and (select reject_reason from public.identity_checks where id = '00000000-0000-0000-0000-0000003513c1') = 'blurry',
  'the rejected ID kept its reason and note');
select pg_temp.check((select id_verified::text from public.profiles where id = '00000000-0000-0000-0000-0000000351b1') = 'Verified',
  'approving the ID verified the owner');

-- 6. Without can_approve, the action is refused.
select pg_temp.grant_approver(false, 'all');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000351a1');
select pg_temp.check(pg_temp.errored($q$select public.approver_review_document('partner', '00000000-0000-0000-0000-0000003512d3', 'approve')$q$),
  'without can_approve the action is refused');

-- 7. Out of scope (referral, with no referral) is refused — re-checked at write time.
reset role;
select pg_temp.grant_approver(true, 'referral');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000351a1');
select pg_temp.check(pg_temp.errored($q$select public.approver_review_document('partner', '00000000-0000-0000-0000-0000003512d3', 'approve')$q$),
  'a document outside the scope is refused');
reset role;
select pg_temp.check((select status = 'Pending Review' from public.provider_documents where id = '00000000-0000-0000-0000-0000003512d3'),
  'the refused document is still pending');

rollback;
