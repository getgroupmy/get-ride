-- Add a server-side PIN field to profiles so PIN status syncs across devices.
-- The PIN is stored as plaintext but protected by RLS (only the owning user
-- can read or update their own profile row) and by Supabase Auth gating sign-in.
alter table public.profiles
  add column if not exists pin text;
