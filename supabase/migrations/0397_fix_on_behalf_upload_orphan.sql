-- Fix: an on-behalf document upload could leave an orphan row.
--
-- "Upload on behalf" of a missing driver/vehicle document is a two-step flow:
--   1. approver_create_document / approver_create_vehicle_document creates a
--      Pending Review row, and
--   2. the approver-upload edge function writes the image and commits it.
-- The create RPCs stamped the row's file_url with a placeholder storage path
-- ("…/approver-<uuid>") at step 1 — before any object existed there. If step 2
-- never completed (the picker was cancelled, the upload failed, the app was
-- closed), the row kept a file_url pointing at a file that was never written:
-- an orphan that shows "Couldn't load this image" and can't be verified.
--
-- The fix decouples "where to write" from "the live image URL":
--   * the create RPCs now leave file_url NULL (the row honestly has no image
--     until one is uploaded — the viewer shows "No image was uploaded");
--   * approver_upload_target generates a fresh write path when a partner/vehicle
--     document has no image yet (instead of refusing), so the normal upload and
--     the Replace button both still work; and
--   * approver_upload_commit already sets file_url to the written path, so the
--     URL only ever appears once the object exists.
--
-- Existing orphans (a placeholder file_url with no object in storage) have their
-- file_url cleared so they read as "no image" and can be re-uploaded or sent
-- back, rather than showing a broken image.

-- 1. Generate a write path for a document that has no image yet.
create or replace function public.approver_upload_target(p_source text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v_url text; v_status text;
  v_vehicle uuid; v_pending boolean := false; v_upload_url text;
  v_base text := 'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object/public/';
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_authorized' using errcode = '42501'; end if;
  if p_source = 'partner' then
    select auth_user_id, file_url, status into v_owner, v_url, v_status from public.provider_documents where id = p_id;
  elsif p_source = 'vehicle' then
    select auth_user_id, file_url, status, vehicle_id into v_owner, v_url, v_status, v_vehicle from public.vehicle_documents where id = p_id;
  elsif p_source = 'identity' then
    select user_id, file_url, status into v_owner, v_url, v_status from public.identity_checks where id = p_id;
  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;
  if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;

  if nullif(btrim(coalesce(v_url, '')), '') is null then
    -- No image yet: a first on-behalf upload (or one whose row was left blank).
    -- Mint a fresh write path for a driver/vehicle document; identity checks
    -- always carry their own image, so there is nothing to write to.
    if p_source = 'partner' then
      v_upload_url := v_base || 'provider-documents/' || v_owner::text || '/approver-' || gen_random_uuid()::text;
    elsif p_source = 'vehicle' then
      if v_vehicle is null then raise exception 'APPROVER_NO_IMAGE' using errcode = '22023'; end if;
      v_upload_url := v_base || 'vehicle-documents/' || v_vehicle::text || '/approver-' || gen_random_uuid()::text;
    else
      raise exception 'APPROVER_NO_IMAGE' using errcode = '22023', hint = 'Replace needs an existing image to overwrite.';
    end if;
    return jsonb_build_object('ok', true, 'owner', v_owner, 'file_url', null,
                              'upload_url', v_upload_url, 'pending', false);
  end if;

  -- An approved driver/vehicle document gets a new pending path; the live image stays.
  if p_source in ('partner', 'vehicle') and v_status = 'Approved' then
    v_pending := true;
    v_upload_url := regexp_replace(v_url, '[^/]+$', 'pending-' || gen_random_uuid()::text);
  else
    v_upload_url := v_url;
  end if;

  return jsonb_build_object('ok', true, 'owner', v_owner, 'file_url', v_url,
                            'upload_url', v_upload_url, 'pending', v_pending);
end;
$function$;

-- 2. Create the on-behalf rows with no placeholder file_url.
create or replace function public.approver_create_document(p_member uuid, p_doc_id text, p_doc_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.approvers; v_me uuid := auth.uid(); v_partner uuid; v_new uuid; v_is_pwd boolean;
  v_rd public.required_document;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_allowed'; end if;
  if p_member is null or p_doc_id is null then raise exception 'bad_input' using errcode = '22023'; end if;
  if not public.approver_covers(p_member) then raise exception 'out_of_scope'; end if;

  select * into v_rd from public.required_document where id = p_doc_id::uuid;
  if not found or not coalesce((v_rd.values->>'active')::boolean, false)
     or (coalesce(nullif(v_rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories()) then
    raise exception 'bad_doc_type' using errcode = '22023';
  end if;
  v_is_pwd := coalesce((v_rd.values->>'isPwd')::boolean, false);

  select id into v_partner from public.partners where auth_user_id = p_member limit 1;
  if v_partner is null then raise exception 'no_partner' using errcode = '22023'; end if;

  if exists (select 1 from public.provider_documents where auth_user_id = p_member and doc_id = p_doc_id) then
    raise exception 'already_exists' using errcode = '22023';
  end if;

  -- No file_url until the image is actually uploaded (approver_upload_commit).
  insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, is_pwd, status, file_url)
  values (v_partner, p_member, p_doc_id,
          coalesce(nullif(btrim(p_doc_name), ''), nullif(btrim(v_rd.values->>'name'), ''), 'Document'),
          v_is_pwd, 'Pending Review', null)
  returning id into v_new;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.create_document', p_member,
          jsonb_build_object('source', 'partner', 'doc_id', p_doc_id, 'document', v_new));

  return jsonb_build_object('ok', true, 'source', 'partner', 'id', v_new);
end;
$$;

create or replace function public.approver_create_vehicle_document(p_vehicle uuid, p_doc_id text, p_doc_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v_partner uuid; v_new uuid;
  v_is_pwd boolean; v_rd public.required_document;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_allowed'; end if;
  if p_vehicle is null or p_doc_id is null then raise exception 'bad_input' using errcode = '22023'; end if;

  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(v_owner) then raise exception 'out_of_scope'; end if;

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

  -- No file_url until the image is actually uploaded (approver_upload_commit).
  insert into public.vehicle_documents (vehicle_id, auth_user_id, partner_id, doc_id, doc_name, is_pwd, status, file_url)
  values (p_vehicle, v_owner, v_partner, p_doc_id,
          coalesce(nullif(btrim(p_doc_name), ''), nullif(btrim(v_rd.values->>'name'), ''), 'Document'),
          v_is_pwd, 'Pending Review', null)
  returning id into v_new;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.create_document', v_owner,
          jsonb_build_object('source', 'vehicle', 'doc_id', p_doc_id, 'document', v_new, 'vehicle', p_vehicle));

  return jsonb_build_object('ok', true, 'source', 'vehicle', 'id', v_new, 'owner_id', v_owner);
end;
$$;

-- 3. Clear the file_url of existing orphans (a placeholder path with no object),
--    so they read as "no image" instead of a broken link.
update public.vehicle_documents d
   set file_url = null
 where d.file_url ~ '/(approver|pending)-[0-9a-f-]+$'
   and not exists (
     select 1 from storage.objects o
      where o.bucket_id = split_part(split_part(d.file_url, '/object/public/', 2), '/', 1)
        and o.name = substr(split_part(d.file_url, '/object/public/', 2),
                            length(split_part(split_part(d.file_url, '/object/public/', 2), '/', 1)) + 2));

update public.provider_documents d
   set file_url = null
 where d.file_url ~ '/(approver|pending)-[0-9a-f-]+$'
   and not exists (
     select 1 from storage.objects o
      where o.bucket_id = split_part(split_part(d.file_url, '/object/public/', 2), '/', 1)
        and o.name = substr(split_part(d.file_url, '/object/public/', 2),
                            length(split_part(split_part(d.file_url, '/object/public/', 2), '/', 1)) + 2));

notify pgrst, 'reload schema';
