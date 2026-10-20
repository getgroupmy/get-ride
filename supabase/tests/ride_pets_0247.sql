-- ============================================================================
-- Regression test for migration 0247: "Pet with me" carries the pets. Each
-- pet's photo sits in the rider's own folder of the private ride-pets
-- bucket: the rider uploads and reads it, another rider can't, the driver
-- who takes the ride can. The pets are saved on the ride, with the photos
-- kept aside while it is open.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_pets_0247.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if (select public from storage.buckets where id = 'ride-pets') is distinct from false then
    raise exception 'FAILED: ride-pets must exist and be private';
  end if;
  if has_function_privilege('anon', 'public.ride_pet_photo_readable(text)', 'execute') then
    raise exception 'FAILED: anon must not call ride_pet_photo_readable';
  end if;
  if has_function_privilege('authenticated', 'public.ride_pets_public(jsonb)', 'execute') then
    raise exception 'FAILED: ride_pets_public is the trigger''s own';
  end if;
end
$$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000247a1'),  -- rider
  ('00000000-0000-0000-0000-0000000247a2'),  -- another rider
  ('00000000-0000-0000-0000-0000000247b1'),  -- the driver who takes the ride
  ('00000000-0000-0000-0000-0000000247b2')   -- another driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000247%'
on conflict do nothing;

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
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
-- How many of the ride-pets files [p_name] the caller can see.
create or replace function pg_temp.sees(p_name text) returns bigint language sql as $$
  select count(*) from storage.objects where bucket_id = 'ride-pets' and name = p_name;
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.sees(text) to authenticated;

-- 1. The rider uploads into, and reads, their own folder ---------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000247a1');
insert into storage.objects (bucket_id, name, owner)
values ('ride-pets', '00000000-0000-0000-0000-0000000247a1/pet-dog.jpg', '00000000-0000-0000-0000-0000000247a1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-0000000247a1/pet-dog.jpg') = 1,
  'the rider reads their own pet photo (an upsert needs this too)');
select pg_temp.refused(
  $q$insert into storage.objects (bucket_id, name)
     values ('ride-pets', '00000000-0000-0000-0000-0000000247a2/pet-x.jpg')$q$,
  'an upload into another rider''s folder');

-- 2. Another rider can't read it; nor a driver before taking a ride ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000247a2');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-0000000247a1/pet-dog.jpg') = 0,
  'another rider cannot read the rider''s pet photo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000247b1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-0000000247a1/pet-dog.jpg') = 0,
  'a driver with no ride reads nothing');
reset role;

-- 3. The pets are saved; an open request keeps the photos aside ----------------------------------
insert into public.ride_requests (id, rider_id, status, note, pets) values
  ('00000000-0000-0000-0000-0000000247d1', '00000000-0000-0000-0000-0000000247a1', 'open',
   'Pet with me: 1 dog (M), 1 cat (S)',
   '[{"type": "Dog", "size": "M", "photo_path": "00000000-0000-0000-0000-0000000247a1/pet-dog.jpg"},
     {"type": "Cat", "size": "S"}]');
select pg_temp.check(
  (select pets = '[{"type": "Dog", "size": "M"}, {"type": "Cat", "size": "S"}]'::jsonb
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000247d1'),
  'an open request shows drivers the types and sizes, not the photos');
select pg_temp.check(
  (select pets->0->>'photo_path' = '00000000-0000-0000-0000-0000000247a1/pet-dog.jpg' and jsonb_array_length(pets) = 2
     from public.ride_request_private where request_id = '00000000-0000-0000-0000-0000000247d1'),
  'the photos wait aside, for the rider');

select pg_temp.refused(
  $q$insert into public.ride_requests (id, rider_id, status, pets) values
     ('00000000-0000-0000-0000-0000000247d2', '00000000-0000-0000-0000-0000000247a1', 'open',
      '[{"type": "Dog", "photo_path": "00000000-0000-0000-0000-0000000247a2/pet-x.jpg"}]')$q$,
  'a pet photo from another rider''s folder');
select pg_temp.refused(
  $q$insert into public.ride_requests (id, rider_id, status, pets) values
     ('00000000-0000-0000-0000-0000000247d3', '00000000-0000-0000-0000-0000000247a1', 'open', '[{"size": "M"}]')$q$,
  'a pet without a type');

-- 4. The driver takes the ride: the photos come back and the driver reads them ---------------------
update public.ride_requests
   set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000247b1', accepted_at = now()
 where id = '00000000-0000-0000-0000-0000000247d1';
select pg_temp.check(
  (select pets->0->>'photo_path' = '00000000-0000-0000-0000-0000000247a1/pet-dog.jpg' and pets->1->>'type' = 'Cat'
     from public.ride_requests where id = '00000000-0000-0000-0000-0000000247d1'),
  'the pets column keeps every pet, with its photo, once the ride is taken');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000247b1');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-0000000247a1/pet-dog.jpg') = 1,
  'the assigned driver reads the ride''s pet photo');
-- Nobody but the rider changes the pets.
do $$
begin
  begin
    update public.ride_requests set pets = null where id = '00000000-0000-0000-0000-0000000247d1';
  exception when others then
    null;
  end;
end $$;
select pg_temp.check(
  (select jsonb_array_length(pets) = 2 from public.ride_requests where id = '00000000-0000-0000-0000-0000000247d1'),
  'the driver cannot change the rider''s pets');

select pg_temp.as_user('00000000-0000-0000-0000-0000000247b2');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-0000000247a1/pet-dog.jpg') = 0,
  'another driver still reads nothing');
select pg_temp.as_user('00000000-0000-0000-0000-0000000247a2');
select pg_temp.check(pg_temp.sees('00000000-0000-0000-0000-0000000247a1/pet-dog.jpg') = 0,
  'another rider still reads nothing');
reset role;

-- 5. A scheduled booking keeps the pets ------------------------------------------------------------
select pg_temp.check(
  public.scheduled_request_clean('{"pets": [{"type": "Dog", "size": "M"}], "status": "accepted"}'::jsonb)
    = '{"pets": [{"type": "Dog", "size": "M"}]}'::jsonb,
  'a scheduled booking keeps the pets');

select 'ride_pets_0247: all passed';
rollback;
