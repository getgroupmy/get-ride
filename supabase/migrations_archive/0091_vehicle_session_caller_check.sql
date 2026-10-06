-- ============================================================================
-- 0091 — vehicle-session RPCs: act only on the caller's own session
--        (merged as 0089 alongside two other 0089s, renumbered; the SQL is
--        unchanged, so a database that ran it as 0089 already has it)
-- ----------------------------------------------------------------------------
-- `claim_vehicle`, `release_vehicle` and `touch_vehicle_session` (0031/0035)
-- are SECURITY DEFINER, were granted to anon, and took the user id as a
-- parameter without comparing it to the caller. Anyone holding the public
-- anon key could therefore:
--   * end any driver's session (`release_vehicle(<their id>)`), dropping them
--     off their car mid-shift, or
--   * claim a vehicle on behalf of any assigned user, so the real driver gets
--     `vehicle_in_use` / `user_busy`.
-- User ids are not secret (ride rows, transfer requests, ...), so the
-- parameter on its own proves nothing.
--
-- Fix: each function now refuses a `p_user_id` other than `auth.uid()`
-- unless the caller is an admin (`caller_is_admin()`: admin_access holders,
-- the service role, direct DB sessions), raising `not_authorized` (42501),
-- the same check the wallet RPCs make. Execute moves from anon to
-- authenticated only.
--
-- Also fixed in `claim_vehicle`: 0035's owner fallback did
-- `select true into v_is_owner ...` and then `if not v_is_owner`. When no
-- row matches, v_is_owner is NULL and `not NULL` is not true, so
-- `not_assigned` never fired: any signed-in user could claim any free
-- vehicle for themselves and block its drivers. It now uses
-- `coalesce(v_is_owner, false)`.
--
-- Everything else, including the `not_assigned` / `vehicle_in_use` /
-- `user_busy` exceptions, is unchanged from 0035.
--
-- Clients already pass the signed-in user's own id (Expo
-- `vehicleAssignmentStore.ts`, Flutter `vehicle_assignment_repository.dart`).
-- Legacy local-PIN sessions (anon key, no Supabase auth) now get a
-- permission error, which the Expo store maps to a sign-in prompt.
--
-- Safe to re-run.
-- ============================================================================

create or replace function public.claim_vehicle(
  p_vehicle_id uuid,
  p_user_id    uuid
) returns public.vehicle_active_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment public.vehicle_user_assignment%rowtype;
  v_session    public.vehicle_active_session%rowtype;
  v_partner_id uuid;
  v_is_owner   boolean := false;
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Active explicit assignment?
  select * into v_assignment
    from public.vehicle_user_assignment
   where vehicle_id = p_vehicle_id
     and user_id    = p_user_id
     and is_active  = true
   limit 1;

  if not found then
    -- Owner of the vehicle counts as an implicit active assignee.
    select true into v_is_owner
      from public.vehicle
     where id = p_vehicle_id
       and auth_user_id = p_user_id
     limit 1;

    -- No row leaves v_is_owner NULL, and `not NULL` is not true, so 0035's
    -- `if not v_is_owner` let every caller through.
    if not coalesce(v_is_owner, false) then
      raise exception 'not_assigned'
        using hint = 'User is not an active assignee or owner of this vehicle.';
    end if;
  end if;

  -- Vehicle already in use?
  select * into v_session
    from public.vehicle_active_session
   where vehicle_id = p_vehicle_id
   limit 1;

  if found then
    if v_session.user_id = p_user_id then
      update public.vehicle_active_session
         set last_seen_at = now(),
             status       = 'online'
       where id = v_session.id
      returning * into v_session;
      return v_session;
    end if;
    raise exception 'vehicle_in_use'
      using hint = 'Vehicle is currently used by another user.';
  end if;

  -- User already driving something else?
  if exists (
    select 1 from public.vehicle_active_session where user_id = p_user_id
  ) then
    raise exception 'user_busy'
      using hint = 'User is already in an active session on another vehicle.';
  end if;

  v_partner_id := v_assignment.partner_id;

  insert into public.vehicle_active_session (vehicle_id, user_id, partner_id)
       values (p_vehicle_id, p_user_id, v_partner_id)
    returning * into v_session;

  return v_session;
end;
$$;

-- Release whatever vehicle the user is currently driving (sets vehicle offline).
create or replace function public.release_vehicle(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  delete from public.vehicle_active_session where user_id = p_user_id;
end;
$$;

-- Heartbeat — call periodically while online to keep the session fresh.
create or replace function public.touch_vehicle_session(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.vehicle_active_session
     set last_seen_at = now()
   where user_id = p_user_id;
end;
$$;

-- Functions are executable by PUBLIC by default, so revoking anon alone
-- would leave the anon role its access through PUBLIC.
revoke execute on function public.claim_vehicle(uuid, uuid)       from public, anon;
revoke execute on function public.release_vehicle(uuid)           from public, anon;
revoke execute on function public.touch_vehicle_session(uuid)     from public, anon;
grant  execute on function public.claim_vehicle(uuid, uuid)       to authenticated;
grant  execute on function public.release_vehicle(uuid)           to authenticated;
grant  execute on function public.touch_vehicle_session(uuid)     to authenticated;

notify pgrst, 'reload schema';
