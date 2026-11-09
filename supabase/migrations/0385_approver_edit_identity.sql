-- ============================================================================
-- 0385: My Team — the dedicated ID sheet lets an approver copy the expiry read
-- off an ID document into what's stored on the identity check, the same "Fix a
-- mismatch" the document detail offers for provider/vehicle docs (0365/Slice
-- 10). Name, ID number and nationality are profile fields, so those fixes reuse
-- approver_edit_profile; the ID's own expiry lives on identity_checks and has
-- no writer yet — this adds one.
--
--   approver_edit_identity(p_check uuid, p_expiry date) → jsonb
--     Writes identity_checks.expiry_date for a covered member's ID check.
--     Gated like the profile edit (active approver, covers the member,
--     can_edit_profile). Leaves the image and the review status alone; an ID
--     already expired is allowed (the approver then rejects it). Logged.
-- ============================================================================

create or replace function public.approver_edit_identity(p_check uuid, p_expiry date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  c       public.identity_checks;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then raise exception 'not_allowed'; end if;
  if p_check is null then raise exception 'bad_input' using errcode = '22023'; end if;

  select * into c from public.identity_checks where id = p_check;
  if not found or c.kind <> 'id' then raise exception 'APPROVER_NOT_FOUND' using errcode = '22023'; end if;
  if not public.approver_covers(c.user_id) then raise exception 'out_of_scope'; end if;

  update public.identity_checks set expiry_date = p_expiry where id = p_check;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.edit_identity', c.user_id,
          jsonb_build_object('check_id', p_check, 'expiry_date', p_expiry));

  return jsonb_build_object('ok', true, 'expiry_date', p_expiry);
end;
$$;
revoke execute on function public.approver_edit_identity(uuid, date) from public, anon;
grant  execute on function public.approver_edit_identity(uuid, date) to authenticated;

notify pgrst, 'reload schema';
