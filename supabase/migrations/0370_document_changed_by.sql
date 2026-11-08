-- ============================================================================
-- 0370: "Changed by" attribution on driver & vehicle documents.
--
-- identity_checks already records reviewed_by, so the rich document sheet (0365)
-- can show who last changed an ID. Driver (provider_documents) and vehicle
-- (vehicle_documents) documents had no such column, so the Documents tab and
-- the detail sheet could not show "Changed by" for them.
--
--   • add reviewed_by to both tables (nullable; only set from now on),
--   • set it in approver_review_document on approve / reject,
--   • expose per-document meta (changed-by name, insurance provider, PWD flag,
--     uploaded / reviewed dates) through a new side read so the Documents tab
--     can show it without changing the shared approver_owner_documents shape.
--
-- All additive — ADD COLUMN and CREATE OR REPLACE / CREATE only, no DROP.
-- ============================================================================

alter table public.provider_documents add column if not exists reviewed_by uuid;
alter table public.vehicle_documents  add column if not exists reviewed_by uuid;

-- The review RPC (0351) now stamps who reviewed partner & vehicle documents.
create or replace function public.approver_review_document(p_source text, p_id uuid, p_action text, p_reason text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v_status text;
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), ''); c public.identity_checks; v_what text;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_approve then raise exception 'not_authorized' using errcode = '42501'; end if;
  if p_action not in ('approve', 'reject') then raise exception 'APPROVER_BAD_ACTION' using errcode = '22023'; end if;
  v_status := case when p_action = 'approve' then 'Approved' else 'Rejected' end;
  if p_action = 'reject' and v_note is null then
    raise exception 'APPROVER_REASON' using errcode = '22023', hint = 'Add a reason when rejecting.';
  end if;

  if p_source = 'partner' then
    select auth_user_id into v_owner from public.provider_documents where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.provider_documents
       set status = v_status, reviewer_notes = case when p_action = 'reject' then v_note else reviewer_notes end,
           reviewed_by = v_me, reviewed_at = now() where id = p_id;
  elsif p_source = 'vehicle' then
    select auth_user_id into v_owner from public.vehicle_documents where id = p_id and status = 'Pending Review';
    if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
    if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;
    update public.vehicle_documents
       set status = v_status, reviewer_notes = case when p_action = 'reject' then v_note else reviewer_notes end,
           reviewed_by = v_me, reviewed_at = now() where id = p_id;
  elsif p_source = 'identity' then
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
          jsonb_build_object('source', p_source, 'doc_id', p_id, 'action', p_action, 'reason', p_reason, 'note', v_note));
  return jsonb_build_object('ok', true, 'status', v_status);
end;
$function$;
revoke execute on function public.approver_review_document(text, uuid, text, text, text) from public, anon;
grant execute on function public.approver_review_document(text, uuid, text, text, text) to authenticated;

-- Per-document meta for one covered member's Documents tab, keyed by the
-- document id (string): who changed it, the insurance provider, the PWD flag,
-- and the uploaded / reviewed timestamps. A side read, so the shared
-- approver_owner_documents (0357) shape is unchanged. Guarded by approver_covers.
create or replace function public.approver_owner_document_meta(p_owner uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := '{}'::jsonb;
begin
  if auth.uid() is null or p_owner is null or not public.approver_covers(p_owner) then
    return v;
  end if;

  select coalesce(jsonb_object_agg(k, meta), '{}'::jsonb) into v from (
    select d.id::text as k, jsonb_build_object(
             'changed_by', nullif(btrim(rp.name), ''),
             'provider', nullif(btrim(d.insurance_provider_name), ''),
             'is_pwd', d.is_pwd,
             'uploaded_at', d.uploaded_at,
             'reviewed_at', d.reviewed_at) as meta
      from public.provider_documents d
      left join public.profiles rp on rp.id = d.reviewed_by
     where d.auth_user_id = p_owner
    union all
    select d.id::text, jsonb_build_object(
             'changed_by', nullif(btrim(rp.name), ''),
             'provider', nullif(btrim(d.insurance_provider_name), ''),
             'is_pwd', null,
             'uploaded_at', d.uploaded_at,
             'reviewed_at', d.reviewed_at)
      from public.vehicle_documents d
      left join public.profiles rp on rp.id = d.reviewed_by
     where d.auth_user_id = p_owner
    union all
    select c.id::text, jsonb_build_object(
             'changed_by', nullif(btrim(rp.name), ''),
             'provider', null, 'is_pwd', null,
             'uploaded_at', c.created_at,
             'reviewed_at', c.reviewed_at)
      from public.identity_checks c
      left join public.profiles rp on rp.id = c.reviewed_by
     where c.user_id = p_owner and c.status is not null
  ) q;

  return v;
end;
$$;
revoke execute on function public.approver_owner_document_meta(uuid) from public, anon;
grant execute on function public.approver_owner_document_meta(uuid) to authenticated;

notify pgrst, 'reload schema';
