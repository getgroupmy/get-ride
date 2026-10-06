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

/// Places demo requests run between (Expo `POPULAR_LOCATIONS`).
const demoPlaces = <(String, String, double, double)>[
  ('KLCC', 'Petronas Twin Towers, Kuala Lumpur City Centre', 3.1579, 101.7116),
  ('Pavilion KL', 'Bukit Bintang, Kuala Lumpur', 3.1493, 101.7142),
  ('Batu Caves', 'Gombak, Selangor', 3.2379, 101.6840),
  ('KL Sentral', 'KL Sentral Station, Kuala Lumpur', 3.1345, 101.6869),
  ('Mid Valley', 'Mid Valley City, Kuala Lumpur', 3.1184, 101.6774),
  ('Bukit Bintang', 'Jalan Bukit Bintang, Kuala Lumpur', 3.1478, 101.7123),
  ('KLIA', 'Kuala Lumpur International Airport, Sepang', 2.7456, 101.7072),
  ('Sunway Pyramid', 'Bandar Sunway, Selangor', 3.0733, 101.6069),
  ('The Curve', 'Mutiara Damansara, Selangor', 3.1533, 101.6105),
  ('1 Utama', 'Bandar Utama, Selangor', 3.1506, 101.6147),
];

const demoPassengers = ['Ahmad R.', 'Siti N.', 'Wei Ming', 'Priya S.', 'Daniel L.', 'Aisha K.', 'Hafiz B.', 'Mei Ling'];
const demoPayments = ['Cash', 'Card', 'E-Wallet', 'Get Pay'];

/// A demo request for an online driver (Expo `generateRandomRequest`).
class DemoJob {
  const DemoJob({
    required this.id,
    required this.passenger,
    required this.rating,
    required this.pickupName,
    required this.pickupAddress,
    required this.pickup,
    required this.dropName,
    required this.dropAddress,
    required this.drop,
    required this.km,
    required this.minutes,
    required this.fare,
    required this.payment,
    required this.pax,
    required this.luggage,
    required this.timeout,
  });

  final String id;
  final String passenger;
  final double rating;
  final String pickupName, pickupAddress, dropName, dropAddress;
  final LatLng pickup, drop;
  final double km;
  final int minutes;
  final double fare;
  final String payment;
  final int pax;
  final int luggage;

  /// How long the card waits for an answer (30–45 s).
  final Duration timeout;
}

/// One demo request between two different [demoPlaces]: distance as the
/// crow flies (at least 1.2 km), ~2.6 min a km (at least 5), fare
/// 3 + 1.5/km + 0.2/min (at least 6), as Expo priced them.
DemoJob demoJob(math.Random rnd, {required String id}) {
  final a = demoPlaces[rnd.nextInt(demoPlaces.length)];
  var b = demoPlaces[rnd.nextInt(demoPlaces.length)];
  while (b == a) {
    b = demoPlaces[rnd.nextInt(demoPlaces.length)];
  }
  final p = LatLng(a.$3, a.$4), d = LatLng(b.$3, b.$4);
  final km = math.max(1.2, const Distance().as(LengthUnit.Meter, p, d) / 1000);
  final minutes = math.max(5, (km * 2.6).round());
  final fare = math.max(6, (3 + 1.5 * km + 0.2 * minutes).round()).toDouble();
  return DemoJob(
    id: id,
    passenger: demoPassengers[rnd.nextInt(demoPassengers.length)],
    rating: 4.4 + rnd.nextInt(7) / 10,
    pickupName: a.$1,
    pickupAddress: a.$2,
    pickup: p,
    dropName: b.$1,
    dropAddress: b.$2,
    drop: d,
    km: double.parse(km.toStringAsFixed(1)),
    minutes: minutes,
    fare: fare,
    payment: demoPayments[rnd.nextInt(demoPayments.length)],
    pax: 1 + rnd.nextInt(4),
    luggage: rnd.nextInt(4),
    timeout: Duration(seconds: 30 + rnd.nextInt(16)),
  );
}

/// The gap before the next demo request (6–14 s).
Duration demoJobGap(math.Random rnd) => Duration(seconds: 6 + rnd.nextInt(9));

/// A demo job's drive: [demoToPickupFor] to the pickup, the driver starts the
/// trip, then [demoJobTripFor] to the drop (Expo `ride-running` simulation).
const demoToPickupFor = Duration(seconds: 30);
const demoJobTripFor = Duration(seconds: 45);
