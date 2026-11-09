-- ============================================================================
-- 0378: Approver permit actions on the Vehicle sheet — bypass and revoke.
--
-- The permits section (0369's approver_vehicle_permit_card) is read-only. The
-- mockup lets an approver who manages the vehicle act on them:
--
--   * Bypass: with no valid EVP, e-hailing is blocked unless bypassed. 0254's
--     vehicle_permit_bypass is admin-only (its guard trg_vehicle_permit_bypass_guard
--     rejects a non-admin write to vehicle.permit_bypass_*). This lets a covering
--     approver with can_manage_vehicle set/clear the bypass too — the guard is
--     widened to accept them, and approver_vehicle_permit_bypass computes the
--     same per-country window and writes it, logged.
--   * Revoke: approver_revoke_vehicle_permit removes a vehicle's permit row
--     (vehicle_documents keyed by permit_type_id), logged.
--
-- Scope/grant: auth.uid() + approver_covers(owner) + can_manage_vehicle,
-- re-checked server-side. All CREATE OR REPLACE / new functions, no DROP.
-- ============================================================================

-- Does the current caller manage this vehicle as an approver (covers its owner)?
create or replace function public.approver_can_manage_vehicle(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.approvers a
      join public.vehicle v on v.id = p_vehicle
     where a.profile_id = auth.uid()
       and a.active and (a.ends_at is null or a.ends_at > now())
       and a.can_manage_vehicle
       and v.auth_user_id is not null
       and public.approver_covers(v.auth_user_id));
$$;
revoke execute on function public.approver_can_manage_vehicle(uuid) from public, anon;
grant execute on function public.approver_can_manage_vehicle(uuid) to authenticated;

-- Widen the bypass guard: admins as before, plus a covering approver.
create or replace function public.vehicle_permit_bypass_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
     and (new.permit_bypass_until, new.permit_bypass_set_at, new.permit_bypass_set_by)
         is distinct from (old.permit_bypass_until, old.permit_bypass_set_at, old.permit_bypass_set_by)
     and not public.caller_admin_can_write('rpc:vehicle_permit_bypass')
     and not public.approver_can_manage_vehicle(new.id) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:permit_bypass_until' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.vehicle_permit_bypass_guard() from public, anon, authenticated;

-- Set / clear the e-hailing permit bypass for a covered member's vehicle.
create or replace function public.approver_vehicle_permit_bypass(p_vehicle uuid, p_on boolean)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_owner uuid;
  v_days  integer;
  v_until timestamptz;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_manage_vehicle then
    raise exception 'not_allowed';
  end if;
  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;

  select max((public.permit_settings_for(c)).bypass_days) into v_days
    from unnest(public.ptr_text_array(public.ptr_vehicle_context(p_vehicle)->'countries')) c;
  v_days := coalesce(v_days, (public.permit_settings_for(null)).bypass_days);
  v_until := case when coalesce(p_on, false) then now() + make_interval(days => v_days) end;

  update public.vehicle
     set permit_bypass_until = v_until, permit_bypass_set_at = now(), permit_bypass_set_by = v_me
   where id = p_vehicle;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.permit_bypass', v_owner,
          jsonb_build_object('vehicle', p_vehicle, 'on', coalesce(p_on, false), 'until', v_until));

  return v_until;
end;
$$;
revoke execute on function public.approver_vehicle_permit_bypass(uuid, boolean) from public, anon;
grant execute on function public.approver_vehicle_permit_bypass(uuid, boolean) to authenticated;

-- Revoke (remove) a covered member's vehicle permit.
create or replace function public.approver_revoke_vehicle_permit(p_vehicle uuid, p_permit_type_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_owner uuid;
  v_doc   uuid;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_manage_vehicle then
    raise exception 'not_allowed';
  end if;
  if p_vehicle is null or p_permit_type_id is null then
    raise exception 'bad_input' using errcode = '22023';
  end if;
  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.approver_covers(v_owner) then
    raise exception 'out_of_scope';
  end if;

  delete from public.vehicle_documents
   where vehicle_id = p_vehicle and permit_type_id = p_permit_type_id
   returning id into v_doc;
  if v_doc is null then
    raise exception 'permit_not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.permit_revoke', v_owner,
          jsonb_build_object('vehicle', p_vehicle, 'permit_type', p_permit_type_id, 'document', v_doc));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_revoke_vehicle_permit(uuid, uuid) from public, anon;
grant execute on function public.approver_revoke_vehicle_permit(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
