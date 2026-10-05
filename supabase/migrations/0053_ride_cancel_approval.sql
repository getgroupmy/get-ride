-- Driver-approved ride cancellation.
--
-- Once a ride has started (status = 'on_trip'), the passenger can no longer
-- cancel unilaterally. Tapping X requests a cancellation instead:
--   - `cancel_requested_at` is stamped when the passenger asks to cancel
--   - the driver sees a popup and either accepts (status → 'cancelled')
--     or declines (`cancel_requested_at` cleared)
alter table public.ride_requests
  add column if not exists cancel_requested_at timestamptz,
  add column if not exists cancel_requested_by text;
