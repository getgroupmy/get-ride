-- ============================================================================
-- 0369: Approver — the Vehicle sheet's Assign driver / Edit vehicle actions
-- (My Team, the follow-up to slice C's 0366).
--
-- The Vehicle detail sheet (0366) shows who can drive a covered member's
-- vehicle and lets an approver with can_manage_vehicle approve or revoke a
-- driver. This adds the two actions the mockup's bottom buttons call for:
--
--   approver_assign_vehicle_driver(vehicle, member)
--       add a covered member as an approved, active driver of the vehicle
--       (idempotent — re-activates an existing assignment).
--
--   approver_update_vehicle(vehicle, patch)
--       edit the vehicle's plate / make / model / colour / year.
--
-- Both are gated exactly like approver_set_vehicle_access: the caller must be
-- an active approver with can_manage_vehicle, and must cover the vehicle's
-- owner. Assigning additionally requires the approver to cover the member
-- being assigned (you can only put your own people on a car). Audited.
-- Neither touches a vehicle's status or a member's own profile.
-- ============================================================================

-- ---- Assign a covered member as a driver of a covered member's vehicle -------
create or replace function public.approver_assign_vehicle_driver(p_vehicle uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_owner uuid;
  v_asg   uuid;
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

  select partner_id into v_owner from public.vehicles where id = p_vehicle;
  if v_owner is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;
  -- You can only assign a driver who is also within your scope.
  if not public.approver_covers(p_member) then
    raise exception 'member_out_of_scope';
  end if;

  insert into public.vehicle_user_assignment as t (vehicle_id, user_id, role, approval, is_active, assigned_by)
  values (p_vehicle, p_member, 'driver', 'approved', true, v_me)
  on conflict (vehicle_id, user_id) do update set
    role = 'driver', approval = 'approved', is_active = true, assigned_by = v_me, updated_at = now()
  returning t.id into v_asg;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.vehicle_assign', p_member,
          jsonb_build_object('vehicle', p_vehicle, 'assignment', v_asg));

  return jsonb_build_object('ok', true, 'assignment_id', v_asg);
end;
$$;
revoke execute on function public.approver_assign_vehicle_driver(uuid, uuid) from public, anon;
grant execute on function public.approver_assign_vehicle_driver(uuid, uuid) to authenticated;

-- ---- Edit a covered member's vehicle (plate / make / model / colour / year) --
-- make, model and plate are NOT NULL, so a blank patch field keeps the stored
-- value; colour and year are nullable, so an explicitly-present empty value
-- clears them. Status and ownership are never changed here.
create or replace function public.approver_update_vehicle(p_vehicle uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v       public.vehicles;
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
  if p_vehicle is null then
    raise exception 'bad_input' using errcode = '22023';
  end if;

  select * into v from public.vehicles where id = p_vehicle;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_owner := v.partner_id;
  if v_owner is null or not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;

  update public.vehicles set
    plate = coalesce(nullif(btrim(p_patch->>'plate'), ''), v.plate),
    make  = coalesce(nullif(btrim(p_patch->>'make'),  ''), v.make),
    model = coalesce(nullif(btrim(p_patch->>'model'), ''), v.model),
    color = case when p_patch ? 'color' then nullif(btrim(p_patch->>'color'), '') else v.color end,
    year  = case when p_patch ? 'year'  then nullif(btrim(p_patch->>'year'),  '') else v.year end,
    updated_at = now()
  where id = p_vehicle;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.vehicle_update', v_owner,
          jsonb_build_object('vehicle', p_vehicle, 'patch', p_patch));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_update_vehicle(uuid, jsonb) from public, anon;
grant execute on function public.approver_update_vehicle(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
