-- Provider document uploads: storage bucket + table + RLS.
-- Each row represents a single uploaded document for a partner.

-- 1. Storage bucket (public read; permissive write to mirror sibling buckets).
insert into storage.buckets (id, name, public)
values ('provider-documents', 'provider-documents', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "provider-documents read" on storage.objects;
create policy "provider-documents read"
  on storage.objects for select
  using (bucket_id = 'provider-documents');

drop policy if exists "provider-documents insert" on storage.objects;
create policy "provider-documents insert"
  on storage.objects for insert
  with check (bucket_id = 'provider-documents');

drop policy if exists "provider-documents update" on storage.objects;
create policy "provider-documents update"
  on storage.objects for update
  using (bucket_id = 'provider-documents')
  with check (bucket_id = 'provider-documents');

drop policy if exists "provider-documents delete" on storage.objects;
create policy "provider-documents delete"
  on storage.objects for delete
  using (bucket_id = 'provider-documents');

-- 2. provider_documents table — one row per uploaded document.
create table if not exists public.provider_documents (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
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
  updated_at timestamptz not null default now()
);

create index if not exists provider_documents_partner_idx
  on public.provider_documents(partner_id);
create index if not exists provider_documents_status_idx
  on public.provider_documents(status);
create index if not exists provider_documents_doc_idx
  on public.provider_documents(doc_id);

-- updated_at trigger
create or replace function public.provider_documents_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists provider_documents_touch on public.provider_documents;
create trigger provider_documents_touch
  before update on public.provider_documents
  for each row execute function public.provider_documents_touch_updated_at();

-- Auto-expire when expiry_date passes. We don't run a cron — instead, the
-- client also updates status to 'Expired' on read. The trigger handles the
-- case where an admin edits the expiry date in place.
create or replace function public.provider_documents_apply_expiry()
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

drop trigger if exists provider_documents_expiry on public.provider_documents;
create trigger provider_documents_expiry
  before insert or update on public.provider_documents
  for each row execute function public.provider_documents_apply_expiry();

-- 3. RLS — permissive like the rest of this project (auth required to write).
alter table public.provider_documents enable row level security;

drop policy if exists "provider_documents read" on public.provider_documents;
create policy "provider_documents read"
  on public.provider_documents for select
  using (true);

drop policy if exists "provider_documents insert" on public.provider_documents;
create policy "provider_documents insert"
  on public.provider_documents for insert
  to authenticated
  with check (true);

drop policy if exists "provider_documents update" on public.provider_documents;
create policy "provider_documents update"
  on public.provider_documents for update
  to authenticated
  using (true)
  with check (true);

drop policy if exists "provider_documents delete" on public.provider_documents;
create policy "provider_documents delete"
  on public.provider_documents for delete
  to authenticated
  using (true);

-- 4. Realtime
alter publication supabase_realtime add table public.provider_documents;

notify pgrst, 'reload schema';
