// Admin → Settings → Maps → Map appearance (see core/map_appearance.dart):
// read live by every app, saved by the admin.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/map_appearance.dart';
import '../providers.dart';
import 'app_display_repository.dart' show appSettingsReadTimeout;
import 'live_tables.dart';

/// The admin's map appearance (public read of `app_settings`
/// [mapAppearanceSettingKey]). Live: an admin's save re-reads it on every
/// open app. Unreachable keeps what this session (or, at launch, this
/// device) last read; nothing read is [MapAppearance.phone].
final mapAppearanceProvider = FutureProvider<MapAppearance>((ref) async {
  ref.watchLive('app_settings');
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from('app_settings')
        .select('value')
        .eq('key', mapAppearanceSettingKey)
        .maybeSingle()
        .timeout(appSettingsReadTimeout);
    final mode = _last = MapAppearance.fromJson(row?['value']);
    unawaited(_keep(mode));
    return mode;
  } catch (_) {
    return _last ?? MapAppearance.fromJson(await _kept());
  }
});

MapAppearance? _last;
const _keptKey = 'map_appearance_v1';

Future<String?> _kept() async {
  try {
    return (await SharedPreferences.getInstance()).getString(_keptKey);
  } catch (_) {
    return null;
  }
}

Future<void> _keep(MapAppearance m) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_keptKey, m.name);
  } catch (_) {}
}

/// Admin: saves [mode] for every app.
Future<void> saveMapAppearance(SupabaseClient db, MapAppearance mode) => db.from('app_settings').upsert({
  'key': mapAppearanceSettingKey,
  'value': mode.toJson(),
  'updated_at': DateTime.now().toUtc().toIso8601String(),
}, onConflict: 'key');

/// How the admin page saves the setting (overridden in tests).
final mapAppearanceSaverProvider = Provider<Future<void> Function(MapAppearance)>(
  (ref) => (mode) => saveMapAppearance(ref.read(supabaseProvider), mode),
);
