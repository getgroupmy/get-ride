import 'dart:math' as math;

/// TEKSI tariffs, ported from `calculateFare` in the Expo app's
/// `utils/maps.ts` so both clients quote the same fare for the same trip.
enum Tariff { old, newTariff }

double calculateFare(
  double distanceKm,
  double durationMin, {
  double multiplier = 1,
  Tariff tariff = Tariff.old,
}) {
  final d = math.max(0.0, distanceKm);
  final t = math.max(0.0, durationMin);

  if (tariff == Tariff.newTariff) {
    const base = 4.0, perKm = 1.0, perMin = 0.3;
    return _round2((base + d * perKm + t * perMin) * multiplier);
  }

  const flagFall = 4.0, increment = 0.35;
  if (d <= 1) return _round2(flagFall * multiplier);

  final extraMeters = (d - 1) * 1000;
  // Time attributable to the segment after the first km (proportional).
  final extraSeconds = t * 60 * (1 - 1 / d);
  final units = math.max((extraMeters / 200).ceil(), (extraSeconds / 36).ceil());
  return _round2((flagFall + units * increment) * multiplier);
}

double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// Ride services offered on the booking sheet. `name` is what lands in
/// `ride_requests.service`.
class RideService {
  const RideService(this.name, this.description, this.multiplier, this.seats, {this.id});
  final String name;
  final String description;
  final double multiplier;
  final int seats;

  /// The admin Vehicle Services entry this came from, when it did.
  final String? id;
}

/// Used only when the admin Vehicle Services catalogue cannot be read.
const rideServices = <RideService>[
  RideService('Teksi', 'Metered taxi', 1.0, 4),
  RideService('GET Car', 'Everyday rides', 1.1, 4),
  RideService('GET XL', 'Up to 6 seats', 1.5, 6),
  RideService('GET Premium', 'Executive cars', 2.0, 4),
];
