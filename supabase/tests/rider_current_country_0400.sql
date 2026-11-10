-- ============================================================================
-- Regression test for migration 0400: a rider's current country drives the ID
-- requirement (Pending Upload list + the booking gate), with set_my_current_country.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rider_current_country_0400.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000400a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000400b1'),  -- user currently in Malaysia (ID on)
  ('00000000-0000-0000-0000-0000000400b2'),  -- user currently in Singapore (ID off)
  ('00000000-0000-0000-0000-0000000400b3'),  -- user with no current country
  ('00000000-0000-0000-0000-0000000400b4')   -- Malaysian national, currently in Singapore
on conflict do nothing;
insert into public.profiles (id, name, phone, nationality, current_country, id_verified, total_rides) values
  ('00000000-0000-0000-0000-0000000400a1', 'Approver Ten', '+60100004001', 'Malaysia', null,        null, 0),
  ('00000000-0000-0000-0000-0000000400b1', 'In Malaysia',  '+60100004002', 'Malaysia', 'Malaysia',  null, 0),
  ('00000000-0000-0000-0000-0000000400b2', 'In Singapore', '+60100004003', 'Malaysia', 'Singapore', null, 0),
  ('00000000-0000-0000-0000-0000000400b3', 'No Country',   '+60100004004', 'Malaysia', null,        null, 0),
  ('00000000-0000-0000-0000-0000000400b4', 'MY in SG',     '+60100004005', 'Malaysia', 'Singapore', null, 5)
on conflict (id) do update set
  nationality = excluded.nationality, current_country = excluded.current_country,
  id_verified = excluded.id_verified, total_rides = excluded.total_rides;

insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000400a1', '00000000-0000-0000-0000-0000000400b1', 'T400CODE1'),
  ('00000000-0000-0000-0000-0000000400a1', '00000000-0000-0000-0000-0000000400b2', 'T400CODE2'),
  ('00000000-0000-0000-0000-0000000400a1', '00000000-0000-0000-0000-0000000400b3', 'T400CODE3')
on conflict (referred_user_id) do nothing;
insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_upload)
values ('00000000-0000-0000-0000-0000000400a1', 'referral', false, false, '[]'::jsonb, '{}', true)
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

insert into public.app_settings (key, value, updated_at)
values ('rider_id_gate', '{"Malaysia": {"require": true}, "Singapore": {"require": false}}'::jsonb, now())
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The booking gate follows the current country, overriding nationality.
select pg_temp.check(public.rider_id_gate_block('00000000-0000-0000-0000-0000000400b1'),
  'a rider currently in Malaysia (ID on, unverified) is gated at booking');
select pg_temp.check(not public.rider_id_gate_block('00000000-0000-0000-0000-0000000400b2'),
  'a rider currently in Singapore (ID off) is not gated');
select pg_temp.check(not public.rider_id_gate_block('00000000-0000-0000-0000-0000000400b4'),
  'a Malaysian national currently in Singapore is not gated (current country wins over nationality)');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000400a1');

-- The Pending Upload list shows a plain user by their current country.
select pg_temp.check(pg_temp.has_id_row('00000000-0000-0000-0000-0000000400b1'),
  'a user currently in a country that requires ID is listed');
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000400b2'),
  'a user currently where ID is not required is not listed');
select pg_temp.check(not pg_temp.has_id_row('00000000-0000-0000-0000-0000000400b3'),
  'a user with no current country is not listed');
select pg_temp.check(
  (select not (e->>'is_partner')::boolean
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000400b1' and e->>'source' = 'identity'),
  'the user ID row is tagged as a user (not a partner)');

-- set_my_current_country moves a user into (and the booking gate follows).
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000400b3');
select public.set_my_current_country('Malaysia');
select pg_temp.as_user('00000000-0000-0000-0000-0000000400a1');
select pg_temp.check(pg_temp.has_id_row('00000000-0000-0000-0000-0000000400b3'),
  'after set_my_current_country(Malaysia) the user is listed');
reset role;
select pg_temp.check(public.rider_id_gate_block('00000000-0000-0000-0000-0000000400b3'),
  'and the booking gate now blocks them');

rollback;
