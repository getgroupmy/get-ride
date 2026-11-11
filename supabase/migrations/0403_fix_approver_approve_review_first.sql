-- ============================================================================
-- 0403: Let an approver approve a partner from My Team, even when the approver
--       is also an admin.
--
-- The approver's "Approve as a partner" (approver_set_member_approval, 0398) is
-- a deliberate, documents-gated approve: the app only offers it once every
-- required document is Approved, and it sets the partner row to 'approved'
-- directly (and cascades to the user account). It is a lighter path than the
-- admin "Review application" flow (partner_review_items, 0289/0296).
--
-- But partners_approved_by() (0296) refuses a direct approve when the caller
-- IS an admin and the partner has no review items (or a rejected one), raising
-- REVIEW_FIRST to push admins through the review flow. An approver who is also
-- an admin therefore could not approve from My Team — the write was refused and
-- the app showed the generic "Couldn't update status. Try again." A non-admin
-- approver was never affected (the guard only fires for admins).
--
-- Fix: approver_set_member_approval marks its own approve with a transaction-
-- local flag (app.approver_set_approval = 'on'), and partners_approved_by skips
-- the REVIEW_FIRST requirement while that flag is set. Everything else about the
-- guard (stamping approved_by / approved_at) is unchanged, and the ordinary
-- admin path — a plain status change in the Partners screen, where the flag is
-- not set — still requires the review flow exactly as before.
--
-- The approver approve touches only the partner and the user account, never the
-- vehicle, so the VOC completion gate (0402) is not involved here.
--
-- Both are CREATE OR REPLACE with unchanged signatures (no DROP); the trigger
-- binding on partners_approved_by stays as 0296 made it.
-- ============================================================================

-- 1. The review-items requirement skips the approver's own approve ---------------------------------
create or replace function public.partners_approved_by()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status::text = 'approved' and old.status::text is distinct from 'approved' then
    if auth.uid() is not null and public.caller_is_admin()
       and old.status::text in ('unapproved', 'unapproved-docs', 'changes-needed')
       and coalesce(current_setting('app.approver_set_approval', true), '') <> 'on' then
      if not exists (select 1 from public.partner_review_items where partner_id = new.id)
         or exists (select 1 from public.partner_review_items where partner_id = new.id and state = 'rejected') then
        raise exception 'REVIEW_FIRST' using errcode = '22023',
          hint = 'Approve this partner from Review application, once every line is checked.';
      end if;
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  return new;
end;
$$;

-- 2. The approver approve marks itself, so the guard above lets it through -------------------------
create or replace function public.approver_set_member_approval(p_member uuid, p_approved boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a            public.approvers;
  v_me         uuid := auth.uid();
  v_part       public.partners%rowtype;
  v_is_partner boolean;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then
    raise exception 'not_allowed';
  end if;
  if p_member is null then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;

  select * into v_part from public.partners where auth_user_id = p_member
   order by updated_at desc nulls last limit 1;
  v_is_partner := found;

  if v_is_partner then
    -- The member is a partner: act on the partner row.
    if p_approved then
      -- Don't clobber an already-approved or permit-verified partner.
      if not (v_part.status::text = 'approved' or v_part.status::text like 'permit-%') then
        -- This is the approver's own documents-gated approve, not the admin
        -- review-application flow, so partners_approved_by (0296) must not demand
        -- review items. Set the flag only around this write, then clear it, so it
        -- can never leak to a later statement in the same transaction.
        perform set_config('app.approver_set_approval', 'on', true);
        update public.partners
           set status = 'approved', status_note = null, documents_ok = true, updated_at = now()
         where id = v_part.id;
        perform set_config('app.approver_set_approval', '', true);
      end if;
      -- Cascade: an approved partner means an approved user account.
      update public.profiles
         set status = 'approved'::public.user_status,
             profile_status = 'Approved'::public.profile_status,
             updated_at = now()
       where id = p_member and status::text is distinct from 'approved';
    else
      update public.partners
         set status = 'unapproved', updated_at = now()
       where id = v_part.id
         and v_part.status::text not in ('blocked', 'rejected');
    end if;
  else
    -- A plain user: act on the account, as before.
    update public.profiles
       set status = case when p_approved then 'approved' else 'unapproved' end::public.user_status,
           profile_status = case when p_approved then 'Approved' else 'Un-Approved' end::public.profile_status,
           updated_at = now()
     where id = p_member;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.set_member_approval', p_member,
          jsonb_build_object('approved', p_approved, 'is_partner', v_is_partner));

  return jsonb_build_object('ok', true, 'is_partner', v_is_partner, 'approved', p_approved);
end;
$$;
revoke execute on function public.approver_set_member_approval(uuid, boolean) from public, anon;
grant execute on function public.approver_set_member_approval(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
