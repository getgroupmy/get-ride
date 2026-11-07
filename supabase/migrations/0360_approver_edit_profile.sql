-- ============================================================================
-- 0360: Approver — edit a covered member's profile (My Team Phase 2b).
--
-- Two new dedicated grant flags:
--   can_edit_profile  edit the member's name, email, ID no., nationality,
--                     address, account status and services (partner types).
--   can_verify_id     the higher power to mark the member's ID *verified*
--                     (which otherwise comes only from the automated ID+face
--                     check). Editing the ID number is can_edit_profile; flipping
--                     verified needs this one.
--
--   approver_edit_profile(member, fields)  writes only the keys present in
--   `fields`, each gated and validated; scoped by approver_covers (0350);
--   audited. The mobile NUMBER is deliberately NOT editable here — changing it
--   is an account-takeover risk and gets its own member-confirmed flow later.
--
-- Both flags are OFF by default and set on the admin Approvers screen.
-- ============================================================================

-- ---- 0. The new grant flags -----------------------------------------------------------------------
alter table public.approvers
  add column if not exists can_edit_profile boolean not null default false,
  add column if not exists can_verify_id    boolean not null default false;

-- approver_config (0349/0359) — carry the new flags through the admin config.
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
    'scope',         case when p->>'scope' in ('all', 'region', 'referral') then p->>'scope' else 'referral' end,
    'use_own_region', coalesce((p->>'use_own_region')::boolean, true),
    'regions',       case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]'::jsonb end,
    'doc_types',     case when jsonb_typeof(p->'doc_types') = 'array' then p->'doc_types' else '[]'::jsonb end,
    'conflict_guard', coalesce((p->>'conflict_guard')::boolean, true),
    'ends_at',       case when (p->>'ends_at') ~ '^\d{4}-\d{2}-\d{2}' then (p->>'ends_at') else null end,
    'note',          nullif(left(btrim(coalesce(p->>'note', '')), 300), ''));
$$;

-- approver_self (0349/0359) — expose the new flags to the app.
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
           'can_verify_id', a.can_verify_id,
           'scope', a.scope, 'doc_types', to_jsonb(a.doc_types))
    from public.approvers a
   where a.profile_id = auth.uid()
     and a.active and (a.ends_at is null or a.ends_at > now());
$$;
revoke execute on function public.approver_self() from public, anon;
grant execute on function public.approver_self() to authenticated;

-- admin_set_approver (0349/0359) — write the new flags with the rest of the grant.
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
                                     can_credit, can_edit_profile, can_verify_id, scope, use_own_region,
                                     regions, doc_types, conflict_guard, ends_at, note, granted_by)
  values (p_user,
          (v_cfg->>'active')::boolean, (v_cfg->>'can_approve')::boolean, (v_cfg->>'can_upload')::boolean,
          (v_cfg->>'can_delete')::boolean, (v_cfg->>'delete_hard')::boolean, (v_cfg->>'can_credit')::boolean,
          (v_cfg->>'can_edit_profile')::boolean, (v_cfg->>'can_verify_id')::boolean,
          v_cfg->>'scope', (v_cfg->>'use_own_region')::boolean, v_cfg->'regions',
          array(select jsonb_array_elements_text(v_cfg->'doc_types')), (v_cfg->>'conflict_guard')::boolean,
          nullif(v_cfg->>'ends_at', '')::timestamptz, v_cfg->>'note', auth.uid())
  on conflict (profile_id) do update set
    active = excluded.active, can_approve = excluded.can_approve, can_upload = excluded.can_upload,
    can_delete = excluded.can_delete, delete_hard = excluded.delete_hard, can_credit = excluded.can_credit,
    can_edit_profile = excluded.can_edit_profile, can_verify_id = excluded.can_verify_id,
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

-- ---- 1. Edit a covered member's profile -----------------------------------------------------------
-- Writes only the keys present in p_fields. name/email/ic/nationality/address/
-- status/partner_types need can_edit_profile; id_verified needs can_verify_id.
-- The mobile number is not accepted here (see header).
create or replace function public.approver_edit_profile(p_member uuid, p_fields jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a         public.approvers;
  v_me      uuid := auth.uid();
  v_status  text;
  v_pstatus text;
  v_idver   text;
  v_types   text[];
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then
    raise exception 'not_allowed';
  end if;
  if p_member is null or jsonb_typeof(p_fields) is distinct from 'object' then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;

  -- The ordinary profile fields + status + services need can_edit_profile.
  if (p_fields ?| array['name','email','ic','nationality','address','status','partner_types'])
     and not a.can_edit_profile then
    raise exception 'not_allowed';
  end if;
  -- Marking the ID verified needs the higher flag.
  if (p_fields ? 'id_verified') and not a.can_verify_id then
    raise exception 'not_allowed';
  end if;

  -- Validate the enum-backed fields; a bad value is rejected.
  if p_fields ? 'status' then
    v_status := p_fields->>'status';
    if v_status not in ('approved','unapproved','blocked','rejected','unapproved-docs') then
      raise exception 'invalid_status';
    end if;
    v_pstatus := case v_status
                   when 'approved' then 'Approved'
                   when 'blocked' then 'Blocked'
                   when 'rejected' then 'Rejected'
                   else 'Un-Approved' end;
  end if;
  if p_fields ? 'id_verified' then
    v_idver := p_fields->>'id_verified';
    if v_idver not in ('Verified','Failed') then
      raise exception 'invalid_id_verified';
    end if;
  end if;

  update public.profiles set
    name         = case when p_fields ? 'name'        then nullif(btrim(p_fields->>'name'), '') else name end,
    email        = case when p_fields ? 'email'       then nullif(btrim(p_fields->>'email'), '') else email end,
    ic           = case when p_fields ? 'ic'          then nullif(btrim(p_fields->>'ic'), '') else ic end,
    nationality  = case when p_fields ? 'nationality' then nullif(btrim(p_fields->>'nationality'), '') else nationality end,
    address      = case when p_fields ? 'address'     then nullif(btrim(p_fields->>'address'), '') else address end,
    status       = case when p_fields ? 'status'      then v_status::public.user_status else status end,
    profile_status = case when p_fields ? 'status'    then v_pstatus::public.profile_status else profile_status end,
    id_verified  = case when p_fields ? 'id_verified' then v_idver::public.id_verification_status else id_verified end,
    updated_at   = now()
   where id = p_member;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  -- Services (partner types) live on the member's partner row, if they have one.
  if p_fields ? 'partner_types' and jsonb_typeof(p_fields->'partner_types') = 'array' then
    v_types := array(select jsonb_array_elements_text(p_fields->'partner_types'));
    update public.partners set partner_types = v_types, updated_at = now()
     where auth_user_id = p_member;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.edit_profile', p_member,
          jsonb_build_object('keys', (select jsonb_agg(k) from jsonb_object_keys(p_fields) k)));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_edit_profile(uuid, jsonb) from public, anon;
grant execute on function public.approver_edit_profile(uuid, jsonb) to authenticated;

-- ---- 2. A covered member's editable fields, to pre-fill the edit form -----------------------------
-- Name / email / ID no. / nationality / address / status / id_verified and the
-- member's partner types (if any). Behind approver_covers, like every read.
create or replace function public.approver_member_detail(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.profiles;
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;
  select * into p from public.profiles where id = p_member;
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'email', p.email,
    'phone', p.phone,
    'ic', p.ic,
    'nationality', p.nationality,
    'address', p.address,
    'status', p.status,
    'id_verified', p.id_verified,
    'is_partner', exists (select 1 from public.partners where auth_user_id = p_member),
    'partner_types', coalesce((select to_jsonb(partner_types) from public.partners
                                where auth_user_id = p_member limit 1), '[]'::jsonb));
end;
$$;
revoke execute on function public.approver_member_detail(uuid) from public, anon;
grant execute on function public.approver_member_detail(uuid) to authenticated;

notify pgrst, 'reload schema';
