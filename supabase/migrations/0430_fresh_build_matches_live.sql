-- ============================================================================
-- 0430: a database built from this folder ends up as the live one
--
-- The live database and one built fresh from this folder (a preview branch,
-- `supabase db reset`, CI's Migrations replay) were compared object by
-- object on 2026-11-22: tables, columns, constraints, indexes, triggers,
-- rules, every function and its grants, cron jobs and buckets. Four things
-- differed. This closes them. On the live database 1, 2 and 4 are already so,
-- and 3 removes a rule that allows nothing: no screen and no answer changes
-- there.
--
-- 1. Courier in three functions. 0268 (Courier) made ride_request_is_freight,
--    ride_cancel_terms and ride_offer_make know a courier request. On the
--    live database 0268 ran after 0269 and 0271. In file order those two run
--    after it and put back their versions from before Courier: 0268 leaves
--    its own out while ride_offers is not there yet, expecting them to
--    "define it themselves". So on a fresh build:
--      * ride_request_is_freight missed a request with a parcel size or a
--        courier service when "what is sent" was empty;
--      * ride_cancel_terms had no 'courier', and for a cancel after the
--        courier arrived it quoted Freight's fee, not Courier's (the fee
--        charged was Courier's all along: 0268's trip trigger);
--      * ride_offer_make turned a driver without a courier vehicle away
--        with Freight's reason (FREIGHT_DRIVER_NO_FREIGHT), not
--        COURIER_DRIVER_NO_COURIER.
--    The three are recreated here exactly as the live database holds them,
--    with 0316's GET.Plus line in ride_cancel_terms: same signatures, same
--    grants, no DROP. supabase/tests/courier_0268.sql took either version;
--    it now expects this one.
--
-- 2. The rule "support-media owner update" on storage.objects. The apps
--    upload a support attachment with upsert, which Storage allows only with
--    an UPDATE rule beside the INSERT one. The live database got the rule
--    from supabase/storage-policies-0148.sql, run once by the owner; no
--    migration has it, so a fresh build did not. It is made here when it is
--    missing, as the live database has it. Where it is there already (the
--    live database), or where the migration role may not write rules on
--    storage.objects, nothing is done.
--
-- 3. The rule "fare_ai_responses insert". 0147 drops it, but that line
--    joined 0147 after the live database had run it, so the rule is still
--    there. It lets nobody insert (with check (false)), which is what no
--    rule does as well. Dropped here so both databases are the same.
--
-- 4. The buckets "Profile Image" and "Vehicle_Image" take images only on the
--    live database (set in the dashboard). Set here where nothing is set.
-- ============================================================================

-- ---- 1. Courier in three functions (as 0268, as live) ---------------------------------------------

-- A courier request counts as freight is: spared the city fees.
create or replace function public.ride_request_is_freight(r public.ride_requests)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select r.cargo_description is not null or r.parcel_size is not null
      or coalesce(public.vehicle_service_is_freight(r.service), false)
      or coalesce(public.vehicle_service_is_courier(r.service), false);
$$;
revoke execute on function public.ride_request_is_freight(public.ride_requests) from public, anon, authenticated;
grant execute on function public.ride_request_is_freight(public.ride_requests) to service_role;

-- 'courier' says which fee the sender owes after the driver arrived; the fee
-- is read under the request's own key (courier-cancel-arrived for a parcel).
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
  -- 0316: a GET.Plus free cancel left.
  v := public.plus_cancel_terms(r, v);
  return v || jsonb_build_object(
    'currency', r.currency,
    'freeUntil', r.accepted_at + make_interval(secs => (v->>'freeMinutes')::numeric * 60),
    'noShowAt', r.arrived_at + make_interval(secs => (v->>'noShowMinutes')::numeric * 60),
    'scheduled', r.scheduled_ride_id is not null,
    'freight', v_freight,
    'courier', r.parcel_size is not null,
    -- What 0267's trip trigger bills (a request with cargo) when the sender
    -- cancels after the driver arrived.
    'freightArrivedFee', case when v_freight and r.cargo_description is not null
                              then public.freight_place_value(public.freight_charges_at(r),
                                                              public.delivery_place_key(r, 'cancel-arrived'))
                              else 0 end);
end;
$$;
revoke execute on function public.ride_cancel_terms(uuid) from public, anon;
grant execute on function public.ride_cancel_terms(uuid) to authenticated;

-- A driver whose vehicle doesn't carry the parcel is told so, ahead of the
-- Freight reasons.
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
    if public.vehicle_service_is_courier(r.service) then
      raise exception 'COURIER_DRIVER_NO_COURIER' using errcode = '42501',
        hint = 'Your vehicle doesn''t take this courier request.';
    end if;
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

-- ---- 2. Support attachments: the owner's UPDATE rule ----------------------------------------------
do $$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'storage' and tablename = 'objects'
                and policyname = 'support-media owner update') then
    return;
  end if;
  create policy "support-media owner update" on storage.objects for update to authenticated
    using (bucket_id = 'support-media'
      and (public.storage_owns_ticket_folder((storage.foldername(name))[1])
           or (select public.caller_admin_can_write('storage:support-media'))))
    with check (bucket_id = 'support-media'
      and (public.storage_owns_ticket_folder((storage.foldername(name))[1])
           or (select public.caller_admin_can_write('storage:support-media'))));
exception when insufficient_privilege then
  -- Only the owner of storage.objects may write its rules here.
  raise notice '0430: the rule "support-media owner update" on storage.objects is missing and this role may not create it';
end
$$;

-- ---- 3. A rule that allows nothing ----------------------------------------------------------------
drop policy if exists "fare_ai_responses insert" on public.fare_ai_responses;

-- ---- 4. Image buckets take images -----------------------------------------------------------------
update storage.buckets
   set allowed_mime_types = array['image/*']
 where id in ('Profile Image', 'Vehicle_Image')
   and allowed_mime_types is null;
