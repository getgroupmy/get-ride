// Smart address and Google Autocomplete (Admin → Settings → Maps, migration
// 0207): A clean two-line results, B places first with the rider's saved and
// recent places on top, C a picked street address checked by Google; and
// Autocomplete's suggestions looked up only when picked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/core/saved_places.dart';
import 'package:get_ride/src/core/smart_address.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/data/saved_places_repository.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _klia = Place.suggestion(
  name: 'KLIA Terminal 1',
  address: 'Sepang, Selangor, Malaysia',
  placeId: 'ChIJ-klia-t1',
  types: ['airport', 'establishment'],
  km: 38.2,
);
const _street = Place(
  name: '12 Jalan Eco Majestic 1/2D',
  address: '12 Jalan Eco Majestic 1/2D, 43500 Semenyih, Selangor, Malaysia',
  point: LatLng(2.94, 101.84),
  types: ['street_address'],
);
const _work = SavedPlace(
  id: 'w1',
  kind: SavedPlaceKind.work,
  name: 'KLIA2 Cargo',
  address: 'KLIA2 Cargo, Sepang',
  point: LatLng(2.75, 101.68),
);

class _Geo extends GeoService {
  _Geo(String smart)
    : super(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => MapProfile(smartAddress: smart),
      );
  final resolved = <String>[];
  final checked = <String>[];

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => const [_klia, _street];

  @override
  Future<List<double?>> distances(LatLng from, List<LatLng> to) async => [for (final _ in to) 3.2];

  @override
  Future<Place?> resolve(Place p) async {
    if (!p.pending) return p;
    resolved.add(p.placeId!);
    return Place(
      name: p.name,
      address: 'KLIA, 64000 Sepang, Selangor, Malaysia',
      point: const LatLng(2.7456, 101.7072),
    );
  }

  @override
  Future<Place> checkAddress(Place p) async {
    checked.add(p.name);
    return Place(
      name: p.name,
      address: '12, Jalan Eco Majestic 1/2D, Eco Majestic, 43500 Semenyih, Selangor',
      point: p.point,
      verified: true,
    );
  }
}

void main() {
  group('the rules', () {
    // Web round 38 (177): area then city, a state repeating the city goes,
    // never the title again.
    test('A: area then city; no state that repeats the city; never the name again', () {
      const klcc = Place(
        name: 'KLCC - Petronas Twin Towers',
        address: 'KLCC, 156, Jalan Ampang, Kampung Sungai Baru, 50450 Kuala Lumpur, '
            'Wilayah Persekutuan Kuala Lumpur, Malaysia',
        point: LatLng(3.158, 101.712),
      );
      expect(shortArea(klcc), 'Kampung Sungai Baru, Kuala Lumpur');
      expect(placeAreaLine(klcc, clean: true), 'Kampung Sungai Baru, Kuala Lumpur');
      const same = Place(name: 'KLCC - Petronas Twin Towers', address: 'KLCC - Petronas Twin Towers', point: LatLng(3, 101));
      expect(placeAreaLine(same, clean: true), isNull, reason: 'the title again: no line');
      expect(placeAreaLine(same, clean: false), isNull);
      const sunway = Place(
        name: 'Sunway Pyramid',
        address: 'Sunway Pyramid, 3, Jalan PJS 11/15, Bandar Sunway, 47500 Petaling Jaya, Selangor, Malaysia',
        point: LatLng(3.07, 101.6),
      );
      expect(shortArea(sunway), 'Bandar Sunway, Petaling Jaya');
      expect(areaRegion(sunway), 'Selangor', reason: 'the state is still the region');
      const kl = Place(name: 'Pavilion', address: 'Pavilion, Bukit Bintang, Kuala Lumpur, Kuala Lumpur, Malaysia', point: LatLng(3, 101));
      expect(shortArea(kl), 'Bukit Bintang, Kuala Lumpur');
      // An area the name already holds is not "the area".
      const held = Place(name: 'Kampung Baru Mosque', address: 'Kampung Baru, Chow Kit, Kuala Lumpur, Selangor', point: LatLng(3, 101));
      expect(shortArea(held), 'Chow Kit, Kuala Lumpur');
    });

    test('A: the area alone, without name, postcode or country', () {
      const p = Place(
        name: 'Kuala Lumpur International Airport (KLIA)',
        address: 'Kuala Lumpur International Airport (KLIA), 64000 Sepang, Selangor, Malaysia',
        point: LatLng(2.7, 101.7),
      );
      expect(shortArea(p), 'Sepang, Selangor');
      expect(shortArea(_street), 'Semenyih, Selangor');
      expect(
        shortArea(const Place(name: 'X', address: 'Malaysia', point: LatLng(0, 1))),
        'Malaysia',
        reason: 'kept',
      );
      expect(placeIcon(_klia), Icons.flight);
      expect(placeIcon(_street), Icons.home_outlined);
    });

    test('street addresses by type, else by how the name reads', () {
      expect(isStreetAddress(_street), isTrue);
      expect(isStreetAddress(_klia), isFalse);
      expect(isStreetAddress(const Place(name: 'Jalan Ampang', address: '', point: LatLng(3, 101))), isTrue);
      expect(isStreetAddress(const Place(name: 'Suria KLCC', address: '', point: LatLng(3, 101))), isFalse);
    });

    test('B: saved and recent that match on top, named places, then addresses', () {
      const recent = Place(name: 'KLIA Terminal 1', address: 'Sepang', point: LatLng(2.7456, 101.7072));
      final r = placesFirst('klia', [_street, _klia], saved: const [_work], recent: const [recent]);
      expect(r.top.first.saved?.id, 'w1');
      expect(r.top[1].recent, isTrue);
      expect(r.top.last.place?.placeId, 'ChIJ-klia-t1');
      expect(r.addresses.single.name, _street.name);
      expect(placesFirst('zz', [_klia], saved: const [_work]).top.single.place, _klia, reason: 'no match, no saved');
    });

    test('the options', () {
      expect([const SmartAddress('a').clean, const SmartAddress('a').placesFirst], [true, false]);
      expect(
        [const SmartAddress('all').clean, const SmartAddress('all').placesFirst, const SmartAddress('all').check],
        [true, true, true],
      );
      expect(const SmartAddress('normal').check, isFalse);
      expect(
        MapProfile.fromJson({
          'profile': {'smartAddress': 'b', 'googleSearch': 'autocomplete'},
        }).smartAddress,
        'b',
      );
      expect(
        MapProfile.fromJson({
          'profile': {'smartAddress': 'x'},
        }).smartAddress,
        'normal',
      );
      expect(
        MapProfile.fromJson({
          'profile': {'googleSearch': 'autocomplete'},
        }).googleAutocomplete,
        isTrue,
      );
    });
  });

  group('the geo service', () {
    test('suggestions without a position, looked up with the search session when picked', () async {
      final asked = <Map<String, String>>[];
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        profile: () => const MapProfile(search: ['google']),
        lookup: (p) async {
          asked.add(p);
          if (p['action'] == 'search') {
            return {
              'places': [
                {
                  'name': 'KLIA',
                  'address': 'Sepang',
                  'lat': null,
                  'lng': null,
                  'id': 'ChIJ-klia',
                  'types': ['airport'],
                  'km': 38,
                },
              ],
            };
          }
          if (p['action'] == 'details') {
            return {
              'place': {
                'name': 'KLIA',
                'address': 'KLIA, Sepang',
                'lat': 2.74,
                'lng': 101.7,
                'types': ['airport'],
              },
            };
          }
          return {
            'checked': {'address': '12, Jalan X, 43500 Semenyih', 'lat': 2.9, 'lng': 101.8, 'complete': true},
          };
        },
      );
      final s = (await geo.search('klia')).single;
      expect(
        [s.pending, s.placeId, s.km, s.types],
        [
          true,
          'ChIJ-klia',
          38.0,
          ['airport'],
        ],
      );
      final session = asked.single['session'];
      expect(session, hasLength(24));
      final p = (await geo.resolve(s))!;
      expect([p.pending, p.point, p.address], [false, const LatLng(2.74, 101.7), 'KLIA, Sepang']);
      expect(asked.last['session'], session, reason: 'the same session');
      await geo.search('klcc');
      expect(asked.last['session'], isNot(session), reason: 'a new search, a new session');

      final c = await geo.checkAddress(_street);
      expect([c.address, c.verified, c.point], ['12, Jalan X, 43500 Semenyih', true, const LatLng(2.9, 101.8)]);
      expect(asked.last['address'], _street.address);
    });

    test("Google's answer missing: nothing picked, the address kept", () async {
      final geo = GeoService(
        client: MockClient((_) async => http.Response('', 500)),
        lookup: (_) async => throw Exception('down'),
      );
      expect(await geo.resolve(_klia), isNull);
      expect(await geo.checkAddress(_street), same(_street));
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<(_Geo, List<PlacePick?>)> open(
      WidgetTester tester,
      String smart, {
      List<Place> recent = const [],
      String? type = 'klia',
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
      final geo = _Geo(smart);
      final picked = <PlacePick?>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recentPlacesProvider.overrideWith((ref) async => recent),
            savedPlacesProvider.overrideWith((ref) async => const [_work]),
            currentUserIdProvider.overrideWithValue('u1'),
            geoServiceProvider.overrideWithValue(geo),
            placeGatesProvider.overrideWith((ref) async => (places: <GateRow>[], gates: <GateRow>[])),
          ],
          child: MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async =>
                      picked.add(await showPlaceSearch(context, title: 'Where to?', near: const LatLng(2.97, 101.82))),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (type != null) {
        await tester.enterText(find.byKey(const ValueKey('place-search-field')), type);
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
      }
      return (geo, picked);
    }

    // Web round 38 (177): recents read as search results do.
    const twin = Place(name: 'KLCC - Petronas Twin Towers', address: 'KLCC - Petronas Twin Towers', point: LatLng(3.158, 101.712));
    const klcc = Place(
      name: 'Suria KLCC',
      address: 'KLCC, 156, Jalan Ampang, Kampung Sungai Baru, 50450 Kuala Lumpur, Wilayah Persekutuan Kuala Lumpur, Malaysia',
      point: LatLng(3.157, 101.711),
    );

    testWidgets('177: Suggested recents: area then city, no line that repeats the title ($mode)', (tester) async {
      await open(tester, 'all', recent: const [twin, klcc], type: null);
      final twinTile = find.byKey(ValueKey('recent-${twin.point.latitude},${twin.point.longitude}'));
      final klccTile = find.byKey(ValueKey('recent-${klcc.point.latitude},${klcc.point.longitude}'));
      expect(find.descendant(of: twinTile, matching: find.byKey(const ValueKey('recent-subtitle'))), findsNothing);
      expect(find.descendant(of: klccTile, matching: find.text('Kampung Sungai Baru, Kuala Lumpur')), findsOneWidget);
      expect(find.textContaining('Jalan Ampang'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('177: recents among the results read the same ($mode)', (tester) async {
      await open(tester, 'all', recent: const [twin, klcc], type: 'klcc');
      final rows = find.byWidgetPredicate(
        (w) => w is ListTile && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('smart-recent-'),
      );
      expect(rows, findsNWidgets(2));
      expect(find.text('Kampung Sungai Baru, Kuala Lumpur'), findsOneWidget);
      expect(find.text('KLCC - Petronas Twin Towers'), findsNothing, reason: 'never the title again as a subtitle');
      expect(tester.takeException(), isNull);
    });

    testWidgets('normal: the results as given ($mode)', (tester) async {
      await open(tester, 'normal');
      expect(find.text('Sepang, Selangor, Malaysia'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-saved-w1')), findsNothing);
      expect(find.byKey(const ValueKey('smart-addresses')), findsNothing);
    });

    testWidgets('combination: saved on top, the area alone, addresses apart, a suggestion looked up ($mode)', (
      tester,
    ) async {
      final (geo, picked) = await open(tester, 'all');
      expect(find.byKey(const ValueKey('smart-saved-w1')), findsOneWidget);
      expect(find.text('Saved: Work'), findsOneWidget);
      expect(find.text('Sepang, Selangor'), findsOneWidget, reason: 'A: no country');
      expect(find.byIcon(Icons.flight), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-addresses')), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('KLIA Terminal 1')).dy,
        lessThan(tester.getTopLeft(find.text(_street.name)).dy),
        reason: 'B: places before addresses',
      );
      expect(find.text('38.2km'), findsOneWidget, reason: "Google's own distance for a suggestion");
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('KLIA Terminal 1'));
      await tester.pumpAndSettle();
      expect(geo.resolved, ['ChIJ-klia-t1']);
      expect(geo.checked, isEmpty, reason: 'C checks street addresses, not airports');
      expect(picked.single?.place?.point, const LatLng(2.7456, 101.7072));
      expect(picked.single?.place?.name, 'KLIA Terminal 1');
    });

    testWidgets('C: a picked street address checked and confirmed ($mode)', (tester) async {
      final (geo, picked) = await open(tester, 'c');
      await tester.tap(find.text(_street.name));
      await tester.pumpAndSettle();
      expect(geo.checked, [_street.name]);
      expect(picked.single?.place?.verified, isTrue);
      expect(picked.single?.place?.address, contains('Eco Majestic, 43500'));
      expect(find.byKey(const ValueKey('place-verified')), findsOneWidget);
    });
  }
}
