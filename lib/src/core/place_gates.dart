import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';

/// Multi-gate places (Expo `components/PlaceGates.tsx`): venues the admin has
/// mapped with several gates — a mall, a stadium, an airport — so a rider
/// picks the gate they'll actually be at instead of a pin in the middle of
/// the building. Places come from `multi_gate` (kind `place`) and
/// `airport_areas`; gates from `multi_gate` (kind `gate`, `values.placeId`).

/// How close a search result must be to an admin place to count as it.
const gateMatchRadiusKm = 1.5;

enum GateUsage { pickup, drop }

/// An admin row: `{id, values}`.
typedef GateRow = ({String id, Map<String, dynamic> values});

class GateOption {
  const GateOption({required this.id, required this.name, this.point});
  final String id;
  final String name;

  /// Null when the admin left the gate's coordinates blank: the place's own
  /// point is used then.
  final LatLng? point;
}

class GatedPlace {
  const GatedPlace({required this.id, required this.name, required this.gates, required this.gateRequired});
  final String id;
  final String name;
  final List<GateOption> gates;

  /// Whether the rider must pick a gate (the place itself can't be tapped).
  /// Defaults to true, as in Expo.
  final bool gateRequired;

  /// Whether tapping the place itself is refused in favour of its gates.
  bool get blocksPlace => gateRequired && gates.isNotEmpty;
}

double? _num(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.trim());
  return n == null || !n.isFinite ? null : n;
}

bool _flag(Object? v, {bool fallback = true}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = '$v'.trim().toLowerCase();
  if (s.isEmpty) return fallback;
  return !(s == 'false' || s == '0' || s == 'no' || s == 'off');
}

String _normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

LatLng? _point(Map<String, dynamic> v) {
  final lat = _num(v['lat']), lon = _num(v['lon'] ?? v['lng']);
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
  return LatLng(lat, lon);
}

String _mode(Object? raw) => switch ('${raw ?? 'both'}') {
  'pickup' => 'pickup',
  'drop' => 'drop',
  _ => 'both',
};

/// The admin place a search result is at (nearest within
/// [gateMatchRadiusKm], else by name), with its active gates for [usage] in
/// display-priority order. Null when it isn't an admin place, or the place
/// is switched off.
GatedPlace? matchGatedPlace({
  required List<GateRow> places,
  required List<GateRow> gates,
  LatLng? point,
  String? name,
  GateUsage? usage,
}) {
  if (places.isEmpty) return null;
  GateRow? place;
  if (point != null) {
    const distance = Distance();
    var best = double.infinity;
    for (final p in places) {
      final at = _point(p.values);
      if (at == null) continue;
      final km = distance.as(LengthUnit.Meter, point, at) / 1000;
      if (km <= gateMatchRadiusKm && km < best) {
        best = km;
        place = p;
      }
    }
  }
  final q = _normalize(name ?? '');
  if (place == null && q.isNotEmpty) {
    for (final p in places) {
      final pn = _normalize('${p.values['name'] ?? ''}');
      if (pn.isNotEmpty && (pn == q || pn.contains(q) || q.contains(pn))) {
        place = p;
        break;
      }
    }
  }
  if (place == null || !_flag(place.values['active'])) return null;

  final mine = [
    for (final g in gates)
      if ('${g.values['placeId'] ?? ''}' == place.id && _flag(g.values['active']))
        if (usage == null || _mode(g.values['mode']) == 'both' || _mode(g.values['mode']) == usage.name) g,
  ]..sort((a, b) => (_num(a.values['displayPriority']) ?? 9999).compareTo(_num(b.values['displayPriority']) ?? 9999));

  return GatedPlace(
    id: place.id,
    name: '${place.values['name'] ?? ''}'.trim(),
    gateRequired: _flag(place.values['gateRequired']),
    gates: [
      for (final g in mine)
        GateOption(
          id: g.id,
          name: '${g.values['name'] ?? ''}'.trim().isEmpty ? 'Gate' : '${g.values['name']}'.trim(),
          point: _point(g.values),
        ),
    ],
  );
}

/// The place a rider picked at [gate]: "Place - Gate", at the gate's own
/// coordinates when the admin mapped them.
Place gatePlace(Place base, GatedPlace place, GateOption gate) {
  final label = '${place.name.isEmpty ? base.name : place.name} - ${gate.name}';
  return Place(name: label, address: base.address, point: gate.point ?? base.point);
}
