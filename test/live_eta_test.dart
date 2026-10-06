import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/live_eta.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';

const pickup = LatLng(3.1579, 101.7116);
const drop = LatLng(3.1340, 101.6869);
final t0 = DateTime(2026, 10, 6, 10, 30);

class _Geo extends GeoService {
  final routed = <(LatLng, LatLng)>[];

  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async {
    routed.add((from, to));
    return RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
  }
}

RideRequest ride(String status, {LatLng? driver, double? heading}) => RideRequest({
  'id': 'r1',
  'status': status,
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': pickup.latitude,
  'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude,
  'drop_lng': drop.longitude,
  'partner_live_lat': driver?.latitude,
  'partner_live_lng': driver?.longitude,
  'partner_live_heading': heading,
});

void main() {
  group('rules', () {
    test('the driver heads for the pickup, then the drop-off', () {
      expect(etaTarget(RideStatus.accepted, pickup: pickup, drop: drop), pickup);
      expect(etaTarget(RideStatus.onTrip, pickup: pickup, drop: drop), drop);
      expect(etaTarget(RideStatus.arrived, pickup: pickup, drop: drop), isNull);
      expect(etaTarget(RideStatus.open, pickup: pickup, drop: drop), isNull);
    });

    test('a route is fetched again on a move, a new target or a minute', () {
      const here = LatLng(3.15, 101.70);
      expect(
        shouldReroute(from: here, to: pickup, now: t0),
        isTrue,
        reason: 'none yet',
      );
      bool again({LatLng from = here, LatLng to = pickup, Duration after = const Duration(seconds: 5)}) =>
          shouldReroute(from: from, to: to, now: t0.add(after), lastFrom: here, lastTo: pickup, lastAt: t0);
      expect(again(), isFalse);
      expect(again(from: const LatLng(3.1510, 101.70)), isFalse, reason: '~110 m');
      expect(again(from: const LatLng(3.1520, 101.70)), isTrue, reason: '~220 m');
      expect(again(to: drop), isTrue);
      expect(again(after: const Duration(seconds: 60)), isTrue);
    });

    test('the ETA line', () {
      expect(etaLabel(minutes: 5.2, km: 2.34, now: t0, toPickup: true), 'Arriving in 6 min · 10:36 · 2.3 km');
      expect(etaLabel(minutes: 14, km: 9.8, now: t0, toPickup: false), 'Arrive at 10:44 · 14 min · 9.8 km');
      expect(etaLabel(minutes: 0.1, km: 0.05, now: t0, toPickup: true), startsWith('Arriving in 1 min'));
    });
  });

  group('map', () {
    late _Geo geo;

    Future<void> pump(WidgetTester tester, RideRequest r) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [geoServiceProvider.overrideWithValue(geo)],
          child: MaterialApp(
            home: Scaffold(
              body: LiveRideMap(ride: r, now: () => t0),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    setUp(() => geo = _Geo());

    testWidgets('a driver on the way gets a route, an ETA and a turned car', (tester) async {
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted', driver: at, heading: 90));
      expect(geo.routed, [(at, pickup)]);
      expect(find.text('Arriving in 6 min · 10:36 · 2.3 km'), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-heading')), findsOneWidget);
    });

    testWidgets('small moves reuse the route; the trip routes to the drop-off', (tester) async {
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted', driver: at));
      await pump(tester, ride('accepted', driver: const LatLng(3.1601, 101.72)));
      expect(geo.routed, hasLength(1));
      await pump(tester, ride('on_trip', driver: pickup));
      expect(geo.routed.last, (pickup, drop));
      expect(find.textContaining('Arrive at'), findsOneWidget);
    });

    testWidgets('no ETA while searching or once the driver has arrived', (tester) async {
      await pump(tester, ride('open'));
      expect(find.byKey(const ValueKey('eta-chip')), findsNothing);
      await pump(tester, ride('arrived', driver: pickup));
      expect(find.byKey(const ValueKey('eta-chip')), findsNothing);
      expect(geo.routed, isEmpty);
    });
  });
}
