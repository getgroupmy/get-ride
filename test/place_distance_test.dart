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
import 'package:get_ride/src/data/saved_places_repository.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/map_pick_icon.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _me = LatLng(3.1390, 101.6869);
const _klcc = Place(name: 'KLCC', address: 'Jalan Ampang, KL', point: LatLng(3.1579, 101.7116));
const _klia = Place(name: 'KLIA', address: 'Sepang', point: LatLng(2.7456, 101.7072));

const _lane = Place.suggestion(name: 'KLIA T2 Departure Lane', address: 'Selangor, Malaysia', placeId: 'lane');
const _airport = Place.suggestion(
  name: 'KL International Airport (KUL)',
  address: 'KLIA, Sepang, Selangor, Malaysia',
  placeId: 'kul',
  km: 44.2,
);

class _Geo extends GeoService {
  _Geo(this.km, {this.suggest = false});
  final List<double?> km;
  final bool suggest;
  final asked = <(LatLng, List<LatLng>)>[];

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => !suggest
      ? const [_klcc, _klia]
      : query == 'klia t'
      ? const [_lane, _klcc, _airport]
      : const [_airport, _lane];

  /// OpenStreetMap knows the lane, not the airport's Google name.
  @override
  Future<List<LatLng?>> roughPoints(List<Place> suggestions, {LatLng? near, bool Function()? stillWanted}) async => [
    for (final p in suggestions) p.placeId == 'lane' ? const LatLng(2.7449, 101.6869) : null,
  ];

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

    test("Autocomplete's suggestions found on OpenStreetMap one at a time, and kept", () async {
      final asked = <Uri>[];
      final geo = GeoService(
        client: MockClient((req) async {
          asked.add(req.url);
          final q = req.url.queryParameters['q']!;
          return http.Response(
            jsonEncode(
              q.startsWith('KLIA T2')
                  ? [
                      {'name': 'KLIA T2', 'display_name': 'KLIA T2, Sepang', 'lat': '2.7449', 'lon': '101.6869'},
                    ]
                  : [],
            ),
            200,
          );
        }),
        profile: () => MapProfile.builtIn,
        nominatimGap: Duration.zero,
      );
      const found = Place(name: 'KLCC', address: 'KL', point: LatLng(3.15, 101.71));
      final points = await geo.roughPoints(const [_lane, _airport, found], near: _me);
      expect(points, [const LatLng(2.7449, 101.6869), null, null]);
      expect(asked, hasLength(2), reason: 'a place with a position is not looked up');
      expect(asked.first.path, '/search');
      expect(asked.first.queryParameters['q'], 'KLIA T2 Departure Lane, Selangor, Malaysia');
      expect(asked.first.queryParameters['limit'], '1');

      expect(await geo.roughPoints(const [_airport, _lane]), [null, const LatLng(2.7449, 101.6869)]);
      expect(asked, hasLength(2), reason: 'kept, found or not');

      const later = Place.suggestion(name: 'X', address: 'Y', placeId: 'x');
      expect(await geo.roughPoints(const [later], stillWanted: () => false), isEmpty);
      expect(asked, hasLength(2), reason: 'a newer search stops the lookups');
    });

    test("the profile's locate providers first, through geo; OpenStreetMap when they find nothing", () async {
      final osm = <Uri>[];
      final asked = <Map<String, String>>[];
      final geo = GeoService(
        client: MockClient((req) async {
          osm.add(req.url);
          return http.Response(
            jsonEncode([
              {'name': 'KUL', 'display_name': 'KUL, Sepang', 'lat': '2.74', 'lon': '101.7'},
            ]),
            200,
          );
        }),
        profile: () => const MapProfile(locate: ['google']),
        lookup: (p) async {
          asked.add(p);
          return {
            'places': [
              if (p['q']!.startsWith('KLIA T2'))
                {'name': 'KLIA T2', 'address': 'Sepang', 'lat': 2.7449, 'lng': 101.6869},
            ],
          };
        },
        nominatimGap: Duration.zero,
      );
      final points = await geo.roughPoints(const [_lane, _airport], near: _me);
      expect(points, [const LatLng(2.7449, 101.6869), const LatLng(2.74, 101.7)]);
      expect(asked.map((a) => '${a['action']} ${a['provider']}'), ['locate google', 'locate google']);
      expect(asked.first['lat'], '3.139');
      expect(osm, hasLength(1), reason: 'OpenStreetMap only for the one Google could not place');
    });

    test('address lookup and place search fall back to OpenStreetMap', () async {
      final geo = GeoService(
        client: MockClient(
          (req) async => http.Response(
            jsonEncode(
              req.url.path == '/reverse'
                  ? {
                      'name': 'Eco Majestic',
                      'display_name': 'Eco Majestic, Semenyih',
                      'address': {'suburb': 'Eco Majestic', 'country': 'Malaysia'},
                    }
                  : [
                      {
                        'name': 'Eco Majestic',
                        'display_name': 'Eco Majestic, Semenyih',
                        'lat': '2.93',
                        'lon': '101.83',
                      },
                    ],
            ),
            200,
          ),
        ),
        profile: () => const MapProfile(search: ['google'], reverse: ['google']),
        lookup: (_) async => throw Exception('refused'),
      );
      expect((await geo.reverse(const LatLng(2.93, 101.83))).name, 'Eco Majestic');
      expect((await geo.search('eco majestic')).single.point, const LatLng(2.93, 101.83));
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

    Future<_Geo> open(
      WidgetTester tester,
      List<double?> km, {
      LatLng? near = _me,
      bool suggest = false,
      Place? from,
      Place? to,
      bool routeEnds = false,
      bool startOnFrom = false,
      List<PlacePick?>? picked,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
      final geo = _Geo(km, suggest: suggest);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recentPlacesProvider.overrideWith((ref) async => const []),
            savedPlacesProvider.overrideWith((ref) async => const []),
            currentUserIdProvider.overrideWithValue(null),
            geoServiceProvider.overrideWithValue(geo),
            placeGatesProvider.overrideWith((ref) async => (places: <GateRow>[], gates: <GateRow>[])),
          ],
          child: MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    final p = await showPlaceSearch(
                      context,
                      title: 'Where to?',
                      near: near,
                      from: from,
                      to: to,
                      routeEnds: routeEnds,
                      startOnFrom: startOnFrom,
                    );
                    picked?.add(p);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (from != null || routeEnds) return geo;
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

    testWidgets("Google's suggestions: road distance where OSM finds them, else Google's ($mode)", (tester) async {
      final geo = await open(tester, [41.7], suggest: true);
      expect(geo.asked.single.$2, [const LatLng(2.7449, 101.6869)], reason: 'only what OSM found, by road');
      expect(tester.widget<Text>(find.byKey(const ValueKey('result-km-lane'))).data, '41.7km');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('result-km-kul'))).data,
        '44.2km',
        reason: "Google's own straight-line distance where OSM can't place it",
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the search over several suggestions keeps the list ($mode)', (tester) async {
      await open(tester, [41.7], suggest: true);
      for (final q in ['klia t', 'klia', '', 'kl']) {
        await tester.enterText(find.byKey(const ValueKey('place-search-field')), q);
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull, reason: 'after "$q"');
      }
      expect(find.text('KLIA T2 Departure Lane'), findsOneWidget);
      expect(find.text('KL International Airport (KUL)'), findsOneWidget);
    });

    testWidgets('the route\'s From can be changed in the same dialog ($mode)', (tester) async {
      final picked = <PlacePick?>[];
      const eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.93, 101.83));
      await open(tester, [8.587, null], from: eco, picked: picked);
      expect(find.text('Eco Majestic'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('place-search-from')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('place-search-from')), findsNothing);
      expect(find.text('From'), findsOneWidget, reason: 'the field is the start now');
      await tester.enterText(find.byKey(const ValueKey('place-search-field')), 'klcc');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.tap(find.text('KLCC'));
      await tester.pumpAndSettle();
      expect(picked.single?.from, isTrue);
      expect(picked.single?.place?.name, 'KLCC');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the route sheet: From over To, Search Results, highlighted names, clear ($mode)', (tester) async {
      const eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.93, 101.83));
      const klcc = Place(name: 'KLCC', address: 'KL', point: LatLng(3.15, 101.71));
      await open(tester, [8.587, null], from: eco, to: klcc);
      expect(find.byType(MapPickIcon), findsOneWidget, reason: 'choose on map');
      expect(find.byKey(const ValueKey('place-tab-results')), findsNothing, reason: 'nothing typed');
      await tester.tap(find.byKey(const ValueKey('place-search-from')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('place-search-field'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('place-search-to'))).dy),
        reason: 'From is searched over the To row',
      );
      expect(find.descendant(of: find.byKey(const ValueKey('place-search-to')), matching: find.text('KLCC')), findsOne);
      await tester.enterText(find.byKey(const ValueKey('place-search-field')), 'kl');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      final results = tester.widget<Material>(
        find.descendant(of: find.byKey(const ValueKey('place-tab-results')), matching: find.byType(Material)).first,
      );
      expect(results.color, Theme.of(tester.element(find.byType(Scaffold).last)).colorScheme.onSurface,
          reason: 'Search Results chosen');
      final title = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey('result-2.7456,101.7072')),
          matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'KLIA'),
        ),
      );
      final lit = <String>[];
      title.text.visitChildren((span) {
        if (span is TextSpan && span.text != null && span.style?.color != null) lit.add(span.text!);
        return true;
      });
      expect(lit, contains('KL'), reason: 'what was typed, in the accent colour');
      expect(find.byKey(const ValueKey('result-save-2.7456,101.7072')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('place-tab-suggested')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('result-2.7456,101.7072')), findsNothing, reason: 'the suggestions instead');
      await tester.tap(find.byKey(const ValueKey('place-search-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('place-tab-results')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('place-search-to')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('place-search-from')), findsOneWidget, reason: 'back to searching To');
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing typed: From (empty) over the To field, Suggested and Saved only ($mode)', (tester) async {
      await open(tester, [8.587, null], routeEnds: true);
      final from = find.byKey(const ValueKey('place-search-from'));
      expect(find.descendant(of: from, matching: find.text('From')), findsOneWidget, reason: 'its name, greyed');
      expect(find.text('Search, or paste a Google Maps link'), findsNothing, reason: 'only the To label');
      expect(find.byKey(const ValueKey('place-tab-suggested')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-tab-saved')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-tab-results')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opened on the pickup: From searched first, To under it ($mode)', (tester) async {
      final picked = <PlacePick?>[];
      const klcc = Place(name: 'KLCC', address: 'KL', point: LatLng(3.15, 101.71));
      await open(tester, [8.587, null], routeEnds: true, startOnFrom: true, to: klcc, picked: picked);
      expect(find.byKey(const ValueKey('place-search-from')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('place-search-to')), matching: find.text('KLCC')), findsOne);
      await tester.enterText(find.byKey(const ValueKey('place-search-field')), 'kl');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.tap(find.text('KLCC').last);
      await tester.pumpAndSettle();
      expect(picked.single?.from, isTrue, reason: 'the pickup');
    });

    testWidgets('the bookmark asks to sign in before saving ($mode)', (tester) async {
      await open(tester, [8.587, null]);
      await tester.tap(find.byKey(const ValueKey('result-save-3.1579,101.7116')));
      await tester.pump();
      expect(find.text('Sign in to save your places'), findsOneWidget);
    });

    testWidgets('a destination picked with From shown is not the start ($mode)', (tester) async {
      final picked = <PlacePick?>[];
      const eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.93, 101.83));
      await open(tester, [8.587, null], from: eco, picked: picked);
      await tester.enterText(find.byKey(const ValueKey('place-search-field')), 'klcc');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.tap(find.text('KLCC'));
      await tester.pumpAndSettle();
      expect(picked.single?.from, isFalse);
    });

    testWidgets('without a known position, no distances asked ($mode)', (tester) async {
      final geo = await open(tester, [1, 2], near: null);
      expect(geo.asked, isEmpty);
      expect(find.text('KLCC'), findsOneWidget);
    });
  }
}
