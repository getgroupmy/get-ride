-- ============================================================================
-- 0199: handing a trip to another driver mid-trip.
--
-- On a trip under way (on_trip), the driver can ask for another driver to
-- take over:
--
--   1. The driver asks, naming a driver by code (My Ride code or GET.me QR)
--      or asking every nearby partner (trip_handover_request).
--   2. The passenger is asked first and approves or declines
--      (trip_handover_rider_answer). Nothing goes to other drivers before.
--   3. The driver named, or every online partner within the admin's radius
--      of the car not on a trip of their own, is asked. The first to accept
--      takes over (trip_handover_accept): the trip becomes theirs and they
--      head to where the car is (the meeting point, kept on the ride), then
--      confirm the passenger is with them (trip_handover_boarded).
--   4. The new driver collects everything and pays the commission and fees
--      as usual. When the trip completes, the first driver's share of the
--      net earnings (the admin's percentage, default 10; a region can set
--      its own, handoverSharePercent in the region's values) moves from the
--      new driver's GET credit to the first driver's.
--
-- Nobody answering in time (the admin's minutes) lapses the request; the
-- first driver can withdraw it until it is accepted. Everyone involved is
-- told each step.
--
-- Admin -> App Settings -> Trip handover (app_settings 'trip_handover'):
--   enabled, sharePercent, nearbyRadiusKm, answerMinutes.
-- ============================================================================

-- ---- Settings ---------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('trip_handover', jsonb_build_object('enabled', true, 'sharePercent', 10, 'nearbyRadiusKm', 5, 'answerMinutes', 5))
on conflict (key) do nothing;

create or replace function public.trip_handover_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'enabled', coalesce((v->>'enabled')::boolean, true),
    'sharePercent', round(public.scheduled_cfg_num(v, 'sharePercent', 10, 0, 100), 2),
    'nearbyRadiusKm', round(public.scheduled_cfg_num(v, 'nearbyRadiusKm', 5, 0.5, 50), 1),
    'answerMinutes', public.scheduled_cfg_num(v, 'answerMinutes', 5, 1, 30)::int
  )
  from (select (select value from public.app_settings where key = 'trip_handover') as v) s;
$$;
revoke execute on function public.trip_handover_config() from public;
grant execute on function public.trip_handover_config() to anon, authenticated;

create or replace function public.set_trip_handover_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change trip handover.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('trip_handover', coalesce(p_config, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  v := public.trip_handover_config();
  update public.app_settings set value = v where key = 'trip_handover';
  return v;
end;
$$;
revoke execute on function public.set_trip_handover_config(jsonb) from public, anon;
grant execute on function public.set_trip_handover_config(jsonb) to authenticated;

-- The share for a ride's region: the most specific region (suburb, city,
-- state, country) that sets handoverSharePercent, else the setting.
create or replace function public.trip_handover_share_percent(p_country text, p_state text, p_city text, p_suburb text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with found as (
    select 1 as rank, s."values" as v from public.suburbs s
     where s.country = p_country and s.state = p_state and s.city = p_city and s.name = p_suburb
    union all
    select 2, c."values" from public.cities c where c.country = p_country and c.state = p_state and c.name = p_city
    union all
    select 3, st."values" from public.states st where st.country = p_country and st.name = p_state
    union all
    select 4, co."values" from public.countries co where co.name = p_country
  )
  select coalesce(
    (select least(100, greatest(0, (v->>'handoverSharePercent')::numeric)) from found
      where jsonb_typeof(v->'handoverSharePercent') = 'number' order by rank limit 1),
    (public.trip_handover_config()->>'sharePercent')::numeric);
$$;
revoke execute on function public.trip_handover_share_percent(text, text, text, text) from public, anon, authenticated;

-- ---- The ride: where the new driver meets the car, and when they did --------------------
alter table public.ride_requests
  add column if not exists handover_meet_lat double precision,
  add column if not exists handover_meet_lng double precision,
  add column if not exists handed_over_at timestamptz,
  add column if not exists handover_boarded_at timestamptz;

-- ---- Handovers -----------------------------------------------------------------------------
create table if not exists public.trip_handovers (
  id              uuid primary key default gen_random_uuid(),
  ride_id         uuid not null references public.ride_requests(id) on delete cascade,
  rider_id        uuid not null references auth.users(id) on delete cascade,
  from_partner_id uuid not null references auth.users(id) on delete cascade,
  to_partner_id   uuid references auth.users(id) on delete set null,
  mode            text not null check (mode in ('code', 'nearby')),
  status          text not null default 'awaiting_rider'
                  check (status in ('awaiting_rider', 'offered', 'accepted', 'declined_rider', 'declined_driver',
                                    'cancelled', 'expired')),
  note            text,
  share_percent   numeric(5,2),
  meet_lat        double precision,
  meet_lng        double precision,
  answer_by       timestamptz not null,
  created_at      timestamptz not null default now(),
  approved_at     timestamptz,
  accepted_at     timestamptz,
  boarded_at      timestamptz,
  share_amount    numeric(12,2),
  settled_at      timestamptz
);
create unique index if not exists trip_handovers_one_open
  on public.trip_handovers (ride_id) where status in ('awaiting_rider', 'offered');
create index if not exists trip_handovers_ride_idx on public.trip_handovers (ride_id);
create index if not exists trip_handovers_due_idx on public.trip_handovers (answer_by)
  where status in ('awaiting_rider', 'offered');

-- The partners asked (one by code, or every nearby one).
create table if not exists public.trip_handover_candidates (
  handover_id uuid not null references public.trip_handovers(id) on delete cascade,
  partner_id  uuid not null references auth.users(id) on delete cascade,
  primary key (handover_id, partner_id)
);
-- Set when the handover is no longer open, so the partners asked see the
-- offer go (they can't read the handover itself).
alter table public.trip_handover_candidates add column if not exists closed boolean not null default false;
create index if not exists trip_handover_candidates_partner_idx on public.trip_handover_candidates (partner_id);

alter table public.trip_handovers enable row level security;
alter table public.trip_handover_candidates enable row level security;
revoke all on public.trip_handovers, public.trip_handover_candidates from anon, authenticated;
grant select on public.trip_handovers to authenticated;
drop policy if exists "trip_handovers parties" on public.trip_handovers;
create policy "trip_handovers parties" on public.trip_handovers
  for select to authenticated
  using (rider_id = (select auth.uid()) or from_partner_id = (select auth.uid()) or to_partner_id = (select auth.uid()));

grant select on public.trip_handover_candidates to authenticated;
drop policy if exists "trip_handover_candidates own" on public.trip_handover_candidates;
create policy "trip_handover_candidates own" on public.trip_handover_candidates
  for select to authenticated
  using (partner_id = (select auth.uid()));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'trip_handovers') then
    alter publication supabase_realtime add table public.trip_handovers;
  end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'trip_handover_candidates') then
    alter publication supabase_realtime add table public.trip_handover_candidates;
  end if;
end $$;

-- Whether a partner is on a ride of their own (accepted, arrived or under way).
create or replace function public.partner_busy(p_partner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ride_requests
                  where partner_id = p_partner and status in ('accepted', 'arrived', 'on_trip'));
$$;
revoke execute on function public.partner_busy(uuid) from public, anon, authenticated;

create or replace function public.trip_handover_name(p_partner uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$ select coalesce(nullif(trim((public.my_ride_partner_of(p_partner)).name), ''), 'A driver') $$;
revoke execute on function public.trip_handover_name(uuid) from public, anon, authenticated;

-- ---- 1. The driver asks ----------------------------------------------------------------------
-- p_code: a driver's My Ride code or GET.me QR; null asks nearby partners.
create or replace function public.trip_handover_request(p_ride uuid, p_code text default null, p_note text default null)
returns public.trip_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  c     jsonb := public.trip_handover_config();
  v_uid uuid := auth.uid();
  v_to  uuid;
  r     public.ride_requests;
  h     public.trip_handovers;
begin
  if not coalesce((c->>'enabled')::boolean, false) then
    raise exception 'HANDOVER_OFF' using hint = 'Handing a trip over is not available.';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.partner_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'on_trip' then
    raise exception 'HANDOVER_NOT_ON_TRIP' using hint = 'A trip can be handed over once it has started.';
  end if;
  if exists (select 1 from public.trip_handovers where ride_id = r.id and status in ('awaiting_rider', 'offered')) then
    raise exception 'HANDOVER_OPEN' using hint = 'A handover for this trip is already waiting for an answer.';
  end if;
  if nullif(trim(coalesce(p_code, '')), '') is not null then
    v_to := public.scheduled_partner_by_code(p_code);
    if v_to = v_uid then
      raise exception 'SCHEDULED_CODE_SELF' using hint = 'That is your own code.';
    end if;
    if v_to = r.rider_id then
      raise exception 'SCHEDULED_CODE_UNAVAILABLE' using hint = 'This driver can''t take this trip.';
    end if;
  end if;

  insert into public.trip_handovers (ride_id, rider_id, from_partner_id, to_partner_id, mode, note, answer_by)
  values (r.id, r.rider_id, v_uid, v_to, case when v_to is null then 'nearby' else 'code' end,
          left(nullif(trim(coalesce(p_note, '')), ''), 200),
          now() + make_interval(mins => (c->>'answerMinutes')::int))
  returning * into h;

  perform public.enqueue_notification(r.rider_id, 'handover-ask-' || h.id, 'trip_handover', 'critical',
    'Your driver asks to hand over your trip',
    case when v_to is null then 'Another driver nearby would take you the rest of the way.'
         else public.trip_handover_name(v_to) || ' would take you the rest of the way.' end ||
    coalesce(' "' || h.note || '"', '') || ' Approve or decline it.',
    jsonb_build_object('type', 'trip_handover_approval', 'handover_id', h.id, 'request_id', r.id), r.id);
  return h;
end;
$$;
revoke execute on function public.trip_handover_request(uuid, text, text) from public, anon;
grant execute on function public.trip_handover_request(uuid, text, text) to authenticated;

-- ---- 2. The passenger answers; approved, the partners are asked ------------------------------
create or replace function public.trip_handover_rider_answer(p_handover uuid, p_approve boolean)
returns public.trip_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  c       jsonb := public.trip_handover_config();
  h       public.trip_handovers;
  r       public.ride_requests;
  v_lat   double precision;
  v_lng   double precision;
  v_told  int := 0;
  x       record;
begin
  select * into h from public.trip_handovers where id = p_handover for update;
  if not found or h.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if h.status <> 'awaiting_rider' or h.answer_by <= now() then
    raise exception 'HANDOVER_GONE' using hint = 'This request is no longer open.';
  end if;
  select * into r from public.ride_requests where id = h.ride_id;

  if not coalesce(p_approve, false) then
    update public.trip_handovers set status = 'declined_rider' where id = h.id returning * into h;
    perform public.enqueue_notification(h.from_partner_id, 'handover-rider-no-' || h.id, 'trip_handover', 'critical',
      'Handover declined', 'The passenger would rather you finish the trip.',
      jsonb_build_object('type', 'trip_handover_declined', 'handover_id', h.id, 'request_id', h.ride_id,
                         'role', 'partner'), h.ride_id);
    return h;
  end if;

  if r.status <> 'on_trip' or r.partner_id is distinct from h.from_partner_id then
    update public.trip_handovers set status = 'cancelled' where id = h.id returning * into h;
    return h;
  end if;

  v_lat := coalesce(r.partner_live_lat, r.pickup_lat);
  v_lng := coalesce(r.partner_live_lng, r.pickup_lng);
  update public.trip_handovers
     set status = 'offered', approved_at = now(), meet_lat = v_lat, meet_lng = v_lng,
         answer_by = now() + make_interval(mins => (c->>'answerMinutes')::int)
   where id = h.id
  returning * into h;

  if h.to_partner_id is not null then
    insert into public.trip_handover_candidates (handover_id, partner_id) values (h.id, h.to_partner_id);
  else
    insert into public.trip_handover_candidates (handover_id, partner_id)
    select h.id, d
      from public.nearby_online_drivers(v_lat, v_lng, (c->>'nearbyRadiusKm')::double precision) d
     where d <> h.from_partner_id and d <> h.rider_id and not public.partner_busy(d)
       and public.partner_status_bookable((public.my_ride_partner_of(d)).status::text);
  end if;

  for x in select partner_id from public.trip_handover_candidates where handover_id = h.id loop
    perform public.enqueue_notification(x.partner_id, 'handover-offer-' || h.id || '-' || x.partner_id,
      'trip_handover', 'critical', 'A driver needs you to take over a trip',
      public.trip_handover_name(h.from_partner_id) || ' asks you to take a passenger the rest of the way' ||
      coalesce(' to ' || nullif(trim(r.drop_address), ''), '') || '. The first to accept takes it.',
      jsonb_build_object('type', 'trip_handover_offer', 'handover_id', h.id, 'role', 'partner'));
    v_told := v_told + 1;
  end loop;

  if v_told = 0 then
    update public.trip_handovers set status = 'expired' where id = h.id returning * into h;
    perform public.enqueue_notification(h.from_partner_id, 'handover-none-' || h.id, 'trip_handover', 'critical',
      'No partner nearby', 'No partner is online near you right now. Try again shortly, or ask one by code.',
      jsonb_build_object('type', 'trip_handover_expired', 'handover_id', h.id, 'request_id', h.ride_id,
                         'role', 'partner'), h.ride_id);
  end if;
  return h;
end;
$$;
revoke execute on function public.trip_handover_rider_answer(uuid, boolean) from public, anon;
grant execute on function public.trip_handover_rider_answer(uuid, boolean) to authenticated;

-- What a partner asked to take over sees: where the car is, where it is
-- going, the fare and their part of it (not who the passenger is).
create or replace function public.trip_handover_offers_for_me()
returns table (
  id uuid, ride_id uuid, from_name text, note text, answer_by timestamptz,
  meet_lat double precision, meet_lng double precision, drop_address text, drop_lat double precision,
  drop_lng double precision, fare numeric, currency text, share_percent numeric)
language sql
stable
security definer
set search_path = public
as $$
  select h.id, h.ride_id, public.trip_handover_name(h.from_partner_id), h.note, h.answer_by,
         h.meet_lat, h.meet_lng, r.drop_address, r.drop_lat, r.drop_lng,
         round(coalesce(r.ride_fare, r.fare, 0), 2), r.currency,
         public.trip_handover_share_percent(r.country, r.state, r.city, r.suburb)
    from public.trip_handovers h
    join public.trip_handover_candidates k on k.handover_id = h.id and k.partner_id = auth.uid()
    join public.ride_requests r on r.id = h.ride_id
   where h.status = 'offered' and h.answer_by > now() and public.caller_is_approved_partner()
   order by h.answer_by;
$$;
revoke execute on function public.trip_handover_offers_for_me() from public, anon;
grant execute on function public.trip_handover_offers_for_me() to authenticated;

-- ---- 3. A partner asked accepts (the first) or declines ------------------------------------
create or replace function public.trip_handover_accept(p_handover uuid)
returns public.trip_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  h      public.trip_handovers;
  r      public.ride_requests;
  card   record;
  v_pct  numeric;
  v_name text;
  x      record;
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into h from public.trip_handovers where id = p_handover for update;
  if not found or not exists (select 1 from public.trip_handover_candidates
                               where handover_id = h.id and partner_id = v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if h.status <> 'offered' or h.answer_by <= now() then
    raise exception 'HANDOVER_GONE' using hint = 'Another partner took it, or it is no longer open.';
  end if;
  if public.partner_busy(v_uid) then
    raise exception 'HANDOVER_BUSY' using hint = 'Finish your own trip first.';
  end if;
  select * into r from public.ride_requests where id = h.ride_id for update;
  if r.status <> 'on_trip' or r.partner_id is distinct from h.from_partner_id then
    update public.trip_handovers set status = 'cancelled' where id = h.id;
    raise exception 'HANDOVER_GONE' using hint = 'This trip is no longer waiting for a handover.';
  end if;

  select * into card from public.ride_partner_card(v_uid);
  v_pct := public.trip_handover_share_percent(r.country, r.state, r.city, r.suburb);
  v_name := coalesce(card.name, public.trip_handover_name(v_uid));

  update public.trip_handovers
     set status = 'accepted', to_partner_id = v_uid, accepted_at = now(), share_percent = v_pct
   where id = h.id
  returning * into h;

  update public.ride_requests
     set partner_id = v_uid, partner_name = card.name, partner_phone = card.phone, partner_photo = card.photo,
         partner_rating = card.rating, partner_plate = card.plate, partner_vehicle = card.vehicle,
         partner_live_lat = null, partner_live_lng = null, partner_live_heading = null, partner_live_at = null,
         handover_meet_lat = h.meet_lat, handover_meet_lng = h.meet_lng,
         handed_over_at = now(), handover_boarded_at = null
   where id = r.id;

  perform public.enqueue_notification(h.rider_id, 'handover-taken-' || h.id, 'trip_handover', 'critical',
    'Your new driver is on the way', v_name || ' is coming to where you are to take you the rest of the way.',
    jsonb_build_object('type', 'trip_handover_accepted', 'handover_id', h.id, 'request_id', r.id), r.id);
  perform public.enqueue_notification(h.from_partner_id, 'handover-accepted-' || h.id, 'trip_handover', 'critical',
    'Trip handed over',
    v_name || ' is coming to take over. Wait with the passenger until they arrive. You get ' ||
    trim(to_char(v_pct, 'FM990.##')) || '% of the trip''s net earnings when it completes.',
    jsonb_build_object('type', 'trip_handover_accepted', 'handover_id', h.id, 'role', 'partner'));
  for x in select partner_id from public.trip_handover_candidates where handover_id = h.id and partner_id <> v_uid loop
    perform public.enqueue_notification(x.partner_id, 'handover-gone-' || h.id || '-' || x.partner_id,
      'trip_handover', 'normal', 'Trip taken', 'Another partner took over the trip.',
      jsonb_build_object('type', 'trip_handover_taken', 'handover_id', h.id, 'role', 'partner'));
  end loop;
  return h;
end;
$$;
revoke execute on function public.trip_handover_accept(uuid) from public, anon;
grant execute on function public.trip_handover_accept(uuid) to authenticated;

-- The partner named by code declines (nearby partners simply don't accept).
create or replace function public.trip_handover_decline(p_handover uuid)
returns public.trip_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.trip_handovers;
begin
  select * into h from public.trip_handovers where id = p_handover for update;
  if not found or not exists (select 1 from public.trip_handover_candidates
                               where handover_id = h.id and partner_id = auth.uid()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if h.status <> 'offered' then
    return h;
  end if;
  delete from public.trip_handover_candidates where handover_id = h.id and partner_id = auth.uid();
  if not exists (select 1 from public.trip_handover_candidates where handover_id = h.id) then
    update public.trip_handovers set status = 'declined_driver' where id = h.id returning * into h;
    perform public.enqueue_notification(h.from_partner_id, 'handover-driver-no-' || h.id, 'trip_handover', 'critical',
      'Handover declined',
      case when h.mode = 'code' then public.trip_handover_name(auth.uid()) || ' can''t take over.'
           else 'No partner nearby can take over.' end || ' Please carry on with the trip, or ask again.',
      jsonb_build_object('type', 'trip_handover_declined', 'handover_id', h.id, 'request_id', h.ride_id,
                         'role', 'partner'), h.ride_id);
  end if;
  return h;
end;
$$;
revoke execute on function public.trip_handover_decline(uuid) from public, anon;
grant execute on function public.trip_handover_decline(uuid) to authenticated;

-- The new driver has the passenger.
create or replace function public.trip_handover_boarded(p_handover uuid)
returns public.trip_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.trip_handovers;
begin
  select * into h from public.trip_handovers where id = p_handover for update;
  if not found or h.to_partner_id is distinct from auth.uid() or h.status <> 'accepted' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if h.boarded_at is null then
    update public.trip_handovers set boarded_at = now() where id = h.id returning * into h;
    update public.ride_requests set handover_boarded_at = now()
     where id = h.ride_id and partner_id = auth.uid();
  end if;
  return h;
end;
$$;
revoke execute on function public.trip_handover_boarded(uuid) from public, anon;
grant execute on function public.trip_handover_boarded(uuid) to authenticated;

-- The first driver withdraws it, until it is accepted.
create or replace function public.trip_handover_cancel(p_handover uuid)
returns public.trip_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.trip_handovers;
  x record;
begin
  select * into h from public.trip_handovers where id = p_handover for update;
  if not found or h.from_partner_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if h.status not in ('awaiting_rider', 'offered') then
    return h;
  end if;
  update public.trip_handovers set status = 'cancelled' where id = h.id returning * into h;
  perform public.enqueue_notification(h.rider_id, 'handover-withdrawn-' || h.id, 'trip_handover', 'normal',
    'Your driver carries on', 'Your driver withdrew the handover and will finish your trip.',
    jsonb_build_object('type', 'trip_handover_withdrawn', 'handover_id', h.id, 'request_id', h.ride_id), h.ride_id);
  for x in select partner_id from public.trip_handover_candidates where handover_id = h.id loop
    perform public.enqueue_notification(x.partner_id, 'handover-withdrawn-' || h.id || '-' || x.partner_id,
      'trip_handover', 'normal', 'Request withdrawn', 'The driver no longer needs a partner to take over.',
      jsonb_build_object('type', 'trip_handover_taken', 'handover_id', h.id, 'role', 'partner'));
  end loop;
  return h;
end;
$$;
revoke execute on function public.trip_handover_cancel(uuid) from public, anon;
grant execute on function public.trip_handover_cancel(uuid) to authenticated;

-- ---- 4. The share, when the trip completes --------------------------------------------------
-- Net earnings: everything the passenger owes, less the commission and the
-- platform's fees on it, as the trip's last driver is charged them.
create or replace function public.ride_net_earnings(r public.ride_requests)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, round(public.ride_amount_due(r) - coalesce(r.commission_amount, 0) - coalesce((
    select sum(round((e->>'value')::numeric, 2))
      from jsonb_array_elements(case when jsonb_typeof(r.charges) = 'array' then r.charges else '[]'::jsonb end) e
     where (e->>'platform')::boolean is true and e->>'charge' = 'fixed'
       and jsonb_typeof(e->'value') = 'number' and (e->>'value')::numeric > 0), 0), 2));
$$;
revoke execute on function public.ride_net_earnings(public.ride_requests) from public, anon, authenticated;

create or replace function public.ride_requests_handover_share()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r      public.ride_requests;
  h      record;
  v_net  numeric;
  v_amt  numeric(12,2);
begin
  if new.status <> 'completed' or old.status = 'completed' or new.partner_id is null then
    return null;
  end if;
  if not exists (select 1 from public.trip_handovers where ride_id = new.id and status = 'accepted' and settled_at is null) then
    return null;
  end if;
  -- After the commission (its trigger sorts first), so the net counts it.
  select * into r from public.ride_requests where id = new.id;
  v_net := public.ride_net_earnings(r);
  for h in
    select * from public.trip_handovers
     where ride_id = new.id and status = 'accepted' and settled_at is null
     order by accepted_at
     for update
  loop
    v_amt := round(v_net * coalesce(h.share_percent, 0) / 100, 2);
    begin
      if v_amt > 0 and h.from_partner_id <> r.partner_id then
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note) values
          (r.partner_id, 'get_credit', 'handover_share', -v_amt,
           'Handover share to the driver who passed you the trip (' || trim(to_char(h.share_percent, 'FM990.##')) ||
           '% of ' || coalesce(r.currency, 'RM') || ' ' || v_net || ' net)'),
          (h.from_partner_id, 'get_credit', 'handover_share', v_amt,
           'Your share of a trip you handed over (' || trim(to_char(h.share_percent, 'FM990.##')) || '% of ' ||
           coalesce(r.currency, 'RM') || ' ' || v_net || ' net)');
      end if;
      update public.trip_handovers set share_amount = greatest(v_amt, 0), settled_at = now() where id = h.id;
      perform public.enqueue_notification(h.from_partner_id, 'handover-paid-' || h.id, 'trip_handover', 'normal',
        'Handover share paid',
        coalesce(r.currency, 'RM') || ' ' || greatest(v_amt, 0) || ' was added to your GET credit for the trip you handed over.',
        jsonb_build_object('type', 'trip_handover_paid', 'handover_id', h.id, 'role', 'partner'));
    exception when others then
      raise warning 'ride % handover share not paid: %', new.id, sqlerrm;
    end;
  end loop;
  return null;
end;
$$;
revoke execute on function public.ride_requests_handover_share() from public, anon, authenticated;

-- Named to sort after trg_ride_requests_commission and _platform_fees.
drop trigger if exists trg_ride_requests_z_handover_share on public.ride_requests;
create trigger trg_ride_requests_z_handover_share
  after update of status on public.ride_requests
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function public.ride_requests_handover_share();

-- ---- The offer goes from the partners asked once the handover closes ---------------------------
create or replace function public.trip_handovers_close_candidates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status not in ('awaiting_rider', 'offered') then
    update public.trip_handover_candidates set closed = true where handover_id = new.id and not closed;
  end if;
  return new;
end;
$$;
revoke execute on function public.trip_handovers_close_candidates() from public, anon, authenticated;

drop trigger if exists trg_trip_handovers_close_candidates on public.trip_handovers;
create trigger trg_trip_handovers_close_candidates
  after update of status on public.trip_handovers
  for each row when (old.status is distinct from new.status)
  execute function public.trip_handovers_close_candidates();

-- ---- Handovers the caller is part of: the first driver, the new one, the passenger ------------
create or replace function public.trip_handovers_mine(p_ride uuid default null)
returns table (
  id uuid, ride_id uuid, status text, mode text, incoming boolean, from_name text, to_name text, note text,
  answer_by timestamptz, share_percent numeric, share_amount numeric, meet_lat double precision,
  meet_lng double precision, boarded_at timestamptz, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select h.id, h.ride_id, h.status, h.mode, h.to_partner_id = auth.uid(),
         public.trip_handover_name(h.from_partner_id),
         case when h.to_partner_id is not null then public.trip_handover_name(h.to_partner_id) end,
         h.note, h.answer_by, h.share_percent, h.share_amount, h.meet_lat, h.meet_lng, h.boarded_at, h.created_at
    from public.trip_handovers h
   where (h.rider_id = auth.uid() or h.from_partner_id = auth.uid() or h.to_partner_id = auth.uid())
     and (p_ride is null or h.ride_id = p_ride)
     and h.created_at > now() - interval '30 days'
   order by h.created_at desc
   limit 50;
$$;
revoke execute on function public.trip_handovers_mine(uuid) from public, anon;
grant execute on function public.trip_handovers_mine(uuid) to authenticated;

-- ---- No answer in time ------------------------------------------------------------------------
create or replace function public.trip_handovers_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  x record;
begin
  for x in
    update public.trip_handovers set status = 'expired'
     where status in ('awaiting_rider', 'offered') and answer_by <= now()
    returning id, ride_id, from_partner_id, rider_id
  loop
    perform public.enqueue_notification(x.from_partner_id, 'handover-lapsed-' || x.id, 'trip_handover', 'critical',
      'No answer in time', 'Nobody answered your handover in time. Please carry on with the trip, or ask again.',
      jsonb_build_object('type', 'trip_handover_expired', 'handover_id', x.id, 'request_id', x.ride_id,
                         'role', 'partner'), x.ride_id);
  end loop;
end;
$$;
revoke execute on function public.trip_handovers_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'trip-handovers';
    perform cron.schedule('trip-handovers', '* * * * *', $job$select public.trip_handovers_tick()$job$);
  end if;
end $$;

notify pgrst, 'reload schema';
