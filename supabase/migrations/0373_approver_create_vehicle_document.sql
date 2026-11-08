-- ============================================================================
-- 0373: Upload a vehicle document on behalf (My Team — Vehicle detail sheet).
--
-- The follow-up to 0372 (which added driver documents only). A vehicle document
-- needs the vehicle it belongs to (vehicle_documents.vehicle_id is NOT NULL),
-- so this lives on the Vehicle detail sheet, where the vehicle is known:
--
--   approver_addable_vehicle_documents(vehicle)
--       the vehicle document types this vehicle does not have yet.
--
--   approver_create_vehicle_document(vehicle, doc_id, doc_name)
--       create a Pending Review vehicle_documents row for one of them, with a
--       fresh vehicle-keyed storage path, and return it + the owner. The
--       approver then uploads its image through the existing approver-upload
--       flow (which already handles the 'vehicle' source).
--
-- Both need the approver active, holding can_upload, and covering the vehicle's
-- owner. A valid, active vehicle document type and no existing row for it are
-- enforced. Reuses _vehicle_doc_categories() from 0372 (a type is a vehicle
-- document when its docTypes include the Vehicle category).
-- ============================================================================

-- The vehicle document types a covered member's vehicle does not have yet.
create or replace function public.approver_addable_vehicle_documents(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload or p_vehicle is null then return '[]'::jsonb; end if;
  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null or not public.approver_covers(v_owner) then return '[]'::jsonb; end if;

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v from (
    select jsonb_build_object(
             'doc_id', rd.id,
             'name', coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document'),
             'required', coalesce((rd.values->>'required')::boolean, false),
             'is_pwd', coalesce((rd.values->>'isPwd')::boolean, false)) as x
      from public.required_document rd
     where coalesce((rd.values->>'active')::boolean, false)
       -- vehicle docs only: the type is tagged with the Vehicle category
       and (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb
              ? 'a7d71867-ac2a-4c0c-ae07-87e5d500693c')
       and not exists (select 1 from public.vehicle_documents d
                        where d.vehicle_id = p_vehicle and d.doc_id = rd.id::text)
  ) q;
  return v;
end;
$$;
revoke execute on function public.approver_addable_vehicle_documents(uuid) from public, anon;
grant execute on function public.approver_addable_vehicle_documents(uuid) to authenticated;

-- Create a Pending Review vehicle document for a covered member's vehicle.
create or replace function public.approver_create_vehicle_document(p_vehicle uuid, p_doc_id text, p_doc_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v_partner uuid; v_new uuid; v_url text;
  v_is_pwd boolean; v_rd public.required_document;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_allowed'; end if;
  if p_vehicle is null or p_doc_id is null then raise exception 'bad_input' using errcode = '22023'; end if;

  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(v_owner) then raise exception 'out_of_scope'; end if;

  -- The doc type must be a real, active vehicle document type.
  select * into v_rd from public.required_document where id = p_doc_id::uuid;
  if not found or not coalesce((v_rd.values->>'active')::boolean, false)
     or not (coalesce(nullif(v_rd.values->>'docTypes', ''), '[]')::jsonb ? 'a7d71867-ac2a-4c0c-ae07-87e5d500693c') then
    raise exception 'bad_doc_type' using errcode = '22023';
  end if;
  v_is_pwd := coalesce((v_rd.values->>'isPwd')::boolean, false);

  select id into v_partner from public.partners where auth_user_id = v_owner limit 1;

  if exists (select 1 from public.vehicle_documents where vehicle_id = p_vehicle and doc_id = p_doc_id) then
    raise exception 'already_exists' using errcode = '22023';
  end if;

  v_url := 'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object/public/vehicle-documents/'
           || p_vehicle::text || '/approver-' || gen_random_uuid()::text;

  insert into public.vehicle_documents (vehicle_id, auth_user_id, partner_id, doc_id, doc_name, is_pwd, status, file_url)
  values (p_vehicle, v_owner, v_partner, p_doc_id,
          coalesce(nullif(btrim(p_doc_name), ''), nullif(btrim(v_rd.values->>'name'), ''), 'Document'),
          v_is_pwd, 'Pending Review', v_url)
  returning id into v_new;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.create_document', v_owner,
          jsonb_build_object('source', 'vehicle', 'doc_id', p_doc_id, 'document', v_new, 'vehicle', p_vehicle));

  return jsonb_build_object('ok', true, 'source', 'vehicle', 'id', v_new, 'owner_id', v_owner);
end;
$$;
revoke execute on function public.approver_create_vehicle_document(uuid, text, text) from public, anon;
grant execute on function public.approver_create_vehicle_document(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
