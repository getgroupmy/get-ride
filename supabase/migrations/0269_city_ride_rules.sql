-- ============================================================================
-- 0269 — City ride: many offers at once, drivers rate riders, cancel and
-- no-show rules by place, and route safety checks.
--
-- Applied by hand as version 20261021032700 (0269_city_ride_rules in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", and the one-time settings
-- flip is marked so it runs once.
--
-- 1. Many offers at once (lib/src/core/ride_offers.dart):
--    * public.ride_offers: one row per driver's offer on an open request
--      (amount, ETA, where they were, their card), status open, declined,
--      expired, accepted or withdrawn, with why it closed (closed_reason:
--      declined, expired, taken, raised, replaced, cancelled, withdrawn).
--      The request's rider and the offering driver read their rows; nobody
--      writes them but these functions.
--    * ride_offer_make(request, amount, eta, lat, lng): the driver's offer,
--      in place of the single-bid row write. It replaces their own open
--      one, lasts the admin's lifetime (15 s), is refused when the driver
--      was declined (once again allowed when the admin says so), while their
--      offers are paused for cancelling too much, or when they could not take
--      the ride (approved, their type offered at the pickup, not their own).
--      The latest open offer is mirrored into the request's old single-bid
--      columns (offered_fare, partner_*), so older apps see a bid, and the
--      rider's auto-accept (0141) still takes one at or under its limit.
--    * ride_offer_accept(offer): the rider takes one offer by id. The ride is
--      assigned to that driver at that amount, atomically; every other open
--      offer is withdrawn (taken), which the other drivers' apps show.
--    * ride_offer_decline(offer) and ride_offer_withdraw(request).
--    * A trigger keeps the rows in step with the request whoever writes it
--      (an older rider app's accept or decline, an older driver app's bid, a
--      raise, a cancel); a 15-second job expires offers that ran out.
--    * Settings (app_settings 'city_ride_offers'): offers shown at once (5,
--      the rest queue), lifetime (15 s), first sort (cheapest; the rider
--      switches to nearest or top rated), offer again once after a decline
--      (on).
--
-- 2. Drivers rate riders:
--    * public.rider_ratings and rate_rider(request, stars, tags): the
--      ride's driver, within 24 hours of the drop-off; tags from the two
--      lists (low for 3 stars or less, high above).
--    * profiles.rider_rating / rider_ratings_count: the average over the
--      rider's last N ratings (100). Only the server writes them.
--    * A new request's rider_rating, rider_ratings_count and rider_trips are
--      stamped by the server (the app sent a made-up 5).
--    * Settings (app_settings 'rider_rating'): N (100), "New rider" under
--      5 ratings, low below 4.0.
--
-- 5. Cancel and no-show by place (lib/src/core/city_cancel.dart):
--    * public.ride_cancel_places: Default, or a country, state, city or
--      suburb (keyed as 0253's ride_option_places), with rules: free cancel
--      minutes after accept (2), late cancel fee (RM 3), cancel after the
--      driver arrived (RM 5), no-show after waiting (5 min) and its fee
--      (RM 5). A key a place sets wins over the place above.
--    * A rider's cancel of a city ride (open requests and scheduled rides
--      excepted) pays the fee it was due when the rider asked; a safety
--      reason (driver not moving, wrong car) is always free. The fee comes
--      from GET.wallet and goes to the driver less the ride's commission
--      rate; a wallet that is short leaves it due (rider_fee_dues), added
--      to the rider's next ride (ride_requests.prior_fees, in what they
--      owe) and paid to that driver when it completes.
--    * ride_no_show(ride): the driver, after waiting the minutes at the
--      pickup, ends it as a no-show and the rider pays the no-show fee.
--    * ride_cancel_terms(ride): what the app shows ("Free to cancel for
--      m:ss", the fee on the button).
--    * A driver whose cancels in the last 7 days pass 20% (at least 5 rides)
--      can't send offers for 30 minutes (profiles.offers_paused_until).
--      driver_cancel_stats() shows them their rate. Settings: app_settings
--      'driver_cancel_limit'.
--
-- 6. Safety:
--    * The route check (reliability row, next to 0154's switches): off the
--      planned route 500 m for 2 min, or stopped 5 min. The rider's app
--      asks; trip_route_report() records the answer, and no answer in 60 s
--      raises the SOS ops incident (sos_raise, 0193) without the call and
--      texts the rider's emergency contacts the live link.
--    * 0154's "Are you in the car?" and "Still on your trip?" checks are on
--      by default.
--    * A trip that starts sends the rider's emergency contacts the live link
--      (0108's share token) by SMS or WhatsApp through the gateway's new
--      "Trip share" channel (routed as the sign-in codes are), when the
--      rider's profiles.trip_share_mode says so: every trip, at night only
--      (10 pm to 6 am in the ride's time zone; the default) or never.
--
-- Admin writes: set_city_ride_config() asks caller_admin_can_write
-- ('rpc:set_city_ride_config'), ride_cancel_places caller_admin_can_write
-- ('ride_cancel_places'), both granted to Admin > App Settings
-- (admin-settings-site), where the cards are. The safety settings are the
-- reliability row, written as 0154's are.
-- ============================================================================

-- ---- 0. Settings ---------------------------------------------------------------------------------
-- The new profile columns: the rider's rating (the server's), a driver's
-- offer pause (the server's) and the rider's trip-share choice (their own).
alter table public.profiles add column if not exists rider_rating numeric(3,2);
alter table public.profiles add column if not exists rider_ratings_count integer not null default 0;
alter table public.profiles add column if not exists offers_paused_until timestamptz;
alter table public.profiles add column if not exists trip_share_mode text not null default 'night';
alter table public.profiles drop constraint if exists profiles_trip_share_mode_check;
alter table public.profiles add constraint profiles_trip_share_mode_check
  check (trip_share_mode in ('always', 'night', 'never'));

-- One reader for the app: offers, rider ratings and the driver cancel limit,
-- each cleaned and with its defaults.
create or replace function public.city_ride_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select coalesce((select s.value from public.app_settings s where s.key = 'city_ride_offers'), '{}'::jsonb) as o,
           coalesce((select s.value from public.app_settings s where s.key = 'rider_rating'), '{}'::jsonb) as r,
           coalesce((select s.value from public.app_settings s where s.key = 'driver_cancel_limit'), '{}'::jsonb) as d
  )
  select jsonb_build_object(
    'offers', jsonb_build_object(
      'shown', least(10, greatest(1, coalesce(
        case when jsonb_typeof(o->'shown') = 'number' then (o->>'shown')::numeric end, 5)))::int,
      'lifetimeSeconds', least(120, greatest(5, coalesce(
        case when jsonb_typeof(o->'lifetimeSeconds') = 'number' then (o->>'lifetimeSeconds')::numeric end, 15)))::int,
      'sort', case when o->>'sort' in ('cheapest', 'nearest', 'rating') then o->>'sort' else 'cheapest' end,
      'reofferAfterDecline', coalesce((o->>'reofferAfterDecline')::boolean, true)),
    'riderRating', jsonb_build_object(
      'window', least(1000, greatest(5, coalesce(
        case when jsonb_typeof(r->'window') = 'number' then (r->>'window')::numeric end, 100)))::int,
      'newBelow', least(50, greatest(0, coalesce(
        case when jsonb_typeof(r->'newBelow') = 'number' then (r->>'newBelow')::numeric end, 5)))::int,
      'lowBelow', round(least(5, greatest(1, coalesce(
        case when jsonb_typeof(r->'lowBelow') = 'number' then (r->>'lowBelow')::numeric end, 4.0))), 1)),
    'driverCancel', jsonb_build_object(
      'limitPercent', least(100, greatest(1, coalesce(
        case when jsonb_typeof(d->'limitPercent') = 'number' then (d->>'limitPercent')::numeric end, 20)))::int,
      'days', least(30, greatest(1, coalesce(
        case when jsonb_typeof(d->'days') = 'number' then (d->>'days')::numeric end, 7)))::int,
      'pauseMinutes', least(1440, greatest(1, coalesce(
        case when jsonb_typeof(d->'pauseMinutes') = 'number' then (d->>'pauseMinutes')::numeric end, 30)))::int,
      'minRides', least(100, greatest(1, coalesce(
        case when jsonb_typeof(d->'minRides') = 'number' then (d->>'minRides')::numeric end, 5)))::int))
  from v;
$$;
revoke execute on function public.city_ride_config() from public, anon;
grant execute on function public.city_ride_config() to authenticated;

-- Admin: one section ('offers', 'riderRating' or 'driverCancel') at a time.
create or replace function public.set_city_ride_config(p_section text, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := case p_section when 'offers' then 'city_ride_offers'
                               when 'riderRating' then 'rider_rating'
                               when 'driverCancel' then 'driver_cancel_limit' end;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:set_city_ride_config') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_key is null or jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'bad_section' using errcode = '22023';
  end if;
  insert into public.app_settings (key, value, updated_at) values (v_key, p_config, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  -- Stored as read back: cleaned and with every default.
  update public.app_settings set value = public.city_ride_config()->p_section where key = v_key;
  return public.city_ride_config();
end;
$$;
revoke execute on function public.set_city_ride_config(text, jsonb) from public, anon;
grant execute on function public.set_city_ride_config(text, jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:set_city_ride_config', 'admin-settings-site'),
  ('ride_cancel_places', 'admin-settings-site')
on conflict do nothing;

-- ---- 1. Many offers at once ---------------------------------------------------------------------
create table if not exists public.ride_offers (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references public.ride_requests(id) on delete cascade,
  partner_id    uuid not null,
  amount        numeric(10,2) not null check (amount > 0),
  eta_min       integer check (eta_min is null or eta_min between 0 and 240),
  from_lat      double precision,
  from_lng      double precision,
  partner_name  text,
  partner_photo text,
  partner_rating numeric(3,2),
  partner_trips integer,
  partner_vehicle text,
  partner_plate text,
  partner_plate_colours jsonb,
  -- The moment itself (several offers can land in one transaction).
  created_at    timestamptz not null default clock_timestamp(),
  expires_at    timestamptz not null,
  status        text not null default 'open'
                check (status in ('open', 'declined', 'expired', 'accepted', 'withdrawn')),
  closed_reason text check (closed_reason is null or closed_reason in
                ('declined', 'expired', 'taken', 'raised', 'replaced', 'cancelled', 'withdrawn')),
  closed_at     timestamptz
);
alter table public.ride_offers alter column created_at set default clock_timestamp();
create index if not exists ride_offers_request_idx on public.ride_offers (request_id, created_at desc);
create index if not exists ride_offers_partner_idx on public.ride_offers (partner_id, created_at desc);
create index if not exists ride_offers_open_idx on public.ride_offers (expires_at) where status = 'open';
-- One open offer per driver per request.
create unique index if not exists ride_offers_one_open_uidx on public.ride_offers (request_id, partner_id)
  where status = 'open';
comment on table public.ride_offers is
  'Drivers'' offers on an open ride request (0269): many at once. Written only by ride_offer_* functions and the request trigger; the latest open one is mirrored into ride_requests.offered_fare for older apps.';

alter table public.ride_offers enable row level security;
revoke all on public.ride_offers from anon, authenticated;
grant select on public.ride_offers to authenticated;
drop policy if exists "ride_offers parties read" on public.ride_offers;
create policy "ride_offers parties read" on public.ride_offers for select to authenticated
  using (partner_id = (select auth.uid())
         or exists (select 1 from public.ride_requests r
                     where r.id = ride_offers.request_id and r.rider_id = (select auth.uid()))
         or (select public.caller_is_admin()));

-- The latest open, unexpired offer of [p_request] onto the request's
-- single-bid columns (null when there is none). The request must be open.
create or replace function public.ride_offers_mirror(p_request uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ride_offers;
  v_status text;
  v_partner uuid;
begin
  perform set_config('city_ride.offer_write', 'on', true);
  select * into o from public.ride_offers x
   where x.request_id = p_request and x.status = 'open' and x.expires_at > clock_timestamp()
   order by x.created_at desc, x.id limit 1;
  if found then
    update public.ride_requests
       set offered_fare = o.amount, partner_id = o.partner_id, partner_name = o.partner_name,
           partner_photo = o.partner_photo, partner_rating = o.partner_rating, partner_trips = o.partner_trips,
           partner_vehicle = o.partner_vehicle, partner_plate = o.partner_plate,
           partner_accept_lat = o.from_lat, partner_accept_lng = o.from_lng
     where id = p_request and status = 'open'
    returning status, partner_id into v_status, v_partner;
    -- The rider's auto-accept (0141) took it as it landed.
    if v_status is distinct from 'open' and v_partner is not null then
      update public.ride_offers set status = 'accepted', closed_at = now()
       where request_id = p_request and partner_id = v_partner and status = 'open';
      perform public.ride_offers_close(p_request, 'withdrawn', 'taken', v_partner);
    end if;
  else
    update public.ride_requests
       set offered_fare = null, partner_id = null, partner_name = null, partner_phone = null,
           partner_photo = null, partner_rating = null, partner_trips = null, partner_vehicle = null,
           partner_plate = null, vehicle_id = null, partner_accept_lat = null, partner_accept_lng = null
     where id = p_request and status = 'open' and (partner_id is not null or offered_fare is not null);
  end if;
  perform set_config('city_ride.offer_write', '', true);
end;
$$;
revoke execute on function public.ride_offers_mirror(uuid) from public, anon, authenticated;

-- Closes the open offers of [p_request] (all, or all but [p_keep]'s driver).
create or replace function public.ride_offers_close(p_request uuid, p_status text, p_reason text,
                                                   p_except_partner uuid default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  update public.ride_offers
     set status = p_status, closed_reason = p_reason, closed_at = now()
   where request_id = p_request and status = 'open'
     and (p_except_partner is null or partner_id <> p_except_partner);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.ride_offers_close(uuid, text, text, uuid) from public, anon, authenticated;

-- Whether the driver's offers are paused for cancelling too much.
create or replace function public.driver_offers_paused_until(p_partner uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select p.offers_paused_until from public.profiles p
   where p.id = p_partner and p.offers_paused_until > now();
$$;
revoke execute on function public.driver_offers_paused_until(uuid) from public, anon, authenticated;

-- The driver's offer.
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

-- The driver takes their open offer back.
create or replace function public.ride_offer_withdraw(p_request uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform 1 from public.ride_requests where id = p_request for update;
  update public.ride_offers set status = 'withdrawn', closed_reason = 'withdrawn', closed_at = now()
   where request_id = p_request and partner_id = v_uid and status = 'open';
  if found then
    perform public.ride_offers_mirror(p_request);
  end if;
end;
$$;
revoke execute on function public.ride_offer_withdraw(uuid) from public, anon;
grant execute on function public.ride_offer_withdraw(uuid) to authenticated;

-- The rider takes one offer: the ride is that driver's at that amount.
create or replace function public.ride_offer_accept(p_offer uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  o public.ride_offers;
  r public.ride_requests;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into o from public.ride_offers where id = p_offer;
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = o.request_id for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'open' then
    raise exception 'OFFER_REQUEST_CLOSED' using errcode = 'P0001', hint = 'This request is no longer open.';
  end if;
  select * into o from public.ride_offers where id = p_offer for update;
  if o.status <> 'open' or o.expires_at <= now() - interval '2 seconds' then
    raise exception 'OFFER_GONE' using errcode = 'P0001', hint = 'That offer is no longer available.';
  end if;

  perform set_config('city_ride.offer_write', 'on', true);
  update public.ride_offers set status = 'accepted', closed_at = now() where id = o.id;
  perform public.ride_offers_close(o.request_id, 'withdrawn', 'taken', o.partner_id);
  update public.ride_requests
     set status = 'accepted', accepted_at = now(), fare = o.amount, ride_fare = o.amount,
         offered_fare = o.amount, partner_id = o.partner_id, partner_name = o.partner_name,
         partner_photo = o.partner_photo, partner_rating = o.partner_rating, partner_trips = o.partner_trips,
         partner_vehicle = coalesce(o.partner_vehicle, partner_vehicle),
         partner_plate = coalesce(o.partner_plate, partner_plate),
         partner_accept_lat = o.from_lat, partner_accept_lng = o.from_lng,
         partner_phone = (select c.phone from public.profiles c where c.id = o.partner_id)
   where id = o.request_id
  returning * into r;
  perform set_config('city_ride.offer_write', '', true);
  return to_jsonb(r);
end;
$$;
revoke execute on function public.ride_offer_accept(uuid) from public, anon;
grant execute on function public.ride_offer_accept(uuid) to authenticated;

-- The rider turns one offer down; the request stays open for the rest.
create or replace function public.ride_offer_decline(p_offer uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  o public.ride_offers;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into o from public.ride_offers where id = p_offer;
  if not found or not exists (select 1 from public.ride_requests r
                               where r.id = o.request_id and r.rider_id = v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform 1 from public.ride_requests where id = o.request_id for update;
  update public.ride_offers set status = 'declined', closed_reason = 'declined', closed_at = now()
   where id = p_offer and status = 'open';
  if found then
    perform public.ride_offers_mirror(o.request_id);
  end if;
end;
$$;
revoke execute on function public.ride_offer_decline(uuid) from public, anon;
grant execute on function public.ride_offer_decline(uuid) to authenticated;

-- Offers that ran out; the request's mirror moves on. Every 15 seconds.
create or replace function public.ride_offers_expire()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req uuid;
  n int := 0;
begin
  for v_req in
    with gone as (
      update public.ride_offers set status = 'expired', closed_reason = 'expired', closed_at = now()
       where status = 'open' and expires_at <= now()
      returning request_id)
    select distinct request_id from gone
  loop
    perform public.ride_offers_mirror(v_req);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.ride_offers_expire() from public, anon, authenticated;

-- Keeps the offers in step with the request, whoever wrote it. The offer
-- functions' own writes are marked (city_ride.offer_write) and skipped.
create or replace function public.ride_requests_offers_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  card record;
begin
  if coalesce(current_setting('city_ride.offer_write', true), '') = 'on' then
    return null;
  end if;
  -- Taken: by the rider's older app, auto-accept, or a driver at the fare.
  if old.status = 'open' and new.status in ('accepted', 'arrived', 'on_trip') then
    update public.ride_offers set status = 'accepted', closed_at = now()
     where request_id = new.id and partner_id = new.partner_id and status = 'open';
    perform public.ride_offers_close(new.id, 'withdrawn', 'taken', new.partner_id);
    return null;
  end if;
  if new.status in ('cancelled', 'expired') and old.status = 'open' then
    perform public.ride_offers_close(new.id, 'withdrawn', 'cancelled');
    return null;
  end if;
  if new.status <> 'open' then
    return null;
  end if;
  -- The rider raised the fare: every offer is off.
  if new.fare is distinct from old.fare then
    perform public.ride_offers_close(new.id, 'withdrawn', 'raised');
    return null;
  end if;
  -- The bid on the row cleared by an older app: the rider declined it, or
  -- the driver withdrew it.
  if old.partner_id is not null and new.partner_id is null then
    update public.ride_offers
       set status = case when auth.uid() = new.rider_id then 'declined' else 'withdrawn' end,
           closed_reason = case when auth.uid() = new.rider_id then 'declined' else 'withdrawn' end,
           closed_at = now()
     where request_id = new.id and partner_id = old.partner_id and status = 'open';
    if pg_trigger_depth() < 2 then
      perform public.ride_offers_mirror(new.id);
    end if;
    return null;
  end if;
  -- An older driver app's bid, written on the row: kept as an offer too.
  if new.partner_id is not null and new.offered_fare is not null
     and (new.partner_id, new.offered_fare) is distinct from (old.partner_id, old.offered_fare) then
    c := public.city_ride_config()->'offers';
    update public.ride_offers set status = 'withdrawn', closed_reason = 'replaced', closed_at = now()
     where request_id = new.id and partner_id = new.partner_id and status = 'open';
    insert into public.ride_offers (request_id, partner_id, amount, from_lat, from_lng, partner_name,
                                    partner_photo, partner_rating, partner_trips, partner_vehicle, partner_plate,
                                    partner_plate_colours, expires_at)
    values (new.id, new.partner_id, new.offered_fare, new.partner_accept_lat, new.partner_accept_lng,
            new.partner_name, new.partner_photo, new.partner_rating, new.partner_trips, new.partner_vehicle,
            new.partner_plate, new.partner_plate_colours,
            clock_timestamp() + make_interval(secs => (c->>'lifetimeSeconds')::int));
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_requests_offers_sync() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_offers_sync on public.ride_requests;
create trigger trg_ride_requests_offers_sync
  after update of status, fare, partner_id, offered_fare on public.ride_requests
  for each row
  when (old.status = 'open')
  execute function public.ride_requests_offers_sync();

-- ---- 2. Drivers rate riders ---------------------------------------------------------------------

-- The rating and the pause are the server's (the profile guard of 0087
-- keeps its own list; this one covers the new columns).
create or replace function public.profiles_guard_city_ride()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if (new.rider_rating, new.rider_ratings_count, new.offers_paused_until)
     is distinct from (old.rider_rating, old.rider_ratings_count, old.offers_paused_until) then
    raise exception 'PROFILE_PROTECTED_COLUMN:rider_rating' using errcode = '42501',
      hint = 'This field can only be changed by an administrator or by the server.';
  end if;
  return new;
end;
$$;
revoke execute on function public.profiles_guard_city_ride() from public, anon, authenticated;
drop trigger if exists trg_profiles_b_guard_city_ride on public.profiles;
create trigger trg_profiles_b_guard_city_ride before update on public.profiles
  for each row execute function public.profiles_guard_city_ride();

create table if not exists public.rider_ratings (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.ride_requests(id) on delete cascade,
  rater_id    uuid not null,  -- the driver (ride_requests.partner_id)
  rider_id    uuid not null references public.profiles(id) on delete cascade,
  stars       smallint not null check (stars between 1 and 5),
  tags        text[] not null default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (request_id, rater_id)
);
create index if not exists rider_ratings_rider on public.rider_ratings (rider_id, created_at desc);
create index if not exists rider_ratings_rater on public.rider_ratings (rater_id, created_at desc);

alter table public.rider_ratings enable row level security;
revoke all on public.rider_ratings from anon, authenticated;
grant select on public.rider_ratings to authenticated;
-- The driver sees what they gave; the rider never sees who rated them, only
-- their average on Profile.
drop policy if exists "rider_ratings rater read" on public.rider_ratings;
create policy "rider_ratings rater read" on public.rider_ratings for select to authenticated
  using (rater_id = (select auth.uid()) or (select public.caller_is_admin()));

create or replace function public.rider_rating_tags()
returns table (tag text, low boolean)
language sql
immutable
set search_path = ''
as $$
  select * from (values
    ('Late to pickup', true), ('Rude', true), ('Wrong pickup point', true), ('Left a mess', true),
    ('Unsafe request', true), ('Polite', false), ('On time', false), ('Clear directions', false)) t(tag, low);
$$;

-- The rider's average over their last N ratings, onto their profile.
create or replace function public.rider_rating_recompute(p_rider uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int := (public.city_ride_config()->'riderRating'->>'window')::int;
begin
  update public.profiles p
     set rider_rating = s.avg, rider_ratings_count = s.cnt
    from (select round(avg(x.stars)::numeric, 2) as avg, count(*)::int as cnt
            from (select r.stars from public.rider_ratings r where r.rider_id = p_rider
                   order by r.created_at desc limit n) x) s
   where p.id = p_rider;
end;
$$;
revoke execute on function public.rider_rating_recompute(uuid) from public, anon, authenticated;

create or replace function public.rate_rider(p_request_id uuid, p_stars int, p_tags text[] default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v_tags text[];
  p public.profiles;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request_id;
  if not found or r.partner_id is distinct from v_uid or r.rider_id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' then
    raise exception 'not_completed';
  end if;
  if coalesce(r.completed_at, r.updated_at) < now() - interval '24 hours' then
    raise exception 'too_late';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'bad_stars' using errcode = '22023';
  end if;
  -- Only the tags of the stars' own list, each once.
  select coalesce(array_agg(distinct t.tag order by t.tag), '{}') into v_tags
    from public.rider_rating_tags() t
   where t.tag = any (coalesce(p_tags, '{}')) and t.low = (p_stars <= 3);

  insert into public.rider_ratings (request_id, rater_id, rider_id, stars, tags)
  values (p_request_id, v_uid, r.rider_id, p_stars, v_tags)
  on conflict (request_id, rater_id) do update
     set stars = excluded.stars, tags = excluded.tags, updated_at = now();
  perform public.rider_rating_recompute(r.rider_id);
  select * into p from public.profiles where id = r.rider_id;
  return jsonb_build_object('stars', p_stars, 'tags', to_jsonb(v_tags),
                            'rider_rating', p.rider_rating, 'ratings', p.rider_ratings_count);
end;
$$;
revoke execute on function public.rate_rider(uuid, int, text[]) from public, anon;
grant execute on function public.rate_rider(uuid, int, text[]) to authenticated;

-- What the driver sees on a request: the rider's rating, how many ratings,
-- and their trips. Stamped on every new request (the app's value is not
-- trusted).
alter table public.ride_requests add column if not exists rider_ratings_count integer;
alter table public.ride_requests add column if not exists rider_trips integer;

create or replace function public.ride_requests_rider_card()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.profiles;
begin
  select * into p from public.profiles where id = new.rider_id;
  new.rider_rating := coalesce(p.rider_rating, 5);
  new.rider_ratings_count := coalesce(p.rider_ratings_count, 0);
  new.rider_trips := (select count(*)::int from public.ride_requests q
                       where q.rider_id = new.rider_id and q.status = 'completed');
  return new;
end;
$$;
revoke execute on function public.ride_requests_rider_card() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_rider_card on public.ride_requests;
create trigger trg_ride_requests_rider_card before insert on public.ride_requests
  for each row execute function public.ride_requests_rider_card();

-- ---- 5. Cancel and no-show by place --------------------------------------------------------------
-- A place's rules: {freeMinutes, lateFee, arrivedFee, noShowMinutes, noShowFee}, each optional.
create or replace function public.ride_cancel_rules_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'object'
     and not exists (
       select 1 from jsonb_each(p) e
        where e.key not in ('freeMinutes', 'lateFee', 'arrivedFee', 'noShowMinutes', 'noShowFee')
           or jsonb_typeof(e.value) <> 'number'
           or (e.value #>> '{}')::numeric < 0
           or (e.value #>> '{}')::numeric > case when e.key like '%Minutes' then 120 else 1000 end);
$$;

create table if not exists public.ride_cancel_places (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  rules      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ride_cancel_places_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)),
  constraint ride_cancel_places_valid check (public.ride_cancel_rules_valid(rules))
);
create unique index if not exists ride_cancel_places_key_uidx on public.ride_cancel_places (place_key);
comment on table public.ride_cancel_places is
  'City ride cancel and no-show rules by place (0269), keyed as ride_option_places: the smallest place that sets a rule wins.';

drop trigger if exists trg_ride_cancel_places_updated_at on public.ride_cancel_places;
create trigger trg_ride_cancel_places_updated_at before update on public.ride_cancel_places
  for each row execute function public.set_updated_at();

alter table public.ride_cancel_places enable row level security;
revoke all on public.ride_cancel_places from anon;
grant select, insert, update, delete on public.ride_cancel_places to authenticated;
drop policy if exists "ride_cancel_places read" on public.ride_cancel_places;
drop policy if exists "ride_cancel_places admin insert" on public.ride_cancel_places;
drop policy if exists "ride_cancel_places admin update" on public.ride_cancel_places;
drop policy if exists "ride_cancel_places admin delete" on public.ride_cancel_places;
create policy "ride_cancel_places read" on public.ride_cancel_places for select to authenticated using (true);
create policy "ride_cancel_places admin insert" on public.ride_cancel_places for insert to authenticated
  with check ((select public.caller_admin_can_write('ride_cancel_places')));
create policy "ride_cancel_places admin update" on public.ride_cancel_places for update to authenticated
  using ((select public.caller_admin_can_write('ride_cancel_places')))
  with check ((select public.caller_admin_can_write('ride_cancel_places')));
create policy "ride_cancel_places admin delete" on public.ride_cancel_places for delete to authenticated
  using ((select public.caller_admin_can_write('ride_cancel_places')));

insert into public.ride_cancel_places (level, rules)
values ('default', jsonb_build_object('freeMinutes', 2, 'lateFee', 3, 'arrivedFee', 5,
                                      'noShowMinutes', 5, 'noShowFee', 5))
on conflict (place_key) do nothing;

-- The rules at a place: each key from the smallest place that sets it,
-- over the built-in defaults.
create or replace function public.ride_cancel_rules_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v jsonb := jsonb_build_object('freeMinutes', 2, 'lateFee', 3, 'arrivedFee', 5, 'noShowMinutes', 5, 'noShowFee', 5);
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_country, '')));
  s text := lower(btrim(coalesce(p_state, '')));
  t text := lower(btrim(coalesce(p_city, '')));
  b text := lower(btrim(coalesce(p_suburb, '')));
  r public.ride_cancel_places;
begin
  if c <> '' then
    k := k || c;
    if s <> '' then
      k := k || (c || '|' || s);
      if t <> '' then
        k := k || (c || '|' || s || '|' || t);
        if b <> '' then
          k := k || (c || '|' || s || '|' || t || '|' || b);
        end if;
      end if;
    end if;
  end if;
  for r in
    select p.* from public.ride_cancel_places p
     where p.place_key = any (k)
     order by case p.level when 'default' then 0 when 'country' then 1 when 'state' then 2
                           when 'city' then 3 else 4 end
  loop
    v := v || r.rules;
  end loop;
  return v;
end;
$$;
revoke execute on function public.ride_cancel_rules_at(text, text, text, text) from public, anon, authenticated;

create or replace function public.ride_cancel_rules_for(r public.ride_requests)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.ride_cancel_rules_at(p.country, p.state, p.city, p.suburb)
    from public.ride_option_place(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city) p;
$$;
revoke execute on function public.ride_cancel_rules_for(public.ride_requests) from public, anon, authenticated;

-- Reasons that are always free: the car isn't coming, or isn't the one booked.
create or replace function public.ride_cancel_safety_reason(p_reason text)
returns boolean
language sql
immutable
set search_path = ''
as $$ select coalesce(btrim(p_reason), '') in ('driver_not_moving', 'wrong_car'); $$;

-- What a rider's cancel asked at [p_at] costs under [p_rules]. Kept in step
-- with cityCancelFee (lib/src/core/city_cancel.dart).
create or replace function public.ride_cancel_fee(p_rules jsonb, p_accepted_at timestamptz,
                                                 p_arrived_at timestamptz, p_at timestamptz, p_reason text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when public.ride_cancel_safety_reason(p_reason) or p_accepted_at is null then 0
    when p_arrived_at is not null and p_at >= p_arrived_at then coalesce((p_rules->>'arrivedFee')::numeric, 0)
    when p_at < p_accepted_at + make_interval(secs => coalesce((p_rules->>'freeMinutes')::numeric, 0) * 60) then 0
    else coalesce((p_rules->>'lateFee')::numeric, 0)
  end;
$$;

alter table public.ride_requests add column if not exists cancel_fee numeric(10,2);
alter table public.ride_requests add column if not exists cancel_fee_status text;
alter table public.ride_requests drop constraint if exists ride_requests_cancel_fee_status_check;
alter table public.ride_requests add constraint ride_requests_cancel_fee_status_check
  check (cancel_fee_status is null or cancel_fee_status in ('charged', 'due', 'none'));
alter table public.ride_requests add column if not exists prior_fees numeric(10,2);
alter table public.ride_requests add column if not exists trip_shared_at timestamptz;

-- Fees a short wallet couldn't pay, added to the rider's next ride.
create table if not exists public.rider_fee_dues (
  id              uuid primary key default gen_random_uuid(),
  rider_id        uuid not null references public.profiles(id) on delete cascade,
  partner_id      uuid not null,
  ride_id         uuid not null references public.ride_requests(id) on delete cascade,
  kind            text not null check (kind in ('late_cancel', 'arrived_cancel', 'no_show')),
  amount          numeric(10,2) not null check (amount > 0),
  commission_rate numeric(6,4) not null default 0,
  status          text not null default 'due' check (status in ('due', 'billed', 'paid', 'waived')),
  -- No foreign key: it is set while that ride is being inserted.
  billed_ride_id  uuid,
  created_at      timestamptz not null default now(),
  settled_at      timestamptz,
  unique (ride_id)
);
alter table public.rider_fee_dues drop constraint if exists rider_fee_dues_billed_ride_id_fkey;
create index if not exists rider_fee_dues_rider on public.rider_fee_dues (rider_id) where status in ('due', 'billed');
create index if not exists rider_fee_dues_billed on public.rider_fee_dues (billed_ride_id) where billed_ride_id is not null;
alter table public.rider_fee_dues enable row level security;
revoke all on public.rider_fee_dues from anon, authenticated;
grant select on public.rider_fee_dues to authenticated;
drop policy if exists "rider_fee_dues parties read" on public.rider_fee_dues;
create policy "rider_fee_dues parties read" on public.rider_fee_dues for select to authenticated
  using (rider_id = (select auth.uid()) or partner_id = (select auth.uid()) or (select public.caller_is_admin()));

-- The fee's money: the rider's GET.wallet to the driver, less the ride's
-- commission. 'charged', or 'due' when the wallet is short.
create or replace function public.ride_fee_take(r public.ride_requests, p_amount numeric, p_kind text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric := case when r.commission_rate >= 0 and r.commission_rate < 1 then r.commission_rate else 0 end;
  v_balance numeric;
  v_label text := case p_kind when 'no_show' then 'No-show fee'
                              when 'arrived_cancel' then 'Cancelled after the driver arrived'
                              else 'Late cancellation fee' end;
begin
  if v_amount <= 0 or r.rider_id is null or r.partner_id is null then
    return 'none';
  end if;
  insert into public.wallets (user_id, wallet_type, balance) values (r.rider_id, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_balance from public.wallets w
   where w.user_id = r.rider_id and w.wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_amount then
    insert into public.rider_fee_dues (rider_id, partner_id, ride_id, kind, amount, commission_rate)
    values (r.rider_id, r.partner_id, r.id, p_kind, v_amount, v_rate)
    on conflict (ride_id) do nothing;
    return 'due';
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
    (r.rider_id, 'get_wallet', 'payment', -v_amount, 'cancellation_fee', v_label),
    (r.partner_id, 'get_wallet', 'cancellation_fee', round(v_amount * (1 - v_rate), 2), 'cancellation_fee',
     v_label || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end);
  return 'charged';
end;
$$;
revoke execute on function public.ride_fee_take(public.ride_requests, numeric, text) from public, anon, authenticated;

-- A rider's cancel of a city ride the driver had taken: the fee it was due
-- when the rider asked (cancel_requested_at), or when it happened.
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

drop trigger if exists trg_ride_requests_city_cancel_fee on public.ride_requests;
create trigger trg_ride_requests_city_cancel_fee
  after update of status on public.ride_requests
  for each row
  when (new.status = 'cancelled' and old.status in ('accepted', 'arrived')
        and old.scheduled_ride_id is null and old.partner_id is not null)
  execute function public.ride_requests_city_cancel_fee();

-- What a ride's rider owes: as 0142, plus fees carried over from earlier rides.
create or replace function public.ride_amount_due(r public.ride_requests)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  f numeric := coalesce(r.ride_fare, r.fare, 0);
  c jsonb;
  v numeric;
  surcharge numeric := 0;
  tax numeric := 0;
  base numeric;
begin
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' = 'tax';
      surcharge := surcharge + round(greatest(0, case when c->>'charge' = 'fixed' then v else f * v / 100 end), 2);
    end loop;
  end if;
  surcharge := round(greatest(0, surcharge), 2);
  base := f + surcharge;

  if btrim(coalesce(r.tax_name, '')) <> '' and coalesce(r.tax_value, 0) > 0 then
    tax := tax + round(greatest(0, case when r.tax_kind = 'fixed' then r.tax_value else f * r.tax_value / 100 end), 2);
  end if;
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' <> 'tax';
      tax := tax + round(greatest(0, case when c->>'charge' = 'fixed' then v else base * v / 100 end), 2);
    end loop;
  end if;
  tax := round(greatest(0, tax), 2);

  return round(f + surcharge + tax + coalesce(r.toll_charges, 0) + coalesce(r.other_charges, 0)
               + coalesce(r.prior_fees, 0), 2);
end;
$$;
revoke execute on function public.ride_amount_due(public.ride_requests) from public, anon;
grant execute on function public.ride_amount_due(public.ride_requests) to authenticated;

-- A new city ride carries the rider's unpaid fees.
create or replace function public.ride_requests_bill_dues()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sum numeric;
begin
  new.prior_fees := null;
  new.cancel_fee := null;
  new.cancel_fee_status := null;
  new.trip_shared_at := null;
  if new.rider_id is null or new.scheduled_ride_id is not null or new.stand_id is not null then
    return new;
  end if;
  with b as (
    update public.rider_fee_dues set status = 'billed', billed_ride_id = new.id
     where rider_id = new.rider_id and status = 'due'
    returning amount)
  select sum(amount) into v_sum from b;
  if coalesce(v_sum, 0) > 0 then
    new.prior_fees := round(v_sum, 2);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_bill_dues() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_bill_dues on public.ride_requests;
create trigger trg_ride_requests_bill_dues before insert on public.ride_requests
  for each row execute function public.ride_requests_bill_dues();

-- The ride that carried the fees ends: completed, the driver who collected
-- them passes each to the driver it was owed to (less commission); ended
-- otherwise, they wait for the next ride again.
create or replace function public.ride_requests_settle_dues()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.rider_fee_dues;
begin
  for d in select * from public.rider_fee_dues where billed_ride_id = new.id and status = 'billed' for update loop
    if new.status = 'completed' and new.partner_id is not null then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
        (new.partner_id, 'get_credit', 'collected_fee', -d.amount, 'cancellation_fee',
         'Earlier ride''s fee collected for another driver'),
        (d.partner_id, 'get_wallet', 'cancellation_fee', round(d.amount * (1 - d.commission_rate), 2),
         'cancellation_fee', 'Cancellation fee paid with the rider''s next ride');
      update public.rider_fee_dues set status = 'paid', settled_at = now() where id = d.id;
      update public.ride_requests set cancel_fee_status = 'charged' where id = d.ride_id;
    else
      update public.rider_fee_dues set status = 'due', billed_ride_id = null where id = d.id;
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function public.ride_requests_settle_dues() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_settle_dues on public.ride_requests;
create trigger trg_ride_requests_settle_dues
  after update of status on public.ride_requests
  for each row
  when (new.prior_fees is not null and new.status in ('completed', 'cancelled', 'expired')
        and old.status is distinct from new.status)
  execute function public.ride_requests_settle_dues();

-- The server's columns stay the server's.
create or replace function public.ride_requests_guard_city_ride()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
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
revoke execute on function public.ride_requests_guard_city_ride() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_guard_city_ride on public.ride_requests;
create trigger trg_ride_requests_guard_city_ride before update on public.ride_requests
  for each row execute function public.ride_requests_guard_city_ride();

-- What the app shows for a ride: the rules there, when the free cancel ends
-- and when the no-show button unlocks. The ride's rider or driver.
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
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or auth.uid() is null or auth.uid() not in (r.rider_id, r.partner_id) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v := public.ride_cancel_rules_for(r);
  return v || jsonb_build_object(
    'currency', r.currency,
    'freeUntil', r.accepted_at + make_interval(secs => (v->>'freeMinutes')::numeric * 60),
    'noShowAt', r.arrived_at + make_interval(secs => (v->>'noShowMinutes')::numeric * 60),
    'scheduled', r.scheduled_ride_id is not null);
end;
$$;
revoke execute on function public.ride_cancel_terms(uuid) from public, anon;
grant execute on function public.ride_cancel_terms(uuid) to authenticated;

-- The driver waited at the pickup and the rider didn't come.
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
  v_fee := round(coalesce((v->>'noShowFee')::numeric, 0), 2);
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

-- A driver's cancels over the admin's days: cancels by them (no-shows not
-- counted) of the rides they took.
create or replace function public.driver_cancel_rate(p_partner uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with c as (select public.city_ride_config()->'driverCancel' as d),
  s as (
    select count(*) filter (where q.status = 'cancelled' and q.cancel_requested_by = 'partner'
                              and coalesce(q.cancel_reason, '') <> 'passenger_no_show') as cancels,
           count(*) as rides
      from public.ride_requests q, c
     where q.partner_id = p_partner and q.accepted_at > now() - make_interval(days => (c.d->>'days')::int)
  )
  select jsonb_build_object(
    'cancels', s.cancels, 'rides', s.rides,
    'percent', case when s.rides > 0 then round(100.0 * s.cancels / s.rides, 1) else 0 end,
    'limitPercent', (c.d->>'limitPercent')::int, 'days', (c.d->>'days')::int,
    'pauseMinutes', (c.d->>'pauseMinutes')::int, 'minRides', (c.d->>'minRides')::int,
    'pausedUntil', (select p.offers_paused_until from public.profiles p
                     where p.id = p_partner and p.offers_paused_until > now()))
  from s, c;
$$;
revoke execute on function public.driver_cancel_rate(uuid) from public, anon, authenticated;

create or replace function public.driver_cancel_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.driver_cancel_rate(auth.uid());
end;
$$;
revoke execute on function public.driver_cancel_stats() from public, anon;
grant execute on function public.driver_cancel_stats() to authenticated;

-- After a driver's own cancel: over the limit, their offers pause.
create or replace function public.ride_requests_driver_cancel_pause()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb := public.driver_cancel_rate(old.partner_id);
begin
  if (s->>'rides')::int >= (s->>'minRides')::int and (s->>'percent')::numeric > (s->>'limitPercent')::numeric then
    update public.profiles
       set offers_paused_until = now() + make_interval(mins => (s->>'pauseMinutes')::int)
     where id = old.partner_id;
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_requests_driver_cancel_pause() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_driver_cancel_pause on public.ride_requests;
create trigger trg_ride_requests_driver_cancel_pause
  after update of status on public.ride_requests
  for each row
  when (new.status = 'cancelled' and old.status in ('accepted', 'arrived') and old.partner_id is not null
        and new.cancel_requested_by = 'partner' and new.cancel_reason is distinct from 'passenger_no_show')
  execute function public.ride_requests_driver_cancel_pause();

-- ---- 6. Safety ----------------------------------------------------------------------------------
-- 0154's switches with the route check, read the same way. The two older
-- checks are on unless the admin turned them off.
create or replace function public.reliability_safety()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select coalesce((select e.values from public.settings_entries e
                      where e.id = '72656c69-6162-4c69-8000-000000000001'), '{}'::jsonb) as j
  )
  select jsonb_build_object(
    'start_check', coalesce(j->>'safety_start_check', 'true') in ('true', 't', '1', 'on'),
    'separation', coalesce(j->>'safety_separation', 'true') in ('true', 't', '1', 'on'),
    'lost_items', coalesce(j->>'safety_lost_items', '') in ('true', 't', '1', 'on'),
    'far_apart_m', greatest(100, least(5000, coalesce(
        case when j->>'safety_far_apart_m' ~ '^[0-9]+$' then (j->>'safety_far_apart_m')::int end, 300))),
    'separation_min', greatest(1, least(30, coalesce(
        case when j->>'safety_separation_min' ~ '^[0-9]+$' then (j->>'safety_separation_min')::int end, 3))),
    'route_check', coalesce(j->>'safety_route_check', 'true') in ('true', 't', '1', 'on'),
    'route_off_m', greatest(100, least(5000, coalesce(
        case when j->>'safety_route_off_m' ~ '^[0-9]+$' then (j->>'safety_route_off_m')::int end, 500))),
    'route_off_min', greatest(1, least(30, coalesce(
        case when j->>'safety_route_off_min' ~ '^[0-9]+$' then (j->>'safety_route_off_min')::int end, 2))),
    'stopped_min', greatest(1, least(60, coalesce(
        case when j->>'safety_stopped_min' ~ '^[0-9]+$' then (j->>'safety_stopped_min')::int end, 5))),
    'no_answer_s', greatest(15, least(600, coalesce(
        case when j->>'safety_no_answer_s' ~ '^[0-9]+$' then (j->>'safety_no_answer_s')::int end, 60))),
    'auto_share', coalesce(j->>'safety_auto_share', 'true') in ('true', 't', '1', 'on')
  ) from v;
$$;
revoke execute on function public.reliability_safety() from public, anon;
grant execute on function public.reliability_safety() to authenticated;

-- For launch: the two checks on in the row too (an admin's saved form
-- stored them off), once.
update public.settings_entries
   set values = values || jsonb_build_object('safety_start_check', true, 'safety_separation', true,
                                             'safety_defaults_0269', true)
 where id = '72656c69-6162-4c69-8000-000000000001'
   and not coalesce((values->>'safety_defaults_0269')::boolean, false);

-- The "Trip share" message channel, routed out of the box as the sign-in
-- codes are (SMS or WhatsApp, the admin's choice on SMS / WhatsApp).
alter table public.sms_outbox drop constraint if exists sms_outbox_channel_check;
alter table public.sms_outbox add constraint sms_outbox_channel_check
  check (channel in ('otp', 'marketing', 'support_message', 'ops_alert', 'trip_share'));
alter table public.messaging_routes drop constraint if exists messaging_routes_channel_check;
alter table public.messaging_routes add constraint messaging_routes_channel_check
  check (channel in ('otp', 'marketing', 'support_call', 'support_message', 'ops_alert', 'trip_share'));
insert into public.messaging_routes (channel, direction, transport, device_ids, whatsapp_number, enabled)
select 'trip_share', 'outbound', r.transport, r.device_ids, r.whatsapp_number, true
  from public.messaging_routes r
 where r.channel = 'otp' and r.direction = 'outbound'
on conflict (channel, direction) do nothing;

-- Whether [p_at] is at night (10 pm to 6 am) in [p_zone]. Kept in step with
-- tripShareAtNight (lib/src/core/trip_safety.dart).
create or replace function public.trip_share_at_night(p_at timestamptz, p_zone text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  h int;
begin
  begin
    h := extract(hour from p_at at time zone coalesce(nullif(btrim(p_zone), ''), 'Asia/Kuala_Lumpur'))::int;
  exception when others then
    h := extract(hour from p_at at time zone 'Asia/Kuala_Lumpur')::int;
  end;
  return h >= 22 or h < 6;
end;
$$;

-- Texts the rider's emergency contacts (up to 5) the ride's live link: the
-- token kept aside as ride_share_link (0108, 0220) keeps it.
create or replace function public.trip_share_text_contacts(r public.ride_requests, p_body text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token uuid;
  n int;
begin
  insert into public.ride_request_private as p (request_id, share_token)
  values (r.id, gen_random_uuid())
  on conflict (request_id) do update set share_token = coalesce(p.share_token, excluded.share_token), updated_at = now()
  returning p.share_token into v_token;
  insert into public.sms_outbox (to_phone, body, channel)
  select left(c.phone, 32), left(replace(p_body, '{link}', 'https://getride.my/share/' || v_token), 1600), 'trip_share'
    from (select distinct on (btrim(e.phone)) btrim(e.phone) as phone
            from public.emergency_contacts e
           where e.profile_id = r.rider_id and char_length(btrim(e.phone)) between 3 and 32
           order by btrim(e.phone), e.created_at
           limit 5) c;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.trip_share_text_contacts(public.ride_requests, text) from public, anon, authenticated;

-- The trip starts: the rider's contacts get the live link, as the rider chose.
create or replace function public.ride_requests_trip_share()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode text;
  v_name text;
begin
  -- A ride booked for someone else is the booker's to share.
  if not (public.reliability_safety()->>'auto_share')::boolean or new.rider_id is null
     or coalesce(new.booked_for_other, false) or new.booked_for_phone is not null then
    return new;
  end if;
  select p.trip_share_mode, nullif(split_part(btrim(coalesce(p.name, new.rider_name, '')), ' ', 1), '')
    into v_mode, v_name
    from public.profiles p where p.id = new.rider_id;
  v_mode := coalesce(v_mode, 'night');
  if v_mode = 'never' or (v_mode = 'night' and not public.trip_share_at_night(now(), new.timezone)) then
    return new;
  end if;
  new.trip_shared_at := now();
  perform public.trip_share_text_contacts(new,
    'GET.ride: ' || coalesce(v_name, 'Your contact') || ' started a trip to '
    || coalesce(nullif(btrim(new.drop_name), ''), 'their destination') || '. Follow it live: {link}');
  return new;
end;
$$;
revoke execute on function public.ride_requests_trip_share() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_trip_share on public.ride_requests;
create trigger trg_ride_requests_trip_share before update of status on public.ride_requests
  for each row
  when (new.status = 'on_trip' and old.status is distinct from 'on_trip' and new.trip_shared_at is null)
  execute function public.ride_requests_trip_share();

-- The route check's answers, for the admin.
create table if not exists public.trip_route_events (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.ride_requests(id) on delete cascade,
  rider_id   uuid not null,
  kind       text not null check (kind in ('off_route', 'stopped')),
  answer     text not null check (answer in ('asked', 'ok', 'sos', 'no_answer')),
  off_m      integer,
  lat        double precision,
  lng        double precision,
  incident_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists trip_route_events_request on public.trip_route_events (request_id, created_at desc);
alter table public.trip_route_events enable row level security;
revoke all on public.trip_route_events from anon, authenticated;
grant select on public.trip_route_events to authenticated;
drop policy if exists "trip_route_events read" on public.trip_route_events;
create policy "trip_route_events read" on public.trip_route_events for select to authenticated
  using (rider_id = (select auth.uid()) or (select public.caller_is_admin()));

-- The rider's app saw the car leave the route (or stop) and asked. 'ok'
-- answers it; 'no_answer' (the rider's time ran out) raises the SOS ops
-- incident without the call and texts the emergency contacts the link.
create or replace function public.trip_route_report(p_ride uuid, p_kind text, p_answer text,
                                                   p_off_m int default null, p_lat double precision default null,
                                                   p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v_incident uuid;
  v_texts int := 0;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_ride;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_kind not in ('off_route', 'stopped') or p_answer not in ('asked', 'ok', 'sos', 'no_answer') then
    raise exception 'bad_report' using errcode = '22023';
  end if;
  if r.status <> 'on_trip' then
    raise exception 'not_on_trip' using errcode = 'P0001';
  end if;
  if public.auth_rate_take('trip_route', p_ride::text, 30, interval '1 hour') > 0 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;
  if p_answer = 'ok' then
    update public.ride_requests set safety_ack_at = now() where id = p_ride;
  elsif p_answer = 'no_answer' then
    v_incident := public.sos_raise(p_ride, p_lat, p_lng);
    update public.safety_incidents
       set note = left(coalesce(note || ' · ', '') || case p_kind when 'stopped' then 'Car stopped too long'
                                                         else 'Car left the planned route' end
                       || ', no answer from the passenger', 500)
     where id = v_incident;
    -- Once per ride: the contacts are texted with the first unanswered check.
    if not exists (select 1 from public.trip_route_events e
                    where e.request_id = p_ride and e.answer = 'no_answer') then
      v_texts := public.trip_share_text_contacts(r,
        'GET.ride safety alert: '
        || coalesce(nullif(split_part(btrim(coalesce((select p.name from public.profiles p where p.id = r.rider_id),
                                                     r.rider_name, '')), ' ', 1), ''), 'Your contact')
        || '''s car ' || case p_kind when 'stopped' then 'has stopped for a while'
                                     else 'has left the planned route' end
        || ' and they didn''t answer. GET.ride support has been told. Follow the trip live: {link}');
    end if;
  end if;
  insert into public.trip_route_events (request_id, rider_id, kind, answer, off_m, lat, lng, incident_id)
  values (p_ride, v_uid, p_kind, p_answer, p_off_m, p_lat, p_lng, v_incident);
  return jsonb_build_object('incident_id', v_incident, 'texts', v_texts);
end;
$$;
revoke execute on function public.trip_route_report(uuid, text, text, int, double precision, double precision)
  from public, anon;
grant execute on function public.trip_route_report(uuid, text, text, int, double precision, double precision)
  to authenticated;

-- ---- Schedule and live updates ------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'ride-offers-expire';
    perform cron.schedule('ride-offers-expire', '15 seconds', $job$select public.ride_offers_expire()$job$);
  end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'ride_offers') then
    alter publication supabase_realtime add table public.ride_offers;
  end if;
  -- Read live by every app (lib/src/data/live_tables.dart).
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'ride_cancel_places') then
    alter publication supabase_realtime add table public.ride_cancel_places;
  end if;
end $$;

notify pgrst, 'reload schema';
