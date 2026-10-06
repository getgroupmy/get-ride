-- ============================================================================
-- 0069: Security lockdown — close the always-true RLS policies
-- ----------------------------------------------------------------------------
-- The Supabase security advisor flagged ~130 policies of the form
-- `using (true)` / `with check (true)` granted `to public`. Because the anon
-- key ships inside the app, those policies let ANY caller — no account needed:
--
--   * grant themselves admin (`admin_access` public insert, from 0010),
--   * read every ride including both parties' live GPS positions, and
--     rewrite/cancel/delete anyone's ride (`ride_requests`),
--   * rewrite every admin-managed config table (fares, commission rates,
--     geo areas, branding, IP access rules, coin peg, …),
--   * read every user's sessions (public IP/ISP), location history, voice
--     recordings, emergency contacts, support threads and push tokens,
--   * overwrite or delete any object in the branding / partner-type-icon /
--     provider-document / vehicle-document / voice-protection buckets.
--
-- This migration follows the 0066 wallet-lockdown pattern:
--
--   * `caller_is_admin()` — true for direct DB sessions (psql, setup
--     scripts), the service role, and profiles holding an `admin_access`
--     row. Used as the privileged branch of every policy below.
--   * `admin_access` returns to the scoped 0009 policies. The 0010
--     bootstrap deadlock is solved with `admin_access_bootstrap()` instead:
--     the FIRST authenticated caller on an empty table becomes the '*'
--     admin; after that only sub-admin-page editors manage rows.
--   * `ride_requests` becomes participant-scoped (details on the policies
--     below).
--   * Admin-managed config tables keep public reads, writes become
--     admin-only.
--   * Personal/PII tables become owner-or-admin scoped.
--   * Push-token registration moves behind owner-scoped RPCs.
--   * The support-agent roster moves behind a SECURITY DEFINER RPC
--     (`support_agents()`) so `admin_access` no longer needs a public read.
--
-- Also fixes the remaining advisor findings:
--   * `online_driver_locations` view: SECURITY DEFINER → security_invoker.
--   * Trigger/cron functions get a pinned `search_path`.
--   * Storage: broad per-bucket SELECT policies (listing) are dropped, and
--     the anon/public write policies on managed buckets are replaced with
--     admin- or owner-scoped ones. Buckets stay `public`, so existing
--     `getPublicUrl()` rendering is unaffected.
--
-- Client impact (mirrors 0066): flows now REQUIRE an authenticated Supabase
-- session. Legacy local-PIN sessions can still read open requests but can no
-- longer write; the stores surface a sign-in prompt (see
-- `rideRequestsStore.ts`). Partners no longer receive realtime UPDATE events
-- for open requests claimed by someone else (the row leaves their SELECT
-- scope); the incoming-request card self-dismisses on its countdown and the
-- accept race stays safe via the `status = 'open'` claim guard.
--
-- Known accepted limitation: any authenticated user may still update a row
-- while it is `open` provided they stamp themselves as `partner_id` (that IS
-- the offer/claim flow — offers live on the request row). `rider_id` is made
-- immutable by trigger so an open request can never be re-owned. Moving
-- offers into an RPC can close the remaining gap later.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper: privileged-caller check.
-- ----------------------------------------------------------------------------
create or replace function public.caller_is_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (setup scripts, psql, triggers)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  if auth.uid() is null then
    return false;
  end if;
  if to_regclass('public.admin_access') is null then
    return false;
  end if;
  return exists (
    select 1 from public.admin_access where profile_id = auth.uid()
  );
end;
$$;

grant execute on function public.caller_is_admin() to anon, authenticated;

-- ============================================================================
-- Part 1 — admin_access: close the privilege-escalation hole (0010)
-- ============================================================================
do $admin_access$
begin
  if to_regclass('public.admin_access') is null then return; end if;

  drop policy if exists "admin_access public read"   on public.admin_access;
  drop policy if exists "admin_access public insert" on public.admin_access;
  drop policy if exists "admin_access public update" on public.admin_access;
  drop policy if exists "admin_access public delete" on public.admin_access;

  drop policy if exists "admin_access self read"          on public.admin_access;
  drop policy if exists "admin_access admin read"         on public.admin_access;
  drop policy if exists "admin_access admin write insert" on public.admin_access;
  drop policy if exists "admin_access admin write update" on public.admin_access;
  drop policy if exists "admin_access admin write delete" on public.admin_access;

  create policy "admin_access self read"
    on public.admin_access for select
    using (profile_id = auth.uid());

  -- Any admin can see the roster (the sub-admin screen lists all rows).
  create policy "admin_access admin read"
    on public.admin_access for select
    using (public.caller_is_admin());

  create policy "admin_access admin write insert"
    on public.admin_access for insert
    with check (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

  create policy "admin_access admin write update"
    on public.admin_access for update
    using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));

  create policy "admin_access admin write delete"
    on public.admin_access for delete
    using (public.admin_can_edit(auth.uid(), 'admin-settings-sub-admin'));
end;
$admin_access$;

-- First-run bootstrap: on an EMPTY admin_access table the first authenticated
-- caller becomes the wildcard admin. Once any row exists this is a no-op, so
-- it cannot be used for escalation. (Replaces 0010's public write policies.)
create or replace function public.admin_access_bootstrap()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;
  if exists (select 1 from public.admin_access) then
    return false;
  end if;
  insert into public.admin_access (profile_id, page, access_level, notes)
  values (auth.uid(), '*', 'edit', 'bootstrap: first admin');
  return true;
end;
$$;

grant execute on function public.admin_access_bootstrap() to anon, authenticated;

-- Support-agent roster for the in-app support flow. Regular users used to
-- read admin_access (+ joined profiles) directly; this returns only the
-- fields the support screen needs.
create or replace function public.support_agents()
returns table (profile_id uuid, name text, avatar_url text, priority integer)
language sql
stable
security definer
set search_path = public
as $$
  select aa.profile_id,
         coalesce(nullif(p.name, ''), nullif(p.phone, ''), 'Agent') as name,
         coalesce(nullif(p.avatar_url, ''), nullif(p.profile_image, '')) as avatar_url,
         min(aa.support) as priority
    from public.admin_access aa
    join public.profiles p on p.id = aa.profile_id
   group by aa.profile_id, p.name, p.phone, p.avatar_url, p.profile_image;
$$;

grant execute on function public.support_agents() to anon, authenticated;

-- ============================================================================
-- Part 2 — ride_requests: participant-scoped dispatch
-- ============================================================================
-- Write shapes these policies must keep working (see rideRequestsStore.ts):
--   * rider inserts an `open` request with rider_id = their own uid;
--   * partners claim/offer on OPEN rows, always stamping partner_id = self
--     in the same update (`acceptRideRequest` / `submitRideOffer`);
--   * the rider raises the fare on their own open row (clears partner_id);
--   * both participants progress/cancel their own row and publish live GPS;
--   * the rider expires their own stale open rows.
do $ride_requests$
begin
  if to_regclass('public.ride_requests') is null then return; end if;

  drop policy if exists "ride_requests read"   on public.ride_requests;
  drop policy if exists "ride_requests insert" on public.ride_requests;
  drop policy if exists "ride_requests update" on public.ride_requests;
  drop policy if exists "ride_requests delete" on public.ride_requests;
  drop policy if exists "ride_requests rider insert"       on public.ride_requests;
  drop policy if exists "ride_requests participant update" on public.ride_requests;
  drop policy if exists "ride_requests claim open"         on public.ride_requests;
  drop policy if exists "ride_requests admin delete"       on public.ride_requests;

  -- Open requests stay visible to everyone (the partner queue, including
  -- legacy anon sessions, needs them). Active/finished rides — which carry
  -- both parties' phone numbers and live GPS — are participant/admin only.
  create policy "ride_requests read"
    on public.ride_requests for select
    using (
      status = 'open'
      or rider_id = auth.uid()
      or partner_id = auth.uid()
      or public.caller_is_admin()
    );

  create policy "ride_requests rider insert"
    on public.ride_requests for insert to public
    with check (
      (auth.uid() is not null and rider_id = auth.uid())
      or public.caller_is_admin()
    );

  create policy "ride_requests participant update"
    on public.ride_requests for update to public
    using (
      rider_id = auth.uid()
      or partner_id = auth.uid()
      or public.caller_is_admin()
    )
    with check (
      rider_id = auth.uid()
      or partner_id = auth.uid()
      or public.caller_is_admin()
    );

  -- Claiming / offering: any authenticated partner may write to an OPEN row,
  -- but the new row must carry their own partner_id.
  create policy "ride_requests claim open"
    on public.ride_requests for update to public
    using (status = 'open' and auth.uid() is not null)
    with check (partner_id = auth.uid());

  create policy "ride_requests admin delete"
    on public.ride_requests for delete to public
    using (public.caller_is_admin());
end;
$ride_requests$;

-- Permissive policies OR together across USING and WITH CHECK independently,
-- so "claim open" USING + "participant update" WITH CHECK would let a caller
-- re-own someone's open request by rewriting rider_id to themselves. Close
-- that: rider_id is immutable after insert (privileged sessions excepted).
create or replace function public.ride_requests_protect_rider()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.rider_id is distinct from old.rider_id and not public.caller_is_admin() then
    raise exception 'rider_immutable';
  end if;
  return new;
end;
$$;

do $rr_trigger$
begin
  if to_regclass('public.ride_requests') is null then return; end if;
  drop trigger if exists trg_ride_requests_protect_rider on public.ride_requests;
  create trigger trg_ride_requests_protect_rider
    before update on public.ride_requests
    for each row execute function public.ride_requests_protect_rider();
end;
$rr_trigger$;

-- ============================================================================
-- Part 3 — admin-managed configuration tables: writes become admin-only
-- ============================================================================
-- Reads stay public (the app renders these), existing INSERT/UPDATE/DELETE
-- policies — whatever their historical names — are dropped and replaced.
do $config$
declare
  t   text;
  pol record;
begin
  foreach t in array array[
    'countries', 'states', 'cities', 'suburbs', 'airport_areas',
    'required_document', 'document_type', 'driver_incentive', 'multi_gate',
    'insurance_providers', 'insurance_types', 'insurance_durations',
    'insurance_premium', 'ev_delivery_advisors', 'ev_finance_options',
    'ev_order_fee', 'ev_vehicle_details', 'ev_vehicle_inventory',
    'vehicle_make_models', 'settings_entries', 'app_settings', 'app_branding',
    'commission_rates', 'ip_access_rules', 'get_coin_settings',
    'get_coin_rate_history', 'admin_display_settings', 'push_notifications'
  ] loop
    if to_regclass('public.' || t) is null then continue; end if;

    for pol in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd in ('INSERT', 'UPDATE', 'DELETE')
    loop
      execute format('drop policy %I on public.%I;', pol.policyname, t);
    end loop;

    execute format(
      'create policy "%1$s admin insert" on public.%1$s for insert to public with check (public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin update" on public.%1$s for update to public using (public.caller_is_admin()) with check (public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin delete" on public.%1$s for delete to public using (public.caller_is_admin());', t);
  end loop;
end;
$config$;

-- push_notifications additionally loses its public read: broadcast history is
-- an admin dashboard concern and the send-push edge function writes with the
-- service role (bypasses RLS).
do $push_notifications$
begin
  if to_regclass('public.push_notifications') is null then return; end if;
  drop policy if exists "push_notifications read" on public.push_notifications;
  create policy "push_notifications read"
    on public.push_notifications for select
    using (public.caller_is_admin());
end;
$push_notifications$;

-- ============================================================================
-- Part 4 — personal / PII tables: owner-or-admin scoped
-- ============================================================================
do $pii$
declare
  t   text;
  pol record;
begin
  foreach t in array array[
    'emergency_contacts', 'user_sessions', 'user_location_history',
    'voice_protection_recordings', 'support_tickets', 'support_messages',
    'support_calls', 'push_tokens', 'provider_documents', 'vehicle',
    'vehicle_documents', 'vehicle_user_assignment', 'vehicle_active_session',
    'fare_ai_responses'
  ] loop
    if to_regclass('public.' || t) is null then continue; end if;
    for pol in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = t
         and cmd in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    loop
      execute format('drop policy %I on public.%I;', pol.policyname, t);
    end loop;
  end loop;
end;
$pii$;

-- emergency_contacts — the rider's own SOS contacts.
do $emergency$
begin
  if to_regclass('public.emergency_contacts') is null then return; end if;
  create policy "emergency_contacts own select" on public.emergency_contacts
    for select using (profile_id = auth.uid() or public.caller_is_admin());
  create policy "emergency_contacts own insert" on public.emergency_contacts
    for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "emergency_contacts own update" on public.emergency_contacts
    for update to public
    using (profile_id = auth.uid() or public.caller_is_admin())
    with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "emergency_contacts own delete" on public.emergency_contacts
    for delete to public using (profile_id = auth.uid() or public.caller_is_admin());
end;
$emergency$;

-- user_sessions / user_location_history — launch telemetry (public IP, ISP,
-- GPS trail). Inserts remain possible pre-login (user_id null) but a caller
-- can never attribute rows to somebody else; reads are owner/admin only.
do $telemetry$
declare t text;
begin
  foreach t in array array['user_sessions', 'user_location_history'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format(
      'create policy "%1$s own select" on public.%1$s for select using (user_id = auth.uid() or public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s own insert" on public.%1$s for insert to public with check (user_id is null or user_id = auth.uid() or public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin update" on public.%1$s for update to public using (public.caller_is_admin()) with check (public.caller_is_admin());', t);
    execute format(
      'create policy "%1$s admin delete" on public.%1$s for delete to public using (public.caller_is_admin());', t);
  end loop;
end;
$telemetry$;

-- voice_protection_recordings — in-ride audio metadata. The recording device
-- inserts/updates its own rows (upload flags); admins request uploads and
-- review.
do $voice$
begin
  if to_regclass('public.voice_protection_recordings') is null then return; end if;
  create policy "voice_protection own select" on public.voice_protection_recordings
    for select using (profile_id = auth.uid() or public.caller_is_admin());
  create policy "voice_protection own insert" on public.voice_protection_recordings
    for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "voice_protection own update" on public.voice_protection_recordings
    for update to public
    using (profile_id = auth.uid() or public.caller_is_admin())
    with check (profile_id = auth.uid() or public.caller_is_admin());
  create policy "voice_protection admin delete" on public.voice_protection_recordings
    for delete to public using (public.caller_is_admin());
end;
$voice$;

-- support_tickets / support_messages / support_calls — the requester and the
-- support admins. Messages are scoped through their ticket.
do $support$
begin
  if to_regclass('public.support_tickets') is not null then
    create policy "support_tickets own select" on public.support_tickets
      for select using (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_tickets own insert" on public.support_tickets
      for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_tickets own update" on public.support_tickets
      for update to public
      using (profile_id = auth.uid() or public.caller_is_admin())
      with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_tickets admin delete" on public.support_tickets
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.support_messages') is not null then
    create policy "support_messages participant select" on public.support_messages
      for select using (
        public.caller_is_admin()
        or exists (
          select 1 from public.support_tickets t
          where t.id = support_messages.ticket_id and t.profile_id = auth.uid()
        )
      );
    create policy "support_messages participant insert" on public.support_messages
      for insert to public with check (
        public.caller_is_admin()
        or exists (
          select 1 from public.support_tickets t
          where t.id = support_messages.ticket_id and t.profile_id = auth.uid()
        )
      );
    create policy "support_messages admin update" on public.support_messages
      for update to public
      using (public.caller_is_admin()) with check (public.caller_is_admin());
    create policy "support_messages admin delete" on public.support_messages
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.support_calls') is not null then
    create policy "support_calls own select" on public.support_calls
      for select using (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_calls own insert" on public.support_calls
      for insert to public with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_calls own update" on public.support_calls
      for update to public
      using (profile_id = auth.uid() or public.caller_is_admin())
      with check (profile_id = auth.uid() or public.caller_is_admin());
    create policy "support_calls admin delete" on public.support_calls
      for delete to public using (public.caller_is_admin());
  end if;
end;
$support$;

-- push_tokens — Expo push tokens are credentials for reaching a device.
-- Registration moves behind owner-scoped RPCs; the table itself is
-- admin-read/write only (the send-push edge function uses the service role).
do $push_tokens$
begin
  if to_regclass('public.push_tokens') is null then return; end if;
  create policy "push_tokens admin select" on public.push_tokens
    for select using (public.caller_is_admin());
  create policy "push_tokens admin insert" on public.push_tokens
    for insert to public with check (public.caller_is_admin());
  create policy "push_tokens admin update" on public.push_tokens
    for update to public
    using (public.caller_is_admin()) with check (public.caller_is_admin());
  create policy "push_tokens admin delete" on public.push_tokens
    for delete to public using (public.caller_is_admin());
end;
$push_tokens$;

-- Owner-scoped registration. Upserting by token also covers the "same device,
-- new account" case, which plain RLS cannot express (the old row belongs to
-- the previous profile).
create or replace function public.push_register_token(
  p_token text,
  p_platform text default null,
  p_device_name text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_token is null or length(trim(p_token)) = 0 or length(p_token) > 512 then
    raise exception 'invalid_token';
  end if;
  insert into public.push_tokens (token, profile_id, platform, device_name)
  values (p_token, auth.uid(), p_platform, p_device_name)
  on conflict (token) do update
    set profile_id  = excluded.profile_id,
        platform    = excluded.platform,
        device_name = excluded.device_name,
        updated_at  = now();
end;
$$;

-- Knowing the token IS the capability (it is device-secret), so sign-out
-- cleanup works even after the auth session is gone.
create or replace function public.push_unregister_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return;
  end if;
  delete from public.push_tokens where token = p_token;
end;
$$;

grant execute on function public.push_register_token(text, text, text) to anon, authenticated;
grant execute on function public.push_unregister_token(text) to anon, authenticated;

-- provider_documents / vehicle / vehicle_documents / vehicle assignments —
-- partner onboarding data (IC numbers, document scans). Owner = the linked
-- auth user, the owning partner, or an assigned driver; admins see all.
do $partner_data$
begin
  if to_regclass('public.provider_documents') is not null then
    create policy "provider_documents own select" on public.provider_documents
      for select using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "provider_documents own insert" on public.provider_documents
      for insert to public with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "provider_documents own update" on public.provider_documents
      for update to public
      using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      )
      with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = provider_documents.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "provider_documents admin delete" on public.provider_documents
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.vehicle') is not null then
    create policy "vehicle own select" on public.vehicle
      for select using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle.owner_partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle_user_assignment a
          where a.vehicle_id = vehicle.id and a.user_id = auth.uid()
        )
      );
    create policy "vehicle own insert" on public.vehicle
      for insert to public with check (
        public.caller_is_admin() or auth_user_id = auth.uid()
      );
    create policy "vehicle own update" on public.vehicle
      for update to public
      using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle.owner_partner_id and p.auth_user_id = auth.uid()
        )
      )
      with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle.owner_partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "vehicle admin delete" on public.vehicle
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.vehicle_documents') is not null then
    create policy "vehicle_documents own select" on public.vehicle_documents
      for select using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      );
    create policy "vehicle_documents own insert" on public.vehicle_documents
      for insert to public with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      );
    create policy "vehicle_documents own update" on public.vehicle_documents
      for update to public
      using (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      )
      with check (
        public.caller_is_admin()
        or auth_user_id = auth.uid()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_documents.partner_id and p.auth_user_id = auth.uid()
        )
        or exists (
          select 1 from public.vehicle v
          where v.id = vehicle_documents.vehicle_id
            and (v.auth_user_id = auth.uid()
                 or exists (
                   select 1 from public.vehicle_user_assignment a
                   where a.vehicle_id = v.id and a.user_id = auth.uid()
                 ))
        )
      );
    create policy "vehicle_documents admin delete" on public.vehicle_documents
      for delete to public using (public.caller_is_admin());
  end if;

  -- Assignments/sessions are managed by admins and the SECURITY DEFINER
  -- claim/release RPCs (0031/0035); drivers only need to read their own.
  if to_regclass('public.vehicle_user_assignment') is not null then
    create policy "vehicle_user_assignment own select" on public.vehicle_user_assignment
      for select using (
        user_id = auth.uid()
        or public.caller_is_admin()
        or exists (
          select 1 from public.partners p
          where p.id = vehicle_user_assignment.partner_id and p.auth_user_id = auth.uid()
        )
      );
    create policy "vehicle_user_assignment admin insert" on public.vehicle_user_assignment
      for insert to public with check (public.caller_is_admin());
    create policy "vehicle_user_assignment admin update" on public.vehicle_user_assignment
      for update to public
      using (public.caller_is_admin()) with check (public.caller_is_admin());
    create policy "vehicle_user_assignment admin delete" on public.vehicle_user_assignment
      for delete to public using (public.caller_is_admin());
  end if;

  if to_regclass('public.vehicle_active_session') is not null then
    create policy "vehicle_active_session own select" on public.vehicle_active_session
      for select using (user_id = auth.uid() or public.caller_is_admin());
    create policy "vehicle_active_session admin insert" on public.vehicle_active_session
      for insert to public with check (public.caller_is_admin());
    create policy "vehicle_active_session admin update" on public.vehicle_active_session
      for update to public
      using (public.caller_is_admin()) with check (public.caller_is_admin());
    create policy "vehicle_active_session admin delete" on public.vehicle_active_session
      for delete to public using (public.caller_is_admin());
  end if;
end;
$partner_data$;

-- fare_ai_responses — request/response logs embed rider route coordinates.
-- Reads become admin-only; inserts stay open because the legacy client-side
-- provider loop (pre ai-route-proxy) logs its attempts best-effort.
do $fare_ai$
begin
  if to_regclass('public.fare_ai_responses') is null then return; end if;
  create policy "fare_ai_responses admin select" on public.fare_ai_responses
    for select using (public.caller_is_admin());
  create policy "fare_ai_responses insert" on public.fare_ai_responses
    for insert to public with check (true);
  create policy "fare_ai_responses admin delete" on public.fare_ai_responses
    for delete to public using (public.caller_is_admin());
end;
$fare_ai$;

-- ============================================================================
-- Part 5 — online_driver_locations: SECURITY DEFINER view → invoker
-- ============================================================================
-- The view (previously created ad hoc, definer-owned, bypassing RLS) exposes
-- online drivers' latest GPS fix. With security_invoker it now runs under the
-- caller's policies — i.e. admin dashboards. No app screen queries it.
do $view$
begin
  if to_regclass('public.vehicle_active_session') is null
     or to_regclass('public.partners') is null
     or to_regclass('public.user_location_history') is null then
    return;
  end if;
  execute $v$
    create or replace view public.online_driver_locations
    with (security_invoker = true) as
    select vas.id as session_id,
           vas.partner_id,
           vas.vehicle_id,
           vas.user_id,
           p.partner_types,
           p.vehicle_type,
           ulh.latitude,
           ulh.longitude,
           ulh.heading,
           ulh.speed,
           ulh.captured_at
      from public.vehicle_active_session vas
      join public.partners p on p.id = vas.partner_id
      join lateral (
        select l.latitude, l.longitude, l.heading, l.speed, l.captured_at
          from public.user_location_history l
         where l.user_id = vas.user_id
         order by l.captured_at desc
         limit 1
      ) ulh on true
     where vas.status = 'online'
  $v$;
end;
$view$;

-- ============================================================================
-- Part 6 — pin search_path on flagged trigger/cron functions
-- ============================================================================
do $fn_paths$
declare f text;
begin
  foreach f in array array[
    'public.set_updated_at()',
    'public.set_support_ticket_number()',
    'public.expire_documents_daily()',
    'public.provider_documents_touch_updated_at()',
    'public.provider_documents_apply_expiry()',
    'public.vehicle_documents_touch_updated_at()',
    'public.vehicle_documents_apply_expiry()'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('alter function %s set search_path = public;', f);
    end if;
  end loop;
  -- hash_profile_pin calls pgcrypto's crypt(); include the extensions schema
  -- in case pgcrypto lives there rather than in public.
  if to_regprocedure('public.hash_profile_pin()') is not null then
    alter function public.hash_profile_pin() set search_path = public, extensions;
  end if;
end;
$fn_paths$;

-- ============================================================================
-- Part 7 — storage: stop public listing + anon writes on managed buckets
-- ============================================================================
-- Buckets stay `public` so existing getPublicUrl() links keep rendering; the
-- policies below only govern the storage API (list/download/upload/delete),
-- which the app uses for uploads and admin signed URLs.

-- Broad SELECT (listing) policies.
drop policy if exists "public read app-assets"     on storage.objects;
drop policy if exists "public read avatars"        on storage.objects;
drop policy if exists "public read id_image"       on storage.objects;
drop policy if exists "public read support-media"  on storage.objects;
drop policy if exists "app-branding read"          on storage.objects;
drop policy if exists "partner-type-icons read"    on storage.objects;
drop policy if exists "provider-documents read"    on storage.objects;
drop policy if exists "vehicle-documents read"     on storage.objects;
drop policy if exists "anon read voice-protection" on storage.objects;

-- Admins keep API-level read (listing, signed URLs) on every managed bucket.
drop policy if exists "managed buckets admin read" on storage.objects;
create policy "managed buckets admin read"
  on storage.objects for select to authenticated
  using (
    public.caller_is_admin()
    and bucket_id in (
      'app-assets', 'app-branding', 'avatars', 'ID_Image',
      'partner-type-icons', 'provider-documents', 'support-media',
      'vehicle-documents', 'voice-protection'
    )
  );

-- Voice-protection recordings: uploads land in a folder named after the
-- recording profile, so the owner keeps read/write on their own folder.
drop policy if exists "anon upload voice-protection" on storage.objects;
drop policy if exists "anon update voice-protection" on storage.objects;
drop policy if exists "anon delete voice-protection" on storage.objects;
drop policy if exists "voice-protection owner read"   on storage.objects;
drop policy if exists "voice-protection owner write"  on storage.objects;
drop policy if exists "voice-protection owner update" on storage.objects;
drop policy if exists "voice-protection admin delete" on storage.objects;
create policy "voice-protection owner read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'voice-protection'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "voice-protection owner write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'voice-protection'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "voice-protection owner update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'voice-protection'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "voice-protection admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'voice-protection' and public.caller_is_admin());

-- Branding + partner-type icons: only admins manage these assets.
drop policy if exists "app-branding insert" on storage.objects;
drop policy if exists "app-branding update" on storage.objects;
drop policy if exists "app-branding delete" on storage.objects;
drop policy if exists "app-branding admin write"  on storage.objects;
drop policy if exists "app-branding admin update" on storage.objects;
drop policy if exists "app-branding admin delete" on storage.objects;
create policy "app-branding admin write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'app-branding' and public.caller_is_admin());
create policy "app-branding admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'app-branding' and public.caller_is_admin());
create policy "app-branding admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'app-branding' and public.caller_is_admin());

drop policy if exists "partner-type-icons insert" on storage.objects;
drop policy if exists "partner-type-icons update" on storage.objects;
drop policy if exists "partner-type-icons delete" on storage.objects;
drop policy if exists "partner-type-icons admin write"  on storage.objects;
drop policy if exists "partner-type-icons admin update" on storage.objects;
drop policy if exists "partner-type-icons admin delete" on storage.objects;
create policy "partner-type-icons admin write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'partner-type-icons' and public.caller_is_admin());
create policy "partner-type-icons admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'partner-type-icons' and public.caller_is_admin());
create policy "partner-type-icons admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'partner-type-icons' and public.caller_is_admin());

-- Partner/vehicle document scans: uploads are keyed by partner/vehicle id
-- (not auth uid), so writes stay authenticated-wide; deletes become admin.
drop policy if exists "provider-documents insert" on storage.objects;
drop policy if exists "provider-documents update" on storage.objects;
drop policy if exists "provider-documents delete" on storage.objects;
drop policy if exists "provider-documents auth write"   on storage.objects;
drop policy if exists "provider-documents auth update"  on storage.objects;
drop policy if exists "provider-documents admin delete" on storage.objects;
create policy "provider-documents auth write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'provider-documents');
create policy "provider-documents auth update"
  on storage.objects for update to authenticated
  using (bucket_id = 'provider-documents');
create policy "provider-documents admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'provider-documents' and public.caller_is_admin());

drop policy if exists "vehicle-documents insert" on storage.objects;
drop policy if exists "vehicle-documents update" on storage.objects;
drop policy if exists "vehicle-documents delete" on storage.objects;
drop policy if exists "vehicle-documents auth write"   on storage.objects;
drop policy if exists "vehicle-documents auth update"  on storage.objects;
drop policy if exists "vehicle-documents admin delete" on storage.objects;
create policy "vehicle-documents auth write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicle-documents');
create policy "vehicle-documents auth update"
  on storage.objects for update to authenticated
  using (bucket_id = 'vehicle-documents');
create policy "vehicle-documents admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'vehicle-documents' and public.caller_is_admin());

-- Support attachments: authenticated uploads (support requires a profile),
-- admin-only rewrite/delete.
drop policy if exists "anon upload support-media" on storage.objects;
drop policy if exists "auth update support-media" on storage.objects;
drop policy if exists "auth delete support-media" on storage.objects;
drop policy if exists "support-media auth write"   on storage.objects;
drop policy if exists "support-media admin update" on storage.objects;
drop policy if exists "support-media admin delete" on storage.objects;
create policy "support-media auth write"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'support-media');
create policy "support-media admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'support-media' and public.caller_is_admin());
create policy "support-media admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'support-media' and public.caller_is_admin());

-- (avatars / ID_Image writes were already authenticated-scoped — unchanged.)

-- ============================================================================
-- Not fixable in SQL: enable "leaked password protection" in the Supabase
-- dashboard (Auth → Providers → Password) to clear the remaining advisor
-- warning. This project signs in via phone OTP + PIN, so impact is minimal.
-- ============================================================================
