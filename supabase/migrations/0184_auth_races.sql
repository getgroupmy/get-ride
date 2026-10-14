-- ============================================================================
-- 0184: the PIN lockout and the one-device claim hold under pressure
-- (audit 14 Oct 2026).
--
--   1. pin_check read the failure count, compared the PIN, then wrote the
--      count back from what it had read. Guesses sent at the same moment all
--      read the same low count, so "five wrong PINs lock the account" let
--      about four times as many through (proved with 50 at once). The
--      account's row is now locked for the check: guesses on one account
--      take turns and each sees the count the last one left.
--   2. claim_session took the account for any token it was called with, so
--      a session already replaced by a newer sign-in (or ended by "Sign out
--      all devices") could take it back for the rest of its access token's
--      life. A session that no longer exists is now told it isn't current,
--      and the app signs it out.
-- ============================================================================

create or replace function public.pin_check(p_phone text, p_pin text, p_ip text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_digits   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_row      record;
  v_matched  boolean := false;
  v_attempts integer;
  -- Keyed as in 0137: no address (SQL, the service role) is not limited
  -- here; pin-login always passes one. The per-account lockout below holds
  -- either way.
  v_wait     integer := public.auth_rate_take('pin_check', p_ip, 30, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  if v_digits = '' then
    return null;
  end if;

  select p.id, p.pin_hash, p.pin_failed_attempts, p.pin_locked_until
    into v_row
    from public.profiles p
   where p.phone = any (array_remove(array[
           '+' || v_digits,
           v_digits,
           '0' || v_digits,
           ltrim(v_digits, '0')
         ], null))
   limit 1
     for update;

  if v_row.id is null then
    return null;
  end if;

  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    raise exception 'PIN_LOCKED:%',
      ceil(extract(epoch from (v_row.pin_locked_until - now())))::integer;
  end if;

  if v_row.pin_hash is not null and v_row.pin_hash <> '' then
    v_matched := v_row.pin_hash = crypt(p_pin, v_row.pin_hash);
  end if;

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null
     where id = v_row.id;
    return v_row.id;
  end if;

  v_attempts := coalesce(v_row.pin_failed_attempts, 0) + 1;
  if v_attempts >= 5 then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = now() + interval '15 minutes'
     where id = v_row.id;
  else
    update public.profiles
       set pin_failed_attempts = v_attempts
     where id = v_row.id;
  end if;
  return null;
end;
$$;

revoke all on function public.pin_check(text, text, text) from public, anon, authenticated, service_role;

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

  -- Only a live session may claim: one deleted by a newer sign-in or by
  -- "Sign out all devices" is over, whatever its token still says.
  if not exists (select 1 from auth.sessions where id = v_sid and user_id = v_uid) then
    return jsonb_build_object('enforced', true, 'current', false);
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
