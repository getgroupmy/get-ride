// Ending a trip before the drop-off (Expo `ride-running`'s "End ride early?").
//
// Expo recalculated the fare from the pickup to where the driver stopped but
// only showed it on the driver's own receipt: the ride row kept the full
// fare, so the passenger was billed, rewarded and charged commission on a
// trip that never happened. Here the recalculated fare is what the ride is
// stored at (`ride_fare`), so every reader of the row agrees.
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'fare.dart';

/// Closer than this to the drop-off is arriving, not ending early.
const earlyEndRadiusMetres = 300.0;

const _distance = Distance();

/// Whether completing at [at] ends the trip short of [drop]. Unknown either
/// way is not early: the driver completes as usual.
bool endsEarly(LatLng? at, LatLng? drop) => at != null && drop != null && _distance(at, drop) > earlyEndRadiusMetres;

/// The fare for a trip ended after [drivenKm] of the [plannedKm] booked: the
/// agreed fare in proportion to the distance covered, never more than the
/// agreed fare and never less than the flag fall (a hire that began is
/// charged at least that much, as the meter would). The agreed fare is kept
/// whenever the proportion can't be known. Rounded to the cent.
double earlyEndFare({required double agreed, required double? plannedKm, required double? drivenKm}) {
  if (agreed <= 0) return 0;
  if (plannedKm == null || plannedKm <= 0 || drivenKm == null || drivenKm < 0) return agreed;
  final share = math.min(1.0, drivenKm / plannedKm);
  final floor = math.min(agreed, calculateFare(0, 0));
  return double.parse(math.max(floor, agreed * share).toStringAsFixed(2));
}
