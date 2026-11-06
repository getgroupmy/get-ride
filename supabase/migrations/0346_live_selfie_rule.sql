-- ============================================================================
-- 0346 — "Live selfie required" partner registration rule.
--
-- Version 20261106050000 (0346_live_selfie_rule). Re-runnable: functions
-- "create or replace" only. No partner is changed when it runs; the rule
-- applies to the next submission or approval.
--
-- A new per-type, per-region "Partner registration" setting `liveSelfie`
-- (PartnerServiceSettings, a RegionRequirement like citizensOnly): where it
-- holds, the partner's onboarding profile selfie must have been taken with
-- the live check (blink / turn) — a selfie taken without it (uploaded on the
-- web, an old app, or otherwise not live) fails the check. Until now that was
-- only a soft "Needs a closer look" flag (0288); turned on here it blocks the
-- partner's Submit and the admin's Approve, exactly like Citizens only and
-- Driver permit, so an old or modified app cannot skip it.
--
-- It is woven into the existing engine (0305) by extending two functions:
--   * reg_rule_checks adds a `live_selfie` row per type where the rule holds,
--     passed only when partner_selfie_liveness (0288) is 'passed';
--   * reg_rule_code maps it to LIVE_SELFIE_REQUIRED.
-- Everything else (submit trigger, partner_review_approve, the review
-- display, admin_partner_rule_failures) already reads those, so no other
-- function or trigger changes. Off by default (no liveSelfie key = no row).
-- ============================================================================

-- The code a failed rule refuses with (0305), plus the new one.
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
    when 'live_selfie' then 'LIVE_SELFIE_REQUIRED'
    else 'PARTNER_RULES_NOT_MET'
  end;
$$;

-- Every rule of the partner's types for the partner [p_row] (a partners row
-- as JSON): see 0305's header, plus the live-selfie rule added in 0346.
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
  v_live      text;
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
  -- How the partner's current profile selfie was taken (0288): 'passed' when
  -- it had the live check, 'not_checked' when it did not, null when unknown.
  v_live := public.partner_selfie_liveness(nullif(p_row ->> 'auth_user_id', '')::uuid, p_row ->> 'avatar_url');

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

    -- Live selfie required (onboarding): the profile selfie must have had the
    -- live check. A RegionRequirement, like Citizens only.
    v_place := public.reg_region_in(public.ptr_json(v -> 'liveSelfie'), v_countries, v_states, v_cities);
    if v_place is not null then
      v_place := coalesce(nullif(btrim(v_place), ''), v_first);
      out := out || jsonb_build_object(
        'rule', 'live_selfie', 'label', 'Live selfie', 'type', v_name, 'place', v_place,
        'liveness', coalesce(v_live, 'unknown'),
        'status', case when v_live = 'passed' then 'passed' else 'failed' end,
        'message', case when v_live = 'passed'
          then format('%s: live selfie', v_name)
          else format('%s in %s needs a live selfie. Retake your selfie with the live check (blink or turn), then submit again.',
                      v_name, v_place)
        end);
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

notify pgrst, 'reload schema';
