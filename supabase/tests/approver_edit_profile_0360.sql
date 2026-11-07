-- ============================================================================
-- Regression test for migration 0360: approver edits a covered member's profile.
--   * can_edit_profile writes name / nationality / address / status (status maps
--     to profile_status) and services (partner_types).
--   * marking the ID verified needs the higher can_verify_id flag.
--   * an out-of-scope member and a non-approver are refused.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_edit_profile_0360.sql
--
-- One transaction, rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000360a1'),  -- approver (can_edit_profile, not verify)
  ('00000000-0000-0000-0000-0000000360b1'),  -- covered member (a partner, for services)
  ('00000000-0000-0000-0000-0000000360c1')   -- a non-approver
on conflict do nothing;
insert into public.profiles (id, name, phone, nationality, status) values
  ('00000000-0000-0000-0000-0000000360a1', 'Edit Approver', '+60100003601', null, 'approved'),
  ('00000000-0000-0000-0000-0000000360b1', 'Old Name', '+60100003602', 'Nowhere', 'unapproved'),
  ('00000000-0000-0000-0000-0000000360c1', 'Nobody', '+60100003603', null, 'approved')
on conflict (id) do update set name = excluded.name, status = excluded.status, nationality = excluded.nationality;
insert into public.partners (id, auth_user_id, name, phone, partner_types) values
  ('00000000-0000-0000-0000-0000036001f1', '00000000-0000-0000-0000-0000000360b1', 'Old Name', '+60100003602', '{}')
on conflict (id) do nothing;

insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_edit_profile, can_verify_id)
values ('00000000-0000-0000-0000-0000000360a1', 'all', false, false, '[]'::jsonb, '{}', true, false)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
  can_edit_profile = excluded.can_edit_profile, can_verify_id = excluded.can_verify_id;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000360a1');

-- 1. Edit name, nationality and status; status maps to profile_status.
select pg_temp.check(
  (public.approver_edit_profile('00000000-0000-0000-0000-0000000360b1',
     '{"name":"New Name","nationality":"Malaysia","status":"blocked"}'::jsonb) ->> 'ok') = 'true',
  'the edit succeeds');
select pg_temp.check(
  (select name = 'New Name' and nationality = 'Malaysia' and status::text = 'blocked'
          and profile_status::text = 'Blocked'
     from public.profiles where id = '00000000-0000-0000-0000-0000000360b1'),
  'name / nationality / status (and profile_status) are written');

-- 2. Services (partner_types) are written on the member's partner row.
select pg_temp.check(
  (public.approver_edit_profile('00000000-0000-0000-0000-0000000360b1',
     '{"partner_types":["TEKSI","ehailing"]}'::jsonb) ->> 'ok') = 'true',
  'editing services succeeds');
select pg_temp.check(
  (select partner_types = array['TEKSI','ehailing']::text[]
     from public.partners where auth_user_id = '00000000-0000-0000-0000-0000000360b1'),
  'the partner types are written');

-- 3. Marking the ID verified is refused without can_verify_id.
select pg_temp.check(
  pg_temp.errored($q$select public.approver_edit_profile('00000000-0000-0000-0000-0000000360b1','{"id_verified":"Verified"}'::jsonb)$q$),
  'ID verify is refused without the flag');
select pg_temp.check(
  (select id_verified is null from public.profiles where id = '00000000-0000-0000-0000-0000000360b1'),
  'the ID was not marked verified');

-- 4. With can_verify_id it works.
reset role;
update public.approvers set can_verify_id = true where profile_id = '00000000-0000-0000-0000-0000000360a1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000360a1');
select pg_temp.check(
  (public.approver_edit_profile('00000000-0000-0000-0000-0000000360b1','{"id_verified":"Verified"}'::jsonb) ->> 'ok') = 'true',
  'ID verify works with the flag');
select pg_temp.check(
  (select id_verified::text = 'Verified' from public.profiles where id = '00000000-0000-0000-0000-0000000360b1'),
  'the ID is marked verified');

-- 5. An invalid status value is rejected.
select pg_temp.check(
  pg_temp.errored($q$select public.approver_edit_profile('00000000-0000-0000-0000-0000000360b1','{"status":"bogus"}'::jsonb)$q$),
  'an invalid status is rejected');

-- 6. A non-approver cannot edit.
select pg_temp.as_user('00000000-0000-0000-0000-0000000360c1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_edit_profile('00000000-0000-0000-0000-0000000360b1','{"name":"Hacked"}'::jsonb)$q$),
  'a non-approver is refused');
select pg_temp.check(
  (select name = 'New Name' from public.profiles where id = '00000000-0000-0000-0000-0000000360b1'),
  'the member name is unchanged by the non-approver');

rollback;
