-- ============================================================================
-- 0223 — Sub-admin page grants reach the database, and the October review's
-- remaining findings
--
-- 1. A sub-admin writes only what their pages edit. caller_is_admin() (0097)
--    is true for any admin_access row, whatever its page or level, and it
--    gated the admin half of every write policy and a set of admin RPCs: a
--    sub-admin with READ on one page could write app settings, routes, other
--    people's rows and top up wallets. Now:
--      * public.admin_table_pages maps each table, storage bucket
--        ('storage:<bucket>') and RPC ('rpc:<name>') to the admin pages whose
--        EDIT grant writes it. Unmapped means full admins only (page '*').
--      * public.caller_admin_can_write(target) answers for the caller: true
--        for direct database sessions and the service role, for full admins,
--        and for an EDIT grant on a mapped page. Edit on 'admin-settings'
--        covers every 'admin-settings-*' page, as the panel does.
--      * Every INSERT / UPDATE / DELETE / ALL policy in public and on
--        storage.objects that called caller_is_admin() now calls it with the
--        table (or bucket) instead. An ALL policy is split: its read keeps
--        caller_is_admin() (any admin still reads), its writes are scoped.
--        Only that term changes: the owner's own paths are kept as they are.
--      * The listed admin RPCs ask the same way ('rpc:<name>'); wallet top-up,
--        the gateway heartbeat, sign-in / PIN / device-guard settings and
--        signing a user out everywhere are full admins' only.
-- 2. set_login_pin: an account that already has a PIN changes it only with
--    the current PIN, or within ten minutes of an SMS sign-in.
-- 3. A driver can't make a rider's cancellation request: who asked
--    (cancel_requested_by) is set by the server from who the caller is.
-- 4. ride_requests: tolls and other charges are real amounts; the lifecycle
--    times are stamped by the server on the status change; rider_rating is
--    the server's.
-- 5. ev_orders: the back office's keys (payments received, the checklist,
--    the advisor, the status) change only through the back office, except
--    what the customer's own steps write (linking a DA by code, accepting
--    delivery).
-- 6. Launch telemetry: signed-in rows are the caller's own; anonymous ones are
--    rate-limited per address; a device's "emulator" flag counts only from
--    the account's own rows.
-- 7. SOS and referral codes are rate-limited.
-- 8. settings_entries 'sub-admin' rows (admin names and emails) are for
--    admins only.
-- 12. meter_trip_record refuses a total below the fare and its extras.
-- 13. support_messages: who sent it (role, id, name) is the server's.
-- 14. voice_protection_recordings: the owner's phone answers an upload request
--     with a file in its own folder, and nothing else.
-- 15. A ride that was taken keeps its driver: from the apps partner_id is
--     cleared only while the request is open.
-- ============================================================================

-- ---- 1. Which admin pages write what ---------------------------------------------------------------
create table if not exists public.admin_table_pages (
  target text not null,
  page   text not null,
  primary key (target, page)
);
comment on table public.admin_table_pages is
  'Which admin pages (admin_access.page) may write a table, a storage bucket (storage:<bucket>) or call an admin RPC (rpc:<name>) with an EDIT grant. Unlisted: full admins only (page *). See caller_admin_can_write().';

alter table public.admin_table_pages enable row level security;
revoke all on public.admin_table_pages from anon;
revoke insert, update, delete, truncate on public.admin_table_pages from authenticated;
grant select on public.admin_table_pages to authenticated;
drop policy if exists "admin_table_pages admin read" on public.admin_table_pages;
create policy "admin_table_pages admin read" on public.admin_table_pages
  for select to authenticated using ((select public.caller_is_admin()));

create or replace function public.caller_admin_can_write(p_target text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (migrations, psql, cron)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  v_uid := auth.uid();
  if v_uid is null then
    return false;
  end if;
  return exists (
    select 1
      from public.admin_access a
     where a.profile_id = v_uid
       and a.access_level = 'edit'
       and (a.page = '*'
            or exists (select 1 from public.admin_table_pages m
                        where m.target = p_target and m.page = a.page)
            -- The Settings hub grant edits every settings page (pageAccessProvider).
            or (a.page = 'admin-settings'
                and exists (select 1 from public.admin_table_pages m
                             where m.target = p_target and m.page like 'admin-settings-%')))
  );
end;
$$;
revoke execute on function public.caller_admin_can_write(text) from public;
grant execute on function public.caller_admin_can_write(text) to anon, authenticated, service_role;

do $pages$
declare
  users     text[] := array['admin-users', 'admin-user-edit', 'admin-user-add', 'admin-users-all',
                            'admin-users-approved', 'admin-users-blocked', 'admin-users-deleted',
                            'admin-users-rejected', 'admin-users-unapproved', 'admin-users-unapproved-docs'];
  partners  text[] := array['admin-partners', 'admin-partner-edit', 'admin-partner-add', 'admin-partners-all',
                            'admin-partners-approved', 'admin-partners-blocked', 'admin-partners-rejected',
                            'admin-partners-unapproved', 'admin-partners-unapproved-docs',
                            'admin-partners-permit-pending', 'admin-partners-permit-non-verified',
                            'admin-partners-permit-verified'];
  vehicles  text[] := array['admin-vehicles', 'admin-vehicle-edit', 'admin-vehicle-add', 'admin-vehicles-all',
                            'admin-vehicles-approved', 'admin-vehicles-blocked', 'admin-vehicles-rejected',
                            'admin-vehicles-unapproved', 'admin-vehicles-unapproved-docs',
                            'admin-vehicles-permit-pending', 'admin-vehicles-permit-non-verified',
                            'admin-vehicles-permit-verified'];
  documents text[] := array['admin-documents', 'admin-documents-partners', 'admin-documents-users',
                            'admin-documents-vehicles'];
  rides     text[] := array['admin-rides', 'admin-trace-fraud'];
  support   text[] := array['admin-support', 'admin-support-pool', 'admin-support-chat'];
  site      text[] := array['admin-settings-site', 'admin-settings-app-icon', 'admin-settings-splash'];
  messaging text[] := array['admin-settings-messaging'];
  fare_ai   text[] := array['admin-settings-fare-ai', 'admin-settings-fare-ai-logs'];
  api_keys  text[] := array['admin-settings-api-keys', 'admin-settings-api-keys-services',
                            'admin-settings-api-keys-keys', 'admin-settings-api-elife'];
  geo       text[] := array['admin-settings-country-states-cities', 'admin-settings-airport-areas',
                            'admin-settings-multi-gate-places', 'admin-settings-multi-gate-place-gates'];
  catalogue text[] := array['admin-settings-service', 'admin-settings-vehicle-services',
                            'admin-settings-partner-type', 'admin-settings-document-type',
                            'admin-settings-required-documents', 'admin-settings-vehicle-make-model',
                            'admin-settings-assign-service', 'admin-settings-assign-service-page'];
  sessions  text[] := array['admin-session-history', 'admin-trace-fraud'];
  push      text[] := array['admin-settings-push-notification'];
  -- Pages that keep rows in settings_entries (admin_categories.g.dart and the
  -- dedicated editors that own a category).
  entries   text[] := array['admin-settings-advertisement-banners', 'admin-settings-app-version',
                            'admin-settings-ev-delivery-advisors', 'admin-settings-ev-delivery-checklist',
                            'admin-settings-email-templates', 'admin-settings-fixed-price',
                            'admin-settings-free-ride', 'admin-settings-geo-fencing',
                            'admin-settings-insurance-providers', 'admin-settings-insurance-types',
                            'admin-settings-leaderboard', 'admin-settings-page-list',
                            'admin-settings-driver-incentive', 'admin-settings-insurance-durations',
                            'admin-settings-insurance-premium', 'admin-settings-promocode',
                            'admin-settings-referral', 'admin-settings-referral-tree', 'admin-settings-rides',
                            'admin-settings-search-radius', 'admin-settings-social-links',
                            'admin-settings-subscription-plan', 'admin-settings-world-currency',
                            'admin-settings-payment-type', 'admin-settings-payment-gateway',
                            'admin-settings-display', 'admin-settings-always-on', 'admin-settings-mock'];
begin
  insert into public.admin_table_pages (target, page)
  select m.target, u.page
    from (values
      -- People
      ('profiles',                users || partners || documents),
      ('partners',                partners || documents),
      ('provider_documents',      partners || documents),
      ('vehicle',                 vehicles || partners || documents),
      ('vehicles',                vehicles || partners || documents),
      ('vehicle_documents',       vehicles || partners || documents),
      ('vehicle_user_assignment', vehicles || partners),
      ('vehicle_active_session',  vehicles || partners),
      ('emergency_contacts',      users),
      ('push_tokens',             users),
      ('favourite_drivers',       users),
      ('personal_qr_codes',       users || partners),
      -- Rides, support, sessions
      ('ride_requests',               rides),
      ('ride_messages',               rides || support),
      ('scheduled_rides',             rides),
      ('voice_protection_recordings', support || rides),
      ('support_tickets',             support),
      ('support_messages',            support),
      ('support_calls',               support),
      ('user_sessions',               sessions),
      ('user_location_history',       sessions),
      -- Messaging
      ('messaging_devices',     messaging),
      ('messaging_routes',      messaging),
      ('sms_settings',          messaging),
      ('sms_fallback_settings', messaging),
      ('sms_outbox',            messaging || support || push),
      ('push_notifications',    push),
      -- Settings pages
      ('settings_entries',       entries || catalogue || geo || site || push),
      ('app_settings',           site || api_keys || fare_ai
                                   || array['admin-settings-page-styles', 'admin-settings-maps']),
      ('app_branding',           site),
      ('admin_display_settings', array['admin-settings-display']),
      ('fare_ai_responses',      fare_ai),
      ('fare_tariffs',           array['admin-settings-fare-tariffs']),
      ('ip_access_rules',        array['admin-settings-ip-access']),
      ('meter_digital_settings', array['admin-settings-meter-digital']),
      ('help_articles',          array['admin-settings-help-articles']),
      ('help_questions',         array['admin-settings-help-articles']),
      ('countries',              array['admin-settings-country-states-cities']),
      ('states',                 array['admin-settings-country-states-cities']),
      ('cities',                 array['admin-settings-country-states-cities']),
      ('suburbs',                array['admin-settings-country-states-cities']),
      ('airport_areas',          array['admin-settings-airport-areas', 'admin-settings-multi-gate-place-gates']),
      ('multi_gate',             array['admin-settings-multi-gate-places', 'admin-settings-multi-gate-place-gates',
                                       'admin-settings-airport-areas']),
      ('document_type',          array['admin-settings-document-type', 'admin-settings-required-documents']),
      ('required_document',      array['admin-settings-required-documents', 'admin-settings-document-type']),
      ('vehicle_make_models',    array['admin-settings-vehicle-make-model']),
      ('driver_incentive',       array['admin-settings-driver-incentive']),
      ('insurance_providers',    array['admin-settings-insurance-providers']),
      ('insurance_types',        array['admin-settings-insurance-types']),
      ('insurance_durations',    array['admin-settings-insurance-durations']),
      ('insurance_premium',      array['admin-settings-insurance-premium']),
      ('get_coin_settings',      array['admin-settings-get-coin']),
      ('get_coin_rate_history',  array['admin-settings-get-coin']),
      ('ev_orders',              array['admin-orders']),
      ('ev_profiles',            array['admin-settings-ev-profiles']),
      ('obd_captures',           array['admin-settings-ev-profiles']),
      ('ev_delivery_advisors',   array['admin-settings-ev-delivery-advisors']),
      ('ev_finance_options',     array['admin-settings-ev-finance-options']),
      ('ev_order_fee',           array['admin-settings-ev-order-fee']),
      ('ev_vehicle_details',     array['admin-settings-ev-vehicle-details']),
      ('ev_vehicle_inventory',   array['admin-settings-ev-vehicle-inventory']),
      -- Storage buckets
      ('storage:avatars',            users || partners),
      ('storage:ID_Image',           users || partners || documents),
      ('storage:provider-documents', partners || documents),
      ('storage:vehicle-documents',  vehicles || partners || documents),
      ('storage:support-media',      support),
      ('storage:ride-chat-media',    rides),
      ('storage:voice-protection',   support || rides),
      ('storage:app-branding',       site || array['admin-settings-partner-statements']),
      ('storage:partner-type-icons', array['admin-settings-partner-type', 'admin-settings-vehicle-services',
                                           'admin-settings-service']),
      -- RPCs (wallet_topup, messaging_heartbeat, set_sign_in_config, set_pin_policy,
      -- admin_sign_out_everywhere and device_guard_set_config are left out: full admins only)
      ('rpc:claim_vehicle',                  vehicles || partners),
      ('rpc:release_vehicle',                vehicles || partners),
      ('rpc:touch_vehicle_session',          vehicles || partners),
      ('rpc:fare_ai_reset_cooldown',         fare_ai),
      ('rpc:set_map_config',                 array['admin-settings-maps']),
      ('rpc:set_permission_rules',           site),
      ('rpc:set_ride_cancel_request_config', site),
      ('rpc:set_ride_privacy_config',        site),
      ('rpc:set_scheduled_rides_config',     site),
      ('rpc:set_sos_ops_config',             site),
      ('rpc:set_trip_handover_config',       site),
      ('rpc:sos_acknowledge',                site || rides || support),
      ('rpc:sos_resolve',                    site || rides || support)
    ) as m(target, pages)
    cross join lateral unnest(m.pages) as u(page)
  on conflict do nothing;
end;
$pages$;

-- Every admin write policy asks about its own table. Only the
-- caller_is_admin() term changes; the rest of each expression, its roles and
-- whether it is permissive are kept. Runs again harmlessly: a policy already
-- rewritten no longer matches.
do $policies$
declare
  pol     record;
  v_target text;
  v_call  text;
  v_qual  text;
  v_check text;
  v_roles text;
  v_base  text;
begin
  for pol in
    select p.schemaname, p.tablename, p.policyname, p.permissive, p.roles, p.cmd, p.qual, p.with_check
      from pg_policies p
     where (p.schemaname = 'public' or (p.schemaname = 'storage' and p.tablename = 'objects'))
       and p.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
       and (coalesce(p.qual, '') like '%caller_is_admin()%'
            or coalesce(p.with_check, '') like '%caller_is_admin()%')
  loop
    if pol.schemaname = 'storage' then
      v_target := 'storage:' || coalesce(
        substring(coalesce(pol.qual, '') || ' ' || coalesce(pol.with_check, '') from 'bucket_id = ''([^'']+)'''),
        'objects');
    else
      v_target := pol.tablename;
    end if;
    v_call := format('(select public.caller_admin_can_write(%L))', v_target);
    v_qual := replace(replace(pol.qual, 'public.caller_is_admin()', v_call), 'caller_is_admin()', v_call);
    v_check := replace(replace(pol.with_check, 'public.caller_is_admin()', v_call), 'caller_is_admin()', v_call);

    if pol.cmd <> 'ALL' then
      execute format('alter policy %I on %I.%I%s%s', pol.policyname, pol.schemaname, pol.tablename,
                     case when pol.qual is not null then ' using (' || v_qual || ')' else '' end,
                     case when pol.with_check is not null then ' with check (' || v_check || ')' else '' end);
      continue;
    end if;

    -- FOR ALL: reading stays as it was, each write is scoped.
    select string_agg(quote_ident(r), ', ') into v_roles from unnest(pol.roles) r;
    v_base := left(pol.policyname, 54);
    execute format('drop policy %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
    if pol.qual is not null then
      execute format('drop policy if exists %I on %I.%I', v_base || ' read', pol.schemaname, pol.tablename);
      execute format('create policy %I on %I.%I as %s for select to %s using (%s)',
                     v_base || ' read', pol.schemaname, pol.tablename, pol.permissive, v_roles, pol.qual);
      execute format('drop policy if exists %I on %I.%I', v_base || ' update', pol.schemaname, pol.tablename);
      execute format('create policy %I on %I.%I as %s for update to %s using (%s) with check (%s)',
                     v_base || ' update', pol.schemaname, pol.tablename, pol.permissive, v_roles,
                     v_qual, coalesce(v_check, v_qual));
      execute format('drop policy if exists %I on %I.%I', v_base || ' delete', pol.schemaname, pol.tablename);
      execute format('create policy %I on %I.%I as %s for delete to %s using (%s)',
                     v_base || ' delete', pol.schemaname, pol.tablename, pol.permissive, v_roles, v_qual);
    end if;
    execute format('drop policy if exists %I on %I.%I', v_base || ' insert', pol.schemaname, pol.tablename);
    execute format('create policy %I on %I.%I as %s for insert to %s with check (%s)',
                   v_base || ' insert', pol.schemaname, pol.tablename, pol.permissive, v_roles,
                   coalesce(v_check, v_qual));
  end loop;
end;
$policies$;

-- The admin RPCs ask the same way, under 'rpc:<name>'. CREATE OR REPLACE from
-- each function's own definition keeps its owner, grants and settings.
do $rpcs$
declare
  f     record;
  v_def text;
  v_call text;
begin
  for f in
    select p.oid, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = any (array[
         'admin_sign_out_everywhere', 'claim_vehicle', 'device_guard_set_config', 'fare_ai_reset_cooldown',
         'messaging_heartbeat', 'release_vehicle', 'set_map_config', 'set_permission_rules', 'set_pin_policy',
         'set_ride_cancel_request_config', 'set_ride_privacy_config', 'set_scheduled_rides_config',
         'set_sign_in_config', 'set_sos_ops_config', 'set_trip_handover_config', 'sos_acknowledge',
         'sos_resolve', 'touch_vehicle_session', 'wallet_topup'])
  loop
    v_def := pg_get_functiondef(f.oid);
    if position('caller_is_admin()' in v_def) = 0 then
      continue;
    end if;
    v_call := format('public.caller_admin_can_write(%L)', 'rpc:' || f.proname);
    execute replace(replace(v_def, 'public.caller_is_admin()', v_call), 'caller_is_admin()', v_call);
  end loop;
end;
$rpcs$;

-- ---- 2. Changing a PIN takes proof ------------------------------------------------------------------
-- As 0097 (+ 0138's search_path), with p_current_pin: an account that has a
-- PIN changes it with that PIN, or within ten minutes of an SMS sign-in (the
-- forgot-PIN path). A wrong current PIN answers false rather than raising,
-- so the failed attempt pin_check counted is kept. The emulator check reads
-- only the account's own session rows (item 6).
drop function if exists public.set_login_pin(text, text);
create or replace function public.set_login_pin(p_pin text, p_device_id text default null,
                                                p_current_pin text default null)
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
begin
  if v_uid is null then
    raise exception 'set_login_pin requires an authenticated session';
  end if;
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN must be exactly 6 digits';
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
revoke all on function public.set_login_pin(text, text, text) from public, anon;
grant execute on function public.set_login_pin(text, text, text) to authenticated, service_role;

-- ---- 3 + 4 (+ batch 7). ride_requests columns a client can't decide ----------------------------
-- The least an early end may store (B7-3). The app prices an early end in
-- proportion to the distance driven, never below the flag fall of the tariff
-- card the ride was priced on (lib/src/core/early_end.dart); the server can't
-- measure the distance, and the card also depends on the service and its
-- multiplier, which the row doesn't carry. So the floor is the safest one the
-- server can know without refusing an honest early end: half of the cheapest
-- zero-distance fare (base fare + booking fee, or the card's minimum when
-- higher) of any active Admin → Fare tariffs card covering the pickup's area
-- (master, country, state, city, suburb), half of the built-in RM 4.00 flag
-- fall when no card covers it, and never above the booked fare. The half
-- leaves room for cheaper services (multiplier down to 0.5).
create or replace function public.ride_early_end_floor(p_ride public.ride_requests)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select least(
    round(coalesce(p_ride.ride_fare, p_ride.fare, 0), 2),
    round(0.5 * coalesce((
      select min(greatest(t.base_fare + t.booking_fee, t.minimum_fare))
        from public.fare_tariffs t
       where t.active
         and (t.level = 'master'
              or (lower(t.country) = lower(p_ride.country)
                  and (t.level = 'country'
                       or (lower(t.state) = lower(p_ride.state)
                           and (t.level = 'state'
                                or (lower(t.city) = lower(p_ride.city)
                                    and (t.level = 'city'
                                         or (t.level = 'suburb' and lower(t.suburb) = lower(p_ride.suburb)))))))))),
      4.00), 2));
$$;
revoke execute on function public.ride_early_end_floor(public.ride_requests) from public, anon;
grant execute on function public.ride_early_end_floor(public.ride_requests) to authenticated, service_role;

-- Runs first of the BEFORE triggers ("0_"). Clients only: the server's own
-- functions and admins who edit rides are unaffected.
--   * toll_charges / other_charges: real, non-negative amounts;
--   * accepted_at .. cancelled_at: now(), on the status change they belong
--     to (the app sends its own clock with the change; that value is
--     replaced); any other change to them is refused (B7-1);
--   * rider_rating: the server's (5 on a new request, kept after);
--   * cancel_requested_by: who the caller is on this ride, whenever a
--     cancellation is asked for (cancel_requested_at set), and when a
--     participant cancels outright; cleared with the request;
--   * where the ride goes (pickup, drop, stops, its area) is fixed once the
--     request is written: the app never edits it (B7-4);
--   * a completed ride's fare and charges are fixed (B7-3), and an early end
--     stores no less than ride_early_end_floor().
create or replace function public.ride_requests_guard_client_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_side text;
  v_floor numeric;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;

  if not (public.ride_money_ok(new.toll_charges) and public.ride_money_ok(new.other_charges)) then
    raise exception 'RIDE_CHARGES_INVALID' using errcode = '22023',
      hint = 'Tolls and other charges are amounts of zero or more.';
  end if;

  if tg_op = 'INSERT' then
    if num_nonnulls(new.accepted_at, new.arrived_at, new.started_at, new.completed_at, new.cancelled_at,
                    new.cancel_requested_at, new.cancel_requested_by) > 0 then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501',
        hint = 'A new request carries no trip times.';
    end if;
    new.rider_rating := 5;
  else
    -- Each time belongs to its own status change, and is the server's clock.
    if (new.accepted_at is distinct from old.accepted_at
          and not (new.status = 'accepted' and old.status is distinct from 'accepted'))
       or (new.arrived_at is distinct from old.arrived_at
          and not (new.status = 'arrived' and old.status is distinct from 'arrived'))
       or (new.started_at is distinct from old.started_at
          and not (new.status = 'on_trip' and old.status is distinct from 'on_trip'))
       or (new.completed_at is distinct from old.completed_at
          and not (new.status = 'completed' and old.status is distinct from 'completed'))
       or (new.cancelled_at is distinct from old.cancelled_at
          and not (new.status = 'cancelled' and old.status is distinct from 'cancelled')) then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501',
        hint = 'Trip times are recorded by the server.';
    end if;
    new.rider_rating := old.rider_rating;
    new.accepted_at := old.accepted_at;
    new.arrived_at := old.arrived_at;
    new.started_at := old.started_at;
    new.completed_at := old.completed_at;
    new.cancelled_at := old.cancelled_at;

    -- Where the ride goes is what was booked.
    if (new.pickup_lat, new.pickup_lng, new.pickup_name, new.pickup_address,
        new.drop_lat, new.drop_lng, new.drop_name, new.drop_address,
        new.country, new.state, new.city, new.suburb, new.stops)
       is distinct from
       (old.pickup_lat, old.pickup_lng, old.pickup_name, old.pickup_address,
        old.drop_lat, old.drop_lng, old.drop_name, old.drop_address,
        old.country, old.state, old.city, old.suburb, old.stops) then
      raise exception 'RIDE_ROUTE_LOCKED' using errcode = '42501',
        hint = 'The pickup and drop-off of a request can''t be changed. Cancel it and book again.';
    end if;

    -- A completed ride is a record.
    if old.status = 'completed'
       and (new.ride_fare, new.fare, new.toll_charges, new.other_charges, new.other_charges_note)
           is distinct from
           (old.ride_fare, old.fare, old.toll_charges, old.other_charges, old.other_charges_note) then
      raise exception 'RIDE_FARE_LOCKED' using errcode = '42501',
        hint = 'A completed trip''s fare and charges can''t be changed.';
    end if;

    -- Ending early: no lower than the floor.
    if old.status = 'on_trip' and new.status = 'completed'
       and new.ride_fare is not null
       and round(new.ride_fare, 2) < round(coalesce(old.ride_fare, old.fare, 0), 2) then
      v_floor := public.ride_early_end_floor(old);
      if round(new.ride_fare, 2) < v_floor then
        raise exception 'RIDE_FARE_TOO_LOW' using errcode = '42501',
          hint = format('An early end is charged at least %s.', to_char(v_floor, 'FM999999990.00'));
      end if;
    end if;

    v_side := case when v_uid is not null and v_uid = old.rider_id then 'rider'
                   when v_uid is not null and v_uid = old.partner_id then 'partner' end;
    if new.cancel_requested_at is distinct from old.cancel_requested_at then
      if new.cancel_requested_at is null then
        new.cancel_requested_by := null;
      else
        if v_side is null then
          raise exception 'RIDE_CANCEL_NOT_PARTICIPANT' using errcode = '42501';
        end if;
        new.cancel_requested_at := least(new.cancel_requested_at, now());
        new.cancel_requested_by := v_side;
      end if;
    elsif new.cancel_requested_by is distinct from old.cancel_requested_by then
      if new.status = 'cancelled' and old.status is distinct from 'cancelled'
         and old.cancel_requested_by is null and v_side is not null then
        new.cancel_requested_by := v_side;
      else
        raise exception 'RIDE_CANCEL_BY_SERVER_ONLY' using errcode = '42501',
          hint = 'Who asked to cancel is recorded by the server.';
      end if;
    end if;
  end if;

  if tg_op = 'INSERT' or new.status is distinct from old.status then
    case new.status
      when 'accepted'  then new.accepted_at := now();
      when 'arrived'   then new.arrived_at := now();
      when 'on_trip'   then new.started_at := now();
      when 'completed' then new.completed_at := now();
      when 'cancelled' then new.cancelled_at := now();
      else null;
    end case;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_client_columns() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_0_client_columns on public.ride_requests;
create trigger trg_ride_requests_0_client_columns
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_client_columns();

-- As 0106: after pickup a driver cancels only on the rider's own request,
-- which cancel_requested_by now records truthfully.
create or replace function public.ride_requests_guard_driver_cancel()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if new.status = 'cancelled'
     and old.status = 'on_trip'
     and old.partner_id is not distinct from auth.uid()
     and old.rider_id is distinct from auth.uid()
     and old.cancel_requested_by is distinct from 'rider' then
    raise exception 'RIDE_DRIVER_CANCEL_AFTER_PICKUP' using errcode = '42501',
      hint = 'The passenger is on board: complete the trip or end it early instead.';
  end if;
  return new;
end;
$$;

-- ---- 5. ev_orders: the back office's keys -----------------------------------------------------------
create or replace function public.ev_flag(p jsonb)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case jsonb_typeof(p)
           when 'boolean' then p::text::boolean
           when 'string' then lower(btrim(p #>> '{}')) in ('true', '1', 'yes')
           when 'number' then p::text = '1'
           else false
         end;
$$;

-- The customer writes their own steps into values (ownership, plate,
-- financing, delivery date ...). What the back office records stays the back
-- office's: sums received, the handover checklist, the price, the advisor and
-- the status. The customer's two steps that touch those are checked here:
--   * linking a delivery advisor by DA code (once, to an advisor that exists;
--     the advisor's details are copied from the catalogue, status 'assigned');
--   * accepting delivery once the advisor has submitted the checklist.
-- Anything else in those keys keeps its stored value.
create or replace function public.ev_orders_guard_back_office()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  o jsonb := case when tg_op = 'UPDATE' then coalesce(old.values, '{}'::jsonb) else '{}'::jsonb end;
  n jsonb := coalesce(new.values, '{}'::jsonb);
  k text;
  v_adv jsonb;
  v_adv_id text := nullif(btrim(coalesce(new.values ->> 'advisorId', '')), '');
  v_status text;
  office text[] := array[
    'status', 'payments',
    'depositPaid', 'depositStatus', 'depositReceivedAt', 'depositAmount', 'depositCurrency',
    'cashBalancePaid', 'balancePaidAmount', 'balanceReceivedAt',
    'leasingAddonPaid', 'leasingAddonReceivedAt',
    'checklistResults', 'checklistSubmitted', 'checklistSubmittedAt',
    'checklistAccepted', 'checklistAcceptedAt',
    'advisorId', 'advisorName', 'advisorContact', 'advisorEmail', 'advisorDealership', 'advisorDaNumber',
    'advisorCountry', 'advisorState', 'advisorCity', 'assignedAt',
    'basePrice', 'tax', 'accessoriesCost', 'total'];
  advisor_keys text[] := array[
    'advisorId', 'advisorName', 'advisorContact', 'advisorEmail', 'advisorDealership', 'advisorDaNumber',
    'advisorCountry', 'advisorState', 'advisorCity', 'assignedAt'];
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ev_orders') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- A new order: priced by the wizard, nothing received, no advisor, no checklist.
    n := n - array['payments', 'depositReceivedAt', 'cashBalancePaid', 'balancePaidAmount', 'balanceReceivedAt',
                   'leasingAddonPaid', 'leasingAddonReceivedAt', 'checklistResults', 'checklistSubmitted',
                   'checklistSubmittedAt', 'checklistAccepted', 'checklistAcceptedAt']
           - advisor_keys;
    new.values := n || jsonb_build_object('status', 'pending', 'depositPaid', false, 'depositStatus', 'due');
    return new;
  end if;

  v_status := lower(coalesce(o ->> 'status', 'pending'));

  -- Linking a delivery advisor by code: once, to an advisor in the catalogue.
  if v_adv_id is distinct from nullif(btrim(coalesce(o ->> 'advisorId', '')), '')
     and v_adv_id is not null
     and nullif(btrim(coalesce(o ->> 'advisorId', '')), '') is null
     and v_adv_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    select a.values into v_adv from public.ev_delivery_advisors a where a.id = v_adv_id::uuid;
  end if;

  -- Every back-office key keeps its stored value ...
  foreach k in array office loop
    if o ? k then
      n := jsonb_set(n, array[k], o -> k);
    else
      n := n - k;
    end if;
  end loop;

  -- ... but for the customer's own steps.
  if v_adv is not null then
    n := n || jsonb_build_object(
      'advisorId', v_adv_id,
      'advisorName', coalesce(v_adv ->> 'name', ''),
      'advisorContact', coalesce(v_adv ->> 'contact', ''),
      'advisorEmail', coalesce(v_adv ->> 'email', ''),
      'advisorDealership', coalesce(v_adv ->> 'dealership', ''),
      'advisorDaNumber', coalesce(v_adv ->> 'daNumber', v_adv_id),
      'advisorCountry', coalesce(v_adv ->> 'country', ''),
      'advisorState', coalesce(v_adv ->> 'state', ''),
      'advisorCity', coalesce(v_adv ->> 'city', ''),
      'assignedAt', to_jsonb(now()));
    if v_status in ('pending', '') then
      n := n || jsonb_build_object('status', 'assigned');
    end if;
  end if;

  if public.ev_flag(new.values -> 'checklistAccepted')
     and not public.ev_flag(o -> 'checklistAccepted')
     and public.ev_flag(o -> 'checklistSubmitted')
     and v_status not in ('cancelled', 'canceled') then
    n := n || jsonb_build_object('checklistAccepted', true, 'checklistAcceptedAt', to_jsonb(now()),
                                 'status', 'delivered');
  end if;

  new.values := n;
  return new;
end;
$$;
revoke execute on function public.ev_orders_guard_back_office() from public, anon, authenticated;

drop trigger if exists trg_ev_orders_guard_back_office on public.ev_orders;
create trigger trg_ev_orders_guard_back_office
  before insert or update on public.ev_orders
  for each row execute function public.ev_orders_guard_back_office();

-- ---- 6. Launch telemetry ----------------------------------------------------------------------------
-- A signed-in caller writes only their own rows; signed out, only rows that
-- name nobody (the launch before sign-in), and those are rate-limited per
-- address. Location rows are written only while signed in.
drop policy if exists "user_sessions own insert" on public.user_sessions;
create policy "user_sessions own insert" on public.user_sessions
  for insert to public with check (
    user_id = (select auth.uid())
    or (user_id is null and (select auth.uid()) is null)
    or (select public.caller_admin_can_write('user_sessions')));

drop policy if exists "user_location_history own insert" on public.user_location_history;
create policy "user_location_history own insert" on public.user_location_history
  for insert to public with check (
    user_id = (select auth.uid())
    or (select public.caller_admin_can_write('user_location_history')));

-- SECURITY DEFINER to reach the rate table, so the caller is told by the
-- request's claims: an API request with no user.
create or replace function public.telemetry_rate_anonymous()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wait integer;
begin
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and auth.uid() is null then
    v_wait := public.auth_rate_take('telemetry_anon', public.request_client_ip(), 120, interval '1 hour');
    if v_wait > 0 then
      raise exception 'RATE_LIMITED:%', v_wait;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.telemetry_rate_anonymous() from public, anon, authenticated;

drop trigger if exists trg_user_sessions_rate_anonymous on public.user_sessions;
create trigger trg_user_sessions_rate_anonymous
  before insert on public.user_sessions
  for each row execute function public.telemetry_rate_anonymous();
drop trigger if exists trg_user_location_history_rate_anonymous on public.user_location_history;
create trigger trg_user_location_history_rate_anonymous
  before insert on public.user_location_history
  for each row execute function public.telemetry_rate_anonymous();

-- As 0097, but a device counts as an emulator only by the account's own rows:
-- anyone can write a signed-out row naming any device id.
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
  if v_uid is not null then
    select coalesce(bool_or(is_physical_device is false), false) into v_emu
    from public.user_sessions
    where user_id = v_uid;
  end if;
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

-- ---- 7. Rate limits ---------------------------------------------------------------------------------
-- As 0193: three new alerts an hour per person. Pressing again within ten
-- minutes still updates the open alert and is never limited.
create or replace function public.sos_raise(p_ride uuid default null, p_lat double precision default null,
                                            p_lng double precision default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c jsonb := public.sos_ops_config();
  r public.ride_requests;
  p public.profiles;
  v_role text := 'user';
  v_id uuid;
  v_wait integer;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_ride is not null then
    select * into r from public.ride_requests where id = p_ride;
    if found and r.rider_id = v_uid then
      v_role := 'rider';
    elsif found and r.partner_id = v_uid then
      v_role := 'partner';
    else
      r := null;  -- not their ride: raised without it
    end if;
  end if;

  -- Pressed again within ten minutes: the same incident, with the new place.
  select id into v_id from public.safety_incidents
   where reporter_id = v_uid and status <> 'resolved' and created_at > now() - interval '10 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    perform public.sos_location(v_id, p_lat, p_lng);
    return v_id;
  end if;

  v_wait := public.auth_rate_take('sos', v_uid::text, 3, interval '1 hour');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;

  select * into p from public.profiles where id = v_uid;
  insert into public.safety_incidents (
    ride_id, reporter_id, reporter_role, reporter_name, reporter_phone, rider_id, partner_id, partner_name,
    plate, vehicle, pickup_name, drop_name, lat, lng, location_at, track_until)
  values (
    r.id, v_uid, v_role, coalesce(p.name, case when v_role = 'partner' then r.partner_name else r.rider_name end),
    coalesce(p.phone, case when v_role = 'partner' then r.partner_phone else r.rider_phone end),
    r.rider_id, r.partner_id, r.partner_name, r.partner_plate, r.partner_vehicle, r.pickup_name, r.drop_name,
    p_lat, p_lng, case when p_lat is not null then now() end,
    now() + make_interval(mins => (c->>'locationMinutes')::int))
  returning id into v_id;
  if p_lat is not null and p_lng is not null then
    insert into public.safety_incident_locations (incident_id, lat, lng) values (v_id, p_lat, p_lng);
  end if;
  perform public.sos_alert(v_id);
  return v_id;
end;
$$;

-- As 0174, ten tries an hour per account.
create or replace function public.apply_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_referrer uuid;
  v_created timestamptz;
  v_enabled boolean := true;
  v_referrer_coins numeric := 0;
  v_referred_coins numeric := 0;
  v_wait integer;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  v_wait := public.auth_rate_take('referral', v_user::text, 10, interval '1 hour');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  if length(v_code) < 4 then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  -- New accounts only: a referral is part of signing up.
  select created_at into v_created from public.profiles where id = v_user;
  if v_created is null or v_created < now() - interval '7 days' then
    return jsonb_build_object('ok', false, 'error', 'not_new_account');
  end if;

  select coalesce(referral_enabled, true),
         coalesce(referral_referrer_coins, 0),
         coalesce(referral_referred_coins, 0)
    into v_enabled, v_referrer_coins, v_referred_coins
    from public.get_coin_settings
   where id = 'master';

  if not coalesce(v_enabled, true) then
    return jsonb_build_object('ok', false, 'error', 'disabled');
  end if;

  -- Resolve the referrer: an explicit profiles.referral_code wins, else the
  -- deterministic account-id code the apps share (its first 8 characters).
  select id into v_referrer
    from public.profiles
   where upper(coalesce(referral_code, '')) = v_code
   limit 1;
  if v_referrer is null and length(v_code) = 8 then
    select id into v_referrer
      from public.profiles
     where upper(left(replace(id::text, '-', ''), 8)) = v_code
     limit 1;
  end if;

  if v_referrer is null then
    return jsonb_build_object('ok', false, 'error', 'code_not_found');
  end if;
  if v_referrer = v_user then
    return jsonb_build_object('ok', false, 'error', 'self_referral');
  end if;
  if exists (select 1 from public.referrals where referred_user_id = v_user) then
    return jsonb_build_object('ok', false, 'error', 'already_referred');
  end if;

  -- Bonuses are minted coins: only what the supply has room for. The
  -- referral itself is recorded either way, at what was actually given.
  v_referred_coins := public.coin_mint_room(v_referred_coins);
  if v_referred_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_user, 'get_coin', 'referral', v_referred_coins, 'referral', 'Welcome bonus — joined with a referral link');
  end if;
  v_referrer_coins := public.coin_mint_room(v_referrer_coins);
  if v_referrer_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_referrer, 'get_coin', 'referral', v_referrer_coins, 'referral', 'Referral bonus — a friend joined with your link');
  end if;

  insert into public.referrals
    (referrer_user_id, referred_user_id, code, referrer_coins, referred_coins)
  values
    (v_referrer, v_user, v_code, v_referrer_coins, v_referred_coins);

  return jsonb_build_object(
    'ok', true,
    'referrer_coins', v_referrer_coins,
    'referred_coins', v_referred_coins
  );
end;
$$;

-- ---- 8. Sub-admin directory rows are for admins ---------------------------------------------------
drop policy if exists "settings_entries sub-admin rows admins only" on public.settings_entries;
create policy "settings_entries sub-admin rows admins only" on public.settings_entries
  as restrictive for select to public
  using (category is distinct from 'sub-admin' or (select public.caller_is_admin()));

-- ---- 12. A meter total is at least the fare and its extras ---------------------------------------
-- As 0219, with that check (the app's total is fare + extra + airport +
-- card surcharge, each rounded; a few cents of rounding are allowed).
create or replace function public.meter_trip_record(p_trip jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_started timestamptz;
  v_ended timestamptz;
  t public.meter_trips;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'METER_TRIP_NOT_PARTNER' using errcode = '42501',
      hint = 'Only an approved partner can send meter trips.';
  end if;
  if jsonb_typeof(p_trip) <> 'object' or pg_column_size(p_trip) > 8000 then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip could not be read.';
  end if;
  begin
    v_id := (p_trip->>'id')::uuid;
    v_started := to_timestamp((p_trip->>'startedAt')::bigint / 1000.0);
    v_ended := to_timestamp((p_trip->>'endedAt')::bigint / 1000.0);
  exception when others then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip could not be read.';
  end;
  if v_id is null or v_ended < v_started or v_ended > now() + interval '1 day'
     or v_ended < now() - interval '90 days' or v_ended - v_started > interval '24 hours' then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip''s times are not possible.';
  end if;

  select * into t from public.meter_trips where id = v_id;
  if found then
    if t.partner_id <> v_uid then
      raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip could not be read.';
    end if;
    return jsonb_build_object('recorded', true, 'charged', t.commission_charged_at is not null,
                              'amount', coalesce(t.commission_amount, 0));
  end if;

  begin
    insert into public.meter_trips (
      id, partner_id, started_at, ended_at, distance_km, duration_s, waiting_s, rate_label, period, currency,
      fare, extra, airport_surcharge, card_surcharge, total, pax, luggage,
      pickup_lat, pickup_lng, pickup_place, dropoff_lat, dropoff_lng, dropoff_place, destination, plate)
    values (
      v_id, v_uid, v_started, v_ended,
      round(greatest(0, coalesce((p_trip->>'distanceM')::numeric, 0)) / 1000, 3),
      greatest(0, coalesce((p_trip->>'elapsedMs')::bigint, 0) / 1000)::int,
      greatest(0, coalesce((p_trip->>'waitingMs')::bigint, 0) / 1000)::int,
      left(nullif(btrim(p_trip->>'rateLabel'), ''), 80),
      left(nullif(btrim(p_trip->>'period'), ''), 20),
      left(coalesce(nullif(btrim(p_trip->>'currency'), ''), 'MYR'), 8),
      round((p_trip->>'fare')::numeric, 2),
      round(coalesce((p_trip->>'extra')::numeric, 0), 2),
      round(coalesce((p_trip->>'airportSurcharge')::numeric, 0), 2),
      round(coalesce((p_trip->>'cardSurcharge')::numeric, 0), 2),
      round((p_trip->>'total')::numeric, 2),
      (p_trip->>'pax')::int,
      (p_trip->>'luggage')::int,
      (p_trip->'pickup'->>'latitude')::double precision,
      (p_trip->'pickup'->>'longitude')::double precision,
      left(nullif(btrim(p_trip->'pickup'->>'place'), ''), 200),
      (p_trip->'dropoff'->>'latitude')::double precision,
      (p_trip->'dropoff'->>'longitude')::double precision,
      left(nullif(btrim(p_trip->'dropoff'->>'place'), ''), 200),
      left(nullif(btrim(p_trip->>'destination'), ''), 200),
      left(nullif(btrim(p_trip->>'plate'), ''), 20))
    returning * into t;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range
                 or not_null_violation then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip''s numbers are not possible.';
  end;

  -- Raised outside the handler above, so the row just written goes with it.
  if t.total + 0.05 < t.fare + t.extra + t.airport_surcharge + t.card_surcharge then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023',
      hint = 'That meter trip''s total is less than its fare.';
  end if;

  if (public.commission_config()->>'meterCommission')::boolean then
    -- A failed charge never loses the hire: it is kept with the reason.
    begin
      perform public.meter_trip_charge_commission(t.id);
    exception when others then
      update public.meter_trips set commission_error = left(sqlerrm, 500) where id = t.id;
    end;
    select * into t from public.meter_trips where id = t.id;
  end if;
  return jsonb_build_object('recorded', true, 'charged', t.commission_charged_at is not null,
                            'amount', coalesce(t.commission_amount, 0));
end;
$$;
revoke execute on function public.meter_trip_record(jsonb) from public, anon;
grant execute on function public.meter_trip_record(jsonb) to authenticated;

-- ---- 13. Who sent a support message -----------------------------------------------------------------
-- Clients only (the server's own messages, e.g. 0191's cancel ticket, keep
-- theirs). An admin who edits support answers as 'admin' on someone else's
-- ticket; everyone else, and anyone on their own ticket, as 'user'. The id
-- is the caller's and the name their profile's.
create or replace function public.support_messages_stamp_sender()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_name text;
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  select t.profile_id into v_owner from public.support_tickets t where t.id = new.ticket_id;
  new.sender_role := case
    when v_uid is not null and v_owner is distinct from v_uid
         and public.caller_admin_can_write('support_messages') then 'admin'
    else 'user' end;
  new.sender_id := v_uid;
  select nullif(btrim(p.name), '') into v_name from public.profiles p where p.id = v_uid;
  new.sender_name := coalesce(v_name,
    case when new.sender_role = 'admin' then left(nullif(btrim(new.sender_name), ''), 80) end);
  return new;
end;
$$;
revoke execute on function public.support_messages_stamp_sender() from public, anon, authenticated;

drop trigger if exists trg_support_messages_stamp_sender on public.support_messages;
create trigger trg_support_messages_stamp_sender
  before insert on public.support_messages
  for each row execute function public.support_messages_stamp_sender();

-- ---- 14. Trip recordings: the phone only answers an upload request ---------------------------------
-- The owner's phone may (a) mark a recording it no longer has as unavailable
-- and (b) answer an agent's upload request with the file it put in its own
-- folder of the voice-protection bucket (`<profile id>/<file>`). Requests,
-- times, the trip it belongs to and every other column are the support
-- agents' and the server's. A new row starts with no request and no upload.
create or replace function public.voice_protection_guard_owner()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated')
     or public.caller_admin_can_write('voice_protection_recordings') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.upload_requested := false;
    new.upload_requested_by := null;
    new.upload_requested_at := null;
    new.ticket_id := null;
    new.uploaded := false;
    new.uploaded_at := null;
    new.media_url := null;
    return new;
  end if;

  if (new.id, new.profile_id, new.ride_id, new.ride_label, new.recorded_at, new.duration_sec, new.expires_at,
      new.upload_requested, new.upload_requested_by, new.upload_requested_at, new.ticket_id, new.created_at)
     is distinct from
     (old.id, old.profile_id, old.ride_id, old.ride_label, old.recorded_at, old.duration_sec, old.expires_at,
      old.upload_requested, old.upload_requested_by, old.upload_requested_at, old.ticket_id, old.created_at) then
    raise exception 'VOICE_RECORDING_SERVER_ONLY' using errcode = '42501',
      hint = 'Only the upload itself is the phone''s to record.';
  end if;

  if (new.uploaded, new.uploaded_at, new.media_url) is distinct from (old.uploaded, old.uploaded_at, old.media_url) then
    if not (old.upload_requested and not old.uploaded and new.uploaded
            and old.profile_id = auth.uid()
            and new.media_url is not null
            and new.media_url ~ ('^' || old.profile_id::text || '/[A-Za-z0-9_.-]+$')
            and position('..' in new.media_url) = 0) then
      raise exception 'VOICE_RECORDING_UPLOAD_INVALID' using errcode = '42501',
        hint = 'An upload answers a request, with a file in the owner''s own folder.';
    end if;
    new.uploaded_at := now();
    new.unavailable := false;
  elsif new.unavailable is distinct from old.unavailable then
    if not (new.unavailable and not old.uploaded) then
      raise exception 'VOICE_RECORDING_SERVER_ONLY' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.voice_protection_guard_owner() from public, anon, authenticated;

drop trigger if exists trg_voice_protection_guard_owner on public.voice_protection_recordings;
create trigger trg_voice_protection_guard_owner
  before insert or update on public.voice_protection_recordings
  for each row execute function public.voice_protection_guard_owner();

-- ---- Batch 7: money flows ---------------------------------------------------------------------------

-- B7-1. A ride counts once towards each incentive rule. As 0201, but the
-- rides a payout counted are recorded, so a trip can't qualify again for the
-- same rule in a later week (completed_at is now the server's clock, too).
create table if not exists public.partner_incentive_rides (
  rule_id      uuid not null,
  request_id   uuid not null,
  profile_id   uuid not null,
  period_start date not null,
  counted_at   timestamptz not null default now(),
  primary key (rule_id, request_id)
);
alter table public.partner_incentive_rides enable row level security;
revoke all on public.partner_incentive_rides from anon, authenticated;
grant select on public.partner_incentive_rides to authenticated;
drop policy if exists "partner_incentive_rides read" on public.partner_incentive_rides;
create policy "partner_incentive_rides read" on public.partner_incentive_rides
  for select to authenticated
  using (profile_id = (select auth.uid()) or (select public.caller_is_admin()));

create or replace function public.partner_incentives_weekly()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  ws date := public.statement_week_start((now() at time zone 'Asia/Kuala_Lumpur')::date - 7);
  v_from timestamptz := ws::timestamp at time zone 'Asia/Kuala_Lumpur';
  v_to timestamptz := (ws + 7)::timestamp at time zone 'Asia/Kuala_Lumpur';
  rule record;
  d record;
  n integer := 0;
  v_reward numeric;
  v_min integer;
begin
  for rule in
    select id, values from public.driver_incentive
     where coalesce(active, true) and coalesce((values->>'active')::boolean, true)
  loop
    v_reward := case when coalesce(rule.values->>'reward', '') ~ '^\d+(\.\d+)?$' then (rule.values->>'reward')::numeric end;
    v_min := case when coalesce(rule.values->>'minRides', '') ~ '^\d+$' then (rule.values->>'minRides')::int end;
    continue when v_reward is null or v_reward <= 0 or v_min is null or v_min <= 0;
    for d in
      select q.partner_id as uid, array_agg(q.id) as rides
        from public.ride_requests q
       where q.status = 'completed' and q.partner_id is not null and q.completed_at >= v_from and q.completed_at < v_to
         and not exists (select 1 from public.partner_incentive_rides c
                          where c.rule_id = rule.id and c.request_id = q.id)
       group by q.partner_id having count(*) >= v_min
    loop
      begin
        insert into public.partner_incentives (profile_id, amount, label, rule_id, period_start)
        values (d.uid, round(v_reward, 2), left(coalesce(nullif(btrim(rule.values->>'name'), ''), 'Weekly incentive'), 120),
                rule.id, ws);
        insert into public.partner_incentive_rides (rule_id, request_id, profile_id, period_start)
        select rule.id, x, d.uid, ws from unnest(d.rides) as x;
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
        values (d.uid, 'get_credit', 'incentive', round(v_reward, 2),
                'Incentive: ' || coalesce(nullif(btrim(rule.values->>'name'), ''), 'Weekly incentive'));
        n := n + 1;
      exception when unique_violation then
        null;
      end;
    end loop;
  end loop;
  return n;
end;
$$;

-- B7-2. The rider cancelling a released scheduled ride's request directly
-- (or the driver approving the rider's own cancellation request) pays the
-- same late-cancel fee as scheduled_ride_cancel (0189). Fired only for client
-- statements (the trigger's WHEN), so scheduled_ride_cancel's own update,
-- which runs as the function's owner, is not charged twice.
create or replace function public.ride_requests_scheduled_rider_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c      jsonb := public.scheduled_rides_config();
  r      public.scheduled_rides;
  v_fee  numeric := 0;
  v_fee_status text := 'none';
begin
  if not (auth.uid() = old.rider_id or old.cancel_requested_by = 'rider') then
    return null;
  end if;
  select * into r from public.scheduled_rides
   where id = old.scheduled_ride_id and ride_id = old.id and status = 'released'
   for update;
  if not found then
    return null;
  end if;

  if now() > r.pickup_at - make_interval(mins => (c->>'freeCancelMinutes')::int)
     and (c->>'lateCancelFee')::numeric > 0 then
    v_fee := (c->>'lateCancelFee')::numeric;
    begin
      perform public.wallet_pay(r.rider_id, v_fee, 'Late cancellation: scheduled ride', 'cancellation_fee');
      v_fee_status := 'charged';
    exception when others then
      v_fee_status := 'due';
    end;
  end if;

  update public.scheduled_rides
     set status = 'cancelled', cancelled_at = now(), cancelled_by = 'rider',
         cancel_reason = left(coalesce(new.cancel_reason, 'Scheduled ride cancelled'), 200),
         cancel_fee = v_fee, cancel_fee_status = v_fee_status
   where id = r.id;
  return null;
end;
$$;
revoke execute on function public.ride_requests_scheduled_rider_cancel() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_scheduled_rider_cancel on public.ride_requests;
create trigger trg_ride_requests_scheduled_rider_cancel
  after update of status on public.ride_requests
  for each row
  when (old.scheduled_ride_id is not null and new.status = 'cancelled'
        and old.status in ('open', 'accepted', 'arrived')
        and current_user in ('anon', 'authenticated'))
  execute function public.ride_requests_scheduled_rider_cancel();

-- B7-6. Taking a trip by handover or a booking needs the same GET.credit as
-- taking a ride (0218's guard).
create or replace function public.driver_credit_assert(p_uid uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.commission_credit_ok(p_uid) then
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = case when public.commission_credit_floor() = 0
                  then 'Your GET.credit is below zero. Top up to take trips again.'
                  else 'Your GET.credit is below RM ' || to_char(public.commission_credit_floor(), 'FM999990.00')
                       || '. Top up to take trips again.' end;
  end if;
end;
$$;
revoke execute on function public.driver_credit_assert(uuid) from public, anon, authenticated;

-- B7-8. A coin reward or a coin payment is for the ride's own rider; a ride
-- with no rider is the server's (or a full admin's) to settle.
-- Both edits are made to each function's current definition (as in part 1).
do $money$
declare
  f      record;
  v_def  text;
  v_new  text;
  v_anchor text;
  v_with text;
begin
  for f in
    select p.oid, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('trip_handover_accept', 'scheduled_ride_accept', 'scheduled_ride_offer_respond',
                         'wallet_award_ride_coins', 'wallet_redeem_fare_coins')
  loop
    v_def := pg_get_functiondef(f.oid);
    if f.proname = 'trip_handover_accept' then
      v_anchor := 'if public.partner_busy(v_uid) then';
      v_with := 'perform public.driver_credit_assert(v_uid);' || chr(10) || '  ' || v_anchor;
      continue when position('driver_credit_assert' in v_def) > 0;
    elsif f.proname in ('scheduled_ride_accept', 'scheduled_ride_offer_respond') then
      v_anchor := 'if public.scheduled_partner_clash(v_uid, r.pickup_at, r.id) then';
      v_with := 'perform public.driver_credit_assert(v_uid);' || chr(10) || '  ' || v_anchor;
      continue when position('driver_credit_assert' in v_def) > 0;
    else
      v_anchor := 'if r.rider_id is not null and r.rider_id <> p_user then';
      v_with := format('if (r.rider_id is null and not public.caller_admin_can_write(%L))', 'rpc:' || f.proname)
                || ' or (r.rider_id is not null and r.rider_id <> p_user) then';
      continue when position('caller_admin_can_write' in v_def) > 0;
    end if;
    if position(v_anchor in v_def) = 0 then
      raise exception '0223: % no longer has "%"; update this migration', f.proname, v_anchor;
    end if;
    v_new := replace(v_def, v_anchor, v_with);
    execute v_new;
  end loop;
end;
$money$;

-- B7-8. Moving coins straight to someone is the server's: the app asks with
-- wallet_request_coin_transfer and the other side answers (0164, 0222).
do $transfer$
begin
  if to_regprocedure('public.wallet_transfer_coins(uuid, numeric, uuid, text, text)') is not null then
    revoke execute on function public.wallet_transfer_coins(uuid, numeric, uuid, text, text)
      from public, anon, authenticated;
    grant execute on function public.wallet_transfer_coins(uuid, numeric, uuid, text, text) to service_role;
  end if;
  if to_regprocedure('public.wallet_transfer_coins_once(uuid, uuid, numeric, uuid, text, text)') is not null then
    revoke execute on function public.wallet_transfer_coins_once(uuid, uuid, numeric, uuid, text, text)
      from public, anon, authenticated;
    grant execute on function public.wallet_transfer_coins_once(uuid, uuid, numeric, uuid, text, text) to service_role;
  end if;
end;
$transfer$;

-- ---- 15. The driver stays on a live ride ----------------------------------------------------------
-- From the apps a ride's driver is
-- cleared only while it is still open (a rider turning a bid down, a driver
-- taking theirs back); once taken, a rider could otherwise drop the driver
-- (and the fare and commission records with them) by writing partner_id
-- null. A driver cancelling a booked ride back to the pool is the server's
-- own step (ride_requests_scheduled_reopen, after this guard).
create or replace function public.ride_requests_guard_partner_claim()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.partner_id is not null or new.offered_fare is not null then
      raise exception 'RIDE_PARTNER_SERVER_ONLY' using errcode = '42501',
        hint = 'A new request is offered to drivers; it can''t name one.';
    end if;
    return new;
  end if;
  if new.partner_id is null and old.partner_id is not null and old.status is distinct from 'open' then
    raise exception 'RIDE_DRIVER_KEPT' using errcode = '42501',
      hint = 'A ride that was taken keeps its driver; cancel it instead.';
  end if;
  if new.partner_id is not null and new.partner_id is distinct from old.partner_id then
    if new.partner_id is distinct from auth.uid() then
      raise exception 'RIDE_CLAIM_SELF_ONLY' using errcode = '42501',
        hint = 'A driver takes or bids on a ride for themselves only.';
    end if;
    if not public.caller_is_approved_partner() then
      raise exception 'RIDE_CLAIM_REQUIRES_APPROVED_PARTNER' using errcode = '42501',
        hint = 'Only partners approved by an administrator can accept or bid on rides.';
    end if;
    if new.partner_id = coalesce(new.rider_id, old.rider_id) then
      raise exception 'RIDE_CLAIM_OWN_RIDE' using errcode = '42501',
        hint = 'You can''t take a ride you booked.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_partner_claim() from public, anon, authenticated;

notify pgrst, 'reload schema';
