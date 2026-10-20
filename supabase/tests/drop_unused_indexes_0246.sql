-- ============================================================================
-- Regression test for migration 0246: the unused single-column indexes are
-- gone, and the ones kept on purpose are still there.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/drop_unused_indexes_0246.sql
--
-- Read-only. A failed assertion raises.
-- ============================================================================
do $$
declare
  left_over text;
  missing text;
begin
  select string_agg(i, ', ') into left_over
    from unnest(array[
      'user_sessions_event_idx',
      'countries_geofence_idx', 'states_geofence_idx', 'cities_geofence_idx', 'suburbs_geofence_idx',
      'vmm_energy_type_idx', 'vmm_vehicle_type_idx', 'settings_entries_active_idx',
      'ip_access_rules_type_idx', 'multi_gate_kind_idx', 'meter_digital_settings_level_idx',
      'profiles_id_type_idx', 'profiles_id_verified_idx', 'profiles_profile_status_idx', 'profiles_status_idx',
      'partners_permit_idx', 'partners_status_idx', 'vehicle_permit_idx', 'vehicle_status_idx',
      'vehicles_permit_idx', 'vehicles_status_idx', 'vehicle_active_session_status_idx', 'rides_status_idx',
      'support_calls_status_idx', 'support_messages_status_idx', 'support_tickets_status_idx'
    ]) as i
   where to_regclass('public.' || i) is not null;
  if left_over is not null then
    raise exception 'FAILED: still there after 0246: %', left_over;
  end if;

  -- Kept: sign-up and device checks, and the admin views read these. Only
  -- the ones every replay creates are checked.
  select string_agg(i, ', ') into missing
    from unnest(array['user_sessions_captured_idx']) as i
   where to_regclass('public.' || i) is null;
  if missing is not null then
    raise exception 'FAILED: 0246 dropped an index it keeps: %', missing;
  end if;
end $$;

select 'drop_unused_indexes_0246: all passed';
