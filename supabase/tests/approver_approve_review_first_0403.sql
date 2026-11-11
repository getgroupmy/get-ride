-- ============================================================================
-- Regression test for migration 0403: an approver who is also an admin can
-- approve a partner from My Team (approver_set_member_approval), without the
-- admin "Review application" flow — while a plain admin status change still
-- needs it (partners_approved_by, 0296).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_approve_review_first_0403.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000403a1'),  -- approver who is ALSO an admin
  ('00000000-0000-0000-0000-0000000403b1')   -- the member: a partner, unapproved
on conflict do nothing;
insert into public.profiles (id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000403a1', 'Approver Admin', '+60100004031', 'approved'),
  ('00000000-0000-0000-0000-0000000403b1', 'Partner Member', '+60100004032', 'unapproved')
on conflict (id) do update set name = excluded.name;
-- a1 is a full admin (so caller_is_admin() is true, the case that used to break).
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000403a1', '*', 'edit')
on conflict do nothing;
-- The partner being approved: unapproved, documents marked ok, NO review items.
insert into public.partners (id, auth_user_id, name, phone, status, documents_ok, partner_types) values
  ('00000000-0000-0000-0000-0000004031b1', '00000000-0000-0000-0000-0000000403b1', 'Partner Member', '+60100004032',
   'unapproved', true, array['DEALER'])
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', p::text, true); end $$;
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true); end $$;
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || ': ' || coalesce(h, ''); end $$;
-- Grant the approver (security definer, so the scope row is seeded regardless of RLS).
create or replace function pg_temp.grant_approver() returns void language plpgsql security definer as $$
begin
  insert into public.approvers (profile_id, can_edit_profile, scope, conflict_guard, use_own_region)
  values ('00000000-0000-0000-0000-0000000403a1', true, 'all', false, false)
  on conflict (profile_id) do update set active = true, ends_at = null, can_edit_profile = true, scope = 'all';
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.as_db(),
  pg_temp.error_of(text), pg_temp.grant_approver() to authenticated;

select pg_temp.grant_approver();
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000403a1');

-- 1. The admin-approver can approve the partner from My Team (0403) --------------------------------
select pg_temp.check(public.approver_covers('00000000-0000-0000-0000-0000000403b1'), 'the approver covers the member');
select pg_temp.check((public.approver_set_member_approval('00000000-0000-0000-0000-0000000403b1', true) ->> 'ok') = 'true',
  'the approver approve succeeds (no REVIEW_FIRST)');
reset role;
select pg_temp.check((select status::text = 'approved' from public.partners where id = '00000000-0000-0000-0000-0000004031b1'),
  'the partner is approved');
select pg_temp.check((select status::text = 'approved' from public.profiles where id = '00000000-0000-0000-0000-0000000403b1'),
  'the user account is approved too (cascade)');
select pg_temp.check((select approved_by = '00000000-0000-0000-0000-0000000403a1' from public.partners
                      where id = '00000000-0000-0000-0000-0000004031b1'),
  'approved_by is still stamped');

-- 2. A plain admin status change still needs the review flow --------------------------------------
-- Put the partner back to unapproved, then a direct admin approve (no approver
-- flag, no review items) must still raise REVIEW_FIRST.
select pg_temp.as_db();
update public.partners set status = 'unapproved', approved_by = null, approved_at = null
 where id = '00000000-0000-0000-0000-0000004031b1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000403a1');
select pg_temp.check(
  pg_temp.error_of($q$update public.partners set status = 'approved'
                     where id = '00000000-0000-0000-0000-0000004031b1'$q$) like 'REVIEW_FIRST:%',
  'a direct admin approve (not via the approver RPC) still requires the review flow');
reset role;

rollback;
