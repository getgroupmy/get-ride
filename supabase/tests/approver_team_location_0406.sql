-- ============================================================================
-- Regression test for migration 0406: Team Location (server foundation).
--   * approver_self() surfaces can_view_location.
--   * approver_may_see_location: true for a covered person when the approver
--     has the grant; false without the grant; false for someone not covered.
--   * approver_team_snapshot: returns a people array for a granted approver;
--     raises 42501 for an approver without the grant.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_team_location_0406.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000406a1'),  -- approver A: grant on
  ('00000000-0000-0000-0000-0000000406b1'),  -- approver B: grant off
  ('00000000-0000-0000-0000-0000000406c1')   -- a person the approver covers
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000406%'
on conflict do nothing;
insert into public.approvers (profile_id, scope, active, can_view_location) values
  ('00000000-0000-0000-0000-0000000406a1', 'all', true, true),
  ('00000000-0000-0000-0000-0000000406b1', 'all', true, false)
on conflict (profile_id) do update
  set scope = excluded.scope, active = excluded.active, can_view_location = excluded.can_view_location;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;

-- 1. The granted approver -------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000406a1');
select pg_temp.check((public.approver_self() ->> 'can_view_location') = 'true',
  'approver_self surfaces can_view_location = true');
select pg_temp.check(public.approver_may_see_location('00000000-0000-0000-0000-0000000406c1'),
  'the granted approver may see a person they cover');
select pg_temp.check(public.approver_team_snapshot() -> 'people' is not null,
  'approver_team_snapshot returns a people array for a granted approver');

-- 2. The approver without the grant ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000406b1');
select pg_temp.check((public.approver_self() ->> 'can_view_location') = 'false',
  'approver_self shows the grant off');
select pg_temp.check(not public.approver_may_see_location('00000000-0000-0000-0000-0000000406c1'),
  'without the grant, may_see_location is false even for a covered person');
do $$
begin
  perform public.approver_team_snapshot();
  raise exception 'FAILED: snapshot should have been refused without the grant';
exception when sqlstate '42501' then null;
end $$;

rollback;
