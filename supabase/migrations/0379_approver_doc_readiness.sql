-- ============================================================================
-- 0379: Document readiness — can a member / vehicle be approved yet?
--
-- The My Team status badges (member header, vehicle card) become tappable: an
-- approver can set the status to Approved only when every REQUIRED document is
-- already Approved; otherwise the tap routes to the documents to review. These
-- read-only checks back that gate.
--
--   approver_member_doc_readiness(member)
--       over the member's required DRIVER documents.
--   approver_vehicle_doc_readiness(vehicle)
--       over the vehicle's required VEHICLE documents.
--
-- Each returns { total, approved, not_approved, all_approved }. all_approved is
-- true when there are required docs and all are Approved, OR when there are no
-- required docs at all (nothing blocks approval). Scope: auth.uid() + covers.
-- Reuses _vehicle_doc_categories() from 0372.
-- ============================================================================

create or replace function public.approver_member_doc_readiness(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_total int; v_ok int;
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;

  with req as (
    select rd.id::text as doc_id
      from public.required_document rd
     where coalesce((rd.values->>'active')::boolean, false)
       and coalesce((rd.values->>'required')::boolean, false)
       and not (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories())
  )
  select count(*),
         count(*) filter (where exists (
           select 1 from public.provider_documents d
            where d.auth_user_id = p_member and d.doc_id = req.doc_id and d.status = 'Approved'))
    into v_total, v_ok
    from req;

  return jsonb_build_object(
    'total', v_total, 'approved', v_ok, 'not_approved', v_total - v_ok,
    'all_approved', (v_total = 0 or v_ok = v_total));
end;
$$;
revoke execute on function public.approver_member_doc_readiness(uuid) from public, anon;
grant execute on function public.approver_member_doc_readiness(uuid) to authenticated;

create or replace function public.approver_vehicle_doc_readiness(p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_owner uuid; v_total int; v_ok int;
begin
  if auth.uid() is null or p_vehicle is null then return null; end if;
  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null or not public.approver_covers(v_owner) then return null; end if;

  with req as (
    select rd.id::text as doc_id
      from public.required_document rd
     where coalesce((rd.values->>'active')::boolean, false)
       and coalesce((rd.values->>'required')::boolean, false)
       and (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories())
  )
  select count(*),
         count(*) filter (where exists (
           select 1 from public.vehicle_documents d
            where d.vehicle_id = p_vehicle and d.doc_id = req.doc_id and d.status = 'Approved'))
    into v_total, v_ok
    from req;

  return jsonb_build_object(
    'total', v_total, 'approved', v_ok, 'not_approved', v_total - v_ok,
    'all_approved', (v_total = 0 or v_ok = v_total));
end;
$$;
revoke execute on function public.approver_vehicle_doc_readiness(uuid) from public, anon;
grant execute on function public.approver_vehicle_doc_readiness(uuid) to authenticated;

notify pgrst, 'reload schema';
