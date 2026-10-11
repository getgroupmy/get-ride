-- ============================================================================
-- 0152: the server checks the trip code and starts the trip (Phase D0)
--
-- The 4-digit trip code (ride_requests.otp) was checked inside the driver's
-- app, which reads it off the ride row: a driver could start a trip without
-- the passenger. Now:
--
--   * ride_trip_codes: the code, readable by the ride's rider only (the
--     driver can't select it). Every new ride gets one: the code the rider's
--     app sent, else one made here. Rides already on the go are copied over;
--   * start_trip(request, code): the ride's driver starts the trip; the
--     server checks the code (5 tries per 10 minutes per trip) and records
--     start_method = 'pin' (or 'none' for an old ride with no code). It
--     answers 'on_trip', 'wrong_code' or 'rate_limited:<seconds>';
--   * ride_requests.start_method ('pin' | 'ble' | 'none'), for the audit and
--     the Bluetooth-vs-PIN stats (Phase D2 adds 'ble');
--   * the shared ride page reads the code from ride_trip_codes.
--
-- Builds already installed still read ride_requests.otp and start the trip
-- with a status update, so both stay as they are until Admin → Reliability →
-- "Trip start checked by the server" is turned on (server_trip_start in the
-- reliability-messaging settings row, off by default; turn it on once the App
-- Version gate has every phone on this build). Then the code is no longer
-- written onto the ride row and a client can't set status 'on_trip' itself:
-- only start_trip (and the Bluetooth handshake) can.
-- ============================================================================

alter table public.ride_requests add column if not exists start_method text
  check (start_method is null or start_method in ('pin', 'ble', 'none'));

create table if not exists public.ride_trip_codes (
  request_id uuid primary key
             references public.ride_requests(id) on delete cascade deferrable initially deferred,
  code       text not null check (code ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);

alter table public.ride_trip_codes enable row level security;
drop policy if exists "ride_trip_codes rider read" on public.ride_trip_codes;
create policy "ride_trip_codes rider read" on public.ride_trip_codes
  for select using (exists (
    select 1 from public.ride_requests r where r.id = request_id and r.rider_id = auth.uid()
  ));
revoke all on public.ride_trip_codes from anon, authenticated;
grant select on public.ride_trip_codes to authenticated;

-- ---- Admin → Reliability: is the server-only trip start on? ---------------------
-- Off unless the admin turned it on (unlike the offline switches, which are on
-- unless turned off): it would stop builds older than this one starting trips.
create or replace function public.reliability_server_trip_start()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select (e.values->>'server_trip_start') in ('true', 't', '1', 'on')
      from public.settings_entries e
     where e.id = '72656c69-6162-4c69-8000-000000000001'
  ), false);
$$;
revoke execute on function public.reliability_server_trip_start() from public, anon;
grant execute on function public.reliability_server_trip_start() to authenticated;

-- ---- A new 4-digit code -----------------------------------------------------------
create or replace function public.new_trip_code()
returns text
language sql
volatile
set search_path = public, extensions
as $$
  select lpad((1000 + ((get_byte(b, 0) * 256 + get_byte(b, 1)) % 9000))::text, 4, '0')
    from (select gen_random_bytes(2) as b) x;
$$;
revoke execute on function public.new_trip_code() from public, anon, authenticated;

-- ---- Every new ride gets its code ------------------------------------------------------
create or replace function public.ride_requests_trip_code()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := case when coalesce(new.otp, '') ~ '^[0-9]{4}$' then new.otp else public.new_trip_code() end;
begin
  insert into public.ride_trip_codes (request_id, code) values (new.id, v_code)
  on conflict (request_id) do nothing;
  if public.reliability_server_trip_start() then
    new.otp := null;
  else
    new.otp := v_code;  -- builds before this one still read it here
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_trip_code() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_trip_code on public.ride_requests;
create trigger trg_ride_requests_trip_code before insert on public.ride_requests
  for each row execute function public.ride_requests_trip_code();

-- Rides already on the go keep their code.
insert into public.ride_trip_codes (request_id, code)
select r.id, r.otp
  from public.ride_requests r
 where r.status in ('open', 'accepted', 'arrived') and coalesce(r.otp, '') ~ '^[0-9]{4}$'
on conflict (request_id) do nothing;

-- ---- Once switched on, only the server starts a trip -----------------------------------
-- Not security definer: current_user has to be the caller's role here (a
-- definer function would always see the owner). start_trip runs as the owner
-- and passes; the switch is read through its own definer function.
create or replace function public.ride_requests_guard_trip_start()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated')
     and new.status = 'on_trip' and old.status is distinct from 'on_trip'
     and public.reliability_server_trip_start() then
    raise exception 'use_start_trip' using errcode = '42501',
      hint = 'Start the trip with start_trip.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_trip_start() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_guard_trip_start on public.ride_requests;
create trigger trg_ride_requests_guard_trip_start before update of status on public.ride_requests
  for each row execute function public.ride_requests_guard_trip_start();

-- ---- The driver starts the trip; the server checks the code ------------------------------
create or replace function public.start_trip(p_request uuid, p_code text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_code text;
  v_wait integer;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.partner_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status = 'on_trip' then
    return 'on_trip';  -- already started (a retry after a dropped reply)
  end if;
  if r.status not in ('accepted', 'arrived') then
    raise exception 'wrong_status:%', r.status;
  end if;

  select c.code into v_code from public.ride_trip_codes c where c.request_id = p_request;
  if v_code is not null then
    -- Answered, not raised: an exception would roll back the try just
    -- counted, and the limit would never bite.
    v_wait := public.auth_rate_take('trip_code', p_request::text, 5, interval '10 minutes');
    if v_wait > 0 then
      return 'rate_limited:' || v_wait;
    end if;
    if coalesce(btrim(p_code), '') <> v_code then
      return 'wrong_code';
    end if;
  end if;

  update public.ride_requests
     set status = 'on_trip',
         started_at = now(),
         start_method = case when v_code is null then 'none' else 'pin' end
   where id = p_request;
  return 'on_trip';
end;
$$;
revoke execute on function public.start_trip(uuid, text) from public, anon;
grant execute on function public.start_trip(uuid, text) to authenticated;

-- ---- The shared ride page reads the code from ride_trip_codes ----------------------------
create or replace function public.ride_share_view(p_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'status', r.status,
    'service', r.service,
    'passenger', split_part(coalesce(nullif(trim(r.booked_for_name), ''), nullif(trim(r.rider_name), ''), 'Passenger'), ' ', 1),
    'booked_for_others', r.booked_for_phone is not null,
    -- Who shared it (the rider, first name only), for the page's footer.
    'rider', split_part(coalesce(nullif(trim(r.rider_name), ''), ''), ' ', 1),
    'passengers', r.passengers,
    'pickup_name', r.pickup_name,
    'pickup_address', r.pickup_address,
    'pickup_lat', r.pickup_lat,
    'pickup_lng', r.pickup_lng,
    'drop_name', r.drop_name,
    'drop_address', r.drop_address,
    'drop_lat', r.drop_lat,
    'drop_lng', r.drop_lng,
    'stops', r.stops,
    'distance_km', r.distance_km,
    'duration_min', r.duration_min,
    'fare', coalesce(r.ride_fare, r.fare),
    'currency', r.currency,
    'payment_mode', r.payment_mode,
    'partner_name', r.partner_name,
    'partner_photo', r.partner_photo,
    'partner_vehicle', r.partner_vehicle,
    'partner_plate', r.partner_plate,
    'vehicle_make', coalesce(v.make, p.make),
    'vehicle_model', coalesce(v.model, p.model),
    'vehicle_color', v.color,
    'partner_rating', r.partner_rating,
    'partner_live_lat', r.partner_live_lat,
    'partner_live_lng', r.partner_live_lng,
    'partner_live_heading', r.partner_live_heading,
    'partner_live_at', r.partner_live_at,
    'otp', case when r.booked_for_phone is not null and r.status in ('open', 'accepted', 'arrived') then coalesce((select c.code from public.ride_trip_codes c where c.request_id = r.id), r.otp) end,
    'created_at', r.created_at,
    'accepted_at', r.accepted_at,
    'arrived_at', r.arrived_at,
    'started_at', r.started_at,
    'completed_at', r.completed_at,
    'cancelled_at', r.cancelled_at
  )
  from public.ride_requests r
  -- The driver's partner record, and the car they drive: the one whose plate
  -- the ride carries, else their most recently updated.
  left join lateral (
    select pa.id, pa.make, pa.model
      from public.partners pa
     where r.partner_id is not null and pa.auth_user_id = r.partner_id
     order by pa.updated_at desc
     limit 1
  ) p on true
  left join lateral (
    select ve.make, ve.model, ve.color
      from public.vehicles ve
     where p.id is not null and ve.partner_id = p.id
     order by (upper(regexp_replace(coalesce(ve.plate, ''), '\s', '', 'g'))
               = upper(regexp_replace(coalesce(r.partner_plate, ''), '\s', '', 'g'))) desc,
              ve.updated_at desc
     limit 1
  ) v on true
  where p_token is not null
    and r.share_token = p_token
    and (r.status in ('open', 'accepted', 'arrived', 'on_trip') or r.updated_at > now() - interval '24 hours')
$$;

revoke all on function public.ride_share_view(uuid) from public;
grant execute on function public.ride_share_view(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
