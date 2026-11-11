-- ============================================================================
-- 0404 — Keep a trip's live dot moving while the app is closed.
--
-- The live map dot during a ride (ride_requests.partner_live_* / user_live_*)
-- is published by the running app from its own GPS stream. When the app is
-- swiped away the stream dies, so the other party's dot freezes — even for a
-- user who granted "Always"/"Allow all the time", because that permission lets
-- a *running* app read location in the background; it does not keep a killed
-- app alive.
--
-- But a phone on "Always" already keeps telling the server where it is with no
-- app running, through the native background reporter (0272) and God View's
-- live stream (0282): both post anonymously, keyed by the install's background
-- key, through push_background_location and push_live_location. Those fixes
-- land in the presence/God View stores only — never on the trip the person is
-- actually on.
--
-- This bridges them. When one of those background fixes arrives for a phone
-- whose account is a participant in an active ride, it also refreshes that
-- ride's live columns — the rider's on a ride they booked, the driver's on a
-- ride they're running. Same two columns, same two recipients, same purpose
-- the app already shares them for (your driver/passenger sees you during the
-- trip); the fix just keeps flowing while the app is in a pocket or closed.
--
-- No new data is exposed: trip_live_bridge only ever writes the live columns of
-- a ride the posting account is on, and only while it is accepted/arrived/
-- on_trip. The two ingestion functions are recreated with their current bodies
-- (0272 / 0282) plus one bridge call, same signatures, so there is no DROP.
--
-- Cadence note (for the follow-ups parked in docs/KIV.md): the background path
-- (push_background_location) reports at most about once a minute, and the
-- native reporter's own schedule is ~15 min / 200 m, so a closed-app trip dot
-- refreshes coarsely. The 5-second cadence (push_live_location) only runs while
-- a live stream is open. A trip-scoped live session that opens that stream for
-- the duration of a ride — the "continuous after close" piece — is the next
-- slice; it needs the native streaming and an on-device test matrix.
-- ============================================================================

-- ---- The bridge --------------------------------------------------------------------------------
-- Given a background fix for [p_profile], refresh the live columns of any ride
-- that profile is actively on: as the rider (user_live_*) and/or as the driver
-- (partner_live_*). Inert when the profile is on no active ride.
create or replace function public.trip_live_bridge(
  p_profile  uuid,
  p_lat      double precision,
  p_lng      double precision,
  p_heading  double precision default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_profile is null or p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return;
  end if;
  -- As the rider on a ride they booked.
  update public.ride_requests r
     set user_live_lat = p_lat, user_live_lng = p_lng, user_live_at = now()
   where r.rider_id = p_profile
     and r.status in ('accepted', 'arrived', 'on_trip');
  -- As the driver on a ride they're running (partners.auth_user_id is the
  -- driver's profile id).
  update public.ride_requests r
     set partner_live_lat = p_lat, partner_live_lng = p_lng,
         partner_live_heading = coalesce(p_heading, r.partner_live_heading),
         partner_live_at = now()
   where r.status in ('accepted', 'arrived', 'on_trip')
     and r.partner_id in (select pt.id from public.partners pt where pt.auth_user_id = p_profile);
end;
$$;
revoke execute on function public.trip_live_bridge(uuid, double precision, double precision, double precision)
  from public, anon, authenticated;

-- ---- 1. Background path (0272/0333): every background fix also feeds the trip ------------------
-- Current body (0333: the background_checkin_allowed gate, area refresh and
-- location history), plus the bridge call for each phone the fix was taken for.
create or replace function public.push_background_location(
  p_key text,
  p_lat double precision,
  p_lng double precision
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  n int := 0;
  r record;
begin
  if p_key is null or length(p_key) not between 32 and 128
     or p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return 0;
  end if;
  v_hash := encode(extensions.digest(convert_to(p_key, 'UTF8'), 'sha256'), 'hex');
  for r in
    update public.push_tokens t
       set last_lat = p_lat,
           last_lng = p_lng,
           located_at = now(),
           located_bg = true
      from public.push_tokens o
     where o.id = t.id
       and t.bg_key_hash = v_hash
       and t.location_always
       and t.profile_id is not null
       -- 0333: drivers, or passengers who opted in while the switch is on.
       and public.background_checkin_allowed(t.profile_id)
       -- The open app's own check-in wins for 3 minutes; one background
       -- report a minute at most.
       and (t.located_at is null
            or t.located_at < now() - case when t.located_bg then interval '60 seconds' else interval '3 minutes' end)
    returning t.id, t.profile_id, o.last_lat as prev_lat, o.last_lng as prev_lng
  loop
    n := n + 1;
    perform public.push_area_refresh(r.id, r.prev_lat, r.prev_lng);
    insert into public.user_location_history (user_id, latitude, longitude, captured_at)
    values (r.profile_id, p_lat, p_lng, now());
    -- Keep this phone's active trip dot moving too (0404).
    perform public.trip_live_bridge(r.profile_id, p_lat, p_lng, null);
  end loop;
  return n;
end;
$$;

-- ---- 2. Live path (0282): the 5 s stream also feeds the trip ----------------------------------
-- Current 0282 body, plus the bridge call once the posting install is known —
-- before the God View throttle, so the trip gets the fix even on a tick the
-- 4-second God View cap skips.
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
  -- Keep this phone's active trip dot moving too (0404), on every live fix.
  perform public.trip_live_bridge(t.profile_id, p_lat, p_lng, null);
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

notify pgrst, 'reload schema';
