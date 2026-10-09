-- 0122: The scheduled taxes and surcharges a ride was booked under
-- (Admin → Country / States / Cities → Rules), stamped beside 0119's
-- whole_fare / tax_* so the driver's request, the trip and the receipt
-- price the ride the same way even after the admin edits the rules.
--
--   charges  a JSON array of {kind: 'tax'|'surcharge', name, charge:
--            'percent'|'fixed', value}; null when none were in force.
--            Surcharges are added to the fare; taxes are on the fare and
--            its surcharges.
--
-- The app books without the column on a database that lacks it.

alter table public.ride_requests
  add column if not exists charges jsonb;

alter table public.ride_requests drop constraint if exists ride_requests_charges_shape;
alter table public.ride_requests
  add constraint ride_requests_charges_shape check (
    charges is null
    or (jsonb_typeof(charges) = 'array' and jsonb_array_length(charges) <= 20 and pg_column_size(charges) <= 8192)
  );
