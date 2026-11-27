-- Reject → restart: a rejected ID returns to pending when the rider re-uploads.
-- ============================================================================
-- The owner's flow: when an admin rejects a rider's ID (profiles.id_verified =
-- 'Failed'), the rider redoes the whole thing, and the fresh upload must come
-- back as a *pending* review (not stay stuck on 'Failed'), on both the Edit-
-- profile plain upload and the GET.eKYC re-capture.
--
-- profiles.id_verified is written by admins (profile_id_review) and by the
-- server's strong auto-verify (rider_id_gate_apply, 0343); a rider's own
-- profiles UPDATE only ever carries id_image. So the reset is done server-side:
--
--  1. A BEFORE UPDATE trigger on profiles returns a 'Failed' profile to pending
--     (id_verified := null) when its id_image changes AND the statement did not
--     itself set id_verified. A BEFORE trigger may set id_verified even though
--     the rider's own statement names only id_image, and the "statement didn't
--     touch id_verified" guard means an admin verify or a strong auto-verify
--     (which set id_verified alongside id_image) is never undone.
--  2. The 0445 seed trigger is widened so a new rider-gate ID check also
--     REPLACES id_image when the profile was 'Failed' (not only when it has
--     none) — the GET.eKYC re-capture then flows through (1) and resets to
--     pending, with the new photo shown.
--
-- Reversible: drop the new trigger + function and restore the 0445 seed trigger
-- to its id_image-is-null-only form.
-- ============================================================================

-- 1. A new ID image on a rejected profile returns it to pending review.
create or replace function public.profiles_reupload_reopens_id()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id_image is distinct from old.id_image
     and old.id_verified = 'Failed'
     and new.id_verified is not distinct from old.id_verified then
    new.id_verified := null;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_reupload_reopens_id on public.profiles;
create trigger profiles_reupload_reopens_id
  before update on public.profiles
  for each row execute function public.profiles_reupload_reopens_id();

-- 2. Widen the 0445 seed so a GET.eKYC / face-match re-capture replaces the
--    rejected image too (then trigger (1) reopens the review).
create or replace function public.identity_check_seed_profile_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'id' and new.purpose = 'rider_gate' and new.file_url is not null then
    update public.profiles
       set id_image = new.file_url, updated_at = now()
     where id = new.user_id and (id_image is null or id_verified = 'Failed');
  end if;
  return new;
end;
$$;
revoke execute on function public.identity_check_seed_profile_id() from public, anon, authenticated;

notify pgrst, 'reload schema';
