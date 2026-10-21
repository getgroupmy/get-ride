/// The rider's gate at an airport or a place with a boundary (migrations 0249
/// and 0258): which area a pickup is in, the gate it snaps to, and how the
/// gate picker lists the gates. Pure.
///
/// A pickup dropped anywhere inside an area that has pickup gates snaps to
/// the nearest of them (straight-line distance); outside every area, or in
/// one without gates, it stays where it was dropped. Where boundaries
/// overlap, the area is the server's (`area_at`, 0266): the smallest place,
/// then an airport.
library;

import 'package:latlong2/latlong.dart';

import 'airport_areas.dart';
import 'airport_queue.dart';

/// The area holding [p] (no buffer), by the server's precedence.
AirportArea? gateAreaAt(List<AirportArea> areas, LatLng p) {
  for (final a in areasByPrecedence(areas)) {
    if (a.contains(p, bufferM: 0)) return a;
  }
  return null;
}

/// The point of a door, or null when the admin left it blank.
LatLng? doorPoint(AirportDoor d) => d.lat == null || d.lng == null ? null : LatLng(d.lat!, d.lng!);

/// The door of [gates] nearest to [p] in a straight line, among those with
/// a point; null when none has one.
AirportDoor? nearestGate(List<AirportDoor> gates, LatLng p) {
  const distance = Distance();
  AirportDoor? best;
  var bestM = double.infinity;
  for (final g in gates) {
    final at = doorPoint(g);
    if (at == null) continue;
    final m = distance.as(LengthUnit.Meter, p, at);
    if (m < bestM) {
      bestM = m;
      best = g;
    }
  }
  return best;
}

/// Where a pickup (or drop-off, [side]) at [p] snaps to.
typedef GateSnap = ({AirportArea area, List<AirportDoor> gates, AirportDoor door});

/// The area [p] is in and the nearest of its gates for [side]; null when
/// [p] is in no area, or its area has no gate with a point.
GateSnap? snapToGate({
  required List<AirportArea> areas,
  required List<AirportDoor> doors,
  required LatLng p,
  AirportSide side = AirportSide.pick,
}) {
  final area = gateAreaAt(areas, p);
  if (area == null) return null;
  final gates = doorsFor(doors, area.id, side);
  final door = nearestGate(gates, p);
  if (door == null) return null;
  return (area: area, gates: gates, door: door);
}

/// "A", "B", … "Z", "AA", … for the [i]th gate (0-based).
String gateLetter(int i) {
  var n = i;
  var s = '';
  do {
    s = String.fromCharCode(65 + n % 26) + s;
    n = n ~/ 26 - 1;
  } while (n >= 0);
  return s;
}

/// A group of gates (a terminal) and its gates, in the admin's order.
typedef GateGroup = ({String name, List<AirportDoor> gates});

/// [gates] by their group, the groups in the order they first appear; one
/// group (named '') when they have fewer than two different groups. A gate
/// with no group joins a group named 'Other' when the rest have groups.
List<GateGroup> gateGroups(List<AirportDoor> gates) {
  final names = <String>[];
  for (final g in gates) {
    if (g.group.isNotEmpty && !names.contains(g.group)) names.add(g.group);
  }
  if (names.length < 2) return [(name: '', gates: gates)];
  final hasNone = gates.any((g) => g.group.isEmpty);
  return [
    for (final n in names) (name: n, gates: [for (final g in gates) if (g.group == n) g]),
    if (hasNone) (name: 'Other', gates: [for (final g in gates) if (g.group.isEmpty) g]),
  ];
}

/// The group and the place in it of the gate [id] (0, 0 when not found).
(int, int) gateIndex(List<GateGroup> groups, String? id) {
  for (var gi = 0; gi < groups.length; gi++) {
    final i = groups[gi].gates.indexWhere((g) => g.id == id);
    if (i >= 0) return (gi, i);
  }
  return (0, 0);
}

/// The one outline of an area to draw around [focus] (the chosen gate, or
/// the pickup): an area copied from OpenStreetMap can hold many pieces
/// (KLIA's terminals, its runways), and drawing them all buries the gates.
/// The smallest piece holding [focus], else the nearest; every piece when
/// there is no [focus].
List<List<LatLng>> ringsAround(List<List<LatLng>> rings, LatLng? focus) {
  final usable = [for (final r in rings) if (r.length >= 3) r];
  if (focus == null || usable.length < 2) return usable;
  final holding = [for (final r in usable) if (ringContains(r, focus)) r];
  if (holding.isNotEmpty) {
    holding.sort((a, b) => ringBoxSize(a).compareTo(ringBoxSize(b)));
    return [holding.first];
  }
  var best = usable.first;
  var bestM = double.infinity;
  for (final r in usable) {
    final m = ringDistanceM(r, focus);
    if (m < bestM) {
      bestM = m;
      best = r;
    }
  }
  return [best];
}
