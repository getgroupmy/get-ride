-- 0246: drop indexes that went unused for a week of live traffic.
--
-- Stats from 13 to 20 Oct 2026: every index below had idx_scan = 0. Each
-- one is on a single column the planner never picks: a flag or a status
-- with a handful of values, or a jsonb geofence that region lookups no
-- longer read (they use boundary_polys since 0125). Each write still paid
-- to keep them.
--
-- Kept on purpose, though some are also unused so far:
-- * foreign-key columns (deleting a parent row scans them);
-- * unique and primary-key indexes, and partial indexes;
-- * user_location_history and user_sessions device_id / user_id /
--   captured_at / session (sign-up and device checks, admin views);
-- * ordering (position, created_at) and name/phone/plate lookups, which
--   start paying off as the tables grow;
-- * help_articles' full-text index.
--
-- Plain DROP INDEX: every table here is small, so the lock is brief.

drop index if exists public.user_sessions_event_idx;

drop index if exists public.countries_geofence_idx;
drop index if exists public.states_geofence_idx;
drop index if exists public.cities_geofence_idx;
drop index if exists public.suburbs_geofence_idx;

drop index if exists public.vmm_energy_type_idx;
drop index if exists public.vmm_vehicle_type_idx;
drop index if exists public.settings_entries_active_idx;
drop index if exists public.ip_access_rules_type_idx;
drop index if exists public.multi_gate_kind_idx;
drop index if exists public.meter_digital_settings_level_idx;

drop index if exists public.profiles_id_type_idx;
drop index if exists public.profiles_id_verified_idx;
drop index if exists public.profiles_profile_status_idx;
drop index if exists public.profiles_status_idx;

drop index if exists public.partners_permit_idx;
drop index if exists public.partners_status_idx;
drop index if exists public.vehicle_permit_idx;
drop index if exists public.vehicle_status_idx;
drop index if exists public.vehicles_permit_idx;
drop index if exists public.vehicles_status_idx;
drop index if exists public.vehicle_active_session_status_idx;
drop index if exists public.rides_status_idx;

drop index if exists public.support_calls_status_idx;
drop index if exists public.support_messages_status_idx;
drop index if exists public.support_tickets_status_idx;
