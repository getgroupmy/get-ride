-- ============================================================================
-- Regression test for migration 0418: the lat/lng box in
-- nearby_online_drivers must never drop a driver the exact distance keeps.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_presence_geo_0418.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

-- The exact rule from 0145, with no box: what the result must equal.
create or replace function pg_temp.exact(p_lat double precision, p_lng double precision, p_r double precision)
returns setof uuid language sql stable as $$
  select d.profile_id
    from public.driver_presence d
   where d.online
     and d.updated_at > now() - interval '3 minutes'
     and d.lat is not null and d.lng is not null
     and 2 * 6371 * asin(sqrt(
           power(sin(radians(d.lat - p_lat) / 2), 2)
           + cos(radians(p_lat)) * cos(radians(d.lat)) * power(sin(radians(d.lng - p_lng) / 2), 2)
         )) <= p_r;
$$;

-- Only our drivers count, written straight in: the online guards (credit,
-- permit, selfie) and session/airport side effects are other tests' business.
alter table public.driver_presence disable trigger user;
delete from public.driver_presence;

-- A ring of online drivers round each test point, at 0.5 to 1.5 times the
-- radius in 16 directions, so the edges of the box are exercised.
create temp table pts (lat double precision, lng double precision, r double precision);
insert into pts values
  (3.1390, 101.6869, 5),     -- Kuala Lumpur
  (3.1390, 101.6869, 0.3),   -- a tight ring
  (1.3521, 103.8198, 25),    -- Singapore, wide
  (60.1699, 24.9384, 10),    -- Helsinki, high latitude
  (-33.8688, 151.2093, 10),  -- Sydney, southern hemisphere
  (0.0, 179.98, 8),          -- straddles the 180th meridian
  (88.5, 0.0, 50);           -- next to the pole

insert into auth.users (id)
select ('00000000-0000-0000-0418-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(1, 7 * 16 * 5) n
on conflict do nothing;
insert into public.profiles (id)
select id from auth.users where id::text like '00000000-0000-0000-0418-%'
on conflict do nothing;

with p as (select row_number() over () as i, * from pts),
     g as (
       select p.*, k as dir, f,
              row_number() over (order by p.i, k, f) as n
         from p, generate_series(0, 15) k, unnest(array[0.5, 0.95, 1.0, 1.05, 1.5]) f
     )
insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
select ('00000000-0000-0000-0418-' || lpad(n::text, 12, '0'))::uuid, true,
       -- Destination point on a sphere, distance f*r along bearing k*22.5°.
       degrees(asin(sin(radians(lat)) * cos(f * r / 6371)
                    + cos(radians(lat)) * sin(f * r / 6371) * cos(radians(dir * 22.5)))),
       (degrees(radians(lng) + atan2(
           sin(radians(dir * 22.5)) * sin(f * r / 6371) * cos(radians(lat)),
           cos(f * r / 6371) - sin(radians(lat)) * sin(radians(degrees(asin(
             sin(radians(lat)) * cos(f * r / 6371)
             + cos(radians(lat)) * sin(f * r / 6371) * cos(radians(dir * 22.5)))))))) + 540)::numeric
         % 360 - 180,
       now()
  from g
on conflict (profile_id) do update
  set online = excluded.online, lat = excluded.lat, lng = excluded.lng, updated_at = excluded.updated_at;

-- 1. Same drivers as the exact rule, at every test point.
select pg_temp.check(
  (select count(*) = 0 from (
     (select * from public.nearby_online_drivers(lat, lng, r) except select * from pg_temp.exact(lat, lng, r))
     union all
     (select * from pg_temp.exact(lat, lng, r) except select * from public.nearby_online_drivers(lat, lng, r))
   ) diff),
  format('box matches exact distance at %s, %s (%s km)', lat, lng, r))
  from pts;

-- 2. Each point has someone inside and someone outside, so the test bites.
select pg_temp.check((select count(*) > 0 from public.nearby_online_drivers(lat, lng, r)),
                     format('someone nearby at %s, %s', lat, lng))
  from pts;
-- The rings at 1.05 and 1.5 times the radius are outside it.
select pg_temp.check(
  (select count(*) < (select count(*) from public.driver_presence)
     from public.nearby_online_drivers(lat, lng, r)),
  format('not everyone nearby at %s, %s', lat, lng))
  from pts;

-- 3. Offline and stale drivers stay out; no position, no one.
update public.driver_presence set online = false
 where profile_id = (select profile_id from public.driver_presence order by profile_id limit 1);
update public.driver_presence set updated_at = now() - interval '10 minutes'
 where profile_id = (select profile_id from public.driver_presence order by profile_id desc limit 1);
select pg_temp.check(
  (select count(*) = 0 from public.driver_presence d
    where (not d.online or d.updated_at < now() - interval '3 minutes')
      and d.profile_id in (select public.nearby_online_drivers(p.lat, p.lng, p.r) from pts p)),
  'offline and stale drivers are left out');
select pg_temp.check((select count(*) = 0 from public.nearby_online_drivers(null, null, 5)), 'no position, no one');

-- 4. The index is there.
select pg_temp.check(
  exists (select 1 from pg_indexes where indexname = 'driver_presence_online_geo'),
  'driver_presence_online_geo exists');

rollback;
