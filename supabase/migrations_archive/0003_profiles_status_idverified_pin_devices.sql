-- ============================================================================
-- 0003_profiles_status_idverified_pin_devices.sql
-- Adds profile status, ID verification status, login PIN, and device count
-- columns to public.profiles.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type profile_status as enum (
    'Approved','Un-Approved','Blocked','Rejected','Deleted'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type id_verification_status as enum ('Verified','Failed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists profile_status profile_status         not null default 'Un-Approved',
  add column if not exists id_verified    id_verification_status,
  add column if not exists login_pin      text,
  add column if not exists device_count   integer                not null default 1;

-- Helpful indexes
create index if not exists profiles_profile_status_idx on public.profiles(profile_status);
create index if not exists profiles_id_verified_idx    on public.profiles(id_verified);

-- ---------------------------------------------------------------------------
-- Reload PostgREST schema cache so the new columns (especially `login_pin`)
-- become writable through the REST API immediately. Without this, PostgREST
-- can silently drop unknown columns from update payloads until the next
-- automatic reload — which is why `login_pin` may not capture on PIN change.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';
