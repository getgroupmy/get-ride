import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/road_info.dart';

/// Reads traffic signals and the road under the car from OpenStreetMap's
/// Overpass API, caching what it has read: signals per [roadInfoTile] grid
/// square for the session, the road per ~10 m. A failed read is an empty
/// answer, never an error: the map simply shows less.
class RoadInfoService {
  RoadInfoService({http.Client? client, String? endpoint})
    : _http = client ?? http.Client(),
      _endpoint = endpoint ?? _overpass;

  /// The one the maps share.
  static RoadInfoService shared = RoadInfoService();

  final http.Client _http;
  final String _endpoint;

  static const _overpass = String.fromEnvironment(
    'OVERPASS_URL',
    defaultValue: 'https://overpass-api.de/api/interpreter',
  );

  Map<String, String> get _headers => kIsWeb ? const {} : const {'User-Agent': 'GET.ride Flutter (getgroup.my)'};

  final _tiles = <String, Future<List<LatLng>>>{};
  final _roads = <String, Future<RoadInfo?>>{};

  Future<Object?> _ask(String query) async {
    try {
      final res = await _http
          .get(Uri.parse(_endpoint).replace(queryParameters: {'data': query}), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body);
    } catch (_) {
      return null;
    }
  }

  /// The traffic signals in the grid squares covering a bounding box.
  Future<List<LatLng>> trafficSignals({
    required double south,
    required double west,
    required double north,
    required double east,
  }) async {
    final tiles = tilesFor(south: south, west: west, north: north, east: east);
    // A view wider than a few squares is zoomed out past where signals show.
    if (tiles.length > 12) return const [];
    final all = await Future.wait([
      for (final t in tiles)
        _tiles.putIfAbsent('${t.south},${t.west}', () async {
          final found = parseTrafficSignals(
            await _ask(
              trafficSignalsQuery((
                south: t.south,
                west: t.west,
                north: t.south + roadInfoTile,
                east: t.west + roadInfoTile,
              )),
            ),
          );
          return found;
        }),
    ]);
    return [for (final list in all) ...list];
  }

  /// The road [at] is on, or null when OSM has none for cars there.
  Future<RoadInfo?> roadAt(LatLng at) {
    final key = '${(at.latitude * 1e4).round()},${(at.longitude * 1e4).round()}';
    if (_roads.length > 500) _roads.clear();
    return _roads.putIfAbsent(key, () async => parseRoadAt(await _ask(roadAtQuery(at)), at));
  }
}
