-- ============================================================================
-- Regression test for migration 0222: sending GET.coin is no phone-number
-- lookup, and commission rates and credit are the caller's own.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/wallet_recipient_scope.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000222a1'),  -- sender with no coins
  ('00000000-0000-0000-0000-0000000222a2'),  -- sender with coins
  ('00000000-0000-0000-0000-0000000222b1'),  -- a rider
  ('00000000-0000-0000-0000-0000000222b2')   -- a driver known only by their partner record
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000222%'
on conflict do nothing;
update public.profiles set phone = '+60129990222', name = 'Rina Rahman' where id = '00000000-0000-0000-0000-0000000222b1';
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000222b2', 'Daud Ismail', '+60129990333', 'approved');
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000222a2', 'get_coin', 'topup', 50, 'test', 'test');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
-- The error [p_sql] raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.error_of(text) to authenticated;
create temp table vals (k text primary key, v jsonb);
grant all on vals to authenticated;

-- 1. An empty wallet learns nothing about a number --------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000222a1');
select pg_temp.check(pg_temp.error_of($q$select public.wallet_request_coin_transfer(
  '00000000-0000-0000-0000-0000000222a1', 5, null, '+60129990222')$q$) = 'insufficient_coins',
  'a known number, no coins: insufficient');
-- Since 0223 a direct transfer is the server's only (the app asks with a request).
select pg_temp.check(pg_temp.error_of($q$select public.wallet_transfer_coins(
  '00000000-0000-0000-0000-0000000222a1', 5, null, '+60120000000')$q$) like '%permission denied%',
  'the app can''t move coins directly');
reset role;
select pg_temp.check(pg_temp.error_of($q$select public.wallet_transfer_coins(
  '00000000-0000-0000-0000-0000000222a1', 5, null, '+60120000000')$q$) = 'insufficient_coins',
  'an unknown number, no coins: the same answer');
set local role authenticated;

-- 2. A funded sender reaches a person, by the masked name only ---------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000222a2');
insert into vals select 'req', public.wallet_request_coin_transfer('00000000-0000-0000-0000-0000000222a2', 5, null, '0129990222');
select pg_temp.check((select not (v ? 'recipient_id') and v->>'recipient_name' is not null
                             and v->>'recipient_name' <> 'Rina Rahman' from vals where k = 'req'),
  'the answer carries a masked name, not the account');
reset role;
select pg_temp.check((select to_user_id = '00000000-0000-0000-0000-0000000222b1' from public.wallet_transfer_requests
                       where id = ((select v->>'request_id' from vals where k = 'req'))::uuid),
  'the request goes to the rider''s account');
-- Direct transfers run as the server (0223), still on the sender's claims.
insert into vals select 'driver', public.wallet_transfer_coins('00000000-0000-0000-0000-0000000222a2', 5, null, '+60129990333');
reset role;
select pg_temp.check((select balance = 5 from public.wallets
                       where user_id = '00000000-0000-0000-0000-0000000222b2' and wallet_type = 'get_coin'),
  'a driver found by their partner record is paid on their own account');
select pg_temp.check(pg_temp.error_of(format($q$select public.wallet_transfer_coins(
  '00000000-0000-0000-0000-0000000222a2', 1, %L)$q$,
  (select id from public.partners where auth_user_id = '00000000-0000-0000-0000-0000000222b2'))) = 'recipient_not_found',
  'a partner record''s own id is nobody''s wallet');

-- 3. Looking numbers up is limited per sender -------------------------------------------------
reset role;
select public.auth_rate_take('phone_resolve', '00000000-0000-0000-0000-0000000222a2', 20, interval '10 minutes')
  from generate_series(1, 20);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000222a2');
select pg_temp.check(pg_temp.error_of($q$select public.wallet_request_coin_transfer(
  '00000000-0000-0000-0000-0000000222a2', 1, null, '+60129990222')$q$) like 'RATE_LIMITED:%',
  'the 21st number in 10 minutes waits');
reset role;

-- 4. Commission: your own -------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated',
  'public.commission_resolve(uuid, double precision, double precision, text, text, text, text)', 'execute'),
  'nobody reads another driver''s rate');
select pg_temp.check(not has_function_privilege('authenticated', 'public.commission_resolve_rate(uuid, text, text, text, text)', 'execute'),
  'nor through the old name');
select pg_temp.check(not has_function_privilege('authenticated', 'public.commission_credit_ok(uuid)', 'execute'),
  'nor their credit standing');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000222b2');
select pg_temp.check(public.commission_credit_ok_self(), 'a driver reads their own');
reset role;

select 'wallet_recipient_scope: all passed';
rollback;
