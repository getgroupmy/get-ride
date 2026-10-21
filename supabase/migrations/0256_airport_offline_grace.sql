-- ============================================================================
-- 0256: going offline starts an airport queue place's leave-grace timer.
--
-- airport_on_presence (0249) read z.airport_id when the driver was offline,
-- where z had never been assigned, so it raised "record \"z\" is not
-- assigned yet". The presence trigger caught the error and only logged a
-- warning, so a driver who went offline kept their place with no grace
-- timer running. The zone now goes through a plain uuid that is null when
-- offline or outside every zone; nothing else changes.
-- ============================================================================

create or replace function public.airport_on_presence(p_driver uuid, p_online boolean, p_lat float8, p_lng float8)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  z record;
  v_airport uuid;
  q public.airport_queue;
  c public.airport_settings;
  d public.airport_dropoffs;
  v_service text;
  v_ride uuid;
begin
  perform set_config('getride.airport_server', 'on', true);
  -- Offline (or no position): no zone. z is only read once it has a row.
  if p_online and p_lat is not null and p_lng is not null then
    select * into z from public.airport_zone_at(p_lat, p_lng);
    if found then
      v_airport := z.airport_id;
    end if;
  end if;
  select * into q from public.airport_queue where driver_id = p_driver;

  if v_airport is null then
    -- Outside every zone, or offline: the place is kept for the grace minutes.
    if q.id is not null then
      if q.outside_since is null then
        update public.airport_queue set outside_since = now() where id = q.id;
      elsif q.outside_since <= now() - make_interval(mins => coalesce(
              (select leave_grace_min from public.airport_settings where airport_id = q.airport_id), 3)) then
        delete from public.airport_queue where id = q.id;
      end if;
    end if;
    return;
  end if;

  if q.id is not null and q.airport_id = v_airport then
    if q.outside_since is not null then
      update public.airport_queue set outside_since = null where id = q.id;
    end if;
  else
    if q.id is not null then
      delete from public.airport_queue where id = q.id;
    end if;
    select * into c from public.airport_settings where airport_id = v_airport;
    -- The line is the vehicle's approved service; without one, no queue.
    v_service := public.driver_vehicle_service(p_driver);
    if c.airport_id is not null and v_service is not null then
      select * into d from public.airport_dropoffs
       where driver_id = p_driver and airport_id = v_airport and used_at is null
         and dropped_at > now() - make_interval(mins => c.join_window_min)
       order by dropped_at
       limit 1;
      if d.id is not null then
        insert into public.airport_queue (airport_id, driver_id, service, dropoff_id, place_at)
        values (v_airport, p_driver, v_service, d.id, d.dropped_at)
        on conflict (driver_id) do nothing;
        update public.airport_dropoffs set used_at = now() where id = d.id;
      elsif not c.need_dropoff then
        insert into public.airport_queue (airport_id, driver_id, service, place_at)
        values (v_airport, p_driver, v_service, now())
        on conflict (driver_id) do nothing;
      end if;
    end if;
  end if;

  -- Someone may now be offered a held pickup here.
  for v_ride in
    select r.id from public.ride_requests r
     where r.status = 'open' and r.airport_hold and r.airport_pickup_id = v_airport
     order by r.created_at
  loop
    perform public.airport_dispatch(v_ride);
  end loop;
end;
$$;
revoke execute on function public.airport_on_presence(uuid, boolean, float8, float8) from public, anon, authenticated;
