// What OpenStreetMap knows about the roads on a map, read from the Overpass
// API: traffic signals (`highway=traffic_signals`), speed limits
// (`maxspeed=*`, which coverage varies a lot by region) and the road class
// (`highway=residential`, `highway=trunk`, ...), which stands in as a
// baseline speed where no limit is tagged and there is no live traffic. Pure.
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Traffic signals are drawn only from this zoom in: further out a city has
/// thousands and the map would be nothing but lights.
const trafficSignalsMinZoom = 15.0;

/// The grid (in degrees, about 1.1 km) traffic signals are fetched and cached
/// in, so panning about reuses what was already read.
const roadInfoTile = 0.01;

/// How far from the car a road may be and still be the one it is on.
const roadAtRadiusMetres = 30;

/// The road class from its `highway` tag, with the speed a car is assumed to
/// make on it where nothing better is known.
enum RoadClass {
  motorway('Motorway', 90),
  trunk('Trunk road', 70),
  primary('Primary road', 60),
  secondary('Secondary road', 50),
  tertiary('Tertiary road', 40),
  unclassified('Minor road', 30),
  residential('Residential road', 30),
  service('Service road', 15),
  livingStreet('Living street', 10);

  const RoadClass(this.label, this.baselineKmh);
  final String label;

  /// A baseline, not a limit: what routing assumes on this class of road.
  final int baselineKmh;

  /// `motorway_link` counts as a motorway, and so on; anything that is not a
  /// road for cars (footway, cycleway, path, steps) is null.
  static RoadClass? parse(String? highway) {
    if (highway == null) return null;
    final base = highway.endsWith('_link') ? highway.substring(0, highway.length - 5) : highway;
    return switch (base) {
      'motorway' => RoadClass.motorway,
      'trunk' => RoadClass.trunk,
      'primary' => RoadClass.primary,
      'secondary' => RoadClass.secondary,
      'tertiary' => RoadClass.tertiary,
      'unclassified' => RoadClass.unclassified,
      'residential' => RoadClass.residential,
      'service' => RoadClass.service,
      'living_street' => RoadClass.livingStreet,
      _ => null,
    };
  }
}

/// A `maxspeed` tag in km/h: `50`, `50 km/h`, `30 mph` (converted), the
/// lower of `60;40`. Null for `none`, `signals`, `walk`, country-zone codes
/// (`MY:urban`) and anything unreadable: a limit is shown only when tagged.
int? parseMaxspeed(String? raw) {
  if (raw == null) return null;
  final values = <int>[];
  for (final part in raw.split(';')) {
    final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(mph|km/h|kmh|kph)?\s*$', caseSensitive: false).firstMatch(part);
    if (m == null) continue;
    final n = double.parse(m.group(1)!);
    final kmh = (m.group(2)?.toLowerCase() == 'mph') ? n * 1.609344 : n;
    if (kmh > 0) values.add(kmh.round());
  }
  return values.isEmpty ? null : values.reduce(math.min);
}

/// The road a point is on, as far as OSM says.
class RoadInfo {
  const RoadInfo({required this.roadClass, this.name, this.maxspeedKmh});
  final RoadClass roadClass;
  final String? name;

  /// The tagged limit; null when the road has none tagged.
  final int? maxspeedKmh;

  /// What the sign shows: the tagged limit, else the class's baseline (and
  /// [estimated] says so).
  int get speedKmh => maxspeedKmh ?? roadClass.baselineKmh;
  bool get estimated => maxspeedKmh == null;
}

/// The Overpass query for traffic signals inside a bounding box.
String trafficSignalsQuery(({double south, double west, double north, double east}) b) =>
    '[out:json][timeout:15];node["highway"="traffic_signals"]'
    '(${b.south},${b.west},${b.north},${b.east});out;';

/// The Overpass query for the roads within [roadAtRadiusMetres] of a point,
/// with their geometry so the nearest can be picked.
String roadAtQuery(LatLng at) =>
    '[out:json][timeout:15];way(around:$roadAtRadiusMetres,${at.latitude},${at.longitude})["highway"];out tags geom;';

/// The grid tiles (south-west corners) covering a bounding box.
List<({double south, double west})> tilesFor({
  required double south,
  required double west,
  required double north,
  required double east,
}) {
  double floor(double v) => (v / roadInfoTile).floorToDouble() * roadInfoTile;
  final out = <({double south, double west})>[];
  for (var s = floor(south); s < north; s += roadInfoTile) {
    for (var w = floor(west); w < east; w += roadInfoTile) {
      out.add((south: _round(s), west: _round(w)));
    }
  }
  return out;
}

double _round(double v) => (v * 1e6).round() / 1e6;

/// The traffic signals in an Overpass answer.
List<LatLng> parseTrafficSignals(Object? json) {
  final elements = json is Map ? json['elements'] : null;
  if (elements is! List) return const [];
  return [
    for (final e in elements)
      if (e is Map && e['type'] == 'node' && e['lat'] is num && e['lon'] is num)
        LatLng((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble()),
  ];
}

/// The road [at] is on: of the car roads in an Overpass answer, the one whose
/// line passes closest. Null when none is a road for cars.
RoadInfo? parseRoadAt(Object? json, LatLng at) {
  final elements = json is Map ? json['elements'] : null;
  if (elements is! List) return null;
  RoadInfo? best;
  var bestMetres = double.infinity;
  for (final e in elements) {
    if (e is! Map || e['type'] != 'way') continue;
    final tags = e['tags'];
    if (tags is! Map) continue;
    final cls = RoadClass.parse(tags['highway'] as String?);
    if (cls == null) continue;
    final geom = e['geometry'];
    if (geom is! List) continue;
    final pts = [
      for (final g in geom)
        if (g is Map && g['lat'] is num && g['lon'] is num)
          LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
    ];
    if (pts.isEmpty) continue;
    final d = distanceToLine(at, pts);
    if (d < bestMetres) {
      bestMetres = d;
      best = RoadInfo(
        roadClass: cls,
        name: (tags['name'] as String?)?.trim().isEmpty ?? true ? null : (tags['name'] as String).trim(),
        maxspeedKmh: parseMaxspeed(tags['maxspeed'] as String?),
      );
    }
  }
  return best;
}

/// Metres from [p] to the nearest point of the polyline [line] (flat-earth,
/// fine at street scale).
double distanceToLine(LatLng p, List<LatLng> line) {
  if (line.length == 1) return const Distance()(p, line.first);
  final k = math.cos(p.latitude * math.pi / 180);
  ({double x, double y}) xy(LatLng q) =>
      (x: (q.longitude - p.longitude) * k * 111320, y: (q.latitude - p.latitude) * 110540);
  var best = double.infinity;
  for (var i = 0; i + 1 < line.length; i++) {
    final a = xy(line[i]), b = xy(line[i + 1]);
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : (-(a.x * dx + a.y * dy) / len2).clamp(0.0, 1.0);
    final cx = a.x + t * dx, cy = a.y + t * dy;
    best = math.min(best, math.sqrt(cx * cx + cy * cy));
  }
  return best;
}
