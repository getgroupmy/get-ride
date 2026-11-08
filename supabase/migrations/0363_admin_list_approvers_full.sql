-- ============================================================================
-- 0363: admin_list_approvers returns every flag the admin dialog edits.
--
-- The Approvers admin dialog (lib/src/admin/screens/people/approvers_screen.dart)
-- pre-fills its toggles from the row admin_list_approvers returns. That reader
-- (0349) still returned only can_approve / can_upload / can_delete, so the
-- flags added later — delete_hard (0349), can_credit (0359), can_edit_profile /
-- can_verify_id (0360) — and the long-standing use_own_region / conflict_guard /
-- note read back as their defaults. The flags SAVE correctly (admin_set_approver
-- writes them), but the dialog re-opened with them off, so a grant looked like
-- it "wasn't saving", and the next save of any field reset them to the
-- defaulted-off toggles.
--
-- Adding columns to the RETURNS TABLE changes the function's return type, which
-- create-or-replace cannot do, so the reader is dropped and recreated. Same
-- name, args and gate; callers (the one RPC) are unaffected.
-- ============================================================================

drop function if exists public.admin_list_approvers();

create function public.admin_list_approvers()
returns table (
  profile_id       uuid,
  name             text,
  phone            text,
  active           boolean,
  scope            text,
  can_approve      boolean,
  can_upload       boolean,
  can_delete       boolean,
  delete_hard      boolean,
  can_credit       boolean,
  can_edit_profile boolean,
  can_verify_id    boolean,
  use_own_region   boolean,
  conflict_guard   boolean,
  ends_at          timestamptz,
  note             text
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
           a.use_own_region, a.conflict_guard, a.ends_at, a.note
      from public.approvers a
      join public.profiles p on p.id = a.profile_id
     order by a.active desc, lower(coalesce(p.name, '')), a.profile_id;
end;
$$;
revoke execute on function public.admin_list_approvers() from public, anon;
grant execute on function public.admin_list_approvers() to authenticated;

notify pgrst, 'reload schema';
