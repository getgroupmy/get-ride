-- 0108: share a ride with a link.
--
-- The rider can send anyone a link (getride.my/share/<token>) that shows the
-- ride read-only: where it is going, the driver and car, the driver's live
-- position on a map, the fare and how far along it is. The person opening it
-- doesn't need an account, so the page reads through one SECURITY DEFINER
-- function that hands out exactly that view and nothing else:
--
--   * no phone numbers (the rider's, the passenger's or the driver's),
--   * the trip code only on a ride booked for someone else (0107) and only
--     until the trip starts: that passenger has no app to read it from, and
--     the driver asks for it at pickup,
--   * only while the ride is on the go, and for 24 hours after it ends.
--
-- The token is random (gen_random_uuid) and made on first share; only the
-- ride's rider can make one.

alter table public.ride_requests
  add column if not exists share_token uuid,
  -- Also added by 0107 (book for others); repeated so this stands alone.
  add column if not exists booked_for_name text,
  add column if not exists booked_for_phone text;

create unique index if not exists ride_requests_share_token_key
  on public.ride_requests (share_token) where share_token is not null;

create or replace function public.ride_share_link(p_ride uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  token uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.ride_requests
     set share_token = coalesce(share_token, gen_random_uuid())
   where id = p_ride and rider_id = auth.uid()
  returning share_token into token;
  if token is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return token;
end;
$$;

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
    'partner_rating', r.partner_rating,
    'partner_live_lat', r.partner_live_lat,
    'partner_live_lng', r.partner_live_lng,
    'partner_live_heading', r.partner_live_heading,
    'partner_live_at', r.partner_live_at,
    'otp', case when r.booked_for_phone is not null and r.status in ('open', 'accepted', 'arrived') then r.otp end,
    'created_at', r.created_at,
    'accepted_at', r.accepted_at,
    'arrived_at', r.arrived_at,
    'started_at', r.started_at,
    'completed_at', r.completed_at,
    'cancelled_at', r.cancelled_at
  )
  from public.ride_requests r
  where p_token is not null
    and r.share_token = p_token
    and (r.status in ('open', 'accepted', 'arrived', 'on_trip') or r.updated_at > now() - interval '24 hours')
$$;

revoke all on function public.ride_share_link(uuid) from public;
revoke execute on function public.ride_share_link(uuid) from anon;
grant execute on function public.ride_share_link(uuid) to authenticated;

revoke all on function public.ride_share_view(uuid) from public;
grant execute on function public.ride_share_view(uuid) to anon, authenticated;
