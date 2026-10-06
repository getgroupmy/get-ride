import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_display.dart';
import '../core/fare.dart';
import '../core/recent_places.dart';
import '../core/ride_services.dart';
import 'geo_service.dart';
import '../providers.dart';

/// The admin display settings the rider app honours (public read of
/// `admin_display_settings`, row `global`). Unreachable or missing means the
/// defaults: the service stays on and sign-up stays open.
final displaySettingsBlobProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from('admin_display_settings')
        .select('settings')
        .eq('id', 'global')
        .maybeSingle();
    final raw = row?['settings'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  } catch (_) {
    return const {};
  }
});

final appDisplayProvider = FutureProvider<AppDisplay>(
  (ref) async => AppDisplay.fromSettings(await ref.watch(displaySettingsBlobProvider.future)),
);

/// What the booking sheet offers: the admin Vehicle Services catalogue
/// (public read of `settings_entries`), arranged by Admin → Display. When the
/// catalogue cannot be read, the built-in list keeps booking working.
final rideServicesProvider = FutureProvider<List<RideService>>((ref) async {
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
