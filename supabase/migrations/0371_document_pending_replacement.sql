-- ============================================================================
-- 0371: Pending replacement for driver & vehicle documents — keep the live
-- approved image while a new one awaits review, and revert on reject.
--
-- Until now the on-behalf upload (0353) OVERWROTE the document's image in place
-- and set it Pending Review, so the previously-approved image was lost the
-- moment a new scan went up. The mockup's flow keeps the approved image LIVE
-- until the new one is approved, and a Reject discards the new one and reverts.
--
-- This adds a pending image alongside the live one, for `partner` and `vehicle`
-- documents (identity keeps its existing overwrite flow):
--   • pending_file_url / pending_uploaded_by / pending_uploaded_at columns,
--   • approver_upload_target now returns a NEW pending storage path (derived
--     from the approved image's folder) when the document is already Approved,
--     so the edge function writes the new scan beside the live one,
--   • approver_upload_commit records it as pending (keeping the live image) for
--     an Approved document, else overwrites in place as before,
--   • approver_review_document promotes the pending image to live on approve,
--     and discards it (reverting to the live approved image) on reject.
-- Contained to the approver on-behalf flow; a driver's own upload is unchanged.
--
-- Additive + CREATE OR REPLACE only (no DROP). The commit signature gains two
-- defaulted params, so the old 2-arg call still resolves.
-- ============================================================================

alter table public.provider_documents add column if not exists pending_file_url     text;
alter table public.provider_documents add column if not exists pending_uploaded_by  uuid;
alter table public.provider_documents add column if not exists pending_uploaded_at  timestamptz;
alter table public.vehicle_documents  add column if not exists pending_file_url     text;
alter table public.vehicle_documents  add column if not exists pending_uploaded_by  uuid;
alter table public.vehicle_documents  add column if not exists pending_uploaded_at  timestamptz;

-- Where the edge function should write the new scan. For an already-approved
-- partner/vehicle document, a fresh "pending-…" object in the same folder (so
-- the live approved image is preserved); otherwise the existing path (overwrite).
create or replace function public.approver_upload_target(p_source text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v_url text; v_status text;
  v_pending boolean := false; v_upload_url text;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_authorized' using errcode = '42501'; end if;
  if p_source = 'partner' then
    select auth_user_id, file_url, status into v_owner, v_url, v_status from public.provider_documents where id = p_id;
  elsif p_source = 'vehicle' then
    select auth_user_id, file_url, status into v_owner, v_url, v_status from public.vehicle_documents where id = p_id;
  elsif p_source = 'identity' then
    select user_id, file_url, status into v_owner, v_url, v_status from public.identity_checks where id = p_id;
  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;
  if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(v_url, '')), '') is null then
    raise exception 'APPROVER_NO_IMAGE' using errcode = '22023', hint = 'Replace needs an existing image to overwrite.';
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
revoke execute on function public.approver_upload_target(text, uuid) from public, anon;
grant execute on function public.approver_upload_target(text, uuid) to authenticated;

-- Record the upload: as a pending replacement (keeping the live image) when the
-- edge function wrote a pending object, else overwrite-in-place as before.
create or replace function public.approver_upload_commit(p_source text, p_id uuid, p_upload_url text default null, p_pending boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare a public.approvers; v_me uuid := auth.uid(); v_owner uuid;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_authorized' using errcode = '42501'; end if;

  if p_source = 'partner' then
    select auth_user_id into v_owner from public.provider_documents where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    if p_pending then
      update public.provider_documents
         set pending_file_url = p_upload_url, pending_uploaded_by = v_me, pending_uploaded_at = now(),
             status = 'Pending Review', reviewer_notes = null, reviewed_at = null, reviewed_by = null
       where id = p_id;
    else
      update public.provider_documents
         set file_url = coalesce(p_upload_url, file_url), status = 'Pending Review',
             reviewer_notes = null, reviewed_at = null, reviewed_by = null,
             pending_file_url = null, pending_uploaded_by = null, pending_uploaded_at = null
       where id = p_id;
    end if;
  elsif p_source = 'vehicle' then
    select auth_user_id into v_owner from public.vehicle_documents where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    if p_pending then
      update public.vehicle_documents
         set pending_file_url = p_upload_url, pending_uploaded_by = v_me, pending_uploaded_at = now(),
             status = 'Pending Review', reviewer_notes = null, reviewed_at = null, reviewed_by = null
       where id = p_id;
    else
      update public.vehicle_documents
         set file_url = coalesce(p_upload_url, file_url), status = 'Pending Review',
             reviewer_notes = null, reviewed_at = null, reviewed_by = null,
             pending_file_url = null, pending_uploaded_by = null, pending_uploaded_at = null
       where id = p_id;
    end if;
  elsif p_source = 'identity' then
    select user_id into v_owner from public.identity_checks where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.identity_checks
       set status = 'Pending Review', reviewed_by = null, reviewed_at = null, reject_reason = null, reject_note = null
     where id = p_id;
  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.upload', v_owner, jsonb_build_object('source', p_source, 'doc_id', p_id, 'pending', p_pending));
  return jsonb_build_object('ok', true);
end;
$function$;
revoke execute on function public.approver_upload_commit(text, uuid, text, boolean) from public, anon;
grant execute on function public.approver_upload_commit(text, uuid, text, boolean) to authenticated;

-- Review now promotes / reverts a pending replacement on partner & vehicle docs.
create or replace function public.approver_review_document(p_source text, p_id uuid, p_action text, p_reason text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v_status text;
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), ''); c public.identity_checks; v_what text;
  v_pending text;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_approve then raise exception 'not_authorized' using errcode = '42501'; end if;
  if p_action not in ('approve', 'reject') then raise exception 'APPROVER_BAD_ACTION' using errcode = '22023'; end if;
  v_status := case when p_action = 'approve' then 'Approved' else 'Rejected' end;

  if p_source = 'partner' then
    select auth_user_id, pending_file_url into v_owner, v_pending from public.provider_documents where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    -- A reject needs a reason, except a pending-replacement revert (the live image simply stays).
    if p_action = 'reject' and v_pending is null and v_note is null then
      raise exception 'APPROVER_REASON' using errcode = '22023', hint = 'Add a reason when rejecting.';
    end if;
    if v_pending is not null then
      if p_action = 'approve' then
        update public.provider_documents
           set file_url = pending_file_url, status = 'Approved',
               pending_file_url = null, pending_uploaded_by = null, pending_uploaded_at = null,
               reviewed_by = v_me, reviewed_at = now() where id = p_id;
      else
        update public.provider_documents
           set status = 'Approved',
               pending_file_url = null, pending_uploaded_by = null, pending_uploaded_at = null,
               reviewer_notes = coalesce(v_note, reviewer_notes), reviewed_by = v_me, reviewed_at = now() where id = p_id;
      end if;
    else
      update public.provider_documents
         set status = v_status, reviewer_notes = case when p_action = 'reject' then v_note else reviewer_notes end,
             reviewed_by = v_me, reviewed_at = now() where id = p_id;
    end if;
  elsif p_source = 'vehicle' then
    select auth_user_id, pending_file_url into v_owner, v_pending from public.vehicle_documents where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    if p_action = 'reject' and v_pending is null and v_note is null then
      raise exception 'APPROVER_REASON' using errcode = '22023', hint = 'Add a reason when rejecting.';
    end if;
    if v_pending is not null then
      if p_action = 'approve' then
        update public.vehicle_documents
           set file_url = pending_file_url, status = 'Approved',
               pending_file_url = null, pending_uploaded_by = null, pending_uploaded_at = null,
               reviewed_by = v_me, reviewed_at = now() where id = p_id;
      else
        update public.vehicle_documents
           set status = 'Approved',
               pending_file_url = null, pending_uploaded_by = null, pending_uploaded_at = null,
               reviewer_notes = coalesce(v_note, reviewer_notes), reviewed_by = v_me, reviewed_at = now() where id = p_id;
      end if;
    else
      update public.vehicle_documents
         set status = v_status, reviewer_notes = case when p_action = 'reject' then v_note else reviewer_notes end,
             reviewed_by = v_me, reviewed_at = now() where id = p_id;
    end if;
  elsif p_source = 'identity' then
    if p_action = 'reject' and v_note is null then
      raise exception 'APPROVER_REASON' using errcode = '22023', hint = 'Add a reason when rejecting.';
    end if;
    select user_id into v_owner from public.identity_checks where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.identity_checks
       set status = v_status,
           reject_reason = case when p_action = 'reject'
                                then case when public.identity_reason_text(p_reason) is not null then p_reason else 'other' end end,
           reject_note = case when p_action = 'reject' then v_note else reject_note end,
           reviewed_by = v_me, reviewed_at = now()
     where id = p_id returning * into c;
    if c.kind = 'id' and p_action = 'approve' then
      update public.profiles
         set id_verified = 'Verified', id_expiry_date = coalesce(c.expiry_date, id_expiry_date),
             id_image = coalesce(id_image, c.file_url)
       where id = c.user_id;
    end if;
    v_what := case when c.kind = 'id' then 'ID' else 'photo' end;
    perform public.approval_push_send(c.user_id,
      case when p_action = 'approve' then
        jsonb_build_object('title', 'Your ' || v_what || ' is approved',
                           'body', case when c.kind = 'id' then 'Open GET.ride to use your role.'
                                        else 'Thanks. Nothing more to do for your photo.' end)
      else
        jsonb_build_object('title', 'Your ' || v_what || ' wasn''t accepted',
                           'body', v_note || '. Open GET.ride to send a new one.')
      end,
      jsonb_build_object('type', 'identity_check', 'check_id', c.id, 'for', 'person'));
  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.review', v_owner,
          jsonb_build_object('source', p_source, 'doc_id', p_id, 'action', p_action, 'reason', p_reason,
                             'note', v_note, 'pending', v_pending is not null));
  return jsonb_build_object('ok', true, 'status', v_status);
end;
$function$;
revoke execute on function public.approver_review_document(text, uuid, text, text, text) from public, anon;
grant execute on function public.approver_review_document(text, uuid, text, text, text) to authenticated;

-- The Documents-tab meta now carries the pending image + who/when, so the card
-- can show the "New image · pending review" state beside the live approved one.
create or replace function public.approver_owner_document_meta(p_owner uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v jsonb := '{}'::jsonb;
begin
  if auth.uid() is null or p_owner is null or not public.approver_covers(p_owner) then return v; end if;
  select coalesce(jsonb_object_agg(k, meta), '{}'::jsonb) into v from (
    select d.id::text as k, jsonb_build_object('changed_by', nullif(btrim(rp.name), ''),
             'provider', nullif(btrim(d.insurance_provider_name), ''), 'is_pwd', d.is_pwd,
             'uploaded_at', d.uploaded_at, 'reviewed_at', d.reviewed_at,
             'pending_file_url', d.pending_file_url,
             'pending_uploaded_by', nullif(btrim(pu.name), ''),
             'pending_uploaded_at', d.pending_uploaded_at) as meta
      from public.provider_documents d
      left join public.profiles rp on rp.id = d.reviewed_by
      left join public.profiles pu on pu.id = d.pending_uploaded_by
     where d.auth_user_id = p_owner
    union all
    select d.id::text, jsonb_build_object('changed_by', nullif(btrim(rp.name), ''),
             'provider', nullif(btrim(d.insurance_provider_name), ''), 'is_pwd', null,
             'uploaded_at', d.uploaded_at, 'reviewed_at', d.reviewed_at,
             'pending_file_url', d.pending_file_url,
             'pending_uploaded_by', nullif(btrim(pu.name), ''),
             'pending_uploaded_at', d.pending_uploaded_at)
      from public.vehicle_documents d
      left join public.profiles rp on rp.id = d.reviewed_by
      left join public.profiles pu on pu.id = d.pending_uploaded_by
     where d.auth_user_id = p_owner
    union all
    select c.id::text, jsonb_build_object('changed_by', nullif(btrim(rp.name), ''),
             'provider', null, 'is_pwd', null, 'uploaded_at', c.created_at, 'reviewed_at', c.reviewed_at,
             'pending_file_url', null, 'pending_uploaded_by', null, 'pending_uploaded_at', null)
      from public.identity_checks c left join public.profiles rp on rp.id = c.reviewed_by
     where c.user_id = p_owner and c.status is not null
  ) q;
  return v;
end;
$$;
revoke execute on function public.approver_owner_document_meta(uuid) from public, anon;
grant execute on function public.approver_owner_document_meta(uuid) to authenticated;

notify pgrst, 'reload schema';
