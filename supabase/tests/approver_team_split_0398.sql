-- ============================================================================
-- Regression test for migration 0398: My Team splits Partners from Users and
-- shows/sets the right approval status.
--   * approver_covered_partners returns is_partner + partner_status, filters by
--     p_kind ('partner'/'user'), and its Approved/Unapproved filter matches the
--     effective status (partner status for a partner, account status for a user).
--   * approver_set_member_approval approves the partner AND cascades to the user
--     account; un-approving a partner leaves the account; a plain user is set at
--     the account level.
--   * approver_pending_uploads tags each row with is_partner.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_team_split_0398.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000398a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000398b1'),  -- member A: a partner
  ('00000000-0000-0000-0000-0000000398b2')   -- member B: a plain user
on conflict do nothing;

-- A is a partner whose account is already approved but whose partner row is not.
insert into public.profiles (id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000398a1', 'Approver Eight', '+60100003981', 'approved'),
  ('00000000-0000-0000-0000-0000000398b1', 'Partner Able',   '+60100003982', 'approved'),
  ('00000000-0000-0000-0000-0000000398b2', 'User Baker',     '+60100003983', 'unapproved')
on conflict (id) do update set name = excluded.name, phone = excluded.phone, status = excluded.status;

insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000039800a1', '00000000-0000-0000-0000-0000000398b1', 'Partner Able', '+60100003982', 'unapproved')
on conflict (id) do update set status = excluded.status;

-- A required partner document neither A nor B has uploaded.
insert into public.required_document (id, values) values
  ('00000000-0000-0000-0000-0000039802d1',
   '{"name": "Test Partner Doc 398", "active": true, "required": true}')
on conflict (id) do nothing;

-- Scope the approver to just these two (referral), so prod's own data can't
-- crowd our members off the (name-ordered, capped) lists.
insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000398a1', '00000000-0000-0000-0000-0000000398b1', 'T398CODE1'),
  ('00000000-0000-0000-0000-0000000398a1', '00000000-0000-0000-0000-0000000398b2', 'T398CODE2')
on conflict (referred_user_id) do nothing;

insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_edit_profile)
values ('00000000-0000-0000-0000-0000000398a1', 'referral', false, false, '[]'::jsonb, '{}', true)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = 'referral', conflict_guard = false, can_edit_profile = true;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;

-- Helper: one row from the covered-people list for a given owner, as jsonb.
create or replace function pg_temp.row_for(p_owner uuid, p_kind text, p_status text) returns jsonb
language sql stable as $$
  select to_jsonb(t) from public.approver_covered_partners(null, null, null, 100, p_status, null, p_kind) t
   where t.owner_id = p_owner limit 1;
$$;
grant execute on function pg_temp.row_for(uuid, text, text) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000398a1');

-- 1. The partner row carries is_partner + the partner status (not the account one).
select pg_temp.check(
  (pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', null, null) ->> 'is_partner')::boolean
  and (pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', null, null) ->> 'partner_status') = 'unapproved'
  and (pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', null, null) ->> 'status') = 'approved',
  'a partner row shows is_partner, the partner status, and the account status separately');

-- 2. The user row is not a partner and has no partner status.
select pg_temp.check(
  not (pg_temp.row_for('00000000-0000-0000-0000-0000000398b2', null, null) ->> 'is_partner')::boolean
  and (pg_temp.row_for('00000000-0000-0000-0000-0000000398b2', null, null) -> 'partner_status') = 'null'::jsonb,
  'a plain user row is not a partner and has no partner status');

-- 3. p_kind splits the list.
select pg_temp.check(
  pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', 'partner', null) is not null
  and pg_temp.row_for('00000000-0000-0000-0000-0000000398b2', 'partner', null) is null,
  'p_kind = partner lists the partner and hides the user');
select pg_temp.check(
  pg_temp.row_for('00000000-0000-0000-0000-0000000398b2', 'user', null) is not null
  and pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', 'user', null) is null,
  'p_kind = user lists the user and hides the partner');

-- 4. The Approved/Unapproved filter matches the EFFECTIVE status: the partner
--    (account approved, partner unapproved) counts as unapproved here.
select pg_temp.check(
  pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', null, 'unapproved') is not null
  and pg_temp.row_for('00000000-0000-0000-0000-0000000398b1', null, 'approved') is null,
  'the partner filters as Unapproved by its partner status, not its approved account');

-- 5. Approving the partner approves the partner row AND cascades to the account.
--    (Start both unapproved to see the cascade.)
reset role;
update public.partners set status = 'unapproved' where id = '00000000-0000-0000-0000-0000039800a1';
update public.profiles set status = 'unapproved' where id = '00000000-0000-0000-0000-0000000398b1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000398a1');
select pg_temp.check(
  (public.approver_set_member_approval('00000000-0000-0000-0000-0000000398b1', true) ->> 'is_partner')::boolean,
  'approving a partner reports is_partner = true');
reset role;
select pg_temp.check(
  (select status::text from public.partners where id = '00000000-0000-0000-0000-0000039800a1') = 'approved'
  and (select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000398b1') = 'approved',
  'approving the partner sets the partner approved AND cascades the account to approved');

-- 6. Un-approving the partner touches only the partner row; the account stays.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000398a1');
select public.approver_set_member_approval('00000000-0000-0000-0000-0000000398b1', false);
reset role;
select pg_temp.check(
  (select status::text from public.partners where id = '00000000-0000-0000-0000-0000039800a1') = 'unapproved'
  and (select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000398b1') = 'approved',
  'un-approving the partner leaves the user account approved');

-- 7. A plain user is approved at the account level (no partner row created).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000398a1');
select pg_temp.check(
  not (public.approver_set_member_approval('00000000-0000-0000-0000-0000000398b2', true) ->> 'is_partner')::boolean,
  'approving a plain user reports is_partner = false');
reset role;
select pg_temp.check(
  (select status::text from public.profiles where id = '00000000-0000-0000-0000-0000000398b2') = 'approved'
  and not exists (select 1 from public.partners where auth_user_id = '00000000-0000-0000-0000-0000000398b2'),
  'approving a plain user approves the account and creates no partner row');

-- 8. A partner's pending-upload row is tagged is_partner = true; a plain user is
--    NOT listed for a partner document at all (migration 0398).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000398a1');
select pg_temp.check(
  (select (e->>'is_partner')::boolean
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000398b1'
      and e->>'doc_id' = '00000000-0000-0000-0000-0000039802d1'),
  'a partner''s pending-upload row for a partner document is tagged is_partner = true');
select pg_temp.check(
  not exists (select 1
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000398b2'),
  'a plain user is not listed to upload partner documents');

rollback;
