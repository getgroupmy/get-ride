/// Destination mode for partners (Expo `partner-ehailing.tsx`, whose toggle
/// read "Prioritising requests toward destination" but never touched the
/// queue): a driver heading somewhere — home, the end of a shift — sees the
/// requests that take them there first, and auto-accept takes only those.
library;

import 'package:latlong2/latlong.dart';

/// A trip must bring the driver at least this much closer to count.
const towardMinGainKm = 2.0;

/// …and at least this share of its own length must be progress, so a long
/// detour that happens to end a little closer does not count.
const towardMinShare = 0.5;

double _km(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b) / 1000;

/// How much closer to [destination] the trip from [pickup] to [drop] leaves
/// the driver, in straight-line km (negative: further away).
double destinationGainKm({required LatLng pickup, required LatLng drop, required LatLng destination}) =>
    _km(pickup, destination) - _km(drop, destination);

/// Whether the trip heads toward [destination]: real progress, and mostly
/// progress rather than detour.
bool headsToward({required LatLng pickup, required LatLng drop, required LatLng destination}) {
  final gain = destinationGainKm(pickup: pickup, drop: drop, destination: destination);
  return gain >= towardMinGainKm && gain >= towardMinShare * _km(pickup, drop);
}

/// [items] with the ones heading toward the destination first, each group
/// nearest first (unknown distance last).
List<T> destinationOrder<T>(List<T> items, {required bool Function(T) toward, required double? Function(T) awayKm}) {
  int rank(T x) => toward(x) ? 0 : 1;
  return [...items]..sort((a, b) {
    final c = rank(a).compareTo(rank(b));
    return c != 0 ? c : (awayKm(a) ?? 1e9).compareTo(awayKm(b) ?? 1e9);
  });
}
