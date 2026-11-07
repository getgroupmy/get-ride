-- ============================================================================
-- 0358: User teams — join a team by referral code, change teams (admin-approved),
-- and see your team's members.
--
-- A "team" rides on the existing referral graph (public.referrals): your team
-- lead is your referrer, and your team-mates are everyone else that lead
-- referred. This is the same relationship the approver "referral" scope and
-- "My Team" (0357) already use, so a lead who is an approver sees their team
-- there automatically.
--
-- States, from a member's point of view:
--   * no referrer yet        -> team_join(code): sets your referrer at once.
--   * already has a referrer  -> team_request_change(code, reason): files a
--     request an admin must approve/reject; approval moves your referral to the
--     new lead. Either outcome pushes the requester.
--
-- team_join does NOT award referral coins — that is the signup reward
-- (apply_referral, which stays the only coin-awarding writer and keeps its
-- 7-day window). Joining a team later is membership, not a reward.
--
-- Reads:
--   team_self()     your team: your lead (name) and any pending change request.
--   team_members()  your team-mates' name + a plate, the lead pinned first.
-- ============================================================================

-- ---- 0. Resolve a referral code to a user ---------------------------------------------------------
-- The same rule apply_referral uses: an explicit profiles.referral_code wins,
-- else the deterministic 8-char account-id code the apps share.
create or replace function public.team_resolve_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  -- An explicit referral_code (pri 1) wins over the account-id prefix (pri 2).
  select id from (
    select id, 1 as pri from public.profiles
     where upper(coalesce(referral_code, '')) = p_code
    union all
    select id, 2 as pri from public.profiles
     where length(p_code) = 8
       and upper(left(replace(id::text, '-', ''), 8)) = p_code
  ) q
  order by pri
  limit 1;
$$;
revoke execute on function public.team_resolve_code(text) from public, anon;
grant execute on function public.team_resolve_code(text) to authenticated;

-- ---- 1. The change-request store ------------------------------------------------------------------
create table if not exists public.team_change_requests (
  id            uuid primary key default gen_random_uuid(),
  requester_id  uuid not null references public.profiles(id) on delete cascade,
  from_lead_id  uuid references public.profiles(id) on delete set null,
  to_lead_id    uuid not null references public.profiles(id) on delete cascade,
  to_code       text not null,
  reason        text not null check (char_length(reason) between 1 and 500),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by    uuid references public.profiles(id) on delete set null,
  decided_at    timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 500),
  created_at    timestamptz not null default now()
);
comment on table public.team_change_requests is
  'Requests to move to a different team lead (0358): filed by a member, approved/rejected by an admin.';
-- At most one request awaiting a decision per person.
create unique index if not exists team_change_one_pending
  on public.team_change_requests (requester_id) where status = 'pending';
create index if not exists team_change_pending_idx
  on public.team_change_requests (created_at) where status = 'pending';

alter table public.team_change_requests enable row level security;
revoke all on public.team_change_requests from public, anon, authenticated;
grant select on public.team_change_requests to authenticated;
grant all on public.team_change_requests to service_role;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public'
                   and tablename = 'team_change_requests' and policyname = 'team_change_read') then
    create policy team_change_read on public.team_change_requests
      for select to authenticated
      using (requester_id = (select auth.uid()) or (select public.caller_is_admin()));
  end if;
end $$;

-- ---- 2. Join a team -------------------------------------------------------------------------------
create or replace function public.team_join(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := auth.uid();
  v_lead uuid;
  v_code text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if length(v_code) < 4 then
    raise exception 'invalid_code';
  end if;
  if exists (select 1 from public.referrals where referred_user_id = v_me) then
    raise exception 'already_on_team';  -- changing teams needs a change request
  end if;
  v_lead := public.team_resolve_code(v_code);
  if v_lead is null then
    raise exception 'code_not_found';
  end if;
  if v_lead = v_me then
    raise exception 'self_team';
  end if;
  insert into public.referrals (referrer_user_id, referred_user_id, code)
  values (v_lead, v_me, v_code);
  return jsonb_build_object('ok', true, 'lead_id', v_lead);
end;
$$;
revoke execute on function public.team_join(text) from public, anon;
grant execute on function public.team_join(text) to authenticated;

-- ---- 3. Request a team change ---------------------------------------------------------------------
create or replace function public.team_request_change(p_code text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me       uuid := auth.uid();
  v_cur_lead uuid;
  v_new_lead uuid;
  v_code     text;
  v_reason   text;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_reason := btrim(coalesce(p_reason, ''));
  if v_reason = '' then
    raise exception 'reason_required';
  end if;
  v_reason := left(v_reason, 500);
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if length(v_code) < 4 then
    raise exception 'invalid_code';
  end if;
  select referrer_user_id into v_cur_lead from public.referrals where referred_user_id = v_me;
  if v_cur_lead is null then
    raise exception 'not_on_team';  -- join a team first
  end if;
  v_new_lead := public.team_resolve_code(v_code);
  if v_new_lead is null then
    raise exception 'code_not_found';
  end if;
  if v_new_lead = v_me then
    raise exception 'self_team';
  end if;
  if v_new_lead = v_cur_lead then
    raise exception 'same_team';
  end if;
  if exists (select 1 from public.team_change_requests where requester_id = v_me and status = 'pending') then
    raise exception 'request_pending';
  end if;
  insert into public.team_change_requests (requester_id, from_lead_id, to_lead_id, to_code, reason)
  values (v_me, v_cur_lead, v_new_lead, v_code, v_reason);
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.team_request_change(text, text) from public, anon;
grant execute on function public.team_request_change(text, text) to authenticated;

-- ---- 4. The caller's team, for the Profile card ---------------------------------------------------
create or replace function public.team_self()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me       uuid := auth.uid();
  v_lead     uuid;
  v_lead_nm  text;
  v_pending  jsonb;
begin
  if v_me is null then
    return null;
  end if;
  select referrer_user_id into v_lead from public.referrals where referred_user_id = v_me;
  if v_lead is not null then
    select coalesce(nullif(btrim(name), ''), 'User') into v_lead_nm from public.profiles where id = v_lead;
  end if;
  select jsonb_build_object('id', r.id, 'to_name',
           coalesce(nullif(btrim(p.name), ''), 'User'), 'created_at', r.created_at)
    into v_pending
    from public.team_change_requests r
    left join public.profiles p on p.id = r.to_lead_id
   where r.requester_id = v_me and r.status = 'pending'
   order by r.created_at desc
   limit 1;
  return jsonb_build_object(
    'on_team', v_lead is not null,
    'lead_id', v_lead,
    'lead_name', v_lead_nm,
    'pending_change', v_pending);
end;
$$;
revoke execute on function public.team_self() from public, anon;
grant execute on function public.team_self() to authenticated;

-- ---- 5. The caller's team-mates -------------------------------------------------------------------
-- The lead and everyone else the lead referred, each with a plate (an approved
-- vehicle first). Name + plate only — this is a members directory, not a profile.
create or replace function public.team_members()
returns table (
  member_id uuid,
  name      text,
  avatar_url text,
  plate     text,
  is_lead   boolean,
  is_me     boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me   uuid := auth.uid();
  v_lead uuid;
begin
  if v_me is null then
    return;
  end if;
  select referrer_user_id into v_lead from public.referrals where referred_user_id = v_me;
  if v_lead is null then
    return;  -- not on a team
  end if;

  return query
  with team as (
    select v_lead as uid, true as lead
    union
    select r.referred_user_id, false from public.referrals r where r.referrer_user_id = v_lead
  )
  select p.id,
         coalesce(nullif(btrim(p.name), ''), 'User'),
         coalesce(nullif(btrim(p.avatar_url), ''), nullif(btrim(p.profile_image), '')),
         v.plate,
         t.lead,
         (p.id = v_me)
    from team t
    join public.profiles p on p.id = t.uid
    left join lateral (
      select nullif(btrim(vv.plate), '') as plate
        from public.vehicle vv
       where vv.auth_user_id = p.id
       order by (vv.status = 'approved') desc, vv.created_at
       limit 1
    ) v on true
   order by t.lead desc, lower(coalesce(nullif(btrim(p.name), ''), 'User')), p.id;
end;
$$;
revoke execute on function public.team_members() from public, anon;
grant execute on function public.team_members() to authenticated;

-- ---- 6. Admin: review team-change requests --------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_list_team_changes', 'admin-team-changes'),
  ('rpc:admin_decide_team_change', 'admin-team-changes')
on conflict do nothing;

create or replace function public.admin_list_team_changes(p_status text default 'pending')
returns table (
  id            uuid,
  requester_id  uuid,
  requester_name text,
  requester_phone text,
  from_lead_id  uuid,
  from_lead_name text,
  to_lead_id    uuid,
  to_lead_name  text,
  to_code       text,
  reason        text,
  status        text,
  created_at    timestamptz,
  decided_at    timestamptz,
  decision_note text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_list_team_changes') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select r.id, r.requester_id,
           coalesce(nullif(btrim(rp.name), ''), 'User'), rp.phone,
           r.from_lead_id, coalesce(nullif(btrim(fp.name), ''), 'User'),
           r.to_lead_id, coalesce(nullif(btrim(tp.name), ''), 'User'),
           r.to_code, r.reason, r.status, r.created_at, r.decided_at, r.decision_note
      from public.team_change_requests r
      join public.profiles rp on rp.id = r.requester_id
      left join public.profiles fp on fp.id = r.from_lead_id
      left join public.profiles tp on tp.id = r.to_lead_id
     where p_status is null or p_status = 'all' or r.status = p_status
     order by (r.status = 'pending') desc, r.created_at desc;
end;
$$;
revoke execute on function public.admin_list_team_changes(text) from public, anon;
grant execute on function public.admin_list_team_changes(text) to authenticated;

create or replace function public.admin_decide_team_change(p_id uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r      public.team_change_requests;
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  v_has  boolean;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_decide_team_change') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_action not in ('approve', 'reject') then
    raise exception 'bad_action';
  end if;
  select * into r from public.team_change_requests where id = p_id and status = 'pending';
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  if p_action = 'approve' then
    -- Move the requester's referral to the new lead (or create it if it is gone).
    select exists (select 1 from public.referrals where referred_user_id = r.requester_id) into v_has;
    if v_has then
      update public.referrals
         set referrer_user_id = r.to_lead_id, code = r.to_code
       where referred_user_id = r.requester_id;
    else
      insert into public.referrals (referrer_user_id, referred_user_id, code)
      values (r.to_lead_id, r.requester_id, r.to_code);
    end if;
  end if;

  update public.team_change_requests
     set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = v_note
   where id = p_id;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'team_change.' || p_action, r.requester_id,
          jsonb_build_object('to_lead_id', r.to_lead_id, 'note', v_note));

  perform public.approval_push_send(
    r.requester_id,
    case when p_action = 'approve'
         then jsonb_build_object('title', 'Team change approved', 'body', 'You have moved to your new team.')
         else jsonb_build_object('title', 'Team change rejected',
                'body', coalesce(v_note, 'Your team change request was not approved.')) end,
    jsonb_build_object('type', 'team_change', 'status',
                       case when p_action = 'approve' then 'approved' else 'rejected' end));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.admin_decide_team_change(uuid, text, text) from public, anon;
grant execute on function public.admin_decide_team_change(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
