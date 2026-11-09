-- ============================================================================
-- 0387: Vehicle seats + make/model from the catalogue.
--
-- The Edit vehicle sheet lets make / model / energy be typed freely. They are
-- being moved to strict pickers backed by vehicle_make_models, and the number
-- of seats — needed for pricing and capacity, and read off the vehicle
-- ownership certificate — has no column yet. This adds vehicle.seats and lets
-- the approver edit + read it, alongside the make/model/energy already handled
-- by 0375.
--
--   * vehicle.seats (int) — the number of seats.
--   * approver_vehicle_detail returns seats.
--   * approver_update_vehicle writes seats (cleared when the key is present and
--     empty, as with the other nullable fields).
--
-- Scope and grant unchanged (auth.uid() + approver_covers(owner) +
-- can_manage_vehicle). CREATE OR REPLACE, no DROP.
-- ============================================================================

alter table public.vehicle add column if not exists seats int;

-- The catalogue carries the model's usual seat count too, so picking a model
-- can suggest it and the AI lookup (vehicle-catalog-lookup) can store it.
alter table public.vehicle_make_models add column if not exists seats int;

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
    'can_manage', coalesce((select a.can_manage_vehicle from public.approvers a
                              where a.profile_id = auth.uid() and a.active
                                and (a.ends_at is null or a.ends_at > now())), false),
    'drivers', v_drv, 'documents', v_docs);
end;
$$;
revoke execute on function public.approver_vehicle_detail(uuid) from public, anon;
grant execute on function public.approver_vehicle_detail(uuid) to authenticated;

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
  v_status text := nullif(btrim(p_patch->>'status'), '');
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

  if p_patch ? 'status' and v_status is not null
     and not exists (select 1 from unnest(enum_range(null::public.partner_status)) e
                      where e::text = v_status) then
    raise exception 'bad_status' using errcode = '22023';
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
    plate         = coalesce(nullif(btrim(p_patch->>'plate'), ''), v.plate),
    make          = case when p_patch ? 'make'          then nullif(btrim(p_patch->>'make'),          '') else v.make          end,
    model         = case when p_patch ? 'model'         then nullif(btrim(p_patch->>'model'),         '') else v.model         end,
    color         = case when p_patch ? 'color'         then nullif(btrim(p_patch->>'color'),         '') else v.color         end,
    year          = case when p_patch ? 'year'          then nullif(btrim(p_patch->>'year'),          '') else v.year          end,
    vehicle_type  = case when p_patch ? 'vehicle_type'  then nullif(btrim(p_patch->>'vehicle_type'),  '') else v.vehicle_type  end,
    energy_type   = case when p_patch ? 'energy_type'   then nullif(btrim(p_patch->>'energy_type'),   '') else v.energy_type   end,
    seats         = case when p_patch ? 'seats'         then nullif(btrim(p_patch->>'seats'), '')::int else v.seats          end,
    vin           = case when p_patch ? 'vin'           then nullif(btrim(p_patch->>'vin'),           '') else v.vin           end,
    engine_number = case when p_patch ? 'engine_number' then nullif(btrim(p_patch->>'engine_number'), '') else v.engine_number end,
    owner_name    = case when p_patch ? 'owner_name'    then nullif(btrim(p_patch->>'owner_name'),    '') else v.owner_name    end,
    owner_ic      = case when p_patch ? 'owner_ic'      then nullif(btrim(p_patch->>'owner_ic'),      '') else v.owner_ic      end,
    owner_id_type = case when p_patch ? 'owner_id_type' then nullif(btrim(p_patch->>'owner_id_type'), '') else v.owner_id_type end,
    owner_phone   = case when p_patch ? 'owner_phone'   then nullif(btrim(p_patch->>'owner_phone'),   '') else v.owner_phone   end,
    status        = case when p_patch ? 'status' and v_status is not null
                         then v_status::public.partner_status else v.status end,
    updated_at    = now()
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
