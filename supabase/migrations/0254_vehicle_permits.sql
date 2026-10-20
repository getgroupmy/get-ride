-- ============================================================================
-- 0254: Permits per country -- vehicle and driver permits, bypass,
-- enforcement, passenger display, plate colours and expiry reminders
--
-- Nothing about any one country's permits is written into the logic: each
-- country's permits are rows an admin keeps (Admin -> People -> Vehicle
-- permits). Malaysia is only seed data at the end of this file.
--
--   * permit_types: per country, a permit an e-hailing / taxi vehicle or its
--     driver must hold -- names (English, local, short), issuer, vehicle or
--     driver, the partner types and vehicle services it is for (empty: all),
--     its fields ({key, label, label_local, kind text|date, role
--     ''|number|valid_from|valid_until|plate, passenger}), who uploads it (admin /
--     driver / either), whether passengers see it and whether it counts
--     towards enforcement. A vehicle permit is a vehicle_documents row tied
--     to its type (permit_type_id, permit_fields); a driver permit is the
--     driver's upload of the Required Document the type names (document_id).
--   * permit_country_settings: per country (and '*' for every country
--     without a row of its own): "Require vehicle permits" (enforce, default
--     off), the bypass length in days (default 3), plate colours and the
--     reminder texts.
--   * Which country: the vehicle's registration region (its own service
--     area, else its owner's -- ptr_vehicle_context, as the partner type
--     rules use), and for a driver permit the partner's service area. It is
--     what the permit is issued against, it is known before any ride and it
--     does not change with where a trip starts.
--   * Status per vehicle: with / without / expired / bypass (and none when
--     no required permit applies). A permit counts once an admin approved
--     it (an admin's own upload is approved) until its valid-until date.
--     Bypass: vehicle.permit_bypass_until, set by an admin for the country's
--     bypass days; it ends by itself.
--   * Enforcement, only in a country whose switch is on, for a vehicle
--     without or with an expired required permit and no bypass (or a driver
--     missing a required driver permit): kept offline (driver_presence),
--     open requests hidden, pushes and offers skipped, bids, takes,
--     scheduled accepts and handovers refused (VEHICLE_PERMIT_REQUIRED).
--     The meter (street hail) is not touched.
--   * Passengers: ride_requests carries the vehicle (partner_vehicle_id),
--     its energy, partner types and plate colours, stamped with the driver's
--     card. ride_permits(ride) gives the ride's rider, from acceptance to
--     the end of the trip, the permits shown to passengers (valid ones,
--     passenger fields only) and their files; a storage rule lets that rider
--     read those files only.
--   * Expiry reminders for every document (driver and vehicle): days before
--     expiry from document_reminder_days (default, per country, per permit
--     type or required document), sent once each (document_expiry_reminders)
--     by a daily job, plus the day it expires.
-- ============================================================================

-- ---- 1. Settings per country ------------------------------------------------------------------

-- A plate colour list: {types: [{type, bg, fg}], energies: [{energy, bg, fg}], other: {bg, fg}}.
create or replace function public.permit_plate_colours_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is null or (
    jsonb_typeof(p) = 'object'
    and pg_column_size(p) <= 16384
    and (p->'types' is null or (jsonb_typeof(p->'types') = 'array' and jsonb_array_length(p->'types') <= 30))
    and (p->'energies' is null or (jsonb_typeof(p->'energies') = 'array' and jsonb_array_length(p->'energies') <= 30))
    and not exists (
      select 1
        from jsonb_array_elements(coalesce(p->'types', '[]'::jsonb) || coalesce(p->'energies', '[]'::jsonb)
                                  || case when p->'other' is null then '[]'::jsonb else jsonb_build_array(p->'other') end) e
       where jsonb_typeof(e) <> 'object'
          or coalesce(e->>'bg', '') !~ '^#[0-9A-Fa-f]{6}$'
          or coalesce(e->>'fg', '') !~ '^#[0-9A-Fa-f]{6}$')
  );
$$;

create table if not exists public.permit_country_settings (
  country      text primary key,
  enforce      boolean not null default false,
  bypass_days  integer not null default 3,
  plate_colours jsonb,
  texts        jsonb not null default '{}'::jsonb,
  updated_at   timestamptz not null default now(),
  constraint permit_country_settings_country check (char_length(btrim(country)) between 1 and 120),
  constraint permit_country_settings_bypass check (bypass_days between 1 and 60),
  constraint permit_country_settings_colours check (public.permit_plate_colours_valid(plate_colours)),
  constraint permit_country_settings_texts check (jsonb_typeof(texts) = 'object' and pg_column_size(texts) <= 8192)
);
comment on table public.permit_country_settings is
  'Per country (''*'': every country without its own row): require permits (enforce), bypass days, plate colours, reminder texts (0254).';

-- ---- 2. Permit types --------------------------------------------------------------------------

-- A field list: [{key, label, label_local, kind, role, passenger}], at most
-- one field per role, dates for the two validity roles.
create or replace function public.permit_fields_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) <= 20
     and pg_column_size(p) <= 16384
     and not exists (
       select 1 from jsonb_array_elements(p) f
        where jsonb_typeof(f) <> 'object'
           or coalesce(f->>'key', '') !~ '^[a-z0-9_]{1,40}$'
           or char_length(btrim(coalesce(f->>'label', ''))) not between 1 and 80
           or char_length(coalesce(f->>'label_local', '')) > 80
           or coalesce(f->>'kind', 'text') not in ('text', 'date')
           or coalesce(f->>'role', '') not in ('', 'number', 'valid_from', 'valid_until', 'plate')
           or (coalesce(f->>'role', '') in ('valid_from', 'valid_until') and coalesce(f->>'kind', 'text') <> 'date'))
     and (select count(distinct f->>'key') from jsonb_array_elements(p) f) = jsonb_array_length(p)
     and not exists (
       select 1 from jsonb_array_elements(p) f
        where coalesce(f->>'role', '') <> ''
        group by f->>'role' having count(*) > 1);
$$;

create table if not exists public.permit_types (
  id                  uuid primary key default gen_random_uuid(),
  country             text not null,
  key                 text not null,
  name                text not null,
  name_local          text not null default '',
  short_name          text not null default '',
  issuer              text not null default '',
  applies_to          text not null default 'vehicle',
  partner_types       text[] not null default '{}',
  services            text[] not null default '{}',
  fields              jsonb not null default '[]'::jsonb,
  uploader            text not null default 'admin',
  shown_to_passengers boolean not null default true,
  required            boolean not null default false,
  document_id         text,
  renewal_text        text not null default '',
  position            integer not null default 0,
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint permit_types_country check (char_length(btrim(country)) between 1 and 120 and country <> '*'),
  constraint permit_types_key check (key ~ '^[a-z0-9-]{1,40}$'),
  constraint permit_types_names check (char_length(btrim(name)) between 1 and 120
                                       and char_length(name_local) <= 120 and char_length(short_name) <= 40
                                       and char_length(issuer) <= 80 and char_length(renewal_text) <= 300),
  constraint permit_types_applies check (applies_to in ('vehicle', 'driver')),
  constraint permit_types_uploader check (uploader in ('admin', 'driver', 'either')),
  constraint permit_types_lists check (coalesce(cardinality(partner_types), 0) <= 30 and coalesce(cardinality(services), 0) <= 60),
  constraint permit_types_fields check (public.permit_fields_valid(fields)),
  constraint permit_types_document check (document_id is null or char_length(document_id) <= 64)
);
create unique index if not exists permit_types_country_key on public.permit_types (lower(btrim(country)), key);
comment on table public.permit_types is
  'Per country: a permit a vehicle or its driver holds for e-hailing / taxi rides; its fields, uploader, passenger display and enforcement (0254).';

-- ---- 3. Where the permits are kept ------------------------------------------------------------
alter table public.vehicle_documents add column if not exists permit_type_id uuid
  references public.permit_types(id) on delete set null;
alter table public.vehicle_documents add column if not exists permit_fields jsonb;
alter table public.provider_documents add column if not exists permit_fields jsonb;
create index if not exists vehicle_documents_permit_type_idx on public.vehicle_documents(permit_type_id);
create unique index if not exists vehicle_documents_one_permit
  on public.vehicle_documents (vehicle_id, permit_type_id) where permit_type_id is not null;
alter table public.vehicle_documents drop constraint if exists vehicle_documents_permit_fields;
alter table public.vehicle_documents add constraint vehicle_documents_permit_fields
  check (permit_fields is null or (jsonb_typeof(permit_fields) = 'object' and pg_column_size(permit_fields) <= 8192));
alter table public.provider_documents drop constraint if exists provider_documents_permit_fields;
alter table public.provider_documents add constraint provider_documents_permit_fields
  check (permit_fields is null or (jsonb_typeof(permit_fields) = 'object' and pg_column_size(permit_fields) <= 8192));

-- The vehicle's energy (from its make & model when not set) and its bypass.
alter table public.vehicle add column if not exists energy_type text;
alter table public.vehicle add column if not exists permit_bypass_until timestamptz;
alter table public.vehicle add column if not exists permit_bypass_set_at timestamptz;
alter table public.vehicle add column if not exists permit_bypass_set_by uuid;
alter table public.vehicle drop constraint if exists vehicle_energy_type_len;
alter table public.vehicle add constraint vehicle_energy_type_len check (coalesce(char_length(energy_type), 0) <= 40);

-- ---- 4. Expiry reminder days and what was sent ---------------------------------------------------
create table if not exists public.document_reminder_days (
  id        uuid primary key default gen_random_uuid(),
  scope     text not null,
  scope_key text not null default '',
  days      integer[] not null,
  updated_at timestamptz not null default now(),
  constraint document_reminder_days_scope check (scope in ('default', 'country', 'permit_type', 'document')),
  constraint document_reminder_days_key check ((scope = 'default') = (scope_key = '') and char_length(scope_key) <= 120),
  constraint document_reminder_days_days check (
    coalesce(cardinality(days), 0) <= 20 and 0 <= all(days) and 400 >= all(days)),
  constraint document_reminder_days_one unique (scope, scope_key)
);
comment on table public.document_reminder_days is
  'Days before a document expires that its holder is reminded: the default, per country, per permit type, per required document (0254).';

create table if not exists public.document_expiry_reminders (
  id          uuid primary key default gen_random_uuid(),
  doc_table   text not null check (doc_table in ('vehicle_documents', 'provider_documents')),
  doc_id      uuid not null,
  expiry_date date not null,
  days_before integer not null,
  profile_id  uuid,
  sent_at     timestamptz not null default now(),
  constraint document_expiry_reminders_once unique (doc_table, doc_id, expiry_date, days_before)
);
create index if not exists document_expiry_reminders_sent_idx on public.document_expiry_reminders (sent_at desc);
comment on table public.document_expiry_reminders is
  'Each expiry reminder sent, so none goes twice (0254).';

-- ---- 5. Who reads and writes ---------------------------------------------------------------------
insert into public.admin_table_pages (target, page)
select m.target, u.page
  from (values
    ('permit_types',             array['admin-vehicle-permits']),
    ('permit_country_settings',  array['admin-vehicle-permits']),
    ('document_reminder_days',   array['admin-vehicle-permits']),
    ('rpc:vehicle_permit_bypass', array['admin-vehicle-permits', 'admin-vehicles', 'admin-vehicle-edit']),
    ('vehicle_documents',        array['admin-vehicle-permits']),
    ('storage:vehicle-documents', array['admin-vehicle-permits'])
  ) as m(target, pages)
  cross join lateral unnest(m.pages) as u(page)
on conflict do nothing;

alter table public.permit_country_settings enable row level security;
alter table public.permit_types enable row level security;
alter table public.document_reminder_days enable row level security;
alter table public.document_expiry_reminders enable row level security;
revoke all on public.permit_country_settings, public.permit_types, public.document_reminder_days,
  public.document_expiry_reminders from anon;
grant select, insert, update, delete on public.permit_country_settings, public.permit_types,
  public.document_reminder_days to authenticated;
revoke all on public.document_expiry_reminders from authenticated;
grant select on public.document_expiry_reminders to authenticated;

do $pol$
declare
  t text;
begin
  foreach t in array array['permit_country_settings', 'permit_types', 'document_reminder_days'] loop
    execute format('drop policy if exists %I on public.%I', t || ' admin insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin insert', t, t);
    execute format('drop policy if exists %I on public.%I', t || ' admin update', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.caller_admin_can_write(%L))) with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin update', t, t, t);
    execute format('drop policy if exists %I on public.%I', t || ' admin delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.caller_admin_can_write(%L)))',
                   t || ' admin delete', t, t);
  end loop;
end
$pol$;

-- Permit types and country settings are read by the apps (names, plate colours).
drop policy if exists "permit_country_settings read" on public.permit_country_settings;
create policy "permit_country_settings read" on public.permit_country_settings for select to authenticated using (true);
drop policy if exists "permit_types read" on public.permit_types;
create policy "permit_types read" on public.permit_types for select to authenticated using (true);
drop policy if exists "document_reminder_days admin read" on public.document_reminder_days;
create policy "document_reminder_days admin read" on public.document_reminder_days for select to authenticated
  using ((select public.caller_is_admin()));
drop policy if exists "document_expiry_reminders admin read" on public.document_expiry_reminders;
create policy "document_expiry_reminders admin read" on public.document_expiry_reminders for select to authenticated
  using ((select public.caller_is_admin()));

create or replace function public.permit_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.permit_touch_updated_at() from public, anon, authenticated;
drop trigger if exists trg_permit_types_touch on public.permit_types;
create trigger trg_permit_types_touch before update on public.permit_types
  for each row execute function public.permit_touch_updated_at();
drop trigger if exists trg_permit_country_settings_touch on public.permit_country_settings;
create trigger trg_permit_country_settings_touch before update on public.permit_country_settings
  for each row execute function public.permit_touch_updated_at();
drop trigger if exists trg_document_reminder_days_touch on public.document_reminder_days;
create trigger trg_document_reminder_days_touch before update on public.document_reminder_days
  for each row execute function public.permit_touch_updated_at();

-- ---- 6. Helpers ------------------------------------------------------------------------------------

-- A country's settings: its own row, else '*', else the column defaults.
create or replace function public.permit_settings_for(p_country text)
returns public.permit_country_settings
language sql
stable
security definer
set search_path = public
as $$
  select s from (
    select s, 0 as o from public.permit_country_settings s
     where public.ptr_name(s.country) = public.ptr_name(p_country) and p_country is not null
    union all
    select s, 1 from public.permit_country_settings s where s.country = '*'
    union all
    select row(coalesce(p_country, '*'), false, 3, null, '{}'::jsonb, now())::public.permit_country_settings, 2
  ) x order by o limit 1;
$$;

-- Whether a permit type covers partner types [p_types] and vehicle service [p_service].
create or replace function public.permit_type_covers(
  p_list text[], p_services text[], p_types text[], p_service text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (coalesce(cardinality(p_list), 0) = 0
          or exists (select 1 from unnest(p_list) a, unnest(coalesce(p_types, '{}')) b
                      where public.ptr_key(a) = public.ptr_key(b)))
     and (coalesce(cardinality(p_services), 0) = 0 or coalesce(p_service, '') = any (p_services));
$$;

-- The storage path of a stored file URL in [p_bucket], or null.
create or replace function public.storage_path_in(p_url text, p_bucket text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(substring(coalesce(p_url, '')
                from '/storage/v1/object/(?:public|sign|authenticated)/' || p_bucket || '/([^?#]+)'), '');
$$;

-- The vehicle's energy: its own, else its make & model's when the catalogue
-- has one answer for it.
create or replace function public.vehicle_energy(p_vehicle uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    nullif(btrim(v.energy_type), ''),
    (select min(m.energy_type) from public.vehicle_make_models m
      where lower(btrim(m.make)) = lower(btrim(v.make)) and lower(btrim(m.model)) = lower(btrim(v.model))
        and (nullif(btrim(v.vehicle_type), '') is null or lower(btrim(m.vehicle_type)) = lower(btrim(v.vehicle_type)))
     having count(distinct lower(btrim(m.energy_type))) = 1))
    from public.vehicle v where v.id = p_vehicle;
$$;

-- The plate's colours in a country: the first partner type listed that the
-- vehicle has, else its energy, else "other"; null without a colour list.
create or replace function public.permit_plate_colours(p_country text, p_types text[], p_energy text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c jsonb := (public.permit_settings_for(p_country)).plate_colours;
  e jsonb;
begin
  if c is null then
    select s.plate_colours into c from public.permit_country_settings s where s.country = '*';
  end if;
  if c is null then
    return null;
  end if;
  for e in select x from jsonb_array_elements(coalesce(c->'types', '[]'::jsonb)) x loop
    if exists (select 1 from unnest(coalesce(p_types, '{}')) t where public.ptr_key(t) = public.ptr_key(e->>'type')) then
      return jsonb_build_object('bg', e->>'bg', 'fg', e->>'fg');
    end if;
  end loop;
  for e in select x from jsonb_array_elements(coalesce(c->'energies', '[]'::jsonb)) x loop
    if lower(btrim(coalesce(p_energy, ''))) = lower(btrim(coalesce(e->>'energy', ''))) and btrim(coalesce(p_energy, '')) <> '' then
      return jsonb_build_object('bg', e->>'bg', 'fg', e->>'fg');
    end if;
  end loop;
  if c->'other' is not null then
    return jsonb_build_object('bg', c->'other'->>'bg', 'fg', c->'other'->>'fg');
  end if;
  return null;
end;
$$;

-- A permit's field values: each field's own value, the validity dates from
-- the document's dates, else what the AI read for that field.
create or replace function public.permit_field_values(p_fields jsonb, p_doc jsonb, p_passenger_only boolean)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', f->>'key', 'label', f->>'label', 'label_local', coalesce(f->>'label_local', ''),
           'kind', coalesce(f->>'kind', 'text'), 'role', coalesce(f->>'role', ''),
           'value', coalesce(
             case f->>'role' when 'valid_from' then p_doc->>'start_date'
                             when 'valid_until' then p_doc->>'expiry_date' end,
             nullif(btrim(p_doc->'permit_fields'->>(f->>'key')), ''),
             case when f->>'role' = 'number' then nullif(btrim(p_doc->>'document_number'), '') end,
             nullif(btrim(p_doc->'ai_verification'->'extracted'->'permitFields'->>(f->>'key')), ''))
         ) order by n), '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) with ordinality as x(f, n)
   where not p_passenger_only or coalesce((f->>'passenger')::boolean, false);
$$;

-- A permit document's state: with (approved, in date), expired, pending
-- (waiting for review), without.
create or replace function public.permit_doc_state(p_status text, p_expiry date)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_status is null or p_status = 'Rejected' then 'without'
    when p_status = 'Expired' or (p_expiry is not null and p_expiry < current_date) then 'expired'
    when p_status = 'Approved' then 'with'
    else 'pending' end;
$$;

-- ---- 7. A vehicle's permits and status -----------------------------------------------------------
create or replace function public.vehicle_permit_rows(p_vehicle uuid)
returns table (type_id uuid, country text, required boolean, enforce boolean, state text,
               document_id uuid, valid_until date)
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select v.id, public.ptr_vehicle_context(v.id) as ctx,
           coalesce(nullif(v.service_approved_id, ''), v.service_id) as service
      from public.vehicle v where v.id = p_vehicle
  )
  select t.id, t.country, t.required, (public.permit_settings_for(t.country)).enforce,
         public.permit_doc_state(d.status, d.expiry_date), d.id, d.expiry_date
    from v
    join public.permit_types t
      on t.active and t.applies_to = 'vehicle'
     and exists (select 1 from unnest(public.ptr_text_array(v.ctx->'countries')) c
                  where public.ptr_name(c) = public.ptr_name(t.country))
     and public.permit_type_covers(t.partner_types, t.services, public.ptr_text_array(v.ctx->'types'), v.service)
    left join lateral (
      select d.id, d.status, d.expiry_date from public.vehicle_documents d
       where d.vehicle_id = v.id and d.permit_type_id = t.id
       order by d.uploaded_at desc limit 1
    ) d on true;
$$;

-- with / without / expired / bypass, or none (no required permit applies).
create or replace function public.vehicle_permit_status(p_vehicle uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_missing boolean := false;
  v_expired boolean := false;
  v_any boolean := false;
  r record;
begin
  for r in select * from public.vehicle_permit_rows(p_vehicle) where required loop
    v_any := true;
    if r.state = 'expired' then
      v_expired := true;
    elsif r.state <> 'with' then
      v_missing := true;
    end if;
  end loop;
  if not v_any then
    return 'none';
  end if;
  if not v_missing and not v_expired then
    return 'with';
  end if;
  if exists (select 1 from public.vehicle where id = p_vehicle and permit_bypass_until > now()) then
    return 'bypass';
  end if;
  return case when v_expired then 'expired' else 'without' end;
end;
$$;

-- Why the vehicle may not take rides (a country that requires permits), or null.
create or replace function public.vehicle_permit_problem(p_vehicle uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r record;
  v_plate text;
begin
  if exists (select 1 from public.vehicle where id = p_vehicle and permit_bypass_until > now()) then
    return null;
  end if;
  for r in
    select x.*, t.name from public.vehicle_permit_rows(p_vehicle) x join public.permit_types t on t.id = x.type_id
     where x.required and x.enforce and x.state <> 'with'
     order by t.position, t.name limit 1
  loop
    select plate into v_plate from public.vehicle where id = p_vehicle;
    return format('The %s for %s %s.', r.name, coalesce(v_plate, 'this vehicle'),
                  case when r.state = 'expired' then 'has expired' else 'is missing' end);
  end loop;
  return null;
end;
$$;

-- ---- 8. A driver's permits ------------------------------------------------------------------------
create or replace function public.driver_permit_rows(p_uid uuid)
returns table (type_id uuid, country text, required boolean, enforce boolean, state text,
               document_id uuid, valid_until date)
language sql
stable
security definer
set search_path = public
as $$
  with p as (
    select p.* from public.partners p where p.auth_user_id = p_uid
     order by (p.status = 'approved' or p.status::text like 'permit-%') desc, p.created_at desc limit 1
  )
  select t.id, t.country, t.required, (public.permit_settings_for(t.country)).enforce,
         public.permit_doc_state(d.status, d.expiry_date), d.id, d.expiry_date
    from p
    join public.permit_types t
      on t.active and t.applies_to = 'driver'
     and exists (select 1 from unnest(coalesce(p.service_countries, '{}')) c
                  where public.ptr_name(c) = public.ptr_name(t.country))
     and public.permit_type_covers(t.partner_types, t.services, p.partner_types, public.driver_vehicle_service(p_uid))
    left join lateral (
      select d.id, d.status, d.expiry_date from public.provider_documents d
       where d.partner_id = p.id and t.document_id is not null and d.doc_id = t.document_id
       order by d.uploaded_at desc limit 1
    ) d on true;
$$;

-- Why driver [p_uid] may not take rides now, or null: the vehicle they
-- drive (else, with none taken, all of their vehicles), then their own
-- permits. Null at once while no country requires permits.
create or replace function public.driver_permit_problem(p_uid uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vehicle uuid;
  v_why text;
  v_first text;
  v_any boolean := false;
  v_ok boolean := false;
  r record;
begin
  if p_uid is null or not exists (select 1 from public.permit_country_settings where enforce) then
    return null;
  end if;
  select s.vehicle_id into v_vehicle from public.vehicle_active_session s where s.user_id = p_uid limit 1;
  if v_vehicle is not null then
    v_why := public.vehicle_permit_problem(v_vehicle);
    if v_why is not null then
      return v_why;
    end if;
  else
    for r in
      select v.id from public.vehicle v
       where v.auth_user_id = p_uid
          or exists (select 1 from public.vehicle_user_assignment a
                      where a.vehicle_id = v.id and a.user_id = p_uid and a.is_active)
    loop
      v_any := true;
      v_why := public.vehicle_permit_problem(r.id);
      if v_why is null then
        v_ok := true;
        exit;
      end if;
      v_first := coalesce(v_first, v_why);
    end loop;
    if v_any and not v_ok then
      return v_first;
    end if;
  end if;
  for r in
    select t.name, x.state from public.driver_permit_rows(p_uid) x join public.permit_types t on t.id = x.type_id
     where x.required and x.enforce and x.state <> 'with'
     order by t.position, t.name limit 1
  loop
    return format('Your %s %s.', r.name, case when r.state = 'expired' then 'has expired' else 'is missing' end);
  end loop;
  return null;
end;
$$;

create or replace function public.caller_permit_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.driver_permit_problem(auth.uid()) is null; $$;

create or replace function public.driver_permit_assert(p_uid uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_why text := public.driver_permit_problem(p_uid);
begin
  if v_why is not null then
    raise exception 'VEHICLE_PERMIT_REQUIRED' using errcode = 'P0001', hint = v_why;
  end if;
end;
$$;

revoke execute on function public.permit_settings_for(text) from public, anon;
revoke execute on function public.vehicle_energy(uuid) from public, anon, authenticated;
revoke execute on function public.permit_plate_colours(text, text[], text) from public, anon, authenticated;
revoke execute on function public.vehicle_permit_rows(uuid) from public, anon, authenticated;
revoke execute on function public.vehicle_permit_status(uuid) from public, anon, authenticated;
revoke execute on function public.vehicle_permit_problem(uuid) from public, anon, authenticated;
revoke execute on function public.driver_permit_rows(uuid) from public, anon, authenticated;
revoke execute on function public.driver_permit_problem(uuid) from public, anon, authenticated;
revoke execute on function public.driver_permit_assert(uuid) from public, anon, authenticated;
revoke execute on function public.caller_permit_ok() from public, anon;
grant execute on function public.permit_settings_for(text), public.caller_permit_ok() to authenticated, service_role;

-- ---- 9. Who writes a permit ------------------------------------------------------------------------
-- A permit an admin uploads is written by admins only; a driver's own
-- (driver / either) goes to review as any document does.
create or replace function public.vehicle_documents_permit_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('vehicle_documents') then
    return new;
  end if;
  if exists (select 1 from public.permit_types t
              where t.id in (new.permit_type_id, case when tg_op = 'UPDATE' then old.permit_type_id end)
                and (t.uploader = 'admin' or t.applies_to <> 'vehicle')) then
    raise exception 'PERMIT_ADMIN_ONLY' using errcode = '42501',
      hint = 'This permit is uploaded by GET.ride.';
  end if;
  if tg_op = 'UPDATE' and new.permit_fields is distinct from old.permit_fields then
    new.status := 'Pending Review';
    new.reviewer_notes := null;
    new.reviewed_at := null;
  end if;
  return new;
end;
$$;
revoke execute on function public.vehicle_documents_permit_guard() from public, anon, authenticated;
drop trigger if exists trg_vehicle_documents_permit_guard on public.vehicle_documents;
create trigger trg_vehicle_documents_permit_guard
  before insert or update on public.vehicle_documents
  for each row execute function public.vehicle_documents_permit_guard();

-- The bypass is set through vehicle_permit_bypass only.
create or replace function public.vehicle_permit_bypass_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
     and (new.permit_bypass_until, new.permit_bypass_set_at, new.permit_bypass_set_by)
         is distinct from (old.permit_bypass_until, old.permit_bypass_set_at, old.permit_bypass_set_by)
     and not public.caller_admin_can_write('rpc:vehicle_permit_bypass') then
    raise exception 'VEHICLE_PROTECTED_COLUMN:permit_bypass_until' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.vehicle_permit_bypass_guard() from public, anon, authenticated;
drop trigger if exists trg_vehicle_permit_bypass_guard on public.vehicle;
create trigger trg_vehicle_permit_bypass_guard
  before update on public.vehicle
  for each row execute function public.vehicle_permit_bypass_guard();

-- An admin's upload of a permit file goes in <vehicle>/permits/; nobody else writes there.
drop policy if exists "vehicle-documents permits admin insert" on storage.objects;
create policy "vehicle-documents permits admin insert" on storage.objects as restrictive for insert to authenticated
  with check (bucket_id <> 'vehicle-documents' or coalesce((storage.foldername(name))[2], '') <> 'permits'
              or (select public.caller_admin_can_write('storage:vehicle-documents')));
drop policy if exists "vehicle-documents permits admin update" on storage.objects;
create policy "vehicle-documents permits admin update" on storage.objects as restrictive for update to authenticated
  using (bucket_id <> 'vehicle-documents' or coalesce((storage.foldername(name))[2], '') <> 'permits'
         or (select public.caller_admin_can_write('storage:vehicle-documents')))
  with check (bucket_id <> 'vehicle-documents' or coalesce((storage.foldername(name))[2], '') <> 'permits'
              or (select public.caller_admin_can_write('storage:vehicle-documents')));

-- ---- 10. Bypass ---------------------------------------------------------------------------------------
-- On: the vehicle may take rides without its permits for its country's
-- bypass days; off: ends it now.
create or replace function public.vehicle_permit_bypass(p_vehicle uuid, p_on boolean)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days integer;
  v_until timestamptz;
begin
  if not public.caller_admin_can_write('rpc:vehicle_permit_bypass') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not exists (select 1 from public.vehicle where id = p_vehicle) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select max((public.permit_settings_for(c)).bypass_days) into v_days
    from unnest(public.ptr_text_array(public.ptr_vehicle_context(p_vehicle)->'countries')) c;
  v_days := coalesce(v_days, (public.permit_settings_for(null)).bypass_days);
  v_until := case when coalesce(p_on, false) then now() + make_interval(days => v_days) end;
  update public.vehicle
     set permit_bypass_until = v_until, permit_bypass_set_at = now(), permit_bypass_set_by = auth.uid()
   where id = p_vehicle;
  return v_until;
end;
$$;
revoke execute on function public.vehicle_permit_bypass(uuid, boolean) from public, anon;
grant execute on function public.vehicle_permit_bypass(uuid, boolean) to authenticated;

-- ---- 11. The ride carries the vehicle --------------------------------------------------------------
alter table public.ride_requests add column if not exists partner_vehicle_id uuid
  references public.vehicle(id) on delete set null;
alter table public.ride_requests add column if not exists partner_energy text;
alter table public.ride_requests add column if not exists partner_vehicle_types text[];
alter table public.ride_requests add column if not exists partner_plate_colours jsonb;
create index if not exists ride_requests_partner_vehicle_idx on public.ride_requests(partner_vehicle_id);
comment on column public.ride_requests.partner_vehicle_id is
  'The vehicle the driver had taken when they bid on or took the ride. Server-stamped (0254).';

-- Stamped from the vehicle the driver is driving whenever the driver
-- changes (after every other guard, whoever writes the row: a bid, a take,
-- a handover, a scheduled release), filled in when still missing later on,
-- cleared with the driver and otherwise kept.
create or replace function public.ride_requests_stamp_vehicle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle uuid;
  v_ctx jsonb;
  v_types text[];
  v_energy text;
  v_country text;
begin
  if new.partner_id is null then
    new.partner_vehicle_id := null;
    new.partner_energy := null;
    new.partner_vehicle_types := null;
    new.partner_plate_colours := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.partner_id is not distinct from old.partner_id then
    if old.partner_vehicle_id is not null
       or new.status not in ('accepted', 'arrived', 'on_trip') then
      new.partner_vehicle_id := old.partner_vehicle_id;
      new.partner_energy := old.partner_energy;
      new.partner_vehicle_types := old.partner_vehicle_types;
      new.partner_plate_colours := old.partner_plate_colours;
      return new;
    end if;
  end if;
  select s.vehicle_id into v_vehicle from public.vehicle_active_session s where s.user_id = new.partner_id limit 1;
  if v_vehicle is null then
    new.partner_vehicle_id := null;
    new.partner_energy := null;
    new.partner_vehicle_types := null;
    new.partner_plate_colours := null;
    return new;
  end if;
  v_ctx := public.ptr_vehicle_context(v_vehicle);
  v_types := public.ptr_text_array(v_ctx->'types');
  v_energy := public.vehicle_energy(v_vehicle);
  v_country := (public.ptr_text_array(v_ctx->'countries'))[1];
  new.partner_vehicle_id := v_vehicle;
  new.partner_energy := v_energy;
  new.partner_vehicle_types := v_types;
  new.partner_plate_colours := public.permit_plate_colours(v_country, v_types, v_energy);
  return new;
end;
$$;
revoke execute on function public.ride_requests_stamp_vehicle() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_zzz_vehicle on public.ride_requests;
create trigger trg_ride_requests_zzz_vehicle
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_stamp_vehicle();

-- ---- 12. Enforcement --------------------------------------------------------------------------------
-- Going online: kept offline while a required permit is missing.
create or replace function public.driver_presence_guard_permit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.online and public.driver_permit_problem(new.profile_id) is not null then
    new.online := false;
  end if;
  return new;
end;
$$;
revoke execute on function public.driver_presence_guard_permit() from public, anon, authenticated;
drop trigger if exists trg_driver_presence_guard_permit on public.driver_presence;
create trigger trg_driver_presence_guard_permit
  before insert or update on public.driver_presence
  for each row execute function public.driver_presence_guard_permit();

-- Bidding on or taking a ride from the apps, or booking a driver directly
-- (as the credit guard, 0218). Admins and the server's own jobs are not held up.
create or replace function public.ride_requests_guard_permit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_why text;
begin
  if new.partner_id is null
     or (tg_op = 'UPDATE' and new.partner_id is not distinct from old.partner_id)
     or coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_is_admin() then
    return new;
  end if;
  v_why := public.driver_permit_problem(new.partner_id);
  if v_why is not null then
    if auth.uid() is distinct from new.partner_id then
      raise exception 'DRIVER_UNAVAILABLE' using errcode = 'P0001',
        hint = 'This driver can''t take trips right now. Please book another driver.';
    end if;
    raise exception 'VEHICLE_PERMIT_REQUIRED' using errcode = 'P0001', hint = v_why;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_permit() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_a_guard_permit on public.ride_requests;
create trigger trg_ride_requests_a_guard_permit
  before insert or update of partner_id on public.ride_requests
  for each row execute function public.ride_requests_guard_permit();

-- Open requests are not shown to a driver who may not take them.
drop policy if exists "ride_requests vehicle permit" on public.ride_requests;
create policy "ride_requests vehicle permit" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (select public.caller_permit_ok()));

-- The server's own takes (scheduled accept, a scheduled offer, a handover)
-- and its pushes and offers, each edited in its current definition.
do $edit$
declare
  e record;
  v_def text;
  v_n int;
begin
  for e in
    select * from (values
      ('scheduled_ride_accept', 'perform public.driver_credit_assert(v_uid);',
         'perform public.driver_credit_assert(v_uid);' || chr(10) || '  perform public.driver_permit_assert(v_uid);'),
      ('scheduled_ride_offer_respond', 'perform public.driver_credit_assert(v_uid);',
         'perform public.driver_credit_assert(v_uid);' || chr(10) || '  perform public.driver_permit_assert(v_uid);'),
      ('trip_handover_accept', 'perform public.driver_credit_assert(v_uid);',
         'perform public.driver_credit_assert(v_uid);' || chr(10) || '  perform public.driver_permit_assert(v_uid);'),
      ('ride_request_push_nearby', 'continue when not public.driver_takes_extras(v_driver, v_keys);',
         'continue when not public.driver_takes_extras(v_driver, v_keys);' || chr(10)
         || '    continue when public.driver_permit_problem(v_driver) is not null;'),
      ('dispatch_push', 'and public.driver_takes_extras(d.profile_id, v_keys)',
         'and public.driver_takes_extras(d.profile_id, v_keys)' || chr(10)
         || '         and public.driver_permit_problem(d.profile_id) is null'),
      ('airport_dispatch', 'and public.driver_takes_extras(l.driver_id, v_keys)',
         'and public.driver_takes_extras(l.driver_id, v_keys)' || chr(10)
         || '       and public.driver_permit_problem(l.driver_id) is null'),
      ('airport_dispatch', 'and public.driver_takes_extras(z.driver_id, v_keys)',
         'and public.driver_takes_extras(z.driver_id, v_keys)' || chr(10)
         || '         and public.driver_permit_problem(z.driver_id) is null'),
      ('scheduled_rides_open', 'and public.service_order_driver_allows(auth.uid(), s.service)',
         'and public.service_order_driver_allows(auth.uid(), s.service)' || chr(10)
         || '     and public.driver_permit_problem(auth.uid()) is null')
    ) as t(fn, anchor, added)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = e.fn;
    if v_def is null then
      raise exception '0254: public.% is missing', e.fn;
    end if;
    -- Run again: a place already edited is left alone.
    continue when position(e.added in v_def) > 0;
    v_n := (length(v_def) - length(replace(v_def, e.anchor, ''))) / length(e.anchor);
    if v_n <> 1 then
      raise exception '0254: public.% should have "%" once (has %); update this migration', e.fn, e.anchor, v_n;
    end if;
    execute replace(v_def, e.anchor, e.added);
  end loop;
end
$edit$;

-- ---- 13. What a passenger sees ----------------------------------------------------------------------
-- The permits of a ride's vehicle and driver shown to passengers: valid,
-- passenger fields only, with their files. For the ride's rider from the
-- driver's acceptance to the end of the trip (admins too); null otherwise.
create or replace function public.ride_permit_items(p_ride uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v public.vehicle;
  v_ctx jsonb;
  v_types text[];
  v_service text;
  v_partner public.partners;
  v_items jsonb := '[]'::jsonb;
  t record;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or r.partner_vehicle_id is null then
    return v_items;
  end if;
  select * into v from public.vehicle where id = r.partner_vehicle_id;
  v_ctx := public.ptr_vehicle_context(v.id);
  v_types := public.ptr_text_array(v_ctx->'types');
  v_service := coalesce(nullif(v.service_approved_id, ''), v.service_id);
  for t in
    select pt.*, to_jsonb(d) as doc,
           public.storage_path_in(d.file_url, 'vehicle-documents') as path
      from public.permit_types pt
      join public.vehicle_documents d on d.vehicle_id = v.id and d.permit_type_id = pt.id
     where pt.active and pt.applies_to = 'vehicle' and pt.shown_to_passengers
       and exists (select 1 from unnest(public.ptr_text_array(v_ctx->'countries')) c
                    where public.ptr_name(c) = public.ptr_name(pt.country))
       and public.permit_type_covers(pt.partner_types, pt.services, v_types, v_service)
       and public.permit_doc_state(d.status, d.expiry_date) = 'with'
     order by pt.position, pt.name
  loop
    v_items := v_items || jsonb_build_object(
      'type_id', t.id, 'applies_to', 'vehicle', 'name', t.name, 'name_local', t.name_local,
      'short_name', t.short_name, 'issuer', t.issuer,
      'fields', public.permit_field_values(t.fields, t.doc, true),
      'bucket', 'vehicle-documents', 'path', t.path);
  end loop;
  select * into v_partner from public.partners p where p.auth_user_id = r.partner_id
   order by (p.status = 'approved' or p.status::text like 'permit-%') desc, p.created_at desc limit 1;
  if found then
    for t in
      select pt.*, to_jsonb(d) as doc, public.storage_path_in(d.file_url, 'provider-documents') as path
        from public.permit_types pt
        join lateral (
          select d.* from public.provider_documents d
           where d.partner_id = v_partner.id and pt.document_id is not null and d.doc_id = pt.document_id
           order by d.uploaded_at desc limit 1) d on true
       where pt.active and pt.applies_to = 'driver' and pt.shown_to_passengers
         and exists (select 1 from unnest(public.ptr_text_array(v_ctx->'countries')) c
                      where public.ptr_name(c) = public.ptr_name(pt.country))
         and public.permit_type_covers(pt.partner_types, pt.services, v_types, v_service)
         and public.permit_doc_state(d.status, d.expiry_date) = 'with'
       order by pt.position, pt.name
    loop
      v_items := v_items || jsonb_build_object(
        'type_id', t.id, 'applies_to', 'driver', 'name', t.name, 'name_local', t.name_local,
        'short_name', t.short_name, 'issuer', t.issuer,
        'fields', public.permit_field_values(t.fields, t.doc, true),
        'bucket', 'provider-documents', 'path', t.path);
    end loop;
  end if;
  return v_items;
end;
$$;
revoke execute on function public.ride_permit_items(uuid) from public, anon, authenticated;

-- Whether the caller may see the ride's permits now.
create or replace function public.ride_permits_open(p_ride uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.ride_requests r
     where r.id = p_ride
       and ((r.rider_id = auth.uid() and r.status in ('accepted', 'arrived', 'on_trip'))
            or public.caller_is_admin()));
$$;
revoke execute on function public.ride_permits_open(uuid) from public, anon, authenticated;

create or replace function public.ride_permits(p_ride uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  if not public.ride_permits_open(p_ride) then
    return null;
  end if;
  select * into r from public.ride_requests where id = p_ride;
  return jsonb_build_object(
    'ride_id', r.id, 'plate', r.partner_plate, 'vehicle', r.partner_vehicle,
    'energy', r.partner_energy, 'types', to_jsonb(coalesce(r.partner_vehicle_types, '{}')),
    'colours', r.partner_plate_colours,
    'permits', public.ride_permit_items(p_ride));
end;
$$;
revoke execute on function public.ride_permits(uuid) from public, anon;
grant execute on function public.ride_permits(uuid) to authenticated;

-- The rider reads those files, and nothing else of the driver's.
create or replace function public.ride_permit_file_readable(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.ride_requests r
     where r.rider_id = auth.uid()
       and r.status in ('accepted', 'arrived', 'on_trip')
       and r.partner_vehicle_id is not null
       and exists (select 1 from jsonb_array_elements(public.ride_permit_items(r.id)) i
                    where i->>'bucket' = p_bucket and i->>'path' = p_name));
$$;
revoke execute on function public.ride_permit_file_readable(text, text) from public, anon;
grant execute on function public.ride_permit_file_readable(text, text) to authenticated;

drop policy if exists "vehicle-documents ride permit read" on storage.objects;
create policy "vehicle-documents ride permit read" on storage.objects for select to authenticated
  using (bucket_id = 'vehicle-documents' and coalesce((storage.foldername(name))[2], '') = 'permits'
         and public.ride_permit_file_readable(bucket_id, name));
drop policy if exists "provider-documents ride permit read" on storage.objects;
create policy "provider-documents ride permit read" on storage.objects for select to authenticated
  using (bucket_id = 'provider-documents' and public.ride_permit_file_readable(bucket_id, name));

-- The reminder days for a document: its permit type's, else its required
-- document's, else its country's, else the default.
create or replace function public.document_reminder_days_for(p_country text, p_type uuid, p_doc text)
returns integer[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select d.days from public.document_reminder_days d where d.scope = 'permit_type' and d.scope_key = p_type::text),
    (select d.days from public.document_reminder_days d where d.scope = 'document' and d.scope_key = p_doc),
    (select d.days from public.document_reminder_days d
      where d.scope = 'country' and public.ptr_name(d.scope_key) = public.ptr_name(p_country) and p_country is not null),
    (select d.days from public.document_reminder_days d where d.scope = 'default'),
    '{}'::integer[]);
$$;
revoke execute on function public.document_reminder_days_for(text, uuid, text) from public, anon, authenticated;

-- ---- 14. What a driver sees --------------------------------------------------------------------------
-- One permit as the driver and admins see it: every field, its state and file.
create or replace function public.permit_item(p_type public.permit_types, p_doc jsonb, p_state text, p_bucket text)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'type_id', p_type.id, 'key', p_type.key, 'country', p_type.country, 'applies_to', p_type.applies_to,
    'name', p_type.name, 'name_local', p_type.name_local, 'short_name', p_type.short_name,
    'issuer', p_type.issuer, 'uploader', p_type.uploader, 'required', p_type.required,
    'shown_to_passengers', p_type.shown_to_passengers, 'renewal_text', p_type.renewal_text,
    'enforce', (public.permit_settings_for(p_type.country)).enforce,
    'warn_days', (select max(x) from unnest(public.document_reminder_days_for(p_type.country, p_type.id, p_doc->>'doc_id')) x),
    'state', p_state, 'document_id', p_doc->>'id', 'status', p_doc->>'status',
    'valid_from', p_doc->>'start_date', 'valid_until', p_doc->>'expiry_date',
    'fields', public.permit_field_values(p_type.fields, p_doc, false),
    'bucket', p_bucket, 'file_url', p_doc->>'file_url',
    'path', public.storage_path_in(p_doc->>'file_url', p_bucket));
$$;
revoke execute on function public.permit_item(public.permit_types, jsonb, text, text) from public, anon, authenticated;

-- A vehicle with its permits, status and plate colours.
create or replace function public.vehicle_permit_card(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.vehicle;
  v_ctx jsonb;
  v_types text[];
  v_energy text;
  v_items jsonb := '[]'::jsonb;
  x record;
begin
  select * into v from public.vehicle where id = p_vehicle;
  if not found then
    return null;
  end if;
  v_ctx := public.ptr_vehicle_context(v.id);
  v_types := public.ptr_text_array(v_ctx->'types');
  v_energy := public.vehicle_energy(v.id);
  for x in
    select t, r.state, (select to_jsonb(d) from public.vehicle_documents d where d.id = r.document_id) as doc
      from public.vehicle_permit_rows(v.id) r join public.permit_types t on t.id = r.type_id
     order by t.position, t.name
  loop
    v_items := v_items || public.permit_item(x.t, coalesce(x.doc, '{}'::jsonb), x.state, 'vehicle-documents');
  end loop;
  return jsonb_build_object(
    'vehicle_id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model, 'color', v.color,
    'label', nullif(btrim(concat_ws(' ', v.color, v.make, v.model)), ''),
    'energy', v_energy, 'types', to_jsonb(v_types), 'countries', v_ctx->'countries',
    'colours', public.permit_plate_colours((public.ptr_text_array(v_ctx->'countries'))[1], v_types, v_energy),
    'status', public.vehicle_permit_status(v.id), 'bypass_until', v.permit_bypass_until,
    'joined_at', v.joined_at, 'vehicle_status', v.status::text,
    'permits', v_items);
end;
$$;
revoke execute on function public.vehicle_permit_card(uuid) from public, anon, authenticated;

-- The caller's vehicles and own permits, any time.
create or replace function public.my_permits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_vehicles jsonb;
  v_driver jsonb := '[]'::jsonb;
  x record;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(public.vehicle_permit_card(v.id)
                    || jsonb_build_object('active', exists (select 1 from public.vehicle_active_session s
                                                             where s.vehicle_id = v.id and s.user_id = v_uid))
                    order by v.plate), '[]'::jsonb)
    into v_vehicles
    from public.vehicle v
   where v.auth_user_id = v_uid
      or exists (select 1 from public.partners p where p.id = v.owner_partner_id and p.auth_user_id = v_uid)
      or exists (select 1 from public.vehicle_user_assignment a
                  where a.vehicle_id = v.id and a.user_id = v_uid and a.is_active);
  for x in
    select t, r.state, (select to_jsonb(d) from public.provider_documents d where d.id = r.document_id) as doc
      from public.driver_permit_rows(v_uid) r join public.permit_types t on t.id = r.type_id
     order by t.position, t.name
  loop
    v_driver := v_driver || public.permit_item(x.t, coalesce(x.doc, '{}'::jsonb), x.state, 'provider-documents');
  end loop;
  return jsonb_build_object('vehicles', v_vehicles, 'driver_permits', v_driver,
                            'problem', public.driver_permit_problem(v_uid));
end;
$$;
revoke execute on function public.my_permits() from public, anon;
grant execute on function public.my_permits() to authenticated;

-- ---- 15. The admin's list ---------------------------------------------------------------------------
-- Every vehicle registered in [p_country] that a permit applies to, with
-- its status and permits.
create or replace function public.admin_vehicle_permits(p_country text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(c order by c->>'plate')
      from (
        select public.vehicle_permit_card(v.id) as c
          from public.vehicle v
         where exists (select 1 from unnest(public.ptr_text_array(public.ptr_vehicle_context(v.id)->'countries')) k
                        where public.ptr_name(k) = public.ptr_name(p_country))
         limit 3000
      ) x
     where x.c->>'status' <> 'none'), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_vehicle_permits(text) from public, anon;
grant execute on function public.admin_vehicle_permits(text) to authenticated;

-- One vehicle's card for the admin's permit editor.
create or replace function public.admin_vehicle_permit_card(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.vehicle_permit_card(p_vehicle);
end;
$$;
revoke execute on function public.admin_vehicle_permit_card(uuid) from public, anon;
grant execute on function public.admin_vehicle_permit_card(uuid) to authenticated;

-- ---- 16. Expiry reminders ----------------------------------------------------------------------------

-- A reminder text: the country's (else '*') template with {document},
-- {for_plate}, {days}, {date} and {issuer} filled in.
create or replace function public.document_reminder_text(
  p_country text, p_key text, p_document text, p_plate text, p_days integer, p_date date, p_issuer text
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text := nullif(btrim(coalesce((public.permit_settings_for(p_country)).texts->>p_key, '')), '');
begin
  if v is null then
    select nullif(btrim(coalesce(s.texts->>p_key, '')), '') into v from public.permit_country_settings s where s.country = '*';
  end if;
  if v is null then
    return null;
  end if;
  return replace(replace(replace(replace(replace(v,
    '{document}', coalesce(p_document, '')),
    '{for_plate}', coalesce(' for ' || nullif(btrim(p_plate), ''), '')),
    '{days}', coalesce(p_days::text, '')),
    '{date}', coalesce(to_char(p_date, 'DD/MM/YYYY'), '')),
    '{issuer}', coalesce(p_issuer, ''));
end;
$$;
revoke execute on function public.document_reminder_text(text, text, text, text, integer, date, text)
  from public, anon, authenticated;

-- Every document that expires in exactly one of its reminder days (or
-- today) is reminded once: its holder by push and in Notifications.
create or replace function public.document_expiry_reminders_run(p_today date default current_date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  d record;
  n integer;
  v_days integer[];
  v_id uuid;
  v_title text;
  v_body text;
  v_more text;
  v_sent integer := 0;
begin
  for d in
    select 'vehicle_documents'::text as tbl, vd.id, vd.expiry_date, vd.doc_id, vd.doc_name, vd.permit_type_id as type_id,
           v.plate, coalesce(v.auth_user_id, op.auth_user_id) as uid,
           (public.ptr_text_array(public.ptr_vehicle_context(v.id)->'countries'))[1] as country
      from public.vehicle_documents vd
      join public.vehicle v on v.id = vd.vehicle_id
      left join public.partners op on op.id = v.owner_partner_id
     where vd.expiry_date between p_today and p_today + 400
       and coalesce(vd.status, '') <> 'Rejected'
    union all
    select 'provider_documents', pd.id, pd.expiry_date, pd.doc_id, pd.doc_name,
           (select t.id from public.permit_types t
             where t.applies_to = 'driver' and t.active and t.document_id = pd.doc_id
               and exists (select 1 from unnest(coalesce(p.service_countries, '{}')) c
                            where public.ptr_name(c) = public.ptr_name(t.country))
             order by t.position limit 1),
           null, coalesce(p.auth_user_id, pd.auth_user_id), p.service_countries[1]
      from public.provider_documents pd
      left join public.partners p on p.id = pd.partner_id
     where pd.expiry_date between p_today and p_today + 400
       and coalesce(pd.status, '') <> 'Rejected'
  loop
    continue when d.uid is null;
    n := d.expiry_date - p_today;
    v_days := public.document_reminder_days_for(d.country, d.type_id, d.doc_id);
    continue when n <> 0 and not (n = any (v_days));
    insert into public.document_expiry_reminders (doc_table, doc_id, expiry_date, days_before, profile_id)
    values (d.tbl, d.id, d.expiry_date, n, d.uid)
    on conflict do nothing
    returning id into v_id;
    continue when v_id is null;
    declare
      t public.permit_types;
      v_name text;
    begin
      select * into t from public.permit_types where id = d.type_id;
      v_name := coalesce(t.name, d.doc_name, 'document');
      v_title := public.document_reminder_text(d.country, case when n = 0 then 'title_today' else 'title' end,
                                               v_name, d.plate, n, d.expiry_date, t.issuer);
      v_body := public.document_reminder_text(d.country, case when n = 0 then 'body_today' else 'body' end,
                                              v_name, d.plate, n, d.expiry_date, t.issuer);
      v_more := case
        when t.id is not null and t.uploader = 'admin' then
          replace(nullif(btrim(t.renewal_text), ''), '{issuer}', coalesce(t.issuer, ''))
        when t.id is not null and nullif(btrim(t.renewal_text), '') is not null then
          replace(t.renewal_text, '{issuer}', coalesce(t.issuer, ''))
        else public.document_reminder_text(d.country, 'driver_upload', v_name, d.plate, n, d.expiry_date, t.issuer) end;
      continue when v_body is null;
      perform public.enqueue_notification(
        d.uid, 'doc-expiry-' || d.id || '-' || d.expiry_date || '-' || n, 'document_expiry', 'normal',
        coalesce(v_title, v_name), btrim(v_body || coalesce(' ' || v_more, '')),
        jsonb_build_object('type', 'document_expiry', 'doc_table', d.tbl, 'document_id', d.id,
                           'permit_type_id', d.type_id, 'days', n, 'expiry_date', d.expiry_date));
      v_sent := v_sent + 1;
    end;
  end loop;
  return v_sent;
end;
$$;
revoke execute on function public.document_expiry_reminders_run(date) from public, anon, authenticated;

-- The admin's "Expiring soon": documents expiring within [p_days] (or
-- expired in the last 7), with their holder and what was sent.
create or replace function public.admin_expiring_documents(p_days integer default 45)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by x->>'expiry_date', x->>'name')
      from (
        select jsonb_build_object(
                 'doc_table', 'vehicle_documents', 'id', vd.id, 'name', coalesce(t.name, vd.doc_name),
                 'plate', v.plate, 'vehicle_id', v.id, 'holder', coalesce(v.owner_name, op.name),
                 'expiry_date', vd.expiry_date, 'permit_type_id', vd.permit_type_id,
                 'sent', (select coalesce(jsonb_agg(r.days_before order by r.days_before desc), '[]'::jsonb)
                            from public.document_expiry_reminders r
                           where r.doc_table = 'vehicle_documents' and r.doc_id = vd.id
                             and r.expiry_date = vd.expiry_date)) as x
          from public.vehicle_documents vd
          join public.vehicle v on v.id = vd.vehicle_id
          left join public.partners op on op.id = v.owner_partner_id
          left join public.permit_types t on t.id = vd.permit_type_id
         where vd.expiry_date between current_date - 7 and current_date + least(greatest(coalesce(p_days, 45), 0), 400)
           and coalesce(vd.status, '') <> 'Rejected'
        union all
        select jsonb_build_object(
                 'doc_table', 'provider_documents', 'id', pd.id, 'name', pd.doc_name,
                 'plate', null, 'partner_id', p.id, 'holder', p.name,
                 'expiry_date', pd.expiry_date, 'permit_type_id', null,
                 'sent', (select coalesce(jsonb_agg(r.days_before order by r.days_before desc), '[]'::jsonb)
                            from public.document_expiry_reminders r
                           where r.doc_table = 'provider_documents' and r.doc_id = pd.id
                             and r.expiry_date = pd.expiry_date))
          from public.provider_documents pd
          left join public.partners p on p.id = pd.partner_id
         where pd.expiry_date between current_date - 7 and current_date + least(greatest(coalesce(p_days, 45), 0), 400)
           and coalesce(pd.status, '') <> 'Rejected'
         limit 2000
      ) s), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_expiring_documents(integer) from public, anon;
grant execute on function public.admin_expiring_documents(integer) to authenticated;

do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'document-expiry-reminders';
    -- 01:07 UTC: the morning in Malaysia.
    perform cron.schedule('document-expiry-reminders', '7 1 * * *',
                          $job$select public.document_expiry_reminders_run()$job$);
  end if;
end
$cron$;

-- ---- 17. Seed: the default and Malaysia --------------------------------------------------------------
insert into public.document_reminder_days (scope, scope_key, days)
values ('default', '', '{45,30,15,3,1}')
on conflict (scope, scope_key) do nothing;

insert into public.permit_country_settings (country, enforce, bypass_days, plate_colours, texts)
values ('*', false, 3,
  '{"types": [{"type": "TEKSI", "bg": "#ffffff", "fg": "#111111"}],
    "energies": [{"energy": "Petrol", "bg": "#111111", "fg": "#ffffff"},
                 {"energy": "EV", "bg": "#1e8e3e", "fg": "#ffffff"},
                 {"energy": "Diesel", "bg": "#1a56c4", "fg": "#ffffff"},
                 {"energy": "Hybrid", "bg": "#9be3a8", "fg": "#0b2a14"},
                 {"energy": "PHEV", "bg": "#9be3a8", "fg": "#0b2a14"}],
    "other": {"bg": "#111111", "fg": "#ffffff"}}'::jsonb,
  '{"title": "{document} expires in {days} days",
    "title_today": "{document} expires today",
    "body": "Your {document}{for_plate} expires in {days} days ({date}).",
    "body_today": "Your {document}{for_plate} expires today ({date}).",
    "driver_upload": "Upload the renewed document in Documents."}'::jsonb)
on conflict (country) do nothing;

insert into public.permit_country_settings (country, enforce, bypass_days)
values ('Malaysia', false, 3)
on conflict (country) do nothing;

insert into public.permit_types (country, key, name, name_local, short_name, issuer, applies_to, partner_types,
                                 fields, uploader, shown_to_passengers, required, renewal_text, position)
values ('Malaysia', 'evp', 'E-hailing vehicle permit (eVP)', 'Permit Kenderaan E-hailing', 'Vehicle permit', 'APAD',
        'vehicle', '{eHailing,TEKSI}',
        '[{"key": "ref_primary", "label": "Permit Reference No. (Primary)", "label_local": "No. Rujukan Permit (Induk)", "kind": "text", "role": "number", "passenger": true},
          {"key": "ref_sub", "label": "Permit Reference No. (Sub)", "label_local": "No. Rujukan Permit (Sub)", "kind": "text", "role": "", "passenger": true},
          {"key": "effective", "label": "Permit Effective Date", "label_local": "Tarikh Mula Kuatkuasa Permit", "kind": "date", "role": "valid_from", "passenger": true},
          {"key": "valid_until", "label": "Permit Valid Until", "label_local": "Tarikh Sahlaku Permit Sehingga", "kind": "date", "role": "valid_until", "passenger": true},
          {"key": "plate", "label": "Vehicle registration no.", "label_local": "Nombor Pendaftaran Kenderaan", "kind": "text", "role": "plate", "passenger": false},
          {"key": "seats", "label": "Seats", "label_local": "Bilangan Tempat Duduk", "kind": "text", "role": "", "passenger": false}]'::jsonb,
        'admin', true, true, 'GET.ride is renewing it with {issuer}.', 1)
on conflict do nothing;

insert into public.permit_types (country, key, name, name_local, short_name, issuer, applies_to, partner_types,
                                 fields, uploader, shown_to_passengers, required, document_id, renewal_text, position)
values ('Malaysia', 'taxi-driver', 'Taxi driver permit', 'Permit Pemandu Teksi', 'Taxi permit', 'APAD',
        'driver', '{TEKSI}',
        '[{"key": "permit_no", "label": "Permit No.", "label_local": "No. Permit", "kind": "text", "role": "number", "passenger": true},
          {"key": "valid_from", "label": "Valid from", "label_local": "Sah dari", "kind": "date", "role": "valid_from", "passenger": true},
          {"key": "valid_until", "label": "Valid until", "label_local": "Sah sehingga", "kind": "date", "role": "valid_until", "passenger": true}]'::jsonb,
        'either', true, false,
        (select r.id::text from public.required_document r
          where public.ptr_bool(r.values -> 'isTaxiPermit', false)
          order by r.active desc, r.position limit 1),
        'Upload the renewed permit in Documents.', 2)
on conflict do nothing;

notify pgrst, 'reload schema';
