import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/partner/driver_home_map.dart';
import 'package:get_ride/src/widgets/map_recenter.dart';
import 'package:latlong2/latlong.dart';

const here = LatLng(3.1579, 101.7116);

void main() {
  test('nowhere to go, or a map not drawn yet, is not a move', () {
    final c = MapController();
    expect(recenterMap(c, null), isFalse);
    expect(recenterMap(c, here), isFalse, reason: 'no map attached');
  });

  testWidgets('the recenter key brings a scrolled map back to the driver', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DriverHomeMap(me: here, requests: []),
          ),
        ),
      ),
    );
    await tester.pump();
    MapCamera camera() => MapCamera.of(tester.element(find.byType(MarkerLayer).first));

    // Scroll away, the way a driver drags the map.
    await tester.drag(find.byType(FlutterMap), const Offset(-300, 250));
    await tester.pump();
    final away = camera().center;
    expect(const Distance()(away, here), greaterThan(100), reason: 'the drag moved the map');

    await tester.tap(find.byKey(const ValueKey('map-recenter')));
    await tester.pump();
    expect(const Distance()(camera().center, here), lessThan(1));
    expect(camera().zoom, recenterZoom);
  });
}
