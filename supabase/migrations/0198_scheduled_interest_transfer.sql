-- ============================================================================
-- 0198: scheduled rides: drivers' interest, handing a booking over, and the
-- passenger choosing a driver.
--
-- Upcoming bookings. Every approved driver sees every booking no driver has
-- taken yet, whatever its date and however many there are
-- (scheduled_rides_upcoming), with or without advance booking.
--
-- Interest. A driver marks a booking "interested". When the booking comes
-- within the admin's interestNoticeMinutes of pickup (Admin -> App Settings
-- -> Scheduled rides, default 60; 0 turns the notice off) every interested
-- driver is told it is ready to accept, and the first to accept gets it
-- (scheduled_ride_accept now allows that without advance booking). The
-- others are told it was taken. Nobody accepts: it is released as usual.
--
-- Handing over. The driver who holds a booking can offer it to another
-- driver by that driver's code: the My Ride code, or the GET.me QR (scanned
-- or pasted). The booking stays theirs until the other driver accepts; on
-- decline, or no answer by release, it stays with them. They can still let
-- it go to the pool at any time, which withdraws the offer. The passenger is
-- told when the driver changes.
--
-- The passenger choosing. On a booking no driver has taken, the passenger
-- can ask a driver by the same codes. The driver accepts or declines; until
-- then the booking stays open to everyone, and if another driver takes it
-- first the request lapses.
--
-- Notifications (all into the driver's or passenger's notification list,
-- pushed as usual): ready to accept, taken by someone else, cancelled by the
-- passenger (to interested drivers and to a driver asked), a handover or a
-- passenger's request to accept, its answer, and its lapsing.
-- ============================================================================

-- ---- Settings: the interest notice ------------------------------------------------------
create or replace function public.scheduled_rides_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'enabled', coalesce((v->>'enabled')::boolean, false),
    'minLeadMinutes', public.scheduled_cfg_num(v, 'minLeadMinutes', 30, 5, 1440)::int,
    'maxDaysAhead', public.scheduled_cfg_num(v, 'maxDaysAhead', 7, 1, 30)::int,
    'feeFixed', round(public.scheduled_cfg_num(v, 'feeFixed', 0, 0, 1000), 2),
    'feePercent', round(public.scheduled_cfg_num(v, 'feePercent', 0, 0, 100), 2),
    'feeTo', case when v->>'feeTo' = 'driver' then 'driver' else 'platform' end,
    'freeCancelMinutes', public.scheduled_cfg_num(v, 'freeCancelMinutes', 60, 0, 1440)::int,
    'lateCancelFee', round(public.scheduled_cfg_num(v, 'lateCancelFee', 0, 0, 1000), 2),
    'mode', case when v->>'mode' = 'advance' then 'advance' else 'release' end,
    'releaseMinutes', public.scheduled_cfg_num(v, 'releaseMinutes', 20, 5, 180)::int,
    'reminderMinutes', public.scheduled_cfg_num(v, 'reminderMinutes', 60, 0, 1440)::int,
    'interestNoticeMinutes', public.scheduled_cfg_num(v, 'interestNoticeMinutes', 60, 0, 1440)::int
  )
  from (select (select value from public.app_settings where key = 'scheduled_rides') as v) s;
$$;
revoke execute on function public.scheduled_rides_config() from public;
grant execute on function public.scheduled_rides_config() to anon, authenticated;

-- 'DD Mon, HH24:MI' in Malaysian time, as the other scheduled messages.
create or replace function public.scheduled_when(p_at timestamptz)
returns text
language sql
immutable
set search_path = public
as $$ select to_char(p_at at time zone 'Asia/Kuala_Lumpur', 'DD Mon, HH24:MI') $$;
revoke execute on function public.scheduled_when(timestamptz) from public, anon, authenticated;

-- ---- Interest ---------------------------------------------------------------------------
create table if not exists public.scheduled_ride_interests (
  scheduled_ride_id uuid not null references public.scheduled_rides(id) on delete cascade,
  partner_id        uuid not null references auth.users(id) on delete cascade,
  created_at        timestamptz not null default now(),
  notified_at       timestamptz,
  primary key (scheduled_ride_id, partner_id)
);
create index if not exists scheduled_ride_interests_partner_idx on public.scheduled_ride_interests (partner_id);

alter table public.scheduled_ride_interests enable row level security;
revoke all on public.scheduled_ride_interests from anon, authenticated;
grant select on public.scheduled_ride_interests to authenticated;
drop policy if exists "scheduled_ride_interests own" on public.scheduled_ride_interests;
create policy "scheduled_ride_interests own" on public.scheduled_ride_interests
  for select to authenticated using (partner_id = (select auth.uid()));

-- ---- Handovers and the passenger's requests ---------------------------------------------
create table if not exists public.scheduled_ride_offers (
  id                uuid primary key default gen_random_uuid(),
  scheduled_ride_id uuid not null references public.scheduled_rides(id) on delete cascade,
  kind              text not null check (kind in ('transfer', 'assign')),
  rider_id          uuid not null references auth.users(id) on delete cascade,
  from_id           uuid not null references auth.users(id) on delete cascade,
  to_partner_id     uuid not null references auth.users(id) on delete cascade,
  status            text not null default 'pending'
                    check (status in ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  expires_at        timestamptz not null,
  created_at        timestamptz not null default now(),
  responded_at      timestamptz
);
create unique index if not exists scheduled_ride_offers_one_pending
  on public.scheduled_ride_offers (scheduled_ride_id) where status = 'pending';
create index if not exists scheduled_ride_offers_to_idx on public.scheduled_ride_offers (to_partner_id, status);
create index if not exists scheduled_ride_offers_due_idx on public.scheduled_ride_offers (expires_at) where status = 'pending';

alter table public.scheduled_ride_offers enable row level security;
revoke all on public.scheduled_ride_offers from anon, authenticated;
grant select on public.scheduled_ride_offers to authenticated;
drop policy if exists "scheduled_ride_offers parties" on public.scheduled_ride_offers;
create policy "scheduled_ride_offers parties" on public.scheduled_ride_offers
  for select to authenticated
  using (rider_id = (select auth.uid()) or from_id = (select auth.uid()) or to_partner_id = (select auth.uid()));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'scheduled_ride_offers') then
    alter publication supabase_realtime add table public.scheduled_ride_offers;
  end if;
end $$;

-- ---- A driver, by code -------------------------------------------------------------------
-- The My Ride code (8 characters) or a GET.me QR (token or link). Codes that
-- match nobody count against the same limits as adding a favourite driver.
create or replace function public.scheduled_partner_by_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_ip    text := public.request_client_ip();
  v_code  text;
  v_token text := public.personal_qr_token_of(p_code);
  v_wait  int;
  v_owner uuid;
  p       public.partners;
  q       public.personal_qr_codes;
begin
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
    raise exception 'SCHEDULED_CODE_WAIT' using hint = 'Too many codes that didn''t match. Try again later.';
  end if;

  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_code := regexp_replace(v_code, '^GETRIDE://MYRIDE/', '');
  v_code := regexp_replace(v_code, '[/-]', '', 'g');
  if v_code ~ '^[2-9A-HJ-NP-Z]{8}$' then
    select * into p from public.partners where my_ride_code = v_code limit 1;
    v_owner := p.auth_user_id;
  elsif v_token is not null then
    select * into q from public.personal_qr_codes where token = v_token;
    if q.id is not null and q.kind = 'me' and public.personal_qr_status(q.expires_at, q.revoked_at) = 'active' then
      v_owner := q.owner_id;
    end if;
  else
    raise exception 'SCHEDULED_CODE_INVALID' using hint = 'Enter the driver''s My Ride code or scan their GET.me QR.';
  end if;

  if v_owner is null then
    perform public.auth_rate_take('my_ride_code_miss', v_uid::text, 10, interval '1 hour');
    perform public.auth_rate_take('my_ride_code_miss_ip', v_ip, 30, interval '1 hour');
    raise exception 'SCHEDULED_CODE_UNKNOWN' using hint = 'No driver has this code. Check it, or ask for their GET.me QR.';
  end if;
  p := public.my_ride_partner_of(v_owner);
  if p.id is null or not public.partner_status_bookable(p.status::text) then
    raise exception 'SCHEDULED_CODE_UNAVAILABLE' using hint = 'This driver can''t take rides at the moment.';
  end if;
  return v_owner;
end;
$$;
revoke execute on function public.scheduled_partner_by_code(text) from public, anon, authenticated;

-- A driver's own ride within an hour of this one (the rule pre-accepting has).
create or replace function public.scheduled_partner_clash(p_partner uuid, p_at timestamptz, p_except uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.scheduled_rides o
                  where o.partner_id = p_partner and o.id <> p_except and o.status in ('assigned', 'released')
                    and abs(extract(epoch from o.pickup_at - p_at)) < 3600);
$$;
revoke execute on function public.scheduled_partner_clash(uuid, timestamptz, uuid) from public, anon, authenticated;

-- ---- Upcoming bookings, for drivers -------------------------------------------------------
-- Every booking still without a driver, soonest first, without a limit.
-- can_accept: advance booking, or interested once the notice has gone out.
create or replace function public.scheduled_rides_upcoming()
returns table (
  id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
  pickup_lat double precision, pickup_lng double precision, drop_lat double precision, drop_lng double precision,
  distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
  interested boolean, can_accept boolean, accept_from timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with c as (select public.scheduled_rides_config() as v)
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when c.v->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         i.partner_id is not null,
         c.v->>'mode' = 'advance'
           or (i.partner_id is not null and (c.v->>'interestNoticeMinutes')::int > 0
               and now() >= s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int)),
         case when c.v->>'mode' = 'advance' then null
              when (c.v->>'interestNoticeMinutes')::int > 0
              then s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int) end
    from public.scheduled_rides s
    cross join c
    left join public.scheduled_ride_interests i on i.scheduled_ride_id = s.id and i.partner_id = auth.uid()
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and (c.v->>'enabled')::boolean
     and public.caller_is_approved_partner()
     and s.rider_id <> auth.uid()
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_rides_upcoming() from public, anon;
grant execute on function public.scheduled_rides_upcoming() to authenticated;

create or replace function public.scheduled_ride_set_interest(p_id uuid, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.scheduled_rides;
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not coalesce(p_on, false) then
    delete from public.scheduled_ride_interests where scheduled_ride_id = p_id and partner_id = v_uid;
    return false;
  end if;
  select * into r from public.scheduled_rides where id = p_id;
  if not found or r.status <> 'scheduled' or r.partner_id is not null or r.pickup_at <= now() then
    raise exception 'SCHEDULED_TAKEN' using hint = 'Another driver has taken this ride, or it is no longer open.';
  end if;
  if r.rider_id = v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  insert into public.scheduled_ride_interests (scheduled_ride_id, partner_id) values (p_id, v_uid)
  on conflict do nothing;
  return true;
end;
$$;
revoke execute on function public.scheduled_ride_set_interest(uuid, boolean) from public, anon;
grant execute on function public.scheduled_ride_set_interest(uuid, boolean) to authenticated;

-- As 0189, and without advance booking an interested driver may accept once
-- told it is ready.
create or replace function public.scheduled_ride_accept(p_id uuid)
returns public.scheduled_rides
language plpgsql
security definer
set search_path = public
as $$
declare
  c     jsonb := public.scheduled_rides_config();
  v_uid uuid := auth.uid();
  r     public.scheduled_rides;
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.status <> 'scheduled' or r.partner_id is not null or r.pickup_at <= now() then
    raise exception 'SCHEDULED_TAKEN' using hint = 'Another driver has taken this ride, or it is no longer open.';
  end if;
  if c->>'mode' <> 'advance' and not (
       (c->>'interestNoticeMinutes')::int > 0
       and now() >= r.pickup_at - make_interval(mins => (c->>'interestNoticeMinutes')::int)
       and exists (select 1 from public.scheduled_ride_interests
                    where scheduled_ride_id = r.id and partner_id = v_uid)) then
    raise exception 'SCHEDULED_NOT_ADVANCE'
      using hint = 'Mark it as interested: you''ll be told when you can accept it.';
  end if;
  if r.rider_id = v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if public.scheduled_partner_clash(v_uid, r.pickup_at, r.id) then
    raise exception 'SCHEDULED_CLASH' using hint = 'You already have a ride within an hour of this one.';
  end if;

  update public.scheduled_rides
     set status = 'assigned', partner_id = v_uid, partner_accepted_at = now()
   where id = r.id
  returning * into r;

  perform public.enqueue_notification(r.rider_id, 'sched-assigned-' || r.id || '-' || v_uid, 'scheduled_ride', 'normal',
    'Driver confirmed',
    'A driver has accepted your ride for ' || public.scheduled_when(r.pickup_at) || '.',
    jsonb_build_object('type', 'scheduled_assigned', 'scheduled_ride_id', r.id));
  return r;
end;
$$;
revoke execute on function public.scheduled_ride_accept(uuid) from public, anon;
grant execute on function public.scheduled_ride_accept(uuid) to authenticated;

-- ---- Offers -------------------------------------------------------------------------------
-- An offer stands until release at the latest.
create or replace function public.scheduled_offer_deadline(p_pickup timestamptz)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$ select p_pickup - make_interval(mins => (public.scheduled_rides_config()->>'releaseMinutes')::int) $$;
revoke execute on function public.scheduled_offer_deadline(timestamptz) from public, anon, authenticated;

-- The driver who holds a booking offers it to another driver.
create or replace function public.scheduled_ride_transfer(p_id uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_to  uuid;
  v_id  uuid;
  r     public.scheduled_rides;
  me    public.partners;
begin
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.partner_id is distinct from v_uid or r.status <> 'assigned' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if public.scheduled_offer_deadline(r.pickup_at) <= now() then
    raise exception 'SCHEDULED_TOO_LATE' using hint = 'It is too close to pickup to hand this ride over.';
  end if;
  v_to := public.scheduled_partner_by_code(p_code);
  if v_to = v_uid then
    raise exception 'SCHEDULED_CODE_SELF' using hint = 'That is your own code.';
  end if;
  if v_to = r.rider_id then
    raise exception 'SCHEDULED_CODE_UNAVAILABLE' using hint = 'This driver can''t take this ride.';
  end if;

  update public.scheduled_ride_offers set status = 'cancelled', responded_at = now()
   where scheduled_ride_id = r.id and status = 'pending';
  insert into public.scheduled_ride_offers (scheduled_ride_id, kind, rider_id, from_id, to_partner_id, expires_at)
  values (r.id, 'transfer', r.rider_id, v_uid, v_to, public.scheduled_offer_deadline(r.pickup_at))
  returning id into v_id;

  me := public.my_ride_partner_of(v_uid);
  perform public.enqueue_notification(v_to, 'sched-offer-' || v_id, 'scheduled_ride', 'normal',
    'A scheduled ride for you',
    coalesce(nullif(trim(me.name), ''), 'A driver') || ' wants to hand over a ride on ' || public.scheduled_when(r.pickup_at) ||
    coalesce(' from ' || nullif(trim(r.pickup_address), ''), '') || '. Accept or decline it.',
    jsonb_build_object('type', 'scheduled_offer', 'scheduled_ride_id', r.id, 'offer_id', v_id, 'role', 'partner'));
  return v_id;
end;
$$;
revoke execute on function public.scheduled_ride_transfer(uuid, text) from public, anon;
grant execute on function public.scheduled_ride_transfer(uuid, text) to authenticated;

-- The passenger asks a driver to take a booking no driver has yet.
create or replace function public.scheduled_ride_request_driver(p_id uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_to  uuid;
  v_id  uuid;
  r     public.scheduled_rides;
begin
  select * into r from public.scheduled_rides where id = p_id for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'scheduled' or r.partner_id is not null then
    raise exception 'SCHEDULED_TAKEN' using hint = 'A driver has already accepted this ride.';
  end if;
  if public.scheduled_offer_deadline(r.pickup_at) <= now() then
    raise exception 'SCHEDULED_TOO_LATE' using hint = 'It is too close to pickup to choose a driver.';
  end if;
  v_to := public.scheduled_partner_by_code(p_code);
  if v_to = v_uid then
    raise exception 'SCHEDULED_CODE_SELF' using hint = 'That is your own code.';
  end if;

  update public.scheduled_ride_offers set status = 'cancelled', responded_at = now()
   where scheduled_ride_id = r.id and status = 'pending';
  insert into public.scheduled_ride_offers (scheduled_ride_id, kind, rider_id, from_id, to_partner_id, expires_at)
  values (r.id, 'assign', v_uid, v_uid, v_to, public.scheduled_offer_deadline(r.pickup_at))
  returning id into v_id;

  perform public.enqueue_notification(v_to, 'sched-offer-' || v_id, 'scheduled_ride', 'normal',
    'A passenger chose you',
    'A passenger asks you to take their ride on ' || public.scheduled_when(r.pickup_at) ||
    coalesce(' from ' || nullif(trim(r.pickup_address), ''), '') || '. Accept or decline it.',
    jsonb_build_object('type', 'scheduled_offer', 'scheduled_ride_id', r.id, 'offer_id', v_id, 'role', 'partner'));
  return v_id;
end;
$$;
revoke execute on function public.scheduled_ride_request_driver(uuid, text) from public, anon;
grant execute on function public.scheduled_ride_request_driver(uuid, text) to authenticated;

-- The driver asked accepts or declines.
create or replace function public.scheduled_ride_offer_respond(p_offer uuid, p_accept boolean)
returns public.scheduled_ride_offers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  o     public.scheduled_ride_offers;
  r     public.scheduled_rides;
  me    public.partners;
  v_who text;
begin
  select * into o from public.scheduled_ride_offers where id = p_offer for update;
  if not found or o.to_partner_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if o.status <> 'pending' or o.expires_at <= now() then
    raise exception 'SCHEDULED_OFFER_GONE' using hint = 'This request is no longer open.';
  end if;
  select * into r from public.scheduled_rides where id = o.scheduled_ride_id for update;
  me := public.my_ride_partner_of(v_uid);
  v_who := coalesce(nullif(trim(me.name), ''), 'The driver');

  if not coalesce(p_accept, false) then
    update public.scheduled_ride_offers set status = 'declined', responded_at = now() where id = o.id returning * into o;
    perform public.enqueue_notification(o.from_id, 'sched-offer-declined-' || o.id, 'scheduled_ride', 'normal',
      case when o.kind = 'transfer' then 'Handover declined' else 'Driver declined' end,
      v_who || ' declined the ride on ' || public.scheduled_when(r.pickup_at) ||
      case when o.kind = 'transfer' then '. It is still yours.' else '. We''ll find you a driver as usual.' end,
      jsonb_build_object('type', 'scheduled_offer_declined', 'scheduled_ride_id', r.id, 'offer_id', o.id)
        || case when o.kind = 'transfer' then jsonb_build_object('role', 'partner') else '{}'::jsonb end);
    return o;
  end if;

  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if o.kind = 'transfer' and (r.status <> 'assigned' or r.partner_id is distinct from o.from_id) then
    raise exception 'SCHEDULED_OFFER_GONE' using hint = 'This request is no longer open.';
  end if;
  if o.kind = 'assign' and (r.status <> 'scheduled' or r.partner_id is not null) then
    raise exception 'SCHEDULED_OFFER_GONE' using hint = 'Another driver has already taken this ride.';
  end if;
  if public.scheduled_partner_clash(v_uid, r.pickup_at, r.id) then
    raise exception 'SCHEDULED_CLASH' using hint = 'You already have a ride within an hour of this one.';
  end if;

  update public.scheduled_ride_offers set status = 'accepted', responded_at = now() where id = o.id returning * into o;
  update public.scheduled_rides
     set status = 'assigned', partner_id = v_uid, partner_accepted_at = now()
   where id = r.id
  returning * into r;

  if o.kind = 'transfer' then
    perform public.enqueue_notification(o.from_id, 'sched-offer-accepted-' || o.id, 'scheduled_ride', 'normal',
      'Ride handed over', v_who || ' accepted the ride on ' || public.scheduled_when(r.pickup_at) || '.',
      jsonb_build_object('type', 'scheduled_offer_accepted', 'scheduled_ride_id', r.id, 'offer_id', o.id, 'role', 'partner'));
    perform public.enqueue_notification(r.rider_id, 'sched-driver-changed-' || o.id, 'scheduled_ride', 'normal',
      'Your driver has changed',
      v_who || ' will now drive you on ' || public.scheduled_when(r.pickup_at) || '.',
      jsonb_build_object('type', 'scheduled_assigned', 'scheduled_ride_id', r.id));
  else
    perform public.enqueue_notification(r.rider_id, 'sched-assigned-' || r.id || '-' || v_uid, 'scheduled_ride', 'normal',
      'Driver confirmed', v_who || ' accepted your ride for ' || public.scheduled_when(r.pickup_at) || '.',
      jsonb_build_object('type', 'scheduled_assigned', 'scheduled_ride_id', r.id));
  end if;
  return o;
end;
$$;
revoke execute on function public.scheduled_ride_offer_respond(uuid, boolean) from public, anon;
grant execute on function public.scheduled_ride_offer_respond(uuid, boolean) to authenticated;

-- Whoever made the offer withdraws it.
create or replace function public.scheduled_ride_offer_cancel(p_offer uuid)
returns public.scheduled_ride_offers
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.scheduled_ride_offers;
begin
  select * into o from public.scheduled_ride_offers where id = p_offer for update;
  if not found or o.from_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if o.status = 'pending' then
    update public.scheduled_ride_offers set status = 'cancelled', responded_at = now() where id = o.id returning * into o;
  end if;
  return o;
end;
$$;
revoke execute on function public.scheduled_ride_offer_cancel(uuid) from public, anon;
grant execute on function public.scheduled_ride_offer_cancel(uuid) to authenticated;

-- The open offers the caller made or was sent, with what the other side
-- needs to decide (not who the passenger is).
create or replace function public.scheduled_ride_offers_open()
returns table (
  id uuid, scheduled_ride_id uuid, kind text, incoming boolean, other_name text, expires_at timestamptz,
  pickup_at timestamptz, service text, pickup_address text, drop_address text, distance_km numeric,
  fare numeric, scheduling_fee numeric, currency text)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.scheduled_ride_id, o.kind, o.to_partner_id = auth.uid(),
         case when o.to_partner_id = auth.uid()
              then case when o.kind = 'transfer' then (public.my_ride_partner_of(o.from_id)).name end
              else (public.my_ride_partner_of(o.to_partner_id)).name end,
         o.expires_at, s.pickup_at, s.service, s.pickup_address, s.drop_address, s.distance_km, s.fare,
         -- Drivers see the fee only when it goes to them, as on the open list.
         case when o.kind = 'transfer' or o.to_partner_id = auth.uid()
              then case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end
              else s.scheduling_fee end,
         s.currency
    from public.scheduled_ride_offers o
    join public.scheduled_rides s on s.id = o.scheduled_ride_id
   where o.status = 'pending' and o.expires_at > now()
     and (o.to_partner_id = auth.uid() or o.from_id = auth.uid())
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_ride_offers_open() from public, anon;
grant execute on function public.scheduled_ride_offers_open() to authenticated;

-- ---- What a booking's change means for the others ------------------------------------------
create or replace function public.scheduled_rides_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  x record;
begin
  -- Taken: interested drivers who were told it was ready hear it is gone; a
  -- passenger's request to another driver lapses.
  if old.partner_id is null and new.partner_id is not null then
    for x in
      select partner_id from public.scheduled_ride_interests
       where scheduled_ride_id = new.id and partner_id <> new.partner_id and notified_at is not null
    loop
      perform public.enqueue_notification(x.partner_id, 'sched-taken-' || new.id || '-' || x.partner_id,
        'scheduled_ride', 'normal', 'Ride taken',
        'Another driver accepted the ride on ' || public.scheduled_when(new.pickup_at) || '.',
        jsonb_build_object('type', 'scheduled_taken', 'scheduled_ride_id', new.id, 'role', 'partner'));
    end loop;
    for x in
      update public.scheduled_ride_offers set status = 'cancelled', responded_at = now()
       where scheduled_ride_id = new.id and status = 'pending' and kind = 'assign' and to_partner_id <> new.partner_id
      returning id, to_partner_id
    loop
      perform public.enqueue_notification(x.to_partner_id, 'sched-offer-gone-' || x.id, 'scheduled_ride', 'normal',
        'Request withdrawn', 'Another driver took the ride on ' || public.scheduled_when(new.pickup_at) || '.',
        jsonb_build_object('type', 'scheduled_taken', 'scheduled_ride_id', new.id, 'role', 'partner'));
    end loop;
  end if;

  -- Let go of (back to the pool): the driver's handover is withdrawn.
  if old.partner_id is not null and new.partner_id is null then
    update public.scheduled_ride_offers set status = 'cancelled', responded_at = now()
     where scheduled_ride_id = new.id and status = 'pending' and kind = 'transfer';
  end if;

  -- Cancelled by the passenger (or an admin): interested drivers and a driver
  -- asked hear it; the driver who held it already did (0189).
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    for x in
      select partner_id from public.scheduled_ride_interests
       where scheduled_ride_id = new.id and partner_id is distinct from old.partner_id
      union
      select to_partner_id from public.scheduled_ride_offers
       where scheduled_ride_id = new.id and status = 'pending' and to_partner_id is distinct from old.partner_id
    loop
      perform public.enqueue_notification(x.partner_id, 'sched-cancel-' || new.id || '-' || x.partner_id,
        'scheduled_ride', 'normal', 'Scheduled ride cancelled',
        'The passenger cancelled the ride booked for ' || public.scheduled_when(new.pickup_at) || '.',
        jsonb_build_object('type', 'scheduled_cancelled', 'scheduled_ride_id', new.id, 'role', 'partner'));
    end loop;
  end if;

  -- No longer waiting for a driver: nothing left to accept.
  if new.status in ('released', 'cancelled', 'expired', 'completed') and old.status <> new.status then
    update public.scheduled_ride_offers set status = 'cancelled', responded_at = now()
     where scheduled_ride_id = new.id and status = 'pending';
  end if;
  return null;
end;
$$;
revoke execute on function public.scheduled_rides_after_change() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_after_change on public.scheduled_rides;
create trigger trg_scheduled_rides_after_change
  after update of status, partner_id on public.scheduled_rides
  for each row execute function public.scheduled_rides_after_change();

-- ---- The minute's work: ready-to-accept notices and lapsed offers --------------------------
create or replace function public.scheduled_rides_interest_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c        jsonb := public.scheduled_rides_config();
  v_notice int := (c->>'interestNoticeMinutes')::int;
  v_release int := (c->>'releaseMinutes')::int;
  x        record;
begin
  if v_notice > 0 and (c->>'enabled')::boolean then
    for x in
      select i.scheduled_ride_id, i.partner_id, s.pickup_at, s.pickup_address
        from public.scheduled_ride_interests i
        join public.scheduled_rides s on s.id = i.scheduled_ride_id
       where i.notified_at is null and s.status = 'scheduled' and s.partner_id is null
         and s.pickup_at - make_interval(mins => v_notice) <= now()
         and s.pickup_at - make_interval(mins => v_release) > now()
       for update of i skip locked
    loop
      perform public.enqueue_notification(x.partner_id, 'sched-ready-' || x.scheduled_ride_id || '-' || x.partner_id,
        'scheduled_ride', 'critical', 'Ready to accept',
        'The ride on ' || public.scheduled_when(x.pickup_at) || coalesce(' from ' || nullif(trim(x.pickup_address), ''), '') ||
        ' can be accepted now. The first driver to accept gets it.',
        jsonb_build_object('type', 'scheduled_ready', 'scheduled_ride_id', x.scheduled_ride_id, 'role', 'partner'));
      update public.scheduled_ride_interests set notified_at = now()
       where scheduled_ride_id = x.scheduled_ride_id and partner_id = x.partner_id;
    end loop;
  end if;

  for x in
    update public.scheduled_ride_offers o set status = 'expired', responded_at = now()
     where o.status = 'pending' and o.expires_at <= now()
    returning o.id, o.kind, o.from_id, o.scheduled_ride_id
  loop
    perform public.enqueue_notification(x.from_id, 'sched-offer-expired-' || x.id, 'scheduled_ride', 'normal',
      'No answer',
      case when x.kind = 'transfer' then 'The driver didn''t accept your handover in time. The ride is still yours.'
           else 'The driver you chose didn''t answer in time. We''ll find you a driver as usual.' end,
      jsonb_build_object('type', 'scheduled_offer_expired', 'scheduled_ride_id', x.scheduled_ride_id, 'offer_id', x.id)
        || case when x.kind = 'transfer' then jsonb_build_object('role', 'partner') else '{}'::jsonb end);
  end loop;
end;
$$;
revoke execute on function public.scheduled_rides_interest_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'scheduled-rides-interest';
    perform cron.schedule('scheduled-rides-interest', '* * * * *', $job$select public.scheduled_rides_interest_tick()$job$);
  end if;
end $$;

notify pgrst, 'reload schema';
