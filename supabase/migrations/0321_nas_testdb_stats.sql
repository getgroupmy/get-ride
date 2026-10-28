-- ============================================================================
-- 0321 — Office NAS: a test copy of the database, and visitor stats
-- (docs/NAS.md items 5 and 6; Admin › Settings › Office NAS, tabs
-- "Test database" and "Visitor stats").
--
-- Version 20261028140000 (0321_nas_testdb_stats). Re-runnable: tables and
-- indexes "if not exists", functions "create or replace", policies dropped
-- first.
--
-- 1. nas_services: one row per service on the office NAS (backups, maps,
--    uptime, test database, visitor stats …) with when it was last heard
--    from, a status word and a few details for Admin › Office NAS ›
--    Overview. Shared with the other NAS services: the same columns,
--    "create table if not exists". Written by the edge functions with the
--    service role; admins read it through admin_office_nas_services().
-- 2. The test database runner (deploy/nas-testdb) pairs like the document
--    reader (0293): a full admin makes a code good for 10 minutes, the NAS
--    trades it once for a key of its own, only the key's hash is kept. It
--    only calls out (the nas-testdb edge function); no port is opened.
--    Full admins only: the runner holds a read-only connection to the live
--    database.
-- 3. app_settings 'nas_testdb': {refreshAt: "HH:MM" (office time, default
--    02:30), scramble: true}. Anyone with EDIT on admin-settings-office-nas
--    sets the time; turning the scrambling of personal data OFF is for full
--    admins only (turning it back on is for anyone who may edit the page).
-- 4. testdb_runs: every refresh of the copy and every migration tried on it,
--    with pass / fail, the error, how long it took and what was tried.
--    admin_testdb_try(pr, branch) queues "try the migrations of PR #n" (or
--    of a branch); the NAS claims it, fetches the PR's migration files from
--    GitHub read-only, applies them to a throw-away copy of last night's
--    copy and reports back. admin_testdb_refresh() asks for a fresh copy
--    now instead of at the nightly time. Queued runs can be cancelled.
-- 5. app_settings 'nas_stats': {on: true, websiteId: "<Umami website id>"}
--    for the nas-stats edge function, which reads today's numbers from
--    Umami on the NAS (stats.getride.my, through a Cloudflare Tunnel) with
--    the key kept in Admin › API Keys › Umami. The site's tracking script
--    is switched on at build time (web/stats.js), not here.
--
-- Admin pages: admin-settings-office-nas (full admins, and grantable to
-- sub-admins: READ shows the tabs, EDIT changes the time and tries
-- migrations). Not region rules: the NAS is one box at the office, so a
-- per-country / state / city rule has nothing to act on here.
-- ============================================================================

-- ---- 1. NAS service heartbeat (shared) -----------------------------------------------------
create table if not exists public.nas_services (
  service   text primary key,
  last_seen timestamptz,
  status    text,
  detail    jsonb,
  version   text
);
alter table public.nas_services enable row level security;
revoke all on public.nas_services from anon, authenticated;
-- Admins read it through 0318's policy (the Office NAS page's status).
grant select on public.nas_services to authenticated;

-- ---- Who may see and change these tabs -----------------------------------------------------
-- Full admins; else a grant on the Office NAS page (or the Settings hub
-- grant, which covers every settings page), EDIT when p_edit.
create or replace function public.testdb_stats_admin_ok(p_edit boolean default false)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (select auth.uid()) is not null and (
    public.caller_is_full_admin()
    or exists (
      select 1 from public.admin_access a
       where a.profile_id = (select auth.uid())
         and a.page in ('*', 'admin-settings-office-nas', 'admin-settings')
         and (not p_edit or a.access_level = 'edit')));
$$;
revoke execute on function public.testdb_stats_admin_ok(boolean) from public, anon;
grant execute on function public.testdb_stats_admin_ok(boolean) to authenticated, service_role;

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_testdb_set', 'admin-settings-office-nas'),
  ('rpc:admin_testdb_try', 'admin-settings-office-nas'),
  ('rpc:admin_testdb_refresh', 'admin-settings-office-nas'),
  ('rpc:admin_testdb_cancel', 'admin-settings-office-nas'),
  ('rpc:admin_nas_stats_set', 'admin-settings-office-nas')
on conflict do nothing;

-- Every NAS service's last check-in, for the Overview cards.
create or replace function public.admin_office_nas_services()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.testdb_stats_admin_ok(false) then
    raise exception 'Admins with the Office NAS page only.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'service', s.service, 'last_seen', s.last_seen, 'status', s.status,
             'detail', coalesce(s.detail, '{}'::jsonb), 'version', s.version)
           order by s.service)
      from public.nas_services s), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_office_nas_services() from public, anon;
grant execute on function public.admin_office_nas_services() to authenticated;

-- ---- 3. Test database settings -------------------------------------------------------------
create or replace function public.nas_testdb_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_at text := btrim(coalesce(p ->> 'refreshAt', ''));
  v_h int;
  v_m int;
begin
  if v_at ~ '^\d{1,2}:\d{2}$' then
    v_h := split_part(v_at, ':', 1)::int;
    v_m := split_part(v_at, ':', 2)::int;
  end if;
  if v_h is null or v_h > 23 or v_m > 59 then
    v_h := 2;
    v_m := 30;
  end if;
  return jsonb_build_object(
    'refreshAt', lpad(v_h::text, 2, '0') || ':' || lpad(v_m::text, 2, '0'),
    'scramble', coalesce(case when jsonb_typeof(p -> 'scramble') = 'boolean' then (p ->> 'scramble')::boolean end, true));
end;
$$;
revoke execute on function public.nas_testdb_normalize(jsonb) from public, anon, authenticated;

create or replace function public.nas_testdb_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.nas_testdb_normalize(
    coalesce((select value from public.app_settings where key = 'nas_testdb'), '{}'::jsonb));
$$;
revoke execute on function public.nas_testdb_config() from public, anon, authenticated;

create or replace function public.admin_testdb_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.nas_testdb_normalize(coalesce(p, '{}'::jsonb));
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_testdb_set') then
    raise exception 'You can''t change the test database.' using errcode = '42501';
  end if;
  -- The copy is the live database's people: only a full admin keeps them
  -- unscrambled.
  if not (v ->> 'scramble')::boolean and (public.nas_testdb_config() ->> 'scramble')::boolean
     and not public.caller_is_full_admin() then
    raise exception 'Only a full admin can turn off scrambling.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value) values ('nas_testdb', v)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.admin_testdb_set(jsonb) from public, anon;
grant execute on function public.admin_testdb_set(jsonb) to authenticated;

-- ---- 2. The runner, its key and pairing codes ----------------------------------------------
create table if not exists public.testdb_runners (
  id           uuid primary key default gen_random_uuid(),
  label        text not null,
  device_id    text not null unique,
  model        text,
  app_version  text,
  key_hash     text not null unique,
  paired_by    uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  -- What the runner last said about its copy: {refreshed_at, size_bytes,
  -- scrambled, source, next_refresh_at, busy}.
  state        jsonb not null default '{}'::jsonb
);
alter table public.testdb_runners enable row level security;
revoke all on public.testdb_runners from anon, authenticated;

create table if not exists public.testdb_runner_pairings (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,
  label       text,
  created_by  uuid not null references auth.users(id) on delete cascade,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  runner_id   uuid references public.testdb_runners(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.testdb_runner_pairings enable row level security;
revoke all on public.testdb_runner_pairings from anon, authenticated;

create table if not exists public.testdb_pair_failures (
  at timestamptz not null default now()
);
create index if not exists testdb_pair_failures_at_idx on public.testdb_pair_failures (at);
alter table public.testdb_pair_failures enable row level security;
revoke all on public.testdb_pair_failures from anon, authenticated;

-- ---- 4. Runs --------------------------------------------------------------------------------
create table if not exists public.testdb_runs (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('refresh', 'migration')),
  pr_number    integer check (pr_number is null or pr_number > 0),
  branch       text,
  head_sha     text,
  files        text[] not null default '{}',
  status       text not null default 'queued'
               check (status in ('queued', 'running', 'passed', 'failed', 'cancelled')),
  error        text,
  ms           integer,
  detail       jsonb not null default '{}'::jsonb,
  requested_by uuid references auth.users(id) on delete set null,
  runner_id    uuid references public.testdb_runners(id) on delete set null,
  created_at   timestamptz not null default now(),
  started_at   timestamptz,
  finished_at  timestamptz
);
create index if not exists testdb_runs_created_idx on public.testdb_runs (created_at desc);
create index if not exists testdb_runs_waiting_idx on public.testdb_runs (created_at) where status in ('queued', 'running');
alter table public.testdb_runs enable row level security;
revoke all on public.testdb_runs from anon, authenticated;

create or replace function public.testdb_run_json(r public.testdb_runs)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id, 'kind', r.kind, 'pr_number', r.pr_number, 'branch', r.branch, 'head_sha', r.head_sha,
    'files', to_jsonb(r.files), 'status', r.status, 'error', r.error, 'ms', r.ms, 'detail', r.detail,
    'created_at', r.created_at, 'started_at', r.started_at, 'finished_at', r.finished_at);
$$;
revoke execute on function public.testdb_run_json(public.testdb_runs) from public, anon, authenticated;

-- "Try migration from PR #": a PR number, or a branch name when there is no PR.
create or replace function public.admin_testdb_try(p_pr integer default null, p_branch text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch text := nullif(btrim(coalesce(p_branch, '')), '');
  v public.testdb_runs;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_testdb_try') then
    raise exception 'You can''t try migrations on the test database.' using errcode = '42501';
  end if;
  if (p_pr is null) = (v_branch is null) then
    raise exception 'Give a PR number or a branch.' using errcode = '22023';
  end if;
  if p_pr is not null and (p_pr < 1 or p_pr > 99999999) then
    raise exception 'That isn''t a PR number.' using errcode = '22023';
  end if;
  if v_branch is not null and (v_branch !~ '^[A-Za-z0-9._/-]{1,200}$' or v_branch ~ '\.\.' or v_branch ~ '^[/.-]') then
    raise exception 'That isn''t a branch name.' using errcode = '22023';
  end if;
  -- Already waiting for the same PR or branch: that one.
  select * into v from public.testdb_runs
   where kind = 'migration' and status in ('queued', 'running')
     and pr_number is not distinct from p_pr and branch is not distinct from v_branch
   order by created_at limit 1;
  if found then
    return public.testdb_run_json(v);
  end if;
  if (select count(*) from public.testdb_runs where status = 'queued') >= 10 then
    raise exception 'Ten tries are already waiting. Wait for them or cancel one.' using errcode = '54000';
  end if;
  insert into public.testdb_runs (kind, pr_number, branch, requested_by)
  values ('migration', p_pr, v_branch, auth.uid())
  returning * into v;
  return public.testdb_run_json(v);
end;
$$;
revoke execute on function public.admin_testdb_try(integer, text) from public, anon;
grant execute on function public.admin_testdb_try(integer, text) to authenticated;

-- A fresh copy now, instead of waiting for the nightly time.
create or replace function public.admin_testdb_refresh()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.testdb_runs;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_testdb_refresh') then
    raise exception 'You can''t refresh the test database.' using errcode = '42501';
  end if;
  select * into v from public.testdb_runs
   where kind = 'refresh' and status in ('queued', 'running') order by created_at limit 1;
  if not found then
    insert into public.testdb_runs (kind, requested_by) values ('refresh', auth.uid()) returning * into v;
  end if;
  return public.testdb_run_json(v);
end;
$$;
revoke execute on function public.admin_testdb_refresh() from public, anon;
grant execute on function public.admin_testdb_refresh() to authenticated;

create or replace function public.admin_testdb_cancel(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.testdb_runs;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_testdb_cancel') then
    raise exception 'You can''t cancel test database runs.' using errcode = '42501';
  end if;
  update public.testdb_runs set status = 'cancelled', finished_at = clock_timestamp()
   where id = p_id and status = 'queued'
  returning * into v;
  if not found then
    raise exception 'Only a run that hasn''t started can be cancelled.' using errcode = '22023';
  end if;
  return public.testdb_run_json(v);
end;
$$;
revoke execute on function public.admin_testdb_cancel(uuid) from public, anon;
grant execute on function public.admin_testdb_cancel(uuid) to authenticated;

-- The Test database tab: settings, the runner, the last refresh, the last
-- migration tried, what is waiting and the latest runs.
create or replace function public.admin_testdb_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.testdb_stats_admin_ok(false) then
    raise exception 'Admins with the Office NAS page only.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'settings', public.nas_testdb_config(),
    'runners', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'label', r.label, 'model', r.model, 'app_version', r.app_version,
               'created_at', r.created_at, 'last_seen_at', r.last_seen_at, 'state', r.state,
               'online', coalesce(r.last_seen_at > now() - interval '3 minutes', false))
             order by r.created_at)
        from public.testdb_runners r), '[]'::jsonb),
    'last_refresh', (select public.testdb_run_json(x) from public.testdb_runs x
                      where x.kind = 'refresh' and x.status in ('passed', 'failed')
                      order by x.finished_at desc nulls last limit 1),
    'last_migration', (select public.testdb_run_json(x) from public.testdb_runs x
                        where x.kind = 'migration' and x.status in ('passed', 'failed')
                        order by x.finished_at desc nulls last limit 1),
    'waiting', coalesce((select jsonb_agg(public.testdb_run_json(x) order by x.created_at)
                           from public.testdb_runs x where x.status in ('queued', 'running')), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(public.testdb_run_json(x) order by x.created_at desc)
                          from (select * from public.testdb_runs
                                 order by created_at desc limit 15) x), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_testdb_state() from public, anon;
grant execute on function public.admin_testdb_state() to authenticated;

-- ---- The admin pairs and removes the runner ------------------------------------------------
create or replace function public.admin_testdb_pairing_code(p_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(8);
  v_code text := '';
  v_expires timestamptz := now() + interval '10 minutes';
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can connect the test database.' using errcode = '42501';
  end if;
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % length(v_alphabet)), 1);
  end loop;
  delete from public.testdb_runner_pairings where created_by = auth.uid() and used_at is null;
  insert into public.testdb_runner_pairings (code_hash, label, created_by, expires_at)
  values (public.gateway_secret_hash(v_code), nullif(left(btrim(coalesce(p_label, '')), 80), ''), auth.uid(), v_expires);
  return jsonb_build_object('code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4), 'expires_at', v_expires);
end;
$$;
revoke execute on function public.admin_testdb_pairing_code(text) from public, anon;
grant execute on function public.admin_testdb_pairing_code(text) to authenticated;

create or replace function public.admin_testdb_runner_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can disconnect the test database.' using errcode = '42501';
  end if;
  update public.testdb_runs set status = 'queued', runner_id = null, started_at = null
   where runner_id = p_id and status = 'running';
  delete from public.testdb_runners where id = p_id;
end;
$$;
revoke execute on function public.admin_testdb_runner_remove(uuid) from public, anon;
grant execute on function public.admin_testdb_runner_remove(uuid) to authenticated;

-- ---- The runner's calls (through the nas-testdb edge function only) ------------------------
create or replace function public.testdb_pair(
  p_code text, p_device_id text, p_label text default null, p_model text default null,
  p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_pair public.testdb_runner_pairings;
  v_runner public.testdb_runners;
  v_key text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if (select count(*) from public.testdb_pair_failures where at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('error', 'TESTDB_PAIR_BUSY', 'hint', 'Too many wrong codes. Wait 10 minutes and try again.');
  end if;
  if coalesce(btrim(p_device_id), '') = '' then
    return jsonb_build_object('error', 'TESTDB_PAIR_DEVICE', 'hint', 'The runner sent no device id.');
  end if;
  select * into v_pair from public.testdb_runner_pairings
   where code_hash = public.gateway_secret_hash(v_code) and used_at is null and expires_at > now()
   for update;
  if not found then
    insert into public.testdb_pair_failures default values;
    return jsonb_build_object('error', 'TESTDB_PAIR_CODE',
      'hint', 'That code is wrong or has expired. Make a new one in Admin -> Settings -> Office NAS -> Test database.');
  end if;
  insert into public.testdb_runners (label, device_id, model, app_version, key_hash, paired_by, last_seen_at)
  values (coalesce(v_pair.label, nullif(left(btrim(coalesce(p_label, '')), 80), ''), 'Office NAS'),
          left(p_device_id, 200), left(p_model, 120), left(p_app_version, 40),
          public.gateway_secret_hash(v_key), v_pair.created_by, now())
  on conflict (device_id) do update
     set label = coalesce(v_pair.label, public.testdb_runners.label),
         model = coalesce(excluded.model, public.testdb_runners.model),
         app_version = excluded.app_version,
         key_hash = excluded.key_hash,
         paired_by = excluded.paired_by,
         last_seen_at = now()
  returning * into v_runner;
  update public.testdb_runner_pairings set used_at = now(), runner_id = v_runner.id where id = v_pair.id;
  return jsonb_build_object('key', v_key, 'runner', v_runner.id, 'label', v_runner.label);
end;
$$;

create or replace function public.testdb_runner_by_key(p_key text)
returns public.testdb_runners
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.testdb_runners;
begin
  update public.testdb_runners set last_seen_at = now()
   where key_hash = public.gateway_secret_hash(p_key)
  returning * into v;
  if not found then
    raise exception 'TESTDB_KEY_INVALID' using errcode = '42501',
      hint = 'This runner is no longer connected. Connect it again from Admin -> Settings -> Office NAS.';
  end if;
  return v;
end;
$$;

-- Check-in, every minute: the runner says how its copy is; it hears the
-- settings and whether a fresh copy was asked for.
create or replace function public.testdb_heartbeat(
  p_key text, p_model text default null, p_app_version text default null, p_state jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.testdb_runners := public.testdb_runner_by_key(p_key);
  v_state jsonb := case when jsonb_typeof(p_state) = 'object' and length(p_state::text) <= 4000 then p_state end;
begin
  update public.testdb_runners
     set model = coalesce(left(p_model, 120), model),
         app_version = coalesce(left(p_app_version, 40), app_version),
         state = coalesce(v_state, state)
   where id = v.id;
  insert into public.nas_services (service, last_seen, status, detail, version)
  values ('testdb', now(),
          case when coalesce(v_state ->> 'busy', '') <> '' then 'busy'
               when v_state ? 'refreshed_at' then 'ok' else 'waiting' end,
          coalesce(v_state, v.state), left(p_app_version, 40))
  on conflict (service) do update
     set last_seen = excluded.last_seen, status = excluded.status, detail = excluded.detail,
         version = coalesce(excluded.version, public.nas_services.version);
  return jsonb_build_object(
    'runner', v.id, 'label', v.label,
    'settings', public.nas_testdb_config(),
    'waiting', (select count(*) from public.testdb_runs where status = 'queued'));
end;
$$;

-- The next waiting run (oldest first) for this runner. A run "running" for
-- 45 minutes is given up on.
create or replace function public.testdb_claim(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.testdb_runners := public.testdb_runner_by_key(p_key);
  r public.testdb_runs;
begin
  update public.testdb_runs set status = 'failed', finished_at = clock_timestamp(),
         error = coalesce(error, 'The NAS stopped answering during the run.')
   where status = 'running' and started_at < now() - interval '45 minutes';
  update public.testdb_runs set status = 'running', runner_id = v.id, started_at = now()
   where id = (select q.id from public.testdb_runs q where q.status = 'queued'
                order by q.created_at limit 1 for update skip locked)
  returning * into r;
  if not found then
    return null;
  end if;
  return public.testdb_run_json(r);
end;
$$;

-- What happened. p_id: the claimed run; null for the nightly refresh the
-- runner did on its own (recorded as a finished run).
create or replace function public.testdb_report(
  p_key text, p_id uuid, p_kind text, p_ok boolean, p_error text default null, p_ms integer default null,
  p_detail jsonb default null, p_head_sha text default null, p_files text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.testdb_runners := public.testdb_runner_by_key(p_key);
  v_detail jsonb := case when jsonb_typeof(p_detail) = 'object' and length(p_detail::text) <= 20000
                         then p_detail else '{}'::jsonb end;
  v_files text[] := (select coalesce(array_agg(left(f, 200)), '{}') from unnest(p_files[1:50]) f);
  r public.testdb_runs;
begin
  if p_kind not in ('refresh', 'migration') then
    raise exception 'TESTDB_BAD_KIND' using errcode = '22023';
  end if;
  if p_id is null then
    if p_kind <> 'refresh' then
      raise exception 'TESTDB_BAD_KIND' using errcode = '22023';
    end if;
    insert into public.testdb_runs (kind, status, error, ms, detail, runner_id, started_at, finished_at)
    values ('refresh', case when p_ok then 'passed' else 'failed' end, left(p_error, 4000),
            case when p_ms is null then null else greatest(0, p_ms) end, v_detail, v.id,
            clock_timestamp() - make_interval(secs => greatest(0, coalesce(p_ms, 0)) / 1000.0), clock_timestamp())
    returning * into r;
  else
    update public.testdb_runs
       set status = case when p_ok then 'passed' else 'failed' end,
           error = case when p_ok then null else left(coalesce(p_error, 'failed'), 4000) end,
           ms = case when p_ms is null then null else greatest(0, p_ms) end,
           detail = v_detail,
           head_sha = coalesce(left(p_head_sha, 64), head_sha),
           files = case when p_files is null then files else v_files end,
           finished_at = clock_timestamp()
     where id = p_id and runner_id = v.id and status = 'running' and kind = p_kind
    returning * into r;
    if not found then
      raise exception 'TESTDB_NOT_YOURS' using errcode = '22023';
    end if;
  end if;
  return public.testdb_run_json(r);
end;
$$;

revoke execute on function public.testdb_pair(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.testdb_runner_by_key(text) from public, anon, authenticated;
revoke execute on function public.testdb_heartbeat(text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.testdb_claim(text) from public, anon, authenticated;
revoke execute on function public.testdb_report(text, uuid, text, boolean, text, integer, jsonb, text, text[])
  from public, anon, authenticated;
grant execute on function public.testdb_pair(text, text, text, text, text) to service_role;
grant execute on function public.testdb_heartbeat(text, text, text, jsonb) to service_role;
grant execute on function public.testdb_claim(text) to service_role;
grant execute on function public.testdb_report(text, uuid, text, boolean, text, integer, jsonb, text, text[])
  to service_role;

-- ---- 5. Visitor stats settings -------------------------------------------------------------
create or replace function public.nas_stats_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_id text := lower(btrim(coalesce(p ->> 'websiteId', '')));
begin
  return jsonb_build_object(
    'on', coalesce(case when jsonb_typeof(p -> 'on') = 'boolean' then (p ->> 'on')::boolean end, true),
    'websiteId', case when v_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_id end);
end;
$$;
revoke execute on function public.nas_stats_normalize(jsonb) from public, anon, authenticated;

create or replace function public.admin_nas_stats_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.testdb_stats_admin_ok(false) then
    raise exception 'Admins with the Office NAS page only.' using errcode = '42501';
  end if;
  return public.nas_stats_normalize(coalesce((select value from public.app_settings where key = 'nas_stats'), '{}'::jsonb));
end;
$$;
revoke execute on function public.admin_nas_stats_config() from public, anon;
grant execute on function public.admin_nas_stats_config() to authenticated;

create or replace function public.admin_nas_stats_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.nas_stats_normalize(coalesce(p, '{}'::jsonb));
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_nas_stats_set') then
    raise exception 'You can''t change visitor stats.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p ->> 'websiteId', '')), '') is not null and v ->> 'websiteId' is null then
    raise exception 'The website ID is the one Umami shows (8-4-4-4-12 letters and digits).' using errcode = '22023';
  end if;
  insert into public.app_settings (key, value) values ('nas_stats', v)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.admin_nas_stats_set(jsonb) from public, anon;
grant execute on function public.admin_nas_stats_set(jsonb) to authenticated;

-- ---- Housekeeping --------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-nas-testdb';
    perform cron.schedule('purge-nas-testdb', '41 3 * * *', $job$
      delete from public.testdb_runner_pairings where expires_at < now() - interval '1 day';
      delete from public.testdb_pair_failures where at < now() - interval '1 day';
      delete from public.testdb_runs where created_at < now() - interval '180 days';
    $job$);
  end if;
end $$;

notify pgrst, 'reload schema';
