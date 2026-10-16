// Google's JavaScript map and Google traffic (Admin → Settings → Maps,
// migration 0204): read from the profile, web only, and the map's own tiles
// whenever Google's map can't be shown.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/google_js_layer.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('the profile', () {
    test("Google's JavaScript map: the browser key and the map type, no tiles", () {
      final light = MapTileSpec.fromJson({
        'url': '',
        'engine': 'google_js',
        'key': 'BROWSER',
        'mapType': 'roadmap',
        'attribution': 'Map data © Google',
      })!;
      expect(light.isGoogleJs, isTrue);
      expect(light.googleJsKey, 'BROWSER');
      expect(light.url, MapTileSpec.googleJsRoadmap);
      final sat = MapTileSpec.fromJson({'engine': 'google_js', 'key': 'BROWSER', 'mapType': 'satellite'})!;
      expect(sat.url, MapTileSpec.googleJsSatellite);
      expect(MapTileSpec.fromJson({'engine': 'google_js', 'key': ''}), isNull, reason: 'no key, no map');
      expect(MapTileSpec.fromJson({'url': '', 'darken': false}), isNull, reason: 'an older answer without a template');
      expect(light == MapTileSpec.googleJs('OTHER'), isFalse);
    });

    test('Google traffic', () {
      final t = MapTrafficSpec.fromJson({'google': true})!;
      expect([t.google, t.off, t.url], [true, false, null]);
      expect(MapTrafficSpec.fromJson({'off': true})!.google, isFalse);
    });

    test('only on the web; elsewhere the tiles the app was built with', () {
      const spec = MapTileSpec.googleJs('BROWSER');
      const profile = MapProfile(light: spec, dark: spec);
      final web = profileTileSource(profile, dark: false, web: true)!;
      expect(web.googleJsKey, 'BROWSER');
      expect(profileTileSource(profile, dark: true, web: false), isNull);
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: SizedBox(
            width: 400,
            height: 400,
            child: FlutterMap(
              options: const MapOptions(initialCenter: LatLng(3.15, 101.7), initialZoom: 14),
              children: const [
                GoogleJsBaseLayer(
                  apiKey: 'BROWSER',
                  fallback: Text('app tiles', key: ValueKey('fallback')),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    testWidgets("the app's tiles when Google's map can't be shown ($mode)", (tester) async {
      expect(googleJsFailed.value, isTrue, reason: 'not the web');
      await pump(tester);
      expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
    });

    testWidgets("Google's map under the app's layers, taking no gestures ($mode)", (tester) async {
      googleJsFailed.value = false;
      addTearDown(() => googleJsFailed.value = true);
      await pump(tester);
      expect(find.byKey(const ValueKey('fallback')), findsNothing);
      expect(find.descendant(of: find.byType(GoogleJsBaseLayer), matching: find.byType(IgnorePointer)), findsWidgets);
      googleJsFailed.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('fallback')), findsOneWidget, reason: 'gives way when Google refuses');
    });
  }
}
