/// Admin → Airport Areas in place search (Expo `utils/airportAreas.ts`): a
/// result inside an airport's drawn boundary, or within [airportBufferM] of
/// it, or named after the airport, becomes one entry for the airport itself,
/// so a rider picks "KLIA" rather than one of a dozen points inside it. A
/// multi-gate place with a boundary does the same when the admin switches
/// "Group search results inside the boundary" on (`values.groupResults`,
/// with extra words to group by in `values.groupWords`). Pure.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const airportBufferM = 300.0;
const _mPerDeg = 111320.0;

/// What an area is (migration 0258): an Airport Areas airport, or a
/// multi-gate place with its boundary switched on.
enum AreaKind { airport, place }

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
    this.kind = AreaKind.airport,
    this.sizeM2,
    this._groupResults,
    this.groupWords = const [],
    this.address,
    this.point,
    this.placeType,
  });

  final String id;
  final AreaKind kind;

  /// A place's boundary size (the server's `size_m2`): the smallest place
  /// holding a point is the one it is at.
  final double? sizeM2;
  bool get isPlace => kind == AreaKind.place;
  final String name;
  final String code;
  final String? placeName;
  final List<List<LatLng>> rings;
  final double north, south, east, west;

  LatLng get centroid => LatLng((north + south) / 2, (east + west) / 2);

  /// Search shows the results inside as this one ("Group search results
  /// inside the boundary"): on for an airport unless the admin turned it
  /// off, off for a place unless turned on.
  bool get groupResults => _groupResults ?? !isPlace;
  final bool? _groupResults;

  /// More words that fold a result in ("klia2"): lower case, for results
  /// Google gives without a position.
  final List<String> groupWords;

  /// The admin's address and position for the area, where set (a place's
  /// grouped result shows them), and a place's type key (0264).
  final String? address;
  final LatLng? point;
  final String? placeType;

  /// An `airport-areas` entry, or null without a usable boundary (the admin
  /// stores it as a JSON string: `{coords, polygons?, bbox}`).
  static AirportArea? fromEntry(
    String id,
    Map<String, dynamic> v, {
    AreaKind kind = AreaKind.airport,
    double? sizeM2,
  }) {
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
    final lat = n(v['lat']), lon = n(v['lon']);
    return AirportArea(
      id: id,
      name: s(v['name']).isEmpty ? (kind == AreaKind.place ? 'Place' : 'Airport') : s(v['name']),
      code: s(v['code']),
      placeName: s(v['placeName']).isEmpty ? null : s(v['placeName']),
      rings: rings,
      kind: kind,
      sizeM2: sizeM2,
      groupResults: parseGroupResults(v['groupResults']),
      groupWords: parseGroupWords(v['groupWords']),
      address: s(v['address']).isEmpty ? null : s(v['address']),
      point: lat == null || lon == null ? null : LatLng(lat, lon),
      placeType: s(v['placeType']).isEmpty ? null : s(v['placeType']),
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

  /// Whether [text] names this airport: its name, code or place name as
  /// whole words, never as part of a word ("KUA" is not in "Kuala Lumpur").
  bool matchesName(String text) {
    final r = _norm(text);
    if (r.isEmpty) return false;
    for (final c in [name, code, placeName ?? ''].map(_norm)) {
      if (c.length < 3) continue;
      if (r == c || _hasWords(r, c) || _hasWords(c, r)) return true;
    }
    return false;
  }

  /// Whether [text] folds into this area by name: [matchesName], or one of
  /// the admin's [groupWords] in it as whole words.
  bool matchesGroupText(String text) {
    if (matchesName(text)) return true;
    final r = _norm(text);
    if (r.isEmpty) return false;
    for (final w in groupWords.map(_norm)) {
      if (w.isNotEmpty && _hasWords(r, w)) return true;
    }
    return false;
  }
}

/// `values.groupResults` as stored: null when the admin never set it (the
/// area's default then applies).
bool? parseGroupResults(Object? raw) => switch (raw) {
  null => null,
  bool b => b,
  num n => n != 0,
  _ => switch ('$raw'.trim().toLowerCase()) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => null,
  },
};

/// A word to group by as stored: trimmed, lower case, one space between
/// words.
String groupWord(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// `values.groupWords` as stored: each a [groupWord], no blanks or repeats.
List<String> parseGroupWords(Object? raw) {
  final out = <String>[];
  if (raw is List) {
    for (final w in raw) {
      final g = groupWord('${w ?? ''}');
      if (g.isNotEmpty && !out.contains(g)) out.add(g);
    }
  }
  return out;
}

/// Whether [p] is inside [ring].
bool ringContains(List<LatLng> ring, LatLng p) => ring.length >= 3 && _inRing(p, ring);

/// How far [p] is from [ring]'s edge, in metres.
double ringDistanceM(List<LatLng> ring, LatLng p) => ring.isEmpty ? double.infinity : _distToRing(p, ring);

/// [ring]'s rough size (its box, in square degrees), to tell a terminal's
/// outline from the whole airport's.
double ringBoxSize(List<LatLng> ring) {
  if (ring.isEmpty) return 0;
  var n = -90.0, s = 90.0, e = -180.0, w = 180.0;
  for (final p in ring) {
    n = math.max(n, p.latitude);
    s = math.min(s, p.latitude);
    e = math.max(e, p.longitude);
    w = math.min(w, p.longitude);
  }
  return (n - s) * (e - w);
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Whether [words] appear in [text] as whole words, in order.
bool _hasWords(String text, String words) => ' $text '.contains(' $words ');

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

/// [results] with every one that falls in (or is named after) an area that
/// groups its results ([AirportArea.groupResults]) replaced by that area,
/// once, where its first match was. A result folds into the first such area
/// in [areasByPrecedence] whose boundary holds its position (null for a
/// suggestion with none yet; a place's boundary has no margin) or whose
/// name, code, place name or words its text has. [area] makes the area's
/// entry, told how many results were folded into it.
List<T> collapseIntoAreas<T>(
  List<T> results,
  List<AirportArea> areas, {
  required LatLng? Function(T) point,
  required String Function(T) text,
  required T Function(AirportArea area, int folded) area,
}) {
  final grouping = [for (final a in areasByPrecedence(areas)) if (a.groupResults) a];
  if (grouping.isEmpty) return results;
  AirportArea? into(T r) {
    final at = point(r);
    final words = text(r);
    for (final a in grouping) {
      if (at != null && a.contains(at, bufferM: a.isPlace ? 0 : airportBufferM)) return a;
      if (a.matchesGroupText(words)) return a;
    }
    return null;
  }

  final hits = [for (final r in results) into(r)];
  final counts = <String, int>{};
  for (final a in hits) {
    if (a != null) counts[a.id] = (counts[a.id] ?? 0) + 1;
  }
  final out = <T>[];
  final seen = <String>{};
  for (var i = 0; i < results.length; i++) {
    final a = hits[i];
    if (a == null) {
      out.add(results[i]);
    } else if (seen.add(a.id)) {
      out.add(area(a, counts[a.id]!));
    }
  }
  return out;
}

/// Which area a point inside both an airport and a place is at (Admin →
/// Airport Areas → Places inside an airport, migration 0266; the server's
/// `area_at` follows the same setting).
enum AreaPrecedence {
  /// The place, unless it is "Part of" the same group as the airport (KLIA
  /// T2 (ERL), part of KLIA, stays KLIA's; Mitsui Outlet Park is its own).
  /// The default.
  partOf('part_of'),

  /// Always the place.
  place('place'),

  /// Always the airport (0258's rule).
  airport('airport');

  const AreaPrecedence(this.key);

  /// As stored in `area_precedence_settings.mode`.
  final String key;

  /// The stored [key]'s choice; the default for anything else.
  static AreaPrecedence of(Object? key) =>
      AreaPrecedence.values.where((m) => m.key == '${key ?? ''}'.trim()).firstOrNull ?? AreaPrecedence.partOf;
}

/// The setting, with each area's "Part of" key (by area id: an airport's
/// `airport_areas.values.partOf`, a place's `multi_gate.values.partOf`, as
/// compared: trimmed, one space, any case; '' or missing for none).
class AreaPrecedenceRule {
  const AreaPrecedenceRule({this.mode = AreaPrecedence.partOf, this.partOf = const {}});
  final AreaPrecedence mode;
  final Map<String, String> partOf;

  /// Which of [place] and [airport], both holding the point, it is at.
  AirportArea pick(AirportArea place, AirportArea airport) => switch (mode) {
    AreaPrecedence.place => place,
    AreaPrecedence.airport => airport,
    AreaPrecedence.partOf =>
      (partOf[place.id] ?? '').isNotEmpty && partOf[place.id] == partOf[airport.id] ? airport : place,
  };
}

/// [areas] in the order a point is matched (as the server's `area_at`,
/// 0258): every airport first, in the order given, then the places from
/// the smallest boundary up. Where a point is in both an airport and a
/// place, [AreaPrecedenceRule] decides (gate_snap.dart's `gateAreaAt`).
List<AirportArea> areasByPrecedence(List<AirportArea> areas) {
  final airports = [for (final a in areas) if (!a.isPlace) a];
  final places = [for (final a in areas) if (a.isPlace) a];
  final order = {for (var i = 0; i < places.length; i++) places[i].id: i};
  places.sort((a, b) {
    final c = (a.sizeM2 ?? double.infinity).compareTo(b.sizeM2 ?? double.infinity);
    return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
  });
  return [...airports, ...places];
}
