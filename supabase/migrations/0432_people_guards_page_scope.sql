-- ============================================================================
-- 0432 — Who may change the protected columns of a partner row.
--
-- A partner row (public.partners) has columns the apps do not write. Through
-- the API with the apps' roles (anon, authenticated) they are changed by the
-- back office, and by nobody else:
--
--   * the row's id, the account it belongs to (auth_user_id), its display id,
--     status and status note, permit, rating, trip count, the dates it joined
--     and was made, when it was sent in again, and whether its documents are
--     in (0147, 0118, 0181);
--   * the name, phone, IC and photo that were reviewed, once the partner is
--     approved (0185);
--   * the phone number at any time (0277), the date the driving licence was
--     first issued (0308) and the My Ride code (0160, 0287).
--
-- The back office, for a table, is an admin who may edit that table: the test
-- the table's own admin policies make, public.caller_admin_can_write('<table>')
-- (0223). For a partner row those are the "partners admin insert" and
-- "partners admin update" policies: a full admin, or an EDIT grant on a page
-- that writes partners. Everybody else is held to the rules on every row they
-- can reach, their own included.
--
-- The same holds for what is reviewed with a partner:
--
--   * public.profiles: the columns the server keeps (0097), the rider's
--     rating and offer pause (0269), an approved partner's name, IC and photo
--     (0277) and the gender on a verified ID (0310) are changed by an admin
--     who may edit profiles.
--   * public.vehicle: its id, display id, status, permit, dates, whether its
--     documents are in, and who owns it (0147, 0181) are changed by an admin
--     who may edit vehicles.
--   * public.provider_documents and public.vehicle_documents: a document's
--     review (its status, the reviewer's notes, when it was reviewed) and
--     whose it is (0185) are changed by an admin who may edit that table.
--
-- As before:
--   * The server's own writes are not checked: the service role, migrations,
--     cron, the SQL editor, and functions that run as their owner.
--   * What a signed-in user does with their own rows: an applicant fills in
--     and submits their application, a vehicle's owner submits it, and the
--     owner of a document replaces it (which sends it back to review).
--   * The rules themselves. Each function below is its latest definition (the
--     migration is named above it) with that one test changed. Its triggers,
--     owner and grants are untouched. Every name in the bodies was already
--     written in full, so each now runs with an empty search_path.
--
-- supabase/tests/people_guards_page_scope_0432.sql covers it.
-- ============================================================================

-- ---- 1. public.partners: an admin who may edit partners -------------------------------------------

-- As 0185.
create or replace function public.partners_guard_protected_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
  v_submit boolean;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('partners') then
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

-- As 0277: the phone number, approved or not.
create or replace function public.partners_guard_phone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('partners') then
    return new;
  end if;
  if new.phone is distinct from old.phone then
    raise exception 'PARTNERS_PROTECTED_COLUMN:phone' using errcode = '42501',
      hint = 'The phone number is changed in Account settings, with an SMS check.';
  end if;
  return new;
end;
$$;

-- As 0308: when the driving licence was first issued.
create or replace function public.partners_guard_driving_since()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('partners') then
    return new;
  end if;
  if (tg_op = 'INSERT' and new.driving_since is not null)
     or (tg_op = 'UPDATE' and new.driving_since is distinct from old.driving_since) then
    raise exception 'PARTNERS_PROTECTED_COLUMN:driving_since' using errcode = '42501',
      hint = 'Set it in City to City, or ask an administrator.';
  end if;
  return new;
end;
$$;

-- As 0287: the My Ride code is the server's; the back office may set one.
create or replace function public.partners_my_ride_code_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('partners') then
    if tg_op = 'INSERT' then
      new.my_ride_code := public.partner_new_my_ride_code();
    else
      new.my_ride_code := old.my_ride_code;
    end if;
  end if;
  if new.my_ride_code is null then
    new.my_ride_code := coalesce(case when tg_op = 'UPDATE' then old.my_ride_code end, public.partner_new_my_ride_code());
  else
    new.my_ride_code := upper(btrim(new.my_ride_code));
  end if;
  return new;
end;
$$;

-- ---- 2. public.profiles: an admin who may edit profiles -------------------------------------------

-- As 0097.
create or replace function public.profiles_guard_protected_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  -- Only direct client requests are restricted. SECURITY DEFINER functions
  -- and server-side sessions (setup scripts, the service role's own
  -- connection role) run under other roles and pass through.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if public.caller_admin_can_write('profiles') then
    return new;
  end if;

  -- jsonb comparison: a column missing on an older schema reads as null on
  -- both sides, so the guard stays safe to apply anywhere.
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id',
    'phone',
    'status',
    'profile_status',
    'id_verified',
    'id_expiry_date',
    'documents_ok',
    'total_rides',
    'display_id',
    'referral_code',
    'device_count',
    'joined_at',
    'created_at',
    'pin_hash',
    'pin_failed_attempts',
    'pin_locked_until',
    'mcash_wallet_id',
    'mcash_ekyc_status',
    'mcash_customer_status'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PROFILE_PROTECTED_COLUMN:%', v_col
        using errcode = '42501',
              hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$$;

-- As 0277: an approved partner's name, IC and photo, on the profile as on the
-- partner row.
create or replace function public.profiles_guard_partner_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_col text;
  v_old jsonb;
  v_new jsonb;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('profiles') then
    return new;
  end if;
  if not exists (
    select 1 from public.partners pa
     where pa.auth_user_id = new.id
       and (pa.status::text = 'approved' or pa.status::text like 'permit-%')
  ) then
    return new;
  end if;
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array['name', 'ic', 'avatar_url'] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PROFILE_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'An approved partner''s name, IC and photo are changed by support.';
    end if;
  end loop;
  return new;
end;
$$;

-- As 0269: the rider's rating and offer pause.
create or replace function public.profiles_guard_city_ride()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('profiles') then
    return new;
  end if;
  if (new.rider_rating, new.rider_ratings_count, new.offers_paused_until)
     is distinct from (old.rider_rating, old.rider_ratings_count, old.offers_paused_until) then
    raise exception 'PROFILE_PROTECTED_COLUMN:rider_rating' using errcode = '42501',
      hint = 'This field can only be changed by an administrator or by the server.';
  end if;
  return new;
end;
$$;

-- As 0310: the gender on a verified ID, or of an approved partner.
create or replace function public.profiles_guard_verified_gender()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('profiles') then
    return new;
  end if;
  if new.gender is distinct from old.gender
     and (coalesce(old.id_verified::text, '') = 'Verified'
          or exists (select 1 from public.partners pa
                      where pa.auth_user_id = new.id
                        and (pa.status::text = 'approved' or pa.status::text like 'permit-%'))) then
    raise exception 'PROFILE_PROTECTED_COLUMN:gender' using errcode = '42501',
      hint = 'Your ID is verified, so support changes your gender.';
  end if;
  return new;
end;
$$;

-- ---- 3. public.vehicle: an admin who may edit vehicles ---------------------------------------------

-- As 0181.
create or replace function public.vehicle_guard_protected_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
  v_submit boolean;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('vehicle') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'VEHICLE_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new vehicle starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'VEHICLE_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    if coalesce((to_jsonb(new) ->> 'documents_ok')::boolean, false) then
      raise exception 'VEHICLE_PROTECTED_COLUMN:documents_ok' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);

  -- The owner's "Submit for review": documents_ok false -> true while waiting.
  -- Only the owner (not a driver merely assigned to the car).
  v_submit := coalesce((v_old ->> 'documents_ok')::boolean, false) = false
    and coalesce((v_new ->> 'documents_ok')::boolean, false) = true
    and old.status::text in ('unapproved', 'unapproved-docs')
    and (
      (old.auth_user_id is not null and old.auth_user_id = auth.uid())
      or exists (
        select 1 from public.partners p
         where p.id = old.owner_partner_id and p.auth_user_id = auth.uid()
      )
    );

  foreach v_col in array array['id', 'display_id', 'status', 'permit', 'joined_at', 'created_at', 'documents_ok'] loop
    continue when v_col = 'documents_ok' and v_submit;
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'VEHICLE_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;

  -- Ownership may only be taken over while unset, and only by the caller.
  if new.auth_user_id is distinct from old.auth_user_id
     and not (old.auth_user_id is null and new.auth_user_id = auth.uid()) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:auth_user_id' using errcode = '42501';
  end if;
  if new.owner_partner_id is distinct from old.owner_partner_id
     and not (
       old.owner_partner_id is null
       and exists (
         select 1 from public.partners p
          where p.id = new.owner_partner_id and p.auth_user_id = auth.uid()
       )
     ) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:owner_partner_id' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- ---- 4. Documents: an admin who may edit the table the document is in ------------------------------

-- As 0185. One function for both tables (provider_documents_a_guard,
-- vehicle_documents_a_guard): it asks about the table it is running on.
create or replace function public.documents_guard_review_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
  v_tag text := upper(tg_table_name) || '_PROTECTED_COLUMN';
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write(tg_table_name::text) then
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

notify pgrst, 'reload schema';
