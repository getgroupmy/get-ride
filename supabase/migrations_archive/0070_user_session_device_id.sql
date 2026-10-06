-- ============================================================================
-- 0070_user_session_device_id.sql
-- Adds a stable per-device identifier to user_sessions and
-- user_location_history so admins can correlate sessions and location pings
-- back to a physical device, independent of the signed-in user/phone.
--
-- Populated client-side (SessionTrackingContext.tsx) as:
--   - Android: Application.androidId (ANDROID_ID)
--   - iOS    : Application.getIosIdForVendorAsync() (identifierForVendor)
--   - other  : a client-generated UUID persisted in AsyncStorage
-- ============================================================================

alter table public.user_sessions
  add column if not exists device_id text;

alter table public.user_location_history
  add column if not exists device_id text;

create index if not exists user_sessions_device_id_idx
  on public.user_sessions (device_id);

create index if not exists user_location_history_device_id_idx
  on public.user_location_history (device_id);
