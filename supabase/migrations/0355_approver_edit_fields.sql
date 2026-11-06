-- ============================================================================
-- 0355: Approver — show and correct a document's captured fields.
--
-- A required document can be configured (required_document settings) to make
-- the owner type a document number, a start date and/or an expiry date at
-- upload (requireDocumentNumber / requireStartDate / requireExpiryDate). Those
-- values are stored on the row (provider_documents / vehicle_documents) but the
-- approver inbox never surfaced them, so an approver could not see — let alone
-- fix — a wrong or missing expiry date before approving.
--
-- This adds two things, both re-using the Phase-1c scope rule (approver_covers)
-- so the app is never trusted:
--   * approver_pending_documents() now also returns the three captured values
--     and, for each, whether the document type requires it (resolved from the
--     required_document settings entry whose id is the row's doc_id).
--   * approver_edit_document(...) lets an approver with can_upload correct those
--     fields on a Pending Review document in their scope. Editing is the same
--     "correct this document" capability as replacing the image (0353), so it
--     reuses can_upload rather than a new permission. It writes only the fields
--     the document type actually requires, never clears a required field to
--     null, and refuses a past expiry date (an expired document can't be
--     accepted — the same rule the upload form enforces). Image bytes and the
--     review decision are untouched; the document stays Pending Review.
--
-- identity_checks is out of scope here: its one date lives on profiles
-- (id_expiry_date) with a different shape, so the edit RPC refuses 'identity'.
-- ============================================================================

-- ---- Whether a required_document setting flag is on ------------------------------------------------
-- The flags are stored in settings_entries.values as JSON booleans or strings
-- ("true"/"1"/"yes"); read them tolerantly, the way the app's _truthy does.
create or replace function public.approver_doc_requires(p_doc_id text, p_flag text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select lower(btrim(coalesce(se.values ->> p_flag, '')))
            in ('true', 't', '1', 'yes', 'y')
       from public.settings_entries se
      where se.category = 'required_document'
        and se.id::text = p_doc_id
      limit 1),
    false);
$$;
revoke execute on function public.approver_doc_requires(text, text) from public, anon;
grant execute on function public.approver_doc_requires(text, text) to authenticated;

-- ---- The caller's pending-documents inbox (now with captured fields) -------------------------------
-- The return type gains columns, so the function is dropped and recreated.
drop function if exists public.approver_pending_documents();
create function public.approver_pending_documents()
returns table (
  source          text,          -- 'partner' | 'vehicle' | 'identity'
  doc_pk          uuid,          -- the document row's id (for later actions)
  owner_id        uuid,
  owner_name      text,
  owner_phone     text,
  doc_key         text,          -- doc_id (partner/vehicle) or doc_type/kind (identity)
  doc_label       text,
  file_url        text,
  file_url_back   text,
  status          text,
  submitted_at    timestamptz,
  document_number text,          -- the captured fields, for review
  start_date      date,
  expiry_date     date,
  requires_number boolean,       -- whether this document type asks for each
  requires_start  boolean,
  requires_expiry boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a    public.approvers;
  v_me uuid := auth.uid();
begin
  if v_me is null then
    return;
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then
    return;
  end if;

  return query
  -- Partner registration documents.
  select 'partner'::text, d.id, d.auth_user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         d.doc_id, coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
         d.file_url, d.file_url_back, d.status, null::timestamptz,
         d.document_number, d.start_date, d.expiry_date,
         public.approver_doc_requires(d.doc_id, 'requireDocumentNumber'),
         public.approver_doc_requires(d.doc_id, 'requireStartDate'),
         public.approver_doc_requires(d.doc_id, 'requireExpiryDate')
    from public.provider_documents d
    join public.profiles p on p.id = d.auth_user_id
   where d.status = 'Pending Review'
     and (a.doc_types = '{}'::text[] or d.doc_id = any(a.doc_types))
     and public.approver_covers(d.auth_user_id)
  union all
  -- Vehicle documents & permits.
  select 'vehicle'::text, d.id, d.auth_user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         d.doc_id, coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
         d.file_url, d.file_url_back, d.status, null::timestamptz,
         d.document_number, d.start_date, d.expiry_date,
         public.approver_doc_requires(d.doc_id, 'requireDocumentNumber'),
         public.approver_doc_requires(d.doc_id, 'requireStartDate'),
         public.approver_doc_requires(d.doc_id, 'requireExpiryDate')
    from public.vehicle_documents d
    join public.profiles p on p.id = d.auth_user_id
   where d.status = 'Pending Review'
     and (a.doc_types = '{}'::text[] or d.doc_id = any(a.doc_types))
     and public.approver_covers(d.auth_user_id)
  union all
  -- User ID / selfie documents. Its expiry is shown but not editable here.
  select 'identity'::text, c.id, c.user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         coalesce(c.doc_type, c.kind),
         case when c.kind = 'selfie'    then 'Selfie'
              when c.doc_type = 'mykad' then 'MyKad'
              when c.doc_type = 'passport' then 'Passport'
              else coalesce(c.doc_type, c.kind, 'ID') end,
         c.file_url, c.file_url_back, c.status, c.created_at,
         null::text, null::date, c.expiry_date,
         false, false, false
    from public.identity_checks c
    join public.profiles p on p.id = c.user_id
   where c.status = 'Pending Review'
     and (a.doc_types = '{}'::text[] or coalesce(c.doc_type, c.kind) = any(a.doc_types))
     and public.approver_covers(c.user_id)
  order by 4, 1;
end;
$$;
revoke execute on function public.approver_pending_documents() from public, anon;
grant execute on function public.approver_pending_documents() to authenticated;

-- ---- Correct a document's captured fields ---------------------------------------------------------
-- can_upload, in scope, Pending Review. Writes only the fields the document
-- type requires; a required field may not be blanked, and an expiry in the past
-- is refused. The image and the review decision are left alone.
create or replace function public.approver_edit_document(
  p_source text, p_id uuid,
  p_document_number text default null,
  p_start date default null,
  p_expiry date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a         public.approvers;
  v_me      uuid := auth.uid();
  v_owner   uuid;
  v_doc_id  text;
  v_number  text := nullif(btrim(coalesce(p_document_number, '')), '');
  r_number  boolean;
  r_start   boolean;
  r_expiry  boolean;
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
    select auth_user_id, doc_id into v_owner, v_doc_id
      from public.provider_documents where id = p_id and status = 'Pending Review';
  elsif p_source = 'vehicle' then
    select auth_user_id, doc_id into v_owner, v_doc_id
      from public.vehicle_documents where id = p_id and status = 'Pending Review';
  else
    -- identity's dates live on profiles with a different shape; not editable here.
    raise exception 'APPROVER_BAD_SOURCE' using errcode = '22023';
  end if;

  if v_owner is null then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(v_owner) then raise exception 'not_authorized' using errcode = '42501'; end if;

  r_number := public.approver_doc_requires(v_doc_id, 'requireDocumentNumber');
  r_start  := public.approver_doc_requires(v_doc_id, 'requireStartDate');
  r_expiry := public.approver_doc_requires(v_doc_id, 'requireExpiryDate');

  if not (r_number or r_start or r_expiry) then
    raise exception 'APPROVER_NO_FIELDS' using errcode = '22023',
      hint = 'This document type has no captured fields to correct.';
  end if;

  -- A required field may not be left blank, and an expired document can't be
  -- accepted (the same rule the upload form enforces).
  if r_number and v_number is null then
    raise exception 'APPROVER_FIELD' using errcode = '22023', hint = 'Enter the document number.';
  end if;
  if r_start and p_start is null then
    raise exception 'APPROVER_FIELD' using errcode = '22023', hint = 'Enter the start date.';
  end if;
  if r_expiry and p_expiry is null then
    raise exception 'APPROVER_FIELD' using errcode = '22023', hint = 'Enter the expiry date.';
  end if;
  if r_expiry and p_expiry < current_date then
    raise exception 'APPROVER_EXPIRED' using errcode = '22023',
      hint = 'That expiry date is in the past. Correct it, or ask for the renewed document.';
  end if;

  if p_source = 'partner' then
    update public.provider_documents
       set document_number = case when r_number then v_number  else document_number end,
           start_date      = case when r_start  then p_start   else start_date end,
           expiry_date     = case when r_expiry then p_expiry  else expiry_date end
     where id = p_id;
  else
    update public.vehicle_documents
       set document_number = case when r_number then v_number  else document_number end,
           start_date      = case when r_start  then p_start   else start_date end,
           expiry_date     = case when r_expiry then p_expiry  else expiry_date end
     where id = p_id;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.edit', v_owner,
          jsonb_build_object('source', p_source, 'doc_id', p_id,
                             'document_number', case when r_number then v_number end,
                             'start_date', case when r_start then p_start end,
                             'expiry_date', case when r_expiry then p_expiry end));
  return jsonb_build_object('ok', true,
                            'document_number', case when r_number then v_number end,
                            'start_date', case when r_start then p_start end,
                            'expiry_date', case when r_expiry then p_expiry end);
end;
$$;
revoke execute on function public.approver_edit_document(text, uuid, text, date, date) from public, anon;
grant execute on function public.approver_edit_document(text, uuid, text, date, date) to authenticated;

notify pgrst, 'reload schema';
