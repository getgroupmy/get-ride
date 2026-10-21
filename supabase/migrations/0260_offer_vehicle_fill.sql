-- ============================================================================
-- 0260: an offer shows the driver's plate and car once they have taken one.
--
-- The driver's card on a ride (partner_plate, partner_vehicle) is filled by
-- ride_requests_guard_sides (0182, 0237) only when partner_id changes, from
-- ride_partner_card: the vehicle of the driver's vehicle_active_session,
-- else the plate and car on their partner profile. partner_vehicle_id and
-- the plate colours (ride_requests_stamp_vehicle, 0254) come from the same
-- session, and an open row (a bid) was never looked at again.
--
-- A driver who bid a few seconds before their session started, with no
-- plate or car on their profile, reached the rider with a name and a photo
-- and nothing else, and nothing filled the rest in afterwards.
--
--   1. ride_requests_stamp_vehicle (0254) looks the session up again on an
--      open row with a bid too, not only once the ride is accepted, and fills
--      a blank partner_plate / partner_vehicle from the stamped vehicle on a
--      live row (open with a bid, accepted, arrived, on_trip). A plate or car
--      already there is never replaced. It runs for every writer, after
--      every other guard (trg_ride_requests_zzz_vehicle).
--   2. When a driver's session starts (or an admin moves it to another
--      vehicle), their live rows with something missing are touched so (1)
--      fills them, and the rider sees the car at once through realtime.
--      The update runs as this function's owner, so guard_sides (which only
--      freezes the card for anon / authenticated) lets the fill through.
--   3. Live rows already missing their car are filled now.
-- ============================================================================

-- ---- 1. The stamp fills the card's plate and car ----------------------------------------
-- As in 0254 (its only definition), plus the open-row retry and the card fill.
create or replace function public.ride_requests_stamp_vehicle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle uuid;
  v_ctx jsonb;
  v_types text[];
  v_energy text;
  v_country text;
  v_plate text;
  v_label text;
begin
  if new.partner_id is null then
    new.partner_vehicle_id := null;
    new.partner_energy := null;
    new.partner_vehicle_types := null;
    new.partner_plate_colours := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.partner_id is not distinct from old.partner_id
     and (old.partner_vehicle_id is not null
          or new.status not in ('open', 'accepted', 'arrived', 'on_trip')) then
    -- Kept: the vehicle already stamped, or a ride no longer live.
    new.partner_vehicle_id := old.partner_vehicle_id;
    new.partner_energy := old.partner_energy;
    new.partner_vehicle_types := old.partner_vehicle_types;
    new.partner_plate_colours := old.partner_plate_colours;
  else
    -- A new driver, or one still without a vehicle on a live ride (a bid
    -- made before their session started): the vehicle they have taken.
    select s.vehicle_id into v_vehicle from public.vehicle_active_session s where s.user_id = new.partner_id limit 1;
    if v_vehicle is null then
      new.partner_vehicle_id := null;
      new.partner_energy := null;
      new.partner_vehicle_types := null;
      new.partner_plate_colours := null;
      return new;
    end if;
    v_ctx := public.ptr_vehicle_context(v_vehicle);
    v_types := public.ptr_text_array(v_ctx->'types');
    v_energy := public.vehicle_energy(v_vehicle);
    v_country := (public.ptr_text_array(v_ctx->'countries'))[1];
    new.partner_vehicle_id := v_vehicle;
    new.partner_energy := v_energy;
    new.partner_vehicle_types := v_types;
    new.partner_plate_colours := public.permit_plate_colours(v_country, v_types, v_energy);
  end if;

  -- The card's plate and car, when still blank, from the stamped vehicle
  -- (as ride_partner_card words them). Never replaces one already there.
  if new.partner_vehicle_id is not null
     and new.status in ('open', 'accepted', 'arrived', 'on_trip')
     and (nullif(btrim(new.partner_plate), '') is null or nullif(btrim(new.partner_vehicle), '') is null) then
    select nullif(btrim(v.plate), ''), nullif(btrim(concat_ws(' ', v.color, v.make, v.model)), '')
      into v_plate, v_label
      from public.vehicle v
     where v.id = new.partner_vehicle_id;
    if nullif(btrim(new.partner_plate), '') is null and v_plate is not null then
      new.partner_plate := v_plate;
    end if;
    if nullif(btrim(new.partner_vehicle), '') is null and v_label is not null then
      new.partner_vehicle := v_label;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_stamp_vehicle() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_zzz_vehicle on public.ride_requests;
create trigger trg_ride_requests_zzz_vehicle
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_stamp_vehicle();

-- ---- 2. A session that starts fills the driver's live rides -----------------------------
-- The driver's live rows (their bids, and rides accepted, arrived or under
-- way) missing the vehicle, the plate or the car. Each row is touched on its
-- own: the stamp (1) does the filling, and a row some other guard refuses
-- (say, an option no longer offered where it was booked) is left as it was
-- rather than failing the driver's claim_vehicle.
create or replace function public.ride_requests_fill_vehicle(p_driver uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_n integer := 0;
begin
  if p_driver is null or current_setting('getride.vehicle_fill', true) = 'on' then
    return 0;
  end if;
  perform set_config('getride.vehicle_fill', 'on', true);
  for r in
    select rr.id
      from public.ride_requests rr
     where rr.partner_id = p_driver
       and rr.status in ('open', 'accepted', 'arrived', 'on_trip')
       and (rr.partner_vehicle_id is null
            or nullif(btrim(rr.partner_plate), '') is null
            or nullif(btrim(rr.partner_vehicle), '') is null)
  loop
    begin
      -- Touched only; ride_requests_stamp_vehicle fills what is blank.
      update public.ride_requests set partner_vehicle_id = partner_vehicle_id where id = r.id;
      v_n := v_n + 1;
    exception when others then
      raise warning 'ride_requests_fill_vehicle: ride % left as it was: %', r.id, sqlerrm;
    end;
  end loop;
  perform set_config('getride.vehicle_fill', 'off', true);
  return v_n;
end;
$$;
revoke execute on function public.ride_requests_fill_vehicle(uuid) from public, anon, authenticated;

create or replace function public.vehicle_active_session_fill_rides()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.vehicle_id is not distinct from old.vehicle_id then
    return null;
  end if;
  perform public.ride_requests_fill_vehicle(new.user_id);
  return null;
end;
$$;
revoke execute on function public.vehicle_active_session_fill_rides() from public, anon, authenticated;

drop trigger if exists trg_vehicle_active_session_fill_rides on public.vehicle_active_session;
create trigger trg_vehicle_active_session_fill_rides
  after insert or update of vehicle_id on public.vehicle_active_session
  for each row execute function public.vehicle_active_session_fill_rides();

-- ---- 3. Live rides already missing their car ---------------------------------------------
select public.ride_requests_fill_vehicle(s.user_id)
  from public.vehicle_active_session s
 where exists (
   select 1 from public.ride_requests rr
    where rr.partner_id = s.user_id
      and rr.status in ('open', 'accepted', 'arrived', 'on_trip')
      and (rr.partner_vehicle_id is null
           or nullif(btrim(rr.partner_plate), '') is null
           or nullif(btrim(rr.partner_vehicle), '') is null));
