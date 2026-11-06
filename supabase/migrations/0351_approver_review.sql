-- ============================================================================
-- 0351: Approver — Phase 2: approve / reject a document.
--
-- An approver with can_approve decides a pending document in their scope. The
-- scope and the conflict guard are re-checked at write time with the very same
-- approver_covers rule the inbox uses (0350) — the app is never trusted. One
-- RPC spans the three stores:
--   partner   provider_documents   status → Approved/Rejected, reviewer_notes,
--   vehicle   vehicle_documents    reviewed_at. The owner is pushed by the
--                                  existing notify_document_status_push trigger.
--   identity  identity_checks      mirrors admin identity_check_review: status,
--                                  reject_reason/reject_note, reviewed_by/_at,
--                                  flips profiles.id_verified on an approved ID,
--                                  and sends the approval push itself.
--
-- A reject needs a reason (note). Only a 'Pending Review' document can be
-- decided — a decided one reads as not found, so a stale tap never re-decides.
-- Every decision is audited ('approver.review'). Upload / delete come in Phase 3.
-- ============================================================================

create or replace function public.approver_review_document(
  p_source text, p_id uuid, p_action text, p_reason text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a        public.approvers;
  v_me     uuid := auth.uid();
  v_owner  uuid;
  v_status text;
  v_note   text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  c        public.identity_checks;
  v_what   text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_approve then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_action not in ('approve', 'reject') then
    raise exception 'APPROVER_BAD_ACTION' using errcode = '22023';
  end if;
  v_status := case when p_action = 'approve' then 'Approved' else 'Rejected' end;
  if p_action = 'reject' and v_note is null then
    raise exception 'APPROVER_REASON' using errcode = '22023', hint = 'Add a reason when rejecting.';
  end if;

  if p_source = 'partner' then
    select auth_user_id into v_owner from public.provider_documents where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.provider_documents
       set status = v_status,
           reviewer_notes = case when p_action = 'reject' then v_note else reviewer_notes end,
           reviewed_at = now()
     where id = p_id;

  elsif p_source = 'vehicle' then
    select auth_user_id into v_owner from public.vehicle_documents where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.vehicle_documents
       set status = v_status,
           reviewer_notes = case when p_action = 'reject' then v_note else reviewer_notes end,
           reviewed_at = now()
     where id = p_id;

  elsif p_source = 'identity' then
    select user_id into v_owner from public.identity_checks where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.identity_checks
       set status = v_status,
           reject_reason = case when p_action = 'reject'
                                then case when public.identity_reason_text(p_reason) is not null then p_reason else 'other' end
                           end,
           reject_note = case when p_action = 'reject' then v_note else reject_note end,
           reviewed_by = v_me,
           reviewed_at = now()
     where id = p_id
    returning * into c;
    if c.kind = 'id' and p_action = 'approve' then
      update public.profiles
         set id_verified = 'Verified',
             id_expiry_date = coalesce(c.expiry_date, id_expiry_date),
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
          jsonb_build_object('source', p_source, 'doc_id', p_id, 'action', p_action,
                             'reason', p_reason, 'note', v_note));
  return jsonb_build_object('ok', true, 'status', v_status);
end;
$$;
revoke execute on function public.approver_review_document(text, uuid, text, text, text) from public, anon;
grant execute on function public.approver_review_document(text, uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
