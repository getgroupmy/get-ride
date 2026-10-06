// The rider's live map once a driver is assigned (Expo `ride-tracking`):
// where the driver is heading, when to fetch the road route again, and the
// ETA line. Pure.
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

const _distance = Distance();

/// Whether to ask for a new route: none yet, the destination changed, the
/// driver moved [rerouteAfterMetres], or [rerouteAfter] has passed. Live
/// positions arrive every few seconds; routing each one would hammer the
/// public routing server.
bool shouldReroute({
  required LatLng from,
  required LatLng to,
  required DateTime now,
  LatLng? lastFrom,
  LatLng? lastTo,
  DateTime? lastAt,
}) {
  if (lastFrom == null || lastTo == null || lastAt == null) return true;
  if (lastTo != to) return true;
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
