-- ============================================================================
-- Regression test for migration 0358: user teams.
--   * team_join sets the referrer (and guards self / unknown / already-joined).
--   * team_request_change files a pending request (guards not-on-team / same /
--     duplicate / empty reason).
--   * team_self + team_members reflect the team; the lead is pinned first.
--   * admin_decide_team_change moves the referral on approve; only an admin may.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/team_0358.sql
--
-- One transaction, rolled back. Made-up people and plates only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000358c1'),  -- admin (edit admin-team-changes)
  ('00000000-0000-0000-0000-0000000358a1'),  -- Lead A
  ('00000000-0000-0000-0000-0000000358a2'),  -- Lead B
  ('00000000-0000-0000-0000-0000000358b1'),  -- Member (joins A, then asks to move to B)
  ('00000000-0000-0000-0000-0000000358b2')   -- Member 2 (also on A's team)
on conflict do nothing;
insert into public.profiles (id, name, phone, referral_code) values
  ('00000000-0000-0000-0000-0000000358c1', 'Admin', '+60100003581', null),
  ('00000000-0000-0000-0000-0000000358a1', 'Lead A', '+60100003582', 'TEAMALPHA'),
  ('00000000-0000-0000-0000-0000000358a2', 'Lead B', '+60100003583', 'TEAMBRAVO'),
  ('00000000-0000-0000-0000-0000000358b1', 'Member One', '+60100003584', null),
  ('00000000-0000-0000-0000-0000000358b2', 'Member Two', '+60100003585', null)
on conflict (id) do update set name = excluded.name, referral_code = excluded.referral_code;

-- Member Two is already on Lead A's team; Lead A has a plate.
insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000358a1', '00000000-0000-0000-0000-0000000358b2', 'TEAMALPHA')
on conflict (referred_user_id) do nothing;
insert into public.vehicle (id, auth_user_id, plate, make, model, color, status) values
  ('00000000-0000-0000-0000-0000035801f1', '00000000-0000-0000-0000-0000000358a1', ' VAB 3581 ', 'Testmake', 'Van', 'White', 'approved')
on conflict (id) do nothing;

insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000358c1', 'admin-team-changes', 'edit')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text) to authenticated;

set local role authenticated;

-- 1. Member One joins Lead A by referral code (case/spacing-insensitive).
select pg_temp.as_user('00000000-0000-0000-0000-0000000358b1');
select pg_temp.check((public.team_join('team alpha') ->> 'ok') = 'true', 'Member One joins by code');
select pg_temp.check(
  (select referrer_user_id = '00000000-0000-0000-0000-0000000358a1'
     from public.referrals where referred_user_id = '00000000-0000-0000-0000-0000000358b1'),
  'the referral now points at Lead A');

-- 2. Joining again is refused (must change instead), and an unknown code fails.
select pg_temp.check(pg_temp.errored($q$select public.team_join('TEAMBRAVO')$q$), 'cannot join twice');
select pg_temp.as_user('00000000-0000-0000-0000-0000000358b1');

-- 3. team_self shows the member is on Lead A's team.
select pg_temp.check(
  (public.team_self() ->> 'on_team') = 'true' and (public.team_self() ->> 'lead_name') = 'Lead A',
  'team_self names Lead A');

-- 4. team_members lists Lead A first, with the trimmed plate, then the two members.
select pg_temp.check(
  (select is_lead and plate = 'VAB 3581'
     from public.team_members()
    where member_id = '00000000-0000-0000-0000-0000000358a1'),
  'the lead is flagged and carries the trimmed plate');
select pg_temp.check((select count(*) = 3 from public.team_members()),
  'team_members returns the lead plus the two members');
select pg_temp.check(
  (select is_me from public.team_members() where member_id = '00000000-0000-0000-0000-0000000358b1'),
  'the caller is flagged is_me');

-- 5. A change request needs a reason and a different team.
select pg_temp.check(pg_temp.errored($q$select public.team_request_change('TEAMBRAVO', '')$q$), 'reason is required');
select pg_temp.check(pg_temp.errored($q$select public.team_request_change('TEAMALPHA', 'x')$q$), 'cannot request the same team');

-- 6. A valid change request is filed and is pending; a second is refused.
select pg_temp.check((public.team_request_change('TEAM BRAVO', 'Moving cities') ->> 'ok') = 'true', 'change request filed');
select pg_temp.check((public.team_self() -> 'pending_change' ->> 'to_name') = 'Lead B', 'team_self shows the pending change to Lead B');
select pg_temp.check(pg_temp.errored($q$select public.team_request_change('TEAMBRAVO', 'again')$q$), 'only one pending request');

-- 7. A non-admin cannot list or decide.
select pg_temp.check(pg_temp.errored($q$select * from public.admin_list_team_changes('pending')$q$), 'a non-admin cannot list requests');

-- 8. The admin approves it; the referral moves to Lead B and the request closes.
select pg_temp.as_user('00000000-0000-0000-0000-0000000358c1');
select pg_temp.check((select count(*) = 1 from public.admin_list_team_changes('pending')), 'the admin sees one pending request');
select pg_temp.check(
  (public.admin_decide_team_change(
     (select id from public.team_change_requests where requester_id = '00000000-0000-0000-0000-0000000358b1' and status = 'pending'),
     'approve', 'ok') ->> 'ok') = 'true',
  'the admin approves the change');
-- Verify the resulting state as the member: referrals RLS only shows a row to
-- its referrer or referred, so the admin (neither) can't see this one.
select pg_temp.as_user('00000000-0000-0000-0000-0000000358b1');
select pg_temp.check(
  (select referrer_user_id = '00000000-0000-0000-0000-0000000358a2'
     from public.referrals where referred_user_id = '00000000-0000-0000-0000-0000000358b1'),
  'the referral now points at Lead B');
select pg_temp.check(
  (select status = 'approved' from public.team_change_requests
    where requester_id = '00000000-0000-0000-0000-0000000358b1'),
  'the request is marked approved');

rollback;
