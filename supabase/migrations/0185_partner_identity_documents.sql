-- ============================================================================
-- 0185: the reviewed driver is the driver, and documents are filed only on
-- your own account (audit 14 Oct 2026).
--
--   1. An approved partner could change their name, phone, IC and photo at
--      will, so the person riders saw (and the person on an account lent to
--      someone else) was never reviewed. Once approved, those four change
--      through an administrator. (0182 already fills the card on each ride
--      from this record, so riders see the reviewed photo and name.)
--   2. A document could be inserted for any partner or vehicle: the insert
--      rule accepted any row stamped with the caller's own auth_user_id. It
--      now has to belong to the caller's own partner record or a vehicle
--      they own or are assigned to.
--   3. Rewriting the AI check's verdict on a reviewed document sends it back
--      to Pending Review, like replacing the file does.
-- ============================================================================

-- ---- 1. The approved partner's identity ---------------------------------------------
create or replace function public.partners_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
  v_submit boolean;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new partner starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'PARTNERS_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    if coalesce(new.rating, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:rating' using errcode = '42501';
    end if;
    if coalesce(new.total_rides, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:total_rides' using errcode = '42501';
    end if;
    if new.status_note is not null or new.resubmitted_at is not null then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status_note' using errcode = '42501';
    end if;
    if coalesce((to_jsonb(new) ->> 'documents_ok')::boolean, false) then
      raise exception 'PARTNERS_PROTECTED_COLUMN:documents_ok' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);

  -- The applicant's own "Submit": documents_ok false -> true while waiting.
  v_submit := coalesce((v_old ->> 'documents_ok')::boolean, false) = false
    and coalesce((v_new ->> 'documents_ok')::boolean, false) = true
    and old.status::text in ('unapproved', 'unapproved-docs')
    and old.auth_user_id is not null
    and old.auth_user_id = auth.uid();

  foreach v_col in array array[
    'id', 'auth_user_id', 'display_id', 'status', 'permit', 'rating',
    'total_rides', 'joined_at', 'created_at', 'status_note', 'resubmitted_at', 'documents_ok'
  ] loop
    continue when v_col = 'documents_ok' and v_submit;
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PARTNERS_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;

  -- Once approved, the person riders see is the person who was reviewed:
  -- their name, phone, IC and photo change through an administrator.
  if old.status::text = 'approved' or old.status::text like 'permit-%' then
    foreach v_col in array array['name', 'phone', 'ic', 'avatar_url'] loop
      if v_old -> v_col is distinct from v_new -> v_col then
        raise exception 'PARTNERS_PROTECTED_COLUMN:%', v_col using errcode = '42501',
          hint = 'An approved partner''s name, phone, IC and photo are changed by support.';
      end if;
    end loop;
  end if;
  return new;
end;
$$;

-- ---- 2. Documents are filed on your own account ------------------------------------------
drop policy if exists "provider_documents own insert" on public.provider_documents;
create policy "provider_documents own insert" on public.provider_documents
  for insert to public with check (
    (select public.caller_is_admin())
    or (coalesce(auth_user_id, (select auth.uid())) = (select auth.uid())
        and case
              when partner_id is null then auth_user_id = (select auth.uid())
              else exists (select 1 from public.partners p
                            where p.id = provider_documents.partner_id and p.auth_user_id = (select auth.uid()))
            end)
  );

drop policy if exists "vehicle_documents own insert" on public.vehicle_documents;
create policy "vehicle_documents own insert" on public.vehicle_documents
  for insert to public with check (
    (select public.caller_is_admin())
    or (coalesce(auth_user_id, (select auth.uid())) = (select auth.uid())
        and (partner_id is not null or vehicle_id is not null or auth_user_id = (select auth.uid()))
        and (partner_id is null
             or exists (select 1 from public.partners p
                         where p.id = vehicle_documents.partner_id and p.auth_user_id = (select auth.uid())))
        and (vehicle_id is null
             or exists (select 1 from public.vehicle v
                         where v.id = vehicle_documents.vehicle_id
                           and (v.auth_user_id = (select auth.uid())
                                or exists (select 1 from public.partners p
                                            where p.id = v.owner_partner_id and p.auth_user_id = (select auth.uid()))
                                or exists (select 1 from public.vehicle_user_assignment a
                                            where a.vehicle_id = v.id and a.user_id = (select auth.uid()))))))
  );

-- ---- 3. The AI's verdict is reviewed like the file ------------------------------------------
create or replace function public.documents_guard_review_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
  v_tag text := upper(tg_table_name) || '_PROTECTED_COLUMN';
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'Pending Review' then
      raise exception '%:status', v_tag using errcode = '42501',
        hint = 'A new document starts in Pending Review; an administrator reviews it.';
    end if;
    if new.reviewer_notes is not null or new.reviewed_at is not null then
      raise exception '%:reviewer_notes', v_tag using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);

  -- Ownership never moves from the client.
  foreach v_col in array array['id', 'auth_user_id', 'partner_id', 'vehicle_id'] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception '%:%', v_tag, v_col using errcode = '42501';
    end if;
  end loop;

  -- Reviewer fields belong to the admin; the owner may only clear them.
  if new.reviewer_notes is distinct from old.reviewer_notes and new.reviewer_notes is not null then
    raise exception '%:reviewer_notes', v_tag using errcode = '42501';
  end if;
  if new.reviewed_at is distinct from old.reviewed_at and new.reviewed_at is not null then
    raise exception '%:reviewed_at', v_tag using errcode = '42501';
  end if;

  -- The owner may only send a document (back) to review, never decide it.
  if new.status is distinct from old.status and new.status is distinct from 'Pending Review' then
    raise exception '%:status', v_tag using errcode = '42501',
      hint = 'Only an administrator can approve or reject a document.';
  end if;

  -- Changing the document itself always needs a fresh review.
  foreach v_col in array array[
    'file_url', 'file_url_back', 'document_number', 'start_date', 'expiry_date',
    'doc_id', 'doc_name', 'issuance_country', 'insurance_provider_id',
    'insurance_provider_name', 'is_pwd',
    -- The AI's verdict is advisory and came from the client: rewriting it
    -- is a change to review, never a way to keep an approval.
    'ai_verification', 'ai_verified', 'detected_document_name'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      new.status := 'Pending Review';
      new.reviewer_notes := null;
      new.reviewed_at := null;
      exit;
    end if;
  end loop;
  return new;
end;
$$;
