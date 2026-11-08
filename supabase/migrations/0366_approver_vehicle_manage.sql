-- ============================================================================
-- 0366: Approver — the Vehicle detail sheet + managing a vehicle's drivers
-- (My Team, slice C).
--
-- A new grant flag, can_manage_vehicle: approve or revoke a driver's access to
-- a covered member's vehicle. Off by default, set on the admin Approvers
-- screen, carried through approver_config / approver_self / admin_set_approver
-- like can_credit (0359) and can_edit_profile / can_verify_id (0360).
--
--   approver_vehicle_detail(vehicle)         who can drive it + its documents
--   approver_set_vehicle_access(assignment, action)  approve | revoke access
--
-- Viewing a vehicle is allowed for any approver who covers its owner (every My
-- Team read is); only the access changes need can_manage_vehicle.
-- ============================================================================

alter table public.approvers
  add column if not exists can_manage_vehicle boolean not null default false;

-- approver_config (0360) — carry the new flag through the admin config.
create or replace function public.approver_config(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'active',        coalesce((p->>'active')::boolean, true),
    'can_approve',   coalesce((p->>'can_approve')::boolean, false),
    'can_upload',    coalesce((p->>'can_upload')::boolean, false),
    'can_delete',    coalesce((p->>'can_delete')::boolean, false),
    'delete_hard',   coalesce((p->>'delete_hard')::boolean, false),
    'can_credit',    coalesce((p->>'can_credit')::boolean, false),
    'can_edit_profile', coalesce((p->>'can_edit_profile')::boolean, false),
    'can_verify_id', coalesce((p->>'can_verify_id')::boolean, false),
    'can_manage_vehicle', coalesce((p->>'can_manage_vehicle')::boolean, false),
    'scope',         case when p->>'scope' in ('all', 'region', 'referral') then p->>'scope' else 'referral' end,
    'use_own_region', coalesce((p->>'use_own_region')::boolean, true),
    'regions',       case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]'::jsonb end,
    'doc_types',     case when jsonb_typeof(p->'doc_types') = 'array' then p->'doc_types' else '[]'::jsonb end,
    'conflict_guard', coalesce((p->>'conflict_guard')::boolean, true),
    'ends_at',       case when (p->>'ends_at') ~ '^\d{4}-\d{2}-\d{2}' then (p->>'ends_at') else null end,
    'note',          nullif(left(btrim(coalesce(p->>'note', '')), 300), ''));
$$;

-- approver_self (0360) — expose the new flag to the app.
create or replace function public.approver_self()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'can_approve', a.can_approve, 'can_upload', a.can_upload,
           'can_delete', a.can_delete, 'delete_hard', a.delete_hard,
           'can_credit', a.can_credit, 'can_edit_profile', a.can_edit_profile,
           'can_verify_id', a.can_verify_id, 'can_manage_vehicle', a.can_manage_vehicle,
           'scope', a.scope, 'doc_types', to_jsonb(a.doc_types))
    from public.approvers a
   where a.profile_id = auth.uid()
     and a.active and (a.ends_at is null or a.ends_at > now());
$$;
revoke execute on function public.approver_self() from public, anon;
grant execute on function public.approver_self() to authenticated;

-- admin_set_approver (0360) — write the new flag with the rest of the grant.
create or replace function public.admin_set_approver(p_user uuid, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg jsonb;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_set_approver') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_cfg := public.approver_config(coalesce(p_config, '{}'::jsonb));

  insert into public.approvers as a (profile_id, active, can_approve, can_upload, can_delete, delete_hard,
                                     can_credit, can_edit_profile, can_verify_id, can_manage_vehicle, scope,
                                     use_own_region, regions, doc_types, conflict_guard, ends_at, note, granted_by)
  values (p_user,
          (v_cfg->>'active')::boolean, (v_cfg->>'can_approve')::boolean, (v_cfg->>'can_upload')::boolean,
          (v_cfg->>'can_delete')::boolean, (v_cfg->>'delete_hard')::boolean, (v_cfg->>'can_credit')::boolean,
          (v_cfg->>'can_edit_profile')::boolean, (v_cfg->>'can_verify_id')::boolean,
          (v_cfg->>'can_manage_vehicle')::boolean,
          v_cfg->>'scope', (v_cfg->>'use_own_region')::boolean, v_cfg->'regions',
          array(select jsonb_array_elements_text(v_cfg->'doc_types')), (v_cfg->>'conflict_guard')::boolean,
          nullif(v_cfg->>'ends_at', '')::timestamptz, v_cfg->>'note', auth.uid())
  on conflict (profile_id) do update set
    active = excluded.active, can_approve = excluded.can_approve, can_upload = excluded.can_upload,
    can_delete = excluded.can_delete, delete_hard = excluded.delete_hard, can_credit = excluded.can_credit,
    can_edit_profile = excluded.can_edit_profile, can_verify_id = excluded.can_verify_id,
    can_manage_vehicle = excluded.can_manage_vehicle,
    scope = excluded.scope, use_own_region = excluded.use_own_region, regions = excluded.regions,
    doc_types = excluded.doc_types, conflict_guard = excluded.conflict_guard, ends_at = excluded.ends_at,
    note = excluded.note, granted_by = excluded.granted_by, updated_at = now();

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'approver.set', p_user, v_cfg);
  return v_cfg;
end;
$$;
revoke execute on function public.admin_set_approver(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_approver(uuid, jsonb) to authenticated;

-- ---- The Vehicle detail sheet: who can drive it + its documents -------------
create or replace function public.approver_vehicle_detail(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v       public.vehicles;
  v_owner uuid;
  v_drv   jsonb;
  v_docs  jsonb;
begin
  if auth.uid() is null or p_vehicle is null then
    return null;
  end if;
  select * into v from public.vehicles where id = p_vehicle;
  if not found then
    return null;
  end if;
  v_owner := v.partner_id;
  if v_owner is null or not public.approver_covers(v_owner) then
    return null;
  end if;

  -- Who can drive it (vehicle_user_assignment), newest first.
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
               'assigned_at', a.assigned_at) as x
        from public.vehicle_user_assignment a
        left join public.profiles dp on dp.id = a.user_id
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
    'id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model, 'year', v.year, 'color', v.color,
    'status', v.status, 'owner_name', coalesce(nullif(btrim(v.owner_name), ''),
      (select nullif(btrim(name), '') from public.profiles where id = v_owner)),
    'can_manage', coalesce((select a.can_manage_vehicle from public.approvers a
                              where a.profile_id = auth.uid() and a.active
                                and (a.ends_at is null or a.ends_at > now())), false),
    'drivers', v_drv, 'documents', v_docs);
end;
$$;
revoke execute on function public.approver_vehicle_detail(uuid) from public, anon;
grant execute on function public.approver_vehicle_detail(uuid) to authenticated;

-- ---- Approve / revoke a driver's access to a covered member's vehicle --------
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
  select partner_id into v_owner from public.vehicles where id = asg.vehicle_id;
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

notify pgrst, 'reload schema';
