// The base map tiles: keyless OpenStreetMap by default, darkened on the
// device in dark mode, and a configured provider when one is set.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/map_tiles.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('defaults to OpenStreetMap, darkened only in dark mode', () {
    final light = resolveTileSource(dark: false, light: '', darkUrl: '');
    expect(light.url, osmTileUrl);
    expect(light.darken, isFalse);

    final dark = resolveTileSource(dark: true, light: '', darkUrl: '');
    expect(dark.url, osmTileUrl);
    expect(dark.darken, isTrue);
  });

  test('a configured light URL is used in both modes, darkened in dark mode', () {
    const url = 'https://tiles.example.com/{z}/{x}/{y}.png?key=k';
    expect(resolveTileSource(dark: false, light: url, darkUrl: '').url, url);
    final dark = resolveTileSource(dark: true, light: url, darkUrl: '');
    expect(dark.url, url);
    expect(dark.darken, isTrue);
  });

  test('a configured dark URL is used as-is in dark mode', () {
    const darkUrl = 'https://tiles.example.com/dark/{z}/{x}/{y}.png?key=k';
    final s = resolveTileSource(dark: true, light: '', darkUrl: darkUrl);
    expect(s.url, darkUrl);
    expect(s.darken, isFalse);
    expect(resolveTileSource(dark: false, light: '', darkUrl: darkUrl).url, osmTileUrl);
  });

  test('the default build no longer uses the keyed CARTO tiles', () {
    expect(resolveTileSource(dark: true).url, isNot(contains('cartocdn')));
  });

  testWidgets('the OSM layer uses one host and retries refused tiles', (tester) async {
    late TileLayer layer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            layer = baseTileLayer(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(layer.urlTemplate, osmTileUrl);
    expect(layer.subdomains, isEmpty);
    expect(layer.evictErrorTileStrategy, EvictErrorTileStrategy.notVisibleRespectMargin);
  });

  testWidgets('a trip map opens already framing pickup and drop-off', (tester) async {
    const klia = LatLng(2.7456, 101.7072), klcc = LatLng(3.1579, 101.7116);
    await tester.pumpWidget(
      const MaterialApp(
        home: RideMap(pickup: klia, drop: klcc),
      ),
    );
    final options = tester.widget<FlutterMap>(find.byType(FlutterMap)).options;
    final fit = options.initialCameraFit;
    expect(fit, isA<FitCoordinates>());
    expect((fit! as FitCoordinates).coordinates, containsAll([klia, klcc]));
  });

  group('tile retries', () {
    test('throttling and server errors are retried; a missing tile is not', () {
      expect(retryTileResponse(429), isTrue);
      expect(retryTileResponse(503), isTrue);
      expect(retryTileResponse(500), isTrue);
      expect(retryTileResponse(404), isFalse);
      expect(retryTileResponse(403), isFalse);
    });

    test('a dropped request is retried; one the map cancelled is not', () {
      expect(retryTileError(http.ClientException('connection reset')), isTrue);
      expect(retryTileError(http.RequestAbortedException()), isFalse);
      expect(retryTileError(StateError('x')), isFalse);
    });

    test('the waits back off', () {
      expect([for (var i = 0; i < 4; i++) tileRetryDelay(i).inMilliseconds], [500, 1000, 2000, 4000]);
    });

    test('a throttled tile arrives on a later attempt', () async {
      var calls = 0;
      final client = RetryClient(
        MockClient((_) async => ++calls < 3 ? http.Response('slow down', 429) : http.Response('png', 200)),
        retries: 4,
        when: (r) => retryTileResponse(r.statusCode),
        whenError: (e, _) => retryTileError(e),
        delay: (_) => Duration.zero,
      );
      final r = await client.get(Uri.parse('https://tile.openstreetmap.org/9/403/253.png'));
      expect(r.statusCode, 200);
      expect(calls, 3);
    });
  });

  testWidgets('the base layer uses the shared provider', (tester) async {
    late TileLayer layer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            layer = baseTileLayer(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(identical(layer.tileProvider, appTileProvider), isTrue);
    expect(layer.errorTileCallback, isNotNull);
  });

  test('satellite is imagery in both themes, never darkened', () {
    for (final dark in [false, true]) {
      final s = resolveTileSource(dark: dark, satellite: true, light: 'https://l/{z}', darkUrl: 'https://d/{z}', satelliteUrl: '');
      expect(s.url, satelliteTileUrl);
      expect(s.darken, isFalse);
    }
    expect(resolveTileSource(dark: true, satellite: true, satelliteUrl: ' https://sat/{z}/{x}/{y} ').url, 'https://sat/{z}/{x}/{y}');
  });
}
