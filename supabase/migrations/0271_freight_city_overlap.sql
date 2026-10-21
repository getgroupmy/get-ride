-- ============================================================================
-- 0271 — Freight and the city ride rules: one set of fees, the whole owed
-- total, and offers only from drivers who may take the request.
--
-- Applied by hand as version 20261021032900 (0271_freight_city_overlap in
-- supabase_migrations.schema_migrations). Re-runnable: every function is
-- "create or replace". 0268 and 0270 belong to other branches; the numbers
-- only have to be unique (check-migration-numbers.sh), gaps are fine.
--
-- 0267 (Freight) and 0269 (City ride) were written side by side and overlap:
--
-- 1. Double fee. A sender cancelling a freight trip after the driver
--    arrived owed 0267's per-place 'freight-cancel-arrived' fee AND 0269's
--    city arrivedFee (RM 5 by default); 0269's late-cancel and no-show fees
--    reached freight trips too. Now a freight request pays only the freight
--    fees:
--    * ride_request_is_freight(ride): a freight Vehicle Service (0267's
--      vehicle_service_is_freight, the Service types check) or a request
--      with cargo (what 0267's trip trigger and the app's isFreight read).
--    * ride_requests_city_cancel_fee (the trigger's function) charges no
--      city fee on one;
--    * ride_no_show still ends it as a no-show, with no fee (freight has
--      none);
--    * ride_cancel_terms gives it no city fee (freeMinutes, lateFee,
--      arrivedFee and noShowFee 0) and says what the freight one is:
--      'freight' true and 'freightArrivedFee', the fee 0267 bills when the
--      sender cancels after the driver arrived. The rider app shows that
--      (lib/src/core/city_cancel.dart); an older app shows "Free to cancel".
-- 2. my_owed_fees (0267's) adds 0269's rider_fee_dues still due, beside the
--    scheduled-ride and freight cancel fees, so the rider sees the whole
--    total.
-- 3. ride_offer_make (0269) checks what the pushes and dispatch check
--    (0263, 0267) before the offer is made: the driver's Services
--    (DRIVER_SERVICE_OFF) and, for freight, a freight vehicle at least that
--    size (FREIGHT_DRIVER_NO_FREIGHT) with the goods-vehicle permit the
--    size asks for (FREIGHT_GOODS_PERMIT_REQUIRED). A car driver could
--    otherwise send an offer on a freight request through the RPC.
-- ============================================================================

-- ---- 1. One set of fees for freight -------------------------------------------------------------
-- Whether a ride request is freight: its service is a freight Vehicle
-- Service (0267), or it carries cargo (0267's trip trigger, the app).
create or replace function public.ride_request_is_freight(r public.ride_requests)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select r.cargo_description is not null or coalesce(public.vehicle_service_is_freight(r.service), false);
$$;
revoke execute on function public.ride_request_is_freight(public.ride_requests) from public, anon, authenticated;
grant execute on function public.ride_request_is_freight(public.ride_requests) to service_role;

-- As 0269, with no city fee on a freight request (0267 bills its own).
create or replace function public.ride_requests_city_cancel_fee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text;
  v_fee numeric;
  v_at timestamptz := coalesce(old.cancel_requested_at, new.cancel_requested_at, new.cancelled_at, now());
  v_rules jsonb;
begin
  if new.cancel_fee_status is not null then
    return null;
  end if;
  if new.cancel_reason = 'passenger_no_show' then
    return null;  -- ride_no_show charges its own fee
  end if;
  if public.ride_request_is_freight(new) then
    return null;  -- freight: only 0267's freight-cancel-arrived fee
  end if;
  if coalesce(new.cancel_requested_by, '') <> 'rider' and auth.uid() is distinct from old.rider_id then
    return null;
  end if;
  v_rules := public.ride_cancel_rules_for(new);
  v_fee := public.ride_cancel_fee(v_rules, old.accepted_at, old.arrived_at, v_at, new.cancel_reason);
  v_kind := case when old.arrived_at is not null and v_at >= old.arrived_at then 'arrived_cancel' else 'late_cancel' end;
  update public.ride_requests
     set cancel_fee = v_fee,
         cancel_fee_status = case when v_fee > 0 then public.ride_fee_take(new, v_fee, v_kind) else 'none' end
   where id = new.id;
  return null;
end;
$$;
revoke execute on function public.ride_requests_city_cancel_fee() from public, anon, authenticated;

-- As 0269; a freight request has no city fee, and says what its own is.
create or replace function public.ride_cancel_terms(p_ride uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.ride_requests;
  v jsonb;
  v_freight boolean;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or auth.uid() is null or auth.uid() not in (r.rider_id, r.partner_id) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v := public.ride_cancel_rules_for(r);
  v_freight := public.ride_request_is_freight(r);
  if v_freight then
    v := v || jsonb_build_object('freeMinutes', 0, 'lateFee', 0, 'arrivedFee', 0, 'noShowFee', 0);
  end if;
  return v || jsonb_build_object(
    'currency', r.currency,
    'freeUntil', r.accepted_at + make_interval(secs => (v->>'freeMinutes')::numeric * 60),
    'noShowAt', r.arrived_at + make_interval(secs => (v->>'noShowMinutes')::numeric * 60),
    'scheduled', r.scheduled_ride_id is not null,
    'freight', v_freight,
    -- What 0267's trip trigger bills (a request with cargo) when the sender
    -- cancels after the driver arrived.
    'freightArrivedFee', case when v_freight and r.cargo_description is not null
                              then public.freight_place_value(public.freight_charges_at(r), 'freight-cancel-arrived')
                              else 0 end);
end;
$$;
revoke execute on function public.ride_cancel_terms(uuid) from public, anon;
grant execute on function public.ride_cancel_terms(uuid) to authenticated;

-- As 0269, with no no-show fee on a freight request.
create or replace function public.ride_no_show(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v jsonb;
  v_fee numeric;
  v_status text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.partner_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'arrived' or r.arrived_at is null then
    raise exception 'NO_SHOW_NOT_ARRIVED' using errcode = 'P0001', hint = 'Tap Arrived at the pickup first.';
  end if;
  v := public.ride_cancel_rules_for(r);
  if now() < r.arrived_at + make_interval(secs => (v->>'noShowMinutes')::numeric * 60) then
    raise exception 'NO_SHOW_TOO_EARLY' using errcode = 'P0001',
      hint = 'Wait ' || (v->>'noShowMinutes') || ' minutes at the pickup first.';
  end if;
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'passenger_no_show',
         cancel_requested_by = 'partner', cancel_requested_at = now()
   where id = p_ride
  returning * into r;
  v_fee := case when public.ride_request_is_freight(r) then 0
                else round(coalesce((v->>'noShowFee')::numeric, 0), 2) end;
  v_status := case when v_fee > 0 and r.scheduled_ride_id is null then public.ride_fee_take(r, v_fee, 'no_show')
                   else 'none' end;
  update public.ride_requests set cancel_fee = case when v_status = 'none' then 0 else v_fee end,
                                  cancel_fee_status = v_status
   where id = p_ride
  returning * into r;
  perform public.enqueue_notification(
    r.rider_id, r.id || ':no_show', 'ride_status', 'normal',
    'Your driver couldn''t find you',
    case when v_status = 'none' then 'They waited at the pickup and ended the ride.'
         else 'They waited at the pickup and ended the ride. A no-show fee of ' || coalesce(r.currency, 'RM') || ' '
              || to_char(v_fee, 'FM999990.00') || ' applies.' end,
    jsonb_build_object('type', 'ride_status', 'request_id', r.id, 'status', 'cancelled'), r.id);
  return to_jsonb(r);
end;
$$;
revoke execute on function public.ride_no_show(uuid) from public, anon;
grant execute on function public.ride_no_show(uuid) to authenticated;

-- ---- 2. The whole owed total ----------------------------------------------------------------------
-- As 0267, with 0269's city fees a short wallet left due.
create or replace function public.my_owed_fees()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select sum(cancel_fee) from public.scheduled_rides
                    where rider_id = auth.uid() and cancel_fee_status = 'due'), 0)
       + coalesce((select sum(freight_cancel_fee) from public.ride_requests
                    where rider_id = auth.uid() and freight_cancel_fee_status = 'due'), 0)
       + coalesce((select sum(amount) from public.rider_fee_dues
                    where rider_id = auth.uid() and status = 'due'), 0);
$$;
revoke execute on function public.my_owed_fees() from public, anon;
grant execute on function public.my_owed_fees() to authenticated;

-- ---- 3. Offers only from drivers who may take the request ----------------------------------------
-- As 0269, with the checks of the pushes and dispatch (0263's Services,
-- 0267's freight vehicle and goods-vehicle permit) after the partner type's.
create or replace function public.ride_offer_make(p_request uuid, p_amount numeric, p_eta_min int default null,
                                                 p_lat double precision default null,
                                                 p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  c jsonb := public.city_ride_config()->'offers';
  r public.ride_requests;
  card record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_declines int;
  v_paused timestamptz;
  o public.ride_offers;
  l public.driver_service_locks;
  v_mine text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.status <> 'open' then
    raise exception 'OFFER_REQUEST_CLOSED' using errcode = 'P0001', hint = 'This request is no longer open.';
  end if;
  if r.rider_id = v_uid then
    raise exception 'RIDE_CLAIM_OWN_RIDE' using errcode = '42501', hint = 'You can''t take a ride you booked.';
  end if;
  if not public.caller_is_approved_partner() then
    raise exception 'RIDE_CLAIM_REQUIRES_APPROVED_PARTNER' using errcode = '42501',
      hint = 'Only partners approved by an administrator can accept or bid on rides.';
  end if;
  if not public.ptr_caller_available_at(r.pickup_lat, r.pickup_lng) then
    raise exception 'RIDE_TYPE_NOT_AVAILABLE' using errcode = '42501',
      hint = 'Your partner type is not offered where this ride starts.';
  end if;
  if not public.driver_takes_service(v_uid, r.service) then
    l := public.driver_service_lock(v_uid, public.driver_session_vehicle(v_uid), r.service);
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = case when l.id is not null
                  then format('get.ride keeps %s off for you. Contact support to change it.', r.service)
                  else format('You turned %s off in Services. Turn it on to take these requests.', r.service) end;
  end if;
  if not public.driver_takes_freight(v_uid, r.service) then
    v_mine := public.driver_vehicle_service(v_uid);
    if v_mine is not null and v_mine = any (public.freight_service_ids())
       and public.service_order_allows(v_mine, r.service) then
      raise exception 'FREIGHT_GOODS_PERMIT_REQUIRED' using errcode = '42501',
        hint = 'This Freight size needs an approved goods-vehicle permit on your vehicle.';
    end if;
    raise exception 'FREIGHT_DRIVER_NO_FREIGHT' using errcode = '42501',
      hint = 'Your vehicle doesn''t take this Freight request.';
  end if;
  v_paused := public.driver_offers_paused_until(v_uid);
  if v_paused is not null then
    raise exception 'OFFERS_PAUSED' using errcode = 'P0001',
      hint = 'You cancelled too many rides this week. You can send offers again at '
             || to_char(v_paused at time zone coalesce(r.timezone, 'Asia/Kuala_Lumpur'), 'HH24:MI') || '.';
  end if;
  if v_amount < round(coalesce(r.ride_fare, r.fare, 0), 2) or v_amount > round(coalesce(r.ride_fare, r.fare, 0) * 4, 2)
     or v_amount <= 0 then
    raise exception 'OFFER_AMOUNT' using errcode = '22023',
      hint = 'Offer the rider''s fare or more, up to 4 times it.';
  end if;
  select count(*) into v_declines from public.ride_offers x
   where x.request_id = p_request and x.partner_id = v_uid and x.status = 'declined';
  if v_declines > (case when (c->>'reofferAfterDecline')::boolean then 1 else 0 end) then
    raise exception 'OFFER_DECLINED' using errcode = 'P0001', hint = 'The rider declined your offer.';
  end if;
  if public.auth_rate_take('ride_offer', p_request::text || ':' || v_uid::text, 10, interval '1 hour') > 0 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;

  -- Their earlier open offer gives way to this one.
  update public.ride_offers set status = 'withdrawn', closed_reason = 'replaced', closed_at = now()
   where request_id = p_request and partner_id = v_uid and status = 'open';

  select * into card from public.ride_partner_card(v_uid);
  insert into public.ride_offers (request_id, partner_id, amount, eta_min, from_lat, from_lng, partner_name,
                                  partner_photo, partner_rating, partner_trips, partner_vehicle, partner_plate,
                                  expires_at)
  values (p_request, v_uid, v_amount, case when p_eta_min between 0 and 240 then p_eta_min end, p_lat, p_lng,
          card.name, card.photo, card.rating, card.trips, card.vehicle, card.plate,
          clock_timestamp() + make_interval(secs => (c->>'lifetimeSeconds')::int))
  returning * into o;

  perform public.ride_offers_mirror(p_request);
  -- The vehicle session's plate and car, and their colours (0254, 0260),
  -- as stamped on the row by its own triggers.
  update public.ride_offers x
     set partner_plate = coalesce(q.partner_plate, x.partner_plate),
         partner_vehicle = coalesce(q.partner_vehicle, x.partner_vehicle),
         partner_plate_colours = q.partner_plate_colours
    from public.ride_requests q
   where x.id = o.id and q.id = p_request and q.partner_id = v_uid
  returning x.* into o;
  select * into o from public.ride_offers where id = o.id;
  return to_jsonb(o);
end;
$$;
revoke execute on function public.ride_offer_make(uuid, numeric, int, double precision, double precision)
  from public, anon;
grant execute on function public.ride_offer_make(uuid, numeric, int, double precision, double precision)
  to authenticated;

notify pgrst, 'reload schema';
