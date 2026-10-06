-- 0104: a trip the driver ended before the drop-off.
--
-- Ending early stores the recalculated fare in ride_fare (the column the
-- trip is billed, rewarded and commissioned on) and stamps this, so the
-- receipts can say the trip ended early rather than passing the lower fare
-- off as the booked one. Clients without it degrade to the fare alone.
alter table public.ride_requests
  add column if not exists ended_early_at timestamptz;
