-- GET.eKYC IDs render, and a pending GET.eKYC shows on User ID Documents.
-- ============================================================================
-- Two fixes so a rider's GET.eKYC identity check is reviewable on Admin →
-- People → User ID Documents (its "Pending" tab), as the owner asked, and not
-- only in the Sign-in checks queue:
--
--  1. GET.eKYC's photos are stored as the bucket's public-form URL (the
--     ekyc-webhook now returns getPublicUrl, the same shape the rider-verify
--     face match already stores), so the admin review screens and the profile
--     can turn them into a signed link and show them. ekyc_apply's "the photo
--     is the person's own" guard is widened to accept that URL form as well as
--     the bare `<user>/…` path, via the pure public.ekyc_photo_bound(url, user):
--     a photo is still bound to its owner, so someone else's photo is refused.
--  2. An inserted rider-gate ID check seeds the rider's profiles.id_image from
--     its front photo when the profile has none yet — coalesce semantics, a
--     real upload or a strong-match write is never overwritten — leaving
--     id_verified null so it reads as pending until a strong auto-match or an
--     admin decides it (id_verification_status is only Verified/Failed/Expired;
--     a null status with an image IS the pending state the "Pending" tab lists).
--
-- Reversible: drop the trigger, its function and ekyc_photo_bound, and restore
-- ekyc_apply's inline path checks. Going live also needs the ekyc-webhook
-- redeploy (it now returns the public URL).
-- ============================================================================

-- 1. A GET.eKYC photo is bound to its owner whether it is stored as a bare
--    ID_Image path (`<user>/…`) or as the bucket's public / signed URL
--    (`…/ID_Image/<user>/…`). Pure, so it is unit-tested.
create or replace function public.ekyc_photo_bound(p_url text, p_user uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_url is not null and (
    p_url ~ ('^' || p_user::text || '/')
    or position('/ID_Image/' || p_user::text || '/' in p_url) > 0
  );
$$;

-- ekyc_apply, reproduced from migration 0439 with only the three photo-path
-- checks routed through ekyc_photo_bound (grants are kept by CREATE OR REPLACE).
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
  if not public.ekyc_photo_bound(v_front, s.user_id) then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'front photo';
  end if;
  v_paths_ok := (v_back is null or public.ekyc_photo_bound(v_back, s.user_id))
                 and (v_selfie is null or public.ekyc_photo_bound(v_selfie, s.user_id));
  if not v_paths_ok then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'photo path';
  end if;
  if v_doc is not null and v_doc not in ('mykad', 'passport', 'id_card') then
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
$$;

-- 2. Seed a pending rider GET.eKYC / face-match ID onto the profile, so it is
--    reviewable on User ID Documents (its "Pending" tab: an id_image with no
--    id_verified yet) as well as in the Sign-in checks queue. Only where the
--    profile has no image yet — a real upload or a strong-match write (0343) is
--    never overwritten.
create or replace function public.identity_check_seed_profile_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'id' and new.purpose = 'rider_gate' and new.file_url is not null then
    update public.profiles
       set id_image = new.file_url, updated_at = now()
     where id = new.user_id and id_image is null;
  end if;
  return new;
end;
$$;
revoke execute on function public.identity_check_seed_profile_id() from public, anon, authenticated;

drop trigger if exists identity_check_seed_profile_id on public.identity_checks;
create trigger identity_check_seed_profile_id
  after insert on public.identity_checks
  for each row execute function public.identity_check_seed_profile_id();

notify pgrst, 'reload schema';
