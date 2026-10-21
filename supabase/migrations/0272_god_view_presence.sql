-- ============================================================================
-- 0272 — God View presence: phones check in while the app is open, "Always
-- on" phones keep reporting from the background, partners left "online"
-- show as not responding, and everyone else at their last known position.
--
-- Applied by hand as version 20261021033000 (0272_god_view_presence in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace".
--
-- Why: God View (0270) was often empty. A phone reported where it was on
-- start, on resume and every 30 minutes, and only after moving 1 km, so an
-- idle open app went stale and the 30-minute window dropped it; nothing
-- was reported while the app was closed; and a partner who closed the app
-- while "online" disappeared after 3 minutes.
--
-- 1. push_tokens, new columns:
--      located_bg       the last position came from the background (the
--                       app closed or not on screen), not the open app;
--      location_always  the phone had location set to "Allow all the time"
--                       ("Always" on an iPhone) at its last check-in;
--      bg_key_hash      sha256 (hex) of the install's background key: the
--                       one thing a closed app's native reporter holds, so
--                       it can report without the user's session (below).
--                       Set only while location_always; cleared when not.
-- 2. push_checkin(tokens, lat, lng, background, always, bg_key): the open
--    app's light check-in, every 2 minutes while it is on screen and signed
--    in, moved or not (lib/src/app.dart). Updates the caller's own tokens'
--    position and located_at, leaves the area alone (push_set_location
--    still sets it, after a move of ~200 m or every 30 minutes).
-- 3. push_background_location(key, lat, lng): what the native reporter
--    (Android BackgroundLocationReceiver.kt, iOS significant location
--    changes in AppDelegate.swift) sends, about every 15 minutes or after
--    ~500 m, only on a phone that already allows location all the time
--    (never asked for in this flow). Callable without a session: the
--    256-bit key is the capability, as the push token is for
--    push_unregister_token. Moves only the rows holding that key's hash,
--    still set to always; ignored within 3 minutes of an open-app check-in
--    (the open app wins) and within 60 s of the previous background one.
--    Sign-out removes the token row (push_unregister_token), and with it
--    the key.
-- 4. push_set_location (as 0168) also marks the position as foreground.
-- 5. god_view_snapshot / god_view_people, redefined from 0270 (same
--    arguments, same region scope, still no phones). Statuses:
--      partners  sos, pickup, trip, free (online, heard from in 3 min) as
--                before; not_responding: driver_presence says online but
--                nothing for more than 3 minutes, shown up to 24 hours old
--                whatever the toggle; then by the phone, as users.
--                A partner is anyone with a partners row: also one whose
--                only fresh report is their phone, or who is on a job.
--      users     sos, searching, ride as before; app_open: an open-app
--                report in the last 30 minutes; always_on: the freshest
--                report came from the background in the last 30 minutes,
--                with location set to always.
--      last_known  (was offline) everyone else with a position in the past
--                7 days, at that position, with p_show_offline (the page's
--                "Last known" toggle, on by default). Without it, only the
--                live statuses and not_responding.
--    The row cap keeps SOS first and last-known rows last; counts gain
--    always_on, not_responding, last_known (and per kind), and
--    omitted_last_known says how many of the left-out rows were last known.
--    partners_offline / users_offline stay, as the last-known counts.
-- 6. Indexes: push_tokens.bg_key_hash. The 7-day window reads
--    push_tokens_located_idx and driver_presence_updated_idx (0270).
-- ============================================================================

-- ---- 1. The phone's report: foreground or background, and the key ------------------------------
alter table public.push_tokens
  add column if not exists located_bg boolean not null default false,
  add column if not exists location_always boolean not null default false,
  add column if not exists bg_key_hash text;
comment on column public.push_tokens.located_bg is
  'The last position (last_lat / last_lng, located_at) came from the background, not the open app (0272).';
comment on column public.push_tokens.location_always is
  'Location was set to Allow all the time / Always at the phone''s last check-in (0272). God View shows a fresh background report from it as Always on.';
comment on column public.push_tokens.bg_key_hash is
  'sha256 hex of the install''s background location key (0272): push_background_location moves only rows holding it. Null unless location_always.';

-- ---- 6. Indexes ---------------------------------------------------------------------------------
create index if not exists push_tokens_bg_key_idx on public.push_tokens (bg_key_hash)
  where bg_key_hash is not null;

-- ---- 2. The open app's check-in -----------------------------------------------------------------
create or replace function public.push_checkin(
  p_tokens text[],
  p_lat double precision,
  p_lng double precision,
  p_background boolean default false,
  p_always boolean default false,
  p_bg_key text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  n int;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'invalid_location' using errcode = '22023';
  end if;
  if p_bg_key is not null and length(p_bg_key) not between 32 and 128 then
    raise exception 'invalid_key' using errcode = '22023';
  end if;
  if p_bg_key is not null then
    v_hash := encode(extensions.digest(convert_to(p_bg_key, 'UTF8'), 'sha256'), 'hex');
  end if;
  update public.push_tokens t
     set last_lat = p_lat,
         last_lng = p_lng,
         located_at = now(),
         located_bg = coalesce(p_background, false),
         location_always = coalesce(p_always, false),
         -- The key only while location is set to always.
         bg_key_hash = case when coalesce(p_always, false) then coalesce(v_hash, t.bg_key_hash) end
   where t.profile_id = auth.uid()
     and t.token = any(coalesce(p_tokens, '{}'));
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.push_checkin(text[], double precision, double precision, boolean, boolean, text)
  from public, anon;
grant execute on function public.push_checkin(text[], double precision, double precision, boolean, boolean, text)
  to authenticated;

-- ---- 3. The closed app's report -----------------------------------------------------------------
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
  n int;
begin
  if p_key is null or length(p_key) not between 32 and 128
     or p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return 0;
  end if;
  v_hash := encode(extensions.digest(convert_to(p_key, 'UTF8'), 'sha256'), 'hex');
  update public.push_tokens t
     set last_lat = p_lat,
         last_lng = p_lng,
         located_at = now(),
         located_bg = true
   where t.bg_key_hash = v_hash
     and t.location_always
     and t.profile_id is not null
     -- The open app's own check-in wins for 3 minutes; one background
     -- report a minute at most.
     and (t.located_at is null
          or t.located_at < now() - case when t.located_bg then interval '60 seconds' else interval '3 minutes' end);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.push_background_location(text, double precision, double precision) from public;
grant execute on function public.push_background_location(text, double precision, double precision)
  to anon, authenticated;

-- ---- 4. push_set_location, as 0168, from the open app -------------------------------------------
create or replace function public.push_set_location(
  p_tokens text[],
  p_lat double precision,
  p_lng double precision,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'invalid_location';
  end if;
  update public.push_tokens
     set last_lat = p_lat,
         last_lng = p_lng,
         area_country = nullif(left(trim(coalesce(p_country, '')), 120), ''),
         area_state = nullif(left(trim(coalesce(p_state, '')), 120), ''),
         area_city = nullif(left(trim(coalesce(p_city, '')), 120), ''),
         area_suburb = nullif(left(trim(coalesce(p_suburb, '')), 120), ''),
         located_at = now(),
         located_bg = false
   where profile_id = auth.uid()
     and token = any(coalesce(p_tokens, '{}'));
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.push_set_location(text[], double precision, double precision, text, text, text, text)
  from public, anon;
grant execute on function public.push_set_location(text[], double precision, double precision, text, text, text, text)
  to authenticated, service_role;

-- ---- 5. The people ------------------------------------------------------------------------------
-- As 0270, with the statuses above. p_offline: also the last known
-- positions, up to 7 days old.
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
  phone as materialized (
    select distinct on (t.profile_id) t.profile_id, t.last_lat, t.last_lng, t.located_at,
           t.area_country, t.area_state, t.area_city, t.area_suburb,
           (t.located_at > q.live_after and t.located_bg and t.location_always) as always_on,
           (t.located_at > q.live_after and not t.located_bg) as app_open
      from public.push_tokens t, q
     where t.located_at > q.seen_after
       and t.profile_id is not null and t.last_lat is not null and t.last_lng is not null
     order by t.profile_id, t.located_at desc
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

-- The page's read, as 0270. p_show_offline: the "Last known" toggle.
create or replace function public.god_view_snapshot(
  p_min_lat double precision default null,
  p_min_lng double precision default null,
  p_max_lat double precision default null,
  p_max_lng double precision default null,
  p_show_offline boolean default false,
  p_query text default null,
  p_limit integer default 1500
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_polys polygon[];
  v_box double precision[];
  v_limit int := least(greatest(coalesce(p_limit, 1500), 1), 3000);
  v jsonb;
begin
  select * into c from public.god_view_caller();
  if not c.ok then
    raise exception 'Only a full admin, or an admin given the God View page, can open God View.'
      using errcode = '42501';
  end if;
  if c.scoped then
    v_polys := public.god_view_region_polys(c.region);
  end if;
  if p_min_lat is not null and p_min_lng is not null and p_max_lat is not null and p_max_lng is not null then
    v_box := array[least(p_min_lat, p_max_lat), p_min_lng, greatest(p_min_lat, p_max_lat), p_max_lng];
  end if;
  with f as materialized (
    select g.*,
           row_number() over (
             order by case g.status when 'sos' then 0 when 'pickup' then 1 when 'trip' then 1
                                    when 'searching' then 2 when 'ride' then 2 when 'free' then 3
                                    when 'not_responding' then 4 when 'app_open' then 4
                                    when 'always_on' then 5 else 6 end,
                      g.updated_at desc nulls last, g.id) as rn
      from public.god_view_people(v_box, p_show_offline, p_query, null, c.scoped, c.region, v_polys) g
  )
  select jsonb_build_object(
    'at', now(),
    'scoped', c.scoped,
    'region', case when c.scoped then c.region end,
    'scope_missing', c.scoped and (c.region is null or btrim(coalesce(c.region->>'country', '')) = ''),
    'total', count(*),
    'omitted', greatest(count(*) - v_limit, 0),
    'omitted_last_known', count(*) filter (where f.rn > v_limit and f.status = 'last_known'),
    'counts', jsonb_build_object(
      'partners_online', count(*) filter (where f.kind = 'partner' and f.status in ('free', 'pickup', 'trip', 'sos')),
      'partners_free', count(*) filter (where f.kind = 'partner' and f.status = 'free'),
      'partners_on_job', count(*) filter (where f.kind = 'partner' and (f.status in ('pickup', 'trip')
                                                                        or (f.status = 'sos' and f.ride_id is not null))),
      'partners_not_responding', count(*) filter (where f.kind = 'partner' and f.status = 'not_responding'),
      'partners_always_on', count(*) filter (where f.kind = 'partner' and f.status = 'always_on'),
      'partners_app_open', count(*) filter (where f.kind = 'partner' and f.status = 'app_open'),
      'partners_offline', count(*) filter (where f.kind = 'partner' and f.status = 'last_known'),
      'users_searching', count(*) filter (where f.kind = 'user' and f.status = 'searching'),
      'users_in_ride', count(*) filter (where f.kind = 'user' and f.status = 'ride'),
      'users_app_open', count(*) filter (where f.kind = 'user' and f.status = 'app_open'),
      'users_always_on', count(*) filter (where f.kind = 'user' and f.status = 'always_on'),
      'users_offline', count(*) filter (where f.kind = 'user' and f.status = 'last_known'),
      'always_on', count(*) filter (where f.status = 'always_on'),
      'not_responding', count(*) filter (where f.status = 'not_responding'),
      'last_known', count(*) filter (where f.status = 'last_known'),
      'sos', count(*) filter (where f.status = 'sos')),
    'people', coalesce(jsonb_agg(jsonb_build_object(
        'kind', f.kind, 'id', f.id, 'partner_row_id', f.partner_row_id, 'name', f.name, 'service', f.service,
        'vehicle', f.vehicle, 'plate', f.plate, 'status', f.status, 'lat', f.lat, 'lng', f.lng,
        'updated_at', f.updated_at, 'ride_id', f.ride_id, 'ride_code', f.ride_code, 'other_id', f.other_id,
        'other_name', f.other_name, 'eta_min', f.eta_min, 'next_lat', f.next_lat, 'next_lng', f.next_lng,
        'area', f.area, 'sos', f.sos, 'incident_id', f.incident_id) order by f.rn)
      filter (where f.rn <= v_limit), '[]'::jsonb))
    into v
    from f;
  return v;
end;
$$;
revoke execute on function public.god_view_snapshot(double precision, double precision, double precision,
  double precision, boolean, text, integer) from public, anon;
grant execute on function public.god_view_snapshot(double precision, double precision, double precision,
  double precision, boolean, text, integer) to authenticated;

notify pgrst, 'reload schema';
