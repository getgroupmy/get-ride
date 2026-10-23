-- ============================================================================
-- 0275 — God View: the phone's area follows its position, also while the app
-- is closed; and the people with no location at all.
--
-- Applied by hand as version 20261021033300 (0275_god_view_area in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace".
--
-- Why: God View showed an "Always on" phone near Batu Dam with the area
-- "Kampung Datuk Keramat". push_checkin (the open app, every 2 minutes) and
-- push_background_location (the closed app's native reporter) move
-- push_tokens.last_lat / last_lng / located_at only (0272); the area names
-- (area_country / state / city / suburb) were set only by push_set_location,
-- which the open app calls after its own reverse geocode. A closed app never
-- refreshed them, so God View, the sub-admin's region scope
-- (god_view_in_scope) and area broadcasts (send-push inArea) went by an area
-- the phone had left.
--
-- 1. push_tokens, new columns:
--      area_lat, area_lng  where the area names were last set;
--      area_set_at         when.
-- 2. push_area_lookup(lat, lng, from lat, from lng, old names) (internal):
--    the names at a point from the admin's own regions (regions_at): the
--    most specific region whose mapped boundary holds the point, the
--    smaller one of two as specific (the enclave rule, 0170), as the app's
--    regionAt picks it. A level that region leaves open keeps the old name
--    only while the region agrees with the old names above it and the
--    phone is still close to where they were set (suburb 1 km, city 10 km,
--    state 50 km; the country whenever nothing contradicts it); else it is
--    cleared — no name is better than a far-away one — as it is when that
--    region is mapped and its boundary leaves the point out.
-- 3. push_area_refresh(token row, previous position) (internal): after a
--    move, refreshes the row's names with the lookup when they may be
--    wrong: no area point yet, more than 1 km from it, or more than 200 m
--    and set over 30 minutes ago. A phone that has not moved costs one
--    distance check.
-- 4. push_checkin and push_background_location (as 0272) call it for each
--    row they moved; push_set_location (as 0272) also records the area
--    point. Same signatures, grants and checks as before.
-- god_view_snapshot / god_view_people read the names as before: unchanged.
-- 5. god_view_unlocated(query, limit): Admin → God View's "No location"
--    list: every account God View cannot put on the map (no phone report,
--    presence, live ride or SOS position in the past 7 days), partner or
--    user, with what can be told about why:
--      no_app        no push token at all: has not opened the new app;
--      never_located token rows, none ever located (with the account's app
--                    version and platform, 0176, so the page can say "Old
--                    app version" or "Location not allowed");
--      stale         located, but before the 7-day window (last_seen_at).
--    Same caller check as god_view_snapshot (god_view_caller). A sub-admin
--    with a region sees only those who can be placed in it: a stale
--    position (god_view_in_scope), else a partner's service area
--    (partners.service_countries / states / cities), else, for a
--    country-only region, the profile's country (profiles.nationality).
--    Anyone else is shown to unscoped admins only. Never a phone number;
--    the search matches name, plate and (4+ digits) phone, as the map's.
-- ============================================================================

-- ---- 1. Where and when the area was set -------------------------------------------------------
alter table public.push_tokens
  add column if not exists area_lat double precision,
  add column if not exists area_lng double precision,
  add column if not exists area_set_at timestamptz;
comment on column public.push_tokens.area_lat is
  'Where the area names (area_country .. area_suburb) were last set (0275), with area_lng.';
comment on column public.push_tokens.area_set_at is
  'When the area names were last set (0275): by the open app (push_set_location) or from the regions after a move.';

-- ---- 2. The names at a point, from the regions ------------------------------------------------
create or replace function public.push_area_lookup(
  p_lat double precision,
  p_lng double precision,
  p_from_lat double precision,
  p_from_lng double precision,
  p_country text,
  p_state text,
  p_city text,
  p_suburb text
)
returns table (country text, state text, city text, suburb text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_spec int := -1;
  v_area double precision;
  v_names text[];
  v_old text[] := array[p_country, p_state, p_city, p_suburb];
  -- How far from where the old names were set each open level is kept.
  v_keep_km double precision[] := array['infinity', 50, 10, 1]::double precision[];
  -- Regions with a mapped boundary that does not hold the point.
  v_outside text[] := '{}';
  v_res text[] := array[null, null, null, null]::text[];
  v_km double precision;
  v_agrees boolean := true;
  v_name text;
  v_key text;
  g record;
begin
  for g in
    select x.country, x.state, x.city, x.suburb, x.inside, x.area,
           case when coalesce(x.suburb, '') <> '' then 3
                when coalesce(x.city, '') <> '' then 2
                when coalesce(x.state, '') <> '' then 1
                else 0 end as spec
      from public.regions_at(p_lat, p_lng) x
     where x.has_boundary
  loop
    if g.inside then
      if g.spec > v_spec or (g.spec = v_spec and g.area < coalesce(v_area, 'infinity')) then
        v_spec := g.spec;
        v_area := g.area;
        v_names := array[g.country, g.state, g.city, g.suburb];
      end if;
    else
      v_outside := v_outside || lower(concat_ws('|', btrim(coalesce(g.country, '')), btrim(coalesce(g.state, '')),
                                                btrim(coalesce(g.city, '')), btrim(coalesce(g.suburb, ''))));
    end if;
  end loop;
  if p_from_lat is not null and p_from_lng is not null then
    v_km := public.km_between(p_from_lat, p_from_lng, p_lat, p_lng);
  end if;
  for i in 1..4 loop
    if i - 1 <= v_spec then
      v_name := nullif(left(btrim(coalesce(v_names[i], '')), 120), '');
      if lower(coalesce(v_name, '')) <> lower(btrim(coalesce(v_old[i], ''))) then
        v_agrees := false;
      end if;
    elsif v_agrees and v_km is not null and v_km < v_keep_km[i] then
      v_name := nullif(left(btrim(coalesce(v_old[i], '')), 120), '');
      -- Not when that region is mapped and its boundary leaves the point out.
      v_key := lower(concat_ws('|', btrim(coalesce(v_old[1], '')),
                               case when i >= 2 then btrim(coalesce(v_old[2], '')) else '' end,
                               case when i >= 3 then btrim(coalesce(v_old[3], '')) else '' end,
                               case when i >= 4 then btrim(coalesce(v_old[4], '')) else '' end));
      if v_key = any(v_outside) then
        v_name := null;
      end if;
    else
      v_name := null;
    end if;
    -- Nothing is kept below a level left empty.
    if v_name is null then
      v_agrees := false;
    end if;
    v_res[i] := v_name;
  end loop;
  return query select v_res[1], v_res[2], v_res[3], v_res[4];
end;
$$;
revoke execute on function public.push_area_lookup(double precision, double precision, double precision,
  double precision, text, text, text, text) from public, anon, authenticated;

-- ---- 3. After a move ---------------------------------------------------------------------------
create or replace function public.push_area_refresh(
  p_id uuid,
  p_prev_lat double precision,
  p_prev_lng double precision
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  t record;
  a record;
  v_km double precision;
  v_from_lat double precision;
  v_from_lng double precision;
begin
  select k.last_lat, k.last_lng, k.area_lat, k.area_lng, k.area_set_at,
         k.area_country, k.area_state, k.area_city, k.area_suburb
    into t
    from public.push_tokens k
   where k.id = p_id;
  if not found or t.last_lat is null or t.last_lng is null then
    return false;
  end if;
  if t.area_lat is not null and t.area_lng is not null then
    v_km := public.km_between(t.area_lat, t.area_lng, t.last_lat, t.last_lng);
    if v_km <= 0.2 or (v_km <= 1 and t.area_set_at > now() - interval '30 minutes') then
      return false;
    end if;
    v_from_lat := t.area_lat;
    v_from_lng := t.area_lng;
  else
    -- Set before 0275: the names were most likely set at the previous position.
    v_from_lat := p_prev_lat;
    v_from_lng := p_prev_lng;
  end if;
  select * into a
    from public.push_area_lookup(t.last_lat, t.last_lng, v_from_lat, v_from_lng,
                                 t.area_country, t.area_state, t.area_city, t.area_suburb);
  update public.push_tokens k
     set area_country = a.country,
         area_state = a.state,
         area_city = a.city,
         area_suburb = a.suburb,
         area_lat = t.last_lat,
         area_lng = t.last_lng,
         area_set_at = now()
   where k.id = p_id;
  return true;
end;
$$;
revoke execute on function public.push_area_refresh(uuid, double precision, double precision)
  from public, anon, authenticated;

-- ---- 4. The open app's check-in (as 0272), now refreshing the area -----------------------------
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
  n int := 0;
  r record;
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
  for r in
    update public.push_tokens t
       set last_lat = p_lat,
           last_lng = p_lng,
           located_at = now(),
           located_bg = coalesce(p_background, false),
           location_always = coalesce(p_always, false),
           -- The key only while location is set to always.
           bg_key_hash = case when coalesce(p_always, false) then coalesce(v_hash, t.bg_key_hash) end
      from public.push_tokens o
     where o.id = t.id
       and t.profile_id = auth.uid()
       and t.token = any(coalesce(p_tokens, '{}'))
    returning t.id, o.last_lat as prev_lat, o.last_lng as prev_lng
  loop
    n := n + 1;
    perform public.push_area_refresh(r.id, r.prev_lat, r.prev_lng);
  end loop;
  return n;
end;
$$;
revoke execute on function public.push_checkin(text[], double precision, double precision, boolean, boolean, text)
  from public, anon;
grant execute on function public.push_checkin(text[], double precision, double precision, boolean, boolean, text)
  to authenticated;

-- ---- 4. The closed app's report (as 0272), now refreshing the area -----------------------------
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
    returning t.id, o.last_lat as prev_lat, o.last_lng as prev_lng
  loop
    n := n + 1;
    perform public.push_area_refresh(r.id, r.prev_lat, r.prev_lng);
  end loop;
  return n;
end;
$$;
revoke execute on function public.push_background_location(text, double precision, double precision) from public;
grant execute on function public.push_background_location(text, double precision, double precision)
  to anon, authenticated;

-- ---- 4. push_set_location (as 0272), also recording where the area was set ---------------------
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
         area_lat = p_lat,
         area_lng = p_lng,
         area_set_at = now(),
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

-- ---- 5. God View: the people with no location -------------------------------------------------
create or replace function public.god_view_unlocated(
  p_query text default null,
  p_limit integer default 500
)
returns table (
  kind text, id uuid, partner_row_id uuid, name text, vehicle text, plate text,
  reason text, last_seen_at timestamptz, app_version text, app_platform text, token_platform text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_polys polygon[];
  v_t text := nullif(regexp_replace(lower(btrim(coalesce(p_query, ''))), '[%_\\]', '', 'g'), '');
  v_digits text := nullif(regexp_replace(coalesce(p_query, ''), '\D', '', 'g'), '');
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_week timestamptz := now() - interval '7 days';
  v_country text;
  v_state text;
  v_city text;
  v_suburb text;
begin
  select * into c from public.god_view_caller();
  if not c.ok then
    raise exception 'Only a full admin, or an admin given the God View page, can open God View.'
      using errcode = '42501';
  end if;
  if c.scoped then
    if c.region is null or btrim(coalesce(c.region->>'country', '')) = '' then
      return;
    end if;
    v_polys := public.god_view_region_polys(c.region);
    v_country := btrim(coalesce(c.region->>'country', ''));
    v_state := btrim(coalesce(c.region->>'state', ''));
    v_city := btrim(coalesce(c.region->>'city', ''));
    v_suburb := btrim(coalesce(c.region->>'suburb', ''));
  end if;
  return query
  with
  -- On the map already (god_view_people with the 7-day window).
  on_map as (
    select t.profile_id as pid from public.push_tokens t
     where t.profile_id is not null and t.last_lat is not null and t.last_lng is not null and t.located_at > v_week
    union select d.profile_id from public.driver_presence d
     where d.updated_at > v_week and d.lat is not null and d.lng is not null
    union select unnest(array[r.rider_id, r.partner_id]) from public.ride_requests r
     where r.status in ('open', 'accepted', 'arrived', 'on_trip') and r.updated_at > now() - interval '12 hours'
    union select unnest(array[s.reporter_id, s.rider_id, s.partner_id]) from public.safety_incidents s
     where s.status in ('open', 'acknowledged')
  ),
  tok as (
    select t.profile_id as pid,
           count(*) as n,
           max(t.located_at) filter (where t.last_lat is not null and t.last_lng is not null) as located_at,
           (array_agg(t.platform order by t.updated_at desc))[1] as platform
      from public.push_tokens t
     where t.profile_id is not null
     group by t.profile_id
  ),
  -- The freshest old position, for the region scope.
  old_pos as (
    select distinct on (t.profile_id) t.profile_id as pid, t.last_lat as lat, t.last_lng as lng,
           t.area_country, t.area_state, t.area_city, t.area_suburb
      from public.push_tokens t
     where t.profile_id is not null and t.last_lat is not null and t.last_lng is not null
     order by t.profile_id, t.located_at desc nulls last
  ),
  presence_old as (
    select d.profile_id as pid, d.updated_at, d.lat, d.lng
      from public.driver_presence d
     where d.lat is not null and d.lng is not null
  ),
  partner as (
    select distinct on (p.auth_user_id) p.auth_user_id as pid, p.id as partner_row_id, p.name, p.plate,
           coalesce(nullif(btrim(concat_ws(' ', p.make, p.model)), ''), p.vehicle) as vehicle,
           p.service_countries, p.service_states, p.service_cities
      from public.partners p
     where p.auth_user_id is not null
     order by p.auth_user_id, p.updated_at desc
  ),
  people as (
    select case when pa.pid is not null then 'partner' else 'user' end as kind,
           pf.id, pa.partner_row_id,
           coalesce(nullif(btrim(pf.name), ''), nullif(btrim(pa.name), '')) as name,
           pa.vehicle, pa.plate,
           case when tk.pid is null then 'no_app'
                when tk.located_at is null and po.pid is null then 'never_located'
                else 'stale' end as reason,
           nullif(greatest(coalesce(tk.located_at, '-infinity'::timestamptz),
                           coalesce(po.updated_at, '-infinity'::timestamptz)), '-infinity'::timestamptz) as last_seen_at,
           nullif(btrim(pf.app_version), '') as app_version,
           nullif(btrim(pf.app_platform), '') as app_platform,
           tk.platform as token_platform,
           coalesce(op.lat, po.lat) as lat, coalesce(op.lng, po.lng) as lng,
           op.area_country, op.area_state, op.area_city, op.area_suburb,
           pf.nationality, pa.service_countries, pa.service_states, pa.service_cities,
           pf.phone
      from public.profiles pf
      left join partner pa on pa.pid = pf.id
      left join tok tk on tk.pid = pf.id
      left join old_pos op on op.pid = pf.id
      left join presence_old po on po.pid = pf.id
     where pf.deleted_at is null
       and not exists (select 1 from on_map m where m.pid = pf.id)
  )
  select x.kind, x.id, x.partner_row_id, x.name, x.vehicle, x.plate, x.reason, x.last_seen_at,
         x.app_version, x.app_platform, x.token_platform
    from people x
   where (v_t is null
          or lower(coalesce(x.name, '')) like '%' || v_t || '%'
          or replace(lower(coalesce(x.plate, '')), ' ', '') like '%' || replace(v_t, ' ', '') || '%'
          or (length(coalesce(v_digits, '')) >= 4
              and regexp_replace(coalesce(x.phone, ''), '\D', '', 'g') like '%' || v_digits || '%'))
     and (not c.scoped
          -- An old position: as the map scopes it.
          or (x.lat is not null
              and public.god_view_in_scope(true, c.region, v_polys, x.lat, x.lng,
                                           x.area_country, x.area_state, x.area_city, x.area_suburb))
          -- A partner without one: the service area they signed up for.
          or (x.lat is null and x.kind = 'partner' and v_suburb = ''
              and exists (select 1 from unnest(x.service_countries) v(n) where public.region_name_matches(v_country, v.n))
              and (v_state = '' or exists (select 1 from unnest(x.service_states) v(n)
                                             where public.region_name_matches(v_state, v.n)))
              and (v_city = '' or exists (select 1 from unnest(x.service_cities) v(n)
                                            where public.region_name_matches(v_city, v.n))))
          -- A user without one, for a country-wide region: the profile's country.
          or (x.lat is null and x.kind = 'user' and v_state = ''
              and coalesce(public.region_name_matches(v_country, x.nationality), false)))
   order by lower(coalesce(x.name, '')), x.id
   limit v_limit;
end;
$$;
revoke execute on function public.god_view_unlocated(text, integer) from public, anon;
grant execute on function public.god_view_unlocated(text, integer) to authenticated;

notify pgrst, 'reload schema';
