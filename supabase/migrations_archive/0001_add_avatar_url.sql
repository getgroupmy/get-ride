-- ============================================================================
-- Migration: ensure profiles.avatar_url exists
-- ----------------------------------------------------------------------------
-- Run this in the Supabase Dashboard → SQL Editor if you see:
--   "Could not find the 'avatar_url' column of 'profiles' in the schema cache"
-- It is idempotent and safe to re-run.
-- ============================================================================

alter table public.profiles
  add column if not exists avatar_url text;

-- Tell PostgREST to reload its schema cache so the new column is visible
-- to the client immediately (no need to restart the project).
notify pgrst, 'reload schema';
