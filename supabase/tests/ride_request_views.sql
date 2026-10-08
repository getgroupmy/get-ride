-- ============================================================================
-- Regression test for migration 0112: drivers viewing a request.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_request_views.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000012a1'),  -- rider
  ('00000000-0000-0000-0000-0000000012a2'),  -- driver with a photo
  ('00000000-0000-0000-0000-0000000012a3'),  -- driver without one
  ('00000000-0000-0000-0000-0000000012a4')   -- not a driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000012%'
on conflict do nothing;
update public.profiles set avatar_url = 'https://x/a2.png' where id = '00000000-0000-0000-0000-0000000012a2';
insert into public.partners (auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000000012a2', 'Reza', '+601201'),
  ('00000000-0000-0000-0000-0000000012a3', 'Yoga', '+601202');

insert into public.ride_requests (id, rider_id, status, pickup_name, drop_name) values
  ('00000000-0000-0000-0000-0000000012c1', '00000000-0000-0000-0000-0000000012a1', 'open', 'A', 'B'),
  ('00000000-0000-0000-0000-0000000012c2', '00000000-0000-0000-0000-0000000012a1', 'accepted', 'A', 'B');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

set local role authenticated;

-- 1. Drivers mark it seen; a non-driver and a closed request count for nothing.
select pg_temp.as_user('00000000-0000-0000-0000-0000000012a2');
select public.ride_request_viewed('00000000-0000-0000-0000-0000000012c1');
select public.ride_request_viewed('00000000-0000-0000-0000-0000000012c1');  -- again: still one
select public.ride_request_viewed('00000000-0000-0000-0000-0000000012c2');  -- not open
select pg_temp.as_user('00000000-0000-0000-0000-0000000012a3');
select public.ride_request_viewed('00000000-0000-0000-0000-0000000012c1');
select pg_temp.as_user('00000000-0000-0000-0000-0000000012a4');
select public.ride_request_viewed('00000000-0000-0000-0000-0000000012c1');

-- 2. The table itself is closed to clients.
do $$
begin
  begin
    perform 1 from public.ride_request_views;
    raise exception 'FAILED: ride_request_views is readable';
  exception when insufficient_privilege then null;
  end;
end $$;

-- 3. Somebody else gets nothing back.
do $$
begin
  if exists (select 1 from public.ride_request_viewers('00000000-0000-0000-0000-0000000012c1')) then
    raise exception 'FAILED: a stranger read the viewers';
  end if;
end $$;

-- 4. The rider sees two viewers, both looking now, and the one photo.
select pg_temp.as_user('00000000-0000-0000-0000-0000000012a1');
do $$
declare r record;
begin
  select * into r from public.ride_request_viewers('00000000-0000-0000-0000-0000000012c1');
  if r.viewed <> 2 or r.viewing <> 2 or r.photos <> array['https://x/a2.png'] then
    raise exception 'FAILED: viewers %', row_to_json(r);
  end if;
  select * into r from public.ride_request_viewers('00000000-0000-0000-0000-0000000012c2');
  if r.viewed <> 0 then
    raise exception 'FAILED: a closed request was viewed %', row_to_json(r);
  end if;
end $$;

-- 5. Thirty seconds on, they have seen it but are not looking.
reset role;
update public.ride_request_views set last_seen_at = now() - interval '1 minute';
set local role authenticated;
do $$
declare r record;
begin
  select * into r from public.ride_request_viewers('00000000-0000-0000-0000-0000000012c1');
  if r.viewed <> 2 or r.viewing <> 0 then
    raise exception 'FAILED: stale viewers %', row_to_json(r);
  end if;
end $$;

select 'ride_request_views: all passed';
rollback;
