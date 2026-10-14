-- ============================================================================
-- Regression test for migration 0195: an open request shows drivers only
-- what they need to decide; the details come back once one accepts.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/open_request_privacy.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000195a1'),  -- rider
  ('00000000-0000-0000-0000-0000000195b1'),  -- driver who accepts
  ('00000000-0000-0000-0000-0000000195b2'),  -- another driver
  ('00000000-0000-0000-0000-0000000195c1')   -- admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000195%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000195c1', '*', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000195b1', 'Badrul', '+60110000195', 'approved'),
  ('00000000-0000-0000-0000-0000000195b2', 'Bella', '+60110000196', 'approved');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;

-- 1. The rider books for Mum ---------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000195a1');
with r as (
  insert into public.ride_requests (rider_id, status, rider_name, rider_phone, rider_photo, booked_for_name,
                                    booked_for_phone, otp, ip_address, full_address, gender, fare, ride_fare,
                                    pickup_name, pickup_lat, pickup_lng)
  values ('00000000-0000-0000-0000-0000000195a1', 'open', 'Siti Aminah binti Ali', '+60120000195',
          'https://example.com/siti.jpg', 'Mum', '+60130000195', '4821', '203.0.113.9', '1 Jalan Ampang, KL',
          'female', 20, 20, 'KLCC', 3.15, 101.71)
  returning id)
insert into ids select 'mum', id from r;

-- What the row now holds.
select pg_temp.check((select rider_name = 'Siti' and rider_phone is null and booked_for_name is null
                             and booked_for_phone is null and booked_for_other and otp is null
                             and ip_address is null and full_address is null and gender is null
                             and rider_photo = 'https://example.com/siti.jpg' and pickup_name = 'KLCC'
                        from public.ride_requests where id = (select id from ids where k = 'mum')),
  'the open row keeps only the first name, the photo and the place');
-- The rider still reads the details.
select pg_temp.check((select rider_name = 'Siti Aminah binti Ali' and booked_for_name = 'Mum'
                             and booked_for_phone = '+60130000195' and rider_phone = '+60120000195'
                        from public.ride_request_private where request_id = (select id from ids where k = 'mum')),
  'the rider reads what was moved aside');
-- The code is where start_trip checks it.
reset role;
select pg_temp.check((select code = '4821' from public.ride_trip_codes where request_id = (select id from ids where k = 'mum')),
  'the trip code is kept for start_trip');
set local role authenticated;

-- 2. A browsing driver sees the open row, not the details ----------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000195b2');
select pg_temp.check((select count(*) from public.ride_requests where id = (select id from ids where k = 'mum')) = 1,
  'drivers still see the open request');
select pg_temp.check((select rider_phone is null and booked_for_phone is null and otp is null
                        from public.ride_requests where id = (select id from ids where k = 'mum')),
  'but not the phone numbers or the code');
select pg_temp.check(not exists (select 1 from public.ride_request_private), 'nor the details kept aside');

-- 3. The rider raises the fare: no false duplicate, details kept ---------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000195a1');
update public.ride_requests set ride_fare = 24 where id = (select id from ids where k = 'mum');
select pg_temp.check((select booked_for_phone = '+60130000195' and rider_name = 'Siti Aminah binti Ali'
                        from public.ride_request_private where request_id = (select id from ids where k = 'mum')),
  'an update keeps what was moved aside');
-- One for Mum is on the go: a second one for her is refused, the rider's own isn't.
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, booked_for_name, booked_for_phone)
  values ('00000000-0000-0000-0000-0000000195a1', 'open', 'Mum', '60130000195')$q$, 'a second ride for Mum');
insert into public.ride_requests (rider_id, status, rider_name, rider_phone)
values ('00000000-0000-0000-0000-0000000195a1', 'open', 'Siti Aminah binti Ali', '+60120000195');

-- 4. The share link works while it's open ---------------------------------------------------
insert into ids select 'token', public.ride_share_link((select id from ids where k = 'mum'));
select pg_temp.check(public.ride_share_link((select id from ids where k = 'mum')) = (select id from ids where k = 'token'),
  'the same link each time');
select pg_temp.check((select share_token is null from public.ride_requests where id = (select id from ids where k = 'mum')),
  'the link is not on the open row');
select pg_temp.check((select v->>'passenger' = 'Mum' and v->>'otp' = '4821' and (v->>'booked_for_others')::boolean
                        from (select public.ride_share_view((select id from ids where k = 'token')) v) s),
  'the shared page shows Mum her code');

-- 5. A driver accepts: the details come back, the code doesn't ------------------------------
reset role;
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000195b1'
 where id = (select id from ids where k = 'mum');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000195b1');
select pg_temp.check((select rider_name = 'Siti Aminah binti Ali' and rider_phone = '+60120000195'
                             and booked_for_name = 'Mum' and booked_for_phone = '+60130000195' and otp is null
                        from public.ride_requests where id = (select id from ids where k = 'mum')),
  'the accepted driver gets the details back, not the code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000195b2');
select pg_temp.check(not exists (select 1 from public.ride_requests where id = (select id from ids where k = 'mum')),
  'other drivers no longer see it');

-- 6. The photo setting ----------------------------------------------------------------------
select pg_temp.refused($q$select public.set_ride_privacy_config('{"showRiderPhoto":false}')$q$,
  'a driver changing the photo setting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000195c1');
select pg_temp.check(not (public.set_ride_privacy_config('{"showRiderPhoto":false}') ->> 'showRiderPhoto')::boolean,
  'the admin turns the photo off');
select pg_temp.as_user('00000000-0000-0000-0000-0000000195a1');
update public.ride_requests set status = 'cancelled'
 where rider_id = '00000000-0000-0000-0000-0000000195a1' and status = 'open';
with r as (
  insert into public.ride_requests (rider_id, status, rider_name, rider_photo)
  values ('00000000-0000-0000-0000-0000000195a1', 'open', 'Siti', 'https://example.com/siti.jpg')
  returning id)
insert into ids select 'nophoto', id from r;
select pg_temp.check((select rider_photo is null from public.ride_requests where id = (select id from ids where k = 'nophoto')),
  'no photo while it is off');
select pg_temp.check((select rider_photo = 'https://example.com/siti.jpg' from public.ride_request_private
                       where request_id = (select id from ids where k = 'nophoto')), 'but kept for after acceptance');

reset role;
select 'open_request_privacy: all passed';
rollback;
