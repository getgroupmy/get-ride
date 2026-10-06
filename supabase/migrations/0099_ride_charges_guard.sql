-- 0099: tolls and other charges declared by the driver at the end of a trip.
--
-- ride_requests.toll_charges / other_charges (0047) have been on the table
-- since the extended capture fields, and the receipts already print them,
-- but nothing wrote them: Expo's driver typed tolls and extras into a popup
-- that only reached the driver's own receipt, so the rider was never shown
-- what they were asked to pay. The Flutter driver now declares them on
-- Complete, and they are stored on the ride.
--
-- This adds the note that goes with "other charges" and makes the three
-- columns the driver's alone to set:
--   * a non-admin client can't insert a request that already carries charges,
--   * only the ride's own partner can change them afterwards (the rider is a
--     participant too and may otherwise update the row),
--   * amounts are 0..10000 and the note at most 200 characters.
-- Admins, the service role and SECURITY DEFINER functions are unaffected.

alter table public.ride_requests
  add column if not exists other_charges_note text;

alter table public.ride_requests drop constraint if exists ride_requests_charges_range;
alter table public.ride_requests
  add constraint ride_requests_charges_range check (
    (toll_charges is null or (toll_charges >= 0 and toll_charges <= 10000))
    and (other_charges is null or (other_charges >= 0 and other_charges <= 10000))
    and (other_charges_note is null or char_length(other_charges_note) <= 200)
  ) not valid;

create or replace function public.ride_requests_guard_charges()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if coalesce(new.toll_charges, 0) <> 0
       or coalesce(new.other_charges, 0) <> 0
       or new.other_charges_note is not null then
      raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
        hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
    end if;
    return new;
  end if;
  if (new.toll_charges, new.other_charges, new.other_charges_note)
       is distinct from (old.toll_charges, old.other_charges, old.other_charges_note)
     and (old.partner_id is null or old.partner_id is distinct from auth.uid()) then
    raise exception 'RIDE_CHARGES_DRIVER_ONLY' using errcode = '42501',
      hint = 'Tolls and other charges are declared by the driver at the end of the trip.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ride_requests_b_guard_charges on public.ride_requests;
create trigger trg_ride_requests_b_guard_charges
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_charges();
