-- ============================================================================
-- 0221 — A ride's driver is only ever the driver who took it
--
-- 1. A rider could create a request already naming a driver (partner_id) —
--    themselves or anybody — and then move it to accepted, arrived and
--    completed. Fake trips counted in statements, earnings, tiers and ride
--    counts; a real driver could be forced into an "accepted" ride.
--    Now, from the apps:
--      * a new request carries no driver and no bid (partner_id and
--        offered_fare are the server's and the driver's);
--      * a driver sets partner_id to themselves only, and never on a ride
--        they booked as the rider;
--    and on every row, by a check, the driver and the rider differ.
--    The server's own writes (scheduled rides, handovers) and admins are as
--    before.
--
-- 2. A scheduled ride is booked by schedule_ride() and released into
--    ride_requests by the minute's job, where the app checks that guard a
--    rider's own insert don't run. The booking kept everything the app sent
--    but a short list of columns, so coin, toll and platform-charge values
--    could be planted. It now keeps only what the booking sheet sends, and
--    no charge the app sends is the platform's. Bookings already waiting are
--    cleaned the same way.
-- ============================================================================

-- ---- 1. The driver's side --------------------------------------------------------------------
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

drop trigger if exists trg_ride_requests_a_guard_claim on public.ride_requests;
create trigger trg_ride_requests_a_guard_claim
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_partner_claim();

-- No ride, however written, has the same person on both sides (none does today).
alter table public.ride_requests drop constraint if exists ride_requests_sides_differ;
alter table public.ride_requests
  add constraint ride_requests_sides_differ check (partner_id is null or partner_id <> rider_id) not valid;
alter table public.ride_requests validate constraint ride_requests_sides_differ;

-- ---- 2. What a scheduled booking keeps -------------------------------------------------------
-- The columns the booking sheet sends (RideRepository.request), and no
-- other; no charge is the platform's but the scheduling fee the server adds
-- ([p_fee], kept when it is already there).
create or replace function public.scheduled_request_clean(p_request jsonb, p_fee numeric default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce((
    select jsonb_object_agg(e.key,
      case when e.key = 'charges' then (
        select coalesce(jsonb_agg(
          case when p_fee is not null and c->>'name' = 'Scheduling fee' and c->'value' = to_jsonb(p_fee)
                    and c->>'kind' = 'surcharge'
               then c else c - 'platform' end), '[]'::jsonb)
          from jsonb_array_elements(e.value) c
         where jsonb_typeof(c) = 'object')
      else e.value end)
      from jsonb_each(coalesce(p_request, '{}'::jsonb)) e
     where e.key = any (array[
       'rider_name', 'rider_phone', 'rider_photo', 'service', 'payment_mode',
       'pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng',
       'drop_name', 'drop_address', 'drop_lat', 'drop_lng', 'stops',
       'distance_km', 'duration_min', 'fare', 'ride_fare', 'currency',
       'passengers', 'luggage', 'note', 'offer_me', 'otp', 'device_os',
       'user_accept_lat', 'user_accept_lng', 'booked_for_name', 'booked_for_phone',
       'country', 'state', 'city', 'suburb', 'full_address', 'ip_address', 'gender',
       'whole_fare', 'tax_name', 'tax_kind', 'tax_value', 'charges', 'timezone'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

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

  -- Only what the booking sheet sends; the release skips the app's checks.
  v_req := public.scheduled_request_clean(v_req);

  v_fee := round((c->>'feeFixed')::numeric + v_fare * (c->>'feePercent')::numeric / 100, 2);
  if v_fee > 0 then
    v_req := jsonb_set(v_req, '{charges}',
      coalesce(v_req->'charges', '[]'::jsonb)
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

-- Bookings still to be released are cleaned the same way, their own fee kept.
update public.scheduled_rides
   set request = public.scheduled_request_clean(request, nullif(scheduling_fee, 0))
 where status in ('scheduled', 'assigned')
   and request is distinct from public.scheduled_request_clean(request, nullif(scheduling_fee, 0));
