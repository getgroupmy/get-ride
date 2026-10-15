import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/navigation_app.dart';
import 'data/account_repository.dart';
import 'data/auth_repository.dart';
import 'data/geo_service.dart';
import 'data/live_tables.dart';
import 'data/models.dart';
import 'data/reliability_repository.dart';
import 'data/ride_repository.dart';
import 'data/map_profile_repository.dart' show geoProxyProvider;

final supabaseProvider = Provider<SupabaseClient>((_) => Supabase.instance.client);

final authRepositoryProvider = Provider((ref) => AuthRepository(ref.watch(supabaseProvider)));
final rideRepositoryProvider = Provider((ref) {
  final repo = RideRepository(ref.watch(supabaseProvider));
  // Admin → Reliability, applied live.
  ref.listen(reliabilityProvider, (_, s) => repo.useOfflineCopy = s.rideCache, fireImmediately: true);
  // An admin's change to a region drops the kept regions on every screen,
  // so they can be kept for minutes rather than re-read every few seconds.
  ref.listen(liveTablesProvider.select((r) => liveStamp(r, liveRegionTables)), (_, _) => repo.forgetRegions());
  return repo;
});
final accountRepositoryProvider = Provider((ref) => AccountRepository(ref.watch(supabaseProvider)));
// Lookups through `geo` for the providers Admin → Settings → Maps puts first.
final geoServiceProvider = Provider((ref) => GeoService(lookup: (p) => ref.read(geoProxyProvider).get(p)));

/// Emits whenever the Supabase session changes.
final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

/// Current user id, kept in sync with [authStateProvider].
final currentUserIdProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser?.id;
});

final profileProvider = FutureProvider<Profile?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  // An admin's change to the account (block, verify, edit) shows at once.
  ref.watchLive('profiles');
  return ref.watch(accountRepositoryProvider).profile();
});

final partnerProvider = FutureProvider<Partner?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  // An admin approving, rejecting or blocking the partner shows at once.
  ref.watchLive('partners');
  try {
    return await ref.watch(accountRepositoryProvider).partner();
  } catch (_) {
    return null;
  }
});

/// Light / dark / system, persisted per device.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    SharedPreferences.getInstance().then((p) {
      final v = p.getString(_key);
      if (v != null) state = ThemeMode.values.byName(v);
    });
    return ThemeMode.system;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// The app the driver's Navigate button opens, persisted per device.
class NavigationAppNotifier extends Notifier<NavigationApp> {
  static const _key = 'navigation_app';

  @override
  NavigationApp build() {
    SharedPreferences.getInstance().then((p) {
      final v = p.getString(_key);
      if (v != null) state = NavigationApp.fromName(v);
    });
    return NavigationApp.google;
  }

  Future<void> set(NavigationApp app) async {
    state = app;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, app.name);
  }
}

final navigationAppProvider = NotifierProvider<NavigationAppNotifier, NavigationApp>(NavigationAppNotifier.new);

/// Settings → Show location to your driver: whether the passenger's live
/// position goes to the driver on the way to them. On unless turned off.
class ShowLocationToDriverNotifier extends Notifier<bool> {
  static const _key = 'show_location_to_driver';

  @override
  bool build() {
    SharedPreferences.getInstance().then((p) {
      final v = p.getBool(_key);
      if (v != null) state = v;
    });
    return true;
  }

  Future<void> set(bool on) async {
    state = on;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key, on);
  }
}

final showLocationToDriverProvider = NotifierProvider<ShowLocationToDriverNotifier, bool>(
  ShowLocationToDriverNotifier.new,
);

/// The rides the passenger turned location sharing off for, just those
/// rides (the trip map's button, "Only this ride"); the setting above
/// stays as it is. Kept on the phone, so closing the app mid-ride keeps the
/// choice; only the most recent [keep] rides are remembered.
class RideLocationOffNotifier extends Notifier<Set<String>> {
  static const _key = 'ride_location_off';
  static const keep = 20;

  @override
  Set<String> build() {
    SharedPreferences.getInstance().then((p) {
      final saved = p.getStringList(_key);
      // Merged: a choice made before the phone's copy has loaded stays.
      if (saved != null && saved.isNotEmpty) state = {...saved, ...state};
    });
    return const {};
  }

  Future<void> turnOff(String rideId) => _save(
    {...state}
      ..remove(rideId)
      ..add(rideId),
  );

  Future<void> turnOn(String rideId) => _save({...state}..remove(rideId));

  Future<void> _save(Set<String> rides) async {
    final list = rides.toList();
    state = list.skip(list.length > keep ? list.length - keep : 0).toSet();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, state.toList());
  }
}

final rideLocationOffProvider = NotifierProvider<RideLocationOffNotifier, Set<String>>(RideLocationOffNotifier.new);

/// Whether this ride shares the passenger's position with the driver now:
/// the setting on, and not turned off for this ride.
bool locationSharedFor(WidgetRef ref, String rideId, {bool watch = false}) {
  final on = watch ? ref.watch(showLocationToDriverProvider) : ref.read(showLocationToDriverProvider);
  final off = watch ? ref.watch(rideLocationOffProvider) : ref.read(rideLocationOffProvider);
  return on && !off.contains(rideId);
}
