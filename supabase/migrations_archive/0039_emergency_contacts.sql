-- ============================================================================
-- Emergency contacts (per profile)
-- ----------------------------------------------------------------------------
-- Stores the user's saved Emergency SOS contacts so they survive app restarts
-- and sync to the user's profile.
--   * emergency_contacts — name + phone rows tied to public.profiles
-- RLS is permissive (matches the rest of this project: admin uses a non-RLS
-- super session, users access their own rows through the same client).
-- Realtime is enabled so edits sync across devices.
-- Safe to re-run.
-- ============================================================================

create table if not exists public.emergency_contacts (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  phone text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists emergency_contacts_profile_idx
  on public.emergency_contacts(profile_id, created_at);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
do $$
begin
  drop trigger if exists trg_emergency_contacts_updated_at on public.emergency_contacts;
  create trigger trg_emergency_contacts_updated_at before update on public.emergency_contacts
    for each row execute function public.set_updated_at();
end$$;

-- ---------------------------------------------------------------------------
-- RLS — permissive
-- ---------------------------------------------------------------------------
alter table public.emergency_contacts enable row level security;

drop policy if exists "emergency_contacts read"   on public.emergency_contacts;
drop policy if exists "emergency_contacts insert" on public.emergency_contacts;
drop policy if exists "emergency_contacts update" on public.emergency_contacts;
drop policy if exists "emergency_contacts delete" on public.emergency_contacts;

create policy "emergency_contacts read"   on public.emergency_contacts for select using (true);
create policy "emergency_contacts insert" on public.emergency_contacts for insert to public with check (true);
create policy "emergency_contacts update" on public.emergency_contacts for update to public using (true) with check (true);
create policy "emergency_contacts delete" on public.emergency_contacts for delete to public using (true);

grant select, insert, update, delete on public.emergency_contacts to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.emergency_contacts;
exception when duplicate_object then null; end$$;
alter table public.emergency_contacts replica identity full;
