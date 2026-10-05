-- ============================================================================
-- 0009_admin_access.sql
-- ----------------------------------------------------------------------------
-- Per-profile admin access control:
--   * which profiles can access the admin section
--   * which admin pages each profile can open
--   * what level of access they have on each page (read-only or edit)
--
-- Model:
--   admin_access  : one row per (profile, page) pair
--                   access_level in ('read','edit')
--                   page is a route key (e.g. 'admin-orders',
--                   'admin-settings-api-keys', or '*' for full access)
--
-- A profile with ANY row in admin_access is considered an admin.
-- A row with page='*' grants access to every admin page at the given level.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Access level enum
-- ---------------------------------------------------------------------------
do $$ begin
  create type admin_access_level as enum ('read','edit');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
create table if not exists public.admin_access (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  page          text not null,                  -- route key, or '*' for all pages
  access_level  admin_access_level not null default 'read',
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (profile_id, page)
);

create index if not exists admin_access_profile_idx on public.admin_access(profile_id);
create index if not exists admin_access_page_idx    on public.admin_access(page);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
drop trigger if exists trg_admin_access_updated_at on public.admin_access;
create trigger trg_admin_access_updated_at
  before update on public.admin_access
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Helper functions (used by the app and by RLS policies on other tables)
-- ---------------------------------------------------------------------------
create or replace function public.is_admin(p_profile uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admin_access where profile_id = p_profile
  );
$$;

create or replace function public.admin_can_edit(p_profile uuid, p_page text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admin_access
    where profile_id = p_profile
      and (page = p_page or page = '*')
      and access_level = 'edit'
  );
$$;

create or replace function public.admin_can_read(p_profile uuid, p_page text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admin_access
    where profile_id = p_profile
      and (page = p_page or page = '*')
  );
$$;

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.admin_access enable row level security;

-- Each profile can see their own admin_access rows (so the app can decide what
-- to show in the admin menu without exposing other admins' permissions).
drop policy if exists "admin_access self read" on public.admin_access;
create policy "admin_access self read"
  on public.admin_access for select
  using (profile_id = auth.uid());

-- Existing admins with 'edit' on the admin-sub-admin page (or '*') can read
-- everyone's rows so they can manage the list.
drop policy if exists "admin_access admin read" on public.admin_access;
create policy "admin_access admin read"
  on public.admin_access for select
  using (
    public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin')
  );

-- Only admins with 'edit' on the sub-admin page can insert/update/delete.
drop policy if exists "admin_access admin write insert" on public.admin_access;
create policy "admin_access admin write insert"
  on public.admin_access for insert
  with check (
    public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin')
  );

drop policy if exists "admin_access admin write update" on public.admin_access;
create policy "admin_access admin write update"
  on public.admin_access for update
  using (
    public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin')
  );

drop policy if exists "admin_access admin write delete" on public.admin_access;
create policy "admin_access admin write delete"
  on public.admin_access for delete
  using (
    public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin')
  );

-- ---------------------------------------------------------------------------
-- Bootstrap note
-- ---------------------------------------------------------------------------
-- The table starts empty, so no profile is an admin yet — meaning the RLS
-- write policies above will block everyone (including you). To seed the
-- first super-admin, run ONE of these in the Supabase SQL editor as the
-- project owner (which bypasses RLS):
--
--   insert into public.admin_access (profile_id, page, access_level)
--   values ('<your-profile-uuid>', '*', 'edit');
--
-- After that, the first admin can grant access to others through the app.
-- ---------------------------------------------------------------------------
