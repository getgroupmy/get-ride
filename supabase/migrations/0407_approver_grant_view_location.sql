-- ============================================================================
-- 0407: the admin can grant Team Location (can_view_location) on an approver.
--
-- Migration 0406 added the approvers.can_view_location column and surfaced it
-- through approver_self(); this is the admin editor's side of it:
--
--   * approver_config(jsonb) — carry can_view_location through the cleaned
--     config the admin dialog sends (defaults false, like every other flag).
--   * admin_set_approver(user, config) — write the new flag with the rest of
--     the grant (insert + on-conflict update), still audited as approver.set.
--   * admin_list_approvers() — return can_view_location so the dialog pre-fills
--     its toggle. While the return type is being changed anyway, it also starts
--     returning can_manage_vehicle (added in 0366) — the dialog edits it but
--     the 0363 reader never returned it, so that toggle read back off and the
--     next save could silently clear it, the same bug 0363 fixed for the rest.
--     Adding columns to a RETURNS TABLE needs a drop + recreate (same name,
--     args and gate; the one RPC caller is unaffected).
--
-- Every rule stays the server's; the flag only decides whether Team Location
-- shows and whether approver_may_see_location / approver_team_snapshot (0406)
-- let the approver through.
-- ============================================================================

-- ---- approver_config: carry the flag ------------------------------------------------------------
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
    'can_view_location', coalesce((p->>'can_view_location')::boolean, false),
    'scope',         case when p->>'scope' in ('all', 'region', 'referral') then p->>'scope' else 'referral' end,
    'use_own_region', coalesce((p->>'use_own_region')::boolean, true),
    'regions',       case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]'::jsonb end,
    'doc_types',     case when jsonb_typeof(p->'doc_types') = 'array' then p->'doc_types' else '[]'::jsonb end,
    'conflict_guard', coalesce((p->>'conflict_guard')::boolean, true),
    'ends_at',       case when (p->>'ends_at') ~ '^\d{4}-\d{2}-\d{2}' then (p->>'ends_at') else null end,
    'note',          nullif(left(btrim(coalesce(p->>'note', '')), 300), ''));
$$;

-- ---- admin_set_approver: write the flag ---------------------------------------------------------
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
                                     can_credit, can_edit_profile, can_verify_id, can_manage_vehicle,
                                     can_view_location, scope,
                                     use_own_region, regions, doc_types, conflict_guard, ends_at, note, granted_by)
  values (p_user,
          (v_cfg->>'active')::boolean, (v_cfg->>'can_approve')::boolean, (v_cfg->>'can_upload')::boolean,
          (v_cfg->>'can_delete')::boolean, (v_cfg->>'delete_hard')::boolean, (v_cfg->>'can_credit')::boolean,
          (v_cfg->>'can_edit_profile')::boolean, (v_cfg->>'can_verify_id')::boolean,
          (v_cfg->>'can_manage_vehicle')::boolean, (v_cfg->>'can_view_location')::boolean,
          v_cfg->>'scope', (v_cfg->>'use_own_region')::boolean, v_cfg->'regions',
          array(select jsonb_array_elements_text(v_cfg->'doc_types')), (v_cfg->>'conflict_guard')::boolean,
          nullif(v_cfg->>'ends_at', '')::timestamptz, v_cfg->>'note', auth.uid())
  on conflict (profile_id) do update set
    active = excluded.active, can_approve = excluded.can_approve, can_upload = excluded.can_upload,
    can_delete = excluded.can_delete, delete_hard = excluded.delete_hard, can_credit = excluded.can_credit,
    can_edit_profile = excluded.can_edit_profile, can_verify_id = excluded.can_verify_id,
    can_manage_vehicle = excluded.can_manage_vehicle, can_view_location = excluded.can_view_location,
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

-- ---- admin_list_approvers: return the flag (and can_manage_vehicle) -----------------------------
drop function if exists public.admin_list_approvers();

create function public.admin_list_approvers()
returns table (
  profile_id         uuid,
  name               text,
  phone              text,
  active             boolean,
  scope              text,
  can_approve        boolean,
  can_upload         boolean,
  can_delete         boolean,
  delete_hard        boolean,
  can_credit         boolean,
  can_edit_profile   boolean,
  can_verify_id      boolean,
  can_manage_vehicle boolean,
  can_view_location  boolean,
  use_own_region     boolean,
  conflict_guard     boolean,
  ends_at            timestamptz,
  note               text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_list_approvers') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select a.profile_id, coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
           a.active, a.scope, a.can_approve, a.can_upload, a.can_delete,
           a.delete_hard, a.can_credit, a.can_edit_profile, a.can_verify_id,
           a.can_manage_vehicle, a.can_view_location,
           a.use_own_region, a.conflict_guard, a.ends_at, a.note
      from public.approvers a
      join public.profiles p on p.id = a.profile_id
     order by a.active desc, lower(coalesce(p.name, '')), a.profile_id;
end;
$$;
revoke execute on function public.admin_list_approvers() from public, anon;
grant execute on function public.admin_list_approvers() to authenticated;

notify pgrst, 'reload schema';
