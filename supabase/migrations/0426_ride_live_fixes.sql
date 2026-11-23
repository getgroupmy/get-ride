-- ============================================================================
-- 0426 — The passenger's map follows the car live: a fix a second.
--
-- The driver's phone has shared its position by updating the ride's own row
-- (partner_live_lat / _lng / _heading) at most once every five seconds. A row
-- of ride_requests is the wrong place to do it any faster: every update runs
-- the row's twenty-odd triggers and sends the whole booking to everyone who
-- follows it. So the passenger's car has been a position five seconds old,
-- played back between one update and the next (core/car_playback.dart in the
-- app): smooth, but five to six seconds behind the real car.
--
-- This is a small channel beside the ride row, for the position alone:
--
--   * ride_live_fixes: one row a DRIVER, holding their latest fix for the ride
--     in hand — where, the speed and course the GPS measured, how far out it
--     may be, and when the phone took it. A driver's row is written over about
--     once a second while they drive, and belongs to their next ride once that
--     starts. So the table is as long as the list of drivers, not of rides,
--     and nothing is ever deleted from it as rides end (a delete is sent to
--     every listener whatever the row was, a ride's end among them).
--   * ride_live_fix(...): how the driver's phone writes it. Only for a ride
--     that is theirs and is under way (accepted, arrived, on trip); anything
--     else is answered false and nothing is kept.
--   * Reading is for one person: the passenger of that ride, while it is under
--     way and still that driver's. Not other passengers, not other drivers,
--     not the driver's later passengers looking back. The moment the ride ends
--     or passes to another driver, the row cannot be read.
--   * It is in the realtime publication, so the passenger's phone hears each
--     fix as it is written.
--
-- Nothing else changes. The driver's phone still writes the ride row every
-- five seconds, which everything else reads (the ETA, the trip card, the
-- admin's map, an app that does not know this table); a passenger's phone
-- that hears nothing here goes on following the ride row as before.
--
-- Checked in supabase/tests/ride_live_fixes_0426.sql.
-- ============================================================================

-- ---- The table ----------------------------------------------------------------------------------
create table if not exists public.ride_live_fixes (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  -- The ride the fix is for. A ride that is removed leaves the row behind
  -- with none, which nobody can read.
  ride_id   uuid references public.ride_requests(id) on delete set null,
  lat       double precision not null check (lat between -90 and 90),
  lng       double precision not null check (lng between -180 and 180),
  -- The way the car is travelling (degrees clockwise from north) and how fast
  -- (m/s), as the GPS measured them; null when it measured neither.
  heading   double precision check (heading is null or (heading >= 0 and heading < 360)),
  speed     double precision check (speed is null or (speed >= 0 and speed <= 150)),
  -- How far out the fix may be, metres.
  accuracy  double precision check (accuracy is null or (accuracy >= 0 and accuracy < 100000)),
  -- When the phone's GPS took the fix, by the phone's clock: what orders two
  -- fixes, and what the passenger's map tells one fix's delay from another's
  -- by. Never compared with this server's clock.
  fixed_at  timestamptz not null,
  -- When it was written here.
  sent_at   timestamptz not null default now()
)
-- Written over about once a second: room is left on each page so the new
-- version of a row lands beside the old one and no index is touched.
with (fillfactor = 50);

comment on table public.ride_live_fixes is
  'The driver''s latest GPS fix for the ride in hand (0426): one row a driver, written about once a '
  'second by ride_live_fix() while a ride is under way, read only by that ride''s passenger. The '
  'ride row''s partner_live_* columns stay the position everything else reads.';

-- The passenger's phone asks for the fix of one ride.
create index if not exists ride_live_fixes_ride_idx on public.ride_live_fixes (ride_id);

-- ---- Who may read a fix -------------------------------------------------------------------------
-- The caller is the passenger of ride [p_ride], it is under way, and [p_driver]
-- is still its driver. Asked by the read policy below, for each fix and each
-- listener: one look at the ride by its id, whatever the ride table's own
-- policies are.
create or replace function public.ride_live_fix_reader(p_ride uuid, p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_ride is not null and p_driver is not null and exists (
    select 1 from public.ride_requests r
     where r.id = p_ride
       and r.partner_id = p_driver
       and r.rider_id = (select auth.uid())
       and r.status in ('accepted', 'arrived', 'on_trip'));
$$;
revoke execute on function public.ride_live_fix_reader(uuid, uuid) from public, anon;
grant execute on function public.ride_live_fix_reader(uuid, uuid) to authenticated;

alter table public.ride_live_fixes enable row level security;
revoke all on public.ride_live_fixes from anon, authenticated;
grant select on public.ride_live_fixes to authenticated;

drop policy if exists "ride_live_fixes passenger read" on public.ride_live_fixes;
create policy "ride_live_fixes passenger read"
  on public.ride_live_fixes for select to authenticated
  using (public.ride_live_fix_reader(ride_id, driver_id));

-- Live: the passenger's map hears each fix as it is written.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ride_live_fixes'
     ) then
    alter publication supabase_realtime add table public.ride_live_fixes;
  end if;
end $$;

-- ---- How the driver's phone writes one ----------------------------------------------------------
-- The caller's fix for ride [p_ride]. True when the ride takes fixes from them
-- (it is theirs and under way), whether or not this one was news; false when
-- it does not, and the phone need send no more for it.
--
-- A fix older than the one held is dropped: two that crossed on the way. One
-- more than ten seconds older is taken all the same, as is any fix once the
-- one held has stood for ten seconds: the phone's clock has been put right,
-- and holding out for it to catch up would leave the passenger's car standing.
create or replace function public.ride_live_fix(
  p_ride     uuid,
  p_lat      double precision,
  p_lng      double precision,
  p_heading  double precision default null,
  p_speed    double precision default null,
  p_accuracy double precision default null,
  p_fixed_at timestamptz default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_at  timestamptz := coalesce(p_fixed_at, now());
begin
  if v_uid is null or p_ride is null or p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return false;
  end if;
  if not exists (
    select 1 from public.ride_requests r
     where r.id = p_ride
       and r.partner_id = v_uid
       and r.status in ('accepted', 'arrived', 'on_trip')
  ) then
    return false;
  end if;
  insert into public.ride_live_fixes as f
    (driver_id, ride_id, lat, lng, heading, speed, accuracy, fixed_at, sent_at)
  values (
    v_uid, p_ride, p_lat, p_lng,
    -- What the GPS could not measure, or a number no GPS gives, is kept as
    -- "not known", never as a made-up course or speed.
    case when p_heading >= 0 and p_heading < 360 then p_heading when p_heading = 360 then 0 end,
    case when p_speed >= 0 and p_speed <= 150 then p_speed end,
    case when p_accuracy >= 0 and p_accuracy < 100000 then p_accuracy end,
    v_at, now())
  on conflict (driver_id) do update
     set ride_id = excluded.ride_id,
         lat = excluded.lat,
         lng = excluded.lng,
         heading = excluded.heading,
         speed = excluded.speed,
         accuracy = excluded.accuracy,
         fixed_at = excluded.fixed_at,
         sent_at = excluded.sent_at
   where f.ride_id is distinct from excluded.ride_id
      or excluded.fixed_at > f.fixed_at
      or excluded.fixed_at < f.fixed_at - interval '10 seconds'
      or f.sent_at < now() - interval '10 seconds';
  return true;
end;
$$;
revoke execute on function public.ride_live_fix(
  uuid, double precision, double precision, double precision, double precision, double precision, timestamptz
) from public, anon;
grant execute on function public.ride_live_fix(
  uuid, double precision, double precision, double precision, double precision, double precision, timestamptz
) to authenticated;

notify pgrst, 'reload schema';
