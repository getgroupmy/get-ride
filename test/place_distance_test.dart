// Place search results show their road distance from the user, as Grab
// does: measured by the profile's distance providers (Admin → Settings →
// Maps, migration 0205), OpenStreetMap's OSRM by default.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/format.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _me = LatLng(3.1390, 101.6869);
const _klcc = Place(name: 'KLCC', address: 'Jalan Ampang, KL', point: LatLng(3.1579, 101.7116));
const _klia = Place(name: 'KLIA', address: 'Sepang', point: LatLng(2.7456, 101.7072));

class _Geo extends GeoService {
  _Geo(this.km);
  final List<double?> km;
  final asked = <(LatLng, List<LatLng>)>[];

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => const [_klcc, _klia];

  @override
  Future<List<double?>> distances(LatLng from, List<LatLng> to) async {
    asked.add((from, to));
    return km;
  }
}

void main() {
  test('labels: metres under a kilometre, two decimals under ten, then fewer', () {
    expect(placeDistanceLabel(0.85), '850m');
    expect(placeDistanceLabel(8.587), '8.59km');
    expect(placeDistanceLabel(29.44), '29.4km');
    expect(placeDistanceLabel(129.6), '130km');
  });

  group('GeoService.distances', () {
    final to = [_klcc.point, _klia.point];

    test("OSRM's table by default: one request, the origin's own column dropped", () async {
      final urls = <Uri>[];
      final geo = GeoService(
        client: MockClient((req) async {
          urls.add(req.url);
          return http.Response(
            jsonEncode({
              'code': 'Ok',
              'distances': [
                [0, 8587.2, null],
              ],
            }),
            200,
          );
        }),
        profile: () => MapProfile.builtIn,
      );
      final km = await geo.distances(_me, to);
      expect(km[0], closeTo(8.5872, 1e-9));
      expect(km[1], isNull, reason: 'no road found');
      expect(urls.single.path, '/table/v1/driving/101.6869,3.139;101.7116,3.1579;101.7072,2.7456');
      expect(urls.single.queryParameters, {'sources': '0', 'annotations': 'distance'});
    });

    test('a keyed provider through geo first, the next when it has nothing', () async {
      final asked = <Map<String, String>>[];
      var answer = <String, dynamic>{
        'distances': [8.59, 45.2],
      };
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(distance: ['here', 'straight']),
        lookup: (p) async {
          asked.add(p);
          return answer;
        },
      );
      expect(await geo.distances(_me, to), [8.59, 45.2]);
      expect(asked.single['action'], 'distance');
      expect(asked.single['provider'], 'here');
      expect(asked.single['from'], '3.139,101.6869');
      expect(asked.single['to'], '3.1579,101.7116;2.7456,101.7072');

      answer = {
        'distances': [null, null],
      };
      final straight = await geo.distances(_me, to);
      expect(straight[0], closeTo(3.4, 0.2), reason: 'as the crow flies');
      expect(straight[1], closeTo(43.6, 0.5));
    });

    test('nothing answers: no distances, never an error', () async {
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(distance: ['google', 'osrm']),
        lookup: (_) async => throw Exception('down'),
      );
      expect(await geo.distances(_me, to), [null, null]);
      expect(await geo.distances(_me, const []), isEmpty);
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<_Geo> open(WidgetTester tester, List<double?> km, {LatLng? near = _me}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
      final geo = _Geo(km);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recentPlacesProvider.overrideWith((ref) async => const []),
            geoServiceProvider.overrideWithValue(geo),
            placeGatesProvider.overrideWith((ref) async => (places: <GateRow>[], gates: <GateRow>[])),
          ],
          child: MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPlaceSearch(context, title: 'Where to?', near: near),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('place-search-field')), 'kl');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      return geo;
    }

    testWidgets('each result shows its distance from the user under its pin ($mode)', (tester) async {
      final geo = await open(tester, [8.587, null]);
      expect(geo.asked.single.$1, _me, reason: 'from where the user is');
      expect(geo.asked.single.$2, [_klcc.point, _klia.point]);
      final km = find.byKey(const ValueKey('result-km-3.1579,101.7116'));
      expect(km, findsOneWidget);
      expect(tester.widget<Text>(km).data, '8.59km');
      expect(find.byKey(const ValueKey('result-km-2.7456,101.7072')), findsNothing, reason: 'no road found');
      expect(find.text('KLIA'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a known position, no distances asked ($mode)', (tester) async {
      final geo = await open(tester, [1, 2], near: null);
      expect(geo.asked, isEmpty);
      expect(find.text('KLCC'), findsOneWidget);
    });
  }
}
