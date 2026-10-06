-- ============================================================================
-- Teksi / Rork app — Supabase schema
-- ----------------------------------------------------------------------------
-- Safe to run on a fresh Supabase project. Idempotent: re-runs do not destroy
-- existing data. To wipe and recreate, run `supabase/reset.sql` first.
-- ============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- caller_is_admin() is created here as well as in the 0069 section below
-- (identical definition): policies earlier in this file call it, and a
-- policy can only reference a function that already exists.
create or replace function public.caller_is_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (setup scripts, psql, triggers)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  if auth.uid() is null then
    return false;
  end if;
  if to_regclass('public.admin_access') is null then
    return false;
  end if;
  return exists (
    select 1 from public.admin_access where profile_id = auth.uid()
  );
end;
$$;

grant execute on function public.caller_is_admin() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type partner_status as enum (
    'approved','unapproved','blocked','rejected',
    'unapproved-docs','permit-pending','permit-non-verified','permit-verified'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type permit_status as enum ('pending','non-verified','verified','none');
exception when duplicate_object then null; end $$;

do $$ begin
  create type user_status as enum (
    'approved','unapproved','blocked','rejected','unapproved-docs'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type gender_type as enum ('male','female','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type profile_status as enum (
    'Approved','Un-Approved','Blocked','Rejected','Deleted'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type id_verification_status as enum ('Verified','Failed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_id text unique,
  name text,
  phone text,
  email text,
  ic text,
  address text,
  profile_image text,
  avatar_url text,
  id_image text,
  nationality text,
  gender gender_type,
  birth_date date,
  referral_code text,
  pin text,
  login_pin text,
  pin_hash text,
  pin_failed_attempts integer not null default 0,
  pin_locked_until timestamptz,
  device_count integer not null default 1,
  status user_status not null default 'unapproved',
  profile_status profile_status not null default 'Un-Approved',
  id_verified id_verification_status,
  documents_ok boolean not null default false,
  total_rides integer not null default 0,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_status_idx on public.profiles(status);
create index if not exists profiles_phone_idx on public.profiles(phone);
create index if not exists profiles_profile_status_idx on public.profiles(profile_status);
create index if not exists profiles_id_verified_idx on public.profiles(id_verified);

-- ---------------------------------------------------------------------------
-- Partners
-- ---------------------------------------------------------------------------
create table if not exists public.partners (
  id uuid primary key default gen_random_uuid(),
  display_id text unique,
  auth_user_id uuid references auth.users(id) on delete set null,
  name text not null,
  phone text not null,
  email text,
  ic text,
  vehicle text,
  plate text,
  vehicle_type text,
  energy_type text,
  make text,
  model text,
  year_from text,
  year_to text,
  partner_type text,
  permit_number text,
  status partner_status not null default 'unapproved',
  permit permit_status not null default 'pending',
  documents_ok boolean not null default false,
  rating numeric(3,2) not null default 0,
  total_rides integer not null default 0,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists partners_status_idx on public.partners(status);
create index if not exists partners_permit_idx on public.partners(permit);
create index if not exists partners_phone_idx on public.partners(phone);

-- Partner onboarding profile columns (migration 0024): service area,
-- multi-select partner types, and resumable onboarding state.
alter table public.partners
  add column if not exists service_countries text[] not null default '{}',
  add column if not exists service_states    text[] not null default '{}',
  add column if not exists service_cities    text[] not null default '{}',
  add column if not exists partner_types     text[] not null default '{}',
  add column if not exists avatar_url        text,
  add column if not exists address           text,
  add column if not exists onboarding_step   text;

create index if not exists partners_auth_user_idx on public.partners(auth_user_id);

-- ---------------------------------------------------------------------------
-- Vehicles
-- ---------------------------------------------------------------------------
create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  display_id text unique,
  partner_id uuid references public.partners(id) on delete set null,
  partner_display_id text,
  plate text not null,
  make text not null,
  model text not null,
  year text,
  color text,
  vehicle_type text,
  owner_name text not null,
  owner_phone text not null,
  status partner_status not null default 'unapproved',
  permit permit_status not null default 'pending',
  documents_ok boolean not null default false,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists vehicles_status_idx on public.vehicles(status);
create index if not exists vehicles_permit_idx on public.vehicles(permit);
create index if not exists vehicles_plate_idx on public.vehicles(plate);
create index if not exists vehicles_partner_idx on public.vehicles(partner_id);

-- ---------------------------------------------------------------------------
-- Vehicle make/model catalog
-- ---------------------------------------------------------------------------
create table if not exists public.vehicle_make_models (
  id uuid primary key default gen_random_uuid(),
  vehicle_type text not null,
  energy_type text not null,
  make text not null,
  model text not null,
  year_from text not null default '',
  year_to text not null default '',
  icon_uri text not null default '',
  status boolean not null default true,
  is_default boolean not null default false,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists vmm_vehicle_type_idx on public.vehicle_make_models(vehicle_type);
create index if not exists vmm_energy_type_idx on public.vehicle_make_models(energy_type);
create index if not exists vmm_make_idx on public.vehicle_make_models(make);
create index if not exists vmm_model_idx on public.vehicle_make_models(model);
create index if not exists vmm_position_idx on public.vehicle_make_models(position);

-- ---------------------------------------------------------------------------
-- Partner documents
-- ---------------------------------------------------------------------------
create table if not exists public.partner_documents (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
  doc_type text not null,
  file_path text not null,
  status text not null default 'pending',
  expires_at timestamptz,
  uploaded_at timestamptz not null default now()
);

create index if not exists partner_documents_partner_idx on public.partner_documents(partner_id);

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
create table if not exists public.settings_entries (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  values jsonb not null default '{}'::jsonb,
  position integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists settings_entries_category_idx on public.settings_entries(category);
create index if not exists settings_entries_active_idx on public.settings_entries(active);

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Regions: countries / states / cities / suburbs
-- Source of truth for admin-settings-country-states-cities.tsx.
-- ---------------------------------------------------------------------------
create table if not exists public.countries (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  values      jsonb not null default '{}'::jsonb,
  geofence    jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists countries_name_idx on public.countries(name);
create index if not exists countries_position_idx on public.countries(position);

create table if not exists public.states (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  geofence    jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, name)
);

create index if not exists states_country_idx on public.states(country);
create index if not exists states_name_idx on public.states(name);

create table if not exists public.cities (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  state       text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  geofence    jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, state, name)
);

create index if not exists cities_country_idx on public.cities(country);
create index if not exists cities_state_idx on public.cities(state);
create index if not exists cities_name_idx on public.cities(name);

create table if not exists public.suburbs (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  state       text not null,
  city        text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  geofence    jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, state, city, name)
);

create index if not exists suburbs_country_idx on public.suburbs(country);
create index if not exists suburbs_state_idx on public.suburbs(state);
create index if not exists suburbs_city_idx on public.suburbs(city);
create index if not exists suburbs_name_idx on public.suburbs(name);

-- ---------------------------------------------------------------------------
-- Dedicated settings tables (split out of settings_entries — see 0019)
-- ---------------------------------------------------------------------------
create table if not exists public.airport_areas (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists airport_areas_position_idx on public.airport_areas(position);

create table if not exists public.required_document (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists required_document_position_idx on public.required_document(position);

create table if not exists public.document_type (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists document_type_position_idx on public.document_type(position);

create table if not exists public.driver_incentive (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists driver_incentive_position_idx on public.driver_incentive(position);

-- ---------------------------------------------------------------------------
-- More dedicated settings tables (see 0020)
-- ---------------------------------------------------------------------------
create table if not exists public.multi_gate (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('place','gate')),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists multi_gate_kind_idx     on public.multi_gate(kind);
create index if not exists multi_gate_position_idx on public.multi_gate(position);

do $extra_tables$
declare t text;
begin
  foreach t in array array[
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format($f$
      create table if not exists public.%1$s (
        id          uuid primary key default gen_random_uuid(),
        values      jsonb not null default '{}'::jsonb,
        position    integer not null default 0,
        active      boolean not null default true,
        created_at  timestamptz not null default now(),
        updated_at  timestamptz not null default now()
      );
      create index if not exists %1$s_position_idx on public.%1$s(position);
    $f$, t);
  end loop;
end;
$extra_tables$;

-- ---------------------------------------------------------------------------
-- Rides
-- ---------------------------------------------------------------------------
create table if not exists public.rides (
  id uuid primary key default gen_random_uuid(),
  rider_id uuid references public.profiles(id) on delete set null,
  partner_id uuid references public.partners(id) on delete set null,
  service text,
  status text not null default 'pending',
  pickup jsonb,
  dropoff jsonb,
  fare numeric(10,2),
  currency text default 'MYR',
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists rides_status_idx on public.rides(status);
create index if not exists rides_rider_idx on public.rides(rider_id);
create index if not exists rides_partner_idx on public.rides(partner_id);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','partners','vehicles','vehicle_make_models','settings_entries','app_settings',
    'countries','states','cities','suburbs',
    'airport_areas','required_document','document_type','driver_incentive',
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format(
      'drop trigger if exists trg_%1$s_updated_at on public.%1$s;
       create trigger trg_%1$s_updated_at before update on public.%1$s
       for each row execute function public.set_updated_at();', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Auto-create profile on auth user signup
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, phone)
  values (new.id, new.email, new.phone)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- A verified phone change (auth.updateUser + verifyOtp 'phone_change') moves
-- auth.users.phone; carry it onto the profile, which clients can't write
-- themselves since 0087 (migration 0092).
create or replace function public.sync_profile_phone()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.phone, '') <> '' and new.phone is distinct from old.phone then
    update public.profiles
       set phone = new.phone
     where id = new.id
       and phone is distinct from new.phone;
  end if;
  return new;
end;
$$;

revoke all on function public.sync_profile_phone() from public, anon, authenticated;

drop trigger if exists on_auth_user_phone_changed on auth.users;
create trigger on_auth_user_phone_changed
  after update of phone on auth.users
  for each row execute function public.sync_profile_phone();

-- ---------------------------------------------------------------------------
-- Launch telemetry: user_location_history + user_sessions (migration 0021,
-- with the columns added by 0049, 0050, 0070, 0075 and 0076 folded in).
-- Defined up here because device_prior_account_count() below reads
-- user_sessions. The owner-or-admin RLS policies live in the 0069 lockdown
-- section below.
-- ---------------------------------------------------------------------------
create table if not exists public.user_location_history (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete cascade,
  phone           text,
  session_id      uuid,
  latitude        double precision not null,
  longitude       double precision not null,
  accuracy        double precision,
  altitude        double precision,
  heading         double precision,
  speed           double precision,
  captured_at     timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

alter table public.user_location_history
  add column if not exists device_id text;

create index if not exists user_location_history_user_idx
  on public.user_location_history(user_id, captured_at desc);
create index if not exists user_location_history_session_idx
  on public.user_location_history(session_id);
create index if not exists user_location_history_captured_idx
  on public.user_location_history(captured_at desc);
create index if not exists user_location_history_device_id_idx
  on public.user_location_history(device_id);

-- One row per login / app launch / app relaunch.
create table if not exists public.user_sessions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid references auth.users(id) on delete cascade,
  phone              text,
  -- 'login' | 'app_launch' | 'app_relaunch' (free text so the client can add new buckets later)
  event_type         text not null default 'app_launch',
  os_name            text,
  os_version         text,
  device_brand       text,
  device_manufacturer text,
  device_model_name  text,
  device_model_id    text,
  device_year_class  integer,
  device_type        text,
  is_physical_device boolean,
  network_type       text,
  network_is_connected boolean,
  network_is_internet_reachable boolean,
  network_operator   text,
  ip_address         text,
  app_version        text,
  app_build_version  text,
  app_id             text,
  raw                jsonb,
  captured_at        timestamptz not null default now(),
  created_at         timestamptz not null default now()
);

alter table public.user_sessions
  add column if not exists connection_type      text,          -- 0049
  add column if not exists isp_provider         text,
  add column if not exists iccid                text,
  add column if not exists mobile_operator_name text,
  add column if not exists public_ip            text,          -- 0050
  add column if not exists isp_org              text,
  add column if not exists ip_city              text,
  add column if not exists ip_region            text,
  add column if not exists ip_country           text,
  add column if not exists device_id            text,          -- 0070
  add column if not exists mobile_country_code  text,          -- 0075
  add column if not exists mobile_network_code  text,
  add column if not exists cellular_generation  text;          -- 0076

create index if not exists user_sessions_user_idx
  on public.user_sessions(user_id, captured_at desc);
create index if not exists user_sessions_event_idx
  on public.user_sessions(event_type);
create index if not exists user_sessions_captured_idx
  on public.user_sessions(captured_at desc);
create index if not exists user_sessions_device_id_idx
  on public.user_sessions(device_id);

alter table public.user_location_history enable row level security;
alter table public.user_sessions enable row level security;
grant select, insert, update, delete on public.user_location_history to anon, authenticated;
grant select, insert, update, delete on public.user_sessions to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.user_location_history;
exception when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.user_sessions;
exception when duplicate_object then null;
end$$;

-- ---------------------------------------------------------------------------
-- Sign-in PIN: bcrypt hashing + brute-force rate limiting
-- (canonical definitions; see migration 0052 for the historical delta)
--
-- profiles.pin_hash stores a bcrypt hash of the 6-digit sign-in PIN. The
-- legacy plaintext columns (pin, login_pin) are kept for backward
-- compatibility as *write-only* inputs: a BEFORE trigger hashes anything
-- written to them and nulls the plaintext, so plaintext never persists.
-- ---------------------------------------------------------------------------
create or replace function public.hash_profile_pin()
returns trigger
language plpgsql
as $$
begin
  -- Prefer login_pin (canonical) over the legacy pin column.
  if new.login_pin is not null and new.login_pin <> '' then
    new.pin_hash := crypt(new.login_pin, gen_salt('bf', 10));
    new.pin_failed_attempts := 0;
    new.pin_locked_until := null;
  elsif new.pin is not null and new.pin <> '' then
    new.pin_hash := crypt(new.pin, gen_salt('bf', 10));
    new.pin_failed_attempts := 0;
    new.pin_locked_until := null;
  end if;
  -- Plaintext never persists.
  new.pin := null;
  new.login_pin := null;
  return new;
end;
$$;

drop trigger if exists trg_profiles_hash_pin on public.profiles;
create trigger trg_profiles_hash_pin
  before insert or update on public.profiles
  for each row execute function public.hash_profile_pin();

-- Client write path for setting/changing the PIN (authenticated users only).
-- set_login_pin also enforces the device-based duplicate-account guard for a
-- brand-new account (no prior pin_hash + freshly created profile). See the
-- device_guard_* functions below and migration 0072. PIN changes / forgot-PIN
-- resets operate on existing profiles and are never blocked.
create or replace function public.set_login_pin(p_pin text, p_device_id text default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_pin_hash text;
  v_created timestamptz;
  v_is_new boolean;
  v_enabled boolean;
  v_max int;
  v_block_emu boolean;
  v_prior int;
  v_emu boolean;
begin
  if v_uid is null then
    raise exception 'set_login_pin requires an authenticated session';
  end if;
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;

  select pin_hash, created_at into v_pin_hash, v_created
  from public.profiles where id = v_uid;
  v_is_new := (v_pin_hash is null)
    and (v_created is null or v_created > now() - interval '1 hour');

  if v_is_new then
    select c.enabled, c.max_accounts, c.block_emulators
      into v_enabled, v_max, v_block_emu
    from public.device_guard_config() c;

    if v_enabled and p_device_id is not null and p_device_id <> '' then
      select count(distinct user_id)::int into v_prior
      from public.user_sessions
      where device_id = p_device_id
        and user_id is not null
        and user_id <> v_uid;
      if v_prior >= v_max then
        raise exception 'DEVICE_LIMIT:%/%', v_prior, v_max;
      end if;
    end if;

    if v_enabled and v_block_emu then
      select coalesce(bool_or(is_physical_device is false), false) into v_emu
      from public.user_sessions
      where (p_device_id is not null and p_device_id <> '' and device_id = p_device_id)
         or user_id = v_uid;
      if v_emu then
        raise exception 'EMULATOR_BLOCKED';
      end if;
    end if;
  end if;

  update public.profiles
  set pin_hash            = crypt(p_pin, gen_salt('bf', 10)),
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null
  where id = v_uid;
  if not found then
    insert into public.profiles (id, pin_hash)
    values (v_uid, crypt(p_pin, gen_salt('bf', 10)))
    on conflict (id) do update set
      pin_hash            = excluded.pin_hash,
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null;
  end if;
  return true;
end;
$$;

revoke all on function public.set_login_pin(text, text) from public;
grant execute on function public.set_login_pin(text, text) to authenticated;

-- Forgot-PIN reset for the signed-in user.
create or replace function public.clear_login_pin()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'clear_login_pin requires an authenticated session';
  end if;
  update public.profiles
  set pin_hash            = null,
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null
  where id = v_uid;
  return found;
end;
$$;

revoke all on function public.clear_login_pin() from public;
grant execute on function public.clear_login_pin() to authenticated;

-- Pre-login PIN check. Returns the user's UUID on match, null on mismatch.
-- Rate limited: 5 consecutive failures lock verification for 15 minutes and
-- the function raises 'PIN_LOCKED:<seconds-remaining>' while locked.
create or replace function public.verify_pin_for_login(p_phone text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_digits   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_row      record;
  v_matched  boolean := false;
  v_attempts integer;
begin
  select p.id, p.pin, p.login_pin, p.pin_hash,
         p.pin_failed_attempts, p.pin_locked_until
    into v_row
    from public.profiles p
   where p.phone = any (array_remove(array[
           '+' || v_digits,
           v_digits,
           '0' || v_digits,
           ltrim(v_digits, '0')
         ], null))
   limit 1;

  if v_row.id is null then
    return null;
  end if;

  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    raise exception 'PIN_LOCKED:%',
      ceil(extract(epoch from (v_row.pin_locked_until - now())))::integer;
  end if;

  if v_row.pin_hash is not null and v_row.pin_hash <> '' then
    v_matched := v_row.pin_hash = crypt(p_pin, v_row.pin_hash);
  end if;
  -- Legacy plaintext columns (rows written before the 0052 backfill).
  if not v_matched then
    v_matched :=
         (v_row.login_pin is not null and v_row.login_pin <> '' and v_row.login_pin = p_pin)
      or (v_row.pin       is not null and v_row.pin       <> '' and v_row.pin       = p_pin);
  end if;

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null,
           -- Opportunistic upgrade: hash any remaining legacy plaintext PIN.
           pin_hash = case when pin_hash is null or pin_hash = ''
                           then crypt(p_pin, gen_salt('bf', 10))
                           else pin_hash end,
           pin       = null,
           login_pin = null
     where id = v_row.id;
    return v_row.id;
  end if;

  v_attempts := coalesce(v_row.pin_failed_attempts, 0) + 1;
  if v_attempts >= 5 then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = now() + interval '15 minutes'
     where id = v_row.id;
  else
    update public.profiles
       set pin_failed_attempts = v_attempts
     where id = v_row.id;
  end if;
  return null;
end;
$$;

revoke all on function public.verify_pin_for_login(text, text) from public;
grant execute on function public.verify_pin_for_login(text, text) to anon, authenticated;

-- Pre-login phone lookup used by the login screen: exposes only booleans,
-- never the profile row itself.
create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array[
      '+' || d,
      d,
      '0' || d,
      ltrim(d, '0')
    ], null) as v
    from digits
  ),
  match as (
    select p.pin, p.login_pin, p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select
    exists(select 1 from match)                                    as has_profile,
    coalesce((select (pin is not null and pin <> '')
                  or (login_pin is not null and login_pin <> '')
                  or (pin_hash is not null and pin_hash <> '')
              from match), false)                                  as has_pin,
    coalesce((select lower(profile_status::text) = 'deleted'
              from match), false)                                  as is_deleted;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- Device-based duplicate-account guard for the sign-up flow (migration 0071).
-- Returns how many DISTINCT accounts other than the caller have signed in from
-- a given device_id — a bare count, never PII — so the client can block bulk
-- multi-accounting on one physical device. SECURITY DEFINER because the 0069
-- RLS lockdown otherwise limits a client to its own user_sessions rows.
create or replace function public.device_prior_account_count(p_device_id text)
returns integer
language sql
security definer
set search_path = public
stable
as $$
  select count(distinct user_id)::int
  from public.user_sessions
  where p_device_id is not null
    and p_device_id <> ''
    and device_id = p_device_id
    and user_id is not null
    and user_id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);
$$;

revoke all on function public.device_prior_account_count(text) from public;
grant execute on function public.device_prior_account_count(text) to anon, authenticated;

-- Device-guard config (migration 0072), stored in app_settings key
-- 'device_account_guard' = { enabled, maxAccountsPerDevice }. Effective values
-- with safe defaults when the row is absent.
-- Effective config: enabled + cumulative account cap + opt-in emulator block
-- (migration 0074), with safe defaults when the app_settings row is absent.
create or replace function public.device_guard_config()
returns table (enabled boolean, max_accounts int, block_emulators boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v jsonb;
begin
  select value into v from public.app_settings where key = 'device_account_guard';
  enabled := coalesce((v->>'enabled')::boolean, true);
  max_accounts := greatest(1, coalesce((v->>'maxAccountsPerDevice')::int, 3));
  block_emulators := coalesce((v->>'blockEmulators')::boolean, false);
  return next;
end;
$$;

revoke all on function public.device_guard_config() from public;
grant execute on function public.device_guard_config() to anon, authenticated;

-- Client pre-check for the sign-up flow: whether a new registration is allowed
-- on this device plus the signals behind the decision.
create or replace function public.device_registration_status(p_device_id text)
returns table (
  allowed boolean,
  prior_accounts int,
  max_accounts int,
  enabled boolean,
  is_emulator boolean,
  block_emulators boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_enabled boolean;
  v_max int;
  v_block_emu boolean;
  v_prior int := 0;
  v_emu boolean := false;
  v_uid uuid := auth.uid();
begin
  select c.enabled, c.max_accounts, c.block_emulators
    into v_enabled, v_max, v_block_emu
  from public.device_guard_config() c;
  if p_device_id is not null and p_device_id <> '' then
    select count(distinct user_id)::int into v_prior
    from public.user_sessions
    where device_id = p_device_id
      and user_id is not null
      and user_id <> coalesce(v_uid, '00000000-0000-0000-0000-000000000000'::uuid);
  end if;
  select coalesce(bool_or(is_physical_device is false), false) into v_emu
  from public.user_sessions
  where (p_device_id is not null and p_device_id <> '' and device_id = p_device_id)
     or (v_uid is not null and user_id = v_uid);
  allowed := (not v_enabled)
    or ((v_prior < v_max) and not (v_block_emu and v_emu));
  prior_accounts := v_prior;
  max_accounts := v_max;
  enabled := v_enabled;
  is_emulator := v_emu;
  block_emulators := v_block_emu;
  return next;
end;
$$;

revoke all on function public.device_registration_status(text) from public;
grant execute on function public.device_registration_status(text) to anon, authenticated;

-- Admin-only writer for the device-guard knobs.
create or replace function public.device_guard_set_config(
  p_enabled boolean,
  p_max_accounts int,
  p_block_emulators boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values (
    'device_account_guard',
    jsonb_build_object(
      'enabled', coalesce(p_enabled, true),
      'maxAccountsPerDevice', greatest(1, coalesce(p_max_accounts, 3)),
      'blockEmulators', coalesce(p_block_emulators, false)
    ),
    now()
  )
  on conflict (key) do update
    set value = excluded.value, updated_at = now();
  return true;
end;
$$;

revoke all on function public.device_guard_set_config(boolean, int, boolean) from public;
grant execute on function public.device_guard_set_config(boolean, int, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.partners enable row level security;
alter table public.vehicles enable row level security;
alter table public.vehicle_make_models enable row level security;
alter table public.partner_documents enable row level security;
alter table public.settings_entries enable row level security;
alter table public.app_settings enable row level security;
alter table public.rides enable row level security;
alter table public.countries enable row level security;
alter table public.states enable row level security;
alter table public.cities enable row level security;
alter table public.suburbs enable row level security;
alter table public.airport_areas enable row level security;
alter table public.required_document enable row level security;
alter table public.document_type enable row level security;
alter table public.driver_incentive enable row level security;
alter table public.multi_gate enable row level security;
alter table public.insurance_providers enable row level security;
alter table public.insurance_types enable row level security;
alter table public.insurance_durations enable row level security;
alter table public.insurance_premium enable row level security;
alter table public.ev_delivery_advisors enable row level security;
alter table public.ev_finance_options enable row level security;
alter table public.ev_order_fee enable row level security;
alter table public.ev_vehicle_details enable row level security;
alter table public.ev_vehicle_inventory enable row level security;

do $extra_pol$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$extra_pol$;

do $dedicated$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$dedicated$;

do $regions$
declare t text;
begin
  foreach t in array array['countries','states','cities','suburbs'] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$regions$;

drop policy if exists "profiles self read" on public.profiles;
drop policy if exists "profiles self write" on public.profiles;
create policy "profiles self read"
  on public.profiles for select
  using (auth.uid() = id);
create policy "profiles self write"
  on public.profiles for update
  using (auth.uid() = id);

drop policy if exists "partners read" on public.partners;
create policy "partners read"
  on public.partners for select
  using (auth.role() = 'authenticated');

drop policy if exists "vehicles read" on public.vehicles;
create policy "vehicles read"
  on public.vehicles for select
  using (true);

drop policy if exists "vehicle_make_models read" on public.vehicle_make_models;
create policy "vehicle_make_models read"
  on public.vehicle_make_models for select
  using (true);

drop policy if exists "partner_documents own" on public.partner_documents;
create policy "partner_documents own"
  on public.partner_documents for select
  using (
    exists (
      select 1 from public.partners p
      where p.id = partner_documents.partner_id
        and p.auth_user_id = auth.uid()
    )
  );

drop policy if exists "settings_entries read" on public.settings_entries;
create policy "settings_entries read"
  on public.settings_entries for select
  using (true);

-- ---------------------------------------------------------------------------
-- Admin access control (migration 0009, folded in) — one row per
-- (profile, page) pair; a profile with ANY row is considered an admin, and
-- page='*' grants every admin page at the given level. Also backs the
-- app_settings secret-row policies below.
-- ---------------------------------------------------------------------------
do $$ begin
  create type admin_access_level as enum ('read','edit');
exception when duplicate_object then null; end $$;

create table if not exists public.admin_access (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  page          text not null,
  access_level  admin_access_level not null default 'read',
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (profile_id, page)
);

create index if not exists admin_access_profile_idx on public.admin_access(profile_id);
create index if not exists admin_access_page_idx    on public.admin_access(page);

-- Support-agent priority tag (migration 0037): "1","2","3"… decides who a new
-- ticket auto-assigns to (lowest first).
alter table public.admin_access
  add column if not exists support integer;

create index if not exists admin_access_support_idx
  on public.admin_access(support) where support is not null;

drop trigger if exists trg_admin_access_updated_at on public.admin_access;
create trigger trg_admin_access_updated_at
  before update on public.admin_access
  for each row execute function public.set_updated_at();

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

alter table public.admin_access enable row level security;

drop policy if exists "admin_access self read" on public.admin_access;
create policy "admin_access self read"
  on public.admin_access for select
  using (profile_id = auth.uid());

drop policy if exists "admin_access admin read" on public.admin_access;
create policy "admin_access admin read"
  on public.admin_access for select
  using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

drop policy if exists "admin_access admin write insert" on public.admin_access;
create policy "admin_access admin write insert"
  on public.admin_access for insert
  with check (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

drop policy if exists "admin_access admin write update" on public.admin_access;
create policy "admin_access admin write update"
  on public.admin_access for update
  using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

drop policy if exists "admin_access admin write delete" on public.admin_access;
create policy "admin_access admin write delete"
  on public.admin_access for delete
  using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

grant select, insert, update, delete on public.admin_access to anon, authenticated;

-- ---------------------------------------------------------------------------
-- app_settings (0066): the 'fare_ai_provider' row holds SECRET AI provider
-- API keys. It is only visible/writable to admin_access holders and the
-- service role (used by the ai-route-proxy edge function); every other row
-- keeps the open policies the app relies on.
-- ---------------------------------------------------------------------------
create or replace function public.app_settings_secret_access()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (setup scripts, psql)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  if auth.uid() is null then
    return false;
  end if;
  if to_regclass('public.admin_access') is null then
    return false;
  end if;
  return exists (
    select 1 from public.admin_access where profile_id = auth.uid()
  );
end;
$$;

grant execute on function public.app_settings_secret_access() to anon, authenticated;

drop policy if exists "app_settings read" on public.app_settings;
create policy "app_settings read"
  on public.app_settings for select
  using (key <> 'fare_ai_provider' or public.app_settings_secret_access());

drop policy if exists "app_settings insert" on public.app_settings;
create policy "app_settings insert"
  on public.app_settings for insert to public
  with check (key <> 'fare_ai_provider' or public.app_settings_secret_access());

drop policy if exists "app_settings update" on public.app_settings;
create policy "app_settings update"
  on public.app_settings for update to public
  using (key <> 'fare_ai_provider' or public.app_settings_secret_access())
  with check (key <> 'fare_ai_provider' or public.app_settings_secret_access());

drop policy if exists "app_settings delete" on public.app_settings;
create policy "app_settings delete"
  on public.app_settings for delete to public
  using (key <> 'fare_ai_provider' or public.app_settings_secret_access());

drop policy if exists "rides participant" on public.rides;
create policy "rides participant"
  on public.rides for select
  using (
    rider_id = auth.uid()
    or exists (
      select 1 from public.partners p
      where p.id = rides.partner_id and p.auth_user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- Storage buckets
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('partner-documents', 'partner-documents', false),
  ('app-assets', 'app-assets', true),
  ('ride-attachments', 'ride-attachments', false),
  ('ID_Image', 'ID_Image', true),
  ('support-media', 'support-media', true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Support: tickets / messages / calls (see migration 0036_support.sql for the
-- full RLS + realtime setup; tables created here for fresh installs).
-- ---------------------------------------------------------------------------
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null default 'Support',
  status text not null default 'open' check (status in ('open','pending','closed')),
  last_message text,
  last_message_at timestamptz,
  last_sender_role text check (last_sender_role in ('user','admin')),
  unread_admin integer not null default 0,
  unread_user integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_role text not null check (sender_role in ('user','admin')),
  sender_id uuid,
  type text not null default 'text' check (type in ('text','image','video','audio','location')),
  body text,
  media_url text,
  media_duration numeric,
  latitude double precision,
  longitude double precision,
  status text not null default 'sent' check (status in ('sent','delivered','read')),
  created_at timestamptz not null default now()
);

create table if not exists public.support_calls (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid references public.support_tickets(id) on delete set null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  caller_role text not null default 'admin' check (caller_role in ('admin')),
  caller_name text,
  media text not null default 'voice' check (media in ('voice','video')),
  status text not null default 'ringing' check (status in ('ringing','accepted','declined','ended','missed')),
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

-- Ticket statuses, agent assignment and reply authorship (migration 0037).
alter table public.support_tickets
  drop constraint if exists support_tickets_status_check;
alter table public.support_tickets
  add constraint support_tickets_status_check
  check (status in ('open','in_progress','pending','closed'));

alter table public.support_tickets
  add column if not exists assigned_admin_id uuid references public.profiles(id) on delete set null,
  add column if not exists assigned_admin_name text,
  add column if not exists assigned_at timestamptz;

create index if not exists support_tickets_assigned_idx
  on public.support_tickets(assigned_admin_id);

alter table public.support_messages
  add column if not exists sender_name text;

alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
alter table public.support_calls enable row level security;

do $support_pol$
declare t text;
begin
  foreach t in array array['support_tickets','support_messages','support_calls'] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$support_pol$;

drop policy if exists "public read support-media" on storage.objects;
drop policy if exists "anon upload support-media" on storage.objects;
drop policy if exists "auth update support-media" on storage.objects;
drop policy if exists "auth delete support-media" on storage.objects;
create policy "public read support-media"
  on storage.objects for select using (bucket_id = 'support-media');
create policy "anon upload support-media"
  on storage.objects for insert to anon, authenticated with check (bucket_id = 'support-media');
create policy "auth update support-media"
  on storage.objects for update to anon, authenticated using (bucket_id = 'support-media');
create policy "auth delete support-media"
  on storage.objects for delete to anon, authenticated using (bucket_id = 'support-media');

drop policy if exists "public read avatars" on storage.objects;
drop policy if exists "public read app-assets" on storage.objects;
create policy "public read avatars"
  on storage.objects for select
  using (bucket_id = 'avatars');
create policy "public read app-assets"
  on storage.objects for select
  using (bucket_id = 'app-assets');

drop policy if exists "users upload own avatar" on storage.objects;
drop policy if exists "users update own avatar" on storage.objects;
drop policy if exists "auth upload avatars" on storage.objects;
drop policy if exists "auth update avatars" on storage.objects;
drop policy if exists "auth delete avatars" on storage.objects;

create policy "auth upload avatars"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth update avatars"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  )
  with check (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth delete avatars"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

drop policy if exists "partner doc owner read" on storage.objects;
drop policy if exists "partner doc owner write" on storage.objects;
create policy "partner doc owner read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'partner-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "partner doc owner write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'partner-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "public read id_image" on storage.objects;
drop policy if exists "auth upload id_image" on storage.objects;
drop policy if exists "auth update id_image" on storage.objects;
drop policy if exists "auth delete id_image" on storage.objects;

create policy "public read id_image"
  on storage.objects for select
  using (bucket_id = 'ID_Image');

create policy "auth upload id_image"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth update id_image"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  )
  with check (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth delete id_image"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

-- ============================================================================
-- Push notifications (Expo push tokens + dispatch log)
-- ----------------------------------------------------------------------------
-- See migrations/00421_push_notifications.sql. Kept here so a fresh bootstrap
-- includes the tables. Tokens are read by the `send-push` edge function with
-- the service-role key; RLS is permissive to match the rest of this project.
-- ============================================================================

create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text,
  device_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists push_tokens_profile_idx
  on public.push_tokens(profile_id);

create table if not exists public.push_notifications (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  audience text not null default 'all',
  recipients integer not null default 0,
  sent integer not null default 0,
  failed integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists push_notifications_created_idx
  on public.push_notifications(created_at desc);

do $$
begin
  drop trigger if exists trg_push_tokens_updated_at on public.push_tokens;
  create trigger trg_push_tokens_updated_at before update on public.push_tokens
    for each row execute function public.set_updated_at();
end$$;

alter table public.push_tokens enable row level security;
alter table public.push_notifications enable row level security;

drop policy if exists "push_tokens read"   on public.push_tokens;
drop policy if exists "push_tokens insert" on public.push_tokens;
drop policy if exists "push_tokens update" on public.push_tokens;
drop policy if exists "push_tokens delete" on public.push_tokens;

create policy "push_tokens read"   on public.push_tokens for select using (true);
create policy "push_tokens insert" on public.push_tokens for insert to public with check (true);
create policy "push_tokens update" on public.push_tokens for update to public using (true) with check (true);
create policy "push_tokens delete" on public.push_tokens for delete to public using (true);

drop policy if exists "push_notifications read"   on public.push_notifications;
drop policy if exists "push_notifications insert" on public.push_notifications;
drop policy if exists "push_notifications delete" on public.push_notifications;

create policy "push_notifications read"   on public.push_notifications for select using (true);
create policy "push_notifications insert" on public.push_notifications for insert to public with check (true);
create policy "push_notifications delete" on public.push_notifications for delete to public using (true);

grant select, insert, update, delete on public.push_tokens to anon, authenticated;
grant select, insert, update, delete on public.push_notifications to anon, authenticated;

-- ============================================================================
-- Ride requests (real passenger → partner ride hailing). See migration
-- 0046_ride_requests.sql. Kept here so a fresh bootstrap includes the table.
-- ============================================================================
create table if not exists public.ride_requests (
  id uuid primary key default gen_random_uuid(),
  rider_id      uuid references public.profiles(id) on delete set null,
  rider_name    text,
  rider_phone   text,
  rider_photo   text,
  rider_rating  numeric(3,2) not null default 5,
  service       text,
  payment_mode  text not null default 'Cash',
  pickup_name   text,
  pickup_address text,
  pickup_lat    double precision,
  pickup_lng    double precision,
  drop_name     text,
  drop_address  text,
  drop_lat      double precision,
  drop_lng      double precision,
  distance_km   numeric(10,2),
  duration_min  integer,
  fare          numeric(10,2),
  currency      text not null default 'MYR',
  passengers    integer not null default 1,
  luggage       integer not null default 0,
  note          text,

  -- Bidding (OfferMe) ----------------------------------------------------------
  offer_me      boolean not null default false,
  offered_fare  numeric(10,2),

  -- Fare breakdown -------------------------------------------------------------
  ride_fare     numeric(10,2),
  toll_charges  numeric(10,2),
  other_charges numeric(10,2),

  -- Partner location checkpoints -----------------------------------------------
  partner_accept_lat double precision,
  partner_accept_lng double precision,
  partner_arrive_lat double precision,
  partner_arrive_lng double precision,
  partner_drop_lat   double precision,
  partner_drop_lng   double precision,

  -- User location checkpoints --------------------------------------------------
  user_accept_lat double precision,
  user_accept_lng double precision,
  user_arrive_lat double precision,
  user_arrive_lng double precision,
  user_drop_lat   double precision,
  user_drop_lng   double precision,

  -- Trip OTP -------------------------------------------------------------------
  otp           text,

  -- Vehicle + address geography ------------------------------------------------
  vehicle_id    text,
  full_address  text,
  country       text,
  state         text,
  city          text,
  suburb        text,

  -- Device / identity metadata -------------------------------------------------
  device_os     text,
  ip_address    text,
  gender        text,

  status        text not null default 'open'
    check (status in ('open','accepted','arrived','on_trip','completed','cancelled','expired')),
  partner_id        uuid,
  partner_name      text,
  partner_phone     text,
  partner_photo     text,
  partner_vehicle   text,
  partner_plate     text,
  partner_rating    numeric(3,2),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  accepted_at   timestamptz,
  arrived_at    timestamptz,
  started_at    timestamptz,
  completed_at  timestamptz,
  cancelled_at  timestamptz,

  -- Driver-approved cancellation (0053): set when the passenger asks to cancel
  -- an already-started trip; cleared if the driver declines.
  cancel_requested_at timestamptz,
  cancel_requested_by text,

  -- Why the ride was cancelled (0054): free-text/preset reason chosen by the
  -- rider (or driver) when cancelling.
  cancel_reason text,

  -- Live location sharing (0055): continuously updated GPS fixes published by
  -- the partner and the passenger during an active ride.
  partner_live_lat     double precision,
  partner_live_lng     double precision,
  partner_live_heading double precision,
  partner_live_at      timestamptz,
  user_live_lat        double precision,
  user_live_lng        double precision,
  user_live_at         timestamptz,

  -- Ride commission (0057): platform commission auto-deducted from the
  -- partner's GET.credit wallet when the trip completes.
  commission_rate       numeric(6,4),
  commission_amount     numeric(12,2),
  commission_charged_at timestamptz
);

-- Idempotent upgrade for databases created before 0053/0054/0055.
alter table public.ride_requests
  add column if not exists cancel_requested_at timestamptz,
  add column if not exists cancel_requested_by text,
  add column if not exists cancel_reason text,
  add column if not exists partner_live_lat     double precision,
  add column if not exists partner_live_lng     double precision,
  add column if not exists partner_live_heading double precision,
  add column if not exists partner_live_at      timestamptz,
  add column if not exists user_live_lat        double precision,
  add column if not exists user_live_lng        double precision,
  add column if not exists user_live_at         timestamptz,
  add column if not exists commission_rate       numeric(6,4),
  add column if not exists commission_amount     numeric(12,2),
  add column if not exists commission_charged_at timestamptz;

create index if not exists ride_requests_status_idx       on public.ride_requests(status);
create index if not exists ride_requests_rider_idx        on public.ride_requests(rider_id);
create index if not exists ride_requests_partner_idx      on public.ride_requests(partner_id);
create index if not exists ride_requests_open_created_idx on public.ride_requests(created_at desc) where status = 'open';

do $$
begin
  drop trigger if exists trg_ride_requests_updated_at on public.ride_requests;
  create trigger trg_ride_requests_updated_at before update on public.ride_requests
    for each row execute function public.set_updated_at();
end$$;

alter table public.ride_requests enable row level security;

drop policy if exists "ride_requests read"   on public.ride_requests;
drop policy if exists "ride_requests insert" on public.ride_requests;
drop policy if exists "ride_requests update" on public.ride_requests;
drop policy if exists "ride_requests delete" on public.ride_requests;

create policy "ride_requests read"   on public.ride_requests for select using (true);
create policy "ride_requests insert" on public.ride_requests for insert to public with check (true);
create policy "ride_requests update" on public.ride_requests for update to public using (true) with check (true);
create policy "ride_requests delete" on public.ride_requests for delete to public using (true);

grant select, insert, update, delete on public.ride_requests to anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.ride_requests;
exception when duplicate_object then null; end$$;
alter table public.ride_requests replica identity full;

-- ============================================================================
-- IP access rules: admin-managed whitelist / blacklist
-- ============================================================================
create table if not exists public.ip_access_rules (
  id uuid primary key default gen_random_uuid(),
  ip_address text not null,
  list_type  text not null default 'blacklist'
    check (list_type in ('whitelist','blacklist')),
  label      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (ip_address, list_type)
);

create index if not exists ip_access_rules_type_idx on public.ip_access_rules(list_type);
create index if not exists ip_access_rules_ip_idx   on public.ip_access_rules(ip_address);

do $$
begin
  drop trigger if exists trg_ip_access_rules_updated_at on public.ip_access_rules;
  create trigger trg_ip_access_rules_updated_at before update on public.ip_access_rules
    for each row execute function public.set_updated_at();
end$$;

alter table public.ip_access_rules enable row level security;

drop policy if exists "ip_access_rules read"   on public.ip_access_rules;
drop policy if exists "ip_access_rules insert" on public.ip_access_rules;
drop policy if exists "ip_access_rules update" on public.ip_access_rules;
drop policy if exists "ip_access_rules delete" on public.ip_access_rules;

create policy "ip_access_rules read"   on public.ip_access_rules for select using (true);
create policy "ip_access_rules insert" on public.ip_access_rules for insert to public with check (true);
create policy "ip_access_rules update" on public.ip_access_rules for update to public using (true) with check (true);
create policy "ip_access_rules delete" on public.ip_access_rules for delete to public using (true);

grant select, insert, update, delete on public.ip_access_rules to anon, authenticated;

-- ============================================================================
-- Wallets — GET.wallet (master) + GET.credit (partner credit)
-- (migrations/0056_wallets.sql + 0057_ride_commission.sql, folded in)
-- ----------------------------------------------------------------------------
-- GET.wallet : master wallet, used by the account in both user & partner mode.
-- GET.credit : partner-only wallet used to pay for in-app services and
--              commissions. Recharged (transferred) from GET.wallet.
-- ============================================================================
create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_type text not null check (wallet_type in ('get_wallet','get_credit')),
  balance numeric(12,2) not null default 0,
  currency text not null default 'RM',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, wallet_type),
  -- GET.credit may go negative (commission owed); GET.wallet stays >= 0.
  constraint wallets_balance_check check (wallet_type = 'get_credit' or balance >= 0)
);

-- Idempotent upgrade for databases created before 0057 (old check forced all
-- wallet balances to be non-negative).
alter table public.wallets drop constraint if exists wallets_balance_check;
alter table public.wallets add constraint wallets_balance_check
  check (wallet_type = 'get_credit' or balance >= 0);

create index if not exists wallets_user_idx on public.wallets(user_id);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  wallet_type text not null check (wallet_type in ('get_wallet','get_credit')),
  kind text not null,
  amount numeric(12,2) not null,
  balance_after numeric(12,2),
  method text,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists wallet_tx_user_idx
  on public.wallet_transactions(user_id, created_at desc);

do $$
begin
  drop trigger if exists trg_wallets_updated_at on public.wallets;
  create trigger trg_wallets_updated_at before update on public.wallets
    for each row execute function public.set_updated_at();
end$$;

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;

-- Locked down in 0066: balances/history stay readable (admin panel + the
-- user's own app), but the ledger can only be written through the
-- SECURITY DEFINER wallet RPCs below — direct client inserts would let any
-- anon-key holder mint money (the 0060 trigger moves wallets.balance for
-- every wallet_transactions row).
drop policy if exists "wallets read"   on public.wallets;
drop policy if exists "wallets insert" on public.wallets;
drop policy if exists "wallets update" on public.wallets;

create policy "wallets read"   on public.wallets for select using (true);

drop policy if exists "wallet_transactions read"   on public.wallet_transactions;
drop policy if exists "wallet_transactions insert" on public.wallet_transactions;

create policy "wallet_transactions read"   on public.wallet_transactions for select using (true);

grant select on public.wallets to anon, authenticated;
grant select on public.wallet_transactions to anon, authenticated;
revoke insert, update on public.wallets from anon, authenticated;
revoke insert on public.wallet_transactions from anon, authenticated;

-- ----------------------------------------------------------------------------
-- Caller assertion helper (0066): every wallet RPC verifies the caller owns
-- the wallet it moves. Direct DB sessions (no PostgREST JWT context) and the
-- service role are exempt.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_assert_caller(p_user uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $wac$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if p_user is null then
    raise exception 'invalid_user';
  end if;
  if v_claims is null or v_claims = '' then
    return; -- direct database session (no API JWT context)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return;
  end if;
  if auth.uid() is distinct from p_user then
    raise exception 'not_authorized';
  end if;
end;
$wac$;

-- Realtime: live wallet balance updates (migrations/0059_wallets_realtime.sql)
alter table public.wallets replica identity full;
alter table public.wallet_transactions replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.wallets;
exception
  when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.wallet_transactions;
exception
  when duplicate_object then null;
end$$;

-- ----------------------------------------------------------------------------
-- Ledger sync (0060): every wallet_transactions row drives wallets.balance.
-- INSERT applies the signed amount (creating the wallet row when missing) and
-- stamps balance_after; UPDATE/DELETE re-adjust. The wallets UPDATE fires the
-- realtime publication, so balances update live in the app no matter where a
-- transaction row came from (RPC, admin tools, SQL editor, integrations).
-- The wallet RPCs below only insert ledger rows — this trigger is the single
-- writer of wallets.balance.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_apply_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric(12,2);
begin
  if tg_op = 'INSERT' then
    insert into public.wallets (user_id, wallet_type, balance)
    values (new.user_id, new.wallet_type, 0)
    on conflict (user_id, wallet_type) do nothing;

    update public.wallets
       set balance = balance + new.amount, updated_at = now()
     where user_id = new.user_id and wallet_type = new.wallet_type
    returning balance into v_balance;

    new.balance_after := v_balance;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    update public.wallets
       set balance = balance - old.amount, updated_at = now()
     where user_id = old.user_id and wallet_type = old.wallet_type;

    insert into public.wallets (user_id, wallet_type, balance)
    values (new.user_id, new.wallet_type, 0)
    on conflict (user_id, wallet_type) do nothing;

    update public.wallets
       set balance = balance + new.amount, updated_at = now()
     where user_id = new.user_id and wallet_type = new.wallet_type
    returning balance into v_balance;

    new.balance_after := v_balance;
    return new;
  end if;

  update public.wallets
     set balance = balance - old.amount, updated_at = now()
   where user_id = old.user_id and wallet_type = old.wallet_type;
  return old;
end;
$$;

drop trigger if exists trg_wallet_tx_apply on public.wallet_transactions;
create trigger trg_wallet_tx_apply
  before insert or update or delete on public.wallet_transactions
  for each row execute function public.wallet_apply_transaction();

-- Admin-only (0096): nothing takes a payment before a top-up, so a
-- self-service top-up would mint money. A future gateway credits through
-- an edge function with the service role.
create or replace function public.wallet_topup(
  p_user uuid,
  p_amount numeric,
  p_method text default null
)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  w public.wallets;
begin
  if not public.caller_is_admin() then
    raise exception 'topup_requires_payment';
  end if;
  if p_user is null then
    raise exception 'invalid_user';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception 'invalid_amount';
  end if;

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves the balance.
  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, method, note)
  values
    (p_user, 'get_wallet', 'topup', p_amount, p_method, 'Top up GET.wallet');

  select * into w from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet';
  return w;
end;
$$;

create or replace function public.wallet_recharge_credit(
  p_user uuid,
  p_amount numeric
)
returns setof public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  w_master public.wallets;
  w_credit public.wallets;
begin
  perform public.wallet_assert_caller(p_user);
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_amount';
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0), (p_user, 'get_credit', 0)
  on conflict (user_id, wallet_type) do nothing;

  select * into w_master
    from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet'
   for update;

  if w_master.balance < p_amount then
    raise exception 'insufficient_balance';
  end if;

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves both balances.
  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, note)
  values
    (p_user, 'get_wallet', 'recharge_out', -p_amount, 'Recharge GET.credit'),
    (p_user, 'get_credit', 'recharge_in',   p_amount, 'Recharged from GET.wallet');

  select * into w_master from public.wallets
   where user_id = p_user and wallet_type = 'get_wallet';
  select * into w_credit from public.wallets
   where user_id = p_user and wallet_type = 'get_credit';

  return next w_master;
  return next w_credit;
end;
$$;

revoke execute on function public.wallet_topup(uuid, numeric, text) from public, anon;
grant execute on function public.wallet_topup(uuid, numeric, text) to authenticated, service_role;
grant execute on function public.wallet_recharge_credit(uuid, numeric) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Commission rates (0058): master default + hierarchical overrides.
-- Resolution priority: user > suburb > city > state > country > master (15%).
-- Managed from Admin -> Settings -> Commission Rates.
-- ----------------------------------------------------------------------------
create table if not exists public.commission_rates (
  id uuid primary key default gen_random_uuid(),
  level text not null check (level in ('master','country','state','city','suburb','user')),
  country text,
  state   text,
  city    text,
  suburb  text,
  user_id    uuid,
  user_label text,
  -- Fraction of the fare, e.g. 0.15 = 15%.
  rate numeric(6,4) not null check (rate >= 0 and rate < 1),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists commission_rates_scope_uidx
  on public.commission_rates (
    level,
    coalesce(lower(country), ''),
    coalesce(lower(state), ''),
    coalesce(lower(city), ''),
    coalesce(lower(suburb), ''),
    coalesce(user_id::text, '')
  );

create index if not exists commission_rates_level_idx on public.commission_rates(level);
create index if not exists commission_rates_user_idx  on public.commission_rates(user_id);

do $$
begin
  drop trigger if exists trg_commission_rates_updated_at on public.commission_rates;
  create trigger trg_commission_rates_updated_at before update on public.commission_rates
    for each row execute function public.set_updated_at();
end$$;

alter table public.commission_rates enable row level security;

drop policy if exists "commission_rates read"   on public.commission_rates;
drop policy if exists "commission_rates insert" on public.commission_rates;
drop policy if exists "commission_rates update" on public.commission_rates;
drop policy if exists "commission_rates delete" on public.commission_rates;

create policy "commission_rates read"   on public.commission_rates for select using (true);
create policy "commission_rates insert" on public.commission_rates for insert to public with check (true);
create policy "commission_rates update" on public.commission_rates for update to public using (true) with check (true);
create policy "commission_rates delete" on public.commission_rates for delete to public using (true);

grant select, insert, update, delete on public.commission_rates to anon, authenticated;

-- Server-side rate resolution mirroring the client priority chain.
create or replace function public.commission_resolve_rate(
  p_user uuid default null,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rate numeric;
begin
  if p_user is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'user' and user_id = p_user
     limit 1;
    if found then return v_rate; end if;
  end if;

  if p_suburb is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'suburb'
       and lower(suburb) = lower(p_suburb)
       and (city    is null or p_city    is null or lower(city)    = lower(p_city))
       and (state   is null or p_state   is null or lower(state)   = lower(p_state))
       and (country is null or p_country is null or lower(country) = lower(p_country))
     limit 1;
    if found then return v_rate; end if;
  end if;

  if p_city is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'city'
       and lower(city) = lower(p_city)
       and (state   is null or p_state   is null or lower(state)   = lower(p_state))
       and (country is null or p_country is null or lower(country) = lower(p_country))
     limit 1;
    if found then return v_rate; end if;
  end if;

  if p_state is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'state'
       and lower(state) = lower(p_state)
       and (country is null or p_country is null or lower(country) = lower(p_country))
     limit 1;
    if found then return v_rate; end if;
  end if;

  if p_country is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'country'
       and lower(country) = lower(p_country)
     limit 1;
    if found then return v_rate; end if;
  end if;

  select rate into v_rate from public.commission_rates
   where active and level = 'master'
   limit 1;
  if found then return v_rate; end if;

  return 0.15;
end;
$$;

grant execute on function public.commission_resolve_rate(uuid, text, text, text, text)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Atomic, idempotent ride-commission charge (0057, updated in 0058): deducts
-- the platform commission from the partner's GET.credit when a trip completes.
-- Locks the ride row; if it was already charged, returns without deducting
-- again. When p_rate is null, the rate is resolved from commission_rates via
-- the ride's stored geography + the partner's user override.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_charge_ride_commission(
  p_ride uuid,
  p_partner uuid,
  p_fare numeric,
  p_rate numeric default null
)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  w public.wallets;
  v_rate numeric;
  v_amount numeric(12,2);
  v_claims text := current_setting('request.jwt.claims', true);
  v_privileged boolean;
begin
  perform public.wallet_assert_caller(p_partner);
  if p_fare is null or p_fare <= 0 then
    raise exception 'invalid_fare';
  end if;

  select * into r from public.ride_requests where id = p_ride for update;
  if not found then
    raise exception 'ride_not_found';
  end if;

  if r.partner_id is not null and r.partner_id <> p_partner then
    raise exception 'not_authorized';
  end if;

  -- Already charged: idempotent no-op.
  if r.commission_charged_at is not null then
    select * into w from public.wallets
     where user_id = p_partner and wallet_type = 'get_credit';
    return w;
  end if;

  -- API callers can't pick their own rate — always resolve server-side
  -- (p_rate is honoured only for service-role / direct DB sessions).
  v_privileged := (v_claims is null or v_claims = '')
    or coalesce(auth.jwt() ->> 'role', '') = 'service_role';
  v_rate := case when v_privileged then p_rate else null end;
  if v_rate is null then
    v_rate := public.commission_resolve_rate(p_partner, r.country, r.state, r.city, r.suburb);
  end if;
  if v_rate is null or v_rate <= 0 or v_rate >= 1 then
    raise exception 'invalid_rate';
  end if;

  v_amount := round(p_fare * v_rate, 2);

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves the balance.
  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, note)
  values
    (p_partner, 'get_credit', 'commission', -v_amount,
     'Ride commission ' || round(v_rate * 100, 1) || '% of ' ||
     coalesce(r.currency, 'RM') || ' ' || round(p_fare, 2));

  update public.ride_requests
     set commission_rate = v_rate,
         commission_amount = v_amount,
         commission_charged_at = now()
   where id = p_ride;

  select * into w from public.wallets
   where user_id = p_partner and wallet_type = 'get_credit';
  return w;
end;
$$;

grant execute on function public.wallet_charge_ride_commission(uuid, uuid, numeric, numeric)
  to anon, authenticated;

-- ============================================================================
-- GET.coin — third wallet, available to BOTH user and partner mode
-- (migrations/0061_get_coin.sql .. 0065_wallet_transfer_approval.sql, folded in)
-- ----------------------------------------------------------------------------
-- GET.coin balances are denominated in "GC" (Get Coins), not currency. The
-- GC <-> currency exchange rate is set from Admin -> Settings -> Get Coin.
-- Coins are earned as ride rewards, spent on QR payments / fares, traded
-- against GET.wallet, and transferable P2P between accounts.
-- ============================================================================

-- Allow the coin wallet type on both ledger tables (upgrades the inline
-- checks from the original wallets DDL above).
alter table public.wallets
  drop constraint if exists wallets_wallet_type_check;
alter table public.wallets
  add constraint wallets_wallet_type_check
  check (wallet_type in ('get_wallet','get_credit','get_coin'));

alter table public.wallet_transactions
  drop constraint if exists wallet_transactions_wallet_type_check;
alter table public.wallet_transactions
  add constraint wallet_transactions_wallet_type_check
  check (wallet_type in ('get_wallet','get_credit','get_coin'));

-- ----------------------------------------------------------------------------
-- Exchange rate + rewards + market settings (single master row)
--   coins_per_currency      : GC per 1 unit of currency (RM). e.g. 10 =>
--                             RM1 = 10 GC, so 1 GC = RM0.10.
--   earn_coins_per_currency : GC earned per RM1 of completed-ride fare
--                             (0 disables ride rewards).
--   market_*                : market-speculated pricing — when enabled, the
--                             coin's RM value floats around the admin peg,
--                             driven by in-app signals (each toggleable).
--   max_supply              : hard cap on total GC in circulation (0 = none).
-- ----------------------------------------------------------------------------
create table if not exists public.get_coin_settings (
  id text primary key default 'master',
  coins_per_currency numeric(12,4) not null default 1 check (coins_per_currency > 0),
  earn_coins_per_currency numeric(12,4) not null default 0,
  market_enabled  boolean       not null default false,
  signal_trading  boolean       not null default true,
  signal_revenue  boolean       not null default true,
  signal_services boolean       not null default true,
  signal_signups  boolean       not null default true,
  signal_minting  boolean       not null default true,
  market_max_swing numeric(6,2) not null default 50,
  max_supply      numeric(18,2) not null default 0,
  currency text not null default 'RM',
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

-- Idempotent upgrades for databases created from a pre-0062/0063 snapshot.
alter table public.get_coin_settings
  add column if not exists earn_coins_per_currency numeric(12,4) not null default 0,
  add column if not exists market_enabled  boolean       not null default false,
  add column if not exists signal_trading  boolean       not null default true,
  add column if not exists signal_revenue  boolean       not null default true,
  add column if not exists signal_services boolean       not null default true,
  add column if not exists signal_signups  boolean       not null default true,
  add column if not exists signal_minting  boolean       not null default true,
  add column if not exists market_max_swing numeric(6,2) not null default 50,
  add column if not exists max_supply      numeric(18,2) not null default 0;

alter table public.get_coin_settings
  drop constraint if exists get_coin_settings_earn_rate_check;
alter table public.get_coin_settings
  add constraint get_coin_settings_earn_rate_check
  check (earn_coins_per_currency >= 0);

alter table public.get_coin_settings
  drop constraint if exists get_coin_settings_swing_check;
alter table public.get_coin_settings
  add constraint get_coin_settings_swing_check
  check (market_max_swing >= 0 and market_max_swing <= 95);

alter table public.get_coin_settings
  drop constraint if exists get_coin_settings_supply_check;
alter table public.get_coin_settings
  add constraint get_coin_settings_supply_check
  check (max_supply >= 0);

insert into public.get_coin_settings (id, coins_per_currency)
values ('master', 1)
on conflict (id) do nothing;

do $$
begin
  drop trigger if exists trg_get_coin_settings_updated_at on public.get_coin_settings;
  create trigger trg_get_coin_settings_updated_at before update on public.get_coin_settings
    for each row execute function public.set_updated_at();
end$$;

alter table public.get_coin_settings enable row level security;

drop policy if exists "get_coin_settings read"   on public.get_coin_settings;
drop policy if exists "get_coin_settings insert" on public.get_coin_settings;
drop policy if exists "get_coin_settings update" on public.get_coin_settings;

create policy "get_coin_settings read"   on public.get_coin_settings for select using (true);
create policy "get_coin_settings insert" on public.get_coin_settings for insert to public with check (true);
create policy "get_coin_settings update" on public.get_coin_settings for update to public using (true) with check (true);

grant select, insert, update on public.get_coin_settings to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Ride rewards (0062): idempotent per-ride GC reward, anchored on
-- ride_requests.coin_rewarded_at so a ride can never be rewarded twice.
-- ----------------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists coin_rewarded_at timestamptz;

-- Priced on the ride's stored fare; p_fare is ignored (migration 0093).
create or replace function public.wallet_award_ride_coins(
  p_ride uuid,
  p_user uuid,
  p_fare numeric
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_rate numeric;
  v_fare numeric;
  v_coins numeric;
begin
  perform public.wallet_assert_caller(p_user);

  select earn_coins_per_currency into v_rate
  from public.get_coin_settings
  where id = 'master';

  if v_rate is null or v_rate <= 0 then
    return 0;
  end if;

  -- Only the ride's rider can claim, only for a completed ride, only once.
  select * into r from public.ride_requests where id = p_ride for update;
  if not found then
    return 0;
  end if;
  if r.status <> 'completed' then
    return 0;
  end if;
  if r.rider_id is not null and r.rider_id <> p_user then
    raise exception 'not_authorized';
  end if;
  if r.coin_rewarded_at is not null then
    return 0;
  end if;

  -- The fare the trip was billed at, never the caller's number.
  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  if v_fare <= 0 or v_fare > 10000 then
    return 0;
  end if;

  v_coins := round(v_fare * v_rate, 2);
  if v_coins <= 0 then
    return 0;
  end if;

  update public.ride_requests
  set coin_rewarded_at = now()
  where id = p_ride;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
  values (p_user, 'get_coin', 'reward', v_coins, 'Ride reward');

  return v_coins;
end;
$$;

grant execute on function public.wallet_award_ride_coins(uuid, uuid, numeric) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Owner-scoped spending RPCs (0066) — replace the client's direct ledger
-- inserts for QR payments, ride-fare coin redemption and coin trading.
-- ----------------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists fare_coins_redeemed_at timestamptz;

-- QR payment from GET.wallet, optionally redeeming GET.coin first (coins
-- cover what they can at the admin rate, GET.wallet pays the rest).
create or replace function public.wallet_pay(
  p_user uuid,
  p_amount numeric,
  p_note text default null,
  p_method text default 'qr_scan',
  p_redeem_coins boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric := 0;
  v_coin_balance numeric := 0;
  v_wallet_balance numeric;
  v_max_coin_value numeric := 0;
  v_coin_value numeric := 0;
  v_coins_used numeric := 0;
  v_wallet_share numeric;
begin
  perform public.wallet_assert_caller(p_user);
  if v_amount <= 0 or v_amount > 100000 then
    raise exception 'invalid_amount';
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0), (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  if coalesce(p_redeem_coins, false) then
    select coins_per_currency into v_rate
    from public.get_coin_settings where id = 'master';

    if coalesce(v_rate, 0) > 0 then
      select balance into v_coin_balance
      from public.wallets
      where user_id = p_user and wallet_type = 'get_coin'
      for update;
      v_coin_balance := coalesce(v_coin_balance, 0);

      if v_coin_balance > 0 then
        v_max_coin_value := floor((v_coin_balance / v_rate) * 100) / 100;
        v_coin_value := least(v_max_coin_value, v_amount);
        v_coins_used := round(v_coin_value * v_rate, 2);
      end if;
    end if;
  end if;

  v_wallet_share := round(v_amount - v_coin_value, 2);

  select balance into v_wallet_balance
  from public.wallets
  where user_id = p_user and wallet_type = 'get_wallet'
  for update;

  if coalesce(v_wallet_balance, 0) < v_wallet_share then
    raise exception 'insufficient_balance';
  end if;

  if v_coins_used > 0 then
    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_coin', 'redeem', -v_coins_used, p_method,
       coalesce(p_note, 'Payment') || ' — paid with coins (RM' ||
       to_char(v_coin_value, 'FM999999990.00') || ')');
  end if;

  if v_wallet_share > 0 then
    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_wallet', 'payment', -v_wallet_share, p_method, p_note);
  end if;

  return jsonb_build_object(
    'coins_used', v_coins_used,
    'coin_value', v_coin_value,
    'wallet_paid', v_wallet_share
  );
end;
$$;

-- Redeem GET.coin towards a ride fare. Idempotent per ride via
-- ride_requests.fare_coins_redeemed_at (simulated rides pass p_ride = null
-- and rely on the client-side guard).
create or replace function public.wallet_redeem_fare_coins(
  p_user uuid,
  p_fare numeric,
  p_ride uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric := round(coalesce(p_fare, 0), 2);
  v_rate numeric;
  v_coin_balance numeric := 0;
  v_max_coin_value numeric := 0;
  v_coin_value numeric := 0;
  v_coins_used numeric := 0;
begin
  perform public.wallet_assert_caller(p_user);
  if v_fare <= 0 or v_fare > 10000 then
    raise exception 'invalid_amount';
  end if;

  select coins_per_currency into v_rate
  from public.get_coin_settings where id = 'master';
  if coalesce(v_rate, 0) <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  if p_ride is not null then
    select * into r from public.ride_requests where id = p_ride for update;
    if found then
      if r.rider_id is not null and r.rider_id <> p_user then
        raise exception 'not_authorized';
      end if;
      if r.fare_coins_redeemed_at is not null then
        return jsonb_build_object('coins_used', 0, 'coin_value', 0);
      end if;
      update public.ride_requests
         set fare_coins_redeemed_at = now()
       where id = p_ride;
    end if;
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_coin_balance
  from public.wallets
  where user_id = p_user and wallet_type = 'get_coin'
  for update;
  v_coin_balance := coalesce(v_coin_balance, 0);

  if v_coin_balance > 0 then
    v_max_coin_value := floor((v_coin_balance / v_rate) * 100) / 100;
    v_coin_value := least(v_max_coin_value, v_fare);
    v_coins_used := round(v_coin_value * v_rate, 2);
  end if;

  if v_coins_used <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, method, note)
  values
    (p_user, 'get_coin', 'redeem', -v_coins_used, 'ride_fare',
     'Ride fare — RM' || to_char(v_coin_value, 'FM999999990.00') || ' paid with coins');

  return jsonb_build_object('coins_used', v_coins_used, 'coin_value', v_coin_value);
end;
$$;

-- Buy GC with GET.wallet / sell GC back (0066, rate made server-side by 0089).
-- Priced from get_coin_trade_quote(): buys at max(market, peg), sells at
-- min(market, peg), so no sequence of trades can return more RM than it put
-- in. p_rate_per_gc is accepted for the apps' 4-argument call and ignored.
-- The supply cap is enforced on buys.
create or replace function public.wallet_trade_coins(
  p_user uuid,
  p_direction text,
  p_coins numeric,
  p_rate_per_gc numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins numeric := round(coalesce(p_coins, 0), 2);
  v_quote jsonb;
  v_rate numeric;
  v_amount numeric;
  v_max_supply numeric;
  v_circulating numeric;
  v_balance numeric;
  v_rate_note text;
begin
  perform public.wallet_assert_caller(p_user);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;
  if p_direction is null or p_direction not in ('buy', 'sell') then
    raise exception 'invalid_direction';
  end if;

  -- Serialise trades so each one prices off the market state the previous
  -- one left behind.
  perform 1 from public.get_coin_settings where id = 'master' for update;

  v_quote := public.get_coin_trade_quote();
  v_rate := case when p_direction = 'buy'
                 then (v_quote->>'buy_rate')::numeric
                 else (v_quote->>'sell_rate')::numeric end;
  if coalesce(v_rate, 0) <= 0 then
    raise exception 'rate_unavailable';
  end if;

  -- Round in the house's favour, so rounding can't add up to a profit
  -- over many small trades.
  v_amount := case when p_direction = 'buy'
                   then round(ceil(v_coins * v_rate * 100) / 100, 2)
                   else round(floor(v_coins * v_rate * 100) / 100, 2) end;
  if v_amount <= 0 then
    raise exception 'invalid_amount';
  end if;

  select coalesce(max_supply, 0) into v_max_supply
  from public.get_coin_settings where id = 'master';

  v_rate_note := 'RM' || to_char(round(v_rate, 4), 'FM999999990.0000') || '/GC';

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_wallet', 0), (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  if p_direction = 'buy' then
    if v_max_supply > 0 then
      select coalesce(sum(balance), 0) into v_circulating
      from public.wallets where wallet_type = 'get_coin';
      if v_circulating + v_coins > v_max_supply then
        raise exception 'supply_cap_reached';
      end if;
    end if;

    select balance into v_balance
    from public.wallets
    where user_id = p_user and wallet_type = 'get_wallet'
    for update;
    if coalesce(v_balance, 0) < v_amount then
      raise exception 'insufficient_balance';
    end if;

    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_wallet', 'payment', -v_amount, 'coin_trade',
       'Bought ' || v_coins || ' GC @ ' || v_rate_note),
      (p_user, 'get_coin', 'topup', v_coins, 'trade_buy',
       'Bought @ ' || v_rate_note);
  else
    select balance into v_balance
    from public.wallets
    where user_id = p_user and wallet_type = 'get_coin'
    for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_coins';
    end if;

    insert into public.wallet_transactions
      (user_id, wallet_type, kind, amount, method, note)
    values
      (p_user, 'get_coin', 'redeem', -v_coins, 'trade_sell',
       'Sold @ ' || v_rate_note),
      (p_user, 'get_wallet', 'topup', v_amount, 'coin_trade',
       'Sold ' || v_coins || ' GC @ ' || v_rate_note);
  end if;

  -- Server-written chart point (clients can't insert since 0069).
  if not exists (
    select 1 from public.get_coin_rate_history
    where recorded_at > now() - interval '15 minutes'
  ) then
    insert into public.get_coin_rate_history (rate_per_gc)
    values ((v_quote->>'market_rate')::numeric);
  end if;

  return jsonb_build_object(
    'coins', v_coins,
    'amount_currency', v_amount,
    'rate_per_gc', v_rate
  );
end;
$$;

grant execute on function public.wallet_pay(uuid, numeric, text, text, boolean) to anon, authenticated;
grant execute on function public.wallet_redeem_fare_coins(uuid, numeric, uuid) to anon, authenticated;
grant execute on function public.wallet_trade_coins(uuid, text, numeric, numeric) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Rate history (0063): snapshots of the market RM value of 1 GC, for the
-- trade screen's price chart. Writes are admin-only (Part 3 below, 0069);
-- wallet_trade_coins records a server-computed point at most every ~15 min
-- (0089). Nothing prices trades off this table.
-- ----------------------------------------------------------------------------
create table if not exists public.get_coin_rate_history (
  id uuid primary key default gen_random_uuid(),
  rate_per_gc numeric(14,6) not null check (rate_per_gc > 0),
  recorded_at timestamptz not null default now()
);

create index if not exists get_coin_rate_history_time_idx
  on public.get_coin_rate_history(recorded_at desc);

alter table public.get_coin_rate_history enable row level security;

drop policy if exists "coin rate history read"   on public.get_coin_rate_history;
drop policy if exists "coin rate history insert" on public.get_coin_rate_history;

create policy "coin rate history read"   on public.get_coin_rate_history for select using (true);
create policy "coin rate history insert" on public.get_coin_rate_history for insert to public with check (true);

grant select, insert on public.get_coin_rate_history to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Market stats (0063, updated by 0064): one security-definer RPC returning
-- every pricing signal over a 30-day window plus circulating supply, so
-- clients never need broad table read access. P2P transfers are excluded from
-- the "minted" signal — they only move coins already in circulation.
-- ----------------------------------------------------------------------------
create or replace function public.get_coin_market_stats()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_since    timestamptz := now() - interval '30 days';
  v_buy      numeric := 0;
  v_sell     numeric := 0;
  v_revenue  numeric := 0;
  v_services bigint  := 0;
  v_signups  bigint  := 0;
  v_minted   numeric := 0;
  v_supply   numeric := 0;
begin
  -- GC bought / sold through trading (30d)
  select coalesce(sum(amount), 0) into v_buy
  from public.wallet_transactions
  where wallet_type = 'get_coin' and method = 'trade_buy'
    and amount > 0 and created_at >= v_since;

  select coalesce(sum(-amount), 0) into v_sell
  from public.wallet_transactions
  where wallet_type = 'get_coin' and method = 'trade_sell'
    and amount < 0 and created_at >= v_since;

  -- App revenue from commissions charged to partners (30d)
  select coalesce(sum(-amount), 0) into v_revenue
  from public.wallet_transactions
  where wallet_type = 'get_credit' and kind = 'commission'
    and amount < 0 and created_at >= v_since;

  -- Completed services (30d)
  select count(*) into v_services
  from public.ride_requests
  where status = 'completed' and created_at >= v_since;

  -- New sign-ups: users + partners (30d)
  select
    (select count(*) from public.profiles where created_at >= v_since)
    + (select count(*) from public.partners where created_at >= v_since)
  into v_signups;

  -- New coins generated (rewards, admin grants, purchases) (30d) —
  -- p2p transfers move existing coins, so they don't count as minting.
  select coalesce(sum(amount), 0) into v_minted
  from public.wallet_transactions
  where wallet_type = 'get_coin' and amount > 0
    and coalesce(method, '') <> 'p2p_transfer'
    and created_at >= v_since;

  -- Total GC in circulation right now
  select coalesce(sum(balance), 0) into v_supply
  from public.wallets
  where wallet_type = 'get_coin';

  return jsonb_build_object(
    'trade_buy_gc',        v_buy,
    'trade_sell_gc',       v_sell,
    'commission_revenue',  v_revenue,
    'completed_services',  v_services,
    'new_signups',         v_signups,
    'minted_gc',           v_minted,
    'circulating_supply',  v_supply
  );
end;
$$;

grant execute on function public.get_coin_market_stats() to anon, authenticated;

-- 0090: names of other accounts shown to a sender are masked with this.
-- Masks an account name for display to someone who is not its owner:
-- first word + initial of the last word ("Ahmad bin Ali" -> "Ahmad A."),
-- a single word keeps only its first letter ("Kumar" -> "K***"). Null/blank
-- in, null out.
create or replace function public.wallet_mask_name(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when w is null or cardinality(w) = 0 then null
    when cardinality(w) = 1 then left(w[1], 1) || '***'
    else w[1] || ' ' || upper(left(w[cardinality(w)], 1)) || '.'
  end
  from (
    select nullif(regexp_split_to_array(btrim(coalesce(p_name, '')), '\s+'), array['']) as w
  ) t;
$$;

-- ----------------------------------------------------------------------------
-- Trade quote (0089): computeMarketRate (Expo utils/getCoinStore.ts, Flutter
-- get_coin.dart) ported to SQL over get_coin_settings + get_coin_market_stats.
-- The market rate only widens a spread around the peg: buy_rate =
-- max(market, peg), sell_rate = min(market, peg). The market signals react to
-- trades, so one symmetric rate would let a trader move the price and trade
-- against it.
-- ----------------------------------------------------------------------------
create or replace function public.get_coin_trade_quote()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s        public.get_coin_settings;
  v_stats  jsonb;
  v_peg    numeric := 0;
  v_p      numeric := 0;  -- signal pressure
  v_total  numeric;
  v_ratio  numeric;
  v_cap    numeric;
  v_mult   numeric := 1;
  v_market numeric;
begin
  select * into s from public.get_coin_settings where id = 'master';
  if not found or coalesce(s.coins_per_currency, 0) <= 0 then
    return jsonb_build_object(
      'peg', 0, 'market_rate', 0, 'buy_rate', 0, 'sell_rate', 0,
      'market_enabled', false);
  end if;

  v_peg := 1 / s.coins_per_currency;

  if s.market_enabled then
    v_stats := public.get_coin_market_stats();

    -- Same weights and log scales as computeMarketRate / _logNorm.
    if s.signal_trading then
      v_total := (v_stats->>'trade_buy_gc')::numeric + (v_stats->>'trade_sell_gc')::numeric;
      if v_total > 0 then
        v_p := v_p + 0.35 * ((v_stats->>'trade_buy_gc')::numeric
                             - (v_stats->>'trade_sell_gc')::numeric) / (v_total + 50);
      end if;
    end if;
    if s.signal_revenue then
      v_p := v_p + 0.25 * least(log(1 + greatest((v_stats->>'commission_revenue')::numeric, 0)) / 4, 1);
    end if;
    if s.signal_services then
      v_p := v_p + 0.2 * least(log(1 + greatest((v_stats->>'completed_services')::numeric, 0)) / 3, 1);
    end if;
    if s.signal_signups then
      v_p := v_p + 0.1 * least(log(1 + greatest((v_stats->>'new_signups')::numeric, 0)) / 2.5, 1);
    end if;
    if s.signal_minting then
      v_p := v_p - 0.3 * least(log(1 + greatest((v_stats->>'minted_gc')::numeric, 0)) / 4, 1);
    end if;
    if s.max_supply > 0 and (v_stats->>'circulating_supply')::numeric > 0 then
      v_ratio := least((v_stats->>'circulating_supply')::numeric / s.max_supply, 1);
      v_p := v_p + 0.3 * v_ratio * v_ratio;
    end if;

    v_cap := greatest(coalesce(s.market_max_swing, 0), 0) / 100;
    v_mult := 1 + least(greatest(v_p, -v_cap), v_cap);
  end if;

  v_market := round(v_peg * v_mult, 6);

  return jsonb_build_object(
    'peg',            v_peg,
    'market_rate',    v_market,
    'buy_rate',       greatest(v_market, v_peg),
    'sell_rate',      least(v_market, v_peg),
    'market_enabled', s.market_enabled
  );
end;
$$;

grant execute on function public.get_coin_trade_quote() to anon, authenticated;

-- ----------------------------------------------------------------------------
-- P2P transfers (0064): send GC straight to another account (user or
-- partner). Transfers move existing coins 1:1 — nothing is minted or burned.
-- Recipients are addressed by account id (scanned getpay:// QR) or by phone
-- number, resolved server-side (profiles are RLS-protected, so the client
-- cannot look other users up itself). The sender's wallet row is locked so
-- concurrent transfers can't overdraw it.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_transfer_coins(
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid    := p_to;
  v_to_name   text;
  v_from_name text;
  v_digits    text;
  v_balance   numeric;
  v_after     numeric;
  v_suffix    text := coalesce(' — ' || nullif(trim(p_note), ''), '');
begin
  perform public.wallet_assert_caller(p_from);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  if v_to is not null then
    select coalesce(name, '') into v_to_name from public.profiles where id = v_to;
    if not found then
      select coalesce(name, '') into v_to_name from public.partners where id = v_to;
      if not found then
        raise exception 'recipient_not_found';
      end if;
    end if;
  else
    -- Resolve by phone: compare digits only, so "+60 12-345 6789" and
    -- "0123456789" line up; fall back to matching the last 9 digits to
    -- bridge country-code prefixes.
    v_digits := regexp_replace(coalesce(p_to_phone, ''), '\D', '', 'g');
    if length(v_digits) < 7 then
      raise exception 'recipient_not_found';
    end if;

    select id, coalesce(name, '') into v_to, v_to_name
    from public.profiles
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
       or (length(v_digits) >= 9
           and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
    order by created_at
    limit 1;

    if v_to is null then
      select id, coalesce(name, '') into v_to, v_to_name
      from public.partners
      where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
         or (length(v_digits) >= 9
             and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
      order by created_at
      limit 1;
    end if;

    if v_to is null then
      raise exception 'recipient_not_found';
    end if;
  end if;

  if v_to = p_from then
    raise exception 'self_transfer';
  end if;

  -- 0090: the sender only ever sees a masked name ("Ahmad A."), so a phone
  -- number cannot be mapped to a full account name before acceptance.
  v_to_name := coalesce(public.wallet_mask_name(v_to_name), '');

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  -- Lock the sender's coin wallet so concurrent transfers serialise.
  insert into public.wallets (user_id, wallet_type, balance)
  values (p_from, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_balance
  from public.wallets
  where user_id = p_from and wallet_type = 'get_coin'
  for update;

  if v_balance is null or v_balance < v_coins then
    raise exception 'insufficient_coins';
  end if;

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves both balances.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values
    (p_from, 'get_coin', 'transfer_out', -v_coins, 'p2p_transfer',
     'Sent to ' || coalesce(nullif(v_to_name, ''), 'user') || v_suffix),
    (v_to, 'get_coin', 'transfer_in', v_coins, 'p2p_transfer',
     'Received from ' || coalesce(nullif(v_from_name, ''), 'user') || v_suffix);

  select balance into v_after
  from public.wallets
  where user_id = p_from and wallet_type = 'get_coin';

  return jsonb_build_object(
    'coins',          v_coins,
    'recipient_id',   v_to,
    'recipient_name', nullif(v_to_name, ''),
    'balance_after',  v_after
  );
end;
$$;

grant execute on function public.wallet_transfer_coins(uuid, numeric, uuid, text, text)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Transfer approval (0065): sending coins is a two-step handshake. The sender
-- creates a *pending* wallet_transfer_requests row (recipient resolved by id
-- or phone, soft balance check); the recipient gets a popup naming the sender
-- and the amount and accepts or declines. Coins only move on acceptance —
-- same ledger rows as the instant transfer above. Requests expire after 15
-- minutes and can be cancelled by the sender while pending. The push webhook
-- triggers (pg_net + Vault) live in migrations/0065_wallet_transfer_approval.sql.
--
-- State machine: pending -> accepted | declined | cancelled | expired | failed
-- ('failed' = sender no longer had enough coins at acceptance time).
-- ----------------------------------------------------------------------------
create table if not exists public.wallet_transfer_requests (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid not null,
  from_name text,
  to_user_id uuid not null,
  to_name text,
  -- GC being sent (locked in at request time).
  coins numeric(12,2) not null check (coins > 0),
  note text,
  status text not null default 'pending'
    check (status in ('pending','accepted','declined','cancelled','expired','failed')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  expires_at timestamptz not null default now() + interval '15 minutes'
);

create index if not exists wallet_transfer_requests_to_idx
  on public.wallet_transfer_requests(to_user_id, status, created_at desc);
create index if not exists wallet_transfer_requests_from_idx
  on public.wallet_transfer_requests(from_user_id, created_at desc);

alter table public.wallet_transfer_requests enable row level security;

-- Both parties watch rows over realtime; all writes go through the
-- security-definer RPCs below, so no insert/update policies are exposed.
-- Reads are limited to the sender, the recipient and admins: the select
-- policy is created in the 00891 section at the end of this file, after
-- caller_is_admin() exists. Until then RLS denies every client read.
drop policy if exists "wallet_transfer_requests read" on public.wallet_transfer_requests;

revoke select on public.wallet_transfer_requests from anon;
grant select on public.wallet_transfer_requests to authenticated;
-- 0097: clients only read this table; drop the default write grants.
revoke insert, update, delete, truncate, references, trigger
  on public.wallet_transfer_requests from anon, authenticated;

alter table public.wallet_transfer_requests replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.wallet_transfer_requests;
exception
  when duplicate_object then null;
end$$;

-- Step 1 — sender creates a pending transfer request.
create or replace function public.wallet_request_coin_transfer(
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid    := p_to;
  v_to_name   text;
  v_from_name text;
  v_digits    text;
  v_balance   numeric;
  v_request   public.wallet_transfer_requests;
begin
  perform public.wallet_assert_caller(p_from);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  if v_to is not null then
    select coalesce(name, '') into v_to_name from public.profiles where id = v_to;
    if not found then
      select coalesce(name, '') into v_to_name from public.partners where id = v_to;
      if not found then
        raise exception 'recipient_not_found';
      end if;
    end if;
  else
    v_digits := regexp_replace(coalesce(p_to_phone, ''), '\D', '', 'g');
    if length(v_digits) < 7 then
      raise exception 'recipient_not_found';
    end if;

    select id, coalesce(name, '') into v_to, v_to_name
    from public.profiles
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
       or (length(v_digits) >= 9
           and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
    order by created_at
    limit 1;

    if v_to is null then
      select id, coalesce(name, '') into v_to, v_to_name
      from public.partners
      where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
         or (length(v_digits) >= 9
             and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
      order by created_at
      limit 1;
    end if;

    if v_to is null then
      raise exception 'recipient_not_found';
    end if;
  end if;

  if v_to = p_from then
    raise exception 'self_transfer';
  end if;

  -- 0090: the sender only ever sees a masked name ("Ahmad A."), so a phone
  -- number cannot be mapped to a full account name before acceptance.
  v_to_name := coalesce(public.wallet_mask_name(v_to_name), '');

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  -- Soft balance check so obviously unfunded requests never reach the
  -- recipient. The authoritative check re-runs at acceptance time.
  select balance into v_balance
  from public.wallets
  where user_id = p_from and wallet_type = 'get_coin';

  if v_balance is null or v_balance < v_coins then
    raise exception 'insufficient_coins';
  end if;

  insert into public.wallet_transfer_requests
    (from_user_id, from_name, to_user_id, to_name, coins, note)
  values
    (p_from, nullif(v_from_name, ''), v_to, nullif(v_to_name, ''), v_coins,
     nullif(trim(coalesce(p_note, '')), ''))
  returning * into v_request;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'recipient_id',   v_to,
    'recipient_name', nullif(v_to_name, ''),
    'coins',          v_coins,
    'expires_at',     v_request.expires_at
  );
end;
$$;

grant execute on function public.wallet_request_coin_transfer(uuid, numeric, uuid, text, text)
  to anon, authenticated;

-- Step 2 — recipient accepts or declines. Returns the resulting status
-- ('accepted' | 'declined' | 'expired' | 'failed') rather than raising, so
-- the status write always commits.
create or replace function public.wallet_respond_coin_transfer(
  p_request uuid,
  p_user uuid,
  p_accept boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r         public.wallet_transfer_requests;
  v_balance numeric;
  v_suffix  text;
begin
  perform public.wallet_assert_caller(p_user);
  if p_request is null then
    raise exception 'invalid_user';
  end if;

  select * into r
  from public.wallet_transfer_requests
  where id = p_request
  for update;

  if not found then
    raise exception 'request_not_found';
  end if;
  if r.to_user_id <> p_user then
    raise exception 'not_recipient';
  end if;
  if r.status <> 'pending' then
    raise exception 'request_not_pending';
  end if;

  if now() > r.expires_at then
    update public.wallet_transfer_requests
       set status = 'expired', responded_at = now()
     where id = r.id;
    return jsonb_build_object('status', 'expired', 'coins', r.coins,
                              'from_name', r.from_name, 'to_name', r.to_name);
  end if;

  if not p_accept then
    update public.wallet_transfer_requests
       set status = 'declined', responded_at = now()
     where id = r.id;
    return jsonb_build_object('status', 'declined', 'coins', r.coins,
                              'from_name', r.from_name, 'to_name', r.to_name);
  end if;

  -- Lock the sender's coin wallet so concurrent transfers serialise.
  insert into public.wallets (user_id, wallet_type, balance)
  values (r.from_user_id, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_balance
  from public.wallets
  where user_id = r.from_user_id and wallet_type = 'get_coin'
  for update;

  if v_balance is null or v_balance < r.coins then
    update public.wallet_transfer_requests
       set status = 'failed', responded_at = now()
     where id = r.id;
    return jsonb_build_object('status', 'failed', 'coins', r.coins,
                              'from_name', r.from_name, 'to_name', r.to_name);
  end if;

  v_suffix := coalesce(' — ' || r.note, '');

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves both balances.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values
    (r.from_user_id, 'get_coin', 'transfer_out', -r.coins, 'p2p_transfer',
     'Sent to ' || coalesce(r.to_name, 'user') || v_suffix),
    (r.to_user_id, 'get_coin', 'transfer_in', r.coins, 'p2p_transfer',
     'Received from ' || coalesce(r.from_name, 'user') || v_suffix);

  update public.wallet_transfer_requests
     set status = 'accepted', responded_at = now()
   where id = r.id;

  return jsonb_build_object('status', 'accepted', 'coins', r.coins,
                            'from_name', r.from_name, 'to_name', r.to_name);
end;
$$;

grant execute on function public.wallet_respond_coin_transfer(uuid, uuid, boolean)
  to anon, authenticated;

-- Sender cancels their own pending request.
create or replace function public.wallet_cancel_transfer_request(
  p_request uuid,
  p_user uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wallet_assert_caller(p_user);
  update public.wallet_transfer_requests
     set status = 'cancelled', responded_at = now()
   where id = p_request and from_user_id = p_user and status = 'pending';
  return found;
end;
$$;

grant execute on function public.wallet_cancel_transfer_request(uuid, uuid)
  to anon, authenticated;

-- ============================================================================
-- Referral program (migrations/0078_referrals.sql, 0079_referrer_name_rpc.sql)
-- ----------------------------------------------------------------------------
-- Invite friends, both earn bonus GET.coin. apply_referral() is called by the
-- NEW user right after signup; get_my_referrer() lets that user learn who
-- invited them (for the profile "Referred" badge) without widening the
-- self-read RLS on public.profiles.
-- ============================================================================

alter table public.get_coin_settings
  add column if not exists referral_enabled boolean not null default true,
  add column if not exists referral_referrer_coins numeric(12,2) not null default 0,
  add column if not exists referral_referred_coins numeric(12,2) not null default 0;

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references public.profiles(id) on delete cascade,
  referred_user_id uuid not null references public.profiles(id) on delete cascade,
  code text not null,
  referrer_coins numeric(12,2) not null default 0,
  referred_coins numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  unique (referred_user_id),
  check (referrer_user_id <> referred_user_id)
);

create index if not exists referrals_referrer_idx
  on public.referrals (referrer_user_id);

alter table public.referrals enable row level security;

drop policy if exists "referrals select own" on public.referrals;
create policy "referrals select own" on public.referrals
  for select to authenticated
  using (auth.uid() = referrer_user_id or auth.uid() = referred_user_id);

-- Apply a referral code (called by the new user right after signup).
create or replace function public.apply_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_referrer uuid;
  v_created timestamptz;
  v_enabled boolean := true;
  v_referrer_coins numeric := 0;
  v_referred_coins numeric := 0;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if length(v_code) < 4 then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  -- New accounts only: a referral is part of signing up.
  select created_at into v_created from public.profiles where id = v_user;
  if v_created is null or v_created < now() - interval '7 days' then
    return jsonb_build_object('ok', false, 'error', 'not_new_account');
  end if;

  select coalesce(referral_enabled, true),
         coalesce(referral_referrer_coins, 0),
         coalesce(referral_referred_coins, 0)
    into v_enabled, v_referrer_coins, v_referred_coins
    from public.get_coin_settings
   where id = 'master';

  if not coalesce(v_enabled, true) then
    return jsonb_build_object('ok', false, 'error', 'disabled');
  end if;

  -- Resolve the referrer: an explicit profiles.referral_code wins, else the
  -- deterministic account-id code the apps share (its first 8 characters).
  select id into v_referrer
    from public.profiles
   where upper(coalesce(referral_code, '')) = v_code
   limit 1;
  if v_referrer is null and length(v_code) = 8 then
    select id into v_referrer
      from public.profiles
     where upper(left(replace(id::text, '-', ''), 8)) = v_code
     limit 1;
  end if;

  if v_referrer is null then
    return jsonb_build_object('ok', false, 'error', 'code_not_found');
  end if;
  if v_referrer = v_user then
    return jsonb_build_object('ok', false, 'error', 'self_referral');
  end if;
  if exists (select 1 from public.referrals where referred_user_id = v_user) then
    return jsonb_build_object('ok', false, 'error', 'already_referred');
  end if;

  insert into public.referrals
    (referrer_user_id, referred_user_id, code, referrer_coins, referred_coins)
  values
    (v_referrer, v_user, v_code, v_referrer_coins, v_referred_coins);

  if v_referrer_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_referrer, 'get_coin', 'referral', v_referrer_coins, 'referral', 'Referral bonus — a friend joined with your link');
  end if;
  if v_referred_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_user, 'get_coin', 'referral', v_referred_coins, 'referral', 'Welcome bonus — joined with a referral link');
  end if;

  return jsonb_build_object(
    'ok', true,
    'referrer_coins', v_referrer_coins,
    'referred_coins', v_referred_coins
  );
end;
$$;

grant execute on function public.apply_referral(text) to authenticated;

-- Who invited the signed-in user (name + code), for the profile badge.
create or replace function public.get_my_referrer()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_name text;
  v_code text;
  v_created timestamptz;
begin
  if v_user is null then
    return null;
  end if;

  select p.name, r.code, r.created_at
    into v_name, v_code, v_created
    from public.referrals r
    join public.profiles p on p.id = r.referrer_user_id
   where r.referred_user_id = v_user
   limit 1;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'name', nullif(trim(coalesce(v_name, '')), ''),
    'code', v_code,
    'created_at', v_created
  );
end;
$$;

grant execute on function public.get_my_referrer() to authenticated;

-- ============================================================================
-- MCash schema groundwork
-- (migrations/0068_mcash_wallet_columns.sql, folded in)
-- ----------------------------------------------------------------------------
-- GET.wallet is planned to be re-based onto the MCash e-money platform
-- (docs/get-wallet-mcash-flow.md): MCash becomes the custodian and ledger of
-- record, the Supabase ledger a read-side mirror written by the future
-- `mcash-proxy` edge function. Columns only — no behavior changes until the
-- proxy ships.
-- ============================================================================

-- Profile <-> MCash identity. All nullable: a null mcash_wallet_id simply
-- means the account has not been provisioned on MCash yet.
alter table public.profiles
  add column if not exists mcash_wallet_id text,
  add column if not exists mcash_ekyc_status text,
  add column if not exists mcash_customer_status text;

alter table public.profiles
  drop constraint if exists profiles_mcash_ekyc_status_check;
alter table public.profiles
  add constraint profiles_mcash_ekyc_status_check
  check (mcash_ekyc_status in
    ('never_submit','pending_screening','pending_review','approved',
     'rejected','on_hold','next_screening_due'));

alter table public.profiles
  drop constraint if exists profiles_mcash_customer_status_check;
alter table public.profiles
  add constraint profiles_mcash_customer_status_check
  check (mcash_customer_status in
    ('active','inactive','partial_blocked','blacklisted','terminated'));

-- One MCash wallet per profile; MCash webhooks/reconciliation resolve the
-- profile by wallet id.
create unique index if not exists profiles_mcash_wallet_id_key
  on public.profiles(mcash_wallet_id) where mcash_wallet_id is not null;

-- Mirror-ledger columns: FPX reloads settle asynchronously, so mirrored rows
-- can sit at pending/processing until MCash acknowledges. Every pre-MCash row
-- is final — hence the 'success' default. mcash_ref carries MCash's
-- transaction reference for reconciliation.
--
-- Note: the 0060 balance trigger still applies every row to wallets.balance
-- regardless of status. That stays correct today because nothing writes
-- non-success rows yet; the mcash-proxy work reworks the trigger when
-- pending mirror rows start to exist.
alter table public.wallet_transactions
  add column if not exists status text not null default 'success',
  add column if not exists mcash_ref text;

alter table public.wallet_transactions
  drop constraint if exists wallet_transactions_status_check;
alter table public.wallet_transactions
  add constraint wallet_transactions_status_check
  check (status in ('success','failed','pending','processing','paused','cancelled'));

create index if not exists wallet_tx_mcash_ref_idx
  on public.wallet_transactions(mcash_ref) where mcash_ref is not null;

-- ============================================================================
-- Vehicles (singular `vehicle` profile table) + driver assignment / sessions
-- ----------------------------------------------------------------------------
-- See migrations 0029 (vehicle), 0030 (photo columns), 0031 (assignment and
-- active-session tables + claim/release RPCs), 0035 (owners claim as implicit
-- assignees + owner backfill) and 0091 (RPCs act only on the caller's own
-- session; `not_assigned` now fires for non-owners). Kept here so a fresh
-- bootstrap has them; the owner-or-admin RLS policies for all three tables
-- live in the 0069 lockdown section below.
--
-- `vehicle_user_assignment`: which users may drive which vehicles (many to
-- many). `vehicle_active_session`: the vehicle currently in use, at most one
-- per vehicle and one per user; the row exists only while the driver is
-- online.
-- ============================================================================

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

-- Onboarding "Photos" step (0030).
alter table public.vehicle
  add column if not exists image_front text,
  add column if not exists image_left  text,
  add column if not exists image_right text,
  add column if not exists image_back  text;

create unique index if not exists vehicle_plate_key      on public.vehicle(plate);
create index if not exists vehicle_status_idx            on public.vehicle(status);
create index if not exists vehicle_permit_idx            on public.vehicle(permit);
create index if not exists vehicle_owner_partner_idx     on public.vehicle(owner_partner_id);
create index if not exists vehicle_auth_user_idx         on public.vehicle(auth_user_id);

drop trigger if exists trg_vehicle_updated_at on public.vehicle;
create trigger trg_vehicle_updated_at
  before update on public.vehicle
  for each row execute function public.set_updated_at();

alter table public.vehicle enable row level security;
grant select, insert, update, delete on public.vehicle to anon, authenticated;

create table if not exists public.vehicle_user_assignment (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.vehicle(id) on delete cascade,
  user_id       uuid not null,                       -- auth.users.id (driver)
  partner_id    uuid references public.partners(id) on delete set null,
  role          text not null default 'driver'
                  check (role in ('owner', 'driver', 'co-driver')),
  assigned_by   uuid,                                -- admin auth id, optional
  assigned_at   timestamptz not null default now(),
  is_active     boolean not null default true,       -- soft-disable a pairing
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint vehicle_user_assignment_unique unique (vehicle_id, user_id)
);

create index if not exists vehicle_user_assignment_vehicle_idx
  on public.vehicle_user_assignment(vehicle_id);
create index if not exists vehicle_user_assignment_user_idx
  on public.vehicle_user_assignment(user_id);
create index if not exists vehicle_user_assignment_partner_idx
  on public.vehicle_user_assignment(partner_id);
create index if not exists vehicle_user_assignment_active_idx
  on public.vehicle_user_assignment(is_active);

drop trigger if exists trg_vehicle_user_assignment_updated_at
  on public.vehicle_user_assignment;
create trigger trg_vehicle_user_assignment_updated_at
  before update on public.vehicle_user_assignment
  for each row execute function public.set_updated_at();

alter table public.vehicle_user_assignment enable row level security;
grant select, insert, update, delete on public.vehicle_user_assignment to anon, authenticated;

create table if not exists public.vehicle_active_session (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicle(id) on delete cascade,
  user_id      uuid not null,                        -- auth.users.id
  partner_id   uuid references public.partners(id) on delete set null,
  started_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  status       text not null default 'online'
                  check (status in ('online', 'busy', 'offline')),
  metadata     jsonb,
  -- Exclusivity:
  constraint vehicle_active_session_vehicle_unique unique (vehicle_id),
  constraint vehicle_active_session_user_unique    unique (user_id)
);

create index if not exists vehicle_active_session_status_idx
  on public.vehicle_active_session(status);
create index if not exists vehicle_active_session_partner_idx
  on public.vehicle_active_session(partner_id);

alter table public.vehicle_active_session enable row level security;
grant select, insert, update, delete on public.vehicle_active_session to anon, authenticated;

alter table public.vehicle replica identity full;
alter table public.vehicle_user_assignment replica identity full;
alter table public.vehicle_active_session replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.vehicle;
exception
  when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.vehicle_user_assignment;
exception
  when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.vehicle_active_session;
exception
  when duplicate_object then null;
end$$;

-- ----------------------------------------------------------------------------
-- Atomic claim / release / heartbeat. Each refuses a `p_user_id` other than
-- the caller's own unless the caller is an admin (0091); otherwise anyone
-- with the anon key could end or take over another driver's session.
-- ----------------------------------------------------------------------------

-- Claim a vehicle for a user. Returns the active session row on success.
-- Raises if the user isn't an active assignee or owner, the vehicle is
-- already taken, or the user is already driving another vehicle.
create or replace function public.claim_vehicle(
  p_vehicle_id uuid,
  p_user_id    uuid
) returns public.vehicle_active_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment public.vehicle_user_assignment%rowtype;
  v_session    public.vehicle_active_session%rowtype;
  v_partner_id uuid;
  v_is_owner   boolean := false;
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Active explicit assignment?
  select * into v_assignment
    from public.vehicle_user_assignment
   where vehicle_id = p_vehicle_id
     and user_id    = p_user_id
     and is_active  = true
   limit 1;

  if not found then
    -- Owner of the vehicle counts as an implicit active assignee.
    select true into v_is_owner
      from public.vehicle
     where id = p_vehicle_id
       and auth_user_id = p_user_id
     limit 1;

    -- No row leaves v_is_owner NULL, and `not NULL` is not true, so 0035's
    -- `if not v_is_owner` let every caller through.
    if not coalesce(v_is_owner, false) then
      raise exception 'not_assigned'
        using hint = 'User is not an active assignee or owner of this vehicle.';
    end if;
  end if;

  -- Vehicle already in use?
  select * into v_session
    from public.vehicle_active_session
   where vehicle_id = p_vehicle_id
   limit 1;

  if found then
    if v_session.user_id = p_user_id then
      update public.vehicle_active_session
         set last_seen_at = now(),
             status       = 'online'
       where id = v_session.id
      returning * into v_session;
      return v_session;
    end if;
    raise exception 'vehicle_in_use'
      using hint = 'Vehicle is currently used by another user.';
  end if;

  -- User already driving something else?
  if exists (
    select 1 from public.vehicle_active_session where user_id = p_user_id
  ) then
    raise exception 'user_busy'
      using hint = 'User is already in an active session on another vehicle.';
  end if;

  v_partner_id := v_assignment.partner_id;

  insert into public.vehicle_active_session (vehicle_id, user_id, partner_id)
       values (p_vehicle_id, p_user_id, v_partner_id)
    returning * into v_session;

  return v_session;
end;
$$;

-- Release whatever vehicle the user is currently driving (sets vehicle offline).
create or replace function public.release_vehicle(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  delete from public.vehicle_active_session where user_id = p_user_id;
end;
$$;

-- Heartbeat — call periodically while online to keep the session fresh.
create or replace function public.touch_vehicle_session(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.vehicle_active_session
     set last_seen_at = now()
   where user_id = p_user_id;
end;
$$;

-- Functions are executable by PUBLIC by default; revoke that too so anon
-- can't reach them through it.
revoke execute on function public.claim_vehicle(uuid, uuid)       from public, anon;
revoke execute on function public.release_vehicle(uuid)           from public, anon;
revoke execute on function public.touch_vehicle_session(uuid)     from public, anon;
grant  execute on function public.claim_vehicle(uuid, uuid)       to authenticated;
grant  execute on function public.release_vehicle(uuid)           to authenticated;
grant  execute on function public.touch_vehicle_session(uuid)     to authenticated;

-- Owners have an implicit assignment (0035); give each owned vehicle an
-- explicit `owner` row so reads of the assignment table see it too.
insert into public.vehicle_user_assignment (vehicle_id, user_id, partner_id, role, is_active)
select v.id,
       v.auth_user_id,
       v.owner_partner_id,
       'owner',
       true
  from public.vehicle v
 where v.auth_user_id is not null
   and not exists (
     select 1 from public.vehicle_user_assignment a
      where a.vehicle_id = v.id
        and a.user_id    = v.auth_user_id
   );

-- ============================================================================
-- Provider + vehicle documents (migrations 0026, 0027, 0028 and 0029 part 2)
-- ----------------------------------------------------------------------------
-- One row per uploaded document, keyed by partner (provider_documents) or by
-- vehicle (vehicle_documents), with matching storage buckets. The real RLS
-- policies (table and storage) live in the 0069 lockdown section below.
-- ============================================================================

insert into storage.buckets (id, name, public)
values
  ('provider-documents', 'provider-documents', true),
  ('vehicle-documents',  'vehicle-documents',  true)
on conflict (id) do update set public = excluded.public;

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

-- AI verification (0027) and detected country / name (0028).
alter table public.provider_documents
  add column if not exists ai_verification jsonb,
  add column if not exists ai_verified boolean,
  add column if not exists issuance_country text,
  add column if not exists detected_document_name text;

create index if not exists provider_documents_partner_idx
  on public.provider_documents(partner_id);
create index if not exists provider_documents_status_idx
  on public.provider_documents(status);
create index if not exists provider_documents_doc_idx
  on public.provider_documents(doc_id);

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

-- Auto-expire when expiry_date has passed (covers admins editing the date in
-- place; the client also flips status to 'Expired' on read).
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

alter table public.provider_documents enable row level security;

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

alter table public.vehicle_documents enable row level security;
grant select, insert, update, delete on public.vehicle_documents to anon, authenticated;
alter table public.vehicle_documents replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.provider_documents;
exception when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.vehicle_documents;
exception when duplicate_object then null;
end$$;

-- ============================================================================
-- Folded-in migrations (added 2026-10-06 with the 0097 squash)
-- ----------------------------------------------------------------------------
-- Until the squash, these migrations' objects existed only on databases that
-- had run the migration files: schema.sql never created them (tables such as
-- emergency_contacts / voice_protection_recordings / fare_ai_*, the push
-- webhook triggers, realtime publication members, indexes and policies). They
-- are copied here verbatim, in order; each is idempotent. The 0069 lockdown
-- section below then rewrites their policies as before.
-- ============================================================================

-- ---- from migrations/0005_profiles_id_type.sql ----
-- Adds id_type to profiles so we can record the document type detected
-- during the ID-scan flow (passport / national_id / driver_license / other).
alter table public.profiles
  add column if not exists id_type text;

create index if not exists profiles_id_type_idx on public.profiles(id_type);

notify pgrst, 'reload schema';

-- ---- from migrations/0012_enable_realtime_publication.sql ----
-- Enable Supabase Realtime for the tables the admin app subscribes to.
--
-- Why this is needed:
--   Supabase Realtime only forwards Postgres `INSERT/UPDATE/DELETE` events
--   for tables that are members of the `supabase_realtime` publication.
--   Without this, `supabase.channel(...).on('postgres_changes', { table: 'settings_entries' }, ...)`
--   subscribes successfully but never receives any payloads — so screens
--   like admin-settings-partner-type.tsx do not update live.
--
-- We also set REPLICA IDENTITY FULL so DELETE events carry the old row
-- (otherwise the client receives an empty `old` and may discard the event).
--
-- Safe to re-run: each ALTER PUBLICATION is wrapped to ignore duplicates.

-- settings_entries (partner-type, vehicle-type, payment-type, etc.)
do $$
begin
  alter publication supabase_realtime add table public.settings_entries;
exception when duplicate_object then null;
end$$;
alter table public.settings_entries replica identity full;

-- partners (admin-partners-*.tsx live updates)
do $$
begin
  alter publication supabase_realtime add table public.partners;
exception when duplicate_object then null;
end$$;
alter table public.partners replica identity full;

-- admin_access (Grant access + admin-login button visibility)
do $$
begin
  alter publication supabase_realtime add table public.admin_access;
exception when duplicate_object then null;
end$$;
alter table public.admin_access replica identity full;

-- profiles (so user list screens stay live too)
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null;
end$$;
alter table public.profiles replica identity full;

-- app_settings (api keys, supabase settings)
do $$
begin
  alter publication supabase_realtime add table public.app_settings;
exception when duplicate_object then null;
end$$;
alter table public.app_settings replica identity full;

-- ---- from migrations/0014_vehicles_table.sql ----
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

-- ---- from migrations/0015_vehicle_make_models_table.sql ----
-- ============================================================================
-- Migration 0015: dedicated `vehicle_make_models` table
-- ----------------------------------------------------------------------------
-- Source of truth for admin-settings-vehicle-make-model.tsx. Previously the
-- screen stored rows in `settings_entries` under category 'vehicle-type' which
-- collided with the rides "vehicle-type" settings (capacity / base fare).
-- Now the catalog lives in its own table, mirroring the partners/vehicles
-- pattern, with realtime + public read/write policies for the admin UI.
-- Safe to re-run.
-- ============================================================================

create table if not exists public.vehicle_make_models (
  id            uuid primary key default gen_random_uuid(),
  vehicle_type  text not null,
  energy_type   text not null,
  make          text not null,
  model         text not null,
  year_from     text not null default '',
  year_to       text not null default '',
  icon_uri      text not null default '',
  status        boolean not null default true,
  is_default    boolean not null default false,
  position      integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists vmm_vehicle_type_idx on public.vehicle_make_models(vehicle_type);
create index if not exists vmm_energy_type_idx  on public.vehicle_make_models(energy_type);
create index if not exists vmm_make_idx         on public.vehicle_make_models(make);
create index if not exists vmm_model_idx        on public.vehicle_make_models(model);
create index if not exists vmm_position_idx     on public.vehicle_make_models(position);

drop trigger if exists trg_vehicle_make_models_updated_at on public.vehicle_make_models;
create trigger trg_vehicle_make_models_updated_at
  before update on public.vehicle_make_models
  for each row execute function public.set_updated_at();

alter table public.vehicle_make_models enable row level security;

drop policy if exists "vehicle_make_models read"   on public.vehicle_make_models;
drop policy if exists "vehicle_make_models insert" on public.vehicle_make_models;
drop policy if exists "vehicle_make_models update" on public.vehicle_make_models;
drop policy if exists "vehicle_make_models delete" on public.vehicle_make_models;

create policy "vehicle_make_models read"
  on public.vehicle_make_models for select using (true);
create policy "vehicle_make_models insert"
  on public.vehicle_make_models for insert to public with check (true);
create policy "vehicle_make_models update"
  on public.vehicle_make_models for update to public using (true) with check (true);
create policy "vehicle_make_models delete"
  on public.vehicle_make_models for delete to public using (true);

grant select, insert, update, delete on public.vehicle_make_models to anon, authenticated;

-- Realtime publication + full replica identity (so DELETE payloads include the row).
alter table public.vehicle_make_models replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.vehicle_make_models;
exception when duplicate_object then null; when others then null; end $$;

-- One-time seed: only insert when table is empty, so re-runs are safe.
insert into public.vehicle_make_models
  (vehicle_type, energy_type, make, model, year_from, year_to, position)
select v.vehicle_type, v.energy_type, v.make, v.model, v.year_from, v.year_to, v.position
from (values
  ('Sedan','Petrol','Proton','Saga','1985','~',0),
  ('Sedan','Petrol','Proton','Wira','1993','2009',1),
  ('Sedan','Petrol','Proton','Waja','2000','2011',2),
  ('Sedan','Petrol','Proton','Persona','2007','~',3),
  ('Sedan','Petrol','Proton','Inspira','2010','2015',4),
  ('Sedan','Petrol','Proton','Preve','2012','2020',5),
  ('Sedan','Petrol','Proton','Perdana','1995','2020',6),
  ('Sedan','Petrol','Proton','S70','2024','~',7),
  ('Sedan','Petrol','Proton','Iswara','1992','2003',8),
  ('Sedan','Petrol','Proton','Tiara','1996','2000',9),
  ('Sedan','Petrol','Proton','Gen-2 Sedan','2008','2012',10),
  ('Sedan','Petrol','Perodua','Bezza','2016','~',11),
  ('Sedan','Petrol','Toyota','Vios','2003','~',12),
  ('Sedan','Petrol','Toyota','Yaris Sedan','2017','~',13),
  ('Sedan','Petrol','Toyota','Corolla Altis','2001','~',14),
  ('Sedan','Hybrid','Toyota','Corolla Altis Hybrid','2019','~',15),
  ('Sedan','Petrol','Toyota','Camry','1982','~',16),
  ('Sedan','Hybrid','Toyota','Camry Hybrid','2011','~',17),
  ('Sedan','Hybrid','Toyota','Prius','1997','~',18),
  ('Sedan','PHEV','Toyota','Prius Prime','2017','~',19),
  ('Sedan','Hydrogen','Toyota','Mirai','2014','~',20),
  ('Sedan','Petrol','Toyota','Avensis','1997','2018',21),
  ('Sedan','Petrol','Toyota','Crown','1955','~',22),
  ('Sedan','Hybrid','Toyota','Crown Hybrid','2008','~',23),
  ('Sedan','Petrol','Toyota','Mark X','2004','2019',24),
  ('Sedan','Petrol','Honda','City','1996','~',25),
  ('Sedan','Hybrid','Honda','City e:HEV','2021','~',26),
  ('Sedan','Petrol','Honda','Civic','1972','~',27),
  ('Sedan','Hybrid','Honda','Civic e:HEV','2022','~',28),
  ('Sedan','Petrol','Honda','Civic Type R','1997','~',29),
  ('Sedan','Petrol','Honda','Accord','1976','~',30),
  ('Sedan','Hybrid','Honda','Accord Hybrid','2014','~',31),
  ('Sedan','Petrol','Honda','Legend','1985','2021',32),
  ('Sedan','Petrol','Nissan','Almera','1995','~',33),
  ('Sedan','Petrol','Nissan','Sentra','1982','~',34),
  ('Sedan','Petrol','Nissan','Sylphy','2000','~',35),
  ('Sedan','Petrol','Nissan','Teana','2003','2020',36),
  ('Sedan','Petrol','Nissan','Skyline','1957','~',37),
  ('Sedan','Petrol','Nissan','Maxima','1981','2023',38),
  ('Sedan','Petrol','Nissan','Cefiro','1988','2003',39),
  ('Sedan','Petrol','Mazda','2 Sedan','2007','~',40),
  ('Sedan','Petrol','Mazda','3 Sedan','2003','~',41),
  ('Sedan','Petrol','Mazda','6','2002','~',42),
  ('Sedan','Petrol','Hyundai','Accent','1994','~',43),
  ('Sedan','Petrol','Hyundai','Avante','1990','~',44),
  ('Sedan','Petrol','Hyundai','Elantra','1990','~',45),
  ('Sedan','Petrol','Hyundai','Sonata','1985','~',46),
  ('Sedan','Hybrid','Hyundai','Sonata Hybrid','2011','~',47),
  ('Sedan','Petrol','Hyundai','Genesis','2008','2016',48),
  ('Sedan','EV','Hyundai','Ioniq Electric','2016','2022',49),
  ('Sedan','Petrol','Kia','Cerato','2003','~',50),
  ('Sedan','Petrol','Kia','Forte','2008','~',51),
  ('Sedan','Petrol','Kia','Optima K5','2000','~',52),
  ('Sedan','Hybrid','Kia','Optima Hybrid','2011','~',53),
  ('Sedan','Petrol','Kia','Stinger','2017','2023',54),
  ('Sedan','Petrol','BMW','318i','1990','~',55),
  ('Sedan','Petrol','BMW','320i','1975','~',56),
  ('Sedan','Petrol','BMW','330i','1992','~',57),
  ('Sedan','Diesel','BMW','320d','1998','~',58),
  ('Sedan','Diesel','BMW','330d','1999','~',59),
  ('Sedan','Petrol','BMW','520i','1981','~',60),
  ('Sedan','Petrol','BMW','530i','1992','~',61),
  ('Sedan','Diesel','BMW','530d','1999','~',62),
  ('Sedan','PHEV','BMW','530e','2017','~',63),
  ('Sedan','Petrol','BMW','540i','1997','~',64),
  ('Sedan','Petrol','BMW','740i','1992','~',65),
  ('Sedan','PHEV','BMW','745e','2019','2022',66),
  ('Sedan','Petrol','BMW','750i','1987','~',67),
  ('Sedan','Petrol','BMW','760Li','2002','~',68),
  ('Sedan','EV','BMW','i4','2021','~',69),
  ('Sedan','EV','BMW','i5','2023','~',70),
  ('Sedan','EV','BMW','i7','2022','~',71),
  ('Sedan','Petrol','BMW','M3','1986','~',72),
  ('Sedan','Petrol','BMW','M5','1985','~',73),
  ('Sedan','Petrol','BMW','M340i','2019','~',74),
  ('Sedan','Petrol','BMW','M760Li','2017','~',75),
  ('Sedan','Petrol','Mercedes-Benz','A-Class Sedan','2018','~',76),
  ('Sedan','Petrol','Mercedes-Benz','C180','1993','~',77),
  ('Sedan','Petrol','Mercedes-Benz','C200','1993','~',78),
  ('Sedan','Petrol','Mercedes-Benz','C300','2014','~',79),
  ('Sedan','Diesel','Mercedes-Benz','C220d','1993','~',80),
  ('Sedan','Petrol','Mercedes-Benz','C43 AMG','2015','~',81),
  ('Sedan','Petrol','Mercedes-Benz','C63 AMG','2008','~',82),
  ('Sedan','Petrol','Mercedes-Benz','E200','1985','~',83),
  ('Sedan','Petrol','Mercedes-Benz','E300','1985','~',84),
  ('Sedan','Diesel','Mercedes-Benz','E220d','2016','~',85),
  ('Sedan','PHEV','Mercedes-Benz','E300e','2019','~',86),
  ('Sedan','Petrol','Mercedes-Benz','E450','2018','~',87),
  ('Sedan','Petrol','Mercedes-Benz','E63 AMG','2007','~',88),
  ('Sedan','Petrol','Mercedes-Benz','S350','2005','~',89),
  ('Sedan','Petrol','Mercedes-Benz','S450','2017','~',90),
  ('Sedan','Petrol','Mercedes-Benz','S500','1992','~',91),
  ('Sedan','Petrol','Mercedes-Benz','S560','2017','2020',92),
  ('Sedan','Petrol','Mercedes-Benz','S580','2020','~',93),
  ('Sedan','Petrol','Mercedes-Benz','S680 Maybach','2021','~',94),
  ('Sedan','EV','Mercedes-Benz','EQE','2022','~',95),
  ('Sedan','EV','Mercedes-Benz','EQS','2021','~',96),
  ('Sedan','Petrol','Audi','A3 Sedan','2013','~',97),
  ('Sedan','Petrol','Audi','A4','1994','~',98),
  ('Sedan','Diesel','Audi','A4 TDI','1995','~',99),
  ('Sedan','Petrol','Audi','A5 Sedan','2007','~',100),
  ('Sedan','Petrol','Audi','A6','1994','~',101),
  ('Sedan','Diesel','Audi','A6 TDI','1995','~',102),
  ('Sedan','Petrol','Audi','A7','2010','~',103),
  ('Sedan','Petrol','Audi','A8','1994','~',104),
  ('Sedan','EV','Audi','e-tron GT','2021','~',105),
  ('Sedan','Petrol','Audi','S4','1991','~',106),
  ('Sedan','Petrol','Audi','S6','1994','~',107),
  ('Sedan','Petrol','Audi','RS3 Sedan','2017','~',108),
  ('Sedan','Petrol','Audi','RS5','2017','~',109),
  ('Sedan','Petrol','Audi','RS6','2002','~',110),
  ('Sedan','Petrol','Audi','RS7','2013','~',111),
  ('Sedan','Petrol','Lexus','IS200t','2015','~',112),
  ('Sedan','Petrol','Lexus','IS300','1999','~',113),
  ('Sedan','Petrol','Lexus','IS350','2005','~',114),
  ('Sedan','Petrol','Lexus','IS500 F Sport','2021','~',115),
  ('Sedan','Petrol','Lexus','ES250','2018','~',116),
  ('Sedan','Hybrid','Lexus','ES300h','2012','~',117),
  ('Sedan','Petrol','Lexus','ES350','1989','~',118),
  ('Sedan','Petrol','Lexus','GS350','1993','2020',119),
  ('Sedan','Petrol','Lexus','LS460','2006','~',120),
  ('Sedan','Petrol','Lexus','LS500','2017','~',121),
  ('Sedan','Hybrid','Lexus','LS500h','2017','~',122),
  ('Sedan','Petrol','Porsche','Panamera','2009','~',123),
  ('Sedan','PHEV','Porsche','Panamera E-Hybrid','2013','~',124),
  ('Sedan','EV','Porsche','Taycan','2019','~',125),
  ('Sedan','Petrol','Volkswagen','Passat','1973','~',126),
  ('Sedan','Diesel','Volkswagen','Passat TDI','1996','~',127),
  ('Sedan','Petrol','Volkswagen','Jetta','1979','~',128),
  ('Sedan','Petrol','Volkswagen','Arteon','2017','~',129),
  ('Sedan','Petrol','Volkswagen','Vento','1992','~',130),
  ('Sedan','Petrol','Volvo','S60','2000','~',131),
  ('Sedan','PHEV','Volvo','S60 T8','2016','~',132),
  ('Sedan','Petrol','Volvo','S90','2016','~',133),
  ('Sedan','PHEV','Volvo','S90 T8','2016','~',134),
  ('Sedan','EV','Tesla','Model 3','2017','~',135),
  ('Sedan','EV','Tesla','Model 3 Performance','2018','~',136),
  ('Sedan','EV','Tesla','Model S','2012','~',137),
  ('Sedan','EV','Tesla','Model S Plaid','2021','~',138),
  ('Sedan','EV','BYD','Seal','2022','~',139),
  ('Sedan','EV','BYD','Han','2020','~',140),
  ('Sedan','PHEV','BYD','Han DM-i','2021','~',141),
  ('Sedan','EV','NIO','ET5','2022','~',142),
  ('Sedan','EV','NIO','ET7','2022','~',143),
  ('Sedan','EV','NIO','ET9','2024','~',144),
  ('Sedan','EV','Xpeng','P5','2021','~',145),
  ('Sedan','EV','Xpeng','P7','2020','~',146),
  ('Sedan','EV','Xpeng','P7+','2024','~',147),
  ('Sedan','EV','Lucid','Air','2021','~',148),
  ('Sedan','EV','MG','MG5','2020','~',149),
  ('Sedan','EV','MG','MG7','2022','~',150),
  ('Sedan','EV','Zeekr','001','2021','~',151),
  ('Sedan','EV','Zeekr','007','2024','~',152),
  ('Sedan','EV','Polestar','2','2019','~',153),
  ('Sedan','EV','Polestar','5','2025','~',154),
  ('Sedan','Petrol','Genesis','G70','2017','~',155),
  ('Sedan','Petrol','Genesis','G80','2016','~',156),
  ('Sedan','EV','Genesis','G80 Electrified','2021','~',157),
  ('Sedan','Petrol','Genesis','G90','2015','~',158),
  ('Sedan','Petrol','Cadillac','CT4','2019','~',159),
  ('Sedan','Petrol','Cadillac','CT5','2019','~',160),
  ('Sedan','Petrol','Cadillac','CT6','2015','2020',161),
  ('Sedan','Petrol','Chrysler','300','2004','~',162),
  ('Sedan','Petrol','Bentley','Flying Spur','2005','~',163),
  ('Sedan','Petrol','Rolls-Royce','Ghost','2009','~',164),
  ('Sedan','Petrol','Rolls-Royce','Phantom','2003','~',165),
  ('Sedan','EV','Rolls-Royce','Spectre','2024','~',166),
  ('Sedan','Petrol','Maserati','Ghibli','2013','~',167),
  ('Sedan','Petrol','Maserati','Quattroporte','2003','~',168),
  ('Sedan','Petrol','Jaguar','XE','2014','~',169),
  ('Sedan','Petrol','Jaguar','XF','2007','~',170),
  ('Sedan','Petrol','Jaguar','XJ','1968','2019',171),
  ('Hatchback','Petrol','Perodua','Myvi','2005','~',172),
  ('Hatchback','Petrol','Perodua','Axia','2014','~',173),
  ('Hatchback','Petrol','Perodua','Viva','2007','2014',174),
  ('Hatchback','Petrol','Perodua','Kancil','1994','2009',175),
  ('Hatchback','Petrol','Perodua','Kelisa','2001','2007',176),
  ('Hatchback','Petrol','Proton','Iriz','2014','~',177),
  ('Hatchback','Petrol','Proton','Satria','1994','2015',178),
  ('Hatchback','Petrol','Proton','Satria Neo','2006','2015',179),
  ('Hatchback','Petrol','Proton','Savvy','2005','2011',180),
  ('Hatchback','Petrol','Toyota','Yaris','1999','~',181),
  ('Hatchback','Petrol','Toyota','Aygo','2005','~',182),
  ('Hatchback','Hybrid','Toyota','Yaris Hybrid','2012','~',183),
  ('Hatchback','Petrol','Honda','Jazz','2001','2020',184),
  ('Hatchback','Hybrid','Honda','Jazz Hybrid','2010','2020',185),
  ('Hatchback','Hybrid','Honda','Fit e:HEV','2020','~',186),
  ('Hatchback','Petrol','Mazda','2 Hatchback','2007','~',187),
  ('Hatchback','Petrol','Mazda','3 Hatchback','2003','~',188),
  ('Hatchback','Petrol','Volkswagen','Polo','1975','~',189),
  ('Hatchback','Petrol','Volkswagen','Up!','2011','~',190),
  ('Hatchback','Petrol','Volkswagen','Golf','1974','~',191),
  ('Hatchback','Petrol','Volkswagen','Golf GTI','1976','~',192),
  ('Hatchback','Petrol','Volkswagen','Golf R','2002','~',193),
  ('Hatchback','Diesel','Volkswagen','Golf TDI','1991','~',194),
  ('Hatchback','Petrol','Mini','Cooper','2001','~',195),
  ('Hatchback','Petrol','Mini','Cooper S','2001','~',196),
  ('Hatchback','Petrol','Mini','JCW','2007','~',197),
  ('Hatchback','EV','Mini','Cooper SE','2020','~',198),
  ('Hatchback','Petrol','Suzuki','Swift','2004','~',199),
  ('Hatchback','Hybrid','Suzuki','Swift Hybrid','2017','~',200),
  ('Hatchback','Petrol','Suzuki','Baleno','2015','~',201),
  ('Hatchback','Petrol','Suzuki','Celerio','2014','~',202),
  ('Hatchback','Petrol','Suzuki','Alto','1979','~',203),
  ('Hatchback','Petrol','Hyundai','i10','2007','~',204),
  ('Hatchback','Petrol','Hyundai','i20','2008','~',205),
  ('Hatchback','Petrol','Hyundai','i30','2007','~',206),
  ('Hatchback','Petrol','Hyundai','i30 N','2017','~',207),
  ('Hatchback','Petrol','Kia','Picanto','2004','~',208),
  ('Hatchback','Petrol','Kia','Rio','1999','~',209),
  ('Hatchback','Petrol','Kia','Ceed','2006','~',210),
  ('Hatchback','Petrol','Ford','Fiesta','1976','~',211),
  ('Hatchback','Petrol','Ford','Fiesta ST','2002','~',212),
  ('Hatchback','Petrol','Ford','Focus','1998','~',213),
  ('Hatchback','Petrol','Ford','Focus ST','2002','~',214),
  ('Hatchback','Petrol','Ford','Focus RS','2002','2018',215),
  ('Hatchback','Petrol','Renault','Clio','1990','~',216),
  ('Hatchback','Petrol','Renault','Megane','1995','~',217),
  ('Hatchback','EV','Renault','Zoe','2012','~',218),
  ('Hatchback','EV','Renault','Megane E-Tech','2022','~',219),
  ('Hatchback','Petrol','Peugeot','208','2012','~',220),
  ('Hatchback','EV','Peugeot','e-208','2019','~',221),
  ('Hatchback','Petrol','Peugeot','308','2007','~',222),
  ('Hatchback','Petrol','Citroen','C3','2002','~',223),
  ('Hatchback','Petrol','Citroen','C4','2004','~',224),
  ('Hatchback','Petrol','Fiat','500','2007','~',225),
  ('Hatchback','EV','Fiat','500e','2020','~',226),
  ('Hatchback','Petrol','Fiat','Panda','1980','~',227),
  ('Hatchback','EV','BMW','i3','2013','2022',228),
  ('Hatchback','Petrol','BMW','1 Series','2004','~',229),
  ('Hatchback','Petrol','Mercedes-Benz','A-Class','1997','~',230),
  ('Hatchback','Petrol','Mercedes-Benz','A45 AMG','2013','~',231),
  ('Hatchback','EV','Volkswagen','ID.3','2020','~',232),
  ('Hatchback','EV','BYD','Dolphin','2021','~',233),
  ('Hatchback','EV','BYD','Seagull','2023','~',234),
  ('Hatchback','EV','Ora','Good Cat','2020','~',235),
  ('Hatchback','EV','Ora','Lightning Cat','2022','~',236),
  ('Hatchback','EV','MG','MG4','2022','~',237),
  ('Hatchback','EV','MG','Mulan','2022','~',238),
  ('Hatchback','Petrol','Subaru','Impreza','1992','~',239),
  ('Hatchback','Petrol','Subaru','WRX','1992','~',240),
  ('Coupe','Petrol','BMW','M2','2015','~',241),
  ('Coupe','Petrol','BMW','M4','2014','~',242),
  ('Coupe','Petrol','BMW','M8','2018','~',243),
  ('Coupe','Petrol','BMW','8 Series','2018','~',244),
  ('Coupe','Petrol','BMW','Z4','2002','~',245),
  ('Coupe','Petrol','Mercedes-Benz','C-Class Coupe','2011','~',246),
  ('Coupe','Petrol','Mercedes-Benz','E-Class Coupe','2009','~',247),
  ('Coupe','Petrol','Mercedes-Benz','AMG GT','2014','~',248),
  ('Coupe','Petrol','Mercedes-Benz','AMG GT 63','2018','~',249),
  ('Coupe','Petrol','Mercedes-Benz','SL','1954','~',250),
  ('Coupe','Petrol','Audi','TT','1998','2023',251),
  ('Coupe','Petrol','Audi','R8','2006','2024',252),
  ('Coupe','Petrol','Audi','RS5 Coupe','2010','~',253),
  ('Coupe','Petrol','Porsche','911 Carrera','1963','~',254),
  ('Coupe','Petrol','Porsche','911 Turbo','1974','~',255),
  ('Coupe','Petrol','Porsche','911 GT3','1999','~',256),
  ('Coupe','Petrol','Porsche','911 GT3 RS','2003','~',257),
  ('Coupe','Petrol','Porsche','718 Cayman','2016','~',258),
  ('Coupe','Petrol','Porsche','718 Boxster','2016','~',259),
  ('Coupe','Petrol','Nissan','GT-R','2007','~',260),
  ('Coupe','Petrol','Nissan','GT-R Nismo','2014','~',261),
  ('Coupe','Petrol','Nissan','Z','2022','~',262),
  ('Coupe','Petrol','Nissan','370Z','2008','2020',263),
  ('Coupe','Petrol','Nissan','350Z','2002','2008',264),
  ('Coupe','Petrol','Toyota','Supra','1978','~',265),
  ('Coupe','Petrol','Toyota','GR86','2021','~',266),
  ('Coupe','Petrol','Subaru','BRZ','2012','~',267),
  ('Coupe','Petrol','Mazda','MX-5 Miata','1989','~',268),
  ('Coupe','Petrol','Mazda','RX-7','1978','2002',269),
  ('Coupe','Petrol','Mazda','RX-8','2003','2012',270),
  ('Coupe','Petrol','Honda','S2000','1999','2009',271),
  ('Coupe','Petrol','Honda','NSX','1990','2022',272),
  ('Coupe','Petrol','Lexus','LC500','2017','~',273),
  ('Coupe','Hybrid','Lexus','LC500h','2017','~',274),
  ('Coupe','Petrol','Lexus','RC F','2014','~',275),
  ('Coupe','Petrol','Chevrolet','Corvette C7','2014','2019',276),
  ('Coupe','Petrol','Chevrolet','Corvette C8','2020','~',277),
  ('Coupe','Petrol','Chevrolet','Camaro','1966','2024',278),
  ('Coupe','Petrol','Chevrolet','Camaro ZL1','2012','2024',279),
  ('Coupe','Petrol','Ford','Mustang','1964','~',280),
  ('Coupe','Petrol','Ford','Mustang GT','1964','~',281),
  ('Coupe','Petrol','Ford','Mustang Shelby GT500','2007','~',282),
  ('Coupe','Petrol','Dodge','Challenger','2008','2023',283),
  ('Coupe','Petrol','Dodge','Challenger Hellcat','2014','2023',284),
  ('Coupe','Petrol','Dodge','Charger SRT','2006','2023',285),
  ('Coupe','Petrol','Aston Martin','Vantage','2005','~',286),
  ('Coupe','Petrol','Aston Martin','DB11','2016','2023',287),
  ('Coupe','Petrol','Aston Martin','DB12','2023','~',288),
  ('Coupe','Petrol','Aston Martin','DBS Superleggera','2018','~',289),
  ('Coupe','Petrol','Bentley','Continental GT','2003','~',290),
  ('Coupe','Petrol','Ferrari','488 GTB','2015','2019',291),
  ('Coupe','Petrol','Ferrari','F8 Tributo','2019','~',292),
  ('Coupe','Petrol','Ferrari','296 GTB','2021','~',293),
  ('Coupe','Petrol','Ferrari','SF90 Stradale','2020','~',294),
  ('Coupe','Petrol','Ferrari','812 Superfast','2017','~',295),
  ('Coupe','Petrol','Ferrari','Roma','2020','~',296),
  ('Coupe','Petrol','Lamborghini','Huracan','2014','~',297),
  ('Coupe','Petrol','Lamborghini','Huracan STO','2020','~',298),
  ('Coupe','Petrol','Lamborghini','Aventador','2011','2022',299),
  ('Coupe','Petrol','Lamborghini','Revuelto','2023','~',300),
  ('Coupe','Petrol','McLaren','720S','2017','~',301),
  ('Coupe','Petrol','McLaren','765LT','2020','~',302),
  ('Coupe','Petrol','McLaren','Artura','2021','~',303),
  ('Coupe','Petrol','McLaren','GT','2019','~',304),
  ('Coupe','Petrol','Maserati','MC20','2020','~',305),
  ('Coupe','Petrol','Maserati','GranTurismo','2007','~',306),
  ('Coupe','EV','Maserati','GranTurismo Folgore','2023','~',307),
  ('Convertible','Petrol','Mazda','MX-5 Miata Convertible','1989','~',308),
  ('Convertible','Petrol','BMW','M4 Convertible','2014','~',309),
  ('Convertible','Petrol','BMW','Z4 Roadster','2002','~',310),
  ('Convertible','Petrol','Mercedes-Benz','SLC','2016','2020',311),
  ('Convertible','Petrol','Mercedes-Benz','SL Roadster','1954','~',312),
  ('Convertible','Petrol','Mercedes-Benz','C-Class Cabriolet','2016','2023',313),
  ('Convertible','Petrol','Mercedes-Benz','E-Class Cabriolet','2010','~',314),
  ('Convertible','Petrol','Audi','A5 Cabriolet','2009','~',315),
  ('Convertible','Petrol','Audi','TT Roadster','1999','2023',316),
  ('Convertible','Petrol','Porsche','911 Cabriolet','1982','~',317),
  ('Convertible','Petrol','Porsche','911 Targa','1965','~',318),
  ('Convertible','Petrol','Porsche','718 Boxster Spyder','2019','~',319),
  ('Convertible','Petrol','Mini','Cooper Convertible','2004','~',320),
  ('Convertible','Petrol','Ford','Mustang Convertible','1964','~',321),
  ('Convertible','Petrol','Chevrolet','Corvette Convertible','1953','~',322),
  ('Convertible','Petrol','Bentley','Continental GTC','2006','~',323),
  ('Convertible','Petrol','Rolls-Royce','Dawn','2015','2023',324),
  ('Convertible','Petrol','Aston Martin','Vantage Roadster','2020','~',325),
  ('Convertible','Petrol','Ferrari','Portofino','2017','~',326),
  ('Convertible','Petrol','Ferrari','Roma Spider','2023','~',327),
  ('Convertible','Petrol','Ferrari','F8 Spider','2019','~',328),
  ('Convertible','Petrol','Lamborghini','Huracan Spyder','2015','~',329),
  ('Convertible','Petrol','Lamborghini','Aventador Roadster','2012','2022',330),
  ('Convertible','Petrol','McLaren','720S Spider','2018','~',331),
  ('Convertible','Petrol','McLaren','Artura Spider','2024','~',332),
  ('Convertible','Petrol','Jaguar','F-Type Convertible','2013','~',333),
  ('Wagon','Petrol','Volvo','V60','2010','~',334),
  ('Wagon','PHEV','Volvo','V60 T8','2018','~',335),
  ('Wagon','Petrol','Volvo','V90','2016','~',336),
  ('Wagon','Petrol','Volvo','V90 Cross Country','2017','~',337),
  ('Wagon','Petrol','Volvo','V70','1996','2016',338),
  ('Wagon','Petrol','Volvo','850 Estate','1991','1997',339),
  ('Wagon','Petrol','BMW','3 Series Touring','1987','~',340),
  ('Wagon','Petrol','BMW','5 Series Touring','1991','~',341),
  ('Wagon','Petrol','BMW','M3 Touring','2022','~',342),
  ('Wagon','Petrol','Mercedes-Benz','C-Class Estate','1996','~',343),
  ('Wagon','Petrol','Mercedes-Benz','E-Class Estate','1985','~',344),
  ('Wagon','Petrol','Mercedes-Benz','E63 AMG Estate','2007','~',345),
  ('Wagon','Petrol','Audi','A4 Avant','1995','~',346),
  ('Wagon','Petrol','Audi','A6 Avant','1995','~',347),
  ('Wagon','Petrol','Audi','RS4 Avant','1999','~',348),
  ('Wagon','Petrol','Audi','RS6 Avant','2002','~',349),
  ('Wagon','Petrol','Subaru','Levorg','2014','~',350),
  ('Wagon','Petrol','Subaru','Legacy Wagon','1989','2014',351),
  ('Wagon','Petrol','Volkswagen','Passat Variant','1981','~',352),
  ('Wagon','Petrol','Volkswagen','Golf Variant','1993','~',353),
  ('Wagon','Petrol','Skoda','Octavia Combi','1996','~',354),
  ('Wagon','Petrol','Skoda','Superb Combi','2009','~',355),
  ('Wagon','Petrol','Peugeot','508 SW','2010','~',356),
  ('SUV','Petrol','Proton','X50','2020','~',357),
  ('SUV','Petrol','Proton','X70','2018','~',358),
  ('SUV','Petrol','Proton','X90','2023','~',359),
  ('SUV','EV','Proton','e.MAS 7','2024','~',360),
  ('SUV','Petrol','Perodua','Aruz','2019','~',361),
  ('SUV','Petrol','Perodua','Ativa','2021','~',362),
  ('SUV','Petrol','Perodua','Kembara','1998','2008',363),
  ('SUV','Petrol','Perodua','Nautica','2008','2009',364),
  ('SUV','Petrol','Toyota','Raize','2019','~',365),
  ('SUV','Petrol','Toyota','Rush','2006','~',366),
  ('SUV','Petrol','Toyota','Corolla Cross','2020','~',367),
  ('SUV','Hybrid','Toyota','Corolla Cross Hybrid','2020','~',368),
  ('SUV','Petrol','Toyota','C-HR','2016','~',369),
  ('SUV','Hybrid','Toyota','C-HR Hybrid','2016','~',370),
  ('SUV','Petrol','Toyota','RAV4','1994','~',371),
  ('SUV','Hybrid','Toyota','RAV4 Hybrid','2015','~',372),
  ('SUV','PHEV','Toyota','RAV4 PHEV','2020','~',373),
  ('SUV','Petrol','Toyota','Harrier','1997','~',374),
  ('SUV','Hybrid','Toyota','Harrier Hybrid','2005','~',375),
  ('SUV','Petrol','Toyota','Fortuner','2004','~',376),
  ('SUV','Diesel','Toyota','Fortuner Diesel','2004','~',377),
  ('SUV','Petrol','Toyota','Land Cruiser','1951','~',378),
  ('SUV','Diesel','Toyota','Land Cruiser Diesel','1951','~',379),
  ('SUV','Petrol','Toyota','Land Cruiser Prado','1990','~',380),
  ('SUV','Diesel','Toyota','Land Cruiser Prado Diesel','1990','~',381),
  ('SUV','Hybrid','Toyota','Highlander Hybrid','2005','~',382),
  ('SUV','Hybrid','Toyota','Kluger Hybrid','2000','~',383),
  ('SUV','EV','Toyota','bZ4X','2022','~',384),
  ('SUV','Petrol','Honda','HR-V','1998','~',385),
  ('SUV','Hybrid','Honda','HR-V Hybrid','2021','~',386),
  ('SUV','Petrol','Honda','CR-V','1995','~',387),
  ('SUV','Hybrid','Honda','CR-V Hybrid','2017','~',388),
  ('SUV','Hydrogen','Honda','CR-V e:FCEV','2024','~',389),
  ('SUV','Petrol','Honda','WR-V','2017','~',390),
  ('SUV','Petrol','Honda','Pilot','2002','~',391),
  ('SUV','Petrol','Honda','Passport','2018','~',392),
  ('SUV','EV','Honda','e:Ny1','2023','~',393),
  ('SUV','Petrol','Nissan','Kicks','2016','~',394),
  ('SUV','Hybrid','Nissan','Kicks e-Power','2017','~',395),
  ('SUV','Petrol','Nissan','Juke','2010','~',396),
  ('SUV','Petrol','Nissan','Qashqai','2007','~',397),
  ('SUV','Petrol','Nissan','X-Trail','2000','~',398),
  ('SUV','Hybrid','Nissan','X-Trail e-Power','2022','~',399),
  ('SUV','Petrol','Nissan','Murano','2002','~',400),
  ('SUV','Petrol','Nissan','Pathfinder','1985','~',401),
  ('SUV','EV','Nissan','Ariya','2022','~',402),
  ('SUV','EV','Nissan','Leaf','2010','~',403),
  ('SUV','Petrol','Nissan','Patrol','1951','~',404),
  ('SUV','Petrol','Mazda','CX-3','2015','~',405),
  ('SUV','Petrol','Mazda','CX-30','2019','~',406),
  ('SUV','Petrol','Mazda','CX-5','2012','~',407),
  ('SUV','Diesel','Mazda','CX-5 Diesel','2012','~',408),
  ('SUV','Petrol','Mazda','CX-50','2022','~',409),
  ('SUV','Petrol','Mazda','CX-60','2022','~',410),
  ('SUV','PHEV','Mazda','CX-60 PHEV','2022','~',411),
  ('SUV','Petrol','Mazda','CX-8','2017','~',412),
  ('SUV','Petrol','Mazda','CX-9','2007','~',413),
  ('SUV','Petrol','Mazda','CX-90','2023','~',414),
  ('SUV','EV','Mazda','MX-30','2020','~',415),
  ('SUV','Petrol','Hyundai','Venue','2019','~',416),
  ('SUV','Petrol','Hyundai','Creta','2014','~',417),
  ('SUV','Petrol','Hyundai','Kona','2017','~',418),
  ('SUV','Hybrid','Hyundai','Kona Hybrid','2019','~',419),
  ('SUV','EV','Hyundai','Kona Electric','2018','~',420),
  ('SUV','Petrol','Hyundai','Tucson','2004','~',421),
  ('SUV','Hybrid','Hyundai','Tucson Hybrid','2020','~',422),
  ('SUV','Petrol','Hyundai','Santa Fe','2000','~',423),
  ('SUV','Hybrid','Hyundai','Santa Fe Hybrid','2020','~',424),
  ('SUV','Petrol','Hyundai','Palisade','2018','~',425),
  ('SUV','EV','Hyundai','Ioniq 5','2021','~',426),
  ('SUV','EV','Hyundai','Ioniq 5 N','2024','~',427),
  ('SUV','EV','Hyundai','Ioniq 6','2022','~',428),
  ('SUV','EV','Hyundai','Ioniq 9','2025','~',429),
  ('SUV','Petrol','Kia','Sonet','2020','~',430),
  ('SUV','Petrol','Kia','Seltos','2019','~',431),
  ('SUV','Petrol','Kia','Sportage','1993','~',432),
  ('SUV','Hybrid','Kia','Sportage Hybrid','2022','~',433),
  ('SUV','Petrol','Kia','Sorento','2002','~',434),
  ('SUV','Hybrid','Kia','Sorento Hybrid','2020','~',435),
  ('SUV','Petrol','Kia','Telluride','2019','~',436),
  ('SUV','EV','Kia','EV6','2021','~',437),
  ('SUV','EV','Kia','EV9','2023','~',438),
  ('SUV','EV','Kia','Niro EV','2018','~',439),
  ('SUV','Hybrid','Kia','Niro Hybrid','2016','~',440),
  ('SUV','Petrol','Mitsubishi','Outlander','2001','~',441),
  ('SUV','PHEV','Mitsubishi','Outlander PHEV','2013','~',442),
  ('SUV','Petrol','Mitsubishi','Eclipse Cross','2017','~',443),
  ('SUV','PHEV','Mitsubishi','Eclipse Cross PHEV','2020','~',444),
  ('SUV','Petrol','Mitsubishi','ASX','2010','~',445),
  ('SUV','Petrol','Mitsubishi','Pajero','1982','2021',446),
  ('SUV','Diesel','Mitsubishi','Pajero Sport','1996','~',447),
  ('SUV','Petrol','Mitsubishi','Xforce','2023','~',448),
  ('SUV','Petrol','Subaru','Forester','1997','~',449),
  ('SUV','Hybrid','Subaru','Forester e-Boxer','2018','~',450),
  ('SUV','Petrol','Subaru','XV','2011','~',451),
  ('SUV','Petrol','Subaru','Crosstrek','2012','~',452),
  ('SUV','Petrol','Subaru','Outback','1994','~',453),
  ('SUV','Petrol','Subaru','Ascent','2018','~',454),
  ('SUV','EV','Subaru','Solterra','2022','~',455),
  ('SUV','Petrol','BMW','X1','2009','~',456),
  ('SUV','EV','BMW','iX1','2022','~',457),
  ('SUV','Petrol','BMW','X2','2018','~',458),
  ('SUV','EV','BMW','iX2','2024','~',459),
  ('SUV','Petrol','BMW','X3','2003','~',460),
  ('SUV','Diesel','BMW','X3 xDrive20d','2003','~',461),
  ('SUV','EV','BMW','iX3','2020','~',462),
  ('SUV','Petrol','BMW','X4','2014','~',463),
  ('SUV','Petrol','BMW','X5','1999','~',464),
  ('SUV','PHEV','BMW','X5 xDrive45e','2019','~',465),
  ('SUV','Diesel','BMW','X5 xDrive30d','1999','~',466),
  ('SUV','Petrol','BMW','X5 M','2009','~',467),
  ('SUV','Petrol','BMW','X6','2008','~',468),
  ('SUV','Petrol','BMW','X6 M','2009','~',469),
  ('SUV','Petrol','BMW','X7','2018','~',470),
  ('SUV','EV','BMW','iX','2021','~',471),
  ('SUV','Petrol','BMW','XM','2022','~',472),
  ('SUV','Petrol','Mercedes-Benz','GLA','2014','~',473),
  ('SUV','Petrol','Mercedes-Benz','GLB','2019','~',474),
  ('SUV','Petrol','Mercedes-Benz','GLC','2015','~',475),
  ('SUV','PHEV','Mercedes-Benz','GLC 300e','2019','~',476),
  ('SUV','Petrol','Mercedes-Benz','GLE','2015','~',477),
  ('SUV','Diesel','Mercedes-Benz','GLE 300d','2015','~',478),
  ('SUV','Petrol','Mercedes-Benz','GLE 53 AMG','2019','~',479),
  ('SUV','Petrol','Mercedes-Benz','GLE 63 AMG','2019','~',480),
  ('SUV','Petrol','Mercedes-Benz','GLS','2015','~',481),
  ('SUV','Petrol','Mercedes-Benz','GLS 600 Maybach','2020','~',482),
  ('SUV','Petrol','Mercedes-Benz','G-Class G500','1979','~',483),
  ('SUV','Petrol','Mercedes-Benz','G-Class G63 AMG','1999','~',484),
  ('SUV','EV','Mercedes-Benz','G580 EQ','2024','~',485),
  ('SUV','EV','Mercedes-Benz','EQA','2021','~',486),
  ('SUV','EV','Mercedes-Benz','EQB','2021','~',487),
  ('SUV','EV','Mercedes-Benz','EQC','2019','~',488),
  ('SUV','EV','Mercedes-Benz','EQE SUV','2022','~',489),
  ('SUV','EV','Mercedes-Benz','EQS SUV','2022','~',490),
  ('SUV','Petrol','Audi','Q2','2016','~',491),
  ('SUV','Petrol','Audi','Q3','2011','~',492),
  ('SUV','Petrol','Audi','Q5','2008','~',493),
  ('SUV','PHEV','Audi','Q5 TFSI e','2019','~',494),
  ('SUV','Petrol','Audi','Q7','2005','~',495),
  ('SUV','Petrol','Audi','Q8','2018','~',496),
  ('SUV','Petrol','Audi','RS Q8','2020','~',497),
  ('SUV','EV','Audi','Q4 e-tron','2021','~',498),
  ('SUV','EV','Audi','Q6 e-tron','2024','~',499),
  ('SUV','EV','Audi','Q8 e-tron','2018','~',500),
  ('SUV','Petrol','Volvo','XC40','2017','~',501),
  ('SUV','EV','Volvo','XC40 Recharge','2020','~',502),
  ('SUV','EV','Volvo','EX30','2024','~',503),
  ('SUV','Petrol','Volvo','XC60','2008','~',504),
  ('SUV','PHEV','Volvo','XC60 T8','2017','~',505),
  ('SUV','Petrol','Volvo','XC90','2002','~',506),
  ('SUV','PHEV','Volvo','XC90 T8','2015','~',507),
  ('SUV','EV','Volvo','EX90','2024','~',508),
  ('SUV','EV','Volvo','C40 Recharge','2021','~',509),
  ('SUV','Petrol','Porsche','Macan','2014','~',510),
  ('SUV','EV','Porsche','Macan EV','2024','~',511),
  ('SUV','Petrol','Porsche','Cayenne','2002','~',512),
  ('SUV','Diesel','Porsche','Cayenne Diesel','2009','2018',513),
  ('SUV','PHEV','Porsche','Cayenne E-Hybrid','2014','~',514),
  ('SUV','Petrol','Porsche','Cayenne Turbo GT','2021','~',515),
  ('SUV','Petrol','Lexus','UX200','2018','~',516),
  ('SUV','Hybrid','Lexus','UX250h','2018','~',517),
  ('SUV','EV','Lexus','UX300e','2020','~',518),
  ('SUV','Petrol','Lexus','NX250','2014','~',519),
  ('SUV','Hybrid','Lexus','NX350h','2014','~',520),
  ('SUV','PHEV','Lexus','NX450h+','2021','~',521),
  ('SUV','Petrol','Lexus','RX350','1998','~',522),
  ('SUV','Hybrid','Lexus','RX450h','2009','~',523),
  ('SUV','PHEV','Lexus','RX500h','2022','~',524),
  ('SUV','Petrol','Lexus','GX460','2009','~',525),
  ('SUV','Petrol','Lexus','LX600','1996','~',526),
  ('SUV','EV','Lexus','RZ450e','2023','~',527),
  ('SUV','Petrol','Ford','EcoSport','2003','2022',528),
  ('SUV','Petrol','Ford','Escape','2000','~',529),
  ('SUV','Hybrid','Ford','Escape Hybrid','2004','~',530),
  ('SUV','Petrol','Ford','Edge','2006','2024',531),
  ('SUV','Petrol','Ford','Bronco','2020','~',532),
  ('SUV','Petrol','Ford','Bronco Sport','2020','~',533),
  ('SUV','Petrol','Ford','Everest','2003','~',534),
  ('SUV','Diesel','Ford','Everest Diesel','2003','~',535),
  ('SUV','Petrol','Ford','Explorer','1990','~',536),
  ('SUV','Petrol','Ford','Expedition','1996','~',537),
  ('SUV','EV','Ford','Mustang Mach-E','2021','~',538),
  ('SUV','EV','Ford','Explorer EV','2024','~',539),
  ('SUV','Petrol','Chevrolet','Trax','2012','~',540),
  ('SUV','Petrol','Chevrolet','Trailblazer','2001','~',541),
  ('SUV','Petrol','Chevrolet','Equinox','2004','~',542),
  ('SUV','EV','Chevrolet','Equinox EV','2024','~',543),
  ('SUV','Petrol','Chevrolet','Tahoe','1995','~',544),
  ('SUV','Petrol','Chevrolet','Suburban','1935','~',545),
  ('SUV','EV','Chevrolet','Blazer EV','2023','~',546),
  ('SUV','Petrol','GMC','Yukon','1991','~',547),
  ('SUV','EV','GMC','Hummer EV SUV','2023','~',548),
  ('SUV','Petrol','Jeep','Renegade','2014','~',549),
  ('SUV','Petrol','Jeep','Compass','2006','~',550),
  ('SUV','Petrol','Jeep','Cherokee','1974','~',551),
  ('SUV','Petrol','Jeep','Wrangler','1986','~',552),
  ('SUV','PHEV','Jeep','Wrangler 4xe','2021','~',553),
  ('SUV','Petrol','Jeep','Grand Cherokee','1992','~',554),
  ('SUV','PHEV','Jeep','Grand Cherokee 4xe','2021','~',555),
  ('SUV','Petrol','Jeep','Wagoneer','1962','~',556),
  ('SUV','EV','Jeep','Avenger','2023','~',557),
  ('SUV','Petrol','Land Rover','Range Rover','1970','~',558),
  ('SUV','Diesel','Land Rover','Range Rover Diesel','1970','~',559),
  ('SUV','Petrol','Land Rover','Range Rover Sport','2005','~',560),
  ('SUV','Petrol','Land Rover','Range Rover Velar','2017','~',561),
  ('SUV','Petrol','Land Rover','Range Rover Evoque','2011','~',562),
  ('SUV','Petrol','Land Rover','Defender','1983','~',563),
  ('SUV','Petrol','Land Rover','Discovery','1989','~',564),
  ('SUV','Petrol','Land Rover','Discovery Sport','2014','~',565),
  ('SUV','EV','Tesla','Model Y','2020','~',566),
  ('SUV','EV','Tesla','Model X','2015','~',567),
  ('SUV','EV','Tesla','Model X Plaid','2021','~',568),
  ('SUV','EV','BYD','Atto 3','2022','~',569),
  ('SUV','EV','BYD','Yuan Plus','2022','~',570),
  ('SUV','EV','BYD','Tang','2018','~',571),
  ('SUV','PHEV','BYD','Tang DM-i','2021','~',572),
  ('SUV','EV','BYD','Song Plus','2020','~',573),
  ('SUV','PHEV','BYD','Sealion 6','2023','~',574),
  ('SUV','EV','BYD','Sealion 7','2024','~',575),
  ('SUV','EV','Xpeng','G3','2018','~',576),
  ('SUV','EV','Xpeng','G6','2023','~',577),
  ('SUV','EV','Xpeng','G9','2022','~',578),
  ('SUV','EV','NIO','ES6','2018','~',579),
  ('SUV','EV','NIO','ES7','2022','~',580),
  ('SUV','EV','NIO','ES8','2018','~',581),
  ('SUV','EV','NIO','EC6','2020','~',582),
  ('SUV','EV','Rivian','R1S','2022','~',583),
  ('SUV','EV','Smart','#1','2022','~',584),
  ('SUV','EV','Smart','#3','2023','~',585),
  ('SUV','EV','Zeekr','X','2023','~',586),
  ('SUV','EV','MG','ZS EV','2019','~',587),
  ('SUV','Petrol','MG','HS','2018','~',588),
  ('SUV','PHEV','MG','HS PHEV','2020','~',589),
  ('SUV','EV','MG','Marvel R','2021','~',590),
  ('SUV','EV','Volkswagen','ID.4','2020','~',591),
  ('SUV','EV','Volkswagen','ID.5','2021','~',592),
  ('SUV','EV','Volkswagen','ID.6','2021','~',593),
  ('SUV','EV','Volkswagen','ID.7 Tourer','2024','~',594),
  ('SUV','Petrol','Volkswagen','Tiguan','2007','~',595),
  ('SUV','Petrol','Volkswagen','Touareg','2002','~',596),
  ('SUV','Petrol','Volkswagen','T-Roc','2017','~',597),
  ('SUV','Petrol','Volkswagen','T-Cross','2018','~',598),
  ('SUV','Petrol','Volkswagen','Atlas','2017','~',599),
  ('SUV','Petrol','Lynk & Co','01','2017','~',600),
  ('SUV','Petrol','Lynk & Co','02','2018','~',601),
  ('SUV','Petrol','Lynk & Co','06','2020','~',602),
  ('SUV','EV','Lynk & Co','Z10','2024','~',603),
  ('SUV','Petrol','GWM','Haval H6','2011','~',604),
  ('SUV','Petrol','GWM','Haval Jolion','2020','~',605),
  ('SUV','Petrol','GWM','Tank 300','2021','~',606),
  ('SUV','Petrol','GWM','Tank 500','2021','~',607),
  ('SUV','Petrol','Chery','Tiggo 7 Pro','2020','~',608),
  ('SUV','Petrol','Chery','Tiggo 8 Pro','2018','~',609),
  ('SUV','Petrol','Chery','Omoda 5','2022','~',610),
  ('SUV','EV','Chery','Omoda E5','2023','~',611),
  ('SUV','Petrol','Chery','Jaecoo J7','2023','~',612),
  ('SUV','Petrol','Geely','Coolray','2018','~',613),
  ('SUV','Petrol','Geely','Atlas','2016','~',614),
  ('SUV','Petrol','Geely','Boyue','2016','~',615),
  ('SUV','Petrol','Ferrari','Purosangue','2022','~',616),
  ('SUV','Petrol','Lamborghini','Urus','2018','~',617),
  ('SUV','PHEV','Lamborghini','Urus SE','2024','~',618),
  ('SUV','Petrol','Aston Martin','DBX','2020','~',619),
  ('SUV','Petrol','Bentley','Bentayga','2015','~',620),
  ('SUV','PHEV','Bentley','Bentayga Hybrid','2018','~',621),
  ('SUV','Petrol','Rolls-Royce','Cullinan','2018','~',622),
  ('SUV','Petrol','Maserati','Levante','2016','~',623),
  ('SUV','Petrol','Maserati','Grecale','2022','~',624),
  ('SUV','EV','Maserati','Grecale Folgore','2024','~',625),
  ('SUV','Petrol','Jaguar','F-Pace','2016','~',626),
  ('SUV','Petrol','Jaguar','E-Pace','2017','~',627),
  ('SUV','EV','Jaguar','I-Pace','2018','~',628),
  ('SUV','Petrol','Cadillac','XT4','2018','~',629),
  ('SUV','Petrol','Cadillac','XT5','2016','~',630),
  ('SUV','Petrol','Cadillac','Escalade','1998','~',631),
  ('SUV','EV','Cadillac','Lyriq','2022','~',632),
  ('SUV','EV','Cadillac','Escalade IQ','2024','~',633),
  ('SUV','Petrol','Lincoln','Navigator','1997','~',634),
  ('SUV','Petrol','Lincoln','Aviator','2002','~',635),
  ('SUV','Petrol','Lincoln','Nautilus','2018','~',636),
  ('SUV','Petrol','Acura','MDX','2000','~',637),
  ('SUV','Petrol','Acura','RDX','2006','~',638),
  ('SUV','Petrol','Infiniti','QX50','2013','~',639),
  ('SUV','Petrol','Infiniti','QX60','2012','~',640),
  ('SUV','Petrol','Infiniti','QX80','2010','~',641),
  ('SUV','Petrol','Genesis','GV70','2020','~',642),
  ('SUV','EV','Genesis','GV70 Electrified','2022','~',643),
  ('SUV','Petrol','Genesis','GV80','2020','~',644),
  ('SUV','EV','Genesis','GV60','2021','~',645),
  ('SUV','EV','Polestar','3','2023','~',646),
  ('SUV','EV','Polestar','4','2024','~',647),
  ('SUV','EV','Lucid','Gravity','2024','~',648),
  ('SUV','EV','Lotus','Eletre','2023','~',649),
  ('SUV','EV','Fisker','Ocean','2022','2024',650),
  ('SUV','EV','VinFast','VF8','2022','~',651),
  ('SUV','EV','VinFast','VF9','2023','~',652),
  ('MPV','Petrol','Proton','Exora','2009','~',653),
  ('MPV','Petrol','Perodua','Alza','2009','~',654),
  ('MPV','Petrol','Toyota','Avanza','2003','~',655),
  ('MPV','Petrol','Toyota','Veloz','2021','~',656),
  ('MPV','Petrol','Toyota','Innova','2004','~',657),
  ('MPV','Diesel','Toyota','Innova Diesel','2004','~',658),
  ('MPV','Hybrid','Toyota','Innova Zenix Hybrid','2022','~',659),
  ('MPV','Petrol','Toyota','Sienta','2003','~',660),
  ('MPV','Hybrid','Toyota','Sienta Hybrid','2015','~',661),
  ('MPV','Petrol','Toyota','Sienna','1997','~',662),
  ('MPV','Hybrid','Toyota','Sienna Hybrid','2020','~',663),
  ('MPV','Petrol','Toyota','Voxy','2001','~',664),
  ('MPV','Hybrid','Toyota','Voxy Hybrid','2014','~',665),
  ('MPV','Petrol','Toyota','Noah','2001','~',666),
  ('MPV','Petrol','Toyota','Estima','1990','2019',667),
  ('MPV','Petrol','Toyota','Alphard','2002','~',668),
  ('MPV','Hybrid','Toyota','Alphard Hybrid','2011','~',669),
  ('MPV','Petrol','Toyota','Vellfire','2008','~',670),
  ('MPV','Hybrid','Toyota','Vellfire Hybrid','2011','~',671),
  ('MPV','Petrol','Honda','Odyssey','1994','~',672),
  ('MPV','Hybrid','Honda','Odyssey Hybrid','2016','~',673),
  ('MPV','Petrol','Honda','BR-V','2015','~',674),
  ('MPV','Petrol','Honda','Freed','2008','~',675),
  ('MPV','Hybrid','Honda','Freed Hybrid','2011','~',676),
  ('MPV','Petrol','Honda','Stepwgn','1996','~',677),
  ('MPV','Petrol','Nissan','Serena','1991','~',678),
  ('MPV','Hybrid','Nissan','Serena e-Power','2018','~',679),
  ('MPV','Petrol','Nissan','Grand Livina','2006','~',680),
  ('MPV','Petrol','Nissan','Elgrand','1997','~',681),
  ('MPV','Petrol','Nissan','Quest','1992','2017',682),
  ('MPV','Petrol','Mitsubishi','Xpander','2017','~',683),
  ('MPV','Petrol','Mitsubishi','Delica','1968','~',684),
  ('MPV','Petrol','Hyundai','Starex','1997','~',685),
  ('MPV','Diesel','Hyundai','Starex Diesel','1997','~',686),
  ('MPV','Petrol','Hyundai','Staria','2021','~',687),
  ('MPV','Petrol','Kia','Carnival','1998','~',688),
  ('MPV','Diesel','Kia','Carnival Diesel','1998','~',689),
  ('MPV','Hybrid','Kia','Carnival Hybrid','2024','~',690),
  ('MPV','Petrol','Mercedes-Benz','V-Class','2014','~',691),
  ('MPV','EV','Mercedes-Benz','EQV','2020','~',692),
  ('MPV','Petrol','Volkswagen','Caddy','1979','~',693),
  ('MPV','Petrol','Volkswagen','Touran','2003','~',694),
  ('MPV','Petrol','Volkswagen','Sharan','1995','2022',695),
  ('MPV','EV','Volkswagen','ID. Buzz','2022','~',696),
  ('MPV','Petrol','Lexus','LM350','2019','~',697),
  ('MPV','Hybrid','Lexus','LM500h','2023','~',698),
  ('MPV','Petrol','Chrysler','Pacifica','2016','~',699),
  ('MPV','PHEV','Chrysler','Pacifica Hybrid','2017','~',700),
  ('MPV','Petrol','Chrysler','Voyager','1983','~',701),
  ('MPV','Petrol','Dodge','Grand Caravan','1983','2020',702),
  ('MPV','Petrol','Renault','Espace','1984','~',703),
  ('MPV','EV','Zeekr','009','2022','~',704),
  ('MPV','EV','BYD','Denza D9','2022','~',705),
  ('MPV','EV','Xpeng','X9','2024','~',706),
  ('Pick Up','Diesel','Toyota','Hilux','1968','~',707),
  ('Pick Up','Petrol','Toyota','Hilux Petrol','1968','~',708),
  ('Pick Up','Petrol','Toyota','Tacoma','1995','~',709),
  ('Pick Up','Hybrid','Toyota','Tacoma Hybrid','2024','~',710),
  ('Pick Up','Petrol','Toyota','Tundra','1999','~',711),
  ('Pick Up','Hybrid','Toyota','Tundra Hybrid','2022','~',712),
  ('Pick Up','Diesel','Ford','Ranger','1983','~',713),
  ('Pick Up','Petrol','Ford','Ranger Petrol','1983','~',714),
  ('Pick Up','Diesel','Ford','Ranger Raptor','2018','~',715),
  ('Pick Up','Petrol','Ford','Ranger Raptor Petrol','2022','~',716),
  ('Pick Up','Petrol','Ford','F-150','1975','~',717),
  ('Pick Up','Petrol','Ford','F-150 Raptor','2010','~',718),
  ('Pick Up','EV','Ford','F-150 Lightning','2022','~',719),
  ('Pick Up','Petrol','Ford','F-250 Super Duty','1999','~',720),
  ('Pick Up','Diesel','Ford','F-350 Super Duty','1999','~',721),
  ('Pick Up','Petrol','Ford','Maverick','2021','~',722),
  ('Pick Up','Hybrid','Ford','Maverick Hybrid','2021','~',723),
  ('Pick Up','Diesel','Mitsubishi','Triton','1978','~',724),
  ('Pick Up','Diesel','Mazda','BT-50','2006','~',725),
  ('Pick Up','Diesel','Isuzu','D-Max','2002','~',726),
  ('Pick Up','Diesel','Isuzu','D-Max V-Cross','2018','~',727),
  ('Pick Up','Diesel','Nissan','Navara','1985','~',728),
  ('Pick Up','Petrol','Nissan','Frontier','1997','~',729),
  ('Pick Up','Petrol','Nissan','Titan','2003','2024',730),
  ('Pick Up','Diesel','Volkswagen','Amarok','2010','~',731),
  ('Pick Up','Petrol','Chevrolet','Silverado','1998','~',732),
  ('Pick Up','Diesel','Chevrolet','Silverado Duramax','2001','~',733),
  ('Pick Up','EV','Chevrolet','Silverado EV','2024','~',734),
  ('Pick Up','Petrol','Chevrolet','Colorado','2003','~',735),
  ('Pick Up','Petrol','GMC','Sierra','1987','~',736),
  ('Pick Up','EV','GMC','Sierra EV','2024','~',737),
  ('Pick Up','EV','GMC','Hummer EV','2021','~',738),
  ('Pick Up','Petrol','GMC','Canyon','2003','~',739),
  ('Pick Up','Diesel','RAM','1500','1981','~',740),
  ('Pick Up','Petrol','RAM','1500 TRX','2020','2024',741),
  ('Pick Up','EV','RAM','1500 REV','2024','~',742),
  ('Pick Up','Diesel','RAM','2500','1981','~',743),
  ('Pick Up','Diesel','RAM','3500','1981','~',744),
  ('Pick Up','Petrol','Jeep','Gladiator','2019','~',745),
  ('Pick Up','Petrol','Honda','Ridgeline','2005','~',746),
  ('Pick Up','EV','Tesla','Cybertruck','2023','~',747),
  ('Pick Up','EV','Rivian','R1T','2021','~',748),
  ('Pick Up','Petrol','GWM','Cannon','2019','~',749),
  ('Pick Up','Diesel','GWM','Cannon Diesel','2019','~',750),
  ('Pick Up','Petrol','GWM','Tank 300 Pickup','2023','~',751),
  ('Pick Up','Diesel','SsangYong','Musso','1993','~',752),
  ('Pick Up','Petrol','Maxus','T60','2017','~',753),
  ('Pick Up','EV','Maxus','T90 EV','2022','~',754),
  ('Pick Up','EV','BYD','Shark','2024','~',755),
  ('Van','Diesel','Toyota','Hiace','1967','~',756),
  ('Van','Petrol','Toyota','Hiace Petrol','1967','~',757),
  ('Van','Diesel','Toyota','Granvia','2019','~',758),
  ('Van','Diesel','Mercedes-Benz','Sprinter','1995','~',759),
  ('Van','EV','Mercedes-Benz','eSprinter','2019','~',760),
  ('Van','Diesel','Mercedes-Benz','Vito','1996','~',761),
  ('Van','EV','Mercedes-Benz','eVito','2018','~',762),
  ('Van','Diesel','Volkswagen','Transporter','1950','~',763),
  ('Van','Diesel','Volkswagen','Crafter','2006','~',764),
  ('Van','EV','Volkswagen','ID. Buzz Cargo','2022','~',765),
  ('Van','Diesel','Ford','Transit','1965','~',766),
  ('Van','Diesel','Ford','Transit Custom','2012','~',767),
  ('Van','EV','Ford','E-Transit','2022','~',768),
  ('Van','EV','Ford','E-Transit Custom','2024','~',769),
  ('Van','Diesel','Hyundai','H-1','1997','~',770),
  ('Van','Diesel','Hyundai','H350','2015','~',771),
  ('Van','Diesel','Hyundai','Porter','1977','~',772),
  ('Van','Diesel','Renault','Trafic','1980','~',773),
  ('Van','Diesel','Renault','Master','1980','~',774),
  ('Van','EV','Renault','Master E-Tech','2022','~',775),
  ('Van','Diesel','Peugeot','Expert','1995','~',776),
  ('Van','Diesel','Peugeot','Boxer','1994','~',777),
  ('Van','EV','Peugeot','e-Expert','2020','~',778),
  ('Van','Diesel','Citroen','Jumper','1994','~',779),
  ('Van','Diesel','Citroen','Berlingo','1996','~',780),
  ('Van','EV','Citroen','e-Berlingo','2021','~',781),
  ('Van','Diesel','Fiat','Ducato','1981','~',782),
  ('Van','EV','Fiat','E-Ducato','2020','~',783),
  ('Van','Diesel','Iveco','Daily','1978','~',784),
  ('Van','EV','Iveco','eDaily','2022','~',785),
  ('Van','Diesel','Nissan','NV200','2009','~',786),
  ('Van','Diesel','Nissan','NV350 Caravan','2012','~',787),
  ('Van','EV','Nissan','Townstar EV','2022','~',788),
  ('Van','Petrol','Suzuki','APV','2004','~',789),
  ('Van','Petrol','Suzuki','Carry','1961','~',790),
  ('Van','EV','Maxus','MIFA 9','2021','~',791),
  ('Van','Diesel','Maxus','Deliver 9','2019','~',792),
  ('Van','EV','Maxus','eDeliver 9','2020','~',793),
  ('Van','Diesel','LDV','V80','2012','~',794),
  ('Van','EV','LDV','EV80','2018','~',795),
  ('Truck','Diesel','Hino','Series 300','2002','~',796),
  ('Truck','Diesel','Hino','Series 500','2002','~',797),
  ('Truck','Diesel','Hino','Series 700','2002','~',798),
  ('Truck','Diesel','Hino','Dutro','1999','~',799),
  ('Truck','Diesel','Hino','Ranger','1980','~',800),
  ('Truck','Diesel','Isuzu','ELF','1959','~',801),
  ('Truck','Diesel','Isuzu','Forward','1970','~',802),
  ('Truck','Diesel','Isuzu','Giga','1994','~',803),
  ('Truck','Diesel','Isuzu','F-Series','1970','~',804),
  ('Truck','Diesel','Mitsubishi Fuso','Canter','1963','~',805),
  ('Truck','Diesel','Mitsubishi Fuso','Fighter','1984','~',806),
  ('Truck','Diesel','Mitsubishi Fuso','Super Great','1996','~',807),
  ('Truck','EV','Mitsubishi Fuso','eCanter','2017','~',808),
  ('Truck','Diesel','UD Trucks','Quester','2013','~',809),
  ('Truck','Diesel','UD Trucks','Quon','2004','~',810),
  ('Truck','Diesel','UD Trucks','Croner','2017','~',811),
  ('Truck','Diesel','UD Trucks','Kuzer','2017','~',812),
  ('Truck','Diesel','Scania','P-Series','2004','~',813),
  ('Truck','Diesel','Scania','G-Series','2007','~',814),
  ('Truck','Diesel','Scania','R-Series','2004','~',815),
  ('Truck','Diesel','Scania','S-Series','2017','~',816),
  ('Truck','EV','Scania','BEV Truck','2020','~',817),
  ('Truck','Diesel','Volvo','FL','1985','~',818),
  ('Truck','Diesel','Volvo','FE','2006','~',819),
  ('Truck','Diesel','Volvo','FH','1993','~',820),
  ('Truck','Diesel','Volvo','FH16','1993','~',821),
  ('Truck','Diesel','Volvo','FM','1998','~',822),
  ('Truck','Diesel','Volvo','FMX','2010','~',823),
  ('Truck','EV','Volvo','FH Electric','2022','~',824),
  ('Truck','EV','Volvo','FE Electric','2019','~',825),
  ('Truck','EV','Volvo','FL Electric','2019','~',826),
  ('Truck','Diesel','Mercedes-Benz','Atego','1998','~',827),
  ('Truck','Diesel','Mercedes-Benz','Axor','2001','2014',828),
  ('Truck','Diesel','Mercedes-Benz','Actros','1996','~',829),
  ('Truck','Diesel','Mercedes-Benz','Arocs','2013','~',830),
  ('Truck','EV','Mercedes-Benz','eActros','2021','~',831),
  ('Truck','EV','Mercedes-Benz','eActros 600','2024','~',832),
  ('Truck','Diesel','MAN','TGL','2005','~',833),
  ('Truck','Diesel','MAN','TGM','2005','~',834),
  ('Truck','Diesel','MAN','TGS','2007','~',835),
  ('Truck','Diesel','MAN','TGX','2007','~',836),
  ('Truck','EV','MAN','eTGX','2024','~',837),
  ('Truck','Diesel','DAF','LF','2001','~',838),
  ('Truck','Diesel','DAF','CF','2000','~',839),
  ('Truck','Diesel','DAF','XF','1997','~',840),
  ('Truck','Diesel','DAF','XG','2021','~',841),
  ('Truck','EV','DAF','XD Electric','2023','~',842),
  ('Truck','Diesel','Iveco','Eurocargo','1991','~',843),
  ('Truck','Diesel','Iveco','Stralis','2002','2019',844),
  ('Truck','Diesel','Iveco','S-Way','2019','~',845),
  ('Truck','EV','Iveco','S-eWay','2024','~',846),
  ('Truck','EV','Tesla','Semi','2022','~',847),
  ('Truck','Diesel','Kenworth','T680','2011','~',848),
  ('Truck','EV','Kenworth','T680E','2021','~',849),
  ('Truck','Diesel','Peterbilt','579','2012','~',850),
  ('Truck','EV','Peterbilt','579EV','2021','~',851),
  ('Truck','Diesel','Freightliner','Cascadia','2007','~',852),
  ('Truck','EV','Freightliner','eCascadia','2022','~',853),
  ('Truck','Diesel','International','LT Series','2017','~',854),
  ('Truck','Diesel','Mack','Anthem','2017','~',855),
  ('Truck','EV','Nikola','Tre BEV','2022','~',856),
  ('Truck','Hydrogen','Nikola','Tre FCEV','2023','~',857),
  ('Truck','EV','BYD','Q1M','2020','~',858),
  ('Truck','Diesel','Sinotruk','HOWO','2004','~',859),
  ('Truck','Diesel','FAW','Jiefang J7','2018','~',860),
  ('Truck','Diesel','Foton','Auman','2002','~',861),
  ('Truck','Diesel','JAC','N-Series','2010','~',862),
  ('Truck','Diesel','Tata','Prima','2009','~',863),
  ('Truck','Diesel','Ashok Leyland','Boss','2014','~',864),
  ('Bus','Diesel','Mercedes-Benz','Citaro','1997','~',865),
  ('Bus','EV','Mercedes-Benz','eCitaro','2018','~',866),
  ('Bus','Diesel','Mercedes-Benz','Tourismo','1994','~',867),
  ('Bus','Diesel','Mercedes-Benz','Travego','1999','~',868),
  ('Bus','Diesel','Setra','MultiClass','2002','~',869),
  ('Bus','Diesel','Setra','ComfortClass','2012','~',870),
  ('Bus','Diesel','Setra','TopClass','2012','~',871),
  ('Bus','Diesel','Volvo','B8R','2014','~',872),
  ('Bus','Diesel','Volvo','B11R','2011','~',873),
  ('Bus','Diesel','Volvo','9700','2001','~',874),
  ('Bus','EV','Volvo','7900 Electric','2018','~',875),
  ('Bus','EV','Volvo','BZL Electric','2022','~',876),
  ('Bus','Diesel','Scania','K-Series','2005','~',877),
  ('Bus','Diesel','Scania','F-Series','2010','~',878),
  ('Bus','Diesel','Scania','Touring','2010','~',879),
  ('Bus','Diesel','Hino','RM1','2006','~',880),
  ('Bus','Diesel','Hino','RK8','2010','~',881),
  ('Bus','Diesel','Hino','Selega','2000','~',882),
  ('Bus','Diesel','Higer','KLQ6128','2008','~',883),
  ('Bus','Diesel','Higer','KLQ6122','2008','~',884),
  ('Bus','Diesel','King Long','XMQ6127','2010','~',885),
  ('Bus','Diesel','King Long','XMQ6900','2010','~',886),
  ('Bus','EV','BYD','K9','2010','~',887),
  ('Bus','EV','BYD','B12','2017','~',888),
  ('Bus','EV','BYD','K7','2014','~',889),
  ('Bus','EV','BYD','ADL Enviro200EV','2015','~',890),
  ('Bus','EV','Yutong','E12','2019','~',891),
  ('Bus','EV','Yutong','E10','2018','~',892),
  ('Bus','EV','Yutong','T12E','2020','~',893),
  ('Bus','Diesel','Iveco','Crossway','2006','~',894),
  ('Bus','Diesel','Iveco','Magelys','2004','2019',895),
  ('Bus','CNG','MAN','Lion''s City','1998','~',896),
  ('Bus','EV','MAN','Lion''s City E','2020','~',897),
  ('Bus','Diesel','MAN','Lion''s Coach','1996','~',898),
  ('Bus','Diesel','Neoplan','Cityliner','1971','~',899),
  ('Bus','Diesel','Neoplan','Tourliner','2006','~',900),
  ('Bus','Diesel','Solaris','Urbino 12','1999','~',901),
  ('Bus','EV','Solaris','Urbino Electric','2013','~',902),
  ('Bus','Hydrogen','Solaris','Urbino Hydrogen','2019','~',903),
  ('Bus','EV','Proterra','ZX5','2020','~',904),
  ('Bus','EV','New Flyer','Xcelsior CHARGE','2017','~',905),
  ('Bus','Diesel','Tata','Starbus','2007','~',906),
  ('Bus','EV','Tata','Starbus EV','2017','~',907),
  ('Bus','Diesel','Ashok Leyland','Viking','1979','~',908),
  ('Bus','EV','Ashok Leyland','Switch EiV 22','2022','~',909),
  ('Bike','Petrol','Yamaha','Y15ZR','2015','~',910),
  ('Bike','Petrol','Yamaha','Y16ZR','2021','~',911),
  ('Bike','Petrol','Yamaha','LC135','2007','~',912),
  ('Bike','Petrol','Yamaha','Lagenda 115Z','2014','~',913),
  ('Bike','Petrol','Yamaha','MT-03','2016','~',914),
  ('Bike','Petrol','Yamaha','MT-07','2014','~',915),
  ('Bike','Petrol','Yamaha','MT-09','2014','~',916),
  ('Bike','Petrol','Yamaha','MT-10','2016','~',917),
  ('Bike','Petrol','Yamaha','MT-15','2018','~',918),
  ('Bike','Petrol','Yamaha','MT-25','2015','~',919),
  ('Bike','Petrol','Yamaha','R3','2014','~',920),
  ('Bike','Petrol','Yamaha','R7','2021','~',921),
  ('Bike','Petrol','Yamaha','R15','2008','~',922),
  ('Bike','Petrol','Yamaha','R25','2014','~',923),
  ('Bike','Petrol','Yamaha','R6','1999','2020',924),
  ('Bike','Petrol','Yamaha','R1','1998','~',925),
  ('Bike','Petrol','Yamaha','R1M','2015','~',926),
  ('Bike','Petrol','Yamaha','FZ150i','2009','~',927),
  ('Bike','Petrol','Yamaha','Tenere 700','2019','~',928),
  ('Bike','Petrol','Yamaha','Niken GT','2018','~',929),
  ('Bike','Petrol','Yamaha','VMAX','1985','2020',930),
  ('Bike','Petrol','Honda','Wave 110','1995','~',931),
  ('Bike','Petrol','Honda','Wave 125','2002','~',932),
  ('Bike','Petrol','Honda','Dash 110','2009','~',933),
  ('Bike','Petrol','Honda','RS150R','2016','~',934),
  ('Bike','Petrol','Honda','RS-X','2022','~',935),
  ('Bike','Petrol','Honda','Winner X','2020','~',936),
  ('Bike','Petrol','Honda','CB150R Streetfire','2015','~',937),
  ('Bike','Petrol','Honda','CBR150R','2002','~',938),
  ('Bike','Petrol','Honda','CBR250RR','2016','~',939),
  ('Bike','Petrol','Honda','CBR500R','2013','~',940),
  ('Bike','Petrol','Honda','CBR650R','2019','~',941),
  ('Bike','Petrol','Honda','CBR1000RR','2004','~',942),
  ('Bike','Petrol','Honda','CBR1000RR-R Fireblade','2020','~',943),
  ('Bike','Petrol','Honda','CB300R','2018','~',944),
  ('Bike','Petrol','Honda','CB500F','2013','~',945),
  ('Bike','Petrol','Honda','CB650R','2019','~',946),
  ('Bike','Petrol','Honda','CB1000R','2008','~',947),
  ('Bike','Petrol','Honda','Africa Twin','1988','~',948),
  ('Bike','Petrol','Honda','Africa Twin Adventure Sports','2018','~',949),
  ('Bike','Petrol','Honda','NC750X','2014','~',950),
  ('Bike','Petrol','Honda','Goldwing','1975','~',951),
  ('Bike','Petrol','Kawasaki','Ninja 250','2008','~',952),
  ('Bike','Petrol','Kawasaki','Ninja 300','2012','~',953),
  ('Bike','Petrol','Kawasaki','Ninja 400','2018','~',954),
  ('Bike','Petrol','Kawasaki','Ninja 500','2024','~',955),
  ('Bike','Petrol','Kawasaki','Ninja 650','2009','~',956),
  ('Bike','Petrol','Kawasaki','Ninja ZX-4RR','2023','~',957),
  ('Bike','Petrol','Kawasaki','Ninja ZX-6R','1995','~',958),
  ('Bike','Petrol','Kawasaki','Ninja ZX-10R','2004','~',959),
  ('Bike','Petrol','Kawasaki','Ninja ZX-10RR','2017','~',960),
  ('Bike','Petrol','Kawasaki','Ninja H2','2015','~',961),
  ('Bike','Petrol','Kawasaki','Ninja H2R','2015','~',962),
  ('Bike','Petrol','Kawasaki','Z400','2018','~',963),
  ('Bike','Petrol','Kawasaki','Z650','2017','~',964),
  ('Bike','Petrol','Kawasaki','Z900','2017','~',965),
  ('Bike','Petrol','Kawasaki','Z1000','2003','2020',966),
  ('Bike','Petrol','Kawasaki','Z H2','2020','~',967),
  ('Bike','Petrol','Kawasaki','Versys 650','2007','~',968),
  ('Bike','Petrol','Kawasaki','Versys 1000','2012','~',969),
  ('Bike','Petrol','Kawasaki','KLX 230','2020','~',970),
  ('Bike','Petrol','Kawasaki','KX 450','1974','~',971),
  ('Bike','Petrol','Suzuki','GSX-R150','2017','~',972),
  ('Bike','Petrol','Suzuki','GSX-S150','2017','~',973),
  ('Bike','Petrol','Suzuki','GSX-R600','1997','~',974),
  ('Bike','Petrol','Suzuki','GSX-R750','1985','~',975),
  ('Bike','Petrol','Suzuki','GSX-R1000','2001','~',976),
  ('Bike','Petrol','Suzuki','GSX-S1000','2015','~',977),
  ('Bike','Petrol','Suzuki','GSX-8S','2023','~',978),
  ('Bike','Petrol','Suzuki','GSX-8R','2024','~',979),
  ('Bike','Petrol','Suzuki','Hayabusa','1999','~',980),
  ('Bike','Petrol','Suzuki','V-Strom 250','2017','~',981),
  ('Bike','Petrol','Suzuki','V-Strom 650','2004','~',982),
  ('Bike','Petrol','Suzuki','V-Strom 1050','2019','~',983),
  ('Bike','Petrol','Suzuki','Katana','1981','~',984),
  ('Bike','Petrol','Ducati','Panigale V2','2020','~',985),
  ('Bike','Petrol','Ducati','Panigale V4','2018','~',986),
  ('Bike','Petrol','Ducati','Panigale V4 R','2019','~',987),
  ('Bike','Petrol','Ducati','Monster','1993','~',988),
  ('Bike','Petrol','Ducati','Monster SP','2023','~',989),
  ('Bike','Petrol','Ducati','Streetfighter V2','2022','~',990),
  ('Bike','Petrol','Ducati','Streetfighter V4','2020','~',991),
  ('Bike','Petrol','Ducati','Multistrada V2','2022','~',992),
  ('Bike','Petrol','Ducati','Multistrada V4','2021','~',993),
  ('Bike','Petrol','Ducati','Diavel V4','2023','~',994),
  ('Bike','Petrol','Ducati','XDiavel','2016','~',995),
  ('Bike','Petrol','Ducati','Scrambler','2015','~',996),
  ('Bike','Petrol','Ducati','DesertX','2022','~',997),
  ('Bike','Petrol','Ducati','Hypermotard 950','2019','~',998),
  ('Bike','Petrol','Harley-Davidson','Iron 883','2009','2022',999),
  ('Bike','Petrol','Harley-Davidson','Forty-Eight','2010','2022',1000),
  ('Bike','Petrol','Harley-Davidson','Sportster S','2021','~',1001),
  ('Bike','Petrol','Harley-Davidson','Nightster','2022','~',1002),
  ('Bike','Petrol','Harley-Davidson','Street 750','2014','2021',1003),
  ('Bike','Petrol','Harley-Davidson','Street Glide','2006','~',1004),
  ('Bike','Petrol','Harley-Davidson','Road Glide','1998','~',1005),
  ('Bike','Petrol','Harley-Davidson','Road King','1994','~',1006),
  ('Bike','Petrol','Harley-Davidson','Fat Boy','1990','~',1007),
  ('Bike','Petrol','Harley-Davidson','Heritage Classic','1986','~',1008),
  ('Bike','Petrol','Harley-Davidson','Pan America 1250','2021','~',1009),
  ('Bike','Petrol','Harley-Davidson','CVO Street Glide','2010','~',1010),
  ('Bike','EV','Harley-Davidson','LiveWire','2019','2021',1011),
  ('Bike','Petrol','BMW','G 310 R','2016','~',1012),
  ('Bike','Petrol','BMW','G 310 GS','2017','~',1013),
  ('Bike','Petrol','BMW','F 750 GS','2018','2023',1014),
  ('Bike','Petrol','BMW','F 850 GS','2018','~',1015),
  ('Bike','Petrol','BMW','F 900 R','2020','~',1016),
  ('Bike','Petrol','BMW','F 900 XR','2020','~',1017),
  ('Bike','Petrol','BMW','R 1250 GS','2018','2023',1018),
  ('Bike','Petrol','BMW','R 1250 GS Adventure','2018','2023',1019),
  ('Bike','Petrol','BMW','R 1300 GS','2024','~',1020),
  ('Bike','Petrol','BMW','S 1000 RR','2009','~',1021),
  ('Bike','Petrol','BMW','M 1000 RR','2020','~',1022),
  ('Bike','Petrol','BMW','S 1000 R','2014','~',1023),
  ('Bike','Petrol','BMW','S 1000 XR','2015','~',1024),
  ('Bike','Petrol','BMW','R nineT','2014','~',1025),
  ('Bike','Petrol','BMW','K 1600 GTL','2011','~',1026),
  ('Bike','Petrol','KTM','Duke 125','2011','~',1027),
  ('Bike','Petrol','KTM','Duke 200','2012','~',1028),
  ('Bike','Petrol','KTM','Duke 250','2017','~',1029),
  ('Bike','Petrol','KTM','Duke 390','2013','~',1030),
  ('Bike','Petrol','KTM','Duke 790','2018','~',1031),
  ('Bike','Petrol','KTM','Duke 890','2020','~',1032),
  ('Bike','Petrol','KTM','RC 125','2014','~',1033),
  ('Bike','Petrol','KTM','RC 390','2014','~',1034),
  ('Bike','Petrol','KTM','1290 Super Duke R','2014','~',1035),
  ('Bike','Petrol','KTM','1290 Super Adventure','2015','~',1036),
  ('Bike','Petrol','KTM','390 Adventure','2020','~',1037),
  ('Bike','Petrol','Aprilia','RS 125','1992','~',1038),
  ('Bike','Petrol','Aprilia','RS 660','2021','~',1039),
  ('Bike','Petrol','Aprilia','Tuono 660','2021','~',1040),
  ('Bike','Petrol','Aprilia','Tuono V4','2011','~',1041),
  ('Bike','Petrol','Aprilia','RSV4','2009','~',1042),
  ('Bike','Petrol','Aprilia','Tuareg 660','2022','~',1043),
  ('Bike','Petrol','Triumph','Bonneville T100','2002','~',1044),
  ('Bike','Petrol','Triumph','Bonneville T120','2016','~',1045),
  ('Bike','Petrol','Triumph','Speed Twin','2019','~',1046),
  ('Bike','Petrol','Triumph','Speed 400','2023','~',1047),
  ('Bike','Petrol','Triumph','Scrambler 400 X','2024','~',1048),
  ('Bike','Petrol','Triumph','Street Triple','2007','~',1049),
  ('Bike','Petrol','Triumph','Street Triple RS','2017','~',1050),
  ('Bike','Petrol','Triumph','Speed Triple 1200 RS','2021','~',1051),
  ('Bike','Petrol','Triumph','Speed Triple 1200 RR','2022','~',1052),
  ('Bike','Petrol','Triumph','Tiger 660 Sport','2021','~',1053),
  ('Bike','Petrol','Triumph','Tiger 900','2020','~',1054),
  ('Bike','Petrol','Triumph','Tiger 1200','2012','~',1055),
  ('Bike','Petrol','Triumph','Daytona 660','2024','~',1056),
  ('Bike','Petrol','Triumph','Rocket 3','2004','~',1057),
  ('Bike','Petrol','MV Agusta','F3 800','2014','~',1058),
  ('Bike','Petrol','MV Agusta','Brutale 1000 RR','2020','~',1059),
  ('Bike','Petrol','MV Agusta','Dragster 800 RR','2018','~',1060),
  ('Bike','Petrol','Norton','V4SV','2022','~',1061),
  ('Bike','Petrol','Norton','Commando 961','2023','~',1062),
  ('Bike','Petrol','Modenas','Kriss 110','1996','~',1063),
  ('Bike','Petrol','Modenas','Karisma','2006','2018',1064),
  ('Bike','Petrol','Modenas','Pulsar NS200','2014','~',1065),
  ('Bike','Petrol','Modenas','Pulsar RS200','2015','~',1066),
  ('Bike','Petrol','Modenas','Dominar 400','2017','~',1067),
  ('Bike','Petrol','SYM','Sport Rider 125i','2014','~',1068),
  ('Bike','Petrol','Benelli','TNT 135','2017','~',1069),
  ('Bike','Petrol','Benelli','TRK 251','2020','~',1070),
  ('Bike','Petrol','Benelli','TRK 502','2017','~',1071),
  ('Bike','Petrol','Benelli','TRK 702','2024','~',1072),
  ('Bike','Petrol','Benelli','TNT 600i','2014','~',1073),
  ('Bike','Petrol','Benelli','Leoncino 500','2017','~',1074),
  ('Bike','Petrol','CFMOTO','300NK','2018','~',1075),
  ('Bike','Petrol','CFMOTO','650NK','2012','~',1076),
  ('Bike','Petrol','CFMOTO','700CL-X','2021','~',1077),
  ('Bike','Petrol','CFMOTO','800MT','2021','~',1078),
  ('Bike','Petrol','CFMOTO','450SR','2023','~',1079),
  ('Bike','Petrol','Royal Enfield','Bullet 350','1948','~',1080),
  ('Bike','Petrol','Royal Enfield','Classic 350','2009','~',1081),
  ('Bike','Petrol','Royal Enfield','Hunter 350','2022','~',1082),
  ('Bike','Petrol','Royal Enfield','Meteor 350','2020','~',1083),
  ('Bike','Petrol','Royal Enfield','Himalayan','2016','~',1084),
  ('Bike','Petrol','Royal Enfield','Himalayan 450','2023','~',1085),
  ('Bike','Petrol','Royal Enfield','Continental GT 650','2018','~',1086),
  ('Bike','Petrol','Royal Enfield','Interceptor 650','2018','~',1087),
  ('Bike','Petrol','Royal Enfield','Super Meteor 650','2023','~',1088),
  ('Bike','Petrol','Bajaj','Pulsar 150','2001','~',1089),
  ('Bike','Petrol','Bajaj','Pulsar NS200','2012','~',1090),
  ('Bike','Petrol','Bajaj','Dominar 400','2017','~',1091),
  ('Bike','Petrol','TVS','Apache RTR 200','2016','~',1092),
  ('Bike','Petrol','TVS','Apache RR 310','2018','~',1093),
  ('Bike','Petrol','Hero','Splendor Plus','1994','~',1094),
  ('Bike','Petrol','Hero','Xpulse 200','2019','~',1095),
  ('Bike','EV','Zero Motorcycles','S','2009','~',1096),
  ('Bike','EV','Zero Motorcycles','DSR','2015','~',1097),
  ('Bike','EV','Zero Motorcycles','SR/F','2019','~',1098),
  ('Bike','EV','Zero Motorcycles','SR/S','2020','~',1099),
  ('Bike','EV','Energica','Ego','2014','~',1100),
  ('Bike','EV','Energica','Eva Ribelle','2019','~',1101),
  ('Bike','EV','Energica','Experia','2022','~',1102),
  ('Bike','EV','LiveWire','One','2021','~',1103),
  ('Bike','EV','LiveWire','S2 Del Mar','2024','~',1104),
  ('Bike','EV','Davinci','DC100','2022','~',1105),
  ('Bike','EV','CAKE','Kalk OR','2018','~',1106),
  ('Bike','EV','Damon','HyperSport','2024','~',1107),
  ('Bike','EV','Verge','TS Ultra','2023','~',1108),
  ('Scooter','Petrol','Yamaha','Mio','2003','~',1109),
  ('Scooter','Petrol','Yamaha','NMAX 155','2015','~',1110),
  ('Scooter','Petrol','Yamaha','Aerox 155','2016','~',1111),
  ('Scooter','Petrol','Yamaha','XMAX 250','2017','~',1112),
  ('Scooter','Petrol','Yamaha','XMAX 300','2017','~',1113),
  ('Scooter','Petrol','Yamaha','TMAX 560','2020','~',1114),
  ('Scooter','Petrol','Honda','BeAT','2008','~',1115),
  ('Scooter','Petrol','Honda','Vario 125','2014','~',1116),
  ('Scooter','Petrol','Honda','Vario 160','2022','~',1117),
  ('Scooter','Petrol','Honda','ADV 160','2022','~',1118),
  ('Scooter','Petrol','Honda','PCX 125','2009','~',1119),
  ('Scooter','Petrol','Honda','PCX 160','2021','~',1120),
  ('Scooter','Petrol','Honda','Forza 250','2008','~',1121),
  ('Scooter','Petrol','Honda','Forza 350','2020','~',1122),
  ('Scooter','Petrol','Honda','Forza 750','2021','~',1123),
  ('Scooter','Petrol','Honda','X-ADV 750','2017','~',1124),
  ('Scooter','Petrol','Vespa','Primavera 150','2014','~',1125),
  ('Scooter','Petrol','Vespa','Sprint 150','2014','~',1126),
  ('Scooter','Petrol','Vespa','GTS 300','2017','~',1127),
  ('Scooter','Petrol','Vespa','GTS 300 HPE','2019','~',1128),
  ('Scooter','Petrol','SYM','Cruisym 250','2017','~',1129),
  ('Scooter','Petrol','SYM','Maxsym TL 500','2020','~',1130),
  ('Scooter','Petrol','SYM','Joymax Z 300','2020','~',1131),
  ('Scooter','Petrol','Kymco','AK 550','2017','~',1132),
  ('Scooter','Petrol','Kymco','Xciting S 400','2018','~',1133),
  ('Scooter','Petrol','Kymco','DTX 360','2022','~',1134),
  ('Scooter','Petrol','Piaggio','Beverly 400','2021','~',1135),
  ('Scooter','Petrol','Piaggio','MP3 530','2022','~',1136),
  ('Scooter','Petrol','Suzuki','Burgman 400','2007','~',1137),
  ('Scooter','EV','Niu','NQi GTS','2018','~',1138),
  ('Scooter','EV','Niu','MQi GT','2020','~',1139),
  ('Scooter','EV','Niu','RQi','2021','~',1140),
  ('Scooter','EV','Gogoro','Smartscooter 2','2017','~',1141),
  ('Scooter','EV','Gogoro','Pulse','2024','~',1142),
  ('Scooter','EV','Vespa','Elettrica','2019','~',1143),
  ('Scooter','EV','BMW','CE 04','2022','~',1144),
  ('Scooter','EV','BMW','CE 02','2024','~',1145),
  ('Scooter','EV','Silence','S01','2020','~',1146),
  ('Scooter','EV','Super Soco','CPx','2020','~',1147),
  ('Scooter','EV','Yadea','G5','2019','~',1148),
  ('Scooter','EV','Ola Electric','S1 Pro','2021','~',1149),
  ('Scooter','EV','Ather','450X','2020','~',1150),
  ('Scooter','EV','TVS','iQube','2020','~',1151),
  ('Scooter','EV','Bajaj','Chetak Electric','2020','~',1152),
  ('Auto Rickshaw','Petrol','Bajaj','RE Compact','1959','~',1153),
  ('Auto Rickshaw','CNG','Bajaj','RE Compact CNG','2005','~',1154),
  ('Auto Rickshaw','EV','Bajaj','RE EV','2022','~',1155),
  ('Auto Rickshaw','Petrol','Bajaj','Maxima Z','2014','~',1156),
  ('Auto Rickshaw','Petrol','TVS','King Deluxe','2010','~',1157),
  ('Auto Rickshaw','CNG','TVS','King Duramax','2014','~',1158),
  ('Auto Rickshaw','EV','Mahindra','Treo','2018','~',1159),
  ('Auto Rickshaw','EV','Mahindra','Treo Yaari','2019','~',1160),
  ('Auto Rickshaw','EV','Mahindra','Zor Grand','2022','~',1161),
  ('Auto Rickshaw','EV','Piaggio','Ape E-City','2019','~',1162),
  ('Auto Rickshaw','Petrol','Piaggio','Ape Auto','1948','~',1163),
  ('Auto Rickshaw','Diesel','Piaggio','Ape Xtra LDX','2014','~',1164),
  ('Auto Rickshaw','EV','Atul','Elite Plus','2018','~',1165),
  ('Auto Rickshaw','EV','YC Electric','Yatri Super','2018','~',1166),
  ('Kei Car','Petrol','Suzuki','Wagon R','1993','~',1167),
  ('Kei Car','Hybrid','Suzuki','Wagon R Hybrid','2017','~',1168),
  ('Kei Car','Petrol','Suzuki','Alto Lapin','2002','~',1169),
  ('Kei Car','Petrol','Suzuki','Hustler','2014','~',1170),
  ('Kei Car','Petrol','Suzuki','Spacia','2013','~',1171),
  ('Kei Car','Petrol','Suzuki','Jimny','1970','~',1172),
  ('Kei Car','Petrol','Daihatsu','Move','1995','~',1173),
  ('Kei Car','Petrol','Daihatsu','Tanto','2003','~',1174),
  ('Kei Car','Petrol','Daihatsu','Mira e:S','2011','~',1175),
  ('Kei Car','Petrol','Daihatsu','Copen','2002','~',1176),
  ('Kei Car','Petrol','Honda','N-Box','2011','~',1177),
  ('Kei Car','Petrol','Honda','N-One','2012','~',1178),
  ('Kei Car','Petrol','Honda','N-WGN','2013','~',1179),
  ('Kei Car','EV','Honda','N-Van e:','2024','~',1180),
  ('Kei Car','Petrol','Mitsubishi','eK Wagon','2001','~',1181),
  ('Kei Car','EV','Mitsubishi','eK X EV','2022','~',1182),
  ('Kei Car','Petrol','Nissan','Dayz','2013','~',1183),
  ('Kei Car','EV','Nissan','Sakura','2022','~',1184),
  ('Kei Car','EV','Wuling','Hongguang Mini EV','2020','~',1185),
  ('Bicycle','Manual','Trek','Madone SLR','2003','~',1186),
  ('Bicycle','Manual','Trek','Domane SLR','2012','~',1187),
  ('Bicycle','Manual','Trek','Emonda SLR','2014','~',1188),
  ('Bicycle','Manual','Specialized','Tarmac SL8','2023','~',1189),
  ('Bicycle','Manual','Specialized','Roubaix SL8','2023','~',1190),
  ('Bicycle','Manual','Specialized','Allez','1981','~',1191),
  ('Bicycle','Manual','Giant','TCR Advanced SL','1998','~',1192),
  ('Bicycle','Manual','Giant','Defy Advanced','2008','~',1193),
  ('Bicycle','Manual','Giant','Propel Advanced SL','2013','~',1194),
  ('Bicycle','Manual','Cannondale','SuperSix EVO','2008','~',1195),
  ('Bicycle','Manual','Cannondale','Synapse Carbon','2006','~',1196),
  ('Bicycle','Manual','Cervelo','S5','2010','~',1197),
  ('Bicycle','Manual','Cervelo','R5','2008','~',1198),
  ('Bicycle','Manual','Pinarello','Dogma F','2022','~',1199),
  ('Bicycle','Manual','Bianchi','Oltre RC','2022','~',1200),
  ('Bicycle','Manual','Canyon','Aeroad CFR','2014','~',1201),
  ('Bicycle','Manual','Canyon','Ultimate CFR','2020','~',1202),
  ('Bicycle','Manual','Brompton','C Line','1976','~',1203),
  ('Bicycle','EV','Brompton','Electric P Line','2022','~',1204),
  ('Bicycle','EV','Specialized','Turbo Vado SL','2020','~',1205),
  ('Bicycle','EV','Specialized','Turbo Levo','2015','~',1206),
  ('Bicycle','EV','Trek','Domane+ SLR','2022','~',1207),
  ('Bicycle','EV','Trek','Rail 9.9','2019','~',1208),
  ('Bicycle','EV','Giant','Trance X E+','2020','~',1209),
  ('Bicycle','EV','Cannondale','Topstone Neo','2020','~',1210),
  ('Bicycle','EV','VanMoof','S5','2022','~',1211),
  ('Bicycle','EV','VanMoof','A5','2022','~',1212),
  ('Bicycle','EV','Cowboy','4','2022','~',1213),
  ('Bicycle','EV','Rad Power','RadRunner 3 Plus','2022','~',1214),
  ('Bicycle','EV','Rad Power','RadRover 6 Plus','2021','~',1215),
  ('Bicycle','EV','Riese & Müller','Charger4','2022','~',1216),
  ('Bicycle','EV','Tern','GSD S10','2018','~',1217),
  ('Bicycle','EV','Yamaha','Wabash RT','2022','~',1218),
  ('Pickup','EV','Tesla','Cybertruck','2023','~',1219),
  ('Pickup','EV','Tesla','Cybertruck Cyberbeast','2024','~',1220),
  ('Sedan','EV','Tesla','Model 3 Highland','2023','~',1221),
  ('Sedan','EV','Tesla','Model 3 Performance (Ludicrous)','2024','~',1222),
  ('SUV','EV','Tesla','Model Y Juniper','2025','~',1223),
  ('Sedan','EV','Tesla','Model S Plaid Refresh','2025','~',1224),
  ('SUV','EV','Tesla','Model X Plaid Refresh','2025','~',1225),
  ('Hatchback','EV','Tesla','Model 2 / Affordable EV','2026','~',1226),
  ('MPV','EV','Tesla','Robovan','2026','~',1227),
  ('Coupe','EV','Tesla','Cybercab','2026','~',1228),
  ('Coupe','EV','Tesla','Roadster (2nd Gen)','2026','~',1229),
  ('Sedan','EV','BYD','Seal','2022','~',1230),
  ('Sedan','PHEV','BYD','Seal DM-i','2024','~',1231),
  ('SUV','EV','BYD','Atto 3','2022','~',1232),
  ('SUV','EV','BYD','Atto 2','2024','~',1233),
  ('Hatchback','EV','BYD','Dolphin','2021','~',1234),
  ('Hatchback','EV','BYD','Seagull / Dolphin Mini','2023','~',1235),
  ('SUV','EV','BYD','Sealion 7','2024','~',1236),
  ('SUV','PHEV','BYD','Sealion 6 DM-i','2024','~',1237),
  ('Sedan','EV','BYD','Han EV (2025 Refresh)','2025','~',1238),
  ('SUV','EV','BYD','Tang EV (2025 Refresh)','2025','~',1239),
  ('Pickup','PHEV','BYD','Shark 6','2024','~',1240),
  ('SUV','PHEV','BYD','Yangwang U8','2023','~',1241),
  ('Coupe','EV','BYD','Yangwang U9','2024','~',1242),
  ('SUV','EV','BYD','Denza N9','2025','~',1243),
  ('MPV','EV','BYD','Denza D9 EV','2022','~',1244),
  ('Sedan','EV','Xpeng','P7+','2024','~',1245),
  ('SUV','EV','Xpeng','G6','2023','~',1246),
  ('SUV','EV','Xpeng','G9 (2025)','2025','~',1247),
  ('MPV','EV','Xpeng','X9','2024','~',1248),
  ('Hatchback','EV','Xpeng','Mona M03','2024','~',1249),
  ('Sedan','EV','Nio','ET9','2025','~',1250),
  ('Sedan','EV','Nio','ET5 (2025)','2025','~',1251),
  ('SUV','EV','Nio','EL8 / ES8 (2024)','2024','~',1252),
  ('Hatchback','EV','Nio','Onvo L60','2024','~',1253),
  ('SUV','EV','Nio','Onvo L90','2025','~',1254),
  ('Hatchback','EV','Nio','Firefly','2025','~',1255),
  ('SUV','PHEV','Li Auto','L6','2024','~',1256),
  ('SUV','PHEV','Li Auto','L7','2022','~',1257),
  ('SUV','PHEV','Li Auto','L9','2022','~',1258),
  ('MPV','EV','Li Auto','Mega','2024','~',1259),
  ('Sedan','EV','Zeekr','007','2024','~',1260),
  ('SUV','EV','Zeekr','7X','2024','~',1261),
  ('MPV','EV','Zeekr','009','2022','~',1262),
  ('Hatchback','EV','Zeekr','X','2023','~',1263),
  ('Hatchback','EV','Zeekr','001 FR','2024','~',1264),
  ('Sedan','EV','Xiaomi','SU7','2024','~',1265),
  ('Sedan','EV','Xiaomi','SU7 Ultra','2025','~',1266),
  ('SUV','EV','Xiaomi','YU7','2025','~',1267),
  ('SUV','Hybrid','Toyota','Land Cruiser 250 / Prado (2024)','2024','~',1268),
  ('SUV','Hybrid','Toyota','4Runner (6th Gen)','2024','~',1269),
  ('SUV','Hybrid','Toyota','Crown Signia','2024','~',1270),
  ('Sedan','Hybrid','Toyota','Camry (9th Gen)','2024','~',1271),
  ('Hatchback','Hybrid','Toyota','Prius (5th Gen)','2023','~',1272),
  ('SUV','EV','Toyota','bZ4X (2025)','2025','~',1273),
  ('SUV','EV','Toyota','bZ3X','2025','~',1274),
  ('SUV','EV','Toyota','Urban Cruiser EV','2025','~',1275),
  ('Pickup','Hybrid','Toyota','Tacoma (4th Gen)','2024','~',1276),
  ('Pickup','Hybrid','Toyota','Tundra i-Force MAX','2022','~',1277),
  ('SUV','Hybrid','Lexus','GX 550','2024','~',1278),
  ('SUV','Hybrid','Lexus','TX','2024','~',1279),
  ('SUV','EV','Lexus','RZ 450e (2025)','2025','~',1280),
  ('Sedan','Hybrid','Lexus','LS (2025)','2025','~',1281),
  ('Coupe','EV','Lexus','LF-ZC','2026','~',1282),
  ('SUV','EV','Honda','Prologue','2024','~',1283),
  ('SUV','EV','Honda','e:NY1','2023','~',1284),
  ('SUV','Hybrid','Honda','CR-V (6th Gen)','2023','~',1285),
  ('SUV','Hybrid','Honda','Passport (4th Gen)','2025','~',1286),
  ('Sedan','Hybrid','Honda','Civic (2025 Refresh)','2025','~',1287),
  ('Sedan','EV','Honda','0 Saloon','2026','~',1288),
  ('SUV','EV','Honda','0 SUV','2026','~',1289),
  ('SUV','EV','Acura','ZDX','2024','~',1290),
  ('SUV','Hybrid','Acura','MDX (2025)','2025','~',1291),
  ('SUV','EV','Hyundai','Ioniq 5 N','2024','~',1292),
  ('SUV','EV','Hyundai','Ioniq 5 (2025 Refresh)','2025','~',1293),
  ('SUV','EV','Hyundai','Ioniq 9','2025','~',1294),
  ('Sedan','EV','Hyundai','Ioniq 6 (2025)','2025','~',1295),
  ('SUV','Hybrid','Hyundai','Santa Fe (5th Gen)','2024','~',1296),
  ('SUV','Hybrid','Hyundai','Tucson (2025 Refresh)','2025','~',1297),
  ('Hatchback','EV','Hyundai','Inster','2024','~',1298),
  ('SUV','Hybrid','Kia','Sorento (2024)','2024','~',1299),
  ('SUV','EV','Kia','EV3','2024','~',1300),
  ('SUV','EV','Kia','EV5','2023','~',1301),
  ('SUV','EV','Kia','EV9','2023','~',1302),
  ('Sedan','EV','Kia','EV4','2025','~',1303),
  ('MPV','EV','Kia','PV5','2025','~',1304),
  ('SUV','EV','Kia','EV6 (2025 Refresh)','2025','~',1305),
  ('SUV','Hybrid','Kia','K4 / K3 Sedan','2024','~',1306),
  ('SUV','EV','Genesis','GV60 (2025)','2025','~',1307),
  ('SUV','EV','Genesis','GV70 Electrified (2025)','2025','~',1308),
  ('Sedan','EV','Genesis','G80 Electrified (2025)','2025','~',1309),
  ('Coupe','EV','Genesis','X Gran Coupe','2026','~',1310),
  ('SUV','EV','Volkswagen','ID.7 Tourer','2024','~',1311),
  ('Sedan','EV','Volkswagen','ID.7','2023','~',1312),
  ('Hatchback','EV','Volkswagen','ID.3 (2024 Refresh)','2024','~',1313),
  ('SUV','EV','Volkswagen','ID.4 (2025)','2025','~',1314),
  ('SUV','EV','Volkswagen','ID.Buzz LWB','2024','~',1315),
  ('Hatchback','EV','Volkswagen','ID.2all','2026','~',1316),
  ('SUV','PHEV','Volkswagen','Tiguan (3rd Gen)','2024','~',1317),
  ('SUV','PHEV','Volkswagen','Tayron','2024','~',1318),
  ('Sedan','EV','Audi','A6 e-tron','2024','~',1319),
  ('SUV','EV','Audi','Q6 e-tron','2024','~',1320),
  ('SUV','EV','Audi','Q4 e-tron (2025)','2025','~',1321),
  ('Sedan','EV','Audi','e-tron GT (2025 Refresh)','2025','~',1322),
  ('SUV','EV','Audi','Q8 e-tron (2024)','2024','~',1323),
  ('SUV','EV','Porsche','Macan EV','2024','~',1324),
  ('Sedan','EV','Porsche','Taycan (2024 Refresh)','2024','~',1325),
  ('SUV','EV','Porsche','Cayenne EV','2026','~',1326),
  ('Coupe','Hybrid','Porsche','911 GTS T-Hybrid','2024','~',1327),
  ('SUV','EV','Skoda','Elroq','2024','~',1328),
  ('SUV','EV','Skoda','Enyaq (2025 Refresh)','2025','~',1329),
  ('SUV','EV','Cupra','Tavascan','2024','~',1330),
  ('Hatchback','EV','Cupra','Born VZ','2024','~',1331),
  ('SUV','EV','BMW','iX2','2024','~',1332),
  ('Sedan','EV','BMW','i5','2023','~',1333),
  ('Wagon','EV','BMW','i5 Touring','2024','~',1334),
  ('SUV','EV','BMW','iX3 (Neue Klasse)','2025','~',1335),
  ('Sedan','EV','BMW','i3 (Neue Klasse Sedan)','2026','~',1336),
  ('SUV','PHEV','BMW','X3 (G45)','2024','~',1337),
  ('Sedan','PHEV','BMW','5 Series (G60)','2023','~',1338),
  ('Coupe','Petrol','BMW','M5 Touring (G99)','2024','~',1339),
  ('SUV','EV','Mini','Countryman E','2024','~',1340),
  ('Hatchback','EV','Mini','Cooper E (J01)','2024','~',1341),
  ('Hatchback','EV','Mini','Aceman','2024','~',1342),
  ('SUV','EV','Mercedes-Benz','EQG / G-Class Electric','2024','~',1343),
  ('Sedan','EV','Mercedes-Benz','CLA EV','2025','~',1344),
  ('SUV','EV','Mercedes-Benz','GLC EV','2026','~',1345),
  ('Sedan','PHEV','Mercedes-Benz','E-Class (W214)','2024','~',1346),
  ('Coupe','Petrol','Mercedes-Benz','AMG GT (C192)','2024','~',1347),
  ('SUV','EV','Mercedes-Benz','EQS SUV (2025 Refresh)','2025','~',1348),
  ('SUV','EV','Volvo','EX30','2024','~',1349),
  ('SUV','EV','Volvo','EX90','2024','~',1350),
  ('MPV','EV','Volvo','EM90','2024','~',1351),
  ('SUV','EV','Volvo','EX60','2026','~',1352),
  ('Sedan','EV','Polestar','2 (2024 Refresh)','2024','~',1353),
  ('SUV','EV','Polestar','3','2024','~',1354),
  ('SUV','EV','Polestar','4','2024','~',1355),
  ('Sedan','EV','Polestar','5','2025','~',1356),
  ('SUV','EV','Polestar','6 Roadster','2026','~',1357),
  ('SUV','EV','Jeep','Wagoneer S','2024','~',1358),
  ('SUV','EV','Jeep','Recon','2025','~',1359),
  ('SUV','EV','Jeep','Avenger','2023','~',1360),
  ('Pickup','EV','Ram','1500 REV','2025','~',1361),
  ('Pickup','PHEV','Ram','1500 Ramcharger','2025','~',1362),
  ('Coupe','EV','Dodge','Charger Daytona','2024','~',1363),
  ('Sedan','Petrol','Dodge','Charger Sixpack','2025','~',1364),
  ('Hatchback','EV','Fiat','600e','2024','~',1365),
  ('Hatchback','EV','Fiat','Grande Panda','2024','~',1366),
  ('SUV','EV','Alfa Romeo','Junior (Milano)','2024','~',1367),
  ('SUV','EV','Maserati','Grecale Folgore','2024','~',1368),
  ('Coupe','EV','Maserati','GranTurismo Folgore','2024','~',1369),
  ('SUV','EV','Citroen','e-C3','2024','~',1370),
  ('SUV','EV','Citroen','C3 Aircross EV','2024','~',1371),
  ('SUV','EV','Peugeot','e-3008','2024','~',1372),
  ('SUV','EV','Peugeot','e-5008','2024','~',1373),
  ('Hatchback','EV','Renault','5 E-Tech','2024','~',1374),
  ('Hatchback','EV','Renault','4 E-Tech','2025','~',1375),
  ('SUV','EV','Renault','Scenic E-Tech','2024','~',1376),
  ('SUV','Hybrid','Renault','Rafale','2024','~',1377),
  ('Hatchback','EV','Dacia','Spring (2024 Refresh)','2024','~',1378),
  ('SUV','Hybrid','Dacia','Bigster','2025','~',1379),
  ('SUV','Hybrid','Dacia','Duster (3rd Gen)','2024','~',1380),
  ('SUV','Hybrid','Nissan','Kicks (3rd Gen)','2024','~',1381),
  ('SUV','Hybrid','Nissan','Murano (4th Gen)','2025','~',1382),
  ('SUV','EV','Nissan','Ariya Nismo','2024','~',1383),
  ('Hatchback','EV','Nissan','Leaf (3rd Gen)','2025','~',1384),
  ('SUV','PHEV','Mitsubishi','Outlander PHEV (2024 Refresh)','2024','~',1385),
  ('Pickup','Diesel','Mitsubishi','Triton (6th Gen)','2024','~',1386),
  ('SUV','EV','Subaru','Trailseeker','2025','~',1387),
  ('SUV','Hybrid','Subaru','Forester (6th Gen)','2025','~',1388),
  ('SUV','Hybrid','Subaru','Crosstrek Hybrid','2026','~',1389),
  ('SUV','PHEV','Mazda','CX-70','2024','~',1390),
  ('SUV','PHEV','Mazda','CX-80','2024','~',1391),
  ('Coupe','Petrol','Mazda','Iconic SP','2026','~',1392),
  ('SUV','EV','Mazda','6e','2025','~',1393),
  ('SUV','EV','Suzuki','e Vitara','2025','~',1394),
  ('Hatchback','Hybrid','Suzuki','Swift (4th Gen)','2024','~',1395),
  ('Pickup','Hybrid','Ford','F-150 (2024 Refresh)','2024','~',1396),
  ('Pickup','EV','Ford','F-150 Lightning (2025)','2025','~',1397),
  ('SUV','PHEV','Ford','Explorer EV (Europe)','2024','~',1398),
  ('SUV','EV','Ford','Capri EV','2024','~',1399),
  ('SUV','Hybrid','Ford','Bronco Sport (2025)','2025','~',1400),
  ('SUV','EV','Cadillac','Lyriq (2025)','2025','~',1401),
  ('SUV','EV','Cadillac','Escalade IQ','2025','~',1402),
  ('SUV','EV','Cadillac','Optiq','2025','~',1403),
  ('SUV','EV','Cadillac','Vistiq','2026','~',1404),
  ('Sedan','EV','Cadillac','Celestiq','2024','~',1405),
  ('SUV','EV','Chevrolet','Equinox EV','2024','~',1406),
  ('SUV','EV','Chevrolet','Blazer EV (2025)','2025','~',1407),
  ('Pickup','EV','Chevrolet','Silverado EV','2024','~',1408),
  ('Pickup','EV','GMC','Sierra EV','2024','~',1409),
  ('SUV','EV','GMC','Hummer EV SUV','2024','~',1410),
  ('SUV','EV','Lincoln','Nautilus (2025)','2025','~',1411),
  ('SUV','EV','Rivian','R1S (Gen 2)','2025','~',1412),
  ('Pickup','EV','Rivian','R1T (Gen 2)','2025','~',1413),
  ('SUV','EV','Rivian','R2','2026','~',1414),
  ('SUV','EV','Rivian','R3','2026','~',1415),
  ('Sedan','EV','Lucid','Air (2025 Refresh)','2025','~',1416),
  ('SUV','EV','Lucid','Gravity','2025','~',1417),
  ('SUV','EV','Scout','Traveler','2026','~',1418),
  ('Pickup','EV','Scout','Terra','2026','~',1419),
  ('SUV','EV','MG','Cyberster','2024','~',1420),
  ('SUV','EV','MG','S5 EV','2025','~',1421),
  ('Hatchback','EV','MG','4 XPower','2024','~',1422),
  ('SUV','EV','MG','ZS EV (2025 Refresh)','2025','~',1423),
  ('SUV','EV','GWM','Ora 03 / Funky Cat','2022','~',1424),
  ('SUV','PHEV','GWM','Tank 300 Hi4-T','2024','~',1425),
  ('SUV','PHEV','GWM','Tank 500 Hi4-T','2024','~',1426),
  ('Pickup','Diesel','GWM','Cannon Alpha','2024','~',1427),
  ('SUV','EV','Chery','Omoda E5','2024','~',1428),
  ('SUV','PHEV','Chery','Jaecoo J7 PHEV','2024','~',1429),
  ('SUV','PHEV','Chery','Tiggo 8 Pro PHEV','2024','~',1430),
  ('SUV','EV','Geely','EX5','2024','~',1431),
  ('Sedan','EV','Geely','Galaxy E8','2024','~',1432),
  ('SUV','EV','Smart','#3','2023','~',1433),
  ('SUV','EV','Smart','#5','2025','~',1434),
  ('SUV','EV','Leapmotor','C10','2024','~',1435),
  ('Hatchback','EV','Leapmotor','T03','2024','~',1436),
  ('SUV','EV','Leapmotor','B10','2025','~',1437),
  ('SUV','EV','Tata','Curvv EV','2024','~',1438),
  ('SUV','EV','Tata','Harrier EV','2025','~',1439),
  ('SUV','EV','Tata','Punch EV','2024','~',1440),
  ('SUV','EV','Tata','Nexon EV (2024 Refresh)','2024','~',1441),
  ('Hatchback','EV','Tata','Tiago EV','2022','~',1442),
  ('SUV','EV','Mahindra','BE 6','2024','~',1443),
  ('SUV','EV','Mahindra','XEV 9e','2024','~',1444),
  ('SUV','Diesel','Mahindra','Thar Roxx','2024','~',1445),
  ('SUV','Petrol','Maruti Suzuki','Grand Vitara (2024 Refresh)','2024','~',1446),
  ('SUV','EV','Maruti Suzuki','e Vitara','2025','~',1447),
  ('Sedan','Petrol','Proton','S70 (2024)','2024','~',1448),
  ('SUV','EV','Proton','e.MAS 7','2024','~',1449),
  ('SUV','Petrol','Proton','X50 (2024 Refresh)','2024','~',1450),
  ('SUV','Petrol','Proton','X90','2023','~',1451),
  ('SUV','Petrol','Perodua','Ativa (2024)','2024','~',1452),
  ('Hatchback','Petrol','Perodua','Axia (2023 Refresh)','2023','~',1453),
  ('MPV','Petrol','Perodua','Alza (2022 Refresh)','2022','~',1454),
  ('Sedan','Petrol','Perodua','Bezza (2025 Refresh)','2025','~',1455),
  ('Bike','Petrol','Honda','CBR1000RR-R Fireblade SP (2024)','2024','~',1456),
  ('Bike','Petrol','Yamaha','R1 (2025 Refresh)','2025','~',1457),
  ('Bike','Petrol','Yamaha','MT-09 (2024)','2024','~',1458),
  ('Bike','Petrol','Kawasaki','Ninja ZX-4RR','2024','~',1459),
  ('Bike','Petrol','Kawasaki','Ninja H2R (2024)','2024','~',1460),
  ('Bike','Petrol','Suzuki','GSX-8R','2024','~',1461),
  ('Bike','Petrol','Ducati','Panigale V4 (2025)','2025','~',1462),
  ('Bike','Petrol','Ducati','Streetfighter V4 S (2025)','2025','~',1463),
  ('Bike','Petrol','BMW','M 1000 RR (2025)','2025','~',1464),
  ('Bike','Petrol','BMW','R 1300 GS','2024','~',1465),
  ('Bike','Petrol','KTM','1390 Super Duke R Evo','2024','~',1466),
  ('Bike','Petrol','Triumph','Speed 400','2024','~',1467),
  ('Bike','Petrol','Triumph','Daytona 660','2024','~',1468),
  ('Bike','Petrol','Royal Enfield','Himalayan 450','2024','~',1469),
  ('Bike','Petrol','Royal Enfield','Shotgun 650','2024','~',1470),
  ('Bike','EV','Harley-Davidson','LiveWire S2 Mulholland','2024','~',1471),
  ('Bike','EV','Zero','SR/F (2025)','2025','~',1472),
  ('Bike','EV','Damon','HyperSport HS','2025','~',1473),
  ('Scooter','EV','Honda','EM1 e:','2024','~',1474),
  ('Scooter','EV','Yamaha','E01','2024','~',1475),
  ('Scooter','EV','Vespa','Elettrica (2024)','2024','~',1476),
  ('Scooter','EV','Ola Electric','S1 Pro Gen 2','2024','~',1477),
  ('Scooter','EV','Ather','Rizta','2024','~',1478),
  ('Scooter','EV','TVS','iQube (2024 Refresh)','2024','~',1479),
  ('Scooter','EV','Bajaj','Chetak Premium 2025','2025','~',1480),
  ('Van','EV','Mercedes-Benz','eSprinter (2024)','2024','~',1481),
  ('Van','EV','Ford','E-Transit Custom','2024','~',1482),
  ('Van','EV','Volkswagen','ID.Buzz Cargo','2023','~',1483),
  ('Van','EV','Renault','Master E-Tech','2024','~',1484),
  ('Van','EV','Stellantis','K0 Platform Vans (2024)','2024','~',1485),
  ('Truck','EV','Volvo Trucks','FH Aero Electric','2024','~',1486),
  ('Truck','EV','Mercedes-Benz','eActros 600','2024','~',1487),
  ('Truck','Hydrogen','Hyundai','Xcient Fuel Cell (2025)','2025','~',1488),
  ('Truck','EV','Tesla','Semi (Production)','2024','~',1489),
  ('Truck','EV','Renault Trucks','E-Tech T','2024','~',1490),
  ('Bus','EV','BYD','B12 e-Coach','2024','~',1491),
  ('Bus','Hydrogen','Solaris','Urbino 18 Hydrogen','2024','~',1492),
  ('Bus','EV','Yutong','E12 Pro','2024','~',1493)
) as v(vehicle_type, energy_type, make, model, year_from, year_to, position)
where not exists (select 1 from public.vehicle_make_models);

-- ---- from migrations/0016_regions_tables.sql ----
-- ============================================================================
-- Migration 0016: dedicated regions tables (countries / states / cities / suburbs)
-- ----------------------------------------------------------------------------
-- Source of truth for admin-settings-country-states-cities.tsx. Previously
-- rows were stored in `settings_entries` under category 'country-states-cities'
-- with the level inferred from which of {country,state,city,suburb} were
-- populated. We now split storage by level so each row has typed columns and
-- can be queried directly.
--
-- The admin UI still treats the dataset as one logical collection; the
-- adminSync layer fans writes out to the right table by inspecting the row's
-- level fields, and fetches union all four tables back together.
--
-- Safe to re-run.
-- ============================================================================

-- Countries -----------------------------------------------------------------
create table if not exists public.countries (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (name)
);

create index if not exists countries_name_idx on public.countries(name);
create index if not exists countries_position_idx on public.countries(position);

drop trigger if exists trg_countries_updated_at on public.countries;
create trigger trg_countries_updated_at
  before update on public.countries
  for each row execute function public.set_updated_at();

alter table public.countries enable row level security;
drop policy if exists "countries read"   on public.countries;
drop policy if exists "countries insert" on public.countries;
drop policy if exists "countries update" on public.countries;
drop policy if exists "countries delete" on public.countries;
create policy "countries read"   on public.countries for select using (true);
create policy "countries insert" on public.countries for insert to public with check (true);
create policy "countries update" on public.countries for update to public using (true) with check (true);
create policy "countries delete" on public.countries for delete to public using (true);
grant select, insert, update, delete on public.countries to anon, authenticated;

alter table public.countries replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.countries;
exception when duplicate_object then null; when others then null; end $$;

-- States --------------------------------------------------------------------
create table if not exists public.states (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, name)
);

create index if not exists states_country_idx on public.states(country);
create index if not exists states_name_idx on public.states(name);
create index if not exists states_position_idx on public.states(position);

drop trigger if exists trg_states_updated_at on public.states;
create trigger trg_states_updated_at
  before update on public.states
  for each row execute function public.set_updated_at();

alter table public.states enable row level security;
drop policy if exists "states read"   on public.states;
drop policy if exists "states insert" on public.states;
drop policy if exists "states update" on public.states;
drop policy if exists "states delete" on public.states;
create policy "states read"   on public.states for select using (true);
create policy "states insert" on public.states for insert to public with check (true);
create policy "states update" on public.states for update to public using (true) with check (true);
create policy "states delete" on public.states for delete to public using (true);
grant select, insert, update, delete on public.states to anon, authenticated;

alter table public.states replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.states;
exception when duplicate_object then null; when others then null; end $$;

-- Cities --------------------------------------------------------------------
create table if not exists public.cities (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  state       text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, state, name)
);

create index if not exists cities_country_idx on public.cities(country);
create index if not exists cities_state_idx on public.cities(state);
create index if not exists cities_name_idx on public.cities(name);
create index if not exists cities_position_idx on public.cities(position);

drop trigger if exists trg_cities_updated_at on public.cities;
create trigger trg_cities_updated_at
  before update on public.cities
  for each row execute function public.set_updated_at();

alter table public.cities enable row level security;
drop policy if exists "cities read"   on public.cities;
drop policy if exists "cities insert" on public.cities;
drop policy if exists "cities update" on public.cities;
drop policy if exists "cities delete" on public.cities;
create policy "cities read"   on public.cities for select using (true);
create policy "cities insert" on public.cities for insert to public with check (true);
create policy "cities update" on public.cities for update to public using (true) with check (true);
create policy "cities delete" on public.cities for delete to public using (true);
grant select, insert, update, delete on public.cities to anon, authenticated;

alter table public.cities replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.cities;
exception when duplicate_object then null; when others then null; end $$;

-- Suburbs -------------------------------------------------------------------
create table if not exists public.suburbs (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  state       text not null,
  city        text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, state, city, name)
);

create index if not exists suburbs_country_idx on public.suburbs(country);
create index if not exists suburbs_state_idx on public.suburbs(state);
create index if not exists suburbs_city_idx on public.suburbs(city);
create index if not exists suburbs_name_idx on public.suburbs(name);
create index if not exists suburbs_position_idx on public.suburbs(position);

drop trigger if exists trg_suburbs_updated_at on public.suburbs;
create trigger trg_suburbs_updated_at
  before update on public.suburbs
  for each row execute function public.set_updated_at();

alter table public.suburbs enable row level security;
drop policy if exists "suburbs read"   on public.suburbs;
drop policy if exists "suburbs insert" on public.suburbs;
drop policy if exists "suburbs update" on public.suburbs;
drop policy if exists "suburbs delete" on public.suburbs;
create policy "suburbs read"   on public.suburbs for select using (true);
create policy "suburbs insert" on public.suburbs for insert to public with check (true);
create policy "suburbs update" on public.suburbs for update to public using (true) with check (true);
create policy "suburbs delete" on public.suburbs for delete to public using (true);
grant select, insert, update, delete on public.suburbs to anon, authenticated;

alter table public.suburbs replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.suburbs;
exception when duplicate_object then null; when others then null; end $$;

-- Best-effort backfill: copy any existing rows in `settings_entries` under
-- the 'country-states-cities' category into the right table, then remove
-- them from settings_entries so we don't read them twice.
do $$
declare r record;
declare c text; s text; ci text; sb text;
declare vals jsonb;
begin
  for r in
    select id, values, position from public.settings_entries
    where category = 'country-states-cities'
  loop
    vals := coalesce(r.values, '{}'::jsonb);
    c  := coalesce(nullif(trim(vals->>'country'), ''), '');
    s  := coalesce(nullif(trim(vals->>'state'),   ''), '');
    ci := coalesce(nullif(trim(vals->>'city'),    ''), '');
    sb := coalesce(nullif(trim(vals->>'suburb'),  ''), '');

    if c <> '' and s = '' and ci = '' and sb = '' then
      insert into public.countries (id, name, values, position)
      values (r.id, c, vals, coalesce(r.position, 0))
      on conflict (name) do update set values = excluded.values;
    elsif s <> '' and ci = '' and sb = '' then
      insert into public.states (id, country, name, values, position)
      values (r.id, c, s, vals, coalesce(r.position, 0))
      on conflict (country, name) do update set values = excluded.values;
    elsif ci <> '' and sb = '' then
      insert into public.cities (id, country, state, name, values, position)
      values (r.id, c, s, ci, vals, coalesce(r.position, 0))
      on conflict (country, state, name) do update set values = excluded.values;
    elsif sb <> '' then
      insert into public.suburbs (id, country, state, city, name, values, position)
      values (r.id, c, s, ci, sb, vals, coalesce(r.position, 0))
      on conflict (country, state, city, name) do update set values = excluded.values;
    end if;
  end loop;

  delete from public.settings_entries where category = 'country-states-cities';
end $$;

-- ---- from migrations/0018_regions_geofence.sql ----
-- ============================================================================
-- Migration 0018: add `geofence` column to regions tables
-- ----------------------------------------------------------------------------
-- The admin-settings-country-states-cities screen lets you draw / fetch a
-- polygon boundary for each region. Previously the polygon JSON, source, and
-- updated-at timestamp were stuffed into the row's generic `values` jsonb. We
-- now promote that to a dedicated `geofence` jsonb column on each level table
-- so it can be queried, indexed, and consumed by other clients without having
-- to know the legacy `boundary` key.
--
-- Shape of the new column:
--   {
--     "boundary":       "<stringified BoundaryShape>",
--     "source":         "osm" | "google" | "geonames" | "bbox" | "manual",
--     "updatedAt":      "<ISO timestamp>"
--   }
--
-- The migration also seeds the column from any existing rows that still carry
-- the boundary in `values`, then strips those legacy keys so they only live in
-- one place going forward.
--
-- Safe to re-run.
-- ============================================================================

-- 1. Add the column to all four region tables -------------------------------
alter table public.countries add column if not exists geofence jsonb;
alter table public.states    add column if not exists geofence jsonb;
alter table public.cities    add column if not exists geofence jsonb;
alter table public.suburbs   add column if not exists geofence jsonb;

create index if not exists countries_geofence_idx on public.countries using gin (geofence);
create index if not exists states_geofence_idx    on public.states    using gin (geofence);
create index if not exists cities_geofence_idx    on public.cities    using gin (geofence);
create index if not exists suburbs_geofence_idx   on public.suburbs   using gin (geofence);

-- 2. Backfill / seed from existing `values.boundary` ------------------------
do $$
declare tbl text;
begin
  foreach tbl in array array['countries','states','cities','suburbs'] loop
    execute format($f$
      update public.%1$I
      set geofence = jsonb_strip_nulls(jsonb_build_object(
            'boundary',  values->>'boundary',
            'source',    values->>'boundarySource',
            'updatedAt', values->>'boundaryUpdatedAt'
          ))
      where geofence is null
        and values ? 'boundary'
        and coalesce(nullif(trim(values->>'boundary'), ''), '') <> '';
    $f$, tbl);

    -- Strip the legacy keys from `values` now that they live in `geofence`.
    execute format($f$
      update public.%1$I
      set values = (values - 'boundary' - 'boundarySource' - 'boundaryUpdatedAt')
      where values ?| array['boundary','boundarySource','boundaryUpdatedAt'];
    $f$, tbl);
  end loop;
end $$;

-- ---- from migrations/0019_settings_dedicated_tables.sql ----
-- ============================================================================
-- 0019 — Dedicated tables for several admin-settings screens
-- ----------------------------------------------------------------------------
-- Splits the following categories out of `settings_entries` into their own
-- typed tables so they can be queried, indexed and seeded independently:
--   * airport-areas      -> public.airport_areas
--   * required-documents -> public.required_document
--   * document-type      -> public.document_type
--   * driver-incentive   -> public.driver_incentive
--
-- All four share the same shape (id / values / position / timestamps) so the
-- existing admin screens keep using SettingEntry without changes.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.airport_areas (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists airport_areas_position_idx on public.airport_areas(position);

create table if not exists public.required_document (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists required_document_position_idx on public.required_document(position);

create table if not exists public.document_type (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists document_type_position_idx on public.document_type(position);

create table if not exists public.driver_incentive (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists driver_incentive_position_idx on public.driver_incentive(position);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------
do $trg$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
    execute format(
      'drop trigger if exists trg_%1$s_updated_at on public.%1$s;
       create trigger trg_%1$s_updated_at before update on public.%1$s
       for each row execute function public.set_updated_at();', t);
  end loop;
end;
$trg$;

-- ---------------------------------------------------------------------------
-- Row-Level Security: open read/write for now (matches regions tables)
-- ---------------------------------------------------------------------------
alter table public.airport_areas    enable row level security;
alter table public.required_document enable row level security;
alter table public.document_type    enable row level security;
alter table public.driver_incentive enable row level security;

do $pol$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$pol$;

-- ---------------------------------------------------------------------------
-- Backfill from settings_entries, then delete the migrated rows
-- ---------------------------------------------------------------------------
do $bf$
declare
  pair record;
  cat  text;
  tbl  text;
begin
  for pair in
    select * from (values
      ('airport-areas',      'airport_areas'),
      ('required-documents', 'required_document'),
      ('document-type',      'document_type'),
      ('driver-incentive',   'driver_incentive')
    ) as v(cat, tbl)
  loop
    cat := pair.cat;
    tbl := pair.tbl;
    execute format(
      'insert into public.%1$s (id, values, position, created_at, updated_at)
         select id, coalesce(values, ''{}''::jsonb), coalesce(position, 0), created_at, updated_at
           from public.settings_entries
          where category = %2$L
       on conflict (id) do nothing;',
      tbl, cat
    );
    execute format(
      'delete from public.settings_entries where category = %1$L;',
      cat
    );
  end loop;
end;
$bf$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $rt$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table public.%1$s;', t);
    exception when duplicate_object then null;
             when others then null;
    end;
  end loop;
end;
$rt$;

-- ---- from migrations/0020_settings_more_dedicated_tables.sql ----
-- ============================================================================
-- 0020 — More dedicated tables for admin-settings screens
-- ----------------------------------------------------------------------------
-- Splits these categories out of `settings_entries` into their own typed
-- tables so they can be queried, indexed and seeded independently:
--
--   multi-gate-places       \
--   multi-gate-place-gates  /->  public.multi_gate (kind = 'place' | 'gate')
--   insurance-providers          ->  public.insurance_providers
--   insurance-types              ->  public.insurance_types
--   insurance-durations          ->  public.insurance_durations
--   insurance-premium            ->  public.insurance_premium
--   ev-delivery-advisors         ->  public.ev_delivery_advisors
--   ev-finance-options           ->  public.ev_finance_options
--   ev-order-fee                 ->  public.ev_order_fee
--   ev-vehicle-details           ->  public.ev_vehicle_details
--   ev-vehicle-inventory         ->  public.ev_vehicle_inventory
--
-- Every table mirrors the settings_entries shape (id / values / position /
-- active / timestamps) so the existing admin screens keep using SettingEntry
-- without changes.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- multi_gate (shared by multi-gate-places and multi-gate-place-gates)
-- ---------------------------------------------------------------------------
create table if not exists public.multi_gate (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('place','gate')),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists multi_gate_kind_idx     on public.multi_gate(kind);
create index if not exists multi_gate_position_idx on public.multi_gate(position);

-- ---------------------------------------------------------------------------
-- Simple per-category tables
-- ---------------------------------------------------------------------------
do $mk$
declare t text;
begin
  foreach t in array array[
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format($f$
      create table if not exists public.%1$s (
        id          uuid primary key default gen_random_uuid(),
        values      jsonb not null default '{}'::jsonb,
        position    integer not null default 0,
        active      boolean not null default true,
        created_at  timestamptz not null default now(),
        updated_at  timestamptz not null default now()
      );
      create index if not exists %1$s_position_idx on public.%1$s(position);
    $f$, t);
  end loop;
end;
$mk$;

-- ---------------------------------------------------------------------------
-- updated_at triggers (relies on public.set_updated_at from schema.sql)
-- ---------------------------------------------------------------------------
do $trg$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format(
      'drop trigger if exists trg_%1$s_updated_at on public.%1$s;
       create trigger trg_%1$s_updated_at before update on public.%1$s
       for each row execute function public.set_updated_at();', t);
  end loop;
end;
$trg$;

-- ---------------------------------------------------------------------------
-- Row-Level Security: open read/write (matches the other dedicated tables)
-- ---------------------------------------------------------------------------
do $pol$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format('alter table public.%1$s enable row level security;', t);
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$pol$;

-- ---------------------------------------------------------------------------
-- Backfill from settings_entries, then delete migrated rows
-- ---------------------------------------------------------------------------
do $bf$
declare
  pair record;
  cat  text;
  tbl  text;
begin
  for pair in
    select * from (values
      ('insurance-providers',   'insurance_providers'),
      ('insurance-types',       'insurance_types'),
      ('insurance-durations',   'insurance_durations'),
      ('insurance-premium',     'insurance_premium'),
      ('ev-delivery-advisors',  'ev_delivery_advisors'),
      ('ev-finance-options',    'ev_finance_options'),
      ('ev-order-fee',          'ev_order_fee'),
      ('ev-vehicle-details',    'ev_vehicle_details'),
      ('ev-vehicle-inventory',  'ev_vehicle_inventory')
    ) as v(cat, tbl)
  loop
    cat := pair.cat;
    tbl := pair.tbl;
    execute format(
      'insert into public.%1$s (id, values, position, created_at, updated_at)
         select id, coalesce(values, ''{}''::jsonb), coalesce(position, 0), created_at, updated_at
           from public.settings_entries
          where category = %2$L
       on conflict (id) do nothing;',
      tbl, cat
    );
    execute format(
      'delete from public.settings_entries where category = %1$L;',
      cat
    );
  end loop;

  -- multi_gate: backfill from the two storage keys, tagging kind appropriately.
  insert into public.multi_gate (id, kind, values, position, created_at, updated_at)
    select id, 'place', coalesce(values, '{}'::jsonb), coalesce(position, 0), created_at, updated_at
      from public.settings_entries
     where category = 'multi-gate-places'
  on conflict (id) do nothing;
  delete from public.settings_entries where category = 'multi-gate-places';

  insert into public.multi_gate (id, kind, values, position, created_at, updated_at)
    select id, 'gate', coalesce(values, '{}'::jsonb), coalesce(position, 0), created_at, updated_at
      from public.settings_entries
     where category = 'multi-gate-place-gates'
  on conflict (id) do nothing;
  delete from public.settings_entries where category = 'multi-gate-place-gates';
end;
$bf$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $rt$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table public.%1$s;', t);
    exception when duplicate_object then null;
             when others then null;
    end;
  end loop;
end;
$rt$;

-- ---- from migrations/0021_user_session_tracking.sql ----
-- ============================================================================
-- 0021_user_session_tracking.sql
-- Adds two telemetry tables used by the Expo client:
--   1. public.user_location_history  — lat/lng ping every ~30 seconds while a
--      user is signed in. Append-only history, never updated.
--   2. public.user_sessions          — one row per app launch / relaunch /
--      login capturing device + network + app metadata.
--
-- Both tables follow the project's permissive RLS pattern (writes open to the
-- `public` role, same as partners / vehicles / settings_entries) so that the
-- anon client used inside the app can insert without a server roundtrip.
-- The `user_id` column references `auth.users(id)` but is nullable so logging
-- still works for legacy / test sessions that don't have a Supabase auth uid.
--
-- Safe to re-run.
-- ============================================================================

-- ---- user_location_history -----------------------------------------------
create table if not exists public.user_location_history (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete cascade,
  phone           text,
  session_id      uuid,
  latitude        double precision not null,
  longitude       double precision not null,
  accuracy        double precision,
  altitude        double precision,
  heading         double precision,
  speed           double precision,
  captured_at     timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

create index if not exists user_location_history_user_idx
  on public.user_location_history(user_id, captured_at desc);
create index if not exists user_location_history_session_idx
  on public.user_location_history(session_id);
create index if not exists user_location_history_captured_idx
  on public.user_location_history(captured_at desc);

alter table public.user_location_history enable row level security;

drop policy if exists "loc_history read"   on public.user_location_history;
drop policy if exists "loc_history insert" on public.user_location_history;
drop policy if exists "loc_history update" on public.user_location_history;
drop policy if exists "loc_history delete" on public.user_location_history;

create policy "loc_history read"
  on public.user_location_history for select
  using (true);

create policy "loc_history insert"
  on public.user_location_history for insert
  to public
  with check (true);

create policy "loc_history update"
  on public.user_location_history for update
  to public
  using (true)
  with check (true);

create policy "loc_history delete"
  on public.user_location_history for delete
  to public
  using (true);

grant select, insert, update, delete
  on public.user_location_history
  to anon, authenticated;

-- ---- user_sessions --------------------------------------------------------
-- Captures one row per login / app launch / app relaunch.
create table if not exists public.user_sessions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid references auth.users(id) on delete cascade,
  phone              text,
  -- 'login' | 'app_launch' | 'app_relaunch' (free text so the client can add new buckets later)
  event_type         text not null default 'app_launch',
  -- Operating system info
  os_name            text,        -- "iOS" | "Android" | "web"
  os_version         text,        -- "17.4", "14", etc.
  -- Device info
  device_brand       text,        -- "Apple", "Samsung", "Google"
  device_manufacturer text,
  device_model_name  text,        -- "iPhone 15 Pro", "Pixel 8"
  device_model_id    text,        -- "iPhone16,1"
  device_year_class  integer,
  device_type        text,        -- "PHONE" | "TABLET" | "DESKTOP" | "TV" | "UNKNOWN"
  is_physical_device boolean,
  -- Network info
  network_type       text,        -- "WIFI" | "CELLULAR" | "NONE" | "UNKNOWN"
  network_is_connected boolean,
  network_is_internet_reachable boolean,
  network_operator   text,        -- carrier name (best-effort)
  ip_address         text,
  -- App info
  app_version        text,
  app_build_version  text,
  app_id             text,
  -- Free-form extras
  raw                jsonb,
  captured_at        timestamptz not null default now(),
  created_at         timestamptz not null default now()
);

create index if not exists user_sessions_user_idx
  on public.user_sessions(user_id, captured_at desc);
create index if not exists user_sessions_event_idx
  on public.user_sessions(event_type);
create index if not exists user_sessions_captured_idx
  on public.user_sessions(captured_at desc);

alter table public.user_sessions enable row level security;

drop policy if exists "sessions read"   on public.user_sessions;
drop policy if exists "sessions insert" on public.user_sessions;
drop policy if exists "sessions update" on public.user_sessions;
drop policy if exists "sessions delete" on public.user_sessions;

create policy "sessions read"
  on public.user_sessions for select
  using (true);

create policy "sessions insert"
  on public.user_sessions for insert
  to public
  with check (true);

create policy "sessions update"
  on public.user_sessions for update
  to public
  using (true)
  with check (true);

create policy "sessions delete"
  on public.user_sessions for delete
  to public
  using (true);

grant select, insert, update, delete
  on public.user_sessions
  to anon, authenticated;

-- ---- Realtime -------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.user_location_history;
exception when duplicate_object then null;
end$$;

do $$
begin
  alter publication supabase_realtime add table public.user_sessions;
exception when duplicate_object then null;
end$$;

-- ---- from migrations/0022_app_branding.sql ----
-- ============================================================================
-- 0022_app_branding.sql
-- Global app branding: splash screen image/background + app icon.
--
-- Storage:
--   public bucket `app-branding` (public read, anon write) holds the uploaded
--   splash image and app icon files.
--
-- Table:
--   public.app_branding (singleton, id = 'global') stores the current image
--   URLs and metadata so every user device can fetch and apply the latest
--   branding globally.
--
-- Safe to re-run.
-- ============================================================================

-- ---- Storage bucket -------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('app-branding', 'app-branding', true)
on conflict (id) do update set public = excluded.public;

-- Permissive storage policies so the anon client used inside the app can
-- upload and replace branding assets, mirroring the project's other buckets.
drop policy if exists "app-branding read"   on storage.objects;
drop policy if exists "app-branding insert" on storage.objects;
drop policy if exists "app-branding update" on storage.objects;
drop policy if exists "app-branding delete" on storage.objects;

create policy "app-branding read"
  on storage.objects for select
  using (bucket_id = 'app-branding');

create policy "app-branding insert"
  on storage.objects for insert
  to public
  with check (bucket_id = 'app-branding');

create policy "app-branding update"
  on storage.objects for update
  to public
  using (bucket_id = 'app-branding')
  with check (bucket_id = 'app-branding');

create policy "app-branding delete"
  on storage.objects for delete
  to public
  using (bucket_id = 'app-branding');

-- ---- app_branding table ---------------------------------------------------
create table if not exists public.app_branding (
  id                text primary key default 'global',
  splash_image_url  text,
  splash_bg_color   text not null default '#ff007f',
  app_icon_url      text,
  icon_changed_at   timestamptz,
  updated_at        timestamptz not null default now()
);

insert into public.app_branding (id, splash_bg_color)
values ('global', '#ff007f')
on conflict (id) do nothing;

alter table public.app_branding enable row level security;

drop policy if exists "app_branding read"   on public.app_branding;
drop policy if exists "app_branding insert" on public.app_branding;
drop policy if exists "app_branding update" on public.app_branding;
drop policy if exists "app_branding delete" on public.app_branding;

create policy "app_branding read"
  on public.app_branding for select
  using (true);

create policy "app_branding insert"
  on public.app_branding for insert
  to public
  with check (true);

create policy "app_branding update"
  on public.app_branding for update
  to public
  using (true)
  with check (true);

create policy "app_branding delete"
  on public.app_branding for delete
  to public
  using (true);

grant select, insert, update, delete
  on public.app_branding
  to anon, authenticated;

-- ---- Realtime -------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.app_branding;
exception when duplicate_object then null;
end$$;

-- ---- from migrations/0023_admin_display_settings.sql ----
-- ============================================================================
-- 0023_admin_display_settings.sql
-- Global admin Display Settings.
--
-- Singleton table public.admin_display_settings (id = 'global') stores the
-- full display-settings JSON. Every device pulls it on app start and applies
-- it locally so admin changes take effect for all users on next launch.
--
-- Safe to re-run.
-- ============================================================================

create table if not exists public.admin_display_settings (
  id          text primary key default 'global',
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

insert into public.admin_display_settings (id, settings)
values ('global', '{}'::jsonb)
on conflict (id) do nothing;

alter table public.admin_display_settings enable row level security;

drop policy if exists "admin_display_settings read"   on public.admin_display_settings;
drop policy if exists "admin_display_settings insert" on public.admin_display_settings;
drop policy if exists "admin_display_settings update" on public.admin_display_settings;
drop policy if exists "admin_display_settings delete" on public.admin_display_settings;

create policy "admin_display_settings read"
  on public.admin_display_settings for select
  using (true);

create policy "admin_display_settings insert"
  on public.admin_display_settings for insert
  to public
  with check (true);

create policy "admin_display_settings update"
  on public.admin_display_settings for update
  to public
  using (true)
  with check (true);

create policy "admin_display_settings delete"
  on public.admin_display_settings for delete
  to public
  using (true);

grant select, insert, update, delete
  on public.admin_display_settings
  to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.admin_display_settings;
exception when duplicate_object then null;
end$$;

-- ---- from migrations/0024_admin_display_settings_global_sync.sql ----
-- ============================================================================
-- 0024_admin_display_settings_global_sync.sql
-- Force-assert the global Display Settings sync so admin changes (including
-- "Coming Soon" toggles) reach EVERY device, not just the admin's own.
--
-- This re-runs the table/RLS/grants from 0023 (safe, idempotent) and ADDS the
-- two things needed for reliable cross-device delivery:
--   1. The table is in the `supabase_realtime` publication (live push).
--   2. REPLICA IDENTITY FULL so realtime UPDATE payloads always carry the
--      full `settings` JSON to every subscribed client.
--
-- Safe to re-run.
-- ============================================================================

create table if not exists public.admin_display_settings (
  id          text primary key default 'global',
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- Ensure the singleton row exists.
insert into public.admin_display_settings (id, settings)
values ('global', '{}'::jsonb)
on conflict (id) do nothing;

-- Row level security: everyone can read the global config, everyone can write
-- it (admin gating happens in the app UI). This is what makes the settings
-- truly global instead of per-device.
alter table public.admin_display_settings enable row level security;

drop policy if exists "admin_display_settings read"   on public.admin_display_settings;
drop policy if exists "admin_display_settings insert" on public.admin_display_settings;
drop policy if exists "admin_display_settings update" on public.admin_display_settings;
drop policy if exists "admin_display_settings delete" on public.admin_display_settings;

create policy "admin_display_settings read"
  on public.admin_display_settings for select
  to anon, authenticated
  using (true);

create policy "admin_display_settings insert"
  on public.admin_display_settings for insert
  to anon, authenticated
  with check (true);

create policy "admin_display_settings update"
  on public.admin_display_settings for update
  to anon, authenticated
  using (true)
  with check (true);

create policy "admin_display_settings delete"
  on public.admin_display_settings for delete
  to anon, authenticated
  using (true);

grant select, insert, update, delete
  on public.admin_display_settings
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime delivery to every device.
-- ---------------------------------------------------------------------------

-- Make sure realtime UPDATE events include the full new row (so subscribers
-- receive the complete `settings` JSON, not just changed keys).
alter table public.admin_display_settings replica identity full;

-- Add the table to the realtime publication if it isn't already. Wrapped so
-- re-running never errors when the table is already a member.
do $$
begin
  alter publication supabase_realtime add table public.admin_display_settings;
exception
  when duplicate_object then null;
  when undefined_object then
    -- Publication doesn't exist yet (fresh project) — create it with the table.
    create publication supabase_realtime for table public.admin_display_settings;
end$$;

-- ---- from migrations/0025_partners_self_rls.sql ----
-- Allow authenticated users to create and update their own partner row so the
-- user-facing Partner onboarding flow can write to the table.

alter table public.partners enable row level security;

drop policy if exists "partners self insert" on public.partners;
create policy "partners self insert"
  on public.partners for insert
  to authenticated
  with check (auth_user_id = auth.uid());

drop policy if exists "partners self update" on public.partners;
create policy "partners self update"
  on public.partners for update
  to authenticated
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- Also allow self-read so the onboarding screen can fetch the row it just made
-- (the existing "partners read" policy already covers authenticated reads, but
-- keeping this here is harmless and self-documenting).
drop policy if exists "partners self select" on public.partners;
create policy "partners self select"
  on public.partners for select
  to authenticated
  using (auth_user_id = auth.uid() or auth.role() = 'authenticated');

notify pgrst, 'reload schema';

-- ---- from migrations/0034_partner_type_icons.sql ----
-- ============================================================================
-- 0034_partner_type_icons.sql
-- Public storage bucket for partner-type icons uploaded from the admin panel.
-- Safe to re-run.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('partner-type-icons', 'partner-type-icons', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "partner-type-icons read"   on storage.objects;
drop policy if exists "partner-type-icons insert" on storage.objects;
drop policy if exists "partner-type-icons update" on storage.objects;
drop policy if exists "partner-type-icons delete" on storage.objects;

create policy "partner-type-icons read"
  on storage.objects for select
  using (bucket_id = 'partner-type-icons');

create policy "partner-type-icons insert"
  on storage.objects for insert
  to public
  with check (bucket_id = 'partner-type-icons');

create policy "partner-type-icons update"
  on storage.objects for update
  to public
  using (bucket_id = 'partner-type-icons')
  with check (bucket_id = 'partner-type-icons');

create policy "partner-type-icons delete"
  on storage.objects for delete
  to public
  using (bucket_id = 'partner-type-icons');

-- ---- from migrations/0036_support.sql ----
-- ============================================================================
-- Support: tickets, messages (live chat), calls + media bucket
-- ----------------------------------------------------------------------------
-- Adds a customer-support system tied to public.profiles:
--   * support_tickets  — one conversation per profile (a ticket / chat thread)
--   * support_messages — chat messages with attachments + read receipts
--   * support_calls    — admin → user call signaling (user only receives)
--   * storage bucket `support-media` for images / video / voice notes
-- Realtime is enabled so both sides see live updates (messages, ticks, calls).
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tickets
-- ---------------------------------------------------------------------------
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null default 'Support',
  status text not null default 'open' check (status in ('open','pending','closed')),
  last_message text,
  last_message_at timestamptz,
  last_sender_role text check (last_sender_role in ('user','admin')),
  unread_admin integer not null default 0,
  unread_user integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists support_tickets_profile_idx on public.support_tickets(profile_id);
create index if not exists support_tickets_status_idx on public.support_tickets(status);
create index if not exists support_tickets_last_msg_idx on public.support_tickets(last_message_at desc);

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_role text not null check (sender_role in ('user','admin')),
  sender_id uuid,
  type text not null default 'text'
    check (type in ('text','image','video','audio','location')),
  body text,
  media_url text,
  media_duration numeric,
  latitude double precision,
  longitude double precision,
  -- 'sent' (1 grey tick) → 'delivered' (2 grey ticks) → 'read' (2 blue ticks)
  status text not null default 'sent' check (status in ('sent','delivered','read')),
  created_at timestamptz not null default now()
);

create index if not exists support_messages_ticket_idx on public.support_messages(ticket_id, created_at);
create index if not exists support_messages_status_idx on public.support_messages(status);

-- ---------------------------------------------------------------------------
-- Calls (admin initiates, user receives)
-- ---------------------------------------------------------------------------
create table if not exists public.support_calls (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid references public.support_tickets(id) on delete set null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  caller_role text not null default 'admin' check (caller_role in ('admin')),
  caller_name text,
  media text not null default 'voice' check (media in ('voice','video')),
  -- ringing → accepted → ended | declined | missed
  status text not null default 'ringing'
    check (status in ('ringing','accepted','declined','ended','missed')),
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists support_calls_profile_idx on public.support_calls(profile_id, created_at desc);
create index if not exists support_calls_status_idx on public.support_calls(status);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
do $$
begin
  drop trigger if exists trg_support_tickets_updated_at on public.support_tickets;
  create trigger trg_support_tickets_updated_at before update on public.support_tickets
    for each row execute function public.set_updated_at();
end$$;

-- ---------------------------------------------------------------------------
-- RLS — permissive (matches the rest of this project: admin uses a non-RLS
-- super session, users access their own tickets through the same client).
-- ---------------------------------------------------------------------------
alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
alter table public.support_calls enable row level security;

do $support_pol$
declare t text;
begin
  foreach t in array array['support_tickets','support_messages','support_calls'] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$support_pol$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.support_tickets;
exception when duplicate_object then null; end$$;
alter table public.support_tickets replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.support_messages;
exception when duplicate_object then null; end$$;
alter table public.support_messages replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.support_calls;
exception when duplicate_object then null; end$$;
alter table public.support_calls replica identity full;

-- ---------------------------------------------------------------------------
-- Storage bucket for support attachments (public read so media renders fast)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('support-media', 'support-media', true)
on conflict (id) do nothing;

drop policy if exists "public read support-media" on storage.objects;
drop policy if exists "auth upload support-media" on storage.objects;
drop policy if exists "anon upload support-media" on storage.objects;
drop policy if exists "auth update support-media" on storage.objects;
drop policy if exists "auth delete support-media" on storage.objects;

create policy "public read support-media"
  on storage.objects for select
  using (bucket_id = 'support-media');

create policy "anon upload support-media"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'support-media');

create policy "auth update support-media"
  on storage.objects for update to anon, authenticated
  using (bucket_id = 'support-media');

create policy "auth delete support-media"
  on storage.objects for delete to anon, authenticated
  using (bucket_id = 'support-media');

-- ---- from migrations/0038_support_ticket_number.sql ----
-- ============================================================================
-- Support: serialised human-readable ticket numbers
-- ----------------------------------------------------------------------------
-- Builds on 0036_support.sql / 0037_support_assignment.sql:
--   * adds support_tickets.ticket_number — a stable, incrementing integer
--     assigned to every ticket via a dedicated sequence
--   * backfills existing tickets in creation order
--   * a BEFORE INSERT trigger stamps new tickets automatically
-- The displayed reference is formatted in the app as e.g. "TKT-001042".
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Sequence + column
-- ---------------------------------------------------------------------------
create sequence if not exists public.support_ticket_number_seq;

alter table public.support_tickets
  add column if not exists ticket_number integer;

-- ---------------------------------------------------------------------------
-- Backfill existing tickets in creation order (only those missing a number)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select id from public.support_tickets
    where ticket_number is null
    order by created_at asc, id asc
  loop
    update public.support_tickets
      set ticket_number = nextval('public.support_ticket_number_seq')
      where id = r.id;
  end loop;
end$$;

-- ---------------------------------------------------------------------------
-- Auto-assign on insert
-- ---------------------------------------------------------------------------
create or replace function public.set_support_ticket_number()
returns trigger
language plpgsql
as $$
begin
  if new.ticket_number is null then
    new.ticket_number := nextval('public.support_ticket_number_seq');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_support_ticket_number on public.support_tickets;
create trigger trg_support_ticket_number
  before insert on public.support_tickets
  for each row execute function public.set_support_ticket_number();

-- Keep the sequence ahead of any backfilled values.
select setval(
  'public.support_ticket_number_seq',
  coalesce((select max(ticket_number) from public.support_tickets), 0) + 1,
  false
);

create unique index if not exists support_tickets_ticket_number_idx
  on public.support_tickets(ticket_number);

-- ---- from migrations/0039_emergency_contacts.sql ----
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

-- ---- from migrations/0040_voice_protection.sql ----
-- ============================================================================
-- VoiceProtection (per ride trip audio safeguard)
-- ----------------------------------------------------------------------------
-- When a rider/partner enables VoiceProtection, the app records trip audio with
-- the device microphone while a ride is in progress. The audio is stored on the
-- DEVICE (local file system) and is NOT accessible to the user. Each recording
-- is retained locally for 24 hours then purged.
--
-- This table tracks the metadata for every local recording so that an admin can
-- REQUEST an upload (e.g. when a user opens a support ticket about a ride). When
-- an upload is requested the user's device uploads the still-retained local file
-- to the private `voice-protection` bucket and fills in `media_url`.
--
--   * voice_protection_recordings — metadata + upload request/fulfilment state
--   * storage bucket `voice-protection` (PRIVATE) holds uploaded audio
--
-- RLS is permissive to match the rest of this project (admin uses a non-RLS
-- super session, users access their own rows through the same client).
-- Realtime is enabled so the device reacts to admin upload requests instantly.
-- Safe to re-run.
-- ============================================================================

create table if not exists public.voice_protection_recordings (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  -- Human reference to the trip (booking number) + optional route summary.
  ride_id text,
  ride_label text,
  recorded_at timestamptz not null default now(),
  duration_sec integer not null default 0,
  -- When the local copy is purged from the device (recorded_at + 24h).
  expires_at timestamptz not null default (now() + interval '24 hours'),
  -- Upload request lifecycle (driven by an admin, fulfilled by the device).
  upload_requested boolean not null default false,
  upload_requested_by uuid,
  upload_requested_at timestamptz,
  ticket_id uuid,
  -- Set by the device once the local file has been uploaded.
  uploaded boolean not null default false,
  uploaded_at timestamptz,
  media_url text,
  -- Set by the device when the local file is no longer available (purged /
  -- never captured) so admins know the upload can't be fulfilled.
  unavailable boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists voice_protection_profile_idx
  on public.voice_protection_recordings(profile_id, recorded_at desc);
create index if not exists voice_protection_pending_upload_idx
  on public.voice_protection_recordings(profile_id, upload_requested, uploaded);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
do $$
begin
  drop trigger if exists trg_voice_protection_updated_at on public.voice_protection_recordings;
  create trigger trg_voice_protection_updated_at before update on public.voice_protection_recordings
    for each row execute function public.set_updated_at();
end$$;

-- ---------------------------------------------------------------------------
-- RLS — permissive
-- ---------------------------------------------------------------------------
alter table public.voice_protection_recordings enable row level security;

drop policy if exists "voice_protection read"   on public.voice_protection_recordings;
drop policy if exists "voice_protection insert" on public.voice_protection_recordings;
drop policy if exists "voice_protection update" on public.voice_protection_recordings;
drop policy if exists "voice_protection delete" on public.voice_protection_recordings;

create policy "voice_protection read"   on public.voice_protection_recordings for select using (true);
create policy "voice_protection insert" on public.voice_protection_recordings for insert to public with check (true);
create policy "voice_protection update" on public.voice_protection_recordings for update to public using (true) with check (true);
create policy "voice_protection delete" on public.voice_protection_recordings for delete to public using (true);

grant select, insert, update, delete on public.voice_protection_recordings to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.voice_protection_recordings;
exception when duplicate_object then null; end$$;
alter table public.voice_protection_recordings replica identity full;

-- ---------------------------------------------------------------------------
-- Storage bucket (PRIVATE — trip audio must not be publicly readable)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('voice-protection', 'voice-protection', false)
on conflict (id) do nothing;

drop policy if exists "anon read voice-protection"   on storage.objects;
drop policy if exists "anon upload voice-protection" on storage.objects;
drop policy if exists "anon update voice-protection" on storage.objects;
drop policy if exists "anon delete voice-protection" on storage.objects;

-- The app uses the anon/authenticated client for both rider uploads and admin
-- review (admin runs a non-RLS super session), so allow both roles.
create policy "anon read voice-protection"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'voice-protection');

create policy "anon upload voice-protection"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'voice-protection');

create policy "anon update voice-protection"
  on storage.objects for update to anon, authenticated
  using (bucket_id = 'voice-protection');

create policy "anon delete voice-protection"
  on storage.objects for delete to anon, authenticated
  using (bucket_id = 'voice-protection');

-- ---- from migrations/0041_profiles_admin_read.sql ----
-- ============================================================================
-- 0041_profiles_admin_read.sql
-- ----------------------------------------------------------------------------
-- The admin "All Users" screen (admin-users-all.tsx) reads every row from
-- public.profiles regardless of status (column `profile_status` / `status`,
-- i.e. the user_status, with '*' = all statuses).
--
-- However the only SELECT policy on public.profiles is "profiles self read":
--
--     using (auth.uid() = id)
--
-- ...which restricts each session to reading ONLY its own row. As a result the
-- admin list comes back empty/partial no matter the approval status.
--
-- This migration adds an additional SELECT policy that lets any admin (any
-- profile with a row in public.admin_access, via the is_admin() helper from
-- 0009_admin_access.sql) read ALL profiles. RLS policies are OR-combined, so
-- the existing self-read policy continues to work for normal users.
-- ============================================================================

drop policy if exists "profiles admin read all" on public.profiles;
create policy "profiles admin read all"
  on public.profiles for select
  using (public.is_admin(auth.uid()));

-- ---- from migrations/0042_app_settings_elife_admin_only.sql ----
-- ============================================================================
-- 0042_app_settings_elife_admin_only.sql
-- ----------------------------------------------------------------------------
-- The Elife Transfer integration stores its connection config — including the
-- OAuth `clientSecret` — in public.app_settings under:
--
--     key = 'elife_api_connection'
--
-- (see expo/utils/elifeApiStore.ts -> ELIFE_REMOTE_KEY).
--
-- Today app_settings is wide open: migration 0008 created PERMISSIVE policies
-- on the `public` role that allow ANY anon/authenticated session to SELECT,
-- INSERT, UPDATE and DELETE every row. That means anyone with the anon key can
-- read or overwrite the Elife client secret. We need to lock that one key down
-- to admins only, WITHOUT breaking open access to all the other settings rows
-- (api_providers, supabase settings, etc.) that the app relies on.
--
-- HOW THIS WORKS
-- --------------
-- Postgres combines RLS policies as follows:
--   * PERMISSIVE policies are OR-combined (grant access).
--   * RESTRICTIVE policies are AND-combined (further constrain access).
-- A row is only visible/mutable if it passes (any permissive) AND (every
-- restrictive) policy.
--
-- So we add RESTRICTIVE policies whose condition is:
--
--     key <> 'elife_api_connection'  OR  public.is_admin(auth.uid())
--
-- For every other key this is TRUE (key <> ...), so the existing public
-- policies keep working unchanged. For the elife row it is TRUE only when the
-- caller is an admin (has a row in public.admin_access, via is_admin() from
-- 0009_admin_access.sql). Non-admins simply can't see or touch that row.
-- ============================================================================

alter table public.app_settings enable row level security;

-- ---------------------------------------------------------------------------
-- SELECT: only admins can read the elife row; all other rows stay readable.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only select" on public.app_settings;
create policy "app_settings elife admin only select"
  on public.app_settings
  as restrictive
  for select
  to public
  using (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- INSERT: only admins can create the elife row.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only insert" on public.app_settings;
create policy "app_settings elife admin only insert"
  on public.app_settings
  as restrictive
  for insert
  to public
  with check (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- UPDATE: only admins can modify the elife row (both the existing row it
-- targets, USING, and the new values it writes, WITH CHECK).
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only update" on public.app_settings;
create policy "app_settings elife admin only update"
  on public.app_settings
  as restrictive
  for update
  to public
  using (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  )
  with check (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- DELETE: only admins can delete the elife row.
-- ---------------------------------------------------------------------------
drop policy if exists "app_settings elife admin only delete" on public.app_settings;
create policy "app_settings elife admin only delete"
  on public.app_settings
  as restrictive
  for delete
  to public
  using (
    key <> 'elife_api_connection'
    or public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- Verification (run manually in the Supabase SQL editor after applying):
--
--   select polname, polpermissive, polcmd
--     from pg_policy
--    where polrelid = 'public.app_settings'::regclass
--    order by polname;
--
-- The 4 new policies should show polpermissive = false (restrictive).
--
-- As a NON-admin session (anon key), this should now return 0 rows:
--   select * from public.app_settings where key = 'elife_api_connection';
-- ...while other keys still read fine:
--   select * from public.app_settings where key = 'api_providers';
-- ============================================================================

-- ---- from migrations/0043_fare_ai_tracking.sql ----
-- ============================================================================
-- 0043_fare_ai_tracking.sql
-- ----------------------------------------------------------------------------
-- Adds per-key usage tracking, automatic cooldown for failed keys, and a full
-- response log for the AI fare-estimation feature.
--
--   * public.fare_ai_key_states  — one row per API key id. Tracks how many
--     times the key was used, how many calls passed/failed, when it was last
--     used, and (when failing) a `disabled_until` cooldown timestamp so the
--     client skips it until the configured retry window elapses.
--
--   * public.fare_ai_responses   — one row per AI request attempt (the
--     "record of respond" the admin asked for). Stores the route, the provider/
--     key/model used, success flag, HTTP status, parsed result, latency and the
--     raw response text for debugging.
--
--   * public.fare_ai_record_usage(...) — atomic upsert that increments the
--     counters and sets/clears the cooldown for a key in a single statement so
--     concurrent clients can't clobber each other's counts.
--
-- RLS follows the existing wide-open pattern used for app_settings (migration
-- 0008) so anon clients can read stats and append response rows. The usage
-- counters are only mutated through the SECURITY DEFINER function below.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Per-key state / counters
-- ---------------------------------------------------------------------------
create table if not exists public.fare_ai_key_states (
  key_id           text primary key,
  provider         text not null default '',
  usage_count      integer not null default 0,
  pass_count       integer not null default 0,
  fail_count       integer not null default 0,
  last_used_at     timestamptz,
  last_success_at  timestamptz,
  last_failed_at   timestamptz,
  disabled_until   timestamptz,
  last_error       text,
  updated_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Response log
-- ---------------------------------------------------------------------------
create table if not exists public.fare_ai_responses (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  provider     text not null default '',
  key_id       text,
  key_label    text,
  model        text,
  origin_lat   double precision,
  origin_lng   double precision,
  dest_lat     double precision,
  dest_lng     double precision,
  success      boolean not null default false,
  http_status  integer,
  distance_km  double precision,
  duration_min double precision,
  summary      text,
  error        text,
  latency_ms   integer,
  raw_response text
);

create index if not exists fare_ai_responses_created_at_idx
  on public.fare_ai_responses (created_at desc);
create index if not exists fare_ai_responses_key_id_idx
  on public.fare_ai_responses (key_id);

-- ---------------------------------------------------------------------------
-- Atomic counter upsert + cooldown management
-- ---------------------------------------------------------------------------
create or replace function public.fare_ai_record_usage(
  p_key_id         text,
  p_provider       text,
  p_success        boolean,
  p_disabled_until timestamptz,
  p_error          text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.fare_ai_key_states as s (
    key_id, provider, usage_count, pass_count, fail_count,
    last_used_at, last_success_at, last_failed_at, disabled_until, last_error, updated_at
  ) values (
    p_key_id, p_provider, 1,
    case when p_success then 1 else 0 end,
    case when p_success then 0 else 1 end,
    now(),
    case when p_success then now() else null end,
    case when p_success then null else now() end,
    case when p_success then null else p_disabled_until end,
    case when p_success then null else p_error end,
    now()
  )
  on conflict (key_id) do update set
    provider        = excluded.provider,
    usage_count     = s.usage_count + 1,
    pass_count      = s.pass_count + case when p_success then 1 else 0 end,
    fail_count      = s.fail_count + case when p_success then 0 else 1 end,
    last_used_at    = now(),
    last_success_at = case when p_success then now() else s.last_success_at end,
    last_failed_at  = case when p_success then s.last_failed_at else now() end,
    disabled_until  = case when p_success then null else p_disabled_until end,
    last_error      = case when p_success then null else p_error end,
    updated_at      = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS: wide-open like app_settings (anon can read stats + append responses).
-- ---------------------------------------------------------------------------
alter table public.fare_ai_key_states enable row level security;
alter table public.fare_ai_responses  enable row level security;

drop policy if exists "fare_ai_key_states read" on public.fare_ai_key_states;
create policy "fare_ai_key_states read"
  on public.fare_ai_key_states for select to public using (true);

drop policy if exists "fare_ai_responses read" on public.fare_ai_responses;
create policy "fare_ai_responses read"
  on public.fare_ai_responses for select to public using (true);

drop policy if exists "fare_ai_responses insert" on public.fare_ai_responses;
create policy "fare_ai_responses insert"
  on public.fare_ai_responses for insert to public with check (true);

drop policy if exists "fare_ai_responses delete" on public.fare_ai_responses;
create policy "fare_ai_responses delete"
  on public.fare_ai_responses for delete to public using (true);

grant select on public.fare_ai_key_states to anon, authenticated, service_role;
grant select, insert, delete on public.fare_ai_responses to anon, authenticated, service_role;
grant execute on function public.fare_ai_record_usage(text, text, boolean, timestamptz, text)
  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Realtime so the admin stats screen updates live.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.fare_ai_key_states;
  exception when duplicate_object then null;
  end;
end $$;
alter table public.fare_ai_key_states replica identity full;

-- ---- from migrations/0044_fare_ai_toll_columns.sql ----
-- ============================================================================
-- 0044_fare_ai_toll_columns.sql
-- ----------------------------------------------------------------------------
-- Persist the toll information parsed from each AI fare estimate so it can be
-- shown per row in the admin Response Log alongside distance/duration.
--
--   * toll_count  — number of toll booths/plazas the model reported.
--   * toll_total  — sum of all toll charges in local currency.
--   * tolls       — jsonb array of { name, charge } per booth.
-- ============================================================================

alter table public.fare_ai_responses
  add column if not exists toll_count integer,
  add column if not exists toll_total double precision,
  add column if not exists tolls jsonb;

-- ---- from migrations/0051_ride_request_push_webhook.sql ----
-- ============================================================================
-- Ride-request push webhook
-- ----------------------------------------------------------------------------
-- When a passenger creates a new `open` ride request, automatically notify the
-- partner (driver) audience by calling the `send-push` edge function from the
-- database via pg_net (async HTTP).
--
-- Config is read from Supabase Vault so no secrets live in the schema:
--   * project_url        — your project URL, e.g. https://xxxx.supabase.co
--   * service_role_key   — the service-role key (allows calling the function)
--
-- Set them once (SQL editor), then re-run is safe:
--   select vault.create_secret('https://YOURREF.supabase.co', 'project_url');
--   select vault.create_secret('YOUR_SERVICE_ROLE_KEY',       'service_role_key');
--
-- If either secret is missing the trigger no-ops quietly (never blocks inserts).
-- Safe to re-run.
-- ============================================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_key    text;
  v_pickup text;
  v_body   text;
begin
  -- Only fire for brand-new open requests.
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- Pull config from Vault; bail out gracefully if not configured.
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    return new;
  end;

  if v_url is null or v_key is null then
    return new;
  end if;

  v_pickup := coalesce(nullif(new.pickup_name, ''), nullif(new.pickup_address, ''), 'a nearby location');
  v_body   := 'Pickup at ' || v_pickup ||
              case when new.fare is not null
                   then ' • ' || coalesce(new.currency, '') || ' ' || new.fare::text
                   else '' end;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := jsonb_build_object(
      'title', 'New ride request',
      'body', v_body,
      'audience', 'partners',
      'data', jsonb_build_object(
        'type', 'ride_request',
        'ride_request_id', new.id
      )
    )
  );

  return new;
exception when others then
  -- Never let a notification failure block the ride request insert.
  return new;
end;
$$;

do $$
begin
  drop trigger if exists trg_ride_request_push on public.ride_requests;
  create trigger trg_ride_request_push
    after insert on public.ride_requests
    for each row execute function public.notify_partners_on_ride_request();
end$$;

-- ---- from migrations/0067_push_webhook_optional_service_key.sql ----
-- ============================================================================
-- Push webhooks: make the Vault `service_role_key` secret optional
-- ----------------------------------------------------------------------------
-- The 0051 (new ride request) and 0065 (wallet transfer) triggers called the
-- `send-push` edge function with `Authorization: Bearer <service_role_key>`
-- read from Vault, and no-oped when EITHER Vault secret was missing. But
-- `send-push` is deployed with `--no-verify-jwt`, so the gateway never checks
-- that bearer — the function authenticates internally with its env-injected
-- service-role key. Requiring the secret only meant deployments that never ran
-- the Vault setup silently sent no partner notifications at all.
--
-- This migration routes all three webhook triggers through one shared helper,
-- `public.send_push_webhook(jsonb)`, which:
--   * still reads `project_url` from Vault (required — the DB cannot derive
--     its own project URL),
--   * attaches the Authorization header only when `service_role_key` exists,
--     and posts without it otherwise (valid because send-push is public),
--   * never raises — notification failures must not block the parent write.
--
-- Setup now needs just one secret (SQL editor, safe to re-run):
--   select vault.create_secret('https://YOURREF.supabase.co', 'project_url');
--
-- Safe to re-run.
-- ============================================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.send_push_webhook(p_body jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url     text;
  v_key     text;
  v_headers jsonb;
begin
  -- Pull config from Vault; bail out gracefully if unreadable.
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    return;
  end;

  if v_url is null then
    return;
  end if;

  v_headers := jsonb_build_object('Content-Type', 'application/json');
  if v_key is not null then
    v_headers := v_headers || jsonb_build_object('Authorization', 'Bearer ' || v_key);
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := v_headers,
    body    := p_body
  );
exception when others then
  null;
end;
$$;

-- Trigger-internal helper; no reason for clients to call it directly.
revoke execute on function public.send_push_webhook(jsonb) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 0051: new open ride request -> notify the partner audience
-- ----------------------------------------------------------------------------
create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_pickup text;
  v_body   text;
begin
  -- Only fire for brand-new open requests.
  if new.status is distinct from 'open' then
    return new;
  end if;

  v_pickup := coalesce(nullif(new.pickup_name, ''), nullif(new.pickup_address, ''), 'a nearby location');
  v_body   := 'Pickup at ' || v_pickup ||
              case when new.fare is not null
                   then ' • ' || coalesce(new.currency, '') || ' ' || new.fare::text
                   else '' end;

  perform public.send_push_webhook(jsonb_build_object(
    'title', 'New ride request',
    'body', v_body,
    'audience', 'partners',
    'data', jsonb_build_object(
      'type', 'ride_request',
      'ride_request_id', new.id
    )
  ));

  return new;
exception when others then
  -- Never let a notification failure block the ride request insert.
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 0065: coin transfer request -> notify the recipient
-- ----------------------------------------------------------------------------
create or replace function public.notify_wallet_transfer_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
begin
  if new.status is distinct from 'pending' then
    return new;
  end if;

  perform public.send_push_webhook(jsonb_build_object(
    'title', 'GET.coin transfer request',
    'body', coalesce(nullif(new.from_name, ''), 'Someone')
            || ' wants to send you ' || new.coins::text || ' GC',
    'profileId', new.to_user_id,
    'data', jsonb_build_object(
      'type', 'wallet_transfer_request',
      'request_id', new.id
    )
  ));

  return new;
exception when others then
  -- Never let a notification failure block the request.
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 0065: coin transfer resolved -> notify the sender
-- ----------------------------------------------------------------------------
create or replace function public.notify_wallet_transfer_response()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_body text;
begin
  if old.status is distinct from 'pending'
     or new.status not in ('accepted', 'declined', 'failed') then
    return new;
  end if;

  v_body := case new.status
    when 'accepted' then coalesce(nullif(new.to_name, ''), 'The recipient')
                         || ' approved your request — ' || new.coins::text || ' GC sent'
    when 'declined' then coalesce(nullif(new.to_name, ''), 'The recipient')
                         || ' declined your transfer of ' || new.coins::text || ' GC'
    else 'Your transfer of ' || new.coins::text || ' GC failed — not enough GET.coin'
  end;

  perform public.send_push_webhook(jsonb_build_object(
    'title', 'GET.coin transfer',
    'body', v_body,
    'profileId', new.from_user_id,
    'data', jsonb_build_object(
      'type', 'wallet_transfer_response',
      'request_id', new.id,
      'status', new.status
    )
  ));

  return new;
exception when others then
  return new;
end;
$$;

-- The triggers from 0051/0065 reference these functions by name, so replacing
-- the bodies above is enough — but re-create them idempotently in case this
-- migration runs on a database that never applied the originals.
do $$
begin
  drop trigger if exists trg_ride_request_push on public.ride_requests;
  create trigger trg_ride_request_push
    after insert on public.ride_requests
    for each row execute function public.notify_partners_on_ride_request();

  drop trigger if exists trg_wallet_transfer_request_push on public.wallet_transfer_requests;
  create trigger trg_wallet_transfer_request_push
    after insert on public.wallet_transfer_requests
    for each row execute function public.notify_wallet_transfer_request();

  drop trigger if exists trg_wallet_transfer_response_push on public.wallet_transfer_requests;
  create trigger trg_wallet_transfer_response_push
    after update on public.wallet_transfer_requests
    for each row execute function public.notify_wallet_transfer_response();
end$$;

-- ---- from migrations/0077_ride_request_fare_raise_push.sql ----
-- ============================================================================
-- Notify partners on raised fare (re-offer) as well as new requests
-- ----------------------------------------------------------------------------
-- The ride-request push webhook (0051, reworked in 0067) only fired on INSERT,
-- so a partner whose app was backgrounded or whose phone was locked got an OS
-- push for a brand-new request but NOT when the passenger raised their fare on
-- an already-open request. A fare raise (`raiseRideRequestFare`) is a fresh,
-- higher offer to the partner queue and deserves the same lock-screen push.
--
-- This migration re-defines `notify_partners_on_ride_request()` to also handle
-- UPDATE, firing only when an open request's fare actually increases — every
-- other open-row update (partner counter-offers, live-location writes, etc.) is
-- ignored so partners aren't spammed. The trigger is recreated to run on
-- INSERT OR UPDATE.
--
-- Still routes through the shared `send_push_webhook` helper from 0067, so it
-- only needs the Vault `project_url` secret and never blocks the parent write.
--
-- Notification bodies now show the currency symbol (e.g. RM) instead of the
-- ISO 4217 code (MYR), matching the in-app fare display — resolved via the
-- `public.currency_symbol()` helper below.
--
-- Safe to re-run.
-- ============================================================================

-- Maps an ISO 4217 currency code to its display symbol (mirrors
-- expo/constants/currency.ts). Falls back to the code itself for unknowns.
create or replace function public.currency_symbol(p_code text)
returns text
language sql
immutable
as $$
  select case upper(coalesce(nullif(p_code, ''), 'MYR'))
    when 'MYR' then 'RM'
    when 'SGD' then 'S$'
    when 'IDR' then 'Rp'
    when 'THB' then '฿'
    when 'PHP' then '₱'
    when 'VND' then '₫'
    when 'INR' then '₹'
    when 'USD' then '$'
    when 'GBP' then '£'
    when 'EUR' then '€'
    when 'JPY' then '¥'
    when 'KRW' then '₩'
    when 'AUD' then 'A$'
    when 'AED' then 'AED'
    when 'SAR' then 'SAR'
    when 'PKR' then 'Rs'
    when 'BDT' then '৳'
    when 'LKR' then 'Rs'
    when 'MMK' then 'K'
    when 'KHR' then '៛'
    when 'LAK' then '₭'
    when 'BND' then 'B$'
    when 'CNY' then '¥'
    when 'TWD' then 'NT$'
    when 'HKD' then 'HK$'
    else upper(coalesce(p_code, ''))
  end;
$$;

create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_pickup text;
  v_fare   text;
  v_title  text;
  v_body   text;
begin
  -- Only ever notify about requests that are still open (biddable).
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- On UPDATE, fire only when the passenger raised their fare on the open row.
  -- Skip every other open-row update so the partner queue isn't spammed.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  v_pickup := coalesce(nullif(new.pickup_name, ''), nullif(new.pickup_address, ''), 'a nearby location');
  v_fare   := case when new.fare is not null
                   then ' • ' || public.currency_symbol(new.currency) || ' ' || new.fare::text
                   else '' end;
  v_title  := case when tg_op = 'UPDATE' then 'Fare increased' else 'New ride request' end;
  v_body   := case when tg_op = 'UPDATE' then 'Higher fare — pickup at ' else 'Pickup at ' end
              || v_pickup || v_fare;

  perform public.send_push_webhook(jsonb_build_object(
    'title', v_title,
    'body', v_body,
    'audience', 'partners',
    'data', jsonb_build_object(
      'type', case when tg_op = 'UPDATE' then 'ride_request_fare_raised' else 'ride_request' end,
      'ride_request_id', new.id
    )
  ));

  return new;
exception when others then
  -- Never let a notification failure block the ride request write.
  return new;
end;
$$;

do $$
begin
  drop trigger if exists trg_ride_request_push on public.ride_requests;
  create trigger trg_ride_request_push
    after insert or update on public.ride_requests
    for each row execute function public.notify_partners_on_ride_request();
end$$;

-- ---- storage buckets present on the live project but created outside
-- migrations (dashboard); no policies reference them ----
insert into storage.buckets (id, name, public) values
  ('Profile Image', 'Profile Image', true),
  ('Provider_Documents', 'Provider_Documents', false),
  ('Vehicle_Image', 'Vehicle_Image', true)
on conflict (id) do nothing;

-- ============================================================================
-- 0069: RLS lockdown (folded in — keep this the LAST section so it overrides
-- the permissive policies created above; see migrations/0069_rls_lockdown.sql
-- for the full rationale). Idempotent: generic drops precede every create.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper: privileged-caller check.
-- ----------------------------------------------------------------------------
create or replace function public.caller_is_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (setup scripts, psql, triggers)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  if auth.uid() is null then
    return false;
  end if;
  if to_regclass('public.admin_access') is null then
    return false;
  end if;
  return exists (
    select 1 from public.admin_access where profile_id = auth.uid()
  );
end;
$$;

grant execute on function public.caller_is_admin() to anon, authenticated;

-- ============================================================================
-- Part 1 — admin_access: close the privilege-escalation hole (0010)
-- ============================================================================
do $admin_access$
begin
  if to_regclass('public.admin_access') is null then return; end if;

  drop policy if exists "admin_access public read"   on public.admin_access;
  drop policy if exists "admin_access public insert" on public.admin_access;
  drop policy if exists "admin_access public update" on public.admin_access;
  drop policy if exists "admin_access public delete" on public.admin_access;

  drop policy if exists "admin_access self read"          on public.admin_access;
  drop policy if exists "admin_access admin read"         on public.admin_access;
  drop policy if exists "admin_access admin write insert" on public.admin_access;
  drop policy if exists "admin_access admin write update" on public.admin_access;
  drop policy if exists "admin_access admin write delete" on public.admin_access;

  create policy "admin_access self read"
    on public.admin_access for select
    using (profile_id = auth.uid());

  -- Any admin can see the roster (the sub-admin screen lists all rows).
  create policy "admin_access admin read"
    on public.admin_access for select
    using (public.caller_is_admin());

  create policy "admin_access admin write insert"
    on public.admin_access for insert
    with check (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

  create policy "admin_access admin write update"
    on public.admin_access for update
    using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

  create policy "admin_access admin write delete"
    on public.admin_access for delete
    using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));
end;
$admin_access$;

-- First-run bootstrap: on an EMPTY admin_access table the first authenticated
-- caller becomes the wildcard admin. Once any row exists this is a no-op, so
-- it cannot be used for escalation. (Replaces 0010's public write policies.)
create or replace function public.admin_access_bootstrap()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;
  if exists (select 1 from public.admin_access) then
    return false;
  end if;
  insert into public.admin_access (profile_id, page, access_level, notes)
  values (auth.uid(), '*', 'edit', 'bootstrap: first admin');
  return true;
end;
$$;

grant execute on function public.admin_access_bootstrap() to anon, authenticated;

-- Support-agent roster for the in-app support flow. Regular users used to
-- read admin_access (+ joined profiles) directly; this returns only the
-- fields the support screen needs.
create or replace function public.support_agents()
returns table (profile_id uuid, name text, avatar_url text, priority integer)
language sql
stable
security definer
set search_path = public
as $$
  select aa.profile_id,
         coalesce(nullif(p.name, ''), nullif(p.phone, ''), 'Agent') as name,
         coalesce(nullif(p.avatar_url, ''), nullif(p.profile_image, '')) as avatar_url,
         min(aa.support) as priority
    from public.admin_access aa
    join public.profiles p on p.id = aa.profile_id
   group by aa.profile_id, p.name, p.phone, p.avatar_url, p.profile_image;
$$;

grant execute on function public.support_agents() to anon, authenticated;

-- ============================================================================
-- Part 2 — ride_requests: participant-scoped dispatch
-- ============================================================================
-- Write shapes these policies must keep working (see rideRequestsStore.ts):
--   * rider inserts an `open` request with rider_id = their own uid;
--   * partners claim/offer on OPEN rows, always stamping partner_id = self
--     in the same update (`acceptRideRequest` / `submitRideOffer`);
--   * the rider raises the fare on their own open row (clears partner_id);
--   * both participants progress/cancel their own row and publish live GPS;
--   * the rider expires their own stale open rows.
do $ride_requests$
begin
  if to_regclass('public.ride_requests') is null then return; end if;

  drop policy if exists "ride_requests read"   on public.ride_requests;
  drop policy if exists "ride_requests insert" on public.ride_requests;
  drop policy if exists "ride_requests update" on public.ride_requests;
  drop policy if exists "ride_requests delete" on public.ride_requests;
  drop policy if exists "ride_requests rider insert"       on public.ride_requests;
  drop policy if exists "ride_requests participant update" on public.ride_requests;
  drop policy if exists "ride_requests claim open"         on public.ride_requests;
  drop policy if exists "ride_requests admin delete"       on public.ride_requests;

  -- Open requests stay visible to everyone (the partner queue, including
  -- legacy anon sessions, needs them). Active/finished rides — which carry
  -- both parties' phone numbers and live GPS — are participant/admin only.
  create policy "ride_requests read"
    on public.ride_requests for select
    using (
      status = 'open'
      or rider_id = auth.uid()
      or partner_id = auth.uid()
      or public.caller_is_admin()
    );

  create policy "ride_requests rider insert"
    on public.ride_requests for insert to public
    with check (
      (auth.uid() is not null and rider_id = auth.uid())
      or public.caller_is_admin()
    );

  create policy "ride_requests participant update"
    on public.ride_requests for update to public
    using (
      rider_id = auth.uid()
      or partner_id = auth.uid()
      or public.caller_is_admin()
    )
    with check (
      rider_id = auth.uid()
      or partner_id = auth.uid()
      or public.caller_is_admin()
    );

  -- Claiming / offering: any authenticated partner may write to an OPEN row,
  -- but the new row must carry their own partner_id.
  create policy "ride_requests claim open"
    on public.ride_requests for update to public
    using (status = 'open' and auth.uid() is not null)
    with check (partner_id = auth.uid());

  create policy "ride_requests admin delete"
    on public.ride_requests for delete to public
    using (public.caller_is_admin());
end;
$ride_requests$;

-- Permissive policies OR together across USING and WITH CHECK independently,
-- so "claim open" USING + "participant update" WITH CHECK would let a caller
-- re-own someone's open request by rewriting rider_id to themselves. Close
-- that: rider_id is immutable after insert (privileged sessions excepted).
create or replace function public.ride_requests_protect_rider()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.rider_id is distinct from old.rider_id and not public.caller_is_admin() then
    raise exception 'rider_immutable';
  end if;
  return new;
end;
$$;

do $rr_trigger$
begin
  if to_regclass('public.ride_requests') is null then return; end if;
  drop trigger if exists trg_ride_requests_protect_rider on public.ride_requests;
  create trigger trg_ride_requests_protect_rider
    before update on public.ride_requests
    for each row execute function public.ride_requests_protect_rider();
end;
$rr_trigger$;

-- ============================================================================
-- Part 3 — admin-managed configuration tables: writes become admin-only
-- ============================================================================
-- Reads stay public (the app renders these), existing INSERT/UPDATE/DELETE
-- policies — whatever their historical names — are dropped and replaced.
do $config$
declare
  t   text;
  pol record;
begin
  foreach t in array array[
    'countries', 'states', 'cities', 'suburbs', 'airport_areas',
    'required_document', 'document_type', 'driver_incentive', 'multi_gate',
    'insurance_providers', 'insurance_types', 'insurance_durations',
    'insurance_premium', 'ev_delivery_advisors', 'ev_finance_options',
    'ev_order_fee', 'ev_vehicle_details', 'ev_vehicle_inventory',
    'vehicle_make_models', 'settings_entries', 'app_settings', 'app_branding',
    'commission_rates', 'ip_access_rules', 'get_coin_settings',
    'get_coin_rate_history', 'admin_display_settings', 'push_notifications',
    'meter_digital_settings'
  ] loop
    if to_regclass('public.' || t) is null then continue; end if;

    for pol in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd in ('INSERT', 'UPDATE', 'DELETE')
    loop
      execute format('drop policy %I on public.%I;', pol.policyname, t);
    end loop;

    execute format(
      'create policy "%1$s admin insert" on public.%1$s for insert to public with check (public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin update" on public.%1$s for update to public using (public.caller_is_admin()) with check (public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin delete" on public.%1$s for delete to public using (public.caller_is_admin());', t);
  end loop;
end;
$config$;

-- push_notifications additionally loses its public read: broadcast history is
-- an admin dashboard concern and the send-push edge function writes with the
-- service role (bypasses RLS).
do $push_notifications$
begin
  if to_regclass('public.push_notifications') is null then return; end if;
  drop policy if exists "push_notifications read" on public.push_notifications;
  create policy "push_notifications read"
    on public.push_notifications for select
    using (public.caller_is_admin());
end;
$push_notifications$;

-- ============================================================================
-- Part 4 — personal / PII tables: owner-or-admin scoped
-- ============================================================================
do $pii$
declare
  t   text;
  pol record;
begin
  foreach t in array array[
    'emergency_contacts', 'user_sessions', 'user_location_history',
    'voice_protection_recordings', 'support_tickets', 'support_messages',
    'support_calls', 'push_tokens', 'provider_documents', 'vehicle',
    'vehicle_documents', 'vehicle_user_assignment', 'vehicle_active_session',
    'fare_ai_responses'
  ] loop
    if to_regclass('public.' || t) is null then continue; end if;
    for pol in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    loop
      execute format('drop policy %I on public.%I;', pol.policyname, t);
    end loop;
  end loop;
end;
$pii$;

-- emergency_contacts — the rider's own SOS contacts.
do $emergency$
begin
  if to_regclass('public.emergency_contacts') is null then return; end if;
  create policy "emergency_contacts own select" on public.emergency_contacts
    for select using (profile_id = auth.uid() or public.caller_is_admin());
  create policy "emergency_contacts own insert" on public.emergency_contacts
    for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "emergency_contacts own update" on public.emergency_contacts
    for update to public
    using (profile_id = auth.uid() or public.caller_is_admin())
    with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "emergency_contacts own delete" on public.emergency_contacts
    for delete to public using (profile_id = auth.uid() or public.caller_is_admin());
end;
$emergency$;

-- partners — the onboarding flow writes the caller's own row (self policies
-- from 0025, kept), and the back office writes any row. Without the admin half
-- (migration 0083) Admin → Partner Edit could never persist a change, because
-- the client upsert carries no auth_user_id and so fails the self WITH CHECK.
do $partners_admin$
begin
  if to_regclass('public.partners') is null then return; end if;
  drop policy if exists "partners admin insert" on public.partners;
  create policy "partners admin insert" on public.partners
    for insert to public with check (public.caller_is_admin());
  drop policy if exists "partners admin update" on public.partners;
  create policy "partners admin update" on public.partners
    for update to public
    using (public.caller_is_admin()) with check (public.caller_is_admin());
  drop policy if exists "partners admin delete" on public.partners;
  create policy "partners admin delete" on public.partners
    for delete to public using (public.caller_is_admin());
end;
$partners_admin$;

-- user_sessions / user_location_history — launch telemetry (public IP, ISP,
-- GPS trail). Inserts remain possible pre-login (user_id null) but a caller
-- can never attribute rows to somebody else; reads are owner/admin only.
do $telemetry$
declare t text;
begin
  foreach t in array array['user_sessions', 'user_location_history'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format(
      'create policy "%1$s own select" on public.%1$s for select using (user_id = auth.uid() or public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s own insert" on public.%1$s for insert to public with check (user_id is null or user_id = auth.uid() or public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin update" on public.%1$s for update to public using (public.caller_is_admin()) with check (public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin delete" on public.%1$s for delete to public using (public.caller_is_admin());', t);
  end loop;
end;
$telemetry$;

-- device_attestations — Play Integrity / App Attest verdicts (migration 0073).
-- Admin-read only; written by the attest-device edge function via the service
-- role (which bypasses RLS). See docs/device-attestation.md.
create table if not exists public.device_attestations (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users(id) on delete set null,
  device_id     text,
  platform      text not null check (platform in ('android', 'ios')),
  attest_key_id text,
  passed        boolean not null default false,
  verdict       jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists device_attestations_device_idx on public.device_attestations (device_id);
create index if not exists device_attestations_key_idx on public.device_attestations (attest_key_id);
create index if not exists device_attestations_user_idx on public.device_attestations (user_id);
alter table public.device_attestations enable row level security;
do $attest$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'device_attestations'
      and policyname = 'device_attestations admin read'
  ) then
    create policy "device_attestations admin read" on public.device_attestations
      for select using (public.caller_is_admin());
  end if;
end;
$attest$;

-- voice_protection_recordings — in-ride audio metadata. The recording device
-- inserts/updates its own rows (upload flags); admins request uploads and
-- review.
do $voice$
begin
  if to_regclass('public.voice_protection_recordings') is null then return; end if;
  create policy "voice_protection own select" on public.voice_protection_recordings
    for select using (profile_id = auth.uid() or public.caller_is_admin());
  create policy "voice_protection own insert" on public.voice_protection_recordings
    for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "voice_protection own update" on public.voice_protection_recordings
    for update to public
    using (profile_id = auth.uid() or public.caller_is_admin())
    with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "voice_protection admin delete" on public.voice_protection_recordings
    for delete to public using (public.caller_is_admin());
end;
$voice$;

-- support_tickets / support_messages / support_calls — the requester and the
-- support admins. Messages are scoped through their ticket.
do $support$
begin
  if to_regclass('public.support_tickets') is not null then
    create policy "support_tickets own select" on public.support_tickets
      for select using (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_tickets own insert" on public.support_tickets
      for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_tickets own update" on public.support_tickets
      for update to public
      using (profile_id = auth.uid() or public.caller_is_admin())
      with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_tickets admin delete" on public.support_tickets
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.support_messages') is not null then
    create policy "support_messages participant select" on public.support_messages
      for select using (
        public.caller_is_admin()
        or exists (
          select 1 from public.support_tickets t
          where t.id = support_messages.ticket_id and t.profile_id = auth.uid()
        )
      );
    create policy "support_messages participant insert" on public.support_messages
      for insert to public with check (
        public.caller_is_admin()
        or exists (
          select 1 from public.support_tickets t
          where t.id = support_messages.ticket_id and t.profile_id = auth.uid()
        )
      );
    create policy "support_messages admin update" on public.support_messages
      for update to public
      using (public.caller_is_admin()) with check (public.caller_is_admin());
    create policy "support_messages admin delete" on public.support_messages
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.support_calls') is not null then
    create policy "support_calls own select" on public.support_calls
      for select using (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_calls own insert" on public.support_calls
      for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_calls own update" on public.support_calls
      for update to public
      using (profile_id = auth.uid() or public.caller_is_admin())
      with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_calls admin delete" on public.support_calls
      for delete to public using (public.caller_is_admin());
  end if;
end;
$support$;

-- push_tokens — Expo push tokens are credentials for reaching a device.
-- Registration moves behind owner-scoped RPCs; the table itself is
-- admin-read/write only (the send-push edge function uses the service role).
do $push_tokens$
begin
  if to_regclass('public.push_tokens') is null then return; end if;
  create policy "push_tokens admin select" on public.push_tokens
    for select using (public.caller_is_admin());
  create policy "push_tokens admin insert" on public.push_tokens
    for insert to public with check (public.caller_is_admin());
  create policy "push_tokens admin update" on public.push_tokens
    for update to public
    using (public.caller_is_admin()) with check (public.caller_is_admin());
  create policy "push_tokens admin delete" on public.push_tokens
    for delete to public using (public.caller_is_admin());
end;
$push_tokens$;

-- Owner-scoped registration. Upserting by token also covers the "same device,
-- new account" case, which plain RLS cannot express (the old row belongs to
-- the previous profile).
create or replace function public.push_register_token(
  p_token text,
  p_platform text default null,
  p_device_name text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_token is null or length(trim(p_token)) = 0 or length(p_token) > 512 then
    raise exception 'invalid_token';
  end if;
  insert into public.push_tokens (token, profile_id, platform, device_name)
  values (p_token, auth.uid(), p_platform, p_device_name)
  on conflict (token) do update
    set profile_id  = excluded.profile_id,
        platform    = excluded.platform,
        device_name = excluded.device_name,
        updated_at  = now();
end;
$$;

-- Knowing the token IS the capability (it is device-secret), so sign-out
-- cleanup works even after the auth session is gone.
create or replace function public.push_unregister_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return;
  end if;
  delete from public.push_tokens where token = p_token;
end;
$$;

grant execute on function public.push_register_token(text, text, text) to anon, authenticated;
grant execute on function public.push_unregister_token(text) to anon, authenticated;

-- provider_documents / vehicle / vehicle_documents / vehicle assignments —
-- partner onboarding data (IC numbers, document scans). Owner = the linked
-- auth user, the owning partner, or an assigned driver; admins see all.
do $partner_data$
begin
  if to_regclass('public.provider_documents') is not null then
    create policy "provider_documents own select" on public.provider_documents
      for select using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "provider_documents own insert" on public.provider_documents
      for insert to public with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "provider_documents own update" on public.provider_documents
      for update to public
      using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      )
      with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "provider_documents admin delete" on public.provider_documents
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.vehicle') is not null then
    create policy "vehicle own select" on public.vehicle
      for select using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle.owner_partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle_user_assignment a
          where a.vehicle_id = vehicle.id and a.user_id = auth.uid()
        )
      );
    create policy "vehicle own insert" on public.vehicle
      for insert to public with check (
        public.caller_is_admin() or auth_user_id = auth.uid()
      );
    create policy "vehicle own update" on public.vehicle
      for update to public
      using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle.owner_partner_id and p.auth_user_id = auth.uid()
        )
      )
      with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle.owner_partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "vehicle admin delete" on public.vehicle
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.vehicle_documents') is not null then
    create policy "vehicle_documents own select" on public.vehicle_documents
      for select using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      );
    create policy "vehicle_documents own insert" on public.vehicle_documents
      for insert to public with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      );
    create policy "vehicle_documents own update" on public.vehicle_documents
      for update to public
      using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      )
      with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      );
    create policy "vehicle_documents admin delete" on public.vehicle_documents
      for delete to public using (public.caller_is_admin());
  end if;

  -- Assignments/sessions are managed by admins and the SECURITY DEFINER
  -- claim/release RPCs (0031/0035); drivers only need to read their own.
  if to_regclass('public.vehicle_user_assignment') is not null then
    create policy "vehicle_user_assignment own select" on public.vehicle_user_assignment
      for select using (
        user_id = auth.uid()
        or public.caller_is_admin()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_user_assignment.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "vehicle_user_assignment admin insert" on public.vehicle_user_assignment
      for insert to public with check (public.caller_is_admin());
    create policy "vehicle_user_assignment admin update" on public.vehicle_user_assignment
      for update to public
      using (public.caller_is_admin()) with check (public.caller_is_admin());
    create policy "vehicle_user_assignment admin delete" on public.vehicle_user_assignment
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.vehicle_active_session') is not null then
    create policy "vehicle_active_session own select" on public.vehicle_active_session
      for select using (user_id = auth.uid() or public.caller_is_admin());
    create policy "vehicle_active_session admin insert" on public.vehicle_active_session
      for insert to public with check (public.caller_is_admin());
    create policy "vehicle_active_session admin update" on public.vehicle_active_session
      for update to public
      using (public.caller_is_admin()) with check (public.caller_is_admin());
    create policy "vehicle_active_session admin delete" on public.vehicle_active_session
      for delete to public using (public.caller_is_admin());
  end if;
end;
$partner_data$;

-- fare_ai_responses — request/response logs embed rider route coordinates.
-- Reads become admin-only; inserts stay open because the legacy client-side
-- provider loop (pre ai-route-proxy) logs its attempts best-effort.
do $fare_ai$
begin
  if to_regclass('public.fare_ai_responses') is null then return; end if;
  create policy "fare_ai_responses admin select" on public.fare_ai_responses
    for select using (public.caller_is_admin());
  create policy "fare_ai_responses insert" on public.fare_ai_responses
    for insert to public with check (true);
  create policy "fare_ai_responses admin delete" on public.fare_ai_responses
    for delete to public using (public.caller_is_admin());
end;
$fare_ai$;

-- ============================================================================
-- Part 5 — online_driver_locations: SECURITY DEFINER view → invoker
-- ============================================================================
-- The view (previously created ad hoc, definer-owned, bypassing RLS) exposes
-- online drivers' latest GPS fix. With security_invoker it now runs under the
-- caller's policies — i.e. admin dashboards. No app screen queries it.
do $view$
begin
  if to_regclass('public.vehicle_active_session') is null
     or to_regclass('public.partners') is null
     or to_regclass('public.user_location_history') is null then
    return;
  end if;
  execute $v$
    create or replace view public.online_driver_locations
    with (security_invoker = true) as
    select vas.id as session_id,
           vas.partner_id,
           vas.vehicle_id,
           vas.user_id,
           p.partner_types,
           p.vehicle_type,
           ulh.latitude,
           ulh.longitude,
           ulh.heading,
           ulh.speed,
           ulh.captured_at
      from public.vehicle_active_session vas
      join public.partners p on p.id = vas.partner_id
      join lateral (
        select l.latitude, l.longitude, l.heading, l.speed, l.captured_at
          from public.user_location_history l
         where l.user_id = vas.user_id
         order by l.captured_at desc
         limit 1
      ) ulh on true
     where vas.status = 'online'
  $v$;
end;
$view$;

-- ============================================================================
-- Part 6 — pin search_path on flagged trigger/cron functions
-- ============================================================================
do $fn_paths$
declare f text;
begin
  foreach f in array array[
    'public.set_updated_at()',
    'public.set_support_ticket_number()',
    'public.expire_documents_daily()',
    'public.provider_documents_touch_updated_at()',
    'public.provider_documents_apply_expiry()',
    'public.vehicle_documents_touch_updated_at()',
    'public.vehicle_documents_apply_expiry()'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('alter function %s set search_path = public;', f);
    end if;
  end loop;
  -- hash_profile_pin calls pgcrypto's crypt(); include the extensions schema
  -- in case pgcrypto lives there rather than in public.
  if to_regprocedure('public.hash_profile_pin()') is not null then
    alter function public.hash_profile_pin() set search_path = public, extensions;
  end if;
end;
$fn_paths$;

-- ============================================================================
-- Part 7 — storage: stop public listing + anon writes on managed buckets
-- ============================================================================
-- Buckets stay `public` so existing getPublicUrl() links keep rendering; the
-- policies below only govern the storage API (list/download/upload/delete),
-- which the app uses for uploads and admin signed URLs.

-- Broad SELECT (listing) policies.
drop policy if exists "public read app-assets"     on storage.objects;
drop policy if exists "public read avatars"        on storage.objects;
drop policy if exists "public read id_image"       on storage.objects;
drop policy if exists "public read support-media"  on storage.objects;
drop policy if exists "app-branding read"          on storage.objects;
drop policy if exists "partner-type-icons read"    on storage.objects;
drop policy if exists "provider-documents read"    on storage.objects;
drop policy if exists "vehicle-documents read"     on storage.objects;
drop policy if exists "anon read voice-protection" on storage.objects;

-- Admins keep API-level read (listing, signed URLs) on every managed bucket.
drop policy if exists "managed buckets admin read" on storage.objects;
create policy "managed buckets admin read"
  on storage.objects for select to authenticated
  using (
    public.caller_is_admin()
    and bucket_id in (
      'app-assets', 'app-branding', 'avatars', 'ID_Image',
      'partner-type-icons', 'provider-documents', 'support-media',
      'vehicle-documents', 'voice-protection'
    )
  );

-- Voice-protection recordings: uploads land in a folder named after the
-- recording profile, so the owner keeps read/write on their own folder.
drop policy if exists "anon upload voice-protection" on storage.objects;
drop policy if exists "anon update voice-protection" on storage.objects;
drop policy if exists "anon delete voice-protection" on storage.objects;
drop policy if exists "voice-protection owner read"   on storage.objects;
drop policy if exists "voice-protection owner write"  on storage.objects;
drop policy if exists "voice-protection owner update" on storage.objects;
drop policy if exists "voice-protection admin delete" on storage.objects;
create policy "voice-protection owner read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'voice-protection'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "voice-protection owner write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'voice-protection'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "voice-protection owner update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'voice-protection'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "voice-protection admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'voice-protection' and public.caller_is_admin());

-- Branding + partner-type icons: only admins manage these assets.
drop policy if exists "app-branding insert" on storage.objects;
drop policy if exists "app-branding update" on storage.objects;
drop policy if exists "app-branding delete" on storage.objects;
drop policy if exists "app-branding admin write"  on storage.objects;
drop policy if exists "app-branding admin update" on storage.objects;
drop policy if exists "app-branding admin delete" on storage.objects;
create policy "app-branding admin write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'app-branding' and public.caller_is_admin());
create policy "app-branding admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'app-branding' and public.caller_is_admin());
create policy "app-branding admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'app-branding' and public.caller_is_admin());

drop policy if exists "partner-type-icons insert" on storage.objects;
drop policy if exists "partner-type-icons update" on storage.objects;
drop policy if exists "partner-type-icons delete" on storage.objects;
drop policy if exists "partner-type-icons admin write"  on storage.objects;
drop policy if exists "partner-type-icons admin update" on storage.objects;
drop policy if exists "partner-type-icons admin delete" on storage.objects;
create policy "partner-type-icons admin write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'partner-type-icons' and public.caller_is_admin());
create policy "partner-type-icons admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'partner-type-icons' and public.caller_is_admin());
create policy "partner-type-icons admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'partner-type-icons' and public.caller_is_admin());

-- Partner/vehicle document scans: uploads are keyed by partner/vehicle id
-- (not auth uid), so writes stay authenticated-wide; deletes become admin.
drop policy if exists "provider-documents insert" on storage.objects;
drop policy if exists "provider-documents update" on storage.objects;
drop policy if exists "provider-documents delete" on storage.objects;
drop policy if exists "provider-documents auth write"   on storage.objects;
drop policy if exists "provider-documents auth update"  on storage.objects;
drop policy if exists "provider-documents admin delete" on storage.objects;
create policy "provider-documents auth write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'provider-documents');
create policy "provider-documents auth update"
  on storage.objects for update to authenticated
  using (bucket_id = 'provider-documents');
create policy "provider-documents admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'provider-documents' and public.caller_is_admin());

drop policy if exists "vehicle-documents insert" on storage.objects;
drop policy if exists "vehicle-documents update" on storage.objects;
drop policy if exists "vehicle-documents delete" on storage.objects;
drop policy if exists "vehicle-documents auth write"   on storage.objects;
drop policy if exists "vehicle-documents auth update"  on storage.objects;
drop policy if exists "vehicle-documents admin delete" on storage.objects;
create policy "vehicle-documents auth write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicle-documents');
create policy "vehicle-documents auth update"
  on storage.objects for update to authenticated
  using (bucket_id = 'vehicle-documents');
create policy "vehicle-documents admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'vehicle-documents' and public.caller_is_admin());

-- Support attachments: authenticated uploads (support requires a profile),
-- admin-only rewrite/delete.
drop policy if exists "anon upload support-media" on storage.objects;
drop policy if exists "auth update support-media" on storage.objects;
drop policy if exists "auth delete support-media" on storage.objects;
drop policy if exists "support-media auth write"   on storage.objects;
drop policy if exists "support-media admin update" on storage.objects;
drop policy if exists "support-media admin delete" on storage.objects;
create policy "support-media auth write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'support-media');
create policy "support-media admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'support-media' and public.caller_is_admin());
create policy "support-media admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'support-media' and public.caller_is_admin());

-- (avatars / ID_Image writes were already authenticated-scoped — unchanged.)

-- ============================================================================
-- Not fixable in SQL: enable "leaked password protection" in the Supabase
-- dashboard (Auth → Providers → Password) to clear the remaining advisor
-- warning. This project signs in via phone OTP + PIN, so impact is minimal.
-- ============================================================================

-- ============================================================================
-- TEKSI EV orders (migration 0080)
-- ============================================================================
-- Customer-owned rows, not admin configuration: the EV wizard creates an order
-- when the customer pays the order fee, so `settings_entries` (admin-write-only
-- since the lockdown above) could never hold them. Same shape as the dedicated
-- settings tables plus `user_id`, with owner-or-admin policies.

create table if not exists public.ev_orders (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid default auth.uid() references auth.users(id) on delete set null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists ev_orders_user_id_idx  on public.ev_orders(user_id);
create index if not exists ev_orders_position_idx on public.ev_orders(position);

drop trigger if exists trg_ev_orders_updated_at on public.ev_orders;
create trigger trg_ev_orders_updated_at
  before update on public.ev_orders
  for each row execute function public.set_updated_at();

-- user_id is immutable after insert (same guard as ride_requests.rider_id).
create or replace function public.ev_orders_freeze_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is distinct from old.user_id and not public.caller_is_admin() then
    raise exception 'ev_orders.user_id is immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ev_orders_freeze_owner on public.ev_orders;
create trigger trg_ev_orders_freeze_owner
  before update on public.ev_orders
  for each row execute function public.ev_orders_freeze_owner();

alter table public.ev_orders enable row level security;

drop policy if exists "ev_orders read"   on public.ev_orders;
drop policy if exists "ev_orders insert" on public.ev_orders;
drop policy if exists "ev_orders update" on public.ev_orders;
drop policy if exists "ev_orders delete" on public.ev_orders;

create policy "ev_orders read" on public.ev_orders
  for select
  using (user_id = auth.uid() or public.caller_is_admin());

create policy "ev_orders insert" on public.ev_orders
  for insert to public
  with check (
    (auth.uid() is not null and user_id = auth.uid())
    or public.caller_is_admin()
  );

create policy "ev_orders update" on public.ev_orders
  for update to public
  using (user_id = auth.uid() or public.caller_is_admin())
  with check (user_id = auth.uid() or public.caller_is_admin());

-- A paid order is a record; only the back office removes one.
create policy "ev_orders delete" on public.ev_orders
  for delete to public
  using (public.caller_is_admin());

grant select, insert, update, delete on public.ev_orders to authenticated;
revoke all on public.ev_orders from anon;

-- ============================================================================
-- Meter Digital settings & rate cards (migration 0081)
-- ----------------------------------------------------------------------------
-- Everything Admin → Settings → Meter Digital Setting configures for the in-app
-- taxi meter (`app/meter-digital.tsx`): which sensors it may bill on, whether a
-- hire may open without an odometer reading, which console panels are shown and
-- which may be tapped, what the two leave-the-meter keys do (0085), and the
-- rate card itself (flag fare, distance charge per
-- km or per started block, time charge per minute / second / started block, how
-- the two combine, the night surcharge and the luggage/passenger extras).
--
-- Scoped like `commission_rates`: one 'master' row is the global card, and
-- country / state / city / suburb rows override it. The meter resolves the
-- first match, highest first — suburb → city → state → country → master →
-- built-in TEKSI tariff — client-side (`utils/meterSettings.ts`), because it has
-- to keep pricing a hire with no signal at all.
-- ============================================================================

create table if not exists public.meter_digital_settings (
  id uuid primary key default gen_random_uuid(),

  level   text not null check (level in ('master','country','state','city','suburb')),
  country text,
  state   text,
  city    text,
  suburb  text,
  label   text,

  -- Sensors
  source_mode text not null default 'gps+obd'
    check (source_mode in ('gps','gps+obd','obd')),
  allow_start_without_odometer boolean not null default true,
  read_odometer                boolean not null default true,

  -- Open /meter-digital at app launch for partners carrying the TEKSI type.
  auto_launch boolean not null default false,

  -- Leaving the console: what the popup's two keys do. The passenger key can
  -- close the app instead of opening passenger mode (without signing the driver
  -- out), and the e-hailing key can open another dispatch app instead of
  -- /partner-ehailing.
  leave_passenger_action text not null default 'passenger'
    check (leave_passenger_action in ('passenger','exit')),
  leave_ehailing_action  text not null default 'app'
    check (leave_ehailing_action in ('app','link')),
  leave_ehailing_url     text,
  leave_ehailing_label   text,

  -- 0086: the dispatch app by name rather than by link, and where to install it
  -- on a phone that does not have it (one store per platform — none of the
  -- three addresses can be derived from another).
  leave_ehailing_app_id        text,
  leave_ehailing_store_ios     text,
  leave_ehailing_store_android text,
  leave_ehailing_store_huawei  text,

  -- Console panels: shown, and tappable
  show_meter    boolean not null default true,
  show_trips    boolean not null default true,
  show_printer  boolean not null default true,
  show_obd      boolean not null default true,
  show_settings boolean not null default true,
  tap_meter     boolean not null default true,
  tap_trips     boolean not null default true,
  tap_printer   boolean not null default true,
  tap_obd       boolean not null default true,
  tap_settings  boolean not null default true,

  -- Rate card
  currency text not null default 'MYR',

  flag_fare       numeric(10,2) not null default 4.00 check (flag_fare >= 0),
  flag_distance_m integer       not null default 1000 check (flag_distance_m >= 0),
  minimum_fare    numeric(10,2) not null default 0 check (minimum_fare >= 0),

  distance_mode         text          not null default 'block'
    check (distance_mode in ('block','per_km','off')),
  distance_block_m      integer       not null default 200 check (distance_block_m > 0),
  distance_block_charge numeric(10,2) not null default 0.35 check (distance_block_charge >= 0),
  per_km_charge         numeric(10,2) not null default 1.00 check (per_km_charge >= 0),

  time_mode         text          not null default 'block'
    check (time_mode in ('block','per_minute','per_second','off')),
  time_block_s      integer       not null default 36 check (time_block_s > 0),
  time_block_charge numeric(10,2) not null default 0.35 check (time_block_charge >= 0),
  per_minute_charge numeric(10,2) not null default 0.30 check (per_minute_charge >= 0),
  per_second_charge numeric(10,4) not null default 0 check (per_second_charge >= 0),

  charge_mode text not null default 'max' check (charge_mode in ('max','sum')),
  charge_from text not null default 'flag' check (charge_from in ('flag','start')),

  -- Night shift
  night_multiplier numeric(6,3) not null default 1.5 check (night_multiplier >= 1),
  night_start_hour smallint     not null default 0 check (night_start_hour between 0 and 23),
  night_end_hour   smallint     not null default 6 check (night_end_hour between 0 and 24),

  -- Extras the meter cannot measure
  extra_luggage_charge   numeric(10,2) not null default 0 check (extra_luggage_charge >= 0),
  free_luggage           smallint      not null default 0 check (free_luggage >= 0),
  extra_passenger_charge numeric(10,2) not null default 0 check (extra_passenger_charge >= 0),
  free_passengers        smallint      not null default 1 check (free_passengers >= 0),
  extra_step             numeric(10,2) not null default 0.50 check (extra_step > 0),
  max_extra              numeric(10,2) not null default 99.50 check (max_extra >= 0),

  active     boolean     not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 0084/0085/0086: added after the table shipped, so an existing project picks
-- them up here. Each defaults to what the console did before it existed.
alter table public.meter_digital_settings
  add column if not exists auto_launch boolean not null default false,
  add column if not exists leave_passenger_action text not null default 'passenger',
  add column if not exists leave_ehailing_action  text not null default 'app',
  add column if not exists leave_ehailing_url     text,
  add column if not exists leave_ehailing_label   text,
  add column if not exists leave_ehailing_app_id        text,
  add column if not exists leave_ehailing_store_ios     text,
  add column if not exists leave_ehailing_store_android text,
  add column if not exists leave_ehailing_store_huawei  text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'meter_digital_settings_leave_passenger_action_check'
  ) then
    alter table public.meter_digital_settings
      add constraint meter_digital_settings_leave_passenger_action_check
      check (leave_passenger_action in ('passenger','exit'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'meter_digital_settings_leave_ehailing_action_check'
  ) then
    alter table public.meter_digital_settings
      add constraint meter_digital_settings_leave_ehailing_action_check
      check (leave_ehailing_action in ('app','link'));
  end if;
end $$;

create unique index if not exists meter_digital_settings_scope_uidx
  on public.meter_digital_settings (
    level,
    coalesce(lower(country), ''),
    coalesce(lower(state), ''),
    coalesce(lower(city), ''),
    coalesce(lower(suburb), '')
  );

create index if not exists meter_digital_settings_level_idx
  on public.meter_digital_settings(level);

do $$
begin
  drop trigger if exists trg_meter_digital_settings_updated_at on public.meter_digital_settings;
  create trigger trg_meter_digital_settings_updated_at
    before update on public.meter_digital_settings
    for each row execute function public.set_updated_at();
end$$;

alter table public.meter_digital_settings enable row level security;

drop policy if exists "meter_digital_settings read"         on public.meter_digital_settings;
drop policy if exists "meter_digital_settings admin insert" on public.meter_digital_settings;
drop policy if exists "meter_digital_settings admin update" on public.meter_digital_settings;
drop policy if exists "meter_digital_settings admin delete" on public.meter_digital_settings;

create policy "meter_digital_settings read" on public.meter_digital_settings
  for select using (true);

create policy "meter_digital_settings admin insert" on public.meter_digital_settings
  for insert to public with check (public.caller_is_admin());

create policy "meter_digital_settings admin update" on public.meter_digital_settings
  for update to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());

create policy "meter_digital_settings admin delete" on public.meter_digital_settings
  for delete to public using (public.caller_is_admin());

grant select on public.meter_digital_settings to anon, authenticated;
grant insert, update, delete on public.meter_digital_settings to authenticated;

-- The master card seeds to the TEKSI "old rates" tariff the meter has always
-- billed on, so a fresh database changes no fare.
insert into public.meter_digital_settings (level, label)
  select 'master', 'Global (TEKSI old rates)'
 where not exists (
   select 1 from public.meter_digital_settings where level = 'master'
 );

-- Realtime: the console panels of a card apply live — the admin Show / Tap
-- switches write through without a Save — so a change has to reach the drivers'
-- meters on its own (migrations/0082_meter_digital_settings_realtime.sql).
alter table public.meter_digital_settings replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.meter_digital_settings;
exception
  when duplicate_object then null;
end$$;

-- ---------------------------------------------------------------------------
-- 0087: profiles admin write + protected-column guard
-- (canonical copy of migrations/0087_profiles_admin_write_and_column_guard.sql)
-- ---------------------------------------------------------------------------
-- ---- Policies ---------------------------------------------------------------

drop policy if exists "profiles self write" on public.profiles;
create policy "profiles self write"
  on public.profiles for update to public
  using (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists "profiles admin update" on public.profiles;
create policy "profiles admin update"
  on public.profiles for update to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());

drop policy if exists "profiles admin delete" on public.profiles;
create policy "profiles admin delete"
  on public.profiles for delete to public
  using (public.caller_is_admin());

-- ---- Column guard -------------------------------------------------------------

create or replace function public.profiles_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- Only direct client requests are restricted. SECURITY DEFINER functions
  -- and server-side sessions (setup scripts, the service role's own
  -- connection role) run under other roles and pass through.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if public.caller_is_admin() then
    return new;
  end if;

  -- jsonb comparison: a column missing on an older schema reads as null on
  -- both sides, so the guard stays safe to apply anywhere.
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id',
    'phone',
    'status',
    'profile_status',
    'id_verified',
    'id_expiry_date',
    'documents_ok',
    'total_rides',
    'display_id',
    'referral_code',
    'device_count',
    'joined_at',
    'created_at',
    'pin_hash',
    'pin_failed_attempts',
    'pin_locked_until',
    'mcash_wallet_id',
    'mcash_ekyc_status',
    'mcash_customer_status'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PROFILE_PROTECTED_COLUMN:%', v_col
        using errcode = '42501',
              hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$$;

comment on function public.profiles_guard_protected_columns() is
  'Rejects non-admin client changes to protected profile columns (status, verification, PIN lockout, phone, ids). See migration 0087.';

drop trigger if exists trg_profiles_a_guard on public.profiles;
create trigger trg_profiles_a_guard
  before update on public.profiles
  for each row execute function public.profiles_guard_protected_columns();

-- ---------------------------------------------------------------------------
-- 0032 + 0033: daily document expiry
-- (canonical copy of migrations/0032_documents_daily_expire.sql and
--  migrations/0033_documents_daily_expire_job.sql)
--
-- Flips documents whose expiry date has passed to 'Expired' across
-- provider_documents, vehicle_documents and profiles (user IDs), daily at
-- 00:00 UTC via pg_cron.
--
-- The new enum label must be committed before SQL can use it. That holds here
-- because setup.sh runs this file with plain `psql -f` (one transaction per
-- statement), and the function body is plpgsql, which is only checked when it
-- runs. Unlike 0033, this file doesn't run the function once at the end: a
-- fresh project has no documents to catch up on.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_enum e on e.enumtypid = t.oid
    where t.typname = 'id_verification_status' and e.enumlabel = 'Expired'
  ) then
    alter type id_verification_status add value 'Expired';
  end if;
end$$;

alter table public.profiles
  add column if not exists id_expiry_date date;

create index if not exists profiles_id_expiry_idx
  on public.profiles(id_expiry_date);

create or replace function public.expire_documents_daily()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- provider_documents
  update public.provider_documents
     set status = 'Expired'
   where expiry_date is not null
     and expiry_date < current_date
     and status not in ('Expired', 'Rejected');

  -- vehicle_documents
  update public.vehicle_documents
     set status = 'Expired'
   where expiry_date is not null
     and expiry_date < current_date
     and status not in ('Expired', 'Rejected');

  -- profiles (user IDs)
  update public.profiles
     set id_verified = 'Expired'
   where id_expiry_date is not null
     and id_expiry_date < current_date
     and (id_verified is null or id_verified::text not in ('Expired', 'Failed'));
end;
$$;

grant execute on function public.expire_documents_daily() to anon, authenticated, service_role;

-- Schedule daily at 00:00 UTC. Unlike 0033, the extension is created inside
-- the guarded block, so a Postgres without pg_cron (local or self-hosted)
-- gets a notice instead of aborting the whole schema run under
-- ON_ERROR_STOP.
do $$
declare
  existing_jobid bigint;
begin
  create extension if not exists pg_cron;

  select jobid into existing_jobid
    from cron.job
   where jobname = 'expire-documents-daily';

  if existing_jobid is not null then
    perform cron.unschedule(existing_jobid);
  end if;

  perform cron.schedule(
    'expire-documents-daily',
    '0 0 * * *',
    $cmd$ select public.expire_documents_daily(); $cmd$
  );
exception
  when undefined_table or undefined_file or feature_not_supported or insufficient_privilege then
    raise notice 'pg_cron not available, so the daily job is not scheduled. Call public.expire_documents_daily() from a scheduled job instead.';
end$$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 0088: partner / vehicle / document approval guards, approved-only ride claims
-- (canonical copy of migrations/0088_partner_approval_guard.sql)
-- ---------------------------------------------------------------------------
-- ---- 1. Approved-partner check + ride claiming ------------------------------

create or replace function public.caller_is_approved_partner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.partners p
     where p.auth_user_id = auth.uid()
       and (p.status = 'approved' or p.status::text like 'permit-%')
  );
$$;

grant execute on function public.caller_is_approved_partner() to anon, authenticated;

drop policy if exists "ride_requests claim open" on public.ride_requests;
create policy "ride_requests claim open"
  on public.ride_requests for update to public
  using (status = 'open' and auth.uid() is not null)
  with check (
    partner_id = auth.uid()
    and (public.caller_is_approved_partner() or public.caller_is_admin())
  );

-- The policy alone is not enough. Postgres accepts an UPDATE whose new row
-- passes the WITH CHECK of *any* applicable permissive policy, and
-- "ride_requests participant update" checks `partner_id = auth.uid()`, which
-- a claimed row satisfies. So the gate is also enforced by a trigger, which
-- sees every write whichever policy admitted it.
create or replace function public.ride_requests_guard_partner_claim()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.partner_id is not null
     and new.partner_id is distinct from old.partner_id
     and not public.caller_is_approved_partner() then
    raise exception 'RIDE_CLAIM_REQUIRES_APPROVED_PARTNER' using errcode = '42501',
      hint = 'Only partners approved by an administrator can accept or bid on rides.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ride_requests_a_guard_claim on public.ride_requests;
create trigger trg_ride_requests_a_guard_claim
  before update on public.ride_requests
  for each row execute function public.ride_requests_guard_partner_claim();

-- ---- 2a. partners guard -----------------------------------------------------

create or replace function public.partners_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new partner starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'PARTNERS_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    if coalesce(new.rating, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:rating' using errcode = '42501';
    end if;
    if coalesce(new.total_rides, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:total_rides' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id', 'auth_user_id', 'display_id', 'status', 'permit', 'rating',
    'total_rides', 'joined_at', 'created_at'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PARTNERS_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_partners_a_guard on public.partners;
create trigger trg_partners_a_guard
  before insert or update on public.partners
  for each row execute function public.partners_guard_protected_columns();

-- ---- 2b. vehicle guard ------------------------------------------------------

create or replace function public.vehicle_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'VEHICLE_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new vehicle starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'VEHICLE_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array['id', 'display_id', 'status', 'permit', 'joined_at', 'created_at'] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'VEHICLE_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;

  -- Ownership may only be taken over while unset, and only by the caller.
  if new.auth_user_id is distinct from old.auth_user_id
     and not (old.auth_user_id is null and new.auth_user_id = auth.uid()) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:auth_user_id' using errcode = '42501';
  end if;
  if new.owner_partner_id is distinct from old.owner_partner_id
     and not (
       old.owner_partner_id is null
       and exists (
         select 1 from public.partners p
          where p.id = new.owner_partner_id and p.auth_user_id = auth.uid()
       )
     ) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:owner_partner_id' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_vehicle_a_guard on public.vehicle;
create trigger trg_vehicle_a_guard
  before insert or update on public.vehicle
  for each row execute function public.vehicle_guard_protected_columns();

-- ---- 2c. document guards (provider_documents, vehicle_documents) ----------

create or replace function public.documents_guard_review_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
  v_tag text := upper(tg_table_name) || '_PROTECTED_COLUMN';
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'Pending Review' then
      raise exception '%:status', v_tag using errcode = '42501',
        hint = 'A new document starts in Pending Review; an administrator reviews it.';
    end if;
    if new.reviewer_notes is not null or new.reviewed_at is not null then
      raise exception '%:reviewer_notes', v_tag using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);

  -- Ownership never moves from the client.
  foreach v_col in array array['id', 'auth_user_id', 'partner_id', 'vehicle_id'] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception '%:%', v_tag, v_col using errcode = '42501';
    end if;
  end loop;

  -- Reviewer fields belong to the admin; the owner may only clear them.
  if new.reviewer_notes is distinct from old.reviewer_notes and new.reviewer_notes is not null then
    raise exception '%:reviewer_notes', v_tag using errcode = '42501';
  end if;
  if new.reviewed_at is distinct from old.reviewed_at and new.reviewed_at is not null then
    raise exception '%:reviewed_at', v_tag using errcode = '42501';
  end if;

  -- The owner may only send a document (back) to review, never decide it.
  if new.status is distinct from old.status and new.status is distinct from 'Pending Review' then
    raise exception '%:status', v_tag using errcode = '42501',
      hint = 'Only an administrator can approve or reject a document.';
  end if;

  -- Changing the document itself always needs a fresh review.
  foreach v_col in array array[
    'file_url', 'file_url_back', 'document_number', 'start_date', 'expiry_date',
    'doc_id', 'doc_name', 'issuance_country', 'insurance_provider_id',
    'insurance_provider_name', 'is_pwd'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      new.status := 'Pending Review';
      new.reviewer_notes := null;
      new.reviewed_at := null;
      exit;
    end if;
  end loop;
  return new;
end;
$$;

-- `*_a_guard` sorts before the existing `*_expiry` triggers.
drop trigger if exists provider_documents_a_guard on public.provider_documents;
create trigger provider_documents_a_guard
  before insert or update on public.provider_documents
  for each row execute function public.documents_guard_review_columns();

drop trigger if exists vehicle_documents_a_guard on public.vehicle_documents;
create trigger vehicle_documents_a_guard
  before insert or update on public.vehicle_documents
  for each row execute function public.documents_guard_review_columns();

-- ---- 3. partners: own-or-admin reads + narrow lookups ----------------------

drop policy if exists "partners read" on public.partners;
drop policy if exists "partners self select" on public.partners;
create policy "partners self select"
  on public.partners for select to public
  using (auth_user_id = auth.uid() or public.caller_is_admin());

create or replace function public.claim_partner_by_phone()
returns setof public.partners
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_digits text;
  v_count  bigint;
  v_id     uuid;
begin
  if v_uid is null then
    return;
  end if;

  -- Already linked: return the caller's own row.
  if exists (select 1 from public.partners where auth_user_id = v_uid) then
    return query select * from public.partners where auth_user_id = v_uid limit 1;
    return;
  end if;

  -- Match on the verified sign-in phone, not anything the client sends.
  select regexp_replace(coalesce(u.phone, ''), '\D', '', 'g')
    into v_digits
    from auth.users u
   where u.id = v_uid;
  if v_digits is null or length(v_digits) < 8 then
    return;
  end if;

  -- Link only when exactly one unclaimed row matches.
  select count(*), min(p.id::text)::uuid
    into v_count, v_id
    from public.partners p
   where p.auth_user_id is null
     and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') = v_digits;
  if v_count <> 1 then
    return;
  end if;

  return query
    update public.partners
       set auth_user_id = v_uid
     where id = v_id and auth_user_id is null
    returning *;
end;
$$;

revoke all on function public.claim_partner_by_phone() from public, anon;
grant execute on function public.claim_partner_by_phone() to authenticated;

create or replace function public.partner_ic_for_my_vehicle(p_partner_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.ic
    from public.partners p
   where p.id = p_partner_id
     and (
       public.caller_is_admin()
       or p.auth_user_id = auth.uid()
       or exists (
         select 1
           from public.vehicle v
          where v.owner_partner_id = p_partner_id
            and (
              v.auth_user_id = auth.uid()
              or exists (
                select 1 from public.vehicle_user_assignment a
                 where a.vehicle_id = v.id and a.user_id = auth.uid()
              )
            )
       )
     );
$$;

revoke all on function public.partner_ic_for_my_vehicle(uuid) from public, anon;
grant execute on function public.partner_ic_for_my_vehicle(uuid) to authenticated;

-- ---- 4. Legacy `vehicles`: admin-only --------------------------------------

drop policy if exists "vehicles read" on public.vehicles;
drop policy if exists "vehicles insert" on public.vehicles;
drop policy if exists "vehicles update" on public.vehicles;
drop policy if exists "vehicles delete" on public.vehicles;
drop policy if exists "vehicles admin all" on public.vehicles;
create policy "vehicles admin all"
  on public.vehicles for all to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());
revoke all on public.vehicles from anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 00891: wallet_transfer_requests readable by participants and admins only
-- (canonical copy of migrations/00891_wallet_transfer_requests_participant_rls.sql)
-- ---------------------------------------------------------------------------
-- 0065 shipped a `using (true)` select policy plus an anon grant, so anyone
-- with the anon key could list (and subscribe over realtime to) every P2P
-- transfer. Writes stay in the SECURITY DEFINER RPCs; realtime applies this
-- policy per subscriber, so both parties' channels keep working.

drop policy if exists "wallet_transfer_requests read" on public.wallet_transfer_requests;
create policy "wallet_transfer_requests read"
  on public.wallet_transfer_requests for select
  using (
    from_user_id = auth.uid()
    or to_user_id = auth.uid()
    or public.caller_is_admin()
  );

revoke select on public.wallet_transfer_requests from anon;
grant select on public.wallet_transfer_requests to authenticated;


-- ---- Ride stops (0098) and driver-declared charges (0100) -------------------

alter table public.ride_requests
  add column if not exists stops jsonb not null default '[]'::jsonb;

alter table public.ride_requests
  add column if not exists other_charges_note text;

alter table public.ride_requests drop constraint if exists ride_requests_charges_range;
alter table public.ride_requests
  add constraint ride_requests_charges_range check (
    (toll_charges is null or (toll_charges >= 0 and toll_charges <= 10000))
    and (other_charges is null or (other_charges >= 0 and other_charges <= 10000))
    and (other_charges_note is null or char_length(other_charges_note) <= 200)
  ) not valid;

create or replace function public.ride_requests_guard_charges()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if coalesce(new.toll_charges, 0) <> 0
       or coalesce(new.other_charges, 0) <> 0
       or new.other_charges_note is not null then
      raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
        hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
    end if;
    return new;
  end if;
  if (new.toll_charges, new.other_charges, new.other_charges_note)
       is distinct from (old.toll_charges, old.other_charges, old.other_charges_note)
     and (old.partner_id is null or old.partner_id is distinct from auth.uid()) then
    raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
      hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ride_requests_b_guard_charges on public.ride_requests;
create trigger trg_ride_requests_b_guard_charges
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_charges();


-- ---- GET.coin fare payout to the driver (0101) ------------------------------

alter table public.ride_requests
  add column if not exists fare_coins_value numeric(10,2),
  add column if not exists fare_coins_used numeric(12,2);

create or replace function public.wallet_redeem_fare_coins(
  p_user uuid,
  p_fare numeric,
  p_ride uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric := round(coalesce(p_fare, 0), 2);
  v_due numeric;
  v_rate numeric;
  v_coin_balance numeric := 0;
  v_max_coin_value numeric := 0;
  v_coin_value numeric := 0;
  v_coins_used numeric := 0;
begin
  perform public.wallet_assert_caller(p_user);
  if v_fare <= 0 or v_fare > 10000 then
    raise exception 'invalid_amount';
  end if;

  select coins_per_currency into v_rate
  from public.get_coin_settings where id = 'master';
  if coalesce(v_rate, 0) <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  if p_ride is not null then
    select * into r from public.ride_requests where id = p_ride for update;
    if found then
      if r.rider_id is not null and r.rider_id <> p_user then
        raise exception 'not_authorized';
      end if;
      if r.status <> 'completed' then
        raise exception 'ride_not_completed';
      end if;
      if r.fare_coins_redeemed_at is not null then
        return jsonb_build_object('coins_used', 0, 'coin_value', 0);
      end if;
      v_due := round(coalesce(r.ride_fare, r.fare, 0)
                     + coalesce(r.toll_charges, 0)
                     + coalesce(r.other_charges, 0), 2);
      v_fare := least(v_fare, v_due);
      update public.ride_requests
         set fare_coins_redeemed_at = now()
       where id = p_ride;
    end if;
  end if;

  if v_fare <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_user, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_coin_balance
  from public.wallets
  where user_id = p_user and wallet_type = 'get_coin'
  for update;
  v_coin_balance := coalesce(v_coin_balance, 0);

  if v_coin_balance > 0 then
    v_max_coin_value := floor((v_coin_balance / v_rate) * 100) / 100;
    v_coin_value := least(v_max_coin_value, v_fare);
    v_coins_used := round(v_coin_value * v_rate, 2);
  end if;

  if v_coins_used <= 0 then
    return jsonb_build_object('coins_used', 0, 'coin_value', 0);
  end if;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, method, note)
  values
    (p_user, 'get_coin', 'redeem', -v_coins_used, 'ride_fare',
     'Ride fare — RM' || to_char(v_coin_value, 'FM999999990.00') || ' paid with coins');

  if r.id is not null then
    update public.ride_requests
       set fare_coins_value = v_coin_value,
           fare_coins_used = v_coins_used
     where id = r.id;
    if r.partner_id is not null then
      insert into public.wallet_transactions
        (user_id, wallet_type, kind, amount, method, note)
      values
        (r.partner_id, 'get_wallet', 'ride_coin_payout', v_coin_value, 'ride_fare',
         'Ride fare paid with GET.coin — RM' || to_char(v_coin_value, 'FM999999990.00'));
    end if;
  end if;

  return jsonb_build_object('coins_used', v_coins_used, 'coin_value', v_coin_value);
end;
$$;

grant execute on function public.wallet_redeem_fare_coins(uuid, numeric, uuid) to anon, authenticated;

-- 0100's guard, extended to the coin columns: no client sets them.
create or replace function public.ride_requests_guard_charges()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if coalesce(new.toll_charges, 0) <> 0
       or coalesce(new.other_charges, 0) <> 0
       or new.other_charges_note is not null then
      raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
        hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
    end if;
    if new.fare_coins_value is not null or new.fare_coins_used is not null then
      raise exception 'RIDE_FARE_COINS_SERVER_ONLY' using errcode = '42501';
    end if;
    return new;
  end if;
  if (new.toll_charges, new.other_charges, new.other_charges_note)
       is distinct from (old.toll_charges, old.other_charges, old.other_charges_note)
     and (old.partner_id is null or old.partner_id is distinct from auth.uid()) then
    raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
      hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
  end if;
  if (new.fare_coins_value, new.fare_coins_used) is distinct from (old.fare_coins_value, old.fare_coins_used) then
    raise exception 'RIDE_FARE_COINS_SERVER_ONLY' using errcode = '42501';
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
