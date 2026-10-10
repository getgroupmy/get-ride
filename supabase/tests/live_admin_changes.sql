-- ============================================================================
-- Regression test for migrations 0135 and 0136: every table the app follows live
-- (lib/src/data/live_tables.dart: liveSettingTables and liveOwnTables) is in
-- the `supabase_realtime` publication, so an admin's change reaches running
-- apps without a relaunch.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/live_admin_changes.sql
--
-- Read-only. A failed assertion raises.
-- ============================================================================
do $$
declare
  t text;
  missing text[] := '{}';
begin
  foreach t in array array[
    'admin_display_settings', 'settings_entries', 'app_settings', 'app_branding',
    'meter_digital_settings', 'get_coin_settings', 'commission_rates', 'airport_areas',
    'multi_gate', 'ip_access_rules', 'admin_access', 'vehicle_make_models',
    'countries', 'states', 'cities', 'suburbs', 'fare_tariffs', 'get_coin_rate_history',
    'required_document', 'document_type', 'ev_vehicle_details', 'ev_vehicle_inventory',
    'ev_delivery_advisors', 'ev_finance_options', 'ev_order_fee', 'wallets',
    'profiles', 'partners', 'provider_documents', 'vehicle', 'vehicle_documents',
    'insurance_providers', 'insurance_types', 'insurance_durations', 'insurance_premium',
    'driver_incentive',
    -- Admin pages (liveAdminTables, migration 0136).
    'vehicle_user_assignment', 'ride_requests', 'support_tickets', 'push_notifications',
    'ev_orders', 'help_articles', 'help_questions', 'fare_ai_responses', 'fare_ai_key_states',
    'user_sessions'
  ] loop
    if to_regclass('public.' || t) is not null and not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      missing := missing || t;
    end if;
  end loop;
  if cardinality(missing) > 0 then
    raise exception 'FAILED: not in supabase_realtime, so not live: %', missing;
  end if;
end
$$;

select 'live_admin_changes: all passed';
