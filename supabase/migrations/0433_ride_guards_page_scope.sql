-- ============================================================================
-- 0433 — Who may change the server's side of a ride request.
--
-- A ride request (public.ride_requests) is written by its rider and by its
-- driver, each within rules: what a new request may hold, who takes it, the
-- path its status follows, and the columns that are the server's (the fare
-- once it is agreed, payment, commission, charges and fees, the promo and
-- GET.Plus amounts, the driver's card, the My Ride and myGiG terms).
--
-- Through the API with the apps' roles (anon, authenticated), those rules
-- hold for everybody but the back office: an admin who may edit rides. That
-- is the test the table's admin policies make,
-- public.caller_admin_can_write('ride_requests') (0223): a full admin, or an
-- EDIT grant on a page that writes rides. Everybody else is held to the
-- rules on every ride they can reach, the ones they book and drive included.
-- ride_requests_guard_client_columns and ride_requests_guard_driver_cancel
-- (0223) and the guards written since ask this way already; the sixteen
-- below now do too.
--
-- Who the rider of a ride is (ride_requests_protect_rider, last of all) is
-- changed by an admin who may edit rides, and by the account link
-- (admin_link_account, 0194): an admin who may edit users moving a deleted
-- account's rides to the person's new account. Nobody else changes it, in
-- the apps or through a function.
--
-- As before:
--   * The server's own writes are not checked: the service role, migrations,
--     cron, the SQL editor and, for the sixteen, functions that run as their
--     owner.
--   * What a rider and a driver do with their rides.
--   * The rules themselves. Each of the sixteen is its latest definition (the
--     migration is named above it) with that one test changed. Triggers,
--     owners and grants are untouched. Every name in the bodies was already
--     written in full, so each now runs with an empty search_path.
--
-- supabase/tests/ride_guards_page_scope_0433.sql covers it.
-- ============================================================================

-- As 0245: a new request names no driver; a driver takes a ride for
-- themselves, approved, where their type is offered, and never their own.
create or replace function public.ride_requests_guard_partner_claim()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.partner_id is not null or new.offered_fare is not null then
      raise exception 'RIDE_PARTNER_SERVER_ONLY' using errcode = '42501',
        hint = 'A new request is offered to drivers; it can''t name one.';
    end if;
    return new;
  end if;
  if new.partner_id is null and old.partner_id is not null and old.status is distinct from 'open' then
    raise exception 'RIDE_DRIVER_KEPT' using errcode = '42501',
      hint = 'A ride that was taken keeps its driver; cancel it instead.';
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
    if not public.ptr_caller_available_at(new.pickup_lat, new.pickup_lng) then
      raise exception 'RIDE_TYPE_NOT_AVAILABLE' using errcode = '42501',
        hint = 'Your partner type is not offered where this ride starts.';
    end if;
  end if;
  return new;
end;
$$;

-- As 0222: a driver takes a ride with enough GET.credit.
create or replace function public.ride_requests_guard_credit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.partner_id is null
     or (tg_op = 'UPDATE' and new.partner_id is not distinct from old.partner_id)
     or current_user not in ('anon', 'authenticated')
     or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if auth.uid() is distinct from new.partner_id then
    -- 0221 lets only the driver themselves take a ride.
    raise exception 'DRIVER_UNAVAILABLE' using errcode = 'P0001',
      hint = 'This driver can''t take trips right now. Please book another driver.';
  end if;
  if not public.commission_credit_ok_self() then
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = case when public.commission_credit_floor() = 0
                  then 'Your GET.credit is below zero. Top up to take trips again.'
                  else 'Your GET.credit is below RM ' || to_char(public.commission_credit_floor(), 'FM999990.00')
                       || '. Top up to take trips again.' end;
  end if;
  return new;
end;
$$;

-- As 0326: one request on the go for a rider and a passenger.
create or replace function public.ride_requests_one_active_request()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  phone text := nullif(regexp_replace(coalesce(new.booked_for_phone,
    (select p.booked_for_phone from public.ride_request_private p where p.request_id = new.id), ''), '\D', '', 'g'), '');
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if new.rider_id is null or new.status is distinct from 'open' then
    return new;
  end if;
  -- Two taps land as two transactions: the second waits for the first.
  perform pg_advisory_xact_lock(hashtextextended('ride_request:' || new.rider_id::text, 0));
  if exists (
    select 1
      from public.ride_requests r
      left join public.ride_request_private p on p.request_id = r.id
     where r.rider_id = new.rider_id
       and r.id is distinct from new.id
       and (
         (r.status = 'open' and r.created_at > now() - interval '7 minutes')
         or (r.status in ('accepted', 'arrived', 'on_trip')
             and (r.updated_at > now() - interval '12 hours'
                  -- 0326: a hire until its end (and the auto-end after it).
                  or (r.hire_package is not null and public.hire_active_until(r) > now())))
       )
       and (
         (phone is null and coalesce(r.booked_for_phone, p.booked_for_phone) is null)
         or (phone is not null
             and regexp_replace(coalesce(r.booked_for_phone, p.booked_for_phone, ''), '\D', '', 'g') = phone)
       )
  ) then
    raise exception 'RIDE_REQUEST_DUPLICATE' using errcode = 'P0001',
      hint = case when phone is null
        then 'You already have a ride request on the go.'
        else 'You already have a ride on the go for this passenger.' end;
  end if;
  return new;
end;
$$;

-- As 0101: tolls and other charges are the driver's; fare coins the server's.
create or replace function public.ride_requests_guard_charges()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if coalesce(new.toll_charges, 0) <> 0
       or coalesce(new.other_charges, 0) <> 0
       or new.other_charges_note is not null then
      raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
        hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
    end if;
    if new.fare_coins_value is not null or new.fare_coins_used is not null then
      raise exception 'RIDE_FARE_COINS_SERVER_ONLY' using errcode = '42501';
    end if;
    return new;
  end if;
  if (new.toll_charges, new.other_charges, new.other_charges_note)
       is distinct from (old.toll_charges, old.other_charges, old.other_charges_note)
     and (old.partner_id is null or old.partner_id is distinct from auth.uid()) then
    raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
      hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
  end if;
  if (new.fare_coins_value, new.fare_coins_used) is distinct from (old.fare_coins_value, old.fare_coins_used) then
    raise exception 'RIDE_FARE_COINS_SERVER_ONLY' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- As 0314: the waiting charge.
create or replace function public.ride_requests_guard_city_extras()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if num_nonnulls(new.waiting_from, new.waiting_terms, new.waiting_minutes, new.waiting_charge) > 0 then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'The waiting charge is the server''s.';
    end if;
    return new;
  end if;
  if (new.waiting_from, new.waiting_terms, new.waiting_minutes, new.waiting_charge)
     is distinct from (old.waiting_from, old.waiting_terms, old.waiting_minutes, old.waiting_charge) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'The waiting charge is the server''s.';
  end if;
  return new;
end;
$$;

-- As 0174: a request starts open and follows the trip's path; the fare and
-- the server's stamps.
create or replace function public.ride_requests_guard_fare()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_is_rider  boolean;
  v_old_fare  numeric;
  v_new_fare  numeric;
  v_fare_changed boolean;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;

  if not (public.ride_money_ok(new.fare) and public.ride_money_ok(new.ride_fare)
          and public.ride_money_ok(new.offered_fare) and public.ride_money_ok(new.auto_accept_fare)) then
    raise exception 'RIDE_FARE_INVALID' using errcode = '22023';
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'open' then
      raise exception 'RIDE_STATUS_TRANSITION' using errcode = '42501',
        hint = 'A ride request starts open.';
    end if;
    if new.payment_status is not null or new.paid_method is not null
       or new.paid_amount is not null or new.paid_at is not null
       or new.commission_rate is not null or new.commission_amount is not null
       or new.commission_charged_at is not null or new.coin_rewarded_at is not null
       or new.fare_coins_redeemed_at is not null then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
    end if;
    return new;
  end if;

  -- Stamps only the server writes.
  if (new.commission_rate, new.commission_amount, new.commission_charged_at,
      new.coin_rewarded_at, new.fare_coins_redeemed_at)
     is distinct from
     (old.commission_rate, old.commission_amount, old.commission_charged_at,
      old.coin_rewarded_at, old.fare_coins_redeemed_at) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
  end if;

  v_is_rider := v_uid is not null and v_uid = old.rider_id;

  -- The status, along the trip's own path.
  if new.status is distinct from old.status then
    if not (
         (old.status = 'open' and new.status = 'accepted'
            and ((v_is_rider and old.partner_id is not null and new.partner_id = old.partner_id)
                 or (not v_is_rider and v_uid is not null and new.partner_id = v_uid)))
      or (old.status = 'open' and new.status in ('cancelled', 'expired') and v_is_rider)
      or (old.status = 'accepted' and new.status = 'arrived' and v_uid = old.partner_id)
      or (old.status in ('accepted', 'arrived') and new.status = 'on_trip' and v_uid = old.partner_id)
      or (old.status in ('accepted', 'arrived', 'on_trip') and new.status = 'cancelled'
            and (v_is_rider or v_uid = old.partner_id))
      or (old.status = 'on_trip' and new.status = 'completed' and v_uid = old.partner_id)
    ) then
      raise exception 'RIDE_STATUS_TRANSITION' using errcode = '42501',
        hint = format('A ride can''t go from %s to %s here.', old.status, new.status);
    end if;
  end if;

  -- The pricing a ride was booked with is fixed once it is written.
  if (new.currency, new.whole_fare, new.tax_name, new.tax_kind, new.tax_value, new.charges)
     is distinct from
     (old.currency, old.whole_fare, old.tax_name, old.tax_kind, old.tax_value, old.charges) then
    raise exception 'RIDE_FARE_LOCKED' using errcode = '42501';
  end if;

  if old.status <> 'open'
     and (new.offered_fare, new.auto_accept_fare) is distinct from (old.offered_fare, old.auto_accept_fare) then
    raise exception 'RIDE_FARE_LOCKED' using errcode = '42501';
  end if;

  v_fare_changed := (new.fare, new.ride_fare) is distinct from (old.fare, old.ride_fare);
  v_old_fare := round(coalesce(old.ride_fare, old.fare, 0), 2);
  v_new_fare := round(coalesce(new.ride_fare, new.fare, 0), 2);

  if old.status = 'open' and new.status = 'accepted' then
    if v_is_rider then
      -- Taking an offer: billed at exactly that offer.
      if old.offered_fare is null
         or round(new.fare, 2) is distinct from round(old.offered_fare, 2)
         or v_new_fare <> round(old.offered_fare, 2) then
        raise exception 'RIDE_FARE_LOCKED' using errcode = '42501',
          hint = 'Accept the offer at the amount offered.';
      end if;
    elsif v_fare_changed then
      -- A partner's claim keeps the rider's fare, unless the rider's own
      -- auto-accept amount took the partner's offer (0141).
      if not (old.auto_accept_fare is not null and new.offered_fare is not null
              and new.offered_fare <= old.auto_accept_fare + 0.005
              and round(new.fare, 2) = round(new.offered_fare, 2)
              and v_new_fare = round(new.offered_fare, 2)) then
        raise exception 'RIDE_FARE_LOCKED' using errcode = '42501';
      end if;
    end if;
    return new;
  end if;

  if not v_fare_changed then
    return new;
  end if;

  -- The rider prices their own open request.
  if old.status = 'open' and new.status = 'open' and v_is_rider then
    return new;
  end if;

  -- Ending early: the partner may lower the fare stored on the ride, never
  -- raise it, and the booked fare stays as it was.
  if old.status = 'on_trip' and new.status = 'completed' and v_uid = old.partner_id
     and new.fare is not distinct from old.fare
     and new.ride_fare is not null and round(new.ride_fare, 2) > 0
     and round(new.ride_fare, 2) <= v_old_fare then
    return new;
  end if;

  raise exception 'RIDE_FARE_LOCKED' using errcode = '42501',
    hint = 'The fare is fixed once a driver has accepted the ride.';
end;
$$;

-- As 0142: payment.
create or replace function public.ride_requests_guard_payment()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('ride_requests')
     and (new.payment_status, new.paid_method, new.paid_amount, new.paid_at)
         is distinct from (old.payment_status, old.paid_method, old.paid_amount, old.paid_at) then
    raise exception 'RIDE_PAYMENT_SERVER_ONLY' using errcode = '42501';
  end if;
  if new.status = 'completed' and old.status is distinct from 'completed' and new.payment_status is null then
    new.payment_status := 'due';
  end if;
  return new;
end;
$$;

-- As 0189: when platform fees were charged, and the booking a ride came from.
create or replace function public.ride_requests_guard_platform_fees()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('ride_requests')
     and (new.platform_fees_charged_at is distinct from old.platform_fees_charged_at
          or new.scheduled_ride_id is distinct from old.scheduled_ride_id) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- As 0314: the bags.
create or replace function public.ride_requests_luggage_fixed()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if new.luggage is distinct from old.luggage then
    raise exception 'RIDE_LUGGAGE_FIXED' using errcode = '42501',
      hint = 'The bags are set when the ride is booked.';
  end if;
  return new;
end;
$$;

-- As 0329: a myGiG ride's terms.
create or replace function public.ride_requests_mygig_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.mygig is not null then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'A myGiG ride is made by the server.';
    end if;
    return new;
  end if;
  if new.mygig is distinct from old.mygig then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'A myGiG ride''s terms are the server''s.';
  end if;
  if old.mygig is not null and (new.fare, new.ride_fare, new.tax_value, new.payment_mode, new.rider_id)
       is distinct from (old.fare, old.ride_fare, old.tax_value, old.payment_mode, old.rider_id) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'A myGiG ride''s price was agreed with the passenger.';
  end if;
  -- Start, no-show and completion go through the myGiG functions.
  if old.mygig is not null and new.status is distinct from old.status and new.status in ('on_trip', 'completed') then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'Use the myGiG trip buttons.';
  end if;
  -- The passenger cancels before the trip with mygig_cancel_ride (the agreed fee terms).
  if old.mygig is not null and new.status = 'cancelled' and old.status in ('accepted', 'arrived')
     and auth.uid() is not distinct from old.rider_id then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'Cancel this myGiG ride from its trip screen.';
  end if;
  return new;
end;
$$;

-- As 0191: how a cancellation request ended.
create or replace function public.ride_requests_cancel_outcome()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.cancel_requested_at is not null and new.cancel_requested_at is distinct from old.cancel_requested_at then
    -- Asked (again): no outcome yet.
    new.cancel_request_outcome := null;
    new.cancel_request_outcome_by := null;
    new.cancel_request_outcome_at := null;
  elsif old.cancel_requested_at is not null and new.cancel_requested_at is null
        and new.status = old.status and new.status in ('accepted', 'arrived', 'on_trip') then
    -- Taken back without the ride ending: lapsed (the server's job) or declined.
    new.cancel_request_outcome := case when current_setting('getride.cancel_lapsing', true) = '1'
                                       then 'expired' else 'declined' end;
    new.cancel_request_outcome_by := old.cancel_requested_by;
    new.cancel_request_outcome_at := now();
  elsif current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('ride_requests') then
    new.cancel_request_outcome := old.cancel_request_outcome;
    new.cancel_request_outcome_by := old.cancel_request_outcome_by;
    new.cancel_request_outcome_at := old.cancel_request_outcome_at;
    new.cancel_ticket_id := old.cancel_ticket_id;
  end if;
  return new;
end;
$$;

-- As 0417: My Ride's targeting and the dispatch ladder.
create or replace function public.ride_requests_my_ride_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  -- The server's columns.
  new.target_driver_ids := old.target_driver_ids;
  new.targeted_until := old.targeted_until;
  new.my_ride_max_km := old.my_ride_max_km;
  new.fallback_pushed_at := old.fallback_pushed_at;
  new.widened_pushed_at := old.widened_pushed_at;
  new.direct_qr_token := old.direct_qr_token;
  new.direct_driver_id := old.direct_driver_id;
  new.direct_qr_id := old.direct_qr_id;
  new.dispatch_ladder := old.dispatch_ladder;
  new.dispatch_opened_at := old.dispatch_opened_at;
  new.dispatch_step := old.dispatch_step;
  -- Inside the window, only the rider and the targeted drivers.
  if old.status = 'open'
     and public.ride_request_targeting(old.target_driver_ids, old.targeted_until)
     and auth.uid() is distinct from old.rider_id
     and not coalesce(auth.uid() = any(old.target_driver_ids), false) then
    raise exception 'RIDE_TARGETED_TO_FAVOURITES' using errcode = '42501',
      hint = 'This request is offered to the rider''s favourite drivers first.';
  end if;
  return new;
end;
$$;

-- As 0262: the driver's card, and each side's own columns. On a ride the
-- back office drives itself, the card is still the server's.
create or replace function public.ride_requests_guard_sides()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_admin boolean;
  c       record;
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  v_admin := public.caller_admin_can_write('ride_requests');
  -- An admin is let through, except on a row where they are the driver
  -- themselves (an admin who also drives, bidding or taking a ride).
  if v_admin and (v_uid is null or new.partner_id is distinct from v_uid) then
    return new;
  end if;

  -- The driver's card follows partner_id: filled by the server when a driver
  -- takes or bids, cleared with the bid, fixed in between.
  if new.partner_id is null then
    new.partner_name := null;
    new.partner_phone := null;
    new.partner_photo := null;
    new.partner_rating := null;
    new.partner_trips := null;
    new.partner_plate := null;
    new.partner_vehicle := null;
  elsif tg_op = 'INSERT' or new.partner_id is distinct from old.partner_id then
    select * into c from public.ride_partner_card(new.partner_id);
    new.partner_name := c.name;
    new.partner_phone := c.phone;
    new.partner_photo := c.photo;
    new.partner_rating := c.rating;
    new.partner_trips := c.trips;
    new.partner_plate := c.plate;
    new.partner_vehicle := c.vehicle;
  else
    new.partner_name := old.partner_name;
    new.partner_phone := old.partner_phone;
    new.partner_photo := old.partner_photo;
    new.partner_rating := old.partner_rating;
    new.partner_trips := old.partner_trips;
    new.partner_plate := old.partner_plate;
    new.partner_vehicle := old.partner_vehicle;
  end if;

  if tg_op = 'INSERT' or v_admin then
    return new;
  end if;

  -- The rider's own: their details, their shared location, their answer to
  -- the safety check (that one only through trip_safety_ok()).
  if v_uid is distinct from old.rider_id
     and ((new.rider_name, new.rider_phone, new.user_live_lat, new.user_live_lng, new.user_live_at)
          is distinct from
          (old.rider_name, old.rider_phone, old.user_live_lat, old.user_live_lng, old.user_live_at)) then
    raise exception 'RIDE_RIDER_ONLY' using errcode = '42501',
      hint = 'Only the passenger changes their own details and location.';
  end if;
  if new.safety_ack_at is distinct from old.safety_ack_at then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501';
  end if;

  -- The driver's own live position.
  if v_uid is distinct from old.partner_id and v_uid is distinct from new.partner_id
     and ((new.partner_live_lat, new.partner_live_lng, new.partner_live_heading, new.partner_live_at)
          is distinct from
          (old.partner_live_lat, old.partner_live_lng, old.partner_live_heading, old.partner_live_at)) then
    raise exception 'RIDE_PARTNER_ONLY' using errcode = '42501';
  end if;

  -- A trip under way ends with the driver; the rider asks for it.
  if old.status = 'on_trip' and new.status = 'cancelled'
     and v_uid is distinct from old.partner_id then
    raise exception 'RIDE_STATUS_TRANSITION' using errcode = '42501',
      hint = 'Ask the driver to end the trip.';
  end if;

  return new;
end;
$$;

-- As 0248: the promo on a ride.
create or replace function public.ride_requests_promo_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_client boolean := current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('ride_requests');
  v_quote jsonb;
  v_fare numeric;
  v_pickup_at timestamptz;
begin
  if tg_op = 'INSERT' then
    new.promo_code := null;
    new.promo_estimate := null;
    new.promo_discount := null;
    new.promo_payable := null;
    new.promo_settled_at := null;
    new.promo_error := null;
    if new.promo_code_id is null then
      return new;
    end if;
    v_fare := greatest(0, round(coalesce(new.ride_fare, new.fare), 2)
                          - public.ride_option_charges_off(new.option_charges, 'promo'));
    -- A scheduled booking turned into a ride by the server (never one from
    -- the apps) is checked again as a scheduled ride, at its pickup time.
    if new.scheduled_ride_id is not null and not v_client then
      v_pickup_at := public.promo_scheduled_pickup(new.scheduled_ride_id);
    end if;
    begin
      v_quote := public.promo_ride_quote(new.promo_code_id, new.rider_id, new.timezone,
                                         new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng,
                                         new.service, v_fare,
                                         case when v_pickup_at is null then 'now' else 'scheduled' end,
                                         coalesce(v_pickup_at, now()));
    exception when others then
      v_quote := jsonb_build_object('reason', 'check_failed');
    end;
    if v_quote ? 'reason' then
      -- The booking goes ahead without the code.
      new.promo_code_id := null;
      new.promo_error := v_quote->>'reason';
      if v_pickup_at is not null then
        perform public.promo_scheduled_dropped(new.scheduled_ride_id, v_quote->>'reason');
      end if;
    else
      new.promo_code := v_quote->>'code';
      new.promo_estimate := (v_quote->>'estimate')::numeric;
    end if;
    return new;
  end if;

  if v_client
     and (new.promo_code_id, new.promo_code, new.promo_estimate, new.promo_discount,
          new.promo_payable, new.promo_settled_at, new.promo_error)
         is distinct from
         (old.promo_code_id, old.promo_code, old.promo_estimate, old.promo_discount,
          old.promo_payable, old.promo_settled_at, old.promo_error) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'The promo on a ride is the server''s.';
  end if;

  if new.promo_code_id is not null and old.status = 'open'
     and (new.fare, new.ride_fare) is distinct from (old.fare, old.ride_fare) then
    new.promo_estimate := coalesce(
      public.promo_ride_estimate(new.promo_code_id,
        greatest(0, round(coalesce(new.ride_fare, new.fare), 2) - public.ride_option_charges_off(new.option_charges, 'promo'))),
      new.promo_estimate);
  end if;
  return new;
end;
$$;

-- As 0269: fees, and the rider's rating on the ride.
create or replace function public.ride_requests_guard_city_ride()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if (new.cancel_fee, new.cancel_fee_status, new.prior_fees, new.trip_shared_at, new.rider_ratings_count,
      new.rider_trips, new.rider_rating)
     is distinct from
     (old.cancel_fee, old.cancel_fee_status, old.prior_fees, old.trip_shared_at, old.rider_ratings_count,
      old.rider_trips, old.rider_rating) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'Fees and the rider''s rating are the server''s.';
  end if;
  return new;
end;
$$;

-- As 0316: GET.Plus on a ride.
create or replace function public.ride_requests_plus_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if (new.plus_pct, new.plus_max_discount, new.plus_priority, new.plus_discount, new.plus_settled_at,
      new.plus_waived_fee)
     is distinct from
     (old.plus_pct, old.plus_max_discount, old.plus_priority, old.plus_discount, old.plus_settled_at,
      old.plus_waived_fee) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'GET.Plus on a ride is the server''s.';
  end if;
  return new;
end;
$$;

-- As 0097, for who may change a ride's rider: an admin who may edit rides,
-- and the account link. admin_link_account (0194) runs for an admin who may
-- edit users and says so with getride.account_linking, as it does for the
-- wallet (wallet_tx_frozen_guard); nothing else in the database moves a ride
-- to another rider. This rule has no test of the caller's role: it holds
-- inside functions too. Still a definer function, with its grants as they
-- were.
create or replace function public.ride_requests_protect_rider()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.rider_id is distinct from old.rider_id
     and not (public.caller_admin_can_write('ride_requests')
              or coalesce(current_setting('getride.account_linking', true), '') = '1') then
    raise exception 'rider_immutable';
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
