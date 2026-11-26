-- 0441 — accept a driving licence as an identity document in GET eKYC (0439).
--
-- A licence that get.ekyc verifies used to be stored with a null doc_type
-- ("not an ID") and its number dropped. It is now labelled 'licence' and its
-- number kept in read_licence. The verification decision itself is unchanged:
-- ekyc_apply gates nothing on the document type, and rider_id_gate_apply
-- auto-verifies on the face match, so a licence that get.ekyc approves already
-- verified the person — this only labels and keeps it properly.
--
-- (Whether get.ekyc returns 'approved' for a licence in document_type:"auto"
-- mode is decided on the eKYC server, not here.)

-- The check now admits 'licence' alongside the existing three.
alter table public.identity_checks
  drop constraint if exists identity_checks_doc_type_check;
alter table public.identity_checks
  add constraint identity_checks_doc_type_check
  check (doc_type is null or doc_type = any (array['mykad', 'passport', 'id_card', 'licence']));

-- Where a licence's number is kept (beside read_ic / read_passport).
alter table public.identity_checks
  add column if not exists read_licence text;

create or replace function public.ekyc_apply(p_session uuid, p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
  -- 0441: 'licence' is now an accepted document type.
  if v_doc is not null and v_doc not in ('mykad', 'passport', 'id_card', 'licence') then
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
    read_name, read_ic, read_passport, read_licence, read_birth, read_expiry, expiry_date, read_nationality, read_gender, read_address,
    read_source, read_at, mismatch, face_score, face_state, face_provider, face_checked_at,
    status, ekyc_verification, ekyc_status, ekyc_reasons)
  values (
    s.user_id, 'id', s.purpose, v_doc, v_front, v_back, v_live, case when v_live = 'passed' then 'turn' end,
    left(nullif(btrim(v_read->>'name'), ''), 120),
    left(nullif(btrim(v_read->>'ic'), ''), 40),
    left(nullif(btrim(v_read->>'passport'), ''), 40),
    left(nullif(btrim(v_read->>'licence'), ''), 40),
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

  if s.purpose = 'rider_gate' and v_status = 'approved' then
    v_applied := public.rider_id_gate_apply(v_check);
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
$function$;
