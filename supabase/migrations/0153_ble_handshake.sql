-- ============================================================================
-- 0153: the phones find each other at the kerb (reliability Phase D1)
--
-- The rider's and the driver's phones each advertise a short Bluetooth token
-- and scan for the other's. Each reports what it saw; when both have seen
-- the other, close and for long enough, and their GPS fixes agree, the
-- server says it's the right car — and, where the operator allows it,
-- starts the trip without the 4-digit code.
--
--   * ride_ble_secrets: a random key per ride that never leaves the server;
--   * get_trip_ble_token(request): this side's token and the other side's,
--     HMAC(key, request : side : 5-minute window), first 8 bytes in hex. A
--     token is good for its window and the one before, so a pair seen
--     across the boundary still matches and a captured one dies in minutes;
--   * ble_handshake_proof(request, seen_token, rssi, seen_ms, lat, lng):
--     the caller reports the other side's token it saw. Recorded in
--     ride_proximity_events (matched or not). Answers 'no_match', 'waiting'
--     (only this side has seen the other), 'matched' (both, close enough),
--     'on_trip' (matched and started) or 'rate_limited:N';
--   * the switches live in the reliability-messaging settings row (0152):
--     ble_enabled (off), ble_android, ble_ios, ble_autostart_no_pin (off),
--     ble_rssi_threshold_dbm (-70), ble_match_timeout_s (20);
--   * ble_start_stats(days): trips started by Bluetooth, by code or neither.
--
-- A match needs both sides, each seeing the other for >= 5 s at or above the
-- RSSI threshold, both within ble_match_timeout_s, and fixes <= 50 m apart.
-- Autostart only from 'arrived'. Off by default: nothing changes until the
-- admin turns it on, and the code (start_trip, 0152) always still works.
-- ============================================================================

create table if not exists public.ride_ble_secrets (
  request_id uuid primary key references public.ride_requests(id) on delete cascade,
  secret     bytea not null,
  created_at timestamptz not null default now()
);
alter table public.ride_ble_secrets enable row level security;
revoke all on public.ride_ble_secrets from anon, authenticated;

create table if not exists public.ride_proximity_events (
  id         bigint generated always as identity primary key,
  request_id uuid not null references public.ride_requests(id) on delete cascade,
  profile_id uuid not null,
  side       text not null check (side in ('rider', 'driver')),
  matched    boolean not null,
  rssi       int,
  seen_ms    int,
  lat        double precision,
  lng        double precision,
  at         timestamptz not null default now()
);
create index if not exists ride_proximity_events_request on public.ride_proximity_events (request_id, at desc);
alter table public.ride_proximity_events enable row level security;
create policy "ride_proximity_events admin read" on public.ride_proximity_events
  for select using (public.caller_is_admin());
revoke all on public.ride_proximity_events from anon, authenticated;
grant select on public.ride_proximity_events to authenticated;

-- ---- The switches ------------------------------------------------------------------
create or replace function public.reliability_ble()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select coalesce((select e.values from public.settings_entries e
                      where e.id = '72656c69-6162-4c69-8000-000000000001'), '{}'::jsonb) as j
  )
  select jsonb_build_object(
    'enabled', coalesce(j->>'ble_enabled', '') in ('true', 't', '1', 'on'),
    'android', coalesce(j->>'ble_android', '') not in ('false', 'f', '0', 'off'),
    'ios', coalesce(j->>'ble_ios', '') not in ('false', 'f', '0', 'off'),
    'autostart_no_pin', coalesce(j->>'ble_autostart_no_pin', '') in ('true', 't', '1', 'on'),
    'rssi_threshold_dbm', greatest(-100, least(-30, coalesce(
        case when j->>'ble_rssi_threshold_dbm' ~ '^-?[0-9]+$' then (j->>'ble_rssi_threshold_dbm')::int end, -70))),
    'match_timeout_s', greatest(5, least(120, coalesce(
        case when j->>'ble_match_timeout_s' ~ '^[0-9]+$' then (j->>'ble_match_timeout_s')::int end, 20)))
  ) from v;
$$;
revoke execute on function public.reliability_ble() from public, anon;
grant execute on function public.reliability_ble() to authenticated;

-- ---- Tokens ------------------------------------------------------------------------
create or replace function public.ble_token(p_secret bytea, p_request uuid, p_side text, p_window bigint)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(substring(hmac(convert_to(p_request::text || ':' || p_side || ':' || p_window, 'UTF8'),
                               p_secret, 'sha256') from 1 for 8), 'hex');
$$;
revoke execute on function public.ble_token(bytea, uuid, text, bigint) from public, anon, authenticated;

create or replace function public.ble_window(p_at timestamptz default now())
returns bigint
language sql
stable
as $$
  select floor(extract(epoch from p_at) / 300)::bigint;
$$;

-- Which side of the ride the caller is on; anyone else is refused.
create or replace function public.ble_ride_side(p_request uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_side text;
begin
  select case when r.partner_id = auth.uid() then 'driver'
              when r.rider_id = auth.uid() then 'rider' end
    into v_side
    from public.ride_requests r where r.id = p_request;
  if auth.uid() is null or v_side is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return v_side;
end;
$$;
revoke execute on function public.ble_ride_side(uuid) from public, anon, authenticated;

create or replace function public.get_trip_ble_token(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r public.ride_requests;
  v_side text;
  v_secret bytea;
  v_window bigint := public.ble_window();
  s jsonb := public.reliability_ble();
begin
  v_side := public.ble_ride_side(p_request);
  select * into r from public.ride_requests where id = p_request;
  if not (s->>'enabled')::boolean then
    return jsonb_build_object('enabled', false);
  end if;
  if r.status not in ('accepted', 'arrived') then
    return jsonb_build_object('enabled', true, 'status', r.status);
  end if;
  insert into public.ride_ble_secrets (request_id, secret) values (p_request, gen_random_bytes(32))
  on conflict (request_id) do nothing;
  select b.secret into v_secret from public.ride_ble_secrets b where b.request_id = p_request;
  return jsonb_build_object(
    'enabled', true,
    'status', r.status,
    'side', v_side,
    'token', public.ble_token(v_secret, p_request, v_side, v_window),
    'peer_token', public.ble_token(v_secret, p_request,
                                   case v_side when 'driver' then 'rider' else 'driver' end, v_window),
    'expires_at', to_timestamp((v_window + 1) * 300),
    'settings', s
  );
end;
$$;
revoke execute on function public.get_trip_ble_token(uuid) from public, anon;
grant execute on function public.get_trip_ble_token(uuid) to authenticated;

-- Great-circle distance in metres.
create or replace function public.geo_distance_m(lat1 double precision, lng1 double precision,
                                                 lat2 double precision, lng2 double precision)
returns double precision
language sql
immutable
as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)));
$$;

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
  v_window bigint := public.ble_window();
  v_matched boolean;
  v_wait int;
  s jsonb := public.reliability_ble();
  v_threshold int := (s->>'rssi_threshold_dbm')::int;
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
  select b.secret into v_secret from public.ride_ble_secrets b where b.request_id = p_request;
  v_matched := v_secret is not null and lower(btrim(coalesce(p_seen_token, ''))) in (
    public.ble_token(v_secret, p_request, v_peer, v_window),
    public.ble_token(v_secret, p_request, v_peer, v_window - 1));

  insert into public.ride_proximity_events (request_id, profile_id, side, matched, rssi, seen_ms, lat, lng)
  values (p_request, auth.uid(), v_side, v_matched, p_rssi, p_seen_ms, p_lat, p_lng);
  if not v_matched then
    return 'no_match';
  end if;

  -- Both sides, each close enough for long enough, recently.
  select * into mine from public.ride_proximity_events e
   where e.request_id = p_request and e.side = v_side and e.matched and e.at >= v_since
     and e.rssi >= v_threshold and e.seen_ms >= 5000
   order by e.id desc limit 1;
  select * into theirs from public.ride_proximity_events e
   where e.request_id = p_request and e.side = v_peer and e.matched and e.at >= v_since
     and e.rssi >= v_threshold and e.seen_ms >= 5000
   order by e.id desc limit 1;
  if mine.id is null or theirs.id is null then
    return 'waiting';
  end if;
  if mine.lat is null or theirs.lat is null
     or public.geo_distance_m(mine.lat, mine.lng, theirs.lat, theirs.lng) > 50 then
    return 'waiting';
  end if;

  if r.status = 'arrived' and (s->>'autostart_no_pin')::boolean then
    update public.ride_requests
       set status = 'on_trip', started_at = now(), start_method = 'ble'
     where id = p_request and status = 'arrived';
    return 'on_trip';
  end if;
  return 'matched';
end;
$$;
revoke execute on function public.ble_handshake_proof(uuid, text, int, int, double precision, double precision)
  from public, anon;
grant execute on function public.ble_handshake_proof(uuid, text, int, int, double precision, double precision)
  to authenticated;

-- ---- Admin: how trips started ------------------------------------------------------
create or replace function public.ble_start_stats(p_days int default 7)
returns table (by_ble bigint, by_pin bigint, by_none bigint, by_unknown bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  select count(*) filter (where r.start_method = 'ble'),
         count(*) filter (where r.start_method = 'pin'),
         count(*) filter (where r.start_method = 'none'),
         count(*) filter (where r.start_method is null)
    from public.ride_requests r
   where r.started_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
end;
$$;
revoke execute on function public.ble_start_stats(int) from public, anon;
grant execute on function public.ble_start_stats(int) to authenticated;

notify pgrst, 'reload schema';
