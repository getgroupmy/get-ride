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

/// A Vehicle Service's own rates (Admin → Vehicle Services: Cost per km,
/// Cost per min, Minimum fare), which price it when no fare tariff covers
/// the trip: km × per km + minutes × per minute, never below the minimum.
class ServiceRates {
  const ServiceRates({required this.perKm, this.perMinute = 0, this.minimumFare = 0});
  final double perKm;
  final double perMinute;
  final double minimumFare;

  /// From a catalogue entry's values; null without a Cost per km, and for a
  /// metered taxi (its meter prices it).
  static ServiceRates? fromValues(Map<String, dynamic> v) {
    double? n(Object? raw) {
      final d = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
      return d == null || !d.isFinite || d < 0 ? null : d;
    }

    final km = n(v['costPerKm']);
    if (km == null || km <= 0) return null;
    bool taxi(Object? x) {
      final l = '${x ?? ''}'.toLowerCase();
      return l.contains('teksi') || l.contains('taxi');
    }

    final types = v['serviceTypes'];
    if (taxi(v['name']) || (types is List && types.any(taxi))) return null;
    return ServiceRates(perKm: km, perMinute: n(v['costPerMin']) ?? 0, minimumFare: n(v['minFareAmount']) ?? 0);
  }

  /// What a trip of [distanceKm] and [durationMin] costs on these rates.
  double fare(double distanceKm, double durationMin) => _round2(
    math.max(minimumFare, math.max(0.0, distanceKm) * perKm + math.max(0.0, durationMin) * perMinute),
  );
}

/// Ride services offered on the booking sheet. `name` is what lands in
/// `ride_requests.service`.
class RideService {
  const RideService(
    this.name,
    this.description,
    this.multiplier,
    this.seats, {
    this.id,
    this.image,
    this.serviceTypes = const [],
    this.parentIds = const [],
    this.rates,
    this.premium = false,
  });
  final String name;
  final String description;
  final double multiplier;
  final int seats;

  /// Its own rates, for a trip no fare tariff covers; null: the built-in
  /// TEKSI tariff × [multiplier].
  final ServiceRates? rates;

  /// The catalogue's picture of the vehicle (hero image, else icon).
  final String? image;

  /// The admin Vehicle Services entry this came from, when it did.
  final String? id;

  /// The Service Settings types it belongs to, by name (Car, Bike, …):
  /// region rules and fares set for a type apply to it.
  final List<String> serviceTypes;

  /// The sub-services it sits under, by settings entry id (`parentServices`,
  /// see core/service_tree.dart).
  final List<String> parentIds;

  /// A Premium service (Vehicle Services › Premium, migration 0316): its
  /// card says which drivers take it.
  final bool premium;
}

/// Used only when the admin Vehicle Services catalogue cannot be read. The
/// names are the seeded services' (0259 partner type services), so a ride
/// booked from this list still reaches the partner types that take it.
const rideServices = <RideService>[
  RideService('Teksi', 'Metered taxi', 1.0, 4),
  RideService('Ride', 'Everyday rides', 1.1, 4),
  RideService('Comfort', 'Newer, roomier cars', 1.3, 4),
  RideService('6-seater', 'Up to 6 seats', 1.5, 6),
  RideService('Premium', 'Executive cars', 2.0, 4),
];
