-- ============================================================================
-- 0353: Approver — Phase 3 (upload): replace a document's image on behalf.
--
-- An approver with can_upload replaces the image of a document already in their
-- scope (a clearer scan of the same document). Approvers cannot write the
-- private document buckets from the app (storage RLS allows only the folder's
-- owner or an admin), so the upload goes through the `approver-upload` edge
-- function with the service role; these two RPCs keep the authorization and the
-- review state in SQL, reusing approver_covers:
--   approver_upload_target(source, id)  authorize (active, can_upload, in scope)
--                                       and return the current image's URL (the
--                                       object the edge function overwrites).
--   approver_upload_commit(source, id)  after the bytes are replaced, reopen the
--                                       document for review (Pending Review,
--                                       reviewer fields cleared) and audit.
-- Replacing only ever overwrites an existing image — it never creates a new
-- document or a new storage path.
-- ============================================================================

create or replace function public.approver_upload_target(p_source text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_owner uuid;
  v_url   text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if p_source = 'partner' then
    select auth_user_id, file_url into v_owner, v_url from public.provider_documents where id = p_id;
  elsif p_source = 'vehicle' then
    select auth_user_id, file_url into v_owner, v_url from public.vehicle_documents where id = p_id;
  elsif p_source = 'identity' then
    select user_id, file_url into v_owner, v_url from public.identity_checks where id = p_id;
  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;

  if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(v_url, '')), '') is null then
    raise exception 'APPROVER_NO_IMAGE' using errcode = '22023', hint = 'Replace needs an existing image to overwrite.';
  end if;

  return jsonb_build_object('ok', true, 'owner', v_owner, 'file_url', v_url);
end;
$$;
revoke execute on function public.approver_upload_target(text, uuid) from public, anon;
grant execute on function public.approver_upload_target(text, uuid) to authenticated;

create or replace function public.approver_upload_commit(p_source text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_owner uuid;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if p_source = 'partner' then
    select auth_user_id into v_owner from public.provider_documents where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.provider_documents
       set status = 'Pending Review', reviewer_notes = null, reviewed_at = null where id = p_id;
  elsif p_source = 'vehicle' then
    select auth_user_id into v_owner from public.vehicle_documents where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.vehicle_documents
       set status = 'Pending Review', reviewer_notes = null, reviewed_at = null where id = p_id;
  elsif p_source = 'identity' then
    select user_id into v_owner from public.identity_checks where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.identity_checks
       set status = 'Pending Review', reviewed_by = null, reviewed_at = null,
           reject_reason = null, reject_note = null where id = p_id;
  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.upload', v_owner, jsonb_build_object('source', p_source, 'doc_id', p_id));
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_upload_commit(text, uuid) from public, anon;
grant execute on function public.approver_upload_commit(text, uuid) to authenticated;

notify pgrst, 'reload schema';
