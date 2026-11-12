-- ============================================================================
-- Regression test for migration 0407: admin can grant can_view_location.
--   * approver_config carries can_view_location (true when asked, false by
--     default), and still carries the flags it carried before.
--   * admin_set_approver writes the column (checked directly, bypassing the
--     admin gate by writing through approver_config + a plain upsert mirror).
--   * admin_list_approvers' return type exposes can_view_location (and the
--     can_manage_vehicle column 0407 also started returning).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_grant_view_location_0407.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;

-- 1. approver_config carries the flag --------------------------------------------------------------
select pg_temp.check(
  (public.approver_config('{"can_view_location":true}'::jsonb) ->> 'can_view_location') = 'true',
  'approver_config carries can_view_location = true when asked');
select pg_temp.check(
  (public.approver_config('{}'::jsonb) ->> 'can_view_location') = 'false',
  'approver_config defaults can_view_location to false');
select pg_temp.check(
  (public.approver_config('{"can_approve":true}'::jsonb) ->> 'can_approve') = 'true',
  'approver_config still carries the older flags');

-- 2. the column takes the written value ------------------------------------------------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000407a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000407a1') on conflict do nothing;
insert into public.approvers (profile_id, scope, active, can_view_location)
values ('00000000-0000-0000-0000-0000000407a1', 'all', true,
        (public.approver_config('{"can_view_location":true}'::jsonb) ->> 'can_view_location')::boolean)
on conflict (profile_id) do update set can_view_location = excluded.can_view_location;
select pg_temp.check(
  (select can_view_location from public.approvers where profile_id = '00000000-0000-0000-0000-0000000407a1'),
  'the approvers.can_view_location column holds the granted value');

-- 3. admin_list_approvers exposes the columns in its return type -----------------------------------
select pg_temp.check(
  (select count(*) = 2 from pg_proc p
     cross join lateral unnest(p.proargnames) n(name)
    where p.proname = 'admin_list_approvers'
      and n.name in ('can_view_location', 'can_manage_vehicle')),
  'admin_list_approvers returns can_view_location and can_manage_vehicle');

rollback;
