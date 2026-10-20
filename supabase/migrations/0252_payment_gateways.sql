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
--      * dispatch calls public.payment_dispatch_paid(intent id, purpose_ref):
--        a no-op here. The stand order (Order Dispatch, 0251) is not on main
--        yet; the migration that adds it replaces this function to mark the
--        order (purpose_ref = its id) paid.
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

-- The hooks a later migration wires (see the header). Called once per paid intent.
create or replace function public.payment_dispatch_paid(p_intent uuid, p_order text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Replaced by the Order Dispatch migration: mark stand order p_order paid.
  return;
end;
$$;
revoke execute on function public.payment_dispatch_paid(uuid, text) from public, anon, authenticated;

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
    v_applied := 'dispatch';
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

notify pgrst, 'reload schema';
