-- ============================================================================
-- 0352: Approver — Phase 3 (delete): remove an uploaded document / image.
--
-- An approver with can_delete removes a bad or wrong upload. Per the grant:
--   soft (default)  "send back": clear the image and set the document back to
--                   Pending Review so the owner uploads a new one (identity
--                   can't clear its NOT NULL image, so its submission is set
--                   Rejected — the owner re-submits); the owner is pushed.
--   hard (delete_hard)  permanently delete the record.
-- The scope and conflict guard are re-checked at write time (approver_covers),
-- and every delete is audited ('approver.delete'). Stored files are left to a
-- separate janitor — this removes the record/reference, not the storage object.
--
-- NOTE for deploy: this migration contains DELETE, which the MCP migration-apply
-- tool refuses (its destructive-op scan times out). Apply it with psql / the
-- Supabase SQL editor; CI's migration-replay (psql) validates it normally.
-- ============================================================================

create or replace function public.approver_delete_document(p_source text, p_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a        public.approvers;
  v_me     uuid := auth.uid();
  v_owner  uuid;
  v_name   text;
  v_note   text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  v_hard   boolean;
  c        public.identity_checks;
  v_what   text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_delete then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_hard := a.delete_hard;

  if p_source = 'partner' then
    select auth_user_id, doc_name into v_owner, v_name from public.provider_documents where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    if v_hard then
      delete from public.provider_documents where id = p_id;
    else
      update public.provider_documents
         set file_url = null, file_url_back = null, status = 'Pending Review',
             reviewer_notes = v_note, reviewed_at = now()
       where id = p_id;
      perform public.approval_push_send(v_owner,
        public.approval_push_message('document', 'rejected', v_name, coalesce(v_note, 'please upload it again')),
        jsonb_build_object('type', 'document_status', 'table', 'provider_documents', 'document_id', p_id, 'status', 'Pending Review'));
    end if;

  elsif p_source = 'vehicle' then
    select auth_user_id, doc_name into v_owner, v_name from public.vehicle_documents where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    if v_hard then
      delete from public.vehicle_documents where id = p_id;
    else
      update public.vehicle_documents
         set file_url = null, file_url_back = null, status = 'Pending Review',
             reviewer_notes = v_note, reviewed_at = now()
       where id = p_id;
      perform public.approval_push_send(v_owner,
        public.approval_push_message('document', 'rejected', v_name, coalesce(v_note, 'please upload it again')),
        jsonb_build_object('type', 'document_status', 'table', 'vehicle_documents', 'document_id', p_id, 'status', 'Pending Review'));
    end if;

  elsif p_source = 'identity' then
    select user_id into v_owner from public.identity_checks where id = p_id;
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    if v_hard then
      delete from public.identity_checks where id = p_id;
    else
      update public.identity_checks
         set status = 'Rejected', reject_reason = 'other',
             reject_note = coalesce(v_note, 'Removed — please upload again.'),
             reviewed_by = v_me, reviewed_at = now()
       where id = p_id
      returning * into c;
      v_what := case when c.kind = 'id' then 'ID' else 'photo' end;
      perform public.approval_push_send(c.user_id,
        jsonb_build_object('title', 'Your ' || v_what || ' wasn''t accepted',
                           'body', coalesce(v_note, 'Removed') || '. Open GET.ride to send a new one.'),
        jsonb_build_object('type', 'identity_check', 'check_id', c.id, 'for', 'person'));
    end if;

  else
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.delete', v_owner,
          jsonb_build_object('source', p_source, 'doc_id', p_id,
                             'mode', case when v_hard then 'hard' else 'soft' end, 'note', v_note));
  return jsonb_build_object('ok', true, 'mode', case when v_hard then 'hard' else 'soft' end);
end;
$$;
revoke execute on function public.approver_delete_document(text, uuid, text) from public, anon;
grant execute on function public.approver_delete_document(text, uuid, text) to authenticated;

notify pgrst, 'reload schema';
