-- ============================================================================
-- 0014_vehicles_table.sql
-- Adds the `public.vehicles` table (fleet of cars/bikes managed in the admin
-- panel under admin-vehicles-*.tsx), opens writes to the `public` role (same
-- pattern as partners / settings_entries / admin_access), adds the table to
-- the supabase_realtime publication so admin screens stay live, and seeds the
-- canonical demo set so a fresh project boots with sample data.
--
-- Safe to re-run.
-- ============================================================================

-- ---- Table ----------------------------------------------------------------
create table if not exists public.vehicles (
  id                 uuid primary key default gen_random_uuid(),
  display_id         text unique,
  partner_id         uuid references public.partners(id) on delete set null,
  partner_display_id text,
  plate              text not null,
  make               text not null,
  model              text not null,
  year               text,
  color              text,
  vehicle_type       text,
  owner_name         text not null,
  owner_phone        text not null,
  status             partner_status not null default 'unapproved',
  permit             permit_status  not null default 'pending',
  documents_ok       boolean not null default false,
  joined_at          timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists vehicles_status_idx  on public.vehicles(status);
create index if not exists vehicles_permit_idx  on public.vehicles(permit);
create index if not exists vehicles_plate_idx   on public.vehicles(plate);
create index if not exists vehicles_partner_idx on public.vehicles(partner_id);

-- updated_at trigger
drop trigger if exists trg_vehicles_updated_at on public.vehicles;
create trigger trg_vehicles_updated_at
  before update on public.vehicles
  for each row execute function public.set_updated_at();

-- ---- RLS ------------------------------------------------------------------
alter table public.vehicles enable row level security;

drop policy if exists "vehicles read"   on public.vehicles;
drop policy if exists "vehicles insert" on public.vehicles;
drop policy if exists "vehicles update" on public.vehicles;
drop policy if exists "vehicles delete" on public.vehicles;

create policy "vehicles read"
  on public.vehicles for select
  using (true);

create policy "vehicles insert"
  on public.vehicles for insert
  to public
  with check (true);

create policy "vehicles update"
  on public.vehicles for update
  to public
  using (true)
  with check (true);

create policy "vehicles delete"
  on public.vehicles for delete
  to public
  using (true);

grant select, insert, update, delete on public.vehicles to anon, authenticated;

-- ---- Realtime -------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.vehicles;
exception when duplicate_object then null;
end$$;
alter table public.vehicles replica identity full;

-- ---- Seed (only if table is empty) ----------------------------------------
insert into public.vehicles
  (display_id, partner_display_id, plate, make, model, year, color, vehicle_type, owner_name, owner_phone, status, permit, documents_ok, joined_at)
select * from (values
  ('VH-3001','DR-1001','WPK 1234','Perodua','Bezza','2022','White','Sedan',    'Ahmad Faizal',   '+60 12-345 6781','approved'::partner_status,           'verified'::permit_status,    true,  '2023-01-12'::timestamptz),
  ('VH-3002','DR-1002','VBA 8821','Honda',  'City', '2021','Silver','Sedan',   'Siti Nurhaliza', '+60 13-887 1102','approved'::partner_status,           'verified'::permit_status,    true,  '2023-04-18'::timestamptz),
  ('VH-3003','DR-1003','JKL 5512','Toyota', 'Vios', '2023','Red','Sedan',      'Rajesh Kumar',   '+60 11-220 9911','unapproved'::partner_status,         'pending'::permit_status,     true,  '2026-04-22'::timestamptz),
  ('VH-3004','DR-1004','PMR 7733','Proton', 'Saga', '2020','Black','Sedan',    'Lim Wei Jie',    '+60 16-554 1188','unapproved'::partner_status,         'pending'::permit_status,     false, '2026-04-28'::timestamptz),
  ('VH-3005','DR-1005','WXR 4421','Perodua','Myvi', '2019','Blue','Hatchback', 'Nor Aisyah',     '+60 19-220 7741','blocked'::partner_status,            'verified'::permit_status,    true,  '2024-06-04'::timestamptz),
  ('VH-3006','DR-1006','BNN 1245','Toyota', 'Avanza','2018','Grey','MPV',      'Chong Kar Mun',  '+60 12-991 4422','rejected'::partner_status,           'non-verified'::permit_status,false, '2026-03-08'::timestamptz),
  ('VH-3007','DR-1007','WTK 2210','Hyundai','Starex','2017','White','Van',     'Hafiz Rahman',   '+60 17-882 3320','unapproved-docs'::partner_status,    'non-verified'::permit_status,false, '2026-04-30'::timestamptz),
  ('VH-3008','DR-1008','JTH 9912','Perodua','Axia','2022','Yellow','Hatchback','Tan Mei Ling',   '+60 18-554 0091','permit-pending'::partner_status,     'pending'::permit_status,     true,  '2025-12-11'::timestamptz),
  ('VH-3009','DR-1009','WJK 4421','Proton', 'X50',  '2023','Black','SUV',      'Kasim Ali',      '+60 11-441 8821','permit-non-verified'::partner_status,'non-verified'::permit_status,true,  '2025-10-02'::timestamptz),
  ('VH-3010','DR-1010','BPK 5520','Honda',  'BRV',  '2021','Silver','SUV',     'Vincent Ng',     '+60 12-887 0021','permit-verified'::partner_status,    'verified'::permit_status,    true,  '2022-09-15'::timestamptz)
) as v(display_id, partner_display_id, plate, make, model, year, color, vehicle_type, owner_name, owner_phone, status, permit, documents_ok, joined_at)
where not exists (select 1 from public.vehicles);
