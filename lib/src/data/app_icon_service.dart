// The home-screen icon on this phone (core/app_icons.dart): the admin's
// settings, the passenger's choice, and the native switch (AppDelegate.swift
// AppIconPlugin, AppIconChannel.kt), applied at launch, on return to the app
// and when either setting changes.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_icons.dart';
import '../providers.dart';
import 'geo_service.dart';
import 'live_tables.dart';

/// The native side; null answers where there is none (web, desktop).
class AppIconPlatform {
  const AppIconPlatform();

  static const _channel = MethodChannel('get_ride/app_icon');

  bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  /// The icon on the home screen now, by id.
  Future<String?> current() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('current');
    } catch (_) {
      return null;
    }
  }

  /// Switches to [id]; false when the phone said no (iOS only switches while
  /// the app is on screen). Android switches once the app leaves the screen.
  Future<bool> set(String id) async {
    if (!supported) return false;
    try {
      await _channel.invokeMethod<void>('set', {'id': id});
      return true;
    } catch (_) {
      return false;
    }
  }
}

final appIconPlatformProvider = Provider<AppIconPlatform>((_) => const AppIconPlatform());

/// The admin's settings, live; the standard ones when they can't be read.
final appIconConfigProvider = FutureProvider<AppIconConfig>((ref) async {
  ref.watchLive('app_settings');
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from('app_settings')
        .select('value')
        .eq('key', appIconSettingKey)
        .maybeSingle();
    return AppIconConfig.fromJson(row?['value']);
  } catch (_) {
    return AppIconConfig.standard;
  }
});

/// Admin: saves the settings.
Future<void> saveAppIconConfig(SupabaseClient db, AppIconConfig c) => db.from('app_settings').upsert({
  'key': appIconSettingKey,
  'value': c.toJson(),
  'updated_at': DateTime.now().toUtc().toIso8601String(),
}, onConflict: 'key');

/// Settings → App icon: [automaticAppIcon] or an icon id, kept on the phone.
class AppIconChoiceNotifier extends Notifier<String> {
  static const _key = 'app_icon_choice';

  @override
  String build() {
    SharedPreferences.getInstance().then((p) {
      final v = p.getString(_key);
      if (v != null && (v == automaticAppIcon || appIconById(v) != null)) state = v;
    });
    return automaticAppIcon;
  }

  Future<void> set(String choice) async {
    state = choice;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, choice);
  }
}

final appIconChoiceProvider = NotifierProvider<AppIconChoiceNotifier, String>(AppIconChoiceNotifier.new);

/// Where the phone is, as region names (state, country), for icons the
/// admin limits to a region; empty when location is off or unknown.
final appIconRegionsProvider = FutureProvider<Set<String>>((ref) async {
  final at = await knownPosition();
  if (at == null) return const {};
  try {
    final regions = await ref.read(rideRepositoryProvider).biddingRegions(at: at);
    return {
      for (final r in regions) ...[r.country, r.state, r.city],
    }..removeWhere((n) => n.trim().isEmpty);
  } catch (_) {
    return const {};
  }
});

/// The icon this phone should show now.
String wantedAppIcon(Ref ref, {DateTime? now}) => chosenAppIcon(
  ref.read(appIconConfigProvider).value ?? AppIconConfig.standard,
  now ?? DateTime.now(),
  userChoice: ref.read(appIconChoiceProvider),
  regions: ref.read(appIconRegionsProvider).value ?? const {},
);

/// Keeps the home-screen icon on [wantedAppIcon]: [sync] at launch and on
/// return to the app; the settings changing syncs too. Asks the phone only
/// when the icon differs (iOS shows an alert each time).
class AppIconSync {
  AppIconSync(this._ref) {
    _ref.listen(appIconConfigProvider, (_, _) => unawaited(sync()));
    _ref.listen(appIconChoiceProvider, (_, _) => unawaited(sync()));
    _ref.listen(appIconRegionsProvider, (_, _) => unawaited(sync()));
  }

  final Ref _ref;
  Future<void>? _running;
  bool _again = false;

  /// One at a time; a call while one runs runs once more after it.
  Future<void> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = () async {
      do {
        _again = false;
        await _sync();
      } while (_again);
    }().whenComplete(() => _running = null);
  }

  Future<void> _sync() async {
    final platform = _ref.read(appIconPlatformProvider);
    if (!platform.supported) return;
    // Settings not read yet: wait for them rather than switch twice.
    if (_ref.read(appIconConfigProvider).isLoading) return;
    final want = wantedAppIcon(_ref);
    if (await platform.current() == want) return;
    await platform.set(want);
  }
}

final appIconSyncProvider = Provider<AppIconSync>(AppIconSync.new);
