-- ============================================================================
-- 0187: full admins read sign-in codes in Admin -> SMS; sub-admins don't.
--
-- 0183 took the code text out of sms_outbox (masked "••••••" there) into
-- sms_otp_secret, readable by nobody but the gateway's claim. A full admin
-- (page '*' with edit access) may read it again, for support; a sub-admin,
-- whatever pages they hold, still sees only the masked row. The secrets are
-- purged after a day, so older jobs show masked to everyone.
-- ============================================================================

create or replace function public.caller_is_full_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_access
     where profile_id = auth.uid() and page = '*' and access_level = 'edit'
  );
$$;
revoke execute on function public.caller_is_full_admin() from public, anon;
grant execute on function public.caller_is_full_admin() to authenticated;

grant select on public.sms_otp_secret to authenticated;

drop policy if exists "sms_otp_secret full admin read" on public.sms_otp_secret;
create policy "sms_otp_secret full admin read" on public.sms_otp_secret
  for select to authenticated
  using ((select public.caller_is_full_admin()));
