-- ============================================================================
-- 0071_device_account_guard.sql
-- Device-based duplicate-account detection for the sign-up flow.
--
-- The client captures a stable per-device fingerprint (user_sessions.device_id,
-- migration 0070). Under the 0069 RLS lockdown a client can only read its OWN
-- user_sessions rows, so it cannot tell whether a device already backs other
-- accounts. This SECURITY DEFINER RPC answers exactly that — and only that —
-- question: how many DISTINCT accounts other than the caller have signed in
-- from a given device_id. It returns a bare count, never any PII.
--
-- The sign-up screen (expo/app/pin-setup.tsx via utils/deviceGuard.ts) calls
-- this before finalizing a new account and blocks once the count reaches the
-- app-side limit (MAX_ACCOUNTS_PER_DEVICE).
-- ============================================================================

create or replace function public.device_prior_account_count(p_device_id text)
returns integer
language sql
security definer
set search_path = public
stable
as $$
  select count(distinct user_id)::int
  from public.user_sessions
  where p_device_id is not null
    and p_device_id <> ''
    and device_id = p_device_id
    and user_id is not null
    -- Exclude the caller themselves so their own prior sessions don't count.
    -- auth.uid() is null for anon callers (pre-session); the sentinel keeps the
    -- comparison valid and simply counts every attributable account.
    and user_id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);
$$;

revoke all on function public.device_prior_account_count(text) from public;
grant execute on function public.device_prior_account_count(text) to anon, authenticated;

notify pgrst, 'reload schema';
