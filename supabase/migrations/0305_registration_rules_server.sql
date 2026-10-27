-- ============================================================================
-- 0305 — Partner registration rules checked by the server (docs/KIV.md M6).
--
-- Version 20261027220000 (0305_registration_rules_server). Re-runnable: the
-- table "if not exists", functions "create or replace" (the approval's old
-- one-argument form dropped first), triggers and policies dropped first,
-- seed rows "on conflict do nothing". No partner is changed when it runs:
-- the rules apply to the next submission or approval.
--
-- Each Partner Service type keeps its "Partner registration" settings as
-- top-level keys of its settings entry (partner_type_rules.dart,
-- PartnerServiceSettings). Before this only the driver app applied three of
-- them, so an old or modified app could skip them:
--
-- 1. reg_rule_checks(partner row): for each of the partner's types, in the
--    partner's service area (ptr_area_places), the same rules the app checks:
--    * citizensOnly: where it holds, the partner's ID must be a citizen ID of
--      that country (reg_citizen_of: a MyKad for Malaysia, else a passport
--      of that nationality; a MyPR never is) -> CITIZENS_ONLY;
--    * businessRegistration: the company number and the registration
--      document (partners.company_reg_no, company_document_url, 0288)
--      -> BUSINESS_REGISTRATION_REQUIRED;
--    * driverPermit: the permit the first place of the area names. It counts
--      when an admin verified the permit, a permit document (Required
--      Documents marked "taxi permit") is uploaded, not rejected and in date,
--      or the Kad Pemandu of the Driver permit step is read with its expiry
--      date, in date (an expired permit counts as missing)
--      -> DRIVER_PERMIT_REQUIRED. The old rules.permit (0245) still counts,
--      as before (an expiry date not needed), under the same code;
--    * vehiclePermit and ageLimitCovers: never a refusal. 0301's
--      vehicle_service_checks already pause just that service of the vehicle
--      on submit (waiting_permit, paused_age), with the covering limit; the
--      checks only report those rows. vehiclePermitAlsoFor needs nothing
--      more: a vehicle is checked for the services it is registered for, so
--      the app's "also for" test (the vehicle is registered for the service
--      itself) always holds there, on both sides.
--    Each row {rule, label, status (failed / passed / paused), type, place,
--    message, ...}. partner_registration_checks(partner) gives them all and
--    partner_registration_problems(partner) the failed ones, to the partner
--    and to admins.
-- 2. The partner's Submit (documents_ok false -> true), "Send for review
--    again" (changes-needed -> unapproved) and a change of types or service
--    area of a submitted application are refused with the first problem's
--    code, its words in the hint and every problem as JSON in the detail.
--    Admins' own edits, the server and sessions without claims are not held
--    (as 0245's rules). 0245's PERMIT_REQUIRED on submit is part of these
--    checks now.
-- 3. partner_review_approve(partner, override_reason default null): the
--    rules are checked again; failing ones refuse the approval
--    (PARTNER_RULES_NOT_MET, the problems in the detail) unless the admin
--    gives a reason. The override (failed rules, reason, admin, when) is
--    kept in partner_rule_overrides, read by admins ("Approved with
--    override" on the review), and in admin_audit_log.
-- 4. admin_partner_rule_failures(type): the partners of that type, submitted
--    or approved, that would fail its rules today, for the Partner Service
--    type page's "Partners affected now". Admins with EDIT on the Partner
--    Service type or Partners pages (caller_admin_can_write).
-- ============================================================================

-- ---- The overrides -----------------------------------------------------------------------------------
create table if not exists public.partner_rule_overrides (
  id         uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners (id) on delete cascade,
  rules      jsonb not null default '[]'::jsonb check (jsonb_typeof(rules) = 'array'),
  reason     text not null check (char_length(btrim(reason)) between 1 and 500),
  admin_id   uuid references public.profiles (id) on delete set null,
  at         timestamptz not null default now()
);
comment on table public.partner_rule_overrides is
  'An approval past failed partner registration rules (0305): the failed rules, the admin''s reason, who and when. Written only by partner_review_approve.';
create index if not exists partner_rule_overrides_partner_idx on public.partner_rule_overrides (partner_id, at desc);

alter table public.partner_rule_overrides enable row level security;
revoke all on public.partner_rule_overrides from public, anon, authenticated;
grant select on public.partner_rule_overrides to authenticated;
grant all on public.partner_rule_overrides to service_role;

drop policy if exists partner_rule_overrides_read on public.partner_rule_overrides;
create policy partner_rule_overrides_read on public.partner_rule_overrides
  for select to authenticated using ((select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_partner_rule_failures', 'admin-settings-partner-type'),
  ('rpc:admin_partner_rule_failures', 'admin-partners'),
  ('rpc:admin_partner_rule_failures', 'admin-partner-edit')
on conflict do nothing;

-- ---- 1. The checks -----------------------------------------------------------------------------------
-- Whether an ID of [p_id_type] with [p_nationality] (as typed or read off
-- the ID: "Malaysian", "Warganegara", "Malaysia") is a citizen ID of
-- [p_country] (blank: Malaysia, the app's default country). A MyKad is
-- Malaysia's, unless the nationality says otherwise; a MyPR never is; a
-- passport, or no ID type, by its nationality.
create or replace function public.reg_citizen_of(p_id_type text, p_nationality text, p_country text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  n    text := lower(btrim(coalesce(p_nationality, '')));
  c    text := lower(btrim(coalesce(nullif(btrim(p_country), ''), 'Malaysia')));
  v_my boolean;
  v_ok boolean;
begin
  v_my := c in ('malaysia', 'my', 'mys');
  v_ok := n <> '' and (
    n = c
    or (char_length(c) >= 4 and left(n, char_length(c) - 1) = left(c, char_length(c) - 1))
    or (v_my and n in ('malaysian', 'mys', 'my', 'warganegara', 'warganegara malaysia')));
  return case lower(btrim(coalesce(p_id_type, '')))
    when 'mypr' then false
    when 'mykad' then v_my and (n = '' or v_ok)
    else v_ok
  end;
end;
$$;

-- Where in the area a {required, all, regions} setting holds: the matching
-- region's narrowest name, or the first place's country for "All regions";
-- null when it holds nowhere there (RegionRequirement.regionIn).
create or replace function public.reg_region_in(
  p_req jsonb, p_countries text[], p_states text[], p_cities text[]
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  pl record;
  s  jsonb;
begin
  if jsonb_typeof(p_req) is distinct from 'object' or not public.ptr_bool(p_req -> 'required', false) then
    return null;
  end if;
  for pl in select * from public.ptr_area_places(p_countries, p_states, p_cities) loop
    if public.ptr_bool(p_req -> 'all', true) then
      return pl.country;
    end if;
    for s in select x from jsonb_array_elements(case when jsonb_typeof(public.ptr_json(p_req -> 'regions')) = 'array'
                                                     then public.ptr_json(p_req -> 'regions') else '[]'::jsonb end) x loop
      if jsonb_typeof(s) = 'object' and public.ptr_scope_matches(s, pl.country, pl.state, pl.city, pl.suburb) then
        return coalesce(public.ptr_scope_label(s), pl.country);
      end if;
    end loop;
  end loop;
  return null;
end;
$$;

-- How the partner (a partners row as JSON, so a trigger can pass the new
-- one) stands with a driver permit: 'ok', 'missing', 'expired' (the Kad
-- Pemandu's expiry date has passed) or 'no_expiry' (read without one). An
-- admin-verified permit or a permit document in date counts too.
create or replace function public.reg_driver_permit_state(p_row jsonb)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_until date;
begin
  if p_row ->> 'permit' = 'verified' then
    return 'ok';
  end if;
  if exists (
    select 1
      from public.provider_documents d
      join public.required_document r on r.id::text = d.doc_id
     where d.partner_id = (p_row ->> 'id')::uuid
       and public.ptr_bool(r.values -> 'isTaxiPermit', false)
       and coalesce(d.status, '') <> 'Rejected'
       and (d.expiry_date is null or d.expiry_date >= current_date)) then
    return 'ok';
  end if;
  if nullif(btrim(coalesce(p_row ->> 'driver_permit_card_no', '')), '') is null
     or nullif(btrim(coalesce(p_row ->> 'driver_permit_front_url', '')), '') is null then
    return 'missing';
  end if;
  v_until := nullif(p_row ->> 'driver_permit_valid_until', '')::date;
  return case when v_until is null then 'no_expiry'
              when v_until < current_date then 'expired'
              else 'ok' end;
end;
$$;
revoke execute on function public.reg_driver_permit_state(jsonb) from public, anon, authenticated;

-- Every rule of the partner's types for the partner [p_row] (a partners row
-- as JSON): see the header.
create or replace function public.reg_rule_checks(p_row jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_countries text[] := public.ptr_text_array(p_row -> 'service_countries');
  v_states    text[] := public.ptr_text_array(p_row -> 'service_states');
  v_cities    text[] := public.ptr_text_array(p_row -> 'service_cities');
  v_vehicle   uuid := nullif(p_row ->> 'registration_vehicle_id', '')::uuid;
  v_id_type   text;
  v_nation    text;
  v_ic        text;
  v_permit    text := public.reg_driver_permit_state(p_row);
  v_until     date := nullif(p_row ->> 'driver_permit_valid_until', '')::date;
  v_first     text;
  out         jsonb := '[]'::jsonb;
  t           text;
  v_name      text;
  v          jsonb;
  req         jsonb;
  rule        jsonb;
  pl          record;
  st          record;
  v_place     text;
  v_fail      text;
  v_any       boolean;
  v_missing   text[];
  v_pname     text;
  v_old       text;
begin
  select pr.id_type, pr.nationality, pr.ic into v_id_type, v_nation, v_ic
    from public.profiles pr where pr.id = nullif(p_row ->> 'auth_user_id', '')::uuid;
  select pl2.country into v_first from public.ptr_area_places(v_countries, v_states, v_cities) pl2 limit 1;
  v_first := coalesce(nullif(btrim(v_first), ''), 'your area');

  for t in
    select q.x from (
      select distinct on (public.ptr_key(u.x)) u.x, u.n
        from unnest(public.ptr_text_array(p_row -> 'partner_types')) with ordinality u(x, n)
       where btrim(coalesce(u.x, '')) <> ''
       order by public.ptr_key(u.x), u.n) q
     order by q.n
  loop
    v_name := public.partner_type_rules(t) ->> 'name';
    v := public.vsc_type_values(t);

    -- Citizens only.
    req := public.ptr_json(v -> 'citizensOnly');
    if jsonb_typeof(req) = 'object' and public.ptr_bool(req -> 'required', false) then
      v_fail := null;
      v_any := false;
      for pl in select * from public.ptr_area_places(v_countries, v_states, v_cities) loop
        continue when not public.ptr_list_allows(req, pl.country, pl.state, pl.city, pl.suburb);
        if not v_any then
          v_place := coalesce(nullif(btrim(pl.country), ''), 'Malaysia');
        end if;
        v_any := true;
        if not public.reg_citizen_of(v_id_type, v_nation, pl.country) then
          v_fail := coalesce(nullif(btrim(pl.country), ''), 'Malaysia');
          exit;
        end if;
      end loop;
      if v_any then
        out := out || jsonb_build_object(
          'rule', 'citizens_only', 'label', 'Citizens only', 'type', v_name,
          'place', coalesce(v_fail, v_place),
          'status', case when v_fail is null then 'passed' else 'failed' end,
          'id_type', v_id_type, 'id_number', v_ic,
          'message', case when v_fail is null
            then format('%s: citizen ID', v_name)
            else format('%s in %s is for citizens only. %s Choose another Partner Service type, or sign up with a citizen ID.',
                        v_name, v_fail,
                        case lower(coalesce(v_id_type, ''))
                          when 'passport' then 'Your ID is a passport.'
                          when 'mypr' then 'Your ID is a MyPR (permanent resident).'
                          when 'mykad' then 'Your ID shows you are not a citizen there.'
                          else 'Add your National ID first.'
                        end)
          end);
      end if;
    end if;

    -- Business registration.
    v_place := public.reg_region_in(public.ptr_json(v -> 'businessRegistration'), v_countries, v_states, v_cities);
    if v_place is not null then
      v_place := coalesce(nullif(btrim(v_place), ''), v_first);
      v_missing := array_remove(array[
        case when nullif(btrim(coalesce(p_row ->> 'company_reg_no', '')), '') is null then 'company number' end,
        case when nullif(btrim(coalesce(p_row ->> 'company_document_url', '')), '') is null
             then 'registration document' end], null);
      out := out || jsonb_build_object(
        'rule', 'business_registration', 'label', 'Business registration', 'type', v_name, 'place', v_place,
        'status', case when cardinality(v_missing) = 0 then 'passed' else 'failed' end,
        'missing', to_jsonb(v_missing),
        'message', case when cardinality(v_missing) = 0
          then format('%s: company number and document', v_name)
          else format('%s in %s needs a company number and the registration document. Add them, then submit again.',
                      v_name, v_place)
        end);
    end if;

    -- Driver permit: the new setting, else the old rules.permit (0245).
    rule := null;
    req := public.ptr_json(v -> 'driverPermit');
    if jsonb_typeof(req) = 'object' and public.ptr_bool(req -> 'required', false) then
      for pl in select * from public.ptr_area_places(v_countries, v_states, v_cities) loop
        rule := public.vsc_narrowest(req -> 'rules', pl.country, pl.state, pl.city, pl.suburb);
        if rule is not null then
          v_place := coalesce(public.ptr_scope_label(rule), nullif(btrim(pl.country), ''), v_first);
          exit;
        end if;
      end loop;
    end if;
    if rule is not null then
      v_pname := coalesce(nullif(btrim(rule ->> 'name'), ''), 'driver permit');
      out := out || jsonb_build_object(
        'rule', 'driver_permit', 'label', 'Driver permit', 'type', v_name, 'place', v_place,
        'permit', v_pname, 'issuer', nullif(btrim(coalesce(rule ->> 'issuer', '')), ''), 'state', v_permit,
        'valid_until', v_until,
        'status', case when v_permit = 'ok' then 'passed' else 'failed' end,
        'message', case v_permit
          when 'ok' then format('%s: %s uploaded', v_name, v_pname)
          when 'expired' then format('Your %s expired on %s: an expired permit counts as missing. Upload the new one, then submit again.',
                                     v_pname, to_char(v_until, 'FMDD Mon YYYY'))
          when 'no_expiry' then format('Type the expiry date of your %s, then submit again.', v_pname)
          else format('%s in %s needs a %s. Upload a photo of the front, with the expiry date showing, then submit again.',
                      v_name, v_place, v_pname)
        end);
    else
      v_old := public.ptr_permit_region(t, v_countries, v_states, v_cities);
      if v_old is not null then
        out := out || jsonb_build_object(
          'rule', 'driver_permit', 'label', 'Driver permit', 'type', v_name,
          'place', coalesce(nullif(v_old, ''), v_first), 'permit', 'permit', 'state', v_permit,
          'status', case when v_permit in ('ok', 'no_expiry') then 'passed' else 'failed' end,
          'message', case when v_permit in ('ok', 'no_expiry')
            then format('%s: permit uploaded', v_name)
            else format('A permit is required for %s%s. Upload it before submitting.',
                        v_name, coalesce(' in ' || nullif(v_old, ''), ''))
          end);
      end if;
    end if;

    -- The vehicle's services (0301's per-service checks): reported, never refused.
    if v_vehicle is not null then
      for st in
        select s.* from public.vehicle_service_status s
         where s.vehicle_id = v_vehicle and public.ptr_key(s.service) = public.ptr_key(v_name)
      loop
        if st.status = 'waiting_permit' or st.permit_name is not null then
          out := out || jsonb_build_object(
            'rule', 'vehicle_permit', 'label', 'Vehicle permit', 'type', v_name, 'place', v_first,
            'permit', st.permit_name,
            'status', case when st.status = 'waiting_permit' then 'paused' else 'passed' end,
            'message', case when st.status = 'waiting_permit'
              then format('%s is paused (waiting for permit) until the %s is uploaded.',
                          v_name, coalesce(st.permit_name, 'vehicle permit'))
              else format('%s: %s uploaded', v_name, coalesce(st.permit_name, 'vehicle permit'))
            end);
        end if;
        if st.status = 'paused_age' or st.max_age_years is not null then
          out := out || jsonb_build_object(
            'rule', 'vehicle_age', 'label', 'Age-limit covers', 'type', v_name, 'place', v_first,
            'max_age_years', st.max_age_years, 'limit_type', st.limit_type,
            'status', case when st.status = 'paused_age' then 'paused' else 'passed' end,
            'message', case when st.status = 'paused_age'
              then format('%s is paused: the vehicle is over the %s-year limit.', v_name, st.max_age_years)
              else format('%s: within %s years%s', v_name, st.max_age_years,
                          case when st.limit_type is not null and public.ptr_key(st.limit_type) <> public.ptr_key(v_name)
                               then format(' (%s covers %s)', st.limit_type, v_name) else '' end)
            end);
        end if;
      end loop;
    end if;
  end loop;
  return out;
end;
$$;
revoke execute on function public.reg_rule_checks(jsonb) from public, anon, authenticated;

-- The failed rows of [p_checks], as {rule, label, type, place, message, ...}.
create or replace function public.reg_rule_failures(p_checks jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x.c order by x.n), '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_checks, '[]'::jsonb)) with ordinality x(c, n)
   where x.c ->> 'status' = 'failed';
$$;

-- The code a failed rule refuses with.
create or replace function public.reg_rule_code(p_rule text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_rule
    when 'citizens_only' then 'CITIZENS_ONLY'
    when 'business_registration' then 'BUSINESS_REGISTRATION_REQUIRED'
    when 'driver_permit' then 'DRIVER_PERMIT_REQUIRED'
    else 'PARTNER_RULES_NOT_MET'
  end;
$$;

-- Every rule for partner [p_partner]: the partner themselves and admins.
create or replace function public.partner_registration_checks(p_partner uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p public.partners%rowtype;
begin
  select * into p from public.partners where id = p_partner;
  if not found then
    return '[]'::jsonb;
  end if;
  if coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') <> ''
     and p.auth_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'Only the partner and admins can see these checks.' using errcode = '42501';
  end if;
  return public.reg_rule_checks(to_jsonb(p));
end;
$$;
revoke execute on function public.partner_registration_checks(uuid) from public, anon;
grant execute on function public.partner_registration_checks(uuid) to authenticated;

-- The rules partner [p_partner] fails today: [{rule, label, type, place, message, ...}].
create or replace function public.partner_registration_problems(p_partner uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.reg_rule_failures(public.partner_registration_checks(p_partner));
$$;
revoke execute on function public.partner_registration_problems(uuid) from public, anon;
grant execute on function public.partner_registration_problems(uuid) to authenticated;

-- ---- 2. On submit -------------------------------------------------------------------------------------
-- 0245's rules without the permit on submit, which the checks below do now.
create or replace function public.partners_partner_type_rules()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  t text;
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
  return new;
end;
$$;
revoke execute on function public.partners_partner_type_rules() from public, anon, authenticated;

create or replace function public.partners_registration_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problems jsonb;
  v_first    jsonb;
begin
  if coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') not in ('authenticated', 'anon')
     or public.caller_is_admin() then
    return new;
  end if;
  if not (
    -- Submit.
    (coalesce(old.documents_ok, false) = false and coalesce(new.documents_ok, false) = true)
    -- "Send for review again" (0289).
    or (old.status::text = 'changes-needed' and new.status::text in ('unapproved', 'unapproved-docs'))
    -- A submitted application's types or area.
    or (coalesce(old.documents_ok, false) and coalesce(new.documents_ok, false)
        and new.status::text in ('unapproved', 'unapproved-docs')
        and (new.partner_types is distinct from old.partner_types
             or new.service_countries is distinct from old.service_countries
             or new.service_states is distinct from old.service_states
             or new.service_cities is distinct from old.service_cities))
  ) then
    return new;
  end if;
  v_problems := public.reg_rule_failures(public.reg_rule_checks(to_jsonb(new)));
  if jsonb_array_length(v_problems) > 0 then
    v_first := v_problems -> 0;
    raise exception '%', public.reg_rule_code(v_first ->> 'rule') using errcode = '42501',
      hint = v_first ->> 'message', detail = v_problems::text;
  end if;
  return new;
end;
$$;
revoke execute on function public.partners_registration_rules() from public, anon, authenticated;

-- "c_": after the types lock (a_, 0299) and the type rules (b_, 0245).
drop trigger if exists trg_partners_c_registration_rules on public.partners;
create trigger trg_partners_c_registration_rules
  before update on public.partners
  for each row execute function public.partners_registration_rules();

-- ---- 3. On approval -----------------------------------------------------------------------------------
-- As 0289, with the rules checked again; [p_override_reason] approves past
-- the failed ones, recorded.
drop function if exists public.partner_review_approve(uuid);
create or replace function public.partner_review_approve(p_partner uuid, p_override_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  p          public.partners%rowtype;
  v_vehicle  boolean := false;
  v_reason   text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_problems jsonb;
  v_override uuid;
begin
  if not public.caller_admin_can_write('rpc:partner_review_approve') then
    raise exception 'Only admins who can edit partners can approve an application.' using errcode = '42501';
  end if;
  select * into p from public.partners where id = p_partner for update;
  if not found then
    raise exception 'PARTNER_NOT_FOUND' using errcode = 'P0002', hint = 'This partner no longer exists.';
  end if;
  if p.status::text = 'blocked' then
    raise exception 'REVIEW_CLOSED' using errcode = '22023', hint = 'This partner is blocked. Unblock them first.';
  end if;
  if p.status::text = 'changes-needed' then
    raise exception 'REVIEW_WITH_DRIVER' using errcode = '22023',
      hint = 'The application is with the driver. You can review it again once they send it back.';
  end if;
  if exists (select 1 from public.partner_review_items where partner_id = p_partner and state = 'rejected') then
    raise exception 'REVIEW_REJECTED_LINES' using errcode = '22023',
      hint = 'Some lines are rejected. Send the application back to the driver, or approve those lines first.';
  end if;

  -- The partner registration rules, checked again (0305).
  v_problems := public.reg_rule_failures(public.reg_rule_checks(to_jsonb(p)));
  if jsonb_array_length(v_problems) > 0 then
    if v_reason is null then
      raise exception 'PARTNER_RULES_NOT_MET' using errcode = '22023',
        hint = format('Can''t approve: %s. Ask the partner for the documents, or approve anyway with a reason.',
                      (select string_agg(format('%s missing (%s needs it in %s)', x ->> 'label', x ->> 'type', x ->> 'place'),
                                         '; ' order by n)
                         from jsonb_array_elements(v_problems) with ordinality e(x, n))),
        detail = v_problems::text;
    end if;
    if char_length(v_reason) > 500 then
      raise exception 'REVIEW_NOTE_TOO_LONG' using errcode = '22023', hint = 'Keep the reason to 500 characters.';
    end if;
    insert into public.partner_rule_overrides (partner_id, rules, reason, admin_id)
    values (p_partner, v_problems, v_reason, v_uid)
    returning id into v_override;
  end if;

  perform public.partner_review_decide_documents(p_partner, true);

  -- Partner and vehicle are approved together.
  if p.registration_vehicle_id is not null then
    update public.vehicle
       set status = 'approved', documents_ok = true
     where id = p.registration_vehicle_id
       and status::text in ('unapproved', 'unapproved-docs', 'rejected');
    v_vehicle := found;
  end if;
  if not (p.status::text = 'approved' or p.status::text like 'permit-%') then
    update public.partners
       set status = 'approved', status_note = null, documents_ok = true, updated_at = now()
     where id = p_partner;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'partner.review_approve', p.auth_user_id,
          jsonb_build_object('partner_id', p_partner, 'vehicle_id', p.registration_vehicle_id,
                             'vehicle_approved', v_vehicle)
          || case when v_override is null then '{}'::jsonb
                  else jsonb_build_object('override_id', v_override, 'override_reason', v_reason,
                                          'rules', v_problems) end);
  return jsonb_build_object('approved', true, 'vehicle_approved', v_vehicle, 'overridden', v_override is not null);
end;
$$;
revoke execute on function public.partner_review_approve(uuid, text) from public, anon;
grant execute on function public.partner_review_approve(uuid, text) to authenticated;

-- ---- 4. Who would fail now ---------------------------------------------------------------------------
-- The partners of type [p_type], submitted or approved (not blocked), that
-- fail its rules today, with those failures.
create or replace function public.admin_partner_rule_failures(p_type text)
returns table (partner_id uuid, name text, display_id text, status text, problems jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.caller_admin_can_write('rpc:admin_partner_rule_failures') then
    raise exception 'Only admins who can edit Partner Service types can see this.' using errcode = '42501';
  end if;
  return query
  select q.id, q.name, q.display_id, q.status, q.problems
    from (
      select p.id, coalesce(nullif(btrim(p.name), ''), 'Partner') as name, p.display_id::text as display_id,
             p.status::text as status,
             (select coalesce(jsonb_agg(f.x order by f.n), '[]'::jsonb)
                from jsonb_array_elements(public.reg_rule_failures(public.reg_rule_checks(to_jsonb(p))))
                     with ordinality f(x, n)
               where public.ptr_key(f.x ->> 'type') = public.ptr_key(public.partner_type_rules(p_type) ->> 'name'))
               as problems
        from public.partners p
       where exists (select 1 from unnest(coalesce(p.partner_types, '{}')) x where public.ptr_key(x) = public.ptr_key(p_type))
         and p.status::text <> 'blocked'
         and (coalesce(p.documents_ok, false) or p.status::text = 'approved' or p.status::text like 'permit-%')
    ) q
   where jsonb_array_length(q.problems) > 0
   order by (q.status = 'approved' or q.status like 'permit-%'), lower(q.name), q.id
   limit 500;
end;
$$;
revoke execute on function public.admin_partner_rule_failures(text) from public, anon;
grant execute on function public.admin_partner_rule_failures(text) to authenticated;

notify pgrst, 'reload schema';
