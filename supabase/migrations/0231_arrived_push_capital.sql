-- ============================================================================
-- 0231: "Your driver has arrived" push starts with a capital letter.
--
-- The body is "<plate> is waiting at <pickup>." When the ride has no plate
-- the fallback is "your car", so the sentence read "your car is waiting at
-- …" (tester finding #99). The first letter is now upper-cased there; a
-- plate is already upper case, and "is on the way in your car." keeps its
-- lower case mid-sentence.
--
-- ride_status_messages is otherwise unchanged from 0191 (its latest
-- definition). create or replace keeps its grants.
-- ============================================================================

create or replace function public.ride_status_messages(o ride_requests, n ride_requests, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  out jsonb := '[]'::jsonb;
  v_plate text := coalesce(nullif(btrim(n.partner_plate), ''), 'your car');
  v_driver text := coalesce(nullif(btrim(n.partner_name), ''), 'Your driver');
  v_pickup text := coalesce(nullif(n.pickup_name, ''), nullif(n.pickup_address, ''), 'the pickup');
  v_rider_is_actor boolean := p_actor is not null and p_actor = n.rider_id;
  v_partner_is_actor boolean := p_actor is not null and p_actor = n.partner_id;
  v_ts text;
begin
  if n.status is distinct from o.status then
    if n.status = 'accepted' and n.partner_id is not null then
      if not v_rider_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'rider', 'event', n.id || ':accepted:r', 'priority', 'critical',
          'title', 'Driver assigned',
          'body', v_driver || ' is on the way in ' || v_plate || '.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'accepted', 'role', 'rider')));
      end if;
      if not v_partner_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'partner', 'event', n.id || ':accepted:p', 'priority', 'critical',
          'title', 'Ride confirmed',
          'body', 'Pick up at ' || v_pickup || '.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'accepted', 'role', 'partner')));
      end if;
    elsif n.status = 'arrived' and not v_rider_is_actor then
      out := out || jsonb_build_array(jsonb_build_object(
        'to', 'rider', 'event', n.id || ':arrived:r', 'priority', 'critical',
        'title', 'Your driver has arrived',
        -- Capitalised: the fallback 'your car' starts the sentence here.
        'body', upper(left(v_plate, 1)) || substr(v_plate, 2) || ' is waiting at ' || v_pickup || '.',
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'arrived', 'role', 'rider')));
    elsif n.status = 'on_trip' and not v_rider_is_actor then
      out := out || jsonb_build_array(jsonb_build_object(
        'to', 'rider', 'event', n.id || ':on_trip:r', 'priority', 'normal',
        'title', 'Trip started',
        'body', 'Enjoy your ride. You can share your trip from the app.',
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'on_trip', 'role', 'rider')));
    elsif n.status = 'cancelled' and n.partner_id is not null
          and o.status in ('accepted', 'arrived', 'on_trip') then
      if not v_rider_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'rider', 'event', n.id || ':cancelled:r', 'priority', 'critical',
          'title', 'Trip cancelled',
          'body', 'Your trip was cancelled. Open the app to book again.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'cancelled', 'role', 'rider')));
      end if;
      if not v_partner_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'partner', 'event', n.id || ':cancelled:p', 'priority', 'critical',
          'title', 'Trip cancelled',
          'body', 'The passenger''s trip was cancelled. You are free for the next one.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'cancelled', 'role', 'partner')));
      end if;
    end if;
  elsif n.status in ('accepted', 'arrived', 'on_trip') then
    -- A cancellation asked for: the other side answers it.
    if n.cancel_requested_at is not null and o.cancel_requested_at is null then
      v_ts := extract(epoch from n.cancel_requested_at)::bigint::text;
      out := out || jsonb_build_array(jsonb_build_object(
        'to', case when n.cancel_requested_by = 'rider' then 'partner' else 'rider' end,
        'event', n.id || ':cr:' || v_ts, 'priority', 'critical',
        'title', 'Cancellation requested',
        'body', case when n.cancel_requested_by = 'rider'
                  then 'Your passenger asked to cancel. Open the app to answer.'
                  else 'Your driver asked to cancel. Open the app to answer.' end,
        'data', jsonb_build_object('type', 'ride_cancel_request', 'request_id', n.id,
                                   'role', case when n.cancel_requested_by = 'rider' then 'partner' else 'rider' end)));
    elsif n.cancel_requested_at is null and o.cancel_requested_at is not null then
      v_ts := extract(epoch from o.cancel_requested_at)::bigint::text;
      out := out || jsonb_build_array(jsonb_build_object(
        'to', case when o.cancel_requested_by = 'rider' then 'rider' else 'partner' end,
        'event', n.id || ':cd:' || v_ts, 'priority', 'normal',
        'title', case when n.cancel_request_outcome = 'expired' then 'No answer to your cancellation'
                      else 'Cancellation declined' end,
        'body', case when n.cancel_request_outcome = 'expired'
                     then case when o.cancel_requested_by = 'rider'
                               then 'Your driver didn''t respond. Ask again, contact support, or use SOS.'
                               else 'Your passenger didn''t respond. Ask again or contact support.' end
                     else 'The ride continues.' end,
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', n.status,
                                   'role', case when o.cancel_requested_by = 'rider' then 'rider' else 'partner' end)));
    end if;
  end if;
  return out;
end;
$function$;
