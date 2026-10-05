-- ============================================================================
-- 0094 — referral codes apply to new accounts only
-- ----------------------------------------------------------------------------
-- apply_referral (0078) credits bonus GET.coin to the inviter and the new
-- user. It is meant to run once, right after sign-up (Expo pin-setup, Flutter
-- set-PIN step), but nothing enforced that: any account, however old, could
-- call it once with any code and collect the welcome bonus (and credit an
-- inviter of its choosing).
--
-- Changes:
--   * The calling account must have been created within the last 7 days
--     (profiles.created_at). Older accounts get error 'not_new_account'.
--   * The account-id fallback (the 8-character code the apps share) needs the
--     full 8 characters. A 4-character code used to match the first profile
--     whose id happened to start with it, crediting an unrelated account.
--     Explicit profiles.referral_code values still match at any length >= 4.
--
-- Everything else is unchanged: one referral per account, no self-referral,
-- the admin's referral_enabled switch and coin amounts.
-- ============================================================================

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
  v_created timestamptz;
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

  -- New accounts only: a referral is part of signing up.
  select created_at into v_created from public.profiles where id = v_user;
  if v_created is null or v_created < now() - interval '7 days' then
    return jsonb_build_object('ok', false, 'error', 'not_new_account');
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
  -- deterministic account-id code the apps share (its first 8 characters).
  select id into v_referrer
    from public.profiles
   where upper(coalesce(referral_code, '')) = v_code
   limit 1;
  if v_referrer is null and length(v_code) = 8 then
    select id into v_referrer
      from public.profiles
     where upper(left(replace(id::text, '-', ''), 8)) = v_code
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
