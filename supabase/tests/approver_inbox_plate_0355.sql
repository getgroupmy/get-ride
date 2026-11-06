-- ============================================================================
-- Regression test for migration 0355: approver_pending_documents returns the
-- vehicle's plate with each vehicle document, and null for other sources.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_inbox_plate_0355.sql
--
-- Scoped to the fixtures below; runs in one transaction and is rolled back.
-- Made-up people and plates only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000355a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000355b1')   -- a vehicle owner
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000355a1', 'Approver', '+60100003551'),
  ('00000000-0000-0000-0000-0000000355b1', 'Car Owner', '+60100003552')
on conflict (id) do update set name = excluded.name;

insert into public.vehicle (id, auth_user_id, plate, make, model, color) values
  ('00000000-0000-0000-0000-0000003551f1', '00000000-0000-0000-0000-0000000355b1', ' TST 3551 ', 'Testmake', 'Car', 'Black')
on conflict (id) do nothing;
insert into public.vehicle_documents (id, vehicle_id, auth_user_id, doc_id, doc_name, status, file_url) values
  ('00000000-0000-0000-0000-0000003552f1', '00000000-0000-0000-0000-0000003551f1',
   '00000000-0000-0000-0000-0000000355b1', 'puspakom', 'Inspection (Puspakom)', 'Pending Review', 'v/f1.jpg')
on conflict (id) do nothing;
insert into public.identity_checks (id, user_id, kind, doc_type, purpose, status, mismatch, file_url) values
  ('00000000-0000-0000-0000-0000003553b1', '00000000-0000-0000-0000-0000000355b1', 'id', 'passport', 'first',
   'Pending Review', '{}'::text[], 'id/b1.jpg')
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;

-- Scope "all", no conflict guard, every document type.
insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types)
values ('00000000-0000-0000-0000-0000000355a1', 'all', false, false, '[]'::jsonb, '{}')
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
  use_own_region = excluded.use_own_region, regions = excluded.regions, doc_types = excluded.doc_types;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000355a1');

select pg_temp.check((select plate = 'TST 3551' from public.approver_pending_documents()
                       where doc_pk = '00000000-0000-0000-0000-0000003552f1'),
  'a vehicle document carries its vehicle''s plate, trimmed');
select pg_temp.check((select plate is null from public.approver_pending_documents()
                       where doc_pk = '00000000-0000-0000-0000-0000003553b1'),
  'a user ID document has no plate');

rollback;
