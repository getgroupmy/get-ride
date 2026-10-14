-- ============================================================================
-- 0192: the server decides the sign-in steps; clearer answers when it says no.
--
--   * pin_policy (Admin -> App Settings -> PIN sign-in): how many wrong PINs
--     lock an account and for how long. pin_check (0184) keeps to it.
--   * pin_attempts_left(phone): what pin-login tells the phone after a wrong
--     PIN, so it can say "2 tries left" (service role only).
--   * my_sign_in_state(): whether the signed-in account still has to choose
--     a PIN. Every account needs one; the app sends anyone without one to
--     "Set your PIN" and doesn't let them past it.
--   * A sign-in SMS refused for too many codes says when to try again.
-- ============================================================================

-- ---- The admin's PIN policy -----------------------------------------------------------------
insert into public.app_settings (key, value)
values ('pin_policy', jsonb_build_object('maxAttempts', 5, 'lockMinutes', 15))
on conflict (key) do nothing;

create or replace function public.pin_policy()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'maxAttempts', least(10, greatest(3, coalesce(
      case when jsonb_typeof(v->'maxAttempts') = 'number' then (v->>'maxAttempts')::numeric end, 5)))::int,
    'lockMinutes', least(1440, greatest(1, coalesce(
      case when jsonb_typeof(v->'lockMinutes') = 'number' then (v->>'lockMinutes')::numeric end, 15)))::int)
  from (select (select value from public.app_settings where key = 'pin_policy') as v) s;
$$;
revoke execute on function public.pin_policy() from public;
grant execute on function public.pin_policy() to anon, authenticated;

create or replace function public.set_pin_policy(p_policy jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change the PIN policy.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('pin_policy', coalesce(p_policy, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  v := public.pin_policy();
  update public.app_settings set value = v where key = 'pin_policy';
  return v;
end;
$$;
revoke execute on function public.set_pin_policy(jsonb) from public, anon;
grant execute on function public.set_pin_policy(jsonb) to authenticated;

-- ---- The check keeps to it --------------------------------------------------------------------
create or replace function public.pin_check(p_phone text, p_pin text, p_ip text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  if v_attempts >= (public.pin_policy()->>'maxAttempts')::int then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = now() + make_interval(mins => (public.pin_policy()->>'lockMinutes')::int)
     where id = v_row.id;
  else
    update public.profiles
       set pin_failed_attempts = v_attempts
     where id = v_row.id;
  end if;
  return null;
end;
$function$;

-- ---- Tries left after a wrong PIN ------------------------------------------------------------------
-- Null for a number with no account or no PIN, so nothing is said about it.
create or replace function public.pin_attempts_left(p_phone text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case when p.pin_locked_until is not null and p.pin_locked_until > now() then 0
              else greatest(0, (public.pin_policy()->>'maxAttempts')::int - coalesce(p.pin_failed_attempts, 0)) end
    from public.profiles p
   where p.pin_hash is not null and p.pin_hash <> ''
     and p.phone = any (array_remove(array[
           '+' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'),
           regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'),
           '0' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'),
           ltrim(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '0')
         ], null))
     and regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') <> ''
   limit 1;
$$;
revoke all on function public.pin_attempts_left(text) from public, anon, authenticated, service_role;
grant execute on function public.pin_attempts_left(text) to service_role;

-- ---- What the signed-in account still has to do -------------------------------------------------
create or replace function public.my_sign_in_state()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'pinSet', coalesce((select p.pin_hash is not null and p.pin_hash <> '' from public.profiles p where p.id = auth.uid()), false),
    'pinRequired', true);
$$;
revoke execute on function public.my_sign_in_state() from public, anon;
grant execute on function public.my_sign_in_state() to authenticated;

-- ---- "Try again in N minutes" for sign-in codes ---------------------------------------------------
create or replace function public.sms_otp_wait_seconds(p_phone text, p_reason text)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.sms_settings;
  v_at timestamptz;
begin
  select * into s from public.sms_settings where id = 1;
  if not found then
    return null;
  end if;
  if p_reason = 'resend_too_soon' then
    select max(created_at) + make_interval(secs => s.min_resend_seconds) into v_at
      from public.sms_log where phone = p_phone and status = 'queued';
  elsif p_reason = 'per_phone_hour' then
    -- When the oldest code counted in the last hour drops out of it.
    select created_at + interval '1 hour' into v_at from public.sms_log
     where phone = p_phone and status = 'queued' and created_at > now() - interval '1 hour'
     order by created_at desc offset greatest(s.per_phone_per_hour - 1, 0) limit 1;
  elsif p_reason = 'per_phone_day' then
    select created_at + interval '1 day' into v_at from public.sms_log
     where phone = p_phone and status = 'queued' and created_at > now() - interval '1 day'
     order by created_at desc offset greatest(s.per_phone_per_day - 1, 0) limit 1;
  elsif p_reason = 'global_hour' then
    select created_at + interval '1 hour' into v_at from public.sms_log
     where status = 'queued' and created_at > now() - interval '1 hour'
     order by created_at desc offset greatest(s.global_per_hour - 1, 0) limit 1;
  end if;
  return case when v_at is null then null else greatest(1, ceil(extract(epoch from v_at - now())))::int end;
end;
$$;
revoke execute on function public.sms_otp_wait_seconds(text, text) from public, anon, authenticated;

-- "3 minutes", "2 hours", "1 minute".
create or replace function public.sms_wait_words(p_seconds int)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when coalesce(p_seconds, 0) <= 0 then 'a few minutes'
    when p_seconds >= 5400 then (round(p_seconds / 3600.0))::int || ' hours'
    when ceil(p_seconds / 60.0) = 1 then '1 minute'
    else ceil(p_seconds / 60.0)::int || ' minutes' end;
$$;

create or replace function public.sms_refusal_message(p_reason text, p_wait_seconds int default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object('error', jsonb_build_object(
    'http_code', case p_reason
                   when 'disabled' then 503 when 'gateway_offline' then 503
                   when 'blocked_number' then 403 when 'prefix' then 403 when 'no_number' then 400
                   else 429 end,
    'message', case p_reason
                 when 'disabled' then 'Sign-in by SMS is unavailable right now. Please try again later.'
                 when 'gateway_offline' then 'Sign-in by SMS is unavailable right now. Please try again later.'
                 when 'blocked_number' then 'This number can''t receive sign-in codes.'
                 when 'prefix' then 'Sign-in codes can''t be sent to this country yet.'
                 when 'no_number' then 'Enter a phone number to get a code.'
                 when 'resend_too_soon' then 'Please wait ' || coalesce(p_wait_seconds, 60) || ' seconds before asking for another code.'
                 when 'per_phone_hour' then 'Too many SMS codes for this number. Try again in '
                                             || public.sms_wait_words(p_wait_seconds) || '.'
                 when 'per_phone_day' then 'You''ve reached today''s limit of SMS codes for this number. Try again in '
                                            || public.sms_wait_words(p_wait_seconds) || '.'
                 when 'global_hour' then 'Sign-in by SMS is busy. Try again in '
                                          || public.sms_wait_words(p_wait_seconds) || '.'
                 else 'The code couldn''t be sent. Please try again.' end));
$$;

create or replace function public.send_sms_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone text := public.sms_e164(event #>> '{user,phone}');
  v_user  uuid;
  v_code  text := event #>> '{sms,otp}';
  v_reason text;
  v_template text;
  v_outbox uuid;
begin
  begin
    v_user := (event #>> '{user,id}')::uuid;
  exception when others then
    v_user := null;
  end;
  -- One request at a time per number, so two at once can't both pass.
  perform pg_advisory_xact_lock(hashtextextended('sms_otp|' || coalesce(v_phone, ''), 149));

  v_reason := public.sms_otp_refusal(v_phone);
  if v_reason is null and coalesce(v_code, '') = '' then
    v_reason := 'no_code';
  end if;
  if v_reason is not null then
    insert into public.sms_log (phone, user_id, status, reason) values (coalesce(v_phone, ''), v_user, 'blocked', v_reason);
    return public.sms_refusal_message(v_reason, public.sms_otp_wait_seconds(v_phone, v_reason));
  end if;

  select message_template into v_template from public.sms_settings where id = 1;
  insert into public.sms_outbox (to_phone, body, channel, created_by)
  values (v_phone, replace(coalesce(v_template, 'Your GET.ride code is {code}. Do not share it.'), '{code}', v_code), 'otp', null)
  returning id into v_outbox;
  insert into public.sms_log (phone, user_id, status, outbox_id) values (v_phone, v_user, 'queued', v_outbox);
  return '{}'::jsonb;
exception when others then
  begin
    insert into public.sms_log (phone, user_id, status, reason)
    values (coalesce(v_phone, ''), v_user, 'failed', left(sqlerrm, 200));
  exception when others then
    null;
  end;
  return public.sms_refusal_message('error');
end;
$function$;
