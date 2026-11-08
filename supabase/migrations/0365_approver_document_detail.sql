-- ============================================================================
-- 0365: approver_document_detail — the rich Document detail sheet (My Team).
--
-- The approver document viewer already shows the image, the captured fields
-- and Approve/Reject (0357). The mockup adds, per document:
--   * read-from-document vs stored (the OCR'd fields next to what's stored),
--   * AI verification (genuine / matches the expected type / confidence /
--     issuance country),
--   * the face check (selfie vs the document portrait),
--   * status & history (reviewer notes, who changed it, uploaded / reviewed).
--
-- That data already exists — on provider_documents / vehicle_documents
-- (ai_verification jsonb with an `extracted` block, issuance_country,
-- detected_document_name, reviewer_notes, uploaded_at, reviewed_at) and on
-- identity_checks (read_* and face_* columns, reviewed_by) plus
-- document_face_checks — but nothing exposed it to approvers. This read does,
-- for one document, normalized into one shape the app renders generically.
-- Scoped by approver_covers, like every My Team read; read-only.
--
--   approver_document_detail(source, id) → jsonb, or null out of scope:
--     { status, document_number, start_date, expiry_date,
--       reviewer_notes, uploaded_at, reviewed_at, changed_by,
--       ai:   { genuine, matches, detected_title, confidence, country } | null,
--       read: [ { field, read, stored, match } ],
--       face: { ok, score, label, reason } | null }
-- ============================================================================

-- A loose compare for read-vs-stored: equal ignoring case, spaces and dashes;
-- a null on either side counts as no-match (something read, nothing on file).
create or replace function public.norm_cmp(a text, b text)
returns boolean
language sql
immutable
as $$
  select case
    when a is null and b is null then true
    when a is null or b is null then false
    else lower(regexp_replace(a, '[\s-]', '', 'g')) = lower(regexp_replace(b, '[\s-]', '', 'g'))
  end;
$$;

create or replace function public.approver_document_detail(p_source text, p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_owner   uuid;
  d         record;
  p         public.profiles;
  v_ai      jsonb;
  v_ex      jsonb;
  v_read    jsonb := '[]'::jsonb;
  v_face    jsonb;
  v_changed text;
  fc        record;
begin
  if auth.uid() is null or p_source is null or p_id is null then
    return null;
  end if;

  if p_source = 'vehicle' then
    select vd.status, vd.document_number, vd.start_date, vd.expiry_date, vd.reviewer_notes,
           vd.uploaded_at, vd.reviewed_at, vd.ai_verification, vd.issuance_country,
           vd.detected_document_name, vd.auth_user_id,
           null::text as read_name, null::text as read_ic, null::text as read_passport,
           null::date as read_expiry, null::text as read_nationality,
           null::text as face_state, null::numeric as face_score, null::text as face_reason, null::uuid as reviewed_by
      into d from public.vehicle_documents vd where vd.id = p_id;
    v_owner := d.auth_user_id;
  elsif p_source = 'identity' then
    select c.status, null::text as document_number, null::date as start_date, c.expiry_date,
           c.reject_note as reviewer_notes, c.created_at as uploaded_at, c.reviewed_at,
           null::jsonb as ai_verification, c.read_nationality as issuance_country,
           c.doc_type as detected_document_name, c.user_id as auth_user_id,
           c.read_name, c.read_ic, c.read_passport, c.read_expiry, c.read_nationality,
           c.face_state, c.face_score, c.face_reason, c.reviewed_by
      into d from public.identity_checks c where c.id = p_id;
    v_owner := d.auth_user_id;
  else -- 'partner'
    select pd.status, pd.document_number, pd.start_date, pd.expiry_date, pd.reviewer_notes,
           pd.uploaded_at, pd.reviewed_at, pd.ai_verification, pd.issuance_country,
           pd.detected_document_name, pd.auth_user_id,
           null::text as read_name, null::text as read_ic, null::text as read_passport,
           null::date as read_expiry, null::text as read_nationality,
           null::text as face_state, null::numeric as face_score, null::text as face_reason, null::uuid as reviewed_by
      into d from public.provider_documents pd where pd.id = p_id;
    v_owner := d.auth_user_id;
  end if;

  if v_owner is null or not public.approver_covers(v_owner) then
    return null;
  end if;
  select * into p from public.profiles where id = v_owner;

  -- AI verification + read-vs-stored, by source.
  if p_source in ('partner', 'vehicle') then
    v_ai := case when jsonb_typeof(d.ai_verification) = 'object' then d.ai_verification end;
    v_ex := case when jsonb_typeof(v_ai -> 'extracted') = 'object' then v_ai -> 'extracted' end;
    v_read := (
      select coalesce(jsonb_agg(r order by ord), '[]'::jsonb) from (
        select 1 ord, jsonb_build_object('field','Document no.','read', v_ex->>'documentNumber',
                 'stored', d.document_number,
                 'match', public.norm_cmp(v_ex->>'documentNumber', d.document_number)) r
         where (v_ex->>'documentNumber') is not null or d.document_number is not null
        union all
        select 2, jsonb_build_object('field','Start date','read', v_ex->>'startDate',
                 'stored', d.start_date::text,
                 'match', public.norm_cmp(v_ex->>'startDate', d.start_date::text))
         where (v_ex->>'startDate') is not null or d.start_date is not null
        union all
        select 3, jsonb_build_object('field','Expiry','read', v_ex->>'expiryDate',
                 'stored', d.expiry_date::text,
                 'match', public.norm_cmp(v_ex->>'expiryDate', d.expiry_date::text))
         where (v_ex->>'expiryDate') is not null or d.expiry_date is not null
        union all
        select 4, jsonb_build_object('field','Country','read', v_ex->>'issuanceCountry',
                 'stored', coalesce(d.issuance_country, v_ex->>'issuanceCountry'), 'match', true)
         where (v_ex->>'issuanceCountry') is not null or d.issuance_country is not null
      ) q
    );
  elsif p_source = 'identity' then
    v_read := (
      select coalesce(jsonb_agg(r order by ord), '[]'::jsonb) from (
        select 1 ord, jsonb_build_object('field','Name','read', d.read_name, 'stored', p.name,
                 'match', public.norm_cmp(d.read_name, p.name)) r where d.read_name is not null
        union all
        select 2, jsonb_build_object('field','ID no.','read', coalesce(d.read_ic, d.read_passport),
                 'stored', p.ic, 'match', public.norm_cmp(coalesce(d.read_ic, d.read_passport), p.ic))
         where coalesce(d.read_ic, d.read_passport) is not null
        union all
        select 3, jsonb_build_object('field','Expiry','read', d.read_expiry::text,
                 'stored', d.expiry_date::text,
                 'match', public.norm_cmp(d.read_expiry::text, d.expiry_date::text))
         where d.read_expiry is not null
        union all
        select 4, jsonb_build_object('field','Nationality','read', d.read_nationality,
                 'stored', p.nationality, 'match', public.norm_cmp(d.read_nationality, p.nationality))
         where d.read_nationality is not null
      ) q
    );
    if d.face_state is not null or d.face_score is not null then
      v_face := jsonb_build_object('ok', d.face_state in ('match', 'pass'),
                  'score', d.face_score, 'label', coalesce(d.face_state, 'checked'), 'reason', d.face_reason);
    end if;
  end if;

  -- Face check from document_face_checks when the source didn't carry one.
  if v_face is null then
    select state, score, reason into fc
      from public.document_face_checks where doc_id = p_id order by checked_at desc nulls last limit 1;
    if found then
      v_face := jsonb_build_object('ok', fc.state in ('match', 'pass'),
                  'score', fc.score, 'label', coalesce(fc.state, 'checked'), 'reason', fc.reason);
    end if;
  end if;

  if p_source = 'identity' and d.reviewed_by is not null then
    select coalesce(nullif(btrim(name), ''), 'Reviewer') into v_changed from public.profiles where id = d.reviewed_by;
  end if;

  return jsonb_build_object(
    'status', d.status,
    'document_number', d.document_number,
    'start_date', d.start_date,
    'expiry_date', d.expiry_date,
    'reviewer_notes', nullif(btrim(coalesce(d.reviewer_notes, '')), ''),
    'uploaded_at', d.uploaded_at,
    'reviewed_at', d.reviewed_at,
    'changed_by', v_changed,
    'ai', case when v_ai is null then null else jsonb_build_object(
            'genuine', (v_ai->>'isReal')::boolean,
            'matches', (v_ai->>'matchesTitle')::boolean,
            'detected_title', coalesce(v_ai->>'detectedTitle', d.detected_document_name),
            'confidence', (v_ai->>'confidence'),
            'country', coalesce(d.issuance_country, v_ex->>'issuanceCountry')) end,
    'read', v_read,
    'face', v_face);
end;
$$;
revoke execute on function public.approver_document_detail(text, uuid) from public, anon;
grant execute on function public.approver_document_detail(text, uuid) to authenticated;

notify pgrst, 'reload schema';
