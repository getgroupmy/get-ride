-- ============================================================================
-- 0372: Upload a driver document on behalf of a covered member (My Team).
--
-- The on-behalf upload (0353/0371) only ever replaced an EXISTING document's
-- image. The mockup also lets an approver add a document the member has not
-- uploaded yet ("… · No Document · Upload on behalf"). This adds, for driver
-- (provider) documents only:
--
--   approver_addable_documents(member)
--       the driver document types the member does not have yet (from the
--       required-document catalogue, excluding vehicle documents), so the tab
--       can list them as "No Document".
--
--   approver_create_document(member, doc_id, doc_name)
--       create a Pending Review provider_documents row for one of those types,
--       with a fresh member-keyed storage path, and return it. The approver
--       then uploads its image through the existing approver-upload flow.
--
-- Both need the approver to be active, cover the member, and hold can_upload.
-- A valid driver doc type and no existing row for it are enforced. Vehicle
-- documents (which also need a vehicle) are out of scope here.
-- ============================================================================

-- The two document_type categories that mark a VEHICLE document.
create or replace function public._vehicle_doc_categories()
returns text[] language sql immutable as $$
  select array['a7d71867-ac2a-4c0c-ae07-87e5d500693c',   -- Vehicle
               '26100737-f401-4364-85af-e6c429e742e0'];  -- Admin-Vehicle
$$;

-- The driver document types a covered member has not uploaded yet.
create or replace function public.approver_addable_documents(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare a public.approvers; v_me uuid := auth.uid(); v jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload or p_member is null or not public.approver_covers(p_member) then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v from (
    select jsonb_build_object(
             'doc_id', rd.id,
             'name', coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document'),
             'required', coalesce((rd.values->>'required')::boolean, false),
             'is_pwd', coalesce((rd.values->>'isPwd')::boolean, false),
             'requires_number', coalesce((rd.values->>'requireDocumentNumber')::boolean, false),
             'requires_start', coalesce((rd.values->>'requireStartDate')::boolean, false),
             'requires_expiry', coalesce((rd.values->>'requireExpiryDate')::boolean, false)) as x
      from public.required_document rd
     where coalesce((rd.values->>'active')::boolean, false)
       -- driver docs only: the type is not tagged as a vehicle document
       and not (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories())
       -- the member has not uploaded this type yet
       and not exists (select 1 from public.provider_documents d
                        where d.auth_user_id = p_member and d.doc_id = rd.id::text)
  ) q;
  return v;
end;
$$;
revoke execute on function public.approver_addable_documents(uuid) from public, anon;
grant execute on function public.approver_addable_documents(uuid) to authenticated;

-- Create a Pending Review driver document for a covered member, ready for the
-- approver to upload its image. The new row gets a fresh member-keyed path in
-- the provider-documents bucket (reads use the stored URL, so the folder is
-- arbitrary); the approver-upload flow then writes the image to it.
create or replace function public.approver_create_document(p_member uuid, p_doc_id text, p_doc_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.approvers; v_me uuid := auth.uid(); v_partner uuid; v_new uuid; v_url text; v_is_pwd boolean;
  v_rd public.required_document;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_allowed'; end if;
  if p_member is null or p_doc_id is null then raise exception 'bad_input' using errcode = '22023'; end if;
  if not public.approver_covers(p_member) then raise exception 'out_of_scope'; end if;

  -- The doc type must be a real, active driver (non-vehicle) document type.
  select * into v_rd from public.required_document where id = p_doc_id::uuid;
  if not found or not coalesce((v_rd.values->>'active')::boolean, false)
     or (coalesce(nullif(v_rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories()) then
    raise exception 'bad_doc_type' using errcode = '22023';
  end if;
  v_is_pwd := coalesce((v_rd.values->>'isPwd')::boolean, false);

  -- The row needs the member's partner id (NOT NULL).
  select id into v_partner from public.partners where auth_user_id = p_member limit 1;
  if v_partner is null then raise exception 'no_partner' using errcode = '22023'; end if;

  -- One document of each type per member.
  if exists (select 1 from public.provider_documents where auth_user_id = p_member and doc_id = p_doc_id) then
    raise exception 'already_exists' using errcode = '22023';
  end if;

  v_url := 'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object/public/provider-documents/'
           || p_member::text || '/approver-' || gen_random_uuid()::text;

  insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url)
  values (v_partner, p_member, p_doc_id,
          coalesce(nullif(btrim(p_doc_name), ''), nullif(btrim(v_rd.values->>'name'), ''), 'Document'),
          v_is_pwd, 'Pending Review', v_url)
  returning id into v_new;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.create_document', p_member,
          jsonb_build_object('source', 'partner', 'doc_id', p_doc_id, 'document', v_new));

  return jsonb_build_object('ok', true, 'source', 'partner', 'id', v_new);
end;
$$;
revoke execute on function public.approver_create_document(uuid, text, text) from public, anon;
grant execute on function public.approver_create_document(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
