-- ============================================================================
-- 0441 GET eKYC: every identity document named on the check
--
-- Why: GET eKYC (0439) also reads MyPR, MyKAS, MyTentera, i-Kad, UNHCR
-- cards, residence permits, foreign ID cards and the Malaysian driving
-- licence. Until now anything but a MyKad or passport was stored without a
-- type and showed to admins as "MyKad".
--
-- 1. identity_checks.doc_type accepts each of them.
-- 2. ekyc_apply (as 0439) keeps the type, and auto-verifies a rider only
--    for an identity card or passport the country's rule accepts (idType):
--    a driving licence, i-Kad, UNHCR card or residence permit is read and
--    kept for an admin to decide.
--
-- Re-runnable. supabase/tests/get_ekyc_document_types_0441.sql covers it.
-- ============================================================================

-- 1. Document types -------------------------------------------------------------------------------
alter table public.identity_checks drop constraint if exists identity_checks_doc_type_check;
alter table public.identity_checks add constraint identity_checks_doc_type_check
  check (doc_type is null or doc_type in ('mykad', 'mypr', 'mykas', 'mytentera', 'id_card', 'passport',
                                          'driving_licence', 'ikad', 'unhcr', 'residence_permit'));

-- 2. The result, as 0439 with the types and the idType rule ----------------------------------------
create or replace function public.ekyc_apply(p_session uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.ekyc_sessions;
  v_read jsonb := coalesce(p->'read', '{}'::jsonb);
  v_status text := p->>'status';
  v_reasons text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'reasons', '[]'::jsonb))), '{}');
  v_doc text := nullif(p->>'doc_type', '');
  v_front text := nullif(p->>'front', '');
  v_back text := nullif(p->>'back', '');
  v_selfie text := nullif(p->>'selfie', '');
  v_score numeric := nullif(p#>>'{face,score}', '')::numeric;
  v_face text := nullif(p#>>'{face,state}', '');
  v_live text := case p->>'liveness' when 'passed' then 'passed' else 'not_checked' end;
  v_check uuid;
  v_applied jsonb := jsonb_build_object('verified', false, 'pending', true);
  v_paths_ok boolean;
  v_id_type text;
begin
  select * into s from public.ekyc_sessions where id = p_session for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if s.state = 'completed' then
    return jsonb_build_object('check_id', s.check_id, 'verified', false, 'pending', false, 'repeat', true);
  end if;
  if v_status is null or v_status not in ('approved', 'review', 'rejected') then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'status';
  end if;
  if v_front is null or v_front !~ ('^' || s.user_id::text || '/') then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'front photo';
  end if;
  v_paths_ok := (v_back is null or v_back ~ ('^' || s.user_id::text || '/'))
                 and (v_selfie is null or v_selfie ~ ('^' || s.user_id::text || '/'));
  if not v_paths_ok then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'photo path';
  end if;
  if v_doc is not null and v_doc not in ('mykad', 'mypr', 'mykas', 'mytentera', 'id_card', 'passport',
                                         'driving_licence', 'ikad', 'unhcr', 'residence_permit') then
    v_doc := null;
  end if;
  if v_face is not null and v_face not in ('match', 'no_match', 'no_face', 'not_checked') then
    v_face := 'not_checked';
  end if;
  if v_score is not null and (v_score < 0 or v_score > 100) then
    v_score := null;
  end if;

  insert into public.identity_checks (
    user_id, kind, purpose, doc_type, file_url, file_url_back, liveness, liveness_detail,
    read_name, read_ic, read_passport, read_birth, read_expiry, expiry_date, read_nationality, read_gender, read_address,
    read_source, read_at, mismatch, face_score, face_state, face_provider, face_checked_at,
    status, ekyc_verification, ekyc_status, ekyc_reasons)
  values (
    s.user_id, 'id', s.purpose, v_doc, v_front, v_back, v_live, case when v_live = 'passed' then 'turn' end,
    left(nullif(btrim(v_read->>'name'), ''), 120),
    left(nullif(btrim(v_read->>'ic'), ''), 40),
    left(nullif(btrim(v_read->>'passport'), ''), 40),
    case when v_read->>'birth' ~ '^\d{4}-\d{2}-\d{2}$' then (v_read->>'birth')::date end,
    case when v_read->>'expiry' ~ '^\d{4}-\d{2}-\d{2}$' then (v_read->>'expiry')::date end,
    case when v_read->>'expiry' ~ '^\d{4}-\d{2}-\d{2}$' then (v_read->>'expiry')::date end,
    case when v_read->>'nationality' ~ '^[A-Z]{3}$' then v_read->>'nationality' end,
    case when v_read->>'gender' in ('male', 'female', 'other') then v_read->>'gender' end,
    left(nullif(btrim(v_read->>'address'), ''), 300),
    'ekyc', now(),
    public.identity_read_mismatch(s.user_id, v_read->>'name', coalesce(nullif(v_read->>'ic', ''), v_read->>'passport')),
    v_score, coalesce(v_face, 'not_checked'), 'ekyc', now(),
    'Pending Review', s.verification_id, v_status, v_reasons)
  returning id into v_check;

  -- Riders: the selfie is kept as its own check, as the rider flow does (0343).
  if s.purpose = 'rider_gate' and v_selfie is not null then
    insert into public.identity_checks (
      user_id, kind, purpose, file_url, liveness, liveness_detail, face_score, face_state, face_provider,
      face_checked_at, status, ekyc_verification, ekyc_status, ekyc_reasons)
    values (
      s.user_id, 'selfie', 'rider_gate', v_selfie, v_live, case when v_live = 'passed' then 'turn' end,
      v_score, coalesce(v_face, 'not_checked'), 'ekyc', now(), 'Pending Review', s.verification_id, v_status, v_reasons);
  end if;

  -- Auto-verify only an identity document the country's rule accepts
  -- (idType national / passport / either); a driving licence, i-Kad, UNHCR
  -- card or residence permit is read and kept, and an admin decides.
  if s.purpose = 'rider_gate' and v_status = 'approved' then
    select coalesce(public.rider_id_gate_config()->pr.nationality, public.rider_id_gate_config()->'master')->>'idType'
      into v_id_type from public.profiles pr where pr.id = s.user_id;
    v_id_type := coalesce(v_id_type, 'either');
    if (v_id_type = 'passport' and v_doc = 'passport')
       or (v_id_type = 'national' and v_doc in ('mykad', 'mypr', 'mykas', 'mytentera', 'id_card'))
       or (v_id_type not in ('passport', 'national')
           and v_doc in ('mykad', 'mypr', 'mykas', 'mytentera', 'id_card', 'passport')) then
      v_applied := public.rider_id_gate_apply(v_check);
    end if;
  end if;
  if (v_applied->>'pending')::boolean then
    begin
      perform public.identity_notify_admins(v_check);
    exception when others then
      raise warning 'ekyc_apply notify: %', sqlerrm;
    end;
  end if;

  update public.ekyc_sessions
     set state = 'completed', ekyc_status = v_status, check_id = v_check, completed_at = now(), error = null
   where id = s.id;
  return jsonb_build_object('check_id', v_check, 'verified', (v_applied->>'verified')::boolean,
                            'pending', (v_applied->>'pending')::boolean);
end;
$$;
revoke execute on function public.ekyc_apply(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.ekyc_apply(uuid, jsonb) to service_role;

notify pgrst, 'reload schema';
