-- ============================================================================
-- Regression test for migration 0362: approver proposes a member's new number;
-- the member confirms it through the ordinary change-number flow and marks it
-- applied.
--   * an approver with can_edit_profile files a proposal (push aside); it is
--     stored as clean E.164, a local-format number is refused, same/in-use are
--     refused, a second proposal replaces the first.
--   * the member reads their own pending proposal, cannot mark it applied until
--     profiles.phone actually matches, and then can.
--   * a non-approver, and an approver without can_edit_profile, are refused.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/member_phone_proposal_0362.sql
--
-- One transaction, rolled back. Made-up people only. The RPC calls run as the
-- approver/member; the DB-state checks run as the owner, because the proposals
-- table (and profiles) RLS shows a row only to the member, the proposer or an
-- admin.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000362a1'),  -- approver (can_edit_profile)
  ('00000000-0000-0000-0000-0000000362b1'),  -- covered member
  ('00000000-0000-0000-0000-0000000362c1'),  -- a non-approver
  ('00000000-0000-0000-0000-0000000362d1')   -- an approver WITHOUT can_edit_profile
on conflict do nothing;
insert into public.profiles (id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000362a1', 'Phone Approver', '+60100003621', 'approved'),
  ('00000000-0000-0000-0000-0000000362b1', 'Phone Member',   '+60100003622', 'approved'),
  ('00000000-0000-0000-0000-0000000362c1', 'Nobody',         '+60100003623', 'approved'),
  ('00000000-0000-0000-0000-0000000362d1', 'Weak Approver',  '+60100003624', 'approved')
on conflict (id) do update set name = excluded.name, phone = excluded.phone, status = excluded.status;

insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_edit_profile)
values
  ('00000000-0000-0000-0000-0000000362a1', 'all', false, false, '[]'::jsonb, '{}', true),
  ('00000000-0000-0000-0000-0000000362d1', 'all', false, false, '[]'::jsonb, '{}', false)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
  can_edit_profile = excluded.can_edit_profile;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000362a1');

-- 1. The approver proposes an international-format number; stored as clean E.164.
select pg_temp.check(
  (public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1', '+60 11-2345 6789') ->> 'ok') = 'true',
  'the proposal succeeds');
reset role;
select pg_temp.check(
  (select proposed_phone = '+601123456789' and status = 'pending' and proposed_by = '00000000-0000-0000-0000-0000000362a1'
     from public.member_phone_proposals where member_id = '00000000-0000-0000-0000-0000000362b1' and status = 'pending'),
  'the proposal is stored as clean E.164, pending, by the approver');

-- 2. Bad inputs are refused.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000362a1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1','011-2345 6789')$q$),
  'a local-format number (leading 0) is refused');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1','+60100003622')$q$),
  'proposing the member''s current number is refused');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1','123')$q$),
  'an implausible number is refused');

-- 3. A second proposal replaces the first (one pending per member).
select pg_temp.check(
  (public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1', '+60133334444') ->> 'ok') = 'true',
  'a replacement proposal succeeds');
reset role;
select pg_temp.check(
  (select count(*) = 1 from public.member_phone_proposals
    where member_id = '00000000-0000-0000-0000-0000000362b1' and status = 'pending'),
  'only one pending proposal remains');
select pg_temp.check(
  (select count(*) = 1 from public.member_phone_proposals
    where member_id = '00000000-0000-0000-0000-0000000362b1' and status = 'cancelled'),
  'the earlier proposal was cancelled');

-- 4. The member reads their own pending proposal.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000362b1');
select pg_temp.check(
  (public.member_phone_proposal() ->> 'proposed_phone') = '+60133334444'
    and (public.member_phone_proposal() ->> 'by_name') = 'Phone Approver',
  'the member reads the pending number and who proposed it');

-- 5. Apply is refused until the member''s number actually matches.
select pg_temp.check(
  pg_temp.errored($q$select public.member_apply_phone_proposal(
    (select id from public.member_phone_proposals where member_id = '00000000-0000-0000-0000-0000000362b1' and status = 'pending'))$q$),
  'the member cannot mark it applied before the number has changed');

-- The member confirms the change through the ordinary flow; profiles.phone follows.
reset role;
update public.profiles set phone = '+60133334444' where id = '00000000-0000-0000-0000-0000000362b1';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000362b1');
select pg_temp.check(
  (public.member_apply_phone_proposal(
    (select id from public.member_phone_proposals where member_id = '00000000-0000-0000-0000-0000000362b1' and status = 'pending')) ->> 'ok') = 'true',
  'the member marks it applied once their number matches');
reset role;
select pg_temp.check(
  (select status = 'applied' and decided_at is not null
     from public.member_phone_proposals where member_id = '00000000-0000-0000-0000-0000000362b1' and status = 'applied'),
  'the proposal is marked applied');

-- 6. A non-approver, and an approver without can_edit_profile, are refused.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000362c1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1','+60155556666')$q$),
  'a non-approver cannot propose');
select pg_temp.as_user('00000000-0000-0000-0000-0000000362d1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_propose_member_phone('00000000-0000-0000-0000-0000000362b1','+60155556666')$q$),
  'an approver without can_edit_profile cannot propose');

rollback;
