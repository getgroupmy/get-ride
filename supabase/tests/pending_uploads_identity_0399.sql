-- ============================================================================
-- Regression test for migration 0399: Pending Upload lists ID / Passport for a
-- PARTNER whose service country requires it (rider_id_gate, migration 0342),
-- and only when the partner hasn't verified or uploaded an ID yet. A plain user
-- (no service country) is not listed here.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pending_uploads_identity_0399.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000399a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000399b1'),  -- partner serving Malaysia (ID on), unverified
  ('00000000-0000-0000-0000-0000000399b2'),  -- partner serving Singapore (ID off), unverified
  ('00000000-0000-0000-0000-0000000399b3'),  -- partner serving Malaysia, already verified
  ('00000000-0000-0000-0000-0000000399b4')   -- a plain user (no service country)
on conflict do nothing;
insert into public.profiles (id, name, phone, id_verified) values
  ('00000000-0000-0000-0000-0000000399a1', 'Approver Nine',  '+60100003991', null),
  ('00000000-0000-0000-0000-0000000399b1', 'MY Partner',     '+60100003992', null),
  ('00000000-0000-0000-0000-0000000399b2', 'SG Partner',     '+65100003993', null),
  ('00000000-0000-0000-0000-0000000399b3', 'Verified MY',    '+60100003994', 'Verified'),
  ('00000000-0000-0000-0000-0000000399b4', 'Plain User',     '+60100003995', null)
on conflict (id) do update set id_verified = excluded.id_verified;

insert into public.partners (id, auth_user_id, name, phone, service_countries) values
  ('00000000-0000-0000-0000-0000039900e1', '00000000-0000-0000-0000-0000000399b1', 'MY Partner',  '+60100003992', '{Malaysia}'),
  ('00000000-0000-0000-0000-0000039900e2', '00000000-0000-0000-0000-0000000399b2', 'SG Partner',  '+65100003993', '{Singapore}'),
  ('00000000-0000-0000-0000-0000039900e3', '00000000-0000-0000-0000-0000000399b3', 'Verified MY', '+60100003994', '{Malaysia}')
on conflict (id) do nothing;

insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b1', 'T399CODE1'),
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b2', 'T399CODE2'),
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b3', 'T399CODE3'),
  ('00000000-0000-0000-0000-0000000399a1', '00000000-0000-0000-0000-0000000399b4', 'T399CODE4')
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

-- Malaysia requires ID; Singapore does not.
insert into public.app_settings (key, value, updated_at)
values ('rider_id_gate', '{"Malaysia": {"require": true}, "Singapore": {"require": false}}'::jsonb, now())
on conflict (key) do update set value = excluded.value, updated_at = now();

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000399a1');

-- 1. A partner serving a country that requires ID, not yet verified → listed.
select pg_temp.check(pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b1'),
  'a partner whose service country (Malaysia) requires ID and who is unverified is listed');
select pg_temp.check(
  (select (e->>'is_partner')::boolean and e->>'name' = 'ID / Passport' and e->>'doc_id' = 'id'
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000399b1' and e->>'source' = 'identity'),
  'the ID row is a partner row named ID / Passport');

-- 2. A partner whose service country does NOT require ID is not listed.
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b2'),
  'a partner serving a country where ID is not required is not listed');

-- 3. A verified partner is not listed.
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b3'),
  'a verified partner is not listed');

-- 4. A plain user (no service country) is not listed here.
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b4'),
  'a plain user is not listed for ID (location-based, enforced at booking time)');

-- 5. The nudge accepts the identity source.
select pg_temp.check(
  (public.approver_request_document_upload(
     '00000000-0000-0000-0000-0000000399b1', 'identity', 'id', 'ID / Passport') ->> 'ok')::boolean,
  'the ID / Passport nudge sends for the identity source');

-- 6. With Malaysia's requirement off, the partner is no longer listed.
reset role;
update public.app_settings set value = '{"Malaysia": {"require": false}}'::jsonb where key = 'rider_id_gate';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000399a1');
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000399b1'),
  'with the service country requirement off, the partner is not listed');

rollback;
