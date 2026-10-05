import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_display.dart';
import '../core/recent_places.dart';
import 'geo_service.dart';
import '../providers.dart';

/// The admin display settings the rider app honours (public read of
/// `admin_display_settings`, row `global`). Unreachable or missing means the
/// defaults: the service stays on and sign-up stays open.
final appDisplayProvider = FutureProvider<AppDisplay>((ref) async {
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from('admin_display_settings')
        .select('settings')
        .eq('id', 'global')
        .maybeSingle();
    return AppDisplay.fromSettings(row?['settings']);
  } catch (_) {
    return const AppDisplay();
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
