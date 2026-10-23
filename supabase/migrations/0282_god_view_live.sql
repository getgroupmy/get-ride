-- ============================================================================
-- 0282 — God View: fresh phone details on every ping, "Live now", and a new
-- phone number set from the admin panel.
--
-- Applied as version 20261024120000 (0282_god_view_live in
-- supabase_migrations.schema_migrations). Re-runnable: tables and indexes
-- "if not exists", functions "or replace", policies and the cron job are
-- dropped first.
--
-- 1. Phone details on every ping answer. A phone answering a "Still there?"
--    ping (0276) or a live share also sends its battery, network, storage,
--    app version and permissions:
--      push_background_details(key, details) (anon, the install's
--        background key as push_background_location): a user_sessions row
--        (event 'ping') for the key's account, the device's own columns
--        copied from its newest row (device id, model, screen, push key),
--        the fresh ones from [details] (whitelisted, typed, clipped). Only
--        for a phone pinged in the last 10 minutes or live now, once in 20
--        seconds; push_tokens.details_at says when.
--      god_view_ping_answer(profile, since), as 0276 with details_at (the
--        newest user_sessions row of the account) and details (whether it
--        is newer than since): God View's "Update" waits on it.
-- 2. Live now. An admin with God View streams one person's position every
--    5 seconds for 5, 15 or 60 minutes:
--      god_view_live_sessions: one row a share (no admin in it: who started
--        and stopped it is in admin_audit_log); one open at a time a person
--        (unique while stopped_at is null); at most an hour. The person
--        reads their own (the app's "Shared live with support" notice).
--      god_view_live_points: the points, read by an admin who may see the
--        person (god_view_live_may_watch), live through realtime; copied
--        into user_location_history within a minute so Movement keeps
--        them (god_view_live_flush), kept 7 days here.
--      god_view_live_start(profile, minutes): the same caller check as
--        god_view_ping (god_view_may_see); 20 starts a caller in 10 minutes;
--        the phones are those a ping goes to; a `location_live` push through
--        location-ping (reason 'live'); logged ('god_view.live_start').
--        An open share is answered as it is (already: true).
--      god_view_live_stop(session): logged ('god_view.live_stop').
--      god_view_live_status(profile, after): the newest share (open, or
--        ended in the last 10 minutes) and its points after point id
--        [after], for the page's poll.
--      push_live_location(key, lat, lng, speed, accuracy) (anon, the
--        install's key): one point, at most one in 4 seconds, while a share
--        is open; moves the phone on the map (push_tokens). Answers
--        { live, ends_at, ends_in (seconds) } so the phone stops on its own
--        when the share is stopped or over.
--      my_live_share(): the signed-in person's open share, for the notice.
--      god_view_live_tick() (pg_cron, every minute): ends shares past their
--        time, copies points into the history, drops points older than 7
--        days.
-- 3. A new phone number from the admin panel (God View's pencil by Phone).
--    No admin path changed the sign-in number before (Edit User saved
--    profiles.phone only):
--      phone_change_requests: one pending change a person; a random link
--        token (only its hash is kept); 24 hours to confirm.
--      admin_phone_change_request(profile, phone): an admin with EDIT on the
--        Users pages ('*', admin-users or admin-user-edit); the number
--        checked free; one a person a minute, 20 a caller an hour; an SMS to
--        the new number with the link (channel 'otp', so the queue row is
--        masked for admins, 0183); logged ('user.phone_change_request').
--      admin_phone_change_status(profile): the newest request of the last 7
--        days, the new number shown by its last 4 digits.
--      phone_change_lookup(token) / phone_change_confirm(token) (anon): the
--        link's page. Confirming moves the Auth login to the new number
--        (auth.users, auth.identities; profiles.phone follows by trigger,
--        0092): the old number no longer signs in.
--
-- The function: supabase/functions/location-ping ('live' sends
-- `location_live`). The phones: a new build (LiveLocation.kt,
-- AppDelegate.swift).
-- ============================================================================

-- ---- 1. Phone details on every ping answer ------------------------------------------------------
alter table public.push_tokens
  add column if not exists details_at timestamptz;
comment on column public.push_tokens.details_at is
  'When the phone last sent its details answering a ping or a live share (push_background_details, 0282).';

-- The details a phone may send, typed and clipped; anything else is dropped.
create or replace function public.phone_details_clean(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'network_type', case when p ->> 'network_type' in ('wifi', 'cellular', 'ethernet', 'vpn', 'bluetooth', 'none', 'other')
                         then p ->> 'network_type' end,
    'cellular_generation', case when p ->> 'cellular_generation' in ('2G', '3G', '4G', '5G')
                                then p ->> 'cellular_generation' end,
    'network_operator', nullif(left(btrim(coalesce(p ->> 'network_operator', '')), 60), ''),
    'mobile_operator_name', nullif(left(btrim(coalesce(p ->> 'mobile_operator_name', '')), 60), ''),
    'network_is_connected', case when jsonb_typeof(p -> 'network_is_connected') = 'boolean'
                                 then p -> 'network_is_connected' end,
    'network_is_internet_reachable', case when jsonb_typeof(p -> 'network_is_internet_reachable') = 'boolean'
                                          then p -> 'network_is_internet_reachable' end,
    'os_version', nullif(left(btrim(coalesce(p ->> 'os_version', '')), 60), ''),
    'app_version', nullif(left(btrim(coalesce(p ->> 'app_version', '')), 20), ''),
    'app_build_version', nullif(left(btrim(coalesce(p ->> 'app_build_version', '')), 20), ''),
    'battery_pct', case when jsonb_typeof(p -> 'battery_pct') = 'number'
                             and (p ->> 'battery_pct')::numeric between 0 and 100
                        then to_jsonb(round((p ->> 'battery_pct')::numeric)::int) end,
    'battery_charging', case when jsonb_typeof(p -> 'battery_charging') = 'boolean' then p -> 'battery_charging' end,
    'storage_free_bytes', case when jsonb_typeof(p -> 'storage_free_bytes') = 'number'
                                    and (p ->> 'storage_free_bytes')::numeric between 0 and 1e15
                               then to_jsonb((p ->> 'storage_free_bytes')::numeric::bigint) end,
    'storage_total_bytes', case when jsonb_typeof(p -> 'storage_total_bytes') = 'number'
                                     and (p ->> 'storage_total_bytes')::numeric between 1 and 1e15
                                then to_jsonb((p ->> 'storage_total_bytes')::numeric::bigint) end,
    'perm_location', case when p ->> 'perm_location' in ('always', 'while_in_use', 'denied', 'unknown')
                          then p ->> 'perm_location' end,
    'location_service_on', case when jsonb_typeof(p -> 'location_service_on') = 'boolean'
                                then p -> 'location_service_on' end,
    'perm_notifications', case when jsonb_typeof(p -> 'perm_notifications') = 'boolean'
                               then p -> 'perm_notifications' end));
$$;
revoke execute on function public.phone_details_clean(jsonb) from public, anon, authenticated;

-- The closed (or open) app's answer to a ping: a session row with the
-- phone's fresh details. True when it was taken.
create or replace function public.push_background_details(p_key text, p_details jsonb)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  t record;
  prev public.user_sessions;
  d jsonb := public.phone_details_clean(case when jsonb_typeof(p_details) = 'object' then p_details else '{}'::jsonb end);
  v_raw jsonb;
begin
  if p_key is null or length(p_key) not between 32 and 128 then
    return false;
  end if;
  v_hash := encode(extensions.digest(convert_to(p_key, 'UTF8'), 'sha256'), 'hex');
  -- Only an asked-for answer (a ping in the last 10 minutes, or a live
  -- share), once in 20 seconds.
  update public.push_tokens k
     set details_at = now()
   where k.id = (select x.id from public.push_tokens x
                  where x.bg_key_hash = v_hash and x.profile_id is not null
                    and (x.details_at is null or x.details_at < now() - interval '20 seconds')
                    and (x.ping_sent_at > now() - interval '10 minutes'
                         or exists (select 1 from public.god_view_live_sessions s
                                     where s.profile_id = x.profile_id and s.stopped_at is null and s.ends_at > now()))
                  order by x.updated_at desc nulls last
                  limit 1)
  returning k.id, k.profile_id, k.platform, k.device_key into t;
  if not found then
    return false;
  end if;
  -- The device's own columns from its newest row (by its push key, else
  -- the newest of its platform).
  select s.* into prev
    from public.user_sessions s
   where s.user_id = t.profile_id
     and (s.raw ->> 'push_device_key' = t.device_key
          or (t.device_key is null or not exists (select 1 from public.user_sessions z
                                                   where z.user_id = t.profile_id
                                                     and z.raw ->> 'push_device_key' = t.device_key))
             and lower(coalesce(s.os_name, '')) = t.platform)
   order by (s.raw ->> 'push_device_key' = t.device_key) desc nulls last, s.captured_at desc
   limit 1;
  v_raw := jsonb_strip_nulls(jsonb_build_object(
    'client', 'native',
    'platform', t.platform,
    'screen', prev.raw -> 'screen',
    'pixel_ratio', prev.raw -> 'pixel_ratio',
    'locale', prev.raw -> 'locale',
    'timezone', prev.raw -> 'timezone',
    'utc_offset_min', prev.raw -> 'utc_offset_min',
    'push_device_key', coalesce(to_jsonb(t.device_key), prev.raw -> 'push_device_key'),
    'app_build', d -> 'app_build_version'))
    || (d - array['network_type', 'cellular_generation', 'network_operator', 'mobile_operator_name',
                  'network_is_connected', 'network_is_internet_reachable', 'os_version', 'app_version',
                  'app_build_version']);
  begin
    insert into public.user_sessions (
      user_id, phone, event_type, device_id, os_name, os_version, device_brand, device_manufacturer,
      device_model_name, device_model_id, device_type, is_physical_device, network_type, network_is_connected,
      network_is_internet_reachable, network_operator, mobile_operator_name, cellular_generation,
      app_version, app_build_version, app_id, ip_city, ip_region, ip_country, raw)
    values (
      t.profile_id, prev.phone, 'ping', prev.device_id, coalesce(prev.os_name, t.platform),
      coalesce(d ->> 'os_version', prev.os_version), prev.device_brand, prev.device_manufacturer,
      prev.device_model_name, prev.device_model_id, coalesce(prev.device_type, 'phone'), prev.is_physical_device,
      d ->> 'network_type', (d ->> 'network_is_connected')::boolean, (d ->> 'network_is_internet_reachable')::boolean,
      d ->> 'network_operator', d ->> 'mobile_operator_name', d ->> 'cellular_generation',
      coalesce(d ->> 'app_version', prev.app_version), coalesce(d ->> 'app_build_version', prev.app_build_version),
      prev.app_id, prev.ip_city, prev.ip_region, prev.ip_country, v_raw);
  exception when others then
    -- The signed-out telemetry limit (0223) or a column the row lacks: the
    -- position still counts.
    return false;
  end;
  return true;
end;
$$;
revoke execute on function public.push_background_details(text, jsonb) from public;
grant execute on function public.push_background_details(text, jsonb) to anon, authenticated;

-- As 0276, with the newest phone report: God View's "Update" waits for it.
create or replace function public.god_view_ping_answer(p_profile_id uuid, p_since timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_at timestamptz;
  v_details timestamptz;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only ping someone on your God View map.' using errcode = '42501';
  end if;
  select max(t.located_at) into v_at
    from public.push_tokens t
   where t.profile_id = p_profile_id;
  select s.captured_at into v_details
    from public.user_sessions s
   where s.user_id = p_profile_id
   order by s.captured_at desc
   limit 1;
  return jsonb_build_object(
    'answered', p_since is not null and v_at >= p_since,
    'located_at', v_at,
    'details', p_since is not null and v_details >= p_since,
    'details_at', v_details);
end;
$$;
revoke execute on function public.god_view_ping_answer(uuid, timestamptz) from public, anon;
grant execute on function public.god_view_ping_answer(uuid, timestamptz) to authenticated;

-- ---- 2. Live now --------------------------------------------------------------------------------
create table if not exists public.god_view_live_sessions (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id) on delete cascade,
  started_at     timestamptz not null default now(),
  ends_at        timestamptz not null,
  stopped_at     timestamptz,
  stop_reason    text check (stop_reason in ('admin', 'expired')),
  first_point_at timestamptz,
  last_point_at  timestamptz,
  points         integer not null default 0,
  constraint god_view_live_sessions_hour check (ends_at > started_at and ends_at <= started_at + interval '61 minutes')
);
comment on table public.god_view_live_sessions is
  'God View "Live now" (0282): one person''s position every 5 s until ends_at. Who started and stopped it is in admin_audit_log.';
create unique index if not exists god_view_live_sessions_one_open
  on public.god_view_live_sessions (profile_id) where stopped_at is null;
create index if not exists god_view_live_sessions_profile_idx
  on public.god_view_live_sessions (profile_id, started_at desc);

create table if not exists public.god_view_live_points (
  id          bigint generated always as identity primary key,
  session_id  uuid not null references public.god_view_live_sessions (id) on delete cascade,
  profile_id  uuid not null,
  lat         double precision not null,
  lng         double precision not null,
  speed       double precision,
  accuracy    double precision,
  captured_at timestamptz not null default now(),
  in_history  boolean not null default false
);
create index if not exists god_view_live_points_session_idx on public.god_view_live_points (session_id, id);
create index if not exists god_view_live_points_unflushed_idx on public.god_view_live_points (id) where not in_history;
create index if not exists god_view_live_points_captured_idx on public.god_view_live_points (captured_at);

alter table public.god_view_live_sessions enable row level security;
alter table public.god_view_live_points enable row level security;
revoke all on public.god_view_live_sessions, public.god_view_live_points from public, anon, authenticated;
grant select on public.god_view_live_sessions, public.god_view_live_points to authenticated;

-- Whether the caller may watch the points of [p_session]: God View's own
-- rule for its person (god_view_may_see is not the client's to call).
create or replace function public.god_view_live_may_watch(p_session uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.god_view_live_sessions s
                  where s.id = p_session and public.god_view_may_see(s.profile_id));
$$;
revoke execute on function public.god_view_live_may_watch(uuid) from public, anon;
grant execute on function public.god_view_live_may_watch(uuid) to authenticated;

drop policy if exists "god_view_live_sessions own read" on public.god_view_live_sessions;
create policy "god_view_live_sessions own read" on public.god_view_live_sessions
  for select to authenticated using (profile_id = (select auth.uid()));
drop policy if exists "god_view_live_points god view read" on public.god_view_live_points;
create policy "god_view_live_points god view read" on public.god_view_live_points
  for select to authenticated using (public.god_view_live_may_watch(session_id));

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'god_view_live_points') then
    alter publication supabase_realtime add table public.god_view_live_points;
  end if;
end $$;

-- A share as the page and the phone read it.
create or replace function public.god_view_live_json(s public.god_view_live_sessions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when s.id is null then null else jsonb_build_object(
    'id', s.id,
    'profile_id', s.profile_id,
    'started_at', s.started_at,
    'ends_at', s.ends_at,
    'stopped_at', s.stopped_at,
    'stop_reason', s.stop_reason,
    'first_point_at', s.first_point_at,
    'last_point_at', s.last_point_at,
    'points', s.points,
    'now', now()) end;
$$;
revoke execute on function public.god_view_live_json(public.god_view_live_sessions) from public, anon, authenticated;

-- The points not yet in user_location_history (of [p_session], or all),
-- copied there: Movement keeps them. Run by the tick, and by the admin's
-- calls (a signed-in caller: the signed-out telemetry limit is not theirs).
create or replace function public.god_view_live_flush(p_session uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  with due as (
    update public.god_view_live_points p
       set in_history = true
     where not p.in_history
       and (p_session is null or p.session_id = p_session)
    returning p.profile_id, p.lat, p.lng, p.speed, p.accuracy, p.captured_at
  )
  insert into public.user_location_history (user_id, latitude, longitude, speed, accuracy, captured_at)
  select d.profile_id, d.lat, d.lng, d.speed, d.accuracy, d.captured_at from due d;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.god_view_live_flush(uuid) from public, anon, authenticated;

-- Shares past their time, ended.
create or replace function public.god_view_live_expire(p_profile_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  update public.god_view_live_sessions s
     set stopped_at = s.ends_at, stop_reason = 'expired'
   where s.stopped_at is null and s.ends_at <= now()
     and (p_profile_id is null or s.profile_id = p_profile_id);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.god_view_live_expire(uuid) from public, anon, authenticated;

create or replace function public.god_view_live_start(p_profile_id uuid, p_minutes integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_minutes int := least(greatest(coalesce(p_minutes, 15), 1), 60);
  v_ids uuid[];
  v_posted boolean := false;
  s public.god_view_live_sessions;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only go live with someone on your God View map.' using errcode = '42501';
  end if;
  if v_uid is not null and (select count(*) from public.admin_audit_log l
                             where l.actor_id = v_uid and l.action = 'god_view.live_start'
                               and l.created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'Too many live shares in 10 minutes. Wait a few minutes and try again.' using errcode = 'P0001';
  end if;
  -- One person at a time: [p_profile_id]'s rows, in order.
  perform pg_advisory_xact_lock(hashtextextended('god_view_live|' || p_profile_id::text, 282));
  perform public.god_view_live_expire(p_profile_id);
  select * into s from public.god_view_live_sessions x
   where x.profile_id = p_profile_id and x.stopped_at is null;
  if s.id is not null then
    return jsonb_build_object('already', true, 'phones', null, 'posted', null, 'session', public.god_view_live_json(s));
  end if;
  -- The phones a ping goes to (0276), claimed as a ping: they answer once
  -- like one, then stream.
  with mine as (
    select t.id
      from public.push_tokens t
      join public.profiles p on p.id = t.profile_id and p.deleted_at is null
     where t.profile_id = p_profile_id
       and t.bg_key_hash is not null
       and t.location_always
       and t.platform in ('ios', 'android')
       for update of t
  ),
  claimed as (
    update public.push_tokens t
       set ping_sent_at = now()
      from mine m
     where t.id = m.id
    returning t.id
  )
  select array_agg(c.id order by c.id) into v_ids from claimed c;
  if coalesce(cardinality(v_ids), 0) = 0 then
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (v_uid, 'god_view.live_start', p_profile_id, jsonb_build_object('minutes', v_minutes, 'phones', 0));
    return jsonb_build_object('already', false, 'phones', 0, 'posted', false, 'session', null);
  end if;
  insert into public.god_view_live_sessions (profile_id, ends_at)
  values (p_profile_id, now() + make_interval(mins => v_minutes))
  returning * into s;
  v_posted := public.location_ping_kick(v_ids, 'live');
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.live_start', p_profile_id,
          jsonb_build_object('minutes', v_minutes, 'phones', cardinality(v_ids), 'posted', v_posted, 'session', s.id));
  return jsonb_build_object('already', false, 'phones', cardinality(v_ids), 'posted', v_posted,
                            'session', public.god_view_live_json(s));
end;
$$;
revoke execute on function public.god_view_live_start(uuid, integer) from public, anon;
grant execute on function public.god_view_live_start(uuid, integer) to authenticated;

create or replace function public.god_view_live_stop(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  s public.god_view_live_sessions;
begin
  select * into s from public.god_view_live_sessions x where x.id = p_session_id;
  if s.id is null or not public.god_view_may_see(s.profile_id) then
    raise exception 'You can only stop a live share of someone on your God View map.' using errcode = '42501';
  end if;
  update public.god_view_live_sessions x
     set stopped_at = now(), stop_reason = 'admin'
   where x.id = s.id and x.stopped_at is null
  returning * into s;
  if s.id is null then
    select * into s from public.god_view_live_sessions x where x.id = p_session_id;
  else
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (v_uid, 'god_view.live_stop', s.profile_id, jsonb_build_object('session', s.id, 'points', s.points));
  end if;
  perform public.god_view_live_flush(s.id);
  return public.god_view_live_json(s);
end;
$$;
revoke execute on function public.god_view_live_stop(uuid) from public, anon;
grant execute on function public.god_view_live_stop(uuid) to authenticated;

-- The person's newest share (open, or ended in the last 10 minutes) and its
-- points after [p_after] (a point id), oldest first, as
-- [id, lat, lng, epoch seconds, speed].
create or replace function public.god_view_live_status(p_profile_id uuid, p_after bigint default 0)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.god_view_live_sessions;
  v_points jsonb;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only see the live share of someone on your God View map.' using errcode = '42501';
  end if;
  perform public.god_view_live_expire(p_profile_id);
  select * into s from public.god_view_live_sessions x
   where x.profile_id = p_profile_id
     and (x.stopped_at is null or x.stopped_at > now() - interval '10 minutes')
   order by x.started_at desc
   limit 1;
  if s.id is null then
    return jsonb_build_object('session', null, 'points', '[]'::jsonb, 'now', now());
  end if;
  perform public.god_view_live_flush(s.id);
  select coalesce(jsonb_agg(jsonb_build_array(
           x.id, round(x.lat::numeric, 6), round(x.lng::numeric, 6),
           floor(extract(epoch from x.captured_at))::bigint, x.speed) order by x.id), '[]'::jsonb)
    into v_points
    from (select p.* from public.god_view_live_points p
           where p.session_id = s.id and p.id > coalesce(p_after, 0)
           order by p.id
           limit 1000) x;
  return jsonb_build_object('session', public.god_view_live_json(s), 'points', v_points, 'now', now());
end;
$$;
revoke execute on function public.god_view_live_status(uuid, bigint) from public, anon;
grant execute on function public.god_view_live_status(uuid, bigint) to authenticated;

-- The phone's live point, with the install's key. { live, ends_at, ends_in }:
-- live false once the share is stopped or over, and the phone stops.
create or replace function public.push_live_location(
  p_key text,
  p_lat double precision,
  p_lng double precision,
  p_speed double precision default null,
  p_accuracy double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  t record;
  s public.god_view_live_sessions;
begin
  if p_key is null or length(p_key) not between 32 and 128
     or p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return jsonb_build_object('live', false);
  end if;
  v_hash := encode(extensions.digest(convert_to(p_key, 'UTF8'), 'sha256'), 'hex');
  select k.id, k.profile_id, k.last_lat, k.last_lng into t
    from public.push_tokens k
   where k.bg_key_hash = v_hash and k.profile_id is not null and k.location_always
   order by k.updated_at desc nulls last
   limit 1;
  if not found then
    return jsonb_build_object('live', false);
  end if;
  -- At most one point in 4 seconds a share.
  update public.god_view_live_sessions x
     set points = x.points + 1,
         first_point_at = coalesce(x.first_point_at, now()),
         last_point_at = now()
   where x.profile_id = t.profile_id
     and x.stopped_at is null
     and x.ends_at > now()
     and (x.last_point_at is null or x.last_point_at < now() - interval '4 seconds')
  returning * into s;
  if s.id is null then
    select * into s from public.god_view_live_sessions x
     where x.profile_id = t.profile_id and x.stopped_at is null and x.ends_at > now();
    if s.id is null then
      return jsonb_build_object('live', false);
    end if;
    return jsonb_build_object('live', true, 'ends_at', s.ends_at,
                              'ends_in', ceil(extract(epoch from s.ends_at - now()))::int, 'taken', false);
  end if;
  insert into public.god_view_live_points (session_id, profile_id, lat, lng, speed, accuracy)
  values (s.id, t.profile_id, p_lat, p_lng,
          case when p_speed >= 0 and p_speed < 150 then p_speed end,
          case when p_accuracy >= 0 and p_accuracy < 100000 then p_accuracy end);
  update public.push_tokens k
     set last_lat = p_lat, last_lng = p_lng, located_at = now()
   where k.id = t.id;
  perform public.push_area_refresh(t.id, t.last_lat, t.last_lng);
  return jsonb_build_object('live', true, 'ends_at', s.ends_at,
                            'ends_in', ceil(extract(epoch from s.ends_at - now()))::int, 'taken', true);
end;
$$;
revoke execute on function public.push_live_location(text, double precision, double precision, double precision,
  double precision) from public;
grant execute on function public.push_live_location(text, double precision, double precision, double precision,
  double precision) to anon, authenticated;

-- The signed-in person's open share: the app's "Shared live with support".
create or replace function public.my_live_share()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', s.id, 'ends_at', s.ends_at, 'now', now())
    from public.god_view_live_sessions s
   where s.profile_id = auth.uid() and s.stopped_at is null and s.ends_at > now()
   limit 1;
$$;
revoke execute on function public.my_live_share() from public, anon;
grant execute on function public.my_live_share() to authenticated;

create or replace function public.god_view_live_tick()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  perform public.god_view_live_expire(null);
  n := public.god_view_live_flush(null);
  delete from public.god_view_live_points p where p.captured_at < now() - interval '7 days' and p.in_history;
  return n;
end;
$$;
revoke execute on function public.god_view_live_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'god-view-live';
    perform cron.schedule('god-view-live', '* * * * *', $job$select public.god_view_live_tick()$job$);
  end if;
end $$;

-- ---- 3. A new phone number from the admin panel -------------------------------------------------
create table if not exists public.phone_change_requests (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references public.profiles (id) on delete cascade,
  new_phone    text not null,
  token_hash   text not null unique,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '24 hours',
  confirmed_at timestamptz,
  cancelled_at timestamptz
);
comment on table public.phone_change_requests is
  'A sign-in number an admin set, waiting for the SMS link to be opened (0282). Only the token''s hash is kept.';
create index if not exists phone_change_requests_profile_idx on public.phone_change_requests (profile_id, created_at desc);
alter table public.phone_change_requests enable row level security;
revoke all on public.phone_change_requests from public, anon, authenticated;

-- Whether the caller may set or see a new number: EDIT ([p_edit]) or any
-- grant on the Users pages, or a full admin.
create or replace function public.phone_change_caller_ok(p_edit boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.admin_access a
     where a.profile_id = auth.uid()
       and a.page in ('*', 'admin-users', 'admin-user-edit')
       and (not p_edit or a.access_level = 'edit'));
$$;
revoke execute on function public.phone_change_caller_ok(boolean) from public, anon, authenticated;

-- "+60 12-••• 4567" style: the dial code and the last 4 digits.
create or replace function public.phone_masked(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when length(d) < 6 then '••••' else '+' || left(d, 2) || ' ••• ' || right(d, 4) end
    from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d) x;
$$;
revoke execute on function public.phone_masked(text) from public, anon, authenticated;

-- Whether [p_digits] signs in to someone other than [p_profile].
create or replace function public.phone_taken_by_other(p_digits text, p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles p
                  where p.id <> p_profile and p.deleted_at is null
                    and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') = p_digits)
      or exists (select 1 from auth.users u where u.id <> p_profile and u.phone = p_digits);
$$;
revoke execute on function public.phone_taken_by_other(text, uuid) from public, anon, authenticated;

create or replace function public.phone_change_json(r public.phone_change_requests)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when r.id is null then null else jsonb_build_object(
    'id', r.id,
    'status', case when r.confirmed_at is not null then 'confirmed'
                   when r.cancelled_at is not null then 'cancelled'
                   when r.expires_at <= now() then 'expired'
                   else 'waiting' end,
    'phone_tail', right(regexp_replace(r.new_phone, '\D', '', 'g'), 4),
    'phone_masked', public.phone_masked(r.new_phone),
    'created_at', r.created_at,
    'expires_at', r.expires_at,
    'confirmed_at', r.confirmed_at) end;
$$;
revoke execute on function public.phone_change_json(public.phone_change_requests) from public, anon, authenticated;

create or replace function public.admin_phone_change_request(p_profile_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := public.sms_e164(p_phone);
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_current text;
  v_token text;
  r public.phone_change_requests;
begin
  if not public.phone_change_caller_ok(true) then
    raise exception 'Only an admin who can edit users can change a phone number.' using errcode = '42501';
  end if;
  select regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') into v_current
    from public.profiles p where p.id = p_profile_id and p.deleted_at is null;
  if not found then
    raise exception 'No such account.' using errcode = 'P0002';
  end if;
  if v_phone is null or v_digits !~ '^[1-9][0-9]{7,14}$' then
    raise exception 'Enter a valid phone number.' using errcode = '22023';
  end if;
  if v_digits = v_current then
    raise exception 'That is already their number.' using errcode = '22023';
  end if;
  if public.phone_taken_by_other(v_digits, p_profile_id) then
    raise exception 'This number is already linked to another account.' using errcode = '23505';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('phone_change|' || p_profile_id::text, 282));
  if exists (select 1 from public.phone_change_requests x
              where x.profile_id = p_profile_id and x.created_at > now() - interval '1 minute') then
    raise exception 'A text went to this account a moment ago. Wait a minute and try again.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.admin_audit_log l
       where l.actor_id = v_uid and l.action = 'user.phone_change_request'
         and l.created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many number changes in an hour. Try again later.' using errcode = 'P0001';
  end if;
  update public.phone_change_requests x
     set cancelled_at = now()
   where x.profile_id = p_profile_id and x.confirmed_at is null and x.cancelled_at is null;
  v_token := encode(extensions.gen_random_bytes(18), 'hex');
  insert into public.phone_change_requests (profile_id, new_phone, token_hash)
  values (p_profile_id, v_phone, encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'))
  returning * into r;
  -- 'otp': the gateway sends it as a code, and admins see it masked (0183).
  insert into public.sms_outbox (to_phone, body, channel, created_by)
  values (v_phone,
          'GET.ride: support is moving your account to this number. To confirm, open https://getride.my/number/'
            || v_token || ' within 24 hours. Not you? Ignore this text.',
          'otp', null);
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'user.phone_change_request', p_profile_id,
          jsonb_build_object('request', r.id, 'phone_tail', right(v_digits, 4)));
  return public.phone_change_json(r);
end;
$$;
revoke execute on function public.admin_phone_change_request(uuid, text) from public, anon;
grant execute on function public.admin_phone_change_request(uuid, text) to authenticated;

create or replace function public.admin_phone_change_status(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.phone_change_requests;
begin
  if not public.phone_change_caller_ok(false) then
    raise exception 'Only an admin with the Users pages can see a number change.' using errcode = '42501';
  end if;
  select * into r from public.phone_change_requests x
   where x.profile_id = p_profile_id and x.created_at > now() - interval '7 days'
   order by x.created_at desc
   limit 1;
  return public.phone_change_json(r);
end;
$$;
revoke execute on function public.admin_phone_change_status(uuid) from public, anon;
grant execute on function public.admin_phone_change_status(uuid) to authenticated;

-- The link's page: what it would do. Never the account's name or the full number.
create or replace function public.phone_change_lookup(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.phone_change_requests;
begin
  if p_token is null or length(p_token) not between 20 and 100 then
    return jsonb_build_object('status', 'unknown');
  end if;
  select * into r from public.phone_change_requests x
   where x.token_hash = encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
  if r.id is null then
    return jsonb_build_object('status', 'unknown');
  end if;
  return public.phone_change_json(r) - 'id' - 'created_at';
end;
$$;
revoke execute on function public.phone_change_lookup(text) from public;
grant execute on function public.phone_change_lookup(text) to anon, authenticated;

-- Opening the link: the account signs in with the new number from now on.
create or replace function public.phone_change_confirm(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.phone_change_requests;
  v_digits text;
begin
  if p_token is null or length(p_token) not between 20 and 100 then
    raise exception 'This link is not valid.' using errcode = '22023';
  end if;
  select * into r from public.phone_change_requests x
   where x.token_hash = encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
   for update;
  if r.id is null then
    raise exception 'This link is not valid.' using errcode = '22023';
  end if;
  if r.confirmed_at is not null then
    return public.phone_change_json(r) - 'id' - 'created_at';
  end if;
  if r.cancelled_at is not null or r.expires_at <= now() then
    raise exception 'This link has expired. Ask support to send a new one.' using errcode = '22023';
  end if;
  v_digits := regexp_replace(r.new_phone, '\D', '', 'g');
  if public.phone_taken_by_other(v_digits, r.profile_id) then
    raise exception 'This number is already linked to another account.' using errcode = '23505';
  end if;
  -- As Auth stores a phone: digits only. profiles.phone follows (0092).
  update auth.users
     set phone = v_digits, phone_confirmed_at = now(), phone_change = '', phone_change_token = '',
         updated_at = now()
   where id = r.profile_id;
  update auth.identities
     set identity_data = coalesce(identity_data, '{}'::jsonb) || jsonb_build_object('phone', v_digits),
         updated_at = now()
   where user_id = r.profile_id and provider = 'phone';
  update public.profiles p
     set phone = r.new_phone
   where p.id = r.profile_id
     and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') <> v_digits;
  update public.phone_change_requests x
     set confirmed_at = now()
   where x.id = r.id
  returning * into r;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (null, 'user.phone_change_confirmed', r.profile_id,
          jsonb_build_object('request', r.id, 'phone_tail', right(v_digits, 4)));
  return public.phone_change_json(r) - 'id' - 'created_at';
end;
$$;
revoke execute on function public.phone_change_confirm(text) from public;
grant execute on function public.phone_change_confirm(text) to anon, authenticated;

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024120000', '0282_god_view_live') on conflict do nothing;
