-- ============================================================================
-- 0423: a driver's airport status no longer fails when they are offline
--
-- airport_driver_state (0258) read `z.airport_id` -- the waiting zone the
-- driver is in -- but only filled `z` for a driver who is online with a
-- position from the last 3 minutes. For everyone else (offline, or the app
-- gone quiet) the read failed with "record z is not assigned yet", so the
-- driver app's airport status call errored instead of answering 'outside'.
--
-- The zone is now a plain uuid that starts as null. Nothing else changes:
-- the same states, the same order of checks.
-- ============================================================================

create or replace function public.airport_driver_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  p public.driver_presence;
  q public.airport_queue;
  c public.airport_settings;
  d public.airport_dropoffs;
  a public.airport_areas;
  v_zone uuid;  -- the airport whose waiting zone holds the driver; null when none (or offline)
  o record;
  v_air uuid;
  v_pos int;
  v_total int;
  v_zones jsonb;
  v_sid text;
  v_sname text;
begin
  if v_uid is null then
    return jsonb_build_object('state', 'outside');
  end if;
  select * into p from public.driver_presence where profile_id = v_uid;
  v_sid := public.driver_vehicle_service(v_uid);
  select e.values->>'name' into v_sname from public.settings_entries e
   where e.category = 'vehicle-services' and e.id::text = v_sid;

  select o2.ride_id, r.pickup_door_name, r.pickup_name, r.service, r.airport_pickup_id, o2.stage, o2.until into o
    from public.airport_ride_offers o2
    join public.ride_requests r on r.id = o2.ride_id and r.status = 'open' and r.airport_hold
   where o2.driver_id = v_uid and o2.outcome is null and (o2.until is null or o2.until > now())
   order by o2.offered_at desc
   limit 1;
  if o.ride_id is not null then
    select * into a from public.airport_areas where id = o.airport_pickup_id;
    return jsonb_build_object('state', 'offer', 'ride_id', o.ride_id, 'door', coalesce(o.pickup_door_name, o.pickup_name),
                              'service', o.service, 'stage', o.stage, 'until', o.until,
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code');
  end if;

  select * into q from public.airport_queue where driver_id = v_uid;
  if q.id is not null then
    select * into a from public.airport_areas where id = q.airport_id;
    select * into c from public.airport_settings where airport_id = q.airport_id;
    select count(*) filter (where l.place_at < q.place_at
                              or (l.place_at = q.place_at and (l.joined_at, l.driver_id) < (q.joined_at, q.driver_id))) + 1,
           count(*)
      into v_pos, v_total
      from public.airport_queue l
     where l.airport_id = q.airport_id and (not coalesce(c.queue_by_service, true) or l.service = q.service);
    return jsonb_build_object('state', 'queued', 'position', v_pos, 'total', v_total,
                              'service', case when coalesce(c.queue_by_service, true)
                                              then coalesce((select e.values->>'name' from public.settings_entries e
                                                              where e.id::text = q.service), '') else '' end,
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code',
                              'outside_since', q.outside_since, 'grace_min', c.leave_grace_min);
  end if;

  if p.online and p.updated_at > now() - interval '3 minutes' then
    select zz.airport_id into v_zone from public.airport_zone_at(p.lat, p.lng) zz limit 1;
  end if;

  select * into d from public.airport_dropoffs
   where driver_id = v_uid and used_at is null
   order by dropped_at desc limit 1;
  if d.id is not null then
    select * into c from public.airport_settings where airport_id = d.airport_id;
    if d.dropped_at <= now() - make_interval(mins => coalesce(c.join_window_min, 60)) then
      d := null;
    end if;
  end if;

  v_air := coalesce(v_zone, d.airport_id);
  if v_air is null and p.online and p.updated_at > now() - interval '3 minutes' then
    v_air := public.airport_at(p.lat, p.lng);
  end if;
  if v_air is null then
    return jsonb_build_object('state', 'outside');
  end if;
  select * into a from public.airport_areas where id = v_air;
  select * into c from public.airport_settings where airport_id = v_air;
  select coalesce(jsonb_agg(w.name order by w.position), '[]'::jsonb) into v_zones
    from public.airport_waiting_zones w where w.airport_id = v_air;

  -- A vehicle without an approved service type can't join any queue.
  if v_sid is null and (v_zone is not null or (d.id is not null and d.airport_id = v_air)) then
    return jsonb_build_object('state', 'refused', 'reason', 'no_service',
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code');
  end if;
  if v_zone is not null and (d.id is null or d.airport_id <> v_zone) and coalesce(c.need_dropoff, true) then
    return jsonb_build_object('state', 'refused', 'reason', 'no_dropoff',
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code');
  end if;
  if d.id is not null and d.airport_id = v_air then
    return jsonb_build_object('state', 'dropped', 'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code',
                              'service', case when coalesce(c.queue_by_service, true) then coalesce(v_sname, '') else '' end,
                              'dropped_at', d.dropped_at, 'window_min', coalesce(c.join_window_min, 60),
                              'minutes_left', greatest(0, ceil(extract(epoch from
                                 d.dropped_at + make_interval(mins => coalesce(c.join_window_min, 60)) - now()) / 60)),
                              'zones', v_zones);
  end if;
  if coalesce(c.restrict_pickups, false) and v_zone is null then
    return jsonb_build_object('state', 'around', 'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code',
                              'zones', v_zones);
  end if;
  return jsonb_build_object('state', 'outside');
end;
$$;

revoke execute on function public.airport_driver_state() from public, anon;
grant execute on function public.airport_driver_state() to authenticated;
