-- 0078: Referral program — invite friends, both earn bonus GET.coin.
--
-- * Adds admin reward rules to get_coin_settings (enabled + coin amounts).
-- * referrals table records who invited whom (one referral per new user).
-- * apply_referral(p_code) RPC: called by the NEW user right after signup.
--   Resolves the referrer from the shared code, records the referral and
--   credits bonus GET.coin to BOTH accounts atomically. SECURITY DEFINER so
--   the new user can credit the referrer's wallet without widening RLS.

-- Reward rules -------------------------------------------------------------
alter table public.get_coin_settings
  add column if not exists referral_enabled boolean not null default true,
  add column if not exists referral_referrer_coins numeric(12,2) not null default 0,
  add column if not exists referral_referred_coins numeric(12,2) not null default 0;

-- Referrals ----------------------------------------------------------------
create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references public.profiles(id) on delete cascade,
  referred_user_id uuid not null references public.profiles(id) on delete cascade,
  code text not null,
  referrer_coins numeric(12,2) not null default 0,
  referred_coins numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  -- A user can only ever be referred once.
  unique (referred_user_id),
  check (referrer_user_id <> referred_user_id)
);

create index if not exists referrals_referrer_idx
  on public.referrals (referrer_user_id);

alter table public.referrals enable row level security;

drop policy if exists "referrals select own" on public.referrals;
create policy "referrals select own" on public.referrals
  for select to authenticated
  using (auth.uid() = referrer_user_id or auth.uid() = referred_user_id);

-- Apply a referral code ------------------------------------------------------
create or replace function public.apply_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_referrer uuid;
  v_enabled boolean := true;
  v_referrer_coins numeric := 0;
  v_referred_coins numeric := 0;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if length(v_code) < 4 then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  select coalesce(referral_enabled, true),
         coalesce(referral_referrer_coins, 0),
         coalesce(referral_referred_coins, 0)
    into v_enabled, v_referrer_coins, v_referred_coins
    from public.get_coin_settings
   where id = 'master';

  if not coalesce(v_enabled, true) then
    return jsonb_build_object('ok', false, 'error', 'disabled');
  end if;

  -- Resolve the referrer: an explicit profiles.referral_code wins, else the
  -- deterministic uuid-prefix code the app shares (first 8 hex chars).
  select id into v_referrer
    from public.profiles
   where upper(coalesce(referral_code, '')) = v_code
   limit 1;
  if v_referrer is null then
    select id into v_referrer
      from public.profiles
     where upper(replace(id::text, '-', '')) like v_code || '%'
     limit 1;
  end if;

  if v_referrer is null then
    return jsonb_build_object('ok', false, 'error', 'code_not_found');
  end if;
  if v_referrer = v_user then
    return jsonb_build_object('ok', false, 'error', 'self_referral');
  end if;
  if exists (select 1 from public.referrals where referred_user_id = v_user) then
    return jsonb_build_object('ok', false, 'error', 'already_referred');
  end if;

  insert into public.referrals
    (referrer_user_id, referred_user_id, code, referrer_coins, referred_coins)
  values
    (v_referrer, v_user, v_code, v_referrer_coins, v_referred_coins);

  if v_referrer_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_referrer, 'get_coin', 'referral', v_referrer_coins, 'referral', 'Referral bonus — a friend joined with your link');
  end if;
  if v_referred_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_user, 'get_coin', 'referral', v_referred_coins, 'referral', 'Welcome bonus — joined with a referral link');
  end if;

  return jsonb_build_object(
    'ok', true,
    'referrer_coins', v_referrer_coins,
    'referred_coins', v_referred_coins
  );
end;
$$;

grant execute on function public.apply_referral(text) to authenticated;

notify pgrst, 'reload schema';
