import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/screens/meterapp/display_logic.dart' show displaySettingsTable, displaySettingsRowId;
import '../core/app_display.dart';
import '../core/fare.dart';
import '../core/recent_places.dart';
import '../core/ride_services.dart';
import 'geo_service.dart';
import 'live_tables.dart';
import '../providers.dart';

/// The admin display settings the rider app honours (public read of
/// `admin_display_settings`, row `global`). Unreachable or missing means the
/// defaults: the service stays on and sign-up stays open. Live: an admin's
/// change re-reads it on every open app (see `live_tables.dart`).
final displaySettingsBlobProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watchLive(displaySettingsTable);
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from(displaySettingsTable)
        .select('settings')
        .eq('id', displaySettingsRowId)
        .maybeSingle();
    return displaySettingsFromRow(row);
  } catch (_) {
    return const {};
  }
});

/// The settings blob off a row, or the defaults (empty) without one.
Map<String, dynamic> displaySettingsFromRow(Map<String, dynamic>? row) {
  final raw = row?['settings'];
  return raw is Map ? Map<String, dynamic>.from(raw) : const {};
}

final appDisplayProvider = FutureProvider<AppDisplay>(
  (ref) async => AppDisplay.fromSettings(await ref.watch(displaySettingsBlobProvider.future)),
);

/// What the booking sheet offers: the admin Vehicle Services catalogue
/// (public read of `settings_entries`), arranged by Admin → Display. When the
/// catalogue cannot be read, the built-in list keeps booking working.
final rideServicesProvider = FutureProvider<List<RideService>>((ref) async {
  ref.watchLive('settings_entries');
  final display = await ref.watch(displaySettingsBlobProvider.future);
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('settings_entries')
        .select('id, values, position')
        .eq('category', 'vehicle-services')
        .order('position');
    final entries = [
      for (final r in rows)
        (id: '${r['id']}', values: r['values'] is Map ? Map<String, dynamic>.from(r['values'] as Map) : <String, dynamic>{}),
    ];
    return rideServicesFromCatalogue(entries, display);
  } catch (_) {
    return rideServices;
  }
});

/// The rider's recent destinations for the place picker, as many as Admin →
/// Display allows. Empty when switched off, signed out or unreachable.
final recentPlacesProvider = FutureProvider.autoDispose<List<Place>>((ref) async {
  final display = await ref.watch(appDisplayProvider.future);
  if (!display.recentLocations || display.recentLocationsCount == 0) return const [];
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  try {
    final rides = await ref.watch(rideRepositoryProvider).history(limit: 40);
    return recentPlaces(rides, riderId: uid, max: display.recentLocationsCount);
  } catch (_) {
    return const [];
  }
});

/// Names of the admin services a home service box can be linked to (public
/// read of `settings_entries`, category `service-settings`), by entry id.
final serviceBoxNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  ref.watchLive('settings_entries');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('settings_entries')
        .select('id, values')
        .eq('category', 'service-settings');
    return {
      for (final r in rows)
        if (r['values'] is Map && '${(r['values'] as Map)['name'] ?? ''}'.trim().isNotEmpty)
          '${r['id']}': '${(r['values'] as Map)['name']}'.trim(),
    };
  } catch (_) {
    return const {};
  }
});
