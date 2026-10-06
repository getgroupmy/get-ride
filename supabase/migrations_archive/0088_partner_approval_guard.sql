-- ============================================================================
-- 0088 — partners, vehicles and documents: no self-approval; only approved
--        partners claim rides
-- ----------------------------------------------------------------------------
-- Same problem as 0087 had for profiles, on the partner side:
--
--   * `partners self update` / `partners self insert` let a partner write any
--     column on their own row, including `status` ('approved'), `permit`
--     ('verified'), `rating` and `total_rides`. They could also insert their
--     row already approved.
--   * The owner policies on `vehicle` allow the same for a vehicle's `status`
--     and `permit`.
--   * The owner policies on `provider_documents` / `vehicle_documents` let a
--     partner mark their own documents 'Approved', undo a 'Rejected', or push
--     `expiry_date` forward to escape 'Expired'.
--   * `ride_requests claim open` let ANY signed-in user accept an open ride.
--     Nothing on the server checked for a partner row, let alone an approved
--     one.
--   * `partners read` let every signed-in user read every partner's phone,
--     email and IC.
--   * The legacy `vehicles` table (unused by the apps since `vehicle`
--     replaced it) had `true` policies for every command, so anyone, signed
--     out included, could read or rewrite it.
--
-- Fix:
--   1. `caller_is_approved_partner()`: the caller has a partner row with
--      status 'approved' or any 'permit-*' status. This mirrors what the
--      Flutter app already treats as "can drive". Claiming or offering on an
--      open ride now requires it (admins are exempt).
--   2. Guard triggers. They apply only to direct client requests (roles
--      anon/authenticated) from non-admins, so SECURITY DEFINER functions,
--      the service role and admins pass through, as in 0087.
--      - partners: a new row must start 'unapproved' with permit 'none' or
--        'pending', and rating / total_rides 0. On update, `id`,
--        `auth_user_id`, `display_id`, `status`, `permit`, `rating`,
--        `total_rides`, `joined_at` and `created_at` are refused.
--        `documents_ok` stays partner-controlled: it means "all compulsory
--        documents uploaded", which onboarding sets, not "approved".
--      - vehicle: same start state. On update, `id`, `display_id`, `status`,
--        `permit`, `joined_at` and `created_at` are refused. `auth_user_id`
--        and `owner_partner_id` may only go from empty to the caller (or the
--        caller's own partner row): that's how onboarding takes over a
--        vehicle an admin pre-added.
--      - provider_documents / vehicle_documents: a new row must be
--        'Pending Review' with no reviewer fields. On update:
--        - the owner ids are refused;
--        - reviewer fields may only be cleared;
--        - `status` may only move to 'Pending Review';
--        - changing the document itself (file, number, dates, type, issuer)
--          automatically sends it back to 'Pending Review', so a new upload or
--          a new expiry date always needs admin review again.
--        The guard sorts before the existing `*_expiry` triggers, which still
--        mark past-dated documents 'Expired' afterwards.
--   3. `partners` is now readable only by its owner and by admins. Two flows
--      used to read other partners' rows; each gets a narrow SECURITY DEFINER
--      function instead:
--      - `claim_partner_by_phone()` links an admin-created partner row
--        (`auth_user_id` empty) to the caller when its phone matches the
--        caller's verified sign-in phone. The old client-side version could
--        never save the link under the existing update policy anyway.
--      - `partner_ic_for_my_vehicle(partner_id)` returns a vehicle owner's IC
--        only to the owner, a driver assigned to one of that partner's
--        vehicles, or an admin. Vehicle onboarding needs it for its
--        verify-owner step.
--   4. Legacy `vehicles`: admin-only, and no anon grants.
--
-- Guard errors are raised as `<TABLE>_PROTECTED_COLUMN:<column>` (SQLSTATE
-- 42501).
-- ============================================================================

-- ---- 1. Approved-partner check + ride claiming ------------------------------

create or replace function public.caller_is_approved_partner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.partners p
     where p.auth_user_id = auth.uid()
       and (p.status = 'approved' or p.status::text like 'permit-%')
  );
$$;

grant execute on function public.caller_is_approved_partner() to anon, authenticated;

drop policy if exists "ride_requests claim open" on public.ride_requests;
create policy "ride_requests claim open"
  on public.ride_requests for update to public
  using (status = 'open' and auth.uid() is not null)
  with check (
    partner_id = auth.uid()
    and (public.caller_is_approved_partner() or public.caller_is_admin())
  );

-- The policy alone is not enough. Postgres accepts an UPDATE whose new row
-- passes the WITH CHECK of *any* applicable permissive policy, and
-- "ride_requests participant update" checks `partner_id = auth.uid()`, which
-- a claimed row satisfies. So the gate is also enforced by a trigger, which
-- sees every write whichever policy admitted it.
create or replace function public.ride_requests_guard_partner_claim()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.partner_id is not null
     and new.partner_id is distinct from old.partner_id
     and not public.caller_is_approved_partner() then
    raise exception 'RIDE_CLAIM_REQUIRES_APPROVED_PARTNER' using errcode = '42501',
      hint = 'Only partners approved by an administrator can accept or bid on rides.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ride_requests_a_guard_claim on public.ride_requests;
create trigger trg_ride_requests_a_guard_claim
  before update on public.ride_requests
  for each row execute function public.ride_requests_guard_partner_claim();

-- ---- 2a. partners guard -----------------------------------------------------

create or replace function public.partners_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
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
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id', 'auth_user_id', 'display_id', 'status', 'permit', 'rating',
    'total_rides', 'joined_at', 'created_at'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PARTNERS_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_partners_a_guard on public.partners;
create trigger trg_partners_a_guard
  before insert or update on public.partners
  for each row execute function public.partners_guard_protected_columns();

-- ---- 2b. vehicle guard ------------------------------------------------------

create or replace function public.vehicle_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
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
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array['id', 'display_id', 'status', 'permit', 'joined_at', 'created_at'] loop
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

drop trigger if exists trg_vehicle_a_guard on public.vehicle;
create trigger trg_vehicle_a_guard
  before insert or update on public.vehicle
  for each row execute function public.vehicle_guard_protected_columns();

-- ---- 2c. document guards (provider_documents, vehicle_documents) ----------

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
    'insurance_provider_name', 'is_pwd'
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

-- `*_a_guard` sorts before the existing `*_expiry` triggers.
drop trigger if exists provider_documents_a_guard on public.provider_documents;
create trigger provider_documents_a_guard
  before insert or update on public.provider_documents
  for each row execute function public.documents_guard_review_columns();

drop trigger if exists vehicle_documents_a_guard on public.vehicle_documents;
create trigger vehicle_documents_a_guard
  before insert or update on public.vehicle_documents
  for each row execute function public.documents_guard_review_columns();

-- ---- 3. partners: own-or-admin reads + narrow lookups ----------------------

drop policy if exists "partners read" on public.partners;
drop policy if exists "partners self select" on public.partners;
create policy "partners self select"
  on public.partners for select to public
  using (auth_user_id = auth.uid() or public.caller_is_admin());

create or replace function public.claim_partner_by_phone()
returns setof public.partners
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_digits text;
  v_count  bigint;
  v_id     uuid;
begin
  if v_uid is null then
    return;
  end if;

  -- Already linked: return the caller's own row.
  if exists (select 1 from public.partners where auth_user_id = v_uid) then
    return query select * from public.partners where auth_user_id = v_uid limit 1;
    return;
  end if;

  -- Match on the verified sign-in phone, not anything the client sends.
  select regexp_replace(coalesce(u.phone, ''), '\D', '', 'g')
    into v_digits
    from auth.users u
   where u.id = v_uid;
  if v_digits is null or length(v_digits) < 8 then
    return;
  end if;

  -- Link only when exactly one unclaimed row matches.
  select count(*), min(p.id::text)::uuid
    into v_count, v_id
    from public.partners p
   where p.auth_user_id is null
     and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') = v_digits;
  if v_count <> 1 then
    return;
  end if;

  return query
    update public.partners
       set auth_user_id = v_uid
     where id = v_id and auth_user_id is null
    returning *;
end;
$$;

revoke all on function public.claim_partner_by_phone() from public, anon;
grant execute on function public.claim_partner_by_phone() to authenticated;

create or replace function public.partner_ic_for_my_vehicle(p_partner_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.ic
    from public.partners p
   where p.id = p_partner_id
     and (
       public.caller_is_admin()
       or p.auth_user_id = auth.uid()
       or exists (
         select 1
           from public.vehicle v
          where v.owner_partner_id = p_partner_id
            and (
              v.auth_user_id = auth.uid()
              or exists (
                select 1 from public.vehicle_user_assignment a
                 where a.vehicle_id = v.id and a.user_id = auth.uid()
              )
            )
       )
     );
$$;

revoke all on function public.partner_ic_for_my_vehicle(uuid) from public, anon;
grant execute on function public.partner_ic_for_my_vehicle(uuid) to authenticated;

-- ---- 4. Legacy `vehicles`: admin-only --------------------------------------

drop policy if exists "vehicles read" on public.vehicles;
drop policy if exists "vehicles insert" on public.vehicles;
drop policy if exists "vehicles update" on public.vehicles;
drop policy if exists "vehicles delete" on public.vehicles;
drop policy if exists "vehicles admin all" on public.vehicles;
create policy "vehicles admin all"
  on public.vehicles for all to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());
revoke all on public.vehicles from anon;

notify pgrst, 'reload schema';
