-- ============================================================================
-- 0376: Vehicle tab — Approve / Decline / Revoke access + Assign by plate.
--
-- The Vehicle tab's "Allowed to use" cards gain their own actions (the mockup):
-- a pending access request can be approved or declined, an active one revoked,
-- and a dashed "Assign / approve another vehicle" finds a vehicle by plate and
-- grants this member access to it.
--
--   * approver_member_vehicles — the allowed list now carries assignment_id so
--     the card can act on the exact assignment (and access_approval, already
--     present, drives the Pending badge).
--   * approver_set_vehicle_access — now also accepts 'decline' (mark the pending
--     request declined and inactive); approve/revoke unchanged.
--   * approver_find_vehicle_by_plate(plate) — look a vehicle up by its plate
--     (normalised), returning its facts only when the approver covers the
--     owner, so a plate probe can't read a car outside scope. The grant itself
--     reuses approver_assign_vehicle_driver (0369).
--
-- Scope/grant unchanged: auth.uid() + approver_covers + can_manage_vehicle on
-- the writes. All CREATE OR REPLACE / new function, so no DROP.
-- ============================================================================

-- ---- The member's vehicles: add assignment_id to the allowed list ------------
create or replace function public.approver_member_vehicles(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_registered jsonb;
  v_allowed    jsonb;
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;

  select coalesce(jsonb_agg(x order by x->>'plate'), '[]'::jsonb) into v_registered
    from (
      select jsonb_build_object(
               'id', v.id, 'display_id', v.display_id, 'plate', v.plate,
               'make', v.make, 'model', v.model, 'year', v.year, 'color', v.color,
               'status', v.status, 'owner_self', true,
               'owner_name', coalesce(nullif(btrim(v.owner_name), ''), 'Self'),
               'registered_at', coalesce(v.joined_at, v.created_at)) as x
        from public.vehicle v
       where v.auth_user_id = p_member
    ) q;

  -- Allowed to use: assigned to drive someone else's car. Includes both active
  -- assignments and pending requests so the card can show and act on either.
  select coalesce(jsonb_agg(x order by x->>'plate'), '[]'::jsonb) into v_allowed
    from (
      select jsonb_build_object(
               'id', v.id, 'display_id', v.display_id, 'plate', v.plate,
               'make', v.make, 'model', v.model, 'year', v.year, 'color', v.color,
               'status', v.status, 'owner_self', false,
               'assignment_id', a.id,
               'owner_name', coalesce(nullif(btrim(v.owner_name), ''),
                                      nullif(btrim(op.name), '')),
               'owner_ic', coalesce(nullif(btrim(v.owner_ic), ''), op.ic),
               'access_approval', a.approval, 'access_active', a.is_active,
               'assigned_at', a.assigned_at) as x
        from public.vehicle_user_assignment a
        join public.vehicle v on v.id = a.vehicle_id
        left join public.profiles op on op.id = v.auth_user_id
       where a.user_id = p_member
         and (a.is_active or a.approval in ('pending', 'requested'))
         and v.auth_user_id is distinct from p_member
    ) q;

  return jsonb_build_object('registered', v_registered, 'allowed', v_allowed);
end;
$$;
revoke execute on function public.approver_member_vehicles(uuid) from public, anon;
grant execute on function public.approver_member_vehicles(uuid) to authenticated;

-- ---- Approve / revoke / decline a driver's access ----------------------------
create or replace function public.approver_set_vehicle_access(p_assignment uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  asg     public.vehicle_user_assignment;
  v_owner uuid;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_manage_vehicle then
    raise exception 'not_allowed';
  end if;
  if p_action not in ('approve', 'revoke', 'decline') then
    raise exception 'bad_action' using errcode = '22023';
  end if;
  select * into asg from public.vehicle_user_assignment where id = p_assignment;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  select auth_user_id into v_owner from public.vehicle where id = asg.vehicle_id;
  if v_owner is null or not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;

  if p_action = 'approve' then
    update public.vehicle_user_assignment
       set approval = 'approved', is_active = true, updated_at = now()
     where id = p_assignment;
  elsif p_action = 'decline' then
    update public.vehicle_user_assignment
       set approval = 'declined', is_active = false, updated_at = now()
     where id = p_assignment;
  else
    update public.vehicle_user_assignment
       set is_active = false, updated_at = now()
     where id = p_assignment;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.vehicle_access', asg.user_id,
          jsonb_build_object('assignment', p_assignment, 'vehicle', asg.vehicle_id, 'action', p_action));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_set_vehicle_access(uuid, text) from public, anon;
grant execute on function public.approver_set_vehicle_access(uuid, text) to authenticated;

-- ---- Find a vehicle by plate (for Assign another vehicle) ---------------------
create or replace function public.approver_find_vehicle_by_plate(p_plate text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a      public.approvers;
  v_me   uuid := auth.uid();
  v      public.vehicle;
  v_norm text;
begin
  if v_me is null then return null; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_manage_vehicle then
    raise exception 'not_allowed';
  end if;

  v_norm := upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_norm = '' then
    return jsonb_build_object('found', false);
  end if;

  select * into v from public.vehicle
   where upper(regexp_replace(coalesce(plate, ''), '[^A-Za-z0-9]', '', 'g')) = v_norm
   order by updated_at desc nulls last
   limit 1;
  if not found then
    return jsonb_build_object('found', false);
  end if;

  -- A plate probe must not read a car whose owner the approver doesn't cover.
  if v.auth_user_id is null or not public.approver_covers(v.auth_user_id) then
    return jsonb_build_object('found', true, 'in_scope', false, 'plate', v.plate);
  end if;

  return jsonb_build_object(
    'found', true, 'in_scope', true,
    'id', v.id, 'plate', v.plate,
    'make', v.make, 'model', v.model, 'year', v.year, 'color', v.color,
    'owner_id', v.auth_user_id,
    'owner_name', coalesce(nullif(btrim(v.owner_name), ''),
                           (select nullif(btrim(p.name), '') from public.profiles p where p.id = v.auth_user_id)),
    'owner_ic', nullif(btrim(v.owner_ic), ''));
end;
$$;
revoke execute on function public.approver_find_vehicle_by_plate(text) from public, anon;
grant execute on function public.approver_find_vehicle_by_plate(text) to authenticated;

notify pgrst, 'reload schema';
