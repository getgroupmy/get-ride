-- ============================================================================
-- 0364: approver_member_vehicles — the Vehicle tab of My Team's Member screen.
--
-- Two lists, exactly as the mockup shows them:
--   registered   vehicles registered under this member (vehicles.partner_id),
--                owner = Self.
--   allowed      vehicles the member is assigned to use but does not own
--                (vehicle_user_assignment, is_active), owner = someone else.
--
-- Scoped like every other My Team read: auth.uid() + approver_covers(member).
-- Read-only; no new grant flag (viewing a covered member is always allowed).
-- ============================================================================
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
               'status', v.status, 'owner_self', true, 'owner_name', 'Self',
               'registered_at', coalesce(v.joined_at, v.created_at)) as x
        from public.vehicles v
       where v.partner_id = p_member
    ) q;

  select coalesce(jsonb_agg(x order by x->>'plate'), '[]'::jsonb) into v_allowed
    from (
      select jsonb_build_object(
               'id', v.id, 'display_id', v.display_id, 'plate', v.plate,
               'make', v.make, 'model', v.model, 'year', v.year, 'color', v.color,
               'status', v.status, 'owner_self', false,
               'owner_name', coalesce(nullif(btrim(op.name), ''), nullif(btrim(v.owner_name), '')),
               'owner_ic', op.ic,
               'access_approval', a.approval, 'access_active', a.is_active,
               'assigned_at', a.assigned_at) as x
        from public.vehicle_user_assignment a
        join public.vehicles v on v.id = a.vehicle_id
        left join public.profiles op on op.id = v.partner_id
       where a.user_id = p_member and a.is_active and v.partner_id is distinct from p_member
    ) q;

  return jsonb_build_object('registered', v_registered, 'allowed', v_allowed);
end;
$$;
revoke execute on function public.approver_member_vehicles(uuid) from public, anon;
grant execute on function public.approver_member_vehicles(uuid) to authenticated;

notify pgrst, 'reload schema';
