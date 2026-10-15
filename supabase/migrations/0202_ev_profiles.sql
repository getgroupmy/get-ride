-- ============================================================================
-- 0202 · EV support for the OBD-II reader.
--
-- Most electric cars answer nothing on standard OBD-II (mode 01/09): their
-- battery, range and odometer sit behind maker-specific requests to one ECU.
-- Those requests are not published, so nothing is guessed here: admins build
-- an `ev_profiles` row from real captures that drivers record with
-- "Record for support" on the OBD-II reader page (`obd_captures`).
--
--   ev_profiles.init    ["ATSP6", "ATSH7E4", "1003"]   AT setup or hex requests, in order
--   ev_profiles.detect  {request: "22F190", header?: "7E4", expect?: "62F190"}
--   ev_profiles.signals [{key: "soc", header: "7E4", request: "220105", reply?: "620105",
--                         start: 4, length: 1, signed: false, scale: 0.5, offset: 0,
--                         unit: "%", bit?: 0..7}]
--
-- `start` counts bytes after the reply prefix (by default the positive
-- response: 0x40 + service, then the echoed identifier); the raw value is
-- big-endian, two's complement when signed, then × scale + offset. `bit`
-- reads one bit of the first byte instead (a charging flag).
--
-- The app reads the active profiles through ev_profiles_for_app(), keeps
-- them on the device for use offline, and follows the table live.
-- ============================================================================

-- ---- Validation -----------------------------------------------------------------------------
-- What is wrong with a profile's init, detect and signals, one line each;
-- empty when nothing is.
create or replace function public.ev_profile_problems(p_init jsonb, p_detect jsonb, p_signals jsonb, p_active boolean)
returns text[]
language plpgsql
immutable
set search_path = public
as $$
declare
  keys text[] := array['soc', 'range_km', 'odometer_km', 'soh', 'aux_voltage', 'charging', 'speed_kmh',
                       'battery_temp_c', 'hv_voltage', 'hv_current'];
  hex_request text := '^([0-9A-F]{2}){1,8}$';
  hex_prefix  text := '^([0-9A-F]{2}){1,16}$';
  can_header  text := '^([0-9A-F]{3}|[0-9A-F]{8})$';
  problems text[] := '{}';
  e jsonb;
  i int := 0;
begin
  -- init: AT setup commands or hex requests.
  if p_init is not null and jsonb_typeof(p_init) <> 'array' then
    problems := problems || 'init must be a list of commands'::text;
  elsif p_init is not null then
    if jsonb_array_length(p_init) > 20 then problems := problems || 'init: at most 20 commands'::text; end if;
    for e in select value from jsonb_array_elements(p_init) loop
      if jsonb_typeof(e) <> 'string' or not (e #>> '{}' ~ '^AT[A-Z0-9 ]{1,20}$' or e #>> '{}' ~ hex_request) then
        problems := problems || format('init: %s is not an AT command or a hex request', e);
      end if;
    end loop;
  end if;

  -- detect: one request that only this car answers as expected.
  if p_detect is not null and jsonb_typeof(p_detect) <> 'null' then
    if jsonb_typeof(p_detect) <> 'object' then
      problems := problems || 'detect must be an object'::text;
    else
      if coalesce(p_detect->>'request', '') !~ hex_request then
        problems := problems || 'detect: request must be hex, e.g. 22F190'::text;
      end if;
      if p_detect ? 'header' and jsonb_typeof(p_detect->'header') <> 'null'
         and coalesce(p_detect->>'header', '') !~ can_header then
        problems := problems || 'detect: header must be a CAN id such as 7E4 or 18DADBF1'::text;
      end if;
      if p_detect ? 'expect' and jsonb_typeof(p_detect->'expect') <> 'null'
         and coalesce(p_detect->>'expect', '') !~ hex_prefix then
        problems := problems || 'detect: expect must be a hex prefix'::text;
      end if;
    end if;
  elsif coalesce(p_active, false) then
    problems := problems || 'an active profile needs a detect request'::text;
  end if;

  -- signals.
  if p_signals is null or jsonb_typeof(p_signals) <> 'array' then
    problems := problems || 'signals must be a list'::text;
  else
    if jsonb_array_length(p_signals) > 40 then problems := problems || 'signals: at most 40'::text; end if;
    if coalesce(p_active, false) and jsonb_array_length(p_signals) = 0 then
      problems := problems || 'an active profile needs at least one signal'::text;
    end if;
    for e in select value from jsonb_array_elements(p_signals) loop
      i := i + 1;
      if jsonb_typeof(e) <> 'object' then
        problems := problems || format('signal %s is not an object', i);
        continue;
      end if;
      if not coalesce(e->>'key', '') = any(keys) then
        problems := problems || format('signal %s: unknown key %s', i, coalesce(e->>'key', 'none'));
      end if;
      if coalesce(e->>'header', '') !~ can_header then
        problems := problems || format('signal %s: header must be a CAN id such as 7E4 or 18DADBF1', i);
      end if;
      if coalesce(e->>'request', '') !~ hex_request then
        problems := problems || format('signal %s: request must be hex, e.g. 220105', i);
      end if;
      if e ? 'reply' and jsonb_typeof(e->'reply') <> 'null' and coalesce(e->>'reply', '') !~ hex_prefix then
        problems := problems || format('signal %s: reply must be a hex prefix', i);
      end if;
      if (case when jsonb_typeof(e->'start') = 'number'
              then (e->>'start')::numeric not between 0 and 255
                   or (e->>'start')::numeric <> trunc((e->>'start')::numeric)
              else true end) then
        problems := problems || format('signal %s: start must be a byte number from 0 to 255', i);
      end if;
      if (case when jsonb_typeof(e->'length') = 'number' then (e->>'length')::numeric not in (1, 2, 3, 4)
              else true end) then
        problems := problems || format('signal %s: length must be 1 to 4 bytes', i);
      end if;
      if e ? 'signed' and jsonb_typeof(e->'signed') not in ('boolean', 'null') then
        problems := problems || format('signal %s: signed must be true or false', i);
      end if;
      if e ? 'scale' and jsonb_typeof(e->'scale') not in ('number', 'null') then
        problems := problems || format('signal %s: scale must be a number', i);
      end if;
      if e ? 'offset' and jsonb_typeof(e->'offset') not in ('number', 'null') then
        problems := problems || format('signal %s: offset must be a number', i);
      end if;
      if e ? 'unit' and jsonb_typeof(e->'unit') not in ('string', 'null') or length(coalesce(e->>'unit', '')) > 12 then
        problems := problems || format('signal %s: unit must be short text', i);
      end if;
      if (case when coalesce(jsonb_typeof(e->'bit'), 'null') = 'null' then false
              when jsonb_typeof(e->'bit') = 'number' then (e->>'bit')::numeric not in (0, 1, 2, 3, 4, 5, 6, 7)
              else true end) then
        problems := problems || format('signal %s: bit must be 0 to 7', i);
      end if;
    end loop;
  end if;
  return problems;
end;
$$;

-- ---- Profiles ---------------------------------------------------------------------------------
create table if not exists public.ev_profiles (
  id         uuid primary key default gen_random_uuid(),
  make       text not null check (length(btrim(make)) between 1 and 60),
  model      text not null check (length(btrim(model)) between 1 and 80),
  years      text check (years is null or length(years) <= 20),
  label      text check (label is null or length(label) <= 120),
  active     boolean not null default false,
  verified   boolean not null default false,
  init       jsonb not null default '[]'::jsonb,
  detect     jsonb,
  signals    jsonb not null default '[]'::jsonb,
  notes      text check (notes is null or length(notes) <= 4000),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create index if not exists ev_profiles_active_idx on public.ev_profiles (make, model) where active;

create or replace function public.ev_profiles_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  problems text[];
begin
  problems := public.ev_profile_problems(new.init, new.detect, new.signals, new.active);
  if cardinality(problems) > 0 then
    raise exception 'EV profile: %', array_to_string(problems, '; ') using errcode = '22023';
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end;
$$;
drop trigger if exists ev_profiles_before_write on public.ev_profiles;
create trigger ev_profiles_before_write before insert or update on public.ev_profiles
  for each row execute function public.ev_profiles_before_write();

alter table public.ev_profiles enable row level security;
revoke all on public.ev_profiles from anon, authenticated;
grant select, insert, update, delete on public.ev_profiles to authenticated;

drop policy if exists "ev_profiles read" on public.ev_profiles;
create policy "ev_profiles read" on public.ev_profiles
  for select to authenticated
  using (active or (select public.caller_is_admin()));
drop policy if exists "ev_profiles admin insert" on public.ev_profiles;
create policy "ev_profiles admin insert" on public.ev_profiles
  for insert to authenticated
  with check ((select public.caller_is_admin()));
drop policy if exists "ev_profiles admin update" on public.ev_profiles;
create policy "ev_profiles admin update" on public.ev_profiles
  for update to authenticated
  using ((select public.caller_is_admin()))
  with check ((select public.caller_is_admin()));
drop policy if exists "ev_profiles admin delete" on public.ev_profiles;
create policy "ev_profiles admin delete" on public.ev_profiles
  for delete to authenticated
  using ((select public.caller_is_admin()));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'ev_profiles') then
    alter publication supabase_realtime add table public.ev_profiles;
  end if;
end $$;

-- The active profiles, as the app reads them.
create or replace function public.ev_profiles_for_app()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'make', p.make, 'model', p.model, 'years', p.years, 'label', p.label,
           'active', p.active, 'verified', p.verified, 'init', p.init, 'detect', p.detect,
           'signals', p.signals, 'updated_at', p.updated_at)
           order by p.make, p.model, p.years), '[]'::jsonb)
    from public.ev_profiles p
   where p.active;
$$;
revoke execute on function public.ev_profiles_for_app() from public, anon;
grant execute on function public.ev_profiles_for_app() to authenticated;

-- ---- Captures ---------------------------------------------------------------------------------
-- What a driver's reader answered to the generic capture script, for an
-- admin to build a profile from: [{header, request, reply, ms}].
create table if not exists public.obd_captures (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  vehicle      text not null check (length(btrim(vehicle)) between 1 and 120),
  battery_hint text check (battery_hint is null or length(battery_hint) <= 20),
  reader       text check (reader is null or length(reader) <= 120),
  app_version  text check (app_version is null or length(app_version) <= 40),
  entries      jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  constraint obd_captures_entries_list check (jsonb_typeof(entries) = 'array'),
  constraint obd_captures_entries_size check (jsonb_array_length(entries) <= 2000),
  constraint obd_captures_entries_bytes check (octet_length(entries::text) <= 1000000)
);
create index if not exists obd_captures_created_idx on public.obd_captures (created_at desc);
create index if not exists obd_captures_profile_idx on public.obd_captures (profile_id);

alter table public.obd_captures enable row level security;
revoke all on public.obd_captures from anon, authenticated;
grant select, insert, delete on public.obd_captures to authenticated;

drop policy if exists "obd_captures insert own" on public.obd_captures;
create policy "obd_captures insert own" on public.obd_captures
  for insert to authenticated
  with check (profile_id = (select auth.uid()));
drop policy if exists "obd_captures read" on public.obd_captures;
create policy "obd_captures read" on public.obd_captures
  for select to authenticated
  using (profile_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "obd_captures admin delete" on public.obd_captures;
create policy "obd_captures admin delete" on public.obd_captures
  for delete to authenticated
  using ((select public.caller_is_admin()));
