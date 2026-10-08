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
    expect(camera().zoom, driverHomeZoom, reason: 'it opens at street level');
    expect(
      tester.getCenter(find.byKey(const ValueKey('map-recenter'))).dy,
      greaterThan(900 / 2),
      reason: 'the map buttons sit low on the map, as on the trip maps',
    );

    // Scroll away, the way a driver drags the map.
    await tester.drag(find.byType(FlutterMap), const Offset(-300, 250));
    await tester.pump();
    final away = camera().center;
    expect(const Distance()(away, here), greaterThan(100), reason: 'the drag moved the map');

    await tester.tap(find.byKey(const ValueKey('map-recenter')));
    await tester.pump();
    expect(const Distance()(camera().center, here), lessThan(1));
    expect(camera().zoom, driverHomeZoom);
  });

  testWidgets('the driver map follows the driver as they move', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.reset);
    Widget at(LatLng p) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: DriverHomeMap(me: p, requests: const []))),
    );
    await tester.pumpWidget(at(here));
    await tester.pump();
    MapCamera camera() => MapCamera.of(tester.element(find.byType(MarkerLayer).first));
    expect(const Distance()(camera().center, here), lessThan(1));

    const moved = LatLng(3.1600, 101.7130);
    await tester.pumpWidget(at(moved));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(const Distance()(camera().center, moved), lessThan(1), reason: 'the camera glides onto the driver');

    // A hand on the map stops the following; the recenter key starts it again.
    await tester.drag(find.byType(FlutterMap), const Offset(200, -150));
    await tester.pump();
    const further = LatLng(3.1610, 101.7140);
    await tester.pumpWidget(at(further));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(const Distance()(camera().center, further), greaterThan(50), reason: 'left where the driver put it');
    await tester.tap(find.byKey(const ValueKey('map-recenter')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(const Distance()(camera().center, further), lessThan(1));
  });

  for (final b in Brightness.values) {
    testWidgets('the recenter button is a white disc with a black arrow in light, charcoal with white in dark ($b)',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: Scaffold(body: Center(child: RecenterButton(onPressed: () => taps++))),
      ));
      final dark = b == Brightness.dark;
      final disc = tester.widget<Material>(find.byKey(const ValueKey('map-recenter')));
      expect(disc.color, dark ? RecenterButton.darkFill : RecenterButton.lightFill);
      expect(disc.shape, isA<CircleBorder>());
      final icon = tester.widget<Icon>(find.byKey(const ValueKey('map-recenter-icon')));
      expect(icon.icon, Icons.near_me_outlined);
      expect(icon.color, dark ? Colors.white : const Color(0xFF111111));
      expect(tester.getSize(find.byKey(const ValueKey('map-recenter'))), const Size.square(RecenterButton.size));
      await tester.tap(find.byKey(const ValueKey('map-recenter')));
      expect(taps, 1);
    });
  }
}
