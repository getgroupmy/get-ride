-- ============================================================================
-- 0391: The vehicle owner approves or declines a driver added to their car.
--
-- When an approver adds a driver to a third-party car (migration 0377) the
-- assignment is created approval='pending', is_active=false, and the owner is
-- notified. 0376 lets an approver who covers the owner approve it; this adds the
-- owner's own side:
--
--   * vehicle_owner_pending_drivers() — the driver requests still waiting on the
--     caller, across every vehicle the caller owns.
--   * vehicle_owner_respond_driver(assignment, approve) — the owner approves
--     (active driver) or declines it; the driver is notified either way.
--
-- Owner-scoped: every row is checked to belong to a vehicle the caller owns
-- (vehicle.auth_user_id = auth.uid()). SECURITY DEFINER, so the approval guard
-- trigger (which blocks a plain authenticated UPDATE of approval) passes through.
-- ============================================================================

create or replace function public.vehicle_owner_pending_drivers()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_me uuid := auth.uid(); v jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'requested_at' desc nulls last), '[]'::jsonb) into v from (
    select jsonb_build_object(
             'assignment_id', asg.id,
             'vehicle_id',    veh.id,
             'plate',         nullif(btrim(veh.plate), ''),
             'vehicle_label', nullif(btrim(concat_ws(' ', nullif(btrim(veh.make), ''), nullif(btrim(veh.model), ''))), ''),
             'driver_id',     p.id,
             'driver_name',   coalesce(nullif(btrim(p.name), ''), 'A driver'),
             'driver_phone',  nullif(btrim(p.phone), ''),
             'driver_avatar', coalesce(nullif(btrim(p.avatar_url), ''), nullif(btrim(p.profile_image), '')),
             'requested_at',  asg.updated_at) as x
      from public.vehicle_user_assignment asg
      join public.vehicle veh on veh.id = asg.vehicle_id
      join public.profiles p on p.id = asg.user_id
     where veh.auth_user_id = v_me
       and asg.role = 'driver'
       and asg.approval in ('pending', 'requested')
       and coalesce(asg.is_active, false) = false
       and asg.user_id <> v_me
  ) q;
  return v;
end;
$function$;

revoke all on function public.vehicle_owner_pending_drivers() from public, anon;
grant execute on function public.vehicle_owner_pending_drivers() to authenticated;

create or replace function public.vehicle_owner_respond_driver(p_assignment uuid, p_approve boolean)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_me uuid := auth.uid();
  asg  public.vehicle_user_assignment;
  v_owner uuid; v_plate text; v_drv uuid;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  if p_assignment is null then raise exception 'bad_input' using errcode = '22023'; end if;

  select * into asg from public.vehicle_user_assignment where id = p_assignment;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;

  select auth_user_id, plate into v_owner, v_plate from public.vehicle where id = asg.vehicle_id;
  if v_owner is null or v_owner <> v_me then raise exception 'not_allowed'; end if;

  -- Already decided: idempotent, report the current state.
  if asg.approval not in ('pending', 'requested') then
    return jsonb_build_object('ok', true, 'already', true, 'approval', asg.approval);
  end if;

  v_drv := asg.user_id;
  if p_approve then
    update public.vehicle_user_assignment
       set approval = 'approved', is_active = true, updated_at = now()
     where id = p_assignment;
  else
    update public.vehicle_user_assignment
       set approval = 'declined', is_active = false, updated_at = now()
     where id = p_assignment;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'vehicle_owner.respond_driver', v_drv,
          jsonb_build_object('vehicle', asg.vehicle_id, 'assignment', p_assignment, 'approve', p_approve));

  perform public.enqueue_notification(
    v_drv,
    'veh-assign-resp-' || p_assignment::text,
    'vehicle_access_response',
    'normal',
    case when p_approve then 'Driver access approved' else 'Driver access declined' end,
    case when p_approve
         then 'You can now drive ' || coalesce(nullif(btrim(v_plate), ''), 'the vehicle') || '.'
         else 'Your request to drive ' || coalesce(nullif(btrim(v_plate), ''), 'the vehicle') || ' was declined.' end,
    jsonb_build_object('vehicle', asg.vehicle_id, 'assignment', p_assignment, 'approved', p_approve),
    null);

  return jsonb_build_object('ok', true, 'approval', case when p_approve then 'approved' else 'declined' end);
end;
$function$;

revoke all on function public.vehicle_owner_respond_driver(uuid, boolean) from public, anon;
grant execute on function public.vehicle_owner_respond_driver(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
