-- 0124: The pickup region's time zone, stamped on the ride at booking
-- (Admin → Country / States / Cities → Time zone; the most specific region
-- around the pickup with one).
--
--   timezone  an IANA name (Asia/Kuala_Lumpur); null where the region has
--             none, and on rides booked before this
--
-- The ride's times are shown as the clocks where it happened showed them —
-- the trip list, the receipt, the shared ride page — rather than in
-- whatever zone the phone reading them is set to. Stamped once, like 0119's
-- pricing, so a later change to the region doesn't move a past trip's
-- times. The app books without the column on a database that lacks it.

alter table public.ride_requests
  add column if not exists timezone text check (timezone is null or timezone ~ '^[A-Za-z0-9_+/-]{1,64}$');
