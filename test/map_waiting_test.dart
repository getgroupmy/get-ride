// The map shows what Admin → Settings → Maps set, not the app's own map
// first and then that: blank until the settings (or the ones this device
// kept) are known, the app's own only when neither can be had.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';

void main() {
  tearDown(() => applyMapProfile(MapProfile.builtIn));

  for (final dark in [false, true]) {
    testWidgets('blank while the settings are asked for, then what is set (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      waitForMapProfile();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(dark ? Brightness.dark : Brightness.light),
          home: Scaffold(
            body: FlutterMap(
              options: const MapOptions(initialCenter: LatLng(3.139, 101.6869), initialZoom: 13),
              children: [Builder(builder: (context) => baseTileLayer(context))],
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('map-waiting')), findsOneWidget);
      expect(find.byType(TileLayer), findsNothing, reason: "not the app's own map first");

      applyMapProfile(
        MapProfile.fromJson({
          'profile': {
            'tiles': {
              'light': {'url': 'https://set.example/{z}/{x}/{y}.png'},
              'dark': {'url': 'https://set.example/dark/{z}/{x}/{y}.png'},
            },
          },
        }),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('map-waiting')), findsNothing);
      final layer = tester.widget<TileLayer>(find.byType(TileLayer));
      expect(layer.urlTemplate, startsWith('https://set.example/'));
    });
  }

  test('waits only at start, not over settings already known', () {
    applyMapProfile(const MapProfile(search: ['google']));
    waitForMapProfile();
    expect(mapProfileListenable.value, isNotNull);
  });
}
