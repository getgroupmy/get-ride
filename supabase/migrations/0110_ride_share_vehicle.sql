-- 0110: the shared ride page shows the car's make, model and colour.
--
-- 0108's ride_share_view handed out the driver's free-text vehicle and the
-- plate only. Someone waiting for, or watching over, the passenger needs to
-- recognise the car, so the view now adds the make, model and colour from
-- the driver's registered vehicle (the one carrying the ride's plate), with
-- the partner record's make/model as the fallback. Nothing else changes: no
-- phone numbers, same 24-hour window.

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
    'vehicle_make', coalesce(v.make, p.make),
    'vehicle_model', coalesce(v.model, p.model),
    'vehicle_color', v.color,
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
