-- ============================================================================
-- 0308 — City to City for drivers (docs/KIV.md L8, part C3): what the driver
-- app needs beyond 0307's offer, withdraw, progress and contact functions.
--
-- Version 20261028010000 (0308_city_to_city_driver). Re-runnable: columns
-- "if not exists", functions "create or replace", triggers dropped first.
--
-- 1. c2c_driver_requests(): the driver's Requests list in one call. Every
--    open request in reach (0307's c2c_driver_in_reach: the partner's
--    service states, else countries), the rider's own excepted, soonest
--    first, each with whether the driver may take it (0307's
--    c2c_driver_eligibility: years and permits, and what is missing), the
--    commission the driver would pay on it now (as it would be locked:
--    commission_resolve with the service, tiers, promotions), the rider as
--    "Farah T." with their rider rating (0269), and the driver's own open
--    offer. A request the driver may not take is listed (the mockup's
--    "Needs: Singapore permit") without its addresses or points: only the
--    areas. Also, for the tab's header: whether the driver is an approved
--    partner with a service area, and their driving experience.
-- 2. c2c_driver_cancel(booking, reason): the booked driver gives the trip up.
--    Rule: while booked or on the way to the pickup, and before the time to
--    leave; never once the rider is picked up (support then). The request
--    goes back to open, as it was before an offer was picked (driver,
--    agreed fare, the driver's time and the locked commission cleared), so
--    drivers in reach can offer again until the time to leave, when 0307's
--    expiry closes it. The driver's accepted offer is marked withdrawn. No
--    fee either way: the rider did nothing, and a driver fee is not built.
--    The booking keeps when and why (driver_dropped_at, driver_drop_reason)
--    so the rider's page can say so. Why back to open and not cancelled:
--    the rider still wants the trip and has up to the time to leave; they
--    may still cancel it free while no driver is picked (0307).
-- 3. c2c_set_driving_since(date): the driver says when their licence was
--    first issued (0306's partners.driving_since), once, and only while the
--    server knows no date for them (none set, no approved licence document).
--    After that an admin changes it (Edit Partner). A new trigger keeps the
--    column from being written by the driver's own table writes, which 0306
--    left open: trg_partners_guard_driving_since.
-- 4. The rider's City to City stars count in the driver's rating:
--    partner_rating_refresh(partner) averages ride_ratings (0159, 0297) and
--    the rated City to City trips onto partners.rating, the one rating the
--    apps show. rate_ride (0297's, unchanged otherwise) and c2c_rate_driver
--    (0307's, unchanged otherwise) call it. Neither is an admin RPC, so 0223's
--    rewrite list is untouched.
-- 5. Chat in the app, not SMS: the ride chat (ride_messages, 0129; photos
--    and voice notes 0140; delivery and the push outbox 0146) also carries a
--    City to City booking's thread. ride_messages gets c2c_booking_id
--    (cascading with the booking); request_id becomes nullable, and exactly
--    one of the two is set. Ride chat is unchanged: its policies are not
--    touched (0163's, 0223's and 0227's rewrites of them stand) and only
--    match rows with a request_id; new, separate policies let the rider and
--    the booked driver of a booking read its thread, and send while it is
--    booked, on the way or on the trip (read-only after, as ride chat). A
--    driver reads the messages from when they were booked: a driver who
--    gave the trip up and the one booked after never read each other's.
--    Admins read every thread through the existing read policy. The
--    triggers that look the ride up learn the booking: the tick guard
--    (only the receiver moves it), the push (through the 0146 outbox, kind
--    'ride_message', data {c2c_booking_id, role}), and the chat files'
--    folder check (ride_chat_media_allowed: the booking's id is the
--    folder). None of these is on 0223's rewrite list.
-- ============================================================================

-- ---- 2. Why a booking went back to open ---------------------------------------------------------------------
alter table public.c2c_bookings add column if not exists driver_dropped_at timestamptz;
alter table public.c2c_bookings add column if not exists driver_drop_reason text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'c2c_bookings_drop_reason_len') then
    alter table public.c2c_bookings add constraint c2c_bookings_drop_reason_len
      check (driver_drop_reason is null or char_length(driver_drop_reason) <= 300);
  end if;
end $$;
comment on column public.c2c_bookings.driver_dropped_at is
  'When the booked driver last gave the trip up (0308); the request went back to open.';

-- ---- 1. The commission a driver would pay on a request now ---------------------------------------------
-- As trg_c2c_bookings_lock_commission (0307) would lock it if [p_driver]
-- were booked on [b] now; null when it can't be found.
create or replace function public.c2c_commission_now(p_driver uuid, b public.c2c_bookings)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
  t record;
  pm record;
begin
  select * into v from public.commission_resolve(
    p_driver, b.pickup_lat, b.pickup_lng, b.pickup_place->>'country', b.pickup_place->>'state',
    b.pickup_place->>'city', b.pickup_place->>'suburb', b.service);
  select * into t from public.commission_apply_tiers(p_driver, v.rate, v.level);
  select * into pm from public.commission_apply_promotions(
    p_driver, t.rate, v.level, now(), coalesce(b.timezone, 'Asia/Kuala_Lumpur'), b.service,
    b.pickup_lat, b.pickup_lng, b.pickup_place->>'country', b.pickup_place->>'state',
    b.pickup_place->>'city', b.pickup_place->>'suburb');
  return case when pm.rate >= 0 and pm.rate < 1 then pm.rate end;
exception when others then
  return null;
end;
$$;
revoke execute on function public.c2c_commission_now(uuid, public.c2c_bookings) from public, anon, authenticated;

-- "Farah T." for "Farah Tan Contoh"; "Rider" when no name.
create or replace function public.c2c_short_name(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(btrim(p_name), '') = '' then 'Rider'
    else split_part(regexp_replace(btrim(p_name), '\s+', ' ', 'g'), ' ', 1)
         || coalesce(' ' || nullif(upper(left(split_part(regexp_replace(btrim(p_name), '\s+', ' ', 'g'), ' ', 2), 1)), '')
                     || '.', '')
  end;
$$;

-- "Ampang, Kuala Lumpur": the suburb and city of a place, else what it has.
create or replace function public.c2c_area(p_place jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    nullif(concat_ws(', ', nullif(p_place->>'suburb', ''),
                     coalesce(nullif(p_place->>'city', ''), nullif(p_place->>'state', ''))), ''),
    nullif(p_place->>'country', ''),
    'Area');
$$;

-- ---- 1. The driver's Requests list ---------------------------------------------------------------------
-- {approved, hasArea, drivingSince, years, canSetDrivingSince, requests: [
--   {...the request's row as the app reads it, without the rider's id or the
--    money fields..., rider_name, rider_rating, eligibility, commission_rate_now,
--    my_offer: {id, price, leave_at, note} | null}]}.
create or replace function public.c2c_driver_requests()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  pa record;
  v_since date;
  v_list jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select p.status::text as status, p.driving_since,
         cardinality(coalesce(p.service_states, '{}')) + cardinality(coalesce(p.service_countries, '{}')) > 0 as has_area
    into pa
    from public.partners p
   where p.auth_user_id = v_uid
   order by (p.status::text = 'approved') desc, p.created_at
   limit 1;
  v_since := public.c2c_driving_since(v_uid);

  select coalesce(jsonb_agg(x.item order by x.leave_at, x.id), '[]'::jsonb)
    into v_list
    from (
      select b.id, b.leave_at,
             (to_jsonb(b) - array['rider_id', 'driver_id', 'offer_id', 'agreed_fare', 'driver_leave_at',
                                  'cancel_fee', 'cancel_fee_status', 'cancel_reason', 'cancelled_by',
                                  'rider_stars', 'rider_comment', 'rated_at', 'commission_rate',
                                  'commission_base_rate', 'commission_rule_id', 'commission_tier_id',
                                  'commission_promotion_id', 'commission_locked_at', 'commission_amount',
                                  'commission_charged_at', 'driver_drop_reason'])
             || case when ok then '{}'::jsonb
                     else jsonb_build_object(
                       'pickup_name', public.c2c_area(b.pickup_place), 'pickup_address', null,
                       'pickup_lat', null, 'pickup_lng', null,
                       'drop_name', public.c2c_area(b.drop_place), 'drop_address', null,
                       'drop_lat', null, 'drop_lng', null, 'note', null) end
             || jsonb_build_object(
                  'rider_name', public.c2c_short_name(pr.name),
                  'rider_rating', pr.rider_rating,
                  'eligibility', el.e - 'ruleId',
                  'commission_rate_now', case when ok then public.c2c_commission_now(v_uid, b) end,
                  'my_offer', (select jsonb_build_object('id', o.id, 'price', o.price, 'leave_at', o.leave_at,
                                                         'note', o.note)
                                 from public.c2c_offers o
                                where o.booking_id = b.id and o.driver_id = v_uid and o.status = 'open'
                                limit 1)) as item
        from public.c2c_bookings b
        cross join lateral (select public.c2c_driver_eligibility(v_uid, b.pickup_place, b.drop_place) as e) el
        cross join lateral (select coalesce((el.e->>'ok')::boolean, false) as ok) k
        left join public.profiles pr on pr.id = b.rider_id
       where b.status in ('open', 'offered')
         and b.expires_at > now()
         and b.rider_id <> v_uid
         and public.c2c_driver_in_reach(v_uid, b.pickup_place)
       order by b.leave_at, b.id
       limit 100) x;

  return jsonb_build_object(
    'approved', coalesce(pa.status = 'approved', false),
    'hasArea', coalesce(pa.has_area, false),
    'drivingSince', v_since,
    'years', case when v_since is null then null else extract(year from age(current_date, v_since))::integer end,
    'canSetDrivingSince', pa.status is not null and v_since is null,
    'requests', v_list);
end;
$$;
revoke execute on function public.c2c_driver_requests() from public, anon;
grant execute on function public.c2c_driver_requests() to authenticated, service_role;

-- ---- 2. The driver gives a booked trip up -----------------------------------------------------------------
-- {status: 'open'}. See item 2 above for the rule.
create or replace function public.c2c_driver_cancel(p_booking uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status = 'on_trip' then
    raise exception 'C2C_ON_TRIP' using errcode = '22023',
      hint = 'The rider is on board. Finish the trip, or contact support.';
  end if;
  if b.status not in ('booked', 'driver_arriving') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip has already ended.';
  end if;
  if now() >= b.leave_at then
    raise exception 'C2C_TOO_LATE' using errcode = '22023',
      hint = 'It is past the time to leave. Contact support to cancel this trip.';
  end if;

  update public.c2c_offers set status = 'withdrawn'
   where booking_id = b.id and driver_id = b.driver_id and status = 'accepted';
  update public.c2c_bookings
     set status = 'open', driver_id = null, offer_id = null, agreed_fare = null, driver_leave_at = null,
         booked_at = null, arriving_at = null,
         commission_rate = null, commission_base_rate = null, commission_rule_id = null,
         commission_tier_id = null, commission_promotion_id = null, commission_locked_at = null,
         driver_dropped_at = now(), driver_drop_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300)
   where id = b.id;
  return jsonb_build_object('status', 'open');
end;
$$;
revoke execute on function public.c2c_driver_cancel(uuid, text) from public, anon;
grant execute on function public.c2c_driver_cancel(uuid, text) to authenticated, service_role;

-- ---- 3. Driving since, from the driver, once ---------------------------------------------------------------
-- Sets the caller's partners.driving_since to [p_since] while the server
-- knows no date for them. The date set.
create or replace function public.c2c_set_driving_since(p_since date)
returns date
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not exists (select 1 from public.partners p where p.auth_user_id = v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if public.c2c_driving_since(v_uid) is not null then
    raise exception 'C2C_DRIVING_SINCE_SET' using errcode = '22023',
      hint = 'Your driving start date is already on file. Ask support to change it.';
  end if;
  if p_since is null or p_since > current_date or p_since < date '1930-01-01' then
    raise exception 'C2C_BAD_DATE' using errcode = '22023',
      hint = 'Enter the date your driving licence was first issued.';
  end if;
  update public.partners set driving_since = p_since where auth_user_id = v_uid;
  return p_since;
end;
$$;
revoke execute on function public.c2c_set_driving_since(date) from public, anon;
grant execute on function public.c2c_set_driving_since(date) to authenticated, service_role;

-- The driver's own writes to partners leave driving_since alone; admins
-- and the server (c2c_set_driving_since runs as its owner) may set it.
create or replace function public.partners_guard_driving_since()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if (tg_op = 'INSERT' and new.driving_since is not null)
     or (tg_op = 'UPDATE' and new.driving_since is distinct from old.driving_since) then
    raise exception 'PARTNERS_PROTECTED_COLUMN:driving_since' using errcode = '42501',
      hint = 'Set it in City to City, or ask an administrator.';
  end if;
  return new;
end;
$$;
revoke execute on function public.partners_guard_driving_since() from public, anon, authenticated;
drop trigger if exists trg_partners_guard_driving_since on public.partners;
create trigger trg_partners_guard_driving_since
  before insert or update of driving_since on public.partners
  for each row execute function public.partners_guard_driving_since();

-- ---- 4. One rating for the driver ----------------------------------------------------------------------------
-- Averages [p_partner]'s city ride ratings (ride_ratings) and rated City to
-- City trips onto partners.rating. {rating, ratings}.
create or replace function public.partner_rating_refresh(p_partner uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_avg numeric;
  v_count integer;
begin
  select round(avg(s.stars)::numeric, 2), count(*)::integer into v_avg, v_count
    from (select x.stars::integer as stars from public.ride_ratings x where x.partner_id = p_partner
          union all
          select c.rider_stars::integer from public.c2c_bookings c
           where c.driver_id = p_partner and c.rider_stars is not null) s;
  if v_count > 0 then
    update public.partners set rating = v_avg where auth_user_id = p_partner;
  end if;
  return jsonb_build_object('rating', v_avg, 'ratings', v_count);
end;
$$;
revoke execute on function public.partner_rating_refresh(uuid) from public, anon, authenticated;

-- As 0297, the average from partner_rating_refresh.
create or replace function public.rate_ride(p_request_id uuid, p_stars int, p_comment text default null,
                                            p_tags text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_uid uuid := auth.uid();
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
  v_tags text[];
  v_sum jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request_id;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' or r.partner_id is null then
    raise exception 'not_completed';
  end if;
  if coalesce(r.completed_at, r.updated_at) < now() - interval '7 days' then
    raise exception 'too_late';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'bad_stars' using errcode = '22023';
  end if;

  -- Without p_tags (an app from before 0297) the tags already given stay.
  if p_tags is null then
    select x.tags into v_tags from public.ride_ratings x where x.request_id = p_request_id and x.rater_id = v_uid;
  end if;
  v_tags := public.driver_rating_tags_for(p_stars, coalesce(p_tags, v_tags));

  insert into public.ride_ratings (request_id, rater_id, partner_id, stars, comment, tags)
  values (p_request_id, v_uid, r.partner_id, p_stars, left(v_comment, 500), v_tags)
  on conflict (request_id, rater_id) do update
     set stars = excluded.stars,
         comment = excluded.comment,
         tags = excluded.tags,
         partner_id = excluded.partner_id,
         updated_at = now();

  v_sum := public.partner_rating_refresh(r.partner_id);

  return jsonb_build_object(
    'stars', p_stars,
    'comment', left(v_comment, 500),
    'tags', to_jsonb(v_tags),
    'partner_rating', (v_sum->>'rating')::numeric,
    'ratings', (v_sum->>'ratings')::integer);
end;
$$;
revoke execute on function public.rate_ride(uuid, int, text, text[]) from public, anon;
grant execute on function public.rate_ride(uuid, int, text, text[]) to authenticated;

-- As 0307, then the driver's rating.
create or replace function public.c2c_rate_driver(p_booking uuid, p_stars integer, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status <> 'completed' then
    raise exception 'C2C_NOT_DONE' using errcode = '22023', hint = 'Rate the driver after the trip.';
  end if;
  if b.rated_at is not null then
    raise exception 'C2C_RATED' using errcode = '22023', hint = 'You have already rated this trip.';
  end if;
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'C2C_BAD_RATING' using errcode = '22023', hint = 'Pick 1 to 5 stars.';
  end if;
  update public.c2c_bookings
     set rider_stars = p_stars, rider_comment = left(nullif(btrim(coalesce(p_comment, '')), ''), 500), rated_at = now()
   where id = b.id;
  if b.driver_id is not null then
    perform public.partner_rating_refresh(b.driver_id);
  end if;
end;
$$;
revoke execute on function public.c2c_rate_driver(uuid, integer, text) from public, anon;
grant execute on function public.c2c_rate_driver(uuid, integer, text) to authenticated, service_role;

-- ---- 5. The ride chat carries City to City threads ------------------------------------------------------
alter table public.ride_messages
  add column if not exists c2c_booking_id uuid references public.c2c_bookings(id) on delete cascade;
alter table public.ride_messages alter column request_id drop not null;
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.ride_messages'::regclass and conname = 'ride_messages_one_thread') then
    alter table public.ride_messages add constraint ride_messages_one_thread
      check (num_nonnulls(request_id, c2c_booking_id) = 1);
  end if;
end $$;
create index if not exists ride_messages_c2c_idx on public.ride_messages (c2c_booking_id, created_at)
  where c2c_booking_id is not null;
comment on column public.ride_messages.c2c_booking_id is
  'A City to City booking''s thread (0308); request_id is null then.';

-- As 0140, the file in the thread's own folder: the ride's, or the booking's.
alter table public.ride_messages drop constraint if exists ride_messages_content;
alter table public.ride_messages add constraint ride_messages_content check (coalesce(
  case type
    when 'location' then latitude between -90 and 90 and longitude between -180 and 180
                         and media_path is null
    when 'image' then starts_with(media_path, coalesce(request_id, c2c_booking_id)::text || '/')
                      and char_length(media_path) <= 300
                      and (body is null or char_length(body) between 1 and 1000)
    when 'audio' then starts_with(media_path, coalesce(request_id, c2c_booking_id)::text || '/')
                      and char_length(media_path) <= 300
                      and media_duration between 0 and 300
                      and body is null
    else char_length(btrim(body)) between 1 and 1000 and media_path is null
  end, false));

-- Who may read a booking's thread, and see message [p_at]: the rider, and
-- the booked driver from when they were booked. The bookings are read
-- under the caller's own row-level security.
drop policy if exists "ride_messages c2c read" on public.ride_messages;
create policy "ride_messages c2c read" on public.ride_messages for select to authenticated
  using (c2c_booking_id is not null
         and exists (select 1 from public.c2c_bookings b
                      where b.id = ride_messages.c2c_booking_id
                        and (b.rider_id = (select auth.uid())
                             or (b.driver_id = (select auth.uid())
                                 and ride_messages.created_at >= coalesce(b.booked_at, '-infinity'::timestamptz)))));
drop policy if exists "ride_messages c2c insert" on public.ride_messages;
create policy "ride_messages c2c insert" on public.ride_messages for insert to authenticated
  with check (c2c_booking_id is not null and request_id is null
              and sender_id = (select auth.uid())
              and exists (select 1 from public.c2c_bookings b
                           where b.id = ride_messages.c2c_booking_id
                             and b.status in ('booked', 'driver_arriving', 'on_trip')
                             and ((ride_messages.sender_role = 'rider' and b.rider_id = (select auth.uid()))
                                  or (ride_messages.sender_role = 'partner' and b.driver_id = (select auth.uid())))));
-- The tick: which participant may move it is the guard trigger's job.
drop policy if exists "ride_messages c2c update" on public.ride_messages;
create policy "ride_messages c2c update" on public.ride_messages for update to authenticated
  using (c2c_booking_id is not null
         and exists (select 1 from public.c2c_bookings b
                      where b.id = ride_messages.c2c_booking_id
                        and (b.rider_id = (select auth.uid()) or b.driver_id = (select auth.uid()))))
  with check (c2c_booking_id is not null
              and exists (select 1 from public.c2c_bookings b
                           where b.id = ride_messages.c2c_booking_id
                             and (b.rider_id = (select auth.uid()) or b.driver_id = (select auth.uid()))));

-- As 0140, with the thread fixed too, and a booking's receiver.
create or replace function public.ride_messages_guard_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rider uuid;
  v_partner uuid;
  v_receiver uuid;
begin
  if (new.id, new.request_id, new.c2c_booking_id, new.sender_id, new.sender_role, new.type, new.body,
      new.latitude, new.longitude, new.media_path, new.media_duration, new.created_at)
     is distinct from
     (old.id, old.request_id, old.c2c_booking_id, old.sender_id, old.sender_role, old.type, old.body,
      old.latitude, old.longitude, old.media_path, old.media_duration, old.created_at) then
    raise exception 'only a message''s status can change' using errcode = '42501';
  end if;
  if array_position(array['sent', 'delivered', 'read'], new.status)
     < array_position(array['sent', 'delivered', 'read'], old.status) then
    raise exception 'a message''s status only moves forward' using errcode = '42501';
  end if;
  if new.status is not distinct from old.status or public.caller_is_admin() then
    return new;
  end if;
  if old.request_id is not null then
    select rider_id, partner_id into v_rider, v_partner from public.ride_requests where id = old.request_id;
  else
    select rider_id, driver_id into v_rider, v_partner from public.c2c_bookings where id = old.c2c_booking_id;
  end if;
  v_receiver := case old.sender_role when 'rider' then v_partner else v_rider end;
  if auth.uid() is null or auth.uid() is distinct from v_receiver then
    raise exception 'only the receiver can mark a message delivered or read' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_messages_guard_update() from public, anon, authenticated;

-- As 0146; a booking's message names the rider or the driver from their
-- profiles and carries the booking's id instead of the ride's.
create or replace function public.notify_ride_message_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_to uuid;
  v_to_role text;
  v_title text;
begin
  if new.request_id is null and new.c2c_booking_id is not null then
    select b.rider_id, b.driver_id as partner_id,
           (select nullif(btrim(p.name), '') from public.profiles p where p.id = b.rider_id) as rider_name,
           coalesce((select nullif(btrim(pa.name), '') from public.partners pa where pa.auth_user_id = b.driver_id
                      order by pa.created_at limit 1),
                    (select nullif(btrim(p.name), '') from public.profiles p where p.id = b.driver_id)) as partner_name
      into r
      from public.c2c_bookings b where b.id = new.c2c_booking_id;
  else
    select rider_id, partner_id, rider_name, partner_name into r
      from public.ride_requests where id = new.request_id;
  end if;
  if new.sender_role = 'rider' then
    v_to := r.partner_id;
    v_to_role := 'partner';
    v_title := coalesce(nullif(btrim(coalesce(r.rider_name, '')), ''), 'Your passenger');
  else
    v_to := r.rider_id;
    v_to_role := 'rider';
    v_title := coalesce(nullif(btrim(coalesce(r.partner_name, '')), ''), 'Your driver');
  end if;
  if v_to is null or v_to = new.sender_id then
    return new;
  end if;
  perform public.enqueue_notification(
    v_to,
    'msg:' || new.id,
    'ride_message',
    'normal',
    v_title,
    public.ride_message_push_body(new.type, new.body),
    case when new.request_id is null
         then jsonb_build_object('type', 'ride_message', 'c2c_booking_id', new.c2c_booking_id, 'role', v_to_role,
                                 'message_id', new.id)
         else jsonb_build_object('type', 'ride_message', 'request_id', new.request_id, 'role', v_to_role,
                                 'message_id', new.id) end,
    new.request_id
  );
  return new;
exception when others then
  return new;
end;
$$;
revoke execute on function public.notify_ride_message_push() from public, anon, authenticated;

-- As 0140, and a booking's folder: its rider and booked driver, adding
-- files only while it takes messages.
create or replace function public.ride_chat_media_allowed(p_name text, p_open boolean)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    exists (
      select 1 from public.ride_requests r
       where r.id::text = split_part(coalesce(p_name, ''), '/', 1)
         and (r.rider_id = auth.uid() or r.partner_id = auth.uid())
         and (not p_open or r.status in ('accepted', 'arrived', 'on_trip')))
    or exists (
      select 1 from public.c2c_bookings b
       where b.id::text = split_part(coalesce(p_name, ''), '/', 1)
         and (b.rider_id = auth.uid() or b.driver_id = auth.uid())
         and (not p_open or b.status in ('booked', 'driver_arriving', 'on_trip'))));
$$;
revoke execute on function public.ride_chat_media_allowed(text, boolean) from public, anon;
grant execute on function public.ride_chat_media_allowed(text, boolean) to authenticated;

notify pgrst, 'reload schema';
