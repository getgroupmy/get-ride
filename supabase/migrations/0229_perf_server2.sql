-- ============================================================================
-- 0229 — Cheaper server work, part two (PERF-56, PERF-61, realtime)
--
-- Nothing here changes who may read or write what, or what any function
-- answers; each part only cuts work the database did on every call.
--
-- 1. Rate limits are one row per key per window (PERF-56).
--    auth_rate_take (0137) took an advisory lock, deleted the key's old
--    tries, counted the rest and inserted one row per try: four statements
--    and a growing table on every sign-in check, BLE report and lookup
--    (p50 ~600 ms under load). It now counts in auth_rate_counts, keyed by
--    (bucket, key, window length, window start): one
--    INSERT ... ON CONFLICT DO UPDATE SET hits = hits + 1 RETURNING hits,
--    compared with the limit. The signature, the answer (0, or the seconds
--    until the caller may try again) and the limits are the same; the window
--    is now fixed (it starts on a multiple of its length since the epoch)
--    rather than sliding, so a burst can straddle two windows. A null or
--    empty key is still never limited, and a try over the limit is still not
--    counted. Callers keep failing closed on an error, as before.
--    auth_rate_wait(bucket, key, limit, window) answers the same wait
--    without counting, for the three functions that read auth_rate_hits
--    directly (add_favourite_driver, scheduled_partner_by_code,
--    personal_qr_miss_wait); they now read the counter. Nothing writes
--    auth_rate_hits any more; it is left in place (empty within a day, by
--    the purge job) for anything outside the repo that reads it. Old windows
--    are removed hourly by pg_cron (purge-auth-rate-counts).
--    Counts taken before this migration don't carry over: each key starts
--    its first window afresh.
-- 2. The Bluetooth handshake writes one row per ride side (PERF-61).
--    ble_handshake_proof (0153) inserted a ride_proximity_events row for
--    every report, every 4 s from each phone. It now upserts the side's one
--    row (unique on request_id, side), and only when the report says
--    something new: a first report, a match where there was none, the
--    signal or the dwell crossing what a match needs, the phone moving
--    > 25 m, or the row getting old (match timeout - 4 s, at most 20 s;
--    60 s once the pair has matched and the report can't start the trip).
--    An unmatched report never replaces a matched one. The token this side
--    last matched with is remembered (as an md5, never the token) so a
--    repeat of it skips the two HMACs. Once the pair has matched
--    (ride_ble_secrets.matched_at), a report that is still close enough is
--    answered 'matched' even when the other phone has gone quiet -- new
--    app builds report only on change (first sighting, the threshold
--    crossed either way, a keep-alive every 25 s) and, after 'matched',
--    once every 4 minutes (lib/src/core/ble_handshake.dart,
--    bleShouldReport). Starting the trip still needs both phones fresh.
--    The answers ('off', 'on_trip', 'wrong_status:…', 'rate_limited:N',
--    'no_match', 'waiting', 'matched') and the signature are unchanged, so
--    old builds keep working. Existing rows are cut to one per side first
--    (the newest matched one, else the newest), so the admin's report counts
--    reports from here on rather than from the start.
-- 3. messaging_devices leaves the realtime publication. Every gateway's
--    heartbeat rewrites its row (~80k updates in one stats window), and the
--    only reader is Admin → SMS / WhatsApp, which now reads it every 30 s
--    while open (and on its refresh button). commission_tiers, which the
--    admin page watches, joins the app's live list
--    (lib/src/data/live_tables.dart); it is published since 0218 and added
--    here if a copy lacks it.
-- ============================================================================

-- 1. Rate limit counters ------------------------------------------------------
create table if not exists public.auth_rate_counts (
  bucket       text        not null,
  key          text        not null,
  window_s     integer     not null,
  window_start timestamptz not null,
  hits         integer     not null default 0,
  primary key (bucket, key, window_s, window_start)
);
create index if not exists auth_rate_counts_window_start on public.auth_rate_counts (window_start);

-- Nobody reads or writes it but the functions below.
alter table public.auth_rate_counts enable row level security;
revoke all on table public.auth_rate_counts from public, anon, authenticated;

-- Counts one try in [p_bucket] for [p_key]: 0 when it is within [p_limit] in
-- this [p_window] (and is counted), else the seconds until the window ends
-- (and nothing is counted). A null key is never limited.
create or replace function public.auth_rate_take(p_bucket text, p_key text, p_limit integer, p_window interval)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secs  integer := greatest(1, ceil(extract(epoch from p_window))::integer);
  v_start timestamptz := to_timestamp(floor(extract(epoch from now()) / v_secs) * v_secs);
  v_hits  integer;
begin
  if p_key is null or p_key = '' then
    return 0;
  end if;
  if p_limit < 1 then
    return greatest(1, ceil(extract(epoch from (v_start + make_interval(secs => v_secs) - now())))::integer);
  end if;
  insert into public.auth_rate_counts as c (bucket, key, window_s, window_start, hits)
  values (p_bucket, p_key, v_secs, v_start, 1)
  on conflict (bucket, key, window_s, window_start) do update
    set hits = c.hits + 1
    where c.hits < p_limit
  returning c.hits into v_hits;
  -- No row back: the window was already full, and this try isn't counted.
  if v_hits is null or v_hits > p_limit then
    return greatest(1, ceil(extract(epoch from (v_start + make_interval(secs => v_secs) - now())))::integer);
  end if;
  return 0;
end;
$$;

revoke execute on function public.auth_rate_take(text, text, integer, interval) from public, anon, authenticated;

-- The seconds until [p_key] may try again in [p_bucket] (0 = now), counting
-- nothing. A null key is never limited.
create or replace function public.auth_rate_wait(p_bucket text, p_key text, p_limit integer, p_window interval)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  with w as (
    select greatest(1, ceil(extract(epoch from p_window))::integer) as secs
  ), s as (
    select secs, to_timestamp(floor(extract(epoch from now()) / secs) * secs) as start from w
  )
  select coalesce((
    select greatest(1, ceil(extract(epoch from (s.start + make_interval(secs => s.secs) - now())))::integer)
      from public.auth_rate_counts c, s
     where p_key is not null and p_key <> ''
       and c.bucket = p_bucket and c.key = p_key and c.window_s = s.secs and c.window_start = s.start
       and c.hits >= p_limit), 0);
$$;

revoke execute on function public.auth_rate_wait(text, text, integer, interval) from public, anon, authenticated;

-- Seconds until the caller may look up unknown tokens again (0 = now).
create or replace function public.personal_qr_miss_wait(p_uid uuid, p_ip text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(public.auth_rate_wait('my_qr_miss', p_uid::text, 20, interval '1 hour'),
                  public.auth_rate_wait('my_qr_miss_ip', p_ip, 60, interval '1 hour'));
$$;

-- The two functions that peeked at auth_rate_hits, reading the counter instead
-- (otherwise as in 0160 and 0198).
create or replace function public.add_favourite_driver(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_ip   text := public.request_client_ip();
  v_code text;
  v_wait int;
  p      public.partners;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Too many codes that matched nobody: no lookups for a while.
  v_wait := greatest(public.auth_rate_wait('my_ride_code_miss', v_uid::text, 10, interval '1 hour'),
                     public.auth_rate_wait('my_ride_code_miss_ip', v_ip, 30, interval '1 hour'));
  if v_wait > 0 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', v_wait);
  end if;

  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_code := regexp_replace(v_code, '^GETRIDE://MYRIDE/', '');
  v_code := regexp_replace(v_code, '[/-]', '', 'g');
  if v_code !~ '^[2-9A-HJ-NP-Z]{8}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  select * into p from public.partners where my_ride_code = v_code limit 1;
  if p.id is null or p.auth_user_id is null then
    perform public.auth_rate_take('my_ride_code_miss', v_uid::text, 10, interval '1 hour');
    perform public.auth_rate_take('my_ride_code_miss_ip', v_ip, 30, interval '1 hour');
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if p.auth_user_id = v_uid then
    return jsonb_build_object('ok', false, 'error', 'own_code');
  end if;
  if p.status::text in ('blocked', 'rejected') then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  if not exists (select 1 from public.favourite_drivers where rider_id = v_uid and driver_id = p.auth_user_id)
     and (select count(*) from public.favourite_drivers where rider_id = v_uid) >= 50 then
    return jsonb_build_object('ok', false, 'error', 'limit_reached');
  end if;
  -- A profile row is what the rider id points at; every signed-in account
  -- has one, but don't fail on one that hasn't.
  if not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'no_profile');
  end if;

  insert into public.favourite_drivers (rider_id, driver_id)
  values (v_uid, p.auth_user_id)
  on conflict (rider_id, driver_id) do nothing;

  return jsonb_build_object('ok', true, 'driver', public.my_ride_driver_card(p));
end;
$$;

create or replace function public.scheduled_partner_by_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_ip    text := public.request_client_ip();
  v_code  text;
  v_token text := public.personal_qr_token_of(p_code);
  v_wait  int;
  v_owner uuid;
  p       public.partners;
  q       public.personal_qr_codes;
begin
  v_wait := greatest(public.auth_rate_wait('my_ride_code_miss', v_uid::text, 10, interval '1 hour'),
                     public.auth_rate_wait('my_ride_code_miss_ip', v_ip, 30, interval '1 hour'));
  if v_wait > 0 then
    raise exception 'SCHEDULED_CODE_WAIT' using hint = 'Too many codes that didn''t match. Try again later.';
  end if;

  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_code := regexp_replace(v_code, '^GETRIDE://MYRIDE/', '');
  v_code := regexp_replace(v_code, '[/-]', '', 'g');
  if v_code ~ '^[2-9A-HJ-NP-Z]{8}$' then
    select * into p from public.partners where my_ride_code = v_code limit 1;
    v_owner := p.auth_user_id;
  elsif v_token is not null then
    select * into q from public.personal_qr_codes where token = v_token;
    if q.id is not null and q.kind = 'me' and public.personal_qr_status(q.expires_at, q.revoked_at) = 'active' then
      v_owner := q.owner_id;
    end if;
  else
    raise exception 'SCHEDULED_CODE_INVALID' using hint = 'Enter the driver''s My Ride code or scan their GET.me QR.';
  end if;

  if v_owner is null then
    perform public.auth_rate_take('my_ride_code_miss', v_uid::text, 10, interval '1 hour');
    perform public.auth_rate_take('my_ride_code_miss_ip', v_ip, 30, interval '1 hour');
    raise exception 'SCHEDULED_CODE_UNKNOWN' using hint = 'No driver has this code. Check it, or ask for their GET.me QR.';
  end if;
  p := public.my_ride_partner_of(v_owner);
  if p.id is null or not public.partner_status_bookable(p.status::text) then
    raise exception 'SCHEDULED_CODE_UNAVAILABLE' using hint = 'This driver can''t take rides at the moment.';
  end if;
  return v_owner;
end;
$$;

-- Old windows go hourly; so do the rows auth_rate_hits held before this.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-auth-rate-counts';
    perform cron.schedule('purge-auth-rate-counts', '11 * * * *', $job$
      delete from public.auth_rate_counts where window_start + make_interval(secs => window_s) < now();
      delete from public.auth_rate_hits where at < now() - interval '1 day';
    $job$);
  end if;
end
$$;

-- 2. Bluetooth handshake: one row per ride side --------------------------------
alter table public.ride_proximity_events add column if not exists token_digest text;
alter table public.ride_proximity_events add column if not exists token_window bigint;
alter table public.ride_ble_secrets add column if not exists matched_at timestamptz;

-- One row per (ride, side): the newest matched report, else the newest.
delete from public.ride_proximity_events e
 using (
   select id, row_number() over (partition by request_id, side order by matched desc, at desc, id desc) as n
     from public.ride_proximity_events
 ) k
 where k.id = e.id and k.n > 1;

create unique index if not exists ride_proximity_events_request_side
  on public.ride_proximity_events (request_id, side);

create or replace function public.ble_handshake_proof(p_request uuid, p_seen_token text, p_rssi int,
                                                      p_seen_ms int, p_lat double precision, p_lng double precision)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_side text;
  v_peer text;
  v_secret bytea;
  v_matched_at timestamptz;
  v_window bigint := public.ble_window();
  v_token text := lower(btrim(coalesce(p_seen_token, '')));
  v_digest text := md5(lower(btrim(coalesce(p_seen_token, ''))));
  v_token_window bigint;
  v_matched boolean := false;
  v_close boolean;
  v_can_start boolean;
  v_hold interval;
  v_write boolean;
  v_wait int;
  s jsonb := public.reliability_ble();
  v_threshold int := (s->>'rssi_threshold_dbm')::int;
  v_timeout int := (s->>'match_timeout_s')::int;
  v_since timestamptz := now() - make_interval(secs => (s->>'match_timeout_s')::int);
  mine public.ride_proximity_events;
  theirs public.ride_proximity_events;
begin
  v_side := public.ble_ride_side(p_request);
  select * into r from public.ride_requests where id = p_request;
  if not (s->>'enabled')::boolean then
    return 'off';
  end if;
  if r.status = 'on_trip' then
    return 'on_trip';
  end if;
  if r.status not in ('accepted', 'arrived') then
    return 'wrong_status:' || r.status;
  end if;
  -- Answered, not raised, so the try just counted stays counted.
  v_wait := public.auth_rate_take('ble_proof', p_request::text || ':' || v_side, 30, interval '1 minute');
  if v_wait > 0 then
    return 'rate_limited:' || v_wait;
  end if;

  v_peer := case v_side when 'driver' then 'rider' else 'driver' end;
  v_close := coalesce(p_rssi >= v_threshold and p_seen_ms >= 5000, false);
  v_can_start := r.status = 'arrived' and (s->>'autostart_no_pin')::boolean;
  select * into mine from public.ride_proximity_events e where e.request_id = p_request and e.side = v_side;
  select b.secret, b.matched_at into v_secret, v_matched_at
    from public.ride_ble_secrets b where b.request_id = p_request;

  -- The token this side last matched with, still in its time: it matches
  -- again without making the tokens again.
  if mine.id is not null and mine.matched and mine.token_digest = v_digest
     and mine.token_window >= v_window - 1 then
    v_matched := true;
    v_token_window := mine.token_window;
  elsif v_secret is not null then
    if v_token = public.ble_token(v_secret, p_request, v_peer, v_window) then
      v_matched := true;
      v_token_window := v_window;
    elsif v_token = public.ble_token(v_secret, p_request, v_peer, v_window - 1) then
      v_matched := true;
      v_token_window := v_window - 1;
    end if;
  end if;

  -- Written only when it says something new, or the row is getting old.
  v_hold := case when v_matched_at is not null and not v_can_start then interval '60 seconds'
                 else make_interval(secs => greatest(0, least(20, v_timeout - 4))) end;
  v_write := mine.id is null
    or (v_matched and not mine.matched)
    or (v_matched = mine.matched and (
          mine.at <= now() - v_hold
          or coalesce(p_rssi >= v_threshold, false) is distinct from coalesce(mine.rssi >= v_threshold, false)
          or coalesce(p_seen_ms >= 5000, false) is distinct from coalesce(mine.seen_ms >= 5000, false)
          or (p_lat is null) <> (mine.lat is null)
          or (p_lat is not null and mine.lat is not null
              and public.geo_distance_m(p_lat, p_lng, mine.lat, mine.lng) > 25)
          or (v_matched and mine.token_digest is distinct from v_digest)));
  if v_write then
    insert into public.ride_proximity_events as e
      (request_id, profile_id, side, matched, rssi, seen_ms, lat, lng, token_digest, token_window)
    values (p_request, auth.uid(), v_side, v_matched, p_rssi, p_seen_ms, p_lat, p_lng,
            case when v_matched then v_digest end, v_token_window)
    on conflict (request_id, side) do update
      set profile_id = excluded.profile_id,
          matched = excluded.matched,
          rssi = excluded.rssi,
          seen_ms = excluded.seen_ms,
          lat = excluded.lat,
          lng = excluded.lng,
          token_digest = excluded.token_digest,
          token_window = excluded.token_window,
          at = now()
    returning e.* into mine;
  end if;
  if not v_matched then
    return 'no_match';
  end if;

  -- Both sides, each close enough for long enough, recently.
  select * into theirs from public.ride_proximity_events e where e.request_id = p_request and e.side = v_peer;
  if mine.matched and mine.at >= v_since and mine.rssi >= v_threshold and mine.seen_ms >= 5000
     and theirs.matched and theirs.at >= v_since and theirs.rssi >= v_threshold and theirs.seen_ms >= 5000
     and mine.lat is not null and theirs.lat is not null
     and public.geo_distance_m(mine.lat, mine.lng, theirs.lat, theirs.lng) <= 50 then
    if v_can_start then
      update public.ride_requests
         set status = 'on_trip', started_at = now(), start_method = 'ble'
       where id = p_request and status = 'arrived';
      return 'on_trip';
    end if;
    if v_matched_at is null then
      update public.ride_ble_secrets set matched_at = now() where request_id = p_request and matched_at is null;
    end if;
    return 'matched';
  end if;
  -- The pair has matched before, and this phone still sees the other close.
  if v_matched_at is not null and v_close then
    return 'matched';
  end if;
  return 'waiting';
end;
$$;

-- 3. Realtime publication ----------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messaging_devices'
  ) then
    alter publication supabase_realtime drop table public.messaging_devices;
  end if;
  if to_regclass('public.commission_tiers') is not null and not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'commission_tiers'
  ) then
    alter publication supabase_realtime add table public.commission_tiers;
  end if;
end
$$;

notify pgrst, 'reload schema';
