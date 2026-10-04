/// Supabase + OpenStreetMap access for the Geography admin screens. Mirrors
/// `fetchRegions` / `upsertRegion` / `deleteRegion` and the dedicated /
/// kind-table branches of `upsertSetting` / `deleteSetting` in the Expo
/// `utils/adminSync.ts`, so both apps read and write identical rows.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../providers.dart';
import 'geo_logic.dart';

/// A `{id, values, position}` row of `airport_areas` / `multi_gate`.
class GeoEntry {
  GeoEntry({required this.id, required this.values, this.position = 0});
  factory GeoEntry.fromRow(Map<String, dynamic> r) => GeoEntry(
        id: r['id'] as String,
        values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {}),
        position: (r['position'] as num?)?.toInt() ?? 0,
      );
  final String id;
  final Map<String, dynamic> values;
  final int position;
}

class GeoAdminRepository {
  GeoAdminRepository(this._db);
  final SupabaseClient _db;
  static const _uuid = Uuid();

  // Regions ------------------------------------------------------------------

  static const _regionSelects = {
    RegionLevel.country: 'id, name, values, geofence, position',
    RegionLevel.state: 'id, country, name, values, geofence, position',
    RegionLevel.city: 'id, country, state, name, values, geofence, position',
    RegionLevel.suburb: 'id, country, state, city, name, values, geofence, position',
  };

  /// All four region tables merged into one list (Expo `fetchRegions`). A
  /// failing table is skipped like Expo does, unless every table fails.
  Future<List<RegionEntry>> regions() async {
    final out = <RegionEntry>[];
    Object? firstError;
    var failures = 0;
    final results = await Future.wait(RegionLevel.values.map((l) async {
      try {
        final rows = await _db.from(regionTables[l]!).select(_regionSelects[l]!).order('position');
        return (l, List<Map<String, dynamic>>.from(rows));
      } catch (e) {
        firstError ??= e;
        failures++;
        return (l, <Map<String, dynamic>>[]);
      }
    }));
    if (failures == RegionLevel.values.length && firstError != null) throw firstError!;
    for (final (level, rows) in results) {
      out.addAll(rows.map((r) => regionEntryFromRow(r, level)));
    }
    return out;
  }

  /// Expo `upsertRegion`: removes the id from the other level tables (a row
  /// can be re-classified), then upserts on the level's natural key.
  Future<void> saveRegion({String? id, required Map<String, dynamic> values, int position = 0}) async {
    final rowId = id ?? _uuid.v4();
    final up = regionUpsert(rowId, values, position: position);
    if (up == null) throw StateError('Please choose or enter a country.');
    for (final t in regionTables.values) {
      if (t == up.table) continue;
      await _db.from(t).delete().eq('id', rowId);
    }
    await _db.from(up.table).upsert(up.row, onConflict: up.onConflict);
  }

  /// Expo `deleteRegion`: the id may live in any of the four tables.
  Future<void> deleteRegion(String id) async {
    await Future.wait(regionTables.values.map((t) => _db.from(t).delete().eq('id', id)));
  }

  /// `service-settings` entries for the per-region services switches.
  Future<List<ServiceOption>> services() async {
    final rows = await _db
        .from('settings_entries')
        .select('id, values, position')
        .eq('category', 'service-settings')
        .order('position');
    return sortServices([
      for (final r in rows)
        (id: r['id'] as String, values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {})),
    ]);
  }

  // Airport areas ------------------------------------------------------------

  Future<List<GeoEntry>> airports() async =>
      (await _db.from('airport_areas').select('id, values, position').order('position')).map(GeoEntry.fromRow).toList();

  Future<void> saveAirport({String? id, required Map<String, dynamic> values, int position = 0}) => _db
      .from('airport_areas')
      .upsert({'id': id ?? _uuid.v4(), 'values': values, 'position': position}, onConflict: 'id');

  Future<void> deleteAirport(String id) => _db.from('airport_areas').delete().eq('id', id);

  // Multi-gate (kind 'place' / 'gate') ---------------------------------------

  Future<List<GeoEntry>> multiGate(String kind) async =>
      (await _db.from('multi_gate').select('id, values, position').eq('kind', kind).order('position'))
          .map(GeoEntry.fromRow)
          .toList();

  Future<void> saveMultiGate(String kind, {String? id, required Map<String, dynamic> values, int position = 0}) =>
      _db.from('multi_gate').upsert(
        {'id': id ?? _uuid.v4(), 'kind': kind, 'values': values, 'position': position},
        onConflict: 'id',
      );

  Future<void> deleteMultiGate(String kind, String id) =>
      _db.from('multi_gate').delete().eq('id', id).eq('kind', kind);
}

final geoAdminRepositoryProvider = Provider((ref) => GeoAdminRepository(ref.watch(supabaseProvider)));

final regionsProvider = FutureProvider.autoDispose((ref) => ref.watch(geoAdminRepositoryProvider).regions());
final regionServicesProvider = FutureProvider.autoDispose<List<ServiceOption>>((ref) async {
  try {
    return await ref.watch(geoAdminRepositoryProvider).services();
  } catch (_) {
    return const [];
  }
});
final airportsProvider = FutureProvider.autoDispose((ref) => ref.watch(geoAdminRepositoryProvider).airports());
final multiGatePlacesProvider =
    FutureProvider.autoDispose((ref) => ref.watch(geoAdminRepositoryProvider).multiGate('place'));
final multiGateGatesProvider =
    FutureProvider.autoDispose((ref) => ref.watch(geoAdminRepositoryProvider).multiGate('gate'));

/// OpenStreetMap Nominatim lookups the shared `GeoService` doesn't cover:
/// boundary polygons (`polygon_geojson`) and worldwide searches with address
/// components. Same endpoint override (`NOMINATIM_URL`) and headers as
/// `GeoService`; no API key involved.
class OsmLookup {
  OsmLookup({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;

  static const _nominatim = String.fromEnvironment(
    'NOMINATIM_URL',
    defaultValue: 'https://nominatim.openstreetmap.org',
  );

  Map<String, String> get _headers => kIsWeb
      ? const {'Accept-Language': 'en'}
      : const {'User-Agent': 'GET.ride Flutter (getgroup.my)', 'Accept-Language': 'en'};

  Future<Object?> _get(String path, Map<String, String> params) async {
    final res = await _http.get(Uri.parse('$_nominatim/$path').replace(queryParameters: params), headers: _headers);
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body);
  }

  /// Expo `fetchOsmCandidates` (optionally bounded to ±[radiusDeg] of [near]).
  Future<List<BoundaryCandidate>> boundaries(String query, {int limit = 10, LatLng? near, double radiusDeg = 0.5}) async {
    try {
      final data = await _get('search', {
        'format': 'json',
        'polygon_geojson': '1',
        'limit': '${limit.clamp(1, 50)}',
        'q': query,
        if (near != null) ...{
          'viewbox':
              '${near.longitude - radiusDeg},${near.latitude + radiusDeg},${near.longitude + radiusDeg},${near.latitude - radiusDeg}',
          'bounded': '1',
        },
      });
      if (data is! List) return [];
      return [
        for (final h in data)
          if (h is Map) ?BoundaryCandidate.fromOsm(Map<String, dynamic>.from(h)),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Expo `fetchOsmReverseCandidates`: the enclosing features at several zooms.
  Future<List<BoundaryCandidate>> reverseBoundaries(LatLng p) async {
    final out = <BoundaryCandidate>[];
    for (final z in const [16, 14, 12, 10, 8]) {
      try {
        final hit = await _get('reverse', {
          'format': 'json',
          'polygon_geojson': '1',
          'zoom': '$z',
          'lat': '${p.latitude}',
          'lon': '${p.longitude}',
        });
        if (hit is! Map) continue;
        final c = BoundaryCandidate.fromOsm(Map<String, dynamic>.from(hit));
        if (c != null) out.add(c);
      } catch (_) {}
    }
    return mergeCandidates(const [], out);
  }

  /// Worldwide place search with address details.
  Future<List<PlaceResult>> places(String query, {List<String> nameKeys = placeNameKeys, int limit = 12}) async {
    final data = await _get('search', {
      'format': 'json',
      'addressdetails': '1',
      'limit': '$limit',
      'q': query,
    });
    if (data is! List) throw StateError('Search failed. Try again.');
    return [
      for (final d in data)
        if (d is Map) placeFromNominatim(Map<String, dynamic>.from(d), nameKeys: nameKeys),
    ];
  }
}

final osmLookupProvider = Provider((_) => OsmLookup());
