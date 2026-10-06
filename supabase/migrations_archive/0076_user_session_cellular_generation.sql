-- ============================================================================
-- 0076_user_session_cellular_generation.sql
-- Adds the cellular connection generation ("SIM type") to user_sessions:
--   - cellular_generation : the radio generation the SIM is connected on
--                           ("2G" / "3G" / "4G" / "5G"), or null when unknown /
--                           not on cellular (WiFi, web).
--
-- Populated client-side (SessionTrackingContext.tsx) via expo-cellular's
-- Cellular.getCellularGenerationAsync().
--
-- NOTE: the SIM card serial number (ICCID) is intentionally NOT captured — the
-- OS blocks it (iOS never exposed it; Android 10+ gates getSimSerialNumber()
-- behind the system-only READ_PRIVILEGED_PHONE_STATE permission), so the
-- long-standing `iccid` column (migration 0049) stays null on real devices.
--
-- Safe to re-run.
-- ============================================================================

alter table public.user_sessions
  add column if not exists cellular_generation text;
