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
