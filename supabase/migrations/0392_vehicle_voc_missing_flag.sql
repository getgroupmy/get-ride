-- ============================================================================
-- 0392: Flag an approved vehicle that has no verified ownership certificate.
--
-- The VOC became a compulsory vehicle document in 0388, which gates *new*
-- submissions and approvals. Vehicles approved before that still have no VOC,
-- and re-gating them live was declined (it would take many cars offline at
-- once). Instead this surfaces them: approver_vehicle_detail now returns
-- voc_missing — true when a VOC document type is active but this vehicle has no
-- Approved one — so the vehicle sheet can show a non-blocking badge and the
-- approver can chase it (the Pending Upload tab already lists the missing VOC).
--
-- CREATE OR REPLACE (signature unchanged), so no DROP. Only the one added field.
-- ============================================================================
create or replace function public.approver_vehicle_detail(p_vehicle uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v       public.vehicle;
  v_owner uuid;
  v_drv   jsonb;
  v_docs  jsonb;
  v_voc_missing boolean;
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

  -- A VOC type is active, but this vehicle has no Approved one on file.
  select exists (select 1 from public.required_document rd
                  where coalesce((rd.values->>'active')::boolean, false)
                    and rd.values->>'readAs' = 'voc')
     and not exists (select 1 from public.vehicle_documents d
                       join public.required_document rd on rd.id::text = d.doc_id
                      where d.vehicle_id = p_vehicle and d.status = 'Approved'
                        and rd.values->>'readAs' = 'voc')
    into v_voc_missing;

  return jsonb_build_object(
    'id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model,
    'year', v.year, 'color', v.color, 'vehicle_type', v.vehicle_type,
    'energy_type', v.energy_type, 'seats', v.seats, 'status', v.status,
    'vin', v.vin, 'engine_number', v.engine_number,
    'registration_date', v.registration_date,
    'photos', jsonb_build_object(
      'front', nullif(btrim(v.image_front), ''), 'back', nullif(btrim(v.image_back), ''),
      'left', nullif(btrim(v.image_left), ''), 'right', nullif(btrim(v.image_right), '')),
    'owner_name', nullif(btrim(v.owner_name), ''),
    'owner_ic', nullif(btrim(v.owner_ic), ''),
    'owner_id_type', nullif(btrim(v.owner_id_type), ''),
    'owner_phone', nullif(btrim(v.owner_phone), ''),
    'voc_missing', coalesce(v_voc_missing, false),
    'can_manage', coalesce((select a.can_manage_vehicle from public.approvers a
                              where a.profile_id = auth.uid() and a.active
                                and (a.ends_at is null or a.ends_at > now())), false),
    'drivers', v_drv, 'documents', v_docs);
end;
$function$;

notify pgrst, 'reload schema';
