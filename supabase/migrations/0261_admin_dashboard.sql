-- ============================================================================
-- 0261: the admin dashboard ("Command Centre", Admin > Dashboard)
--
-- Two reads for the dashboard page, both for admins who may view it (the
-- Dashboard page's grant, admin-dashboard, or a full admin):
--
--   * admin_dashboard_summary(from, to, prev_from, prev_to, bucket): one
--     jsonb with every period figure of the page, for the period and for the
--     one it is compared with (same length, immediately before or the same
--     days of the last week / month; the app works the instants out in
--     Malaysia's days). Buckets are Malaysia's hours ('hour') or days
--     ('day').
--       current / previous: the KPIs, the chart's buckets, the request
--         funnel, the service and payment mixes, demand by hour, and quality;
--       areas: the busiest pickup areas with the previous period's trips;
--       drivers: the drivers with the most completed trips;
--       airports: each active airport and place, its queue and pickups;
--       attention: what waits for an admin (not period bound).
--   * admin_dashboard_live(): the "Right now" panel, independent of any
--     period: drivers online, rides in progress, open requests, how long
--     today's requests waited for a driver, the airport and place queues,
--     and SOS alerts not yet resolved.
--
-- Where the figures come from:
--   * a completed trip is a ride_requests row completed in the period
--     (completed_at); its booking is the final fare (ride_fare, else fare,
--     as the app shows it) and its commission the commission charged on it
--     (commission_amount, 0216). Meter hires are not trips here.
--   * requests, the funnel, acceptance, cancellations, demand and quality
--     are the requests made in the period (created_at). A request "got an
--     offer" once a driver had it on screen (ride_request_views, 0112), bid
--     on it, was offered it by dispatch, or took it.
--   * an area is the pickup's suburb, else its city, else its state, as
--     stamped on the ride at booking.
--   * a driver's online time is their online sessions (0201) inside the
--     period; online_recorded says whether there are any to show.
--   * there is no payouts table, so nothing about payouts.
--
-- Indexes: requests by created_at, profiles by created_at and ratings by
-- created_at (completed trips already have ride_requests_done_at_idx).
-- ============================================================================

create index if not exists ride_requests_created_idx on public.ride_requests (created_at);
create index if not exists profiles_created_idx on public.profiles (created_at);
create index if not exists ride_ratings_created_idx on public.ride_ratings (created_at);

-- ---- Who may read it --------------------------------------------------------------------------
-- The Dashboard page's grant (read or edit) or a full admin; a direct
-- database session (psql, cron) and the service role too.
create or replace function public.caller_can_read_dashboard()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return true;
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  return auth.uid() is not null and public.admin_can_read(auth.uid(), 'admin-dashboard');
end;
$$;
revoke execute on function public.caller_can_read_dashboard() from public, anon;
grant execute on function public.caller_can_read_dashboard() to authenticated, service_role;

-- ---- One period's figures ---------------------------------------------------------------------
-- Everything of one period [p_from, p_to) the page compares: KPIs, chart
-- buckets, funnel, mixes, demand by hour, quality. Called by
-- admin_dashboard_summary only (no grant).
create or replace function public.admin_dashboard_period(p_from timestamptz, p_to timestamptz, p_bucket text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz constant text := 'Asia/Kuala_Lumpur';
  step constant interval := ('1 ' || p_bucket)::interval;
  v jsonb;
begin
  with done as materialized (
    select r.id, r.completed_at, r.rider_id, r.partner_id, r.currency,
           coalesce(nullif(btrim(r.service), ''), 'Other') as service,
           coalesce(nullif(btrim(r.payment_mode), ''), 'Other') as payment,
           coalesce(r.ride_fare, r.fare, 0)::numeric as fare,
           coalesce(r.commission_amount, 0)::numeric as commission
      from public.ride_requests r
     where r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to
  ), req as materialized (
    select r.id, r.created_at, r.status, r.cancel_requested_by, r.accepted_at, r.arrived_at,
           (r.accepted_at is not null or r.started_at is not null or r.status = 'completed') as accepted,
           (r.started_at is not null or r.status = 'completed') as picked,
           (r.accepted_at is not null or r.started_at is not null or r.status = 'completed'
            or r.offered_fare is not null or r.dispatch_offered_at is not null
            or exists (select 1 from public.ride_request_views w where w.request_id = r.id)) as offered
      from public.ride_requests r
     where r.created_at >= p_from and r.created_at < p_to
  ), riders as materialized (
    select p.created_at from public.profiles p where p.created_at >= p_from and p.created_at < p_to
  ), partners_new as materialized (
    select p.created_at from public.partners p where p.created_at >= p_from and p.created_at < p_to
  ), slots as (
    select g.s
      from generate_series(date_trunc(p_bucket, p_from at time zone tz),
                           (p_to at time zone tz) - interval '1 microsecond', step) as g(s)
  ), bd as (
    select date_trunc(p_bucket, d.completed_at at time zone tz) as s, count(*) as trips,
           sum(d.fare) as bookings, sum(d.commission) as commission, count(distinct d.rider_id) as riders
      from done d group by 1
  ), bq as (
    select date_trunc(p_bucket, q.created_at at time zone tz) as s, count(*) as requests,
           count(*) filter (where q.accepted) as accepted,
           count(*) filter (where q.status = 'cancelled') as cancelled
      from req q group by 1
  ), bu as (
    select date_trunc(p_bucket, x.created_at at time zone tz) as s, count(*) as n from riders x group by 1
  ), bp as (
    select date_trunc(p_bucket, x.created_at at time zone tz) as s, count(*) as n from partners_new x group by 1
  )
  select jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', coalesce((select d.currency from done d group by d.currency order by count(*) desc, d.currency limit 1), 'MYR'),
    'kpis', jsonb_build_object(
      'trips', (select count(*) from done),
      'bookings', (select coalesce(round(sum(d.fare), 2), 0) from done d),
      'commission', (select coalesce(round(sum(d.commission), 2), 0) from done d),
      'riders_active', (select count(distinct d.rider_id) from done d),
      'requests', (select count(*) from req),
      'accepted', (select count(*) from req q where q.accepted),
      'cancelled', (select count(*) from req q where q.status = 'cancelled'),
      'expired', (select count(*) from req q where q.status = 'expired'),
      'new_riders', (select count(*) from riders),
      'new_partners', (select count(*) from partners_new)),
    'buckets', (select coalesce(jsonb_agg(jsonb_build_object(
                  'start', to_char(sl.s, 'YYYY-MM-DD"T"HH24:MI'),
                  'trips', coalesce(bd.trips, 0),
                  'bookings', round(coalesce(bd.bookings, 0), 2),
                  'commission', round(coalesce(bd.commission, 0), 2),
                  'riders', coalesce(bd.riders, 0),
                  'requests', coalesce(bq.requests, 0),
                  'accepted', coalesce(bq.accepted, 0),
                  'cancelled', coalesce(bq.cancelled, 0),
                  'new_riders', coalesce(bu.n, 0),
                  'new_partners', coalesce(bp.n, 0)) order by sl.s), '[]'::jsonb)
                  from slots sl
                  left join bd on bd.s = sl.s left join bq on bq.s = sl.s
                  left join bu on bu.s = sl.s left join bp on bp.s = sl.s),
    'funnel', jsonb_build_object(
      'requests', (select count(*) from req),
      'offered', (select count(*) from req q where q.offered),
      'accepted', (select count(*) from req q where q.accepted),
      'picked_up', (select count(*) from req q where q.picked),
      'completed', (select count(*) from req q where q.status = 'completed')),
    'services', (select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'trips', x.n, 'bookings', x.b)
                                           order by x.n desc, x.name), '[]'::jsonb)
                   from (select (array_agg(d.service order by d.service ~ '^[[:upper:]]' desc, d.service))[1] as name, count(*) as n, round(sum(d.fare), 2) as b
                           from done d group by lower(d.service)) x),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'trips', x.n, 'bookings', x.b)
                                           order by x.b desc, x.name), '[]'::jsonb)
                   from (select (array_agg(d.payment order by d.payment ~ '^[[:upper:]]' desc, d.payment))[1] as name, count(*) as n, round(sum(d.fare), 2) as b
                           from done d group by lower(d.payment)) x),
    'heat', (select coalesce(jsonb_agg(jsonb_build_object('dow', x.dow, 'hour', x.h, 'n', x.n)
                                       order by x.dow, x.h), '[]'::jsonb)
               from (select extract(isodow from q.created_at at time zone tz)::int as dow,
                            extract(hour from q.created_at at time zone tz)::int as h, count(*) as n
                       from req q group by 1, 2) x),
    'quality', jsonb_build_object(
      'rating_avg', (select round(avg(g.stars), 2) from public.ride_ratings g
                      where g.created_at >= p_from and g.created_at < p_to),
      'ratings', (select count(*) from public.ride_ratings g where g.created_at >= p_from and g.created_at < p_to),
      'driver_cancels', (select count(*) from req q
                          where q.status = 'cancelled' and q.cancel_requested_by = 'partner'),
      'rider_cancels', (select count(*) from req q
                         where q.status = 'cancelled' and q.cancel_requested_by is distinct from 'partner'),
      'pickup_min', (select round((avg(extract(epoch from q.arrived_at - q.accepted_at)) / 60)::numeric, 1)
                       from req q
                      where q.arrived_at is not null and q.accepted_at is not null and q.arrived_at >= q.accepted_at),
      'complaints', (select count(*) from public.support_tickets t
                      where t.created_at >= p_from and t.created_at < p_to))
  ) into v;
  return v;
end;
$$;
revoke execute on function public.admin_dashboard_period(timestamptz, timestamptz, text) from public, anon, authenticated;

-- ---- The summary ------------------------------------------------------------------------------
create or replace function public.admin_dashboard_summary(
  p_from timestamptz, p_to timestamptz, p_prev_from timestamptz, p_prev_to timestamptz, p_bucket text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz constant text := 'Asia/Kuala_Lumpur';
  v_today date := (now() at time zone tz)::date;
  v jsonb;
begin
  if not public.caller_can_read_dashboard() then
    raise exception 'Only an admin who may view the dashboard can read it.' using errcode = '42501';
  end if;
  if p_bucket is null or p_bucket not in ('hour', 'day') then
    raise exception 'DASHBOARD_BUCKET' using errcode = '22023', hint = 'hour or day.';
  end if;
  if p_from is null or p_to is null or p_prev_from is null or p_prev_to is null
     or p_to <= p_from or p_prev_to <= p_prev_from
     or p_to - p_from > interval '400 days' or p_prev_to - p_prev_from > interval '400 days'
     or (p_bucket = 'hour' and (p_to - p_from > interval '8 days' or p_prev_to - p_prev_from > interval '8 days')) then
    raise exception 'DASHBOARD_PERIOD' using errcode = '22023', hint = 'Pick a period of up to a year.';
  end if;

  with area_rides as materialized (
    select coalesce(nullif(btrim(r.suburb), ''), nullif(btrim(r.city), ''), nullif(btrim(r.state), ''), '') as area,
           nullif(btrim(r.city), '') as city,
           r.completed_at >= p_from and r.completed_at < p_to as cur,
           coalesce(r.ride_fare, r.fare, 0)::numeric as fare
      from public.ride_requests r
     where r.status = 'completed'
       and ((r.completed_at >= p_from and r.completed_at < p_to)
            or (r.completed_at >= p_prev_from and r.completed_at < p_prev_to))
  ), areas as (
    select (array_agg(a.area order by a.area ~ '^[[:upper:]]' desc, a.area) filter (where a.cur))[1] as name,
           max(a.city) filter (where a.cur and lower(a.city) <> lower(a.area)) as city,
           count(*) filter (where a.cur) as trips,
           round(coalesce(sum(a.fare) filter (where a.cur), 0), 2) as bookings,
           count(*) filter (where not a.cur) as prev_trips
      from area_rides a
     group by lower(a.area)
    having count(*) filter (where a.cur) > 0
  ), drivers as (
    select r.partner_id as uid, count(*) as trips,
           round(sum(coalesce(r.ride_fare, r.fare, 0) - coalesce(r.commission_amount, 0)), 2) as earned,
           max(r.partner_name) as ride_name
      from public.ride_requests r
     where r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to and r.partner_id is not null
     group by r.partner_id
     order by count(*) desc, sum(coalesce(r.ride_fare, r.fare, 0)) desc, r.partner_id
     limit 8
  )
  select jsonb_build_object(
    'generated_at', now(),
    'bucket', p_bucket,
    'current', public.admin_dashboard_period(p_from, p_to, p_bucket),
    'previous', public.admin_dashboard_period(p_prev_from, p_prev_to, p_bucket),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object(
                'name', nullif(x.name, ''), 'city', x.city, 'trips', x.trips, 'bookings', x.bookings,
                'prev_trips', x.prev_trips) order by x.trips desc, x.bookings desc, x.name), '[]'::jsonb)
                from (select * from areas order by trips desc, bookings desc, name limit 8) x),
    'online_recorded', exists (select 1 from public.partner_online_sessions s
                                where s.started_at < p_to and coalesce(s.ended_at, s.last_seen_at) > p_from),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object(
                  'profile_id', d.uid, 'partner_id', pt.id, 'display_id', pt.display_id,
                  'name', coalesce(pt.name, pr.name, d.ride_name), 'trips', d.trips, 'earned', d.earned,
                  'rating', coalesce(nullif(pt.rating, 0), (select round(avg(g.stars), 2) from public.ride_ratings g
                                                            where g.partner_id = d.uid)),
                  'online_seconds', (select coalesce(sum(extract(epoch from
                                              least(coalesce(s.ended_at, s.last_seen_at), p_to) - greatest(s.started_at, p_from))), 0)::bigint
                                       from public.partner_online_sessions s
                                      where s.profile_id = d.uid and s.started_at < p_to
                                        and coalesce(s.ended_at, s.last_seen_at) > p_from))
                  order by d.trips desc, d.earned desc, d.uid), '[]'::jsonb)
                  from drivers d
                  left join public.profiles pr on pr.id = d.uid
                  left join lateral (select p.id, p.display_id, p.name, p.rating from public.partners p
                                      where p.auth_user_id = d.uid order by p.created_at limit 1) pt on true),
    'airports', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', a.id, 'kind', a.kind,
                   'name', coalesce(nullif(btrim(a.values->>'name'), ''), nullif(btrim(g.values->>'name'), ''),
                                    case a.kind when 'place' then 'Place' else 'Airport' end),
                   'waiting', (select count(*) from public.airport_queue q where q.airport_id = a.id),
                   'pickups', (select count(*) from public.ride_requests r
                                where r.airport_pickup_id = a.id and r.status = 'completed'
                                  and r.completed_at >= p_from and r.completed_at < p_to),
                   'prev_pickups', (select count(*) from public.ride_requests r
                                     where r.airport_pickup_id = a.id and r.status = 'completed'
                                       and r.completed_at >= p_prev_from and r.completed_at < p_prev_to))
                   order by a.position, a.created_at, a.id), '[]'::jsonb)
                   from public.airport_areas a
                   left join public.multi_gate g on g.id = a.place_id
                  where a.active),
    'attention', jsonb_build_object(
      'partners_pending', (select count(*) from public.partners p where p.status = 'unapproved'),
      'partner_docs_pending', (select count(*) from public.provider_documents d where d.status = 'Pending Review'),
      'vehicle_docs_pending', (select count(*) from public.vehicle_documents d where d.status = 'Pending Review'),
      'vehicles_no_permit', case
        when exists (select 1 from public.permit_types t where t.active and t.applies_to = 'vehicle' and t.required)
        then (select count(*) from public.vehicle v where public.vehicle_permit_status(v.id) in ('without', 'expired'))
        else 0 end,
      'permits_expiring', (select count(*) from public.vehicle_documents d
                            where d.permit_type_id is not null and coalesce(d.status, '') <> 'Rejected'
                              and d.expiry_date between v_today and v_today + 15),
      'tickets_open', (select count(*) from public.support_tickets t where t.status <> 'closed'))
  ) into v;
  return v;
end;
$$;
revoke execute on function public.admin_dashboard_summary(timestamptz, timestamptz, timestamptz, timestamptz, text)
  from public, anon;
grant execute on function public.admin_dashboard_summary(timestamptz, timestamptz, timestamptz, timestamptz, text)
  to authenticated;

-- ---- Right now --------------------------------------------------------------------------------
create or replace function public.admin_dashboard_live()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz constant text := 'Asia/Kuala_Lumpur';
  v_day_start timestamptz := date_trunc('day', now() at time zone tz) at time zone tz;
  v jsonb;
begin
  if not public.caller_can_read_dashboard() then
    raise exception 'Only an admin who may view the dashboard can read it.' using errcode = '42501';
  end if;
  with today as materialized (
    select extract(epoch from least(
             r.accepted_at, r.dispatch_offered_at,
             (select min(w.first_seen_at) from public.ride_request_views w where w.request_id = r.id)) - r.created_at) as wait
      from public.ride_requests r
     where r.created_at >= v_day_start
  )
  select jsonb_build_object(
    'at', now(),
    'drivers_online', (select count(*) from public.driver_presence d
                        where d.online and d.updated_at > now() - interval '3 minutes'),
    'rides_in_progress', (select count(*) from public.ride_requests r where r.status in ('accepted', 'arrived', 'on_trip')),
    'open_requests', (select count(*) from public.ride_requests r where r.status = 'open'),
    'first_offer_seconds', (select round(avg(greatest(t.wait, 0)))::bigint from today t where t.wait is not null),
    'first_offer_samples', (select count(*) from today t where t.wait is not null),
    'queue_waiting', (select count(*) from public.airport_queue q
                       join public.airport_areas a on a.id = q.airport_id and a.active),
    'queues', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'kind', x.kind, 'waiting', x.n)
                                         order by x.n desc, x.name), '[]'::jsonb)
                 from (select a.id, a.kind,
                              coalesce(nullif(btrim(a.values->>'name'), ''), nullif(btrim(g.values->>'name'), ''),
                                       case a.kind when 'place' then 'Place' else 'Airport' end) as name,
                              count(*) as n
                         from public.airport_queue q
                         join public.airport_areas a on a.id = q.airport_id and a.active
                         left join public.multi_gate g on g.id = a.place_id
                        group by a.id, a.kind, a.values, g.values) x),
    'sos_open', (select count(*) from public.safety_incidents s where s.status <> 'resolved')
  ) into v;
  return v;
end;
$$;
revoke execute on function public.admin_dashboard_live() from public, anon;
grant execute on function public.admin_dashboard_live() to authenticated;
