// Amazon Location Service with GrabMaps (Admin → Settings → Maps, migration
// 0206): its map as a MapLibre style the browser draws (web only, with the
// app's own tiles whenever it can't be shown), its credit, and the admin's
// choices for it.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/maps/maps_logic.dart';
import 'package:get_ride/src/admin/screens/security/api_keys_logic.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/map_credit.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:get_ride/src/widgets/maplibre_layer.dart';
import 'package:latlong2/latlong.dart';

const _style =
    'https://maps.geo.ap-southeast-5.amazonaws.com/v2/styles/Standard/descriptor?color-scheme=Dark&key=MAPKEY';
const _credit = '© AWS, Grab, © OpenMapTiles, © OpenStreetMap contributors';

void main() {
  group('the profile', () {
    test('a MapLibre style and its key, no tiles', () {
      final spec = MapTileSpec.fromJson({
        'url': '',
        'engine': 'maplibre',
        'style': _style,
        'key': 'MAPKEY',
        'attribution': _credit,
      })!;
      expect([spec.isMapLibre, spec.isBrowserMap, spec.isGoogleJs], [true, true, false]);
      expect(spec.url, _style);
      expect(spec.maplibreKey, 'MAPKEY');
      expect(MapTileSpec.fromJson({'engine': 'maplibre', 'style': _style, 'key': ''}), isNull, reason: 'no key');
      expect(MapTileSpec.fromJson({'engine': 'maplibre', 'style': 'http://x', 'key': 'K'}), isNull, reason: 'https');
      expect(spec == MapTileSpec.maplibre(_style, 'OTHER'), isFalse);
    });

    test('only on the web; elsewhere the tiles the app was built with', () {
      const spec = MapTileSpec.maplibre(_style, 'MAPKEY', attribution: _credit);
      const profile = MapProfile(light: spec, dark: spec);
      final web = profileTileSource(profile, dark: true, web: true)!;
      expect([web.url, web.maplibreKey, web.isBrowserMap], [_style, 'MAPKEY', true]);
      expect(profileTileSource(profile, dark: true, web: false), isNull);
    });

    test("Grab's credit, not Google's", () {
      final c = mapCreditFor(_style, attribution: _credit);
      expect(c.text, _credit);
      expect(c.google, isFalse);
    });
  });

  group('the admin', () {
    test('Amazon in every list, its map on the web only, two key slots, a region', () {
      expect(placeProviders, contains('amazon'));
      expect(routeProviders, contains('amazon'));
      expect(distanceProviders, contains('amazon'));
      expect(tileOptionsFor('light', 'web'), contains('amazon_js'));
      expect(tileOptionsFor('dark', 'android'), isNot(contains('amazon_js')));
      expect(tileOptionsFor('satellite', 'web'), isNot(contains('amazon_js')), reason: 'GrabMaps has no imagery');
      expect(mapProviderLabel('amazon'), 'Amazon Location (GrabMaps)');

      final s = MapSettings.fromJson({
        'amazonRegion': 'ap-southeast-1',
        'profiles': {
          'partner.web': {
            'tiles': {'light': 'amazon_js', 'dark': 'amazon_js'},
            'search': ['amazon', 'nominatim'],
          },
        },
      });
      expect(s.amazonRegion, 'ap-southeast-1');
      expect(MapSettings.fromJson({'amazonRegion': 'us-east-1'}).amazonRegion, 'ap-southeast-5');
      expect(MapSettings.fromJson(s.toJson()), s);
      expect(s.withAmazonRegion('ap-southeast-5') == s, isFalse, reason: 'a change to save');
      expect(s.withKey('here', 'here/api').amazonRegion, 'ap-southeast-1', reason: 'kept through other edits');
      expect(s.usedKeySlots, containsAll(['amazon', 'amazon_maps']));
      expect(s.profile('partner', 'web').forDevice('ios').tiles['light'], 'app');
      expect(s.keyRef('amazon'), 'amazon/location');
      expect(s.keyRef('amazon_maps'), 'amazon/maps');

      final amazon = defaultApiProviders.firstWhere((p) => p.id == 'amazon');
      expect(amazon.services.map((x) => x.id), ['location', 'maps']);
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<void> pump(WidgetTester tester, {List<Widget>? children}) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: appTheme(dark ? Brightness.dark : Brightness.light),
          home: SizedBox(
            width: 400,
            height: 400,
            child: FlutterMap(
              options: const MapOptions(initialCenter: LatLng(3.15, 101.7), initialZoom: 14),
              children:
                  children ??
                  const [
                    MapLibreBaseLayer(
                      style: _style,
                      apiKey: 'MAPKEY',
                      fallback: Text('app tiles', key: ValueKey('fallback')),
                    ),
                  ],
            ),
          ),
        ),
      ),
    );

    testWidgets("the app's tiles when the map can't be drawn ($mode)", (tester) async {
      expect(maplibreFailed.value, isTrue, reason: 'not the web');
      await pump(tester);
      expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
    });

    testWidgets("Amazon's map under the app's layers, taking no gestures ($mode)", (tester) async {
      maplibreFailed.value = false;
      addTearDown(() => maplibreFailed.value = true);
      await pump(tester);
      expect(find.byKey(const ValueKey('fallback')), findsNothing);
      expect(find.descendant(of: find.byType(MapLibreBaseLayer), matching: find.byType(IgnorePointer)), findsWidgets);
      maplibreFailed.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('fallback')), findsOneWidget, reason: 'gives way when refused');
    });
  }
}
