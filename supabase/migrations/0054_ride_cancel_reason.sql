-- Rider cancellation reason.
--
-- The partner (driver) side already collects a reason when cancelling an
-- order. This adds a `cancel_reason` column so the rider side can store the
-- reason too — both for direct cancellations (before the trip starts) and
-- driver-approved cancellation requests (after pickup).
alter table public.ride_requests
  add column if not exists cancel_reason text;
