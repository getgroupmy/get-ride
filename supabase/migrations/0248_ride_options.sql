-- ============================================================================
-- 0248: Ride Options — "Assistance required", and what the options add to
-- the fare
--
-- Admin → Display Settings → Ride Options (kept in the display settings
-- blob, as before) shows, hides, renames and orders the rider's options,
-- and sets an assistance catalogue and charges for pets and assistance.
-- What reaches the ride:
--
--   * ride_requests.assistance: {items: [{id, name, emoji, choice}], note}.
--     Each item's name and emoji are copied in, so a ride keeps what was
--     picked even after the admin renames or removes it. The note label
--     keeps "Assistance: ..." (names only) for driver apps that don't read
--     the column.
--   * Ride privacy (0182, 0195, 0247) holds: approved drivers read an open
--     request's row, so they see what help is needed before accepting, but
--     the rider's free-text note waits in ride_request_private (the rider
--     and admins). When a driver takes the ride the note comes back to the
--     row, which only the rider, that driver and admins read. Reopened, it
--     moves out again. Only the rider (or an admin) changes the help.
--   * ride_requests.option_charges: [{kind, name, amount}], what the pets
--     and the assistance added ("Pet charge" 10). The fare already includes
--     them (the app adds them before quoting), so promo codes, commission
--     and every total work on the fare as before; the column says what is
--     in it, for the driver and admins. Written at booking only, by the
--     rider, and never more than the fare.
--   * Pet types are the admin's own list now: ride_pets_valid (0247) only
--     checks a type's length, never a fixed list, so a custom type books.
--   * A scheduled booking keeps both (0247's list plus assistance and
--     option_charges); the booking is read by the rider, the driver who took
--     it and admins only.
-- ============================================================================

-- ---- The help ------------------------------------------------------------------
-- Null, or an object with 1 to 40 items, each with a name (1 to 60
-- characters), maybe an id (up to 60), an emoji (up to 16) and a choice (up
-- to 80); and maybe a note (up to 500).
create or replace function public.ride_assistance_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is null
      or jsonb_typeof(p) = 'null'
      or (jsonb_typeof(p) = 'object'
          and jsonb_typeof(p->'items') = 'array'
          and jsonb_array_length(p->'items') between 1 and 40
          and (p->'note' is null or jsonb_typeof(p->'note') = 'null'
               or (jsonb_typeof(p->'note') = 'string' and char_length(p->>'note') <= 500))
          and pg_column_size(p) <= 16384
          and not exists (
            select 1 from jsonb_array_elements(p->'items') e
             where not coalesce(
               jsonb_typeof(e) = 'object'
               and jsonb_typeof(e->'name') = 'string'
               and char_length(btrim(e->>'name')) between 1 and 60
               and (e->'id' is null or (jsonb_typeof(e->'id') = 'string' and char_length(e->>'id') <= 60))
               and (e->'emoji' is null or jsonb_typeof(e->'emoji') = 'null'
                    or (jsonb_typeof(e->'emoji') = 'string' and char_length(e->>'emoji') <= 16))
               and (e->'choice' is null or jsonb_typeof(e->'choice') = 'null'
                    or (jsonb_typeof(e->'choice') = 'string' and char_length(e->>'choice') <= 80)),
               false)));
$$;

-- The help without the rider's note: what an open request shows drivers.
create or replace function public.ride_assistance_public(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p else p - 'note' end;
$$;
revoke execute on function public.ride_assistance_public(jsonb) from public, anon, authenticated;

-- ---- What the options add to the fare ------------------------------------------
-- Null, or up to 10 lines, each a name (1 to 60) and an amount of zero or
-- more (at most 100000), maybe with a kind.
create or replace function public.ride_option_charges_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is null
      or jsonb_typeof(p) = 'null'
      or (jsonb_typeof(p) = 'array'
          and jsonb_array_length(p) <= 10
          and not exists (
            select 1 from jsonb_array_elements(p) e
             where not coalesce(
               jsonb_typeof(e) = 'object'
               and jsonb_typeof(e->'name') = 'string'
               and char_length(btrim(e->>'name')) between 1 and 60
               and jsonb_typeof(e->'amount') = 'number'
               and (e->>'amount')::numeric between 0 and 100000
               and (e->'kind' is null or (jsonb_typeof(e->'kind') = 'string' and char_length(e->>'kind') <= 20)),
               false)));
$$;

-- The lines' total; 0 for none.
create or replace function public.ride_option_charges_total(p jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select coalesce((select sum((e->>'amount')::numeric)
                     from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) e
                    where jsonb_typeof(e->'amount') = 'number'), 0);
$$;

alter table public.ride_requests add column if not exists assistance jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_assistance_valid;
alter table public.ride_requests
  add constraint ride_requests_assistance_valid check (public.ride_assistance_valid(assistance));

alter table public.ride_requests add column if not exists option_charges jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_option_charges_valid;
alter table public.ride_requests
  add constraint ride_requests_option_charges_valid check (public.ride_option_charges_valid(option_charges));

alter table public.ride_request_private add column if not exists assistance jsonb;

-- ---- Open requests keep the note aside -------------------------------------------
-- Before the pets and privacy triggers (zz_assistance < zz_pets <
-- zz_privacy); it only touches assistance and option_charges. Who may
-- change them is the guard's below.
create or replace function public.ride_requests_assistance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ins boolean := tg_op = 'INSERT';
begin
  if new.assistance is not null and jsonb_typeof(new.assistance) = 'null' then
    new.assistance := null;
  end if;
  if new.option_charges is not null
     and (jsonb_typeof(new.option_charges) = 'null'
          or (jsonb_typeof(new.option_charges) = 'array' and jsonb_array_length(new.option_charges) = 0)) then
    new.option_charges := null;
  end if;
  if not public.ride_assistance_valid(new.assistance) then
    raise exception 'RIDE_ASSISTANCE_INVALID' using errcode = '22023',
      hint = 'Each kind of help needs a name; the note is at most 500 characters.';
  end if;

  if new.status = 'open' then
    if ins or new.assistance is distinct from old.assistance
       or (jsonb_typeof(new.assistance) = 'object' and new.assistance ? 'note') then
      insert into public.ride_request_private as p (request_id, assistance)
      values (new.id, new.assistance)
      on conflict (request_id) do update set assistance = excluded.assistance, updated_at = now();
      new.assistance := public.ride_assistance_public(new.assistance);
    end if;
  elsif not ins and old.status = 'open' and new.assistance is not distinct from old.assistance then
    -- Taken (or ended): the note comes back to the row.
    new.assistance := coalesce((select p.assistance from public.ride_request_private p where p.request_id = new.id),
                               new.assistance);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_assistance() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_zz_assistance on public.ride_requests;
create trigger trg_ride_requests_zz_assistance
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_assistance();

-- ---- Who changes them ------------------------------------------------------------
-- App callers are told apart by the session's role, as in 0247's pets guard;
-- the server's functions and admins who may edit rides are unaffected.
--   * the help is the rider's: nobody else changes it;
--   * what the options add is set when the ride is booked, and is part of
--     its fare.
create or replace function public.ride_requests_guard_rider_options()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_setting('role', true) not in ('anon', 'authenticated')
     or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.option_charges is not null and jsonb_typeof(new.option_charges) = 'array'
       and public.ride_option_charges_total(new.option_charges) > coalesce(new.fare, 0) + 0.005 then
      raise exception 'RIDE_OPTION_CHARGES_INVALID' using errcode = '22023',
        hint = 'The option charges are part of the fare.';
    end if;
    return new;
  end if;
  if auth.uid() is distinct from old.rider_id
     and new.assistance is distinct from old.assistance then
    raise exception 'RIDE_RIDER_ONLY' using errcode = '42501',
      hint = 'Only the passenger changes the help they asked for.';
  end if;
  if new.option_charges is distinct from old.option_charges then
    raise exception 'RIDE_OPTION_CHARGES_FIXED' using errcode = '42501',
      hint = 'The option charges are set when the ride is booked.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_rider_options() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_guard_rider_options on public.ride_requests;
create trigger trg_ride_requests_b_guard_rider_options
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_rider_options();

-- ---- Scheduled bookings ----------------------------------------------------------
-- The booking keeps the help and the option charges (0247's list, plus
-- assistance and option_charges).
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
       'promo_code_id', 'pets', 'assistance', 'option_charges'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- Help or charges that would stop the ride at its release are refused at
-- booking.
create or replace function public.scheduled_rides_options_check()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not public.ride_assistance_valid(new.request->'assistance') then
    raise exception 'RIDE_ASSISTANCE_INVALID' using errcode = '22023',
      hint = 'Each kind of help needs a name; the note is at most 500 characters.';
  end if;
  if not public.ride_option_charges_valid(new.request->'option_charges') then
    raise exception 'RIDE_OPTION_CHARGES_INVALID' using errcode = '22023',
      hint = 'The option charges are part of the fare.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_options_check() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_options on public.scheduled_rides;
create trigger trg_scheduled_rides_options
  before insert or update of request on public.scheduled_rides
  for each row execute function public.scheduled_rides_options_check();

notify pgrst, 'reload schema';
