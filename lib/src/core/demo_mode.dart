/// Admin → Display Settings → Demo / Mockup Data (Expo's mock driver
/// offers, mock incoming requests and simulated driving), for showing the
/// app off without real drivers or riders. Everything here is local: no demo
/// offer, request or trip is ever written to the database. Pure.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Which demo parts are on. Unlike Expo, a switch the admin never set is
/// OFF, so a real rider can never meet a demo driver by default.
class DemoSettings {
  const DemoSettings({
    this.riderOffers = false,
    this.riderTripSim = false,
    this.partnerRequests = false,
    this.partnerDriveSim = false,
  });

  /// Demo driver offers and "viewing" drivers while a rider searches.
  final bool riderOffers;

  /// A demo trip's car drives itself to the pickup and on to the drop.
  final bool riderTripSim;

  /// Demo incoming requests for an online driver.
  final bool partnerRequests;

  /// A demo job's car drives itself, arriving on its own.
  final bool partnerDriveSim;

  static DemoSettings fromSettings(Map<String, dynamic> s) {
    bool on(String k) {
      final v = s[k];
      return v == true || v == 1 || (v is String && const {'true', '1', 'on'}.contains(v.trim().toLowerCase()));
    }

    return DemoSettings(
      riderOffers: on('userMockEnabled'),
      riderTripSim: on('riderTripSimEnabled'),
      partnerRequests: on('partnerMockEnabled'),
      partnerDriveSim: on('partnerDriveSimEnabled'),
    );
  }
}

/// A demo driver's offer to a searching rider (Expo `MOCK_DRIVER_OFFERS`).
class DemoOffer {
  const DemoOffer({
    required this.id,
    required this.name,
    required this.vehicle,
    required this.rating,
    required this.rides,
    required this.etaMin,
    required this.km,
    required this.price,
    this.platinum = false,
  });

  final String id;
  final String name;
  final String vehicle;
  final double rating;
  final int rides;
  final int etaMin;
  final double km;
  final double price;
  final bool platinum;
}

/// The three demo offers on [fare], each a little above or at it, and when
/// each arrives after the search starts (3, 6 and 9 s).
List<(Duration, DemoOffer)> demoOffers(double fare) {
  double at(double markup) => math.max(1, (fare * (1 + markup)).roundToDouble());
  return [
    (
      const Duration(seconds: 3),
      DemoOffer(
        id: 'demo-1',
        name: 'Patrick',
        vehicle: 'Toyota Innova',
        rating: 5.0,
        rides: 2553,
        etaMin: 15,
        km: 3,
        price: at(0.06),
        platinum: true,
      ),
    ),
    (
      const Duration(seconds: 6),
      DemoOffer(
        id: 'demo-2',
        name: 'Mellier',
        vehicle: 'Mitsubishi G4',
        rating: 4.62,
        rides: 789,
        etaMin: 7,
        km: 1,
        price: at(0),
      ),
    ),
    (
      const Duration(seconds: 9),
      DemoOffer(
        id: 'demo-3',
        name: 'Gomer',
        vehicle: 'Toyota Avanza',
        rating: 4.79,
        rides: 692,
        etaMin: 14,
        km: 3,
        price: at(0.03),
      ),
    ),
  ];
}

/// When the "N drivers are viewing your request" line appears, and how long
/// an offer stays before it slides away unanswered.
const demoViewersAfter = Duration(milliseconds: 1500);
const demoOfferLife = Duration(seconds: 10);
const demoViewerNames = ['Aiman', 'Farid', 'Kumar', 'Lee'];

/// Where the demo trip's car is: [route] followed for [fraction] (0–1) of
/// its length.
LatLng alongRoute(List<LatLng> route, double fraction) {
  if (route.isEmpty) return const LatLng(0, 0);
  if (route.length == 1 || fraction <= 0) return route.first;
  if (fraction >= 1) return route.last;
  const d = Distance();
  final legs = [for (var i = 1; i < route.length; i++) d.as(LengthUnit.Meter, route[i - 1], route[i])];
  final total = legs.fold<double>(0, (a, b) => a + b);
  if (total == 0) return route.first;
  var left = total * fraction;
  for (var i = 0; i < legs.length; i++) {
    if (left <= legs[i] || i == legs.length - 1) {
      final t = legs[i] == 0 ? 0.0 : (left / legs[i]).clamp(0.0, 1.0);
      final a = route[i], b = route[i + 1];
      return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
    }
    left -= legs[i];
  }
  return route.last;
}

/// The demo trip's phases (Expo `ride-tracking` simulation): the driver
/// arrives over [demoArriveFor], waits [demoWaitFor], then drives the trip
/// over [demoTripFor].
enum DemoPhase { arriving, arrived, onTrip, completed }

const demoArriveFor = Duration(seconds: 14);
const demoWaitFor = Duration(milliseconds: 3500);
const demoTripFor = Duration(seconds: 20);

({DemoPhase phase, double progress}) demoPhaseAt(Duration elapsed) {
  if (elapsed < demoArriveFor) {
    return (phase: DemoPhase.arriving, progress: elapsed.inMilliseconds / demoArriveFor.inMilliseconds);
  }
  final afterArrive = elapsed - demoArriveFor;
  if (afterArrive < demoWaitFor) return (phase: DemoPhase.arrived, progress: 1);
  final onTrip = afterArrive - demoWaitFor;
  if (onTrip < demoTripFor) {
    return (phase: DemoPhase.onTrip, progress: onTrip.inMilliseconds / demoTripFor.inMilliseconds);
  }
  return (phase: DemoPhase.completed, progress: 1);
}

/// Where the demo driver starts: a little south-west of the pickup.
LatLng demoDriverStart(LatLng pickup) => LatLng(pickup.latitude - 0.012, pickup.longitude - 0.009);
