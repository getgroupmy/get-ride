-- ============================================================================
-- 0141: "Auto-accept offer of RM x", kept by the database
--
-- A driver's Accept is now an offer at the rider's fare, like a
-- counter-offer: the rider still says yes. The exception is the rider who
-- booked with "Auto-accept offer of RM x" switched on: an offer at or under
-- that amount is taken at once. Until now that was done by the rider's
-- phone, so it only worked while the searching screen was open; this keeps
-- the amount on the request (`auto_accept_fare`) and takes such an offer
-- in the same write that places it, whether the rider's app is open or not.
--
--   * Only the rider sets `auto_accept_fare` (null is off). A write by
--     anyone else leaves it as it was.
--   * When an offer lands (or changes, or the rider switches auto-accept on
--     with an offer standing) at or under the amount, the row moves to
--     `accepted` with that driver, billed at the offer — exactly what the
--     rider's own accept does.
-- ============================================================================

alter table public.ride_requests add column if not exists auto_accept_fare numeric;

create or replace function public.ride_requests_auto_accept()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Nobody but the rider (or a server-side caller) decides it.
  if new.auto_accept_fare is distinct from old.auto_accept_fare
     and auth.uid() is not null
     and auth.uid() is distinct from old.rider_id then
    new.auto_accept_fare := old.auto_accept_fare;
  end if;
  if new.status = 'open'
     and old.status = 'open'
     and new.offered_fare is not null
     and new.partner_id is not null
     and new.auto_accept_fare is not null
     and new.offered_fare <= new.auto_accept_fare + 0.005
     and (new.offered_fare is distinct from old.offered_fare
          or new.partner_id is distinct from old.partner_id
          or new.auto_accept_fare is distinct from old.auto_accept_fare) then
    new.status := 'accepted';
    new.accepted_at := now();
    new.fare := new.offered_fare;
    new.ride_fare := new.offered_fare;
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_auto_accept() from public, anon, authenticated;

create or replace trigger trg_ride_requests_auto_accept
  before update on public.ride_requests
  for each row execute function public.ride_requests_auto_accept();

notify pgrst, 'reload schema';
