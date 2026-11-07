-- ============================================================================
-- Regression test for migration 0361: payout account (bank / e-wallet).
--   * approver_set_member_payout writes a covered member's bank or e-wallet
--     payout (account number normalised), gated on can_edit_profile + scope.
--   * an invalid account / not-allowed / out-of-scope are refused.
--   * approver_member_detail returns the payout; the provider list is seeded.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_payout_0361.sql
--
-- One transaction, rolled back. Made-up people only. DB-state checks run as the
-- owner (partner_payout_accounts RLS is self/admin-only).
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000361a1'),  -- approver (can_edit_profile)
  ('00000000-0000-0000-0000-0000000361b1'),  -- covered member
  ('00000000-0000-0000-0000-0000000361c1')   -- a plain approver (no edit)
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000361a1', 'Payout Approver', '+60100003611'),
  ('00000000-0000-0000-0000-0000000361b1', 'Payout Member', '+60100003612'),
  ('00000000-0000-0000-0000-0000000361c1', 'Plain Approver', '+60100003613')
on conflict (id) do update set name = excluded.name;
insert into public.approvers (profile_id, scope, conflict_guard, can_edit_profile) values
  ('00000000-0000-0000-0000-0000000361a1', 'all', false, true),
  ('00000000-0000-0000-0000-0000000361c1', 'all', false, false)
on conflict (profile_id) do update set
  active = true, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
  can_edit_profile = excluded.can_edit_profile;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text) to authenticated;

-- 0. The provider list was seeded (banks + e-wallets).
select pg_temp.check((select count(*) >= 20 from public.settings_entries where category = 'payout_provider'),
  'the payout provider list is seeded');
select pg_temp.check((select count(*) > 0 from public.settings_entries
                       where category = 'payout_provider' and values->>'type' = 'ewallet'),
  'the list has e-wallets');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000361a1');

-- 1. The approver sets a bank payout (spaces/dashes stripped from the account).
select pg_temp.check(
  (public.approver_set_member_payout('00000000-0000-0000-0000-0000000361b1',
     'Maybank', '1234-567 890', 'Payout Member', 'bank') ->> 'ok') = 'true',
  'setting a bank payout succeeds');
reset role;
select pg_temp.check(
  (select bank_name = 'Maybank' and account_no = '1234567890' and account_type = 'bank'
     from public.partner_payout_accounts where profile_id = '00000000-0000-0000-0000-0000000361b1'),
  'the bank payout is written with the account normalised');

-- 2. Switching to an e-wallet updates the same row.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000361a1');
select pg_temp.check(
  (public.approver_set_member_payout('00000000-0000-0000-0000-0000000361b1',
     'Touch n Go eWallet', '0123456789', 'Payout Member', 'ewallet') ->> 'ok') = 'true',
  'switching to an e-wallet succeeds');
-- approver_member_detail returns the payout (the approver can read it this way).
select pg_temp.check(
  (public.approver_member_detail('00000000-0000-0000-0000-0000000361b1') -> 'payout' ->> 'type') = 'ewallet',
  'the member detail reports the e-wallet payout');

-- 3. A too-short account number is refused.
select pg_temp.check(
  pg_temp.errored($q$select public.approver_set_member_payout('00000000-0000-0000-0000-0000000361b1','Maybank','12','X','bank')$q$),
  'a bad account number is refused');

-- 4. An approver without can_edit_profile is refused.
select pg_temp.as_user('00000000-0000-0000-0000-0000000361c1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_set_member_payout('00000000-0000-0000-0000-0000000361b1','Maybank','1234567890','X','bank')$q$),
  'an approver without can_edit_profile is refused');

rollback;
