-- ============================================================================
-- 0262: a driver who is also an admin gets their card on a bid or a take.
--
-- The driver's card on a ride (partner_name, phone, photo, rating, trips,
-- plate, vehicle) is stamped by ride_requests_guard_sides (0182, 0237) from
-- ride_partner_card when partner_id changes, and frozen in between. The
-- guard returned at once for any caller_is_admin(): a profile with even one
-- admin_access row. Such a driver's bid or take (ride_repository submitOffer
-- / accept, a plain table update) kept what their app sent: the plate and
-- car from their partner profile, which were empty, no trip count ("New
-- driver") and the app's rating. Their vehicle session (the car they had
-- taken an hour before) was never looked at, so the rider's offer card had a
-- name and a photo and no plate or car.
--
--   1. ride_requests_guard_sides treats a caller writing a row on which they
--      are the driver (new.partner_id = auth.uid()) as a driver for the card,
--      admin or not: stamped from ride_partner_card on a bid or a take,
--      frozen while it stands. An admin writing someone else's ride is let
--      through as before, as are the guard's other checks for admins.
--      As in 0182 with 0237's partner_trips; nothing else changes.
--   2. Live rides whose card was left unstamped this way are stamped now.
--
-- 0260 (ride_requests_stamp_vehicle filling a blank plate and car from the
-- vehicle session) covers the plate and car once a session exists; this
-- puts the whole card back on the server for these drivers too.
-- ============================================================================

-- ---- 1. The card is the server's for a driver, admin or not ------------------------------
create or replace function public.ride_requests_guard_sides()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_admin boolean;
  c       record;
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  v_admin := public.caller_is_admin();
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
revoke execute on function public.ride_requests_guard_sides() from public, anon, authenticated;

-- ---- 2. Live rides of admin drivers, card left as their app sent it ---------------------
-- Rides of a driver with an admin_access row, still live, that never got
-- their trip count (the guard stamps it on every bid and take). Filled from
-- the card; a plate or car already there is kept. Run as the migration's
-- owner, so the guard lets the write through, and ride_partner_card answers
-- (no JWT: caller_is_admin).
with due as (
  select r.id, c.*
    from public.ride_requests r
    cross join lateral public.ride_partner_card(r.partner_id) c
   where r.status in ('open', 'accepted', 'arrived', 'on_trip')
     and r.partner_trips is null
     and exists (select 1 from public.admin_access a where a.profile_id = r.partner_id)
)
update public.ride_requests r
   set partner_trips   = d.trips,
       partner_rating  = coalesce(d.rating, r.partner_rating),
       partner_name    = coalesce(nullif(btrim(d.name), ''), r.partner_name),
       partner_plate   = coalesce(nullif(btrim(r.partner_plate), ''), d.plate),
       partner_vehicle = coalesce(nullif(btrim(r.partner_vehicle), ''), d.vehicle)
  from due d
 where d.id = r.id;

-- Live drift: 0141 revoked execute on this trigger function, but live still grants it.
revoke execute on function public.ride_requests_auto_accept() from public, anon, authenticated;
