// "Destination addresses", as inDrive's: the places after the pickup,
// numbered, the last with a flag; ✕ removes, the handle reorders.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';
import 'package:latlong2/latlong.dart';

const _a = Place(name: 'Kulai', address: 'Johor', point: LatLng(1.66, 103.6));
const _b = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(3.15, 101.71));
const _c = Place(name: 'Sentral', address: 'Kuala Lumpur', point: LatLng(3.13, 101.68));

void main() {
  Future<List<List<Place>>> open(WidgetTester tester, List<Place> places) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <List<Place>>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () => showRouteStopsSheet(c, destinations: places, onChanged: changes.add),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return changes;
  }

  testWidgets('numbered stops, the destination flagged; ✕ removes; back closes', (tester) async {
    final changes = await open(tester, const [_a, _b, _c]);
    expect(find.text('Destination addresses'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byKey(const ValueKey('route-stop-flag')), findsOneWidget);
    expect(tester.getCenter(find.byKey(const ValueKey('route-stop-flag'))).dy,
        closeTo(tester.getCenter(find.text('Sentral')).dy, 2), reason: 'the last one is the destination');

    await tester.tap(find.byKey(const ValueKey('route-stop-remove-0')));
    await tester.pumpAndSettle();
    expect(changes.last.map((p) => p.name), ['KLCC', 'Sentral']);
    expect(find.text('Kulai'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('route-stop-remove-1')));
    await tester.pumpAndSettle();
    expect(changes.last.map((p) => p.name), ['KLCC'], reason: 'KLCC is the destination now');
    expect(find.byKey(const ValueKey('route-stop-remove-0')), findsNothing, reason: 'the last one stays');

    await tester.tap(find.byKey(const ValueKey('route-stops-back')));
    await tester.pumpAndSettle();
    expect(find.text('Destination addresses'), findsNothing);
  });

  testWidgets('dragging by the handle reorders; whichever is last becomes the destination', (tester) async {
    final changes = await open(tester, const [_a, _b]);
    final handle = find.byKey(const ValueKey('route-stop-drag-0'));
    final g = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(changes.last.map((p) => p.name), ['KLCC', 'Kulai']);
    expect(tester.getCenter(find.byKey(const ValueKey('route-stop-flag'))).dy,
        closeTo(tester.getCenter(find.text('Kulai')).dy, 2));
  });
}
