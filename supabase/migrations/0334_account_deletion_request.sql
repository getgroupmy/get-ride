-- ============================================================================
-- 0334 — Delete your account from the web (getride.my/delete-account), the
-- account-deletion link Google Play asks for.
--
-- Version 20261102110000 (0334_account_deletion_request). Re-runnable: the
-- table and indexes "if not exists", functions "create or replace",
-- triggers and policies dropped first, settings "on conflict do nothing".
-- Stands on 0194 (account deletion), 0149/0292 (the sign-in SMS hook with
-- its limits and country rules), 0137/0234 (auth_rate_take) and 0270
-- (admin_audit_log); nothing from 0333.
--
-- Two ways on the page, both without the app:
--   * Sign in and delete: the usual SMS sign-in, then
--     delete_my_account_web(reason) — 0194's delete_my_account with its
--     own confirm step (an SMS sign-in in the last 10 minutes), deleted at
--     once as in the app, and the request recorded (method 'sign_in').
--   * Request by phone, for someone who can't sign in:
--       request_account_deletion_code(phone): a 6-digit code texted through
--         0292's send_sms_hook (its limits, country rules, sms_log and the
--         otp queue), only when the number has an account. The answer is
--         the same either way: no way to tell whether a number has one.
--       confirm_account_deletion_request(phone, code, reason): a right code
--         records the request "in grace": the account is signed out
--         everywhere and told, and is deleted when the grace days are over
--         (account_deletion_requests_run, every 15 minutes). A wrong code,
--         and any code for a number with no account, read the same.
--     Signing in again during the grace days cancels it (a trigger on
--     auth.users.last_sign_in_at), as does an admin with Users edit rights.
--
-- The deletion itself is 0194's, moved into account_deletion_apply(user,
-- reason, actor, detail) so the app, the web and the grace run share it;
-- delete_my_account keeps its checks and answers exactly. Final deletion
-- (0194) now also empties the account's voice-protection folder.
--
-- Settings (app_settings 'account_deletion_web'): graceDays, 0 to 30,
-- 7 by default. account_deletion_public_info() gives the page the grace
-- and 0194's retention days without sign-in.
--
-- Rate limits (auth_rate_take, by caller IP and by number, the same for
-- every number): codes 5 per IP per 10 minutes and 20 a day, 3 per number
-- an hour; tries 20 per IP per 10 minutes, 10 per number an hour, 5 per
-- code. A code lasts 10 minutes.
--
-- Audit: every request, cancel and deletion is an account_events row
-- (kinds 'deletion_requested' and 'deletion_cancelled' added); an admin's
-- cancel is also in admin_audit_log. Admins read requests through
-- admin_account_deletion_requests(profile, status); the table itself is
-- closed to anon and authenticated.
-- ============================================================================

-- ---- Settings ----------------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('account_deletion_web', jsonb_build_object('graceDays', 7))
on conflict (key) do nothing;

create or replace function public.account_deletion_web_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('graceDays',
    least(30, greatest(0, coalesce(
      (select case when jsonb_typeof(value->'graceDays') = 'number' then (value->>'graceDays')::numeric end
         from public.app_settings where key = 'account_deletion_web'), 7)::int)));
$$;
revoke execute on function public.account_deletion_web_config() from public, anon;
grant execute on function public.account_deletion_web_config() to authenticated, service_role;

create or replace function public.set_account_deletion_web_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days numeric := case when jsonb_typeof(p_config->'graceDays') = 'number'
                         then (p_config->>'graceDays')::numeric end;
begin
  if not public.caller_can_edit_users() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_days is null or v_days < 0 or v_days > 30 then
    raise exception 'ACCOUNT_DELETION_CONFIG' using hint = 'Wait 0 to 30 days before deleting a phone request.';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('account_deletion_web', jsonb_build_object('graceDays', round(v_days)::int), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.account_deletion_web_config();
end;
$$;
revoke execute on function public.set_account_deletion_web_config(jsonb) from public, anon;
grant execute on function public.set_account_deletion_web_config(jsonb) to authenticated;

-- What the public page says: no personal data, safe for anyone.
create or replace function public.account_deletion_public_info()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.account_deletion_config() || public.account_deletion_web_config()
         || jsonb_build_object('codeMinutes', 10);
$$;
revoke execute on function public.account_deletion_public_info() from public;
grant execute on function public.account_deletion_public_info() to anon, authenticated;

-- ---- Requests ----------------------------------------------------------------------------------
create table if not exists public.account_deletion_requests (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null,
  phone_hash      text not null,
  source          text not null default 'web' check (source in ('web')),
  method          text not null check (method in ('phone_code', 'sign_in')),
  status          text not null default 'requested'
                  check (status in ('requested', 'in_grace', 'deleted', 'cancelled', 'expired')),
  code_hash       text,
  code_expires_at timestamptz,
  code_attempts   int not null default 0,
  reason          text check (char_length(reason) <= 300),
  confirmed_at    timestamptz,
  grace_until     timestamptz,
  deleted_at      timestamptz,
  cancelled_at    timestamptz,
  cancel_reason   text check (cancel_reason in ('signed_in', 'admin')),
  cancelled_by    uuid,
  last_error      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists account_deletion_requests_user_idx
  on public.account_deletion_requests (user_id, created_at desc);
create index if not exists account_deletion_requests_phone_idx
  on public.account_deletion_requests (phone_hash, created_at desc) where status = 'requested';
create index if not exists account_deletion_requests_due_idx
  on public.account_deletion_requests (grace_until) where status = 'in_grace';
-- One request in grace per account.
create unique index if not exists account_deletion_requests_one_open
  on public.account_deletion_requests (user_id) where status = 'in_grace';

alter table public.account_deletion_requests enable row level security;
revoke all on public.account_deletion_requests from anon, authenticated;
comment on table public.account_deletion_requests is
  'Account deletion asked for on getride.my/delete-account (0334). Written and read only through its SECURITY DEFINER functions; admins use admin_account_deletion_requests.';

-- The event log takes the request's two events too.
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'account_events_kind_check'
                and conrelid = 'public.account_events'::regclass) then
    alter table public.account_events drop constraint account_events_kind_check;
  end if;
  alter table public.account_events add constraint account_events_kind_check
    check (kind in ('deleted', 'linked', 'final_deleted', 'deletion_requested', 'deletion_cancelled'));
end $$;

-- The number as the request keeps it: a hash, never the digits.
create or replace function public.account_deletion_phone_hash(p_e164 text)
returns text
language sql
immutable
set search_path = public
as $$
  select encode(sha256(convert_to('get.ride/account-deletion/' || coalesce(p_e164, ''), 'UTF8')), 'hex');
$$;
revoke execute on function public.account_deletion_phone_hash(text) from public, anon, authenticated;

-- The live account on [p_e164], or null. As 0292's send_sms_hook finds it.
create or replace function public.account_deletion_find_user(p_e164 text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id from public.profiles p
   where p.phone = any (array[p_e164, ltrim(coalesce(p_e164, ''), '+')])
     and p.deleted_at is null
   order by p.created_at desc
   limit 1;
$$;
revoke execute on function public.account_deletion_find_user(text) from public, anon, authenticated;

-- "RATE_LIMITED:<seconds>" when any of the limits says wait, as 0137's lookups do.
create or replace function public.account_deletion_rate(p_kind text, p_ip text, p_hash text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wait int := 0;
begin
  if p_kind = 'code' then
    v_wait := greatest(
      public.auth_rate_take('deletion_code_ip', p_ip, 5, interval '10 minutes'),
      public.auth_rate_take('deletion_code_ip_day', p_ip, 20, interval '1 day'),
      public.auth_rate_take('deletion_code_phone', p_hash, 3, interval '1 hour'));
  else
    v_wait := greatest(
      public.auth_rate_take('deletion_try_ip', p_ip, 20, interval '10 minutes'),
      public.auth_rate_take('deletion_try_phone', p_hash, 10, interval '1 hour'));
  end if;
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
end;
$$;
revoke execute on function public.account_deletion_rate(text, text, text) from public, anon, authenticated;

-- ---- The deletion, shared by the app, the web and the grace run -----------------------------------
-- 0194's delete_my_account from the active-ride check on, for any account.
-- Returns {ok:true} or {error: 'already_deleted' | 'active_ride'}.
create or replace function public.account_deletion_apply(p_uid uuid, p_reason text, p_actor uuid,
                                                         p_detail jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := p_uid;
  p      public.profiles;
  s      public.scheduled_rides;
  v_rides int := 0;
  v_booked int := 0;
  v_jobs int := 0;
begin
  select * into p from public.profiles where id = v_uid for update;
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p.deleted_at is not null then
    return jsonb_build_object('error', 'already_deleted');
  end if;

  if public.account_has_active_ride(v_uid) then
    return jsonb_build_object('error', 'active_ride');
  end if;

  -- A request still looking for a driver.
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(), cancel_requested_by = 'rider',
         cancel_reason = 'Account deleted'
   where rider_id = v_uid and status = 'open';
  get diagnostics v_rides = row_count;

  -- Upcoming bookings: cancelled with no fee; the driver is told.
  for s in
    select * from public.scheduled_rides
     where rider_id = v_uid and status in ('scheduled', 'assigned', 'released')
     for update
  loop
    if s.ride_id is not null then
      update public.ride_requests
         set status = 'cancelled', cancelled_at = now(), cancel_requested_by = 'rider',
             cancel_reason = 'Account deleted'
       where id = s.ride_id and status = 'open';
    end if;
    update public.scheduled_rides
       set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system',
           cancel_reason = 'Account deleted', cancel_fee = 0, cancel_fee_status = 'none'
     where id = s.id;
    v_booked := v_booked + 1;
    if s.partner_id is not null then
      perform public.enqueue_notification(s.partner_id, 'sched-cancel-' || s.id, 'scheduled_ride', 'normal',
        'Scheduled ride cancelled',
        'The passenger cancelled the ride booked for '
          || to_char(s.pickup_at at time zone 'Asia/Kuala_Lumpur', 'DD Mon, HH24:MI') || '.',
        jsonb_build_object('type', 'scheduled_cancelled', 'scheduled_ride_id', s.id));
    end if;
  end loop;

  -- Bookings this driver took go back to be matched again.
  for s in
    select * from public.scheduled_rides where partner_id = v_uid and status = 'assigned' for update
  loop
    update public.scheduled_rides
       set status = 'scheduled', partner_id = null, partner_accepted_at = null
     where id = s.id;
    v_jobs := v_jobs + 1;
    perform public.enqueue_notification(s.rider_id, 'sched-driver-left-' || s.id || '-' || now()::text,
      'scheduled_ride', 'normal', 'Finding you a new driver',
      'Your driver can''t make it. Your ride is still booked and we''re finding you another driver.',
      jsonb_build_object('type', 'scheduled_reassigning', 'scheduled_ride_id', s.id));
  end loop;

  -- Off the map and out of every push.
  delete from public.driver_presence where profile_id = v_uid;
  delete from public.push_tokens where profile_id = v_uid;

  update public.profiles
     set deleted_at = now(), deleted_phone = p.phone, deletion_reason = left(nullif(trim(p_reason), ''), 300),
         profile_status = 'Deleted', phone = null, updated_at = now()
   where id = v_uid;

  update public.partners
     set status = 'blocked', status_note = 'Account deleted by the partner.'
   where auth_user_id = v_uid;

  -- Release the number: the old login keeps no phone and can't sign in again.
  update auth.users
     set phone = null, phone_confirmed_at = null, phone_change = '', phone_change_token = '',
         banned_until = now() + interval '100 years', updated_at = now()
   where id = v_uid;
  update auth.identities
     set identity_data = identity_data - 'phone', updated_at = now()
   where user_id = v_uid and provider = 'phone';
  delete from auth.sessions where user_id = v_uid;
  delete from public.active_sessions where user_id = v_uid;

  insert into public.account_events (profile_id, kind, actor_id, detail)
  values (v_uid, 'deleted', p_actor, jsonb_build_object(
    'phone', p.phone, 'reason', left(nullif(trim(p_reason), ''), 300),
    'requestsCancelled', v_rides, 'bookingsCancelled', v_booked, 'jobsReleased', v_jobs)
    || coalesce(p_detail, '{}'::jsonb));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.account_deletion_apply(uuid, text, uuid, jsonb) from public, anon, authenticated;

-- 0194's, unchanged in what it checks and answers; the deletion is shared.
create or replace function public.delete_my_account(p_pin text default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  p      public.profiles;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = v_uid for update;
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p.deleted_at is not null then
    return jsonb_build_object('error', 'already_deleted');
  end if;

  if nullif(trim(coalesce(p_pin, '')), '') is not null then
    if public.pin_check(coalesce(p.phone, ''), p_pin, public.request_client_ip()) is distinct from v_uid then
      return jsonb_build_object('error', 'wrong_pin');
    end if;
  elsif not public.session_recent_sms_sign_in() then
    return jsonb_build_object('error', 'confirm_needed');
  end if;

  return public.account_deletion_apply(v_uid, p_reason, v_uid);
end;
$$;
revoke execute on function public.delete_my_account(text, text) from public, anon;
grant execute on function public.delete_my_account(text, text) to authenticated;

-- ---- Sign in and delete (the web page) -----------------------------------------------------------
-- delete_my_account after the page's SMS sign-in, recorded as a web request.
create or replace function public.delete_my_account_web(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_phone text;
  v_out   jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select phone into v_phone from public.profiles where id = v_uid;
  v_out := public.delete_my_account(null, p_reason);
  if (v_out ->> 'ok')::boolean is true then
    update public.account_deletion_requests
       set status = 'deleted', deleted_at = now(), updated_at = now(), code_hash = null
     where user_id = v_uid and status in ('requested', 'in_grace');
    insert into public.account_deletion_requests
      (user_id, phone_hash, method, status, reason, confirmed_at, deleted_at)
    values (v_uid, public.account_deletion_phone_hash(public.sms_e164(v_phone)), 'sign_in', 'deleted',
            left(nullif(trim(p_reason), ''), 300), now(), now());
  end if;
  return v_out;
end;
$$;
revoke execute on function public.delete_my_account_web(text) from public, anon;
grant execute on function public.delete_my_account_web(text) to authenticated;

-- ---- Request by phone ----------------------------------------------------------------------------
-- Texts a code to [p_phone] when it has an account. The answer never says
-- whether it has: {ok, codeMinutes} for every number that passes the
-- limits. A number that isn't a number at all is refused, the same for all.
create or replace function public.request_account_deletion_code(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := public.sms_e164(p_phone);
  v_hash  text;
  v_user  uuid;
  v_id    uuid;
  v_code  text;
  v_sent  jsonb;
begin
  if v_phone is null or length(v_phone) < 8 or length(v_phone) > 16 then
    raise exception 'DELETION_PHONE' using hint = 'Enter your mobile number with its country code.';
  end if;
  v_hash := public.account_deletion_phone_hash(v_phone);
  perform public.account_deletion_rate('code', public.request_client_ip(), v_hash);
  -- One request at a time per number.
  perform pg_advisory_xact_lock(hashtextextended('account_deletion|' || v_hash, 334));

  v_user := public.account_deletion_find_user(v_phone);
  if v_user is not null then
    -- An earlier code for this number stops working.
    update public.account_deletion_requests
       set status = 'expired', code_hash = null, updated_at = now()
     where phone_hash = v_hash and status = 'requested';

    v_id := gen_random_uuid();
    v_code := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint
                     % 1000000))::text, 6, '0');
    insert into public.account_deletion_requests (id, user_id, phone_hash, method, status, code_hash, code_expires_at)
    values (v_id, v_user, v_hash, 'phone_code', 'requested',
            encode(sha256(convert_to(v_id::text || ':' || v_code, 'UTF8')), 'hex'), now() + interval '10 minutes');

    -- The sign-in code's path: its limits, the country rules, the log and the gateway queue.
    begin
      v_sent := public.send_sms_hook(jsonb_build_object(
        'user', jsonb_build_object('id', v_user, 'phone', v_phone),
        'sms', jsonb_build_object('otp', v_code)));
    exception when others then
      v_sent := jsonb_build_object('error', jsonb_build_object('message', left(sqlerrm, 200)));
    end;
    if v_sent ? 'error' then
      update public.account_deletion_requests
         set last_error = left(coalesce(v_sent #>> '{error,message}', 'not sent'), 200)
       where id = v_id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'codeMinutes', 10);
end;
$$;
revoke execute on function public.request_account_deletion_code(text) from public;
grant execute on function public.request_account_deletion_code(text) to anon, authenticated;

-- Signs the account out everywhere: its next sign-in cancels the request.
create or replace function public.account_deletion_sign_out(p_uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from auth.sessions where user_id = p_uid;
  delete from public.active_sessions where user_id = p_uid;
  begin
    delete from public.account_devices where user_id = p_uid;
  exception when undefined_table then
    null;
  end;
end;
$$;
revoke execute on function public.account_deletion_sign_out(uuid) from public, anon, authenticated;

-- The code from the text. Right: the request is in grace (or, with no grace
-- days, the account is deleted now) and {ok, graceDays, deleteAfter}. Wrong,
-- expired, too many tries, or a number with no account: {error:'wrong_code'}.
-- Returned, not raised, so a wrong try still counts.
create or replace function public.confirm_account_deletion_request(p_phone text, p_code text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := public.sms_e164(p_phone);
  v_hash  text;
  v_code  text := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
  r       public.account_deletion_requests;
  v_open  public.account_deletion_requests;
  v_days  int := (public.account_deletion_web_config() ->> 'graceDays')::int;
  v_until timestamptz;
  v_out   jsonb;
begin
  if v_phone is null then
    return jsonb_build_object('error', 'wrong_code');
  end if;
  v_hash := public.account_deletion_phone_hash(v_phone);
  perform public.account_deletion_rate('try', public.request_client_ip(), v_hash);
  perform pg_advisory_xact_lock(hashtextextended('account_deletion|' || v_hash, 334));

  select * into r from public.account_deletion_requests
   where phone_hash = v_hash and status = 'requested'
   order by created_at desc limit 1
   for update;
  if r.id is null or r.code_hash is null or r.code_expires_at < now() or r.code_attempts >= 5 then
    return jsonb_build_object('error', 'wrong_code');
  end if;
  if length(v_code) <> 6
     or encode(sha256(convert_to(r.id::text || ':' || v_code, 'UTF8')), 'hex') <> r.code_hash then
    update public.account_deletion_requests
       set code_attempts = code_attempts + 1, updated_at = now(),
           code_hash = case when code_attempts + 1 >= 5 then null else code_hash end
     where id = r.id;
    return jsonb_build_object('error', 'wrong_code');
  end if;

  -- Already asked: the earlier request stands.
  select * into v_open from public.account_deletion_requests
   where user_id = r.user_id and status = 'in_grace' limit 1;
  if v_open.id is not null then
    update public.account_deletion_requests
       set status = 'expired', code_hash = null, updated_at = now()
     where id = r.id;
    return jsonb_build_object('ok', true, 'graceDays', v_days, 'deleteAfter', v_open.grace_until);
  end if;
  -- Deleted since the code was sent: nothing left to do.
  if exists (select 1 from public.profiles where id = r.user_id and deleted_at is not null) then
    update public.account_deletion_requests
       set status = 'deleted', code_hash = null, confirmed_at = now(),
           deleted_at = (select deleted_at from public.profiles where id = r.user_id), updated_at = now()
     where id = r.id;
    return jsonb_build_object('ok', true, 'graceDays', 0, 'deleteAfter', now());
  end if;

  v_until := now() + make_interval(days => v_days);
  update public.account_deletion_requests
     set status = 'in_grace', code_hash = null, confirmed_at = now(), grace_until = v_until,
         reason = left(nullif(trim(p_reason), ''), 300), updated_at = now()
   where id = r.id;
  insert into public.account_events (profile_id, kind, actor_id, detail)
  values (r.user_id, 'deletion_requested', r.user_id, jsonb_build_object(
    'source', 'web', 'method', 'phone_code', 'requestId', r.id, 'graceUntil', v_until,
    'reason', left(nullif(trim(p_reason), ''), 300)));

  if v_days = 0 then
    v_out := public.account_deletion_run_one(r.id);
    return jsonb_build_object('ok', true, 'graceDays', 0, 'deleteAfter', now(),
                              'deleted', coalesce((v_out ->> 'ok')::boolean, false));
  end if;

  perform public.account_deletion_sign_out(r.user_id);
  perform public.enqueue_notification(r.user_id, 'account-deletion-' || r.id, 'account', 'normal',
    'Your account will be deleted',
    'We got a request on getride.my to delete your GET.ride account. It will be deleted on '
      || to_char(v_until at time zone 'Asia/Kuala_Lumpur', 'DD Mon YYYY')
      || '. To keep it, sign in to GET.ride again before then.',
    jsonb_build_object('type', 'account_deletion_requested', 'request_id', r.id));
  return jsonb_build_object('ok', true, 'graceDays', v_days, 'deleteAfter', v_until);
end;
$$;
revoke execute on function public.confirm_account_deletion_request(text, text, text) from public;
grant execute on function public.confirm_account_deletion_request(text, text, text) to anon, authenticated;

-- ---- Cancel by signing in --------------------------------------------------------------------
create or replace function public.account_deletion_cancel(p_id uuid, p_why text, p_by uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.account_deletion_requests;
begin
  update public.account_deletion_requests
     set status = 'cancelled', cancelled_at = now(), cancel_reason = p_why, cancelled_by = p_by, updated_at = now()
   where id = p_id and status = 'in_grace'
  returning * into r;
  if r.id is null then
    return false;
  end if;
  insert into public.account_events (profile_id, kind, actor_id, detail)
  values (r.user_id, 'deletion_cancelled', p_by, jsonb_build_object('requestId', r.id, 'why', p_why));
  perform public.enqueue_notification(r.user_id, 'account-deletion-kept-' || r.id, 'account', 'normal',
    'Your account is kept',
    case p_why when 'signed_in' then 'You signed in, so the request to delete your GET.ride account is cancelled.'
               else 'The request to delete your GET.ride account was cancelled by our team.' end,
    jsonb_build_object('type', 'account_deletion_cancelled', 'request_id', r.id));
  return true;
end;
$$;
revoke execute on function public.account_deletion_cancel(uuid, text, uuid) from public, anon, authenticated;

-- A fresh sign-in (SMS code, PIN or passkey: Auth stamps last_sign_in_at)
-- after the request was confirmed cancels it. Never stops the sign-in.
create or replace function public.account_deletion_on_sign_in()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if new.last_sign_in_at is not null and new.last_sign_in_at is distinct from old.last_sign_in_at then
    begin
      for v_id in
        select id from public.account_deletion_requests
         where user_id = new.id and status = 'in_grace' and confirmed_at < new.last_sign_in_at
      loop
        perform public.account_deletion_cancel(v_id, 'signed_in', new.id);
      end loop;
    exception when others then
      null;
    end;
  end if;
  return new;
end;
$$;
revoke execute on function public.account_deletion_on_sign_in() from public, anon, authenticated;
drop trigger if exists on_auth_user_signed_in_deletion on auth.users;
create trigger on_auth_user_signed_in_deletion
  after update of last_sign_in_at on auth.users
  for each row execute function public.account_deletion_on_sign_in();

-- ---- The grace run -----------------------------------------------------------------------------
-- One request in grace, deleted now. A ride under way waits for the next run.
create or replace function public.account_deletion_run_one(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r      public.account_deletion_requests;
  v_seen timestamptz;
  v_out  jsonb;
begin
  select * into r from public.account_deletion_requests where id = p_id and status = 'in_grace' for update;
  if r.id is null then
    return jsonb_build_object('error', 'not_in_grace');
  end if;
  -- Signed in since (the trigger's backstop).
  select last_sign_in_at into v_seen from auth.users where id = r.user_id;
  if v_seen is not null and v_seen > r.confirmed_at then
    perform public.account_deletion_cancel(r.id, 'signed_in', r.user_id);
    return jsonb_build_object('error', 'signed_in');
  end if;
  v_out := public.account_deletion_apply(r.user_id, r.reason, r.user_id,
             jsonb_build_object('source', 'web', 'method', 'phone_code', 'requestId', r.id));
  if (v_out ->> 'ok')::boolean is true or v_out ->> 'error' = 'already_deleted' then
    update public.account_deletion_requests
       set status = 'deleted', updated_at = now(), last_error = null,
           deleted_at = (select deleted_at from public.profiles where id = r.user_id)
     where id = r.id;
    return jsonb_build_object('ok', true);
  end if;
  update public.account_deletion_requests
     set last_error = coalesce(v_out ->> 'error', 'failed'), updated_at = now()
   where id = r.id;
  return v_out;
end;
$$;
revoke execute on function public.account_deletion_run_one(uuid) from public, anon, authenticated;

-- Every request past its grace days; old codes nobody used are closed.
create or replace function public.account_deletion_requests_run()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id   uuid;
  v_done int := 0;
begin
  update public.account_deletion_requests
     set status = 'expired', code_hash = null, updated_at = now()
   where status = 'requested' and code_expires_at < now();
  for v_id in
    select id from public.account_deletion_requests
     where status = 'in_grace' and grace_until <= now()
     order by grace_until
     limit 200
  loop
    begin
      if (public.account_deletion_run_one(v_id) ->> 'ok')::boolean is true then
        v_done := v_done + 1;
      end if;
    exception when others then
      update public.account_deletion_requests
         set last_error = left(sqlerrm, 200), updated_at = now()
       where id = v_id;
    end;
  end loop;
  return v_done;
end;
$$;
revoke execute on function public.account_deletion_requests_run() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'account-deletion-requests';
    perform cron.schedule('account-deletion-requests', '*/15 * * * *',
      $job$select public.account_deletion_requests_run()$job$);
  end if;
end$$;

-- ---- Admin --------------------------------------------------------------------------------------
-- Users pages (read or edit), or every page.
create or replace function public.caller_can_read_users()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.uid() is null then coalesce(auth.role(), '') not in ('anon', 'authenticated')
    else exists (
      select 1 from public.admin_access
       where profile_id = auth.uid()
         and page in ('*', 'admin-users', 'admin-user-edit'))
  end;
$$;
revoke execute on function public.caller_can_read_users() from public, anon;
grant execute on function public.caller_can_read_users() to authenticated, service_role;

-- The requests, newest first: one account's, or every one (optionally of one status).
create or replace function public.admin_account_deletion_requests(p_profile uuid default null, p_status text default null)
returns table (
  id            uuid,
  user_id       uuid,
  source        text,
  method        text,
  status        text,
  reason        text,
  confirmed_at  timestamptz,
  grace_until   timestamptz,
  deleted_at    timestamptz,
  cancelled_at  timestamptz,
  cancel_reason text,
  last_error    text,
  created_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_can_read_users() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  select r.id, r.user_id, r.source, r.method, r.status, r.reason, r.confirmed_at, r.grace_until,
         r.deleted_at, r.cancelled_at, r.cancel_reason, r.last_error, r.created_at
    from public.account_deletion_requests r
   where (p_profile is null or r.user_id = p_profile)
     and (p_status is null or r.status = p_status)
   order by r.created_at desc
   limit 500;
end;
$$;
revoke execute on function public.admin_account_deletion_requests(uuid, text) from public, anon;
grant execute on function public.admin_account_deletion_requests(uuid, text) to authenticated;

create or replace function public.admin_cancel_account_deletion_request(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
begin
  if not public.caller_can_edit_users() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select user_id into v_user from public.account_deletion_requests where id = p_id;
  if not public.account_deletion_cancel(p_id, 'admin', auth.uid()) then
    raise exception 'ACCOUNT_DELETION_NOT_OPEN' using hint = 'Only a request still in its grace days can be cancelled.';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'account_deletion_request_cancel', v_user, jsonb_build_object('requestId', p_id));
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.admin_cancel_account_deletion_request(uuid) from public, anon;
grant execute on function public.admin_cancel_account_deletion_request(uuid) to authenticated;

-- ---- Final deletion empties the voice-protection folder too ---------------------------------------
-- 0194's, with the account's Voice Protection uploads (`<profile id>/<file>`).
create or replace function public.admin_final_delete_account(p_profile uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p        public.profiles;
  v_days   int := (public.account_deletion_config() ->> 'retentionDays')::int;
  v_parts  uuid[];
  v_folders jsonb;
begin
  if not public.caller_can_edit_users() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = p_profile for update;
  if not found or p.deleted_at is null then
    raise exception 'ACCOUNT_NOT_DELETED' using hint = 'Only a deleted account can be finally deleted.';
  end if;
  if p.final_deleted_at is null and p.deleted_at > now() - make_interval(days => v_days) then
    raise exception 'ACCOUNT_NOT_DUE'
      using hint = 'Deleted accounts are kept for ' || v_days || ' days before final deletion.';
  end if;

  select coalesce(array_agg(id), '{}') into v_parts from public.partners where auth_user_id = p_profile;

  if p.final_deleted_at is null then
    update public.profiles
       set name = 'Deleted user', email = null, ic = null, address = null, profile_image = null,
           avatar_url = null, id_image = null, nationality = null, gender = null, birth_date = null,
           pin = null, login_pin = null, pin_hash = null, phone = null, deleted_phone = null,
           deletion_reason = null, referral_code = null,
           final_deleted_at = now(), final_deleted_by = auth.uid(), updated_at = now()
     where id = p_profile;

    update public.partners
       set name = 'Deleted partner', phone = '', email = null, ic = null, avatar_url = null,
           status_note = 'Account deleted.'
     where id = any(v_parts);
    delete from public.provider_documents where partner_id = any(v_parts) or auth_user_id = p_profile;
    delete from public.partner_documents where partner_id = any(v_parts);

    update public.ride_requests set rider_name = 'Deleted user', rider_phone = null where rider_id = p_profile;
    update public.ride_requests set partner_name = 'Deleted partner', partner_phone = null where partner_id = p_profile;
    update public.safety_incidents set reporter_name = 'Deleted user', reporter_phone = null, lat = null, lng = null
     where reporter_id = p_profile;
    update public.safety_incidents set partner_name = 'Deleted partner' where partner_id = p_profile;
    delete from public.safety_incident_locations
     where incident_id in (select id from public.safety_incidents where reporter_id = p_profile);

    delete from public.emergency_contacts where profile_id = p_profile;
    delete from public.saved_places where user_id = p_profile;
    delete from public.favourite_drivers where rider_id = p_profile or driver_id = p_profile;
    delete from public.personal_qr_codes where owner_id = p_profile;
    delete from public.push_tokens where profile_id = p_profile;
    delete from public.user_notifications where profile_id = p_profile;
    delete from public.user_location_history where user_id = p_profile;
    delete from public.voice_protection_recordings where profile_id = p_profile;
    delete from public.help_questions where user_id = p_profile;
    delete from public.user_sessions where user_id = p_profile;
    delete from public.active_sessions where user_id = p_profile;

    update auth.users
       set email = null, phone = null, raw_user_meta_data = '{}'::jsonb, updated_at = now()
     where id = p_profile;
    update auth.identities set identity_data = jsonb_build_object('sub', p_profile::text), updated_at = now()
     where user_id = p_profile;

    insert into public.account_events (profile_id, kind, actor_id, detail)
    values (p_profile, 'final_deleted', auth.uid(), jsonb_build_object('partners', to_jsonb(v_parts)));
  end if;

  select jsonb_agg(f) into v_folders from (
    select jsonb_build_object('bucket', 'avatars', 'folder', p_profile::text) f
    union all select jsonb_build_object('bucket', 'ID_Image', 'folder', p_profile::text)
    union all select jsonb_build_object('bucket', 'provider-documents', 'folder', p_profile::text)
    union all select jsonb_build_object('bucket', 'provider-documents', 'folder', x::text) from unnest(v_parts) x
    union all select jsonb_build_object('bucket', 'voice-protection', 'folder', p_profile::text)
  ) s;
  return jsonb_build_object('ok', true, 'folders', coalesce(v_folders, '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_final_delete_account(uuid) from public, anon;
grant execute on function public.admin_final_delete_account(uuid) to authenticated;

-- The admin app empties those folders (0194's rule, with voice-protection).
drop policy if exists "account files admin delete" on storage.objects;
create policy "account files admin delete" on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'ID_Image', 'provider-documents', 'voice-protection')
         and (select public.caller_can_edit_users()));

notify pgrst, 'reload schema';
