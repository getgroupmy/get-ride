// Admin → Settings → Maps (migration 0200): reading and saving the setting,
// usage per provider, and the keys Admin → API Keys holds.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/live_tables.dart';
import '../../../providers.dart';
import '../../../data/function_region.dart';
import '../security/api_keys_logic.dart';
import '../security/security_data.dart';
import 'maps_logic.dart';

/// The server's refusal as one sentence (its hint, when it gives one).
class MapSettingsError implements Exception {
  const MapSettingsError(this.message);
  final String message;

  static Object wrap(Object e) =>
      e is PostgrestException && (e.hint ?? '').trim().isNotEmpty ? MapSettingsError(e.hint!.trim()) : e;

  @override
  String toString() => message;
}

/// One provider's calls through `geo` over the period.
class MapUsageRow {
  const MapUsageRow({
    required this.provider,
    required this.kind,
    required this.calls,
    required this.cached,
    required this.failures,
  });

  final String provider;
  final String kind;
  final int calls;
  final int cached;
  final int failures;

  factory MapUsageRow.fromRow(Map<String, dynamic> r) {
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
    return MapUsageRow(
      provider: '${r['provider'] ?? ''}',
      kind: '${r['kind'] ?? ''}',
      calls: n(r['calls']),
      cached: n(r['cached']),
      failures: n(r['failures']),
    );
  }
}

/// One failed call through `geo` (migration 0209): when, for whom and why.
@immutable
class MapErrorRow {
  const MapErrorRow({required this.id, required this.at, required this.detail, this.role, this.device});

  final int id;
  final DateTime at;
  final String detail;
  final String? role;
  final String? device;

  factory MapErrorRow.fromRow(Map<String, dynamic> r) => MapErrorRow(
    id: r['id'] is num ? (r['id'] as num).toInt() : int.tryParse('${r['id']}') ?? 0,
    at: DateTime.tryParse('${r['at']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    detail: '${r['detail'] ?? ''}',
    role: r['role'] as String?,
    device: r['device'] as String?,
  );
}

class MapsRepository {
  MapsRepository(this._db);
  final SupabaseClient _db;

  Future<MapSettings> load() async => MapSettings.fromJson(await _db.rpc('map_config'));

  /// Saves, and returns the setting as stored (cleaned).
  Future<MapSettings> save(MapSettings s) async {
    try {
      return MapSettings.fromJson(await _db.rpc('set_map_config', params: {'p_config': s.toJson()}));
    } catch (e) {
      throw MapSettingsError.wrap(e);
    }
  }

  /// The key slots `geo` has a secret for (synced from GitHub), names only;
  /// empty when it can't say.
  Future<Set<String>> fallbackSlots() async {
    try {
      final res = await _db.functions.invokeNearDb(
        'geo',
        method: HttpMethod.get,
        queryParameters: const {'action': 'fallbacks'},
      );
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      final slots = data is Map ? data['slots'] : null;
      return slots is List ? {for (final s in slots) '$s'} : const {};
    } catch (_) {
      return const {};
    }
  }

  /// [provider]'s [kind] failures, newest first: [limit] older than [before]
  /// (an id; null for the newest).
  Future<List<MapErrorRow>> errors(String provider, String kind, {int? before, int limit = 30}) async => [
    for (final r
        in await _db.rpc(
              'map_errors',
              params: {'p_provider': provider, 'p_kind': kind, 'p_before': before, 'p_limit': limit},
            )
            as List)
      MapErrorRow.fromRow(Map<String, dynamic>.from(r as Map)),
  ];

  Future<List<MapUsageRow>> usage({int days = 30}) async => [
    for (final r in await _db.rpc('map_usage', params: {'p_days': days}) as List)
      MapUsageRow.fromRow(Map<String, dynamic>.from(r as Map)),
  ];
}

final mapsRepositoryProvider = Provider((ref) => MapsRepository(ref.watch(supabaseProvider)));

final adminMapSettingsProvider = FutureProvider.autoDispose<MapSettings>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(mapsRepositoryProvider).load();
});

final adminMapUsageProvider = FutureProvider.autoDispose<List<MapUsageRow>>(
  (ref) => ref.watch(mapsRepositoryProvider).usage(),
);

/// Admin → API Keys' providers (to pick each map provider's key).
final adminMapApiKeysProvider = FutureProvider.autoDispose<List<ApiProviderDef>>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(securityRepositoryProvider).apiProviders();
});

/// Key slots with a GitHub-synced secret on `geo` (see sync-map-keys.yml).
final adminMapFallbackSlotsProvider = FutureProvider.autoDispose<Set<String>>(
  (ref) => ref.watch(mapsRepositoryProvider).fallbackSlots(),
);
