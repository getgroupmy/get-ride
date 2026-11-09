-- ============================================================================
-- 0384: My Team — an approver nudges a covered member to upload a pending or
-- missing document with a push notification, and the request is logged so the
-- approver can see how many reminders were sent and when the last one went.
--
--   * document_upload_requests — one row per (member, source, doc_key, vehicle),
--     accumulating sent_count + last_sent_at. Works for a document that has no
--     row yet (a missing type), since it is keyed by the type, not a doc id.
--   * approver_request_document_upload(member, source, doc_key, label, vehicle)
--     — gated like Upload-on-behalf (active approver, covers the member,
--     can_upload). Bumps the counter, sends the member a push, logs it, and
--     returns the new count + timestamp.
--   * approver_document_request_stats(member) — the per-document counters, so
--     the member's Documents tab and the vehicle sheet can show "Requested N×".
--
-- Covers every document source — provider (driver) documents, vehicle
-- documents and identity checks — not only vehicle.
-- ============================================================================

create table if not exists public.document_upload_requests (
  target_user_id uuid        not null,
  source         text        not null check (source in ('partner', 'vehicle', 'identity')),
  doc_key        text        not null,
  vehicle_id     uuid,
  doc_label      text,
  sent_count     int         not null default 0,
  last_sent_at   timestamptz,
  last_sent_by   uuid,
  created_at     timestamptz not null default now()
);

-- One counter per document type for a member (a null vehicle folds to the zero
-- uuid so driver/identity docs share a single slot).
create unique index if not exists document_upload_requests_key
  on public.document_upload_requests (
    target_user_id, source, doc_key,
    coalesce(vehicle_id, '00000000-0000-0000-0000-000000000000'::uuid));

alter table public.document_upload_requests enable row level security;
-- No policies: the table is reached only through the SECURITY DEFINER RPCs
-- below, never by a client directly.

-- An approver asks a covered member to upload a document. Returns the running
-- count and the moment this reminder was sent.
create or replace function public.approver_request_document_upload(
  p_member   uuid,
  p_source   text,
  p_doc_key  text,
  p_label    text default null,
  p_vehicle  uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a        public.approvers;
  v_me     uuid := auth.uid();
  v_source text := lower(btrim(coalesce(p_source, '')));
  v_key    text := btrim(coalesce(p_doc_key, ''));
  v_label  text := nullif(btrim(coalesce(p_label, '')), '');
  v_count  int;
  v_at     timestamptz;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then raise exception 'not_allowed'; end if;
  if p_member is null or v_key = '' then raise exception 'bad_input' using errcode = '22023'; end if;
  if v_source not in ('partner', 'vehicle', 'identity') then
    raise exception 'bad_input' using errcode = '22023';
  end if;
  if not public.approver_covers(p_member) then raise exception 'out_of_scope'; end if;

  insert into public.document_upload_requests
      (target_user_id, source, doc_key, vehicle_id, doc_label, sent_count, last_sent_at, last_sent_by)
    values (p_member, v_source, v_key, p_vehicle, v_label, 1, now(), v_me)
  on conflict (target_user_id, source, doc_key,
               coalesce(vehicle_id, '00000000-0000-0000-0000-000000000000'::uuid))
    do update set sent_count   = public.document_upload_requests.sent_count + 1,
                  last_sent_at = now(),
                  last_sent_by = v_me,
                  doc_label    = coalesce(excluded.doc_label, public.document_upload_requests.doc_label)
  returning sent_count, last_sent_at into v_count, v_at;

  -- Notify the member (best-effort; a push failure never fails the request).
  perform public.approval_push_send(
    p_member,
    jsonb_build_object(
      'title', 'Document needed',
      'body', case when v_label is not null
                   then 'Please upload your ' || v_label || ' to continue.'
                   else 'Please upload a pending document to continue.' end),
    jsonb_build_object('type', 'document_request', 'source', v_source, 'doc_key', v_key));

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.request_document', p_member,
          jsonb_build_object('source', v_source, 'doc_key', v_key,
                             'vehicle_id', p_vehicle, 'count', v_count));

  return jsonb_build_object('ok', true, 'sent_count', v_count, 'last_sent_at', v_at);
end;
$$;
revoke execute on function public.approver_request_document_upload(uuid, text, text, text, uuid) from public, anon;
grant  execute on function public.approver_request_document_upload(uuid, text, text, text, uuid) to authenticated;

-- The reminder counters for a covered member's documents, for the approver UI.
create or replace function public.approver_document_request_stats(p_member uuid)
returns table (source text, doc_key text, vehicle_id uuid, sent_count int, last_sent_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare a public.approvers; v_me uuid := auth.uid();
begin
  if v_me is null then return; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or p_member is null or not public.approver_covers(p_member) then return; end if;

  return query
    select r.source, r.doc_key, r.vehicle_id, r.sent_count, r.last_sent_at
      from public.document_upload_requests r
     where r.target_user_id = p_member;
end;
$$;
revoke execute on function public.approver_document_request_stats(uuid) from public, anon;
grant  execute on function public.approver_document_request_stats(uuid) to authenticated;

notify pgrst, 'reload schema';
