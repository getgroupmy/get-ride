-- ============================================================================
-- 0087 — profiles: admins can write, users can't approve themselves
-- ----------------------------------------------------------------------------
-- Until now `public.profiles` had exactly one write policy, "profiles self
-- write" (UPDATE, `auth.uid() = id`, no WITH CHECK). Two problems followed:
--
--   1. Admin writes silently did nothing. With no admin UPDATE/DELETE policy,
--      every back-office change to another user (approve / block / reject,
--      ID-document verify and reject, profile edits, delete) matched zero rows
--      and PostgREST reported success. Both the Expo panel and the Flutter
--      panel showed "Saved".
--   2. Users could change anything on their own row: `status`,
--      `profile_status`, `id_verified`, `documents_ok`, `pin_failed_attempts`,
--      `pin_locked_until`, `phone`, … So a blocked user could unblock
--      themselves and anyone could mark their own ID as verified.
--
-- Fix:
--   * "profiles admin update" / "profiles admin delete" for callers holding an
--     `admin_access` row (`caller_is_admin()`, same as every 0069 policy).
--   * "profiles self write" gains a WITH CHECK, so a row can't be moved to
--     another id.
--   * A BEFORE UPDATE guard rejects changes to protected columns made by a
--     direct client request (role anon/authenticated) from a non-admin.
--     SECURITY DEFINER functions run as their owner, not as the client role,
--     so the server-side paths that legitimately maintain these columns pass
--     through untouched:
--     - set_login_pin / clear_login_pin → pin_hash
--     - verify_pin_for_login → lockout counters
--     - apply_referral, the wallet RPCs
--     - the auth signup trigger
--   * The guard is named to sort before `trg_profiles_hash_pin`, so it sees
--     the client's own values. The legacy `login_pin` / `pin` write path keeps
--     working, while a client writing `pin_hash` directly is refused.
--
-- What users may still change on their own row is exactly what the apps write
-- today: name, email, avatar_url / profile_image, nationality, ic, address,
-- id_image, id_type, gender, birth_date, and the legacy login_pin / pin
-- inputs (hashed by trg_profiles_hash_pin).
--
-- The guard raises `PROFILE_PROTECTED_COLUMN:<column>` (SQLSTATE 42501) so a
-- client can tell this refusal apart from other errors.
-- ============================================================================

-- ---- Policies ---------------------------------------------------------------

drop policy if exists "profiles self write" on public.profiles;
create policy "profiles self write"
  on public.profiles for update to public
  using (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists "profiles admin update" on public.profiles;
create policy "profiles admin update"
  on public.profiles for update to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());

drop policy if exists "profiles admin delete" on public.profiles;
create policy "profiles admin delete"
  on public.profiles for delete to public
  using (public.caller_is_admin());

-- ---- Column guard -------------------------------------------------------------

create or replace function public.profiles_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- Only direct client requests are restricted. SECURITY DEFINER functions
  -- and server-side sessions (setup scripts, the service role's own
  -- connection role) run under other roles and pass through.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if public.caller_is_admin() then
    return new;
  end if;

  -- jsonb comparison: a column missing on an older schema reads as null on
  -- both sides, so the guard stays safe to apply anywhere.
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id',
    'phone',
    'status',
    'profile_status',
    'id_verified',
    'id_expiry_date',
    'documents_ok',
    'total_rides',
    'display_id',
    'referral_code',
    'device_count',
    'joined_at',
    'created_at',
    'pin_hash',
    'pin_failed_attempts',
    'pin_locked_until',
    'mcash_wallet_id',
    'mcash_ekyc_status',
    'mcash_customer_status'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PROFILE_PROTECTED_COLUMN:%', v_col
        using errcode = '42501',
              hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$$;

comment on function public.profiles_guard_protected_columns() is
  'Rejects non-admin client changes to protected profile columns (status, verification, PIN lockout, phone, ids). See migration 0087.';

drop trigger if exists trg_profiles_a_guard on public.profiles;
create trigger trg_profiles_a_guard
  before update on public.profiles
  for each row execute function public.profiles_guard_protected_columns();
