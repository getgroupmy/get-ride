-- ============================================================================
-- 0402: VOC completion gate — a vehicle needs its ownership certificate to be
--       submitted, and verified to be approved.
--
-- The Vehicle Ownership Certificate (VOC) became a compulsory vehicle document
-- in 0388, and 0392 surfaces a missing one as a non-blocking badge. This makes
-- it a hard gate, at the two chokepoints that move a vehicle through review:
--
--   * Submit  (partners_registration_rules, the before-update trigger): the VOC
--     must at least be UPLOADED (a vehicle_documents row that is not Rejected).
--     You can't send a vehicle for review with no ownership certificate at all.
--   * Approve (partner_review_approve): the VOC must be VERIFIED (an Approved
--     vehicle_documents row). The partner + vehicle are approved together, so
--     this blocks the whole approval unless an admin forces it with a reason —
--     the same override path the registration rules already use (recorded).
--
-- Strictness (owner's decision): present to submit, Approved to approve.
--
-- Legacy-exempt (owner's decision, and as 0392): both gates act only while a
-- vehicle is moving through review — submit fires on a submit transition, and
-- the approve gate only guards the unapproved/rejected -> approved transition.
-- A vehicle approved before the VOC existed is already 'approved', so it never
-- re-transitions and is never re-gated; it keeps the soft voc_missing badge.
--
-- Detection mirrors 0392 exactly (a VOC type is active; Approved vs any
-- non-rejected one on the vehicle), so the badge and the gate always agree.
--
-- All three objects are CREATE OR REPLACE with unchanged signatures (the two
-- functions are recreated from their current 0339 bodies with the VOC checks
-- added), so there is no DROP. Inert where no active VOC document type exists:
-- vehicle_voc_state returns 'na' and neither gate fires.
-- ============================================================================

-- ---- 0. The VOC state of a vehicle ---------------------------------------------------------------
-- 'na'       no active VOC document type — the gate does not apply.
-- 'approved' the vehicle has an Approved VOC on file (verified).
-- 'present'  the vehicle has a non-rejected VOC on file, not yet Approved.
-- 'missing'  a VOC type is active but the vehicle has no non-rejected VOC.
create or replace function public.vehicle_voc_state(p_vehicle uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_vehicle is null then 'na'
    when not exists (select 1 from public.required_document rd
                      where coalesce((rd.values->>'active')::boolean, false)
                        and rd.values->>'readAs' = 'voc') then 'na'
    when exists (select 1 from public.vehicle_documents d
                   join public.required_document rd on rd.id::text = d.doc_id
                  where d.vehicle_id = p_vehicle and d.status = 'Approved'
                    and rd.values->>'readAs' = 'voc') then 'approved'
    when exists (select 1 from public.vehicle_documents d
                   join public.required_document rd on rd.id::text = d.doc_id
                  where d.vehicle_id = p_vehicle and coalesce(d.status, '') <> 'Rejected'
                    and rd.values->>'readAs' = 'voc') then 'present'
    else 'missing'
  end;
$$;
revoke execute on function public.vehicle_voc_state(uuid) from public, anon;
grant execute on function public.vehicle_voc_state(uuid) to authenticated;

-- ---- 1. Submit: the VOC must at least be uploaded ------------------------------------------------
-- As 0339, plus: a vehicle with no ownership certificate uploaded can't be sent
-- for review. Independent of per-service readiness — it is a vehicle-level
-- requirement, so one ready type does not excuse a missing VOC.
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
  -- VC-6: the vehicle's ownership certificate (VOC) must at least be uploaded to
  -- submit; it is verified at approval. Legacy-safe — this runs only on a submit
  -- transition, so an already-approved vehicle is never involved.
  if public.vehicle_voc_state(new.registration_vehicle_id) = 'missing' then
    raise exception 'VOC_REQUIRED' using errcode = '42501',
      hint = 'Upload the vehicle''s ownership certificate (VOC / geran) before submitting for review.';
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

-- ---- 2. Approve: the VOC must be verified -------------------------------------------------------
-- As 0339, plus: a vehicle is approved only with its VOC verified (Approved).
-- The VOC block refuses the whole approval even when a service type is ready —
-- a car can't go live without its ownership certificate — unless the admin
-- forces it with a reason, recorded like any other rule override. The reason
-- then also lets the vehicle transition go through.
-- CREATE OR REPLACE with the current (uuid, text) signature, so no DROP — the
-- drop would also remove the grants, and trips the destructive-statement guard.
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
  v_voc_block boolean := false;
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

  -- VC-6: the vehicle being approved needs its VOC verified. Only while it is
  -- actually moving to approved (legacy-safe), and only when a VOC type is
  -- active and this vehicle has no Approved one yet (mirrors 0392).
  if p.registration_vehicle_id is not null
     and exists (select 1 from public.vehicle v
                  where v.id = p.registration_vehicle_id
                    and v.status::text in ('unapproved', 'unapproved-docs', 'rejected'))
     and public.vehicle_voc_state(p.registration_vehicle_id) in ('present', 'missing') then
    v_voc_block := true;
    v_problems := coalesce(v_problems, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'rule', 'voc', 'label', 'Vehicle Ownership Certificate', 'type', 'Vehicle',
      'place', coalesce(nullif(btrim((p.service_countries)[1]), ''), 'Malaysia'),
      'status', 'failed',
      'message', 'The vehicle''s ownership certificate (VOC) must be verified before the vehicle is approved.'));
  end if;

  if jsonb_array_length(v_problems) > 0 then
    -- Refuse unless the admin forces it with a reason: when nothing is ready, or
    -- when the VOC is not verified (a vehicle-level block that a ready type does
    -- not excuse).
    if (not v_ready or v_voc_block) and v_reason is null then
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

  -- Partner and vehicle are approved together. The vehicle transition is held
  -- back when its VOC is not verified, unless the approval was forced (a reason
  -- was given, recorded above).
  if p.registration_vehicle_id is not null and (not v_voc_block or v_reason is not null) then
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

notify pgrst, 'reload schema';
