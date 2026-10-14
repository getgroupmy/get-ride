// Ending a trip before the drop-off (Expo `ride-running`'s "End ride early?").
//
// Expo recalculated the fare from the pickup to where the driver stopped but
// only showed it on the driver's own receipt: the ride row kept the full
// fare, so the passenger was billed, rewarded and charged commission on a
// trip that never happened. Here the recalculated fare is what the ride is
// stored at (`ride_fare`), so every reader of the row agrees.
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'commission.dart' show Geo;
import 'fare.dart';
import 'fare_tariff.dart';
import 'region_pricing.dart';

/// Closer than this to the drop-off is arriving, not ending early.
const earlyEndRadiusMetres = 300.0;

const _distance = Distance();

/// Whether completing at [at] ends the trip short of [drop]. Unknown either
/// way is not early: the driver completes as usual.
bool endsEarly(LatLng? at, LatLng? drop) => at != null && drop != null && _distance(at, drop) > earlyEndRadiusMetres;

/// The least an early end charges: what a trip of no distance costs on the
/// tariff the ride was priced on (its base fare, minimum and booking fee),
/// as a meter charges at least its flag fall. [card] is the Admin → Fare
/// tariffs card for the pickup and service; null is the built-in TEKSI
/// tariff, with the service's [multiplier].
double earlyEndFloor(FareTariff? card, {double multiplier = 1}) =>
    quoteFare(card, 0, 0, multiplier: multiplier).fare;

/// The tariff card a ride was priced on: the pickup's area from the ride row
/// and its service, matched by name in the catalogue ([services]: catalogue
/// id → service-type ids). Null for the built-in TEKSI tariff.
FareTariff? rideTariffCard(
  List<FareTariff> cards,
  Map<String, dynamic> ride, {
  String? vehicleServiceId,
  Set<String> serviceTypes = const {},
}) {
  String? s(String k) => ride[k] is String && (ride[k] as String).trim().isNotEmpty ? ride[k] as String : null;
  return resolveFareTariff(
    cards,
    Geo(country: s('country'), state: s('state'), city: s('city'), suburb: s('suburb')),
    vehicleService: vehicleServiceId,
    serviceTypes: serviceTypes,
  );
}

/// The Service Settings ids of [s]'s types ([names]: id → type name), which
/// tariff cards for a type are keyed by.
Set<String> serviceTypeIds(RideService s, Map<String, String> names) {
  final wanted = {for (final n in s.serviceTypes) n.trim().toLowerCase()};
  return {
    for (final e in names.entries)
      if (wanted.contains(e.value.trim().toLowerCase())) e.key,
  };
}

/// The fare for a trip ended after [drivenKm] of the [plannedKm] booked: the
/// agreed fare in proportion to the distance covered, never more than the
/// agreed fare and never less than [floor] (a hire that began is charged at
/// least the flag fall of its tariff, see [earlyEndFloor]; the built-in
/// TEKSI one when not given). The agreed fare is kept
/// whenever the proportion can't be known. Rounded as the ride's region
/// books fares ([pricing]: up to a whole amount where whole fares are on,
/// else to the cent), and still never above the agreed fare, which the
/// server refuses (0174).
double earlyEndFare({
  required double agreed,
  required double? plannedKm,
  required double? drivenKm,
  RegionPricing pricing = RegionPricing.none,
  double? floor,
}) {
  if (agreed <= 0) return 0;
  if (plannedKm == null || plannedKm <= 0 || drivenKm == null || drivenKm < 0) return agreed;
  final share = math.min(1.0, drivenKm / plannedKm);
  final least = math.min(agreed, floor ?? calculateFare(0, 0));
  return math.min(agreed, pricing.roundFare(math.max(least, agreed * share)));
}
