-- ============================================================================
-- 0050_user_session_ip_isp_lookup.sql
-- Adds server-resolved public IP + ISP geolocation columns to user_sessions.
--
-- The device's `ip_address` is the LAN/local IP and cannot reveal the ISP.
-- These columns are populated by the `ip-lookup` edge function, which reads the
-- caller's PUBLIC IP from request headers and resolves it via an IP geo service.
--   - public_ip   : the public/egress IP the server observed
--   - isp_org     : organization / AS owner for the IP
--   - ip_city     : city resolved from the public IP
--   - ip_region   : region/state resolved from the public IP
--   - ip_country  : country resolved from the public IP
-- (the existing `isp_provider` column is reused to store the resolved ISP name)
-- ============================================================================

alter table public.user_sessions
  add column if not exists public_ip  text,
  add column if not exists isp_org    text,
  add column if not exists ip_city    text,
  add column if not exists ip_region  text,
  add column if not exists ip_country text;
