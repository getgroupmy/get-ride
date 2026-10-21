import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'airport_queue.dart';

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
  const GatedPlace({
    required this.id,
    required this.name,
    required this.gates,
    required this.gateRequired,
    this.typeKey,
    this.address = '',
    this.iconColor,
    this.point,
    this.partOf = '',
  });
  final String id;
  final String name;
  final List<GateOption> gates;

  /// The place's type key (0264's `values.placeType`; 'airport' for an
  /// airport); null when it has none (shown as Other).
  final String? typeKey;

  /// The address the admin keeps for the place ('' for none).
  final String address;

  /// The chip colour Google gave the place (`values.iconBackgroundColor`,
  /// `#RRGGBB`), when it came from Places search; null for the type's own.
  final String? iconColor;

  /// The place's own point (`values.lat` / `lon`); null when it has none.
  final LatLng? point;

  /// The admin's "Part of" name (`values.partOf`, '' for none): places with
  /// the same one open together in the door sheet ([linkedGatedPlaces]).
  final String partOf;

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

/// The admin place a search result is at (the one of exactly that name,
/// else the airport whose boundary holds the result ([airportId]), else the
/// nearest within [gateMatchRadiusKm], else by name), with its active gates
/// for [usage] in display-priority order. Null when it isn't an admin place,
/// or the place is switched off. The exact name and the airport come first
/// so an airport result (shown at its boundary's centre) or an address in
/// the airport ("KLIA2 Arrival Lane") is the airport, not a smaller place
/// nearer that point (an ERL station).
GatedPlace? matchGatedPlace({
  required List<GateRow> places,
  required List<GateRow> gates,
  LatLng? point,
  String? name,
  GateUsage? usage,
  String? airportId,
}) {
  if (places.isEmpty) return null;
  final q = _normalize(name ?? '');
  GateRow? place = q.isEmpty ? null : places.where((p) => _normalize('${p.values['name'] ?? ''}') == q).firstOrNull;
  if (place == null && airportId != null) place = places.where((p) => p.id == airportId).firstOrNull;
  if (place == null && point != null) {
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
  return gatedPlaceOf(place, gates, usage: usage);
}

/// [place] with its active gates for [usage] (every gate when null), in
/// display-priority order.
GatedPlace gatedPlaceOf(GateRow place, List<GateRow> gates, {GateUsage? usage}) {
  final mine = [
    for (final g in gates)
      if ('${g.values['placeId'] ?? ''}' == place.id && _flag(g.values['active']))
        if (usage == null || _mode(g.values['mode']) == 'both' || _mode(g.values['mode']) == usage.name) g,
  ]..sort((a, b) => (_num(a.values['displayPriority']) ?? 9999).compareTo(_num(b.values['displayPriority']) ?? 9999));

  final type = '${place.values['placeType'] ?? ''}'.trim();
  return GatedPlace(
    id: place.id,
    name: '${place.values['name'] ?? ''}'.trim(),
    gateRequired: _flag(place.values['gateRequired']),
    typeKey: type.isEmpty ? null : type,
    address: '${place.values['address'] ?? ''}'.trim(),
    iconColor: RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch('${place.values['iconBackgroundColor'] ?? ''}')
        ? '${place.values['iconBackgroundColor']}'
        : null,
    point: _point(place.values),
    partOf: '${place.values['partOf'] ?? ''}'.trim(),
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

/// A "Part of" name as compared: trimmed, one space between words, any
/// case ('' for none).
String partOfKey(Object? partOf) => '${partOf ?? ''}'.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// A place's order among the places it is part of (`values.partOrder`, 1
/// when unset).
num partOrderOf(Map<String, dynamic> values) => _num(values['partOrder']) ?? 1;

/// The place [placeId] and the other active places that share its "Part
/// of" name (KLIA Terminal 1 and 2, both part of KLIA), in their order and
/// then by name, each with its gates for [usage]. Just the place when it is
/// part of nothing; empty when it isn't listed.
List<GatedPlace> linkedGatedPlaces({
  required List<GateRow> places,
  required List<GateRow> gates,
  required String placeId,
  GateUsage? usage,
}) {
  final place = places.where((p) => p.id == placeId).firstOrNull;
  if (place == null) return const [];
  final key = partOfKey(place.values['partOf']);
  if (key.isEmpty) return [gatedPlaceOf(place, gates, usage: usage)];
  final linked = [
    for (final p in places)
      if (partOfKey(p.values['partOf']) == key && (p.id == placeId || _flag(p.values['active']))) p,
  ];
  String name(GateRow p) => '${p.values['name'] ?? ''}'.trim().toLowerCase();
  linked.sort((a, b) {
    final c = partOrderOf(a.values).compareTo(partOrderOf(b.values));
    return c != 0 ? c : name(a).compareTo(name(b));
  });
  return [for (final p in linked) gatedPlaceOf(p, gates, usage: usage)];
}

/// The doors of [linked] for the door sheet, from the gate rows' values
/// ([rows], by id): each door in a group named after its place, so the
/// sheet's left wheel lists the places in their order. A name two places
/// share gets a number, so their doors stay apart.
List<AirportDoor> linkedPlaceDoors(List<GatedPlace> linked, Map<String, Map<String, dynamic>> rows) {
  final used = <String>{};
  final doors = <AirportDoor>[];
  for (final place in linked) {
    final base = place.name.isEmpty ? 'Place' : place.name;
    var group = base;
    for (var n = 2; !used.add(group.toLowerCase()); n++) {
      group = '$base ($n)';
    }
    for (final g in place.gates) {
      if (rows[g.id] case final v?) doors.add(AirportDoor.fromGate(g.id, v).withGroup(group));
    }
  }
  return doors;
}

/// The place a rider picked at [gate]: "Place - Gate", at the gate's own
/// coordinates when the admin mapped them.
Place gatePlace(Place base, GatedPlace place, GateOption gate) {
  final label = '${place.name.isEmpty ? base.name : place.name} - ${gate.name}';
  return Place(name: label, address: base.address, point: gate.point ?? base.point);
}
