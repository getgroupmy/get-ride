import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:latlong2/latlong.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';

void main() {
  Future<void> pumpMap(WidgetTester tester, Map<String, dynamic> row) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Scaffold(body: LiveRideMap(ride: RideRequest(row)))),
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
}
