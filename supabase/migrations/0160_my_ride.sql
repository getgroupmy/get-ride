-- ============================================================================
-- 0160: My Ride — favourite drivers, booking to them first, and widening
--       dispatch radii
--
-- A rider keeps a short list of drivers they like ("My Ride"). A driver
-- hands out a code (or its QR); a rider who enters it has that driver as a
-- favourite. No approval: a driver who does not want a rider can HIDE them,
-- and the rider is never told — the driver just shows as unavailable and
-- is never targeted or starred for them again.
--
-- Booking with My Ride on: the request names some of the rider's
-- favourites (`target_driver_ids`). For a short window (per vehicle
-- service, default 60 s) only those drivers can see it, bid on it or take
-- it; then it opens to everybody nearby on its own ("auto fallback"), or
-- sooner if the rider presses "Offer to all nearby".
--
-- QR payload convention: `getride://myride/<CODE>` (the Dart side parses
-- it in lib/src/core/my_ride.dart; a bare code works too). Codes are 8
-- characters of 23456789ABCDEFGHJKLMNPQRSTUVWXYZ (no 0/O/1/I), random,
-- 2^40 of them, matched case-insensitively.
--
-- What is here:
--
--   favourite_drivers              rider_id → driver_id (the driver's
--                                  ACCOUNT id, as ride_requests.partner_id
--                                  holds it), hidden_by_driver/hidden_at.
--                                  Readable by the driver, by the rider
--                                  (rows not hidden — a hidden row only
--                                  shows through my_favourite_drivers(),
--                                  as "unavailable") and by admins; written
--                                  only by the functions below (admins may
--                                  also write directly).
--   partners.my_ride_code          unique, set for every partner (backfilled
--                                  here, defaulted for new ones) and never
--                                  settable by a client: a client write of
--                                  it is ignored.
--   my_ride_code() / rotate_my_ride_code()
--   add_favourite_driver(code)     resolves the code; refuses the caller's
--                                  own, blocked/rejected partners, and more
--                                  than 50 favourites. A code that matches
--                                  nobody counts towards a limit of 10 per
--                                  account / 30 per network address per
--                                  hour (auth_rate_hits, 0137), so codes
--                                  cannot be walked. Outcomes come back as
--                                  {ok, error?, retry_after?, driver?}
--                                  rather than raised, so a counted miss is
--                                  not rolled back.
--   remove_favourite_driver(driver_id)
--   my_favourite_drivers(lat, lng) the rider's list with safe display
--                                  fields only (what a rider sees of a
--                                  driver on a ride, plus colour — never a
--                                  phone), `available`, online / last-seen
--                                  bucket, and km to (lat, lng) rounded to
--                                  0.5 km while online.
--   hide_favourite_rider(rider, hidden) / my_favourite_riders() /
--   my_favourite_rider_ids()       the driver's side; names masked with
--                                  wallet_mask_name. Hiding also takes the
--                                  driver off that rider's open requests.
--   ride_request_offer_to_all(id)  the rider ends the window now.
--   ride_request_add_targets(id, driver_ids)
--                                  the rider adds favourites while
--                                  searching (own, not hidden, approved).
--   vehicle_service_dispatch_config(service)
--                                  the service's radii and windows from its
--                                  `vehicle-services` settings entry (keys
--                                  searchRadiusMinKm 3, searchRadiusMaxKm
--                                  15, searchWidenAfterSec 30, myRideMaxKm
--                                  0 = no limit, myRideWindowSec 60; a
--                                  missing / non-positive value takes the
--                                  default). ride_requests.service holds
--                                  the service NAME (the app writes
--                                  _service.name); the entry id is matched
--                                  too.
--
-- ride_requests gains target_driver_ids, targeted_until, my_ride_max_km,
-- fallback_pushed_at, widened_pushed_at. All null = today's behaviour, so
-- older app builds (which never send them) book exactly as before.
--
--   * BEFORE INSERT (trg_ride_requests_c_my_ride): the targets the client
--     sent are kept only where they are the rider's own, non-hidden
--     favourites, approved (or permit-*) partners, and — when a distance
--     cap applies (the smaller non-zero of the rider's my_ride_max_km and
--     the service's myRideMaxKm) — not known to be farther than it (a
--     driver whose position is not known stays targeted). At most 20. The
--     window is the service's, whatever the client sent. The bookkeeping
--     columns are always reset.
--   * SELECT policy "ride_requests read": an open row inside its window is
--     visible only to its rider, its targeted drivers and admins. Every
--     other row reads exactly as before (open → anyone; otherwise rider,
--     partner, admin).
--   * BEFORE UPDATE (trg_ride_requests_c_my_ride_guard): a client cannot
--     change any My Ride column (silently kept), and inside the window
--     nobody but the rider or a targeted driver can change the row at all
--     (RIDE_TARGETED_TO_FAVOURITES) — the policy already hides it from
--     them, this backs it for an UPDATE without a WHERE. Server code
--     (definer functions, cron) and admins pass.
--
-- Push (notify_partners_on_ride_request, replacing 0145's):
--   * inside the window: only the targeted drivers, "Your regular rider
--     needs a ride", wherever they are;
--   * otherwise: online drivers within the service's MIN radius; where
--     nobody is that close (decided at insert), straight to the MAX
--     radius; where nobody is within that either, every driver
--     (audience 'partners') as 0145 did.
--   * ride_requests_dispatch_tick() (pg_cron, every 20 s, or every minute
--     where seconds schedules are not supported — so a fallback can land up
--     to a tick late; the rider's app may end the window itself with
--     ride_request_offer_to_all): pushes requests whose window ended to
--     nearby drivers (min radius, same widening rule), and widens requests
--     that have been open to all for searchWidenAfterSec to the max radius.
--     Nobody is pushed twice for the same request: ride_request_pushes
--     records who was told (a fare raise is a new message and still goes
--     to everybody near).
--
-- Rollback:
--   drop trigger trg_ride_requests_c_my_ride on public.ride_requests;
--   drop trigger trg_ride_requests_c_my_ride_guard on public.ride_requests;
--   re-run 0145's notify_partners_on_ride_request and 0097's
--   "ride_requests read" policy; select cron.unschedule('ride-requests-dispatch-tick');
--   drop the functions and tables above and the five ride_requests
--   columns and partners.my_ride_code.
-- ============================================================================

-- ---- Helpers -----------------------------------------------------------------

-- Great-circle distance in km.
create or replace function public.km_between(
  p_lat1 double precision, p_lng1 double precision,
  p_lat2 double precision, p_lng2 double precision
)
returns double precision
language sql
immutable
set search_path = ''
as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(p_lat2 - p_lat1) / 2), 2)
    + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
  ));
$$;

-- A positive number from a settings JSON value, else null.
create or replace function public.settings_positive_number(p_values jsonb, p_key text)
returns double precision
language plpgsql
immutable
set search_path = ''
as $$
declare
  v double precision;
begin
  if p_values is null or not (p_values ? p_key) then
    return null;
  end if;
  begin
    v := nullif(btrim(p_values->>p_key), '')::double precision;
  exception when others then
    return null;
  end;
  if v is null or v = 'NaN'::double precision or v <= 0 or v = 'Infinity'::double precision then
    return null;
  end if;
  return v;
end;
$$;

-- The dispatch settings of a vehicle service, defaults filled in.
create or replace function public.vehicle_service_dispatch_config(p_service text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_min double precision;
  v_max double precision;
  v_widen double precision;
  v_my_max double precision;
  v_window double precision;
begin
  if nullif(btrim(coalesce(p_service, '')), '') is not null then
    select e.values into v
      from public.settings_entries e
     where e.category = 'vehicle-services'
       and (lower(btrim(e.values->>'name')) = lower(btrim(p_service)) or e.id::text = btrim(p_service))
     order by e.active desc, e.position, e.created_at
     limit 1;
  end if;
  v_min    := coalesce(public.settings_positive_number(v, 'searchRadiusMinKm'), 3);
  v_max    := coalesce(public.settings_positive_number(v, 'searchRadiusMaxKm'), 15);
  v_widen  := coalesce(public.settings_positive_number(v, 'searchWidenAfterSec'), 30);
  v_my_max := public.settings_positive_number(v, 'myRideMaxKm');
  v_window := coalesce(public.settings_positive_number(v, 'myRideWindowSec'), 60);
  v_min    := least(v_min, 200);
  v_max    := least(greatest(v_max, v_min), 200);
  return jsonb_build_object(
    'search_radius_min_km', v_min,
    'search_radius_max_km', v_max,
    'widen_after_sec', least(greatest(round(v_widen), 5), 3600)::int,
    'my_ride_max_km', v_my_max,
    'my_ride_window_sec', least(greatest(round(v_window), 5), 600)::int
  );
end;
$$;

revoke execute on function public.vehicle_service_dispatch_config(text) from public, anon;
grant execute on function public.vehicle_service_dispatch_config(text) to authenticated;

-- Whether a partner may be booked / bid (as caller_is_approved_partner).
create or replace function public.partner_status_bookable(p_status text)
returns boolean
language sql
immutable
set search_path = ''
as $$ select p_status = 'approved' or p_status like 'permit-%' $$;

-- ---- Driver codes ------------------------------------------------------------

create or replace function public.gen_my_ride_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- 32 characters, so a byte mod 32 is unbiased.
  a constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  b bytea := uuid_send(gen_random_uuid());
  i int;
  s text := '';
begin
  -- Bytes 6 and 8 carry the uuid's version / variant bits; skip them.
  foreach i in array array[0, 1, 2, 3, 4, 5, 9, 10] loop
    s := s || substr(a, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return s;
end;
$$;

revoke execute on function public.gen_my_ride_code() from public, anon, authenticated;

alter table public.partners add column if not exists my_ride_code text;
alter table public.partners alter column my_ride_code set default public.gen_my_ride_code();
create unique index if not exists partners_my_ride_code_key on public.partners (my_ride_code);

do $backfill$
declare
  r record;
begin
  for r in select id from public.partners where my_ride_code is null loop
    loop
      begin
        update public.partners set my_ride_code = public.gen_my_ride_code() where id = r.id;
        exit;
      exception when unique_violation then
        null;  -- try another code
      end;
    end loop;
  end loop;
end
$backfill$;

-- A client never chooses its code: on insert it is generated, on update
-- the old one is kept. Server code and admins pass.
create or replace function public.partners_my_ride_code_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and not public.caller_is_admin() then
    if tg_op = 'INSERT' then
      new.my_ride_code := public.gen_my_ride_code();
    else
      new.my_ride_code := old.my_ride_code;
    end if;
  end if;
  if new.my_ride_code is null then
    new.my_ride_code := coalesce(case when tg_op = 'UPDATE' then old.my_ride_code end, public.gen_my_ride_code());
  else
    new.my_ride_code := upper(btrim(new.my_ride_code));
  end if;
  return new;
end;
$$;

revoke execute on function public.partners_my_ride_code_guard() from public, anon, authenticated;

drop trigger if exists trg_partners_my_ride_code on public.partners;
create trigger trg_partners_my_ride_code
  before insert or update of my_ride_code on public.partners
  for each row execute function public.partners_my_ride_code_guard();

-- The caller's partner row (the bookable one first).
create or replace function public.my_ride_own_partner(p_uid uuid)
returns public.partners
language sql
stable
security definer
set search_path = public
as $$
  select p.* from public.partners p
   where p.auth_user_id = p_uid
   order by public.partner_status_bookable(p.status::text) desc, p.created_at
   limit 1;
$$;

revoke execute on function public.my_ride_own_partner(uuid) from public, anon, authenticated;

-- The caller's code; null for an account that is not a driver.
create or replace function public.my_ride_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  p public.partners;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  p := public.my_ride_own_partner(v_uid);
  if p.id is null then
    return null;
  end if;
  if p.my_ride_code is null then
    loop
      begin
        update public.partners set my_ride_code = public.gen_my_ride_code() where id = p.id
          returning my_ride_code into p.my_ride_code;
        exit;
      exception when unique_violation then
        null;
      end;
    end loop;
  end if;
  return p.my_ride_code;
end;
$$;

revoke execute on function public.my_ride_code() from public, anon;
grant execute on function public.my_ride_code() to authenticated;

-- A new code for the caller; the old one stops working. Riders who already
-- added the driver keep them.
create or replace function public.rotate_my_ride_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  p public.partners;
  v_code text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  p := public.my_ride_own_partner(v_uid);
  if p.id is null then
    raise exception 'not_a_driver' using errcode = '42501';
  end if;
  loop
    begin
      update public.partners set my_ride_code = public.gen_my_ride_code()
       where auth_user_id = v_uid and id = p.id
       returning my_ride_code into v_code;
      exit;
    exception when unique_violation then
      null;
    end;
  end loop;
  return v_code;
end;
$$;

revoke execute on function public.rotate_my_ride_code() from public, anon;
grant execute on function public.rotate_my_ride_code() to authenticated;

-- ---- Favourites --------------------------------------------------------------

create table if not exists public.favourite_drivers (
  id               uuid primary key default gen_random_uuid(),
  rider_id         uuid not null references public.profiles(id) on delete cascade,
  -- The driver's account id (partners.auth_user_id).
  driver_id        uuid not null references auth.users(id) on delete cascade,
  created_at       timestamptz not null default now(),
  hidden_by_driver boolean not null default false,
  hidden_at        timestamptz,
  unique (rider_id, driver_id),
  check (rider_id <> driver_id)
);

create index if not exists favourite_drivers_driver on public.favourite_drivers (driver_id);

alter table public.favourite_drivers enable row level security;

drop policy if exists "favourite_drivers read" on public.favourite_drivers;
create policy "favourite_drivers read" on public.favourite_drivers
  for select using (
    (rider_id = auth.uid() and not hidden_by_driver)
    or driver_id = auth.uid()
    or public.caller_is_admin()
  );

drop policy if exists "favourite_drivers admin write" on public.favourite_drivers;
create policy "favourite_drivers admin write" on public.favourite_drivers
  for all using (public.caller_is_admin()) with check (public.caller_is_admin());

revoke all on public.favourite_drivers from public, anon, authenticated;
grant select, insert, update, delete on public.favourite_drivers to authenticated;

-- What a rider sees of a favourite driver: what they see of a driver on a
-- ride (name, photo, vehicle, plate, rating) plus make / model / colour.
-- Never a phone number.
create or replace function public.my_ride_driver_card(p public.partners)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'driver_id', p.auth_user_id,
    'name', p.name,
    'avatar_url', coalesce(nullif(p.avatar_url, ''), nullif(pr.avatar_url, ''), nullif(pr.profile_image, '')),
    'vehicle', nullif(p.vehicle, ''),
    'make', coalesce(nullif(v.make, ''), nullif(p.make, '')),
    'model', coalesce(nullif(v.model, ''), nullif(p.model, '')),
    'colour', nullif(v.color, ''),
    'plate', coalesce(nullif(v.plate, ''), nullif(p.plate, '')),
    'rating', case when coalesce(p.rating, 0) > 0 then p.rating end
  )
  from (select 1) one
  left join public.profiles pr on pr.id = p.auth_user_id
  left join lateral (
    select vv.make, vv.model, vv.color, vv.plate
      from public.vehicles vv
     where vv.partner_id = p.id
     order by public.partner_status_bookable(vv.status::text) desc, vv.updated_at desc
     limit 1
  ) v on true;
$$;

revoke execute on function public.my_ride_driver_card(public.partners) from public, anon, authenticated;

-- The driver's bookable partner row for an account id.
create or replace function public.my_ride_partner_of(p_driver uuid)
returns public.partners
language sql
stable
security definer
set search_path = public
as $$
  select p.* from public.partners p
   where p.auth_user_id = p_driver
   order by public.partner_status_bookable(p.status::text) desc, p.created_at
   limit 1;
$$;

revoke execute on function public.my_ride_partner_of(uuid) from public, anon, authenticated;

create or replace function public.add_favourite_driver(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_ip   text := public.request_client_ip();
  v_code text;
  v_wait int;
  p      public.partners;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Too many codes that matched nobody: no lookups for a while.
  select greatest(
           coalesce((select case when count(*) >= 10
                             then ceil(extract(epoch from (min(at) + interval '1 hour' - now())))::int end
                       from public.auth_rate_hits
                      where bucket = 'my_ride_code_miss' and key = v_uid::text
                        and at > now() - interval '1 hour'), 0),
           coalesce((select case when count(*) >= 30
                             then ceil(extract(epoch from (min(at) + interval '1 hour' - now())))::int end
                       from public.auth_rate_hits
                      where v_ip is not null and bucket = 'my_ride_code_miss_ip' and key = v_ip
                        and at > now() - interval '1 hour'), 0))
    into v_wait;
  if v_wait > 0 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', v_wait);
  end if;

  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_code := regexp_replace(v_code, '^GETRIDE://MYRIDE/', '');
  v_code := regexp_replace(v_code, '[/-]', '', 'g');
  if v_code !~ '^[2-9A-HJ-NP-Z]{8}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  select * into p from public.partners where my_ride_code = v_code limit 1;
  if p.id is null or p.auth_user_id is null then
    perform public.auth_rate_take('my_ride_code_miss', v_uid::text, 10, interval '1 hour');
    perform public.auth_rate_take('my_ride_code_miss_ip', v_ip, 30, interval '1 hour');
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if p.auth_user_id = v_uid then
    return jsonb_build_object('ok', false, 'error', 'own_code');
  end if;
  if p.status::text in ('blocked', 'rejected') then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  if not exists (select 1 from public.favourite_drivers where rider_id = v_uid and driver_id = p.auth_user_id)
     and (select count(*) from public.favourite_drivers where rider_id = v_uid) >= 50 then
    return jsonb_build_object('ok', false, 'error', 'limit_reached');
  end if;
  -- A profile row is what the rider id points at; every signed-in account
  -- has one, but don't fail on one that hasn't.
  if not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'no_profile');
  end if;

  insert into public.favourite_drivers (rider_id, driver_id)
  values (v_uid, p.auth_user_id)
  on conflict (rider_id, driver_id) do nothing;

  return jsonb_build_object('ok', true, 'driver', public.my_ride_driver_card(p));
end;
$$;

revoke execute on function public.add_favourite_driver(text) from public, anon;
grant execute on function public.add_favourite_driver(text) to authenticated;

-- The rider's favourites. `available` is false for a driver who hid the
-- rider or can't take rides (blocked, not approved) — the two read alike,
-- and nothing more (online, distance) is shown for either.
create or replace function public.my_favourite_drivers(
  p_lat double precision default null,
  p_lng double precision default null
)
returns table (
  driver_id    uuid,
  added_at     timestamptz,
  available    boolean,
  online       boolean,
  last_seen    text,
  distance_km  double precision,
  name         text,
  avatar_url   text,
  vehicle      text,
  make         text,
  model        text,
  colour       text,
  plate        text,
  rating       numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lat double precision := case when p_lat between -90 and 90 then p_lat end;
  v_lng double precision := case when p_lng between -180 and 180 then p_lng end;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  with fav as (
    select f.driver_id as did, f.created_at as at, f.hidden_by_driver as hidden,
           public.my_ride_partner_of(f.driver_id) as p
      from public.favourite_drivers f
     where f.rider_id = v_uid
  ), card as (
    select fav.did, fav.at,
           (not fav.hidden and (fav.p).id is not null
              and public.partner_status_bookable((fav.p).status::text)) as ok,
           case when (fav.p).id is not null then public.my_ride_driver_card(fav.p) end as c,
           d.online as d_online, d.updated_at as d_at, d.lat as d_lat, d.lng as d_lng
      from fav
      left join public.driver_presence d on d.profile_id = fav.did
  )
  select card.did,
         card.at,
         coalesce(card.ok, false),
         coalesce(card.ok and card.d_online and card.d_at > now() - interval '3 minutes', false),
         case
           when not coalesce(card.ok, false) or card.d_at is null then null
           when card.d_online and card.d_at > now() - interval '3 minutes' then 'online'
           when card.d_at > now() - interval '1 hour' then 'recent'
           when card.d_at > now() - interval '1 day' then 'today'
           else 'away'
         end,
         case
           when coalesce(card.ok, false) and card.d_online and card.d_at > now() - interval '3 minutes'
                and v_lat is not null and v_lng is not null and card.d_lat is not null and card.d_lng is not null
           then round(public.km_between(v_lat, v_lng, card.d_lat, card.d_lng) * 2) / 2
         end,
         coalesce(card.c->>'name', 'Driver'),
         card.c->>'avatar_url',
         card.c->>'vehicle',
         card.c->>'make',
         card.c->>'model',
         card.c->>'colour',
         card.c->>'plate',
         (card.c->>'rating')::numeric
    from card
   order by coalesce(card.ok, false) desc, card.at desc;
end;
$$;

revoke execute on function public.my_favourite_drivers(double precision, double precision) from public, anon;
grant execute on function public.my_favourite_drivers(double precision, double precision) to authenticated;

-- ---- The driver's side ---------------------------------------------------------

create or replace function public.my_favourite_riders()
returns table (
  rider_id       uuid,
  name           text,
  added_at       timestamptz,
  hidden         boolean,
  hidden_at      timestamptz,
  rides_together integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  select f.rider_id,
         coalesce(public.wallet_mask_name(pr.name), 'Rider'),
         f.created_at,
         f.hidden_by_driver,
         f.hidden_at,
         (select count(*)::int from public.ride_requests r
           where r.rider_id = f.rider_id and r.partner_id = v_uid and r.status = 'completed')
    from public.favourite_drivers f
    left join public.profiles pr on pr.id = f.rider_id
   where f.driver_id = v_uid
   order by f.hidden_by_driver, f.created_at desc;
end;
$$;

revoke execute on function public.my_favourite_riders() from public, anon;
grant execute on function public.my_favourite_riders() to authenticated;

-- Riders who have the caller as a favourite and are not hidden: their
-- requests get the gold star.
create or replace function public.my_favourite_rider_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select f.rider_id from public.favourite_drivers f
   where auth.uid() is not null and f.driver_id = auth.uid() and not f.hidden_by_driver;
$$;

revoke execute on function public.my_favourite_rider_ids() from public, anon;
grant execute on function public.my_favourite_rider_ids() to authenticated;

-- ---- ride_requests: targeting columns -----------------------------------------

alter table public.ride_requests
  add column if not exists target_driver_ids  uuid[],
  add column if not exists targeted_until     timestamptz,
  add column if not exists my_ride_max_km     double precision,
  add column if not exists fallback_pushed_at timestamptz,
  add column if not exists widened_pushed_at  timestamptz;

-- Who has been pushed about which request (so widening never repeats a
-- push). profile_id null marks the every-driver broadcast.
create table if not exists public.ride_request_pushes (
  id          bigserial primary key,
  request_id  uuid not null references public.ride_requests(id) on delete cascade,
  profile_id  uuid,
  kind        text not null,
  at          timestamptz not null default now()
);
create unique index if not exists ride_request_pushes_once
  on public.ride_request_pushes (request_id, profile_id) where profile_id is not null;
create index if not exists ride_request_pushes_at on public.ride_request_pushes (at);

alter table public.ride_request_pushes enable row level security;
revoke all on table public.ride_request_pushes from public, anon, authenticated;
revoke all on sequence public.ride_request_pushes_id_seq from public, anon, authenticated;

-- Whether a request's favourites window is running.
create or replace function public.ride_request_targeting(p_targets uuid[], p_until timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$ select coalesce(cardinality(p_targets), 0) > 0 and p_until is not null and p_until > now() $$;

-- [p_candidates] narrowed to the rider's own non-hidden, bookable
-- favourites not known to be farther than [p_max_km] from the pickup.
create or replace function public.my_ride_valid_targets(
  p_rider uuid,
  p_candidates uuid[],
  p_lat double precision,
  p_lng double precision,
  p_max_km double precision
)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select array_agg(t.did order by t.did)
    from (
      select distinct f.driver_id as did
        from public.favourite_drivers f
       where f.rider_id = p_rider
         and f.driver_id = any(coalesce(p_candidates, '{}'))
         and f.driver_id <> p_rider
         and not f.hidden_by_driver
         and exists (select 1 from public.partners p
                      where p.auth_user_id = f.driver_id
                        and public.partner_status_bookable(p.status::text))
         and (p_max_km is null or p_lat is null or p_lng is null
              or not exists (
                select 1 from public.driver_presence d
                 where d.profile_id = f.driver_id
                   and d.updated_at > now() - interval '3 minutes'
                   and d.lat is not null and d.lng is not null
                   and public.km_between(p_lat, p_lng, d.lat, d.lng) > p_max_km))
       limit 20
    ) t;
$$;

revoke execute on function public.my_ride_valid_targets(uuid, uuid[], double precision, double precision, double precision)
  from public, anon, authenticated;

create or replace function public.ride_requests_my_ride_targets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.vehicle_service_dispatch_config(new.service);
  v_rider_max double precision := case when new.my_ride_max_km > 0 then new.my_ride_max_km end;
  v_max double precision;
  v_targets uuid[];
begin
  new.targeted_until := null;
  new.fallback_pushed_at := null;
  new.widened_pushed_at := null;
  -- The smaller of the rider's and the service's caps (least() skips nulls).
  v_max := least(v_rider_max, (cfg->>'my_ride_max_km')::double precision);
  new.my_ride_max_km := v_max;

  if coalesce(cardinality(new.target_driver_ids), 0) > 0 and new.status = 'open' and new.rider_id is not null then
    v_targets := public.my_ride_valid_targets(new.rider_id, new.target_driver_ids, new.pickup_lat, new.pickup_lng, v_max);
  end if;
  if coalesce(cardinality(v_targets), 0) > 0 then
    new.target_driver_ids := v_targets;
    new.targeted_until := now() + make_interval(secs => (cfg->>'my_ride_window_sec')::int);
  else
    new.target_driver_ids := null;
  end if;

  -- Open to everybody from the start: where nobody is within the min
  -- radius, the insert push goes straight to the max radius.
  if new.status = 'open' and new.targeted_until is null
     and not exists (select 1 from public.nearby_online_drivers(new.pickup_lat, new.pickup_lng,
                                                                (cfg->>'search_radius_min_km')::double precision) d
                      where d is distinct from new.rider_id) then
    new.widened_pushed_at := now();
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_my_ride_targets() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_my_ride on public.ride_requests;
create trigger trg_ride_requests_c_my_ride
  before insert on public.ride_requests
  for each row execute function public.ride_requests_my_ride_targets();

create or replace function public.ride_requests_my_ride_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  -- The server's columns.
  new.target_driver_ids := old.target_driver_ids;
  new.targeted_until := old.targeted_until;
  new.my_ride_max_km := old.my_ride_max_km;
  new.fallback_pushed_at := old.fallback_pushed_at;
  new.widened_pushed_at := old.widened_pushed_at;
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

revoke execute on function public.ride_requests_my_ride_guard() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_my_ride_guard on public.ride_requests;
create trigger trg_ride_requests_c_my_ride_guard
  before update on public.ride_requests
  for each row execute function public.ride_requests_my_ride_guard();

-- Reads: as 0097, except that an open request inside its favourites window
-- is only for its rider, its targeted drivers and admins.
drop policy if exists "ride_requests read" on public.ride_requests;
create policy "ride_requests read"
  on public.ride_requests for select
  using (
    (status = 'open'
      and (targeted_until is null
           or targeted_until <= now()
           or coalesce(cardinality(target_driver_ids), 0) = 0
           or auth.uid() = any(target_driver_ids)))
    or rider_id = auth.uid()
    or partner_id = auth.uid()
    or public.caller_is_admin()
  );

-- ---- Push ------------------------------------------------------------------------

-- Pushes each online driver within [p_radius_km] of the pickup (not the
-- rider; with [p_once], not anyone already told about the request) and
-- records them. Returns how many were pushed.
create or replace function public.ride_request_push_nearby(
  p_request uuid,
  p_rider uuid,
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision,
  p_message jsonb,
  p_kind text,
  p_once boolean
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver uuid;
  v_told int := 0;
  n int;
begin
  for v_driver in select * from public.nearby_online_drivers(p_lat, p_lng, p_radius_km) loop
    continue when v_driver = p_rider;
    insert into public.ride_request_pushes (request_id, profile_id, kind)
    values (p_request, v_driver, p_kind)
    on conflict (request_id, profile_id) where profile_id is not null do nothing;
    get diagnostics n = row_count;
    continue when p_once and n = 0;
    perform public.send_push_webhook(p_message || jsonb_build_object('profileId', v_driver));
    v_told := v_told + 1;
  end loop;
  return v_told;
end;
$$;

revoke execute on function public.ride_request_push_nearby(uuid, uuid, double precision, double precision, double precision, jsonb, text, boolean)
  from public, anon, authenticated;

-- Every driver, as 0145 did when nobody was known nearby.
create or replace function public.ride_request_push_everyone(p_request uuid, p_message jsonb, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ride_request_pushes (request_id, profile_id, kind) values (p_request, null, p_kind);
  perform public.send_push_webhook(p_message || jsonb_build_object('audience', 'partners'));
end;
$$;

revoke execute on function public.ride_request_push_everyone(uuid, jsonb, text) from public, anon, authenticated;

-- {title, body, data} for a request.
create or replace function public.ride_request_push_message(
  p_request uuid, p_pickup_name text, p_pickup_address text, p_fare numeric, p_currency text,
  p_kind text
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'title', case p_kind
               when 'raised' then 'Fare increased'
               when 'my_ride' then 'Your regular rider needs a ride'
               else 'New ride request' end,
    'body', case when p_kind = 'raised' then 'Higher fare — pickup at ' else 'Pickup at ' end
            || coalesce(nullif(p_pickup_name, ''), nullif(p_pickup_address, ''), 'a nearby location')
            || case when p_fare is not null
                    then ' • ' || public.currency_symbol(p_currency) || ' ' || p_fare::text
                    else '' end,
    'data', jsonb_build_object(
      'type', case when p_kind = 'raised' then 'ride_request_fare_raised' else 'ride_request' end,
      'ride_request_id', p_request,
      'my_ride', p_kind = 'my_ride'
    )
  );
$$;

revoke execute on function public.ride_request_push_message(uuid, text, text, numeric, text, text)
  from public, anon, authenticated;

-- Pushes the targeted drivers in [p_drivers] who haven't been told yet.
create or replace function public.ride_request_push_targets(p_request uuid, p_drivers uuid[], p_message jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver uuid;
  v_told int := 0;
  n int;
begin
  foreach v_driver in array coalesce(p_drivers, '{}') loop
    insert into public.ride_request_pushes (request_id, profile_id, kind)
    values (p_request, v_driver, 'my_ride')
    on conflict (request_id, profile_id) where profile_id is not null do nothing;
    get diagnostics n = row_count;
    continue when n = 0;
    perform public.send_push_webhook(p_message || jsonb_build_object('profileId', v_driver));
    v_told := v_told + 1;
  end loop;
  return v_told;
end;
$$;

revoke execute on function public.ride_request_push_targets(uuid, uuid[], jsonb) from public, anon, authenticated;

create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  cfg      jsonb;
  v_raised boolean := tg_op = 'UPDATE';
  v_msg    jsonb;
  v_radius double precision;
  v_driver uuid;
  v_told   int := 0;
begin
  -- Only ever notify about requests that are still open (biddable).
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- On UPDATE, fire only when the passenger raised their fare on the open row.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  -- Inside the favourites window: the targeted drivers, wherever they are.
  if public.ride_request_targeting(new.target_driver_ids, new.targeted_until) then
    v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                              case when v_raised then 'raised' else 'my_ride' end);
    if v_raised then
      foreach v_driver in array new.target_driver_ids loop
        continue when v_driver = new.rider_id;
        perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      end loop;
    else
      perform public.ride_request_push_targets(new.id, new.target_driver_ids, v_msg);
    end if;
    return new;
  end if;

  -- Open to all: the drivers near the pickup — the service's min radius,
  -- or its max once widened.
  cfg := public.vehicle_service_dispatch_config(new.service);
  v_radius := case when new.widened_pushed_at is not null
                   then (cfg->>'search_radius_max_km')::double precision
                   else (cfg->>'search_radius_min_km')::double precision end;
  v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                            case when v_raised then 'raised' else 'new' end);
  v_told := public.ride_request_push_nearby(new.id, new.rider_id, new.pickup_lat, new.pickup_lng, v_radius, v_msg,
                                            case when v_raised then 'raised' else 'nearby' end, false);

  -- Nobody known nearby: every driver, as before.
  if v_told = 0 then
    perform public.ride_request_push_everyone(new.id, v_msg, case when v_raised then 'raised' else 'everyone' end);
  end if;

  return new;
exception when others then
  -- Never let a notification failure block the ride request write.
  return new;
end;
$$;

-- The favourites window of [p_request] is over (or the rider ended it):
-- open it to everybody now and push the drivers near the pickup — the min
-- radius, or the max where nobody is that close, or every driver where
-- nobody is within that either. Returns how many drivers were pushed (-1
-- when there was nothing to do).
create or replace function public.ride_request_open_to_all(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  cfg jsonb;
  v_msg jsonb;
  v_min double precision;
  v_max double precision;
  v_told int := 0;
  v_widened timestamptz;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.status <> 'open' or r.targeted_until is null or r.fallback_pushed_at is not null then
    return -1;
  end if;
  cfg := public.vehicle_service_dispatch_config(r.service);
  v_min := (cfg->>'search_radius_min_km')::double precision;
  v_max := (cfg->>'search_radius_max_km')::double precision;

  update public.ride_requests
     set targeted_until = least(targeted_until, now()),
         fallback_pushed_at = now()
   where id = p_request;

  begin
    v_msg := public.ride_request_push_message(r.id, r.pickup_name, r.pickup_address, r.fare, r.currency, 'new');
    v_told := public.ride_request_push_nearby(r.id, r.rider_id, r.pickup_lat, r.pickup_lng, v_min, v_msg, 'fallback', true);
    if not exists (select 1 from public.nearby_online_drivers(r.pickup_lat, r.pickup_lng, v_min) d
                    where d is distinct from r.rider_id) then
      v_widened := now();
      v_told := v_told + public.ride_request_push_nearby(r.id, r.rider_id, r.pickup_lat, r.pickup_lng, v_max, v_msg,
                                                         'fallback', true);
      if v_told = 0
         and not exists (select 1 from public.nearby_online_drivers(r.pickup_lat, r.pickup_lng, v_max) d
                          where d is distinct from r.rider_id) then
        perform public.ride_request_push_everyone(r.id, v_msg, 'everyone');
      end if;
    end if;
  exception when others then
    null;  -- a push failure never keeps the request from opening
  end;

  if v_widened is not null then
    update public.ride_requests set widened_pushed_at = v_widened where id = p_request and widened_pushed_at is null;
  end if;
  return v_told;
end;
$$;

revoke execute on function public.ride_request_open_to_all(uuid) from public, anon, authenticated;

-- A request open to all for the service's searchWidenAfterSec without
-- being taken: push the drivers out to the max radius not told yet.
-- Returns how many were pushed (-1 when it was not due).
create or replace function public.ride_request_widen(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  cfg jsonb;
  v_msg jsonb;
  v_told int := 0;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.status <> 'open' or r.widened_pushed_at is not null
     or (r.targeted_until is not null and r.fallback_pushed_at is null) then
    return -1;
  end if;
  cfg := public.vehicle_service_dispatch_config(r.service);
  if coalesce(r.fallback_pushed_at, r.created_at) > now() - make_interval(secs => (cfg->>'widen_after_sec')::int) then
    return -1;
  end if;
  update public.ride_requests set widened_pushed_at = now() where id = p_request;
  begin
    v_msg := public.ride_request_push_message(r.id, r.pickup_name, r.pickup_address, r.fare, r.currency, 'new');
    v_told := public.ride_request_push_nearby(r.id, r.rider_id, r.pickup_lat, r.pickup_lng,
                                              (cfg->>'search_radius_max_km')::double precision, v_msg, 'widened', true);
  exception when others then
    null;
  end;
  return v_told;
end;
$$;

revoke execute on function public.ride_request_widen(uuid) from public, anon, authenticated;

-- The scheduled pass: windows that ended, then requests due to widen.
-- Returns how many requests it acted on.
create or replace function public.ride_requests_dispatch_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := 0;
begin
  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and created_at > now() - interval '15 minutes'
       and targeted_until is not null and targeted_until <= now()
       and fallback_pushed_at is null
  loop
    if public.ride_request_open_to_all(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and created_at > now() - interval '15 minutes'
       and widened_pushed_at is null
       and (targeted_until is null or fallback_pushed_at is not null)
  loop
    if public.ride_request_widen(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  delete from public.ride_request_pushes where at < now() - interval '1 day';
  return n;
end;
$$;

revoke execute on function public.ride_requests_dispatch_tick() from public, anon, authenticated;
grant execute on function public.ride_requests_dispatch_tick() to service_role;

-- ---- The rider during the search -------------------------------------------------

-- "Offer to all nearby": the rider ends the favourites window now.
create or replace function public.ride_request_offer_to_all(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v_told int;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request_id;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'not_open');
  end if;
  v_told := public.ride_request_open_to_all(p_request_id);
  return jsonb_build_object('ok', true, 'opened', v_told >= 0, 'told', greatest(v_told, 0));
end;
$$;

revoke execute on function public.ride_request_offer_to_all(uuid) from public, anon;
grant execute on function public.ride_request_offer_to_all(uuid) to authenticated;

-- The rider adds favourites to their open request while searching. Only
-- their own, not hidden, bookable favourites within the request's distance
-- cap are added (at most 20 in all); each one added is pushed. Returns the
-- request's target list.
create or replace function public.ride_request_add_targets(p_request_id uuid, p_driver_ids uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v_new uuid[];
  v_all uuid[];
  v_msg jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request_id for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'open' then
    raise exception 'not_open' using errcode = '22023';
  end if;
  v_new := public.my_ride_valid_targets(
    v_uid,
    array(select d from unnest(coalesce(p_driver_ids, '{}')) d
           where not (d = any(coalesce(r.target_driver_ids, '{}')))),
    r.pickup_lat, r.pickup_lng, r.my_ride_max_km);
  v_new := v_new[1:greatest(0, 20 - coalesce(cardinality(r.target_driver_ids), 0))];
  if coalesce(cardinality(v_new), 0) = 0 then
    return coalesce(r.target_driver_ids, '{}');
  end if;
  v_all := coalesce(r.target_driver_ids, '{}') || v_new;
  update public.ride_requests set target_driver_ids = v_all where id = p_request_id;
  begin
    v_msg := public.ride_request_push_message(r.id, r.pickup_name, r.pickup_address, r.fare, r.currency, 'my_ride');
    perform public.ride_request_push_targets(r.id, v_new, v_msg);
  exception when others then
    null;
  end;
  return v_all;
end;
$$;

revoke execute on function public.ride_request_add_targets(uuid, uuid[]) from public, anon;
grant execute on function public.ride_request_add_targets(uuid, uuid[]) to authenticated;

-- Takes [p_driver] off [p_rider]'s open requests. A request left with
-- nobody to wait for inside its window opens to everybody at once.
create or replace function public.ride_requests_drop_target(p_rider uuid, p_driver uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  for v_id in
    update public.ride_requests
       set target_driver_ids = nullif(array_remove(target_driver_ids, p_driver), '{}')
     where rider_id = p_rider and status = 'open' and p_driver = any(target_driver_ids)
    returning id
  loop
    if exists (select 1 from public.ride_requests
                where id = v_id and target_driver_ids is null
                  and targeted_until is not null and fallback_pushed_at is null) then
      perform public.ride_request_open_to_all(v_id);
    end if;
  end loop;
end;
$$;

revoke execute on function public.ride_requests_drop_target(uuid, uuid) from public, anon, authenticated;

create or replace function public.remove_favourite_driver(p_driver_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  n int;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  delete from public.favourite_drivers where rider_id = v_uid and driver_id = p_driver_id;
  get diagnostics n = row_count;
  -- Off the rider's open requests too.
  perform public.ride_requests_drop_target(v_uid, p_driver_id);
  return n > 0;
end;
$$;

revoke execute on function public.remove_favourite_driver(uuid) from public, anon;
grant execute on function public.remove_favourite_driver(uuid) to authenticated;

-- The driver hides (or shows again) a rider who added them. Hiding takes
-- the driver off that rider's open requests; a request left with nobody to
-- wait for opens to everybody at once.
create or replace function public.hide_favourite_rider(p_rider_id uuid, p_hidden boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  n int;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.favourite_drivers
     set hidden_by_driver = coalesce(p_hidden, false),
         hidden_at = case when coalesce(p_hidden, false) then coalesce(hidden_at, now()) end
   where driver_id = v_uid and rider_id = p_rider_id;
  get diagnostics n = row_count;
  if n > 0 and coalesce(p_hidden, false) then
    perform public.ride_requests_drop_target(p_rider_id, v_uid);
  end if;
  return n > 0;
end;
$$;

revoke execute on function public.hide_favourite_rider(uuid, boolean) from public, anon;
grant execute on function public.hide_favourite_rider(uuid, boolean) to authenticated;

-- ---- Schedule ------------------------------------------------------------------

-- Every 20 seconds where pg_cron takes seconds schedules (1.5+), else every
-- minute. Guarded as 0097 / 0139: a Postgres without pg_cron gets a notice.
do $$
begin
  create extension if not exists pg_cron;
  begin
    perform cron.schedule('ride-requests-dispatch-tick', '20 seconds',
                          $cmd$ select public.ride_requests_dispatch_tick(); $cmd$);
  exception when undefined_table or undefined_file or undefined_function or feature_not_supported
                 or insufficient_privilege then
    raise;
  when others then
    perform cron.schedule('ride-requests-dispatch-tick', '* * * * *',
                          $cmd$ select public.ride_requests_dispatch_tick(); $cmd$);
  end;
exception
  when undefined_table or undefined_file or undefined_function or feature_not_supported or insufficient_privilege then
    raise notice 'pg_cron not available, so My Ride fallback and radius widening are not scheduled. Call public.ride_requests_dispatch_tick() from a scheduled job instead.';
end$$;

notify pgrst, 'reload schema';
