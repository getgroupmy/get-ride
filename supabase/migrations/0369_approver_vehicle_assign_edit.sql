-- ============================================================================
-- 0369: Approver — My Team vehicles read the REAL vehicle table, the full
-- Vehicle detail sheet, and Assign driver / Edit vehicle.
--
-- Bug fix + the follow-up to slice C. The first cut of the Vehicle tab (0364)
-- and detail sheet (0366) read `public.vehicles` (a separate, near-empty
-- table), so a covered member's actual car — which lives in `public.vehicle`
-- (singular), the table the header label (0357), vehicle_user_assignment and
-- vehicle_documents all use — never showed ("No vehicles"). Every approver
-- vehicle function is redefined here to read `public.vehicle`, keyed by its
-- owner account `auth_user_id`.
--
-- The detail read is also enriched to the mockup: the four vehicle photos, the
-- full spec grid (type / energy / VIN / engine), the registered owner block,
-- and each driver's taxi-permit plate vs the car's plate (match / mismatch).
--
--   approver_member_vehicles(member)      registered + allowed-to-use lists
--   approver_vehicle_detail(vehicle)      the full sheet's data
--   approver_vehicle_permit_card(vehicle) Services & Permits (reuses the engine)
--   approver_set_vehicle_access(a, act)   approve | revoke a driver
--   approver_assign_vehicle_driver(v, m)  add a covered member as a driver
--   approver_update_vehicle(v, patch)     edit plate / make / model / colour / year
--
-- Scope is unchanged: auth.uid() + approver_covers(owner); the three write
-- actions additionally need can_manage_vehicle. All CREATE OR REPLACE (the
-- signatures are unchanged), so no DROP.
-- ============================================================================

-- ---- 1. The member's vehicles: registered under them + allowed to use --------
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

  -- Registered under this member (they are the account the car is on).
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

  -- Allowed to use: assigned to drive someone else's car.
  select coalesce(jsonb_agg(x order by x->>'plate'), '[]'::jsonb) into v_allowed
    from (
      select jsonb_build_object(
               'id', v.id, 'display_id', v.display_id, 'plate', v.plate,
               'make', v.make, 'model', v.model, 'year', v.year, 'color', v.color,
               'status', v.status, 'owner_self', false,
               'owner_name', coalesce(nullif(btrim(v.owner_name), ''),
                                      nullif(btrim(op.name), '')),
               'owner_ic', coalesce(nullif(btrim(v.owner_ic), ''), op.ic),
               'access_approval', a.approval, 'access_active', a.is_active,
               'assigned_at', a.assigned_at) as x
        from public.vehicle_user_assignment a
        join public.vehicle v on v.id = a.vehicle_id
        left join public.profiles op on op.id = v.auth_user_id
       where a.user_id = p_member and a.is_active
         and v.auth_user_id is distinct from p_member
    ) q;

  return jsonb_build_object('registered', v_registered, 'allowed', v_allowed);
end;
$$;
revoke execute on function public.approver_member_vehicles(uuid) from public, anon;
grant execute on function public.approver_member_vehicles(uuid) to authenticated;

-- ---- 2. The full Vehicle detail sheet ----------------------------------------
create or replace function public.approver_vehicle_detail(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v       public.vehicle;
  v_owner uuid;
  v_drv   jsonb;
  v_docs  jsonb;
begin
  if auth.uid() is null or p_vehicle is null then
    return null;
  end if;
  select * into v from public.vehicle where id = p_vehicle;
  if not found then
    return null;
  end if;
  v_owner := v.auth_user_id;
  if v_owner is null or not public.approver_covers(v_owner) then
    return null;
  end if;

  -- Who can drive it, newest first, each with their taxi-permit plate vs this car.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_drv
    from (
      select a.assigned_at ord, jsonb_build_object(
               'assignment_id', a.id,
               'driver_id', a.user_id,
               'name', coalesce(nullif(btrim(dp.name), ''), 'User'),
               'driver_no', dp.display_id,
               'role', a.role,
               'active', a.is_active,
               'approval', a.approval,
               'state', case when a.approval in ('pending', 'requested') then 'pending'
                             when a.is_active then 'active' else 'revoked' end,
               'assigned_at', a.assigned_at,
               'permit_plate', nullif(btrim(pt.driver_permit_plate), ''),
               'permit_no', nullif(btrim(pt.permit_number), ''),
               'permit_expiry', pt.driver_permit_valid_until,
               'plate_match', case
                 when nullif(btrim(pt.driver_permit_plate), '') is null then null
                 when upper(regexp_replace(pt.driver_permit_plate, '[^A-Za-z0-9]', '', 'g'))
                    = upper(regexp_replace(coalesce(v.plate, ''), '[^A-Za-z0-9]', '', 'g')) then true
                 else false end) as x
        from public.vehicle_user_assignment a
        left join public.profiles dp on dp.id = a.user_id
        left join public.partners  pt on pt.auth_user_id = a.user_id
       where a.vehicle_id = p_vehicle
    ) q;

  -- Its documents.
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_docs
    from (
      select d.uploaded_at ord, jsonb_build_object(
               'id', d.id, 'doc_name', coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
               'status', d.status, 'expiry_date', d.expiry_date,
               'provider', d.insurance_provider_name,
               'has_file', (coalesce(d.file_url, '') <> '')) as x
        from public.vehicle_documents d
       where d.vehicle_id = p_vehicle
    ) q;

  return jsonb_build_object(
    'id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model,
    'year', v.year, 'color', v.color, 'vehicle_type', v.vehicle_type,
    'energy_type', v.energy_type, 'status', v.status,
    'vin', v.vin, 'engine_number', v.engine_number,
    'registration_date', v.registration_date,
    'photos', jsonb_build_object(
      'front', nullif(btrim(v.image_front), ''), 'back', nullif(btrim(v.image_back), ''),
      'left', nullif(btrim(v.image_left), ''), 'right', nullif(btrim(v.image_right), '')),
    'owner_name', nullif(btrim(v.owner_name), ''),
    'owner_ic', nullif(btrim(v.owner_ic), ''),
    'owner_phone', nullif(btrim(v.owner_phone), ''),
    'can_manage', coalesce((select a.can_manage_vehicle from public.approvers a
                              where a.profile_id = auth.uid() and a.active
                                and (a.ends_at is null or a.ends_at > now())), false),
    'drivers', v_drv, 'documents', v_docs);
end;
$$;
revoke execute on function public.approver_vehicle_detail(uuid) from public, anon;
grant execute on function public.approver_vehicle_detail(uuid) to authenticated;

-- ---- 3. Services & Permits — reuse the permit engine, approver-scoped --------
create or replace function public.approver_vehicle_permit_card(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  if auth.uid() is null or p_vehicle is null then
    return null;
  end if;
  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null or not public.approver_covers(v_owner) then
    return null;
  end if;
  return public.vehicle_permit_card(p_vehicle);
end;
$$;
revoke execute on function public.approver_vehicle_permit_card(uuid) from public, anon;
grant execute on function public.approver_vehicle_permit_card(uuid) to authenticated;

-- ---- 4. Approve / revoke a driver's access (read owner from `vehicle`) --------
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
  if p_action not in ('approve', 'revoke') then
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

-- ---- 5. Assign a covered member as a driver of a covered member's vehicle -----
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

  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;
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

-- ---- 6. Edit a covered member's vehicle --------------------------------------
-- On `vehicle`, only plate is NOT NULL; make/model/colour/year are nullable, so
-- a present-but-empty patch value clears them. Status and ownership never change.
create or replace function public.approver_update_vehicle(p_vehicle uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v       public.vehicle;
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

  select * into v from public.vehicle where id = p_vehicle;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_owner := v.auth_user_id;
  if v_owner is null or not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;

  update public.vehicle set
    plate = coalesce(nullif(btrim(p_patch->>'plate'), ''), v.plate),
    make  = case when p_patch ? 'make'  then nullif(btrim(p_patch->>'make'),  '') else v.make  end,
    model = case when p_patch ? 'model' then nullif(btrim(p_patch->>'model'), '') else v.model end,
    color = case when p_patch ? 'color' then nullif(btrim(p_patch->>'color'), '') else v.color end,
    year  = case when p_patch ? 'year'  then nullif(btrim(p_patch->>'year'),  '') else v.year  end,
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
