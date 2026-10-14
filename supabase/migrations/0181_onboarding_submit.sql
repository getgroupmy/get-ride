-- ============================================================================
-- 0181: partners can submit their application and their vehicles again.
--
-- The apps mark a finished application, and a vehicle sent for review, by
-- setting documents_ok. 0147 made that column the admin's alone, so the
-- final "Submit" of both wizards was refused (PARTNERS_PROTECTED_COLUMN /
-- VEHICLE_PROTECTED_COLUMN:documents_ok) and nobody could apply.
--
-- The owner may now make exactly one change to it: false -> true, on their
-- own row, while it is still waiting for review (unapproved or
-- unapproved-docs). That is "submitted", not "approved": approval is the
-- status column, which stays the admin's. Once a row is approved, rejected,
-- blocked or under a permit status, documents_ok is the admin's again, so a
-- driver can't restore it after an admin clears it. Everything else in the
-- 0147 guards is unchanged. Server-side only: every installed app version
-- submits again as soon as this runs.
-- ============================================================================

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
  return new;
end;
$$;

create or replace function public.vehicle_guard_protected_columns()
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
