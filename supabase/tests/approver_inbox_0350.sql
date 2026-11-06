-- ============================================================================
-- Regression test for migration 0350: the Approver scoped, read-only inbox.
--   * approver_region_tags gathers a profile's partner service area.
--   * approver_covers honours all / region-overlap / referral and the
--     conflict guard (own documents, and off-referral the people referred).
--   * approver_pending_documents unions the three document stores (partner
--     registration, vehicle, user ID) and returns only pending documents in
--     the caller's scope, filtered by doc_types.
--   * a non-approver, a revoked grant and an expired grant all read empty.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_inbox_0350.sql
--
-- Every assertion is scoped to the fixtures below (owner_id in the fixture
-- set), so any rows already in the database never affect the result. Runs in
-- one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000350a1'),  -- the approver (a partner in KL)
  ('00000000-0000-0000-0000-0000000350b1'),  -- owner, partner in KL   (region overlap)
  ('00000000-0000-0000-0000-0000000350b2'),  -- owner, partner in Penang (no overlap)
  ('00000000-0000-0000-0000-0000000350b3'),  -- owner the approver referred
  ('00000000-0000-0000-0000-0000000350b4')   -- plain user with an ID document
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000350a1', 'Approver', '+60100003501'),
  ('00000000-0000-0000-0000-0000000350b1', 'KL Owner', '+60100003502'),
  ('00000000-0000-0000-0000-0000000350b2', 'Penang Owner', '+60100003503'),
  ('00000000-0000-0000-0000-0000000350b3', 'Referred Owner', '+60100003504'),
  ('00000000-0000-0000-0000-0000000350b4', 'Plain User', '+60100003505')
on conflict (id) do update set name = excluded.name;

-- The approver and two owners are partners with a service area.
insert into public.partners (id, auth_user_id, name, phone, service_cities) values
  ('00000000-0000-0000-0000-0000003501a1', '00000000-0000-0000-0000-0000000350a1', 'Approver', '+60100003501', '{"Kuala Lumpur"}'),
  ('00000000-0000-0000-0000-0000003501b1', '00000000-0000-0000-0000-0000000350b1', 'KL Owner', '+60100003502', '{"Kuala Lumpur"}'),
  ('00000000-0000-0000-0000-0000003501b2', '00000000-0000-0000-0000-0000000350b2', 'Penang Owner', '+60100003503', '{"George Town"}')
on conflict (id) do nothing;

-- A pending partner-registration document for each partner owner and the approver.
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url) values
  ('00000000-0000-0000-0000-0000003502a1', '00000000-0000-0000-0000-0000003501a1', '00000000-0000-0000-0000-0000000350a1', 'dreg', 'Licence', false, 'Pending Review', 'u/a1.jpg'),
  ('00000000-0000-0000-0000-0000003502b1', '00000000-0000-0000-0000-0000003501b1', '00000000-0000-0000-0000-0000000350b1', 'dreg', 'Licence', false, 'Pending Review', 'u/b1.jpg'),
  ('00000000-0000-0000-0000-0000003502b2', '00000000-0000-0000-0000-0000003501b2', '00000000-0000-0000-0000-0000000350b2', 'dreg', 'Licence', false, 'Pending Review', 'u/b2.jpg'),
  ('00000000-0000-0000-0000-0000003502b3', '00000000-0000-0000-0000-0000003501b1', '00000000-0000-0000-0000-0000000350b3', 'dreg', 'Licence', false, 'Pending Review', 'u/b3.jpg')
on conflict (id) do nothing;

-- A pending user ID document, and a profile-purpose check that is not reviewed.
insert into public.identity_checks (id, user_id, kind, doc_type, purpose, status, mismatch, file_url) values
  ('00000000-0000-0000-0000-0000003503b4', '00000000-0000-0000-0000-0000000350b4', 'id', 'passport', 'first', 'Pending Review', '{}'::text[], 'id/b4.jpg'),
  ('00000000-0000-0000-0000-0000003503b5', '00000000-0000-0000-0000-0000000350b4', 'selfie', null, 'profile', null, '{}'::text[], 'id/b4s.jpg')
on conflict (id) do nothing;

-- The approver referred b3.
insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000350a1', '00000000-0000-0000-0000-0000000350b3', 'REFCODE1')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
-- Grant / reconfigure the approver directly (admin_set_approver is tested in 0349).
create or replace function pg_temp.grant_approver(p_scope text, p_conflict boolean, p_own boolean, p_regions jsonb, p_doc_types text[])
returns void language plpgsql as $$
begin
  insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types)
  values ('00000000-0000-0000-0000-0000000350a1', p_scope, p_conflict, p_own, p_regions, p_doc_types)
  on conflict (profile_id) do update set
    active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
    use_own_region = excluded.use_own_region, regions = excluded.regions, doc_types = excluded.doc_types;
end $$;
-- The fixture owners returned by the inbox, sorted — ignores any pre-existing rows.
create or replace function pg_temp.fixture_owners() returns uuid[] language sql as $$
  select coalesce(array_agg(distinct owner_id order by owner_id), '{}'::uuid[])
    from public.approver_pending_documents()
   where owner_id = any(array['00000000-0000-0000-0000-0000000350a1','00000000-0000-0000-0000-0000000350b1',
                              '00000000-0000-0000-0000-0000000350b2','00000000-0000-0000-0000-0000000350b3',
                              '00000000-0000-0000-0000-0000000350b4']::uuid[]);
$$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid),
  pg_temp.grant_approver(text, boolean, boolean, jsonb, text[]), pg_temp.fixture_owners() to authenticated;

-- 0. Region tags come from the partner service area.
select pg_temp.check(public.approver_region_tags('00000000-0000-0000-0000-0000000350a1') = '{"kuala lumpur"}'::text[],
  'approver_region_tags lowercases and gathers the service area');
select pg_temp.check(public.approver_region_tags('00000000-0000-0000-0000-0000000350b4') = '{}'::text[],
  'a non-partner has no region tags');

set local role authenticated;

-- 1. Scope "all" with the conflict guard on: own documents and referred
--    people are hidden; the unreviewed profile selfie never shows.
select pg_temp.grant_approver('all', true, true, '[]'::jsonb, '{}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000350a1');
select pg_temp.check(pg_temp.fixture_owners() =
    array['00000000-0000-0000-0000-0000000350b1','00000000-0000-0000-0000-0000000350b2','00000000-0000-0000-0000-0000000350b4']::uuid[],
  'scope all + guard: b1, b2 and b4 — not own and not the referred b3');
select pg_temp.check((select count(*) = 1 from public.approver_pending_documents()
                        where source = 'identity' and owner_id = '00000000-0000-0000-0000-0000000350b4'),
  'the pending user ID document shows, the profile selfie does not');

-- 2. Conflict guard off: own and referred documents come back.
select pg_temp.grant_approver('all', false, true, '[]'::jsonb, '{}');
select pg_temp.check(pg_temp.fixture_owners() =
    array['00000000-0000-0000-0000-0000000350a1','00000000-0000-0000-0000-0000000350b1','00000000-0000-0000-0000-0000000350b2',
          '00000000-0000-0000-0000-0000000350b3','00000000-0000-0000-0000-0000000350b4']::uuid[],
  'scope all, guard off: every fixture owner');

-- 3. doc_types filter.
select pg_temp.grant_approver('all', false, true, '[]'::jsonb, '{other}');
select pg_temp.check(pg_temp.fixture_owners() = '{}'::uuid[],
  'a doc_types filter that matches nothing empties the inbox');
select pg_temp.grant_approver('all', false, true, '[]'::jsonb, '{dreg,passport}');
select pg_temp.check(pg_temp.fixture_owners() =
    array['00000000-0000-0000-0000-0000000350a1','00000000-0000-0000-0000-0000000350b1','00000000-0000-0000-0000-0000000350b2',
          '00000000-0000-0000-0000-0000000350b3','00000000-0000-0000-0000-0000000350b4']::uuid[],
  'doc_types matches the partner doc_id and the identity doc_type');

-- 4. Region scope, own region (KL): KL owner and own doc overlap; Penang does not.
select pg_temp.grant_approver('region', false, true, '[]'::jsonb, '{}');
select pg_temp.check(pg_temp.fixture_owners() =
    array['00000000-0000-0000-0000-0000000350a1','00000000-0000-0000-0000-0000000350b1']::uuid[],
  'region/own: the KL owner and the approver''s own KL doc, not Penang or non-partners');

-- 5. Region scope with the guard on hides the approver's own doc.
select pg_temp.grant_approver('region', true, true, '[]'::jsonb, '{}');
select pg_temp.check(pg_temp.fixture_owners() = array['00000000-0000-0000-0000-0000000350b1']::uuid[],
  'region + guard: only the KL owner');

-- 6. Region scope from admin-set regions (Penang), own region off.
select pg_temp.grant_approver('region', false, false, '["George Town"]'::jsonb, '{}');
select pg_temp.check(pg_temp.fixture_owners() = array['00000000-0000-0000-0000-0000000350b2']::uuid[],
  'admin-set regions reach the Penang owner, not the KL ones');

-- 7. Referral scope: only the referred owner, regardless of the guard.
select pg_temp.grant_approver('referral', true, true, '[]'::jsonb, '{}');
select pg_temp.check(pg_temp.fixture_owners() = array['00000000-0000-0000-0000-0000000350b3']::uuid[],
  'referral scope reaches the referred owner even with the guard on');

-- 8. A non-approver, a revoked grant and an expired grant all read empty.
select pg_temp.as_user('00000000-0000-0000-0000-0000000350b2');
select pg_temp.check(pg_temp.fixture_owners() = '{}'::uuid[], 'a non-approver sees nothing');
reset role;
update public.approvers set active = false where profile_id = '00000000-0000-0000-0000-0000000350a1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000350a1');
select pg_temp.check(pg_temp.fixture_owners() = '{}'::uuid[], 'a revoked approver sees nothing');
reset role;
update public.approvers set active = true, ends_at = now() - interval '1 day'
 where profile_id = '00000000-0000-0000-0000-0000000350a1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000350a1');
select pg_temp.check(pg_temp.fixture_owners() = '{}'::uuid[], 'an expired grant sees nothing');
reset role;

rollback;
