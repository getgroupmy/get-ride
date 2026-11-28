-- GET.eKYC's approval verifies the rider, whatever the face-score bar.
-- ============================================================================
-- get.ekyc now approves on its own only when the document's details are
-- confirmed by the machine (a MyKad's validated number, or the check digits of
-- a passport or of an ID card with machine-readable lines), the selfie matches
-- its photo and the head-turn liveness passed; everything else comes back as
-- 'review' for a person. The owner's rule: that approval is final, and the app
-- verifies the rider at once.
--
-- Until now rider_id_gate_apply (0343) also wanted the face score at or above
-- the country's autoVerifyScore (85 by default). get.ekyc reports a face that
-- just passes its own threshold as 80, so some of its approvals stayed
-- 'Pending Review'. A check get.ekyc approved — written only by ekyc_apply
-- with the service role, from a signed webhook — now counts as strong when
-- its face matched and its liveness passed. The face-score rule still decides
-- for the other providers (rider-verify's face match).
--
-- Reversible: re-run 0343's rider_id_gate_apply.
-- ============================================================================

create or replace function public.rider_id_gate_apply(p_check uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_check public.identity_checks;
  v_prof public.profiles;
  v_rule jsonb;
  v_strong boolean;
begin
  select * into v_check from public.identity_checks where id = p_check;
  if not found or v_check.kind <> 'id' or v_check.purpose <> 'rider_gate' then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select * into v_prof from public.profiles where id = v_check.user_id;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  v_rule := coalesce(public.rider_id_gate_config()->v_prof.nationality, public.rider_id_gate_config()->'master');

  v_strong := (v_check.face_provider = 'ekyc'
               and v_check.ekyc_status = 'approved'
               and v_check.face_state = 'match'
               and v_check.liveness = 'passed')
              or (v_check.face_state = 'match'
                  and v_check.face_score is not null
                  and v_check.face_score >= coalesce((v_rule->>'autoVerifyScore')::numeric, 85));

  if v_strong then
    update public.profiles set
      id_verified = 'Verified',
      id_expiry_date = coalesce(v_check.expiry_date, id_expiry_date),
      id_image = coalesce(id_image, v_check.file_url),
      name = coalesce(nullif(btrim(name), ''), v_check.read_name),
      birth_date = coalesce(birth_date, v_check.read_birth),
      address = coalesce(nullif(btrim(address), ''), v_check.read_address),
      gender = coalesce(gender, case when v_check.read_gender in ('male', 'female', 'other')
                                     then v_check.read_gender::public.gender_type end)
     where id = v_check.user_id;
    update public.identity_checks set status = 'Approved', reviewed_at = now() where id = p_check;
    return jsonb_build_object('verified', true, 'pending', false);
  end if;

  -- Not strong enough: leave it for an admin to decide.
  update public.identity_checks set status = 'Pending Review' where id = p_check and status is distinct from 'Approved';
  return jsonb_build_object('verified', false, 'pending', true);
end;
$$;
revoke execute on function public.rider_id_gate_apply(uuid) from public, anon, authenticated;
grant execute on function public.rider_id_gate_apply(uuid) to service_role;

notify pgrst, 'reload schema';
