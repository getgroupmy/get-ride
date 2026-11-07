-- ============================================================================
-- Regression test for migration 0357: "My Team".
--   * approver_covered_partners lists the people the grant reaches, with card
--     fields (plate, pending-docs count), searchable and keyset-paginated.
--   * approver_owner_documents returns one covered person's documents across
--     every status, and nothing for a person the grant does not reach.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_team_0357.sql
--
-- Scoped to the fixtures below; runs in one transaction and is rolled back.
-- Made-up people and plates only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000357a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000357b1'),  -- Able (covered, has a vehicle + docs)
  ('00000000-0000-0000-0000-0000000357b2'),  -- Baker (covered, no vehicle)
  ('00000000-0000-0000-0000-0000000357b3')   -- Zara (covered)
on conflict do nothing;
insert into public.profiles (id, name, phone, ic, nationality) values
  ('00000000-0000-0000-0000-0000000357a1', 'Approver', '+60100003571', null, null),
  ('00000000-0000-0000-0000-0000000357b1', 'Able Owner', '+60100003572', '900101015571', 'Malaysia'),
  ('00000000-0000-0000-0000-0000000357b2', 'Baker Owner', '+60100003573', null, null),
  ('00000000-0000-0000-0000-0000000357b3', 'Zara Owner', '+60100003574', null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone, ic = excluded.ic;

insert into public.vehicle (id, auth_user_id, plate, make, model, color, status) values
  ('00000000-0000-0000-0000-0000035701f1', '00000000-0000-0000-0000-0000000357b1', ' WXY 3571 ', 'Testmake', 'Sedan', 'Blue', 'approved')
on conflict (id) do nothing;
insert into public.vehicle_documents (id, vehicle_id, auth_user_id, doc_id, doc_name, status, file_url) values
  ('00000000-0000-0000-0000-0000035702f1', '00000000-0000-0000-0000-0000035701f1',
   '00000000-0000-0000-0000-0000000357b1', 'puspakom', 'Inspection (Puspakom)', 'Pending Review', 'v/f1.jpg'),
  ('00000000-0000-0000-0000-0000035702f2', '00000000-0000-0000-0000-0000035701f1',
   '00000000-0000-0000-0000-0000000357b1', 'roadtax', 'Road tax', 'Approved', 'v/f2.jpg')
on conflict (id) do nothing;
insert into public.identity_checks (id, user_id, kind, doc_type, purpose, status, mismatch, file_url) values
  ('00000000-0000-0000-0000-0000035703b1', '00000000-0000-0000-0000-0000000357b1', 'id', 'passport', 'first',
   'Pending Review', '{}'::text[], 'id/b1.jpg'),
  -- A profile-purpose selfie (status null) that must NOT show as a document.
  ('00000000-0000-0000-0000-0000035703b2', '00000000-0000-0000-0000-0000000357b1', 'selfie', null, 'profile',
   null, '{}'::text[], 'id/b2.jpg')
on conflict (id) do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;

-- Scope "all", no conflict guard, every document type.
insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types)
values ('00000000-0000-0000-0000-0000000357a1', 'all', false, false, '[]'::jsonb, '{}')
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
  use_own_region = excluded.use_own_region, regions = excluded.regions, doc_types = excluded.doc_types;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000357a1');

-- 1. Able appears, carries the trimmed plate, the "Make Model" label and its two pending docs.
select pg_temp.check(
  (select plate = 'WXY 3571' and vehicle_label = 'Testmake Sedan' and pending_docs = 2
     from public.approver_covered_partners(null, null, null, 50)
    where owner_id = '00000000-0000-0000-0000-0000000357b1'),
  'Able carries the trimmed plate, the vehicle label and a pending-docs count of 2');

-- 2. Baker has no vehicle (null plate) and no pending documents.
select pg_temp.check(
  (select plate is null and pending_docs = 0
     from public.approver_covered_partners(null, null, null, 50)
    where owner_id = '00000000-0000-0000-0000-0000000357b2'),
  'Baker has a null plate and no pending documents');

-- 3. Search by plate finds Able and only Able (of our fixtures).
select pg_temp.check(
  (select count(*) = 1
     from public.approver_covered_partners('WXY 3571', null, null, 50)
    where owner_id in ('00000000-0000-0000-0000-0000000357b1',
                       '00000000-0000-0000-0000-0000000357b2',
                       '00000000-0000-0000-0000-0000000357b3')),
  'search by plate returns exactly Able among the fixtures');

-- 4. Keyset pagination: the page after "Able Owner" never repeats Able.
select pg_temp.check(
  not exists (
    select 1 from public.approver_covered_partners(
      null, 'Able Owner', '00000000-0000-0000-0000-0000000357b1', 50)
     where owner_id = '00000000-0000-0000-0000-0000000357b1'),
  'the keyset cursor after Able does not return Able again');

-- 5. approver_owner_documents returns Able's three reviewable docs (2 vehicle + 1 identity),
--    across statuses, and skips the profile-purpose selfie.
select pg_temp.check(
  (select count(*) = 3 from public.approver_owner_documents('00000000-0000-0000-0000-0000000357b1')),
  'owner documents returns Able''s three reviewable documents, skipping the profile selfie');

-- 6. The approved road-tax row is included with its real status (all statuses, not just pending).
select pg_temp.check(
  (select status = 'Approved' from public.approver_owner_documents('00000000-0000-0000-0000-0000000357b1')
    where doc_pk = '00000000-0000-0000-0000-0000035702f2'),
  'owner documents includes the approved document with its status');

-- 7. A grant with conflict_guard on never lists the approver themselves.
update public.approvers set conflict_guard = true where profile_id = '00000000-0000-0000-0000-0000000357a1';
select pg_temp.check(
  not exists (select 1 from public.approver_covered_partners(null, null, null, 50)
               where owner_id = '00000000-0000-0000-0000-0000000357a1'),
  'the approver is never in their own team list');

-- 8. A non-approver gets nothing from either function.
select pg_temp.as_user('00000000-0000-0000-0000-0000000357b2');
select pg_temp.check(
  (select count(*) = 0 from public.approver_covered_partners(null, null, null, 50)),
  'a non-approver sees no team');
select pg_temp.check(
  (select count(*) = 0 from public.approver_owner_documents('00000000-0000-0000-0000-0000000357b1')),
  'a non-approver sees no owner documents');

rollback;
