// The confirm map's marks, as inDrive's: the pickup a waving rider over a
// ringed dot, stops numbered squares, the drop-off a flag, and the route
// black on a light map and white on a dark one; and the "show whole route"
// button a winding route to a pin.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:get_ride/src/widgets/map_recenter.dart';
import 'package:get_ride/src/widgets/ride_map.dart';

void main() {
  for (final b in Brightness.values) {
    testWidgets('pickup, stop and drop-off marks follow the theme ($b)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: const Scaffold(
            body: RideMap(
              pickup: LatLng(2.95, 101.80),
              stops: [LatLng(3.15, 101.70)],
              drop: LatLng(1.50, 103.70),
              route: [LatLng(2.95, 101.80), LatLng(3.15, 101.70), LatLng(1.50, 103.70)],
              dotPins: true,
            ),
          ),
        ),
      );
      await tester.pump();
      final fill = b == Brightness.dark ? Colors.white : const Color(0xFF111111);
      Color boxColour(Finder f) => (tester.widget<Container>(f).decoration! as BoxDecoration).color!;

      final pickup = find.byKey(const ValueKey('map-dot-pickup'));
      expect(find.descendant(of: pickup, matching: find.byIcon(Icons.emoji_people)), findsOneWidget);
      expect(find.byKey(const ValueKey('map-dot-pickup-point')), findsOneWidget);
      final stop = find.byKey(const ValueKey('map-dot-stop-0'));
      expect(find.descendant(of: stop, matching: find.text('1')), findsOneWidget);
      expect(boxColour(stop), fill);
      final drop = find.byKey(const ValueKey('map-dot-drop'));
      expect(find.descendant(of: drop, matching: find.byIcon(Icons.flag)), findsOneWidget);
      expect(boxColour(drop), fill);
      // The pickup dot stands under its square.
      expect(
        tester.getCenter(find.byKey(const ValueKey('map-dot-pickup-point'))).dy,
        greaterThan(tester.getCenter(find.descendant(of: pickup, matching: find.byIcon(Icons.emoji_people))).dy),
      );
      expect(tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines.single.color, fill);
    });

    testWidgets('the whole-route button is a route to a pin on the recenter disc ($b)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(
            body: Center(child: RouteFitButton(onPressed: () => taps++)),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('route-icon')), findsOneWidget);
      expect(find.byTooltip('Show whole route'), findsOneWidget);
      final disc = tester.widget<Material>(
        find.ancestor(of: find.byKey(const ValueKey('route-icon')), matching: find.byType(Material)).first,
      );
      expect(disc.color, b == Brightness.dark ? RecenterButton.darkFill : RecenterButton.lightFill);
      expect(tester.getSize(find.byType(InkWell)), const Size.square(RecenterButton.size));
      await tester.tap(find.byType(RouteFitButton));
      expect(taps, 1);
    });
  }
}
