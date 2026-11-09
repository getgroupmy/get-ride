-- ============================================================================
-- 0386: My Team — an approver who manages a vehicle can put a permit (the EVP /
-- APAD e-hailing permit and any other) on file from the dedicated permit sheet,
-- typing or scanning its number and expiry. 0378 only let an approver bypass or
-- revoke; this is the write that makes a permit present.
--
--   approver_set_vehicle_permit(vehicle, permit_type_id, number, expiry) → jsonb
--     Upserts the vehicle_documents row for (vehicle, permit_type_id) — the same
--     shape the owner/admin write uses: doc_id 'permit:<key>', the type's name,
--     status Approved. Returns the row id so the app can attach a scanned image
--     through the existing approver-upload function. Gated like the other permit
--     actions (active approver, covers the owner, can_manage_vehicle). Logged.
--     The image and read_fields are left to the upload step; only the number,
--     expiry and status are written here.
-- ============================================================================

create or replace function public.approver_set_vehicle_permit(
  p_vehicle uuid, p_permit_type_id uuid, p_number text, p_expiry date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_owner uuid;
  t       public.permit_types;
  v_num   text := nullif(btrim(coalesce(p_number, '')), '');
  v_id    uuid;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_manage_vehicle then raise exception 'not_allowed'; end if;
  if p_vehicle is null or p_permit_type_id is null then raise exception 'bad_input' using errcode = '22023'; end if;

  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not public.approver_covers(v_owner) then raise exception 'out_of_scope'; end if;

  select * into t from public.permit_types where id = p_permit_type_id;
  if not found then raise exception 'permit_not_found' using errcode = 'P0002'; end if;

  select id into v_id from public.vehicle_documents
   where vehicle_id = p_vehicle and permit_type_id = p_permit_type_id;

  if v_id is null then
    insert into public.vehicle_documents
        (vehicle_id, auth_user_id, doc_id, doc_name, permit_type_id,
         document_number, expiry_date, status, reviewed_by, reviewed_at, uploaded_at)
      values (p_vehicle, v_owner, 'permit:' || t.key, t.name, p_permit_type_id,
              v_num, p_expiry, 'Approved', v_me, now(), now())
    returning id into v_id;
  else
    update public.vehicle_documents
       set document_number = v_num, expiry_date = p_expiry, status = 'Approved',
           reviewed_by = v_me, reviewed_at = now()
     where id = v_id;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.permit_set', v_owner,
          jsonb_build_object('vehicle', p_vehicle, 'permit_type', p_permit_type_id,
                             'document', v_id, 'expiry', p_expiry));

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
revoke execute on function public.approver_set_vehicle_permit(uuid, uuid, text, date) from public, anon;
grant  execute on function public.approver_set_vehicle_permit(uuid, uuid, text, date) to authenticated;

notify pgrst, 'reload schema';
