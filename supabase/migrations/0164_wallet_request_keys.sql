-- ============================================================================
-- 0164: money calls that are safe to repeat (wallet request keys)
--
-- wallet_pay, wallet_recharge_credit, wallet_trade_coins,
-- wallet_request_coin_transfer and wallet_transfer_coins move money and have
-- no guard against running twice. Since the app gives up on a server that
-- does not answer (TimeoutHttpClient), a call it stopped waiting for may
-- still have completed -- and the user's next tap would pay again.
--
-- Each gets a `_once` twin taking a client-chosen p_request_id. The twin
-- claims the id in wallet_request_keys inside the same transaction, calls
-- the original function unchanged, and stores its result against the id.
-- The same id again returns the stored result instead of moving money a
-- second time. A concurrent duplicate waits on the claim row and then reads
-- the result; a call that failed rolled its claim back with it, so a retry
-- runs for real. The originals are untouched and still callable, so an
-- older app (or one on a database without this migration) works as before.
--
-- The app keeps an id only while an outcome is unknown (timeout, network
-- error), and drops it once the server has answered either way, so paying
-- the same amount twice on purpose is two payments.
-- ============================================================================

create table if not exists public.wallet_request_keys (
  id uuid primary key,
  user_id uuid not null,
  fn text not null,
  result jsonb,
  created_at timestamptz not null default now()
);
create index if not exists wallet_request_keys_created_idx on public.wallet_request_keys (created_at);

-- Only the functions below touch it.
alter table public.wallet_request_keys enable row level security;
revoke all on public.wallet_request_keys from public, anon, authenticated;

-- Claims p_request_id for p_user's call to p_fn. Null: go ahead (the claim
-- is held until the transaction ends). Otherwise the stored result of the
-- earlier call with this id.
create or replace function public.wallet_request_claim(p_request_id uuid, p_user uuid, p_fn text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.wallet_assert_caller(p_user);
  if p_request_id is null then
    raise exception 'invalid_request_id';
  end if;
  insert into public.wallet_request_keys (id, user_id, fn)
  values (p_request_id, p_user, p_fn)
  on conflict (id) do nothing;
  if found then
    return null;
  end if;
  select k.result into v
    from public.wallet_request_keys k
   where k.id = p_request_id and k.user_id = p_user and k.fn = p_fn;
  if v is null then
    -- Someone else's id, another function's, or (impossibly) unsettled.
    raise exception 'request_id_conflict';
  end if;
  return v;
end
$$;

create or replace function public.wallet_request_settle(p_request_id uuid, p_result jsonb)
returns jsonb
language sql
security definer
set search_path = public
as $$
  update public.wallet_request_keys
     set result = coalesce(p_result, 'null'::jsonb)
   where id = p_request_id
  returning result;
$$;

revoke execute on function public.wallet_request_claim(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.wallet_request_settle(uuid, jsonb) from public, anon, authenticated;

create or replace function public.wallet_pay_once(
  p_request_id uuid,
  p_user uuid,
  p_amount numeric,
  p_note text default null,
  p_method text default 'qr_scan',
  p_redeem_coins boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.wallet_request_claim(p_request_id, p_user, 'wallet_pay');
begin
  if v is not null then
    return v;
  end if;
  return public.wallet_request_settle(
    p_request_id, public.wallet_pay(p_user, p_amount, p_note, p_method, p_redeem_coins));
end
$$;

create or replace function public.wallet_recharge_credit_once(p_request_id uuid, p_user uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.wallet_request_claim(p_request_id, p_user, 'wallet_recharge_credit');
begin
  if v is not null then
    return v;
  end if;
  return public.wallet_request_settle(
    p_request_id,
    (select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) from public.wallet_recharge_credit(p_user, p_amount) w));
end
$$;

create or replace function public.wallet_trade_coins_once(
  p_request_id uuid,
  p_user uuid,
  p_direction text,
  p_coins numeric,
  p_rate_per_gc numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.wallet_request_claim(p_request_id, p_user, 'wallet_trade_coins');
begin
  if v is not null then
    return v;
  end if;
  return public.wallet_request_settle(
    p_request_id, public.wallet_trade_coins(p_user, p_direction, p_coins, p_rate_per_gc));
end
$$;

create or replace function public.wallet_request_coin_transfer_once(
  p_request_id uuid,
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.wallet_request_claim(p_request_id, p_from, 'wallet_request_coin_transfer');
begin
  if v is not null then
    return v;
  end if;
  return public.wallet_request_settle(
    p_request_id, public.wallet_request_coin_transfer(p_from, p_coins, p_to, p_to_phone, p_note));
end
$$;

create or replace function public.wallet_transfer_coins_once(
  p_request_id uuid,
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.wallet_request_claim(p_request_id, p_from, 'wallet_transfer_coins');
begin
  if v is not null then
    return v;
  end if;
  return public.wallet_request_settle(
    p_request_id, public.wallet_transfer_coins(p_from, p_coins, p_to, p_to_phone, p_note));
end
$$;

-- Signed in only, like the originals (0162).
revoke execute on function public.wallet_pay_once(uuid, uuid, numeric, text, text, boolean) from public, anon;
revoke execute on function public.wallet_recharge_credit_once(uuid, uuid, numeric) from public, anon;
revoke execute on function public.wallet_trade_coins_once(uuid, uuid, text, numeric, numeric) from public, anon;
revoke execute on function public.wallet_request_coin_transfer_once(uuid, uuid, numeric, uuid, text, text) from public, anon;
revoke execute on function public.wallet_transfer_coins_once(uuid, uuid, numeric, uuid, text, text) from public, anon;
grant execute on function public.wallet_pay_once(uuid, uuid, numeric, text, text, boolean) to authenticated, service_role;
grant execute on function public.wallet_recharge_credit_once(uuid, uuid, numeric) to authenticated, service_role;
grant execute on function public.wallet_trade_coins_once(uuid, uuid, text, numeric, numeric) to authenticated, service_role;
grant execute on function public.wallet_request_coin_transfer_once(uuid, uuid, numeric, uuid, text, text) to authenticated, service_role;
grant execute on function public.wallet_transfer_coins_once(uuid, uuid, numeric, uuid, text, text) to authenticated, service_role;

-- Keys are only needed while a retry could arrive: a daily sweep keeps 30
-- days, where pg_cron is installed.
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'wallet-request-keys-sweep',
      '17 3 * * *',
      $sql$delete from public.wallet_request_keys where created_at < now() - interval '30 days'$sql$
    );
  end if;
end
$$;
