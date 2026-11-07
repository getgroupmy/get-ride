-- ============================================================================
-- 0362: Approver proposes a member's new mobile number (My Team Phase 2b-2).
--
-- A member's sign-in number controls OTP sign-in and PIN reset, so an approver
-- must NOT be able to change it silently. Instead the approver *proposes* a new
-- number; the MEMBER confirms it themselves through the ordinary change-number
-- flow (Supabase Auth texts the new number, the member enters the code), which
-- is the only path that proves control of the new number. profiles.phone then
-- follows auth.users.phone by trigger (0092).
--
-- This migration is just the proposal layer:
--   approver_propose_member_phone(member, phone)  file a pending proposal + push
--   member_phone_proposal()                       the caller's own pending one
--   member_cancel_phone_proposal(id)              the member declines
--   member_apply_phone_proposal(id)               the member marks it done once
--                                                 their number already matches
-- The actual number change is the existing self-service change-number flow; no
-- new phone-change backend is added here.
-- ============================================================================

create table if not exists public.member_phone_proposals (
  id             uuid primary key default gen_random_uuid(),
  member_id      uuid not null references public.profiles(id) on delete cascade,
  proposed_phone text not null,
  proposed_by    uuid references public.profiles(id) on delete set null,
  status         text not null default 'pending' check (status in ('pending', 'applied', 'cancelled')),
  created_at     timestamptz not null default now(),
  decided_at     timestamptz
);
comment on table public.member_phone_proposals is
  'An approver''s proposed new mobile number for a member (0362); the member confirms it through the ordinary change-number flow.';
create unique index if not exists member_phone_proposal_one_pending
  on public.member_phone_proposals (member_id) where status = 'pending';

alter table public.member_phone_proposals enable row level security;
revoke all on public.member_phone_proposals from public, anon, authenticated;
grant select on public.member_phone_proposals to authenticated;
grant all on public.member_phone_proposals to service_role;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public'
                   and tablename = 'member_phone_proposals' and policyname = 'member_phone_proposal_read') then
    create policy member_phone_proposal_read on public.member_phone_proposals
      for select to authenticated
      using (member_id = (select auth.uid()) or proposed_by = (select auth.uid()) or (select public.caller_is_admin()));
  end if;
end $$;

-- A phone to its '+digits' E.164 form, or null when it is not a plausible
-- international number. A leading 0 is rejected: E.164 never starts with 0, so a
-- local-format number ('011-2345 6789') must be given with its country code
-- ('+60 11-2345 6789') — otherwise it could never match the member's confirmed
-- auth.users.phone, which is always E.164.
create or replace function public.normalize_phone_digits(p_phone text)
returns text
language sql
immutable
as $$
  select case when length(d) between 8 and 15 and left(d, 1) <> '0' then '+' || d end
    from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d) q;
$$;

-- ---- The approver proposes ------------------------------------------------------------------------
create or replace function public.approver_propose_member_phone(p_member uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a       public.approvers;
  v_me    uuid := auth.uid();
  v_phone text := public.normalize_phone_digits(p_phone);
  v_name  text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then
    raise exception 'not_allowed';
  end if;
  if p_member is null or not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;
  if v_phone is null then
    raise exception 'invalid_phone';
  end if;
  if v_phone = public.normalize_phone_digits((select phone from public.profiles where id = p_member)) then
    raise exception 'same_phone';  -- that is already their number
  end if;
  -- A number already signed in to another account can't be taken.
  if exists (select 1 from auth.users u where u.id <> p_member and u.phone = v_phone) then
    raise exception 'phone_in_use';
  end if;

  -- One pending proposal per member: replace any earlier one.
  update public.member_phone_proposals set status = 'cancelled', decided_at = now()
   where member_id = p_member and status = 'pending';
  insert into public.member_phone_proposals (member_id, proposed_phone, proposed_by)
  values (p_member, v_phone, v_me);

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.propose_phone', p_member, jsonb_build_object('phone', v_phone));

  select coalesce(nullif(btrim(name), ''), 'your team') into v_name from public.profiles where id = v_me;
  perform public.approval_push_send(
    p_member,
    jsonb_build_object('title', 'Confirm your new number',
      'body', v_name || ' proposed a new mobile number for your account. Open the app to confirm it.'),
    jsonb_build_object('type', 'phone_proposal'));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_propose_member_phone(uuid, text) from public, anon;
grant execute on function public.approver_propose_member_phone(uuid, text) to authenticated;

-- ---- The member reads / cancels / applies their own proposal -------------------------------------
create or replace function public.member_phone_proposal()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  r    jsonb;
begin
  if v_me is null then
    return null;
  end if;
  select jsonb_build_object('id', q.id, 'proposed_phone', q.proposed_phone,
           'by_name', coalesce(nullif(btrim(p.name), ''), 'your team'), 'created_at', q.created_at)
    into r
    from public.member_phone_proposals q
    left join public.profiles p on p.id = q.proposed_by
   where q.member_id = v_me and q.status = 'pending'
   order by q.created_at desc
   limit 1;
  return r;
end;
$$;
revoke execute on function public.member_phone_proposal() from public, anon;
grant execute on function public.member_phone_proposal() to authenticated;

create or replace function public.member_cancel_phone_proposal(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.member_phone_proposals set status = 'cancelled', decided_at = now()
   where id = p_id and member_id = v_me and status = 'pending';
  return jsonb_build_object('ok', found);
end;
$$;
revoke execute on function public.member_cancel_phone_proposal(uuid) from public, anon;
grant execute on function public.member_cancel_phone_proposal(uuid) to authenticated;

-- Marks the proposal applied once the member's number already matches it (the
-- app calls this after the change-number OTP succeeds; profiles.phone has
-- followed auth.users.phone by then).
create or replace function public.member_apply_phone_proposal(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  r    public.member_phone_proposals;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.member_phone_proposals
   where id = p_id and member_id = v_me and status = 'pending';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if public.normalize_phone_digits((select phone from public.profiles where id = v_me))
       is distinct from r.proposed_phone then
    raise exception 'phone_not_changed';  -- the number hasn't actually been changed yet
  end if;
  update public.member_phone_proposals set status = 'applied', decided_at = now() where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.member_apply_phone_proposal(uuid) from public, anon;
grant execute on function public.member_apply_phone_proposal(uuid) to authenticated;

notify pgrst, 'reload schema';
