-- ============================================================================
-- 0285 — God View: which people a sub-admin sees.
--
-- Applied by hand as version 20261024150000 (0285_god_view_people in
-- supabase_migrations.schema_migrations). Re-runnable.
--
-- A sub-admin's God View grant has a region (0270), or Everywhere (0284). A
-- full admin (or an admin who edits Sub-admins) can now narrow it further, in Admin → Sub-admins, on the same
-- grant. It only ever takes people away:
--
--   * Who they see (admin_access.people_mode):
--       null      Region: the region on the grant, or Everywhere, as before.
--       'only'    Only these people: the "only" list, wherever they are.
--       'nobody'  Nobody: they keep the page and see no one on it.
--   * public.admin_god_view_people: the grant's "only" and "hide" lists. Hide
--     applies with Region and Everywhere; a hidden person is not shown even
--     inside the region.
--
-- Enforced on the server, for every God View read and action:
--   * god_view_caller() reads a grant set to Only or Nobody as limited with no
--     region (sees nobody), so anything that asks it alone fails closed.
--   * god_view_people_rule() is the caller's mode and lists;
--     god_view_rule_allows(mode, only, hide, person) the one test.
--   * god_view_snapshot (map, list, search) and god_view_unlocated ("No
--     location") filter their rows with it; god_view_may_see(person), which
--     every per-person call asks (Movement trail, ping and its answer with the
--     phone details, Live, show phone, suspend, the live points' RLS), asks it
--     first. Full admins are never limited.
--
-- Written only through admin_god_view_people_save(), which whoever edits
-- Admin → Sub-admins may call (caller_admin_can_write('rpc:admin_god_view_people_save'):
-- a full admin, or an EDIT grant on admin-settings-sub-admin, the page that
-- already writes admin_access) but never on their own grant unless a full
-- admin; it logs the change in admin_audit_log ('god_view.people'). Read
-- through admin_god_view_people_get() by the same page's grants. The table
-- has no write grants at all, and admin_access.people_mode is refused to a
-- direct client write (admin_access_people_mode_guard).
-- ============================================================================

-- ---- 1. Where it is kept --------------------------------------------------------------------------
alter table public.admin_access add column if not exists people_mode text;
alter table public.admin_access drop constraint if exists admin_access_people_mode_check;
alter table public.admin_access add constraint admin_access_people_mode_check
  check (people_mode is null or people_mode in ('only', 'nobody'));
comment on column public.admin_access.people_mode is
  'God View (admin-god-view) only: who a sub-admin sees. null = the region (or Everywhere); only = the people on admin_god_view_people''s "only" list; nobody = no one (0285). Set through admin_god_view_people_save().';

create table if not exists public.admin_god_view_people (
  grant_id   uuid not null references public.admin_access(id) on delete cascade,
  person_id  uuid not null references public.profiles(id) on delete cascade,
  list       text not null check (list in ('only', 'hide')),
  added_by   uuid,
  created_at timestamptz not null default now(),
  primary key (grant_id, list, person_id)
);
create index if not exists admin_god_view_people_person_idx on public.admin_god_view_people (person_id);
comment on table public.admin_god_view_people is
  'A sub-admin''s God View grant: the people it shows only (list = only, with people_mode = only) or never (list = hide, with the region or Everywhere). 0285. Written by admin_god_view_people_save() only.';

alter table public.admin_god_view_people enable row level security;
revoke all on public.admin_god_view_people from anon, authenticated;
grant select on public.admin_god_view_people to authenticated;
drop policy if exists "admin_god_view_people full admin read" on public.admin_god_view_people;
create policy "admin_god_view_people full admin read" on public.admin_god_view_people
  for select to authenticated using ((select public.caller_is_full_admin()));

-- Only the RPC sets who they see: the Sub-admins page's own admin_access
-- writes (grants, levels, regions) leave people_mode alone.
create or replace function public.admin_access_people_mode_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A client (anon, authenticated) writing the table itself; the save RPC
  -- runs as its owner.
  if current_user::text in ('anon', 'authenticated')
     and (case when tg_op = 'INSERT' then new.people_mode is not null
               else new.people_mode is distinct from old.people_mode end) then
    raise exception 'Who a sub-admin sees on God View is set on the Sub-admins page only.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.admin_access_people_mode_guard() from public, anon, authenticated;
drop trigger if exists admin_access_people_mode_guard on public.admin_access;
create trigger admin_access_people_mode_guard
  before insert or update of people_mode on public.admin_access
  for each row execute function public.admin_access_people_mode_guard();

-- The Sub-admins page (and the Settings hub, through caller_admin_can_write)
-- saves the lists, as it writes admin_access.
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_god_view_people_save', 'admin-settings-sub-admin')
on conflict do nothing;

-- ---- 2. The caller -----------------------------------------------------------------------------
-- As 0284; a grant set to Only these people or Nobody is limited with no
-- region, which sees nobody: the functions below lift it for Only.
create or replace function public.god_view_caller(out ok boolean, out scoped boolean, out region jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
  v_mode text;
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
  select true, true, a.region, a.people_mode into ok, scoped, region, v_mode
    from public.admin_access a
   where a.profile_id = v_uid and a.page = 'admin-god-view';
  ok := coalesce(ok, false);
  scoped := coalesce(scoped, false);
  -- Everywhere, set on purpose in Admin → Sub-admins: no region limit.
  if ok and coalesce(region ->> 'everywhere', '') = 'true' then
    scoped := false;
    region := null;
  end if;
  -- Only these people / Nobody (0285): no region to go by.
  if ok and v_mode is not null then
    scoped := true;
    region := null;
  end if;
end;
$$;
revoke execute on function public.god_view_caller() from public, anon, authenticated;

-- The caller's people rule: mode null for whoever is not limited (a full
-- admin, the service role, a direct session); else 'region', 'only' or
-- 'nobody' with the grant's lists.
create or replace function public.god_view_people_rule(out mode text, out only_ids uuid[], out hide_ids uuid[])
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
  v_grant uuid;
begin
  mode := null;
  only_ids := '{}';
  hide_ids := '{}';
  if v_claims is null or v_claims = '' or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return;
  end if;
  v_uid := auth.uid();
  if v_uid is not null and exists (select 1 from public.admin_access a where a.profile_id = v_uid and a.page = '*') then
    return;
  end if;
  select a.id, coalesce(a.people_mode, 'region') into v_grant, mode
    from public.admin_access a
   where a.profile_id = v_uid and a.page = 'admin-god-view';
  if v_grant is null then
    mode := 'nobody';
    return;
  end if;
  select coalesce(array_agg(p.person_id) filter (where p.list = 'only'), '{}'),
         coalesce(array_agg(p.person_id) filter (where p.list = 'hide'), '{}')
    into only_ids, hide_ids
    from public.admin_god_view_people p
   where p.grant_id = v_grant;
end;
$$;
revoke execute on function public.god_view_people_rule() from public, anon, authenticated;

-- The one test: may a caller with this rule see p_person?
create or replace function public.god_view_rule_allows(p_mode text, p_only uuid[], p_hide uuid[], p_person uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_mode is null
      or coalesce(p_mode = 'only' and p_person = any(coalesce(p_only, '{}')), false)
      or coalesce(p_mode = 'region' and not (p_person = any(coalesce(p_hide, '{}'))), false);
$$;
revoke execute on function public.god_view_rule_allows(text, uuid[], uuid[], uuid) from public, anon, authenticated;

-- ---- 3. One person: everything per person asks this -----------------------------------------------
-- As 0270, with the rule first. Only these people: a listed person anywhere.
create or replace function public.god_view_may_see(p_profile uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  r record;
begin
  select * into c from public.god_view_caller();
  if not c.ok or p_profile is null then
    return false;
  end if;
  select * into r from public.god_view_people_rule();
  if not public.god_view_rule_allows(r.mode, r.only_ids, r.hide_ids, p_profile) then
    return false;
  end if;
  if not c.scoped or r.mode = 'only' then
    return true;
  end if;
  return exists (select 1 from public.god_view_people(null, true, null, p_profile, true, c.region,
                                                      public.god_view_region_polys(c.region)));
end;
$$;
revoke execute on function public.god_view_may_see(uuid) from public, anon, authenticated;

-- ---- 4. The map, the list and the search ------------------------------------------------------------
-- As 0276, the rows filtered by the rule; 'people_mode' says which applies.
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
  r record;
  v_area boolean;
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
  select * into r from public.god_view_people_rule();
  -- Only these people: the list limits them, not a region.
  v_area := c.scoped and r.mode is distinct from 'only';
  if v_area then
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
      from public.god_view_people(v_box, p_show_offline, p_query, null, v_area, c.region, v_polys) g
     where public.god_view_rule_allows(r.mode, r.only_ids, r.hide_ids, g.id)
  )
  select jsonb_build_object(
    'at', now(),
    'scoped', c.scoped,
    'region', case when c.scoped and r.mode = 'region' then c.region end,
    'scope_missing', c.scoped and r.mode = 'region'
                     and (c.region is null or btrim(coalesce(c.region->>'country', '')) = ''),
    'people_mode', r.mode,
    'settings', public.god_view_settings()
                || jsonb_build_object('editable', not c.scoped and (auth.uid() is null or public.caller_is_full_admin())),
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
        'area', f.area, 'sos', f.sos, 'incident_id', f.incident_id, 'moved_at', f.moved_at) order by f.rn)
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

-- ---- 5. "No location" --------------------------------------------------------------------------
-- As 0275, filtered by the rule.
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
  r record;
  v_area boolean;
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
  select * into r from public.god_view_people_rule();
  if r.mode = 'nobody' then
    return;
  end if;
  v_area := c.scoped and r.mode is distinct from 'only';
  if v_area then
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
    union select unnest(array[rr.rider_id, rr.partner_id]) from public.ride_requests rr
     where rr.status in ('open', 'accepted', 'arrived', 'on_trip') and rr.updated_at > now() - interval '12 hours'
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
     and public.god_view_rule_allows(r.mode, r.only_ids, r.hide_ids, x.id)
     and (not v_area
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

-- ---- 6. Admin → Sub-admins: read and save -----------------------------------------
-- One sub-admin's God View people: the mode ('region', 'only', 'nobody')
-- and both lists, each person with name, phone, display id and whether
-- they are a partner. No God View grant: Region and no one listed.
create or replace function public.admin_god_view_people_get(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_grant uuid;
  v_mode text;
begin
  -- A full admin, or a grant on the Sub-admins page (or the Settings hub).
  if not (public.caller_is_full_admin()
          or exists (select 1 from public.admin_access a
                      where a.profile_id = auth.uid()
                        and a.page in ('admin-settings-sub-admin', 'admin-settings'))) then
    raise exception 'Only an admin who edits Sub-admins can see who a sub-admin''s God View shows.' using errcode = '42501';
  end if;
  select a.id, coalesce(a.people_mode, 'region') into v_grant, v_mode
    from public.admin_access a
   where a.profile_id = p_profile_id and a.page = 'admin-god-view';
  return jsonb_build_object(
    'mode', coalesce(v_mode, 'region'),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pf.id, 'name', pf.name, 'phone', pf.phone, 'display_id', pf.display_id,
               'partner', exists (select 1 from public.partners pa where pa.auth_user_id = pf.id),
               'list', g.list)
             order by g.list, lower(coalesce(pf.name, '')), pf.id)
        from public.admin_god_view_people g
        join public.profiles pf on pf.id = g.person_id
       where g.grant_id = v_grant), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_god_view_people_get(uuid) from public, anon;
grant execute on function public.admin_god_view_people_get(uuid) to authenticated;

-- Sets the mode and replaces both lists, in one go, and logs what changed.
-- p_mode: 'region', 'only' or 'nobody'. The person must hold God View.
create or replace function public.admin_god_view_people_save(
  p_profile_id uuid,
  p_mode text,
  p_only uuid[] default '{}',
  p_hide uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_mode text := lower(btrim(coalesce(p_mode, 'region')));
  v_grant uuid;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.caller_admin_can_write('rpc:admin_god_view_people_save') then
    raise exception 'Only an admin who edits Sub-admins can change who a sub-admin''s God View shows.' using errcode = '42501';
  end if;
  -- No one lifts their own limit; a full admin is never limited anyway.
  if p_profile_id = v_uid and not public.caller_is_full_admin() then
    raise exception 'You can''t change who your own God View shows.' using errcode = '42501';
  end if;
  if v_mode not in ('region', 'only', 'nobody') then
    raise exception 'Who they see is region, only or nobody.' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_only), 0) > 500 or coalesce(cardinality(p_hide), 0) > 500 then
    raise exception 'List at most 500 people.' using errcode = '22023';
  end if;
  select a.id into v_grant
    from public.admin_access a
   where a.profile_id = p_profile_id and a.page = 'admin-god-view'
   for update;
  if v_grant is null then
    raise exception 'They have no God View access to limit.' using errcode = 'P0002';
  end if;

  v_before := public.admin_god_view_people_state(v_grant);
  update public.admin_access set people_mode = nullif(v_mode, 'region') where id = v_grant;
  delete from public.admin_god_view_people where grant_id = v_grant;
  insert into public.admin_god_view_people (grant_id, person_id, list, added_by)
  select v_grant, pf.id, x.list, v_uid
    from (select distinct unnest(coalesce(p_only, '{}')) as pid, 'only'::text as list
          union
          select distinct unnest(coalesce(p_hide, '{}')), 'hide') x
    join public.profiles pf on pf.id = x.pid
  on conflict do nothing;
  v_after := public.admin_god_view_people_state(v_grant);

  if v_before is distinct from v_after then
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (v_uid, 'god_view.people', p_profile_id, jsonb_build_object('before', v_before, 'after', v_after));
  end if;
  return public.admin_god_view_people_get(p_profile_id);
end;
$$;

-- The grant's mode and lists as stored, for the log.
create or replace function public.admin_god_view_people_state(p_grant uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'mode', coalesce((select a.people_mode from public.admin_access a where a.id = p_grant), 'region'),
    'only', coalesce((select jsonb_agg(g.person_id order by g.person_id) from public.admin_god_view_people g
                       where g.grant_id = p_grant and g.list = 'only'), '[]'::jsonb),
    'hide', coalesce((select jsonb_agg(g.person_id order by g.person_id) from public.admin_god_view_people g
                       where g.grant_id = p_grant and g.list = 'hide'), '[]'::jsonb));
$$;
revoke execute on function public.admin_god_view_people_state(uuid) from public, anon, authenticated;
revoke execute on function public.admin_god_view_people_save(uuid, text, uuid[], uuid[]) from public, anon;
grant execute on function public.admin_god_view_people_save(uuid, text, uuid[], uuid[]) to authenticated;

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024150000', '0285_god_view_people') on conflict do nothing;
