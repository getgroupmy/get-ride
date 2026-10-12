// The Reliability switches (lib/src/core/reliability_settings.dart): read by
// every app, live; written by the admin.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ble_handshake.dart';
import '../core/reliability_settings.dart';
import '../core/trip_safety.dart';
import '../providers.dart';
import 'live_tables.dart';

/// Kept on the phone for the push background handler, which runs with
/// nothing of the app started.
const backgroundAckPrefsKey = 'reliability_background_ack_v1';

class ReliabilityRepository {
  ReliabilityRepository(this._db);
  final SupabaseClient _db;

  Future<ReliabilitySettings> fetch() async {
    final row = await _db
        .from('settings_entries')
        .select('values')
        .eq('category', reliabilityCategory)
        .eq('id', reliabilityRowId)
        .maybeSingle();
    final values = row?['values'];
    return ReliabilitySettings.fromValues(values is Map ? Map<String, dynamic>.from(values) : null);
  }

  Future<void> save(ReliabilitySettings s) => _db.from('settings_entries').upsert({
    'id': reliabilityRowId,
    'category': reliabilityCategory,
    'values': s.toValues(),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  }, onConflict: 'id');

  /// How trips started lately (ble_start_stats, 0153; admins only).
  Future<BleStartStats> bleStats(int days) async =>
      BleStartStats.fromRow(await _db.rpc('ble_start_stats', params: {'p_days': days}));

  /// What the trip safety signals did lately (trip_safety_summary, 0154).
  Future<TripSafetySummary> safetySummary(int days) async =>
      TripSafetySummary.fromRow(await _db.rpc('trip_safety_summary', params: {'p_days': days}));
}

final reliabilityRepositoryProvider = Provider((ref) => ReliabilityRepository(ref.watch(supabaseProvider)));

/// The switches as the admin last set them; all on when unreadable.
final reliabilitySettingsProvider = FutureProvider<ReliabilitySettings>((ref) async {
  ref.watchLive('settings_entries');
  ReliabilitySettings s;
  try {
    s = await ref.watch(reliabilityRepositoryProvider).fetch();
  } catch (_) {
    s = const ReliabilitySettings();
  }
  unawaited(_mirrorBackgroundAck(s.backgroundAck));
  return s;
});

/// How trips started in the last 7 days, for the Reliability card.
final bleStartStatsProvider = FutureProvider.autoDispose<BleStartStats>(
  (ref) => ref.watch(reliabilityRepositoryProvider).bleStats(7),
);

/// What the trip safety signals did in the last 7 days, for the Reliability card.
final tripSafetySummaryProvider = FutureProvider.autoDispose<TripSafetySummary>(
  (ref) => ref.watch(reliabilityRepositoryProvider).safetySummary(7),
);

/// The switches now, without waiting: all on until they have loaded.
final reliabilityProvider = Provider<ReliabilitySettings>(
  (ref) => ref.watch(reliabilitySettingsProvider).value ?? const ReliabilitySettings(),
);

Future<void> _mirrorBackgroundAck(bool on) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(backgroundAckPrefsKey) != on) await prefs.setBool(backgroundAckPrefsKey, on);
  } catch (_) {}
}
