// The credit under every map: the provider drawing the tiles, worked out from
// Admin → Settings → Maps' attribution or the tile URL; Google's logo and the
// viewport's copyright always on screen (light and dark).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_credit.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/widgets/map_credit.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';

const _googleTiles = 'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?session=S1&key=K1';

void main() {
  group('which credit', () {
    test('worked out from the tile host', () {
      expect(mapCreditFor(osmTileUrl), const MapCredit(osmCredit));
      expect(mapCreditFor(satelliteTileUrl).text, 'Imagery © Esri');
      expect(
        mapCreditFor('https://api.mapbox.com/styles/v1/mapbox/x/tiles/{z}/{x}/{y}?access_token=t').text,
        '© Mapbox © OpenStreetMap',
      );
      expect(mapCreditFor('https://maps.hereapi.com/v3/base/mc/{z}/{x}/{y}/png8?apiKey=k').text, '© HERE');
      expect(
        mapCreditFor('https://a.basemaps.cartocdn.com/x/{z}/{x}/{y}.png').text,
        '© CARTO © OpenStreetMap contributors',
      );
      expect(mapCreditFor('https://tiles.example.org/{z}/{x}/{y}.png').text, osmCredit, reason: 'unknown: OSM data');
    });

    test("the admin's attribution wins; Google is always Google", () {
      expect(
        mapCreditFor('https://tiles.example.org/{z}/{x}/{y}.png', attribution: '© Example'),
        const MapCredit('© Example'),
      );
      expect(mapCreditFor(_googleTiles), const MapCredit(googleDefaultCredit, google: true));
      expect(mapCreditFor(_googleTiles, attribution: 'Map data © Google').google, isTrue);
    });

    test("Google's viewport request carries the tile session and key", () {
      final u = googleViewportUri(_googleTiles, zoom: 14, north: 3.2, south: 3.1, east: 101.8, west: 101.6)!;
      expect(u.host, 'tile.googleapis.com');
      expect(u.path, '/tile/v1/viewport');
      expect(u.queryParameters['session'], 'S1');
      expect(u.queryParameters['key'], 'K1');
      expect(u.queryParameters['zoom'], '14');
      expect(u.queryParameters['north'], '3.20000');
      expect(googleViewportUri(osmTileUrl, zoom: 1, north: 0, south: 0, east: 0, west: 0), isNull);
      expect(
        googleViewportUri(
          'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}',
          zoom: 1,
          north: 0,
          south: 0,
          east: 0,
          west: 0,
        ),
        isNull,
        reason: 'no session',
      );
      expect(parseGoogleCopyright({'copyright': 'Map data ©2026 Google'}), 'Map data ©2026 Google');
      expect(parseGoogleCopyright({'copyright': ''}), isNull);
      expect(parseGoogleCopyright('x'), isNull);
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<void> pumpMap(WidgetTester tester, {bool satellite = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: SizedBox(
            width: 400,
            height: 400,
            child: FlutterMap(
              options: const MapOptions(initialCenter: LatLng(3.15, 101.7), initialZoom: 14),
              children: [MapCreditLayer(satellite: satellite)],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('OpenStreetMap by default, behind the ⓘ button, one © ($mode)', (tester) async {
      activeMapProfile = MapProfile.builtIn;
      await pumpMap(tester);
      expect(find.byType(RichAttributionWidget), findsOneWidget);
      await tester.tap(find.byIcon(Icons.info_outlined));
      await tester.pumpAndSettle();
      expect(find.text(osmCredit), findsOneWidget);
      expect(find.textContaining('© ©'), findsNothing);
    });

    testWidgets("the admin's provider credited ($mode)", (tester) async {
      const spec = MapTileSpec(
        url: 'https://api.mapbox.com/styles/v1/mapbox/s/tiles/{z}/{x}/{y}?access_token=t',
        attribution: '© Mapbox © OpenStreetMap',
      );
      activeMapProfile = const MapProfile(light: spec, dark: spec);
      addTearDown(() => activeMapProfile = MapProfile.builtIn);
      await pumpMap(tester);
      await tester.tap(find.byIcon(Icons.info_outlined));
      await tester.pumpAndSettle();
      expect(find.text('© Mapbox © OpenStreetMap'), findsOneWidget);
    });

    testWidgets("Google: the logo and the viewport's copyright, always on screen ($mode)", (tester) async {
      const spec = MapTileSpec(url: _googleTiles, attribution: googleDefaultCredit);
      activeMapProfile = const MapProfile(light: spec, dark: spec);
      final asked = <Uri>[];
      final before = googleViewportFetcher;
      googleViewportFetcher = (uri) async {
        asked.add(uri);
        return 'Map data ©2026 Google';
      };
      addTearDown(() {
        activeMapProfile = MapProfile.builtIn;
        googleViewportFetcher = before;
      });
      await pumpMap(tester);
      expect(find.byType(RichAttributionWidget), findsNothing, reason: 'not tucked behind a button');
      expect(find.byKey(const ValueKey('google-map-logo')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('google-map-copyright'))).data, googleDefaultCredit);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(asked, hasLength(1));
      expect(asked.single.queryParameters['session'], 'S1');
      expect(tester.widget<Text>(find.byKey(const ValueKey('google-map-copyright'))).data, 'Map data ©2026 Google');
    });
  }
}
