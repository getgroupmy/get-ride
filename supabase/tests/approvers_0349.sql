-- ============================================================================
-- Regression test for migration 0349: the Approver grant model and admin
-- management.
--   * approver_config defaults/cleans a config.
--   * only an admin who can edit the Approvers page may set / remove / list.
--   * admin_set_approver grants; approver_self returns the caller's config;
--     admin_list_approvers shows them; admin_remove_approver soft-revokes
--     (active = false) so approver_self then returns null.
--   * a non-approver, and an expired grant, read approver_self as null.
--   * an approver reads their own row; a non-admin cannot read others'.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approvers_0349.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000349a1'),  -- admin (edit Approvers)
  ('00000000-0000-0000-0000-0000000349u1'),  -- the approver
  ('00000000-0000-0000-0000-0000000349u2')   -- a plain user (not an approver)
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000349a1', 'Admin One', '+60100003491'),
  ('00000000-0000-0000-0000-0000000349u1', 'Approver One', '+60100003492'),
  ('00000000-0000-0000-0000-0000000349u2', 'Plain User', '+60100003493')
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000349a1', 'admin-approvers', 'edit')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text) to authenticated;

-- 0. Config defaults.
select pg_temp.check(public.approver_config('{}'::jsonb) ->> 'scope' = 'referral'
                       and (public.approver_config('{}'::jsonb) ->> 'can_approve') = 'false'
                       and (public.approver_config('{}'::jsonb) ->> 'conflict_guard') = 'true',
  'an empty config defaults to a read-only, conflict-guarded referral approver');
select pg_temp.check(public.approver_config('{"scope":"bogus"}'::jsonb) ->> 'scope' = 'referral',
  'an unknown scope falls back to referral');

set local role authenticated;

-- 1. A non-admin cannot manage approvers.
select pg_temp.as_user('00000000-0000-0000-0000-0000000349u2');
select pg_temp.check(pg_temp.errored($q$select public.admin_set_approver('00000000-0000-0000-0000-0000000349u1', '{}')$q$),
  'a non-admin cannot grant an approver');
select pg_temp.check(pg_temp.errored($q$select * from public.admin_list_approvers()$q$),
  'a non-admin cannot list approvers');

-- 2. The admin grants one.
select pg_temp.as_user('00000000-0000-0000-0000-0000000349a1');
select pg_temp.check((public.admin_set_approver('00000000-0000-0000-0000-0000000349u1',
                        '{"can_approve":true,"can_delete":true,"scope":"region","note":"pilot"}'::jsonb) ->> 'can_approve') = 'true',
  'the admin grants an approve/delete, region-scoped approver');
select pg_temp.check((select count(*) = 1 from public.admin_list_approvers()
                        where profile_id = '00000000-0000-0000-0000-0000000349u1' and scope = 'region' and can_approve),
  'the approver shows in the admin list');

-- 3. The approver reads their own grant.
select pg_temp.as_user('00000000-0000-0000-0000-0000000349u1');
select pg_temp.check((public.approver_self() ->> 'can_approve') = 'true'
                       and (public.approver_self() ->> 'scope') = 'region'
                       and (public.approver_self() ->> 'can_delete') = 'true',
  'the approver reads their own permissions and scope');
select pg_temp.check((select count(*) = 1 from public.approvers where profile_id = '00000000-0000-0000-0000-0000000349u1'),
  'the approver can read their own row');

-- 4. A non-approver reads null.
select pg_temp.as_user('00000000-0000-0000-0000-0000000349u2');
select pg_temp.check(public.approver_self() is null, 'a non-approver has no grant');

-- 5. Remove = soft revoke: the grant goes inactive and approver_self clears.
select pg_temp.as_user('00000000-0000-0000-0000-0000000349a1');
select public.admin_remove_approver('00000000-0000-0000-0000-0000000349u1');
reset role;
select pg_temp.check((select not active from public.approvers where profile_id = '00000000-0000-0000-0000-0000000349u1'),
  'the grant is kept but inactive');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000349u1');
select pg_temp.check(public.approver_self() is null, 'a revoked approver has no grant');

-- 6. An expired grant reads null too.
reset role;
update public.approvers set active = true, ends_at = now() - interval '1 day'
 where profile_id = '00000000-0000-0000-0000-0000000349u1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000349u1');
select pg_temp.check(public.approver_self() is null, 'an expired grant is inactive');
reset role;

rollback;
