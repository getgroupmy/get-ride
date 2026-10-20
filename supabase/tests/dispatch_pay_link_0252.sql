-- ============================================================================
-- Regression test for migration 0252's Order Dispatch payment links: a card
-- / e-wallet stand order is paid by a link from the dispatch account; the
-- intent is the customer's total (fare + the fee they bear), reused while
-- pending; the link is put on the order and texted; paid and done in either
-- order, the driver's share goes to their GET.wallet and the stand's share
-- of its fee to its GET.wallet, exactly once; the stand's credit limit
-- doesn't hold it up. With no dispatch account it is the counter's, as
-- before. Only the server changes the link's columns.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/dispatch_pay_link_0252.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('authenticated', 'public.payment_dispatch_intent(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.payment_dispatch_link_set(uuid, text, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.payment_dispatch_paid(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.payment_dispatch_link_allowed(uuid)', 'execute') then
    raise exception 'FAILED: a server-only payment link function is callable by the app';
  end if;
end $$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-00000252da01', '60100025201'),  -- full admin (operates the console)
  ('00000000-0000-0000-0000-00000252da02', '60100025202'),  -- stand owner (earns the fee)
  ('00000000-0000-0000-0000-00000252dd01', '60100025211'),  -- driver, group member
  ('00000000-0000-0000-0000-00000252dd02', '60100025212')   -- driver, not in the stand's groups
on conflict do nothing;
insert into public.profiles (id, name) select id, 'P' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-00000252d%'
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-00000252da01', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status, plate, vehicle_type) values
  ('00000000-0000-0000-0000-00000252dd01', 'Ali', '60100025211', 'approved', 'WPL 2521', 'Taxi'),
  ('00000000-0000-0000-0000-00000252dd02', 'Hafiz', '60100025212', 'approved', 'WPL 2522', 'Taxi');
-- RM 2 from the customer; the platform takes 20 % of it; the stand keeps RM 1.60.
insert into public.dispatch_stands (id, name, kind, code, lat, lng, allow_fixed_fare, settlement,
                                    fee_type, fee_value, fee_bearer, platform_fee_type, platform_fee_value, owner_id) values
  ('00000000-0000-0000-0000-00000252de01', 'Link Mall', 'mall', 'LNK', 3.149, 101.713, true, 'wallet',
   'fixed', 2, 'customer', 'percent', 20, '00000000-0000-0000-0000-00000252da02');
insert into public.dispatch_groups (id, name, kind, members_first_sec) values
  ('00000000-0000-0000-0000-00000252df01', 'Link Mall drivers', 'closed', 0);
insert into public.dispatch_stand_groups (stand_id, group_id) values
  ('00000000-0000-0000-0000-00000252de01', '00000000-0000-0000-0000-00000252df01');
insert into public.dispatch_group_members (group_id, driver_id, status) values
  ('00000000-0000-0000-0000-00000252df01', '00000000-0000-0000-0000-00000252dd01', 'approved');

-- No gateway account yet.
delete from public.settings_entries where category = 'payment-gateway';

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
create or replace function pg_temp.refused_with(p_sql text, p_msg text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like '%' || p_msg || '%' then
      raise exception 'FAILED (% refused with "%", expected "%")', p_what, sqlerrm, p_msg;
    end if;
    return;
  end;
  raise exception 'FAILED (not refused): %', p_what;
end $$;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated, service_role;
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from ids where k = p_k $$;
create or replace function pg_temp.order_as(p_k text, p_order jsonb) returns void language sql as $$
  insert into ids values (p_k, (public.dispatch_create_order('00000000-0000-0000-0000-00000252de01', p_order)->>'id')::uuid);
$$;
-- Taken by the member, picked up and done (a metered one at [p_fare]).
create or replace function pg_temp.ride(p_k text, p_fare numeric default null) returns void language plpgsql as $$
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-00000252dd01');
  update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-00000252dd01',
         partner_name = 'Ali' where id = pg_temp.id(p_k) and status = 'open';
  perform pg_temp.as_user('00000000-0000-0000-0000-00000252da01');
  perform public.dispatch_order_action(pg_temp.id(p_k), 'picked_up');
  perform public.dispatch_order_action(pg_temp.id(p_k), 'complete',
    case when p_fare is null then '{}'::jsonb else jsonb_build_object('fare', p_fare) end);
end $$;
create or replace function pg_temp.ledger(p_k text) returns text language sql as $$
  select coalesce(string_agg(kind || ':' || amount::text, ',' order by kind), '')
    from public.wallet_transactions where ride_id = pg_temp.id(p_k);
$$;
create or replace function pg_temp.order_json(p_k text) returns jsonb language sql security definer as $$
  select public.dispatch_order_json(pg_temp.id(p_k));
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.as_service(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.refused_with(text, text, text), pg_temp.id(text),
  pg_temp.order_as(text, jsonb), pg_temp.ride(text, numeric), pg_temp.ledger(text), pg_temp.order_json(text)
  to authenticated, service_role;

-- ---- 1. No dispatch account: a card / e-wallet order is the counter's, as before --------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000252da01');
select pg_temp.check(not public.dispatch_pay_link_available(), 'links available without a gateway');
select pg_temp.order_as('nolink', '{"drop_name": "KLCC", "mode": "broadcast",
  "group_id": "00000000-0000-0000-0000-00000252df01", "fare_mode": "fixed", "fare": 20, "payment": "app"}');
select pg_temp.check(not (pg_temp.order_json('nolink')->>'pay_link')::boolean, 'a link without a gateway');
select pg_temp.ride('nolink');
reset role;
select pg_temp.check(pg_temp.ledger('nolink') = 'stand_payout:20.00,stand_payout_due:-20.00,stand_platform_fee:-0.40',
  'no gateway: the counter settlement, got ' || pg_temp.ledger('nolink'));
select pg_temp.check((select paid_method = 'counter' from public.ride_requests where id = pg_temp.id('nolink')),
  'no gateway: paid at the counter');

-- ---- 2. A dispatch account: card / e-wallet orders are paid by a link -------------------------------------
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-00000252d0f1', 'payment-gateway',
   '{"providerId":"stripe","providerName":"Stripe","accountName":"Live","mode":"Live","active":true,"isDefault":true}', 1);
-- The stand can carry no more counter orders.
update public.dispatch_stands set credit_limit = 0 where id = '00000000-0000-0000-0000-00000252de01';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000252da01');
select pg_temp.refused($q$select public.dispatch_create_order('00000000-0000-0000-0000-00000252de01',
  '{"drop_name": "KLCC", "mode": "broadcast", "group_id": "00000000-0000-0000-0000-00000252df01",
    "fare_mode": "fixed", "fare": 30, "payment": "counter"}')$q$, 'a counter order past the limit');
select pg_temp.order_as('first', '{"drop_name": "KLCC", "mode": "broadcast",
  "group_id": "00000000-0000-0000-0000-00000252df01", "fare_mode": "fixed", "fare": 30, "payment": "app",
  "customer_name": "Aminah", "customer_phone": "+60123450001"}');
select pg_temp.order_as('later', '{"drop_name": "Mid Valley", "mode": "broadcast",
  "group_id": "00000000-0000-0000-0000-00000252df01", "fare_mode": "fixed", "fare": 20, "payment": "app"}');
select pg_temp.order_as('meter', '{"drop_name": "Cheras", "mode": "broadcast",
  "group_id": "00000000-0000-0000-0000-00000252df01", "payment": "app"}');
select pg_temp.check((pg_temp.order_json('first')->>'pay_link')::boolean, 'a card order with a gateway is a link order');
select pg_temp.check(public.dispatch_pay_link_available(), 'links not available with a gateway');
select pg_temp.check(public.payment_dispatch_link_allowed(pg_temp.id('first')), 'the operator may ask for its link');
select pg_temp.check((public.dispatch_stand_credit('00000000-0000-0000-0000-00000252de01')->>'pending')::numeric = 0,
  'a link order counts against the stand''s credit');
-- Only the server touches the link.
select pg_temp.refused($q$update public.ride_requests set dispatch_pay_paid_at = now() where id = pg_temp.id('first')$q$,
  'the operator marks it paid');
select pg_temp.as_user('00000000-0000-0000-0000-00000252dd02');
select pg_temp.check(not public.payment_dispatch_link_allowed(pg_temp.id('first')), 'another driver asks for its link');
reset role;

-- ---- 3. The intent, the link, the SMS ------------------------------------------------------------------
set local role service_role;
select pg_temp.as_service();
do $$
declare
  a jsonb;
  b jsonb;
begin
  a := public.payment_dispatch_intent(pg_temp.id('first'));
  perform pg_temp.check((a->>'amount')::numeric = 32 and a->>'purpose' = 'dispatch'
                        and a->>'purpose_ref' = pg_temp.id('first')::text and a->>'provider' = 'stripe'
                        and not (a->>'test_mode')::boolean, 'intent: ' || a::text);
  perform pg_temp.check(a->'customer'->>'phone' = '+60123450001' and a->'customer'->>'name' = 'Aminah', 'customer');
  b := public.payment_dispatch_intent(pg_temp.id('first'));
  perform pg_temp.check(a->>'id' = b->>'id', 'a second ask made another intent');
  perform pg_temp.refused_with(format('select public.payment_dispatch_intent(%L)', pg_temp.id('meter')),
    'fare_unknown', 'a metered order before its fare');
  perform pg_temp.refused_with(format('select public.payment_dispatch_intent(%L)', pg_temp.id('nolink')),
    'not_pay_link', 'an order taken at the counter');
  perform public.payment_dispatch_link_set(pg_temp.id('first'), 'https://checkout.stripe.com/c/pay/cs_1',
                                           '00000000-0000-0000-0000-00000252da01');
  perform pg_temp.check(pg_temp.order_json('first')->>'pay_url' = 'https://checkout.stripe.com/c/pay/cs_1'
                        and pg_temp.order_json('first')->>'pay_status' = 'pending'
                        and (pg_temp.order_json('first')->>'pay_amount')::numeric = 32, 'the link on the order');
  perform pg_temp.check(exists (select 1 from public.sms_outbox
                                 where body like '%pay RM 32.00 by card or e-wallet: https://checkout.stripe.com/c/pay/cs_1%'),
    'the link was not texted');
  perform pg_temp.check(exists (select 1 from public.dispatch_order_events
                                 where request_id = pg_temp.id('first') and action = 'pay_link'), 'not logged');
  perform pg_temp.refused_with(format('select public.payment_dispatch_link_set(%L, %L)', pg_temp.id('first'), 'http://x'),
    'unknown_order', 'a link that isn''t https');
end $$;
reset role;

-- ---- 4. Paid first, then done: settled when the trip is done, once --------------------------------------
do $$
declare
  j public.payment_intents;
begin
  select * into j from public.payment_intents where purpose_ref = pg_temp.id('first')::text;
  j := public.payment_intent_settle(j.reference, 'stripe', 'paid', 'cs_1', 32, 'MYR', null);
  perform pg_temp.check(j.applied = 'dispatch', 'applied ' || coalesce(j.applied, 'null'));
  perform pg_temp.check((select dispatch_pay_paid_at is not null and dispatch_settled_at is null
                           from public.ride_requests where id = pg_temp.id('first')), 'paid, not settled before the trip');
  perform pg_temp.check(pg_temp.ledger('first') = '', 'money moved before the trip');
  -- The provider says it again.
  j := public.payment_intent_settle(j.reference, 'stripe', 'paid', 'cs_1', 32, 'MYR', null);
end $$;
set local role authenticated;
select pg_temp.ride('first');
reset role;
select pg_temp.check(pg_temp.ledger('first') = 'stand_fee_earning:1.60,stand_payout:30.00',
  'paid by link: the driver''s fare and the stand''s share, got ' || pg_temp.ledger('first'));
select pg_temp.check((select user_id = '00000000-0000-0000-0000-00000252dd01' and wallet_type = 'get_wallet'
                        from public.wallet_transactions where ride_id = pg_temp.id('first') and kind = 'stand_payout')
  and (select user_id = '00000000-0000-0000-0000-00000252da02' and wallet_type = 'get_wallet'
         from public.wallet_transactions where ride_id = pg_temp.id('first') and kind = 'stand_fee_earning'),
  'who got what');
select pg_temp.check((select payment_status = 'paid' and paid_method = 'gateway' and paid_amount = 32
                             and stand_platform_fee = 0.40 and dispatch_settled_at is not null
                        from public.ride_requests where id = pg_temp.id('first')), 'the order is paid by link');
select public.dispatch_settle(pg_temp.id('first'));
select pg_temp.check(pg_temp.ledger('first') = 'stand_fee_earning:1.60,stand_payout:30.00', 'settled twice');

-- ---- 5. Done first, then paid: settled when the payment comes in ----------------------------------------
set local role authenticated;
select pg_temp.ride('later');
reset role;
select pg_temp.check((select dispatch_settled_at is null and payment_status is distinct from 'paid'
                        from public.ride_requests where id = pg_temp.id('later')), 'settled before it was paid');
select pg_temp.check(pg_temp.ledger('later') = '', 'money moved before the payment');
do $$
declare
  a jsonb;
  j public.payment_intents;
begin
  a := public.payment_dispatch_intent(pg_temp.id('later'));
  perform pg_temp.check((a->>'amount')::numeric = 22, 'later: ' || a::text);
  -- A wrong amount pays nothing.
  j := public.payment_intent_settle(a->>'reference', 'stripe', 'paid', 'cs_2', 2, 'MYR', null);
  perform pg_temp.check(pg_temp.ledger('later') = '', 'a wrong amount settled the order');
  j := public.payment_intent_settle(a->>'reference', 'stripe', 'paid', 'cs_2', 22, 'MYR', null);
  perform pg_temp.check(pg_temp.ledger('later') = 'stand_fee_earning:1.60,stand_payout:20.00',
    'paid after the trip: got ' || pg_temp.ledger('later'));
  perform pg_temp.refused_with(format('select public.payment_dispatch_intent(%L)', pg_temp.id('later')),
    'already_paid', 'a link for a paid order');
end $$;

-- ---- 6. A metered order: its link once the meter fare is in; a sandbox payment pays nothing out ----------
update public.settings_entries set values = values || '{"mode":"Sandbox"}' where id = '00000000-0000-0000-0000-00000252d0f1';
set local role authenticated;
select pg_temp.ride('meter', 15);
reset role;
do $$
declare
  a jsonb;
  j public.payment_intents;
begin
  a := public.payment_dispatch_intent(pg_temp.id('meter'));
  perform pg_temp.check((a->>'amount')::numeric = 17 and (a->>'test_mode')::boolean, 'meter: ' || a::text);
  j := public.payment_intent_settle(a->>'reference', 'stripe', 'paid', 'cs_3', 17, 'MYR', null);
  perform pg_temp.check(j.applied = 'test_mode', 'sandbox dispatch applied ' || coalesce(j.applied, 'null'));
  perform pg_temp.check(pg_temp.ledger('meter') = '', 'a sandbox payment paid the driver');
  perform pg_temp.check(exists (select 1 from public.dispatch_order_events
                                 where request_id = pg_temp.id('meter') and action = 'paid_test'), 'sandbox not logged');
end $$;

-- ---- 7. Every new column's foreign key has an index ------------------------------------------------------
select pg_temp.check(exists (select 1 from pg_index i
                              where i.indrelid = 'public.ride_requests'::regclass
                                and i.indkey[0] = (select attnum from pg_attribute
                                                    where attrelid = 'public.ride_requests'::regclass
                                                      and attname = 'dispatch_pay_intent_id')),
  'dispatch_pay_intent_id has no index');

select 'dispatch_pay_link_0252: all passed';
rollback;
