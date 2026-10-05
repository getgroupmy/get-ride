-- ============================================================================
-- 0004 — Phone-to-PIN lookup RPC for the login flow.
--
-- Problem: profiles RLS allows reads only when auth.uid() = id, so an anon
-- client (pre-login) cannot check whether a phone number already has a PIN
-- and ends up routing every user to the "create account" sheet.
--
-- Solution: a SECURITY DEFINER function that returns only the two booleans
-- the login screen needs (has_pin, is_deleted) plus the canonical id, never
-- the row itself. Phone variants are matched server-side so the client
-- doesn't have to guess the stored format.
-- ============================================================================

create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
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
    select p.pin, p.login_pin, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select
    exists(select 1 from match)                                    as has_profile,
    coalesce((select (pin is not null and pin <> '')
                  or (login_pin is not null and login_pin <> '')
              from match), false)                                  as has_pin,
    coalesce((select lower(profile_status::text) = 'deleted'
              from match), false)                                  as is_deleted;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

notify pgrst, 'reload schema';
