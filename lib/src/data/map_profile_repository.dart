// Admin → Settings → Maps (migration 0200), as the app reads it: this user's
// and this device's map profile from the `geo` function, kept on the device
// for the next start, and lookups through `geo` for providers with keys.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/map_profile.dart';
import '../providers.dart';
import 'live_tables.dart';
import 'notifications_repository.dart' show appModeProvider;

/// Calls the `geo` function for the signed-in mode (rider or partner) on
/// this kind of device. The client is looked up on first use, so building
/// one needs no backend.
class GeoProxy {
  GeoProxy(this._db, {required this.role, MapDevice? device}) : device = device ?? currentMapDevice();

  final SupabaseClient Function() _db;
  final String Function() role;
  final MapDevice device;

  /// The function's JSON answer for [params], or null when it gave none.
  /// Sent as a POST body to the function's bare URL: the same URL every
  /// time, so a browser asks its CORS preflight once and keeps it (PERF-74).
  Future<Map<String, dynamic>?> get(Map<String, String> params) async {
    final res = await _db().functions.invoke(
      'geo',
      method: HttpMethod.post,
      body: {...params, 'role': role(), 'device': device.name},
    );
    final data = res.data is String ? jsonDecode(res.data as String) : res.data;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }
}

/// 'rider' or 'partner', from the mode the app is in (rider until it says).
String mapRole(String? mode) => mode == 'partner' ? 'partner' : 'rider';

final geoProxyProvider = Provider<GeoProxy>(
  (ref) => GeoProxy(() => ref.read(supabaseProvider), role: () => mapRole(ref.read(appModeProvider))),
);

class MapProfileRepository {
  MapProfileRepository(this._proxy);
  final GeoProxy _proxy;

  static String prefsKey(String role, MapDevice device) => 'map_profile_v1:$role.${device.name}';

  /// The profile from `geo`; kept on the device for the next start.
  Future<MapProfile> fetch(String role) async {
    final body = await _proxy.get({'action': 'profile', 'role': role});
    if (body == null || body['profile'] is! Map) throw StateError('No map profile');
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(prefsKey(role, _proxy.device), jsonEncode(body));
    } catch (_) {}
    return MapProfile.fromJson(body);
  }

  /// The profile this device last had, or null.
  Future<MapProfile?> kept(String role) async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(prefsKey(role, _proxy.device));
      return s == null ? null : MapProfile.fromJson(jsonDecode(s));
    } catch (_) {
      return null;
    }
  }
}

final mapProfileRepositoryProvider = Provider((ref) => MapProfileRepository(ref.watch(geoProxyProvider)));

/// This user's and device's map profile, kept live; the one kept on the
/// device, else [MapProfile.builtIn], when `geo` can't be reached. Sets
/// [activeMapProfile] for the tile layers and [GeoService] ([applyMapProfile]).
final mapProfileProvider = FutureProvider<MapProfile>((ref) async {
  ref.watchLive('app_settings');
  final role = mapRole(ref.watch(appModeProvider));
  final repo = ref.watch(mapProfileRepositoryProvider);
  // What this device had last time draws at once while the current one is
  // asked for; the app's own map only when neither can be had.
  final kept = await repo.kept(role);
  if (kept != null && mapProfileListenable.value == null) applyMapProfile(kept);
  MapProfile profile;
  try {
    profile = await repo.fetch(role).timeout(const Duration(seconds: 8));
  } catch (_) {
    profile = kept ?? MapProfile.builtIn;
  }
  applyMapProfile(profile);
  return profile;
});
