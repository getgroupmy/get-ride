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
