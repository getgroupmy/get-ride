-- ============================================================================
-- 0045 — Verify-PIN-for-login RPC
--
-- Problem: signInWithPin mints a Supabase session via signInWithPassword using
-- a deterministic password derived from the PIN. If that password was never
-- synced (user predates the feature, or updateUser failed), the login fails
-- with "Invalid login credentials". The client-side fallback that checks the
-- in-memory profilePin can't help a logged-out user (profilePin is only
-- populated after an authenticated session is established).
--
-- Solution: a SECURITY DEFINER function the anon client can call to check
-- whether an entered PIN matches what is stored in profiles. Returns the
-- user's UUID on success so the caller can identify the account; returns null
-- on mismatch. Never returns the stored PIN itself.
-- ============================================================================

create or replace function public.verify_pin_for_login(p_phone text, p_pin text)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array[
      '+' || d,
      d,
      '0' || d,
      ltrim(d, '0')
    ], null) as v
    from digits
  ),
  match as (
    select p.id, p.pin, p.login_pin
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select id from match
  where
    (login_pin is not null and login_pin <> '' and login_pin = p_pin)
    or (pin     is not null and pin      <> '' and pin      = p_pin)
$$;

revoke all on function public.verify_pin_for_login(text, text) from public;
grant execute on function public.verify_pin_for_login(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
