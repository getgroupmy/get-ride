-- ============================================================================
-- 0035_claim_vehicle_owner_fix.sql
--
-- Fix: `claim_vehicle` previously raised `not_assigned` for vehicles a user
-- *owns* (added themselves through vehicle-onboarding) because the check only
-- looked at `vehicle_user_assignment`. Owners never have an explicit row there.
--
-- This migration:
--   1. Updates `claim_vehicle` so an owner (vehicle.auth_user_id = p_user_id)
--      is treated as an implicit active assignee. The exclusivity checks
--      (vehicle_in_use / user_busy) are unchanged.
--   2. Backfills `vehicle_user_assignment` with an `owner` row for every
--      existing vehicle that has an `auth_user_id` but no assignment yet, so
--      future queries that read the assignment table directly also see them.
--
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. claim_vehicle — accept owners as implicit active assignees
-- ---------------------------------------------------------------------------
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

    if not v_is_owner then
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

grant execute on function public.claim_vehicle(uuid, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Backfill owner assignments so the assignment table reflects ownership.
--    Pulls partner_id from the vehicle row (owner_partner_id) when present.
-- ---------------------------------------------------------------------------
insert into public.vehicle_user_assignment (vehicle_id, user_id, partner_id, role, is_active)
select v.id,
       v.auth_user_id,
       v.owner_partner_id,
       'owner',
       true
  from public.vehicle v
 where v.auth_user_id is not null
   and not exists (
     select 1 from public.vehicle_user_assignment a
      where a.vehicle_id = v.id
        and a.user_id    = v.auth_user_id
   );

notify pgrst, 'reload schema';
