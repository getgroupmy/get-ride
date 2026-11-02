-- ============================================================================
-- 0333 — Store review login: a number Google Play and App Store reviewers
-- sign in with, no SMS code and no PIN, into ONE sealed demo account that
-- can only run the app's simulations.
--
-- Version 20261102100000 (0333_store_review). Re-runnable: tables, columns
-- and indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, seed rows only where missing.
--
-- 1. store_review_settings (one row): on / off (OFF by default) and the
--    number (digits, default 60608080, shorter than a Malaysian mobile, so
--    it never meets the 0292 rules while it is on). Admins only, through
--    admin_store_review_state / admin_store_review_set (edit on Admin ›
--    Settings › App Settings, 'admin-settings-site'). A number a live
--    account already uses is refused (STORE_REVIEW_PHONE_TAKEN).
-- 2. store_review_sign_ins: every try of the reviewer route (allowed, off,
--    wrong number, rate limited), with the time, the address, the platform,
--    the device, the app version and the user agent. Admins read it.
-- 3. The demo account: one fixed Auth user (store_review_user_id()) made
--    here when missing, with a phone no one can receive a code on
--    (+999 60608080, no country), app_metadata.store_review = true (so every
--    token it gets says so), profiles.store_review = true, no PIN, not a
--    partner, not an admin, and up to 10 devices at once (0298), so several
--    test phones stay signed in.
-- 4. Sign-in: profile_phone_lookup (0292's) answers store_review = true for
--    the number while the switch is on, before the country rules; the app
--    then calls pin-login's `review` action, which asks
--    store_review_sign_in() (service role only: the switch, the number, a
--    per-address and an overall rate limit, the log) and mints a session for
--    the demo account alone. Off, the number is like any other (the phone
--    rules apply). my_sign_in_state (0192's) does not ask the demo account
--    for a PIN. A lookup of the demo account's own phone is refused.
-- 5. The seal, on the server. is_store_review(uid) is the account's flag;
--    store_review_caller() is the caller's token (its app_metadata, or the
--    demo account's id), read without a table lookup.
--      a. request_guard (0298's PostgREST pre-request hook): for the demo
--         account, every table write (POST / PATCH / PUT / DELETE) and
--         every view that is not security_invoker is refused, and RPCs only
--         run from a read-only list (store_review_rpc_allowed: the session
--         checks, settings readers (*_config), price quotes (*_quote) and
--         the account's own lists (my_*, *_mine)). Refused with HTTP 403,
--         'STORE_REVIEW_DEMO'.
--      b. Reads: a restrictive SELECT policy on every table with a person
--         column (a foreign key to profiles or auth.users, or a uuid column
--         named user_id, rider_id, driver_id ...): the demo account reads
--         only rows that name it, so other people's data reads as nothing.
--      c. Writes, in depth (whatever path they come by: a definer RPC, an
--         edge function with the service key): a BEFORE INSERT trigger
--         (store_review_seal) on bookings and trips of every module, offers,
--         chat, calls, support, SOS, wallet and payments, partners and
--         their documents and vehicles, driver presence, Family, favourites,
--         referrals, promo redemptions, QR codes, phone changes and admin
--         access refuses a row from the demo account or naming it
--         ('STORE_REVIEW_DEMO').
--      d. profiles: its phone never changes and it is never deleted; the
--         flag changes only from the database itself. auth.users: its phone
--         and email never change.
--      e. storage.objects: the demo account uploads, replaces and deletes
--         nothing.
-- 6. News and offers: profiles.news_offers, OFF for everyone (new and
--    existing) until they opt in (the permissions notice, or Settings ›
--    Notifications), set_news_offers(on) for the signed-in account only,
--    and news_offers_on_ids() (service role) that send-push reads: a
--    broadcast from Admin › Push Notification, sent now or on a schedule
--    (push_schedules, 0279), reaches only those accounts (Apple 4.5.4,
--    PDPA: marketing is opt-in). Trip,
--    offer, call, chat, money, safety, document and account pushes, and an
--    admin's push to one person, are sent as before.
-- 7. Passenger location check-ins when the app is closed (owner's switch,
--    OFF by default): app_settings 'location_checkins' {passengers},
--    location_checkins_config() for the app, set_location_checkins_config
--    (edit on App Settings). profiles.location_checkins: the passenger's own
--    opt-in (off until they turn it on, set_location_checkins). The closed
--    app's reports (push_background_location, 0278's) are kept only for a
--    partner (drivers unchanged), or for a passenger while the switch is on
--    AND they opted in; any other report is ignored.
--
-- Deploy with it: supabase/functions/pin-login (the `review` action) and
-- supabase/functions/send-push (News and offers).
-- ============================================================================

-- ---- 1. Settings ------------------------------------------------------------------------------------
create table if not exists public.store_review_settings (
  id         smallint primary key default 1 check (id = 1),
  enabled    boolean not null default false,
  phone      text not null default '60608080' check (phone ~ '^[0-9]{6,15}$'),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.store_review_settings (id) values (1) on conflict (id) do nothing;

alter table public.store_review_settings enable row level security;
revoke all on public.store_review_settings from public, anon, authenticated;
grant all on public.store_review_settings to service_role;

-- ---- 2. The log ---------------------------------------------------------------------------------------
create table if not exists public.store_review_sign_ins (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  outcome     text not null check (outcome in ('allowed', 'off', 'wrong_number', 'rate_limited', 'no_account')),
  phone       text check (phone is null or length(phone) <= 20),
  ip          text check (ip is null or length(ip) <= 64),
  platform    text check (platform is null or length(platform) <= 20),
  device      text check (device is null or length(device) <= 120),
  app_version text check (app_version is null or length(app_version) <= 40),
  user_agent  text check (user_agent is null or length(user_agent) <= 200)
);
create index if not exists store_review_sign_ins_at on public.store_review_sign_ins (at desc);

alter table public.store_review_sign_ins enable row level security;
revoke all on public.store_review_sign_ins from public, anon, authenticated;
grant select on public.store_review_sign_ins to authenticated;
grant all on public.store_review_sign_ins to service_role;
drop policy if exists store_review_sign_ins_admin_read on public.store_review_sign_ins;
create policy store_review_sign_ins_admin_read on public.store_review_sign_ins
  for select to authenticated using ((select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_store_review_set', 'admin-settings-site')
on conflict do nothing;

-- ---- 3. Who is the demo account -------------------------------------------------------------------
alter table public.profiles add column if not exists store_review boolean not null default false;

create or replace function public.store_review_user_id()
returns uuid
language sql
immutable
set search_path = public
as $$
  select 'a0000333-5707-4e00-8000-000000000333'::uuid;
$$;

-- Whether [p_uid] is a store review account (the flag on its profile).
create or replace function public.is_store_review(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_uid is not null
     and (p_uid = public.store_review_user_id()
          or exists (select 1 from public.profiles p where p.id = p_uid and p.store_review));
$$;
revoke execute on function public.is_store_review(uuid) from public, anon;
grant execute on function public.is_store_review(uuid) to authenticated, service_role;

-- Whether the caller's token is the store review account's: its
-- app_metadata (set on the Auth user, which no user can change) or its id.
-- No table is read, so policies and triggers can ask on every statement.
create or replace function public.store_review_caller()
returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  v jsonb;
begin
  begin
    v := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then
    return false;
  end;
  if v is null then
    return false;
  end if;
  return coalesce(v -> 'app_metadata' ->> 'store_review', '') = 'true'
      or coalesce(v ->> 'sub', '') = public.store_review_user_id()::text;
end;
$$;
grant execute on function public.store_review_caller() to anon, authenticated, service_role;

-- The demo account itself: made once, kept flagged on every run.
do $demo$
declare
  v_id uuid := public.store_review_user_id();
begin
  if not exists (select 1 from auth.users where id = v_id) then
    insert into auth.users (
      instance_id, id, aud, role, email, phone, phone_confirmed_at, encrypted_password,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      phone_change, phone_change_token, email_change_token_current, reauthentication_token)
    values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', null, '99960608080', now(), '',
      '{"provider": "phone", "providers": ["phone"], "store_review": true}'::jsonb,
      '{"name": "Store review (demo)"}'::jsonb, now(), now(),
      '', '', '', '', '', '', '', '');
  end if;
  update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"store_review": true}'::jsonb
   where id = v_id
     and coalesce(raw_app_meta_data ->> 'store_review', '') <> 'true';
  begin
    if not exists (select 1 from auth.identities where user_id = v_id) then
      insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (v_id::text, v_id, jsonb_build_object('sub', v_id::text, 'phone', '99960608080'), 'phone', null, now(), now());
    end if;
  exception when others then
    raise notice 'store review: no Auth identity row (%)', sqlerrm;
  end;
  -- The sign-up trigger made the profile; a database without it gets one here.
  insert into public.profiles (id, phone) values (v_id, '99960608080') on conflict (id) do nothing;
  update public.profiles
     set store_review = true,
         name = coalesce(name, 'Store review (demo)'),
         nationality = coalesce(nationality, 'MY'),
         status = 'approved',
         profile_status = 'Approved'
   where id = v_id
     and (not store_review or name is null or nationality is null
          or status is distinct from 'approved' or profile_status is distinct from 'Approved');
  -- Several test phones at once (0298), never one signing the next out.
  insert into public.device_allowances (user_id, devices, reason)
  values (v_id, 10, 'Store review: several reviewer test devices')
  on conflict (user_id) do nothing;
end
$demo$;

-- ---- 4. Sign-in ---------------------------------------------------------------------------------------
-- Whether [p_phone] is the store review number and the switch is on.
create or replace function public.store_review_number_on(p_phone text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select s.enabled and s.phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
                     from public.store_review_settings s where s.id = 1), false);
$$;
revoke execute on function public.store_review_number_on(text) from public, anon, authenticated;

-- The phone screen: 0292's, with store_review. The column changes the
-- function's result, so it is made again.
drop function if exists public.profile_phone_lookup(text);
create function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile  boolean,
  has_pin      boolean,
  is_deleted   boolean,
  store_review boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip   text := public.request_client_ip();
  v_wait integer := public.auth_rate_take('phone_lookup', v_ip, 20, interval '10 minutes');
  v_has  boolean;
  v_pin  boolean;
  v_del  boolean;
  v_demo boolean;
  v_rule jsonb;
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  v_wait := public.auth_rate_take('phone_lookup_day', v_ip, 100, interval '1 day');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  -- The store review number while the switch is on: no account, no code,
  -- no country rules; the app signs in through pin-login's review action.
  if public.store_review_number_on(p_phone) then
    return query select false, false, false, true;
    return;
  end if;
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array['+' || d, d, '0' || d, ltrim(d, '0')], null) as v
    from digits
  ),
  match as (
    select p.pin_hash, p.profile_status, p.store_review
    from public.profiles p, variants
    where p.phone = any(variants.v)
      and p.deleted_at is null
    order by (lower(p.profile_status::text) = 'deleted'), p.created_at desc
    limit 1
  )
  select
    exists(select 1 from match),
    coalesce((select m.pin_hash is not null and m.pin_hash <> '' from match m), false),
    coalesce((select lower(m.profile_status::text) = 'deleted' from match m), false),
    coalesce((select m.store_review from match m), false)
  into v_has, v_pin, v_del, v_demo;
  -- The demo account's own phone is no way in.
  if v_demo then
    raise exception 'PHONE_BLOCKED: This number can''t be used to sign in.';
  end if;
  v_rule := public.phone_rule_check(p_phone, not v_has);
  if v_rule ? 'code' then
    raise exception '%', public.phone_rule_message(v_rule);
  end if;
  return query select v_has, v_pin, v_del, false;
end;
$$;
revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- pin-login's review action (service role only): the switch, the number,
-- the rate limits, and a line in the log either way. The demo account's id
-- when it may sign in.
create or replace function public.store_review_sign_in(
  p_phone text,
  p_ip text,
  p_platform text default null,
  p_device text default null,
  p_app_version text default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.store_review_settings;
  v_ip text := coalesce(nullif(btrim(p_ip), ''), 'unknown');
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_wait integer;
  v_outcome text;
  v_user uuid := public.store_review_user_id();
begin
  v_wait := public.auth_rate_take('store_review', v_ip, 30, interval '10 minutes');
  if v_wait = 0 then
    v_wait := public.auth_rate_take('store_review_all', 'all', 300, interval '1 hour');
  end if;
  select * into s from public.store_review_settings where id = 1;
  v_outcome := case
    when v_wait > 0 then 'rate_limited'
    when s.id is null or not s.enabled then 'off'
    when v_digits <> s.phone then 'wrong_number'
    when not exists (select 1 from auth.users u where u.id = v_user)
      or not public.is_store_review(v_user) then 'no_account'
    else 'allowed'
  end;
  insert into public.store_review_sign_ins (outcome, phone, ip, platform, device, app_version, user_agent)
  values (v_outcome, left(v_digits, 20), left(v_ip, 64), left(lower(p_platform), 20), left(p_device, 120),
          left(p_app_version, 40), left(p_user_agent, 200));
  delete from public.store_review_sign_ins where at < now() - interval '180 days';
  return jsonb_build_object(
    'ok', v_outcome = 'allowed',
    'outcome', v_outcome,
    'user_id', case when v_outcome = 'allowed' then v_user end,
    'retry_after', nullif(v_wait, 0));
end;
$$;
revoke execute on function public.store_review_sign_in(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.store_review_sign_in(text, text, text, text, text, text) to service_role;

-- 0192's, with no PIN asked of the demo account.
create or replace function public.my_sign_in_state()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'pinSet', coalesce((select p.pin_hash is not null and p.pin_hash <> '' from public.profiles p where p.id = auth.uid()), false),
    'pinRequired', not public.is_store_review(auth.uid()),
    'storeReview', public.is_store_review(auth.uid()));
$$;
revoke execute on function public.my_sign_in_state() from public, anon;
grant execute on function public.my_sign_in_state() to authenticated;

-- ---- Admin ------------------------------------------------------------------------------------------
create or replace function public.admin_store_review_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.store_review_settings;
begin
  if not public.caller_is_admin() then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  select * into s from public.store_review_settings where id = 1;
  return jsonb_build_object(
    'enabled', coalesce(s.enabled, false),
    'phone', coalesce(s.phone, '60608080'),
    'updatedAt', s.updated_at,
    'accountReady', exists (select 1 from auth.users where id = public.store_review_user_id())
                    and public.is_store_review(public.store_review_user_id()),
    'signIns', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', l.at, 'outcome', l.outcome, 'phone', l.phone, 'ip', l.ip, 'platform', l.platform,
               'device', l.device, 'appVersion', l.app_version) order by l.at desc, l.id desc)
        from (select * from public.store_review_sign_ins order by at desc, id desc limit 100) l), '[]'::jsonb),
    'allowedLast30Days', (select count(*) from public.store_review_sign_ins
                           where outcome = 'allowed' and at > now() - interval '30 days'));
end;
$$;
revoke execute on function public.admin_store_review_state() from public, anon;
grant execute on function public.admin_store_review_state() to authenticated;

create or replace function public.admin_store_review_set(p_enabled boolean, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.caller_admin_can_write('rpc:admin_store_review_set') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the store review login.';
  end if;
  if v_digits !~ '^[0-9]{6,15}$' then
    raise exception 'STORE_REVIEW_PHONE: Enter 6 to 15 digits, with the country code.' using errcode = '22023';
  end if;
  if exists (select 1 from public.profiles p
              where p.phone = any (array['+' || v_digits, v_digits, '0' || v_digits, ltrim(v_digits, '0')])
                and p.deleted_at is null
                and not p.store_review) then
    raise exception 'STORE_REVIEW_PHONE_TAKEN: An account already uses this number. Pick another.' using errcode = '22023';
  end if;
  insert into public.store_review_settings (id, enabled, phone, updated_at, updated_by)
  values (1, coalesce(p_enabled, false), v_digits, now(), auth.uid())
  on conflict (id) do update
    set enabled = excluded.enabled, phone = excluded.phone, updated_at = now(), updated_by = auth.uid();
  return public.admin_store_review_state();
end;
$$;
revoke execute on function public.admin_store_review_set(boolean, text) from public, anon;
grant execute on function public.admin_store_review_set(boolean, text) to authenticated;

-- ---- 5a. The pre-request seal -----------------------------------------------------------------------
-- The RPCs the demo account may call: read-only, about itself or the
-- settings. Everything else (bookings, payments, chat, calls, partner
-- sign-up, admin) is refused before it runs.
create or replace function public.store_review_rpc_allowed(p_name text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_name is not null and (
       p_name = any (array[
         'claim_session', 'session_is_current', 'my_sign_in_state', 'pin_policy', 'sign_in_config',
         'permission_rules', 'device_registration_status', 'push_unregister_token',
         'notifications_mark_read', 'notifications_delete', 'ack_notification', 'ack_ride_notifications',
         'help_search', 'partner_type_check', 'ride_option_place_at', 'promo_zone_here', 'promo_offers',
         'ride_cancel_terms', 'ride_tip_terms', 'statement_surcharge_names', 'partner_statement_layout',
         'mygig_global', 'ev_settings', 'ev_profiles_for_app', 'family_pay_option', 'family_passengers',
         'family_my_invites', 'passenger_cover_mine', 'payment_purpose_info', 'dispatch_my_checks',
         'dispatch_my_stands', 'dispatch_my_fleets', 'business_my_accounts', 'driver_services_for',
         'c2c_available_at', 'get_coin_market_stats', 'account_deletion_config', 'set_news_offers',
         'set_location_checkins'])
    or (p_name ~ '_config$' and p_name !~ '^(set_|admin_)')
    or (p_name ~ '_quote$' and p_name !~ '^admin_')
    or (p_name ~ '^my_' and p_name <> all (array['my_qr_codes', 'my_ride_code']))
    or p_name ~ '_mine$'
  );
$$;

-- Whether a request at [p_path] with [p_method] is refused to the demo
-- account: an RPC off the list, any write to a table, or a view that does
-- not read as the caller.
create or replace function public.store_review_request_blocked(p_path text, p_method text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rel text;
begin
  if coalesce(p_path, '') like '/rpc/%' then
    return not public.store_review_rpc_allowed(split_part(substr(p_path, 6), '/', 1));
  end if;
  if upper(coalesce(nullif(p_method, ''), 'GET')) not in ('GET', 'HEAD') then
    return true;
  end if;
  v_rel := split_part(ltrim(coalesce(p_path, ''), '/'), '/', 1);
  if v_rel = '' then
    return false;
  end if;
  return exists (select 1 from pg_class c
                  where c.relnamespace = 'public'::regnamespace
                    and c.relname = v_rel
                    and c.relkind in ('v', 'm')
                    and not coalesce(c.reloptions @> array['security_invoker=true'], false));
end;
$$;
revoke execute on function public.store_review_request_blocked(text, text) from public, anon, authenticated;

-- PostgREST's pre-request hook: 0298's, with the store review seal first.
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
  v_blocked boolean := false;
begin
  -- The store review account (0333): demo data only. Fails closed.
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then
    v_claims := null;
  end;
  if v_claims is not null and v_claims ->> 'role' = 'authenticated'
     and (coalesce(v_claims -> 'app_metadata' ->> 'store_review', '') = 'true'
          or coalesce(v_claims ->> 'sub', '') = public.store_review_user_id()::text) then
    begin
      v_blocked := public.store_review_request_blocked(current_setting('request.path', true),
                                                       current_setting('request.method', true));
    exception when others then
      v_blocked := true;
    end;
    if v_blocked then
      raise sqlstate 'PT403' using
        message = 'STORE_REVIEW_DEMO',
        detail = 'The store review account runs on demo data only.';
    end if;
  end if;

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

-- ---- 5b. Reads: only rows that name the demo account -----------------------------------------------
-- The person columns of a table: a foreign key to profiles or auth.users,
-- or a uuid column with one of these names; "*_by" (who set it) is not one.
create or replace function public.store_review_person_columns(p_table regclass)
returns text[]
language sql
stable
set search_path = public
as $$
  select coalesce(array_agg(distinct a.attname::text order by a.attname::text), '{}')
    from pg_attribute a
   where a.attrelid = p_table
     and a.attnum > 0
     and not a.attisdropped
     and a.atttypid = 'uuid'::regtype
     and a.attname !~ '_by$'
     and (a.attname in ('user_id', 'rider_id', 'driver_id', 'partner_id', 'profile_id', 'sender_id',
                        'recipient_id', 'passenger_id', 'owner_id', 'caller_id', 'callee_id', 'host_id',
                        'member_id', 'booker_id', 'auth_user_id', 'partner_user_id')
          or exists (select 1 from pg_constraint c
                      where c.conrelid = p_table
                        and c.contype = 'f'
                        and c.conkey = array[a.attnum]
                        and c.confrelid in ('public.profiles'::regclass, 'auth.users'::regclass)));
$$;
revoke execute on function public.store_review_person_columns(regclass) from public, anon, authenticated;

do $reads$
declare
  t record;
  v_cols text[];
  v_expr text;
begin
  for t in
    select c.oid::regclass as rel, c.relname
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and c.relkind in ('r', 'p')
       and c.relrowsecurity
     order by c.relname
  loop
    execute format('drop policy if exists "store review sealed read" on %s', t.rel);
    v_cols := public.store_review_person_columns(t.rel);
    if t.relname = 'profiles' then
      v_cols := array['id'];
    end if;
    if cardinality(v_cols) = 0 then
      continue;
    end if;
    select string_agg(format('%I = (select auth.uid())', col), ' or ') into v_expr from unnest(v_cols) col;
    execute format(
      'create policy "store review sealed read" on %s as restrictive for select to authenticated '
      'using ((select public.store_review_caller()) is not true or %s)', t.rel, v_expr);
  end loop;
end
$reads$;

-- ---- 5c. Writes, in depth ---------------------------------------------------------------------------
-- A row made by the demo account, or naming it in a person column
-- (TG_ARGV), is refused.
create or replace function public.store_review_seal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_val text;
  i int;
begin
  if public.store_review_caller() then
    raise exception 'STORE_REVIEW_DEMO: The store review account runs on demo data only.' using errcode = '42501';
  end if;
  if tg_nargs > 0 then
    v_row := to_jsonb(new);
    for i in 0 .. tg_nargs - 1 loop
      v_val := v_row ->> tg_argv[i];
      if v_val is not null and v_val ~ '^[0-9a-fA-F-]{36}$' and public.is_store_review(v_val::uuid) then
        raise exception 'STORE_REVIEW_DEMO: The store review account runs on demo data only.' using errcode = '42501';
      end if;
    end loop;
  end if;
  return new;
end;
$$;
revoke execute on function public.store_review_seal() from public, anon, authenticated;

do $writes$
declare
  v_tables text[] := array[
    -- bookings and trips, every module
    'ride_requests', 'rides', 'scheduled_rides', 'scheduled_ride_offers', 'scheduled_ride_interests',
    'c2c_bookings', 'c2c_trips', 'c2c_offers', 'c2c_payments', 'hire_bookings', 'hire_holds',
    'mygig_bookings', 'mygig_deliveries', 'mygig_offers', 'mygig_reassigns', 'mygig_passes',
    'ev_orders', 'business_trips', 'meter_trips', 'airport_queue', 'airport_ride_offers', 'trip_handovers',
    'family_trips',
    -- offers, chat, calls, support, safety
    'ride_offers', 'ride_messages', 'ride_calls', 'ride_call_signals', 'ride_ratings', 'rider_ratings',
    'ride_tips', 'ride_lost_items', 'support_tickets', 'support_messages', 'support_calls',
    'support_call_signals', 'safety_incidents', 'emergency_contacts', 'sms_outbox',
    -- money
    'wallets', 'wallet_transactions', 'wallet_transfer_requests', 'wallet_request_keys', 'payment_intents',
    'plus_memberships', 'plus_charges', 'partner_payout_accounts', 'promo_redemptions', 'referrals',
    'cover_claims', 'rider_fee_dues',
    -- partners
    'partners', 'partner_documents', 'vehicles', 'vehicle_documents', 'vehicle_user_assignment',
    'driver_presence', 'identity_checks', 'partner_online_checks', 'dispatch_stand_people',
    'dispatch_fleet_owners', 'dispatch_group_members', 'business_members', 'business_accounts',
    -- people
    'families', 'family_members', 'favourite_drivers', 'rider_blocks', 'personal_qr_codes',
    'phone_change_requests', 'admin_access', 'test_accounts'];
  v_name text;
  v_rel regclass;
  v_cols text[];
begin
  foreach v_name in array v_tables loop
    v_rel := to_regclass('public.' || v_name);
    if v_rel is null then
      continue;
    end if;
    v_cols := public.store_review_person_columns(v_rel);
    execute format('drop trigger if exists %I on %s', '0_store_review_seal', v_rel);
    execute format('create trigger %I before insert on %s for each row execute function public.store_review_seal(%s)',
                   '0_store_review_seal', v_rel,
                   coalesce((select string_agg(quote_literal(c), ', ') from unnest(v_cols) c), ''));
  end loop;
end
$writes$;

-- ---- 5d. The account itself -----------------------------------------------------------------------
create or replace function public.store_review_profile_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claims text := nullif(current_setting('request.jwt.claims', true), '');
begin
  -- The flag is the database's: no app, admin or service key sets it.
  if new.store_review is distinct from old.store_review and v_claims is not null then
    raise exception 'STORE_REVIEW_FLAG: Only the database sets the store review flag.' using errcode = '42501';
  end if;
  if old.store_review and (new.phone is distinct from old.phone
                           or (new.deleted_at is not null and old.deleted_at is null)) then
    raise exception 'STORE_REVIEW_DEMO: The store review account runs on demo data only.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.store_review_profile_guard() from public, anon, authenticated;
drop trigger if exists trg_profiles_0_store_review on public.profiles;
create trigger trg_profiles_0_store_review
  before update on public.profiles
  for each row execute function public.store_review_profile_guard();

create or replace function public.store_review_auth_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_store_review(old.id)
     and (new.phone is distinct from old.phone
          or new.email is distinct from old.email
          or coalesce(new.phone_change, '') not in ('', coalesce(old.phone_change, ''))
          or coalesce(new.email_change, '') not in ('', coalesce(old.email_change, ''))) then
    raise exception 'STORE_REVIEW_DEMO: The store review account runs on demo data only.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.store_review_auth_guard() from public, anon, authenticated;
do $auth$
begin
  drop trigger if exists on_auth_user_store_review on auth.users;
  create trigger on_auth_user_store_review
    before update of phone, email, phone_change, email_change on auth.users
    for each row execute function public.store_review_auth_guard();
exception when insufficient_privilege then
  -- The profile guard above still holds the phone (sync_profile_phone).
  raise notice 'store review: no trigger on auth.users (%)', sqlerrm;
end
$auth$;

-- ---- 5e. Storage: nothing uploaded, replaced or deleted -------------------------------------------
do $storage$
begin
  drop policy if exists "store review no upload" on storage.objects;
  create policy "store review no upload" on storage.objects as restrictive for insert to authenticated
    with check ((select public.store_review_caller()) is not true);
  drop policy if exists "store review no update" on storage.objects;
  create policy "store review no update" on storage.objects as restrictive for update to authenticated
    using ((select public.store_review_caller()) is not true);
  drop policy if exists "store review no delete" on storage.objects;
  create policy "store review no delete" on storage.objects as restrictive for delete to authenticated
    using ((select public.store_review_caller()) is not true);
exception when insufficient_privilege or undefined_table then
  raise notice 'store review: storage policies not set (%)', sqlerrm;
end
$storage$;

-- ---- 6. News and offers ------------------------------------------------------------------------------
alter table public.profiles add column if not exists news_offers boolean not null default false;

-- The signed-in account's own switch; the new value.
create or replace function public.set_news_offers(p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  update public.profiles set news_offers = coalesce(p_on, false) where id = v_uid and news_offers is distinct from coalesce(p_on, false);
  return coalesce(p_on, false);
end;
$$;
revoke execute on function public.set_news_offers(boolean) from public, anon;
grant execute on function public.set_news_offers(boolean) to authenticated;

-- The accounts a News and offers broadcast reaches (send-push): opted in,
-- not deleted, and never the store review account.
drop function if exists public.news_offers_off_ids();
create or replace function public.news_offers_on_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id from public.profiles p
   where p.news_offers and p.deleted_at is null and not p.store_review;
$$;
revoke execute on function public.news_offers_on_ids() from public, anon, authenticated;
grant execute on function public.news_offers_on_ids() to service_role;

-- ---- 7. Passenger location check-ins when the app is closed ---------------------------------------
alter table public.profiles add column if not exists location_checkins boolean not null default false;

insert into public.app_settings (key, value) values ('location_checkins', '{"passengers": false}')
on conflict (key) do nothing;
insert into public.admin_table_pages (target, page) values
  ('rpc:set_location_checkins_config', 'admin-settings-site')
on conflict do nothing;

create or replace function public.location_checkins_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('passengers',
    coalesce((select (value ->> 'passengers')::boolean from public.app_settings where key = 'location_checkins'), false));
$$;
revoke execute on function public.location_checkins_config() from public;
grant execute on function public.location_checkins_config() to anon, authenticated;

create or replace function public.set_location_checkins_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:set_location_checkins_config') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change passenger location check-ins.';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('location_checkins', jsonb_build_object('passengers', coalesce((p_config ->> 'passengers')::boolean, false)), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.location_checkins_config();
end;
$$;
revoke execute on function public.set_location_checkins_config(jsonb) from public, anon;
grant execute on function public.set_location_checkins_config(jsonb) to authenticated;

-- The passenger's own opt-in; the new value.
create or replace function public.set_location_checkins(p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  update public.profiles set location_checkins = coalesce(p_on, false)
   where id = v_uid and location_checkins is distinct from coalesce(p_on, false);
  return coalesce(p_on, false);
end;
$$;
revoke execute on function public.set_location_checkins(boolean) from public, anon;
grant execute on function public.set_location_checkins(boolean) to authenticated;

-- Whether a closed-app report for [p_profile] is kept: a partner (drivers
-- as before), or a passenger with the switch on who opted in.
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
        and exists (select 1 from public.profiles p where p.id = p_profile and p.location_checkins)));
$$;
revoke execute on function public.background_checkin_allowed(uuid) from public, anon, authenticated;

-- 0278's, keeping a report only where background_checkin_allowed says so.
create or replace function public.push_background_location(
  p_key text,
  p_lat double precision,
  p_lng double precision
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  n int := 0;
  r record;
begin
  if p_key is null or length(p_key) not between 32 and 128
     or p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return 0;
  end if;
  v_hash := encode(extensions.digest(convert_to(p_key, 'UTF8'), 'sha256'), 'hex');
  for r in
    update public.push_tokens t
       set last_lat = p_lat,
           last_lng = p_lng,
           located_at = now(),
           located_bg = true
      from public.push_tokens o
     where o.id = t.id
       and t.bg_key_hash = v_hash
       and t.location_always
       and t.profile_id is not null
       -- 0333: drivers, or passengers who opted in while the switch is on.
       and public.background_checkin_allowed(t.profile_id)
       -- The open app's own check-in wins for 3 minutes; one background
       -- report a minute at most.
       and (t.located_at is null
            or t.located_at < now() - case when t.located_bg then interval '60 seconds' else interval '3 minutes' end)
    returning t.id, t.profile_id, o.last_lat as prev_lat, o.last_lng as prev_lng
  loop
    n := n + 1;
    perform public.push_area_refresh(r.id, r.prev_lat, r.prev_lng);
    insert into public.user_location_history (user_id, latitude, longitude, captured_at)
    values (r.profile_id, p_lat, p_lng, now());
  end loop;
  return n;
end;
$$;
revoke execute on function public.push_background_location(text, double precision, double precision) from public;
grant execute on function public.push_background_location(text, double precision, double precision)
  to anon, authenticated;

notify pgrst, 'reload schema';
