-- ============================================================================
-- Seed data — mirrors the in-app AsyncStorage defaults so a fresh Supabase
-- project boots with the same baseline the app already knows.
-- Run AFTER schema.sql. Safe to re-run; uses ON CONFLICT DO NOTHING where
-- possible. For settings_entries we delete-then-insert per category so
-- re-running gives a clean baseline.
-- ============================================================================

-- ---- App settings ---------------------------------------------------------
-- device_account_guard: sign-up device guard (migrations 0072/0074). Defaults
-- match device_guard_config() — cumulative cap on, emulator block off. The
-- server functions default gracefully if this row is absent; seeding it just
-- makes the baseline explicit and editable from the admin panel on day one.
insert into public.app_settings (key, value) values
  ('app',            jsonb_build_object('name','GET.ride','supportEmail','support@getride.my')),
  ('theme.light',    jsonb_build_object('primary','#0A84FF','background','#FFFFFF','text','#0B0B0F')),
  ('theme.dark',     jsonb_build_object('primary','#0A84FF','background','#0B0B0F','text','#FFFFFF')),
  ('splash',         jsonb_build_object('background','#0B0B0F','image',null)),
  ('icons',          jsonb_build_object('appIcon',null,'adaptiveIcon',null)),
  ('defaultLocation',jsonb_build_object('lat',3.139,'lng',101.6869,'label','Kuala Lumpur')),
  ('device_account_guard', jsonb_build_object('enabled',true,'maxAccountsPerDevice',3,'blockEmulators',false))
on conflict (key) do nothing;

-- ---- Settings entries -----------------------------------------------------
-- Keep this list aligned with AdminDataContext SEED_ENTRIES categories.
delete from public.settings_entries where category in (
  'vehicle-type','required-documents','service-settings','site-settings',
  'payment-type','referral-settings','referral-tree','rides','promocode-list',
  'free-ride','fixed-price','partner-type'
);

insert into public.settings_entries (category, position, values) values
  ('vehicle-type', 1, jsonb_build_object('name','Sedan','capacity',4,'baseFare',5)),
  ('vehicle-type', 2, jsonb_build_object('name','SUV','capacity',6,'baseFare',8)),
  ('vehicle-type', 3, jsonb_build_object('name','MPV','capacity',7,'baseFare',9)),

  ('required-documents', 1, jsonb_build_object('name','Driving License','required',true)),
  ('required-documents', 2, jsonb_build_object('name','Vehicle Insurance','required',true)),
  ('required-documents', 3, jsonb_build_object('name','PSV Permit','required',false)),

  ('service-settings', 1, jsonb_build_object('name','Car','description','Standard car service','displayPriority',1,'active',true,'isDefault',true)),
  ('service-settings', 2, jsonb_build_object('name','Bike','description','Motorbike service','displayPriority',2,'active',true,'isDefault',true)),
  ('service-settings', 3, jsonb_build_object('name','Auto','description','Auto rickshaw service','displayPriority',3,'active',true,'isDefault',true)),
  ('service-settings', 4, jsonb_build_object('name','Delivery','description','Parcel & courier delivery','displayPriority',4,'active',true,'isDefault',true)),
  ('service-settings', 5, jsonb_build_object('name','Food','description','Food ordering & delivery','displayPriority',5,'active',true,'isDefault',true)),
  ('service-settings', 6, jsonb_build_object('name','Mart','description','Grocery & mart delivery','displayPriority',6,'active',true,'isDefault',true)),

  ('site-settings', 1, jsonb_build_object('name','App Name','value','GET.ride')),
  ('site-settings', 2, jsonb_build_object('name','Support Email','value','support@getride.my')),

  ('payment-type', 1, jsonb_build_object('name','Cash','enabled',true)),
  ('payment-type', 2, jsonb_build_object('name','Card','enabled',true)),
  ('payment-type', 3, jsonb_build_object('name','Wallet','enabled',false)),

  ('referral-settings', 1, jsonb_build_object('name','User Referral','reward',10)),
  ('referral-settings', 2, jsonb_build_object('name','Driver Referral','reward',25)),

  ('referral-tree', 1, jsonb_build_object('name','Level 1','percentage',10)),
  ('referral-tree', 2, jsonb_build_object('name','Level 2','percentage',5)),

  ('rides', 1, jsonb_build_object('name','Cancellation Fee','value',5)),
  ('rides', 2, jsonb_build_object('name','Wait Time Limit','value',5)),

  ('promocode-list', 1, jsonb_build_object('code','WELCOME10','discount',10)),
  ('promocode-list', 2, jsonb_build_object('code','RIDE5','discount',5)),

  ('free-ride', 1, jsonb_build_object('name','First Ride Free','limit',1)),
  ('fixed-price', 1, jsonb_build_object('from','KLIA','to','KL Sentral','price',75)),

  -- partner-type defaults: isDefault=true marks them as non-deletable in the admin UI.
  -- Delete only from Supabase directly (or unset isDefault first).
  ('partner-type', 1, jsonb_build_object('name','Dealer',          'enabled',true,'subServicesEnabled',false,'subServicesJson','[]','displayPriority',1,'isDefault',true)),
  ('partner-type', 2, jsonb_build_object('name','Delivery',        'enabled',true,'subServicesEnabled',true, 'subServicesJson','[]','displayPriority',2,'isDefault',true)),
  ('partner-type', 3, jsonb_build_object('name','eHailing',        'enabled',true,'subServicesEnabled',false,'subServicesJson','[]','displayPriority',3,'isDefault',true)),
  ('partner-type', 4, jsonb_build_object('name','Fleet',           'enabled',true,'subServicesEnabled',false,'subServicesJson','[]','displayPriority',4,'isDefault',true)),
  ('partner-type', 5, jsonb_build_object('name','pHailing',        'enabled',true,'subServicesEnabled',false,'subServicesJson','[]','displayPriority',5,'isDefault',true)),
  ('partner-type', 6, jsonb_build_object('name','Service Provider','enabled',true,'subServicesEnabled',true, 'subServicesJson','[]','displayPriority',6,'isDefault',true)),
  ('partner-type', 7, jsonb_build_object('name','Teksi',           'enabled',true,'subServicesEnabled',false,'subServicesJson','[]','displayPriority',7,'isDefault',true));

-- ---- Vehicles -------------------------------------------------------------
-- Mirrors AdminDataContext SEED_VEHICLES so a fresh project boots with the
-- same demo fleet. Only inserts when the table is empty so re-running this
-- seed against an existing database is non-destructive.
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

-- ---- Vehicle make/model catalog -----------------------------------------
-- The full 1494-row catalog is seeded by migration
-- 0015_vehicle_make_models_table.sql so the data exists from day one,
-- independent of the app. seed.sql intentionally does NOT duplicate that
-- payload; run the migration to populate the catalog.
