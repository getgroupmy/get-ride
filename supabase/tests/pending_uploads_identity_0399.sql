-- ============================================================================
-- Regression test for migration 0399: Pending Upload lists ID / Passport where
-- the country requires it (rider_id_gate, migration 0342), for partner and user
-- alike, and only when the person hasn't verified or uploaded an ID yet.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pending_uploads_identity_0399.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000399a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000399b1'),  -- a user who needs to upload ID
  ('00000000-0000-0000-0000-0000000399b2'),  -- a user already ID-verified
  ('00000000-0000-0000-0000-0000000399b3')   -- a user with an ID check pending
on conflict do nothing;
insert into public.profiles (id, name, phone, nationality, id_verified) values
  ('00000000-0000-0000-0000-0000000399a1', 'Approver Nine', '+60100003991', 'Malaysia', null),
  ('00000000-0000-0000-0000-0000000399b1', 'Need ID',       '+60100003992', 'Malaysia', null),
  ('00000000-0000-0000-0000-0000000399b2', 'Done ID',       '+60100003993', 'Malaysia', 'Verified'),
  ('00000000-0000-0000-0000-0000000399b3', 'Pending ID',    '+60100003994', 'Malaysia', null)
on conflict (id) do update set nationality = excluded.nationality, id_verified = excluded.id_verified;

-- b3 has already uploaded an ID that is awaiting review.
insert into public.identity_checks (user_id, kind, file_url, status) values
  ('00000000-0000-0000-0000-0000000399b3', 'id', 'u/b3-id.jpg', 'Pending Review')
on conflict do nothing;

insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b1', 'T399CODE1'),
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b2', 'T399CODE2'),
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b3', 'T399CODE3')
on conflict (referred_user_id) do nothing;
insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_upload)
values ('00000000-0000-0000-0000-0000000399a1', 'referral', false, false, '[]'::jsonb, '{}', true)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = 'referral', conflict_guard = false, can_upload = true;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.has_id_row(p_member uuid) returns boolean language sql stable as $$
  select exists (select 1 from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
                  where e->>'member_id' = p_member::text and e->>'source' = 'identity');
$$;
grant execute on function pg_temp.has_id_row(uuid) to authenticated;

-- The country rule requires ID for everyone (master).
insert into public.app_settings (key, value, updated_at)
values ('rider_id_gate', '{"master": {"require": true}}'::jsonb, now())
on conflict (key) do update set value = excluded.value, updated_at = now();

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000399a1');

-- 1. The country requires ID and b1 hasn't verified → an ID/Passport row shows.
select pg_temp.check(pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b1'),
  'a member whose country requires ID and who is not verified is listed for ID / Passport');
select pg_temp.check(
  (select (e->>'is_partner')::boolean = false and e->>'name' = 'ID / Passport' and e->>'doc_id' = 'id'
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000399b1' and e->>'source' = 'identity'),
  'the ID row is tagged as a user (not a partner) and named ID / Passport');

-- 2. An already-verified member is not listed.
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b2'),
  'a verified member is not listed for ID');

-- 3. A member whose ID is already uploaded (pending review) is not listed.
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b3'),
  'a member with an ID check already pending is not listed');

-- 4. The nudge accepts the identity source.
select pg_temp.check(
  (public.approver_request_document_upload(
     '00000000-0000-0000-0000-0000000399b1', 'identity', 'id', 'ID / Passport') ->> 'ok')::boolean,
  'the ID / Passport nudge sends for the identity source');

-- 5. With the requirement off, nobody is listed for ID.
reset role;
update public.app_settings set value = '{"master": {"require": false}}'::jsonb where key = 'rider_id_gate';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000399a1');
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b1'),
  'with the country requirement off, no ID row is listed');

rollback;
