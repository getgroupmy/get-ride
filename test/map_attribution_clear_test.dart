import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';

void main() {
  testWidgets('the trip map buttons leave the OpenStreetMap credit reachable', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: LiveRideMap(
              ride: RideRequest({
                'id': 'r1',
                'status': 'open',
                'pickup_lat': 2.7456,
                'pickup_lng': 101.7072,
                'drop_lat': 3.1579,
                'drop_lng': 101.7116,
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final credit = tester.getRect(find.byIcon(Icons.info_outlined)).inflate(12); // its 48 px tap target
    expect(credit.center.dx, lessThan(390 / 2), reason: 'the credit sits at the bottom left');
    for (final key in const ['map-type', 'map-recenter']) {
      final button = tester.getRect(find.byKey(ValueKey(key)));
      expect(button.overlaps(credit), isFalse, reason: '$key covers the credit button');
    }
    // Map view sits above recenter, low in the corner.
    final type = tester.getRect(find.byKey(const ValueKey('map-type')));
    final recenter = tester.getRect(find.byKey(const ValueKey('map-recenter')));
    expect(type.bottom, lessThan(recenter.top));
    expect(400 - recenter.bottom, lessThanOrEqualTo(24));
    // And the credit still opens.
    await tester.tap(find.byIcon(Icons.info_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('OpenStreetMap contributors', findRichText: true), findsWidgets);
  });
}
