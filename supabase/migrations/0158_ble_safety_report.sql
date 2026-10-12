-- ============================================================================
-- 0158: Bluetooth & safety report (Admin → Reports → Bluetooth & safety)
--
-- One read for the page, so its numbers agree with each other:
--
--   ble_safety_report(p_days)        how trips started (Bluetooth / code /
--                                    none / older app), day by day; how the
--                                    pickup handshake went (rides that used
--                                    it, both phones present, both phones
--                                    seen each other); the trip-safety
--                                    signals (0154) and lost items.
--   ble_safety_report_trips(p_days)  the trips behind the safety numbers,
--                                    newest first, to open one.
--
-- Admins only (caller_is_admin), like ble_start_stats / trip_safety_summary.
-- Days are Malaysian days (Asia/Kuala_Lumpur), the app's own clock.
--
-- Rollback: drop function public.ble_safety_report(int);
--           drop function public.ble_safety_report_trips(int, int);
-- ============================================================================

create or replace function public.ble_safety_report(p_days int default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days int := greatest(1, least(coalesce(p_days, 7), 90));
  v_tz text := 'Asia/Kuala_Lumpur';
  v_today date := (now() at time zone v_tz)::date;
  v_first date := v_today - (v_days - 1);
  v_since timestamptz := (v_first::timestamp) at time zone v_tz;
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'days', v_days,
    'since', v_since,
    'starts', (
      select jsonb_build_object(
        'ble', count(*) filter (where r.start_method = 'ble'),
        'pin', count(*) filter (where r.start_method = 'pin'),
        'none', count(*) filter (where r.start_method = 'none'),
        'unknown', count(*) filter (where r.start_method is null))
        from public.ride_requests r
       where r.started_at >= v_since),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', d.day,
               'ble', coalesce(c.ble, 0),
               'pin', coalesce(c.pin, 0),
               'other', coalesce(c.other, 0)) order by d.day), '[]'::jsonb)
        from (select (v_first + i) as day from generate_series(0, v_days - 1) i) d
        left join (
          select (r.started_at at time zone v_tz)::date as day,
                 count(*) filter (where r.start_method = 'ble') as ble,
                 count(*) filter (where r.start_method = 'pin') as pin,
                 count(*) filter (where r.start_method is distinct from 'ble'
                                    and r.start_method is distinct from 'pin') as other
            from public.ride_requests r
           where r.started_at >= v_since
           group by 1
        ) c on c.day = d.day),
    'handshake', (
      select jsonb_build_object(
        'rides', count(*),
        'both_phones', count(*) filter (where s.rider_seen_at is not null and s.driver_seen_at is not null),
        'seen_both_ways', count(*) filter (where exists (
            select 1 from public.ride_proximity_events e
             where e.request_id = s.request_id and e.side = 'rider' and e.matched)
          and exists (
            select 1 from public.ride_proximity_events e
             where e.request_id = s.request_id and e.side = 'driver' and e.matched)),
        'reports', (select count(*) from public.ride_proximity_events e where e.at >= v_since),
        'matched_reports', (select count(*) from public.ride_proximity_events e where e.at >= v_since and e.matched),
        'avg_rssi', (select round(avg(e.rssi)) from public.ride_proximity_events e
                      where e.at >= v_since and e.matched and e.rssi is not null))
        from public.ride_ble_secrets s
       where s.created_at >= v_since),
    'safety', jsonb_build_object(
      'far_apart', (select count(*) from public.ride_requests r
                     where r.start_flag_at >= v_since and r.start_flag = 'far_apart'),
      'no_proximity', (select count(*) from public.ride_requests r
                        where r.start_flag_at >= v_since and r.start_flag = 'no_proximity'),
      'separations', (select count(*) from public.ride_requests r where r.separated_at >= v_since),
      'answered_ok', (select count(*) from public.ride_requests r
                       where greatest(r.start_flag_at, r.separated_at) >= v_since and r.safety_ack_at is not null),
      'lost_open', (select count(*) from public.ride_lost_items l where l.created_at >= v_since and l.status = 'open'),
      'lost_found', (select count(*) from public.ride_lost_items l where l.created_at >= v_since and l.status = 'found'),
      'lost_returned', (select count(*) from public.ride_lost_items l
                         where l.created_at >= v_since and l.status = 'returned'),
      'lost_not_found', (select count(*) from public.ride_lost_items l
                          where l.created_at >= v_since and l.status = 'not_found'))
  );
end;
$$;
revoke execute on function public.ble_safety_report(int) from public, anon;
grant execute on function public.ble_safety_report(int) to authenticated;

-- The trips behind the safety numbers. kind: 'far_apart' | 'no_proximity'
-- (started away from the passenger), 'separated' (apart mid-trip),
-- 'lost_item' (a passenger reported something left behind).
create or replace function public.ble_safety_report_trips(p_days int default 7, p_limit int default 50)
returns table (
  request_id uuid,
  kind text,
  at timestamptz,
  ride_status text,
  pickup_name text,
  rider_name text,
  driver_name text,
  answered_ok boolean,
  start_method text,
  detail text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  select x.request_id, x.kind, x.at, r.status, r.pickup_name,
         (select p.name from public.profiles p where p.id = r.rider_id),
         (select p.name from public.profiles p where p.id = r.partner_id),
         x.kind <> 'lost_item' and r.safety_ack_at is not null,
         r.start_method, x.detail
    from (
      select r.id as request_id, r.start_flag as kind, r.start_flag_at as at, null::text as detail
        from public.ride_requests r
       where r.start_flag_at >= v_since and r.start_flag is not null
      union all
      select r.id, 'separated', r.separated_at, null
        from public.ride_requests r
       where r.separated_at >= v_since
      union all
      select l.request_id, 'lost_item', l.created_at, l.status || ': ' || left(l.description, 120)
        from public.ride_lost_items l
       where l.created_at >= v_since
    ) x
    join public.ride_requests r on r.id = x.request_id
   order by x.at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;
revoke execute on function public.ble_safety_report_trips(int, int) from public, anon;
grant execute on function public.ble_safety_report_trips(int, int) to authenticated;

notify pgrst, 'reload schema';
