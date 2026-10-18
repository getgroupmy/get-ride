-- ============================================================================
-- Regression test for migration 0231: the "Your driver has arrived" push
-- starts with a capital letter when the ride has no plate ("Your car is
-- waiting at …"), keeps a plate as it is, and the accepted push still says
-- "is on the way in your car." mid-sentence.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/arrived_push_0231.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
declare
  o public.ride_requests;
  n public.ride_requests;
  m jsonb;
begin
  n.id := gen_random_uuid();
  n.rider_id := gen_random_uuid();
  n.partner_id := gen_random_uuid();
  n.pickup_name := 'KLCC';

  -- Arrived, no plate.
  o.status := 'accepted';
  n.status := 'arrived';
  m := public.ride_status_messages(o, n, n.partner_id);
  if m->0->>'body' is distinct from 'Your car is waiting at KLCC.' then
    raise exception 'FAILED: arrived without a plate: %', m->0->>'body';
  end if;

  -- Arrived, with a plate.
  n.partner_plate := 'ABC1234';
  m := public.ride_status_messages(o, n, n.partner_id);
  if m->0->>'body' is distinct from 'ABC1234 is waiting at KLCC.' then
    raise exception 'FAILED: arrived with a plate: %', m->0->>'body';
  end if;

  -- Accepted, no plate: lower case mid-sentence.
  n.partner_plate := null;
  n.partner_name := 'Ali';
  o.status := 'searching';
  n.status := 'accepted';
  m := public.ride_status_messages(o, n, n.partner_id);
  if m->0->>'body' is distinct from 'Ali is on the way in your car.' then
    raise exception 'FAILED: accepted without a plate: %', m->0->>'body';
  end if;
end $$;

rollback;
