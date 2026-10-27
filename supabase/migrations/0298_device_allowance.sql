-- ============================================================================
-- 0298: more than one device for chosen accounts
-- Version 20261027100000 (0298_device_allowance).
--
-- With one device per account on (0179, 0180), an admin may allow a chosen
-- account up to 10 devices at once (Admin → Users → an account → Devices).
-- A new sign-in past the allowance signs out the device that signed in
-- longest ago.
--
--   * device_allowances: per account, how many devices (2 to 10) and why.
--     No row: the app default, one.
--   * account_devices: an account with an allowance keeps its sessions
--     here, one row each. active_sessions (0180) stays as it is for every
--     other account: phones from before this watch their own row there and
--     sign out when it names another session, so an account with an
--     allowance has no row there (a removed row signs nobody out).
--     account_devices is not sent over realtime: a phone pushed out finds
--     out from its next request or its check on resume (every 3 minutes).
--   * claim_session(), session_is_current(), request_guard() and
--     admin_sign_out_everywhere(): 0184's, 0292's, 0194's and 0180's, with
--     the allowance. claim_session() also returns 'allowed', so the app can
--     say why it was signed out.
--   * admin_device_allowance_set(), admin_sign_out_device(),
--     admin_device_allowances(): the admin's side.
-- Re-runnable.
-- ============================================================================

create table if not exists public.device_allowances (
  user_id uuid primary key references auth.users (id) on delete cascade,
  devices int not null check (devices between 2 and 10),
  reason text check (reason is null or length(reason) <= 200),
  set_by uuid,
  set_at timestamptz not null default now()
);

alter table public.device_allowances enable row level security;
revoke all on public.device_allowances from public, anon, authenticated;
grant select on public.device_allowances to authenticated;
grant all on public.device_allowances to service_role;
drop policy if exists device_allowances_admin_read on public.device_allowances;
create policy device_allowances_admin_read on public.device_allowances
  for select to authenticated using ((select public.caller_is_admin()));

create table if not exists public.account_devices (
  user_id uuid not null references auth.users (id) on delete cascade,
  session_id uuid not null,
  device_id text check (device_id is null or length(device_id) <= 200),
  device_label text check (device_label is null or length(device_label) <= 120),
  platform text check (platform is null or length(platform) <= 20),
  app_version text check (app_version is null or length(app_version) <= 40),
  claimed_at timestamptz not null default clock_timestamp(),
  primary key (user_id, session_id)
);

alter table public.account_devices enable row level security;
revoke all on public.account_devices from public, anon, authenticated;
grant select on public.account_devices to authenticated;
grant all on public.account_devices to service_role;
drop policy if exists account_devices_admin_read on public.account_devices;
create policy account_devices_admin_read on public.account_devices
  for select to authenticated using ((select public.caller_is_admin()));

-- Allowing more devices: edit on Users. Signing a device out stays with full
-- admins, as 0223 keeps "Sign out all devices" (no admin_table_pages row).
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_device_allowance_set', 'admin-users')
on conflict do nothing;

-- How many devices an account may be signed in on at once.
create or replace function public.device_allowance(p_user uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select devices from public.device_allowances where user_id = p_user), 1);
$$;
revoke execute on function public.device_allowance(uuid) from public, anon, authenticated;

-- Keeps the newest [p_n] of an account's devices; the ones pushed past it
-- lose their sign-in. A session that signed in but hasn't claimed yet is
-- left alone: it claims in a moment (or is refused after two minutes).
create or replace function public.device_trim(p_user uuid, p_n int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gone uuid[];
  v_out int := 0;
begin
  with gone as (
    delete from public.account_devices d
     where d.user_id = p_user
       and d.session_id not in (select k.session_id from public.account_devices k
                                 where k.user_id = p_user
                                 order by k.claimed_at desc limit greatest(p_n, 1))
    returning d.session_id
  )
  select array_agg(session_id) into v_gone from gone;
  if v_gone is null then
    return 0;
  end if;
  begin
    delete from auth.sessions s where s.user_id = p_user and s.id = any (v_gone);
    get diagnostics v_out = row_count;
  exception when others then
    v_out := 0;
  end;
  return v_out;
end;
$$;
revoke execute on function public.device_trim(uuid, int) from public, anon, authenticated;

-- ---- Claiming ---------------------------------------------------------------------------------------
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
  v_n int;
begin
  if v_uid is null or v_sid is null then
    return jsonb_build_object('enforced', false);
  end if;
  if not public.one_device_on() or exists (select 1 from public.admin_access where profile_id = v_uid) then
    delete from public.active_sessions where user_id = v_uid;
    delete from public.account_devices where user_id = v_uid;
    return jsonb_build_object('enforced', false);
  end if;
  v_n := public.device_allowance(v_uid);

  if v_n <= 1 then
    -- 0184's one device.
    delete from public.account_devices where user_id = v_uid;
    if p_only_if_unclaimed and exists (select 1 from public.active_sessions where user_id = v_uid) then
      return jsonb_build_object('enforced', true, 'current', public.session_is_current(), 'allowed', 1);
    end if;
    if not exists (select 1 from auth.sessions where id = v_sid and user_id = v_uid) then
      return jsonb_build_object('enforced', true, 'current', false, 'allowed', 1);
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
    begin
      delete from auth.sessions where user_id = v_uid and id <> v_sid;
      get diagnostics v_out = row_count;
    exception when others then
      v_out := 0;
    end;
    return jsonb_build_object('enforced', true, 'current', true, 'signed_out', v_out, 'allowed', 1);
  end if;

  -- Several devices. The 0180 row would sign older phones out: none here.
  delete from public.active_sessions where user_id = v_uid;
  if exists (select 1 from public.account_devices where user_id = v_uid and session_id = v_sid) then
    if p_only_if_unclaimed then
      return jsonb_build_object('enforced', true, 'current', true, 'allowed', v_n);
    end if;
  elsif p_only_if_unclaimed
        and (select count(*) from public.account_devices where user_id = v_uid) >= v_n then
    -- On launch, with every place taken: this one only if it is current.
    return jsonb_build_object('enforced', true, 'current', public.session_is_current(), 'allowed', v_n);
  end if;
  if not exists (select 1 from auth.sessions where id = v_sid and user_id = v_uid) then
    return jsonb_build_object('enforced', true, 'current', false, 'allowed', v_n);
  end if;

  insert into public.account_devices (user_id, session_id, device_id, device_label, platform, app_version, claimed_at)
  values (v_uid, v_sid, left(p_device_id, 200), left(p_label, 120), left(lower(p_platform), 20), left(p_app_version, 40),
          clock_timestamp())
  on conflict (user_id, session_id) do update
    set device_id = excluded.device_id,
        device_label = excluded.device_label,
        platform = excluded.platform,
        app_version = excluded.app_version,
        claimed_at = excluded.claimed_at;
  v_out := public.device_trim(v_uid, v_n);
  return jsonb_build_object('enforced', true, 'current', true, 'signed_out', v_out, 'allowed', v_n);
end;
$$;

revoke execute on function public.claim_session(text, text, text, text, boolean) from public, anon;
grant execute on function public.claim_session(text, text, text, text, boolean) to authenticated;

-- ---- Is this session still allowed? -------------------------------------------------------------
-- 0292's, plus: an account with several devices is current when this
-- session is one of them, or newer than them all and within its two
-- minutes to claim.
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
  v_phone text;
  v_latest timestamptz;
begin
  if v_uid is null then
    return true;
  end if;
  if exists (select 1 from public.country_phone_rules where access = 'blocked')
     or exists (select 1 from public.phone_number_blocks) then
    select phone into v_phone from public.profiles where id = v_uid;
    if v_phone is not null and public.phone_rule_check(v_phone, false)->>'code' = 'PHONE_BLOCKED' then
      return false;
    end if;
  end if;
  select max(claimed_at) into v_latest from public.account_devices where user_id = v_uid;
  if v_latest is not null then
    if exists (select 1 from public.account_devices where user_id = v_uid and session_id = v_sid) then
      return true;
    end if;
    if v_sid is null then
      return false;
    end if;
    select created_at into v_created from auth.sessions where id = v_sid;
    return v_created is not null and v_created > v_latest and v_created > now() - interval '2 minutes';
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

-- ---- PostgREST's pre-request hook ------------------------------------------------------------------
-- 0194's, looking in account_devices too.
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
  v_deleted boolean := false;
  v_uid uuid;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    if v_claims is null or v_claims ->> 'role' is distinct from 'authenticated' then
      return;
    end if;
    v_uid := (v_claims ->> 'sub')::uuid;
    v_deleted := exists (select 1 from public.profiles where id = v_uid and deleted_at is not null);
    if not v_deleted then
      -- Nothing recorded for this account: nothing to hold it to.
      if not exists (select 1 from public.active_sessions where user_id = v_uid)
         and not exists (select 1 from public.account_devices where user_id = v_uid) then
        return;
      end if;
      v_path := coalesce(current_setting('request.path', true), '');
      if v_path in ('/rpc/claim_session', '/rpc/session_is_current') then
        return;
      end if;
      v_current := public.session_is_current();
    end if;
  exception when others then
    return;
  end;
  if v_deleted then
    raise sqlstate 'PT401' using
      message = 'account_deleted',
      detail = 'This account was deleted.';
  end if;
  if not v_current then
    raise sqlstate 'PT401' using
      message = 'signed_in_elsewhere',
      detail = 'This account signed in on another device.';
  end if;
end;
$$;

revoke execute on function public.request_guard() from public, anon, authenticated;
grant execute on function public.request_guard() to authenticator, anon, authenticated;

-- ---- Admin ------------------------------------------------------------------------------------------
-- 0179's switches (full admins only, as 0223 made them); off also lets go
-- of accounts with several devices.
create or replace function public.set_sign_in_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_sign_in_config') then
    raise exception 'Only an admin can change sign-in security.' using errcode = '42501';
  end if;
  v := jsonb_build_object(
    'passkeyWeb', coalesce((p_config->>'passkeyWeb')::boolean, false),
    'passkeyAndroid', coalesce((p_config->>'passkeyAndroid')::boolean, false),
    'passkeyIos', coalesce((p_config->>'passkeyIos')::boolean, false),
    'oneDevice', coalesce((p_config->>'oneDevice')::boolean, false)
  );
  insert into public.app_settings (key, value, updated_at) values ('sign_in', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  if not (v->>'oneDevice')::boolean then
    delete from public.active_sessions where true;
    delete from public.account_devices where true;
  end if;
  return v;
end;
$$;
revoke execute on function public.set_sign_in_config(jsonb) from public, anon;
grant execute on function public.set_sign_in_config(jsonb) to authenticated;

-- 0180's "Sign out all devices" (full admins only, as 0223 made it), for
-- either kind of account: every Auth
-- session ends and a recorded session that matches nothing stops the
-- tokens still out there.
create or replace function public.admin_sign_out_everywhere(p_user uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_out int := 0;
begin
  if not public.caller_admin_can_write('rpc:admin_sign_out_everywhere') then
    raise exception 'Only an admin can sign an account out.' using errcode = '42501';
  end if;
  if p_user is null then
    return 0;
  end if;
  if public.one_device_on() and not exists (select 1 from public.admin_access where profile_id = p_user) then
    if public.device_allowance(p_user) > 1 then
      delete from public.active_sessions where user_id = p_user;
      delete from public.account_devices where user_id = p_user;
      insert into public.account_devices (user_id, session_id) values (p_user, gen_random_uuid());
    else
      delete from public.account_devices where user_id = p_user;
      insert into public.active_sessions (user_id, session_id, claimed_at)
      values (p_user, gen_random_uuid(), now())
      on conflict (user_id) do update
        set session_id = excluded.session_id, device_id = null, device_label = null,
            platform = null, app_version = null, claimed_at = excluded.claimed_at;
    end if;
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

-- Sets how many devices an account may use at once (1 = the app default).
-- Going up moves its device into the list; going down signs out the ones
-- that signed in longest ago, at once.
create or replace function public.admin_device_allowance_set(p_user uuid, p_devices int, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_keep public.account_devices;
begin
  if not public.caller_admin_can_write('rpc:admin_device_allowance_set') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_user is null or not exists (select 1 from auth.users where id = p_user) then
    raise exception 'no_account' using errcode = '22023';
  end if;
  if p_devices is null or p_devices < 1 or p_devices > 10 then
    raise exception 'bad_devices' using errcode = '22023', detail = 'From 1 to 10 devices.';
  end if;
  if v_reason is not null and length(v_reason) > 200 then
    raise exception 'reason_too_long' using errcode = '22023';
  end if;

  if p_devices = 1 then
    delete from public.device_allowances where user_id = p_user;
    -- Back to one: the newest device stays, as 0180 records it.
    select * into v_keep from public.account_devices where user_id = p_user order by claimed_at desc limit 1;
    delete from public.account_devices where user_id = p_user;
    if v_keep.session_id is not null and public.one_device_on() then
      insert into public.active_sessions (user_id, session_id, device_id, device_label, platform, app_version, claimed_at)
      values (p_user, v_keep.session_id, v_keep.device_id, v_keep.device_label, v_keep.platform, v_keep.app_version,
              v_keep.claimed_at)
      on conflict (user_id) do update
        set session_id = excluded.session_id, device_id = excluded.device_id,
            device_label = excluded.device_label, platform = excluded.platform,
            app_version = excluded.app_version, claimed_at = excluded.claimed_at;
      begin
        delete from auth.sessions where user_id = p_user and id <> v_keep.session_id;
      exception when others then
        null;
      end;
    end if;
    return jsonb_build_object('devices', 1, 'reason', null);
  end if;

  insert into public.device_allowances (user_id, devices, reason, set_by, set_at)
  values (p_user, p_devices, v_reason, auth.uid(), now())
  on conflict (user_id) do update
    set devices = excluded.devices, reason = excluded.reason, set_by = excluded.set_by, set_at = excluded.set_at;
  -- The device 0180 recorded joins the list; its row goes quietly.
  insert into public.account_devices (user_id, session_id, device_id, device_label, platform, app_version, claimed_at)
  select user_id, session_id, device_id, device_label, platform, app_version, claimed_at
    from public.active_sessions where user_id = p_user
  on conflict (user_id, session_id) do nothing;
  delete from public.active_sessions where user_id = p_user;
  if exists (select 1 from public.account_devices where user_id = p_user) then
    perform public.device_trim(p_user, p_devices);
  end if;
  return jsonb_build_object('devices', p_devices, 'reason', v_reason);
end;
$$;
revoke execute on function public.admin_device_allowance_set(uuid, int, text) from public, anon;
grant execute on function public.admin_device_allowance_set(uuid, int, text) to authenticated;

-- Signs one device of an account with several out.
create or replace function public.admin_sign_out_device(p_user uuid, p_session uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gone boolean;
begin
  if not public.caller_admin_can_write('rpc:admin_sign_out_device') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  delete from public.account_devices where user_id = p_user and session_id = p_session;
  v_gone := found;
  -- The last one gone: a row matching nothing keeps its token out.
  if v_gone and not exists (select 1 from public.account_devices where user_id = p_user) then
    insert into public.account_devices (user_id, session_id) values (p_user, gen_random_uuid());
  end if;
  begin
    delete from auth.sessions where user_id = p_user and id = p_session;
  exception when others then
    null;
  end;
  return v_gone;
end;
$$;
revoke execute on function public.admin_sign_out_device(uuid, uuid) from public, anon;
grant execute on function public.admin_sign_out_device(uuid, uuid) to authenticated;

-- App Settings → Sign-in security: the accounts allowed more than one.
create or replace function public.admin_device_allowances()
returns table (user_id uuid, name text, display_id text, devices int, reason text, in_use int, set_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select a.user_id, p.name::text, p.display_id::text, a.devices, a.reason,
           (select count(*)::int from public.account_devices d
             where d.user_id = a.user_id and d.device_id is not null),
           a.set_at
      from public.device_allowances a
      left join public.profiles p on p.id = a.user_id
     order by a.set_at desc;
end;
$$;
revoke execute on function public.admin_device_allowances() from public, anon;
grant execute on function public.admin_device_allowances() to authenticated;

notify pgrst, 'reload schema';
