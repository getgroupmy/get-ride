-- ============================================================================
-- 0234 — Security tester batch 9
--
-- 1. fare_ai_key_states is for the admins of the Fare AI page. Its only
--    policy was SELECT USING (true) for everyone, so the anon key read every
--    AI key's id, provider, usage, cooldown and last_error (raw provider
--    answers). Now only a signed-in admin with READ or EDIT on
--    'admin-settings-fare-ai', on the Settings hub ('admin-settings', which
--    the panel lets open every settings page) or on everything ('*') reads
--    it (fare_ai_caller_can_read). anon loses every grant; authenticated
--    keeps SELECT only. The edge functions (ai-route-proxy,
--    document-ai-verify) write it with the service role, and
--    fare_ai_reset_cooldown is security definer, so neither changes.
-- 2. Rate limits slide. auth_rate_take (0229) counted in fixed windows
--    aligned to the epoch, so a burst straddling a boundary got ~2x the
--    limit (5 trip-code tries at 9:59 and 5 more at 10:00). Both
--    auth_rate_take and auth_rate_wait now weigh the previous window in:
--      effective = this window's count
--                + previous window's count x (1 - fraction of this window gone)
--    and refuse when effective >= limit. Signatures, grants, the answer (0,
--    or the seconds until a try would pass) and the storage (one row per
--    bucket, key, window length and window start) are unchanged; a try over
--    the limit is still not counted, a null or empty key is never limited,
--    and callers still fail closed on an error. The hourly purge
--    (purge-auth-rate-counts) now keeps the window before the current one,
--    which the weighing reads.
-- 3. claude_access_rules: anon reads the list (the hook uses the publishable
--    key) and writes nothing; the admin page writes through the table's
--    policies as authenticated. The write grants anon had from the default
--    privileges are revoked, and TRUNCATE / REFERENCES / TRIGGER from both.
-- ============================================================================

-- ---- 1. fare_ai_key_states: Fare AI admins only ----------------------------------------------------
create or replace function public.fare_ai_caller_can_read()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1 from public.admin_access a
        where a.profile_id = auth.uid()
          and a.page in ('*', 'admin-settings', 'admin-settings-fare-ai'));
$$;
revoke execute on function public.fare_ai_caller_can_read() from public, anon;
grant execute on function public.fare_ai_caller_can_read() to authenticated;

drop policy if exists "fare_ai_key_states read" on public.fare_ai_key_states;
drop policy if exists "fare_ai_key_states admin read" on public.fare_ai_key_states;
create policy "fare_ai_key_states admin read" on public.fare_ai_key_states
  for select to authenticated using ((select public.fare_ai_caller_can_read()));

revoke all on table public.fare_ai_key_states from public, anon;
revoke insert, update, delete, truncate, references, trigger on table public.fare_ai_key_states from authenticated;
grant select on table public.fare_ai_key_states to authenticated;

-- ---- 2. Sliding rate limits ------------------------------------------------------------------------
-- Seconds until a try would pass, for a key with [p_cur] tries in this window
-- and [p_prev] in the one before, [p_elapsed] seconds into a [p_secs]-second
-- window; 0 when one passes now (effective < limit). At least 1 otherwise.
create or replace function public.auth_rate_retry_after(
  p_cur integer, p_prev integer, p_limit integer, p_secs integer, p_elapsed double precision)
returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  v_left double precision := p_secs - p_elapsed;   -- until this window ends
  v_at   double precision;                         -- seconds from now
begin
  if p_limit < 1 then
    return greatest(1, ceil(v_left)::integer);
  end if;
  if p_cur + coalesce(p_prev, 0) * (1 - p_elapsed / p_secs) < p_limit then
    return 0;
  end if;
  if p_cur >= p_limit then
    -- Not before this window ends; then its tries weigh as the previous
    -- window's: p_cur x (1 - f) < limit once f > 1 - limit / p_cur.
    v_at := v_left + p_secs * (1 - p_limit::double precision / p_cur);
  else
    -- Within this window: p_cur + p_prev x (1 - f) < limit once
    -- f > 1 - (limit - p_cur) / p_prev.
    v_at := p_secs * (1 - (p_limit - p_cur)::double precision / p_prev) - p_elapsed;
  end if;
  return greatest(1, ceil(v_at)::integer);
end;
$$;
revoke execute on function public.auth_rate_retry_after(integer, integer, integer, integer, double precision)
  from public, anon, authenticated;

-- Counts one try in [p_bucket] for [p_key]: 0 when it is within [p_limit]
-- (and is counted), else the seconds until a try would pass (and nothing is
-- counted). The window slides: the previous window's tries weigh in by how
-- much of it still overlaps the last [p_window]. A null key is never limited.
create or replace function public.auth_rate_take(p_bucket text, p_key text, p_limit integer, p_window interval)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secs    integer := greatest(1, ceil(extract(epoch from p_window))::integer);
  v_epoch   double precision := extract(epoch from now());
  v_start   timestamptz := to_timestamp(floor(v_epoch / v_secs) * v_secs);
  v_elapsed double precision := v_epoch - floor(v_epoch / v_secs) * v_secs;
  v_prev    integer;
  v_weight  double precision;
  v_cur     integer;
  v_hits    integer;
begin
  if p_key is null or p_key = '' then
    return 0;
  end if;
  if p_limit < 1 then
    return public.auth_rate_retry_after(0, 0, p_limit, v_secs, v_elapsed);
  end if;
  select c.hits into v_prev from public.auth_rate_counts c
   where c.bucket = p_bucket and c.key = p_key and c.window_s = v_secs
     and c.window_start = v_start - make_interval(secs => v_secs);
  v_prev := coalesce(v_prev, 0);
  v_weight := v_prev * (1 - v_elapsed / v_secs);
  if v_weight < p_limit then
    insert into public.auth_rate_counts as c (bucket, key, window_s, window_start, hits)
    values (p_bucket, p_key, v_secs, v_start, 1)
    on conflict (bucket, key, window_s, window_start) do update
      set hits = c.hits + 1
      where c.hits + v_weight < p_limit
    returning c.hits into v_hits;
  end if;
  -- No row back: the limit was reached, and this try isn't counted.
  if v_hits is null then
    select c.hits into v_cur from public.auth_rate_counts c
     where c.bucket = p_bucket and c.key = p_key and c.window_s = v_secs and c.window_start = v_start;
    return public.auth_rate_retry_after(coalesce(v_cur, 0), v_prev, p_limit, v_secs, v_elapsed);
  end if;
  return 0;
end;
$$;
revoke execute on function public.auth_rate_take(text, text, integer, interval) from public, anon, authenticated;

-- The wait auth_rate_take would answer, without counting anything.
create or replace function public.auth_rate_wait(p_bucket text, p_key text, p_limit integer, p_window interval)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_secs    integer := greatest(1, ceil(extract(epoch from p_window))::integer);
  v_epoch   double precision := extract(epoch from now());
  v_start   timestamptz := to_timestamp(floor(v_epoch / v_secs) * v_secs);
  v_elapsed double precision := v_epoch - floor(v_epoch / v_secs) * v_secs;
  v_cur     integer;
  v_prev    integer;
begin
  if p_key is null or p_key = '' then
    return 0;
  end if;
  select coalesce(sum(c.hits) filter (where c.window_start = v_start), 0),
         coalesce(sum(c.hits) filter (where c.window_start = v_start - make_interval(secs => v_secs)), 0)
    into v_cur, v_prev
    from public.auth_rate_counts c
   where c.bucket = p_bucket and c.key = p_key and c.window_s = v_secs
     and c.window_start in (v_start, v_start - make_interval(secs => v_secs));
  -- 0229 answered 0 for a limit of none with nothing counted; keep that.
  if p_limit < 1 and v_cur = 0 then
    return 0;
  end if;
  return public.auth_rate_retry_after(v_cur, v_prev, p_limit, v_secs, v_elapsed);
end;
$$;
revoke execute on function public.auth_rate_wait(text, text, integer, interval) from public, anon, authenticated;

-- The purge keeps the window before the current one: the weighing reads it.
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-auth-rate-counts';
    perform cron.schedule('purge-auth-rate-counts', '11 * * * *', $job$
      delete from public.auth_rate_counts where window_start + 2 * make_interval(secs => window_s) < now();
      delete from public.auth_rate_hits where at < now() - interval '1 day';
    $job$);
  end if;
end
$cron$;

-- ---- 3. claude_access_rules: anon reads only ---------------------------------------------------------
revoke insert, update, delete, truncate, references, trigger on table public.claude_access_rules from anon;
revoke truncate, references, trigger on table public.claude_access_rules from authenticated;
grant select on table public.claude_access_rules to anon, authenticated;
grant insert, update, delete on table public.claude_access_rules to authenticated;
