-- ============================================================================
-- 0182: who can read a ride, and whose word the rider sees (audit 14 Oct 2026).
--
--   1. Open requests were readable by anyone, signed out included: rider name
--      and phone, the exact pickup, the trip code, the rider's IP. Now an open
--      request is read by approved drivers only (and, as before, its rider,
--      its driver and admins); signed-out callers lose the table entirely.
--   2. The driver's name, photo, phone, rating, plate and car on a ride were
--      whatever the driver's app sent. The server now fills them from the
--      partner's approved record and the vehicle they are driving whenever a
--      driver takes or bids on a ride, and keeps them fixed afterwards.
--   3. Each side writes only its own live data: the driver can't move the
--      rider's shared location, answer the rider's safety check or rewrite
--      the rider's name and phone; the rider can't move the driver's.
--   4. A trip under way is ended by the driver: the rider asks (the app's
--      cancel request) instead of cancelling it outright and never paying.
--
-- Server-side only; the apps send the same requests as before.
-- ============================================================================

-- ---- 1. Reads -------------------------------------------------------------------
drop policy if exists "ride_requests read" on public.ride_requests;
create policy "ride_requests read"
  on public.ride_requests for select
  using (
    (status = 'open'
      and (select public.caller_is_approved_partner())
      and (targeted_until is null
           or targeted_until <= now()
           or coalesce(cardinality(target_driver_ids), 0) = 0
           or (select auth.uid()) = any(target_driver_ids)))
    or rider_id = (select auth.uid())
    or partner_id = (select auth.uid())
    or (select public.caller_is_admin())
  );

revoke select on public.ride_requests from anon;

-- ---- 2. The driver's card, from the server -----------------------------------------
-- The calling driver's own card: name, phone, photo and rating from their
-- approved partner record (the profile when a field is blank), plate and car
-- from the vehicle they are driving now. Nothing for anyone else.
create or replace function public.ride_partner_card(p_partner uuid)
returns table (name text, phone text, photo text, rating numeric, plate text, vehicle text)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select p.name, p.phone, p.avatar_url, p.rating, p.plate, p.vehicle
      from public.partners p
     where p.auth_user_id = p_partner
       and (p.status = 'approved' or p.status::text like 'permit-%')
     order by p.created_at desc
     limit 1
  ), prof as (
    select pr.name, pr.phone, pr.avatar_url from public.profiles pr where pr.id = p_partner
  ), car as (
    select v.plate, nullif(btrim(concat_ws(' ', v.color, v.make, v.model)), '') as label
      from public.vehicle_active_session s
      join public.vehicle v on v.id = s.vehicle_id
     where s.user_id = p_partner
     limit 1
  )
  select coalesce(nullif(btrim(me.name), ''), prof.name),
         coalesce(nullif(btrim(me.phone), ''), prof.phone),
         coalesce(nullif(btrim(me.avatar_url), ''), prof.avatar_url),
         me.rating,
         coalesce(nullif(btrim(car.plate), ''), nullif(btrim(me.plate), '')),
         coalesce(car.label, nullif(btrim(me.vehicle), ''))
    from me
    left join prof on true
    left join car on true
   where p_partner = auth.uid() or public.caller_is_admin();
$$;

revoke execute on function public.ride_partner_card(uuid) from public, anon;
grant execute on function public.ride_partner_card(uuid) to authenticated;

-- ---- 2-4. The guard ---------------------------------------------------------------
create or replace function public.ride_requests_guard_sides()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  c      record;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  -- The driver's card follows partner_id: filled by the server when a driver
  -- takes or bids, cleared with the bid, fixed in between.
  if new.partner_id is null then
    new.partner_name := null;
    new.partner_phone := null;
    new.partner_photo := null;
    new.partner_rating := null;
    new.partner_plate := null;
    new.partner_vehicle := null;
  elsif tg_op = 'INSERT' or new.partner_id is distinct from old.partner_id then
    select * into c from public.ride_partner_card(new.partner_id);
    new.partner_name := c.name;
    new.partner_phone := c.phone;
    new.partner_photo := c.photo;
    new.partner_rating := c.rating;
    new.partner_plate := c.plate;
    new.partner_vehicle := c.vehicle;
  else
    new.partner_name := old.partner_name;
    new.partner_phone := old.partner_phone;
    new.partner_photo := old.partner_photo;
    new.partner_rating := old.partner_rating;
    new.partner_plate := old.partner_plate;
    new.partner_vehicle := old.partner_vehicle;
  end if;

  if tg_op = 'INSERT' then
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

-- After the other guards (alphabetical within BEFORE): it only fills and
-- freezes, so it sees what they let through.
drop trigger if exists trg_ride_requests_d_guard_sides on public.ride_requests;
create trigger trg_ride_requests_d_guard_sides
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_sides();
