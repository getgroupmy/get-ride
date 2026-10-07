// A street hail with a destination (Expo `partner-teksi.tsx`, "Trip
// summary"): the driver sets where the passenger is going, sees the route
// and what the meter's own rate card would charge for it, and starts the
// meter. The meter still bills what it measures; the estimate is a quote,
// and is printed as one. Pure.
import 'dart:math' as math;

import '../admin/screens/meterapp/meter_logic.dart';

/// Where a hailed passenger asked to go, with the route found to it.
class HailDestination {
  const HailDestination({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.address,
    this.routeKm,
    this.routeMin,
  });

  final String name;
  final String? address;
  final double latitude;
  final double longitude;

  /// The planned route from where the hail was taken; null when no route
  /// could be found (no estimate is then given).
  final double? routeKm;
  final double? routeMin;

  bool get hasRoute => routeKm != null && routeKm! > 0 && routeMin != null && routeMin! >= 0;
}

/// What [rates] would charge for the planned route, at [multiplier] (the
/// night shift). Null without a route.
///
/// A card that bills time from the flag distance only bills the share of the
/// time spent past it, as Expo's `calculateFare` estimates the TEKSI tariff.
double? hailEstimate(MeterRates rates, HailDestination d, {double multiplier = 1}) {
  if (!d.hasRoute) return null;
  final metres = d.routeKm! * 1000;
  final ms = (d.routeMin! * 60000).round();
  final flag = math.max(0, rates.flagDistanceM).toDouble();
  final pastFlag = metres <= flag ? 0 : (ms * (1 - flag / metres)).round();
  return computeMeterFareTotal(rates, distanceM: metres, elapsedMs: ms, chargeableMs: pastFlag, multiplier: multiplier);
}

/// `8.2 km · ~18 min`.
String describeHailRoute(HailDestination d) {
  if (!d.hasRoute) return 'No route found';
  return '${d.routeKm!.toStringAsFixed(1)} km · ~${math.max(1, d.routeMin!.round())} min';
}
