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
    'user_sessions', 'safety_incidents',
    -- Sign-in SMS limits (migration 0149).
    'sms_settings', 'sms_log',
    -- SMS fallback for trips (migration 0150).
    'sms_fallback_settings',
    -- Lost item reports (migration 0154).
    'ride_lost_items',
    -- Scheduled rides (migration 0189).
    'scheduled_rides',
    -- Handovers and passengers' choices of driver (migration 0198).
    'scheduled_ride_offers',
    -- Mid-trip handovers (migration 0199).
    'trip_handovers', 'trip_handover_candidates',
    -- EV profiles for the OBD-II reader (migration 0202).
    'ev_profiles',
    -- Commission promotions (migration 0224).
    'commission_promotions',
    -- Rider promo codes and redemptions (migration 0242).
    'promo_codes',
    'promo_redemptions',
    -- Commission tiers (migration 0218; followed by the app since 0229).
    'commission_tiers',
    -- Claude Code access (migration 0228).
    'claude_access_rules',
    -- Airports' settings, waiting zones and fare zones (migration 0249).
    'airport_settings', 'airport_waiting_zones', 'airport_fare_zones', 'vehicle_service_order',
    -- The service order for every booking (migration 0250).
    'service_order_settings',
    -- Ride Options by place, and the extras each driver takes (migration 0253).
    'ride_option_places', 'driver_ride_extras',
    -- Partner type services (migration 0259).
    'partner_type_services',
    -- Driver services: switches per car, locks and their log (migration 0263).
    'driver_service_prefs', 'driver_service_locks', 'driver_service_lock_events',
    -- Place types (migration 0264).
    'place_types',
    -- Places inside an airport (migration 0266).
    'area_precedence_settings',
    -- Freight: the recipients' tracking link notices (migration 0267).
    'freight_recipient_notices',
    -- City ride cancel and no-show rules by place (migration 0269).
    'ride_cancel_places',
    -- The Media Gallery's uploads (migration 0273).
    'media_assets',
    -- City to City: settings, permits by country, route rules; commission per service (migration 0306).
    'city_to_city_settings', 'c2c_country_permits', 'c2c_route_rules', 'commission_service_rates',
    -- City to City bookings and offers (migration 0307).
    'c2c_bookings', 'c2c_offers',
    -- City to City give-up and in-app payment rules, give-up fees owed (migration 0309).
    'c2c_giveup_rules', 'c2c_pay_rules', 'c2c_driver_fees',
    -- City to City per-seat rules and the trips drivers post (migration 0310).
    'c2c_seat_rules', 'c2c_trips',
    -- Ride safety: settings, report categories, passenger cover, rider blocks (migration 0311).
    'ride_safety_settings', 'trip_report_categories', 'passenger_cover_rules', 'rider_blocks',
    -- Freight and Courier add-ons: the rules and cover claims (migration 0312).
    'delivery_addon_rules', 'cover_claims',
    -- City ride extras by place, and tips on the driver's trip card (migration 0314).
    'city_ride_extra_places', 'ride_tips',
    -- Premium service rules and GET.Plus by place (migration 0316).
    'premium_plus_places'
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
