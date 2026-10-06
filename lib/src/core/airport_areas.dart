/// Admin → Airport Areas in place search (Expo `utils/airportAreas.ts`): a
/// result inside an airport's drawn boundary, or within [airportBufferM] of
/// it, or named after the airport, becomes one entry for the airport itself,
/// so a rider picks "KLIA" rather than one of a dozen points inside it.
/// Pure.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const airportBufferM = 300.0;
const _mPerDeg = 111320.0;

class AirportArea {
  const AirportArea({
    required this.id,
    required this.name,
    required this.code,
    required this.rings,
    required this.north,
    required this.south,
    required this.east,
    required this.west,
    this.placeName,
  });

  final String id;
  final String name;
  final String code;
  final String? placeName;
  final List<List<LatLng>> rings;
  final double north, south, east, west;

  LatLng get centroid => LatLng((north + south) / 2, (east + west) / 2);

  /// An `airport-areas` entry, or null without a usable boundary (the admin
  /// stores it as a JSON string: `{coords, polygons?, bbox}`).
  static AirportArea? fromEntry(String id, Map<String, dynamic> v) {
    final raw = v['boundary'];
    Map<String, dynamic>? b;
    try {
      final j = raw is String ? jsonDecode(raw) : raw;
      if (j is Map) b = Map<String, dynamic>.from(j);
    } catch (_) {}
    if (b == null || b['coords'] is! List || b['bbox'] is! Map) return null;
    double? n(Object? x) => x is num ? x.toDouble() : double.tryParse('$x');
    List<LatLng> ring(Object? list) => [
      if (list is List)
        for (final p in list)
          if (p is Map && n(p['latitude']) != null && n(p['longitude']) != null)
            LatLng(n(p['latitude'])!, n(p['longitude'])!),
    ];
    final bbox = b['bbox'] as Map;
    final north = n(bbox['north']), south = n(bbox['south']), east = n(bbox['east']), west = n(bbox['west']);
    if (north == null || south == null || east == null || west == null) return null;
    final polygons = [
      if (b['polygons'] is List)
        for (final p in b['polygons'] as List) ring(p),
    ].where((r) => r.isNotEmpty).toList();
    final coords = ring(b['coords']);
    final rings = polygons.isNotEmpty
        ? polygons
        : coords.length >= 3
        ? [coords]
        : [
            [LatLng(north, west), LatLng(north, east), LatLng(south, east), LatLng(south, west)],
          ];
    String s(Object? x) => '${x ?? ''}'.trim();
    return AirportArea(
      id: id,
      name: s(v['name']).isEmpty ? 'Airport' : s(v['name']),
      code: s(v['code']),
      placeName: s(v['placeName']).isEmpty ? null : s(v['placeName']),
      rings: rings,
      north: north,
      south: south,
      east: east,
      west: west,
    );
  }

  bool contains(LatLng p, {double bufferM = airportBufferM}) {
    final latBuf = bufferM / _mPerDeg;
    final cosL = math.cos(p.latitude * math.pi / 180);
    final lngBuf = bufferM / (_mPerDeg * (cosL == 0 ? 1 : cosL));
    if (p.latitude > north + latBuf || p.latitude < south - latBuf) return false;
    if (p.longitude > east + lngBuf || p.longitude < west - lngBuf) return false;
    for (final r in rings) {
      if (r.length < 3) continue;
      if (_inRing(p, r) || _distToRing(p, r) <= bufferM) return true;
    }
    return false;
  }

  bool matchesName(String text) {
    final r = _norm(text);
    if (r.isEmpty) return false;
    for (final c in [name, code, placeName ?? ''].map(_norm)) {
      if (c.length < 3) continue;
      if (r == c || r.contains(c) || c.contains(r)) return true;
    }
    return false;
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

bool _inRing(LatLng p, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude, xj = ring[j].longitude, yj = ring[j].latitude;
    final d = yj - yi;
    if ((yi > p.latitude) != (yj > p.latitude) &&
        p.longitude < (xj - xi) * (p.latitude - yi) / (d == 0 ? 1e-12 : d) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

double _distToRing(LatLng p, List<LatLng> ring) {
  final cosL = math.cos(p.latitude * math.pi / 180);
  var best = double.infinity;
  for (var i = 0; i < ring.length; i++) {
    final a = ring[i], b = ring[(i + 1) % ring.length];
    final ax = (a.longitude - p.longitude) * cosL * _mPerDeg, ay = (a.latitude - p.latitude) * _mPerDeg;
    final bx = (b.longitude - p.longitude) * cosL * _mPerDeg, by = (b.latitude - p.latitude) * _mPerDeg;
    final dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
    final t = len2 > 0 ? (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0) : 0.0;
    final cx = ax + t * dx, cy = ay + t * dy;
    best = math.min(best, math.sqrt(cx * cx + cy * cy));
  }
  return best;
}

/// [results] with every one that falls in (or is named after) an airport
/// replaced by that airport, once, where its first match was.
List<T> collapseAirports<T>(
  List<T> results,
  List<AirportArea> areas, {
  required LatLng Function(T) point,
  required String Function(T) text,
  required T Function(AirportArea) airport,
}) {
  if (areas.isEmpty) return results;
  final out = <T>[];
  final seen = <String>{};
  for (final r in results) {
    final hits = [
      for (final a in areas)
        if (a.contains(point(r)) || a.matchesName(text(r))) a,
    ];
    if (hits.isEmpty) {
      out.add(r);
      continue;
    }
    for (final a in hits) {
      if (seen.add(a.id)) out.add(airport(a));
    }
  }
  return out;
}
