-- ============================================================================
-- 0426 — The trip live bridge finds the driver's rides.
--
-- 0404 and 0405 looked for the rides a driver is running with
--
--   r.partner_id in (select pt.id from public.partners pt where pt.auth_user_id = p_profile)
--
-- as if ride_requests.partner_id held a partners.id. It does not: it holds the
-- driver's own account id (their auth uid, which is profiles.id).
--
--   * A ride is claimed under the policy "ride_requests claim open", whose
--     check is partner_id = auth.uid(); the other policies and the guards on
--     the table compare partner_id with auth.uid() too.
--   * The server's own lookups go the same way: ride_partner_card reads
--     partners.auth_user_id = <the ride's partner_id>, and trip_handover and
--     mygig_reassign_apply write an account id there.
--   * The column has no foreign key to partners.
--
-- So for a driver these three never matched a real ride:
--
--   * trip_live_bridge: a driver's background or live fix
--     (push_background_location, push_live_location) never reached
--     ride_requests.partner_live_lat / lng / at;
--   * profile_on_active_trip: push_live_location never answered "live, trip"
--     to a driver, so the phone's 5-second stream was not kept going for the
--     length of the trip;
--   * trip_live_kick: a driver's closed app was never woken.
--
-- The passenger's half (r.rider_id = p_profile) was right and is not changed.
-- The regression tests passed only because they put a partners.id in
-- partner_id, which no real ride has; they now set it the way the app does
-- (supabase/tests/trip_live_bridge_0404.sql, trip_live_sessions_0405.sql).
--
-- The driver is now matched by r.partner_id = p_profile, and by nothing else.
-- The partners.id form is dropped rather than kept beside it: nothing writes
-- that id on a ride, so a match on it could only be a ride that belongs to a
-- different account.
--
-- This turns on, for drivers, what 0404 and 0405 describe and what has never
-- run for them. Read before `supabase db push`:
--
--   * While a driver is on a ride that is accepted, arrived or on_trip, every
--     background or live fix from a phone signed in to their account also
--     moves that ride's partner_live_* (the car the passenger sees).
--   * Once a minute, a driver whose ride position is older than 45 seconds is
--     sent a silent `location_live` push, to every phone of theirs that has
--     location on "Always" / "Allow all the time" and a background key. The
--     phone starts its native 5-second stream (the location indicator on an
--     iPhone, an ongoing "Sharing your live location" notification on Android)
--     and keeps it going until the ride is no longer active.
--   * That is not only a closed app. The open app shares the driver's position
--     when the car has moved 15 m (partner_trip_screen.dart), so a driver
--     standing still for 45 seconds — waiting at the pickup, in a jam — is
--     woken too, with the app on the screen.
--
-- The checks on real phones that 0405 leaves open (docs/KIV.md) come before
-- this reaches the live database.
--
-- The three functions are recreated from their bodies in 0404 and 0405 with
-- only the driver match changed: same signatures, same grants, no DROP.
-- push_background_location and push_live_location call them and are not
-- touched; nor is the `trip-live-kick` cron job.
-- ============================================================================

-- ---- The bridge (0404) --------------------------------------------------------------------------
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
  -- As the driver on a ride they're running: ride_requests.partner_id is the
  -- driver's account id (0426), not a partners.id.
  update public.ride_requests r
     set partner_live_lat = p_lat, partner_live_lng = p_lng,
         partner_live_heading = coalesce(p_heading, r.partner_live_heading),
         partner_live_at = now()
   where r.partner_id = p_profile
     and r.status in ('accepted', 'arrived', 'on_trip');
end;
$$;
revoke execute on function public.trip_live_bridge(uuid, double precision, double precision, double precision)
  from public, anon, authenticated;

-- ---- Is this profile on an active ride, as rider or driver? (0405) -------------------------------
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
       and (r.rider_id = p_profile or r.partner_id = p_profile));
$$;
revoke execute on function public.profile_on_active_trip(uuid) from public, anon, authenticated;

-- ---- trip_live_kick(): wake a phone whose trip fix has gone stale (0405) -------------------------
-- For every participant on an active ride whose own live fix is older than 45 s
-- (or missing) and who may background-report, claim their eligible phones (at
-- most one wake a minute a phone, like a God View ping) and send a
-- `location_live` push. Returns how many phones were woken. The driver of a
-- ride is its partner_id (0426).
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
    select r.partner_id as profile_id, r.partner_live_at as live_at
      from public.ride_requests r
     where r.status in ('accepted', 'arrived', 'on_trip') and r.partner_id is not null
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

notify pgrst, 'reload schema';
