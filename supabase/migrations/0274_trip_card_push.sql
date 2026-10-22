-- ============================================================================
-- 0274 — Trip card push: the trip card on an Android phone keeps moving
-- while the app is closed.
--
-- Applied by hand as version 20261021033200 (0274_trip_card_push in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", the trigger is dropped first.
--
-- The trip card (lib/src/core/trip_card.dart, PR #495) is started and moved
-- by the open app. Once the app is closed, the Edge Function trip-card-push
-- moves it: it builds the same card (supabase/functions/_shared/trip_card.ts)
-- for the ride's rider and its driver and sends their Android phones an FCM
-- data message that TripCardPushReceiver.kt applies, even with the app's
-- process dead. This migration calls it:
--
-- 1. public.trip_card_pushes: when each ride's card was last pushed (one row
--    per ride, gone with the ride). Only the definer functions below touch
--    it; nobody else reads or writes it.
-- 2. trip_card_push_snapshot(ride) (service role only): what the function
--    builds the card from — the ride's columns the card reads, picked by
--    name (never the trip code `otp` nor a courier's delivery code, which
--    is not on the row anyway), its amount due (ride_amount_due, as the
--    phone's RideRequest.totalDue), and Admin → Display Settings → Trip
--    card (admin_display_settings.settings.tripCard).
-- 3. trip_card_push_kick(ride, former driver): POSTs { rideId,
--    formerPartnerId } to /functions/v1/trip-card-push over pg_net with the
--    existing push webhook secret (`x-push-secret`, Vault
--    `push_webhook_secret`, 0128) and nothing else; no-ops without the
--    Vault `project_url` or the secret. Never fails the write it came from.
-- 4. Trigger trg_ride_requests_trip_card_push, after an update of a ride's
--    status, driver or the driver's live position, when the rider, the
--    driver or the driver who had it has an Android phone (push_tokens):
--      * a new status, or another driver (reopened, handed over): at once;
--      * the driver's position, on the way to the pickup or on the trip:
--        at most once every 30 seconds per ride (trip_card_pushes.sent_at,
--        claimed with one upsert, so two moves at once send one push).
--
-- What the function then sends, and to whom (the admin's switches, the done
-- card's minutes, the end of a cancelled ride, passenger / driver mode) is
-- in supabase/functions/_shared/trip_card_push.ts. Deploy it:
--   supabase functions deploy trip-card-push --no-verify-jwt
-- ============================================================================

-- ---- 1. When each ride's card was last pushed ------------------------------
create table if not exists public.trip_card_pushes (
  ride_id uuid primary key references public.ride_requests(id) on delete cascade,
  sent_at timestamptz not null default now()
);
alter table public.trip_card_pushes enable row level security;
revoke all on table public.trip_card_pushes from public, anon, authenticated;

-- ---- 2. What the card is built from ------------------------------------------
create or replace function public.trip_card_push_snapshot(p_ride uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ride',
      (select coalesce(jsonb_object_agg(k, j -> k), '{}'::jsonb)
         from unnest(array[
           'id', 'status', 'service', 'rider_id', 'rider_name', 'booked_for_name',
           'partner_id', 'partner_name', 'partner_vehicle', 'partner_plate',
           'pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng',
           'drop_name', 'drop_address', 'drop_lat', 'drop_lng',
           'distance_km', 'duration_min', 'fare', 'ride_fare', 'currency', 'payment_mode',
           'partner_accept_lat', 'partner_accept_lng', 'partner_live_lat', 'partner_live_lng',
           'pickup_door_name', 'parcel_size', 'cargo_description', 'recipient_name',
           'started_at', 'completed_at', 'timezone'
         ]) as k
        where j ? k)
      || jsonb_build_object('total_due', public.ride_amount_due(r)),
    'settings',
      coalesce((select s.settings -> 'tripCard' from public.admin_display_settings s where s.id = 'global'), '{}'::jsonb)
  )
  from public.ride_requests r
  cross join lateral to_jsonb(r) j
  where r.id = p_ride;
$$;
revoke execute on function public.trip_card_push_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.trip_card_push_snapshot(uuid) to service_role;

-- ---- 3. The call -------------------------------------------------------------
create or replace function public.trip_card_push_kick(p_ride uuid, p_former uuid default null)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return;
  end;
  if v_url is null or v_secret is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/trip-card-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := jsonb_strip_nulls(jsonb_build_object('rideId', p_ride, 'formerPartnerId', p_former))
  );
exception when others then
  -- A card that did not move never blocks the ride's write.
  null;
end;
$$;
revoke execute on function public.trip_card_push_kick(uuid, uuid) from public, anon, authenticated;

-- ---- 4. When ------------------------------------------------------------------
create or replace function public.ride_requests_trip_card_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_former  uuid := case when old.partner_id is not null and old.partner_id is distinct from new.partner_id
                         then old.partner_id end;
  v_status  boolean := new.status is distinct from old.status;
  v_moved   boolean := (new.partner_live_lat, new.partner_live_lng)
                        is distinct from (old.partner_live_lat, old.partner_live_lng);
  v_claimed int;
begin
  if not v_status and v_former is null and not v_moved then
    return null;
  end if;
  -- Only an Android phone has a card a push can move.
  if not exists (
    select 1 from public.push_tokens t
     where t.platform = 'android'
       and t.profile_id in (new.rider_id, new.partner_id, v_former)
  ) then
    return null;
  end if;

  if v_status or v_former is not null then
    insert into public.trip_card_pushes as p (ride_id, sent_at) values (new.id, now())
    on conflict (ride_id) do update set sent_at = now();
    perform public.trip_card_push_kick(new.id, v_former);
  elsif new.status in ('accepted', 'on_trip') and new.partner_id is not null then
    -- The driver's position: once every 30 seconds per ride at most.
    insert into public.trip_card_pushes as p (ride_id, sent_at) values (new.id, now())
    on conflict (ride_id) do update set sent_at = now()
      where p.sent_at <= now() - interval '30 seconds';
    get diagnostics v_claimed = row_count;
    if v_claimed > 0 then
      perform public.trip_card_push_kick(new.id, null);
    end if;
  end if;
  return null;
exception when others then
  return null;
end;
$$;
revoke execute on function public.ride_requests_trip_card_push() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_trip_card_push on public.ride_requests;
create trigger trg_ride_requests_trip_card_push
  after update of status, partner_id, partner_live_lat, partner_live_lng on public.ride_requests
  for each row
  execute function public.ride_requests_trip_card_push();
