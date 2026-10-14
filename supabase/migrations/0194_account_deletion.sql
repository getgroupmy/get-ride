-- ============================================================================
-- 0194: delete my account, and an admin linking a deleted account's history
--
-- A person can delete their own account from the app:
--   * confirmed with their PIN, or with an SMS code just verified on this
--     session (the token's "otp" sign-in within the last 10 minutes);
--   * refused while a ride is under way (accepted / arrived / on trip);
--   * an open request is cancelled, upcoming scheduled rides are cancelled
--     with no fee, and a driver's assigned bookings go back to be re-matched;
--   * the account is kept (soft delete): rides, receipts, wallet and GET.coin
--     balances (frozen: no ledger row moves them) and any partner debt stay
--     on record;
--   * the phone number is released: the old login loses its number and is
--     banned, every session ends, so the next sign-in with that number makes
--     a new account.
--
-- An admin with Users edit rights can link a deleted account to the new one,
-- picking what moves: trips, ratings, wallet & GET.coin, saved places &
-- favourites, referral, partner profile/documents/vehicles, support tickets.
-- Every link is recorded in account_events. A linked partner goes back to
-- review.
--
-- After the retention days (admin-set, 365 by default) a deleted account is
-- "due for final deletion". An admin approves it: personal data is wiped,
-- financial records stay, anonymised. A weekly push reminds the Users admins
-- while any are due.
--
-- Also: no request from a deleted account's leftover token is served
-- (request_guard), and the phone lookup ignores deleted accounts.
-- ============================================================================

-- ---- Settings -----------------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('account_deletion', jsonb_build_object('retentionDays', 365))
on conflict (key) do nothing;

-- Admin pages that may edit users (or every page).
create or replace function public.caller_can_edit_users()
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
         and access_level = 'edit'
         and page in ('*', 'admin-users', 'admin-user-edit'))
  end;
$$;
revoke execute on function public.caller_can_edit_users() from public, anon;
grant execute on function public.caller_can_edit_users() to authenticated, service_role;

create or replace function public.account_deletion_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('retentionDays',
    least(3650, greatest(30, coalesce(
      (select case when jsonb_typeof(value->'retentionDays') = 'number' then (value->>'retentionDays')::numeric end
         from public.app_settings where key = 'account_deletion'), 365)::int)));
$$;
revoke execute on function public.account_deletion_config() from public, anon;
grant execute on function public.account_deletion_config() to authenticated, service_role;

create or replace function public.set_account_deletion_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days numeric := case when jsonb_typeof(p_config->'retentionDays') = 'number'
                         then (p_config->>'retentionDays')::numeric end;
begin
  if not public.caller_can_edit_users() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_days is null or v_days < 30 or v_days > 3650 then
    raise exception 'ACCOUNT_DELETION_CONFIG' using hint = 'Keep deleted accounts for 30 to 3650 days.';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('account_deletion', jsonb_build_object('retentionDays', round(v_days)::int), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.account_deletion_config();
end;
$$;
revoke execute on function public.set_account_deletion_config(jsonb) from public, anon;
grant execute on function public.set_account_deletion_config(jsonb) to authenticated;

-- ---- Columns and the event log ------------------------------------------------------------------
alter table public.profiles
  add column if not exists deleted_at       timestamptz,
  add column if not exists deleted_phone    text,
  add column if not exists deletion_reason  text,
  add column if not exists final_deleted_at timestamptz,
  add column if not exists final_deleted_by uuid;

create index if not exists profiles_deleted_idx on public.profiles (deleted_at) where deleted_at is not null;
create index if not exists profiles_deleted_phone_idx on public.profiles (deleted_phone) where deleted_phone is not null;

-- Deleted, linked, finally deleted: who did what, to which account.
create table if not exists public.account_events (
  id               uuid primary key default gen_random_uuid(),
  profile_id       uuid not null,
  kind             text not null check (kind in ('deleted', 'linked', 'final_deleted')),
  actor_id         uuid,
  other_profile_id uuid,
  categories       text[] not null default '{}',
  detail           jsonb not null default '{}',
  created_at       timestamptz not null default now()
);
create index if not exists account_events_profile_idx on public.account_events (profile_id, created_at desc);
create index if not exists account_events_other_idx on public.account_events (other_profile_id)
  where other_profile_id is not null;

alter table public.account_events enable row level security;
drop policy if exists "account_events admin read" on public.account_events;
create policy "account_events admin read" on public.account_events
  for select to authenticated using ((select public.caller_is_admin()));
revoke insert, update, delete on public.account_events from anon, authenticated;
grant select on public.account_events to authenticated;

-- ---- A deleted account's balances do not move ---------------------------------------------------
-- Sorts before trg_wallet_tx_apply, so nothing is applied. Linking moves them
-- (getride.account_linking).
create or replace function public.wallet_tx_frozen_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('getride.account_linking', true), '') <> '1'
     and exists (select 1 from public.profiles where id = new.user_id and deleted_at is not null) then
    raise exception 'ACCOUNT_DELETED' using hint = 'This account was deleted, so its balance can''t change.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_wallet_tx_0_frozen on public.wallet_transactions;
create trigger trg_wallet_tx_0_frozen
  before insert on public.wallet_transactions
  for each row execute function public.wallet_tx_frozen_guard();

-- ---- Delete my account --------------------------------------------------------------------------
-- Signed in by SMS code within the last 10 minutes (the session's "otp" sign-in).
create or replace function public.session_recent_sms_sign_in()
returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
    select 1
      from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) a
     where jsonb_typeof(a) = 'object'
       and a ->> 'method' in ('otp', 'sms')
       and (a ->> 'timestamp') ~ '^[0-9]+$'
       and (a ->> 'timestamp')::bigint >= extract(epoch from now())::bigint - 600);
$$;
revoke execute on function public.session_recent_sms_sign_in() from public, anon;
grant execute on function public.session_recent_sms_sign_in() to authenticated;

-- A ride under way, as rider or driver.
create or replace function public.account_has_active_ride(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ride_requests
     where (rider_id = p_user or partner_id = p_user)
       and status in ('accepted', 'arrived', 'on_trip')
       and updated_at > now() - interval '12 hours');
$$;
revoke execute on function public.account_has_active_ride(uuid) from public, anon, authenticated;

-- Returns {ok:true} or {error: 'confirm_needed' | 'wrong_pin' | 'active_ride' | 'already_deleted'}.
-- A wrong PIN is returned, not raised, so the failed try still counts.
create or replace function public.delete_my_account(p_pin text default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  p      public.profiles;
  s      public.scheduled_rides;
  v_rides int := 0;
  v_booked int := 0;
  v_jobs int := 0;
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
  values (v_uid, 'deleted', v_uid, jsonb_build_object(
    'phone', p.phone, 'reason', left(nullif(trim(p_reason), ''), 300),
    'requestsCancelled', v_rides, 'bookingsCancelled', v_booked, 'jobsReleased', v_jobs));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.delete_my_account(text, text) from public, anon;
grant execute on function public.delete_my_account(text, text) to authenticated;

-- What the app shows before asking: whether a ride is under way.
create or replace function public.my_account_deletion_check()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'activeRide', public.account_has_active_ride(auth.uid()),
    'bookings', (select count(*) from public.scheduled_rides
                  where rider_id = auth.uid() and status in ('scheduled', 'assigned', 'released')),
    'retentionDays', (public.account_deletion_config() ->> 'retentionDays')::int);
$$;
revoke execute on function public.my_account_deletion_check() from public, anon;
grant execute on function public.my_account_deletion_check() to authenticated;

-- ---- No request from a deleted account ----------------------------------------------------------
-- 0180's hook, plus: a leftover token of a deleted account is refused.
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
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    if v_claims is null or v_claims ->> 'role' is distinct from 'authenticated' then
      return;
    end if;
    v_deleted := exists (select 1 from public.profiles
                          where id = (v_claims ->> 'sub')::uuid and deleted_at is not null);
    if not v_deleted then
      -- Nothing recorded for this account: nothing to hold it to.
      if not exists (select 1 from public.active_sessions where user_id = (v_claims ->> 'sub')::uuid) then
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

-- ---- The phone lookup ignores deleted accounts --------------------------------------------------
-- 0173, with deleted accounts left out: their number is free for a new one.
-- An account an admin marked Deleted (no deleted_at) still reads as deleted.
create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip   text := public.request_client_ip();
  v_wait integer := public.auth_rate_take('phone_lookup', v_ip, 20, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  v_wait := public.auth_rate_take('phone_lookup_day', v_ip, 100, interval '1 day');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  return query
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array['+' || d, d, '0' || d, ltrim(d, '0')], null) as v
    from digits
  ),
  match as (
    select p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
      and p.deleted_at is null
    order by (lower(p.profile_status::text) = 'deleted'), p.created_at desc
    limit 1
  )
  select
    exists(select 1 from match),
    coalesce((select m.pin_hash is not null and m.pin_hash <> '' from match m), false),
    coalesce((select lower(m.profile_status::text) = 'deleted' from match m), false);
end;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- ---- Admin: link a deleted account to the new one -----------------------------------------------
create or replace function public.admin_link_account(p_old uuid, p_new uuid, p_categories text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o       public.profiles;
  n       public.profiles;
  v_cats  text[];
  v_done  text[];
  v_bad   text[];
  v_count int;
  v_out   jsonb := '{}';
  w       record;
  v_code  text;
begin
  if not public.caller_can_edit_users() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select array_agg(distinct c order by c) into v_cats
    from unnest(coalesce(p_categories, '{}')) c where c is not null;
  if v_cats is null then
    raise exception 'ACCOUNT_LINK_NOTHING' using hint = 'Pick at least one thing to move.';
  end if;
  select array_agg(c) into v_bad from unnest(v_cats) c
   where c not in ('trips', 'ratings', 'wallet', 'places', 'referral', 'partner', 'tickets');
  if v_bad is not null then
    raise exception 'ACCOUNT_LINK_CATEGORY' using hint = 'Unknown: ' || array_to_string(v_bad, ', ') || '.';
  end if;

  select * into o from public.profiles where id = p_old for update;
  select * into n from public.profiles where id = p_new for update;
  if o.id is null or n.id is null or o.id = n.id then
    raise exception 'ACCOUNT_LINK_PAIR' using hint = 'Pick a deleted account and a different, active account.';
  end if;
  if o.deleted_at is null or o.final_deleted_at is not null then
    raise exception 'ACCOUNT_LINK_PAIR' using hint = 'Only a deleted account that hasn''t been wiped can be linked.';
  end if;
  if n.deleted_at is not null then
    raise exception 'ACCOUNT_LINK_PAIR' using hint = 'The new account has been deleted too.';
  end if;

  -- Each part moves once.
  select array_agg(distinct c) into v_done
    from public.account_events e, unnest(e.categories) c
   where e.profile_id = p_old and e.kind = 'linked' and c = any(v_cats);
  if v_done is not null then
    raise exception 'ACCOUNT_LINK_DONE' using hint = 'Already linked: ' || array_to_string(v_done, ', ') || '.';
  end if;
  if 'partner' = any(v_cats)
     and exists (select 1 from public.partners where auth_user_id = p_old)
     and exists (select 1 from public.partners where auth_user_id = p_new) then
    raise exception 'ACCOUNT_LINK_PARTNER' using hint = 'The new account already has a partner profile.';
  end if;

  perform set_config('getride.account_linking', '1', true);

  if 'trips' = any(v_cats) then
    update public.ride_requests set rider_id = p_new where rider_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('ridesAsPassenger', v_count);
    update public.ride_requests set partner_id = p_new where partner_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('ridesAsDriver', v_count);
    update public.scheduled_rides set rider_id = p_new where rider_id = p_old;
    update public.scheduled_rides set partner_id = p_new where partner_id = p_old;
    update public.ride_lost_items set rider_id = p_new where rider_id = p_old;
    update public.ride_lost_items set partner_id = p_new where partner_id = p_old;
  end if;

  if 'ratings' = any(v_cats) then
    update public.ride_ratings set rater_id = p_new where rater_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('ratingsGiven', v_count);
    update public.ride_ratings set partner_id = p_new where partner_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('ratingsReceived', v_count);
  end if;

  -- Balances move through the ledger, so both histories show it. Debt too.
  if 'wallet' = any(v_cats) then
    v_count := 0;
    for w in select wallet_type, balance from public.wallets where user_id = p_old and balance <> 0 loop
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
      values (p_old, w.wallet_type, 'account_link', -w.balance, 'Moved to the new account'),
             (p_new, w.wallet_type, 'account_link', w.balance, 'Moved from the previous account');
      v_count := v_count + 1;
    end loop;
    v_out := v_out || jsonb_build_object('balancesMoved', v_count);
  end if;

  if 'places' = any(v_cats) then
    -- One Home and one Work each: the new account's own stay.
    update public.saved_places sp set user_id = p_new
     where sp.user_id = p_old
       and not (sp.kind in ('home', 'work')
                and exists (select 1 from public.saved_places x where x.user_id = p_new and x.kind = sp.kind));
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('savedPlaces', v_count);
    update public.favourite_drivers f set rider_id = p_new
     where f.rider_id = p_old
       and not exists (select 1 from public.favourite_drivers x where x.rider_id = p_new and x.driver_id = f.driver_id);
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('favouriteDrivers', v_count);
  end if;

  if 'referral' = any(v_cats) then
    update public.referrals set referrer_user_id = p_new where referrer_user_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('referred', v_count);
    if not exists (select 1 from public.referrals where referred_user_id = p_new) then
      update public.referrals set referred_user_id = p_new where referred_user_id = p_old;
    end if;
    v_code := nullif(o.referral_code, '');
    if v_code is not null then
      update public.profiles set referral_code = null where id = p_old;
      update public.profiles set referral_code = v_code where id = p_new;
    end if;
  end if;

  -- The partner comes back for review under the new login.
  if 'partner' = any(v_cats) then
    update public.partners
       set auth_user_id = p_new, phone = coalesce(n.phone, phone), status = 'unapproved',
           status_note = 'Linked from a deleted account. Review again before approving.'
     where auth_user_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('partnerProfiles', v_count);
    update public.provider_documents set auth_user_id = p_new where auth_user_id = p_old;
    update public.vehicle_documents set auth_user_id = p_new where auth_user_id = p_old;
    update public.vehicle set auth_user_id = p_new where auth_user_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('vehicles', v_count);
    update public.vehicle_user_assignment set user_id = p_new where user_id = p_old;
    update public.commission_rates set user_id = p_new where user_id = p_old;
    update public.favourite_drivers f set driver_id = p_new
     where f.driver_id = p_old
       and not exists (select 1 from public.favourite_drivers x where x.driver_id = p_new and x.rider_id = f.rider_id);
  end if;

  if 'tickets' = any(v_cats) then
    update public.support_tickets set profile_id = p_new where profile_id = p_old;
    get diagnostics v_count = row_count;
    v_out := v_out || jsonb_build_object('tickets', v_count);
    update public.support_messages set sender_id = p_new where sender_id = p_old;
    update public.support_calls set profile_id = p_new where profile_id = p_old;
  end if;

  insert into public.account_events (profile_id, kind, actor_id, other_profile_id, categories, detail)
  values (p_old, 'linked', auth.uid(), p_new, v_cats, v_out);

  return v_out || jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.admin_link_account(uuid, uuid, text[]) from public, anon;
grant execute on function public.admin_link_account(uuid, uuid, text[]) to authenticated;

-- ---- Final deletion -----------------------------------------------------------------------------
create or replace function public.accounts_due_final_deletion()
returns setof public.profiles
language sql
stable
security definer
set search_path = public
as $$
  select p.* from public.profiles p
   where public.caller_can_edit_users()
     and p.deleted_at is not null
     and p.final_deleted_at is null
     and p.deleted_at < now() - make_interval(days => (public.account_deletion_config() ->> 'retentionDays')::int)
   order by p.deleted_at;
$$;
revoke execute on function public.accounts_due_final_deletion() from public, anon;
grant execute on function public.accounts_due_final_deletion() to authenticated;

-- Wipes the person, keeps the money: rides, ledger and tickets stay, with
-- names and numbers removed. Returns the storage folders the admin app then
-- empties (files can't be removed from SQL). Safe to run again.
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
  ) s;
  return jsonb_build_object('ok', true, 'folders', coalesce(v_folders, '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_final_delete_account(uuid) from public, anon;
grant execute on function public.admin_final_delete_account(uuid) to authenticated;

-- The admin app empties those folders.
drop policy if exists "account files admin delete" on storage.objects;
create policy "account files admin delete" on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'ID_Image', 'provider-documents') and (select public.caller_can_edit_users()));

-- ---- Weekly reminder ----------------------------------------------------------------------------
create or replace function public.account_deletion_remind()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_due  int;
  v_days int := (public.account_deletion_config() ->> 'retentionDays')::int;
  v_to   uuid;
  v_sent int := 0;
begin
  select count(*) into v_due from public.profiles
   where deleted_at is not null and final_deleted_at is null
     and deleted_at < now() - make_interval(days => v_days);
  if v_due = 0 then
    return 0;
  end if;
  for v_to in
    select distinct a.profile_id from public.admin_access a
      join public.profiles pr on pr.id = a.profile_id and pr.deleted_at is null
     where a.access_level = 'edit' and a.page in ('*', 'admin-users', 'admin-user-edit')
  loop
    perform public.enqueue_notification(v_to,
      'acct-final-' || to_char(now(), 'IYYY-IW') || '-' || v_to, 'admin_alert', 'normal',
      'Accounts due for final deletion',
      v_due || case when v_due = 1 then ' deleted account has' else ' deleted accounts have' end
        || ' passed ' || v_days || ' days. Review and approve the final deletion.',
      jsonb_build_object('type', 'accounts_due_final_deletion', 'route', '/admin/users?status=final-delete'));
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end;
$$;
revoke execute on function public.account_deletion_remind() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'account-final-deletion-reminder';
    -- Mondays, 09:07 in Malaysia.
    perform cron.schedule('account-final-deletion-reminder', '7 1 * * 1',
      $job$select public.account_deletion_remind()$job$);
  end if;
end$$;

-- ---- Help article -------------------------------------------------------------------------------
-- 0130 seeds the new text on a fresh database; this updates one already
-- seeded, leaving an article an admin has edited alone.
update public.help_articles
   set answer = 'Settings → Delete account. Confirm with your PIN or an SMS code. You can''t delete during a ride; upcoming scheduled rides are cancelled free. Your rides, receipts and any balance are kept on record and frozen, and your number is free to sign up again as a new account. If you come back, ask support to link your old history to the new account.',
       action_label = 'Delete account',
       action_route = '/account/settings/delete'
 where id = '68656c70-0000-4000-8000-000000000070'
   and answer = 'There is no delete button in the app. Ask in Help & support chat and our team will close your account. Settle any GET.wallet balance and finish any ride first, and partners should hand back any shared vehicle.';
