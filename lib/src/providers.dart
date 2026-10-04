import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/account_repository.dart';
import 'data/auth_repository.dart';
import 'data/geo_service.dart';
import 'data/models.dart';
import 'data/ride_repository.dart';

final supabaseProvider = Provider<SupabaseClient>((_) => Supabase.instance.client);

final authRepositoryProvider = Provider((ref) => AuthRepository(ref.watch(supabaseProvider)));
final rideRepositoryProvider = Provider((ref) => RideRepository(ref.watch(supabaseProvider)));
final accountRepositoryProvider = Provider((ref) => AccountRepository(ref.watch(supabaseProvider)));
final geoServiceProvider = Provider((_) => GeoService());

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
  return ref.watch(accountRepositoryProvider).profile();
});

final partnerProvider = FutureProvider<Partner?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
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
