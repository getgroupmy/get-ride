-- ============================================================================
-- Regression test for migration 0252: payment gateway secrets are
-- write-only (set, replaced and cleared by an admin who can edit Payment
-- Gateways, never read back; readable by the service role alone), a secret
-- put in the public record moves to Vault, which account takes which
-- payment, and payment intents (idempotent, the owner reads their own, a
-- paid top-up credits GET.wallet exactly once, a wrong amount or a sandbox
-- payment credits nothing).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payment_gateways_0252.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000252a1'),  -- admin, EDIT on Payment Gateways
  ('00000000-0000-0000-0000-0000000252a2'),  -- admin, READ on Payment Gateways
  ('00000000-0000-0000-0000-0000000252a3'),  -- admin, EDIT on another page
  ('00000000-0000-0000-0000-0000000252c1'),  -- riders
  ('00000000-0000-0000-0000-0000000252c2')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000252%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000252a1', 'admin-settings-payment-gateway', 'edit'),
  ('00000000-0000-0000-0000-0000000252a2', 'admin-settings-payment-gateway', 'read'),
  ('00000000-0000-0000-0000-0000000252a3', 'admin-settings-ip-access', 'edit')
on conflict do nothing;

-- Only these accounts, so the default and routing are this test's.
delete from public.settings_entries where category = 'payment-gateway';
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-0000002520f1', 'payment-gateway',
   '{"providerId":"stripe","providerName":"Stripe","accountName":"Live","mode":"Live","active":true,"isDefault":true}', 1),
  ('00000000-0000-0000-0000-0000002520f2', 'payment-gateway',
   '{"providerId":"billplz","providerName":"Billplz","accountName":"Sandbox","mode":"Sandbox","active":true,"billplz_collectionId":"col"}', 2);

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
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
-- Refused: an error, or no row touched.
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
    raise exception 'FAILED (not refused): %', p_what;
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
grant execute on function pg_temp.as_user(uuid), pg_temp.as_service(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.refused_with(text, text, text) to authenticated, anon, service_role;

-- ---- Grants -----------------------------------------------------------------------------------------
do $$
declare
  r_fn text;
begin
  perform pg_temp.check(not has_table_privilege('anon', 'public.payment_gateway_secrets', 'select'), 'anon reads secrets');
  perform pg_temp.check(not has_table_privilege('authenticated', 'public.payment_gateway_secrets', 'select'),
    'authenticated reads secrets');
  perform pg_temp.check(not has_table_privilege('authenticated', 'public.payment_gateway_secrets', 'insert'),
    'authenticated writes secrets');
  perform pg_temp.check(not has_function_privilege('authenticated', 'public.payment_gateway_account(uuid)', 'execute'),
    'authenticated reads an account with its secrets');
  perform pg_temp.check(not has_function_privilege('anon', 'public.payment_gateway_account(uuid)', 'execute'),
    'anon reads an account with its secrets');
  perform pg_temp.check(has_function_privilege('service_role', 'public.payment_gateway_account(uuid)', 'execute'),
    'the service role reads an account');
  perform pg_temp.check(not has_function_privilege('authenticated', 'public.payment_gateway_secret_store(uuid, text, text)', 'execute'),
    'authenticated stores a secret unchecked');
  perform pg_temp.check(not has_function_privilege('anon', 'public.payment_gateway_secret_set(uuid, text, text)', 'execute'),
    'anon sets a secret');
  foreach r_fn in array array[
    'public.payment_intent_create(uuid, text, numeric, text, text, uuid)',
    'public.payment_intent_settle(text, text, text, text, numeric, text, jsonb)',
    'public.payment_intent_set_checkout(uuid, text, text)',
    'public.payment_intent_apply(uuid)',
    'public.payment_gateway_for(text)'] loop
    perform pg_temp.check(not has_function_privilege('authenticated', r_fn, 'execute'), r_fn || ' callable by the app');
  end loop;
  perform pg_temp.check(not has_table_privilege('authenticated', 'public.payment_intents', 'insert'), 'the app makes intents');
  perform pg_temp.check(not has_table_privilege('authenticated', 'public.payment_intents', 'update'), 'the app settles intents');
  perform pg_temp.check(not has_table_privilege('authenticated', 'vault.decrypted_secrets', 'select'), 'the app reads Vault');
  perform pg_temp.check(exists (select 1 from public.admin_table_pages
                                  where target = 'payment_gateway_secrets' and page = 'admin-settings-payment-gateway'),
    'secrets are not scoped to the Payment Gateways page');
  perform pg_temp.check(exists (select 1 from public.admin_table_pages
                                  where target = 'payment_gateway_routing' and page = 'admin-settings-payment-gateway'),
    'routing is not scoped to the Payment Gateways page');
end $$;

-- ---- A secret written into the public record moves to Vault -------------------------------------------
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-0000002520f3', 'payment-gateway',
   '{"providerId":"stripe","providerName":"Stripe","accountName":"Old app","mode":"Live","active":false,
     "stripe_publishableKey":"pk_live_x","stripe_secretKey":"sk_live_LEGACYSECRET1234","stripe_webhookSecret":""}', 3);
do $$
declare
  v jsonb;
begin
  select values into v from public.settings_entries where id = '00000000-0000-0000-0000-0000002520f3';
  perform pg_temp.check(not (v ? 'stripe_secretKey') and not (v ? 'stripe_webhookSecret'), 'secret left in the public record');
  perform pg_temp.check(v ->> 'stripe_publishableKey' = 'pk_live_x', 'public field lost');
  perform pg_temp.check((select last4 from public.payment_gateway_secrets
                          where gateway_id = '00000000-0000-0000-0000-0000002520f3' and field = 'secretKey') = '1234',
    'moved secret not recorded');
  perform pg_temp.check((select d.decrypted_secret from public.payment_gateway_secrets s
                           join vault.decrypted_secrets d on d.id = s.vault_id
                          where s.gateway_id = '00000000-0000-0000-0000-0000002520f3' and s.field = 'secretKey')
                         = 'sk_live_LEGACYSECRET1234', 'moved secret not in Vault');
  perform pg_temp.check(not exists (select 1 from public.payment_gateway_secrets
                                     where gateway_id = '00000000-0000-0000-0000-0000002520f3' and field = 'webhookSecret'),
    'an empty secret was stored');
  -- An update does the same.
  update public.settings_entries set values = values || '{"stripe_webhookSecret":"whsec_LEGACYWEBHOOK99"}'
   where id = '00000000-0000-0000-0000-0000002520f3';
  select values into v from public.settings_entries where id = '00000000-0000-0000-0000-0000002520f3';
  perform pg_temp.check(not (v ? 'stripe_webhookSecret'), 'secret left in the record on update');
  perform pg_temp.check(exists (select 1 from public.payment_gateway_secrets
                                 where gateway_id = '00000000-0000-0000-0000-0000002520f3' and field = 'webhookSecret'),
    'secret not moved on update');
end $$;

-- ---- Admin with EDIT: set, replace, clear; never read back -----------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000252a1');
do $$
declare
  r jsonb;
  v_vault uuid;
begin
  r := public.payment_gateway_secret_set('00000000-0000-0000-0000-0000002520f1', 'secretKey', ' sk_live_abcdefghijklmnop ');
  perform pg_temp.check(r ->> 'last4' = 'mnop' and (r ->> 'set')::boolean and (r ->> 'length')::int = 24,
    'set answer: ' || r::text);
  perform pg_temp.check(r::text not like '%abcdefgh%', 'set answers the secret');
  perform pg_temp.check((select last4 from public.payment_gateway_secret_status()
                          where gateway_id = '00000000-0000-0000-0000-0000002520f1' and field = 'secretKey') = 'mnop',
    'status does not show the last 4');
  perform pg_temp.refused('select * from public.payment_gateway_secrets', 'an admin selects the secrets table');
  perform pg_temp.refused('select * from vault.decrypted_secrets', 'an admin reads Vault');
  perform pg_temp.refused('select public.payment_gateway_account(''00000000-0000-0000-0000-0000002520f1'')',
    'an admin reads an account with its secrets');
  -- Replace: the same Vault secret, a new value.
  r := public.payment_gateway_secret_set('00000000-0000-0000-0000-0000002520f1', 'secretKey', 'sk_live_REPLACED0000wxyz');
  perform pg_temp.check(r ->> 'last4' = 'wxyz', 'replace');
  -- A short secret shows no characters.
  r := public.payment_gateway_secret_set('00000000-0000-0000-0000-0000002520f1', 'webhookSecret', 'short1');
  perform pg_temp.check(r ->> 'last4' is null and (r ->> 'length')::int = 6, 'a short secret shows its end');
  -- Clear.
  r := public.payment_gateway_secret_set('00000000-0000-0000-0000-0000002520f1', 'webhookSecret', '');
  perform pg_temp.check(not (r ->> 'set')::boolean, 'clear');
  perform pg_temp.check(not exists (select 1 from public.payment_gateway_secret_status()
                                     where gateway_id = '00000000-0000-0000-0000-0000002520f1' and field = 'webhookSecret'),
    'cleared secret still listed');
  perform pg_temp.refused_with(
    'select public.payment_gateway_secret_set(''00000000-0000-0000-0000-0000002520f1'', ''apiKey'', ''x'')',
    'unknown_secret_field', 'a field Stripe does not have');
  perform pg_temp.refused_with(
    'select public.payment_gateway_secret_set(''00000000-0000-0000-0000-0000002520f1'', ''publishableKey'', ''x'')',
    'unknown_secret_field', 'a public field as a secret');
  perform pg_temp.refused_with(
    'select public.payment_gateway_secret_set(''00000000-0000-0000-0000-000000000000'', ''secretKey'', ''x'')',
    'unknown_gateway', 'an unknown account');
  -- Routing.
  update public.payment_gateway_routing set gateway_id = '00000000-0000-0000-0000-0000002520f2' where purpose = 'dispatch';
  perform pg_temp.check(found, 'the admin could not choose an account');
end $$;
select pg_temp.as_service();
reset role;
do $$ begin
  perform pg_temp.check((select count(*) from vault.secrets where name like 'payment_gateway:00000000-0000-0000-0000-0000002520f1:%') = 1,
    'Vault keeps a cleared secret');
end $$;

-- ---- Admin with READ, admin of another page, rider ----------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000252a2');
do $$ begin
  perform pg_temp.refused_with(
    'select public.payment_gateway_secret_set(''00000000-0000-0000-0000-0000002520f1'', ''secretKey'', ''sk_x_hijack'')',
    'not_authorized', 'a READ admin sets a secret');
  perform pg_temp.check((select count(*) from public.payment_gateway_secret_status()) >= 1, 'a READ admin sees the status');
  perform pg_temp.refused('update public.payment_gateway_routing set gateway_id = null where purpose = ''dispatch''',
    'a READ admin changes the routing');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000252a3');
do $$ begin
  perform pg_temp.refused_with(
    'select public.payment_gateway_secret_set(''00000000-0000-0000-0000-0000002520f1'', ''secretKey'', ''sk_x_hijack'')',
    'not_authorized', 'another page''s admin sets a secret');
  perform pg_temp.refused('update public.payment_gateway_routing set gateway_id = null where purpose = ''dispatch''',
    'another page''s admin changes the routing');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000252c1');
do $$
declare
  r jsonb;
begin
  perform pg_temp.refused_with('select * from public.payment_gateway_secret_status()', 'not_authorized', 'a rider sees the status');
  perform pg_temp.refused_with(
    'select public.payment_gateway_secret_set(''00000000-0000-0000-0000-0000002520f1'', ''secretKey'', ''x'')',
    'not_authorized', 'a rider sets a secret');
  perform pg_temp.check((select count(*) from public.payment_gateway_routing) = 0, 'a rider reads the routing');
  -- What the app is told: no credentials.
  r := public.payment_purpose_info('wallet_topup');
  perform pg_temp.check((r ->> 'available')::boolean and r ->> 'provider' = 'stripe' and not (r ->> 'test_mode')::boolean,
    'purpose info: ' || r::text);
  perform pg_temp.check(r::text not like '%sk_live%', 'purpose info leaks a key');
  r := public.payment_purpose_info('dispatch');
  perform pg_temp.check(r ->> 'provider' = 'billplz' and (r ->> 'test_mode')::boolean, 'routed purpose: ' || r::text);
end $$;
reset role;

-- ---- The service role reads secrets (the payments function) --------------------------------------------
set local role service_role;
select pg_temp.as_service();
do $$
declare
  a jsonb;
begin
  a := public.payment_gateway_account('00000000-0000-0000-0000-0000002520f1');
  perform pg_temp.check(a -> 'secrets' ->> 'secretKey' = 'sk_live_REPLACED0000wxyz', 'service role secret: ' || (a -> 'secrets')::text);
  perform pg_temp.check(not (a -> 'secrets' ? 'webhookSecret'), 'a cleared secret is still read');
  perform pg_temp.check(public.payment_gateway_for('wallet_topup') = '00000000-0000-0000-0000-0000002520f1',
    'the default account takes top-ups');
  perform pg_temp.check(public.payment_gateway_for('dispatch') = '00000000-0000-0000-0000-0000002520f2',
    'the chosen account takes dispatch payments');
end $$;

-- ---- Payment intents ----------------------------------------------------------------------------------
do $$
declare
  i public.payment_intents;
  j public.payment_intents;
  n integer;
  bal numeric;
begin
  i := public.payment_intent_create('00000000-0000-0000-0000-0000000252c1', 'wallet_topup', 50, 'key-c1-00000001');
  j := public.payment_intent_create('00000000-0000-0000-0000-0000000252c1', 'wallet_topup', 50, 'key-c1-00000001');
  perform pg_temp.check(i.id = j.id, 'the same key made two payments');
  perform pg_temp.check(i.provider = 'stripe' and not i.test_mode and i.currency = 'MYR' and i.status = 'pending',
    'intent: ' || row_to_json(i)::text);
  perform pg_temp.check(i.reference ~ '^GR[0-9]{6}[0-9A-F]{10}$', 'reference ' || i.reference);
  perform pg_temp.refused_with(
    'select public.payment_intent_create(''00000000-0000-0000-0000-0000000252c1'', ''wallet_topup'', 60, ''key-c1-00000001'')',
    'idempotency_key_reused', 'a key reused for another amount');
  perform pg_temp.refused_with(
    'select public.payment_intent_create(''00000000-0000-0000-0000-0000000252c1'', ''wallet_topup'', 1, null)',
    'invalid_amount', 'below the minimum');
  perform pg_temp.refused_with(
    'select public.payment_intent_create(''00000000-0000-0000-0000-0000000252c1'', ''wallet_topup'', 10.005, null)',
    'invalid_amount', 'a third decimal');

  -- Paid: the wallet is credited once, however often it is confirmed.
  select coalesce((select balance from public.wallets
                    where user_id = '00000000-0000-0000-0000-0000000252c1' and wallet_type = 'get_wallet'), 0) into bal;
  j := public.payment_intent_settle(i.reference, 'stripe', 'paid', 'cs_1', 50, 'myr', '{"via":"test"}');
  perform pg_temp.check(j.status = 'paid' and j.applied = 'wallet_credited' and j.provider_ref = 'cs_1',
    'settled: ' || row_to_json(j)::text);
  j := public.payment_intent_settle(i.reference, 'stripe', 'paid', 'cs_1', 50, 'MYR', null);
  j := public.payment_intent_settle(i.reference, 'stripe', 'failed', null, null, null, null);
  perform pg_temp.check(j.status = 'paid', 'a later failure undid a payment');
  select count(*) into n from public.wallet_transactions where payment_intent_id = i.id;
  perform pg_temp.check(n = 1, n || ' ledger lines for one payment');
  perform pg_temp.check((select balance from public.wallets
                          where user_id = '00000000-0000-0000-0000-0000000252c1' and wallet_type = 'get_wallet') = bal + 50,
    'balance not credited by 50');
  perform pg_temp.check((select kind from public.wallet_transactions where payment_intent_id = i.id) = 'topup', 'ledger kind');
  begin
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, payment_intent_id)
    values ('00000000-0000-0000-0000-0000000252c1', 'get_wallet', 'topup', 50, i.id);
    raise exception 'FAILED: a second ledger line for one payment';
  exception when unique_violation then null;
  end;

  -- Another provider's word, or another amount, does not count.
  i := public.payment_intent_create('00000000-0000-0000-0000-0000000252c1', 'wallet_topup', 30, null);
  perform pg_temp.refused_with(format('select public.payment_intent_settle(%L, ''billplz'', ''paid'')', i.reference),
    'unknown_payment', 'another provider settles');
  j := public.payment_intent_settle(i.reference, 'stripe', 'paid', 'cs_2', 3, 'MYR', null);
  perform pg_temp.check(j.status = 'pending' and j.failure = 'amount_mismatch', 'a wrong amount was accepted');
  j := public.payment_intent_settle(i.reference, 'stripe', 'paid', 'cs_2', 30, 'USD', null);
  perform pg_temp.check(j.status = 'pending', 'a wrong currency was accepted');
  perform pg_temp.check(not exists (select 1 from public.wallet_transactions where payment_intent_id = i.id),
    'a wrong amount credited the wallet');
  j := public.payment_intent_settle(i.reference, 'stripe', 'cancelled', null, null, null, null);
  perform pg_temp.check(j.status = 'cancelled', 'cancel');
  -- A payment that went through after all still counts.
  j := public.payment_intent_settle(i.reference, 'stripe', 'paid', 'cs_2', 30, 'MYR', null);
  perform pg_temp.check(j.status = 'paid' and j.applied = 'wallet_credited', 'paid after a cancel');

  -- A sandbox account's payment is not money.
  update public.payment_gateway_routing set gateway_id = '00000000-0000-0000-0000-0000002520f2' where purpose = 'wallet_topup';
  i := public.payment_intent_create('00000000-0000-0000-0000-0000000252c2', 'wallet_topup', 20, null);
  perform pg_temp.check(i.provider = 'billplz' and i.test_mode, 'sandbox intent: ' || row_to_json(i)::text);
  j := public.payment_intent_settle(i.reference, 'billplz', 'paid', 'b1', 20, 'MYR', null);
  perform pg_temp.check(j.status = 'paid' and j.applied = 'test_mode', 'sandbox: ' || row_to_json(j)::text);
  perform pg_temp.check(not exists (select 1 from public.wallet_transactions where payment_intent_id = i.id),
    'a sandbox payment credited the wallet');

  -- Dispatch in sandbox: nothing is paid out (supabase/tests/dispatch_pay_link_0252.sql has the orders).
  i := public.payment_intent_create('00000000-0000-0000-0000-0000000252c2', 'dispatch', 120, null, 'order-1');
  j := public.payment_intent_settle(i.reference, 'billplz', 'paid', 'b2', 120, 'MYR', null);
  perform pg_temp.check(j.applied = 'test_mode' and j.purpose_ref = 'order-1', 'dispatch hook in sandbox');
  -- An admin's test payment.
  i := public.payment_intent_create('00000000-0000-0000-0000-0000000252a1', 'test', 1, null, null,
                                    '00000000-0000-0000-0000-0000002520f1');
  perform pg_temp.check(i.provider = 'stripe' and i.amount = 1, 'test intent');
  j := public.payment_intent_settle(i.reference, 'stripe', 'paid', 'cs_t', 1, 'MYR', null);
  perform pg_temp.check(j.applied = 'test', 'a test payment did something');
end $$;
reset role;

-- ---- The owner reads their own intents ----------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000252c1');
do $$ begin
  perform pg_temp.check((select count(*) from public.payment_intents) = 2, 'the payer does not see their 2 payments');
  perform pg_temp.refused('insert into public.payment_intents (user_id, purpose, provider, amount) values
    (''00000000-0000-0000-0000-0000000252c1'', ''wallet_topup'', ''stripe'', 5)', 'a payer makes an intent');
  perform pg_temp.refused('update public.payment_intents set status = ''paid''', 'a payer settles an intent');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000252c2');
do $$ begin
  perform pg_temp.check((select count(*) from public.payment_intents
                          where user_id = '00000000-0000-0000-0000-0000000252c1') = 0, 'a payer sees another''s payments');
end $$;
reset role;

-- ---- Deleting an account deletes its secrets, in Vault too ---------------------------------------------
do $$
declare
  v_ids uuid[];
begin
  select array_agg(vault_id) into v_ids from public.payment_gateway_secrets
   where gateway_id = '00000000-0000-0000-0000-0000002520f3';
  delete from public.settings_entries where id = '00000000-0000-0000-0000-0000002520f3';
  perform pg_temp.check(not exists (select 1 from public.payment_gateway_secrets
                                     where gateway_id = '00000000-0000-0000-0000-0000002520f3'), 'secrets outlive the account');
  perform pg_temp.check(not exists (select 1 from vault.secrets where id = any (v_ids)), 'Vault keeps a deleted account''s secrets');
end $$;

-- ---- Foreign keys of 0252 have an index ----------------------------------------------------------------
do $$
declare
  bad text;
begin
  select string_agg(format('%s.%s', c.conrelid::regclass, a.attname), ', ') into bad
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.contype = 'f'
     and (c.conrelid::regclass::text in ('payment_gateway_secrets', 'payment_gateway_routing', 'payment_intents')
          or (c.conrelid::regclass::text = 'wallet_transactions' and a.attname = 'payment_intent_id'))
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  perform pg_temp.check(bad is null, 'foreign keys without an index: ' || coalesce(bad, ''));
end $$;

select 'payment_gateways_0252: all passed';
rollback;
