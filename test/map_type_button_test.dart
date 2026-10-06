import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/partner/driver_home_map.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:get_ride/src/widgets/map_type_button.dart';
import 'package:latlong2/latlong.dart';

void main() {
  String tiles(WidgetTester tester) => tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate!;

  testWidgets('the map-type key switches the map to satellite and back, for every map', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: DriverHomeMap(me: LatLng(3.15, 101.71), requests: []),
          ),
        ),
      ),
    );
    expect(tiles(tester), isNot(satelliteTileUrl));
    await tester.tap(find.byKey(const ValueKey('map-type')));
    await tester.pump();
    expect(tiles(tester), satelliteTileUrl);
    expect(container.read(mapSatelliteProvider), isTrue, reason: 'one choice for the session');
    await tester.tap(find.byKey(const ValueKey('map-type')));
    await tester.pump();
    expect(tiles(tester), isNot(satelliteTileUrl));
  });
}
