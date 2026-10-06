-- 0102: intermediate stops on a ride request.
--
-- First merged as 0098_ride_request_stops, the same version the migration
-- squash (getgroupmy/get-ride#69) gave its baseline; renumbered so every
-- version is unique again. Idempotent, so a database that already ran it
-- as 0098 (the live project did) is unaffected.
--
-- The Expo booking screen let a rider add stops between pickup and drop-off;
-- they changed the route and the fare, but were never stored on the request,
-- so the partner was paid for stops they had no way to know about. The
-- Flutter app now stores them here, in order, as
--   [{"name": text, "address": text, "lat": number, "lng": number}, ...]
-- (the final drop-off stays in drop_*). An empty array is a direct ride.
--
-- No policy change: the column rides on the existing ride_requests insert /
-- read policies, like every other request field. Clients that predate it
-- simply don't send it.

alter table public.ride_requests
  add column if not exists stops jsonb not null default '[]'::jsonb;

comment on column public.ride_requests.stops is
  'Intermediate stops between pickup and drop-off, in order: [{name, address, lat, lng}]. Migration 0102.';
