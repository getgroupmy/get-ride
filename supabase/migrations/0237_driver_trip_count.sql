-- ============================================================================
-- 0237: the driver's completed trips on the rider's offer card ("★ 4.9 · 312
-- trips").
--
--   1. partners.total_rides was never written, so it read 0 for everyone. It
--      is now the driver's completed trips, counted the way the Earnings page
--      counts them (ride_requests with status 'completed', credited to the
--      ride's partner_id, which is the driver's auth user id):
--        * backfilled once from the rides already completed;
--        * +1 when a ride turns completed, -1 if a completed ride is later
--          moved off completed (only an administrator or the server can), and
--          moved from one driver to the other if a completed ride's driver
--          changes. Only the transition counts, so writing a completed ride
--          again, or repeating its status, never counts twice.
--      A refund changes payment_status, not the ride's status, so a refunded
--      trip stays completed, on Earnings and in the count. The column stays protected (partners_guard_protected_columns):
--      the counting trigger is a definer function, which the guard lets
--      through.
--   2. ride_requests.partner_trips: stamped from the partner's record with
--      the rest of the driver's card wherever partner_rating is (a bid or a
--      take through ride_requests_guard_sides, a scheduled ride released with
--      its driver, a trip handed over), cleared with it when the bid is
--      withdrawn or a scheduled ride goes back to the pool, and frozen in
--      between, so a rider (or the driver) can't write their own.
--
-- Grants and row rules on ride_requests are unchanged. The apps read the new
-- column when it is there; an app on a database without it shows the rating
-- alone.
-- ============================================================================

-- ---- 2a. The column --------------------------------------------------------------------
alter table public.ride_requests add column if not exists partner_trips integer;

comment on column public.ride_requests.partner_trips is
  'The driver''s completed trips (partners.total_rides) when they bid on or took this ride. Server-stamped.';

-- ---- 1. Counting completed trips -------------------------------------------------------
-- A driver can have more than one partner record (re-applications); all of
-- them carry the same count, and the card reads the newest.
create or replace function public.ride_requests_count_trips()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_was uuid;  -- the driver this ride counted for before
  v_now uuid;  -- the driver it counts for now
begin
  if tg_op <> 'INSERT' and old.status = 'completed' then
    v_was := old.partner_id;
  end if;
  if tg_op <> 'DELETE' and new.status = 'completed' then
    v_now := new.partner_id;
  end if;
  if v_was is not distinct from v_now then
    return null;
  end if;

  if v_was is not null then
    update public.partners
       set total_rides = greatest(coalesce(total_rides, 0) - 1, 0)
     where auth_user_id = v_was;
  end if;
  if v_now is not null then
    update public.partners
       set total_rides = coalesce(total_rides, 0) + 1
     where auth_user_id = v_now;
  end if;
  return null;
end;
$$;

revoke execute on function public.ride_requests_count_trips() from public, anon, authenticated;

-- Created before the backfill: the trigger's lock keeps rides from completing
-- between the count and the trigger taking over, so none is missed or
-- counted twice.
drop trigger if exists trg_ride_requests_count_trips on public.ride_requests;
create trigger trg_ride_requests_count_trips
  after insert or delete or update of status, partner_id on public.ride_requests
  for each row execute function public.ride_requests_count_trips();

-- The backfill, kept as a function so it can be run again to repair the
-- counts (server only).
create or replace function public.partner_trips_recount()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  update public.partners p
     set total_rides = coalesce(c.n, 0)
    from public.partners p2
    left join (
      select r.partner_id, count(*)::int as n
        from public.ride_requests r
       where r.status = 'completed' and r.partner_id is not null
       group by r.partner_id
    ) c on c.partner_id = p2.auth_user_id
   where p.id = p2.id
     and p.total_rides is distinct from coalesce(c.n, 0);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.partner_trips_recount() from public, anon, authenticated;

select public.partner_trips_recount();

-- ---- 2b. The driver's card carries the count ---------------------------------------------
-- As in 0182, plus trips. The returned row changes, so drop and create.
drop function if exists public.ride_partner_card(uuid);
create function public.ride_partner_card(p_partner uuid)
returns table (name text, phone text, photo text, rating numeric, plate text, vehicle text, trips integer)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select p.name, p.phone, p.avatar_url, p.rating, p.plate, p.vehicle, p.total_rides
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
         coalesce(car.label, nullif(btrim(me.vehicle), '')),
         me.total_rides
    from me
    left join prof on true
    left join car on true
   where p_partner = auth.uid() or public.caller_is_admin();
$$;

revoke execute on function public.ride_partner_card(uuid) from public, anon;
grant execute on function public.ride_partner_card(uuid) to authenticated;

-- ---- 2c. Stamped and cleared with partner_rating ------------------------------------------
-- Each edit is made to the function's current definition, as 0223 does
-- (0223 rewrote trip_handover_accept in place, so a copy of 0199's text would
-- undo it). CREATE OR REPLACE from pg_get_functiondef keeps owner, grants
-- and settings.
--   ride_requests_guard_sides (0182): a bid or a take is stamped from the
--     card, cleared with the bid, frozen in between, whoever writes the row.
--   scheduled_ride_release (0189): a booking released with its driver.
--   ride_requests_scheduled_reopen (0189): a driver's cancel sends a booking
--     back to the pool, card cleared.
--   trip_handover_accept (0199, 0223): the new driver's card.
do $stamp$
declare
  e      record;
  v_def  text;
  v_done text[] := '{}';
  nl     text := chr(10);
begin
  for e in
    select * from (values
      (1, 'ride_requests_guard_sides',
          $a$    new.partner_rating := null;$a$ || nl,
          $a$    new.partner_trips := null;$a$ || nl),
      (2, 'ride_requests_guard_sides',
          $a$    new.partner_rating := c.rating;$a$ || nl,
          $a$    new.partner_trips := c.trips;$a$ || nl),
      (3, 'ride_requests_guard_sides',
          $a$    new.partner_rating := old.partner_rating;$a$ || nl,
          $a$    new.partner_trips := old.partner_trips;$a$ || nl),
      (4, 'scheduled_ride_release',
          $a$'partner_rating', card.rating, $a$,
          $a$'partner_trips', card.trips, $a$),
      (5, 'ride_requests_scheduled_reopen',
          $a$  new.partner_rating := null;$a$ || nl,
          $a$  new.partner_trips := null;$a$ || nl),
      (6, 'trip_handover_accept',
          $a$partner_rating = card.rating, $a$,
          $a$partner_trips = card.trips, $a$)
    ) as t(n, fn, anchor, added)
    order by n
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = e.fn;
    if v_def is null then
      raise exception '0237: public.% is missing', e.fn;
    end if;
    -- Run again: a function already edited is left alone.
    continue when position('partner_trips' in v_def) > 0 and not e.fn = any (v_done);
    if (length(v_def) - length(replace(v_def, e.anchor, ''))) / length(e.anchor) <> 1 then
      raise exception '0237: public.% should have "%" once; update this migration', e.fn, e.anchor;
    end if;
    execute replace(v_def, e.anchor, e.anchor || e.added);
    v_done := v_done || e.fn;
  end loop;
end;
$stamp$;

-- ---- 2d. Rides already under way carry their driver's count -------------------------------
-- Only the new column is written; as the migration's owner the guard lets it
-- through.
update public.ride_requests r
   set partner_trips = (
         select pa.total_rides
           from public.partners pa
          where pa.auth_user_id = r.partner_id
            and (pa.status = 'approved' or pa.status::text like 'permit-%')
          order by pa.created_at desc
          limit 1)
 where r.partner_id is not null
   and r.status in ('open', 'accepted', 'arrived', 'on_trip')
   and r.partner_trips is null;
