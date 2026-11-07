-- ============================================================================
-- Regression test for migration 0359: approver adds credit to a covered member.
--   * a credit moves money GET.wallet -> GET.wallet and no further.
--   * the same request id never charges twice (idempotent).
--   * the wrong PIN, an over-cap amount, crediting yourself, an out-of-scope
--     member, and a grant without can_credit all move nothing.
--   * approver_member_wallet shows a covered member's balance.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_add_credit_0359.sql
--
-- One transaction, rolled back. Made-up people and phones only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000359a1'),  -- approver (can_credit, scope all)
  ('00000000-0000-0000-0000-0000000359b1'),  -- a covered member
  ('00000000-0000-0000-0000-0000000359c1')   -- a referral-only approver (for scope test)
on conflict do nothing;
-- PIN '123456' for the approvers; members need none.
insert into public.profiles (id, name, phone, pin_hash) values
  ('00000000-0000-0000-0000-0000000359a1', 'Credit Approver', '+60100003591', extensions.crypt('123456', extensions.gen_salt('bf'))),
  ('00000000-0000-0000-0000-0000000359b1', 'Credit Member', '+60100003592', null),
  ('00000000-0000-0000-0000-0000000359c1', 'Referral Approver', '+60100003593', extensions.crypt('123456', extensions.gen_salt('bf')))
on conflict (id) do update set phone = excluded.phone, pin_hash = excluded.pin_hash;

insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_credit)
values
  ('00000000-0000-0000-0000-0000000359a1', 'all', false, false, '[]'::jsonb, '{}', true),
  -- A referral-scoped approver who has referred nobody: covers no one.
  ('00000000-0000-0000-0000-0000000359c1', 'referral', true, false, '[]'::jsonb, '{}', true)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard,
  can_credit = excluded.can_credit, doc_types = excluded.doc_types;

-- The approver starts with RM500 in GET.wallet.
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
values ('00000000-0000-0000-0000-0000000359a1', 'get_wallet', 'seed', 500, 'seed');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create or replace function pg_temp.errored(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.errored(text) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000359a1');

-- 1. A valid credit returns ok and the amount.
select pg_temp.check(
  (public.approver_add_credit('00000000-0000-0000-0000-0000000359b1', 100, '123456',
     '11111111-1111-1111-1111-111111111111'::uuid) ->> 'ok') = 'true',
  'a valid credit succeeds');

-- 2. The money moved GET.wallet -> GET.wallet.
select pg_temp.check(
  (select balance = 400 from public.wallets
    where user_id = '00000000-0000-0000-0000-0000000359a1' and wallet_type = 'get_wallet'),
  'the approver was debited to 400');
-- Read the member's balance through the approver RPC: wallets RLS shows a row
-- only to its owner, so the approver cannot read the member's wallet directly.
select pg_temp.check(public.approver_member_wallet('00000000-0000-0000-0000-0000000359b1') = 100,
  'the member was credited to 100');

-- 3. The same request id does not charge again.
select pg_temp.check(
  (public.approver_add_credit('00000000-0000-0000-0000-0000000359b1', 100, '123456',
     '11111111-1111-1111-1111-111111111111'::uuid) ->> 'ok') = 'true',
  'the idempotent retry still returns ok');
select pg_temp.check(
  (select balance = 400 from public.wallets
    where user_id = '00000000-0000-0000-0000-0000000359a1' and wallet_type = 'get_wallet'),
  'the retry did not debit a second time');

-- 4. The wrong PIN moves nothing.
select pg_temp.check(
  pg_temp.errored($q$select public.approver_add_credit('00000000-0000-0000-0000-0000000359b1', 50, '000000',
     '22222222-2222-2222-2222-222222222222'::uuid)$q$),
  'a wrong PIN is refused');

-- 5. Over the per-top-up cap, and crediting yourself, are refused.
select pg_temp.check(
  pg_temp.errored($q$select public.approver_add_credit('00000000-0000-0000-0000-0000000359b1', 20000, '123456',
     '33333333-3333-3333-3333-333333333333'::uuid)$q$),
  'an amount over the cap is refused');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_add_credit('00000000-0000-0000-0000-0000000359a1', 10, '123456',
     '44444444-4444-4444-4444-444444444444'::uuid)$q$),
  'crediting yourself is refused');

-- 6. The approver still has 400 after all the refused attempts.
select pg_temp.check(
  (select balance = 400 from public.wallets
    where user_id = '00000000-0000-0000-0000-0000000359a1' and wallet_type = 'get_wallet'),
  'no refused attempt moved money');

-- 7. approver_member_wallet shows the member's balance to the approver.
select pg_temp.check(public.approver_member_wallet('00000000-0000-0000-0000-0000000359b1') = 100,
  'the approver can read the member''s wallet balance');

-- 8. A referral-scoped approver who covers no one cannot credit the member.
select pg_temp.as_user('00000000-0000-0000-0000-0000000359c1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_add_credit('00000000-0000-0000-0000-0000000359b1', 10, '123456',
     '55555555-5555-5555-5555-555555555555'::uuid)$q$),
  'an out-of-scope member is refused');
select pg_temp.check(public.approver_member_wallet('00000000-0000-0000-0000-0000000359b1') is null,
  'an out-of-scope member''s wallet is not readable');

-- 9. A grant without can_credit cannot credit at all.
reset role;
update public.approvers set can_credit = false where profile_id = '00000000-0000-0000-0000-0000000359a1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000359a1');
select pg_temp.check(
  pg_temp.errored($q$select public.approver_add_credit('00000000-0000-0000-0000-0000000359b1', 10, '123456',
     '66666666-6666-6666-6666-666666666666'::uuid)$q$),
  'a grant without can_credit is refused');

rollback;
