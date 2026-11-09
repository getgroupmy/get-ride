-- ============================================================================
-- 0377: Assigning a driver to someone else's vehicle needs the owner's consent.
--
-- 0369's approver_assign_vehicle_driver made the driver approved + active at
-- once, even on a car registered under a third party. The mockup is explicit:
-- granting access to another owner's vehicle *notifies the owner* and *may need
-- their approval*. So:
--
--   * Self-owned (the member owns the car): active immediately, as before.
--   * Third-party-owned: the assignment is created PENDING (approval='pending',
--     is_active=false) and the owner is notified (notification_outbox). It
--     becomes active when it is approved — by the owner, or by an approver who
--     covers the owner via approver_set_vehicle_access (0376).
--   * An already-approved, active assignment is left as-is (idempotent, no new
--     request, no duplicate notification).
--
-- The function now returns {ok, pending, assignment_id} so the app can tell the
-- approver whether the driver is active or awaiting the owner. Scope/grant
-- unchanged (can_manage_vehicle + approver_covers of both owner and member).
-- CREATE OR REPLACE (signature unchanged), so no DROP.
-- ============================================================================
create or replace function public.approver_assign_vehicle_driver(p_vehicle uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a           public.approvers;
  v_me        uuid := auth.uid();
  v_owner     uuid;
  v_plate     text;
  v_asg       uuid;
  v_existing  public.vehicle_user_assignment;
  v_has       boolean;
  v_self      boolean;
  v_pending   boolean;
  v_member_nm text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_manage_vehicle then
    raise exception 'not_allowed';
  end if;
  if p_vehicle is null or p_member is null then
    raise exception 'bad_input' using errcode = '22023';
  end if;

  select auth_user_id, plate into v_owner, v_plate from public.vehicle where id = p_vehicle;
  if v_owner is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;
  if not public.approver_covers(p_member) then
    raise exception 'member_out_of_scope';
  end if;

  v_self := (v_owner = p_member);
  select * into v_existing from public.vehicle_user_assignment
   where vehicle_id = p_vehicle and user_id = p_member;
  v_has := found;

  if v_self then
    -- The member owns the car: active at once, no consent needed.
    insert into public.vehicle_user_assignment as t (vehicle_id, user_id, role, approval, is_active, assigned_by)
    values (p_vehicle, p_member, 'driver', 'approved', true, v_me)
    on conflict (vehicle_id, user_id) do update set
      role = 'driver', approval = 'approved', is_active = true, assigned_by = v_me, updated_at = now()
    returning t.id into v_asg;
    v_pending := false;
  elsif v_has and v_existing.approval = 'approved' and v_existing.is_active then
    -- Already an approved, active driver: idempotent, nothing to request.
    v_asg := v_existing.id;
    v_pending := false;
  else
    -- Third-party car: create a pending request and tell the owner.
    insert into public.vehicle_user_assignment as t (vehicle_id, user_id, role, approval, is_active, assigned_by)
    values (p_vehicle, p_member, 'driver', 'pending', false, v_me)
    on conflict (vehicle_id, user_id) do update set
      role = 'driver', approval = 'pending', is_active = false, assigned_by = v_me, updated_at = now()
    returning t.id into v_asg;
    v_pending := true;

    select coalesce(nullif(btrim(name), ''), 'A driver') into v_member_nm
      from public.profiles where id = p_member;
    perform public.enqueue_notification(
      v_owner,
      'veh-assign-' || v_asg::text,
      'vehicle_access_request',
      'normal',
      'Driver access requested',
      coalesce(v_member_nm, 'A driver') || ' has been added as a driver of '
        || coalesce(nullif(btrim(v_plate), ''), 'your vehicle')
        || '. Approve or decline it in your vehicle settings.',
      jsonb_build_object('vehicle', p_vehicle, 'assignment', v_asg),
      null);
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.vehicle_assign', p_member,
          jsonb_build_object('vehicle', p_vehicle, 'assignment', v_asg, 'pending', v_pending, 'owner', v_owner));

  return jsonb_build_object('ok', true, 'pending', v_pending, 'assignment_id', v_asg);
end;
$$;
revoke execute on function public.approver_assign_vehicle_driver(uuid, uuid) from public, anon;
grant execute on function public.approver_assign_vehicle_driver(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
