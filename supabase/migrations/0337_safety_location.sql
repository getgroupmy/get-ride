-- ============================================================================
-- 0337 — Safety location case: an admin turns on a specific user's background
-- location for a safety case, ALWAYS disclosed to that user while it is on.
--
-- Version 20261103100000 (0337_safety_location). Re-runnable: the table,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first.
--
-- THE HARD RULE — no covert tracking. This feature never keeps a background
-- location report for a user under a safety case until that user's app has
-- shown the one-time modal (or rendered the banner) and called
-- safety_location_ack(). The gate lives in background_checkin_allowed (point
-- 2): a case that is enabled but whose notified_at is still null does NOT
-- allow a background report. There is no flag, setting or path that enables
-- background location without the indicator being shown first.
--
-- 1. safety_location_cases: one row a user (pk user_id), the open case. reason
--    (required to open, kept internal — the audit log and this table hold the
--    admin's words; the user is only ever shown a generic "a safety review"),
--    disclosure_style ('modal' | 'banner'), who opened / closed it and when,
--    notified_at (set by safety_location_ack when the user's app first shows
--    the indicator). Reopening a closed case clears notified_at, so the app
--    must disclose again before any report is kept.
-- 2. background_checkin_allowed(profile): 0333's, ALSO true for a user with an
--    open, enabled safety case whose notified_at is not null. So: drivers, OR
--    opted-in passengers while the admin switch is on, OR a safety case the
--    user has actually been shown. push_background_location (0333) reads this
--    unchanged, so the first report for a case waits until the ack.
-- 3. RPCs:
--      admin_safety_location_set(user, enabled, reason, style): an admin with
--        edit on God View ('*' or rpc:admin_safety_location_set), and only for
--        someone on their God View map (god_view_may_see). Opening needs a
--        non-empty reason. Logged in admin_audit_log ('safety_location.set').
--      safety_location_state(): about the signed-in caller only; {active,
--        style, reason (generic), since} or null. The app reads it to show the
--        modal / banner and the Settings row.
--      safety_location_ack(): the app calls it once it has shown the modal (or
--        first rendered the banner); sets notified_at = now() if null. Only
--        this unlocks background reports for the case.
-- 4. god_view_devices(profile): the per-device breakdown (device id, platform,
--    last position, located_at, freshness) for the admin's device picker, for
--    someone the caller may see. Does not widen who can call God View.
-- 5. god_view_people (0276's, same signature): a person's shown position is
--    now the newer of their freshest push_tokens report and their latest
--    user_location_history row, so an open app / in-trip / SOS refreshes the
--    map even without a background case (the "Last known 18 h" bug).
-- ============================================================================

-- ---- 1. The case -----------------------------------------------------------------------------------
create table if not exists public.safety_location_cases (
  user_id          uuid primary key references public.profiles (id) on delete cascade,
  enabled          boolean not null default false,
  reason           text not null,
  disclosure_style text not null default 'modal' check (disclosure_style in ('modal', 'banner')),
  opened_by        uuid,
  opened_at        timestamptz,
  closed_by        uuid,
  closed_at        timestamptz,
  notified_at      timestamptz,
  updated_at       timestamptz not null default now()
);
comment on table public.safety_location_cases is
  'An admin-opened safety case that turns on a user''s background location (0337). Always disclosed: no report is kept until notified_at is set by safety_location_ack.';
create index if not exists safety_location_cases_enabled_idx
  on public.safety_location_cases (user_id) where enabled;

alter table public.safety_location_cases enable row level security;
revoke all on public.safety_location_cases from public, anon, authenticated;
grant all on public.safety_location_cases to service_role;
-- The user may read their own case (the Settings row reads it through the RPC,
-- but a direct read is harmless and nothing covert can hide behind it).
drop policy if exists "safety_location own read" on public.safety_location_cases;
create policy "safety_location own read" on public.safety_location_cases
  for select to authenticated using (user_id = (select auth.uid()));

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_safety_location_set', 'admin-god-view')
on conflict do nothing;

-- ---- 2. The gate: who may have a background report kept --------------------------------------------
-- 0333's rule, ALSO true for a user whose safety case is enabled AND has been
-- disclosed (notified_at set). A case that is enabled but not yet acked does
-- NOT allow a report: this is what keeps the feature from ever tracking before
-- the indicator is shown.
create or replace function public.background_checkin_allowed(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_profile is not null and (
       exists (select 1 from public.partners pa where pa.auth_user_id = p_profile)
    or ((public.location_checkins_config() ->> 'passengers')::boolean
        and exists (select 1 from public.profiles p where p.id = p_profile and p.location_checkins))
    or exists (select 1 from public.safety_location_cases c
                where c.user_id = p_profile and c.enabled and c.notified_at is not null));
$$;
revoke execute on function public.background_checkin_allowed(uuid) from public, anon, authenticated;

-- ---- 3. RPCs ---------------------------------------------------------------------------------------
-- The case as the app and the admin read it. The user is never shown the
-- admin's exact reason: a generic, non-alarming phrase.
create or replace function public.safety_location_json(c public.safety_location_cases)
returns jsonb
language sql
stable
set search_path = public
as $$
  select case when c.user_id is null or not c.enabled then null else jsonb_build_object(
    'active', true,
    'style', c.disclosure_style,
    'reason', 'a safety review',
    'since', coalesce(c.opened_at, c.updated_at),
    'notified', c.notified_at is not null) end;
$$;
revoke execute on function public.safety_location_json(public.safety_location_cases) from public, anon, authenticated;

-- The signed-in caller's own case, or null. The app shows the modal / banner
-- and the Settings row from this.
create or replace function public.safety_location_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c public.safety_location_cases;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  select * into c from public.safety_location_cases x where x.user_id = v_uid;
  return public.safety_location_json(c);
end;
$$;
revoke execute on function public.safety_location_state() from public, anon;
grant execute on function public.safety_location_state() to authenticated;

-- The app calls this once it has actually shown the one-time modal, or first
-- rendered the banner. Sets notified_at if null — the ONLY thing that unlocks
-- background reports for the case.
create or replace function public.safety_location_ack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c public.safety_location_cases;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  update public.safety_location_cases x
     set notified_at = now(), updated_at = now()
   where x.user_id = v_uid and x.enabled and x.notified_at is null
  returning * into c;
  if c.user_id is null then
    select * into c from public.safety_location_cases x where x.user_id = v_uid;
  end if;
  return public.safety_location_json(c);
end;
$$;
revoke execute on function public.safety_location_ack() from public, anon;
grant execute on function public.safety_location_ack() to authenticated;

-- An admin opens, retunes or closes a user's safety case. Edit on God View,
-- and only for someone on the caller's own God View map. Opening needs a
-- reason; reopening a closed case clears notified_at so the app must disclose
-- afresh before any report is kept.
create or replace function public.admin_safety_location_set(
  p_user_id uuid,
  p_enabled boolean,
  p_reason text default null,
  p_disclosure_style text default 'modal'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_enabled boolean := coalesce(p_enabled, false);
  v_style text := lower(btrim(coalesce(p_disclosure_style, 'modal')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_prev public.safety_location_cases;
  c public.safety_location_cases;
begin
  if not public.caller_admin_can_write('rpc:admin_safety_location_set') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You need edit access to God View to change a safety case.';
  end if;
  if p_user_id is null or not public.god_view_may_see(p_user_id) then
    raise exception 'You can only open a safety case for someone on your God View map.' using errcode = '42501';
  end if;
  if v_style not in ('modal', 'banner') then
    raise exception 'Choose modal or banner.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user_id and p.deleted_at is null) then
    raise exception 'No such account.' using errcode = 'P0002';
  end if;
  select * into v_prev from public.safety_location_cases x where x.user_id = p_user_id;
  if v_enabled and v_reason is null and not (v_prev.user_id is not null and v_prev.enabled) then
    raise exception 'Enter a reason for the safety case.' using errcode = '22023';
  end if;

  if v_enabled then
    insert into public.safety_location_cases (user_id, enabled, reason, disclosure_style, opened_by, opened_at, updated_at)
    values (p_user_id, true, coalesce(v_reason, 'Safety case'), v_style, v_uid, now(), now())
    on conflict (user_id) do update set
      enabled = true,
      reason = coalesce(v_reason, public.safety_location_cases.reason),
      disclosure_style = v_style,
      -- Reopening a closed case: a fresh disclosure is required (notified_at
      -- cleared), the open is re-stamped.
      opened_by = case when public.safety_location_cases.enabled then public.safety_location_cases.opened_by else v_uid end,
      opened_at = case when public.safety_location_cases.enabled then public.safety_location_cases.opened_at else now() end,
      notified_at = case when public.safety_location_cases.enabled then public.safety_location_cases.notified_at else null end,
      closed_by = null, closed_at = null, updated_at = now()
    returning * into c;
  else
    update public.safety_location_cases x
       set enabled = false, disclosure_style = v_style,
           closed_by = v_uid, closed_at = now(), updated_at = now()
     where x.user_id = p_user_id
    returning * into c;
    if c.user_id is null then
      -- Nothing to close: record a closed row so the admin sees a consistent state.
      insert into public.safety_location_cases (user_id, enabled, reason, disclosure_style, closed_by, closed_at, updated_at)
      values (p_user_id, false, coalesce(v_reason, 'Safety case'), v_style, v_uid, now(), now())
      on conflict (user_id) do update set enabled = false, updated_at = now()
      returning * into c;
    end if;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'safety_location.set', p_user_id, jsonb_build_object(
    'enabled', c.enabled, 'style', c.disclosure_style, 'reason', c.reason,
    'reopened', v_enabled and not coalesce(v_prev.enabled, false)));

  -- The admin's full view of the case (reason included; this is an admin RPC).
  return jsonb_build_object(
    'user_id', c.user_id,
    'enabled', c.enabled,
    'reason', c.reason,
    'disclosure_style', c.disclosure_style,
    'opened_at', c.opened_at,
    'closed_at', c.closed_at,
    'notified_at', c.notified_at,
    'notified', c.notified_at is not null);
end;
$$;
revoke execute on function public.admin_safety_location_set(uuid, boolean, text, text) from public, anon;
grant execute on function public.admin_safety_location_set(uuid, boolean, text, text) to authenticated;

-- A read-only look at a user's case for the God View panel: the admin sees
-- the reason, the style and — so they know whether the user has actually been
-- shown the indicator — notified_at (null until the app acks). Any God View
-- admin who may see the person; no write, no gate change.
create or replace function public.admin_safety_location_state(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.safety_location_cases;
begin
  if p_user_id is null or not public.god_view_may_see(p_user_id) then
    raise exception 'You can only see the safety case of someone on your God View map.' using errcode = '42501';
  end if;
  select * into c from public.safety_location_cases x where x.user_id = p_user_id;
  return jsonb_build_object(
    'user_id', p_user_id,
    'enabled', coalesce(c.enabled, false),
    'reason', c.reason,
    'disclosure_style', coalesce(c.disclosure_style, 'modal'),
    'opened_at', c.opened_at,
    'closed_at', c.closed_at,
    'notified_at', c.notified_at,
    'notified', c.notified_at is not null);
end;
$$;
revoke execute on function public.admin_safety_location_state(uuid) from public, anon;
grant execute on function public.admin_safety_location_state(uuid) to authenticated;

-- ---- 4. God View: the person's logged-in devices ---------------------------------------------------
-- Each device that has a push token for the person, with its last position and
-- when it reported, so the admin can pick which one to centre on. Only for
-- someone the caller may see; does not widen who may open God View.
create or replace function public.god_view_devices(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_devices jsonb;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only see the devices of someone on your God View map.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(d order by d.located_at desc nulls last), '[]'::jsonb)
    into v_devices
    from (
      select distinct on (coalesce(t.device_key, t.id::text)) jsonb_build_object(
               'device_key', t.device_key,
               'token_id', t.id,
               'platform', t.platform,
               'lat', t.last_lat,
               'lng', t.last_lng,
               'located_at', t.located_at,
               'located_bg', t.located_bg,
               'location_always', t.location_always,
               'moved_at', t.moved_at) as d,
             t.located_at
        from public.push_tokens t
       where t.profile_id = p_profile_id
         and t.last_lat is not null and t.last_lng is not null
       order by coalesce(t.device_key, t.id::text), t.located_at desc nulls last
    ) d;
  return jsonb_build_object('profile_id', p_profile_id, 'devices', v_devices, 'now', now());
end;
$$;
revoke execute on function public.god_view_devices(uuid) from public, anon;
grant execute on function public.god_view_devices(uuid) to authenticated;

-- ---- 5. Freshness: the newer of push_tokens and user_location_history -------------------------------
-- 0276's god_view_people, same signature, with one change: the phone CTE now
-- takes a person's position from the newer of their freshest push_tokens
-- report and their latest user_location_history row. So an open app, a trip
-- or an SOS (which all write user_location_history) refreshes the map even
-- when no background report updated push_tokens.
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
  next_lat double precision, next_lng double precision, area text, sos boolean, incident_id uuid,
  moved_at timestamptz
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
           now() - interval '30 minutes' as live_after,
           now() - make_interval(hours => (public.god_view_settings() ->> 'alwaysOnHours')::int) as quiet_after,
           now() - case when coalesce(p_offline, false) then interval '7 days'
                        else greatest(interval '30 minutes',
                                      make_interval(hours => (public.god_view_settings() ->> 'alwaysOnHours')::int)) end
             as seen_after,
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
  -- The freshest push-token report per person (the open app's or the
  -- background's), with the area names and the always-on / app-open flags
  -- (0272, 0276).
  tok as materialized (
    select distinct on (t.profile_id) t.profile_id, t.last_lat, t.last_lng, t.located_at,
           t.area_country, t.area_state, t.area_city, t.area_suburb,
           coalesce(t.moved_at, t.located_at) as moved_at,
           (t.location_always
            and ((t.located_at > q.live_after and t.located_bg)
                 or (t.located_at <= q.live_after and t.located_at > q.quiet_after and t.bg_key_hash is not null)))
             as always_on,
           (t.located_at > q.live_after and not t.located_bg) as app_open
      from public.push_tokens t, q
     where t.located_at > q.seen_after
       and t.profile_id is not null and t.last_lat is not null and t.last_lng is not null
     order by t.profile_id, t.located_at desc
  ),
  -- The latest recorded location per person (an open app, a trip or an SOS
  -- all write it, 0278): the freshness fix.
  hist as materialized (
    select distinct on (h.user_id) h.user_id as profile_id, h.latitude as lat, h.longitude as lng, h.captured_at
      from public.user_location_history h, q
     where h.captured_at > q.seen_after and h.latitude is not null and h.longitude is not null
     order by h.user_id, h.captured_at desc
  ),
  -- Per person, the newer of the two. When the history row is newer than the
  -- push token's, its position and time win, and the person counts as live
  -- (App open at least), so God View stops showing a stale "Last known".
  phone as materialized (
    select coalesce(tk.profile_id, hs.profile_id) as profile_id,
           case when coalesce(hs.captured_at, '-infinity'::timestamptz) > coalesce(tk.located_at, '-infinity'::timestamptz)
                then hs.lat else tk.last_lat end as last_lat,
           case when coalesce(hs.captured_at, '-infinity'::timestamptz) > coalesce(tk.located_at, '-infinity'::timestamptz)
                then hs.lng else tk.last_lng end as last_lng,
           greatest(coalesce(tk.located_at, '-infinity'::timestamptz),
                    coalesce(hs.captured_at, '-infinity'::timestamptz)) as located_at,
           tk.area_country, tk.area_state, tk.area_city, tk.area_suburb,
           coalesce(tk.moved_at, greatest(coalesce(tk.located_at, '-infinity'::timestamptz),
                                          coalesce(hs.captured_at, '-infinity'::timestamptz))) as moved_at,
           coalesce(tk.always_on, false) as always_on,
           (coalesce(tk.app_open, false)
            or (hs.captured_at > q.live_after
                and coalesce(hs.captured_at, '-infinity'::timestamptz) >= coalesce(tk.located_at, '-infinity'::timestamptz)))
             as app_open
      from tok tk
      full join hist hs on hs.profile_id = tk.profile_id
      cross join q
  ),
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
           ph.moved_at,
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
           ph.moved_at,
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
                  (case when ur.user_live_at >= ur.created_at then ur.user_live_lat end,
                   case when ur.user_live_at >= ur.created_at then ur.user_live_lng end, ur.user_live_at, 1),
                  (sp.lat, sp.lng, sp.location_at, 0),
                  (case when ur.status = 'open' then ur.pickup_lat end,
                   case when ur.status = 'open' then ur.pickup_lng end, ur.updated_at, 2),
                  (case when ur.status <> 'open' then ur.partner_live_lat end,
                   case when ur.status <> 'open' then ur.partner_live_lng end, ur.partner_live_at, 3),
                  (case when ur.status <> 'open' then ur.pickup_lat end,
                   case when ur.status <> 'open' then ur.pickup_lng end, ur.updated_at, 4),
                  (case when ur.id is null then ph.last_lat end,
                   case when ur.id is null then ph.last_lng end, ph.located_at, 5)
               ) v(lat, lng, at, rank)
         where v.lat is not null and v.lng is not null
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
         e.ride_id, e.ride_code, e.other_id, e.other_name, e.eta_min, e.next_lat, e.next_lng, e.area, e.sos, e.incident_id,
         case when e.status = 'always_on' then e.moved_at end
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
