-- ============================================================================
-- 0287 — New sign-up per role: Admin › Display › Sign-in Screen gets "New
-- passenger sign-up" and "New driver (partner) sign-up" in place of the one
-- "Allow new registrations" switch, and the server enforces them.
--
-- Applied by hand as version 20261024170000 (0287_registration_switches in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "or replace" / "if exists".
--
-- The switches live where the old one did: admin_display_settings row
-- 'global', settings keys passengerRegistrationEnabled and
-- driverRegistrationEnabled, beside registrationEnabled (the old switch,
-- now written by the admin as "either is open"). Missing keys are on; the
-- old switch off closes both, so apps and admin pages that only know it
-- keep working. No new table: the row is written under the existing
-- admin_display_settings policies (caller_admin_can_write, page
-- admin-settings-display in admin_table_pages, migration 0223).
--
-- 1. registration_open(role) (anon, authenticated, auth): 'passenger',
--    'driver', or null for "either".
-- 2. set_login_pin(pin, device, current_pin, role): a new account (no PIN
--    yet, made in the last hour) says the role it signs up as and is
--    refused with REGISTRATION_CLOSED:<role> when that sign-up is off; an
--    app that sends no role is refused only when both are off.
-- 3. partners: a signed-in user inserting their own partner row (a new
--    partner application) is refused with REGISTRATION_CLOSED:driver while
--    driver sign-up is off. Rows already there (applications part-way
--    through) are untouched; admins and the service role are not limited;
--    claiming an admin-added row (claim_partner_by_phone) is an update and
--    still works.
-- 4. before_user_created_hook(event): Supabase Auth's "Before User Created"
--    hook. With both sign-ups off, a phone number with no account gets no
--    user, so no SMS code (REGISTRATION_CLOSED, HTTP 403). Accounts an
--    admin makes (dispatch-account: phone already confirmed) and e-mail
--    users pass. It works once enabled: Dashboard › Authentication › Hooks ›
--    Before User Created › Postgres function public.before_user_created_hook
--    (supabase/config.toml enables it for the local stack).
-- ============================================================================

-- ---- 1. registration_open ---------------------------------------------------------------------------
-- A display flag as the apps read it (AppDisplay.fromSettings): booleans,
-- numbers and 'true'/'false'/'on'/'off'/'1'/'0'; anything else is on.
create or replace function public.display_setting_flag(p_settings jsonb, p_key text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case
    when p_settings is null or not (p_settings ? p_key) then true
    when jsonb_typeof(p_settings -> p_key) = 'boolean' then (p_settings ->> p_key)::boolean
    when jsonb_typeof(p_settings -> p_key) = 'number' then (p_settings ->> p_key)::numeric <> 0
    when jsonb_typeof(p_settings -> p_key) = 'string'
      then lower(btrim(p_settings ->> p_key)) not in ('false', '0', 'off')
    else true
  end;
$$;
revoke all on function public.display_setting_flag(jsonb, text) from public;
grant execute on function public.display_setting_flag(jsonb, text) to anon, authenticated, service_role;

create or replace function public.registration_open(p_role text default null)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_s jsonb := coalesce((select s.settings from public.admin_display_settings s where s.id = 'global'), '{}'::jsonb);
  v_any boolean := public.display_setting_flag(v_s, 'registrationEnabled');
  v_passenger boolean := v_any and public.display_setting_flag(v_s, 'passengerRegistrationEnabled');
  v_driver boolean := v_any and public.display_setting_flag(v_s, 'driverRegistrationEnabled');
begin
  return case lower(coalesce(p_role, ''))
    when 'passenger' then v_passenger
    when 'user' then v_passenger
    when 'driver' then v_driver
    when 'partner' then v_driver
    else v_passenger or v_driver
  end;
end;
$$;
revoke all on function public.registration_open(text) from public;
grant execute on function public.registration_open(text) to anon, authenticated, service_role;
comment on function public.registration_open(text) is
  'Whether new sign-up is open for a role (passenger / driver; null: either), from admin_display_settings global: registrationEnabled and passengerRegistrationEnabled / driverRegistrationEnabled (0287).';

-- ---- 2. set_login_pin with the role -----------------------------------------------------------------
-- As 0223, plus p_role and the REGISTRATION_CLOSED check for a new account.
-- The three-argument form is replaced (old apps call it by name with two or
-- three arguments, which the new one takes).
drop function if exists public.set_login_pin(text, text, text);
create or replace function public.set_login_pin(p_pin text, p_device_id text default null,
                                                p_current_pin text default null, p_role text default null)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_pin_hash text;
  v_created timestamptz;
  v_phone text;
  v_is_new boolean;
  v_enabled boolean;
  v_max int;
  v_block_emu boolean;
  v_prior int;
  v_emu boolean;
  v_role text := nullif(lower(btrim(coalesce(p_role, ''))), '');
begin
  if v_uid is null then
    raise exception 'set_login_pin requires an authenticated session';
  end if;
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;
  if v_role is not null and v_role not in ('passenger', 'driver') then
    raise exception 'Unknown sign-up role %', v_role using errcode = '22023';
  end if;

  select pin_hash, created_at, phone into v_pin_hash, v_created, v_phone
  from public.profiles where id = v_uid;

  if nullif(v_pin_hash, '') is not null then
    if nullif(btrim(coalesce(p_current_pin, '')), '') is not null then
      if public.pin_check(coalesce(v_phone, ''), p_current_pin, public.request_client_ip()) is distinct from v_uid then
        return false;
      end if;
    elsif not public.session_recent_sms_sign_in() then
      raise exception 'PIN_PROOF_REQUIRED' using errcode = '42501',
        hint = 'Enter your current PIN, or confirm with an SMS code first.';
    end if;
  end if;

  v_is_new := (v_pin_hash is null)
    and (v_created is null or v_created > now() - interval '1 hour');

  if v_is_new then
    -- Admin › Display › Sign-in Screen (0287): the role's sign-up, or
    -- either for an app that doesn't say.
    if not public.registration_open(v_role) then
      raise exception 'REGISTRATION_CLOSED:%', coalesce(v_role, 'any') using errcode = '42501',
        hint = 'New sign-up is closed for this role.';
    end if;

    select c.enabled, c.max_accounts, c.block_emulators
      into v_enabled, v_max, v_block_emu
    from public.device_guard_config() c;

    if v_enabled and p_device_id is not null and p_device_id <> '' then
      select count(distinct user_id)::int into v_prior
      from public.user_sessions
      where device_id = p_device_id
        and user_id is not null
        and user_id <> v_uid;
      if v_prior >= v_max then
        raise exception 'DEVICE_LIMIT:%/%', v_prior, v_max;
      end if;
    end if;

    if v_enabled and v_block_emu then
      select coalesce(bool_or(is_physical_device is false), false) into v_emu
      from public.user_sessions
      where user_id = v_uid;
      if v_emu then
        raise exception 'EMULATOR_BLOCKED';
      end if;
    end if;
  end if;

  update public.profiles
  set pin_hash            = crypt(p_pin, gen_salt('bf', 10)),
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null
  where id = v_uid;
  if not found then
    insert into public.profiles (id, pin_hash)
    values (v_uid, crypt(p_pin, gen_salt('bf', 10)))
    on conflict (id) do update set
      pin_hash            = excluded.pin_hash,
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null;
  end if;
  return true;
end;
$$;
revoke all on function public.set_login_pin(text, text, text, text) from public, anon;
grant execute on function public.set_login_pin(text, text, text, text) to authenticated, service_role;

-- ---- 3. A new partner application ------------------------------------------------------------------
create or replace function public.partners_registration_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null
     and new.auth_user_id is not distinct from auth.uid()
     and not public.caller_is_admin()
     and not public.registration_open('driver') then
    raise exception 'REGISTRATION_CLOSED:driver' using errcode = '42501',
      hint = 'New partner registration is paused.';
  end if;
  return new;
end;
$$;
revoke all on function public.partners_registration_gate() from public, anon, authenticated;

-- "0" sorts before the a_/b_/c_ triggers of 0245 and 0277: refused first.
drop trigger if exists trg_partners_0_registration_gate on public.partners;
create trigger trg_partners_0_registration_gate before insert on public.partners
  for each row execute function public.partners_registration_gate();

-- ---- 4. Supabase Auth: Before User Created ----------------------------------------------------------
create or replace function public.before_user_created_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user jsonb := coalesce(event -> 'user', '{}'::jsonb);
begin
  if public.registration_open(null) then
    return '{}'::jsonb;
  end if;
  -- Made by an admin (phone already confirmed), or not a phone sign-up.
  if nullif(v_user ->> 'phone_confirmed_at', '') is not null
     or nullif(v_user ->> 'email', '') is not null
     or nullif(v_user ->> 'phone', '') is null then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'REGISTRATION_CLOSED: There is no account for this number, and new sign-ups are closed.'));
end;
$$;
revoke all on function public.before_user_created_hook(jsonb) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant execute on function public.before_user_created_hook(jsonb) to supabase_auth_admin';
  end if;
end $$;
comment on function public.before_user_created_hook(jsonb) is
  'Supabase Auth Before User Created hook (0287): refuses a phone sign-up while passenger and driver sign-up are both closed, so no SMS code is sent.';

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024170000', '0287_registration_switches') on conflict do nothing;
