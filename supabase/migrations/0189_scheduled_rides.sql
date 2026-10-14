-- ============================================================================
-- 0189: scheduled rides.
--
-- A rider books a ride for later, for themself or for someone else. The
-- booking (scheduled_rides) holds the ride exactly as the app would have
-- created it, plus the pickup time; it becomes a real ride_requests row at
-- the admin's lead time before pickup ("release").
--
-- Admin -> App Settings -> Scheduled rides (app_settings 'scheduled_rides'):
--   enabled, minLeadMinutes, maxDaysAhead,
--   feeFixed + feePercent      the scheduling fee (both may be 0), added to the
--                              ride as a "Scheduling fee" charge,
--   feeTo                      'platform' (taken back from the driver at the
--                              end of the trip, as commission is) or 'driver',
--   freeCancelMinutes          the rider cancels free until this long before
--                              pickup; after that lateCancelFee applies,
--   mode                       'advance': drivers see bookings ahead of time
--                              and pre-accept them; 'release': drivers first
--                              see a booking when it is released,
--   releaseMinutes             how long before pickup a booking is released,
--   reminderMinutes            the rider's reminder (0: none).
--
-- The late-cancel fee comes out of the rider's GET wallet when it can;
-- otherwise it is owed and is added to the rider's next ride as a charge.
-- On that ride the driver receives it (wallet payout or cash), so it is
-- taken back from the driver's GET credit when the trip completes.
--
-- A driver who cancels a ride that came from a booking does not end it: the
-- ride goes back to the pool for another driver and the rider is told.
-- ============================================================================

-- ---- Settings ----------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('scheduled_rides', jsonb_build_object(
  'enabled', false, 'minLeadMinutes', 30, 'maxDaysAhead', 7,
  'feeFixed', 0, 'feePercent', 0, 'feeTo', 'platform',
  'freeCancelMinutes', 60, 'lateCancelFee', 0,
  'mode', 'release', 'releaseMinutes', 20, 'reminderMinutes', 60))
on conflict (key) do nothing;

-- One number from the settings, defaulted and kept within [lo, hi].
create or replace function public.scheduled_cfg_num(v jsonb, p_key text, p_default numeric, lo numeric, hi numeric)
returns numeric
language sql
immutable
set search_path = public
as $$
  select least(hi, greatest(lo, coalesce(
    case when jsonb_typeof(v->p_key) = 'number' then (v->>p_key)::numeric end, p_default)));
$$;

create or replace function public.scheduled_rides_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'enabled', coalesce((v->>'enabled')::boolean, false),
    'minLeadMinutes', public.scheduled_cfg_num(v, 'minLeadMinutes', 30, 5, 1440)::int,
    'maxDaysAhead', public.scheduled_cfg_num(v, 'maxDaysAhead', 7, 1, 30)::int,
    'feeFixed', round(public.scheduled_cfg_num(v, 'feeFixed', 0, 0, 1000), 2),
    'feePercent', round(public.scheduled_cfg_num(v, 'feePercent', 0, 0, 100), 2),
    'feeTo', case when v->>'feeTo' = 'driver' then 'driver' else 'platform' end,
    'freeCancelMinutes', public.scheduled_cfg_num(v, 'freeCancelMinutes', 60, 0, 1440)::int,
    'lateCancelFee', round(public.scheduled_cfg_num(v, 'lateCancelFee', 0, 0, 1000), 2),
    'mode', case when v->>'mode' = 'advance' then 'advance' else 'release' end,
    'releaseMinutes', public.scheduled_cfg_num(v, 'releaseMinutes', 20, 5, 180)::int,
    'reminderMinutes', public.scheduled_cfg_num(v, 'reminderMinutes', 60, 0, 1440)::int
  )
  from (select (select value from public.app_settings where key = 'scheduled_rides') as v) s;
$$;
revoke execute on function public.scheduled_rides_config() from public;
grant execute on function public.scheduled_rides_config() to anon, authenticated;

create or replace function public.set_scheduled_rides_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change scheduled rides.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('scheduled_rides', coalesce(p_config, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  -- Stored as cleaned, so what the app reads back is what applies.
  v := public.scheduled_rides_config();
  update public.app_settings set value = v where key = 'scheduled_rides';
  return v;
end;
$$;
revoke execute on function public.set_scheduled_rides_config(jsonb) from public, anon;
grant execute on function public.set_scheduled_rides_config(jsonb) to authenticated;

-- ---- The bookings -------------------------------------------------------------------------
create table if not exists public.scheduled_rides (
  id                  uuid primary key default gen_random_uuid(),
  rider_id            uuid not null references auth.users(id) on delete cascade,
  pickup_at           timestamptz not null,
  status              text not null default 'scheduled'
                      check (status in ('scheduled', 'assigned', 'released', 'completed', 'cancelled', 'expired')),
  request             jsonb not null,
  service             text,
  pickup_address      text,
  drop_address        text,
  pickup_lat          double precision,
  pickup_lng          double precision,
  drop_lat            double precision,
  drop_lng            double precision,
  distance_km         numeric,
  fare                numeric(12,2) not null,
  scheduling_fee      numeric(12,2) not null default 0,
  currency            text,
  booked_for_name     text,
  booked_for_phone    text,
  partner_id          uuid,
  partner_accepted_at timestamptz,
  ride_id             uuid references public.ride_requests(id) on delete set null,
  releases            integer not null default 0,
  released_at         timestamptz,
  reminded_at         timestamptz,
  last_error          text,
  cancelled_at        timestamptz,
  cancelled_by        text check (cancelled_by is null or cancelled_by in ('rider', 'admin', 'system')),
  cancel_reason       text,
  cancel_fee          numeric(12,2) not null default 0,
  cancel_fee_status   text not null default 'none' check (cancel_fee_status in ('none', 'charged', 'due', 'billed', 'paid')),
  billed_ride_id      uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists scheduled_rides_due_idx on public.scheduled_rides (status, pickup_at);
create index if not exists scheduled_rides_rider_idx on public.scheduled_rides (rider_id, pickup_at desc);
create index if not exists scheduled_rides_partner_idx on public.scheduled_rides (partner_id) where partner_id is not null;
create index if not exists scheduled_rides_owed_idx on public.scheduled_rides (rider_id) where cancel_fee_status = 'due';

drop trigger if exists trg_scheduled_rides_updated_at on public.scheduled_rides;
create trigger trg_scheduled_rides_updated_at
  before update on public.scheduled_rides
  for each row execute function public.set_updated_at();

alter table public.scheduled_rides enable row level security;
revoke all on public.scheduled_rides from anon, authenticated;
grant select on public.scheduled_rides to authenticated;
grant update on public.scheduled_rides to authenticated;

drop policy if exists "scheduled_rides read" on public.scheduled_rides;
create policy "scheduled_rides read" on public.scheduled_rides
  for select to authenticated
  using (rider_id = (select auth.uid()) or partner_id = (select auth.uid()) or (select public.caller_is_admin()));

-- Writes go through the functions below; an admin may also edit a booking.
drop policy if exists "scheduled_rides admin update" on public.scheduled_rides;
create policy "scheduled_rides admin update" on public.scheduled_rides
  for update to authenticated
  using ((select public.caller_is_admin())) with check ((select public.caller_is_admin()));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'scheduled_rides') then
    alter publication supabase_realtime add table public.scheduled_rides;
  end if;
end $$;

-- A ride that came from a booking; the fees on a ride the platform keeps.
alter table public.ride_requests
  add column if not exists scheduled_ride_id uuid,
  add column if not exists platform_fees_charged_at timestamptz;
create index if not exists ride_requests_scheduled_idx on public.ride_requests (scheduled_ride_id)
  where scheduled_ride_id is not null;

-- ---- The rider books ---------------------------------------------------------------------------
-- p_request: the ride_requests row the app would insert for a ride now.
create or replace function public.schedule_ride(p_request jsonb, p_pickup_at timestamptz)
returns public.scheduled_rides
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  c      jsonb := public.scheduled_rides_config();
  v_req  jsonb := coalesce(p_request, '{}'::jsonb);
  v_fare numeric;
  v_fee  numeric;
  v_name text;
  v_phone text;
  r      public.scheduled_rides;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not (c->>'enabled')::boolean then
    raise exception 'SCHEDULED_OFF' using hint = 'Scheduled rides are not available.';
  end if;
  if p_pickup_at is null
     or p_pickup_at < now() + make_interval(mins => (c->>'minLeadMinutes')::int)
     or p_pickup_at > now() + make_interval(days => (c->>'maxDaysAhead')::int) then
    raise exception 'SCHEDULED_TIME' using hint = format('Pick a time between %s minutes and %s days from now.',
      c->>'minLeadMinutes', c->>'maxDaysAhead');
  end if;
  if (select count(*) from public.scheduled_rides
       where rider_id = v_uid and status in ('scheduled', 'assigned', 'released')) >= 5 then
    raise exception 'SCHEDULED_LIMIT' using hint = 'You already have 5 upcoming rides.';
  end if;

  v_fare := round(coalesce(
    case when jsonb_typeof(v_req->'ride_fare') = 'number' then (v_req->>'ride_fare')::numeric end,
    case when jsonb_typeof(v_req->'fare') = 'number' then (v_req->>'fare')::numeric end, 0), 2);
  if not public.ride_money_ok(v_fare) or v_fare <= 0 then
    raise exception 'RIDE_FARE_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(v_req->'pickup_lat') <> 'number' or jsonb_typeof(v_req->'pickup_lng') <> 'number' then
    raise exception 'SCHEDULED_PICKUP' using hint = 'A pickup point is needed.';
  end if;

  v_name := nullif(btrim(coalesce(v_req->>'booked_for_name', '')), '');
  v_phone := nullif(btrim(coalesce(v_req->>'booked_for_phone', '')), '');
  if (v_name is not null and (v_phone is null or length(v_name) > 80))
     or (v_phone is not null and length(v_phone) not between 6 and 32) then
    raise exception 'SCHEDULED_PASSENGER' using hint = 'Give the passenger''s name and phone number.';
  end if;

  -- What the server decides is not the app's to send.
  v_req := v_req - array[
    'id', 'status', 'rider_id', 'partner_id', 'partner_name', 'partner_phone', 'partner_photo',
    'partner_vehicle', 'partner_plate', 'partner_rating', 'accepted_at', 'arrived_at', 'started_at',
    'completed_at', 'cancelled_at', 'offered_fare', 'payment_status', 'paid_method', 'paid_amount',
    'paid_at', 'commission_rate', 'commission_amount', 'commission_charged_at', 'coin_rewarded_at',
    'fare_coins_redeemed_at', 'created_at', 'updated_at', 'scheduled_ride_id', 'platform_fees_charged_at',
    'target_driver_ids', 'targeted_until', 'direct_qr_token', 'direct_driver_id', 'direct_qr_id',
    'share_token', 'auto_accept_fare'];

  v_fee := round((c->>'feeFixed')::numeric + v_fare * (c->>'feePercent')::numeric / 100, 2);
  if v_fee > 0 then
    v_req := jsonb_set(v_req, '{charges}',
      (case when jsonb_typeof(v_req->'charges') = 'array' then v_req->'charges' else '[]'::jsonb end)
      || jsonb_build_array(jsonb_build_object(
           'kind', 'surcharge', 'name', 'Scheduling fee', 'charge', 'fixed', 'value', v_fee,
           'platform', (c->>'feeTo') = 'platform')));
  end if;

  insert into public.scheduled_rides (
    rider_id, pickup_at, request, service, pickup_address, drop_address,
    pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km, fare, scheduling_fee, currency,
    booked_for_name, booked_for_phone)
  values (
    v_uid, p_pickup_at, v_req, v_req->>'service',
    coalesce(v_req->>'pickup_address', v_req->>'pickup_name'), coalesce(v_req->>'drop_address', v_req->>'drop_name'),
    (v_req->>'pickup_lat')::double precision, (v_req->>'pickup_lng')::double precision,
    case when jsonb_typeof(v_req->'drop_lat') = 'number' then (v_req->>'drop_lat')::double precision end,
    case when jsonb_typeof(v_req->'drop_lng') = 'number' then (v_req->>'drop_lng')::double precision end,
    case when jsonb_typeof(v_req->'distance_km') = 'number' then (v_req->>'distance_km')::numeric end,
    v_fare, greatest(v_fee, 0), v_req->>'currency', v_name, v_phone)
  returning * into r;
  return r;
end;
$$;
revoke execute on function public.schedule_ride(jsonb, timestamptz) from public, anon;
grant execute on function public.schedule_ride(jsonb, timestamptz) to authenticated;

-- ---- The rider cancels ------------------------------------------------------------------------
create or replace function public.scheduled_ride_cancel(p_id uuid, p_reason text default null)
returns public.scheduled_rides
language plpgsql
security definer
set search_path = public
as $$
declare
  c      jsonb := public.scheduled_rides_config();
  r      public.scheduled_rides;
  ride   public.ride_requests;
  v_late boolean;
  v_fee  numeric := 0;
  v_fee_status text := 'none';
begin
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status not in ('scheduled', 'assigned', 'released') then
    raise exception 'SCHEDULED_CLOSED' using hint = 'This booking can no longer be cancelled.';
  end if;

  if r.ride_id is not null then
    select * into ride from public.ride_requests where id = r.ride_id for update;
    if found and ride.status in ('on_trip', 'completed') then
      raise exception 'SCHEDULED_ON_TRIP' using hint = 'The trip has already started.';
    end if;
    if found and ride.status in ('open', 'accepted', 'arrived') then
      update public.ride_requests
         set status = 'cancelled', cancelled_at = now(), cancel_requested_by = 'rider',
             cancel_reason = left(coalesce(p_reason, 'Scheduled ride cancelled'), 200)
       where id = ride.id;
    end if;
  end if;

  v_late := now() > r.pickup_at - make_interval(mins => (c->>'freeCancelMinutes')::int);
  if v_late and (c->>'lateCancelFee')::numeric > 0 then
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
         cancel_reason = left(p_reason, 200), cancel_fee = v_fee, cancel_fee_status = v_fee_status
   where id = r.id
  returning * into r;

  if r.partner_id is not null then
    perform public.enqueue_notification(r.partner_id, 'sched-cancel-' || r.id, 'scheduled_ride', 'normal',
      'Scheduled ride cancelled',
      'The passenger cancelled the ride booked for ' || to_char(r.pickup_at at time zone 'Asia/Kuala_Lumpur', 'DD Mon, HH24:MI') || '.',
      jsonb_build_object('type', 'scheduled_cancelled', 'scheduled_ride_id', r.id));
  end if;
  return r;
end;
$$;
revoke execute on function public.scheduled_ride_cancel(uuid, text) from public, anon;
grant execute on function public.scheduled_ride_cancel(uuid, text) to authenticated;

-- ---- Drivers, in advance mode -------------------------------------------------------------------
-- What a driver needs to decide, not who the passenger is.
create or replace function public.scheduled_rides_open()
returns table (
  id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
  pickup_lat double precision, pickup_lng double precision, drop_lat double precision, drop_lng double precision,
  distance_km numeric, fare numeric, scheduling_fee numeric, currency text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
   order by s.pickup_at
   limit 100;
$$;
revoke execute on function public.scheduled_rides_open() from public, anon;
grant execute on function public.scheduled_rides_open() to authenticated;

create or replace function public.scheduled_ride_accept(p_id uuid)
returns public.scheduled_rides
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.scheduled_rides;
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if public.scheduled_rides_config()->>'mode' <> 'advance' then
    raise exception 'SCHEDULED_NOT_ADVANCE' using hint = 'Scheduled rides are offered when they are released.';
  end if;
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.status <> 'scheduled' or r.partner_id is not null or r.pickup_at <= now() then
    raise exception 'SCHEDULED_TAKEN' using hint = 'Another driver has taken this ride, or it is no longer open.';
  end if;
  if r.rider_id = v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if exists (select 1 from public.scheduled_rides o
              where o.partner_id = v_uid and o.status in ('assigned', 'released')
                and abs(extract(epoch from o.pickup_at - r.pickup_at)) < 3600) then
    raise exception 'SCHEDULED_CLASH' using hint = 'You already have a ride within an hour of this one.';
  end if;

  update public.scheduled_rides
     set status = 'assigned', partner_id = v_uid, partner_accepted_at = now()
   where id = r.id
  returning * into r;

  perform public.enqueue_notification(r.rider_id, 'sched-assigned-' || r.id || '-' || v_uid, 'scheduled_ride', 'normal',
    'Driver confirmed',
    'A driver has accepted your ride for ' || to_char(r.pickup_at at time zone 'Asia/Kuala_Lumpur', 'DD Mon, HH24:MI') || '.',
    jsonb_build_object('type', 'scheduled_assigned', 'scheduled_ride_id', r.id));
  return r;
end;
$$;
revoke execute on function public.scheduled_ride_accept(uuid) from public, anon;
grant execute on function public.scheduled_ride_accept(uuid) to authenticated;

-- The driver lets go of a booking before it is released: back to the pool.
-- (After release the driver cancels the ride itself; see the trigger below.)
create or replace function public.scheduled_ride_driver_cancel(p_id uuid, p_reason text default null)
returns public.scheduled_rides
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.scheduled_rides;
begin
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.partner_id is distinct from auth.uid() or r.status <> 'assigned' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.scheduled_rides
     set status = 'scheduled', partner_id = null, partner_accepted_at = null
   where id = r.id
  returning * into r;
  perform public.enqueue_notification(r.rider_id, 'sched-driver-left-' || r.id || '-' || now()::text, 'scheduled_ride', 'normal',
    'Finding you a new driver',
    'Your driver can''t make it. Your ride is still booked and we''re finding you another driver.',
    jsonb_build_object('type', 'scheduled_reassigning', 'scheduled_ride_id', r.id));
  return r;
end;
$$;
revoke execute on function public.scheduled_ride_driver_cancel(uuid, text) from public, anon;
grant execute on function public.scheduled_ride_driver_cancel(uuid, text) to authenticated;

-- ---- Release: the booking becomes a ride -------------------------------------------------------
create or replace function public.scheduled_ride_release(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  r      public.scheduled_rides;
  card   record;
  v_json jsonb;
  v_cols text;
  v_ride uuid := gen_random_uuid();
  v_with_driver boolean := false;
begin
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.status not in ('scheduled', 'assigned', 'released') then
    return null;
  end if;

  v_json := r.request || jsonb_build_object(
    'id', v_ride, 'rider_id', r.rider_id, 'scheduled_ride_id', r.id, 'status', 'open', 'created_at', now());

  if r.partner_id is not null then
    select * into card from public.ride_partner_card(r.partner_id);
    if found and card.name is not null then
      v_with_driver := true;
      v_json := v_json || jsonb_build_object(
        'status', 'accepted', 'accepted_at', now(), 'partner_id', r.partner_id,
        'partner_name', card.name, 'partner_phone', card.phone, 'partner_photo', card.photo,
        'partner_rating', card.rating, 'partner_plate', card.plate, 'partner_vehicle', card.vehicle);
    end if;
  end if;

  -- Only the keys that are columns, so every other column keeps its default.
  select string_agg(quote_ident(a.attname), ', ') into v_cols
    from pg_attribute a
   where a.attrelid = 'public.ride_requests'::regclass and a.attnum > 0 and not a.attisdropped
     and v_json ? a.attname;
  execute format('insert into public.ride_requests (%1$s) select %1$s from jsonb_populate_record(null::public.ride_requests, $1)',
                 v_cols) using v_json;

  update public.scheduled_rides
     set status = 'released', ride_id = v_ride, released_at = now(), releases = releases + 1,
         last_error = null,
         partner_id = case when v_with_driver then partner_id end,
         partner_accepted_at = case when v_with_driver then partner_accepted_at end
   where id = r.id;

  if v_with_driver then
    perform public.enqueue_notification(r.rider_id, 'sched-released-' || v_ride, 'scheduled_ride', 'critical',
      'Your driver is on the way', coalesce(card.name, 'Your driver') || ' is coming for your scheduled ride.',
      jsonb_build_object('type', 'scheduled_released', 'scheduled_ride_id', r.id, 'request_id', v_ride), v_ride);
    perform public.enqueue_notification(r.partner_id, 'sched-go-' || v_ride, 'scheduled_ride', 'critical',
      'Scheduled ride: time to go', 'Head to the pickup for the ride you accepted.',
      jsonb_build_object('type', 'scheduled_released', 'scheduled_ride_id', r.id, 'request_id', v_ride), v_ride);
  end if;
  return v_ride;
end;
$$;
revoke execute on function public.scheduled_ride_release(uuid) from public, anon, authenticated;

-- ---- The minute's work -----------------------------------------------------------------------
create or replace function public.scheduled_rides_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.scheduled_rides_config();
  s record;
begin
  -- Reminders.
  if (c->>'reminderMinutes')::int > 0 then
    for s in
      select * from public.scheduled_rides
       where status in ('scheduled', 'assigned') and reminded_at is null and pickup_at > now()
         and pickup_at - make_interval(mins => (c->>'reminderMinutes')::int) <= now()
    loop
      perform public.enqueue_notification(s.rider_id, 'sched-remind-' || s.id, 'scheduled_ride', 'normal',
        'Ride coming up',
        'Your ride is booked for ' || to_char(s.pickup_at at time zone 'Asia/Kuala_Lumpur', 'HH24:MI') ||
        case when s.partner_id is not null then '. Your driver is confirmed.' else '. We''ll find you a driver shortly.' end,
        jsonb_build_object('type', 'scheduled_reminder', 'scheduled_ride_id', s.id));
      update public.scheduled_rides set reminded_at = now() where id = s.id;
    end loop;
  end if;

  -- What became of released rides.
  for s in
    select b.id, b.rider_id, b.pickup_at, b.status, q.status as ride_status, q.cancel_requested_by
      from public.scheduled_rides b join public.ride_requests q on q.id = b.ride_id
     where b.status = 'released' and q.status in ('completed', 'cancelled', 'expired')
  loop
    if s.ride_status = 'completed' then
      update public.scheduled_rides set status = 'completed' where id = s.id;
    elsif s.ride_status = 'cancelled' then
      update public.scheduled_rides
         set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()),
             cancelled_by = coalesce(cancelled_by, case when s.cancel_requested_by = 'rider' then 'rider' else 'system' end)
       where id = s.id;
    elsif now() < s.pickup_at + interval '10 minutes' then
      -- Nobody took it in time: offered again until just after pickup time.
      begin
        perform public.scheduled_ride_release(s.id);
      exception when others then
        update public.scheduled_rides set last_error = left(sqlerrm, 300) where id = s.id;
      end;
    else
      update public.scheduled_rides set status = 'expired' where id = s.id;
      perform public.enqueue_notification(s.rider_id, 'sched-expired-' || s.id, 'scheduled_ride', 'normal',
        'No driver found', 'We couldn''t find a driver for your scheduled ride. You haven''t been charged.',
        jsonb_build_object('type', 'scheduled_expired', 'scheduled_ride_id', s.id));
    end if;
  end loop;

  -- Release what is due.
  for s in
    select id from public.scheduled_rides
     where status in ('scheduled', 'assigned')
       and pickup_at - make_interval(mins => (c->>'releaseMinutes')::int) <= now()
       and pickup_at > now() - interval '10 minutes'
     order by pickup_at
  loop
    begin
      perform public.scheduled_ride_release(s.id);
    exception when others then
      update public.scheduled_rides set last_error = left(sqlerrm, 300) where id = s.id;
    end;
  end loop;

  -- Bookings that could never be released.
  for s in
    select * from public.scheduled_rides
     where status in ('scheduled', 'assigned') and pickup_at <= now() - interval '10 minutes'
  loop
    update public.scheduled_rides set status = 'expired' where id = s.id;
    perform public.enqueue_notification(s.rider_id, 'sched-expired-' || s.id, 'scheduled_ride', 'normal',
      'No driver found', 'We couldn''t arrange your scheduled ride. You haven''t been charged.',
      jsonb_build_object('type', 'scheduled_expired', 'scheduled_ride_id', s.id));
  end loop;
end;
$$;
revoke execute on function public.scheduled_rides_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'scheduled-rides-tick';
    perform cron.schedule('scheduled-rides-tick', '* * * * *', $job$select public.scheduled_rides_tick()$job$);
  end if;
end $$;

-- ---- A driver who cancels a booked ride sends it back to the pool ------------------------------
create or replace function public.ride_requests_scheduled_reopen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.scheduled_ride_id is null or new.status <> 'cancelled' or old.status not in ('accepted', 'arrived')
     or auth.uid() is null or auth.uid() is distinct from old.partner_id then
    return new;
  end if;

  new.status := 'open';
  new.created_at := now();
  new.partner_id := null;
  new.partner_name := null;
  new.partner_phone := null;
  new.partner_photo := null;
  new.partner_rating := null;
  new.partner_plate := null;
  new.partner_vehicle := null;
  new.partner_accept_lat := null;
  new.partner_accept_lng := null;
  new.partner_arrive_lat := null;
  new.partner_arrive_lng := null;
  new.partner_live_lat := null;
  new.partner_live_lng := null;
  new.partner_live_heading := null;
  new.partner_live_at := null;
  new.vehicle_id := null;
  new.offered_fare := null;
  new.accepted_at := null;
  new.arrived_at := null;
  new.cancelled_at := null;
  new.cancel_reason := null;
  new.cancel_requested_by := null;
  new.cancel_requested_at := null;

  -- The driver's row check (they are no longer its partner) passes for this
  -- one ride only; see the policy below.
  perform set_config('getride.scheduled_reopen', old.id::text, true);
  update public.scheduled_rides set partner_id = null, partner_accepted_at = null
   where id = old.scheduled_ride_id;
  perform public.enqueue_notification(old.rider_id, 'sched-reopen-' || old.id || '-' || now()::text, 'scheduled_ride', 'critical',
    'Finding you a new driver',
    'Your driver had to cancel. We''re finding you another driver for your scheduled ride.',
    jsonb_build_object('type', 'scheduled_reassigning', 'scheduled_ride_id', old.scheduled_ride_id, 'request_id', old.id));
  return new;
end;
$$;
revoke execute on function public.ride_requests_scheduled_reopen() from public, anon, authenticated;

-- Last of the BEFORE triggers: the guards have allowed the driver's cancel.
drop trigger if exists trg_ride_requests_z_scheduled_reopen on public.ride_requests;
create trigger trg_ride_requests_z_scheduled_reopen
  before update on public.ride_requests
  for each row execute function public.ride_requests_scheduled_reopen();

drop policy if exists "ride_requests scheduled reopen" on public.ride_requests;
create policy "ride_requests scheduled reopen" on public.ride_requests
  for update to authenticated
  using (partner_id = (select auth.uid()) and scheduled_ride_id is not null)
  with check (scheduled_ride_id is not null and status = 'open' and partner_id is null
              and id::text = (select current_setting('getride.scheduled_reopen', true)));

-- ---- Owed late-cancel fees ride on the next order ------------------------------------------------
create or replace function public.ride_requests_bill_owed_fees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charges jsonb;
  v_owed numeric;
begin
  v_charges := case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end;

  select coalesce(sum(cancel_fee), 0) into v_owed
    from public.scheduled_rides where rider_id = new.rider_id and cancel_fee_status = 'due';
  if v_owed > 0 then
    v_charges := v_charges || jsonb_build_array(jsonb_build_object(
      'kind', 'surcharge', 'name', 'Late cancellation fee (earlier booking)', 'charge', 'fixed',
      'value', round(v_owed, 2), 'platform', true));
    update public.scheduled_rides set cancel_fee_status = 'billed', billed_ride_id = new.id
     where rider_id = new.rider_id and cancel_fee_status = 'due';
  end if;
  new.charges := case when v_charges = '[]'::jsonb and new.charges is null then null else v_charges end;
  return new;
end;
$$;
revoke execute on function public.ride_requests_bill_owed_fees() from public, anon, authenticated;

-- Only the server marks a charge as the platform's. (Not a definer
-- function, so current_user is the caller.)
create or replace function public.ride_requests_strip_platform_charges()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and jsonb_typeof(new.charges) = 'array' then
    select coalesce(jsonb_agg(e - 'platform'), '[]'::jsonb) into new.charges from jsonb_array_elements(new.charges) e;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_strip_platform_charges() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_0_a_strip_platform on public.ride_requests;
create trigger trg_ride_requests_0_a_strip_platform
  before insert on public.ride_requests
  for each row execute function public.ride_requests_strip_platform_charges();

-- Before the fare guard (it only checks amounts on insert) and after the
-- request's own defaults.
drop trigger if exists trg_ride_requests_0_bill_owed on public.ride_requests;
create trigger trg_ride_requests_0_bill_owed
  before insert on public.ride_requests
  for each row execute function public.ride_requests_bill_owed_fees();

-- The ride ends: an owed fee it carried is paid, or owed again if it never ran;
-- on a completed trip the driver gives back the platform's charges.
create or replace function public.ride_requests_settle_platform_fees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric := 0;
begin
  if new.status in ('cancelled', 'expired') and old.status is distinct from new.status then
    update public.scheduled_rides set cancel_fee_status = 'due', billed_ride_id = null
     where billed_ride_id = new.id and cancel_fee_status = 'billed';
    return new;
  end if;
  if new.status <> 'completed' or old.status = 'completed' or new.partner_id is null
     or new.platform_fees_charged_at is not null then
    return new;
  end if;

  update public.scheduled_rides set cancel_fee_status = 'paid'
   where billed_ride_id = new.id and cancel_fee_status = 'billed';

  if jsonb_typeof(new.charges) = 'array' then
    select coalesce(sum(round((e->>'value')::numeric, 2)), 0) into v_total
      from jsonb_array_elements(new.charges) e
     where (e->>'platform')::boolean is true and e->>'charge' = 'fixed'
       and jsonb_typeof(e->'value') = 'number' and (e->>'value')::numeric > 0;
  end if;
  if v_total > 0 then
    -- As with commission, a completion is never held up by this.
    begin
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
      values (new.partner_id, 'get_credit', 'platform_fee', -round(v_total, 2),
              'Platform fees collected on the ride (scheduling / late cancellation)');
      update public.ride_requests set platform_fees_charged_at = now() where id = new.id;
    exception when others then
      raise warning 'ride % platform fees not charged: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_settle_platform_fees() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_platform_fees on public.ride_requests;
create trigger trg_ride_requests_platform_fees
  after update of status on public.ride_requests
  for each row execute function public.ride_requests_settle_platform_fees();

-- The fees are the server's to mark charged.
create or replace function public.ride_requests_guard_platform_fees()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_is_admin()
     and (new.platform_fees_charged_at is distinct from old.platform_fees_charged_at
          or new.scheduled_ride_id is distinct from old.scheduled_ride_id) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_platform_fees() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_guard_platform_fees on public.ride_requests;
create trigger trg_ride_requests_b_guard_platform_fees
  before update on public.ride_requests
  for each row execute function public.ride_requests_guard_platform_fees();

-- The rider's owed fees, for the booking screen ("RM x from an earlier booking").
create or replace function public.my_owed_fees()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(cancel_fee), 0) from public.scheduled_rides
   where rider_id = auth.uid() and cancel_fee_status = 'due';
$$;
revoke execute on function public.my_owed_fees() from public, anon;
grant execute on function public.my_owed_fees() to authenticated;
