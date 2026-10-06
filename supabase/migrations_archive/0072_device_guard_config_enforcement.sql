-- ============================================================================
-- 0072_device_guard_config_enforcement.sql
-- Makes the device-based duplicate-account guard (0071) admin-configurable and
-- enforces it SERVER-SIDE so a modified client can't skip the block.
--
--   - Config lives in app_settings key 'device_account_guard'
--       { "enabled": bool, "maxAccountsPerDevice": int }.
--   - device_guard_config()          -> effective (enabled, max_accounts), with
--                                        defaults when the row is absent.
--   - device_registration_status()   -> the client's pre-check: allowed +
--                                        prior_accounts + the effective limit.
--   - device_guard_set_config()      -> admin-only writer for the two knobs.
--   - set_login_pin() gains a p_device_id arg and now blocks a NEW account
--     (no prior pin_hash + freshly created profile) whose device already backs
--     >= max_accounts other accounts. PIN changes and forgot-PIN resets — both
--     existing accounts — are never affected.
-- ============================================================================

-- Default config (do not clobber an existing admin-tuned row).
insert into public.app_settings (key, value)
values (
  'device_account_guard',
  jsonb_build_object('enabled', true, 'maxAccountsPerDevice', 3)
)
on conflict (key) do nothing;

-- Effective config with safe defaults. SECURITY DEFINER so it reads the row
-- regardless of the caller's RLS visibility.
create or replace function public.device_guard_config()
returns table (enabled boolean, max_accounts int)
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
  return next;
end;
$$;

revoke all on function public.device_guard_config() from public;
grant execute on function public.device_guard_config() to anon, authenticated;

-- Client pre-check: is a new registration allowed on this device, and why.
create or replace function public.device_registration_status(p_device_id text)
returns table (
  allowed boolean,
  prior_accounts int,
  max_accounts int,
  enabled boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_enabled boolean;
  v_max int;
  v_prior int := 0;
  v_uid uuid := auth.uid();
begin
  select c.enabled, c.max_accounts into v_enabled, v_max
  from public.device_guard_config() c;

  if p_device_id is not null and p_device_id <> '' then
    select count(distinct user_id)::int into v_prior
    from public.user_sessions
    where device_id = p_device_id
      and user_id is not null
      and user_id <> coalesce(v_uid, '00000000-0000-0000-0000-000000000000'::uuid);
  end if;

  allowed := (not v_enabled) or (v_prior < v_max);
  prior_accounts := v_prior;
  max_accounts := v_max;
  enabled := v_enabled;
  return next;
end;
$$;

revoke all on function public.device_registration_status(text) from public;
grant execute on function public.device_registration_status(text) to anon, authenticated;

-- Admin-only writer for the two knobs.
create or replace function public.device_guard_set_config(
  p_enabled boolean,
  p_max_accounts int
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
      'maxAccountsPerDevice', greatest(1, coalesce(p_max_accounts, 3))
    ),
    now()
  )
  on conflict (key) do update
    set value = excluded.value, updated_at = now();
  return true;
end;
$$;

revoke all on function public.device_guard_set_config(boolean, int) from public;
grant execute on function public.device_guard_set_config(boolean, int) to authenticated;

-- Re-create set_login_pin with an optional device id + server-side enforcement.
-- Drop the single-arg version so PostgREST doesn't see two overloads.
drop function if exists public.set_login_pin(text);

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
  v_prior int;
begin
  if v_uid is null then
    raise exception 'set_login_pin requires an authenticated session';
  end if;
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;

  -- A brand-new account = no PIN hash yet AND a freshly created (or not-yet
  -- existing) profile. This is server-authoritative, so PIN changes and
  -- forgot-PIN resets (old profiles) are never blocked, and the client can't
  -- forge the distinction.
  select pin_hash, created_at into v_pin_hash, v_created
  from public.profiles where id = v_uid;
  v_is_new := (v_pin_hash is null)
    and (v_created is null or v_created > now() - interval '1 hour');

  if v_is_new and p_device_id is not null and p_device_id <> '' then
    select c.enabled, c.max_accounts into v_enabled, v_max
    from public.device_guard_config() c;
    if v_enabled then
      select count(distinct user_id)::int into v_prior
      from public.user_sessions
      where device_id = p_device_id
        and user_id is not null
        and user_id <> v_uid;
      if v_prior >= v_max then
        -- Parsed client-side (parseDeviceLimitError) to show a friendly message.
        raise exception 'DEVICE_LIMIT:%/%', v_prior, v_max;
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
