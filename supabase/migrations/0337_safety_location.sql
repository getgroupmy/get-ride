-- ============================================================================
-- 0337 — Safety location case: an admin turns on a specific user's background
-- location for a safety case, ALWAYS disclosed to that user while it is on.
--
-- Version 20261103100000 (0337_safety_location). Re-runnable: the table,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first.
--
-- THE HARD RULE — no covert tracking. This feature never keeps a background
-- location report for a user under a safety case until that user's app has
-- shown the one-time modal (or rendered the banner) and called
-- safety_location_ack(). The gate lives in background_checkin_allowed (point
-- 2): a case that is enabled but whose notified_at is still null does NOT
-- allow a background report. There is no flag, setting or path that enables
-- background location without the indicator being shown first.
--
-- 1. safety_location_cases: one row a user (pk user_id), the open case. reason
--    (required to open, kept internal — the audit log and this table hold the
--    admin's words; the user is only ever shown a generic "a safety review"),
--    disclosure_style ('modal' | 'banner'), who opened / closed it and when,
--    notified_at (set by safety_location_ack when the user's app first shows
--    the indicator). Reopening a closed case clears notified_at, so the app
--    must disclose again before any report is kept.
-- 2. background_checkin_allowed(profile): 0333's, ALSO true for a user with an
--    open, enabled safety case whose notified_at is not null. So: drivers, OR
--    opted-in passengers while the admin switch is on, OR a safety case the
--    user has actually been shown. push_background_location (0333) reads this
--    unchanged, so the first report for a case waits until the ack.
-- 3. RPCs:
--      admin_safety_location_set(user, enabled, reason, style): an admin with
--        edit on God View ('*' or rpc:admin_safety_location_set), and only for
--        someone on their God View map (god_view_may_see). Opening needs a
--        non-empty reason. Logged in admin_audit_log ('safety_location.set').
--      safety_location_state(): about the signed-in caller only; {active,
--        style, reason (generic), since} or null. The app reads it to show the
--        modal / banner and the Settings row.
--      safety_location_ack(): the app calls it once it has shown the modal (or
--        first rendered the banner); sets notified_at = now() if null. Only
--        this unlocks background reports for the case.
-- 4. god_view_devices(profile): the per-device breakdown (device id, platform,
--    last position, located_at, freshness) for the admin's device picker, for
--    someone the caller may see. Does not widen who can call God View.
-- (The God View freshness change is handled separately, not in this migration.)
-- ============================================================================

-- ---- 1. The case -----------------------------------------------------------------------------------
create table if not exists public.safety_location_cases (
  user_id          uuid primary key references public.profiles (id) on delete cascade,
  enabled          boolean not null default false,
  reason           text not null,
  disclosure_style text not null default 'modal' check (disclosure_style in ('modal', 'banner')),
  opened_by        uuid,
  opened_at        timestamptz,
  closed_by        uuid,
  closed_at        timestamptz,
  notified_at      timestamptz,
  updated_at       timestamptz not null default now()
);
comment on table public.safety_location_cases is
  'An admin-opened safety case that turns on a user''s background location (0337). Always disclosed: no report is kept until notified_at is set by safety_location_ack.';
create index if not exists safety_location_cases_enabled_idx
  on public.safety_location_cases (user_id) where enabled;

alter table public.safety_location_cases enable row level security;
revoke all on public.safety_location_cases from public, anon, authenticated;
grant all on public.safety_location_cases to service_role;
-- The user may read their own case (the Settings row reads it through the RPC,
-- but a direct read is harmless and nothing covert can hide behind it).
drop policy if exists "safety_location own read" on public.safety_location_cases;
create policy "safety_location own read" on public.safety_location_cases
  for select to authenticated using (user_id = (select auth.uid()));

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_safety_location_set', 'admin-god-view')
on conflict do nothing;

-- ---- 2. The gate: who may have a background report kept --------------------------------------------
-- 0333's rule, ALSO true for a user whose safety case is enabled AND has been
-- disclosed (notified_at set). A case that is enabled but not yet acked does
-- NOT allow a report: this is what keeps the feature from ever tracking before
-- the indicator is shown.
create or replace function public.background_checkin_allowed(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_profile is not null and (
       exists (select 1 from public.partners pa where pa.auth_user_id = p_profile)
    or ((public.location_checkins_config() ->> 'passengers')::boolean
        and exists (select 1 from public.profiles p where p.id = p_profile and p.location_checkins))
    or exists (select 1 from public.safety_location_cases c
                where c.user_id = p_profile and c.enabled and c.notified_at is not null));
$$;
revoke execute on function public.background_checkin_allowed(uuid) from public, anon, authenticated;

-- ---- 3. RPCs ---------------------------------------------------------------------------------------
-- The case as the app and the admin read it. The user is never shown the
-- admin's exact reason: a generic, non-alarming phrase.
create or replace function public.safety_location_json(c public.safety_location_cases)
returns jsonb
language sql
stable
set search_path = public
as $$
  select case when c.user_id is null or not c.enabled then null else jsonb_build_object(
    'active', true,
    'style', c.disclosure_style,
    'reason', 'a safety review',
    'since', coalesce(c.opened_at, c.updated_at),
    'notified', c.notified_at is not null) end;
$$;
revoke execute on function public.safety_location_json(public.safety_location_cases) from public, anon, authenticated;

-- The signed-in caller's own case, or null. The app shows the modal / banner
-- and the Settings row from this.
create or replace function public.safety_location_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c public.safety_location_cases;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  select * into c from public.safety_location_cases x where x.user_id = v_uid;
  return public.safety_location_json(c);
end;
$$;
revoke execute on function public.safety_location_state() from public, anon;
grant execute on function public.safety_location_state() to authenticated;

-- The app calls this once it has actually shown the one-time modal, or first
-- rendered the banner. Sets notified_at if null — the ONLY thing that unlocks
-- background reports for the case.
create or replace function public.safety_location_ack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c public.safety_location_cases;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  update public.safety_location_cases x
     set notified_at = now(), updated_at = now()
   where x.user_id = v_uid and x.enabled and x.notified_at is null
  returning * into c;
  if c.user_id is null then
    select * into c from public.safety_location_cases x where x.user_id = v_uid;
  end if;
  return public.safety_location_json(c);
end;
$$;
revoke execute on function public.safety_location_ack() from public, anon;
grant execute on function public.safety_location_ack() to authenticated;

-- An admin opens, retunes or closes a user's safety case. Edit on God View,
-- and only for someone on the caller's own God View map. Opening needs a
-- reason; reopening a closed case clears notified_at so the app must disclose
-- afresh before any report is kept.
create or replace function public.admin_safety_location_set(
  p_user_id uuid,
  p_enabled boolean,
  p_reason text default null,
  p_disclosure_style text default 'modal'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_enabled boolean := coalesce(p_enabled, false);
  v_style text := lower(btrim(coalesce(p_disclosure_style, 'modal')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_prev public.safety_location_cases;
  c public.safety_location_cases;
begin
  if not public.caller_admin_can_write('rpc:admin_safety_location_set') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You need edit access to God View to change a safety case.';
  end if;
  if p_user_id is null or not public.god_view_may_see(p_user_id) then
    raise exception 'You can only open a safety case for someone on your God View map.' using errcode = '42501';
  end if;
  if v_style not in ('modal', 'banner') then
    raise exception 'Choose modal or banner.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user_id and p.deleted_at is null) then
    raise exception 'No such account.' using errcode = 'P0002';
  end if;
  select * into v_prev from public.safety_location_cases x where x.user_id = p_user_id;
  if v_enabled and v_reason is null and not (v_prev.user_id is not null and v_prev.enabled) then
    raise exception 'Enter a reason for the safety case.' using errcode = '22023';
  end if;

  if v_enabled then
    insert into public.safety_location_cases (user_id, enabled, reason, disclosure_style, opened_by, opened_at, updated_at)
    values (p_user_id, true, coalesce(v_reason, 'Safety case'), v_style, v_uid, now(), now())
    on conflict (user_id) do update set
      enabled = true,
      reason = coalesce(v_reason, public.safety_location_cases.reason),
      disclosure_style = v_style,
      -- Reopening a closed case: a fresh disclosure is required (notified_at
      -- cleared), the open is re-stamped.
      opened_by = case when public.safety_location_cases.enabled then public.safety_location_cases.opened_by else v_uid end,
      opened_at = case when public.safety_location_cases.enabled then public.safety_location_cases.opened_at else now() end,
      notified_at = case when public.safety_location_cases.enabled then public.safety_location_cases.notified_at else null end,
      closed_by = null, closed_at = null, updated_at = now()
    returning * into c;
  else
    update public.safety_location_cases x
       set enabled = false, disclosure_style = v_style,
           closed_by = v_uid, closed_at = now(), updated_at = now()
     where x.user_id = p_user_id
    returning * into c;
    if c.user_id is null then
      -- Nothing to close: record a closed row so the admin sees a consistent state.
      insert into public.safety_location_cases (user_id, enabled, reason, disclosure_style, closed_by, closed_at, updated_at)
      values (p_user_id, false, coalesce(v_reason, 'Safety case'), v_style, v_uid, now(), now())
      on conflict (user_id) do update set enabled = false, updated_at = now()
      returning * into c;
    end if;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'safety_location.set', p_user_id, jsonb_build_object(
    'enabled', c.enabled, 'style', c.disclosure_style, 'reason', c.reason,
    'reopened', v_enabled and not coalesce(v_prev.enabled, false)));

  -- The admin's full view of the case (reason included; this is an admin RPC).
  return jsonb_build_object(
    'user_id', c.user_id,
    'enabled', c.enabled,
    'reason', c.reason,
    'disclosure_style', c.disclosure_style,
    'opened_at', c.opened_at,
    'closed_at', c.closed_at,
    'notified_at', c.notified_at,
    'notified', c.notified_at is not null);
end;
$$;
revoke execute on function public.admin_safety_location_set(uuid, boolean, text, text) from public, anon;
grant execute on function public.admin_safety_location_set(uuid, boolean, text, text) to authenticated;

-- A read-only look at a user's case for the God View panel: the admin sees
-- the reason, the style and — so they know whether the user has actually been
-- shown the indicator — notified_at (null until the app acks). Any God View
-- admin who may see the person; no write, no gate change.
create or replace function public.admin_safety_location_state(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.safety_location_cases;
begin
  if p_user_id is null or not public.god_view_may_see(p_user_id) then
    raise exception 'You can only see the safety case of someone on your God View map.' using errcode = '42501';
  end if;
  select * into c from public.safety_location_cases x where x.user_id = p_user_id;
  return jsonb_build_object(
    'user_id', p_user_id,
    'enabled', coalesce(c.enabled, false),
    'reason', c.reason,
    'disclosure_style', coalesce(c.disclosure_style, 'modal'),
    'opened_at', c.opened_at,
    'closed_at', c.closed_at,
    'notified_at', c.notified_at,
    'notified', c.notified_at is not null);
end;
$$;
revoke execute on function public.admin_safety_location_state(uuid) from public, anon;
grant execute on function public.admin_safety_location_state(uuid) to authenticated;

-- ---- 4. God View: the person's logged-in devices ---------------------------------------------------
-- Each device that has a push token for the person, with its last position and
-- when it reported, so the admin can pick which one to centre on. Only for
-- someone the caller may see; does not widen who may open God View.
create or replace function public.god_view_devices(p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_devices jsonb;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only see the devices of someone on your God View map.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(d order by d.located_at desc nulls last), '[]'::jsonb)
    into v_devices
    from (
      select distinct on (coalesce(t.device_key, t.id::text)) jsonb_build_object(
               'device_key', t.device_key,
               'token_id', t.id,
               'platform', t.platform,
               'lat', t.last_lat,
               'lng', t.last_lng,
               'located_at', t.located_at,
               'located_bg', t.located_bg,
               'location_always', t.location_always,
               'moved_at', t.moved_at) as d,
             t.located_at
        from public.push_tokens t
       where t.profile_id = p_profile_id
         and t.last_lat is not null and t.last_lng is not null
       order by coalesce(t.device_key, t.id::text), t.located_at desc nulls last
    ) d;
  return jsonb_build_object('profile_id', p_profile_id, 'devices', v_devices, 'now', now());
end;
$$;
revoke execute on function public.god_view_devices(uuid) from public, anon;
grant execute on function public.god_view_devices(uuid) to authenticated;


notify pgrst, 'reload schema';
