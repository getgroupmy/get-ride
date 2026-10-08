import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

const pickup = LatLng(3.1340, 101.6860);

void main() {
  testWidgets('the pickup box stands 5 px above the pin and moves with the map', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final map = MapController();
    addTearDown(map.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RideMap(
            controller: map,
            pickup: pickup,
            extraMarkers: [labelAbovePin(pickup, const SizedBox(key: ValueKey('box'), width: 200, height: 50))],
          ),
        ),
      ),
    );
    await tester.pump();

    final pin = find.byType(PickupPin);
    // The pin is a 40 px rounded square on a 14 px stem, standing on the point.
    double ringTop() => tester.getRect(pin).top;
    double gap() => ringTop() - tester.getRect(find.byKey(const ValueKey('box'))).bottom;
    expect(tester.getRect(pin).height, pickupPinHeight);
    expect(rideMapPinTop, pickupPinHeight);
    expect(gap(), closeTo(5, 0.5));
    expect(tester.getCenter(find.byKey(const ValueKey('box'))).dx, closeTo(tester.getCenter(pin).dx, 0.5));

    final before = tester.getRect(find.byKey(const ValueKey('box')));
    await tester.drag(find.byType(FlutterMap), const Offset(-60, 120));
    await tester.pump();
    final after = tester.getRect(find.byKey(const ValueKey('box')));
    expect(after.top - before.top, closeTo(120, 1), reason: 'it follows the map, not the screen');
    expect(gap(), closeTo(5, 0.5));
  });
}
