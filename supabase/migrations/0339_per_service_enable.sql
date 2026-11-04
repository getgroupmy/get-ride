-- ============================================================================
-- Per-service enabling (0339): a partner is allowed to use each Partner
-- Service type the moment that type's own requirements are met, instead of
-- one all-or-nothing approval. A partner who picked eHailing + Teksi whose
-- documents satisfy eHailing but not Teksi is approved and dispatched for
-- eHailing while Teksi stays off until its documents land — automatically,
-- with no second approval.
--
-- This builds entirely on the existing per-type machinery:
--   * reg_rule_checks(partner) already emits one row per rule PER TYPE, each
--     labelled with its type; reg_rule_failures keeps the failed ones. A type
--     is "blocked" when it has a failed rule (citizens_only / business_
--     registration / driver_permit). The driver-permit rule already reads the
--     uploaded document's status live (reg_driver_permit_state), so a type
--     turns on by itself when its permit is approved.
--   * vehicle permits and age limits stay the per-vehicle gate they already
--     are (vehicle_service_status / vehicle_service_block); they are reported
--     by reg_rule_checks with status 'paused', never 'failed', so they do not
--     enter the per-type block set here — a car with eHailing waiting on its
--     eVP still runs its other services, exactly as before.
--
-- What changes:
--   1. New helpers: reg_type_blocked_keys / reg_has_ready_type /
--      partner_type_ready.
--   2. driver_partner_service_ok (the accept-time and service-effective gate)
--      now requires a partner type that BOTH allows the service AND is ready,
--      so the server dispatches a service only to a ready type.
--   3. Submit (partners_registration_rules) and approval
--      (partner_review_approve) no longer refuse the whole application when
--      some type fails: they proceed as long as at least one type is ready,
--      and refuse only when nothing is ready (approval still takes an admin
--      override reason to force a wholly-unready partner, as before).
--
-- Nothing is dropped; every function is create-or-replace with its existing
-- signature, so all call sites inherit the new behaviour. Idempotent.
-- ============================================================================

-- ---- 1. Per-type readiness -------------------------------------------------

-- The ptr_key()s of the partner types that have a FAILED registration rule in
-- [p_row] (a partners row as JSON). Vehicle permit / age rows are status
-- 'paused', not 'failed', so they are not here — they gate the vehicle, not
-- the partner type.
create or replace function public.reg_type_blocked_keys(p_row jsonb)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    array_agg(distinct public.ptr_key(e.x ->> 'type'))
      filter (where nullif(btrim(coalesce(e.x ->> 'type', '')), '') is not null),
    '{}')
    from jsonb_array_elements(public.reg_rule_failures(public.reg_rule_checks(p_row))) e(x);
$$;
revoke execute on function public.reg_type_blocked_keys(jsonb) from public, anon, authenticated;
grant execute on function public.reg_type_blocked_keys(jsonb) to service_role;

-- Whether at least one of [p_row]'s selected partner types is ready (no failed
-- rule). True when nothing fails at all (including a partner with no types, so
-- submit is never newly refused for them). A type with no rules is ready.
create or replace function public.reg_has_ready_type(p_row jsonb)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with blocked as (select public.reg_type_blocked_keys(p_row) as k)
  select case
    when coalesce(cardinality((select k from blocked)), 0) = 0 then true
    else exists (
      select 1
        from unnest(public.ptr_text_array(p_row -> 'partner_types')) as t
       where nullif(btrim(coalesce(t, '')), '') is not null
         and public.ptr_key(public.partner_type_rules(t) ->> 'name') <> all((select k from blocked)))
  end;
$$;
revoke execute on function public.reg_has_ready_type(jsonb) from public, anon, authenticated;
grant execute on function public.reg_has_ready_type(jsonb) to service_role;

-- Whether partner type [p_type] (a key or name) is ready for the driver: no
-- failed registration rule for that type. Unknown driver / partner → true, so
-- it never blocks where readiness can't be judged (mirrors
-- driver_partner_service_ok).
create or replace function public.partner_type_ready(p_driver uuid, p_type text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p public.partners%rowtype;
begin
  if p_driver is null or nullif(btrim(coalesce(p_type, '')), '') is null then
    return true;
  end if;
  select * into p from public.partners where auth_user_id = p_driver order by created_at limit 1;
  if not found then
    return true;
  end if;
  return public.ptr_key(public.partner_type_rules(p_type) ->> 'name')
         <> all(public.reg_type_blocked_keys(to_jsonb(p)));
end;
$$;
revoke execute on function public.partner_type_ready(uuid, text) from public, anon, authenticated;
grant execute on function public.partner_type_ready(uuid, text) to service_role;

-- ---- 2. Dispatch gate: only a READY type takes a service -------------------
-- As 0299, plus: the allowing type must also be ready (its documents met).
create or replace function public.driver_partner_service_ok(p_driver uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p        public.partners%rowtype;
  v_types  text[];
  v_blocked text[];
begin
  if p_driver is null or coalesce(btrim(p_service), '') = '' or lower(btrim(p_service)) ~ '^(extra|hail):' then
    return true;
  end if;
  select * into p from public.partners where auth_user_id = p_driver order by created_at limit 1;
  if not found then
    return true;
  end if;
  v_types := array(select btrim(t)
                     from unnest(case when coalesce(cardinality(p.partner_types), 0) > 0
                                      then p.partner_types else array[p.partner_type] end) as t
                    where coalesce(btrim(t), '') <> '');
  if coalesce(cardinality(v_types), 0) = 0 then
    return true;
  end if;
  v_blocked := public.reg_type_blocked_keys(to_jsonb(p));
  return exists (
    select 1 from unnest(v_types) as t
     where public.partner_type_allows_service(t, p_service)
       and public.ptr_key(public.partner_type_rules(t) ->> 'name') <> all(v_blocked));
end;
$$;
revoke execute on function public.driver_partner_service_ok(uuid, text) from public, anon, authenticated;
grant execute on function public.driver_partner_service_ok(uuid, text) to service_role;

-- ---- 3. Submit: allow as long as one type is ready -------------------------
-- As 0305, but the whole application is refused only when NOTHING is ready;
-- with one ready type the partner may submit and use it while the rest wait.
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
  -- Per-service (0339): only refuse when not one type is ready.
  if jsonb_array_length(v_problems) > 0 and not public.reg_has_ready_type(to_jsonb(new)) then
    v_first := v_problems -> 0;
    raise exception '%', public.reg_rule_code(v_first ->> 'rule') using errcode = '42501',
      hint = v_first ->> 'message', detail = v_problems::text;
  end if;
  return new;
end;
$$;
revoke execute on function public.partners_registration_rules() from public, anon, authenticated;

-- ---- 4. Approve: enable the ready services, don't refuse the rest ----------
-- As 0305, but a partial application is approved: when some types are ready it
-- goes through (the unready ones stay off at dispatch and turn on by
-- themselves once their documents are approved). Only a wholly-unready partner
-- still needs an admin override reason. The override is recorded only when a
-- reason is actually given (a forced approval), as before.
drop function if exists public.partner_review_approve(uuid, text);
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
  v_ready    boolean;
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

  -- The partner registration rules, checked again (0305/0339).
  v_problems := public.reg_rule_failures(public.reg_rule_checks(to_jsonb(p)));
  v_ready := public.reg_has_ready_type(to_jsonb(p));
  if jsonb_array_length(v_problems) > 0 then
    -- Nothing ready: refuse unless the admin forces it with a reason.
    if not v_ready and v_reason is null then
      raise exception 'PARTNER_RULES_NOT_MET' using errcode = '22023',
        hint = format('Can''t approve: %s. Ask the partner for the documents, or approve anyway with a reason.',
                      (select string_agg(format('%s missing (%s needs it in %s)', x ->> 'label', x ->> 'type', x ->> 'place'),
                                         '; ' order by n)
                         from jsonb_array_elements(v_problems) with ordinality e(x, n))),
        detail = v_problems::text;
    end if;
    -- A reason was given: record the override (forced approval).
    if v_reason is not null then
      if char_length(v_reason) > 500 then
        raise exception 'REVIEW_NOTE_TOO_LONG' using errcode = '22023', hint = 'Keep the reason to 500 characters.';
      end if;
      insert into public.partner_rule_overrides (partner_id, rules, reason, admin_id)
      values (p_partner, v_problems, v_reason, v_uid)
      returning id into v_override;
    end if;
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
                             'vehicle_approved', v_vehicle, 'partial', v_problems is not null
                               and jsonb_array_length(v_problems) > 0 and v_override is null)
          || case when v_override is null then '{}'::jsonb
                  else jsonb_build_object('override_id', v_override, 'override_reason', v_reason,
                                          'rules', v_problems) end);
  return jsonb_build_object('approved', true, 'vehicle_approved', v_vehicle, 'overridden', v_override is not null,
                            'partial', jsonb_array_length(v_problems) > 0 and v_override is null);
end;
$$;
revoke execute on function public.partner_review_approve(uuid, text) from public, anon;
grant execute on function public.partner_review_approve(uuid, text) to authenticated;
