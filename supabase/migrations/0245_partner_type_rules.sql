-- ============================================================================
-- 0245: Partner type rules -- vehicle age, permit, street hail, availability
--
-- Admin -> Settings -> Partner Type gains four rules per type, kept with the
-- type in settings_entries.values.rules (category 'partner-type'):
--
--   {
--     "vehicleAge":   {"required": bool,
--                      "rules": [{"country","state","city","suburb","maxYears": int}]},
--     "permit":       {"required": bool, "all": bool, "regions": [scope]},
--     "hail":         {"allowed": bool,  "all": bool, "regions": [scope]},
--     "availability": {"all": bool, "regions": [scope]}
--   }
--
-- A scope is {"country","state","city","suburb"}: blank levels match any
-- place, so {} is "All regions" and {"country":"Malaysia","state":"Selangor"}
-- is Selangor and everything in it. Names are the Country / States / Cities
-- / Suburbs tables' names, compared without case or outer spaces.
--
-- Vehicle age, permit and hail only apply to a type with "Vehicle required"
-- on (the app's default for TEKSI, eHailing and pHailing when the entry says
-- nothing). Availability applies to every type.
--
-- Missing rules keep today's behaviour: no age limit, no extra permit
-- requirement, street hail for TEKSI only (as the meter is today), and every
-- type available everywhere.
--
-- Which place each check uses:
--   * vehicle age and permit: the registration region -- the vehicle's own
--     service area when it has one, else the owner partner's service area
--     from onboarding (service_countries / _states / _cities). Every place in
--     it is checked; the narrowest age rule matching a place decides there.
--   * availability and street hail: the driver's current location (the
--     point sent with presence, the ride's pickup for a bid), resolved to
--     country / state / city / suburb on the mapped region outlines (the
--     smallest outline holding the point, as regions_at / ride_point_gap).
--     With no point, or no outline holding it, the service area is used for
--     availability and hail is not refused.
--   * availability when picking types in onboarding: the service area (a
--     type is offered when it is available in at least one place of it).
--
-- Enforced here (the apps check first, to say why):
--   * vehicle: submitting it for review (documents_ok false -> true) or
--     changing its year is refused when it is too old for every
--     vehicle-required type of its owner (VEHICLE_TOO_OLD);
--   * claim_vehicle: refused when too old for every vehicle-required type of
--     the driver (vehicle_too_old);
--   * partners: submitting the application is refused without a permit
--     where one is required (PERMIT_REQUIRED); choosing a partner type, or a
--     service area, where the type is not available is refused
--     (PARTNER_TYPE_NOT_AVAILABLE);
--   * set_driver_presence: online only when at least one of the driver's
--     e-hailing types passes all four rules here;
--   * ride_requests: a driver bids on or takes a ride only when one of their
--     e-hailing types is available at its pickup (RIDE_TYPE_NOT_AVAILABLE);
--   * partner_type_check(lat, lng, teksi): the same verdict for the app,
--     with the reason and whether street hail is allowed here.
--
-- Writes to partner-type rows now need the Partner Type page's edit grant
-- (or a full admin / the Settings hub grant), not any settings page's.
-- ============================================================================

-- ---- Helpers -----------------------------------------------------------------------

-- A JSON flag as the admin app stores it: true / "true" / 1 / "yes".
create or replace function public.ptr_bool(p jsonb, p_default boolean)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select case
    when p is null or jsonb_typeof(p) = 'null' then p_default
    when jsonb_typeof(p) = 'boolean' then (p #>> '{}')::boolean
    when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric <> 0
    when jsonb_typeof(p) = 'string' then lower(btrim(p #>> '{}')) in ('true', '1', 'yes')
    else p_default
  end;
$$;

-- A partner-type name as the apps compare them: no case, spaces, _ or -.
create or replace function public.ptr_key(p text)
returns text
language sql
immutable
set search_path to ''
as $$
  select lower(regexp_replace(coalesce(p, ''), '[\s_-]+', '', 'g'));
$$;

-- A region name as compared: no case or outer spaces.
create or replace function public.ptr_name(p text)
returns text
language sql
immutable
set search_path to ''
as $$
  select lower(btrim(coalesce(p, '')));
$$;

-- A JSON value that may be stored as a JSON string (as the admin app does
-- for lists), parsed; null when it can't be.
create or replace function public.ptr_json(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path to ''
as $$
begin
  if p is null then
    return null;
  end if;
  if jsonb_typeof(p) = 'string' then
    begin
      return (p #>> '{}')::jsonb;
    exception when others then
      return null;
    end;
  end if;
  return p;
end;
$$;

-- Whether [p_scope] covers the place: each level the scope names matches.
create or replace function public.ptr_scope_matches(
  p_scope jsonb, p_country text, p_state text, p_city text, p_suburb text
)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select (public.ptr_name(p_scope ->> 'country') = '' or public.ptr_name(p_scope ->> 'country') = public.ptr_name(p_country))
     and (public.ptr_name(p_scope ->> 'state') = '' or public.ptr_name(p_scope ->> 'state') = public.ptr_name(p_state))
     and (public.ptr_name(p_scope ->> 'city') = '' or public.ptr_name(p_scope ->> 'city') = public.ptr_name(p_city))
     and (public.ptr_name(p_scope ->> 'suburb') = '' or public.ptr_name(p_scope ->> 'suburb') = public.ptr_name(p_suburb));
$$;

-- How narrow a scope is: the number of levels it names (0: All regions).
create or replace function public.ptr_scope_rank(p_scope jsonb)
returns int
language sql
immutable
set search_path to ''
as $$
  select (public.ptr_name(p_scope ->> 'country') <> '')::int + (public.ptr_name(p_scope ->> 'state') <> '')::int
       + (public.ptr_name(p_scope ->> 'city') <> '')::int + (public.ptr_name(p_scope ->> 'suburb') <> '')::int;
$$;

-- A scope as people say it: its narrowest name, or null for All regions.
create or replace function public.ptr_scope_label(p_scope jsonb)
returns text
language sql
immutable
set search_path to ''
as $$
  select coalesce(nullif(btrim(p_scope ->> 'suburb'), ''), nullif(btrim(p_scope ->> 'city'), ''),
                  nullif(btrim(p_scope ->> 'state'), ''), nullif(btrim(p_scope ->> 'country'), ''));
$$;

-- An {all, regions} list allows the place.
create or replace function public.ptr_list_allows(
  p_list jsonb, p_country text, p_state text, p_city text, p_suburb text
)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select public.ptr_bool(p_list -> 'all', true)
      or exists (
           select 1 from jsonb_array_elements(coalesce(public.ptr_json(p_list -> 'regions'), '[]'::jsonb)) r(s)
            where jsonb_typeof(r.s) = 'object'
              and public.ptr_scope_matches(r.s, p_country, p_state, p_city, p_suburb));
$$;

-- The places of a service area: each city, each state with none of its
-- cities listed, each country with none of its states listed; one blank
-- place when the area is empty (only "All regions" rules match it).
create or replace function public.ptr_area_places(p_countries text[], p_states text[], p_cities text[])
returns table (country text, state text, city text, suburb text)
language sql
immutable
set search_path to ''
as $$
  with c as (
    select split_part(x, '|', 1) country, split_part(x, '|', 2) state, split_part(x, '|', 3) city
      from unnest(coalesce(p_cities, '{}')) x where split_part(x, '|', 3) <> ''
  ), s as (
    select split_part(x, '|', 1) country, split_part(x, '|', 2) state
      from unnest(coalesce(p_states, '{}')) x where split_part(x, '|', 2) <> ''
  ), k as (
    select btrim(x) country from unnest(coalesce(p_countries, '{}')) x where btrim(x) <> ''
  ), places as (
    select c.country, c.state, c.city, '' suburb from c
    union
    select s.country, s.state, '', '' from s
     where not exists (select 1 from c where public.ptr_name(c.country) = public.ptr_name(s.country)
                                         and public.ptr_name(c.state) = public.ptr_name(s.state))
    union
    select k.country, '', '', '' from k
     where not exists (select 1 from s where public.ptr_name(s.country) = public.ptr_name(k.country))
       and not exists (select 1 from c where public.ptr_name(c.country) = public.ptr_name(k.country))
  )
  select * from places
  union all
  select '', '', '', '' where not exists (select 1 from places);
$$;

-- The place at a point: at each level the smallest mapped outline holding
-- it, inside the level above. Blank from the first level that can't be told
-- (no outline holds it); all blank without a point.
create or replace function public.ptr_point_place(p_lat double precision, p_lng double precision)
returns table (country text, state text, city text, suburb text)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  pt point;
  v_country text := '';
  v_state text := '';
  v_city text := '';
  v_suburb text := '';
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return query select '', '', '', '';
    return;
  end if;
  pt := point(p_lng, p_lat);
  select c.name into v_country from public.countries c
   where coalesce(cardinality(c.boundary_polys), 0) > 0
     and public.region_holding_area(c.boundary_polys, pt) is not null
   order by public.region_holding_area(c.boundary_polys, pt) limit 1;
  if coalesce(v_country, '') <> '' then
    select s.name into v_state from public.states s
     where public.ptr_name(s.country) = public.ptr_name(v_country)
       and coalesce(cardinality(s.boundary_polys), 0) > 0
       and public.region_holding_area(s.boundary_polys, pt) is not null
     order by public.region_holding_area(s.boundary_polys, pt) limit 1;
  end if;
  if coalesce(v_state, '') <> '' then
    select c.name into v_city from public.cities c
     where public.ptr_name(c.country) = public.ptr_name(v_country)
       and public.ptr_name(c.state) = public.ptr_name(v_state)
       and coalesce(cardinality(c.boundary_polys), 0) > 0
       and public.region_holding_area(c.boundary_polys, pt) is not null
     order by public.region_holding_area(c.boundary_polys, pt) limit 1;
  end if;
  if coalesce(v_city, '') <> '' then
    select b.name into v_suburb from public.suburbs b
     where public.ptr_name(b.country) = public.ptr_name(v_country)
       and public.ptr_name(b.state) = public.ptr_name(v_state)
       and public.ptr_name(b.city) = public.ptr_name(v_city)
       and coalesce(cardinality(b.boundary_polys), 0) > 0
       and public.region_holding_area(b.boundary_polys, pt) is not null
     order by public.region_holding_area(b.boundary_polys, pt) limit 1;
  end if;
  return query select coalesce(v_country, ''), coalesce(v_state, ''), coalesce(v_city, ''), coalesce(v_suburb, '');
end;
$$;

-- ---- A type's rules ---------------------------------------------------------------

-- The type's effective rules, with today's behaviour for anything unset:
-- {name, vehicleRequired, age:{required, rules}, permit:{required, all,
-- regions}, hail:{allowed, all, regions}, availability:{all, regions}}.
-- A name with no catalogue entry has no rules (available everywhere).
create or replace function public.partner_type_rules(p_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v jsonb;
  r jsonb;
  k text := public.ptr_key(p_name);
  v_vehicle boolean;
  v_teksi boolean := k = 'teksi';
begin
  select e.values into v from public.settings_entries e
   where e.category = 'partner-type' and public.ptr_key(e.values ->> 'name') = k
   order by e.active desc, e.position, e.created_at limit 1;
  v := coalesce(v, '{}'::jsonb);
  r := coalesce(public.ptr_json(v -> 'rules'), '{}'::jsonb);
  if jsonb_typeof(r) <> 'object' then
    r := '{}'::jsonb;
  end if;
  v_vehicle := case when v ? 'vehicleRequired' then public.ptr_bool(v -> 'vehicleRequired', false)
                    else k in ('teksi', 'ehailing', 'phailing') end;
  return jsonb_build_object(
    'name', coalesce(nullif(btrim(v ->> 'name'), ''), btrim(coalesce(p_name, ''))),
    'vehicleRequired', v_vehicle,
    'age', jsonb_build_object(
      'required', v_vehicle and public.ptr_bool(r #> '{vehicleAge,required}', false),
      'rules', coalesce(public.ptr_json(r #> '{vehicleAge,rules}'), '[]'::jsonb)),
    'permit', jsonb_build_object(
      'required', v_vehicle and public.ptr_bool(r #> '{permit,required}', false),
      'all', public.ptr_bool(r #> '{permit,all}', true),
      'regions', coalesce(public.ptr_json(r #> '{permit,regions}'), '[]'::jsonb)),
    'hail', jsonb_build_object(
      -- Unset: as today, the meter is TEKSI's.
      'allowed', case when v_vehicle then public.ptr_bool(r #> '{hail,allowed}', v_teksi) else v_teksi end,
      'all', case when v_vehicle then public.ptr_bool(r #> '{hail,all}', true) else true end,
      'regions', case when v_vehicle then coalesce(public.ptr_json(r #> '{hail,regions}'), '[]'::jsonb) else '[]'::jsonb end),
    'availability', jsonb_build_object(
      'all', public.ptr_bool(r #> '{availability,all}', true),
      'regions', coalesce(public.ptr_json(r #> '{availability,regions}'), '[]'::jsonb))
  );
end;
$$;

-- The narrowest age rule matching the place ({maxYears, scope}), the
-- lower limit on a tie; null when none applies.
create or replace function public.ptr_age_rule(
  p_rules jsonb, p_country text, p_state text, p_city text, p_suburb text
)
returns jsonb
language sql
immutable
set search_path to ''
as $$
  select jsonb_build_object('maxYears', (x.s ->> 'maxYears')::int, 'scope', x.s)
    from jsonb_array_elements(case when jsonb_typeof(p_rules) = 'array' then p_rules else '[]'::jsonb end) x(s)
   where jsonb_typeof(x.s) = 'object'
     and coalesce(x.s ->> 'maxYears', '') ~ '^\d{1,3}$'
     and public.ptr_scope_matches(x.s, p_country, p_state, p_city, p_suburb)
   order by public.ptr_scope_rank(x.s) desc, (x.s ->> 'maxYears')::int
   limit 1;
$$;

-- Why a vehicle of [p_year] can't be used for [p_type] in the area, or null.
-- [p_strict]: a missing year is a problem (registering); otherwise it is
-- let through (a vehicle already on the road).
create or replace function public.ptr_vehicle_age_problem(
  p_type text, p_year text, p_countries text[], p_states text[], p_cities text[], p_strict boolean default true
)
returns text
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  t jsonb := public.partner_type_rules(p_type);
  y int := nullif(substring(coalesce(p_year, '') from '(\d{4})'), '')::int;
  age int;
  pl record;
  rule jsonb;
  worst jsonb;
  label text;
begin
  if not (t #>> '{age,required}')::boolean then
    return null;
  end if;
  for pl in select * from public.ptr_area_places(p_countries, p_states, p_cities) loop
    rule := public.ptr_age_rule(t #> '{age,rules}', pl.country, pl.state, pl.city, pl.suburb);
    if rule is not null and (worst is null or (rule ->> 'maxYears')::int < (worst ->> 'maxYears')::int) then
      worst := rule;
    end if;
  end loop;
  if worst is null then
    return null;
  end if;
  label := public.ptr_scope_label(worst -> 'scope');
  if y is null then
    if not p_strict then
      return null;
    end if;
    return format('Enter the vehicle''s year: vehicles for %s%s must be at most %s years old.',
                  t ->> 'name', coalesce(' in ' || label, ''), worst ->> 'maxYears');
  end if;
  age := extract(year from current_date)::int - y;
  if age <= (worst ->> 'maxYears')::int then
    return null;
  end if;
  return format('Vehicles for %s%s must be at most %s years old (this one is %s).',
                t ->> 'name', coalesce(' in ' || label, ''), worst ->> 'maxYears', age);
end;
$$;

-- The region of the area where [p_type] needs a permit (its label, '' for
-- all regions), or null when it needs none there.
create or replace function public.ptr_permit_region(
  p_type text, p_countries text[], p_states text[], p_cities text[]
)
returns text
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  t jsonb := public.partner_type_rules(p_type);
  pl record;
  s jsonb;
begin
  if not (t #>> '{permit,required}')::boolean then
    return null;
  end if;
  if public.ptr_bool(t #> '{permit,all}', true) then
    return '';
  end if;
  for pl in select * from public.ptr_area_places(p_countries, p_states, p_cities) loop
    for s in select x from jsonb_array_elements(case when jsonb_typeof(t #> '{permit,regions}') = 'array'
                                                     then t #> '{permit,regions}' else '[]'::jsonb end) x loop
      if jsonb_typeof(s) = 'object' and public.ptr_scope_matches(s, pl.country, pl.state, pl.city, pl.suburb) then
        return coalesce(public.ptr_scope_label(s), '');
      end if;
    end loop;
  end loop;
  return null;
end;
$$;

-- Whether the partner holds a permit: an upload of a permit document
-- (Required Documents marked "taxi permit") that is not rejected or expired,
-- or a permit an administrator verified.
create or replace function public.ptr_partner_has_permit(p_partner_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
           select 1 from public.partners p
            where p.id = p_partner_id and p.permit::text = 'verified')
      or exists (
           select 1
             from public.provider_documents d
             join public.required_document r on r.id::text = d.doc_id
            where d.partner_id = p_partner_id
              and public.ptr_bool(r.values -> 'isTaxiPermit', false)
              and coalesce(d.status, '') <> 'Rejected'
              and (d.expiry_date is null or d.expiry_date >= current_date));
$$;

-- Whether [p_type] is offered at the place.
create or replace function public.ptr_type_available_at(
  p_type text, p_country text, p_state text, p_city text, p_suburb text
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select public.ptr_list_allows(public.partner_type_rules(p_type) -> 'availability', p_country, p_state, p_city, p_suburb);
$$;

-- Whether [p_type] is offered in at least one place of the area.
create or replace function public.ptr_type_available_in_area(
  p_type text, p_countries text[], p_states text[], p_cities text[]
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.ptr_area_places(p_countries, p_states, p_cities) pl
     where public.ptr_type_available_at(p_type, pl.country, pl.state, pl.city, pl.suburb));
$$;

-- The first of [p_types] that needs a vehicle and for which the vehicle is
-- fine, or else why it is refused: {ok, reason}. A list with no
-- vehicle-required type is always ok.
create or replace function public.ptr_vehicle_fits_types(
  p_types text[], p_year text, p_countries text[], p_states text[], p_cities text[], p_strict boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  t text;
  why text;
  first_why text;
  any_vehicle boolean := false;
begin
  foreach t in array coalesce(p_types, '{}') loop
    continue when btrim(coalesce(t, '')) = '';
    continue when not (public.partner_type_rules(t) ->> 'vehicleRequired')::boolean;
    any_vehicle := true;
    why := public.ptr_vehicle_age_problem(t, p_year, p_countries, p_states, p_cities, p_strict);
    if why is null then
      return jsonb_build_object('ok', true);
    end if;
    first_why := coalesce(first_why, why);
  end loop;
  if not any_vehicle then
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', false, 'reason', first_why);
end;
$$;

-- The registration region of a vehicle: its own service area, else its
-- owner partner's ({countries, states, cities}), with the owner's types.
create or replace function public.ptr_vehicle_context(p_vehicle_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'year', v.year,
    'countries', to_jsonb(case when coalesce(cardinality(v.service_countries), 0) > 0 then v.service_countries
                               else coalesce(o.service_countries, '{}') end),
    'states', to_jsonb(case when coalesce(cardinality(v.service_countries), 0) > 0 then coalesce(v.service_states, '{}')
                            else coalesce(o.service_states, '{}') end),
    'cities', to_jsonb(case when coalesce(cardinality(v.service_countries), 0) > 0 then coalesce(v.service_cities, '{}')
                            else coalesce(o.service_cities, '{}') end),
    'types', to_jsonb(case when coalesce(cardinality(v.partner_types), 0) > 0 then v.partner_types
                           else coalesce(o.partner_types, '{}') end))
    from public.vehicle v
    left join lateral (
      select p.* from public.partners p
       where p.id = v.owner_partner_id or (v.owner_partner_id is null and p.auth_user_id = v.auth_user_id)
       order by (p.id = v.owner_partner_id) desc nulls last limit 1
    ) o on true
   where v.id = p_vehicle_id;
$$;

create or replace function public.ptr_text_array(p jsonb)
returns text[]
language sql
immutable
set search_path to ''
as $$
  select coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end)), '{}');
$$;

-- ---- The driver's verdict --------------------------------------------------------------

-- Whether driver [p_uid] may work here: their e-hailing types ([p_teksi]
-- false) or TEKSI ([p_teksi] true) -- the partner's types of that kind,
-- else all of them, as the app's document check picks them -- each judged
-- on availability at the point (else the service area), permit in the
-- service area, and the age of the vehicle they have taken (its
-- registration region). ok when one type passes, or the partner has no
-- types. hail: whether one of the driver's types allows street hail here.
create or replace function public.ptr_driver_check(
  p_uid uuid, p_lat double precision, p_lng double precision, p_teksi boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  p public.partners%rowtype;
  pl record;
  here_known boolean;
  all_types text[];
  mode_types text[];
  t text;
  rules jsonb;
  v_ctx jsonb;
  why text;
  first_why text;
  ok boolean := false;
  hail boolean := false;
  out_types jsonb := '[]'::jsonb;
  avail boolean;
  age_why text;
  permit_where text;
  permit_ok boolean;
begin
  select * into p from public.partners where auth_user_id = p_uid order by created_at limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'partner', false, 'hail', null, 'types', '[]'::jsonb);
  end if;
  select * into pl from public.ptr_point_place(p_lat, p_lng);
  here_known := coalesce(pl.country, '') <> '';
  all_types := array(select btrim(x) from unnest(coalesce(p.partner_types, '{}')) x where btrim(coalesce(x, '')) <> '');
  mode_types := array(select x from unnest(all_types) x where (public.ptr_key(x) = 'teksi') = coalesce(p_teksi, false));
  if cardinality(mode_types) = 0 then
    mode_types := all_types;
  end if;

  -- The vehicle being driven, and its registration region.
  select public.ptr_vehicle_context(s.vehicle_id) into v_ctx
    from public.vehicle_active_session s where s.user_id = p_uid limit 1;

  foreach t in array all_types loop
    rules := public.partner_type_rules(t);
    avail := case when here_known
                  then public.ptr_list_allows(rules -> 'availability', pl.country, pl.state, pl.city, pl.suburb)
                  else public.ptr_type_available_in_area(t, p.service_countries, p.service_states, p.service_cities) end;
    -- Street hail: on, offered here, and (where the place can't be told)
    -- not refused for want of it.
    if avail and (rules #>> '{hail,allowed}')::boolean
       and (not here_known or public.ptr_list_allows(rules -> 'hail', pl.country, pl.state, pl.city, pl.suburb)) then
      hail := true;
    end if;
    continue when not (t = any(mode_types));

    why := null;
    if not avail then
      why := format('%s is not offered in %s.', rules ->> 'name',
                    case when here_known then coalesce(nullif(pl.suburb, ''), nullif(pl.city, ''), nullif(pl.state, ''), pl.country)
                         else 'your service area' end);
    end if;
    age_why := null;
    if why is null and v_ctx is not null and (rules ->> 'vehicleRequired')::boolean then
      age_why := public.ptr_vehicle_age_problem(t, v_ctx ->> 'year',
        public.ptr_text_array(v_ctx -> 'countries'), public.ptr_text_array(v_ctx -> 'states'),
        public.ptr_text_array(v_ctx -> 'cities'), false);
      why := age_why;
    end if;
    permit_where := public.ptr_permit_region(t, p.service_countries, p.service_states, p.service_cities);
    permit_ok := permit_where is null or public.ptr_partner_has_permit(p.id);
    if why is null and not permit_ok then
      why := format('A permit is required for %s%s. Upload it in your documents.',
                    rules ->> 'name', coalesce(' in ' || nullif(permit_where, ''), ''));
    end if;
    out_types := out_types || jsonb_build_object(
      'name', rules ->> 'name', 'available', avail, 'vehicleAgeProblem', age_why,
      'permitRequired', permit_where is not null, 'permitOk', permit_ok, 'reason', why);
    if why is null then
      ok := true;
    else
      first_why := coalesce(first_why, why);
    end if;
  end loop;

  if cardinality(mode_types) = 0 then
    ok := true;
  end if;
  return jsonb_build_object(
    'ok', ok, 'partner', true, 'reason', case when ok then null else first_why end, 'hail', hail,
    'place', jsonb_build_object('country', pl.country, 'state', pl.state, 'city', pl.city, 'suburb', pl.suburb),
    'types', out_types);
end;
$$;

-- The app's question: may I go online (or start the meter, [p_teksi]) here,
-- and is street hail offered here.
create or replace function public.partner_type_check(
  p_lat double precision default null,
  p_lng double precision default null,
  p_teksi boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.ptr_driver_check(auth.uid(), p_lat, p_lng, p_teksi);
end;
$$;

-- Whether one of the caller's e-hailing types is offered at the point
-- (true when they are no partner, or the point can't be placed).
create or replace function public.ptr_caller_available_at(p_lat double precision, p_lng double precision)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  p public.partners%rowtype;
  pl record;
  t text;
  types text[];
begin
  -- No rules set on any type: everywhere, as before (and nothing to look up).
  if not exists (select 1 from public.settings_entries e
                  where e.category = 'partner-type' and e.values ? 'rules') then
    return true;
  end if;
  select * into p from public.partners where auth_user_id = auth.uid() order by created_at limit 1;
  if not found then
    return true;
  end if;
  select * into pl from public.ptr_point_place(p_lat, p_lng);
  if coalesce(pl.country, '') = '' then
    return true;
  end if;
  types := array(select btrim(x) from unnest(coalesce(p.partner_types, '{}')) x
                  where btrim(coalesce(x, '')) <> '' and public.ptr_key(x) <> 'teksi');
  if cardinality(types) = 0 then
    types := array(select btrim(x) from unnest(coalesce(p.partner_types, '{}')) x where btrim(coalesce(x, '')) <> '');
  end if;
  if cardinality(types) = 0 then
    return true;
  end if;
  foreach t in array types loop
    if public.ptr_type_available_at(t, pl.country, pl.state, pl.city, pl.suburb) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;

-- Execute: the pure helpers are harmless; the ones reading partners,
-- vehicles and documents are the server's own (called from definer code).
revoke all on function public.ptr_point_place(double precision, double precision) from public, anon;
grant execute on function public.ptr_point_place(double precision, double precision) to authenticated, service_role;
revoke all on function public.partner_type_rules(text) from public, anon;
grant execute on function public.partner_type_rules(text) to authenticated, service_role;
revoke all on function public.ptr_vehicle_age_problem(text, text, text[], text[], text[], boolean) from public, anon, authenticated;
revoke all on function public.ptr_permit_region(text, text[], text[], text[]) from public, anon, authenticated;
revoke all on function public.ptr_partner_has_permit(uuid) from public, anon, authenticated;
revoke all on function public.ptr_type_available_at(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.ptr_type_available_in_area(text, text[], text[], text[]) from public, anon, authenticated;
revoke all on function public.ptr_vehicle_fits_types(text[], text, text[], text[], text[], boolean) from public, anon, authenticated;
revoke all on function public.ptr_vehicle_context(uuid) from public, anon, authenticated;
revoke all on function public.ptr_driver_check(uuid, double precision, double precision, boolean) from public, anon, authenticated;
revoke all on function public.partner_type_check(double precision, double precision, boolean) from public, anon;
grant execute on function public.partner_type_check(double precision, double precision, boolean) to authenticated;
revoke all on function public.ptr_caller_available_at(double precision, double precision) from public, anon;
grant execute on function public.ptr_caller_available_at(double precision, double precision) to authenticated;

-- ---- Vehicles: registering and submitting -------------------------------------------------
create or replace function public.vehicle_partner_type_rules()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  ctx jsonb;
  fit jsonb;
begin
  -- The owner's own writes from the apps; admins and the server decide freely.
  if coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') not in ('authenticated', 'anon')
     or public.caller_is_admin() then
    return new;
  end if;
  if not ((coalesce(old.documents_ok, false) = false and coalesce(new.documents_ok, false) = true)
          or (new.year is distinct from old.year and btrim(coalesce(new.year, '')) <> '')) then
    return new;
  end if;
  ctx := public.ptr_vehicle_context(new.id);
  fit := public.ptr_vehicle_fits_types(
    public.ptr_text_array(ctx -> 'types'), new.year,
    case when coalesce(cardinality(new.service_countries), 0) > 0 then new.service_countries
         else public.ptr_text_array(ctx -> 'countries') end,
    case when coalesce(cardinality(new.service_countries), 0) > 0 then new.service_states
         else public.ptr_text_array(ctx -> 'states') end,
    case when coalesce(cardinality(new.service_countries), 0) > 0 then new.service_cities
         else public.ptr_text_array(ctx -> 'cities') end,
    true);
  if not (fit ->> 'ok')::boolean then
    raise exception 'VEHICLE_TOO_OLD' using errcode = '42501', hint = fit ->> 'reason';
  end if;
  return new;
end;
$$;
revoke execute on function public.vehicle_partner_type_rules() from public, anon, authenticated;

drop trigger if exists trg_vehicle_b_partner_type_rules on public.vehicle;
create trigger trg_vehicle_b_partner_type_rules
  before update on public.vehicle
  for each row execute function public.vehicle_partner_type_rules();

-- ---- Partners: types, area and the application ----------------------------------------------
create or replace function public.partners_partner_type_rules()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  t text;
  where_ text;
  area_changed boolean;
begin
  if coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') not in ('authenticated', 'anon')
     or public.caller_is_admin() then
    return new;
  end if;

  -- A type is chosen only where it is offered (once an area is chosen).
  area_changed := tg_op = 'INSERT'
    or new.partner_types is distinct from old.partner_types
    or new.service_countries is distinct from old.service_countries
    or new.service_states is distinct from old.service_states
    or new.service_cities is distinct from old.service_cities;
  if area_changed and coalesce(cardinality(new.service_countries), 0) > 0 then
    foreach t in array coalesce(new.partner_types, '{}') loop
      continue when btrim(coalesce(t, '')) = '';
      if not public.ptr_type_available_in_area(t, new.service_countries, new.service_states, new.service_cities) then
        raise exception 'PARTNER_TYPE_NOT_AVAILABLE' using errcode = '42501',
          hint = format('%s is not offered in your service area.', public.partner_type_rules(t) ->> 'name');
      end if;
    end loop;
  end if;

  -- The applicant's Submit: a permit where one is required.
  if tg_op = 'UPDATE' and coalesce(old.documents_ok, false) = false and coalesce(new.documents_ok, false) = true then
    foreach t in array coalesce(new.partner_types, '{}') loop
      continue when btrim(coalesce(t, '')) = '';
      where_ := public.ptr_permit_region(t, new.service_countries, new.service_states, new.service_cities);
      if where_ is not null and not public.ptr_partner_has_permit(new.id) then
        raise exception 'PERMIT_REQUIRED' using errcode = '42501',
          hint = format('A permit is required for %s%s. Upload it before submitting.',
                        public.partner_type_rules(t) ->> 'name', coalesce(' in ' || nullif(where_, ''), ''));
      end if;
    end loop;
  end if;
  return new;
end;
$$;
revoke execute on function public.partners_partner_type_rules() from public, anon, authenticated;

drop trigger if exists trg_partners_b_partner_type_rules on public.partners;
create trigger trg_partners_b_partner_type_rules
  before insert or update on public.partners
  for each row execute function public.partners_partner_type_rules();

-- ---- Going online ----------------------------------------------------------------------------
-- As 0186, and online only when one of the driver's e-hailing types passes
-- the type rules where they are.
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
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  -- Only a driver has a presence.
  if not exists (select 1 from public.partners where auth_user_id = auth.uid()) then
    return;
  end if;
  v_online := coalesce(p_online, false) and public.caller_is_approved_partner();
  -- The partner type rules (0245): where it is offered, the permit, the
  -- vehicle's age. Without a fix this report, the last known position.
  -- Only once an admin has set rules on some type: until then, as before.
  if v_online and exists (select 1 from public.settings_entries e
                           where e.category = 'partner-type' and e.values ? 'rules') then
    v_online := coalesce((public.ptr_driver_check(
      auth.uid(),
      coalesce(v_lat, (select d.lat from public.driver_presence d where d.profile_id = auth.uid())),
      coalesce(v_lng, (select d.lng from public.driver_presence d where d.profile_id = auth.uid())),
      false) ->> 'ok')::boolean, true);
  end if;
  insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
  values (auth.uid(), v_online, v_lat, v_lng, now())
  on conflict (profile_id) do update
    set online = excluded.online,
        -- A report without a fix keeps the last known position.
        lat = coalesce(excluded.lat, driver_presence.lat),
        lng = coalesce(excluded.lng, driver_presence.lng),
        updated_at = now();
end;
$$;

revoke execute on function public.set_driver_presence(boolean, double precision, double precision) from public, anon;
grant execute on function public.set_driver_presence(boolean, double precision, double precision) to authenticated;

-- ---- Taking a vehicle ---------------------------------------------------------------------------
-- As 0186 / 0223 (an admin's call scoped to the page grant), and a vehicle
-- too old for every vehicle-required type of the driver (in its registration region) is not taken.
create or replace function public.claim_vehicle(
  p_vehicle_id uuid,
  p_user_id    uuid
) returns public.vehicle_active_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment public.vehicle_user_assignment%rowtype;
  v_session    public.vehicle_active_session%rowtype;
  v_partner_id uuid;
  v_is_owner   boolean := false;
  v_ctx        jsonb;
  v_fit        jsonb;
begin
  if p_user_id is distinct from auth.uid() and not public.caller_admin_can_write('rpc:claim_vehicle') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Active explicit assignment?
  select * into v_assignment
    from public.vehicle_user_assignment
   where vehicle_id = p_vehicle_id
     and user_id    = p_user_id
     and is_active  = true
   limit 1;

  if not found then
    -- Owner of the vehicle counts as an implicit active assignee.
    select true into v_is_owner
      from public.vehicle
     where id = p_vehicle_id
       and auth_user_id = p_user_id
     limit 1;

    -- No row leaves v_is_owner NULL, and `not NULL` is not true, so 0035's
    -- `if not v_is_owner` let every caller through.
    if not coalesce(v_is_owner, false) then
      raise exception 'not_assigned'
        using hint = 'User is not an active assignee or owner of this vehicle.';
    end if;
  end if;

  -- Only an approved vehicle is driven (the app offers no other; a direct
  -- call no longer gets round it).
  if not public.caller_admin_can_write('rpc:claim_vehicle') and not exists (
    select 1 from public.vehicle
     where id = p_vehicle_id and status::text in ('approved', 'permit-verified')
  ) then
    raise exception 'vehicle_not_approved'
      using hint = 'This vehicle is not approved to drive.';
  end if;

  -- The partner type's vehicle age limit (0245), for the driver's types.
  if not public.caller_admin_can_write('rpc:claim_vehicle') then
    v_ctx := public.ptr_vehicle_context(p_vehicle_id);
    v_fit := public.ptr_vehicle_fits_types(
      (select p.partner_types from public.partners p where p.auth_user_id = p_user_id order by p.created_at limit 1),
      v_ctx ->> 'year',
      public.ptr_text_array(v_ctx -> 'countries'), public.ptr_text_array(v_ctx -> 'states'),
      public.ptr_text_array(v_ctx -> 'cities'), false);
    if not coalesce((v_fit ->> 'ok')::boolean, true) then
      raise exception 'vehicle_too_old' using hint = v_fit ->> 'reason';
    end if;
  end if;

  -- Vehicle already in use?
  select * into v_session
    from public.vehicle_active_session
   where vehicle_id = p_vehicle_id
   limit 1;

  if found then
    if v_session.user_id = p_user_id then
      update public.vehicle_active_session
         set last_seen_at = now(),
             status       = 'online'
       where id = v_session.id
      returning * into v_session;
      return v_session;
    end if;
    raise exception 'vehicle_in_use'
      using hint = 'Vehicle is currently used by another user.';
  end if;

  -- User already driving something else?
  if exists (
    select 1 from public.vehicle_active_session where user_id = p_user_id
  ) then
    raise exception 'user_busy'
      using hint = 'User is already in an active session on another vehicle.';
  end if;

  v_partner_id := v_assignment.partner_id;

  insert into public.vehicle_active_session (vehicle_id, user_id, partner_id)
       values (p_vehicle_id, p_user_id, v_partner_id)
    returning * into v_session;

  return v_session;
end;
$$;

revoke execute on function public.claim_vehicle(uuid, uuid) from public, anon;
grant execute on function public.claim_vehicle(uuid, uuid) to authenticated;

-- ---- Bidding on and taking a ride ------------------------------------------------------------
-- As 0223, and a driver bids on or takes a ride only where one of their
-- e-hailing types is offered (at its pickup).
create or replace function public.ride_requests_guard_partner_claim()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.partner_id is not null or new.offered_fare is not null then
      raise exception 'RIDE_PARTNER_SERVER_ONLY' using errcode = '42501',
        hint = 'A new request is offered to drivers; it can''t name one.';
    end if;
    return new;
  end if;
  if new.partner_id is null and old.partner_id is not null and old.status is distinct from 'open' then
    raise exception 'RIDE_DRIVER_KEPT' using errcode = '42501',
      hint = 'A ride that was taken keeps its driver; cancel it instead.';
  end if;
  if new.partner_id is not null and new.partner_id is distinct from old.partner_id then
    if new.partner_id is distinct from auth.uid() then
      raise exception 'RIDE_CLAIM_SELF_ONLY' using errcode = '42501',
        hint = 'A driver takes or bids on a ride for themselves only.';
    end if;
    if not public.caller_is_approved_partner() then
      raise exception 'RIDE_CLAIM_REQUIRES_APPROVED_PARTNER' using errcode = '42501',
        hint = 'Only partners approved by an administrator can accept or bid on rides.';
    end if;
    if new.partner_id = coalesce(new.rider_id, old.rider_id) then
      raise exception 'RIDE_CLAIM_OWN_RIDE' using errcode = '42501',
        hint = 'You can''t take a ride you booked.';
    end if;
    if not public.ptr_caller_available_at(new.pickup_lat, new.pickup_lng) then
      raise exception 'RIDE_TYPE_NOT_AVAILABLE' using errcode = '42501',
        hint = 'Your partner type is not offered where this ride starts.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_partner_claim() from public, anon, authenticated;

-- ---- Who writes partner types ------------------------------------------------------------------
-- The Partner Type page's EDIT grant (or the Settings hub's, or a full
-- admin), on top of settings_entries' own write rules.
create or replace function public.caller_admin_can_edit_page(p_page text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (migrations, psql, cron)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  v_uid := auth.uid();
  if v_uid is null then
    return false;
  end if;
  return exists (
    select 1 from public.admin_access a
     where a.profile_id = v_uid
       and a.access_level = 'edit'
       and (a.page = '*' or a.page = p_page or (a.page = 'admin-settings' and p_page like 'admin-settings-%')));
end;
$$;
revoke execute on function public.caller_admin_can_edit_page(text) from public;
grant execute on function public.caller_admin_can_edit_page(text) to anon, authenticated, service_role;

drop policy if exists "settings_entries partner-type insert" on public.settings_entries;
create policy "settings_entries partner-type insert" on public.settings_entries
  as restrictive for insert to public
  with check (category is distinct from 'partner-type'
              or (select public.caller_admin_can_edit_page('admin-settings-partner-type')));
drop policy if exists "settings_entries partner-type update" on public.settings_entries;
create policy "settings_entries partner-type update" on public.settings_entries
  as restrictive for update to public
  using (category is distinct from 'partner-type'
         or (select public.caller_admin_can_edit_page('admin-settings-partner-type')))
  with check (category is distinct from 'partner-type'
              or (select public.caller_admin_can_edit_page('admin-settings-partner-type')));
drop policy if exists "settings_entries partner-type delete" on public.settings_entries;
create policy "settings_entries partner-type delete" on public.settings_entries
  as restrictive for delete to public
  using (category is distinct from 'partner-type'
         or (select public.caller_admin_can_edit_page('admin-settings-partner-type')));

notify pgrst, 'reload schema';
