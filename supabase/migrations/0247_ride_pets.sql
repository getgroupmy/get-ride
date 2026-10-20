-- ============================================================================
-- 0247: "Pet with me" carries the pets — type, size and a photo of each
--
-- The Options switch was a plain flag that reached the driver as the note
-- label "Pet with me". Now the rider says which pets come (Dog, Cat, ...),
-- a size for each and a photo of each:
--
--   * ride_requests.pets: a list of {type, size, photo_path}. The note keeps
--     "Pet with me: 2 dogs (M, L)" for driver apps that don't read it.
--   * The photos are in the private `ride-pets` bucket, in the rider's own
--     folder (`<rider uid>/pet-<uuid>.jpg`). The rider adds to and reads
--     their folder; the driver who takes the ride, and admins, read the
--     photos that ride names. The apps open them through signed links.
--   * Ride privacy (0182, 0195) holds: while a request is open, approved
--     drivers can read its row, so the photo paths wait in
--     ride_request_private (the rider and admins) and the row keeps only
--     each pet's type and size. When a driver takes the ride the paths come
--     back to the row, which only the rider, that driver and admins read.
--   * A scheduled booking keeps the pets (0242's list plus `pets`) and they
--     go to the ride when it is released.
-- ============================================================================

-- ---- The pets ------------------------------------------------------------------
-- A list of at most 50 pets, each with a type (1 to 40 characters), maybe
-- a size (1 to 10) and maybe a photo, which must be in [p_rider]'s folder
-- of the bucket. Null is no pets.
create or replace function public.ride_pets_valid(p_pets jsonb, p_rider uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_pets is null
      or jsonb_typeof(p_pets) = 'null'
      or (jsonb_typeof(p_pets) = 'array'
          and jsonb_array_length(p_pets) <= 50
          and not exists (
            select 1 from jsonb_array_elements(p_pets) e
             where not coalesce(
               jsonb_typeof(e) = 'object'
               and jsonb_typeof(e->'type') = 'string'
               and char_length(btrim(e->>'type')) between 1 and 40
               and (e->'size' is null or jsonb_typeof(e->'size') = 'null'
                    or (jsonb_typeof(e->'size') = 'string' and char_length(btrim(e->>'size')) between 1 and 10))
               and (e->'photo_path' is null or jsonb_typeof(e->'photo_path') = 'null'
                    or (jsonb_typeof(e->'photo_path') = 'string'
                        and p_rider is not null
                        and starts_with(e->>'photo_path', p_rider::text || '/')
                        and char_length(e->>'photo_path') <= 300
                        and position('..' in e->>'photo_path') = 0)),
               false)));
$$;

-- The pets without their photos: what an open request shows drivers.
create or replace function public.ride_pets_public(p_pets jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p_pets is null or jsonb_typeof(p_pets) <> 'array' then p_pets
    else coalesce((select jsonb_agg(e.value - 'photo_path' order by e.ord)
                     from jsonb_array_elements(p_pets) with ordinality as e(value, ord)), '[]'::jsonb)
  end;
$$;
revoke execute on function public.ride_pets_public(jsonb) from public, anon, authenticated;

alter table public.ride_requests add column if not exists pets jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_pets_valid;
alter table public.ride_requests
  add constraint ride_requests_pets_valid check (public.ride_pets_valid(pets, rider_id));

alter table public.ride_request_private add column if not exists pets jsonb;

-- ---- Open requests keep the photos aside ---------------------------------------
-- Before the privacy trigger (zz_pets < zz_privacy); it only touches pets.
create or replace function public.ride_requests_pets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ins boolean := tg_op = 'INSERT';
begin
  if new.pets is not null and (jsonb_typeof(new.pets) = 'null'
                               or (jsonb_typeof(new.pets) = 'array' and jsonb_array_length(new.pets) = 0)) then
    new.pets := null;
  end if;
  if not public.ride_pets_valid(new.pets, new.rider_id) then
    raise exception 'RIDE_PETS_INVALID' using errcode = '22023',
      hint = 'Each pet needs a type, and its photo must be the rider''s own.';
  end if;
  -- The rider's pets are the rider's: nobody else changes them.
  if not ins and new.pets is distinct from old.pets
     and current_user in ('anon', 'authenticated') and not public.caller_is_admin()
     and auth.uid() is distinct from old.rider_id then
    raise exception 'RIDE_RIDER_ONLY' using errcode = '42501',
      hint = 'Only the passenger changes their pets.';
  end if;

  if new.status = 'open' then
    if ins or new.pets is distinct from old.pets
       or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(new.pets) = 'array' then new.pets
                                                          else '[]'::jsonb end) e
                   where e ? 'photo_path') then
      insert into public.ride_request_private as p (request_id, pets)
      values (new.id, new.pets)
      on conflict (request_id) do update set pets = excluded.pets, updated_at = now();
      new.pets := public.ride_pets_public(new.pets);
    end if;
  elsif not ins and old.status = 'open' and new.pets is not distinct from old.pets then
    -- Taken (or ended): the photos come back to the row.
    new.pets := coalesce((select p.pets from public.ride_request_private p where p.request_id = new.id), new.pets);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_pets() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_zz_pets on public.ride_requests;
create trigger trg_ride_requests_zz_pets
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_pets();

-- ---- Scheduled bookings ----------------------------------------------------------
-- The booking keeps the pets (0242's list, plus pets).
create or replace function public.scheduled_request_clean(p_request jsonb, p_fee numeric default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce((
    select jsonb_object_agg(e.key,
      case when e.key = 'charges' then (
        select coalesce(jsonb_agg(
          case when p_fee is not null and c->>'name' = 'Scheduling fee' and c->'value' = to_jsonb(p_fee)
                    and c->>'kind' = 'surcharge'
               then c else c - 'platform' end), '[]'::jsonb)
          from jsonb_array_elements(e.value) c
         where jsonb_typeof(c) = 'object')
      else e.value end)
      from jsonb_each(coalesce(p_request, '{}'::jsonb)) e
     where e.key = any (array[
       'rider_name', 'rider_phone', 'rider_photo', 'service', 'payment_mode',
       'pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng',
       'drop_name', 'drop_address', 'drop_lat', 'drop_lng', 'stops',
       'distance_km', 'duration_min', 'fare', 'ride_fare', 'currency',
       'passengers', 'luggage', 'note', 'offer_me', 'otp', 'device_os',
       'user_accept_lat', 'user_accept_lng', 'booked_for_name', 'booked_for_phone',
       'country', 'state', 'city', 'suburb', 'full_address', 'ip_address', 'gender',
       'whole_fare', 'tax_name', 'tax_kind', 'tax_value', 'charges', 'timezone',
       'promo_code_id', 'pets'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- Pets that would stop the ride at its release are refused at booking.
create or replace function public.scheduled_rides_pets_check()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not public.ride_pets_valid(new.request->'pets', new.rider_id) then
    raise exception 'RIDE_PETS_INVALID' using errcode = '22023',
      hint = 'Each pet needs a type, and its photo must be the rider''s own.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_pets_check() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_pets on public.scheduled_rides;
create trigger trg_scheduled_rides_pets
  before insert or update of request on public.scheduled_rides
  for each row execute function public.scheduled_rides_pets_check();

-- ---- The photos ------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ride-pets', 'ride-pets', false, 15728640, array['image/*'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Whether the caller may see the pet photo [p_name]: an admin, or the
-- driver of a ride they have taken that names it (its rider's own file).
-- The rider's own folder is the policy's first test.
create or replace function public.ride_pet_photo_readable(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    public.caller_is_admin()
    or exists (
      select 1 from public.ride_requests r
       where r.partner_id = auth.uid()
         and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
         and r.rider_id::text = split_part(coalesce(p_name, ''), '/', 1)
         and r.pets @> jsonb_build_array(jsonb_build_object('photo_path', p_name))
    )
  );
$$;
revoke execute on function public.ride_pet_photo_readable(text) from public, anon;
grant execute on function public.ride_pet_photo_readable(text) to authenticated;

drop policy if exists "ride pets owner upload" on storage.objects;
drop policy if exists "ride pets read" on storage.objects;
drop policy if exists "ride pets admin delete" on storage.objects;

create policy "ride pets owner upload"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ride-pets'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- The rider's own folder (which storage's upsert needs as well), the ride's
-- driver and admins.
create policy "ride pets read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'ride-pets'
    and ((storage.foldername(name))[1] = (select auth.uid())::text
         or public.ride_pet_photo_readable(name))
  );

create policy "ride pets admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'ride-pets' and public.caller_admin_can_write('storage:ride-pets'));

notify pgrst, 'reload schema';
