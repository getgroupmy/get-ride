-- ============================================================================
-- 0049_user_session_network_details.sql
-- Adds detailed network/connection metadata columns to user_sessions:
--   - connection_type       : explicit connection medium (wifi / mobile / ethernet / other)
--   - isp_provider          : ISP name (WiFi) or mobile carrier/provider name
--   - iccid                 : SIM card ICCID (best-effort, Android only)
--   - mobile_operator_name  : mobile network operator (distinct from isp_provider
--                             so dual-SIM / roaming scenarios can be captured)
-- ============================================================================

alter table public.user_sessions
  add column if not exists connection_type      text,
  add column if not exists isp_provider         text,
  add column if not exists iccid                text,
  add column if not exists mobile_operator_name text;
