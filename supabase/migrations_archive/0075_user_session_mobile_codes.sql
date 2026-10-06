-- ============================================================================
-- 0075_user_session_mobile_codes.sql
-- Adds the SIM's numeric mobile country/network codes (MCC / MNC) to
-- user_sessions. Together they form the PLMN id that identifies the SIM's home
-- operator, independent of the carrier NAME (which iOS 16+ no longer exposes).
--
-- Populated client-side (SessionTrackingContext.tsx) via expo-cellular:
--   - mobile_country_code : Cellular.getMobileCountryCodeAsync()  (e.g. "502")
--   - mobile_network_code : Cellular.getMobileNetworkCodeAsync()  (e.g. "12")
-- Both stay null on web and on iOS 16+ (the OS returns a "65535" placeholder
-- which the client normalizes to null before insert).
--
-- Safe to re-run.
-- ============================================================================

alter table public.user_sessions
  add column if not exists mobile_country_code text,
  add column if not exists mobile_network_code text;
