-- ============================================================================
-- 0180: one device per account (admins and sub-admins exempt)
--
-- With Admin → App Settings → Sign-in security → "One device per account"
-- on (0179's oneDevice), an account that is not in admin_access may be
-- signed in on one device at a time, and the newest sign-in wins: signing
-- in on a new phone signs the old one out. Refusing the new one instead
-- would lock out anybody whose phone was lost or stolen, and leave the
-- account with whoever holds it.
--
--   * active_sessions: per enforced account, the one Auth session allowed
--     (the `session_id` claim of its token) and the device it is on.
--   * claim_session(): the app calls it right after every sign-in (PIN,
--     SMS code, passkey). It records this session as the one, and deletes
--     the account's other Auth sessions so the old device can't refresh.
--     With p_only_if_unclaimed it claims only when nothing is recorded
--     yet, which is what the app does on launch so accounts already
--     signed in on two phones when the switch goes on converge to one.
--   * request_guard(): PostgREST's pre-request hook. A token from a
--     session that is not the account's recorded one is refused with
--     `signed_in_elsewhere` (HTTP 401) on every API call, so the old
--     device can't use the hour its last token has left. A session newer
--     than the claim gets two minutes to claim before it is refused too,
--     so the new device's first calls aren't caught in the race, and a
--     client that never claims gets nowhere.
--   * session_is_current(): the app's own check on resume; let through the
--     guard so it answers false rather than failing.
--   * admin_sign_out_everywhere(): Admin → Users → "Sign out all devices".
--
-- Admins are never held to one device (the gateway phone signs in with an
-- admin account), and their claim removes any row they had. Off, the
-- table is empty and the guard costs one primary-key lookup per request.
-- ============================================================================

create table if not exists public.active_sessions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  session_id uuid not null,
  device_id text check (device_id is null or length(device_id) <= 200),
  device_label text check (device_label is null or length(device_label) <= 120),
  platform text check (platform is null or length(platform) <= 20),
  app_version text check (app_version is null or length(app_version) <= 40),
  claimed_at timestamptz not null default now()
);

alter table public.active_sessions enable row level security;
revoke all on public.active_sessions from public, anon, authenticated;
grant select on public.active_sessions to authenticated;
grant all on public.active_sessions to service_role;

-- Your own row (the app watches it to learn it was signed out
-- elsewhere), or any row for an admin. Written only by the functions here.
drop policy if exists active_sessions_read on public.active_sessions;
create policy active_sessions_read on public.active_sessions
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.caller_is_admin()));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'active_sessions') then
    alter publication supabase_realtime add table public.active_sessions;
  end if;
end
$$;

-- The calling token's Auth session, or null.
create or replace function public.current_session_id()
returns uuid
language plpgsql
stable
set search_path = public
as $$
begin
  return nullif(auth.jwt() ->> 'session_id', '')::uuid;
exception when others then
  return null;
end;
$$;

create or replace function public.claim_session(
  p_device_id text default null,
  p_label text default null,
  p_platform text default null,
  p_app_version text default null,
  p_only_if_unclaimed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_sid uuid := public.current_session_id();
  v_out int := 0;
begin
  if v_uid is null or v_sid is null then
    return jsonb_build_object('enforced', false);
  end if;
  if not public.one_device_on() or exists (select 1 from public.admin_access where profile_id = v_uid) then
    delete from public.active_sessions where user_id = v_uid;
    return jsonb_build_object('enforced', false);
  end if;
  if p_only_if_unclaimed and exists (select 1 from public.active_sessions where user_id = v_uid) then
    return jsonb_build_object('enforced', true, 'current', public.session_is_current());
  end if;

  insert into public.active_sessions (user_id, session_id, device_id, device_label, platform, app_version, claimed_at)
  values (v_uid, v_sid, left(p_device_id, 200), left(p_label, 120), left(lower(p_platform), 20), left(p_app_version, 40), now())
  on conflict (user_id) do update
    set session_id = excluded.session_id,
        device_id = excluded.device_id,
        device_label = excluded.device_label,
        platform = excluded.platform,
        app_version = excluded.app_version,
        claimed_at = excluded.claimed_at;

  -- The old device can no longer refresh its sign-in.
  begin
    delete from auth.sessions where user_id = v_uid and id <> v_sid;
    get diagnostics v_out = row_count;
  exception when others then
    v_out := 0;
  end;
  return jsonb_build_object('enforced', true, 'current', true, 'signed_out', v_out);
end;
$$;

revoke execute on function public.claim_session(text, text, text, text, boolean) from public, anon;
grant execute on function public.claim_session(text, text, text, text, boolean) to authenticated;

-- Whether the calling session may act for its account: no recorded
-- session, the recorded one, or a newer one still within its two minutes
-- to claim.
create or replace function public.session_is_current()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_sid uuid := public.current_session_id();
  a public.active_sessions;
  v_created timestamptz;
begin
  if v_uid is null then
    return true;
  end if;
  select * into a from public.active_sessions where user_id = v_uid;
  if not found or a.session_id = v_sid then
    return true;
  end if;
  if v_sid is null then
    return false;
  end if;
  select created_at into v_created from auth.sessions where id = v_sid;
  return v_created is not null and v_created > a.claimed_at and v_created > now() - interval '2 minutes';
end;
$$;

revoke execute on function public.session_is_current() from public, anon;
grant execute on function public.session_is_current() to authenticated;

-- PostgREST's pre-request hook: runs before every API request. Anything
-- unexpected lets the request through: this must never take the API down.
create or replace function public.request_guard()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claims jsonb;
  v_path text;
  v_current boolean := true;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    if v_claims is null or v_claims ->> 'role' is distinct from 'authenticated' then
      return;
    end if;
    -- Nothing recorded for this account: nothing to hold it to.
    if not exists (select 1 from public.active_sessions where user_id = (v_claims ->> 'sub')::uuid) then
      return;
    end if;
    v_path := coalesce(current_setting('request.path', true), '');
    if v_path in ('/rpc/claim_session', '/rpc/session_is_current') then
      return;
    end if;
    v_current := public.session_is_current();
  exception when others then
    return;
  end;
  if not v_current then
    raise sqlstate 'PT401' using
      message = 'signed_in_elsewhere',
      detail = 'This account signed in on another device.';
  end if;
end;
$$;

revoke execute on function public.request_guard() from public, anon, authenticated;
grant execute on function public.request_guard() to authenticator, anon, authenticated;

alter role authenticator set pgrst.db_pre_request to 'public.request_guard';
notify pgrst, 'reload config';

-- Admin → Users → "Sign out all devices": every Auth session ends, and an
-- enforced account's tokens stop working at once (a recorded session that
-- matches nothing). The next sign-in claims as usual.
create or replace function public.admin_sign_out_everywhere(p_user uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_out int := 0;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can sign an account out.' using errcode = '42501';
  end if;
  if p_user is null then
    return 0;
  end if;
  if public.one_device_on() and not exists (select 1 from public.admin_access where profile_id = p_user) then
    insert into public.active_sessions (user_id, session_id, claimed_at)
    values (p_user, gen_random_uuid(), now())
    on conflict (user_id) do update
      set session_id = excluded.session_id, device_id = null, device_label = null,
          platform = null, app_version = null, claimed_at = excluded.claimed_at;
  end if;
  begin
    delete from auth.sessions where user_id = p_user;
    get diagnostics v_out = row_count;
  exception when others then
    v_out := 0;
  end;
  return v_out;
end;
$$;

revoke execute on function public.admin_sign_out_everywhere(uuid) from public, anon;
grant execute on function public.admin_sign_out_everywhere(uuid) to authenticated;

notify pgrst, 'reload schema';
