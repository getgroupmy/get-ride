-- ============================================================================
-- 0405 — Continuous live tracking during a trip, even with the app closed.
--
-- Slice 1 (0404) bridges a background fix into the trip's live dot, but a
-- closed app only reports on the background reporter's own schedule (~1/min at
-- most, ~15 min / 200 m natively), so the dot is kept un-frozen rather than
-- live. This is the continuous piece, reusing God View's "Live now" transport
-- (0282) with no native change:
--
--   * push_live_location keeps answering "live" while the poster is on an
--     active ride, so a phone already streaming the 5-second stream carries on
--     for the whole trip (and stops on its own when the ride ends). Gated the
--     same way the background path is (background_checkin_allowed: drivers, or
--     passengers who opted in) — the live columns are already shared during a
--     trip, this only governs the extra background streaming.
--   * trip_live_kick() (pg_cron, every minute) wakes a closed/backgrounded
--     phone whose trip fix has gone stale: it claims that participant's phones
--     and sends them a `location_live` push (location_ping_kick, reason
--     'live') — exactly how god_view_live_start wakes a phone. The native side
--     starts its stream on that push with no God View session needed
--     (AppDelegate.swift `startLive`, LiveLocation.kt), and push_live_location
--     above keeps it going. It only ever fires for an active trip whose last
--     fix is older than 45 s, so while the app is open (or backgrounded but
--     alive, publishing every few seconds) nothing is kicked — only a killed
--     app, which is the whole point.
--
-- Platform ceilings still apply (docs/KIV.md): iOS suppresses the relaunch
-- after a manual force-quit until the next reboot, and some Android OEMs kill
-- the stream; "live after close" therefore means re-acquired within a push
-- cycle, not guaranteed-continuous. The on-device test matrix is the remaining
-- work.
--
-- push_live_location is recreated from its 0404 body (unchanged god view path)
-- plus the trip keep-alive branch, same signature, no DROP.
-- ============================================================================

-- ---- Is this profile on an active ride (as rider or driver)? ------------------------------------
create or replace function public.profile_on_active_trip(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_profile is not null and exists (
    select 1 from public.ride_requests r
     where r.status in ('accepted', 'arrived', 'on_trip')
       and (r.rider_id = p_profile
            or r.partner_id in (select pt.id from public.partners pt where pt.auth_user_id = p_profile)));
$$;
revoke execute on function public.profile_on_active_trip(uuid) from public, anon, authenticated;

-- ---- push_live_location: keep the stream alive for the length of a trip -------------------------
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
      -- No God View share. Keep the stream running for the length of an active
      -- trip (0405), so the dot stays live after the app is closed. Gated like
      -- the background path. The rolling 2-minute window is refreshed on each
      -- fix, so the phone stops within it once the ride ends.
      if public.background_checkin_allowed(t.profile_id) and public.profile_on_active_trip(t.profile_id) then
        return jsonb_build_object('live', true, 'trip', true, 'ends_at', now() + interval '2 minutes',
                                  'ends_in', 120, 'taken', true);
      end if;
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
revoke execute on function public.push_live_location(text, double precision, double precision, double precision, double precision)
  from public;
grant execute on function public.push_live_location(text, double precision, double precision, double precision, double precision)
  to anon, authenticated;

-- ---- trip_live_kick(): wake a killed app whose trip fix has gone stale --------------------------
-- For every participant on an active ride whose own live fix is older than 45 s
-- (or missing) and who may background-report, claim their eligible phones (at
-- most one wake a minute a phone, like a God View ping) and send a
-- `location_live` push. Returns how many phones were woken.
create or replace function public.trip_live_kick()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  with parts as (
    select r.rider_id as profile_id, r.user_live_at as live_at
      from public.ride_requests r
     where r.status in ('accepted', 'arrived', 'on_trip') and r.rider_id is not null
    union all
    select pt.auth_user_id as profile_id, r.partner_live_at as live_at
      from public.ride_requests r
      join public.partners pt on pt.id = r.partner_id
     where r.status in ('accepted', 'arrived', 'on_trip')
  ),
  stale as (
    select profile_id
      from parts
     group by profile_id
    having max(live_at) is null or max(live_at) < now() - interval '45 seconds'
  ),
  eligible as (
    select s.profile_id
      from stale s
     where public.background_checkin_allowed(s.profile_id)
  ),
  phones as (
    select t.id
      from public.push_tokens t
      join eligible e on e.profile_id = t.profile_id
     where t.bg_key_hash is not null
       and t.location_always
       and t.platform in ('ios', 'android')
       and (t.ping_sent_at is null or t.ping_sent_at < now() - interval '55 seconds')
       for update of t
  ),
  claimed as (
    update public.push_tokens t
       set ping_sent_at = now()
      from phones p
     where t.id = p.id
    returning t.id
  )
  select array_agg(id) into v_ids from claimed;
  if coalesce(cardinality(v_ids), 0) = 0 then
    return 0;
  end if;
  perform public.location_ping_kick(v_ids, 'live');
  return cardinality(v_ids);
end;
$$;
revoke execute on function public.trip_live_kick() from public, anon, authenticated;

-- ---- The minute cron -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('trip-live-kick') where exists (
      select 1 from cron.job where jobname = 'trip-live-kick');
    perform cron.schedule('trip-live-kick', '* * * * *', $job$select public.trip_live_kick()$job$);
  end if;
end;
$$;

notify pgrst, 'reload schema';
