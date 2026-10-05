-- ============================================================================
-- 0029_vehicle_and_vehicle_documents.sql
--
-- 1) `public.vehicle` — singular-named vehicle profile table that mirrors the
--    shape of `public.profiles` / `public.partners`. This is the canonical
--    home for a vehicle's identity, ownership, service area, and onboarding
--    status. (The existing plural `public.vehicles` admin table is kept
--    untouched so legacy admin screens keep working.)
--
-- 2) `public.vehicle_documents` — mirrors `public.provider_documents` but is
--    keyed by `vehicle_id` instead of `partner_id`. Same storage bucket
--    pattern, same status / expiry triggers, same AI verification columns.
--
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. vehicle (singular) — profile-style record per vehicle
-- ---------------------------------------------------------------------------
create table if not exists public.vehicle (
  id                    uuid primary key default gen_random_uuid(),
  display_id            text unique,
  auth_user_id          uuid,
  owner_partner_id      uuid references public.partners(id) on delete set null,
  owner_partner_display_id text,
  owner_name            text,
  owner_phone           text,
  owner_ic              text,

  -- Identity
  plate                 text not null,
  make                  text,
  model                 text,
  year                  text,
  color                 text,
  vehicle_type          text,
  vin                   text,
  engine_number         text,

  -- Service area (mirrors partners)
  service_countries     text[] not null default '{}',
  service_states        text[] not null default '{}',
  service_cities        text[] not null default '{}',
  partner_types         text[] not null default '{}',

  -- Profile extras
  avatar_url            text,
  address               text,
  notes                 text,
  onboarding_step       text,

  -- Lifecycle
  status                partner_status not null default 'unapproved',
  permit                permit_status  not null default 'pending',
  documents_ok          boolean not null default false,
  joined_at             timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create unique index if not exists vehicle_plate_key      on public.vehicle(plate);
create index if not exists vehicle_status_idx            on public.vehicle(status);
create index if not exists vehicle_permit_idx            on public.vehicle(permit);
create index if not exists vehicle_owner_partner_idx     on public.vehicle(owner_partner_id);
create index if not exists vehicle_auth_user_idx         on public.vehicle(auth_user_id);

-- updated_at trigger (reuses the shared helper from earlier migrations)
drop trigger if exists trg_vehicle_updated_at on public.vehicle;
create trigger trg_vehicle_updated_at
  before update on public.vehicle
  for each row execute function public.set_updated_at();

-- RLS — permissive, matching partners / vehicles
alter table public.vehicle enable row level security;

drop policy if exists "vehicle read"   on public.vehicle;
drop policy if exists "vehicle insert" on public.vehicle;
drop policy if exists "vehicle update" on public.vehicle;
drop policy if exists "vehicle delete" on public.vehicle;

create policy "vehicle read"
  on public.vehicle for select
  using (true);

create policy "vehicle insert"
  on public.vehicle for insert
  to public
  with check (true);

create policy "vehicle update"
  on public.vehicle for update
  to public
  using (true)
  with check (true);

create policy "vehicle delete"
  on public.vehicle for delete
  to public
  using (true);

grant select, insert, update, delete on public.vehicle to anon, authenticated;

-- Realtime
do $$
begin
  alter publication supabase_realtime add table public.vehicle;
exception when duplicate_object then null;
end$$;
alter table public.vehicle replica identity full;


-- ---------------------------------------------------------------------------
-- 2. vehicle_documents — mirrors provider_documents but keyed by vehicle_id
-- ---------------------------------------------------------------------------

-- Storage bucket
insert into storage.buckets (id, name, public)
values ('vehicle-documents', 'vehicle-documents', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "vehicle-documents read" on storage.objects;
create policy "vehicle-documents read"
  on storage.objects for select
  using (bucket_id = 'vehicle-documents');

drop policy if exists "vehicle-documents insert" on storage.objects;
create policy "vehicle-documents insert"
  on storage.objects for insert
  with check (bucket_id = 'vehicle-documents');

drop policy if exists "vehicle-documents update" on storage.objects;
create policy "vehicle-documents update"
  on storage.objects for update
  using (bucket_id = 'vehicle-documents')
  with check (bucket_id = 'vehicle-documents');

drop policy if exists "vehicle-documents delete" on storage.objects;
create policy "vehicle-documents delete"
  on storage.objects for delete
  using (bucket_id = 'vehicle-documents');

-- Table
create table if not exists public.vehicle_documents (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicle(id) on delete cascade,
  partner_id uuid references public.partners(id) on delete set null,
  auth_user_id uuid,
  doc_id text not null,            -- references settings_entries id for required-documents
  doc_name text not null,
  document_number text,
  insurance_provider_id text,
  insurance_provider_name text,
  is_pwd boolean not null default false,
  start_date date,
  expiry_date date,
  file_url text,                   -- front (or single) image
  file_url_back text,              -- back image when requireFrontBack = true
  status text not null default 'Pending Review'
    check (status in ('Approved', 'Pending Review', 'Rejected', 'Expired')),
  reviewer_notes text,
  reviewed_at timestamptz,
  uploaded_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- AI verification (mirrors provider_documents)
  ai_verification jsonb,
  ai_verified boolean,
  issuance_country text,
  detected_document_name text
);

create index if not exists vehicle_documents_vehicle_idx
  on public.vehicle_documents(vehicle_id);
create index if not exists vehicle_documents_partner_idx
  on public.vehicle_documents(partner_id);
create index if not exists vehicle_documents_status_idx
  on public.vehicle_documents(status);
create index if not exists vehicle_documents_doc_idx
  on public.vehicle_documents(doc_id);

-- updated_at trigger
create or replace function public.vehicle_documents_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists vehicle_documents_touch on public.vehicle_documents;
create trigger vehicle_documents_touch
  before update on public.vehicle_documents
  for each row execute function public.vehicle_documents_touch_updated_at();

-- Auto-expire (same pattern as provider_documents)
create or replace function public.vehicle_documents_apply_expiry()
returns trigger language plpgsql as $$
begin
  if new.expiry_date is not null and new.expiry_date < current_date then
    if new.status not in ('Rejected') then
      new.status = 'Expired';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists vehicle_documents_expiry on public.vehicle_documents;
create trigger vehicle_documents_expiry
  before insert or update on public.vehicle_documents
  for each row execute function public.vehicle_documents_apply_expiry();

-- RLS — permissive, same as provider_documents
alter table public.vehicle_documents enable row level security;

drop policy if exists "vehicle_documents read"   on public.vehicle_documents;
drop policy if exists "vehicle_documents insert" on public.vehicle_documents;
drop policy if exists "vehicle_documents update" on public.vehicle_documents;
drop policy if exists "vehicle_documents delete" on public.vehicle_documents;

create policy "vehicle_documents read"
  on public.vehicle_documents for select
  using (true);

create policy "vehicle_documents insert"
  on public.vehicle_documents for insert
  to authenticated
  with check (true);

create policy "vehicle_documents update"
  on public.vehicle_documents for update
  to authenticated
  using (true)
  with check (true);

create policy "vehicle_documents delete"
  on public.vehicle_documents for delete
  to authenticated
  using (true);

grant select, insert, update, delete on public.vehicle_documents to anon, authenticated;

-- Realtime
do $$
begin
  alter publication supabase_realtime add table public.vehicle_documents;
exception when duplicate_object then null;
end$$;
alter table public.vehicle_documents replica identity full;

notify pgrst, 'reload schema';
