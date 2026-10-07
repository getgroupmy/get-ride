-- 0107: one request at a time, and booking rides for other people.
--
-- A rider has one ride of their own on the go at a time. Once they have
-- tapped Find driver, another request of their own is a duplicate (a second
-- tap, a second device, a retry): it is refused before it is written, so it
-- is never stored and never broadcast to drivers (the new-request push is an
-- AFTER INSERT trigger, and the app only notifies after a successful insert).
--
-- Rides booked for someone else are exempt: a rider may have several on the
-- go at once (one for a parent, one for a child), and each is marked with
-- the passenger it is for. The one limit there is one live ride per
-- passenger phone, which is what a double tap on the same booking is.
--
-- "On the go" is: open and younger than the 7-minute request expiry (an
-- older open row is one the app never got round to expiring, and must not
-- lock the rider out), or accepted / arrived / on_trip and touched within
-- the last 12 hours (a ride abandoned without being ended doesn't block
-- forever). Admins, the service role and SECURITY DEFINER functions are
-- unaffected.

alter table public.ride_requests
  add column if not exists booked_for_name text,
  add column if not exists booked_for_phone text;

alter table public.ride_requests drop constraint if exists ride_requests_booked_for_shape;
alter table public.ride_requests
  add constraint ride_requests_booked_for_shape check (
    (booked_for_name is null or char_length(booked_for_name) between 1 and 80)
    and (booked_for_phone is null or char_length(booked_for_phone) between 6 and 32)
    and (booked_for_name is null or booked_for_phone is not null)
  ) not valid;

create or replace function public.ride_requests_one_active_request()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  phone text := nullif(regexp_replace(coalesce(new.booked_for_phone, ''), '\D', '', 'g'), '');
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.rider_id is null or new.status is distinct from 'open' then
    return new;
  end if;
  -- Two taps land as two transactions: the second waits for the first.
  perform pg_advisory_xact_lock(hashtextextended('ride_request:' || new.rider_id::text, 0));
  if exists (
    select 1
      from public.ride_requests r
     where r.rider_id = new.rider_id
       and r.id is distinct from new.id
       and (
         (r.status = 'open' and r.created_at > now() - interval '7 minutes')
         or (r.status in ('accepted', 'arrived', 'on_trip') and r.updated_at > now() - interval '12 hours')
       )
       and (
         (phone is null and r.booked_for_phone is null)
         or (phone is not null and regexp_replace(coalesce(r.booked_for_phone, ''), '\D', '', 'g') = phone)
       )
  ) then
    raise exception 'RIDE_REQUEST_DUPLICATE' using errcode = 'P0001',
      hint = case when phone is null
        then 'You already have a ride request on the go.'
        else 'You already have a ride on the go for this passenger.' end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ride_requests_a_one_active on public.ride_requests;
create trigger trg_ride_requests_a_one_active
  before insert on public.ride_requests
  for each row execute function public.ride_requests_one_active_request();
