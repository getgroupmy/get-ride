-- ============================================================================
-- 0030_vehicle_photos.sql
--
-- Adds four photo columns to public.vehicle for the vehicle-onboarding
-- "Photos" step (Front / Left / Right / Back). Photos are stored in the
-- existing `vehicle-documents` storage bucket under `${vehicleId}/photos/`.
--
-- Safe to re-run.
-- ============================================================================

alter table public.vehicle
  add column if not exists image_front text,
  add column if not exists image_left  text,
  add column if not exists image_right text,
  add column if not exists image_back  text;

notify pgrst, 'reload schema';
