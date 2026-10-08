import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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

    test('the road ahead starts where the car is on it', () {
      const a = LatLng(3.0, 101.0), b = LatLng(3.0, 101.01), c = LatLng(3.01, 101.01);
      final ahead = routeAhead([a, b, c], const LatLng(3.0001, 101.005))!;
      expect(ahead.points.first.longitude, closeTo(101.005, 1e-6), reason: 'snapped onto the road');
      expect(ahead.points.first.latitude, closeTo(3.0, 1e-9));
      expect(ahead.points.skip(1), [b, c], reason: 'what is behind the car is dropped');
      expect(ahead.offBy, closeTo(11, 1), reason: '0.0001° of latitude is about 11 m');
      expect(routeAhead([a], a), isNull);

      // Halfway along the first of two equal legs: three quarters left.
      final eta = etaAhead(routeMinutes: 10, routeKm: 4, route: [a, b, c], ahead: ahead.points);
      expect(eta.km, closeTo(3, 0.01), reason: "the road distance, not the line's");
      expect(eta.minutes, closeTo(7.5, 0.02), reason: 'the time counts down with the road');
    });

    test('leaving the route reroutes at once, but not on every fix', () {
      bool again(Duration after) => shouldReroute(
            from: pickup,
            to: drop,
            now: t0.add(after),
            lastFrom: pickup,
            lastTo: drop,
            lastAt: t0,
            offRoute: true,
          );
      expect(again(const Duration(seconds: 3)), isFalse);
      expect(again(rerouteOffRouteGap), isTrue);
    });

    test('the ETA line', () {
      expect(etaLabel(minutes: 5.2, km: 2.34, now: t0, toPickup: true), 'Arriving in 6 min · 10:36 · 2.3 km');
      expect(etaLabel(minutes: 14, km: 9.8, now: t0, toPickup: false), 'Arrive at 10:44 · 14 min · 9.8 km');
      expect(etaLabel(minutes: 0.1, km: 0.05, now: t0, toPickup: true), startsWith('Arriving in 1 min'));
    });
  });

  group('map', () {
    late _Geo geo;

    Future<void> pump(
      WidgetTester tester,
      RideRequest r, {
      LatLng? driverAt,
      double? heading,
      DateTime Function()? now,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [geoServiceProvider.overrideWithValue(geo)],
          child: MaterialApp(
            home: Scaffold(
              body: LiveRideMap(ride: r, now: now ?? () => t0, driverAt: driverAt, driverHeading: heading),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    MapCamera camera(WidgetTester tester) => tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;

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

    testWidgets('the camera follows the car, north up for the rider', (tester) async {
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted', driver: at, heading: 90));
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).center.latitude, closeTo(at.latitude, 1e-6));
      expect(camera(tester).center.longitude, closeTo(at.longitude, 1e-6));
      expect(camera(tester).zoom, followZoom);
      expect(camera(tester).rotation, 0);

      const next = LatLng(3.161, 101.721);
      await pump(tester, ride('accepted', driver: next, heading: 90));
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).center.latitude, closeTo(next.latitude, 1e-6), reason: 'it moves with the car');
    });

    testWidgets("the driver's own map turns to the way the car is going", (tester) async {
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted'), driverAt: at, heading: 90);
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).rotation, closeTo(-90, 1e-6));
      expect(camera(tester).zoom, followZoom);
    });

    testWidgets('moving the map by hand stops the following; recenter starts it again', (tester) async {
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted', driver: at));
      await tester.pump(const Duration(seconds: 1));
      await tester.drag(find.byType(FlutterMap), const Offset(200, 0));
      await tester.pump(const Duration(seconds: 1));
      final panned = camera(tester).center;
      expect(panned.longitude, isNot(closeTo(at.longitude, 1e-6)));

      await pump(tester, ride('accepted', driver: const LatLng(3.161, 101.721)));
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).center, panned, reason: 'the camera stays where it was put');

      await tester.tap(find.byTooltip('Follow the car'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).center.latitude, closeTo(3.161, 1e-6));
    });

    testWidgets('left alone for a while, the next position recentres on the car by itself', (tester) async {
      var now = t0;
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted', driver: at), now: () => now);
      await tester.pump(const Duration(seconds: 1));
      await tester.drag(find.byType(FlutterMap), const Offset(200, 0));
      await tester.pump(const Duration(seconds: 1));
      final panned = camera(tester).center;

      now = t0.add(const Duration(seconds: 5));
      await pump(tester, ride('accepted', driver: const LatLng(3.161, 101.721)), now: () => now);
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).center, panned, reason: 'too soon after the hand');

      now = t0.add(followResumeAfter + const Duration(seconds: 1));
      await pump(tester, ride('accepted', driver: const LatLng(3.162, 101.722)), now: () => now);
      await tester.pump(const Duration(seconds: 1));
      expect(camera(tester).center.latitude, closeTo(3.162, 1e-6));
      expect(camera(tester).center.longitude, closeTo(101.722, 1e-6));
    });

    testWidgets('a car that leaves the route is rerouted, and the ETA counts down along it', (tester) async {
      var now = t0;
      const at = LatLng(3.16, 101.72);
      await pump(tester, ride('accepted', driver: at), now: () => now);
      expect(geo.routed, hasLength(1));
      // A tenth of the way along the line it was given (under 150 m), on it:
      // no new route, nine tenths of the way left.
      LatLng along(double f) => LatLng(
            at.latitude + (pickup.latitude - at.latitude) * f,
            at.longitude + (pickup.longitude - at.longitude) * f,
          );
      now = t0.add(const Duration(seconds: 10));
      await pump(tester, ride('accepted', driver: along(0.1)), now: () => now);
      expect(geo.routed, hasLength(1));
      expect(find.textContaining('2.1 km'), findsOneWidget, reason: 'nine tenths of 2.34 km');
      // About 100 m off the line, still under 150 m from the last route: rerouted.
      final off = LatLng(along(0.1).latitude + 0.0009, along(0.1).longitude);
      await pump(tester, ride('accepted', driver: off), now: () => now);
      expect(geo.routed.last, (off, pickup));
    });
  });
}
