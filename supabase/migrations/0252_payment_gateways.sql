-- ============================================================================
-- 0252 — Payment gateways: write-only secrets, which account takes which
-- payment, and payment intents
--
-- Admin → Settings → Payment Gateways kept each gateway account (Stripe,
-- Fiuu, Billplz, …) as a settings_entries row (category 'payment-gateway')
-- that every app user can read, so only public configuration (merchant IDs,
-- publishable keys, mode) belonged there and nothing charged a payment. Now:
--
-- 1. Secret credentials (secret keys, passwords, webhook secrets) are kept in
--    Supabase Vault, one Vault secret per account and field.
--    public.payment_gateway_secrets says which are set (last 4 characters
--    of a long one, length, when, by whom) and is readable by nobody but the
--    service role; admins see that through payment_gateway_secret_status().
--    An admin with EDIT on the Payment Gateways page
--    (caller_admin_can_write('payment_gateway_secrets'), mapped in
--    admin_table_pages) sets, replaces or clears one with
--    payment_gateway_secret_set() and can never read it back. Only the
--    service role (the `payments` edge function) reads them, through
--    payment_gateway_account().
--    A secret written into the public record (an old app, Expo) is moved into
--    Vault and taken out of the record as it is saved, and the ones already
--    there are moved now.
-- 2. public.payment_gateway_routing: which account takes each kind of
--    payment ('wallet_topup', 'ride_card', 'dispatch'). Unset, the default
--    account (isDefault) does, else the only active one.
--    payment_gateway_for() answers; payment_purpose_info() tells the app
--    whether a purpose can be paid (no credentials, no secrets).
-- 3. public.payment_intents: one row per checkout, created and settled by the
--    `payments` edge function with the service role (payment_intent_create,
--    payment_intent_set_checkout, payment_intent_settle). The owner reads
--    their own rows (the app waits on the status); admins read all.
--    Settling is idempotent: a payment confirmed twice (the webhook and the
--    browser's return, or a provider's retry) is applied once. On paid:
--      * wallet_topup credits GET.wallet through the wallet ledger
--        (wallet_transactions, kind 'topup'); wallet_transactions.
--        payment_intent_id is unique, so it can never be credited twice.
--        An account in Sandbox (test) mode never credits real money: the
--        intent is marked paid with applied = 'test_mode'.
--      * dispatch calls public.payment_dispatch_paid(intent id, purpose_ref =
--        the stand order's id): the order is paid and settled (section 4).
--        A sandbox payment is logged on the order and pays nothing out.
--      * ride_card calls public.payment_ride_card_paid(intent id, ride id):
--        a no-op until rides are charged by card.
--      * test (Admin → Test connection) does nothing.
-- ============================================================================

-- ---- 1. Secrets ------------------------------------------------------------------------------------

-- The secret fields of each provider, as the admin form and the edge
-- function's adapters list them (lib/src/admin/screens/commerce/commerce_logic.dart,
-- supabase/functions/_shared/payments/). A deno test keeps the three equal.
create or replace function public.payment_gateway_secret_fields(p_provider text)
returns text[]
language sql
immutable
set search_path = public
as $$
  select case p_provider
    when 'stripe'    then array['secretKey', 'webhookSecret']
    when 'fiuu'      then array['verifyKey', 'secretKey']
    when 'adaptis'   then array['merchantKey', 'eghlPassword']
    when 'ipay88'    then array['merchantKey']
    when 'eghl'      then array['password']
    when 'senangpay' then array['secretKey']
    when 'billplz'   then array['apiKey', 'xSignatureKey']
    when 'hitpay'    then array['apiKey', 'salt']
    when 'paypal'    then array['clientSecret']
    when 'airwallex' then array['apiKey', 'webhookSecret']
    when 'payhalal'  then array['secretKey']
    when 'toyyibpay' then array['userSecretKey']
    when 'paydibs'   then array['merchantPassword']
    when 'curlec'    then array['keySecret', 'webhookSecret']
    when '2c2p'      then array['secretKey']
    when 'adyen'     then array['apiKey', 'hmacKey']
    when 'xendit'    then array['secretKey', 'callbackToken']
    else array[]::text[]
  end;
$$;

create table if not exists public.payment_gateway_secrets (
  -- Deferred: a secret saved with a new account (the trigger below) is
  -- written before the account's own row.
  gateway_id uuid        not null references public.settings_entries(id) on delete cascade
                         deferrable initially deferred,
  field      text        not null check (field ~ '^[A-Za-z][A-Za-z0-9]{0,63}$'),
  vault_id   uuid        not null,
  last4      text,
  length     integer     not null,
  updated_at timestamptz not null default now(),
  updated_by uuid        references auth.users(id) on delete set null,
  primary key (gateway_id, field)
);
create index if not exists payment_gateway_secrets_updated_by_idx on public.payment_gateway_secrets (updated_by);
comment on table public.payment_gateway_secrets is
  'Which payment gateway secrets are set (0252). The values are in Vault (vault_id); nobody but the service role reads this table. Admins see it through payment_gateway_secret_status().';

alter table public.payment_gateway_secrets enable row level security;
revoke all on public.payment_gateway_secrets from public, anon, authenticated;
-- No policy: anon and authenticated have no grant and no row.

-- A cleared secret, or one whose account was deleted, leaves Vault too.
create or replace function public.payment_gateway_secrets_drop_vault()
returns trigger
language plpgsql
security definer
set search_path = public, vault
as $$
begin
  delete from vault.secrets where id = old.vault_id;
  return old;
end;
$$;
revoke execute on function public.payment_gateway_secrets_drop_vault() from public, anon, authenticated;
drop trigger if exists trg_payment_gateway_secrets_drop_vault on public.payment_gateway_secrets;
create trigger trg_payment_gateway_secrets_drop_vault after delete on public.payment_gateway_secrets
  for each row execute function public.payment_gateway_secrets_drop_vault();

-- Stores (or, with an empty value, clears) one secret. No caller check: only
-- the functions below call it.
create or replace function public.payment_gateway_secret_store(p_gateway uuid, p_field text, p_value text)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_value text := nullif(btrim(coalesce(p_value, '')), '');
  v_row public.payment_gateway_secrets;
  v_name text := 'payment_gateway:' || p_gateway || ':' || p_field;
  v_id uuid;
begin
  if v_value is null then
    delete from public.payment_gateway_secrets where gateway_id = p_gateway and field = p_field;
    return;
  end if;
  if length(v_value) > 8000 then
    raise exception 'secret_too_long' using errcode = '22023';
  end if;
  select * into v_row from public.payment_gateway_secrets
   where gateway_id = p_gateway and field = p_field for update;
  if found then
    perform vault.update_secret(v_row.vault_id, v_value);
    v_id := v_row.vault_id;
  else
    delete from vault.secrets where name = v_name;  -- left over from an interrupted write
    v_id := vault.create_secret(v_value, v_name, 'Payment gateway secret (0252)');
  end if;
  insert into public.payment_gateway_secrets (gateway_id, field, vault_id, last4, length, updated_at, updated_by)
  values (p_gateway, p_field, v_id,
          -- The last 4 of a long secret only: of a short password they'd give too much away.
          case when length(v_value) >= 12 then right(v_value, 4) end,
          length(v_value), now(), auth.uid())
  on conflict (gateway_id, field) do update
     set vault_id = excluded.vault_id, last4 = excluded.last4, length = excluded.length,
         updated_at = excluded.updated_at, updated_by = excluded.updated_by;
end;
$$;
revoke execute on function public.payment_gateway_secret_store(uuid, text, text) from public, anon, authenticated;

-- Admin: set, replace or (empty / null value) clear one secret. Never returns it.
create or replace function public.payment_gateway_secret_set(p_gateway uuid, p_field text, p_value text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider text;
  v_row public.payment_gateway_secrets;
begin
  if not public.caller_admin_can_write('payment_gateway_secrets') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select values ->> 'providerId' into v_provider
    from public.settings_entries where id = p_gateway and category = 'payment-gateway';
  if not found then
    raise exception 'unknown_gateway' using errcode = '22023';
  end if;
  if p_field is null or not (p_field = any (public.payment_gateway_secret_fields(v_provider))) then
    raise exception 'unknown_secret_field' using errcode = '22023';
  end if;
  perform public.payment_gateway_secret_store(p_gateway, p_field, p_value);
  select * into v_row from public.payment_gateway_secrets where gateway_id = p_gateway and field = p_field;
  return jsonb_build_object('field', p_field, 'set', v_row.gateway_id is not null, 'last4', v_row.last4,
                            'length', v_row.length, 'updated_at', v_row.updated_at);
end;
$$;
revoke execute on function public.payment_gateway_secret_set(uuid, text, text) from public, anon;
grant execute on function public.payment_gateway_secret_set(uuid, text, text) to authenticated, service_role;

-- Admin: which secrets are set, for the masked form. Never the values.
create or replace function public.payment_gateway_secret_status()
returns table (gateway_id uuid, field text, last4 text, length integer, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select s.gateway_id, s.field, s.last4, s.length, s.updated_at
      from public.payment_gateway_secrets s
     order by s.gateway_id, s.field;
end;
$$;
revoke execute on function public.payment_gateway_secret_status() from public, anon;
grant execute on function public.payment_gateway_secret_status() to authenticated, service_role;

-- Service role only: one account with its secrets, for the edge function.
create or replace function public.payment_gateway_account(p_gateway uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, vault
as $$
  select jsonb_build_object(
           'id', e.id,
           'active', e.active and coalesce(e.values ->> 'active', 'true') <> 'false',
           'values', e.values,
           'secrets', coalesce((select jsonb_object_agg(s.field, d.decrypted_secret)
                                  from public.payment_gateway_secrets s
                                  join vault.decrypted_secrets d on d.id = s.vault_id
                                 where s.gateway_id = e.id), '{}'::jsonb))
    from public.settings_entries e
   where e.id = p_gateway and e.category = 'payment-gateway';
$$;
revoke execute on function public.payment_gateway_account(uuid) from public, anon, authenticated;
grant execute on function public.payment_gateway_account(uuid) to service_role;

-- A secret saved into the public record (an older app) moves to Vault before
-- the row is written, so it is never stored, or sent to the app, there.
create or replace function public.settings_entries_gateway_secrets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider text := new.values ->> 'providerId';
  v_field text;
  v_key text;
  v_found text[] := array[]::text[];
begin
  if new.category <> 'payment-gateway' or v_provider is null then
    return new;
  end if;
  foreach v_field in array public.payment_gateway_secret_fields(v_provider) loop
    v_key := v_provider || '_' || v_field;
    if new.values ? v_key then
      if coalesce(new.values ->> v_key, '') <> '' then
        perform public.payment_gateway_secret_store(new.id, v_field, new.values ->> v_key);
      end if;
      v_found := v_found || v_key;
    end if;
  end loop;
  if cardinality(v_found) > 0 then
    new.values := new.values - v_found;
  end if;
  return new;
end;
$$;
revoke execute on function public.settings_entries_gateway_secrets() from public, anon, authenticated;
drop trigger if exists trg_settings_entries_gateway_secrets on public.settings_entries;
create trigger trg_settings_entries_gateway_secrets before insert or update of values on public.settings_entries
  for each row when (new.category = 'payment-gateway')
  execute function public.settings_entries_gateway_secrets();

-- The secrets already in public records move now (the trigger does it).
update public.settings_entries e
   set values = e.values
 where e.category = 'payment-gateway'
   and exists (select 1 from unnest(public.payment_gateway_secret_fields(e.values ->> 'providerId')) f
                where e.values ? ((e.values ->> 'providerId') || '_' || f));

-- ---- 2. Which account takes which payment -----------------------------------------------------------
create table if not exists public.payment_gateway_routing (
  purpose    text primary key check (purpose in ('wallet_topup', 'ride_card', 'dispatch')),
  gateway_id uuid references public.settings_entries(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists payment_gateway_routing_gateway_idx on public.payment_gateway_routing (gateway_id);
insert into public.payment_gateway_routing (purpose) values ('wallet_topup'), ('ride_card'), ('dispatch')
on conflict do nothing;
comment on table public.payment_gateway_routing is
  'Which payment gateway account (settings_entries payment-gateway) takes each kind of payment; null = the default account (0252).';

drop trigger if exists trg_payment_gateway_routing_updated_at on public.payment_gateway_routing;
create trigger trg_payment_gateway_routing_updated_at before update on public.payment_gateway_routing
  for each row execute function public.set_updated_at();

alter table public.payment_gateway_routing enable row level security;
revoke all on public.payment_gateway_routing from public, anon;
revoke insert, delete, truncate on public.payment_gateway_routing from authenticated;
grant select, update on public.payment_gateway_routing to authenticated;
drop policy if exists "payment_gateway_routing admin read" on public.payment_gateway_routing;
create policy "payment_gateway_routing admin read" on public.payment_gateway_routing
  for select to authenticated using ((select public.caller_is_admin()));
drop policy if exists "payment_gateway_routing admin update" on public.payment_gateway_routing;
create policy "payment_gateway_routing admin update" on public.payment_gateway_routing for update to authenticated
  using ((select public.caller_admin_can_write('payment_gateway_routing')))
  with check ((select public.caller_admin_can_write('payment_gateway_routing')));

insert into public.admin_table_pages (target, page) values
  ('payment_gateway_secrets', 'admin-settings-payment-gateway'),
  ('payment_gateway_routing', 'admin-settings-payment-gateway')
on conflict do nothing;

-- The account that takes [p_purpose]: the one chosen for it while active,
-- else the active default, else the only active account; null for none.
create or replace function public.payment_gateway_for(p_purpose text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with active as (
    select e.id, coalesce(e.values ->> 'isDefault', '') = 'true' as is_default
      from public.settings_entries e
     where e.category = 'payment-gateway' and e.active
       and coalesce(e.values ->> 'active', 'true') <> 'false'
  )
  select coalesce(
    (select a.id from public.payment_gateway_routing r join active a on a.id = r.gateway_id where r.purpose = p_purpose),
    (select a.id from active a where a.is_default order by a.id limit 1),
    (select a.id from active a where (select count(*) from active) = 1));
$$;
revoke execute on function public.payment_gateway_for(text) from public, anon, authenticated;
grant execute on function public.payment_gateway_for(text) to service_role;

-- The limits of one payment (RM).
create or replace function public.payment_limits(p_purpose text)
returns numeric[]
language sql
immutable
as $$
  select case p_purpose
    when 'wallet_topup' then array[5, 2000]::numeric[]
    when 'test'         then array[1, 1]::numeric[]
    else array[1, 100000]::numeric[]
  end;
$$;
revoke execute on function public.payment_limits(text) from public, anon;
grant execute on function public.payment_limits(text) to authenticated, service_role;

-- The app: can [p_purpose] be paid, by which provider, in test mode, within what.
create or replace function public.payment_purpose_info(p_purpose text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_values jsonb;
begin
  if auth.uid() is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  if p_purpose not in ('wallet_topup', 'ride_card', 'dispatch') then
    raise exception 'unknown_purpose' using errcode = '22023';
  end if;
  v_id := public.payment_gateway_for(p_purpose);
  select values into v_values from public.settings_entries where id = v_id;
  return jsonb_build_object(
    'available', v_id is not null,
    'provider', v_values ->> 'providerId',
    'provider_name', v_values ->> 'providerName',
    'test_mode', coalesce(v_values ->> 'mode', 'Live') = 'Sandbox',
    'currency', 'MYR',
    'min', (public.payment_limits(p_purpose))[1],
    'max', (public.payment_limits(p_purpose))[2]);
end;
$$;
revoke execute on function public.payment_purpose_info(text) from public, anon;
grant execute on function public.payment_purpose_info(text) to authenticated, service_role;

-- ---- 3. Payment intents ----------------------------------------------------------------------------
-- 18 characters, letters and digits: what every provider takes as an order number.
create or replace function public.payment_new_reference()
returns text
language sql
volatile
set search_path = public, extensions
as $$
  select 'GR' || to_char(now() at time zone 'utc', 'YYMMDD')
         || upper(encode(extensions.gen_random_bytes(5), 'hex'));
$$;
revoke execute on function public.payment_new_reference() from public, anon, authenticated;

create table if not exists public.payment_intents (
  id              uuid primary key default gen_random_uuid(),
  reference       text not null unique default public.payment_new_reference(),
  user_id         uuid references auth.users(id) on delete set null,
  purpose         text not null check (purpose in ('wallet_topup', 'ride_card', 'dispatch', 'test')),
  purpose_ref     text,
  gateway_id      uuid references public.settings_entries(id) on delete set null,
  provider        text not null,
  test_mode       boolean not null default false,
  amount          numeric(12,2) not null check (amount > 0),
  currency        text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  status          text not null default 'pending'
                    check (status in ('pending', 'paid', 'failed', 'expired', 'cancelled')),
  provider_ref    text,
  checkout_url    text,
  idempotency_key text check (idempotency_key is null or length(idempotency_key) between 8 and 80),
  callback        jsonb,
  failure         text,
  applied         text,
  paid_at         timestamptz,
  applied_at      timestamptz,
  expires_at      timestamptz not null default now() + interval '1 day',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists payment_intents_user_idx on public.payment_intents (user_id, created_at desc);
create index if not exists payment_intents_gateway_idx on public.payment_intents (gateway_id);
create index if not exists payment_intents_provider_ref_idx on public.payment_intents (provider, provider_ref)
  where provider_ref is not null;
create unique index if not exists payment_intents_idempotency_key
  on public.payment_intents (user_id, idempotency_key) where idempotency_key is not null;
comment on table public.payment_intents is
  'One checkout at a payment gateway (0252). Created and settled by the payments edge function (service role); the owner reads their own.';
comment on column public.payment_intents.callback is
  'The last verified callback, minimally: event, provider status, amount, currency, provider reference. No card or personal data.';

drop trigger if exists trg_payment_intents_updated_at on public.payment_intents;
create trigger trg_payment_intents_updated_at before update on public.payment_intents
  for each row execute function public.set_updated_at();

alter table public.payment_intents enable row level security;
revoke all on public.payment_intents from public, anon;
revoke insert, update, delete, truncate on public.payment_intents from authenticated;
grant select on public.payment_intents to authenticated;
drop policy if exists "payment_intents own read" on public.payment_intents;
create policy "payment_intents own read" on public.payment_intents
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.caller_is_admin()));

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'payment_intents') then
    alter publication supabase_realtime add table public.payment_intents;
  end if;
end $$;

-- A wallet top-up is credited once: the ledger line names its intent.
alter table public.wallet_transactions
  add column if not exists payment_intent_id uuid references public.payment_intents(id) on delete set null;
create unique index if not exists wallet_transactions_payment_intent_key
  on public.wallet_transactions (payment_intent_id) where payment_intent_id is not null;

-- Service role: a new intent, or the one this idempotency key already made.
create or replace function public.payment_intent_create(
  p_user uuid,
  p_purpose text,
  p_amount numeric,
  p_idempotency_key text default null,
  p_purpose_ref text default null,
  p_gateway uuid default null
)
returns public.payment_intents
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.payment_intents;
  v_gateway uuid;
  v_values jsonb;
  v_limits numeric[] := public.payment_limits(p_purpose);
begin
  if p_user is null then
    raise exception 'invalid_user' using errcode = '22023';
  end if;
  if p_purpose not in ('wallet_topup', 'ride_card', 'dispatch', 'test') then
    raise exception 'unknown_purpose' using errcode = '22023';
  end if;
  if p_idempotency_key is not null then
    select * into v from public.payment_intents where user_id = p_user and idempotency_key = p_idempotency_key;
    if found then
      if v.purpose <> p_purpose or v.amount <> p_amount then
        raise exception 'idempotency_key_reused' using errcode = '22023';
      end if;
      return v;
    end if;
  end if;
  if p_amount is null or p_amount <> round(p_amount, 2) or p_amount < v_limits[1] or p_amount > v_limits[2] then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if (select count(*) from public.payment_intents
       where user_id = p_user and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'too_many_payments' using errcode = '22023';
  end if;
  v_gateway := case when p_purpose = 'test' then p_gateway else coalesce(p_gateway, public.payment_gateway_for(p_purpose)) end;
  select e.values into v_values from public.settings_entries e
   where e.id = v_gateway and e.category = 'payment-gateway';
  if v_values is null then
    raise exception 'no_gateway' using errcode = '22023';
  end if;
  insert into public.payment_intents (user_id, purpose, purpose_ref, gateway_id, provider, test_mode, amount,
                                      currency, idempotency_key)
  values (p_user, p_purpose, p_purpose_ref, v_gateway, v_values ->> 'providerId',
          coalesce(v_values ->> 'mode', 'Live') = 'Sandbox', p_amount, 'MYR', p_idempotency_key)
  returning * into v;
  return v;
end;
$$;
revoke execute on function public.payment_intent_create(uuid, text, numeric, text, text, uuid) from public, anon, authenticated;
grant execute on function public.payment_intent_create(uuid, text, numeric, text, text, uuid) to service_role;

-- Service role: the hosted page the gateway gave for an intent.
create or replace function public.payment_intent_set_checkout(p_id uuid, p_provider_ref text, p_url text)
returns public.payment_intents
language sql
security definer
set search_path = public
as $$
  update public.payment_intents
     set provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref),
         checkout_url = coalesce(nullif(p_url, ''), checkout_url)
   where id = p_id
  returning *;
$$;
revoke execute on function public.payment_intent_set_checkout(uuid, text, text) from public, anon, authenticated;
grant execute on function public.payment_intent_set_checkout(uuid, text, text) to service_role;

-- The hook a later migration wires (see the header). Called once per paid intent.
create or replace function public.payment_ride_card_paid(p_intent uuid, p_ride text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Replaced when rides are charged by card: mark ride p_ride paid.
  return;
end;
$$;
revoke execute on function public.payment_ride_card_paid(uuid, text) from public, anon, authenticated;

-- What a paid intent does, once.
create or replace function public.payment_intent_apply(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.payment_intents;
  v_applied text;
begin
  select * into v from public.payment_intents where id = p_id for update;
  if not found or v.status <> 'paid' or v.applied_at is not null then
    return;
  end if;
  if v.purpose = 'wallet_topup' then
    if v.test_mode then
      v_applied := 'test_mode';  -- a sandbox payment is not money
    elsif v.user_id is null then
      v_applied := 'no_user';
    else
      begin
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, payment_intent_id)
        values (v.user_id, 'get_wallet', 'topup', v.amount, 'gateway:' || v.provider, 'Top up GET.wallet', v.id)
        on conflict (payment_intent_id) where payment_intent_id is not null do nothing;
        v_applied := 'wallet_credited';
      exception when others then
        -- A deleted account's balance doesn't move (0194): the payment is
        -- kept as paid for an admin to refund, and the provider is still
        -- answered, so it stops retrying.
        if sqlerrm = 'ACCOUNT_DELETED' then
          v_applied := 'account_deleted';
        else
          raise;
        end if;
      end;
    end if;
  elsif v.purpose = 'dispatch' then
    perform public.payment_dispatch_paid(v.id, v.purpose_ref);
    v_applied := case when v.test_mode then 'test_mode' else 'dispatch' end;
  elsif v.purpose = 'ride_card' then
    perform public.payment_ride_card_paid(v.id, v.purpose_ref);
    v_applied := 'ride_card';
  else
    v_applied := 'test';
  end if;
  update public.payment_intents set applied = v_applied, applied_at = now() where id = v.id;
end;
$$;
revoke execute on function public.payment_intent_apply(uuid) from public, anon, authenticated;

-- Service role: what a verified callback (or a status lookup) said about an
-- intent. Paid is final and applied once; a paid amount or currency that
-- isn't the intent's is not accepted (failure = 'amount_mismatch', still
-- pending, for an admin to look at). Failed / expired / cancelled only
-- replace pending.
create or replace function public.payment_intent_settle(
  p_reference text,
  p_provider text,
  p_status text,
  p_provider_ref text default null,
  p_amount numeric default null,
  p_currency text default null,
  p_callback jsonb default null
)
returns public.payment_intents
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.payment_intents;
begin
  if p_status not in ('pending', 'paid', 'failed', 'expired', 'cancelled') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  select * into v from public.payment_intents where reference = p_reference for update;
  if not found or v.provider <> p_provider then
    raise exception 'unknown_payment' using errcode = '22023';
  end if;
  if v.status = 'paid' then
    return v;
  end if;
  if p_status = 'paid' then
    if (p_amount is not null and p_amount <> v.amount)
       or (p_currency is not null and upper(p_currency) <> v.currency) then
      update public.payment_intents
         set failure = 'amount_mismatch', callback = p_callback,
             provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref)
       where id = v.id
      returning * into v;
      return v;
    end if;
    update public.payment_intents
       set status = 'paid', paid_at = now(), failure = null, callback = coalesce(p_callback, callback),
           provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref)
     where id = v.id;
    perform public.payment_intent_apply(v.id);
  elsif p_status = 'pending' or v.status <> 'pending' then
    update public.payment_intents
       set callback = coalesce(p_callback, callback), provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref)
     where id = v.id;
  else
    update public.payment_intents
       set status = p_status, callback = coalesce(p_callback, callback),
           provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref)
     where id = v.id;
  end if;
  select * into v from public.payment_intents where id = v.id;
  return v;
end;
$$;
revoke execute on function public.payment_intent_settle(text, text, text, text, numeric, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.payment_intent_settle(text, text, text, text, numeric, text, jsonb) to service_role;


-- ---- 4. Order Dispatch: card / e-wallet orders paid by a link (0251) -------------------------------
-- A stand order taken as "Card / e-wallet" (dispatch_payment 'app') is paid
-- through the account Admin → Payment Gateways chose for dispatch payment
-- links. When there is one as the order goes out, dispatch_pay_link is set:
--   * the console asks the `payments` function for a link once the fare is
--     known (fixed or app fare: at once; a metered one: when the driver
--     enters the meter fare). payment_dispatch_intent() makes (or reuses)
--     the intent for the customer's total (dispatch_split 'customer');
--     payment_dispatch_link_set() puts the hosted page on the order and
--     texts it to the customer;
--   * the order isn't the stand's to carry: no credit-limit check, nothing
--     on the stand's GET.credit;
--   * paid (payment_dispatch_paid, once per intent) and done, in either
--     order, dispatch_settle pays the driver's share into their GET.wallet
--     and the stand's share of its fee into its GET.wallet (the platform
--     keeps its fee and the customer's money), exactly once (the ledger's
--     one-of-each-kind-per-ride index and dispatch_settled_at).
-- With no dispatch account, a card / e-wallet order is the stand's as
-- before (taken at the counter's terminal: the counter settlement) and the
-- console says "No payment gateway set".
alter table public.ride_requests
  add column if not exists dispatch_pay_link      boolean,
  add column if not exists dispatch_pay_intent_id uuid references public.payment_intents(id) on delete set null,
  add column if not exists dispatch_pay_url       text,
  add column if not exists dispatch_pay_paid_at   timestamptz;
create index if not exists ride_requests_dispatch_pay_intent_idx on public.ride_requests (dispatch_pay_intent_id);

-- A gateway payment is recorded as such.
alter table public.ride_requests drop constraint if exists ride_requests_paid_method_check;
alter table public.ride_requests add constraint ride_requests_paid_method_check
  check (paid_method is null or paid_method in ('get_wallet', 'get_coin', 'cash', 'counter', 'gateway'));

-- Whether a card / e-wallet stand order is paid by a link: decided as the
-- ride is written (now, or when a booking ahead is released).
create or replace function public.ride_requests_dispatch_pay_link()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.dispatch_pay_link := case
    when new.stand_id is not null and new.dispatch_payment = 'app' then public.payment_gateway_for('dispatch') is not null
  end;
  new.dispatch_pay_intent_id := null;
  new.dispatch_pay_url := null;
  new.dispatch_pay_paid_at := null;
  return new;
end;
$$;
revoke execute on function public.ride_requests_dispatch_pay_link() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_dispatch_pay_link on public.ride_requests;
create trigger trg_ride_requests_dispatch_pay_link before insert on public.ride_requests
  for each row execute function public.ride_requests_dispatch_pay_link();

-- Only the server changes them (the app's callers are told apart by the
-- session's role, as in 0247 / 0248).
create or replace function public.ride_requests_guard_dispatch_pay()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
     and (new.dispatch_pay_link, new.dispatch_pay_intent_id, new.dispatch_pay_url, new.dispatch_pay_paid_at)
         is distinct from (old.dispatch_pay_link, old.dispatch_pay_intent_id, old.dispatch_pay_url, old.dispatch_pay_paid_at) then
    raise exception 'DISPATCH_PAY_FIXED' using errcode = '42501', hint = 'The payment link is the server''s.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_dispatch_pay() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_guard_dispatch_pay on public.ride_requests;
create trigger trg_ride_requests_guard_dispatch_pay before update on public.ride_requests
  for each row execute function public.ride_requests_guard_dispatch_pay();

-- The latest 0251 definitions, changed only where marked (0252).
create or replace function public.dispatch_create_order(p_stand uuid, p_order jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s public.dispatch_stands;
  g public.dispatch_groups;
  v_admin boolean := public.caller_admin_can_write('rpc:dispatch_console');
  v_call boolean;
  v_mode text := coalesce(nullif(p_order->>'mode', ''), 'broadcast');
  v_fare_mode text := coalesce(nullif(p_order->>'fare_mode', ''), 'meter');
  v_pay text;
  v_drop text := nullif(btrim(coalesce(p_order->>'drop_name', '')), '');
  v_name text := nullif(btrim(coalesce(p_order->>'customer_name', '')), '');
  v_phone text := nullif(btrim(coalesce(p_order->>'customer_phone', '')), '');
  v_note text := nullif(btrim(coalesce(p_order->>'note', '')), '');
  v_via text := nullif(p_order->>'booked_via', '');
  v_pickup_at timestamptz := nullif(p_order->>'pickup_at', '')::timestamptz;
  v_lead integer := coalesce(nullif(p_order->>'lead_minutes', '')::integer, 30);
  v_rider uuid;
  v_driver uuid;
  v_fare numeric;
  v_n integer;
  v_ticket text;
  v_id uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_fee numeric;
  v_earner uuid;
  v_detail text;
  v_pax integer := coalesce(nullif(p_order->>'passengers', '')::integer, 1);
  v_plat double precision;
  v_plng double precision;
  v_pname text;
  v_paddr text;
  v_row jsonb;
  v_cols text;
  v_offer uuid;
  b public.scheduled_rides;
  j jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into s from public.dispatch_stands where id = p_stand and active;
  if not found or not public.dispatch_caller_can(p_stand, 'use') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- The Call centre (admins only): a customer who phoned or texted.
  v_call := s.admin_only;
  if v_call and not v_admin then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_pay := coalesce(nullif(p_order->>'payment', ''), case when v_call then 'cash' else 'counter' end);

  if v_drop is null or char_length(v_drop) > 200 then
    raise exception 'DISPATCH_DESTINATION' using errcode = '22023', hint = 'Say where the customer is going.';
  end if;
  if v_pax < 1 or v_pax > 20 then
    raise exception 'DISPATCH_PASSENGERS' using errcode = '22023', hint = 'Passengers are 1 to 20.';
  end if;
  if v_name is not null and char_length(v_name) > 80 then
    raise exception 'DISPATCH_CUSTOMER' using errcode = '22023', hint = 'The name is too long.';
  end if;
  if v_phone is not null and char_length(regexp_replace(v_phone, '\D', '', 'g')) not between 6 and 20 then
    raise exception 'DISPATCH_PHONE' using errcode = '22023', hint = 'The phone number doesn''t look right.';
  end if;
  if v_pay not in ('counter', 'cash', 'app') then
    raise exception 'DISPATCH_PAYMENT' using errcode = '22023';
  end if;

  -- Where the customer is picked up: the stand, or (Call centre) their address.
  if v_call then
    if v_name is null or v_phone is null then
      raise exception 'DISPATCH_CUSTOMER' using errcode = '22023', hint = 'A phone booking needs the customer''s name and phone.';
    end if;
    if v_via is null or v_via not in ('phone', 'sms', 'whatsapp') then
      raise exception 'DISPATCH_VIA' using errcode = '22023', hint = 'Say how the customer booked.';
    end if;
    v_plat := nullif(p_order->>'pickup_lat', '')::double precision;
    v_plng := nullif(p_order->>'pickup_lng', '')::double precision;
    v_pname := nullif(btrim(coalesce(p_order->>'pickup_name', '')), '');
    v_paddr := nullif(btrim(coalesce(p_order->>'pickup_address', '')), '');
    if v_plat is null or v_plng is null or v_pname is null then
      raise exception 'DISPATCH_PICKUP' using errcode = '22023', hint = 'Find the pickup address.';
    end if;
    -- A customer with a GET.ride account: booked on their account (their app
    -- tracks it); else a guest.
    v_rider := public.dispatch_profile_by_phone(v_phone);
    if v_rider is not null and v_pickup_at is null and exists (
         select 1 from public.ride_requests x
          where x.rider_id = v_rider
            and ((x.status = 'open' and x.created_at > now() - interval '7 minutes')
                 or (x.status in ('accepted', 'arrived', 'on_trip') and x.updated_at > now() - interval '12 hours'))) then
      raise exception 'RIDE_REQUEST_DUPLICATE' using errcode = 'P0001',
        hint = 'This customer already has a ride on the go.';
    end if;
  else
    v_via := null;
    v_plat := s.lat;
    v_plng := s.lng;
    v_pname := s.name;
    v_paddr := s.address;
  end if;

  -- When: now, or booked ahead (released [lead] minutes before pickup).
  if v_pickup_at is not null then
    if v_lead not in (15, 30, 60) then
      raise exception 'DISPATCH_LEAD' using errcode = '22023', hint = 'Send it 15, 30 or 60 minutes before.';
    end if;
    if v_pickup_at < now() + make_interval(mins => v_lead + 5) or v_pickup_at > now() + interval '30 days' then
      raise exception 'DISPATCH_TIME' using errcode = '22023',
        hint = format('Pick a time at least %s minutes from now, within 30 days.', v_lead + 5);
    end if;
    if v_rider is not null and (select count(*) from public.scheduled_rides
                                 where rider_id = v_rider and status in ('scheduled', 'assigned', 'released')) >= 5 then
      raise exception 'SCHEDULED_LIMIT' using hint = 'This customer already has 5 upcoming rides.';
    end if;
  end if;

  -- The fare.
  if v_fare_mode not in ('meter', 'estimate', 'fixed') then
    raise exception 'DISPATCH_FARE' using errcode = '22023';
  end if;
  if v_fare_mode = 'fixed' and not (v_admin or (s.allow_fixed_fare and public.dispatch_caller_can(p_stand, 'fixed_fare'))) then
    raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501', hint = 'You can''t set a fixed fare here.';
  end if;
  if v_fare_mode in ('fixed', 'estimate') then
    v_fare := round(nullif(p_order->>'fare', '')::numeric, 2);
    if v_fare is null or v_fare <= 0 or not public.ride_money_ok(v_fare) then
      raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Enter the fare.';
    end if;
  end if;

  -- Who it goes to.
  if v_mode = 'assign' then
    if not public.dispatch_caller_can(p_stand, 'assign') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501', hint = 'You can''t assign drivers here.';
    end if;
    v_driver := nullif(p_order->>'driver_id', '')::uuid;
    if v_driver is null or v_driver = v_rider or not exists (
         select 1 from public.partners p where p.auth_user_id = v_driver
            and (p.status = 'approved' or p.status::text like 'permit-%')) then
      raise exception 'DISPATCH_DRIVER' using errcode = '22023', hint = 'Pick a driver.';
    end if;
    -- The service order (0250): only a vehicle of this service or a higher one.
    if not public.service_order_driver_allows(v_driver, nullif(btrim(coalesce(p_order->>'service', '')), '')) then
      raise exception 'SERVICE_ORDER_DIRECT' using errcode = '42501',
        hint = 'This driver''s vehicle can''t take this service. Pick another driver or service.';
    end if;
    v_detail := 'Assigned to ' || public.dispatch_actor_name(v_driver);
  elsif v_mode = 'broadcast' then
    if not public.dispatch_caller_can(p_stand, 'broadcast') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501', hint = 'You can''t broadcast here.';
    end if;
    select * into g from public.dispatch_groups
     where id = nullif(p_order->>'group_id', '')::uuid and active;
    if not found or not (v_admin or exists (select 1 from public.dispatch_stand_groups sg
                                             where sg.stand_id = p_stand and sg.group_id = g.id)) then
      raise exception 'DISPATCH_GROUP' using errcode = '22023', hint = 'Pick a group this stand sends to.';
    end if;
    v_detail := 'Broadcast to ' || g.name;
  elsif v_mode = 'nearby' and v_call then
    v_detail := 'Nearby drivers, as a normal booking';
  else
    raise exception 'DISPATCH_MODE' using errcode = '22023';
  end if;

  -- Paid at the counter: within the stand's credit limit (cash is always fine).
  -- (0252) A card / e-wallet order paid by a gateway link isn't the stand's to carry.
  if (v_pay = 'counter' or (v_pay = 'app' and public.payment_gateway_for('dispatch') is null))
     and s.settlement = 'wallet' then
    perform public.dispatch_credit_check(p_stand, public.dispatch_counter_due(v_fare, s.fee_type, s.fee_value,
      s.fee_bearer, s.platform_fee_type, s.platform_fee_value));
  end if;

  -- The ticket: the stand's next number, under its row lock.
  update public.dispatch_stands set next_ticket = next_ticket + 1 where id = p_stand
  returning next_ticket - 1 into v_n;
  v_ticket := public.dispatch_ticket_text(s.code, v_n);

  v_fee := case when s.fee_type = 'none' then null
                else public.dispatch_fee_amount(s.fee_type, s.fee_value, coalesce(v_fare, 0)) end;
  v_earner := public.dispatch_stand_account(s.id);

  -- The ride as it goes out (now, or when the booking is released).
  v_row := jsonb_build_object(
    'rider_id', v_rider, 'rider_name', coalesce(v_name, 'Customer'), 'rider_phone', v_phone,
    'service', nullif(btrim(coalesce(p_order->>'service', '')), ''),
    'payment_mode', case v_pay when 'counter' then 'Paid at counter' when 'app' then 'Card / e-wallet' else 'Cash' end,
    'pickup_name', v_pname, 'pickup_address', v_paddr, 'pickup_lat', v_plat, 'pickup_lng', v_plng,
    'drop_name', v_drop, 'drop_address', nullif(btrim(coalesce(p_order->>'drop_address', '')), ''),
    'drop_lat', nullif(p_order->>'drop_lat', '')::double precision,
    'drop_lng', nullif(p_order->>'drop_lng', '')::double precision,
    'distance_km', nullif(p_order->>'distance_km', '')::numeric,
    'duration_min', nullif(p_order->>'duration_min', '')::numeric::integer,
    'fare', v_fare, 'ride_fare', v_fare, 'passengers', v_pax, 'note', left(v_note, 300), 'share_token', v_token)
  || jsonb_build_object(
    'stand_id', s.id, 'ticket_no', v_ticket, 'dispatch_stand_name', s.name, 'dispatch_created_by', v_uid,
    'dispatch_mode', v_mode, 'dispatch_group_id', g.id, 'dispatch_group_name', g.name, 'dispatch_group_kind', g.kind,
    'dispatch_driver_id', v_driver, 'fare_mode', v_fare_mode, 'dispatch_payment', v_pay,
    'stand_settlement', s.settlement, 'stand_fee_type', s.fee_type, 'stand_fee_value', s.fee_value,
    'stand_fee_bearer', s.fee_bearer, 'stand_fee_earner_id', v_earner, 'stand_fee_amount', v_fee,
    'stand_platform_fee_type', s.platform_fee_type, 'stand_platform_fee_value', s.platform_fee_value,
    'dispatch_booked_via', v_via);
  -- Booked ahead: the trip code is fixed now, for the ticket.
  if v_pickup_at is not null then
    v_row := v_row || jsonb_build_object('otp', public.new_trip_code());
  end if;

  perform set_config('dispatch.rpc', '1', true);

  if v_pickup_at is not null then
    insert into public.scheduled_rides (
      rider_id, pickup_at, request, service, pickup_address, drop_address,
      pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km, fare, scheduling_fee, currency, stand_id, lead_minutes)
    values (
      v_rider, v_pickup_at, jsonb_strip_nulls(v_row), v_row->>'service', coalesce(v_paddr, v_pname),
      coalesce(v_row->>'drop_address', v_drop), v_plat, v_plng,
      (v_row->>'drop_lat')::double precision, (v_row->>'drop_lng')::double precision,
      (v_row->>'distance_km')::numeric, coalesce(v_fare, 0), 0, 'MYR', s.id, v_lead)
    returning * into b;
    perform public.dispatch_log_scheduled(b.id, s.id, 'created',
      v_ticket || ' · for ' || public.dispatch_when(v_pickup_at) || ' · ' || v_detail
      || coalesce(' · booked by ' || v_via, ''));
    -- An assigned driver is asked now, as a passenger's choice of driver is (0198).
    if v_driver is not null then
      insert into public.scheduled_ride_offers (scheduled_ride_id, kind, rider_id, from_id, to_partner_id, expires_at)
      values (b.id, 'assign', v_rider, v_uid, v_driver, public.scheduled_offer_deadline(v_pickup_at))
      returning id into v_offer;
      perform public.enqueue_notification(v_driver, 'sched-offer-' || v_offer, 'scheduled_ride', 'normal',
        'Stand booking for you',
        coalesce(s.name, 'A stand') || ' asks you to take a ride on ' || public.scheduled_when(v_pickup_at)
        || ' from ' || coalesce(v_pname, 'the stand') || '. Accept or decline it.',
        jsonb_build_object('type', 'scheduled_offer', 'scheduled_ride_id', b.id, 'offer_id', v_offer, 'role', 'partner'));
    end if;
    j := public.dispatch_scheduled_json(b.id);
  else
    v_row := v_row || jsonb_build_object(
      'id', v_id, 'status', 'open', 'dispatch_offered_at', now(),
      'dispatch_offer_until', case when v_mode = 'assign' then now() + interval '30 seconds' end,
      'dispatch_open_after', case when v_mode = 'broadcast' and g.kind = 'open'
                                  then now() + make_interval(secs => g.members_first_sec) end);
    select string_agg(quote_ident(a.attname), ', ') into v_cols
      from pg_attribute a
     where a.attrelid = 'public.ride_requests'::regclass and a.attnum > 0 and not a.attisdropped
       and v_row ? a.attname;
    execute format('insert into public.ride_requests (%1$s) select %1$s from jsonb_populate_record(null::public.ride_requests, $1)',
                   v_cols) using v_row;
    perform public.dispatch_log(v_id, s.id, 'created', v_ticket || ' · ' || v_detail || coalesce(' · booked by ' || v_via, ''));
    perform public.dispatch_push(v_id);
    j := public.dispatch_order_json(v_id);
  end if;

  -- A guest (no GET.ride account) is texted the ticket; an account holder
  -- has it in their app.
  if v_phone is not null and v_rider is null then
    perform public.dispatch_sms(v_phone,
      'GET.ride ' || s.name || ': ticket ' || v_ticket || ' to ' || v_drop
      || coalesce(', pickup ' || public.dispatch_when(v_pickup_at), '')
      || coalesce('. Trip code ' || (j->>'trip_code'), '')
      || '. Track: https://getride.my/share/' || v_token);
  end if;
  return j;
end;
$$;

create or replace function public.dispatch_order_action(p_request uuid, p_action text, p_args jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  g public.dispatch_groups;
  v_driver uuid;
  v_fare numeric;
  v_reason text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.stand_id is null or not public.dispatch_caller_can(r.stand_id, 'use') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform set_config('dispatch.rpc', '1', true);

  -- Sending a counter-paid order out again: within the stand's credit limit.
  if p_action in ('widen', 'resend_group', 'resend_driver', 'reassign')
     and (r.dispatch_payment = 'counter' or (r.dispatch_payment = 'app' and not coalesce(r.dispatch_pay_link, false)))
     and r.stand_settlement = 'wallet' then
    perform public.dispatch_credit_check(r.stand_id,
      public.dispatch_counter_due(coalesce(r.ride_fare, r.fare), r.stand_fee_type, r.stand_fee_value,
                                  r.stand_fee_bearer, r.stand_platform_fee_type, r.stand_platform_fee_value), r.id);
  end if;

  if p_action = 'widen' then
    if not public.dispatch_caller_can(r.stand_id, 'broadcast') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
    end if;
    if r.status <> 'open' then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Only a waiting order is re-sent.';
    end if;
    update public.ride_requests
       set dispatch_mode = 'broadcast', dispatch_widened_at = now(), dispatch_offered_at = now(),
           dispatch_returned_at = null, dispatch_offer_until = null, dispatch_driver_id = null,
           dispatch_widen_pushed_at = now()
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'widened', 'Re-sent to any nearby driver');
    perform public.dispatch_push(r.id);

  elsif p_action in ('resend_group', 'resend_driver', 'reassign') then
    if p_action = 'reassign' then
      if not public.dispatch_caller_can(r.stand_id, 'reassign') then
        raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
      end if;
      if r.status not in ('open', 'accepted', 'arrived') then
        raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023',
          hint = 'Only an order not yet picked up is reassigned.';
      end if;
    elsif r.status <> 'open' then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Only a waiting order is re-sent.';
    end if;
    v_driver := nullif(p_args->>'driver_id', '')::uuid;
    if v_driver is not null then
      if not public.dispatch_caller_can(r.stand_id, 'assign') then
        raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
      end if;
      if not exists (select 1 from public.partners p where p.auth_user_id = v_driver
                        and (p.status = 'approved' or p.status::text like 'permit-%')) then
        raise exception 'DISPATCH_DRIVER' using errcode = '22023', hint = 'Pick a driver.';
      end if;
      if not public.service_order_driver_allows(v_driver, r.service) then
        raise exception 'SERVICE_ORDER_DIRECT' using errcode = '42501',
          hint = 'This driver''s vehicle can''t take this service. Pick another driver.';
      end if;
    else
      if not public.dispatch_caller_can(r.stand_id, 'broadcast') then
        raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
      end if;
      select * into g from public.dispatch_groups
       where id = coalesce(nullif(p_args->>'group_id', '')::uuid, r.dispatch_group_id) and active;
      if not found or not (public.caller_admin_can_write('rpc:dispatch_console')
                           or exists (select 1 from public.dispatch_stand_groups sg
                                       where sg.stand_id = r.stand_id and sg.group_id = g.id)) then
        raise exception 'DISPATCH_GROUP' using errcode = '22023', hint = 'Pick a group this stand sends to.';
      end if;
    end if;
    update public.ride_requests
       set status = 'open', partner_id = null, partner_name = null, partner_phone = null,
           partner_photo = null, partner_vehicle = null, partner_plate = null, partner_rating = null,
           partner_trips = null, accepted_at = null, arrived_at = null, offered_fare = null,
           commission_locked_at = null,
           dispatch_mode = case when v_driver is not null then 'assign' else 'broadcast' end,
           dispatch_driver_id = v_driver,
           dispatch_group_id = case when v_driver is null then g.id end,
           dispatch_group_name = case when v_driver is null then g.name end,
           dispatch_group_kind = case when v_driver is null then g.kind end,
           dispatch_offered_at = now(),
           dispatch_offer_until = case when v_driver is not null then now() + interval '30 seconds' end,
           dispatch_open_after = case when v_driver is null and g.kind = 'open'
                                      then now() + make_interval(secs => g.members_first_sec) end,
           dispatch_widened_at = null, dispatch_widen_pushed_at = null, dispatch_returned_at = null
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, case when p_action = 'reassign' then 'reassigned' else 'resent' end,
      case when v_driver is not null then 'To ' || public.dispatch_actor_name(v_driver) else 'To ' || g.name end
      || case when r.partner_id is not null and r.status <> 'open'
              then ' (was ' || coalesce(r.partner_name, 'a driver') || ')' else '' end);
    perform public.dispatch_push(r.id);

  elsif p_action = 'picked_up' then
    if r.status not in ('accepted', 'arrived') then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'The driver hasn''t taken it yet.';
    end if;
    update public.ride_requests set status = 'on_trip', start_method = 'none', started_at = now() where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'picked_up', 'Customer picked up');

  elsif p_action = 'complete' then
    if r.status <> 'on_trip' then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023', hint = 'Only a trip under way is completed.';
    end if;
    v_fare := round(nullif(p_args->>'fare', '')::numeric, 2);
    if r.fare_mode = 'meter' and coalesce(r.ride_fare, r.fare) is null and v_fare is null then
      raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Enter the meter fare.';
    end if;
    if v_fare is not null and (v_fare <= 0 or not public.ride_money_ok(v_fare) or r.fare_mode <> 'meter') then
      raise exception 'DISPATCH_FARE' using errcode = '22023', hint = 'Only a metered trip takes a fare here.';
    end if;
    update public.ride_requests
       set status = 'completed', completed_at = now(),
           fare = coalesce(v_fare, fare), ride_fare = coalesce(v_fare, ride_fare, fare)
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'completed',
      case when v_fare is not null then 'Meter fare ' || to_char(v_fare, 'FM999999990.00') else 'Trip done' end);

  elsif p_action = 'cancel' then
    if not public.dispatch_caller_can(r.stand_id, 'cancel') then
      raise exception 'DISPATCH_NO_PERMISSION' using errcode = '42501';
    end if;
    if r.status not in ('open', 'accepted', 'arrived') then
      raise exception 'DISPATCH_WRONG_STATUS' using errcode = '22023',
        hint = 'Only an order not yet picked up is cancelled here.';
    end if;
    v_reason := coalesce(nullif(btrim(coalesce(p_args->>'reason', '')), ''), 'Cancelled by the stand');
    update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_reason = left(v_reason, 200)
     where id = r.id;
    perform public.dispatch_log(r.id, r.stand_id, 'cancelled', v_reason);

  else
    raise exception 'DISPATCH_ACTION' using errcode = '22023';
  end if;

  return public.dispatch_order_json(r.id);
end;
$$;

create or replace function public.dispatch_credit_state(p_stand uuid, p_except uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with s as (select * from public.dispatch_stands where id = p_stand),
       b as (select coalesce((select w.balance from public.wallets w
                               where w.user_id = public.dispatch_stand_account(p_stand)
                                 and w.wallet_type = 'get_credit'), 0)::numeric as balance),
       p as (select coalesce(sum(public.dispatch_counter_due(coalesce(r.ride_fare, r.fare), r.stand_fee_type,
                                   r.stand_fee_value, r.stand_fee_bearer, r.stand_platform_fee_type,
                                   r.stand_platform_fee_value)), 0)::numeric as pending
               from public.ride_requests r
              where r.stand_id = p_stand
                and (r.dispatch_payment = 'counter' or (r.dispatch_payment = 'app' and not coalesce(r.dispatch_pay_link, false)))
                and r.dispatch_settled_at is null and r.status not in ('cancelled', 'expired')
                and r.stand_settlement = 'wallet'
                and r.id is distinct from p_except)
  select jsonb_build_object(
    'applies', s.settlement = 'wallet' and s.credit_limit is not null and not s.admin_only,
    'balance', b.balance, 'limit', s.credit_limit, 'pending', p.pending,
    'available', case when s.credit_limit is null then null
                      else round(b.balance - p.pending + s.credit_limit, 2) end,
    'set_by', s.credit_limit_set_by, 'max', s.credit_limit_max)
    from s, b, p;
$$;

create or replace function public.dispatch_settle(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  m jsonb;
  v_fare numeric;
  v_fee numeric;
  v_plat numeric;
  v_stand numeric;
  v_driver numeric;
  v_total numeric;
  v_note text;
  v_no_fee boolean;
  v_link boolean;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.stand_id is null or r.status <> 'completed' or r.dispatch_settled_at is not null then
    return jsonb_build_object('settled', false);
  end if;
  v_no_fee := coalesce(r.stand_fee_type, 'none') = 'none';
  m := public.dispatch_split(coalesce(r.ride_fare, r.fare, 0), r.stand_fee_type, r.stand_fee_value,
                             r.stand_fee_bearer, r.stand_platform_fee_type, r.stand_platform_fee_value);
  v_fare := (m->>'fare')::numeric;
  v_fee := (m->>'fee')::numeric;
  v_plat := (m->>'platform')::numeric;
  v_stand := (m->>'stand')::numeric;
  v_driver := (m->>'driver')::numeric;
  v_total := (m->>'customer')::numeric;
  v_note := coalesce(r.dispatch_stand_name, 'Stand') || ' · ticket ' || r.ticket_no;
  v_link := r.dispatch_payment = 'app' and coalesce(r.dispatch_pay_link, false);

  if v_link then
    -- (0252) Paid by a gateway link: the platform has the customer's money.
    -- Settled once both the trip is done and the payment is in (whichever
    -- comes second calls this): the driver's share to their GET.wallet, the
    -- stand's share of its fee to its GET.wallet; the platform keeps its fee.
    if r.dispatch_pay_paid_at is null then
      return jsonb_build_object('settled', false, 'waiting_payment', true);
    end if;
    if r.partner_id is not null and v_driver > 0 then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.partner_id, 'get_wallet', 'stand_payout', v_driver, 'gateway',
              'Fare paid by card / e-wallet link — ' || v_note, r.id)
      on conflict do nothing;
    end if;
    if r.stand_fee_earner_id is not null and v_stand > 0 then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.stand_fee_earner_id, 'get_wallet', 'stand_fee_earning', v_stand, 'gateway',
              'Stand fee less the platform''s — ' || v_note, r.id)
      on conflict do nothing;
    end if;
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'gateway', paid_amount = v_total,
           paid_at = r.dispatch_pay_paid_at,
           stand_fee_amount = case when v_no_fee then null else v_fee end,
           stand_platform_fee = case when v_no_fee then null else v_plat end,
           dispatch_settled_at = now()
     where id = r.id;
    return jsonb_build_object('settled', true, 'via', 'gateway') || m;
  end if;

  if r.dispatch_payment in ('counter', 'app') then
    -- The stand has the customer's money. Paid out in the app: the driver's
    -- share to their wallet, owed by the stand with the platform's fee.
    if r.stand_settlement = 'wallet' and r.partner_id is not null then
      if v_driver > 0 then
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
        values (r.partner_id, 'get_wallet', 'stand_payout', v_driver, 'stand',
                'Fare paid at the counter — ' || v_note, r.id)
        on conflict do nothing;
      end if;
      if r.stand_fee_earner_id is not null then
        if v_driver > 0 then
          insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
          values (r.stand_fee_earner_id, 'get_credit', 'stand_payout_due', -v_driver, 'stand',
                  'Driver paid for you — ' || v_note, r.id)
          on conflict do nothing;
        end if;
        if v_plat > 0 then
          insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
          values (r.stand_fee_earner_id, 'get_credit', 'stand_platform_fee', -v_plat, 'stand',
                  'Platform fee — ' || v_note, r.id)
          on conflict do nothing;
        end if;
      end if;
    end if;
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'counter', paid_amount = v_total, paid_at = now(),
           stand_fee_amount = case when v_no_fee then null else v_fee end,
           stand_platform_fee = case when v_no_fee then null else v_plat end,
           dispatch_settled_at = now()
     where id = r.id;
  else
    -- Cash to the driver, who holds the fee too: it comes off their
    -- GET.credit; the stand gets its share, the platform keeps its own.
    if v_fee > 0 and r.partner_id is not null then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.partner_id, 'get_credit', 'stand_fee', -v_fee, 'stand', 'Stand fee — ' || v_note, r.id)
      on conflict do nothing;
      if r.stand_fee_earner_id is not null and v_stand > 0 then
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
        values (r.stand_fee_earner_id, 'get_wallet', 'stand_fee_earning', v_stand, 'stand',
                'Stand fee less the platform''s — ' || v_note, r.id)
        on conflict do nothing;
      end if;
    end if;
    update public.ride_requests
       set payment_status = 'paid', paid_method = 'cash', paid_amount = v_total, paid_at = now(),
           stand_fee_amount = case when v_no_fee then null else v_fee end,
           stand_platform_fee = case when v_no_fee then null else v_plat end,
           dispatch_settled_at = now()
     where id = r.id;
  end if;
  return jsonb_build_object('settled', true) || m;
end;
$$;

create or replace function public.dispatch_order_json(p_request uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id, 'stand_id', r.stand_id, 'stand_name', r.dispatch_stand_name, 'ticket_no', r.ticket_no,
    'status', r.status, 'mode', r.dispatch_mode, 'group_id', r.dispatch_group_id,
    'group_name', r.dispatch_group_name, 'group_kind', r.dispatch_group_kind,
    'driver_id', r.dispatch_driver_id,
    'driver_target_name', case when r.dispatch_driver_id is not null then public.dispatch_actor_name(r.dispatch_driver_id) end,
    'offered_at', r.dispatch_offered_at, 'offer_until', r.dispatch_offer_until,
    'open_after', r.dispatch_open_after, 'widened_at', r.dispatch_widened_at,
    'returned_at', r.dispatch_returned_at, 'created_at', r.created_at,
    'pickup_name', r.pickup_name, 'pickup_address', r.pickup_address,
    'pickup_lat', r.pickup_lat, 'pickup_lng', r.pickup_lng,
    'booked_via', r.dispatch_booked_via, 'rider_account', r.rider_id is not null,
    'drop_name', r.drop_name, 'drop_address', r.drop_address, 'drop_lat', r.drop_lat, 'drop_lng', r.drop_lng,
    'service', r.service, 'passengers', r.passengers, 'note', r.note)
  || jsonb_build_object(
    'fare_mode', r.fare_mode, 'fare', coalesce(r.ride_fare, r.fare), 'currency', r.currency,
    'payment', r.dispatch_payment, 'payment_mode', r.payment_mode, 'payment_status', r.payment_status,
    'settlement', r.stand_settlement,
    'fee_type', r.stand_fee_type, 'fee_value', r.stand_fee_value, 'fee_bearer', r.stand_fee_bearer,
    'fee_amount', r.stand_fee_amount, 'settled_at', r.dispatch_settled_at,
    'platform_fee', r.stand_platform_fee,
    'customer_name', coalesce(pv.rider_name, r.rider_name),
    'customer_phone', coalesce(r.rider_phone, pv.rider_phone),
    'partner_id', r.partner_id, 'partner_name', r.partner_name, 'partner_phone', r.partner_phone,
    'partner_plate', r.partner_plate, 'partner_vehicle', r.partner_vehicle,
    'accepted_at', r.accepted_at, 'arrived_at', r.arrived_at, 'started_at', r.started_at,
    'completed_at', r.completed_at, 'cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason,
    'trip_code', (select c.code from public.ride_trip_codes c where c.request_id = r.id),
    'share_token', coalesce(r.share_token, pv.share_token),
    'created_by', r.dispatch_created_by, 'created_by_name', public.dispatch_actor_name(r.dispatch_created_by),
    'events', coalesce((select jsonb_agg(jsonb_build_object('action', e.action, 'detail', e.detail,
                                                            'actor', e.actor_name, 'at', e.at) order by e.at)
                          from public.dispatch_order_events e
                         where e.request_id = r.id
                            or (r.scheduled_ride_id is not null and e.scheduled_ride_id = r.scheduled_ride_id)),
                       '[]'::jsonb),
    'scheduled_ride_id', r.scheduled_ride_id,
    'pickup_at', (select b.pickup_at from public.scheduled_rides b where b.id = r.scheduled_ride_id))
  -- (0252) A card / e-wallet order's payment link.
  || jsonb_build_object(
    'pay_link', coalesce(r.dispatch_pay_link, false), 'pay_url', r.dispatch_pay_url,
    'pay_paid_at', r.dispatch_pay_paid_at,
    'pay_status', (select i.status from public.payment_intents i where i.id = r.dispatch_pay_intent_id),
    'pay_amount', (select i.amount from public.payment_intents i where i.id = r.dispatch_pay_intent_id),
    'pay_test', (select i.test_mode from public.payment_intents i where i.id = r.dispatch_pay_intent_id))
  from public.ride_requests r
  left join public.ride_request_private pv on pv.request_id = r.id
  where r.id = p_request;
$$;


-- The console: may the caller ask for a payment link for this order?
create or replace function public.payment_dispatch_link_allowed(p_request uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ride_requests r
                  where r.id = p_request and r.stand_id is not null
                    and public.dispatch_caller_can(r.stand_id, 'use'));
$$;
revoke execute on function public.payment_dispatch_link_allowed(uuid) from public, anon;
grant execute on function public.payment_dispatch_link_allowed(uuid) to authenticated, service_role;

-- The console: are card / e-wallet orders paid by a link now (no credentials)?
create or replace function public.dispatch_pay_link_available()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and public.payment_gateway_for('dispatch') is not null;
$$;
revoke execute on function public.dispatch_pay_link_available() from public, anon;
grant execute on function public.dispatch_pay_link_available() to authenticated;

-- Service role: the intent for an order's link (the pending one with the same
-- amount when there is one), with what the checkout needs of the customer.
create or replace function public.payment_dispatch_intent(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v public.payment_intents;
  v_gateway uuid;
  v_values jsonb;
  v_total numeric;
  v_phone text;
  v_name text;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.stand_id is null then
    raise exception 'unknown_order' using errcode = '22023';
  end if;
  if r.dispatch_payment is distinct from 'app' or not coalesce(r.dispatch_pay_link, false) then
    raise exception 'not_pay_link' using errcode = '22023';
  end if;
  if r.dispatch_pay_paid_at is not null or r.dispatch_settled_at is not null then
    raise exception 'already_paid' using errcode = '22023';
  end if;
  if r.status in ('cancelled', 'expired') then
    raise exception 'order_closed' using errcode = '22023';
  end if;
  if coalesce(r.ride_fare, r.fare, 0) <= 0 then
    raise exception 'fare_unknown' using errcode = '22023';
  end if;
  v_total := (public.dispatch_split(coalesce(r.ride_fare, r.fare), r.stand_fee_type, r.stand_fee_value,
                                    r.stand_fee_bearer, r.stand_platform_fee_type, r.stand_platform_fee_value)
              ->> 'customer')::numeric;
  select coalesce(pv.rider_phone, r.rider_phone), coalesce(pv.rider_name, r.rider_name) into v_phone, v_name
    from (select 1) x left join public.ride_request_private pv on pv.request_id = r.id;
  select * into v from public.payment_intents
   where id = r.dispatch_pay_intent_id and status = 'pending' and amount = v_total;
  if not found then
    v_gateway := public.payment_gateway_for('dispatch');
    select e.values into v_values from public.settings_entries e where e.id = v_gateway;
    if v_values is null then
      raise exception 'no_gateway' using errcode = '22023';
    end if;
    -- A link for another amount (the fare changed) is no longer the one to pay.
    update public.payment_intents set status = 'cancelled', failure = 'replaced'
     where id = r.dispatch_pay_intent_id and status = 'pending';
    insert into public.payment_intents (user_id, purpose, purpose_ref, gateway_id, provider, test_mode, amount, currency)
    values (r.rider_id, 'dispatch', r.id::text, v_gateway, v_values ->> 'providerId',
            coalesce(v_values ->> 'mode', 'Live') = 'Sandbox', v_total, 'MYR')
    returning * into v;
    update public.ride_requests set dispatch_pay_intent_id = v.id, dispatch_pay_url = null where id = r.id;
  end if;
  return to_jsonb(v) || jsonb_build_object(
    'customer', jsonb_build_object('name', coalesce(v_name, ''), 'phone', coalesce(v_phone, ''), 'email', ''),
    'ticket_no', r.ticket_no, 'stand_name', r.dispatch_stand_name);
end;
$$;
revoke execute on function public.payment_dispatch_intent(uuid) from public, anon, authenticated;
grant execute on function public.payment_dispatch_intent(uuid) to service_role;

-- Service role: the hosted page is on the order; the customer is texted it.
create or replace function public.payment_dispatch_link_set(p_request uuid, p_url text, p_actor uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_phone text;
  v_amount numeric;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.dispatch_pay_intent_id is null or coalesce(p_url, '') !~ '^https://' then
    raise exception 'unknown_order' using errcode = '22023';
  end if;
  update public.ride_requests set dispatch_pay_url = p_url where id = r.id;
  select amount into v_amount from public.payment_intents where id = r.dispatch_pay_intent_id;
  perform public.dispatch_log(r.id, r.stand_id, 'pay_link',
    'Payment link sent · RM ' || to_char(v_amount, 'FM999999990.00'), p_actor);
  v_phone := coalesce(r.rider_phone, (select p.rider_phone from public.ride_request_private p where p.request_id = r.id));
  if v_phone is not null then
    perform public.dispatch_sms(v_phone,
      'GET.ride ticket ' || r.ticket_no || ': pay RM ' || to_char(v_amount, 'FM999999990.00')
      || ' by card or e-wallet: ' || p_url);
  end if;
end;
$$;
revoke execute on function public.payment_dispatch_link_set(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.payment_dispatch_link_set(uuid, text, uuid) to service_role;

-- A paid link (payment_intent_apply, once per intent): the order is paid;
-- settled now if the trip is done, else when it is.
create or replace function public.payment_dispatch_paid(p_intent uuid, p_order text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  i public.payment_intents;
begin
  select * into i from public.payment_intents where id = p_intent;
  if p_order is null or p_order !~ '^[0-9a-fA-F-]{36}$' then
    return;
  end if;
  select * into r from public.ride_requests where id = p_order::uuid for update;
  if not found or r.stand_id is null then
    return;
  end if;
  if r.dispatch_pay_paid_at is not null or r.dispatch_settled_at is not null then
    -- Paid twice (an old link, or after the counter took it): an admin refunds it.
    perform public.dispatch_log(r.id, r.stand_id, 'paid_again',
      'Paid again by link (' || i.reference || ', RM ' || to_char(i.amount, 'FM999999990.00') || '): refund it', null);
    return;
  end if;
  if i.test_mode then
    -- A sandbox payment is not money: nothing is paid out.
    perform public.dispatch_log(r.id, r.stand_id, 'paid_test',
      'Test payment by link (sandbox) · RM ' || to_char(i.amount, 'FM999999990.00') || ': not paid out', null);
    return;
  end if;
  update public.ride_requests
     set dispatch_pay_paid_at = now(), dispatch_pay_intent_id = p_intent
   where id = r.id;
  perform public.dispatch_log(r.id, r.stand_id, 'paid',
    'Paid by card / e-wallet link · RM ' || to_char(i.amount, 'FM999999990.00')
    || case when i.test_mode then ' (test)' else '' end, null);
  if r.status in ('cancelled', 'expired') then
    perform public.dispatch_log(r.id, r.stand_id, 'paid_again', 'Paid after the order was cancelled: refund it', null);
    return;
  end if;
  if r.status = 'completed' then
    perform public.dispatch_settle(r.id);
  end if;
end;
$$;
revoke execute on function public.payment_dispatch_paid(uuid, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
