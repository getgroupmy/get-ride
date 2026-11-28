-- Admin ID review also captures the document type and the documents-OK flag.
-- ============================================================================
-- Admin → People → User ID Documents reads an ID with GET.ocr / Vision and the
-- admin keeps, per field, the keyed value or the one on the card. On top of the
-- fields migration 0345 already wrote (name, IC, date of birth, gender,
-- address, nationality), the scan now also carries:
--   * id_type       — the kind of ID read ('mykad' / 'passport'), an IdDocType
--                      key, stored on profiles.id_type so the record shows which
--                      ID was used for verification;
--   * documents_ok  — whether the document is OK (the read name and IC match the
--                      keyed ones), set true/false on Verify; the admin can still
--                      override it from Edit user details afterwards.
-- This redefines the 0345 RPC to accept those two keys (ignoring a malformed
-- value, as it does for the others) and to audit them. Same gate
-- (rpc:identity_check_review), still never touches id_verified.
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
  v_id_type text;
  v_docs_ok boolean;
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
  -- id_type is an IdDocType key the reader identified ('mykad'/'passport'); keep
  -- it to a short lowercase token (as the app stores it) and ignore anything else.
  if jsonb_typeof(p_fields->'id_type') = 'string'
     and lower(btrim(p_fields->>'id_type')) ~ '^[a-z_]{2,40}$' then
    v_id_type := lower(btrim(p_fields->>'id_type'));
  end if;
  -- documents_ok must be a real JSON boolean (false is meaningful, so a null
  -- here means "not supplied / malformed" and the stored value is kept).
  if jsonb_typeof(p_fields->'documents_ok') = 'boolean' then
    v_docs_ok := (p_fields->>'documents_ok')::boolean;
  end if;

  update public.profiles set
    name         = case when p_fields ? 'name'        then nullif(btrim(p_fields->>'name'), '') else name end,
    ic           = case when p_fields ? 'ic'          then nullif(btrim(p_fields->>'ic'), '') else ic end,
    nationality  = case when p_fields ? 'nationality' then nullif(btrim(p_fields->>'nationality'), '') else nationality end,
    address      = case when p_fields ? 'address'     then nullif(btrim(p_fields->>'address'), '') else address end,
    birth_date   = case when p_fields ? 'birth_date'  then v_birth else birth_date end,
    gender       = case when p_fields ? 'gender'      then v_gender::public.gender_type else gender end,
    id_type      = case when p_fields ? 'id_type' and v_id_type is not null then v_id_type else id_type end,
    documents_ok = case when v_docs_ok is not null then v_docs_ok else documents_ok end,
    updated_at   = now()
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
