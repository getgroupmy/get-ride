-- ============================================================================
-- 0338 — God View freshness: an open app (and a trip or SOS) refreshes the map.
--
-- The only change to god_view_people is that a person's position and liveness
-- now come from the NEWER of their freshest push_tokens report and their
-- latest user_location_history row (0278). An open app writes
-- user_location_history, so a phone that opened the app but sent no background
-- report no longer reads as a stale "Last known". Everything else — the
-- windows, the always-on / app-open rules, partners, rides, SOS, scope and
-- search — is byte-for-byte 0272's, so presence with no history row is
-- unchanged (supabase/tests/god_view_presence_0272.sql passes untouched).
--
-- Re-runnable: create or replace only.
-- ============================================================================

create or replace function public.god_view_people(
  p_box double precision[],
  p_offline boolean,
  p_query text,
  p_only uuid,
  p_scoped boolean,
  p_region jsonb,
  p_polys polygon[]
)
returns table (
  kind text, id uuid, partner_row_id uuid, name text, service text, vehicle text, plate text,
  status text, lat double precision, lng double precision, updated_at timestamptz,
  ride_id uuid, ride_code text, other_id uuid, other_name text, eta_min integer,
  next_lat double precision, next_lng double precision, area text, sos boolean, incident_id uuid
)
language sql
stable
security definer
set search_path = ''
as $$
  with
  q as (
    select nullif(regexp_replace(lower(btrim(coalesce(p_query, ''))), '[%_\\]', '', 'g'), '') as t,
           nullif(regexp_replace(coalesce(p_query, ''), '\D', '', 'g'), '') as digits,
           -- Live: an app-open or background report in the last 30 minutes.
           now() - interval '30 minutes' as live_after,
           -- Phones: live ones, or with the last known positions a week of them.
           now() - case when coalesce(p_offline, false) then interval '7 days' else interval '30 minutes' end as seen_after,
           -- Partners' presence: 24 h for "online, not responding", a week for the last known.
           now() - case when coalesce(p_offline, false) then interval '7 days' else interval '24 hours' end as presence_after
  ),
  rides as materialized (
    select r.id, r.status, r.rider_id, r.partner_id, r.service, r.partner_vehicle, r.partner_plate,
           r.rider_name, r.partner_name,
           r.pickup_lat, r.pickup_lng, r.drop_lat, r.drop_lng,
           r.partner_live_lat, r.partner_live_lng, r.partner_live_at,
           r.user_live_lat, r.user_live_lng, r.user_live_at,
           r.country, r.state, r.city, r.suburb,
           r.created_at, r.updated_at, r.started_at, r.duration_min,
           'R-' || upper(left(replace(r.id::text, '-', ''), 6)) as code
      from public.ride_requests r
     where r.status in ('open', 'accepted', 'arrived', 'on_trip')
       and r.updated_at > now() - interval '12 hours'
  ),
  partner_ride as (
    select distinct on (r.partner_id) r.*
      from rides r
     where r.partner_id is not null and r.status in ('accepted', 'arrived', 'on_trip')
     order by r.partner_id, r.updated_at desc
  ),
  rider_ride as (
    select distinct on (r.rider_id) r.*
      from rides r
     where r.rider_id is not null
     order by r.rider_id, (r.status <> 'open') desc, r.updated_at desc
  ),
  eta as (
    select distinct on (o.request_id) o.request_id, o.eta_min
      from public.ride_offers o
      join rides r on r.id = o.request_id
     where o.status = 'accepted'
     order by o.request_id, o.created_at desc
  ),
  sos as materialized (
    select distinct on (x.pid) x.pid, x.id as incident_id,
           case when x.pid = x.reporter_id then x.lat end as lat,
           case when x.pid = x.reporter_id then x.lng end as lng,
           case when x.pid = x.reporter_id then x.location_at end as location_at
      from (select s.*, unnest(array[s.reporter_id, s.rider_id, s.partner_id,
                                     r.rider_id, r.partner_id]) as pid
              from public.safety_incidents s
              left join public.ride_requests r on r.id = s.ride_id
             where s.status in ('open', 'acknowledged')) x
     where x.pid is not null
     order by x.pid, x.created_at desc
  ),
  -- The phone's freshest position (the open app's or the background's),
  -- for app-open, always-on and last-known people, and every area name.
  -- The phone's freshest push-token position (open app's or background's),
  -- exactly as 0272: app-open / always-on flags and the area names. (0338
  -- splits 0272's single `phone` CTE into this plus `hist`, then recombines
  -- them in `phone`; the push-token logic here is unchanged from 0272.)
  tok as materialized (
    select distinct on (t.profile_id) t.profile_id, t.last_lat, t.last_lng, t.located_at,
           t.area_country, t.area_state, t.area_city, t.area_suburb,
           (t.located_at > q.live_after and t.located_bg and t.location_always) as always_on,
           (t.located_at > q.live_after and not t.located_bg) as app_open
      from public.push_tokens t, q
     where t.located_at > q.seen_after
       and t.profile_id is not null and t.last_lat is not null and t.last_lng is not null
     order by t.profile_id, t.located_at desc
  ),
  -- The latest recorded position per person (an open app, a trip and an SOS
  -- all write user_location_history, 0278), within the same window as tok.
  hist as materialized (
    select distinct on (h.user_id) h.user_id as profile_id, h.latitude as lat, h.longitude as lng, h.captured_at
      from public.user_location_history h, q
     where h.captured_at > q.seen_after and h.latitude is not null and h.longitude is not null
     order by h.user_id, h.captured_at desc
  ),
  -- The freshness fix: per person, the newer of the push token and the history
  -- row. When the history row is newer, its position wins and the person is at
  -- least "App open", so an open app stops reading as a stale "Last known". A
  -- person with only a history row (no live push token) appears too. With no
  -- history row this CTE equals 0272's `phone` exactly, so presence is unchanged.
  phone as materialized (
    select coalesce(tk.profile_id, hs.profile_id) as profile_id,
           case when hs.captured_at > coalesce(tk.located_at, '-infinity'::timestamptz)
                then hs.lat else tk.last_lat end as last_lat,
           case when hs.captured_at > coalesce(tk.located_at, '-infinity'::timestamptz)
                then hs.lng else tk.last_lng end as last_lng,
           greatest(coalesce(tk.located_at, '-infinity'::timestamptz),
                    coalesce(hs.captured_at, '-infinity'::timestamptz)) as located_at,
           tk.area_country, tk.area_state, tk.area_city, tk.area_suburb,
           coalesce(tk.always_on, false) as always_on,
           coalesce(coalesce(tk.app_open, false)
            or (hs.captured_at > q.live_after
                and hs.captured_at >= coalesce(tk.located_at, '-infinity'::timestamptz)), false) as app_open
      from tok tk
      full join hist hs on hs.profile_id = tk.profile_id
      cross join q
  ),
  -- Partners: a recent presence, a phone report, a job or an SOS.
  partner_ids as (
    select d.profile_id as pid from public.driver_presence d, q where d.updated_at > q.presence_after
    union select ph.profile_id from phone ph
    union select r.partner_id from partner_ride r
    union select s.pid from sos s
  ),
  presence as (
    select distinct on (p.auth_user_id) p.auth_user_id as profile_id,
           coalesce(d.online, false) as online, d.lat, d.lng, d.updated_at,
           p.id as partner_row_id, p.name as partner_name, p.vehicle, p.make, p.model, p.plate,
           p.vehicle_type, p.partner_type
      from partner_ids i
      join public.partners p on p.auth_user_id = i.pid
      cross join q
      left join public.driver_presence d on d.profile_id = p.auth_user_id and d.updated_at > q.presence_after
     order by p.auth_user_id, p.updated_at desc
  ),
  partner_rows as (
    select 'partner'::text as kind, pr.profile_id as id, pr.partner_row_id,
           coalesce(nullif(btrim(pf.name), ''), pr.partner_name) as name,
           coalesce(nullif(btrim(ar.service), ''), nullif(btrim(pr.vehicle_type), ''), pr.partner_type) as service,
           coalesce(nullif(btrim(ar.partner_vehicle), ''), nullif(btrim(concat_ws(' ', pr.make, pr.model)), ''),
                    pr.vehicle) as vehicle,
           coalesce(nullif(btrim(ar.partner_plate), ''), pr.plate) as plate,
           case when sp.pid is not null then 'sos'
                when ar.status in ('accepted', 'arrived') then 'pickup'
                when ar.status = 'on_trip' then 'trip'
                when pr.online and pr.updated_at > now() - interval '3 minutes' then 'free'
                when pr.online and pr.updated_at > now() - interval '24 hours' then 'not_responding'
                when ph.always_on then 'always_on'
                when ph.app_open then 'app_open'
                else 'last_known' end as status,
           pos.lat, pos.lng, pos.at as updated_at,
           ar.id as ride_id, ar.code as ride_code, ar.rider_id as other_id,
           (select nullif(btrim(o.name), '') from public.profiles o where o.id = ar.rider_id) as other_name,
           case when ar.status in ('accepted', 'arrived') then e.eta_min
                when ar.status = 'on_trip' and ar.started_at is not null and ar.duration_min is not null
                  then greatest(0, ar.duration_min - (extract(epoch from now() - ar.started_at) / 60)::int)
           end as eta_min,
           case when ar.status in ('accepted', 'arrived') then ar.pickup_lat
                when ar.status = 'on_trip' then ar.drop_lat end as next_lat,
           case when ar.status in ('accepted', 'arrived') then ar.pickup_lng
                when ar.status = 'on_trip' then ar.drop_lng end as next_lng,
           coalesce(nullif(btrim(ph.area_suburb), ''), nullif(btrim(ph.area_city), ''),
                    nullif(btrim(ar.suburb), ''), nullif(btrim(ar.city), '')) as area,
           sp.pid is not null as sos, sp.incident_id,
           coalesce(ph.area_country, ar.country) as country, coalesce(ph.area_state, ar.state) as state,
           coalesce(ph.area_city, ar.city) as city, coalesce(ph.area_suburb, ar.suburb) as suburb,
           (q.t is null
            or lower(coalesce(pf.name, pr.partner_name, '')) like '%' || q.t || '%'
            or replace(lower(coalesce(ar.partner_plate, pr.plate, '')), ' ', '') like '%' || replace(q.t, ' ', '') || '%'
            or lower(coalesce(ar.code, '')) like '%' || q.t || '%'
            or (ar.id is not null and ar.id::text like q.t || '%')
            or (length(coalesce(q.digits, '')) >= 4
                and regexp_replace(coalesce(pf.phone, ''), '\D', '', 'g') like '%' || q.digits || '%')) as hit
      from presence pr
      cross join q
      left join public.profiles pf on pf.id = pr.profile_id
      left join partner_ride ar on ar.partner_id = pr.profile_id
      left join eta e on e.request_id = ar.id
      left join sos sp on sp.pid = pr.profile_id
      left join phone ph on ph.profile_id = pr.profile_id
      left join lateral (
        -- The freshest of presence, the ride's live share, their SOS and the phone.
        select v.lat, v.lng, v.at
          from (values (pr.lat, pr.lng, pr.updated_at),
                       (ar.partner_live_lat, ar.partner_live_lng, ar.partner_live_at),
                       (sp.lat, sp.lng, sp.location_at),
                       (ph.last_lat, ph.last_lng, ph.located_at)) v(lat, lng, at)
         where v.lat is not null and v.lng is not null
         order by v.at desc nulls last
         limit 1
      ) pos on true
  ),
  user_ids as (
    select r.rider_id as pid from rider_ride r
    union select ph.profile_id from phone ph
    union select s.pid from sos s
  ),
  user_rows as (
    select 'user'::text as kind, u.pid as id, null::uuid as partner_row_id,
           nullif(btrim(pf.name), '') as name,
           ur.service, null::text as vehicle, null::text as plate,
           case when sp.pid is not null then 'sos'
                when ur.status = 'open' then 'searching'
                when ur.status is not null then 'ride'
                when ph.always_on then 'always_on'
                when ph.app_open then 'app_open'
                else 'last_known' end as status,
           pos.lat, pos.lng, pos.at as updated_at,
           ur.id as ride_id, ur.code as ride_code, ur.partner_id as other_id,
           (select nullif(btrim(o.name), '') from public.profiles o where o.id = ur.partner_id) as other_name,
           null::integer as eta_min,
           case when ur.status = 'on_trip' then ur.drop_lat end as next_lat,
           case when ur.status = 'on_trip' then ur.drop_lng end as next_lng,
           coalesce(nullif(btrim(ur.suburb), ''), nullif(btrim(ur.city), ''),
                    nullif(btrim(ph.area_suburb), ''), nullif(btrim(ph.area_city), '')) as area,
           sp.pid is not null as sos, sp.incident_id,
           coalesce(ur.country, ph.area_country) as country, coalesce(ur.state, ph.area_state) as state,
           coalesce(ur.city, ph.area_city) as city, coalesce(ur.suburb, ph.area_suburb) as suburb,
           (q.t is null
            or lower(coalesce(pf.name, '')) like '%' || q.t || '%'
            or lower(coalesce(ur.code, '')) like '%' || q.t || '%'
            or (ur.id is not null and ur.id::text like q.t || '%')
            or (length(coalesce(q.digits, '')) >= 4
                and regexp_replace(coalesce(pf.phone, ''), '\D', '', 'g') like '%' || q.digits || '%')) as hit
      from user_ids u
      cross join q
      left join public.profiles pf on pf.id = u.pid
      left join rider_ride ur on ur.rider_id = u.pid
      left join sos sp on sp.pid = u.pid
      left join phone ph on ph.profile_id = u.pid
      left join lateral (
        select v.lat, v.lng, v.at
          from (values
                  -- The rider's GPS share during this ride.
                  (case when ur.user_live_at >= ur.created_at then ur.user_live_lat end,
                   case when ur.user_live_at >= ur.created_at then ur.user_live_lng end, ur.user_live_at, 1),
                  -- Their own SOS location.
                  (sp.lat, sp.lng, sp.location_at, 0),
                  -- Searching: the pickup. In a ride: with the driver, else the pickup.
                  (case when ur.status = 'open' then ur.pickup_lat end,
                   case when ur.status = 'open' then ur.pickup_lng end, ur.updated_at, 2),
                  (case when ur.status <> 'open' then ur.partner_live_lat end,
                   case when ur.status <> 'open' then ur.partner_live_lng end, ur.partner_live_at, 3),
                  (case when ur.status <> 'open' then ur.pickup_lat end,
                   case when ur.status <> 'open' then ur.pickup_lng end, ur.updated_at, 4),
                  -- No ride: the phone (open app, background or last known).
                  (case when ur.id is null then ph.last_lat end,
                   case when ur.id is null then ph.last_lng end, ph.located_at, 5)
               ) v(lat, lng, at, rank)
         where v.lat is not null and v.lng is not null
         -- Their SOS location when it is newer than the share; the rest in order.
         order by case when v.rank > 0 then v.rank
                       when v.at > coalesce(ur.user_live_at, '-infinity'::timestamptz) then 0
                       else 9 end
         limit 1
      ) pos on true
     where not exists (select 1 from presence pr where pr.profile_id = u.pid)
  ),
  everyone as (
    select * from partner_rows
    union all
    select * from user_rows
  )
  select e.kind, e.id, e.partner_row_id, e.name, e.service, e.vehicle, e.plate, e.status, e.lat, e.lng, e.updated_at,
         e.ride_id, e.ride_code, e.other_id, e.other_name, e.eta_min, e.next_lat, e.next_lng, e.area, e.sos, e.incident_id
    from everyone e
   where e.lat is not null and e.lng is not null
     and (coalesce(p_offline, false) or e.status <> 'last_known')
     and (p_only is null or e.id = p_only)
     and e.hit
     and (p_box is null or p_only is not null or nullif(btrim(coalesce(p_query, '')), '') is not null
          or cardinality(p_box) <> 4
          or (e.lat between p_box[1] and p_box[3]
              and case when p_box[2] <= p_box[4] then e.lng between p_box[2] and p_box[4]
                       else e.lng >= p_box[2] or e.lng <= p_box[4] end))
     and public.god_view_in_scope(p_scoped, p_region, p_polys, e.lat, e.lng, e.country, e.state, e.city, e.suburb);
$$;

revoke execute on function public.god_view_people(double precision[], boolean, text, uuid, boolean, jsonb, polygon[])
  from public, anon, authenticated;

notify pgrst, 'reload schema';
