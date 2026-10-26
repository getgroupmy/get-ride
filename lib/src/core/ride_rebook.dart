// Booking the same ride again (web tester #131): after a driver cancels,
// "Find another driver" and "Book another ride" take the rider back to the
// home confirm step with the same pickup, stops, drop-off, vehicle and fare
// already filled in. The rider sends it from there, through the same
// checks and booking as any other ride (coverage, the region's rules and
// pricing, bidding): nothing is re-posted from the ride screen itself.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import '../data/models.dart';

/// The trip to book again.
class RideRebook {
  const RideRebook({
    required this.pickup,
    required this.drop,
    this.stops = const [],
    this.service,
    this.fare,
    this.payment,
    this.forName,
    this.forPhone,
  });

  final Place pickup, drop;
  final List<Place> stops;

  /// The vehicle class booked (a service name), if any.
  final String? service;

  /// The fare the rider booked at; where they may offer one it is offered
  /// again, else the fare is the one priced now.
  final double? fare;

  /// The payment mode booked.
  final String? payment;

  /// Who's riding, when it is someone else (a saved booking).
  final String? forName, forPhone;

  /// The same route alone: the vehicle, fare and payment picked afresh.
  RideRebook get routeOnly => RideRebook(pickup: pickup, drop: drop, stops: stops);
}

/// [r]'s trip, or null when it has no pickup or drop-off to go back to.
RideRebook? rideRebookOf(RideRequest r) {
  final pLat = r.pickupLat, pLng = r.pickupLng, dLat = r.dropLat, dLng = r.dropLng;
  if (pLat == null || pLng == null || dLat == null || dLng == null) return null;
  return RideRebook(
    pickup: Place(name: r.pickupLabel, address: r.pickupAddress ?? '', point: LatLng(pLat, pLng)),
    drop: Place(name: r.dropLabel, address: r.dropAddress ?? '', point: LatLng(dLat, dLng)),
    stops: r.stops,
    service: r.service,
    fare: r.effectiveFare,
    payment: r.raw['payment_mode'] as String?,
  );
}

class RideRebookNotifier extends Notifier<RideRebook?> {
  @override
  RideRebook? build() => null;

  void set(RideRebook? trip) => state = trip;

  /// The trip waiting to be filled in, once: null after.
  RideRebook? take() {
    final t = state;
    state = null;
    return t;
  }
}

/// The trip the home screen fills in next time it shows.
final rideRebookProvider = NotifierProvider<RideRebookNotifier, RideRebook?>(RideRebookNotifier.new);
