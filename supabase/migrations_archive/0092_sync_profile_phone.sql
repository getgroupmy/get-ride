-- ============================================================================
-- 0092 — keep profiles.phone in step with a verified phone change
-- ----------------------------------------------------------------------------
-- Changing number (Expo app/change-number.tsx, Flutter ChangePhoneScreen)
-- goes through Supabase Auth: `auth.updateUser({ phone })` texts a code to
-- the new number and `verifyOtp({ type: 'phone_change' })` moves
-- `auth.users.phone`. Nothing carried that across to `public.profiles.phone`:
-- the signup trigger (`handle_new_auth_user`) only runs on insert, and since
-- 0087 clients can't write `profiles.phone` themselves (protected column).
-- So after a change:
--   * `verify_pin_for_login` / `profile_phone_lookup`, which match on
--     profiles.phone, still answered for the OLD number: PIN sign-in with the
--     new number fell through to OTP, and the old number still read as taken;
--   * admin screens and receipts kept showing the old number.
--
-- Fix: an AFTER UPDATE OF phone trigger on auth.users copies the verified
-- number onto the profile. It runs as its owner (SECURITY DEFINER), so the
-- 0087 guard — which only restricts direct anon/authenticated requests —
-- lets it through. profiles.phone has no unique constraint, so the copy
-- can't fail and block the Auth update. Numbers are stored as Auth stores
-- them (digits, no '+'), the same as the signup trigger.
--
-- Also backfills any profile whose phone already differs from Auth.
-- ============================================================================

create or replace function public.sync_profile_phone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.phone, '') <> '' and new.phone is distinct from old.phone then
    update public.profiles
       set phone = new.phone
     where id = new.id
       and phone is distinct from new.phone;
  end if;
  return new;
end;
$$;

revoke all on function public.sync_profile_phone() from public, anon, authenticated;

drop trigger if exists on_auth_user_phone_changed on auth.users;
create trigger on_auth_user_phone_changed
  after update of phone on auth.users
  for each row execute function public.sync_profile_phone();

update public.profiles p
   set phone = u.phone
  from auth.users u
 where u.id = p.id
   and coalesce(u.phone, '') <> ''
   and p.phone is distinct from u.phone;
