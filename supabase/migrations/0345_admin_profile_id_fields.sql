-- Admin writes the ID fields chosen during review (Admin → People → User ID
-- Documents). ============================================================================
-- When an admin reviews a pending ID, the app OCRs the ID image and shows each
-- field (name, IC, date of birth, gender, address, nationality) read from the
-- image beside what the user keyed, and the admin picks per field which to
-- keep. There is no admin UPDATE policy on public.profiles (account_repository
-- notes it), so the chosen values are written through this SECURITY DEFINER
-- RPC — gated on the same page as the ID review (rpc:identity_check_review) —
-- rather than a direct update. It writes only the keys present in p_fields and
-- validates each; it never touches id_verified (profile_id_review does that).
-- ============================================================================

create or replace function public.admin_set_profile_id_fields(p_user uuid, p_fields jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_birth date;
  v_gender text;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:identity_check_review') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_user is null or jsonb_typeof(p_fields) is distinct from 'object' then
    raise exception 'bad_request' using errcode = '22023';
  end if;

  -- Validate the typed fields up front; a bad value is ignored, not fatal.
  if p_fields ? 'birth_date' and (p_fields->>'birth_date') ~ '^\d{4}-\d{2}-\d{2}$' then
    v_birth := (p_fields->>'birth_date')::date;
  end if;
  if p_fields ? 'gender' and (p_fields->>'gender') in ('male', 'female', 'other') then
    v_gender := p_fields->>'gender';
  end if;

  update public.profiles set
    name        = case when p_fields ? 'name'        then nullif(btrim(p_fields->>'name'), '') else name end,
    ic          = case when p_fields ? 'ic'          then nullif(btrim(p_fields->>'ic'), '') else ic end,
    nationality = case when p_fields ? 'nationality' then nullif(btrim(p_fields->>'nationality'), '') else nationality end,
    address     = case when p_fields ? 'address'     then nullif(btrim(p_fields->>'address'), '') else address end,
    birth_date  = case when p_fields ? 'birth_date'  then v_birth else birth_date end,
    gender      = case when p_fields ? 'gender'      then v_gender::public.gender_type else gender end,
    updated_at  = now()
   where id = p_user;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'identity.id_fields', p_user,
          jsonb_build_object('keys', (select jsonb_agg(k) from jsonb_object_keys(p_fields) k)));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.admin_set_profile_id_fields(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_profile_id_fields(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
