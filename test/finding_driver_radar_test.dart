import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/live_eta.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:latlong2/latlong.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';

void main() {
  Future<void> pumpMap(
    WidgetTester tester,
    Map<String, dynamic> row, {
    bool partner = false,
    Stream<LatLng> Function()? riderPosition,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LiveRideMap(ride: RideRequest(row), partner: partner, riderPosition: riderPosition),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  const pickup = {'pickup_lat': 3.1390, 'pickup_lng': 101.6869, 'drop_lat': 3.1579, 'drop_lng': 101.7116};

  testWidgets('while finding a driver the map sits on the pickup at street level, pulsing', (tester) async {
    await pumpMap(tester, {'id': 'r1', 'status': 'open', ...pickup});
    expect(find.byKey(const ValueKey('radar-pulse')), findsOneWidget);
    final camera = MapCamera.of(tester.element(find.byKey(const ValueKey('radar-pulse'))));
    expect(camera.zoom, searchingZoom);
    expect(camera.rotation, 0);
    // The pickup is drawn on the radar's centre.
    final pulse = tester.getCenter(find.byKey(const ValueKey('radar-pulse')));
    final at = camera.latLngToScreenOffset(const LatLng(3.1390, 101.6869));
    expect((pulse - at).distance, lessThan(1));
    // The pulse keeps going.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('radar-pulse')), findsOneWidget);
  });

  testWidgets('no radar once a driver is on the way', (tester) async {
    await pumpMap(tester, {
      'id': 'r1',
      'status': 'accepted',
      ...pickup,
      'partner_live_lat': 3.13,
      'partner_live_lng': 101.68,
    });
    expect(find.byKey(const ValueKey('radar-pulse')), findsNothing);
  });

  testWidgets("the driver on the way sees where the passenger is waiting; the passenger doesn't see themselves", (
    tester,
  ) async {
    final row = {
      'id': 'r1',
      'status': 'accepted',
      ...pickup,
      'user_live_lat': 3.1392,
      'user_live_lng': 101.6871,
      'user_live_at': DateTime.now().toUtc().toIso8601String(),
    };
    await pumpMap(tester, row, partner: true);
    expect(find.byKey(const ValueKey('passenger-here')), findsOneWidget);
    await pumpMap(tester, row);
    expect(find.byKey(const ValueKey('passenger-here')), findsNothing);
  });

  group('the passenger waiting: you are here, and the way to the pickup', () {
    test('the dot only while waiting; the line only when away from the pickup', () {
      expect(showRiderDot(RideStatus.open), isTrue);
      expect(showRiderDot(RideStatus.accepted), isTrue);
      expect(showRiderDot(RideStatus.arrived), isTrue);
      expect(showRiderDot(RideStatus.onTrip), isFalse);
      const at = LatLng(3.1390, 101.6869);
      expect(walkToPickupLine(const LatLng(3.13905, 101.68695), at), isNull, reason: 'a few metres: at it');
      expect(walkToPickupLine(const LatLng(3.1400, 101.6880), at), [const LatLng(3.1400, 101.6880), at]);
      expect(walkToPickupLine(null, at), isNull);
    });

    Stream<LatLng> Function() at(LatLng p) =>
        () => Stream.value(p);

    testWidgets('away from the pickup: a dashed line to it', (tester) async {
      await pumpMap(tester, {
        'id': 'r1',
        'status': 'accepted',
        ...pickup,
        'partner_live_lat': 3.13,
        'partner_live_lng': 101.68,
      }, riderPosition: at(const LatLng(3.1400, 101.6880)));
      expect(find.byKey(const ValueKey('walk-to-pickup')), findsOneWidget);
    });

    testWidgets('at the pickup: no line', (tester) async {
      await pumpMap(tester, {
        'id': 'r1',
        'status': 'open',
        ...pickup,
      }, riderPosition: at(const LatLng(3.13905, 101.68695)));
      expect(find.byKey(const ValueKey('walk-to-pickup')), findsNothing);
    });

    testWidgets('in the car, and on the driver\'s map: none', (tester) async {
      var listened = false;
      Stream<LatLng> watched() {
        listened = true;
        return Stream.value(const LatLng(3.1400, 101.6880));
      }

      await pumpMap(tester, {'id': 'r1', 'status': 'on_trip', ...pickup}, riderPosition: watched);
      expect(find.byKey(const ValueKey('walk-to-pickup')), findsNothing);
      expect(listened, isFalse, reason: 'the phone is not asked for a fix');
      await pumpMap(tester, {'id': 'r1', 'status': 'accepted', ...pickup}, partner: true);
      expect(find.byKey(const ValueKey('walk-to-pickup')), findsNothing, reason: 'no shared position');
    });

    testWidgets('the driver sees the same line from the passenger to the pickup', (tester) async {
      Map<String, dynamic> row(double lat, double lng) => {
        'id': 'r1',
        'status': 'accepted',
        ...pickup,
        'user_live_lat': lat,
        'user_live_lng': lng,
        'user_live_at': DateTime.now().toUtc().toIso8601String(),
      };
      await pumpMap(tester, row(3.1400, 101.6880), partner: true);
      expect(find.byKey(const ValueKey('walk-to-pickup')), findsOneWidget);
      expect(find.byKey(const ValueKey('passenger-here')), findsOneWidget);
      await pumpMap(tester, row(3.13905, 101.68695), partner: true);
      expect(find.byKey(const ValueKey('walk-to-pickup')), findsNothing, reason: 'at the pickup');
    });
  });
}
