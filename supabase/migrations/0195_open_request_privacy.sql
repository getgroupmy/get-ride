-- ============================================================================
-- 0195: an open ride request shows drivers only what they need to decide
--
-- RUN THIS LAST, and only once App Version's minimum is 1.4.9 with Force
-- update on: 1.4.8 and earlier read the passenger's details straight off the
-- request row and would show blanks.
--
-- Until now any approved driver could read every column of an open request
-- (and Realtime sent them the whole row): the rider's full name and phone,
-- who it was booked for and their number, the trip code, the share link,
-- the device's address and the full address.
--
-- Now, while a request is open:
--   * those move into ride_request_private, which only the rider (and
--     admins) can read; the trip code lives only in ride_trip_codes (0152)
--     and start_trip checks it;
--   * the row keeps the area, distance, fare, the rider's first name, the
--     rating and, unless an admin turns it off, the rider's photo;
--   * a request booked for someone else shows as booked_for_other (an icon
--     in the app), not who it is for.
-- When it leaves "open" (a driver accepts, or it's cancelled or expires) the
-- details come back to the row, which only the rider, that driver and
-- admins can read. Reopened, they move out again.
-- ============================================================================

-- ---- Setting: the rider's photo on an open request ----------------------------------------------
insert into public.app_settings (key, value)
values ('ride_privacy', jsonb_build_object('showRiderPhoto', true))
on conflict (key) do nothing;

create or replace function public.ride_privacy_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('showRiderPhoto',
    coalesce((select (value->>'showRiderPhoto') not in ('false', 'f', '0', 'off')
                from public.app_settings where key = 'ride_privacy'), true));
$$;
revoke execute on function public.ride_privacy_config() from public, anon;
grant execute on function public.ride_privacy_config() to authenticated, service_role;

create or replace function public.set_ride_privacy_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('ride_privacy', jsonb_build_object('showRiderPhoto', coalesce(p_config->'showRiderPhoto', 'true'::jsonb) <> 'false'::jsonb), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.ride_privacy_config();
end;
$$;
revoke execute on function public.set_ride_privacy_config(jsonb) from public, anon;
grant execute on function public.set_ride_privacy_config(jsonb) to authenticated;

-- ---- Where the details wait -------------------------------------------------------------------
alter table public.ride_requests add column if not exists booked_for_other boolean not null default false;

create table if not exists public.ride_request_private (
  request_id       uuid primary key references public.ride_requests(id) on delete cascade deferrable initially deferred,
  rider_name       text,
  rider_phone      text,
  rider_photo      text,
  booked_for_name  text,
  booked_for_phone text,
  full_address     text,
  ip_address       text,
  gender           text,
  share_token      uuid unique,
  updated_at       timestamptz not null default now()
);

alter table public.ride_request_private enable row level security;
drop policy if exists "ride_request_private rider read" on public.ride_request_private;
create policy "ride_request_private rider read" on public.ride_request_private
  for select to authenticated using (
    exists (select 1 from public.ride_requests r where r.id = request_id and r.rider_id = (select auth.uid()))
    or (select public.caller_is_admin()));
revoke all on public.ride_request_private from anon, authenticated;
grant select on public.ride_request_private to authenticated;

-- ---- The move ---------------------------------------------------------------------------------
-- Last of the BEFORE triggers (zz), so every guard has seen the caller's own
-- values first.
create or replace function public.ride_requests_privacy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ins  boolean := tg_op = 'INSERT';
  pv   public.ride_request_private;
  photo boolean := (public.ride_privacy_config() ->> 'showRiderPhoto')::boolean;
begin
  if new.status = 'open' then
    insert into public.ride_request_private as p (request_id, rider_name, rider_phone, rider_photo, booked_for_name,
                                                  booked_for_phone, full_address, ip_address, gender, share_token)
    values (new.id,
      case when ins or new.rider_name is distinct from old.rider_name then new.rider_name end,
      case when ins or new.rider_phone is distinct from old.rider_phone then new.rider_phone end,
      case when ins or new.rider_photo is distinct from old.rider_photo then new.rider_photo end,
      case when ins or new.booked_for_name is distinct from old.booked_for_name then new.booked_for_name end,
      case when ins or new.booked_for_phone is distinct from old.booked_for_phone then new.booked_for_phone end,
      case when ins or new.full_address is distinct from old.full_address then new.full_address end,
      case when ins or new.ip_address is distinct from old.ip_address then new.ip_address end,
      case when ins or new.gender is distinct from old.gender then new.gender end,
      case when ins or new.share_token is distinct from old.share_token then new.share_token end)
    on conflict (request_id) do update set
      rider_name       = coalesce(excluded.rider_name, p.rider_name),
      rider_phone      = coalesce(excluded.rider_phone, p.rider_phone),
      rider_photo      = coalesce(excluded.rider_photo, p.rider_photo),
      booked_for_name  = coalesce(excluded.booked_for_name, p.booked_for_name),
      booked_for_phone = coalesce(excluded.booked_for_phone, p.booked_for_phone),
      full_address     = coalesce(excluded.full_address, p.full_address),
      ip_address       = coalesce(excluded.ip_address, p.ip_address),
      gender           = coalesce(excluded.gender, p.gender),
      share_token      = coalesce(excluded.share_token, p.share_token),
      updated_at       = now()
    returning * into pv;

    new.booked_for_other := new.booked_for_other or pv.booked_for_phone is not null;
    -- First name only.
    new.rider_name := nullif(split_part(btrim(coalesce(pv.rider_name, '')), ' ', 1), '');
    new.rider_photo := case when photo then pv.rider_photo end;
    new.rider_phone := null;
    new.booked_for_name := null;
    new.booked_for_phone := null;
    new.full_address := null;
    new.ip_address := null;
    new.gender := null;
    new.share_token := null;
    new.otp := null;  -- ride_trip_codes has it (0152)
  elsif not ins and old.status = 'open' then
    select * into pv from public.ride_request_private where request_id = new.id;
    if found then
      new.rider_name       := coalesce(pv.rider_name, new.rider_name);
      new.rider_phone      := coalesce(new.rider_phone, pv.rider_phone);
      new.rider_photo      := coalesce(pv.rider_photo, new.rider_photo);
      new.booked_for_name  := coalesce(new.booked_for_name, pv.booked_for_name);
      new.booked_for_phone := coalesce(new.booked_for_phone, pv.booked_for_phone);
      new.full_address     := coalesce(new.full_address, pv.full_address);
      new.ip_address       := coalesce(new.ip_address, pv.ip_address);
      new.gender           := coalesce(new.gender, pv.gender);
      new.share_token      := coalesce(new.share_token, pv.share_token);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_privacy() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_zz_privacy on public.ride_requests;
create trigger trg_ride_requests_zz_privacy
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_privacy();

-- Requests already open move now.
update public.ride_requests set status = status where status = 'open';

-- ---- What read the moved columns of an open request ----------------------------------------------
-- 0107's one-request rule: the passenger's number may now be waiting aside.
create or replace function public.ride_requests_one_active_request()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  phone text := nullif(regexp_replace(coalesce(new.booked_for_phone,
    (select p.booked_for_phone from public.ride_request_private p where p.request_id = new.id), ''), '\D', '', 'g'), '');
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
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
         or (r.status in ('accepted', 'arrived', 'on_trip') and r.updated_at > now() - interval '12 hours')
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

-- The share link: kept aside while the request is open.
create or replace function public.ride_share_link(p_ride uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  token uuid;
begin
  if auth.uid() is null
     or not exists (select 1 from public.ride_requests where id = p_ride and rider_id = auth.uid()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  token := coalesce(
    (select share_token from public.ride_request_private where request_id = p_ride),
    (select share_token from public.ride_requests where id = p_ride),
    gen_random_uuid());
  update public.ride_requests set share_token = token where id = p_ride and share_token is distinct from token;
  return token;
end;
$$;
revoke all on function public.ride_share_link(uuid) from public, anon;
grant execute on function public.ride_share_link(uuid) to authenticated;

-- The shared page: found by a link kept aside too; names from there.
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
    'passenger', split_part(coalesce(nullif(trim(coalesce(r.booked_for_name, pv.booked_for_name)), ''),
                                    nullif(trim(coalesce(pv.rider_name, r.rider_name)), ''), 'Passenger'), ' ', 1),
    'booked_for_others', r.booked_for_other or r.booked_for_phone is not null,
    -- Who shared it (the rider, first name only), for the page's footer.
    'rider', split_part(coalesce(nullif(trim(coalesce(pv.rider_name, r.rider_name)), ''), ''), ' ', 1),
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
    'otp', case when (r.booked_for_other or r.booked_for_phone is not null) and r.status in ('open', 'accepted', 'arrived') then coalesce((select c.code from public.ride_trip_codes c where c.request_id = r.id), r.otp) end,
    'created_at', r.created_at,
    'accepted_at', r.accepted_at,
    'arrived_at', r.arrived_at,
    'started_at', r.started_at,
    'completed_at', r.completed_at,
    'cancelled_at', r.cancelled_at
  )
  from public.ride_requests r
  left join public.ride_request_private pv on pv.request_id = r.id
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
    and r.id = coalesce((select x.request_id from public.ride_request_private x where x.share_token = p_token),
                        (select y.id from public.ride_requests y where y.share_token = p_token))
    and (r.status in ('open', 'accepted', 'arrived', 'on_trip') or r.updated_at > now() - interval '24 hours')
$$;
revoke all on function public.ride_share_view(uuid) from public;
grant execute on function public.ride_share_view(uuid) to anon, authenticated;
