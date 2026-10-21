-- ============================================================================
-- 0270 — God View: everyone's live position and status on one admin map.
--
-- Applied by hand as version 20261021032800 (0270_god_view in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace". 0268 is another branch's
-- number; the gap is fine (check-migration-numbers.sh only refuses a
-- number used twice).
--
-- 1. Who may look (Admin -> God View, page key admin-god-view):
--    * a full admin (any page '*' grant) sees everyone;
--    * a sub-admin holding the God View page sees the people inside the
--      region set on that grant: admin_access.region, {country, state,
--      city, suburb} as the Country / States / Cities / Suburbs tables name
--      them (the sub-admin editor sets it beside the page). A point is
--      inside when the region's mapped boundary (boundary_polys, 0125)
--      holds it; a region without a boundary goes by the names the ride or
--      the phone reported. A God View grant without a region sees nobody
--      (scope_missing in the snapshot) until a full admin sets one;
--    * everyone else is refused (42501).
-- 2. god_view_snapshot(box, show_offline, query, limit): one jsonb for the
--    page, polled every 5 s while it is on screen (no realtime: a
--    publication on driver_presence would stream every driver's position to
--    every admin's socket). The rows inside the map's visible box (the
--    client passes it; a search looks everywhere in the scope), at most
--    `limit` of them (1500, at most 3000) by priority, SOS first, with
--    `total` and `omitted` saying how many matched and were left out, and
--    the counts for the stats over all of them:
--      partners  driver_presence rows (0145): online and heard from in the
--                last 3 minutes, or on a job; with show_offline also the
--                ones last heard from in the past 2 hours (greyed).
--                Position: the freshest of presence, the ride's live share
--                (partner_live_*, 0055) and their own SOS location.
--                Status: sos, pickup (accepted / arrived), trip (on_trip),
--                free, offline.
--      users     searching (an open request), in a ride (accepted, arrived,
--                on_trip), app open (the phone's last position,
--                push_tokens.last_lat / last_lng / located_at (0168), in the
--                last 30 minutes) and, with show_offline, last seen in the
--                past 2 hours. A ride's user is where the rider's GPS share
--                says (user_live_*, 0055), else a searching user's pickup
--                point, else their driver's position.
--      Each row: kind, id (profile), partner_row_id, name, service,
--      vehicle, plate, status, lat, lng, updated_at, ride_id, ride_code,
--      other_id, other_name, eta_min (the accepted offer's ETA (0269) to
--      the pickup, the trip's minutes left on a trip), next_lat / next_lng
--      (the pickup, or the drop-off on a trip), area, sos and incident_id
--      (an SOS incident (0193) still open or acknowledged, on the person or
--      their ride). Phone numbers are never in it.
-- 3. god_view_reveal_phone(profile): the phone, for a person the caller may
--    see, and a row in public.admin_audit_log (new: who looked at what, when;
--    full admins read it). At most 60 reveals per admin per 10 minutes.
-- 4. god_view_suspend(profile, reason, note): the Users / Partners pages'
--    block, from the map: a partner's partners.status = 'blocked' with the
--    reason shown to them (status_note), taken offline (their ride in
--    progress is left alone, and the claim guard keeps new requests from
--    them); a user's profile_status 'Blocked' / status 'blocked'. Needs the
--    same EDIT grant the page needs (caller_admin_can_write on partners or
--    profiles), and is logged in admin_audit_log.
-- 5. Partners report where they are every 10 s while online, not 60 s
--    (lib/src/data/driver_presence.dart: skipped while they have moved
--    under 15 m and less than 30 s have passed). set_driver_presence (as
--    0245) re-checks the partner type rules at most once a minute while
--    the driver stays online and within ~200 m of their last report
--    (driver_presence.rules_checked_at), so the faster reports cost what
--    the old ones did.
-- 6. Indexes for thousands of rows: push_tokens.located_at,
--    driver_presence.updated_at (all rows; the online one stays), the
--    active rides by status and safety_incidents by status.
-- 7. RLS is unchanged: driver_presence and push_tokens stay readable by
--    their owner and admins only (supabase/tests/god_view_0270.sql checks
--    that a rider reads neither); every God View read goes through these
--    SECURITY DEFINER functions.
-- ============================================================================

-- ---- 1. The region on a grant, and the log ------------------------------------------------------
alter table public.admin_access add column if not exists region jsonb;
alter table public.admin_access drop constraint if exists admin_access_region_shape;
alter table public.admin_access add constraint admin_access_region_shape
  check (region is null or (jsonb_typeof(region) = 'object' and pg_column_size(region) <= 2048));
comment on column public.admin_access.region is
  'The region a page grant is limited to, {country, state, city, suburb} by region names (0270). Read by God View (admin-god-view): a sub-admin sees the people inside it only.';

create table if not exists public.admin_audit_log (
  id                uuid primary key default gen_random_uuid(),
  actor_id          uuid,
  action            text not null check (length(action) between 1 and 80),
  target_profile_id uuid,
  detail            jsonb not null default '{}',
  created_at        timestamptz not null default now()
);
create index if not exists admin_audit_log_actor_idx on public.admin_audit_log (actor_id, created_at desc);
create index if not exists admin_audit_log_target_idx on public.admin_audit_log (target_profile_id, created_at desc)
  where target_profile_id is not null;
comment on table public.admin_audit_log is
  'What an admin did that is not a row change of its own, e.g. looking at a phone number on God View (0270). Written by SECURITY DEFINER functions only; full admins read it.';

alter table public.admin_audit_log enable row level security;
revoke all on public.admin_audit_log from anon, authenticated;
grant select on public.admin_audit_log to authenticated;
drop policy if exists "admin_audit_log full admin read" on public.admin_audit_log;
create policy "admin_audit_log full admin read" on public.admin_audit_log
  for select to authenticated using ((select public.caller_is_full_admin()));

-- ---- 6. Indexes ---------------------------------------------------------------------------------
create index if not exists push_tokens_located_idx on public.push_tokens (located_at)
  where located_at is not null;
create index if not exists driver_presence_updated_idx on public.driver_presence (updated_at);
create index if not exists ride_requests_active_status_idx on public.ride_requests (status, updated_at)
  where status in ('open', 'accepted', 'arrived', 'on_trip');
create index if not exists safety_incidents_unresolved_idx on public.safety_incidents (status)
  where status in ('open', 'acknowledged');

-- ---- Who is asking ------------------------------------------------------------------------------
-- ok: may open God View. scoped: limited to region (null region = nobody).
create or replace function public.god_view_caller(out ok boolean, out scoped boolean, out region jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
begin
  ok := false;
  scoped := false;
  region := null;
  if v_claims is null or v_claims = '' or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    ok := true;  -- a direct database session (migrations, psql) or the service role
    return;
  end if;
  v_uid := auth.uid();
  if v_uid is null then
    return;
  end if;
  if exists (select 1 from public.admin_access a where a.profile_id = v_uid and a.page = '*') then
    ok := true;
    return;
  end if;
  select true, true, a.region into ok, scoped, region
    from public.admin_access a
   where a.profile_id = v_uid and a.page = 'admin-god-view';
  ok := coalesce(ok, false);
  scoped := coalesce(scoped, false);
end;
$$;
revoke execute on function public.god_view_caller() from public, anon, authenticated;

-- The outlines of a region named {country, state, city, suburb}: its
-- deepest named level's boundary_polys (null when it has none mapped).
create or replace function public.god_view_region_polys(p_region jsonb)
returns polygon[]
language sql
stable
security definer
set search_path = ''
as $$
  with n as (
    select lower(btrim(coalesce(p_region->>'country', ''))) c, lower(btrim(coalesce(p_region->>'state', ''))) s,
           lower(btrim(coalesce(p_region->>'city', ''))) t, lower(btrim(coalesce(p_region->>'suburb', ''))) b
  )
  select case
    when n.c = '' then null
    when n.s = '' then (select x.boundary_polys from public.countries x where lower(btrim(x.name)) = n.c limit 1)
    when n.t = '' then (select x.boundary_polys from public.states x
                         where lower(btrim(x.country)) = n.c and lower(btrim(x.name)) = n.s limit 1)
    when n.b = '' then (select x.boundary_polys from public.cities x
                         where lower(btrim(x.country)) = n.c and lower(btrim(x.state)) = n.s
                           and lower(btrim(x.name)) = n.t limit 1)
    else (select x.boundary_polys from public.suburbs x
           where lower(btrim(x.country)) = n.c and lower(btrim(x.state)) = n.s
             and lower(btrim(x.city)) = n.t and lower(btrim(x.name)) = n.b limit 1)
  end
  from n;
$$;
revoke execute on function public.god_view_region_polys(jsonb) from public, anon, authenticated;

-- Whether a person at (lat, lng), in the region names their ride or phone
-- gave, is inside the caller's region. No region: everyone. An empty
-- region (no country): nobody.
create or replace function public.god_view_in_scope(
  p_scoped boolean, p_region jsonb, p_polys polygon[],
  p_lat double precision, p_lng double precision,
  p_country text, p_state text, p_city text, p_suburb text
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_names text[] := array[p_country, p_state, p_city, p_suburb];
  v_keys text[] := array['country', 'state', 'city', 'suburb'];
  v_want text;
  i int;
begin
  if not p_scoped then
    return true;
  end if;
  if p_region is null or btrim(coalesce(p_region->>'country', '')) = '' then
    return false;
  end if;
  if coalesce(cardinality(p_polys), 0) > 0 then
    return p_lat is not null and p_lng is not null
       and exists (select 1 from unnest(p_polys) g(poly)
                    where g.poly operator(pg_catalog.@>) point(p_lng, p_lat));
  end if;
  for i in 1..4 loop
    v_want := btrim(coalesce(p_region->>v_keys[i], ''));
    exit when v_want = '';
    if not coalesce(public.region_name_matches(v_want, v_names[i]), false) then
      return false;
    end if;
  end loop;
  return true;
end;
$$;
revoke execute on function public.god_view_in_scope(boolean, jsonb, polygon[], double precision, double precision,
  text, text, text, text) from public, anon, authenticated;

-- ---- 2. The people ------------------------------------------------------------------------------
-- Everyone God View may show the caller, filtered. p_box = {min_lat,
-- min_lng, max_lat, max_lng} (null: everywhere; a min_lng above max_lng
-- crosses the 180th meridian); ignored with p_query or p_only. Internal:
-- called by the functions below only.
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
           now() - case when coalesce(p_offline, false) then interval '2 hours' else interval '30 minutes' end as seen_after
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
  -- The phone's last known place, for app-open users and every area name.
  phone as materialized (
    select distinct on (t.profile_id) t.profile_id, t.last_lat, t.last_lng, t.located_at,
           t.area_country, t.area_state, t.area_city, t.area_suburb
      from public.push_tokens t, q
     where t.located_at > q.seen_after
       and t.profile_id is not null and t.last_lat is not null and t.last_lng is not null
     order by t.profile_id, t.located_at desc
  ),
  presence as (
    select distinct on (d.profile_id) d.profile_id, d.online, d.lat, d.lng, d.updated_at,
           p.id as partner_row_id, p.name as partner_name, p.vehicle, p.make, p.model, p.plate,
           p.vehicle_type, p.partner_type
      from public.driver_presence d
      join public.partners p on p.auth_user_id = d.profile_id
     where d.updated_at > now() - interval '2 hours'
     order by d.profile_id, p.updated_at desc
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
                else 'offline' end as status,
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
        select v.lat, v.lng, v.at
          from (values (pr.lat, pr.lng, pr.updated_at),
                       (ar.partner_live_lat, ar.partner_live_lng, ar.partner_live_at),
                       (sp.lat, sp.lng, sp.location_at)) v(lat, lng, at)
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
                when ph.located_at > now() - interval '30 minutes' then 'app_open'
                else 'offline' end as status,
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
                  -- No ride: the phone.
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
     and (coalesce(p_offline, false) or e.status <> 'offline')
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

-- The page's read. Bounds in degrees (all four, or none for everywhere).
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
                                    when 'app_open' then 4 else 5 end,
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
    'counts', jsonb_build_object(
      'partners_online', count(*) filter (where f.kind = 'partner' and f.status <> 'offline'),
      'partners_free', count(*) filter (where f.kind = 'partner' and f.status = 'free'),
      'partners_on_job', count(*) filter (where f.kind = 'partner' and (f.status in ('pickup', 'trip')
                                                                        or (f.status = 'sos' and f.ride_id is not null))),
      'partners_offline', count(*) filter (where f.kind = 'partner' and f.status = 'offline'),
      'users_searching', count(*) filter (where f.kind = 'user' and f.status = 'searching'),
      'users_in_ride', count(*) filter (where f.kind = 'user' and f.status = 'ride'),
      'users_app_open', count(*) filter (where f.kind = 'user' and f.status = 'app_open'),
      'users_offline', count(*) filter (where f.kind = 'user' and f.status = 'offline'),
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

-- Whether the caller may act on p_profile on God View: anyone for a full
-- admin, someone on their map (offline ones too) for a scoped sub-admin.
create or replace function public.god_view_may_see(p_profile uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
begin
  select * into c from public.god_view_caller();
  if not c.ok then
    return false;
  end if;
  if not c.scoped then
    return true;
  end if;
  return exists (select 1 from public.god_view_people(null, true, null, p_profile, true, c.region,
                                                      public.god_view_region_polys(c.region)));
end;
$$;
revoke execute on function public.god_view_may_see(uuid) from public, anon, authenticated;

-- ---- 3. A phone number, logged ------------------------------------------------------------------
create or replace function public.god_view_reveal_phone(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only see the phone of someone on your God View map.' using errcode = '42501';
  end if;
  if v_uid is not null and (select count(*) from public.admin_audit_log l
                             where l.actor_id = v_uid and l.action = 'god_view.reveal_phone'
                               and l.created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'Too many phone numbers shown in 10 minutes. Wait a few minutes and try again.'
      using errcode = 'P0001';
  end if;
  select coalesce(nullif(btrim(pf.phone), ''),
                  (select nullif(btrim(p.phone), '') from public.partners p
                    where p.auth_user_id = p_profile_id order by p.updated_at desc limit 1))
    into v_phone
    from public.profiles pf
   where pf.id = p_profile_id;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.reveal_phone', p_profile_id, jsonb_build_object('found', v_phone is not null));
  return jsonb_build_object('phone', v_phone);
end;
$$;
revoke execute on function public.god_view_reveal_phone(uuid) from public, anon;
grant execute on function public.god_view_reveal_phone(uuid) to authenticated;

-- ---- 4. Suspend from the map --------------------------------------------------------------------
create or replace function public.god_view_suspend(p_profile_id uuid, p_reason text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 120), '');
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 360), '');
  v_shown text;
  v_partner boolean;
  v_on_trip boolean := false;
  n int;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only suspend someone on your God View map.' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Pick a reason.' using errcode = '22023';
  end if;
  v_shown := left(v_reason || coalesce(': ' || v_note, ''), 500);
  v_partner := exists (select 1 from public.partners p where p.auth_user_id = p_profile_id);
  if v_partner then
    if not public.caller_admin_can_write('partners') then
      raise exception 'You need edit access to Partners to suspend a partner.' using errcode = '42501';
    end if;
    -- As the Partners page's Block: the reason is shown to them.
    update public.partners
       set status = 'blocked', status_note = v_shown, updated_at = now()
     where auth_user_id = p_profile_id;
    get diagnostics n = row_count;
    -- No new jobs: offline now (the claim guard refuses a blocked partner's
    -- claims anyway). A ride in progress is theirs to finish.
    update public.driver_presence set online = false where profile_id = p_profile_id and online;
    v_on_trip := exists (select 1 from public.ride_requests r
                          where r.partner_id = p_profile_id and r.status in ('accepted', 'arrived', 'on_trip'));
  else
    if not public.caller_admin_can_write('profiles') then
      raise exception 'You need edit access to Users to suspend a user.' using errcode = '42501';
    end if;
    -- As the Users page's Block.
    update public.profiles
       set profile_status = 'Blocked', status = 'blocked', updated_at = now()
     where id = p_profile_id;
    get diagnostics n = row_count;
  end if;
  if n = 0 then
    raise exception 'Nothing was suspended: the account was not found.' using errcode = 'P0002';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'god_view.suspend', p_profile_id,
          jsonb_build_object('kind', case when v_partner then 'partner' else 'user' end,
                             'reason', v_reason, 'note', v_note, 'on_trip', v_on_trip));
  return jsonb_build_object('kind', case when v_partner then 'partner' else 'user' end, 'on_trip', v_on_trip);
end;
$$;
revoke execute on function public.god_view_suspend(uuid, text, text) from public, anon;
grant execute on function public.god_view_suspend(uuid, text, text) to authenticated;

-- ---- 5. Presence every 10 s ---------------------------------------------------------------------
alter table public.driver_presence add column if not exists rules_checked_at timestamptz;
comment on column public.driver_presence.rules_checked_at is
  'When set_driver_presence last checked the partner type rules for this driver going or staying online (0270: at most once a minute while online).';

-- As 0245, but a driver who stays online, about where they last reported
-- (within ~200 m), is checked against the partner type rules at most once a
-- minute (the app reports every 10 s now).
create or replace function public.set_driver_presence(
  p_online boolean,
  p_lat double precision default null,
  p_lng double precision default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lat double precision := case when p_lat between -90 and 90 then p_lat end;
  v_lng double precision := case when p_lng between -180 and 180 then p_lng end;
  v_online boolean;
  v_prev public.driver_presence;
  v_checked timestamptz;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  -- Only a driver has a presence.
  if not exists (select 1 from public.partners where auth_user_id = auth.uid()) then
    return;
  end if;
  select * into v_prev from public.driver_presence d where d.profile_id = auth.uid();
  v_checked := v_prev.rules_checked_at;
  v_online := coalesce(p_online, false) and public.caller_is_approved_partner();
  -- The partner type rules (0245): where it is offered, the permit, the
  -- vehicle's age. Without a fix this report, the last known position.
  -- Only once an admin has set rules on some type: until then, as before.
  if v_online and exists (select 1 from public.settings_entries e
                           where e.category = 'partner-type' and e.values ? 'rules')
     and not (coalesce(v_prev.online, false) and v_prev.rules_checked_at > now() - interval '60 seconds'
              -- ...and still about where they were (a jump over a border is checked at once).
              and (v_lat is null or v_lng is null
                   or (abs(v_lat - coalesce(v_prev.lat, 1000)) < 0.002 and abs(v_lng - coalesce(v_prev.lng, 1000)) < 0.002))) then
    v_online := coalesce((public.ptr_driver_check(
      auth.uid(),
      coalesce(v_lat, v_prev.lat),
      coalesce(v_lng, v_prev.lng),
      false) ->> 'ok')::boolean, true);
    v_checked := now();
  end if;
  insert into public.driver_presence (profile_id, online, lat, lng, updated_at, rules_checked_at)
  values (auth.uid(), v_online, v_lat, v_lng, now(), v_checked)
  on conflict (profile_id) do update
    set online = excluded.online,
        -- A report without a fix keeps the last known position.
        lat = coalesce(excluded.lat, driver_presence.lat),
        lng = coalesce(excluded.lng, driver_presence.lng),
        updated_at = now(),
        rules_checked_at = excluded.rules_checked_at;
end;
$$;

revoke execute on function public.set_driver_presence(boolean, double precision, double precision) from public, anon;
grant execute on function public.set_driver_presence(boolean, double precision, double precision) to authenticated;

notify pgrst, 'reload schema';
