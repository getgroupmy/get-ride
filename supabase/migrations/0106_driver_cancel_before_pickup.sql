-- 0106: a driver may cancel a ride only before the passenger is on board.
--
-- Until the trip starts (accepted / arrived) the driver cancels outright,
-- with a reason, and the passenger is told. Once the passenger is in the car
-- (on_trip) the driver can no longer cancel: the trip is completed, or ended
-- early, which prices it to where the car is. The one exception is a
-- cancellation the passenger asked for themselves: the driver approving it
-- is what moves the ride to cancelled.
--
-- The app already offers no cancel key on a trip in progress; this makes
-- the rule hold for any client. Admins, the service role and SECURITY
-- DEFINER functions are unaffected.

create or replace function public.ride_requests_guard_driver_cancel()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.status = 'cancelled'
     and old.status = 'on_trip'
     and old.partner_id is not distinct from auth.uid()
     and old.rider_id is distinct from auth.uid()
     and old.cancel_requested_by is distinct from 'rider' then
    raise exception 'RIDE_DRIVER_CANCEL_AFTER_PICKUP' using errcode = '42501',
      hint = 'The passenger is on board: complete the trip or end it early instead.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ride_requests_b_guard_driver_cancel on public.ride_requests;
create trigger trg_ride_requests_b_guard_driver_cancel
  before update on public.ride_requests
  for each row execute function public.ride_requests_guard_driver_cancel();
