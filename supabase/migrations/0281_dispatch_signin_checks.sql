-- ============================================================================
-- 0281 — Dispatch IDs: what someone does when they sign in.
--
-- Re-runnable: columns and tables "if not exists", functions "create or
-- replace", policies dropped first.
--
-- Why: Admin → Dispatch → Accounts → "Create an ID" made the account (or
-- gave the role to an existing one) and the person set their own PIN on first
-- sign-in. Nothing showed who they were. Now each grant says what they must
-- do before the role opens, and the server holds the role shut until they
-- have.
--
-- 1. Per grant (dispatch_stand_people, dispatch_fleet_owners):
--      verify_selfie  take a live selfie when there is no approved (or
--                     received) photo, or the last one was rejected;
--      verify_id      upload MyKad or passport (front + back) when there is
--                     no ID on record, it was rejected, or it ran out; the
--                     role stays shut while the ID waits for review;
--      verify_days    "finish within X days" (null: no deadline), and
--      verify_by      when that runs out. Past it with steps left the role is
--                     "Paused: not verified" (it is shut either way; the
--                     word is for the admin and the person).
--    The PIN is not a switch: the app's sign-in already keeps an account
--    with no PIN on "Set your PIN" (0192); 'pin' is reported, not gated.
--    dispatch_grant takes the switches in p_perms (verify_selfie, verify_id,
--    verify_days), so its signature and the dispatch-account function's call
--    stay as they were. dispatch_set_verify changes them afterwards
--    (Dispatch → Accounts, Users → Edit User).
-- 2. identity_checks: every selfie and ID photo sent, with what the phone
--    found (liveness: blink or head turn, or 'not_checked' where the phone
--    can't tell; the name, IC and expiry read off the card), what the
--    server saw against the profile (mismatch), the face match score the
--    face-compare function stores, and the admin's decision with a reason
--    from the list. Profile photo selfies (sign-up, Edit profile, partner
--    sign-up) are kept too, purpose 'profile', with no review status: so an
--    admin sees whether a photo was taken live.
-- 3. dispatch_devices: the phones someone holding a dispatch role opened it
--    on. The first time, the phones already on record for them (push_tokens,
--    user_sessions' push device key) are known; with none, this phone is.
--    A phone not seen before needs a live selfie before the role opens
--    ('recheck').
-- 4. The gate: dispatch_role_needs(user, selfie, id) is what is still
--    needed; dispatch_row_open is true when nothing is. dispatch_caller_stand_ids,
--    dispatch_caller_admin_stand_ids, dispatch_caller_fleet_ids,
--    dispatch_person_can, dispatch_my_stands and dispatch_may_grant (a stand
--    admin making staff) only count open grants, so every RLS policy and RPC
--    built on them follows.
-- 5. dispatch_my_checks(device): the app's one call — what is still needed,
--    with reasons. identity_check_submit: the phone sends a selfie or an ID.
--    identity_check_review: an admin with a Documents page decides, with a
--    reason from the list; the person is told by push. Admins with a
--    Documents page get a push when something is sent (send_push_webhook,
--    the existing x-push-secret path).
-- 6. dispatch_verify_config / dispatch_set_verify_config: how many days
--    before an ID runs out the person is asked for a new one (30).
-- ============================================================================

-- 1. The switches on each grant ------------------------------------------------------------------
alter table public.dispatch_stand_people
  add column if not exists verify_selfie boolean not null default false,
  add column if not exists verify_id boolean not null default false,
  add column if not exists verify_days integer check (verify_days is null or verify_days between 1 and 365),
  add column if not exists verify_by timestamptz;
alter table public.dispatch_fleet_owners
  add column if not exists verify_selfie boolean not null default false,
  add column if not exists verify_id boolean not null default false,
  add column if not exists verify_days integer check (verify_days is null or verify_days between 1 and 365),
  add column if not exists verify_by timestamptz;

-- A stand admin's change to their staff: access and on/off only (as 0251),
-- now never the sign-in checks either: those are the admin's.
create or replace function public.dispatch_people_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('dispatch_stand_people') then
    return new;
  end if;
  if (new.stand_id, new.user_id, new.role, new.created_by, new.created_at,
      new.verify_selfie, new.verify_id, new.verify_days, new.verify_by)
     is distinct from (old.stand_id, old.user_id, old.role, old.created_by, old.created_at,
                       old.verify_selfie, old.verify_id, old.verify_days, old.verify_by)
     or new.role <> 'staff' then
    raise exception 'DISPATCH_STAFF_ONLY' using errcode = '42501',
      hint = 'A stand admin changes their staff''s access and on/off only.';
  end if;
  return new;
end;
$$;

-- 2. What was sent ---------------------------------------------------------------------------------
create table if not exists public.identity_checks (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  kind            text not null check (kind in ('selfie', 'id')),
  -- first: asked by a grant; recheck: a new phone; profile: a profile photo
  -- (not reviewed).
  purpose         text not null default 'first' check (purpose in ('first', 'recheck', 'profile')),
  doc_type        text check (doc_type is null or doc_type in ('mykad', 'passport')),
  file_url        text not null check (char_length(file_url) <= 1000),
  file_url_back   text check (file_url_back is null or char_length(file_url_back) <= 1000),
  liveness        text check (liveness is null or liveness in ('passed', 'not_checked')),
  -- How it was passed: 'blink' or 'turn'.
  liveness_detail text check (liveness_detail is null or char_length(liveness_detail) <= 40),
  device_key      text check (device_key is null or char_length(device_key) <= 128),
  -- Read off the card by the phone, as read.
  read_name       text check (read_name is null or char_length(read_name) <= 120),
  read_ic         text check (read_ic is null or char_length(read_ic) <= 40),
  read_expiry     date,
  expiry_date     date,
  -- 'name' / 'ic': what was read differs from the profile.
  mismatch        text[] not null default '{}',
  face_score      numeric(5, 2) check (face_score is null or face_score between 0 and 100),
  face_state      text check (face_state is null or face_state in ('match', 'no_match', 'no_face', 'not_checked', 'error')),
  face_checked_at timestamptz,
  status          text check (status is null or status in ('Pending Review', 'Approved', 'Rejected')),
  reject_reason   text check (reject_reason is null or reject_reason in
                    ('blurry', 'face_unclear', 'name_mismatch', 'expired', 'wrong_document', 'other')),
  reject_note     text check (reject_note is null or char_length(reject_note) <= 500),
  reviewed_by     uuid references public.profiles(id) on delete set null,
  reviewed_at     timestamptz,
  created_at      timestamptz not null default now(),
  check ((purpose = 'profile') = (status is null)),
  check (kind = 'selfie' or purpose <> 'recheck')
);
create index if not exists identity_checks_user_idx on public.identity_checks (user_id, kind, created_at desc);
create index if not exists identity_checks_waiting_idx on public.identity_checks (created_at desc)
  where status = 'Pending Review';
create index if not exists identity_checks_reviewed_by_idx on public.identity_checks (reviewed_by);

-- 3. The phones a role holder opened it on ------------------------------------------------------
create table if not exists public.dispatch_devices (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  device_key text not null check (char_length(device_key) between 8 and 128),
  known      boolean not null default false,
  check_id   uuid references public.identity_checks(id) on delete set null,
  first_seen timestamptz not null default now(),
  seen_at    timestamptz not null default now(),
  primary key (user_id, device_key)
);
create index if not exists dispatch_devices_seen_idx on public.dispatch_devices (user_id, seen_at desc);
create index if not exists dispatch_devices_check_idx on public.dispatch_devices (check_id);

-- Who reads them: the person their own; admins with a Documents, Users or
-- Dispatch Accounts page.
create or replace function public.identity_admin_reads()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.admin_access a
     where a.profile_id = auth.uid()
       and a.page in ('*', 'admin-documents', 'admin-documents-users', 'admin-documents-partners',
                      'admin-users', 'admin-user-edit', 'admin-dispatch-accounts'));
$$;
revoke execute on function public.identity_admin_reads() from public, anon;
grant execute on function public.identity_admin_reads() to authenticated;

alter table public.identity_checks enable row level security;
alter table public.dispatch_devices enable row level security;
revoke all on public.identity_checks, public.dispatch_devices from anon;
revoke insert, update, delete on public.identity_checks, public.dispatch_devices from authenticated;

drop policy if exists "identity_checks read" on public.identity_checks;
create policy "identity_checks read" on public.identity_checks
  for select to authenticated using (user_id = (select auth.uid()) or (select public.identity_admin_reads()));
drop policy if exists "dispatch_devices read" on public.dispatch_devices;
create policy "dispatch_devices read" on public.dispatch_devices
  for select to authenticated using (user_id = (select auth.uid()) or (select public.identity_admin_reads()));

insert into public.admin_table_pages (target, page) values
  ('rpc:identity_check_review',        'admin-documents'),
  ('rpc:identity_check_review',        'admin-documents-users'),
  ('rpc:identity_check_review',        'admin-documents-partners'),
  ('rpc:dispatch_set_verify',          'admin-dispatch-accounts'),
  ('rpc:dispatch_set_verify',          'admin-user-edit'),
  ('rpc:dispatch_set_verify_config',   'admin-dispatch-accounts')
on conflict do nothing;

-- ---- What is on record ---------------------------------------------------------------------------
-- How many days before an ID runs out the person is asked for a new one.
create or replace function public.identity_renew_days()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select least(greatest((s.value->>'renewDays')::integer, 0), 365)
      from public.app_settings s
     where s.key = 'dispatch_verify' and jsonb_typeof(s.value->'renewDays') = 'number'), 30);
$$;
revoke execute on function public.identity_renew_days() from public, anon, authenticated;

-- [p_user]'s photo: ok (approved, or an approved partner's photo), received
-- (waiting for review: enough to go on), rejected (with the reason), missing.
create or replace function public.identity_photo_state(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.identity_checks;
begin
  select * into c from public.identity_checks
   where user_id = p_user and kind = 'selfie' and purpose <> 'profile'
   order by created_at desc limit 1;
  if found then
    if c.status = 'Rejected' then
      return jsonb_build_object('state', 'rejected', 'reason', c.reject_reason, 'note', c.reject_note, 'check_id', c.id);
    end if;
    return jsonb_build_object('state', case when c.status = 'Approved' then 'ok' else 'received' end,
                              'check_id', c.id, 'liveness', c.liveness);
  end if;
  if exists (select 1 from public.partners pa
               join public.profiles p on p.id = pa.auth_user_id
              where pa.auth_user_id = p_user and pa.status::text = 'approved'
                and nullif(btrim(coalesce(p.avatar_url, '')), '') is not null) then
    return jsonb_build_object('state', 'ok');
  end if;
  return jsonb_build_object('state', 'missing');
end;
$$;
revoke execute on function public.identity_photo_state(uuid) from public, anon, authenticated;

-- [p_user]'s ID: ok, renew (runs out within identity_renew_days), pending
-- (sent, waiting for review, nothing valid before it), rejected, expired,
-- missing. An approved check counts, or the profile's ID verified on Users →
-- ID documents. A newer upload waiting while the old one is still good is ok.
create or replace function public.identity_id_state(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days integer := public.identity_renew_days();
  v_last public.identity_checks;
  v_good public.identity_checks;
  v_had boolean := false;
  v_expiry date;
  v_newer boolean;
  p public.profiles;
begin
  select * into v_last from public.identity_checks
   where user_id = p_user and kind = 'id' order by created_at desc limit 1;
  select * into v_good from public.identity_checks
   where user_id = p_user and kind = 'id' and status = 'Approved' order by created_at desc limit 1;
  if v_good.id is not null then
    v_had := true;
    v_expiry := v_good.expiry_date;
  else
    select * into p from public.profiles where id = p_user;
    if p.id_verified::text in ('Verified', 'Expired') then
      v_had := true;
      v_expiry := case when p.id_verified::text = 'Expired' then coalesce(p.id_expiry_date, current_date - 1)
                       else p.id_expiry_date end;
    end if;
  end if;
  v_newer := v_last.id is not null and v_last.status <> 'Approved'
             and (v_good.id is null or v_last.created_at > v_good.created_at);

  if v_had and (v_expiry is null or v_expiry >= current_date) then
    if v_expiry is not null and v_expiry < current_date + v_days
       and not (v_newer and v_last.status = 'Pending Review') then
      return jsonb_build_object('state', 'renew', 'expiry', v_expiry,
        'reason', case when v_newer then v_last.reject_reason end,
        'note', case when v_newer then v_last.reject_note end);
    end if;
    return jsonb_build_object('state', 'ok', 'expiry', v_expiry,
                              'renewing', v_newer and v_last.status = 'Pending Review');
  end if;
  if v_newer and v_last.status = 'Pending Review' then
    return jsonb_build_object('state', 'pending', 'check_id', v_last.id, 'expiry', v_last.expiry_date);
  end if;
  if v_newer and v_last.status = 'Rejected' then
    return jsonb_build_object('state', 'rejected', 'reason', v_last.reject_reason, 'note', v_last.reject_note,
                              'check_id', v_last.id);
  end if;
  if v_had then
    return jsonb_build_object('state', 'expired', 'expiry', v_expiry);
  end if;
  return jsonb_build_object('state', 'missing');
end;
$$;
revoke execute on function public.identity_id_state(uuid) from public, anon, authenticated;

-- Whether the phone [p_user] last opened their role on is one not seen
-- before (and no selfie taken on it since).
create or replace function public.dispatch_recheck_due(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select not d.known from public.dispatch_devices d
                    where d.user_id = p_user order by d.seen_at desc limit 1), false);
$$;
revoke execute on function public.dispatch_recheck_due(uuid) from public, anon, authenticated;

-- 4. The gate ---------------------------------------------------------------------------------
-- What [p_user] still has to do for a grant asking [p_selfie] / [p_id]:
-- 'selfie', 'recheck' (a new phone; one selfie answers both), 'id', and
-- 'pending' (the ID waits for review). Empty: the grant is open.
create or replace function public.dispatch_role_needs(p_user uuid, p_selfie boolean, p_id boolean)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text[] := '{}';
  s text;
begin
  if p_user is null then
    return v;
  end if;
  if coalesce(p_selfie, false) then
    s := public.identity_photo_state(p_user)->>'state';
    if s in ('missing', 'rejected') then
      v := array_append(v, 'selfie');
    end if;
  end if;
  if not ('selfie' = any (v)) and public.dispatch_recheck_due(p_user) then
    v := array_append(v, 'recheck');
  end if;
  if coalesce(p_id, false) then
    s := public.identity_id_state(p_user)->>'state';
    if s in ('missing', 'rejected', 'expired') then
      v := array_append(v, 'id');
    elsif s = 'pending' then
      v := array_append(v, 'pending');
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function public.dispatch_role_needs(uuid, boolean, boolean) from public, anon, authenticated;

create or replace function public.dispatch_row_open(p_user uuid, p_selfie boolean, p_id boolean)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(cardinality(public.dispatch_role_needs(p_user, p_selfie, p_id)), 0) = 0;
$$;
revoke execute on function public.dispatch_row_open(uuid, boolean, boolean) from public, anon, authenticated;

-- The 0251 lookups, counting open grants only.
create or replace function public.dispatch_caller_stand_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(o.stand_id), '{}')
    from public.dispatch_stand_people o
    join public.dispatch_stands s on s.id = o.stand_id
   where o.user_id = auth.uid() and o.active and s.active and not s.admin_only
     and public.dispatch_row_open(o.user_id, o.verify_selfie, o.verify_id);
$$;
revoke execute on function public.dispatch_caller_stand_ids() from public, anon;
grant execute on function public.dispatch_caller_stand_ids() to authenticated;

create or replace function public.dispatch_caller_admin_stand_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(o.stand_id), '{}')
    from public.dispatch_stand_people o
    join public.dispatch_stands s on s.id = o.stand_id
   where o.user_id = auth.uid() and o.role = 'admin' and o.active and s.active and not s.admin_only
     and public.dispatch_row_open(o.user_id, o.verify_selfie, o.verify_id);
$$;
revoke execute on function public.dispatch_caller_admin_stand_ids() from public, anon;
grant execute on function public.dispatch_caller_admin_stand_ids() to authenticated;

create or replace function public.dispatch_caller_fleet_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(f.group_id), '{}')
    from public.dispatch_fleet_owners f
    join public.dispatch_groups g on g.id = f.group_id
   where f.user_id = auth.uid() and f.active and g.active and g.kind = 'fleet'
     and public.dispatch_row_open(f.user_id, f.verify_selfie, f.verify_id);
$$;
revoke execute on function public.dispatch_caller_fleet_ids() from public, anon;
grant execute on function public.dispatch_caller_fleet_ids() to authenticated;

create or replace function public.dispatch_person_can(p_user uuid, p_stand uuid, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case
      when o.role = 'admin' then true
      else case p_perm
        when 'use' then true
        when 'assign' then o.can_assign
        when 'broadcast' then o.can_broadcast
        when 'fixed_fare' then o.can_fixed_fare
        when 'cancel' then o.can_cancel
        when 'reassign' then o.can_reassign
        when 'reports' then o.can_reports
        else false end end
      from public.dispatch_stand_people o
      join public.dispatch_stands s on s.id = o.stand_id and s.active and not s.admin_only
     where o.stand_id = p_stand and o.user_id = p_user and o.active
       and public.dispatch_row_open(o.user_id, o.verify_selfie, o.verify_id)), false);
$$;
revoke execute on function public.dispatch_person_can(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.dispatch_my_stands()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admin boolean := public.caller_admin_can_write('rpc:dispatch_console');
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'kind', s.kind, 'code', s.code, 'address', s.address, 'admin_only', s.admin_only,
      'lat', s.lat, 'lng', s.lng, 'allow_fixed_fare', s.allow_fixed_fare, 'settlement', s.settlement,
      'fee_type', s.fee_type, 'fee_value', s.fee_value, 'fee_bearer', s.fee_bearer, 'fee_set_by', s.fee_set_by,
      'platform_fee_type', s.platform_fee_type, 'platform_fee_value', s.platform_fee_value,
      'credit_limit', s.credit_limit, 'credit_limit_set_by', s.credit_limit_set_by,
      'credit_limit_max', s.credit_limit_max,
      'admin', v_admin,
      'role', case when v_admin then 'admin' else o.role end,
      'perms', jsonb_build_object(
        'assign', v_admin or o.role = 'admin' or coalesce(o.can_assign, false),
        'broadcast', v_admin or o.role = 'admin' or coalesce(o.can_broadcast, false),
        'fixed_fare', v_admin or o.role = 'admin' or coalesce(o.can_fixed_fare, false),
        'cancel', v_admin or o.role = 'admin' or coalesce(o.can_cancel, false),
        'reassign', v_admin or o.role = 'admin' or coalesce(o.can_reassign, false),
        'reports', v_admin or o.role = 'admin' or coalesce(o.can_reports, false),
        'staff', o.role = 'admin'),
      'groups', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', g.id, 'name', g.name, 'kind', g.kind, 'members_first_sec', g.members_first_sec,
          'members', (select count(*) from public.dispatch_group_members m
                       where m.group_id = g.id and m.status = 'approved')) order by g.name)
          from public.dispatch_groups g
         where g.active
           and (exists (select 1 from public.dispatch_stand_groups sg where sg.stand_id = s.id and sg.group_id = g.id)
                or v_admin)), '[]'::jsonb)
    ) order by s.name)
      from public.dispatch_stands s
      left join public.dispatch_stand_people o on o.stand_id = s.id and o.user_id = auth.uid() and o.active
             and public.dispatch_row_open(o.user_id, o.verify_selfie, o.verify_id)
     where s.active and (v_admin or (o.user_id is not null and not s.admin_only))), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_my_stands() from public, anon;
grant execute on function public.dispatch_my_stands() to authenticated;

-- A stand admin makes staff only while their own grant is open.
create or replace function public.dispatch_may_grant(p_caller uuid, p_kind text, p_stand_ids uuid[], p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_caller is not null and case p_kind
    when 'stand_admin' then public.dispatch_admin_edits(p_caller, 'admin-dispatch-accounts')
      and coalesce(cardinality(p_stand_ids), 0) > 0
      and (select count(*) from public.dispatch_stands s
            where s.id = any (p_stand_ids) and not s.admin_only) = cardinality(p_stand_ids)
    when 'fleet_owner' then public.dispatch_admin_edits(p_caller, 'admin-dispatch-accounts')
      and exists (select 1 from public.dispatch_groups g where g.id = p_group and g.kind = 'fleet')
    when 'staff' then coalesce(cardinality(p_stand_ids), 0) > 0
      and not exists (select 1 from public.dispatch_stands s where s.id = any (p_stand_ids) and s.admin_only)
      and (public.dispatch_admin_edits(p_caller, 'admin-dispatch-accounts')
           or not exists (
             select 1 from unnest(p_stand_ids) x(stand_id)
              where not exists (select 1 from public.dispatch_stand_people o
                                 where o.stand_id = x.stand_id and o.user_id = p_caller
                                   and o.role = 'admin' and o.active
                                   and public.dispatch_row_open(o.user_id, o.verify_selfie, o.verify_id))))
    else false end;
$$;
revoke execute on function public.dispatch_may_grant(uuid, text, uuid[], uuid) from public, anon, authenticated;
grant execute on function public.dispatch_may_grant(uuid, text, uuid[], uuid) to service_role;

-- ---- Granting, with the switches ---------------------------------------------------------------
-- As 0251, and [p_perms] may also carry verify_selfie, verify_id and
-- verify_days. A re-grant without them keeps what the grant had.
create or replace function public.dispatch_grant(
  p_caller uuid, p_user uuid, p_kind text, p_name text, p_phone text,
  p_stand_ids uuid[] default '{}', p_group uuid default null, p_perms jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stand uuid;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_where text;
  v_perms jsonb := coalesce(p_perms, '{}');
  v_has_verify boolean := coalesce(p_perms, '{}') ?| array['verify_selfie', 'verify_id', 'verify_days'];
  v_selfie boolean := coalesce((p_perms->>'verify_selfie')::boolean, false);
  v_id boolean := coalesce((p_perms->>'verify_id')::boolean, false);
  v_days integer;
  v_by timestamptz;
begin
  if not public.dispatch_may_grant(p_caller, p_kind, p_stand_ids, p_group) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'DISPATCH_NO_ACCOUNT' using errcode = '22023';
  end if;
  if v_name is null or char_length(v_name) > 80 then
    raise exception 'DISPATCH_NAME' using errcode = '22023', hint = 'Give their name.';
  end if;
  if p_user = p_caller and p_kind = 'staff' then
    raise exception 'DISPATCH_SELF' using errcode = '22023', hint = 'You can''t add yourself as staff.';
  end if;
  if jsonb_typeof(v_perms->'verify_days') = 'number' and (v_selfie or v_id) then
    v_days := (v_perms->>'verify_days')::numeric::integer;
    if v_days not between 1 and 365 then
      raise exception 'DISPATCH_VERIFY_DAYS' using errcode = '22023', hint = 'Give 1 to 365 days, or leave it blank.';
    end if;
    v_by := now() + make_interval(days => v_days);
  end if;

  if p_kind in ('stand_admin', 'staff') then
    foreach v_stand in array p_stand_ids loop
      if p_kind = 'staff' and exists (select 1 from public.dispatch_stand_people o
                                       where o.stand_id = v_stand and o.user_id = p_user and o.role = 'admin') then
        raise exception 'DISPATCH_ALREADY_ADMIN' using errcode = '22023',
          hint = 'They are already the stand admin there.';
      end if;
      insert into public.dispatch_stand_people as o (stand_id, user_id, role, name, phone,
        can_assign, can_broadcast, can_fixed_fare, can_cancel, can_reassign, can_reports, active, created_by,
        verify_selfie, verify_id, verify_days, verify_by)
      values (v_stand, p_user, case when p_kind = 'stand_admin' then 'admin' else 'staff' end, v_name, p_phone,
        p_kind = 'stand_admin' or coalesce((p_perms->>'assign')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'broadcast')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'fixed_fare')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'cancel')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'reassign')::boolean, false),
        p_kind = 'stand_admin' or coalesce((p_perms->>'reports')::boolean, false),
        true, p_caller, v_selfie, v_id, v_days, v_by)
      on conflict (stand_id, user_id) do update set
        role = excluded.role, name = excluded.name, phone = coalesce(excluded.phone, o.phone),
        can_assign = excluded.can_assign, can_broadcast = excluded.can_broadcast,
        can_fixed_fare = excluded.can_fixed_fare, can_cancel = excluded.can_cancel,
        can_reassign = excluded.can_reassign, can_reports = excluded.can_reports,
        verify_selfie = case when v_has_verify then excluded.verify_selfie else o.verify_selfie end,
        verify_id = case when v_has_verify then excluded.verify_id else o.verify_id end,
        verify_days = case when v_has_verify then excluded.verify_days else o.verify_days end,
        verify_by = case when v_has_verify then excluded.verify_by else o.verify_by end,
        active = true, updated_at = now();
    end loop;
    select string_agg(s.name, ', ' order by s.name) into v_where from public.dispatch_stands s where s.id = any (p_stand_ids);
  else
    insert into public.dispatch_fleet_owners as f (group_id, user_id, name, phone, active, created_by,
      verify_selfie, verify_id, verify_days, verify_by)
    values (p_group, p_user, v_name, p_phone, true, p_caller, v_selfie, v_id, v_days, v_by)
    on conflict (group_id, user_id) do update set name = excluded.name, phone = coalesce(excluded.phone, f.phone),
      verify_selfie = case when v_has_verify then excluded.verify_selfie else f.verify_selfie end,
      verify_id = case when v_has_verify then excluded.verify_id else f.verify_id end,
      verify_days = case when v_has_verify then excluded.verify_days else f.verify_days end,
      verify_by = case when v_has_verify then excluded.verify_by else f.verify_by end,
      active = true;
    select g.name into v_where from public.dispatch_groups g where g.id = p_group;
  end if;

  perform public.dispatch_sms(coalesce(p_phone, (select phone from public.profiles where id = p_user)),
    'GET.ride: you are now ' || case p_kind when 'stand_admin' then 'the stand admin' when 'staff' then 'staff'
                                            else 'the fleet owner' end
    || ' for ' || coalesce(v_where, 'GET.ride') || '. Sign in to the GET.ride app with this number; '
    || 'a new account gets a code by SMS to set its PIN.'
    || case when v_selfie and v_id then ' Have your MyKad or passport ready: you will take a selfie and a photo of it.'
            when v_id then ' Have your MyKad or passport ready to photograph.'
            when v_selfie then ' You will take a selfie.'
            else '' end);
  return jsonb_build_object('user_id', p_user, 'kind', p_kind, 'granted', true);
end;
$$;
revoke execute on function public.dispatch_grant(uuid, uuid, text, text, text, uuid[], uuid, jsonb) from public, anon, authenticated;
grant execute on function public.dispatch_grant(uuid, uuid, text, text, text, uuid[], uuid, jsonb) to service_role;

-- Changes the switches of every grant of [p_kind] [p_user] holds. A new
-- number of days starts the deadline again from now; the same number keeps it.
create or replace function public.dispatch_set_verify(
  p_user uuid, p_kind text, p_selfie boolean, p_id boolean, p_days integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days integer := case when coalesce(p_selfie, false) or coalesce(p_id, false) then p_days end;
  n integer;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:dispatch_set_verify') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_days is not null and v_days not between 1 and 365 then
    raise exception 'DISPATCH_VERIFY_DAYS' using errcode = '22023', hint = 'Give 1 to 365 days, or leave it blank.';
  end if;
  if p_kind = 'fleet_owner' then
    update public.dispatch_fleet_owners f set
      verify_selfie = coalesce(p_selfie, false), verify_id = coalesce(p_id, false), verify_days = v_days,
      verify_by = case when v_days is null then null
                       when f.verify_days is not distinct from v_days and f.verify_by is not null then f.verify_by
                       else now() + make_interval(days => v_days) end
     where f.user_id = p_user;
  elsif p_kind in ('stand_admin', 'staff') then
    update public.dispatch_stand_people o set
      verify_selfie = coalesce(p_selfie, false), verify_id = coalesce(p_id, false), verify_days = v_days,
      verify_by = case when v_days is null then null
                       when o.verify_days is not distinct from v_days and o.verify_by is not null then o.verify_by
                       else now() + make_interval(days => v_days) end
     where o.user_id = p_user and o.role = case p_kind when 'stand_admin' then 'admin' else 'staff' end;
  else
    raise exception 'DISPATCH_KIND' using errcode = '22023';
  end if;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'DISPATCH_NO_GRANT' using errcode = '22023', hint = 'They don''t hold that role.';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'dispatch.set_verify', p_user,
          jsonb_build_object('kind', p_kind, 'selfie', coalesce(p_selfie, false), 'id', coalesce(p_id, false),
                             'days', v_days));
  return jsonb_build_object('updated', n);
end;
$$;
revoke execute on function public.dispatch_set_verify(uuid, text, boolean, boolean, integer) from public, anon;
grant execute on function public.dispatch_set_verify(uuid, text, boolean, boolean, integer) to authenticated;

-- What one account's grants ask and where they stand, for the admin lists.
create or replace function public.dispatch_verify_json(p_user uuid, p_selfie boolean, p_id boolean,
  p_days integer, p_by timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_needs text[] := public.dispatch_role_needs(p_user, p_selfie, p_id);
begin
  if not exists (select 1 from public.profiles where id = p_user and pin_hash is not null) then
    v_needs := array_prepend('pin', v_needs);
  end if;
  return jsonb_build_object(
    'selfie', coalesce(p_selfie, false), 'id', coalesce(p_id, false), 'days', p_days, 'by', p_by,
    'needs', to_jsonb(v_needs),
    'paused', p_by is not null and p_by < now()
              and exists (select 1 from unnest(v_needs) n where n not in ('pending', 'pin')));
end;
$$;
revoke execute on function public.dispatch_verify_json(uuid, boolean, boolean, integer, timestamptz)
  from public, anon, authenticated;

-- 0251's list of IDs, with each one's sign-in checks.
create or replace function public.dispatch_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object(
      'kind', 'stand_admin', 'user_id', o.user_id, 'name', max(o.name), 'phone', max(o.phone),
      'active', bool_or(o.active),
      'places', jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name),
      'staff', (select count(*) from public.dispatch_stand_people x
                 where x.role = 'staff' and x.stand_id = any (array_agg(o.stand_id))),
      'verify', public.dispatch_verify_json(o.user_id, bool_or(o.verify_selfie), bool_or(o.verify_id),
                                            max(o.verify_days), min(o.verify_by))) as x
      from public.dispatch_stand_people o
      join public.dispatch_stands s on s.id = o.stand_id
     where o.role = 'admin'
     group by o.user_id
    union all
    select jsonb_build_object(
      'kind', 'fleet_owner', 'user_id', f.user_id, 'name', max(f.name), 'phone', max(f.phone),
      'active', bool_or(f.active),
      'places', jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) order by g.name), 'staff', 0,
      'verify', public.dispatch_verify_json(f.user_id, bool_or(f.verify_selfie), bool_or(f.verify_id),
                                            max(f.verify_days), min(f.verify_by)))
      from public.dispatch_fleet_owners f
      join public.dispatch_groups g on g.id = f.group_id
     group by f.user_id) y(x)), '[]'::jsonb);
end;
$$;
revoke execute on function public.dispatch_accounts() from public, anon;
grant execute on function public.dispatch_accounts() to authenticated;

-- 5. The phone's side -----------------------------------------------------------------------------
-- Notes the phone [p_device] for [p_user]. The first time, what is on record
-- for them is known; with nothing on record, this phone is.
create or replace function public.dispatch_note_device(p_user uuid, p_device text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := nullif(left(btrim(coalesce(p_device, '')), 128), '');
begin
  if p_user is null or v_key is null or char_length(v_key) < 8 then
    return;
  end if;
  if not exists (select 1 from public.dispatch_devices where user_id = p_user) then
    insert into public.dispatch_devices (user_id, device_key, known, first_seen, seen_at)
    select p_user, k, true, clock_timestamp() - interval '1 second', clock_timestamp() - interval '1 second'
      from (select t.device_key as k from public.push_tokens t
             where t.profile_id = p_user and t.device_key is not null
            union
            select u.raw->>'push_device_key' from public.user_sessions u
             where u.user_id = p_user and u.raw ? 'push_device_key') x
     where char_length(coalesce(k, '')) between 8 and 128
    on conflict do nothing;
    if not found then
      insert into public.dispatch_devices (user_id, device_key, known) values (p_user, v_key, true)
      on conflict do nothing;
    end if;
  end if;
  -- clock_timestamp: the newest is the phone in hand, even within one transaction.
  insert into public.dispatch_devices (user_id, device_key, known, seen_at)
  values (p_user, v_key, false, clock_timestamp())
  on conflict (user_id, device_key) do update set seen_at = clock_timestamp();
end;
$$;
revoke execute on function public.dispatch_note_device(uuid, text) from public, anon, authenticated;

-- The app's one call: what the signed-in person still has to do before
-- their dispatch role opens, with reasons. Notes this phone ([p_device], the
-- app's device key) when they hold a role.
--   { holds, kinds, needs: ['pin'|'selfie'|'recheck'|'id'|'pending'],
--     asks_selfie, asks_id, selfie: {state, reason, note}, id: {state, reason,
--     note, expiry}, deadline, paused, renew_days }
create or replace function public.dispatch_my_checks(p_device text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_selfie boolean;
  v_id boolean;
  v_by timestamptz;
  v_kinds text[];
  v_verify jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select bool_or(g.verify_selfie), bool_or(g.verify_id), min(g.verify_by), array_agg(distinct g.kind)
    into v_selfie, v_id, v_by, v_kinds
    from (select case when o.role = 'admin' then 'stand_admin' else 'staff' end as kind,
                 o.verify_selfie, o.verify_id, o.verify_by
            from public.dispatch_stand_people o where o.user_id = v_uid and o.active
          union all
          select 'fleet_owner', f.verify_selfie, f.verify_id, f.verify_by
            from public.dispatch_fleet_owners f where f.user_id = v_uid and f.active) g;
  if v_kinds is null then
    return jsonb_build_object('holds', false, 'needs', '[]'::jsonb);
  end if;
  perform public.dispatch_note_device(v_uid, p_device);
  v_verify := public.dispatch_verify_json(v_uid, v_selfie, v_id, null, v_by);
  return jsonb_build_object(
    'holds', true,
    'kinds', to_jsonb(v_kinds),
    'needs', v_verify->'needs',
    'asks_selfie', coalesce(v_selfie, false),
    'asks_id', coalesce(v_id, false),
    'selfie', public.identity_photo_state(v_uid),
    'id', public.identity_id_state(v_uid),
    'deadline', v_by,
    'paused', v_verify->'paused',
    'renew_days', public.identity_renew_days());
end;
$$;
revoke execute on function public.dispatch_my_checks(text) from public, anon;
grant execute on function public.dispatch_my_checks(text) to authenticated;

-- A word for the person, by reason code.
create or replace function public.identity_reason_text(p_reason text)
returns text
language sql
immutable
set search_path = public
as $$
  select case p_reason
    when 'blurry' then 'Photo blurry'
    when 'face_unclear' then 'Face not clear'
    when 'name_mismatch' then 'Name doesn''t match'
    when 'expired' then 'Expired'
    when 'wrong_document' then 'Wrong document'
    when 'other' then 'Other'
    else null end;
$$;

-- Tells the admins who have a Documents page that [p_check] is waiting.
create or replace function public.identity_notify_admins(p_check uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.identity_checks;
  v_who text;
  r record;
begin
  select * into c from public.identity_checks where id = p_check;
  if not found or c.status is distinct from 'Pending Review' then
    return;
  end if;
  select coalesce(nullif(btrim(p.name), ''), p.phone, 'Someone') into v_who from public.profiles p where p.id = c.user_id;
  for r in
    select distinct a.profile_id from public.admin_access a
     where a.page in ('*', 'admin-documents', 'admin-documents-users', 'admin-documents-partners')
       and a.profile_id <> c.user_id
  loop
    perform public.approval_push_send(r.profile_id,
      jsonb_build_object(
        'title', case when c.kind = 'id' then 'ID to review' else 'Selfie to review' end,
        'body', coalesce(v_who, 'Someone') || case
          when c.kind = 'id' then ' sent their ' || case when c.doc_type = 'passport' then 'passport' else 'MyKad' end || '.'
          when c.purpose = 'recheck' then ' took a selfie on a new phone.'
          else ' took a selfie.' end),
      jsonb_build_object('type', 'identity_check', 'check_id', c.id, 'for', 'admin'));
  end loop;
end;
$$;
revoke execute on function public.identity_notify_admins(uuid) from public, anon, authenticated;

-- The phone sends a selfie or an ID it has already uploaded to the person's
-- own folder (ID_Image; a profile photo: avatars).
--   p: { kind: 'selfie'|'id', purpose?: 'first'|'recheck'|'profile',
--        file_url, file_url_back?, doc_type?: 'mykad'|'passport',
--        liveness?: 'passed'|'not_checked', liveness_detail?, device?,
--        read_name?, read_ic?, read_expiry?, expiry_date? }
-- Returns { id, mismatch }.
create or replace function public.identity_check_submit(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_kind text := p->>'kind';
  v_purpose text := coalesce(nullif(p->>'purpose', ''), 'first');
  v_file text := nullif(btrim(coalesce(p->>'file_url', '')), '');
  v_back text := nullif(btrim(coalesce(p->>'file_url_back', '')), '');
  v_doc text := nullif(p->>'doc_type', '');
  v_live text := coalesce(nullif(p->>'liveness', ''), 'not_checked');
  v_device text := nullif(left(btrim(coalesce(p->>'device', '')), 128), '');
  v_read_name text := nullif(left(btrim(coalesce(p->>'read_name', '')), 120), '');
  v_read_ic text := nullif(left(btrim(coalesce(p->>'read_ic', '')), 40), '');
  v_read_expiry date;
  v_expiry date;
  v_bucket text;
  v_mismatch text[] := '{}';
  v_name text;
  v_ic text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_kind not in ('selfie', 'id') or v_purpose not in ('first', 'recheck', 'profile')
     or (v_kind = 'id' and v_purpose <> 'first') then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  v_bucket := case when v_purpose = 'profile' then 'avatars' else 'ID_Image' end;
  if v_file is null or strpos(v_file, '/' || v_bucket || '/' || v_uid::text || '/') = 0
     or (v_back is not null and strpos(v_back, '/' || v_bucket || '/' || v_uid::text || '/') = 0) then
    raise exception 'IDENTITY_FILE' using errcode = '22023', hint = 'Upload the photo again.';
  end if;
  if v_kind = 'id' and (v_doc is null or v_doc not in ('mykad', 'passport') or v_back is null) then
    raise exception 'IDENTITY_ID_SIDES' using errcode = '22023', hint = 'Add the front and the back.';
  end if;
  if v_live not in ('passed', 'not_checked') then
    v_live := 'not_checked';
  end if;
  begin
    v_read_expiry := nullif(p->>'read_expiry', '')::date;
    v_expiry := nullif(p->>'expiry_date', '')::date;
  exception when others then
    raise exception 'IDENTITY_DATE' using errcode = '22023', hint = 'Check the expiry date.';
  end;
  if v_kind = 'id' and v_doc = 'passport' and v_expiry is null then
    raise exception 'IDENTITY_EXPIRY' using errcode = '22023', hint = 'Add the passport''s expiry date.';
  end if;
  if v_expiry is not null and v_expiry < current_date then
    raise exception 'IDENTITY_EXPIRED' using errcode = '22023', hint = 'This ID has run out. Use one that is still valid.';
  end if;
  if (select count(*) from public.identity_checks
       where user_id = v_uid and created_at > now() - interval '1 day') >= 20 then
    raise exception 'IDENTITY_TOO_MANY' using errcode = '22023', hint = 'Too many photos today. Try again tomorrow.';
  end if;

  -- What was read against the profile: a name neither of which contains the
  -- other, or a different IC number.
  if v_kind = 'id' then
    select regexp_replace(lower(coalesce(pr.name, '')), '[^a-z]', '', 'g'),
           regexp_replace(coalesce(pr.ic, ''), '[^0-9A-Za-z]', '', 'g')
      into v_name, v_ic
      from public.profiles pr where pr.id = v_uid;
    if v_read_name is not null and coalesce(v_name, '') <> '' then
      if strpos(regexp_replace(lower(v_read_name), '[^a-z]', '', 'g'), v_name) = 0
         and strpos(v_name, regexp_replace(lower(v_read_name), '[^a-z]', '', 'g')) = 0 then
        v_mismatch := array_append(v_mismatch, 'name');
      end if;
    end if;
    if v_read_ic is not null and coalesce(v_ic, '') <> ''
       and upper(regexp_replace(v_read_ic, '[^0-9A-Za-z]', '', 'g')) <> upper(v_ic) then
      v_mismatch := array_append(v_mismatch, 'ic');
    end if;
  end if;

  insert into public.identity_checks (user_id, kind, purpose, doc_type, file_url, file_url_back, liveness,
    liveness_detail, device_key, read_name, read_ic, read_expiry, expiry_date, mismatch, status)
  values (v_uid, v_kind, v_purpose, case when v_kind = 'id' then v_doc end, v_file,
    case when v_kind = 'id' then v_back end,
    case when v_kind = 'selfie' then v_live end,
    case when v_kind = 'selfie' then nullif(left(coalesce(p->>'liveness_detail', ''), 40), '') end,
    v_device,
    case when v_kind = 'id' then v_read_name end, case when v_kind = 'id' then v_read_ic end,
    case when v_kind = 'id' then v_read_expiry end, case when v_kind = 'id' then v_expiry end,
    v_mismatch, case when v_purpose = 'profile' then null else 'Pending Review' end)
  returning id into v_id;

  -- A selfie taken on a phone makes it known.
  if v_kind = 'selfie' and v_purpose <> 'profile' and v_device is not null and char_length(v_device) >= 8 then
    insert into public.dispatch_devices (user_id, device_key, known, check_id, seen_at)
    values (v_uid, v_device, true, v_id, clock_timestamp())
    on conflict (user_id, device_key) do update set known = true, check_id = excluded.check_id,
      seen_at = clock_timestamp();
  end if;
  if v_purpose <> 'profile' then
    perform public.identity_notify_admins(v_id);
  end if;
  return jsonb_build_object('id', v_id, 'mismatch', to_jsonb(v_mismatch));
end;
$$;
revoke execute on function public.identity_check_submit(jsonb) from public, anon;
grant execute on function public.identity_check_submit(jsonb) to authenticated;

-- An admin with a Documents page decides. Rejecting needs a reason from the
-- list ('other' with a note). An approved ID is also the profile's verified
-- ID (with its expiry); the person is told either way.
create or replace function public.identity_check_review(p_id uuid, p_status text, p_reason text default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.identity_checks;
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  v_what text;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:identity_check_review') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_status not in ('Approved', 'Rejected') then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  if p_status = 'Rejected' and (public.identity_reason_text(p_reason) is null
                                or (p_reason = 'other' and v_note is null)) then
    raise exception 'IDENTITY_REASON' using errcode = '22023', hint = 'Pick why, and add a note for Other.';
  end if;
  update public.identity_checks set
    status = p_status,
    reject_reason = case when p_status = 'Rejected' then p_reason end,
    reject_note = v_note,
    reviewed_by = auth.uid(),
    reviewed_at = now()
   where id = p_id and status is not null
  returning * into c;
  if not found then
    raise exception 'IDENTITY_NOT_FOUND' using errcode = '22023';
  end if;
  if c.kind = 'id' and p_status = 'Approved' then
    update public.profiles set
      id_verified = 'Verified',
      id_expiry_date = coalesce(c.expiry_date, id_expiry_date),
      id_image = coalesce(id_image, c.file_url)
     where id = c.user_id;
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'identity.review', c.user_id,
          jsonb_build_object('check_id', c.id, 'kind', c.kind, 'status', p_status, 'reason', c.reject_reason));
  v_what := case when c.kind = 'id' then 'ID' else 'photo' end;
  perform public.approval_push_send(c.user_id,
    case when p_status = 'Approved' then
      jsonb_build_object('title', 'Your ' || v_what || ' is approved',
                         'body', case when c.kind = 'id' then 'Open GET.ride to use your role.'
                                      else 'Thanks. Nothing more to do for your photo.' end)
    else
      jsonb_build_object('title', 'Your ' || v_what || ' wasn''t accepted',
                         'body', public.identity_reason_text(p_reason) || coalesce(': ' || v_note, '')
                                 || '. Open GET.ride to send a new one.')
    end,
    jsonb_build_object('type', 'identity_check', 'check_id', c.id, 'for', 'person'));
  return jsonb_build_object('id', c.id, 'status', c.status);
end;
$$;
revoke execute on function public.identity_check_review(uuid, text, text, text) from public, anon;
grant execute on function public.identity_check_review(uuid, text, text, text) to authenticated;

-- Users → ID documents: the profile's ID photo verified or rejected, with a
-- reason from the list, and the person told why.
create or replace function public.profile_id_review(p_user uuid, p_status text, p_reason text default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:identity_check_review') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_status not in ('Verified', 'Failed') then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  if p_status = 'Failed' and (public.identity_reason_text(p_reason) is null
                              or (p_reason = 'other' and v_note is null)) then
    raise exception 'IDENTITY_REASON' using errcode = '22023', hint = 'Pick why, and add a note for Other.';
  end if;
  update public.profiles set id_verified = p_status::public.id_verification_status where id = p_user;
  if not found then
    raise exception 'IDENTITY_NOT_FOUND' using errcode = '22023';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'identity.profile_id', p_user,
          jsonb_build_object('status', p_status, 'reason', p_reason, 'note', v_note));
  perform public.approval_push_send(p_user,
    case when p_status = 'Verified' then
      jsonb_build_object('title', 'Your ID is verified', 'body', 'Thanks. Nothing more to do.')
    else
      jsonb_build_object('title', 'Your ID wasn''t accepted',
                         'body', public.identity_reason_text(p_reason) || coalesce(': ' || v_note, '')
                                 || '. Open GET.ride to send a new one.')
    end,
    jsonb_build_object('type', 'identity_check', 'for', 'person'));
  return jsonb_build_object('user_id', p_user, 'status', p_status);
end;
$$;
revoke execute on function public.profile_id_review(uuid, text, text, text) from public, anon;
grant execute on function public.profile_id_review(uuid, text, text, text) to authenticated;

-- Admin → Documents → Sign-in checks: the uploads, with whose they are and
-- what the profile says. [p_filter]: waiting, approved, rejected, all.
create or replace function public.identity_checks_list(p_filter text default 'waiting')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.identity_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(c) || jsonb_build_object(
             'name', pr.name, 'phone', pr.phone, 'ic', pr.ic,
             'reviewer', public.dispatch_actor_name(c.reviewed_by)) order by c.created_at desc)
      from (select * from public.identity_checks x
             where x.status is not null
               and case coalesce(p_filter, 'waiting')
                     when 'waiting' then x.status = 'Pending Review'
                     when 'approved' then x.status = 'Approved'
                     when 'rejected' then x.status = 'Rejected'
                     else true end
             order by x.created_at desc
             limit 300) c
      join public.profiles pr on pr.id = c.user_id), '[]'::jsonb);
end;
$$;
revoke execute on function public.identity_checks_list(text) from public, anon;
grant execute on function public.identity_checks_list(text) to authenticated;

-- How many wait, for the Documents count.
create or replace function public.identity_checks_waiting()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case when public.identity_admin_reads()
              then (select count(*)::integer from public.identity_checks where status = 'Pending Review') end;
$$;
revoke execute on function public.identity_checks_waiting() from public, anon;
grant execute on function public.identity_checks_waiting() to authenticated;

-- Users → Edit User: the person's dispatch roles with their switches and
-- state, their recent checks (re-check selfies among them) and whether
-- their profile photo was taken live.
create or replace function public.identity_person(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.identity_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'roles', coalesce((
      select jsonb_agg(r order by r->>'kind') from (
        select jsonb_build_object(
          'kind', case when o.role = 'admin' then 'stand_admin' else 'staff' end,
          'places', jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name),
          'active', bool_or(o.active),
          'verify', public.dispatch_verify_json(o.user_id, bool_or(o.verify_selfie), bool_or(o.verify_id),
                                                max(o.verify_days), min(o.verify_by))) as r
          from public.dispatch_stand_people o
          join public.dispatch_stands s on s.id = o.stand_id
         where o.user_id = p_user
         group by o.user_id, o.role
        union all
        select jsonb_build_object(
          'kind', 'fleet_owner',
          'places', jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) order by g.name),
          'active', bool_or(f.active),
          'verify', public.dispatch_verify_json(f.user_id, bool_or(f.verify_selfie), bool_or(f.verify_id),
                                                max(f.verify_days), min(f.verify_by)))
          from public.dispatch_fleet_owners f
          join public.dispatch_groups g on g.id = f.group_id
         where f.user_id = p_user
         group by f.user_id) y(r)), '[]'::jsonb),
    'photo', (select jsonb_build_object('liveness', c.liveness, 'at', c.created_at, 'url', c.file_url)
                from public.identity_checks c
               where c.user_id = p_user and c.kind = 'selfie' and c.purpose = 'profile'
               order by c.created_at desc limit 1),
    'checks', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.created_at desc)
        from (select * from public.identity_checks x
               where x.user_id = p_user and x.status is not null
               order by x.created_at desc limit 10) c), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object('known', d.known, 'first_seen', d.first_seen, 'seen_at', d.seen_at,
                                          'check_id', d.check_id) order by d.seen_at desc)
        from public.dispatch_devices d where d.user_id = p_user), '[]'::jsonb));
end;
$$;
revoke execute on function public.identity_person(uuid) from public, anon;
grant execute on function public.identity_person(uuid) to authenticated;

-- 6. When to ask for a new ID --------------------------------------------------------------------
create or replace function public.dispatch_verify_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('renewDays', public.identity_renew_days());
$$;
revoke execute on function public.dispatch_verify_config() from public, anon;
grant execute on function public.dispatch_verify_config() to authenticated;

create or replace function public.dispatch_set_verify_config(p_renew_days integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:dispatch_set_verify_config') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_renew_days is null or p_renew_days not between 0 and 365 then
    raise exception 'DISPATCH_VERIFY_DAYS' using errcode = '22023', hint = 'Give 0 to 365 days.';
  end if;
  insert into public.app_settings (key, value) values ('dispatch_verify', jsonb_build_object('renewDays', p_renew_days))
  on conflict (key) do update set value = public.app_settings.value || excluded.value, updated_at = now();
  return public.dispatch_verify_config();
end;
$$;
revoke execute on function public.dispatch_set_verify_config(integer) from public, anon;
grant execute on function public.dispatch_set_verify_config(integer) to authenticated;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261024110000', '0281_dispatch_signin_checks')
on conflict do nothing;
