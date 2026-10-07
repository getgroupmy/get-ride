// The rider's live map once a driver is assigned (Expo `ride-tracking`):
// where the driver is heading, when to fetch the road route again, and the
// ETA line. Pure.
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../data/models.dart';

/// Where the driver is going now: the pickup until they arrive, the
/// drop-off on the trip, nowhere otherwise (waiting at the pickup, or done).
LatLng? etaTarget(RideStatus status, {LatLng? pickup, LatLng? drop}) => switch (status) {
  RideStatus.accepted => pickup,
  RideStatus.onTrip => drop,
  _ => null,
};

/// A road route is fetched again once the driver has moved this far…
const rerouteAfterMetres = 150.0;

/// …or this long has passed, so the ETA keeps up with traffic.
const rerouteAfter = Duration(seconds: 60);

/// A driver this far from the route's line has left it (GPS drifts a few
/// tens of metres on a good road)…
const offRouteMetres = 45.0;

/// …and is rerouted, but no more often than this.
const rerouteOffRouteGap = Duration(seconds: 8);

const _distance = Distance();

/// Whether to ask for a new route: none yet, the destination changed, the
/// driver moved [rerouteAfterMetres], or [rerouteAfter] has passed. Live
/// positions arrive every few seconds; routing each one would hammer the
/// public routing server.
///
/// [offRoute]: the driver has left the road the route takes (a missed or
/// different turn), which reroutes at once — no sooner than
/// [rerouteOffRouteGap] after the last fetch, so a car parked a little off
/// the line doesn't fetch on every fix.
bool shouldReroute({
  required LatLng from,
  required LatLng to,
  required DateTime now,
  LatLng? lastFrom,
  LatLng? lastTo,
  DateTime? lastAt,
  bool offRoute = false,
}) {
  if (lastFrom == null || lastTo == null || lastAt == null) return true;
  if (lastTo != to) return true;
  if (offRoute && now.difference(lastAt) >= rerouteOffRouteGap) return true;
  if (_distance(lastFrom, from) >= rerouteAfterMetres) return true;
  return now.difference(lastAt) >= rerouteAfter;
}

/// `Arriving in 6 min · 10:42 · 2.3 km` (to the pickup) or `Arrive at 10:58 ·
/// 14 min · 9.8 km` (on the trip). Never says 0 min.
String etaLabel({required double minutes, required double km, required DateTime now, required bool toPickup}) {
  final mins = minutes.ceil().clamp(1, 24 * 60);
  final at = now.add(Duration(minutes: mins));
  final clock = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final dist = '${km.toStringAsFixed(1)} km';
  return toPickup ? 'Arriving in $mins min · $clock · $dist' : 'Arrive at $clock · $mins min · $dist';
}

/// The road still ahead of [at] on [route]: the route from the point on it
/// nearest [at] (which starts the line) to the end, plus how far [at] is
/// from the route in metres. Null for a route of fewer than two points.
({List<LatLng> points, double offBy})? routeAhead(List<LatLng> route, LatLng at) {
  if (route.length < 2) return null;
  var best = double.infinity;
  var bestIndex = 0;
  var bestPoint = route.first;
  for (var i = 0; i < route.length - 1; i++) {
    final p = _nearestOnSegment(at, route[i], route[i + 1]);
    final d = _distance(at, p);
    if (d < best) {
      best = d;
      bestIndex = i;
      bestPoint = p;
    }
  }
  return (points: [bestPoint, ...route.sublist(bestIndex + 1)], offBy: best);
}

/// Length of a line in kilometres.
double lineKm(List<LatLng> points) {
  var m = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    m += _distance(points[i], points[i + 1]);
  }
  return m / 1000;
}

/// Minutes and kilometres left: the route's time and road distance scaled
/// by the share of its line still [ahead] of the car, so the ETA counts
/// down between route fetches.
({double minutes, double km}) etaAhead({
  required double routeMinutes,
  required double routeKm,
  required List<LatLng> route,
  required List<LatLng> ahead,
}) {
  final whole = lineKm(route);
  final share = whole <= 0 ? 1.0 : (lineKm(ahead) / whole).clamp(0.0, 1.0);
  return (minutes: routeMinutes * share, km: routeKm * share);
}

/// The point on segment [a]–[b] nearest [p], on a local flat projection
/// (fine at street scale).
LatLng _nearestOnSegment(LatLng p, LatLng a, LatLng b) {
  final k = math.cos(p.latitude * math.pi / 180);
  final ax = a.longitude * k, ay = a.latitude;
  final bx = b.longitude * k, by = b.latitude;
  final px = p.longitude * k, py = p.latitude;
  final dx = bx - ax, dy = by - ay;
  final len = dx * dx + dy * dy;
  final t = len == 0 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / len).clamp(0.0, 1.0);
  return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
}
