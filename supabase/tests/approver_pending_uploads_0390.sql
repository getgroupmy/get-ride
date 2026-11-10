-- ============================================================================
-- Regression test for approver_pending_uploads (migrations 0389/0390).
--   * The function unions the partner-document rows and the vehicle-document
--     rows and sorts them. It must RUN (migration 0390 left an ORDER BY with
--     expressions directly on the UNION ALL, which Postgres rejects at plan
--     time, so the function raised on every call and the Pending Upload tab was
--     always empty — fixed in 0395).
--   * A covered member who is missing a required partner document and whose
--     vehicle is missing a required vehicle document appears once for each.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_pending_uploads_0390.sql
--
-- Scoped to the fixtures below; runs in one transaction and is rolled back.
-- Made-up people, plates and documents only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000390a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000390b1')   -- Able (covered, has a vehicle)
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000390a1', 'Approver Nine', '+60100003901'),
  ('00000000-0000-0000-0000-0000000390b1', 'Able Ninety',   '+60100003902')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

insert into public.vehicle (id, auth_user_id, plate, make, model, color, status) values
  ('00000000-0000-0000-0000-0000039001f1', '00000000-0000-0000-0000-0000000390b1',
   'WXY 3901', 'Testmake', 'Sedan', 'Blue', 'approved')
on conflict (id) do nothing;

-- Able is a partner, so partner/driver documents are listed for them (0398).
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-000003900191', '00000000-0000-0000-0000-0000000390b1', 'Able Ninety', '+60100003902')
on conflict (id) do nothing;

-- Two required documents Able has not uploaded: one partner (no vehicle docType),
-- one vehicle (a Vehicle-category docType). Both active + required.
insert into public.required_document (id, values) values
  ('00000000-0000-0000-0000-0000039002d1',
   '{"name": "Test Partner Doc 390", "active": true, "required": true}'),
  ('00000000-0000-0000-0000-0000039002d2',
   '{"name": "Test Vehicle Doc 390", "active": true, "required": true, "docTypes": ["a7d71867-ac2a-4c0c-ae07-87e5d500693c"]}')
on conflict (id) do nothing;

insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types)
values ('00000000-0000-0000-0000-0000000390a1', 'all', false, false, '[]'::jsonb, '{}')
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000390a1');

-- The function runs (no plan-time ORDER BY error) and returns a JSON array.
select pg_temp.check(
  jsonb_typeof(public.approver_pending_uploads(null, 1000)) = 'array',
  'approver_pending_uploads runs and returns an array');

-- Able's missing partner document appears, with no vehicle.
select pg_temp.check(
  exists (select 1 from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
           where e->>'member_id' = '00000000-0000-0000-0000-0000000390b1'
             and e->>'source' = 'partner'
             and e->>'doc_id' = '00000000-0000-0000-0000-0000039002d1'
             and e->>'vehicle_id' is null),
  'the covered member''s missing partner document is listed');

-- Able's vehicle's missing vehicle document appears, carrying the plate.
select pg_temp.check(
  exists (select 1 from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
           where e->>'member_id' = '00000000-0000-0000-0000-0000000390b1'
             and e->>'source' = 'vehicle'
             and e->>'doc_id' = '00000000-0000-0000-0000-0000039002d2'
             and e->>'plate' = 'WXY 3901'),
  'the covered member''s missing vehicle document is listed with its plate');

-- A search that matches nobody returns an empty array (and still does not raise).
select pg_temp.check(
  public.approver_pending_uploads('zzz-no-such-member-zzz', 1000) = '[]'::jsonb,
  'a non-matching search returns an empty array');

rollback;
