-- ============================================================================
-- 0172: PIN sign-in through the server (pin-login edge function)
--
-- Until now a PIN sign-in sent Supabase Auth a password built from the PIN
-- ('teksi-pin-v1-' || pin). Six digits make a million passwords per phone,
-- and Auth has no per-account lockout on the password grant -- only a
-- per-address rate limit -- so anyone spread across enough addresses could
-- try them all against a known number. The lockout below (five wrong PINs,
-- fifteen minutes) only ever guarded verify_pin_for_login, not that route.
--
-- The pin-login edge function now does the sign-in: it checks the PIN here
-- (same hash, same rate limit and lockout), and on a match gives the Auth
-- user a fresh random password, signs in with it and hands the session back.
-- Nothing derived from the PIN is a password any more, so the password grant
-- is no use to a guesser once an account's old derived password is gone (the
-- apps overwrite it with a random one, and the function does at every
-- sign-in).
--
--   * pin_check(phone, pin, ip): the check itself, factored out of
--     verify_pin_for_login (0151) with the caller's address passed in;
--     internal, granted to nobody;
--   * verify_pin_for_login(phone, pin): unchanged behaviour for the apps,
--     now calling pin_check with the request's address;
--   * pin_login_check(phone, pin, ip): what pin-login calls, service role
--     only -- the function forwards the client's address, since its own
--     request to the database comes from the function, not the phone.
-- ============================================================================

create or replace function public.pin_check(p_phone text, p_pin text, p_ip text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_digits   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_row      record;
  v_matched  boolean := false;
  v_attempts integer;
  -- Keyed as in 0137: no address (SQL, the service role) is not limited
  -- here; pin-login always passes one. The per-account lockout below holds
  -- either way.
  v_wait     integer := public.auth_rate_take('pin_check', p_ip, 30, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  if v_digits = '' then
    return null;
  end if;

  select p.id, p.pin_hash, p.pin_failed_attempts, p.pin_locked_until
    into v_row
    from public.profiles p
   where p.phone = any (array_remove(array[
           '+' || v_digits,
           v_digits,
           '0' || v_digits,
           ltrim(v_digits, '0')
         ], null))
   limit 1;

  if v_row.id is null then
    return null;
  end if;

  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    raise exception 'PIN_LOCKED:%',
      ceil(extract(epoch from (v_row.pin_locked_until - now())))::integer;
  end if;

  if v_row.pin_hash is not null and v_row.pin_hash <> '' then
    v_matched := v_row.pin_hash = crypt(p_pin, v_row.pin_hash);
  end if;

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null
     where id = v_row.id;
    return v_row.id;
  end if;

  v_attempts := coalesce(v_row.pin_failed_attempts, 0) + 1;
  if v_attempts >= 5 then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = now() + interval '15 minutes'
     where id = v_row.id;
  else
    update public.profiles
       set pin_failed_attempts = v_attempts
     where id = v_row.id;
  end if;
  return null;
end;
$$;

revoke all on function public.pin_check(text, text, text) from public, anon, authenticated;

create or replace function public.verify_pin_for_login(p_phone text, p_pin text)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.pin_check(p_phone, p_pin, public.request_client_ip());
$$;

revoke all on function public.verify_pin_for_login(text, text) from public;
grant execute on function public.verify_pin_for_login(text, text) to anon, authenticated;

create or replace function public.pin_login_check(p_phone text, p_pin text, p_ip text)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.pin_check(p_phone, p_pin, p_ip);
$$;

revoke all on function public.pin_login_check(text, text, text) from public, anon, authenticated;
grant execute on function public.pin_login_check(text, text, text) to service_role;
