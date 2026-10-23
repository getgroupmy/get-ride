-- ============================================================================
-- 0278 — God View: where someone moved (the "Movement" trail), partners and
-- users alike.
--
-- Re-runnable: functions are "create or replace".
--
-- Why: an admin looking at a driver or a rider on God View wants the path
-- they took: the last 24 hours, a past day, or chosen hours of it. The
-- points are in user_location_history (kept 90 days, 0186), but only while
-- the app was open: the closed app's reports (push_background_location,
-- 0272 / 0275) moved the dot on the map and left no trail.
--
-- 1. push_background_location (as 0275) also writes a user_location_history
--    row for each report it takes (one a minute at most, as before).
-- 2. god_view_trail(p_profile_id, p_from, p_to): the points between the two
--    times, oldest first, as [lat, lng, epoch seconds, speed m/s or null].
--      - Only for someone the caller may see on God View (god_view_may_see:
--        God View access, and a sub-admin's own region).
--      - At most 48 hours in one call, and not before the 90 days kept.
--      - At most 4000 points: a longer trail is thinned evenly, the first
--        and last always kept ('thinned' says so).
--      - Every call is in admin_audit_log ('god_view.trail').
-- ============================================================================

-- 1. The closed app's report, now also in the trail ------------------------------
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
  end loop;
  return n;
end;
$$;
revoke execute on function public.push_background_location(text, double precision, double precision) from public;
grant execute on function public.push_background_location(text, double precision, double precision)
  to anon, authenticated;

-- 2. The trail --------------------------------------------------------------------
create or replace function public.god_view_trail(
  p_profile_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_from timestamptz := greatest(p_from, now() - interval '90 days');
  v_to timestamptz := least(coalesce(p_to, now()), now());
  v_total int;
  v_step int;
  v_points jsonb;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only see the movement of someone on your God View map.' using errcode = '42501';
  end if;
  if p_from is null or v_to <= v_from then
    raise exception 'Choose a start time before the end time.' using errcode = '22023';
  end if;
  if v_to - v_from > interval '48 hours' then
    raise exception 'Choose at most 48 hours at a time.' using errcode = '22023';
  end if;

  select count(*) into v_total
    from public.user_location_history h
   where h.user_id = p_profile_id and h.captured_at >= v_from and h.captured_at <= v_to;
  v_step := greatest(1, ceil(v_total / 4000.0)::int);

  select coalesce(jsonb_agg(jsonb_build_array(
           round(x.latitude::numeric, 6), round(x.longitude::numeric, 6),
           floor(extract(epoch from x.captured_at))::bigint, x.speed) order by x.captured_at), '[]'::jsonb)
    into v_points
    from (
      select h.latitude, h.longitude, h.captured_at, h.speed,
             row_number() over (order by h.captured_at) as rn
        from public.user_location_history h
       where h.user_id = p_profile_id and h.captured_at >= v_from and h.captured_at <= v_to
    ) x
   where (x.rn - 1) % v_step = 0 or x.rn = v_total;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.trail', p_profile_id,
          jsonb_build_object('from', v_from, 'to', v_to, 'points', v_total));

  return jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'total', v_total,
    'thinned', v_step > 1,
    'points', v_points);
end;
$$;
revoke execute on function public.god_view_trail(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.god_view_trail(uuid, timestamptz, timestamptz) to authenticated;
