-- ============================================================================
-- 0301 — Per-service checks for every vehicle, worked out by the server
-- (docs/KIV.md M9).
--
-- Version 20261027170000 (0301_vehicle_service_checks). Re-runnable: the
-- column "if not exists", functions "create or replace", triggers dropped
-- first, seed rows "on conflict do nothing". No vehicle is changed when it
-- runs: existing vehicles are checked only when an admin applies it
-- (admin_vehicle_service_checks_apply) or the vehicle is submitted again.
--
-- 1. vehicle_service_checks(vehicle): what partner registration's
--    vehicleServiceStatuses (partner_registration.dart) works out, on the
--    server: for each vehicle-required Partner Service type of the vehicle
--    (its partner_types, else its owner partner's), in its registration
--    region (its service area, else the owner's): paused_age when the
--    vehicle is over that type's effective age limit (the type's own, or the
--    larger limit of a registered type that covers it there,
--    ageLimitCovers; the lowest place of the area wins), waiting_permit when
--    the type needs a vehicle permit there (vehiclePermit) and no approved,
--    in-date permit of that permit type KEY is on the vehicle (as 0299),
--    else active. Age from the registration date, else 1 January of the
--    year made, in whole years.
-- 2. vehicle_service_status_fill(vehicle) writes them: rows for the types
--    the vehicle has are upserted, rows for types it no longer has are
--    removed, rows an admin set (set_by_admin, new) are kept as they are. A
--    vehicle with no type at all is left alone.
-- 3. It runs when a vehicle is submitted (documents_ok false -> true:
--    registration and vehicles added later alike), and again when a
--    submitted vehicle's types, year, registration date or service area
--    change.
-- 4. A vehicle added later is no longer refused when it is too old for every
--    type (VEHICLE_TOO_OLD, 0245/0288): as in registration, only the
--    service it fails is paused (owner's decision). Approved vehicles taken
--    to drive are still checked by claim_vehicle (0245).
-- 5. The server has the last word on the rows. The registration wizard
--    (older apps too) still writes them while the vehicle is a draft (the
--    0288 policies stay, so nothing it does is refused); submitting replaces
--    them with the server's. Admin-set rows can't be changed or removed from
--    the apps: such a write is skipped, not refused.
-- 6. admin_vehicle_service_checks_preview(vehicle?) shows, per vehicle and
--    service, the row today, what the checks say and what applying would
--    leave; admin_vehicle_service_checks_apply(vehicle) writes them. Admins
--    with EDIT on the vehicle pages (caller_admin_can_write).
-- ============================================================================

-- ---- 1. Who set a row ----------------------------------------------------------------------------
alter table public.vehicle_service_status
  add column if not exists set_by_admin boolean not null default false;
comment on column public.vehicle_service_status.set_by_admin is
  'An admin set this row (0301): the server''s checks keep it as it is.';

-- ---- 2. The checks ----------------------------------------------------------------------------------
-- A partner-type entry's stored values (as partner_type_rules finds it), for
-- the registration settings partner_type_rules leaves out: vehiclePermit,
-- ageLimitCovers.
create or replace function public.vsc_type_values(p_name text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select e.values from public.settings_entries e
     where e.category = 'partner-type' and public.ptr_key(e.values ->> 'name') = public.ptr_key(p_name)
     order by e.active desc, e.position, e.created_at
     limit 1), '{}'::jsonb);
$$;
revoke execute on function public.vsc_type_values(text) from public, anon, authenticated;

-- The narrowest of a list of scoped rules holding the place (the first on a
-- tie), or null: PermitRequirement.ruleAt and coverRuleAt in the app.
create or replace function public.vsc_narrowest(
  p_list jsonb, p_country text, p_state text, p_city text, p_suburb text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select x.s
    from jsonb_array_elements(case when jsonb_typeof(public.ptr_json(p_list)) = 'array'
                                   then public.ptr_json(p_list) else '[]'::jsonb end) with ordinality x(s, n)
   where jsonb_typeof(x.s) = 'object'
     and public.ptr_scope_matches(x.s, p_country, p_state, p_city, p_suburb)
   order by public.ptr_scope_rank(x.s) desc, x.n
   limit 1;
$$;

-- What each of [p_vehicle]'s services should be: one row per vehicle-required
-- type, as the app's vehicleServiceStatuses.
create or replace function public.vehicle_service_checks(p_vehicle uuid)
returns table (service text, status text, max_age_years integer, limit_type text, permit_name text,
               permit_type text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  ctx        jsonb := public.ptr_vehicle_context(p_vehicle);
  v_countries text[];
  v_states   text[];
  v_cities   text[];
  v_types    text[];
  v_reg      date;
  v_age      integer;
  s          text;
  c          text;
  t          jsonb;
  ct         jsonb;
  preq       jsonb;
  pl         record;
  own        jsonb;
  lim        jsonb;
  cover      jsonb;
  cover_rule jsonb;
  at_place   jsonb;
  worst      jsonb;
  permit     jsonb;
  v_key      text;
  v_over     boolean;
  v_has      boolean;
begin
  if ctx is null then
    return;
  end if;
  v_countries := public.ptr_text_array(ctx -> 'countries');
  v_states := public.ptr_text_array(ctx -> 'states');
  v_cities := public.ptr_text_array(ctx -> 'cities');
  -- The vehicle services: the types that need a vehicle, by their entry's
  -- name, once each (vehicleServicesOf).
  select coalesce(array_agg(q.name order by q.n), '{}') into v_types
    from (
      select distinct on (public.ptr_key(r ->> 'name')) r ->> 'name' as name, u.n
        from unnest(public.ptr_text_array(ctx -> 'types')) with ordinality u(x, n)
        cross join lateral (select public.partner_type_rules(u.x) as r) z
       where btrim(coalesce(u.x, '')) <> '' and (z.r ->> 'vehicleRequired')::boolean
       order by public.ptr_key(r ->> 'name'), u.n
    ) q;

  select coalesce(v.registration_date,
                  make_date(nullif(substring(coalesce(v.year, '') from '(\d{4})'), '')::int, 1, 1))
    into v_reg
    from public.vehicle v where v.id = p_vehicle;
  -- Whole years (vehicleAgeYears): registered 1 Nov 2010 is 15 on 31 Oct 2026.
  v_age := case when v_reg is null then null
                else greatest(extract(year from age(current_date, v_reg))::int, 0) end;

  foreach s in array v_types loop
    t := public.partner_type_rules(s);
    -- The age limit (effectiveMaxVehicleAge): at each place the type's own,
    -- or the largest of the other registered types covering it there.
    worst := null;
    for pl in select * from public.ptr_area_places(v_countries, v_states, v_cities) loop
      own := case when (t #>> '{age,required}')::boolean
                  then public.ptr_age_rule(t #> '{age,rules}', pl.country, pl.state, pl.city, pl.suburb) end;
      continue when own is null;
      at_place := jsonb_build_object('maxYears', (own ->> 'maxYears')::int, 'type', t ->> 'name');
      cover := null;
      foreach c in array v_types loop
        continue when public.ptr_key(c) = public.ptr_key(s);
        ct := public.partner_type_rules(c);
        continue when not (ct ->> 'vehicleRequired')::boolean;
        cover_rule := public.vsc_narrowest(public.vsc_type_values(c) -> 'ageLimitCovers',
                                           pl.country, pl.state, pl.city, pl.suburb);
        continue when cover_rule is null or not exists (
          select 1 from jsonb_array_elements_text(
                          case when jsonb_typeof(public.ptr_json(cover_rule -> 'types')) = 'array'
                               then public.ptr_json(cover_rule -> 'types') else '[]'::jsonb end) x
           where public.ptr_key(x) = public.ptr_key(s));
        lim := case when (ct #>> '{age,required}')::boolean
                    then public.ptr_age_rule(ct #> '{age,rules}', pl.country, pl.state, pl.city, pl.suburb) end;
        continue when lim is null;
        if cover is null or (lim ->> 'maxYears')::int > (cover ->> 'maxYears')::int then
          cover := jsonb_build_object('maxYears', (lim ->> 'maxYears')::int, 'type', ct ->> 'name');
        end if;
      end loop;
      if cover is not null then
        at_place := cover;
      end if;
      if worst is null or (at_place ->> 'maxYears')::int < (worst ->> 'maxYears')::int then
        worst := at_place;
      end if;
    end loop;

    -- The vehicle permit (vehiclePermitFor): the first place of the area
    -- needing one. The vehicle is registered for this type, so it applies.
    permit := null;
    preq := public.ptr_json(public.vsc_type_values(s) -> 'vehiclePermit');
    if jsonb_typeof(preq) = 'object' and public.ptr_bool(preq -> 'required', false) then
      for pl in select * from public.ptr_area_places(v_countries, v_states, v_cities) loop
        permit := public.vsc_narrowest(preq -> 'rules', pl.country, pl.state, pl.city, pl.suburb);
        exit when permit is not null;
      end loop;
    end if;
    v_key := nullif(btrim(coalesce(permit ->> 'permitType', '')), '');
    -- Uploaded and approved already: matched by the permit type's key (or
    -- id), any approved permit when the rule names none (as 0299).
    v_has := permit is not null and exists (
      select 1 from public.vehicle_documents d
        join public.permit_types pt on pt.id = d.permit_type_id
       where d.vehicle_id = p_vehicle
         and d.status = 'Approved'
         and (d.expiry_date is null or d.expiry_date >= current_date)
         and (v_key is null or pt.key = v_key or pt.id::text = v_key));

    v_over := worst is not null and v_age is not null and v_age > (worst ->> 'maxYears')::int;
    service := left(coalesce(nullif(btrim(t ->> 'name'), ''), btrim(s)), 80);
    status := case when v_over then 'paused_age'
                   when permit is not null and not v_has then 'waiting_permit'
                   else 'active' end;
    max_age_years := case when worst is null then null else least(greatest((worst ->> 'maxYears')::int, 0), 100) end;
    limit_type := left(worst ->> 'type', 80);
    permit_name := left(nullif(btrim(coalesce(permit ->> 'name', '')), ''), 120);
    permit_type := left(v_key, 60);
    return next;
  end loop;
end;
$$;
revoke execute on function public.vehicle_service_checks(uuid) from public, anon, authenticated;

-- Writes the checks for [p_vehicle] (see the header): the number of rows
-- the checks give. Rows an admin set are kept; a vehicle with no type is
-- left alone.
create or replace function public.vehicle_service_status_fill(p_vehicle uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
  n      integer;
begin
  if p_vehicle is null or not exists (select 1 from public.vehicle where id = p_vehicle) then
    return 0;
  end if;
  if not exists (
    select 1 from unnest(public.ptr_text_array(public.ptr_vehicle_context(p_vehicle) -> 'types')) x
     where btrim(coalesce(x, '')) <> '') then
    return 0;
  end if;
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into v_rows
    from public.vehicle_service_checks(p_vehicle) c;
  n := jsonb_array_length(v_rows);

  perform set_config('app.vehicle_service_fill', 'on', true);
  delete from public.vehicle_service_status s
   where s.vehicle_id = p_vehicle
     and not s.set_by_admin
     and not exists (select 1 from jsonb_to_recordset(v_rows) as c(service text) where c.service = s.service);
  insert into public.vehicle_service_status as s
    (vehicle_id, service, status, max_age_years, limit_type, permit_name, permit_type, set_by_admin)
  select p_vehicle, c.service, c.status, c.max_age_years, c.limit_type, c.permit_name, c.permit_type, false
    from jsonb_to_recordset(v_rows) as c(service text, status text, max_age_years integer, limit_type text,
                                          permit_name text, permit_type text)
   where not exists (select 1 from public.vehicle_service_status a
                      where a.vehicle_id = p_vehicle and a.set_by_admin
                        and public.ptr_key(a.service) = public.ptr_key(c.service))
  on conflict (vehicle_id, service) do update
     set status = excluded.status, max_age_years = excluded.max_age_years, limit_type = excluded.limit_type,
         permit_name = excluded.permit_name, permit_type = excluded.permit_type, set_by_admin = false
   where not s.set_by_admin;
  perform set_config('app.vehicle_service_fill', '', true);
  return n;
end;
$$;
revoke execute on function public.vehicle_service_status_fill(uuid) from public, anon, authenticated;

-- ---- 3. On submit ---------------------------------------------------------------------------------
create or replace function public.vehicle_service_checks_on_submit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (coalesce(old.documents_ok, false) = false and coalesce(new.documents_ok, false) = true)
     or (coalesce(new.documents_ok, false)
         and (new.partner_types is distinct from old.partner_types
              or new.year is distinct from old.year
              or new.registration_date is distinct from old.registration_date
              or new.service_countries is distinct from old.service_countries
              or new.service_states is distinct from old.service_states
              or new.service_cities is distinct from old.service_cities)) then
    -- The checks never hold a submission up: a failure is logged, and an
    -- admin can apply them again.
    begin
      perform public.vehicle_service_status_fill(new.id);
    exception when others then
      raise warning 'vehicle_service_status_fill(%): %', new.id, sqlerrm;
    end;
  end if;
  return null;
end;
$$;
revoke execute on function public.vehicle_service_checks_on_submit() from public, anon, authenticated;
drop trigger if exists trg_vehicle_service_checks on public.vehicle;
create trigger trg_vehicle_service_checks
  after update on public.vehicle
  for each row execute function public.vehicle_service_checks_on_submit();

-- ---- 4. Too old for a type: paused, not refused -------------------------------------------------------
-- 0245/0288 refused a vehicle added later (VEHICLE_TOO_OLD) when every type
-- failed its age limit. The checks above pause just the failing services.
create or replace function public.vehicle_partner_type_rules()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  -- Kept for older references; nothing is refused (0301).
  return new;
end;
$$;
revoke execute on function public.vehicle_partner_type_rules() from public, anon, authenticated;
drop trigger if exists trg_vehicle_b_partner_type_rules on public.vehicle;

-- ---- 5. The server has the last word -------------------------------------------------------------
-- Who writes a row: the server's checks (the fill, an approved permit, run
-- from a trigger) and database sessions as given; an admin who may write the
-- table marks it set_by_admin; anyone else (the owner's draft, 0288) never
-- does, and their write to an admin-set row is skipped, not refused, so the
-- registration wizard of older apps keeps working.
create or replace function public.vehicle_service_status_who()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(current_setting('app.vehicle_service_fill', true), '') = 'on' or pg_trigger_depth() > 1
     or coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if public.caller_is_admin() and public.caller_admin_can_write('vehicle_service_status') then
    if tg_op = 'DELETE' then
      return old;
    end if;
    new.set_by_admin := true;
    return new;
  end if;
  if tg_op = 'DELETE' then
    return case when old.set_by_admin then null else old end;
  end if;
  if tg_op = 'UPDATE' and old.set_by_admin then
    return old;
  end if;
  new.set_by_admin := false;
  return new;
end;
$$;
revoke execute on function public.vehicle_service_status_who() from public, anon, authenticated;
drop trigger if exists trg_vehicle_service_status_who on public.vehicle_service_status;
create trigger trg_vehicle_service_status_who
  before insert or update or delete on public.vehicle_service_status
  for each row execute function public.vehicle_service_status_who();

-- ---- 6. The admin's preview and apply --------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_vehicle_service_checks_preview', 'admin-vehicles'),
  ('rpc:admin_vehicle_service_checks_preview', 'admin-vehicle-edit'),
  ('rpc:admin_vehicle_service_checks_preview', 'admin-vehicle-permits'),
  ('rpc:admin_vehicle_service_checks_apply', 'admin-vehicles'),
  ('rpc:admin_vehicle_service_checks_apply', 'admin-vehicle-edit'),
  ('rpc:admin_vehicle_service_checks_apply', 'admin-vehicle-permits')
on conflict do nothing;

-- Per vehicle ([p_vehicle], else every submitted or approved one) and
-- service: the row today (current_*), what the checks say (checks_status)
-- and what applying would leave (would_*: an admin-set row stays, a vehicle
-- with no type keeps its rows, a service the vehicle no longer has goes:
-- null). changes: applying would change the row.
create or replace function public.admin_vehicle_service_checks_preview(p_vehicle uuid default null)
returns table (vehicle_id uuid, plate text, service text, current_status text, checks_status text,
               would_status text, max_age_years integer, limit_type text, permit_name text, permit_type text,
               set_by_admin boolean, changes boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.caller_admin_can_write('rpc:admin_vehicle_service_checks_preview') then
    raise exception 'Only admins who can edit vehicles can see the service checks.' using errcode = '42501';
  end if;
  return query
  with v as (
    select x.id, x.plate,
           exists (select 1 from unnest(public.ptr_text_array(public.ptr_vehicle_context(x.id) -> 'types')) t
                    where btrim(coalesce(t, '')) <> '') as has_types
      from public.vehicle x
     where (p_vehicle is null and (x.documents_ok or x.status::text = 'approved')) or x.id = p_vehicle
  ), k as (
    select v.id, c.* from v cross join lateral public.vehicle_service_checks(v.id) c
  ), cur as (
    select s.* from public.vehicle_service_status s join v on v.id = s.vehicle_id
  ), j as (
    select coalesce(cur.vehicle_id, k.id) as vid, coalesce(cur.service, k.service) as svc,
           cur.status as cur_status, k.status as chk_status, k.max_age_years as k_age, k.limit_type as k_limit,
           k.permit_name as k_pname, k.permit_type as k_ptype,
           cur.max_age_years as c_age, cur.limit_type as c_limit, cur.permit_name as c_pname,
           cur.permit_type as c_ptype, coalesce(cur.set_by_admin, false) as admin_set,
           cur.vehicle_id is not null as has_row, k.id is not null as has_check
      from cur full join k on k.id = cur.vehicle_id and k.service = cur.service
  )
  select j.vid, v.plate, j.svc, j.cur_status, j.chk_status,
         case when j.admin_set or not v.has_types then j.cur_status else j.chk_status end,
         case when j.admin_set or not v.has_types then j.c_age else j.k_age end,
         case when j.admin_set or not v.has_types then j.c_limit else j.k_limit end,
         case when j.admin_set or not v.has_types then j.c_pname else j.k_pname end,
         case when j.admin_set or not v.has_types then j.c_ptype else j.k_ptype end,
         j.admin_set,
         not (j.admin_set or not v.has_types)
           and (j.has_row is distinct from j.has_check
                or j.cur_status is distinct from j.chk_status
                or j.c_age is distinct from j.k_age
                or j.c_limit is distinct from j.k_limit
                or j.c_pname is distinct from j.k_pname
                or j.c_ptype is distinct from j.k_ptype)
    from j join v on v.id = j.vid
   order by v.plate, j.vid, j.svc;
end;
$$;
revoke execute on function public.admin_vehicle_service_checks_preview(uuid) from public, anon;
grant execute on function public.admin_vehicle_service_checks_preview(uuid) to authenticated;

-- Writes the checks for one vehicle (rows an admin set are kept): the
-- number of services checked. In admin_audit_log.
create or replace function public.admin_vehicle_service_checks_apply(p_vehicle uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  n       integer;
begin
  if not public.caller_admin_can_write('rpc:admin_vehicle_service_checks_apply') then
    raise exception 'Only admins who can edit vehicles can apply the service checks.' using errcode = '42501';
  end if;
  select coalesce(v.auth_user_id, p.auth_user_id) into v_owner
    from public.vehicle v left join public.partners p on p.id = v.owner_partner_id
   where v.id = p_vehicle;
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002', hint = 'This vehicle no longer exists.';
  end if;
  n := public.vehicle_service_status_fill(p_vehicle);
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'vehicle.service_checks_apply', v_owner,
          jsonb_build_object('vehicle_id', p_vehicle, 'services', n));
  return n;
end;
$$;
revoke execute on function public.admin_vehicle_service_checks_apply(uuid) from public, anon;
grant execute on function public.admin_vehicle_service_checks_apply(uuid) to authenticated;
