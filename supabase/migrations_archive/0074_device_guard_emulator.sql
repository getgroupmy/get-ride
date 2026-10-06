-- ============================================================================
-- 0074_device_guard_emulator.sql
-- Adds an OPT-IN "block emulators/simulators" knob to the device guard.
--
-- user_sessions.is_physical_device (captured by SessionTrackingContext via
-- expo-device) is false on emulators/simulators — the cheapest fake-account
-- vector for bulk multi-accounting. This lets an admin block new sign-ups from
-- such devices. It is a client-reported signal (forgeable by a modified
-- client, unlike a signed attestation), so it stops the common unsophisticated
-- case, not a determined attacker — hence it defaults OFF and is opt-in.
--
-- Config gains "blockEmulators" (default false). device_guard_config exposes
-- it, device_registration_status factors it in and reports is_emulator, and
-- set_login_pin enforces it for brand-new accounts only. PIN changes / resets
-- are unaffected, exactly like the DEVICE_LIMIT guard.
-- ============================================================================

-- Return-type (OUT column) changes require dropping first. set_login_pin
-- depends on device_guard_config, so drop it too and recreate below.
drop function if exists public.set_login_pin(text, text);
drop function if exists public.device_registration_status(text);
drop function if exists public.device_guard_config();

create or replace function public.device_guard_config()
returns table (enabled boolean, max_accounts int, block_emulators boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v jsonb;
begin
  select value into v from public.app_settings where key = 'device_account_guard';
  enabled := coalesce((v->>'enabled')::boolean, true);
  max_accounts := greatest(1, coalesce((v->>'maxAccountsPerDevice')::int, 3));
  block_emulators := coalesce((v->>'blockEmulators')::boolean, false);
  return next;
end;
$$;

revoke all on function public.device_guard_config() from public;
grant execute on function public.device_guard_config() to anon, authenticated;

create or replace function public.device_registration_status(p_device_id text)
returns table (
  allowed boolean,
  prior_accounts int,
  max_accounts int,
  enabled boolean,
  is_emulator boolean,
  block_emulators boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_enabled boolean;
  v_max int;
  v_block_emu boolean;
  v_prior int := 0;
  v_emu boolean := false;
  v_uid uuid := auth.uid();
begin
  select c.enabled, c.max_accounts, c.block_emulators
    into v_enabled, v_max, v_block_emu
  from public.device_guard_config() c;

  if p_device_id is not null and p_device_id <> '' then
    select count(distinct user_id)::int into v_prior
    from public.user_sessions
    where device_id = p_device_id
      and user_id is not null
      and user_id <> coalesce(v_uid, '00000000-0000-0000-0000-000000000000'::uuid);
  end if;

  select coalesce(bool_or(is_physical_device is false), false) into v_emu
  from public.user_sessions
  where (p_device_id is not null and p_device_id <> '' and device_id = p_device_id)
     or (v_uid is not null and user_id = v_uid);

  allowed := (not v_enabled)
    or ((v_prior < v_max) and not (v_block_emu and v_emu));
  prior_accounts := v_prior;
  max_accounts := v_max;
  enabled := v_enabled;
  is_emulator := v_emu;
  block_emulators := v_block_emu;
  return next;
end;
$$;

revoke all on function public.device_registration_status(text) from public;
grant execute on function public.device_registration_status(text) to anon, authenticated;

-- Writer gains the third knob. Drop the 2-arg overload to avoid ambiguity.
drop function if exists public.device_guard_set_config(boolean, int);

create or replace function public.device_guard_set_config(
  p_enabled boolean,
  p_max_accounts int,
  p_block_emulators boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values (
    'device_account_guard',
    jsonb_build_object(
      'enabled', coalesce(p_enabled, true),
      'maxAccountsPerDevice', greatest(1, coalesce(p_max_accounts, 3)),
      'blockEmulators', coalesce(p_block_emulators, false)
    ),
    now()
  )
  on conflict (key) do update
    set value = excluded.value, updated_at = now();
  return true;
end;
$$;

revoke all on function public.device_guard_set_config(boolean, int, boolean) from public;
grant execute on function public.device_guard_set_config(boolean, int, boolean) to authenticated;

-- set_login_pin: enforce the device limit AND (opt-in) the emulator block for a
-- brand-new account only.
create or replace function public.set_login_pin(p_pin text, p_device_id text default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_pin_hash text;
  v_created timestamptz;
  v_is_new boolean;
  v_enabled boolean;
  v_max int;
  v_block_emu boolean;
  v_prior int;
  v_emu boolean;
begin
  if v_uid is null then
    raise exception 'set_login_pin requires an authenticated session';
  end if;
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;

  select pin_hash, created_at into v_pin_hash, v_created
  from public.profiles where id = v_uid;
  v_is_new := (v_pin_hash is null)
    and (v_created is null or v_created > now() - interval '1 hour');

  if v_is_new then
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
      where (p_device_id is not null and p_device_id <> '' and device_id = p_device_id)
         or user_id = v_uid;
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

revoke all on function public.set_login_pin(text, text) from public;
grant execute on function public.set_login_pin(text, text) to authenticated;

notify pgrst, 'reload schema';
