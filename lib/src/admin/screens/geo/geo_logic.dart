/// Pure geography logic for the Geography admin screens, ported from the Expo
/// screens `admin-settings-country-states-cities.tsx`,
/// `admin-settings-airport-areas.tsx`, `admin-settings-multi-gate-places.tsx`,
/// `admin-settings-multi-gate-place-gates.tsx` and the region helpers in
/// `utils/adminSync.ts` (`regionLevel`, `rowToRegionEntry`, `upsertRegion`).
///
/// Everything here is free of Flutter and Supabase so it can be unit tested.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// Boundaries / geofences
// ---------------------------------------------------------------------------

/// Where a boundary came from. Stored as `boundarySource` / `geofence.source`.
/// `google` and `geonames` are only read (rows written by the Expo app); the
/// Flutter editor produces `osm`, `bbox` and `manual`.
const boundarySources = ['osm', 'google', 'geonames', 'bbox', 'manual'];

class BBox {
  const BBox({required this.north, required this.south, required this.east, required this.west});
  final double north;
  final double south;
  final double east;
  final double west;

  Map<String, dynamic> toJson() => {'north': north, 'south': south, 'east': east, 'west': west};

  static BBox? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final n = _num(raw['north']);
    final s = _num(raw['south']);
    final e = _num(raw['east']);
    final w = _num(raw['west']);
    if (n == null || s == null || e == null || w == null) return null;
    return BBox(north: n, south: s, east: e, west: w);
  }

  /// Bounding box of a set of points (Expo `commitDraft`).
  static BBox ofPoints(List<LatLng> pts) => BBox(
        north: pts.map((p) => p.latitude).reduce(math.max),
        south: pts.map((p) => p.latitude).reduce(math.min),
        east: pts.map((p) => p.longitude).reduce(math.max),
        west: pts.map((p) => p.longitude).reduce(math.min),
      );

  LatLng get center => LatLng((north + south) / 2, (east + west) / 2);

  @override
  bool operator ==(Object other) =>
      other is BBox && other.north == north && other.south == south && other.east == east && other.west == west;

  @override
  int get hashCode => Object.hash(north, south, east, west);
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// Rectangle ring for a bbox: NW, NE, SE, SW (Expo `bboxToRect`).
List<LatLng> bboxToRect(BBox b) => [
      LatLng(b.north, b.west),
      LatLng(b.north, b.east),
      LatLng(b.south, b.east),
      LatLng(b.south, b.west),
    ];

/// The `BoundaryShape` JSON stored (as a string) under `values.boundary` /
/// `geofence.boundary`: `{coords:[{latitude,longitude}], polygons?, bbox, source}`.
class BoundaryShape {
  const BoundaryShape({required this.coords, this.polygons, required this.bbox, required this.source});

  /// The main ring (largest polygon for a MultiPolygon).
  final List<LatLng> coords;

  /// Every ring when the source had more than one (or the drawn ring).
  final List<List<LatLng>>? polygons;
  final BBox bbox;
  final String source;

  /// Rings to draw / test against.
  List<List<LatLng>> get rings => (polygons != null && polygons!.isNotEmpty) ? polygons! : [coords];

  int get pointCount => coords.length;

  Map<String, dynamic> toJson() => {
        'coords': [for (final p in coords) _pt(p)],
        if (polygons != null)
          'polygons': [
            for (final ring in polygons!) [for (final p in ring) _pt(p)],
          ],
        'bbox': bbox.toJson(),
        'source': source,
      };

  String encode() => jsonEncode(toJson());

  static Map<String, double> _pt(LatLng p) => {'latitude': p.latitude, 'longitude': p.longitude};

  @override
  bool operator ==(Object other) => other is BoundaryShape && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

List<LatLng>? _ring(Object? raw) {
  if (raw is! List) return null;
  final out = <LatLng>[];
  for (final p in raw) {
    if (p is! Map) return null;
    final lat = _num(p['latitude']);
    final lng = _num(p['longitude']);
    if (lat == null || lng == null) return null;
    out.add(LatLng(lat, lng));
  }
  return out;
}

/// Expo `parseBoundary`: a JSON string with `coords` (array) and `bbox`, or
/// null when missing / malformed.
BoundaryShape? parseBoundary(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return null;
    final coords = _ring(j['coords']);
    final bbox = BBox.fromJson(j['bbox']);
    if (coords == null || bbox == null) return null;
    List<List<LatLng>>? polygons;
    final rawPolys = j['polygons'];
    if (rawPolys is List) {
      polygons = [for (final r in rawPolys) ?_ring(r)];
    }
    final source = j['source'] is String ? j['source'] as String : 'manual';
    return BoundaryShape(coords: coords, polygons: polygons, bbox: bbox, source: source);
  } catch (_) {
    return null;
  }
}

/// A finished drawing (≥ 3 vertices) becomes a `manual` shape; null when there
/// are too few points (Expo `commitDraft`).
BoundaryShape? boundaryFromDraft(List<LatLng> pts) {
  if (pts.length < 3) return null;
  final ring = List<LatLng>.unmodifiable(pts);
  return BoundaryShape(coords: ring, polygons: [ring], bbox: BBox.ofPoints(ring), source: 'manual');
}

/// A rectangle from typed N/S/E/W bounds; null unless all four parse.
BoundaryShape? boundaryFromBBoxInput(String n, String s, String e, String w) {
  final v = [n, s, e, w].map((x) => double.tryParse(x.trim())).toList();
  if (v.any((x) => x == null || x.isNaN)) return null;
  final b = BBox(north: v[0]!, south: v[1]!, east: v[2]!, west: v[3]!);
  return BoundaryShape(coords: bboxToRect(b), bbox: b, source: 'bbox');
}

/// Expo `osmHitToShape`: Nominatim hit (with `polygon_geojson=1`) → shape.
/// `boundingbox` is `[south, north, west, east]` as strings.
BoundaryShape? osmHitToShape(Map<String, dynamic> hit) {
  final bb = hit['boundingbox'];
  if (bb is! List || bb.length < 4) return null;
  final s = _num(bb[0]), n = _num(bb[1]), w = _num(bb[2]), e = _num(bb[3]);
  if (s == null || n == null || w == null || e == null) return null;
  final bbox = BBox(north: n, south: s, east: e, west: w);
  var coords = bboxToRect(bbox);
  var polygons = <List<LatLng>>[];
  List<LatLng> ringOf(Object? r) => r is List
      ? [
          for (final c in r)
            if (c is List && c.length >= 2 && c[0] is num && c[1] is num)
              LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ]
      : <LatLng>[];
  final gj = hit['geojson'];
  if (gj is Map) {
    final coordsRaw = gj['coordinates'];
    if (gj['type'] == 'Polygon' && coordsRaw is List) {
      final ring = ringOf(coordsRaw.isNotEmpty ? coordsRaw.first : null);
      coords = ring;
      polygons = [ring];
    } else if (gj['type'] == 'MultiPolygon' && coordsRaw is List) {
      polygons = [
        for (final p in coordsRaw) ringOf(p is List && p.isNotEmpty ? p.first : null),
      ].where((r) => r.isNotEmpty).toList();
      var best = <LatLng>[];
      for (final r in polygons) {
        if (r.length > best.length) best = r;
      }
      if (best.isNotEmpty) coords = best;
    }
  }
  return BoundaryShape(coords: coords, polygons: polygons.isEmpty ? null : polygons, bbox: bbox, source: 'osm');
}

class BoundaryCandidate {
  const BoundaryCandidate({
    required this.displayName,
    required this.shape,
    this.type,
    this.className,
    this.osmType,
    this.osmId,
  });
  final String displayName;
  final String? type;
  final String? className;
  final String? osmType;
  final String? osmId;
  final BoundaryShape shape;

  /// Dedupe key (Expo `candidateKey`).
  String key(int index) => '${osmType ?? 'x'}-${osmId ?? index}';

  String get tag => [className, type].whereType<String>().where((s) => s.isNotEmpty).join('/');

  static BoundaryCandidate? fromOsm(Map<String, dynamic> hit) {
    final shape = osmHitToShape(hit);
    if (shape == null) return null;
    return BoundaryCandidate(
      displayName: (hit['display_name'] as String?) ?? '',
      type: hit['type'] as String?,
      className: (hit['class'] ?? hit['category']) as String?,
      osmType: hit['osm_type'] as String?,
      osmId: hit['osm_id']?.toString(),
      shape: shape,
    );
  }
}

/// Appends [fresh] to [existing], dropping repeats by [BoundaryCandidate.key].
List<BoundaryCandidate> mergeCandidates(List<BoundaryCandidate> existing, List<BoundaryCandidate> fresh) {
  final seen = <String>{for (var i = 0; i < existing.length; i++) existing[i].key(i)};
  final out = [...existing];
  for (final c in fresh) {
    final k = c.key(out.length);
    if (seen.add(k)) out.add(c);
  }
  return out;
}

/// Ray-casting point-in-polygon test (ring need not be closed).
bool pointInRing(LatLng p, List<LatLng> ring) {
  if (ring.length < 3) return false;
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    final crosses = (yi > p.latitude) != (yj > p.latitude) &&
        p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi;
    if (crosses) inside = !inside;
  }
  return inside;
}

/// True when [p] lies inside any ring of [shape].
bool boundaryContains(BoundaryShape shape, LatLng p) => shape.rings.any((r) => pointInRing(p, r));

// ---------------------------------------------------------------------------
// Regions (countries / states / cities / suburbs)
// ---------------------------------------------------------------------------

enum RegionLevel { country, state, city, suburb }

const regionTables = {
  RegionLevel.country: 'countries',
  RegionLevel.state: 'states',
  RegionLevel.city: 'cities',
  RegionLevel.suburb: 'suburbs',
};

const regionConflictKeys = {
  RegionLevel.country: 'name',
  RegionLevel.state: 'country,name',
  RegionLevel.city: 'country,state,name',
  RegionLevel.suburb: 'country,state,city,name',
};

String regionLevelLabel(RegionLevel l, {bool plural = false}) => switch (l) {
      RegionLevel.country => plural ? 'countries' : 'country',
      RegionLevel.state => plural ? 'states' : 'state',
      RegionLevel.city => plural ? 'cities' : 'city',
      RegionLevel.suburb => plural ? 'suburbs' : 'suburb',
    };

String _s(Object? v) => (v ?? '').toString().trim();

/// Expo `regionLevel`: the deepest filled name decides the table.
RegionLevel regionLevelOf(Map<String, dynamic> values) {
  if (_s(values['suburb']).isNotEmpty) return RegionLevel.suburb;
  if (_s(values['city']).isNotEmpty) return RegionLevel.city;
  if (_s(values['state']).isNotEmpty) return RegionLevel.state;
  return RegionLevel.country;
}

/// One region row in the legacy SettingEntry shape: the four level names plus
/// the free-form `values` (and the boundary keys re-hydrated from `geofence`).
class RegionEntry {
  RegionEntry({required this.id, required this.values, this.position = 0});
  final String id;
  final Map<String, dynamic> values;
  final int position;

  String get country => _s(values['country']);
  String get state => _s(values['state']);
  String get city => _s(values['city']);
  String get suburb => _s(values['suburb']);
  RegionLevel get level => regionLevelOf(values);
  String get key => regionRowKey(country, state, city, suburb);
}

/// Expo `rowToRegionEntry`.
RegionEntry regionEntryFromRow(Map<String, dynamic> row, RegionLevel level) {
  final values = <String, dynamic>{...?(row['values'] as Map?)?.cast<String, dynamic>()};
  final gf = row['geofence'];
  if (gf is Map) {
    if (gf['boundary'] is String && (gf['boundary'] as String).isNotEmpty) values['boundary'] = gf['boundary'];
    if (gf['source'] is String && (gf['source'] as String).isNotEmpty) values['boundarySource'] = gf['source'];
    if (gf['updatedAt'] is String && (gf['updatedAt'] as String).isNotEmpty) {
      values['boundaryUpdatedAt'] = gf['updatedAt'];
    }
  }
  final name = (row['name'] ?? '').toString();
  String col(String k) => (row[k] ?? '').toString();
  switch (level) {
    case RegionLevel.country:
      values.addAll({'country': name, 'state': '', 'city': '', 'suburb': ''});
    case RegionLevel.state:
      values.addAll({'country': col('country'), 'state': name, 'city': '', 'suburb': ''});
    case RegionLevel.city:
      values.addAll({'country': col('country'), 'state': col('state'), 'city': name, 'suburb': ''});
    case RegionLevel.suburb:
      values.addAll({'country': col('country'), 'state': col('state'), 'city': col('city'), 'suburb': name});
  }
  return RegionEntry(id: row['id'] as String, values: values, position: (row['position'] as num?)?.toInt() ?? 0);
}

/// What `upsertRegion` writes: the destination table, its conflict target and
/// the row. Null when the entry has no country (Expo skips it).
({String table, String onConflict, Map<String, dynamic> row, RegionLevel level})? regionUpsert(
  String id,
  Map<String, dynamic> values, {
  int position = 0,
}) {
  final country = _s(values['country']);
  if (country.isEmpty) return null;
  final state = _s(values['state']);
  final city = _s(values['city']);
  final suburb = _s(values['suburb']);
  final level = regionLevelOf(values);
  final payload = <String, dynamic>{...values}
    ..remove('country')
    ..remove('state')
    ..remove('city')
    ..remove('suburb');
  final boundary = values['boundary'] is String ? values['boundary'] as String : '';
  final source = values['boundarySource'] is String ? values['boundarySource'] as String : '';
  final updatedAt = values['boundaryUpdatedAt'] is String ? values['boundaryUpdatedAt'] as String : '';
  payload
    ..remove('boundary')
    ..remove('boundarySource')
    ..remove('boundaryUpdatedAt');
  final geofence = boundary.isEmpty
      ? null
      : {
          'boundary': boundary,
          if (source.isNotEmpty) 'source': source,
          if (updatedAt.isNotEmpty) 'updatedAt': updatedAt,
        };
  final row = <String, dynamic>{
    'id': id,
    ...switch (level) {
      RegionLevel.country => {'name': country},
      RegionLevel.state => {'country': country, 'name': state},
      RegionLevel.city => {'country': country, 'state': state, 'name': city},
      RegionLevel.suburb => {'country': country, 'state': state, 'city': city, 'name': suburb},
    },
    'values': payload,
    'geofence': geofence,
    'position': position,
  };
  return (table: regionTables[level]!, onConflict: regionConflictKeys[level]!, row: row, level: level);
}

/// Expo `rowKey`: case-insensitive identity of a region path.
String regionRowKey(String country, String state, String city, String suburb) =>
    '${country.toLowerCase()}|${state.toLowerCase()}|${city.toLowerCase()}|${suburb.toLowerCase()}';

/// A row in the drill-down list. [entry] is the saved row at exactly this
/// level, or null when the name is only known from deeper rows.
class RegionRow {
  const RegionRow({
    required this.level,
    required this.country,
    this.state = '',
    this.city = '',
    this.suburb = '',
    this.entry,
  });
  final RegionLevel level;
  final String country;
  final String state;
  final String city;
  final String suburb;
  final RegionEntry? entry;

  String get name => switch (level) {
        RegionLevel.country => country,
        RegionLevel.state => state,
        RegionLevel.city => city,
        RegionLevel.suburb => suburb,
      };

  String get key => regionRowKey(country, state, city, suburb);

  BoundaryShape? get boundary => parseBoundary(entry?.values['boundary']);

  /// The geocoder query for this row (Expo `queryFromRow`).
  String get query => switch (level) {
        RegionLevel.country => country,
        RegionLevel.state => '$state, $country',
        RegionLevel.city => '$city, $state, $country',
        RegionLevel.suburb => '$suburb, $city, $state, $country',
      };
}

/// The browsing level for a breadcrumb selection.
RegionLevel currentRegionLevel(String selCountry, String selState, String selCity) => selCountry.isEmpty
    ? RegionLevel.country
    : selState.isEmpty
        ? RegionLevel.state
        : selCity.isEmpty
            ? RegionLevel.city
            : RegionLevel.suburb;

/// Rows for one drill-down level. The Expo screen merged a bundled world
/// catalogue (`country-state-city`) with saved rows; Flutter has no such
/// catalogue, so names come from saved rows — including names only referenced
/// by deeper rows (e.g. a state whose country row was never saved), so every
/// saved row stays reachable.
List<RegionRow> buildRegionRows(
  List<RegionEntry> entries, {
  String selCountry = '',
  String selState = '',
  String selCity = '',
  String query = '',
}) {
  final level = currentRegionLevel(selCountry, selState, selCity);
  final q = query.trim().toLowerCase();
  bool eq(String a, String b) => a.toLowerCase() == b.toLowerCase();
  final byName = <String, RegionRow>{};
  for (final e in entries) {
    if (e.country.isEmpty) continue;
    String name;
    switch (level) {
      case RegionLevel.country:
        name = e.country;
      case RegionLevel.state:
        if (!eq(e.country, selCountry) || e.state.isEmpty) continue;
        name = e.state;
      case RegionLevel.city:
        if (!eq(e.country, selCountry) || !eq(e.state, selState) || e.city.isEmpty) continue;
        name = e.city;
      case RegionLevel.suburb:
        if (!eq(e.country, selCountry) || !eq(e.state, selState) || !eq(e.city, selCity) || e.suburb.isEmpty) {
          continue;
        }
        name = e.suburb;
    }
    final k = name.toLowerCase();
    final atLevel = e.level == level;
    final existing = byName[k];
    if (existing != null && (existing.entry != null || !atLevel)) continue;
    byName[k] = RegionRow(
      level: level,
      country: level == RegionLevel.country ? name : selCountry,
      state: switch (level) {
        RegionLevel.country => '',
        RegionLevel.state => name,
        _ => selState,
      },
      city: switch (level) {
        RegionLevel.city => name,
        RegionLevel.suburb => selCity,
        _ => '',
      },
      suburb: level == RegionLevel.suburb ? name : '',
      entry: atLevel ? e : null,
    );
  }
  final rows = byName.values.where((r) => q.isEmpty || r.name.toLowerCase().contains(q)).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return rows;
}

/// Expo `onSave` validation (by the level being browsed).
String? validateRegionForm(RegionLevel level, {required String country, String state = '', String city = '', String suburb = ''}) {
  if (country.trim().isEmpty) return 'Please choose or enter a country.';
  final s = state.trim(), c = city.trim(), sb = suburb.trim();
  switch (level) {
    case RegionLevel.state when s.isEmpty:
      return 'Please enter a state name.';
    case RegionLevel.city when s.isEmpty || c.isEmpty:
      return 'State and city names are required.';
    case RegionLevel.suburb when s.isEmpty || c.isEmpty || sb.isEmpty:
      return 'State, city and suburb names are required.';
    default:
      return null;
  }
}

/// The region editor's inputs.
class RegionForm {
  RegionForm({
    this.country = '',
    this.state = '',
    this.city = '',
    this.suburb = '',
    this.lat = '',
    this.lng = '',
    Map<String, bool>? services,
    this.biddingEnabled = true,
    this.currencyName = '',
    this.currencySymbol = '',
    this.emergencyNumber = '',
    this.languageCode = '',
    this.dateFormat = '',
    this.callingCode = '',
    this.timezone = '',
  }) : services = services ?? {};

  String country, state, city, suburb, lat, lng;
  Map<String, bool> services;
  bool biddingEnabled;
  String currencyName, currencySymbol, emergencyNumber, languageCode, dateFormat, callingCode, timezone;

  bool get isCountryRow => state.trim().isEmpty && city.trim().isEmpty && suburb.trim().isEmpty;

  /// Pre-fills from a saved entry, falling back to country defaults for the
  /// country-level metadata (Expo `openEdit`).
  factory RegionForm.fromEntry(RegionEntry e) {
    final v = e.values;
    String str(String k) => v[k] == null ? '' : v[k].toString();
    final isCountry = e.state.isEmpty && e.city.isEmpty && e.suburb.isEmpty;
    final def = isCountry ? countryDefaultsForName(e.country) : null;
    return RegionForm(
      country: str('country'),
      state: str('state'),
      city: str('city'),
      suburb: str('suburb'),
      lat: v['lat'] is num ? '${v['lat']}' : '',
      lng: v['lng'] is num ? '${v['lng']}' : '',
      services: parseServicesMap(v['services']),
      biddingEnabled: v['biddingEnabled'] != false,
      currencyName: str('currencyName'),
      currencySymbol: str('currencySymbol'),
      emergencyNumber: v['emergencyNumber'] != null ? str('emergencyNumber') : (def?.emergencyNumber ?? ''),
      languageCode: v['languageCode'] != null ? str('languageCode') : (def?.languageCode ?? ''),
      dateFormat: str('dateFormat'),
      callingCode: str('callingCode'),
      timezone: str('timezone'),
    );
  }

  /// Expo `onSave` values (merged over the existing values by the caller).
  Map<String, dynamic> toValues() {
    final c = country.trim(), s = state.trim(), ci = city.trim(), sb = suburb.trim();
    final values = <String, dynamic>{'country': c, 'state': s, 'city': ci, 'suburb': sb};
    final la = double.tryParse(lat.trim());
    final ln = double.tryParse(lng.trim());
    if (la != null && !la.isNaN) values['lat'] = la;
    if (ln != null && !ln.isNaN) values['lng'] = ln;
    if (isCountryRow) {
      values.addAll({
        'currencyName': currencyName.trim(),
        'currencySymbol': currencySymbol.trim(),
        'emergencyNumber': emergencyNumber.trim(),
        'languageCode': languageCode.trim(),
        'dateFormat': dateFormat.trim(),
        'callingCode': callingCode.trim(),
      });
    }
    if (sb.isEmpty) values['timezone'] = timezone.trim();
    values['services'] = encodeServicesMap(services);
    values['biddingEnabled'] = biddingEnabled;
    return values;
  }
}

/// Saved entry with the same path (Expo duplicate check on add).
RegionEntry? findRegionDuplicate(List<RegionEntry> entries, String c, String s, String ci, String sb) {
  final k = regionRowKey(c.trim(), s.trim(), ci.trim(), sb.trim());
  for (final e in entries) {
    if (e.key == k) return e;
  }
  return null;
}

/// Values written when a boundary is saved on a region row (Expo `saveBoundary`).
Map<String, dynamic> regionBoundaryValues(RegionRow r, BoundaryShape b, DateTime now) => {
      ...?r.entry?.values,
      'country': r.country,
      'state': r.state,
      'city': r.city,
      'suburb': r.suburb,
      ...boundaryValues(b, now),
    };

/// The three boundary keys stored in `values`.
Map<String, dynamic> boundaryValues(BoundaryShape b, DateTime now) => {
      'boundary': b.encode(),
      'boundarySource': b.source,
      'boundaryUpdatedAt': now.toUtc().toIso8601String(),
    };

/// [values] without the boundary keys (Expo `clearBoundary`).
Map<String, dynamic> withoutBoundary(Map<String, dynamic> values) => {...values}
  ..remove('boundary')
  ..remove('boundarySource')
  ..remove('boundaryUpdatedAt');

/// Expo `parseServicesMap`: JSON string `{serviceId: bool}`.
Map<String, bool> parseServicesMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return {};
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return {};
    return {for (final e in j.entries) '${e.key}': e.value == true || (e.value is num && e.value != 0)};
  } catch (_) {
    return {};
  }
}

/// Only the enabled services, as a JSON string.
String encodeServicesMap(Map<String, bool> m) => jsonEncode({
      for (final e in m.entries)
        if (e.value) e.key: true,
    });

class ServiceOption {
  const ServiceOption({required this.id, required this.name, this.description = ''});
  final String id;
  final String name;
  final String description;
}

/// `service-settings` rows ordered by `displayPriority` then original order.
List<ServiceOption> sortServices(List<({String id, Map<String, dynamic> values})> rows) {
  final list = [
    for (var i = 0; i < rows.length; i++)
      (
        idx: i,
        priority: _num(rows[i].values['displayPriority']) ?? double.maxFinite,
        opt: ServiceOption(
          id: rows[i].id,
          name: (rows[i].values['name'] ?? 'Unnamed service').toString(),
          description: (rows[i].values['description'] ?? '').toString(),
        ),
      ),
  ]..sort((a, b) {
      final c = a.priority.compareTo(b.priority);
      return c != 0 ? c : a.idx.compareTo(b.idx);
    });
  return [for (final x in list) x.opt];
}

// Country defaults (Expo COUNTRY_LANGUAGE_MAP / COUNTRY_EMERGENCY_MAP).

const countryLanguageMap = {
  'MY': 'ms-MY', 'US': 'en-US', 'GB': 'en-GB', 'SG': 'en-SG', 'ID': 'id-ID', 'TH': 'th-TH',
  'PH': 'en-PH', 'VN': 'vi-VN', 'JP': 'ja-JP', 'KR': 'ko-KR', 'CN': 'zh-CN', 'HK': 'zh-HK',
  'TW': 'zh-TW', 'IN': 'en-IN', 'PK': 'ur-PK', 'BD': 'bn-BD', 'LK': 'si-LK', 'NP': 'ne-NP',
  'AU': 'en-AU', 'NZ': 'en-NZ', 'CA': 'en-CA', 'FR': 'fr-FR', 'DE': 'de-DE', 'IT': 'it-IT',
  'ES': 'es-ES', 'PT': 'pt-PT', 'BR': 'pt-BR', 'MX': 'es-MX', 'AR': 'es-AR', 'CL': 'es-CL',
  'CO': 'es-CO', 'PE': 'es-PE', 'RU': 'ru-RU', 'UA': 'uk-UA', 'AE': 'ar-AE', 'SA': 'ar-SA',
  'QA': 'ar-QA', 'KW': 'ar-KW', 'OM': 'ar-OM', 'BH': 'ar-BH', 'EG': 'ar-EG', 'MA': 'ar-MA',
  'TR': 'tr-TR', 'NL': 'nl-NL', 'SE': 'sv-SE', 'NO': 'nb-NO', 'DK': 'da-DK', 'FI': 'fi-FI',
  'PL': 'pl-PL', 'CH': 'de-CH', 'AT': 'de-AT', 'BE': 'nl-BE', 'IE': 'en-IE', 'ZA': 'en-ZA',
  'NG': 'en-NG', 'KE': 'en-KE', 'GH': 'en-GH', 'TZ': 'sw-TZ', 'UG': 'en-UG', 'ET': 'am-ET',
  'IL': 'he-IL', 'GR': 'el-GR', 'CZ': 'cs-CZ', 'HU': 'hu-HU', 'RO': 'ro-RO', 'BG': 'bg-BG',
};

const countryEmergencyMap = {
  'MY': '999', 'US': '911', 'GB': '999', 'SG': '999', 'ID': '112', 'TH': '191',
  'PH': '911', 'VN': '113', 'JP': '110', 'KR': '112', 'CN': '110', 'HK': '999',
  'TW': '110', 'IN': '112', 'PK': '15', 'BD': '999', 'LK': '119', 'NP': '100',
  'AU': '000', 'NZ': '111', 'CA': '911', 'FR': '112', 'DE': '112', 'IT': '112',
  'ES': '112', 'PT': '112', 'BR': '190', 'MX': '911', 'AR': '911', 'CL': '133',
  'CO': '123', 'PE': '105', 'RU': '112', 'UA': '112', 'AE': '999', 'SA': '999',
  'QA': '999', 'KW': '112', 'OM': '9999', 'BH': '999', 'EG': '122', 'MA': '19',
  'TR': '112', 'NL': '112', 'SE': '112', 'NO': '112', 'DK': '112', 'FI': '112',
  'PL': '112', 'CH': '112', 'AT': '112', 'BE': '112', 'IE': '999', 'ZA': '10111',
  'NG': '112', 'KE': '999', 'GH': '112', 'TZ': '112', 'UG': '999', 'ET': '991',
  'IL': '100', 'GR': '112', 'CZ': '112', 'HU': '112', 'RO': '112', 'BG': '112',
};

/// English names (as the Expo catalogue spells them, plus common aliases) for
/// the ISO codes above — the Flutter app has no world catalogue to resolve
/// a typed country name to its code otherwise.
const countryIsoByName = {
  'malaysia': 'MY', 'united states': 'US', 'usa': 'US', 'united kingdom': 'GB', 'uk': 'GB',
  'singapore': 'SG', 'indonesia': 'ID', 'thailand': 'TH', 'philippines': 'PH', 'vietnam': 'VN',
  'viet nam': 'VN', 'japan': 'JP', 'south korea': 'KR', 'korea': 'KR', 'china': 'CN', 'hong kong': 'HK',
  'hong kong s.a.r.': 'HK', 'taiwan': 'TW', 'india': 'IN', 'pakistan': 'PK', 'bangladesh': 'BD',
  'sri lanka': 'LK', 'nepal': 'NP', 'australia': 'AU', 'new zealand': 'NZ', 'canada': 'CA',
  'france': 'FR', 'germany': 'DE', 'italy': 'IT', 'spain': 'ES', 'portugal': 'PT', 'brazil': 'BR',
  'mexico': 'MX', 'argentina': 'AR', 'chile': 'CL', 'colombia': 'CO', 'peru': 'PE', 'russia': 'RU',
  'ukraine': 'UA', 'united arab emirates': 'AE', 'uae': 'AE', 'saudi arabia': 'SA', 'qatar': 'QA',
  'kuwait': 'KW', 'oman': 'OM', 'bahrain': 'BH', 'egypt': 'EG', 'morocco': 'MA', 'turkey': 'TR',
  'netherlands': 'NL', 'sweden': 'SE', 'norway': 'NO', 'denmark': 'DK', 'finland': 'FI',
  'poland': 'PL', 'switzerland': 'CH', 'austria': 'AT', 'belgium': 'BE', 'ireland': 'IE',
  'south africa': 'ZA', 'nigeria': 'NG', 'kenya': 'KE', 'ghana': 'GH', 'tanzania': 'TZ',
  'uganda': 'UG', 'ethiopia': 'ET', 'israel': 'IL', 'greece': 'GR', 'czech republic': 'CZ',
  'czechia': 'CZ', 'hungary': 'HU', 'romania': 'RO', 'bulgaria': 'BG',
};

/// Expo `getCountryDefaults` (minus the Intl-derived date format).
({String emergencyNumber, String languageCode}) countryDefaults(String iso) {
  final code = iso.toUpperCase();
  return (
    emergencyNumber: countryEmergencyMap[code] ?? '',
    languageCode: countryLanguageMap[code] ?? (code.isEmpty ? '' : 'en-$code'),
  );
}

({String emergencyNumber, String languageCode})? countryDefaultsForName(String name) {
  final iso = countryIsoByName[name.trim().toLowerCase()];
  return iso == null ? null : countryDefaults(iso);
}

// ---------------------------------------------------------------------------
// Airport areas (`airport_areas`)
// ---------------------------------------------------------------------------

class AirportForm {
  AirportForm({
    this.name = '',
    this.code = '',
    this.country = '',
    this.state = '',
    this.city = '',
    this.address = '',
    this.lat = '',
    this.lon = '',
    this.placeName = '',
  });

  factory AirportForm.fromValues(Map<String, dynamic> v) {
    String s(String k) => v[k] == null ? '' : '${v[k]}';
    return AirportForm(
      name: s('name'),
      code: s('code'),
      country: s('country'),
      state: s('state'),
      city: s('city'),
      address: s('address'),
      lat: s('lat'),
      lon: s('lon'),
      placeName: s('placeName'),
    );
  }

  String name, code, country, state, city, address, lat, lon, placeName;

  /// Expo `onSave` checks.
  String? validate() {
    if (name.trim().isEmpty) return 'Please fill in Airport Name.';
    if (country.trim().isEmpty) return 'Please fill in Country.';
    if (placeName.trim().isEmpty) return 'Please assign at least one place using the OSM search.';
    return null;
  }

  /// Cleaned values (code upper-cased; lat/lon stay strings like Expo).
  Map<String, dynamic> toValues() => {
        'name': name.trim(),
        'code': code.trim().toUpperCase(),
        'country': country.trim(),
        'state': state.trim(),
        'city': city.trim(),
        'address': address.trim(),
        'lat': lat.trim(),
        'lon': lon.trim(),
        'placeName': placeName.trim(),
      };

  /// Applies a picked search result; region fields are only filled when empty
  /// (Expo `pickPlace`).
  void applyPlace(PlaceResult r) {
    placeName = r.name;
    address = r.address;
    lat = r.lat;
    lon = r.lon;
    if (country.trim().isEmpty && r.country != null) country = r.country!;
    if (state.trim().isEmpty && r.state != null) state = r.state!;
    if (city.trim().isEmpty && r.city != null) city = r.city!;
  }
}

/// Values saved on edit: the form's fields over the stored values, so the
/// stored geofence survives an edit of the airport details.
Map<String, dynamic> airportSaveValues(Map<String, dynamic>? existing, AirportForm f) {
  final kept = <String, dynamic>{};
  if (existing != null) {
    for (final k in const ['boundary', 'boundarySource', 'boundaryUpdatedAt']) {
      if (existing.containsKey(k)) kept[k] = existing[k];
    }
  }
  return {...kept, ...f.toValues()};
}

/// Filter-chip options for the airport list (distinct, sorted).
({List<String> countries, List<String> states, List<String> cities}) airportFilterOptions(
  List<Map<String, dynamic>> values, {
  String country = '',
  String state = '',
}) {
  final cs = <String>{}, ss = <String>{}, ci = <String>{};
  for (final v in values) {
    final c = _s(v['country']);
    if (c.isNotEmpty) cs.add(c);
    if (country.isNotEmpty && '${v['country'] ?? ''}' != country) continue;
    final s = _s(v['state']);
    if (s.isNotEmpty) ss.add(s);
    if (state.isNotEmpty && '${v['state'] ?? ''}' != state) continue;
    final cityName = _s(v['city']);
    if (cityName.isNotEmpty) ci.add(cityName);
  }
  return (countries: cs.toList()..sort(), states: ss.toList()..sort(), cities: ci.toList()..sort());
}

/// Expo airport list filter: exact region matches plus a free-text search over
/// every value.
bool airportMatches(Map<String, dynamic> v, {String query = '', String country = '', String state = '', String city = ''}) {
  if (country.isNotEmpty && '${v['country'] ?? ''}' != country) return false;
  if (state.isNotEmpty && '${v['state'] ?? ''}' != state) return false;
  if (city.isNotEmpty && '${v['city'] ?? ''}' != city) return false;
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return v.values.any((x) => '$x'.toLowerCase().contains(q));
}

/// Parsed lat/lon of a record whose coordinates are stored as strings.
LatLng? latLngOf(Map<String, dynamic> v, {String latKey = 'lat', String lonKey = 'lon'}) {
  final la = _num(v[latKey]);
  final lo = _num(v[lonKey]);
  if (la == null || lo == null || !la.isFinite || !lo.isFinite) return null;
  return LatLng(la, lo);
}

// ---------------------------------------------------------------------------
// Place search results (Nominatim with addressdetails=1)
// ---------------------------------------------------------------------------

class PlaceResult {
  const PlaceResult({
    required this.id,
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
    this.type = 'place',
    this.country,
    this.state,
    this.city,
  });
  final String id;
  final String name;
  final String address;
  final String lat;
  final String lon;
  final String type;
  final String? country;
  final String? state;
  final String? city;
}

/// Address keys tried for the primary name, per screen.
const airportNameKeys = ['aeroway', 'attraction', 'building'];
const placeNameKeys = ['attraction', 'building', 'amenity', 'tourism', 'shop'];

/// One Nominatim search hit → [PlaceResult] (Expo OSM mapping).
PlaceResult placeFromNominatim(Map<String, dynamic> d, {List<String> nameKeys = placeNameKeys}) {
  final addr = <String, dynamic>{...?(d['address'] as Map?)?.cast<String, dynamic>()};
  final display = (d['display_name'] ?? '').toString();
  String? a(String k) {
    final v = addr[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  var primary = (d['name'] is String && (d['name'] as String).isNotEmpty) ? d['name'] as String : null;
  for (final k in nameKeys) {
    primary ??= a(k);
  }
  primary ??= display.split(',').first;
  return PlaceResult(
    id: 'osm-${d['place_id']}',
    name: primary,
    address: display,
    lat: '${d['lat'] ?? ''}',
    lon: '${d['lon'] ?? ''}',
    type: (d['type'] ?? d['class'] ?? d['category'] ?? 'place').toString(),
    country: a('country'),
    state: a('state') ?? a('region'),
    city: a('city') ?? a('town') ?? a('village') ?? a('municipality') ?? a('county'),
  );
}

/// Drops results without finite coordinates and repeats at the same rounded
/// position ([digits] decimals: 4 for airports, 3 for multi-gate places).
List<PlaceResult> dedupePlaces(List<PlaceResult> list, {int digits = 4}) {
  final seen = <String>{};
  final out = <PlaceResult>[];
  for (final r in list) {
    final la = double.tryParse(r.lat), lo = double.tryParse(r.lon);
    if (la == null || lo == null || !la.isFinite || !lo.isFinite) continue;
    if (seen.add('${la.toStringAsFixed(digits)},${lo.toStringAsFixed(digits)}')) out.add(r);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Multi-gate places & gates (`multi_gate`, kind 'place' / 'gate')
// ---------------------------------------------------------------------------

const multiGatePlacesKey = 'multi-gate-places';
const airportAreasKey = 'airport-areas';

bool _flag(Object? v, {bool fallback = true}) => v == null ? fallback : (v == true || (v is num && v != 0) || (v is String && v.isNotEmpty && v != 'false'));

class PlaceForm {
  PlaceForm({
    this.name = '',
    this.gates = '',
    this.address = '',
    this.lat = '',
    this.lon = '',
    this.gateRequired = true,
    this.active = true,
  });

  factory PlaceForm.fromValues(Map<String, dynamic> v) => PlaceForm(
        name: '${v['name'] ?? ''}',
        gates: '${v['gates'] ?? ''}',
        address: '${v['address'] ?? ''}',
        lat: '${v['lat'] ?? ''}',
        lon: '${v['lon'] ?? ''}',
        gateRequired: _flag(v['gateRequired']),
        active: _flag(v['active']),
      );

  /// Pre-filled from a search hit (2 gates by default, like Expo).
  factory PlaceForm.fromResult(PlaceResult r) =>
      PlaceForm(name: r.name, gates: '2', address: r.address, lat: r.lat, lon: r.lon);

  String name, gates, address, lat, lon;
  bool gateRequired, active;

  String? validate() {
    if (name.trim().isEmpty) return 'Please enter a place name.';
    final n = _parseIntPrefix(gates);
    if (n == null || n < 1) return 'Number of gates must be at least 1.';
    return null;
  }

  Map<String, dynamic> toValues() => {
        'name': name.trim(),
        'gates': _parseIntPrefix(gates),
        'address': address.trim(),
        'lat': lat.trim(),
        'lon': lon.trim(),
        'gateRequired': gateRequired,
        'active': active,
      };
}

/// JS `parseInt(s, 10)`: leading integer, null when none.
int? _parseIntPrefix(String s) {
  final m = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
  return m == null ? null : int.tryParse(m.group(1)!);
}

bool placeIsActive(Map<String, dynamic> v) => _flag(v['active']);
bool placeGateRequired(Map<String, dynamic> v) => _flag(v['gateRequired']);

enum GateMode { both, pickup, drop }

GateMode parseGateMode(Object? raw) => switch ('${raw ?? 'both'}') {
      'pickup' => GateMode.pickup,
      'drop' => GateMode.drop,
      _ => GateMode.both,
    };

String gateModeLabel(GateMode m) => switch (m) {
      GateMode.both => 'Both',
      GateMode.pickup => 'Pick up',
      GateMode.drop => 'Drop',
    };

/// Expo `parseSurcharge`: '' unless a finite number ≥ 0 (stored as a string).
String parseSurcharge(String s) {
  final t = s.trim();
  if (t.isEmpty) return '';
  final n = double.tryParse(t);
  if (n == null || !n.isFinite || n < 0) return '';
  return _jsNumber(n);
}

/// Number formatted as JS `String(n)` for the common cases (no trailing `.0`).
String _jsNumber(double n) => n == n.truncateToDouble() && n.abs() < 1e15 ? n.toInt().toString() : n.toString();

/// Displayed surcharge, or null when none applies for the gate's mode.
double? gateSurcharge(Map<String, dynamic> v, {required bool pickup}) {
  final mode = parseGateMode(v['mode']);
  if (pickup && mode == GateMode.drop) return null;
  if (!pickup && mode == GateMode.pickup) return null;
  final n = _num(v[pickup ? 'pickupSurcharge' : 'dropSurcharge']);
  return (n != null && n.isFinite && n > 0) ? n : null;
}

class GateForm {
  GateForm({
    this.name = '',
    this.lat = '',
    this.lon = '',
    this.displayPriority = 1,
    this.active = true,
    this.mode = GateMode.both,
    this.pickupSurcharge = '',
    this.dropSurcharge = '',
  });

  factory GateForm.fromValues(Map<String, dynamic> v) {
    String sur(String k) => v[k] == null ? '' : '${v[k]}';
    return GateForm(
      name: '${v['name'] ?? ''}',
      lat: '${v['lat'] ?? ''}',
      lon: '${v['lon'] ?? ''}',
      displayPriority: _priority(v['displayPriority']),
      active: _flag(v['active']),
      mode: parseGateMode(v['mode']),
      pickupSurcharge: sur('pickupSurcharge'),
      dropSurcharge: sur('dropSurcharge'),
    );
  }

  static int _priority(Object? raw) {
    final p = _num(raw);
    return (p == null || p == 0 || p.isNaN) ? 1 : p.toInt();
  }

  /// New gate: "Gate N" at the place's position (Expo `openAdd`).
  factory GateForm.next(int existingCount, LatLng at) => GateForm(
        name: 'Gate ${existingCount + 1}',
        lat: _jsNumber(at.latitude),
        lon: _jsNumber(at.longitude),
        displayPriority: existingCount + 1,
      );

  String name, lat, lon;
  int displayPriority;
  bool active;
  GateMode mode;
  String pickupSurcharge, dropSurcharge;

  String? validate() {
    if (name.trim().isEmpty) return 'Please enter a gate name.';
    final la = double.tryParse(lat.trim()), lo = double.tryParse(lon.trim());
    if (la == null || lo == null || !la.isFinite || !lo.isFinite) {
      return 'Please provide a valid latitude and longitude.';
    }
    return null;
  }

  Map<String, dynamic> toValues({required String placeId, required String parentKey}) => {
        'placeId': placeId,
        'parentKey': parentKey,
        'name': name.trim(),
        'lat': _jsNumber(double.parse(lat.trim())),
        'lon': _jsNumber(double.parse(lon.trim())),
        'displayPriority': displayPriority,
        'active': active,
        'mode': mode.name,
        'pickupSurcharge': mode == GateMode.drop ? '' : parseSurcharge(pickupSurcharge),
        'dropSurcharge': mode == GateMode.pickup ? '' : parseSurcharge(dropSurcharge),
      };
}

/// Fallback position for a place with no coordinates (Kuala Lumpur).
LatLng placeCenter(Map<String, dynamic>? v) {
  final la = _num(v?['lat']);
  final lo = _num(v?['lon']);
  return LatLng((la == null || la == 0 || !la.isFinite) ? 3.139 : la, (lo == null || lo == 0 || !lo.isFinite) ? 101.6869 : lo);
}

/// Gates belonging to one place (gates without a `parentKey` belong to
/// multi-gate places), sorted by `displayPriority` (missing last).
List<T> gatesForPlace<T>(List<T> gates, Map<String, dynamic> Function(T) values, String placeId, String parentKey) {
  final list = gates.where((g) {
    final v = values(g);
    return '${v['placeId'] ?? ''}' == placeId && '${v['parentKey'] ?? multiGatePlacesKey}' == parentKey;
  }).toList();
  double prio(T g) => _num(values(g)['displayPriority']) ?? 9999;
  list.sort((a, b) => prio(a).compareTo(prio(b)));
  return list;
}

/// Moves [id] one step ([dir] = -1 up, +1 down) in [sortedIds] and returns
/// the gates whose 1-based priority changed (Expo `moveGate`).
Map<String, int> reorderGates(List<String> sortedIds, Map<String, num?> currentPriority, String id, int dir) {
  final from = sortedIds.indexOf(id);
  if (from == -1) return {};
  final to = from + dir;
  if (to < 0 || to >= sortedIds.length) return {};
  final next = [...sortedIds];
  final m = next.removeAt(from);
  next.insert(to, m);
  final out = <String, int>{};
  for (var i = 0; i < next.length; i++) {
    final want = i + 1;
    if ((currentPriority[next[i]] ?? -1) != want) out[next[i]] = want;
  }
  return out;
}
