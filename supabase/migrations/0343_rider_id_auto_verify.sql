-- Rider ID auto-verify on a strong, server-scored face match.
-- ============================================================================
-- When a rider self-verifies (migration 0342 gate), the `rider-verify` edge
-- function scores their live selfie against their ID photo server-side (reusing
-- the face providers, keys never leaving the server) and records it on an
-- identity_checks row (purpose 'rider_gate'). This migration adds the policy
-- that turns a strong score into id_verified='Verified' at once; a weak or
-- borderline score is left 'Pending Review' for an admin, so the booking gate
-- stays closed until a human approves. The admin sets the strong-match
-- threshold per country (autoVerifyScore on the rule).
--
-- The score itself is NEVER supplied by the client: rider_id_gate_apply only
-- ever reads the face_score the edge function wrote with the service role.
-- ============================================================================

-- ---- 0. autoVerifyScore on the rule (re-create the cleaner from 0342) -----------------------------
create or replace function public.rider_id_gate_rule(p in jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'require', coalesce((p->>'require')::boolean, false),
    'idType', case when p->>'idType' in ('national', 'passport', 'either') then p->>'idType' else 'either' end,
    'nthBooking', least(50, greatest(1, coalesce(
      case when jsonb_typeof(p->'nthBooking') = 'number' then (p->>'nthBooking')::numeric end, 1)))::int,
    'selfie', coalesce((p->>'selfie')::boolean, true),
    'allowPhoto', coalesce((p->>'allowPhoto')::boolean, true),
    -- The face-match score (0..100) at or above which a rider is verified
    -- without a human; below it the submission waits for admin review.
    'autoVerifyScore', least(99, greatest(60, coalesce(
      case when jsonb_typeof(p->'autoVerifyScore') = 'number' then (p->>'autoVerifyScore')::numeric end, 85)))::int);
$$;

-- ---- 1. Gender / address read fields on the check -------------------------------------------------
alter table public.identity_checks
  add column if not exists read_gender text
    check (read_gender is null or read_gender in ('male', 'female', 'other')),
  add column if not exists read_address text
    check (read_address is null or char_length(read_address) <= 300);

-- ---- 2. Apply the policy (service role only) ------------------------------------------------------
-- Reads the face_score already written on the check by the edge function and
-- the rider's country rule, and either verifies them and fills their profile
-- (only where empty) or leaves the check pending for admin review. Returns
-- { verified, pending }.
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

  v_strong := v_check.face_state = 'match'
              and v_check.face_score is not null
              and v_check.face_score >= coalesce((v_rule->>'autoVerifyScore')::numeric, 85);

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
