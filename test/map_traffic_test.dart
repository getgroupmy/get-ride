// The driver map's live-traffic overlay: lib/src/widgets/map_traffic.dart.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/features/partner/driver_home_map.dart';
import 'package:get_ride/src/widgets/map_traffic.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _url = 'https://traffic.example/{z}/{x}/{y}.png?key=test';

void main() {
  group('the configured source', () {
    test('only an https XYZ template counts', () {
      expect(resolveTrafficTileUrl(configured: ''), isNull);
      expect(resolveTrafficTileUrl(configured: '   '), isNull);
      expect(resolveTrafficTileUrl(configured: 'http://insecure/{z}/{x}/{y}.png'), isNull);
      expect(resolveTrafficTileUrl(configured: 'https://no-placeholders.example/tile.png'), isNull);
      expect(resolveTrafficTileUrl(configured: ' $_url '), _url);
    });

    test('no layer unless configured and switched on', () {
      expect(trafficTileLayer(null, on: true), isNull);
      expect(trafficTileLayer(_url, on: false), isNull);
      expect(trafficTileLayer(_url, on: true)!.urlTemplate, _url);
    });

    test('a backup source is used per tile when the primary fails', () {
      const backup = 'https://backup.example/{z}/{x}/{y}/png?apiKey=test';
      expect(resolveTrafficFallbackUrl(configured: '', primary: _url), isNull);
      expect(resolveTrafficFallbackUrl(configured: 'http://insecure/{z}/{x}/{y}', primary: _url), isNull);
      expect(resolveTrafficFallbackUrl(configured: backup, primary: _url), backup);
      // The same source twice is nothing to fall back to.
      expect(resolveTrafficFallbackUrl(configured: _url, primary: _url), isNull);
      expect(trafficTileLayer(_url, on: true, fallback: backup)!.fallbackUrl, backup);
      expect(trafficTileLayer(_url, on: true)!.fallbackUrl, isNull);
    });
  });

  test('the switch is remembered on the device', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(mapTrafficProvider), isFalse);
    await c.read(mapTrafficProvider.notifier).toggle();
    expect(c.read(mapTrafficProvider), isTrue);
    expect((await SharedPreferences.getInstance()).getBool(MapTraffic.prefsKey), isTrue);

    final again = ProviderContainer();
    addTearDown(again.dispose);
    again.read(mapTrafficProvider);
    await Future<void>.delayed(Duration.zero);
    expect(again.read(mapTrafficProvider), isTrue, reason: 'a new session starts where the driver left it');
  });

  for (final b in Brightness.values) {
    group('the driver map (${b.name})', () {
      Future<ProviderContainer> pump(WidgetTester tester, {String? url}) async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer(overrides: [trafficTileUrlProvider.overrideWithValue(url)]);
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: appTheme(b),
              home: const Scaffold(
                body: DriverHomeMap(me: LatLng(3.15, 101.71), requests: []),
              ),
            ),
          ),
        );
        await tester.pump();
        return container;
      }

      Iterable<String?> tiles(WidgetTester tester) =>
          tester.widgetList<TileLayer>(find.byType(TileLayer)).map((l) => l.urlTemplate);

      testWidgets('no traffic button without a traffic source', (tester) async {
        await pump(tester);
        expect(find.byKey(const ValueKey('map-traffic')), findsNothing);
        expect(tiles(tester), isNot(contains(_url)));
        expect(tester.takeException(), isNull);
      });

      testWidgets('the button draws traffic over the map and takes it away', (tester) async {
        final c = await pump(tester, url: _url);
        final button = find.byKey(const ValueKey('map-traffic'));
        expect(button, findsOneWidget);
        // Above the map-type button.
        expect(tester.getRect(button).bottom, lessThan(tester.getRect(find.byKey(const ValueKey('map-type'))).top));
        expect(tiles(tester), isNot(contains(_url)));

        await tester.tap(button);
        await tester.pump();
        expect(c.read(mapTrafficProvider), isTrue);
        expect(tiles(tester).length, 2);
        expect(tiles(tester).first, isNot(_url), reason: 'the base tiles stay');
        expect(tiles(tester).last, _url, reason: 'traffic is drawn over them');

        await tester.tap(button);
        await tester.pump();
        expect(tiles(tester), isNot(contains(_url)));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
