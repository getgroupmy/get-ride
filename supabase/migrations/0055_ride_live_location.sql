-- Live location sharing during an active ride (0055).
--
-- The partner app continuously publishes the driver's real GPS position
-- (plus heading) onto the ride request row, and the passenger app publishes
-- the rider's position. Each side subscribes to the row via realtime and
-- moves the corresponding map marker, so both screens show true live
-- movement instead of a local animation.

alter table public.ride_requests
  add column if not exists partner_live_lat     double precision,
  add column if not exists partner_live_lng     double precision,
  add column if not exists partner_live_heading double precision,
  add column if not exists partner_live_at      timestamptz,
  add column if not exists user_live_lat        double precision,
  add column if not exists user_live_lng        double precision,
  add column if not exists user_live_at         timestamptz;
