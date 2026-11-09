-- ============================================================================
-- 0381: Approver can reset a covered member's sign-in PIN to the default, and
-- the member is then required to set a new one.
--
--   * profiles.must_change_pin — set when the PIN was reset to the default, so
--     the app forces a change at the next sign-in; cleared when the member sets
--     a new PIN.
--   * approver_reset_member_pin(member) — sets pin_hash to the default 123456
--     (bcrypt), raises must_change_pin, clears any legacy plaintext PIN and the
--     lockout counters. Needs the approver active, covering the member, and
--     holding can_edit_profile. Logged.
--   * pin_must_change() — the signed-in user's flag, for the post-login check.
--   * clear_must_change_pin() — the signed-in user clears it after setting a new
--     PIN (the app calls this right after set_login_pin succeeds).
-- ============================================================================
alter table public.profiles add column if not exists must_change_pin boolean not null default false;

create or replace function public.approver_reset_member_pin(p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare a public.approvers; v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then raise exception 'not_allowed'; end if;
  if p_member is null then raise exception 'bad_input' using errcode = '22023'; end if;
  if not public.approver_covers(p_member) then raise exception 'out_of_scope'; end if;

  update public.profiles set
    pin_hash            = crypt('123456', gen_salt('bf', 10)),
    must_change_pin     = true,
    pin                 = null,
    login_pin           = null,
    pin_failed_attempts = 0,
    pin_locked_until    = null
  where id = p_member;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.reset_pin', p_member, jsonb_build_object('to', 'default'));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_reset_member_pin(uuid) from public, anon;
grant execute on function public.approver_reset_member_pin(uuid) to authenticated;

-- The signed-in user's "must change PIN" flag (checked right after sign-in).
create or replace function public.pin_must_change()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select must_change_pin from public.profiles where id = auth.uid()), false);
$$;
revoke execute on function public.pin_must_change() from public, anon;
grant execute on function public.pin_must_change() to authenticated;

-- The signed-in user clears the flag after choosing a new PIN.
create or replace function public.clear_must_change_pin()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return; end if;
  update public.profiles set must_change_pin = false where id = auth.uid() and must_change_pin;
end;
$$;
revoke execute on function public.clear_must_change_pin() from public, anon;
grant execute on function public.clear_must_change_pin() to authenticated;

notify pgrst, 'reload schema';
