// "Group search results inside the boundary": an airport, or a multi-gate
// place with a boundary, shows the search results inside it (and those
// named with its words) as one result (`values.groupResults`,
// `values.groupWords`). The rider's search with the grouped row and its
// door sheet, and the admin's switch and words on Edit Airport and Edit
// Place, saved with the rest, light and dark.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/geo/airport_areas_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/geo/multi_gate_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/airport_areas.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/data/airport_repository.dart' show airportSettingsProvider;
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _shape(double n, double s, double e, double w) => jsonEncode({
  'coords': [
    {'latitude': n, 'longitude': w},
    {'latitude': n, 'longitude': e},
    {'latitude': s, 'longitude': e},
    {'latitude': s, 'longitude': w},
  ],
  'bbox': {'north': n, 'south': s, 'east': e, 'west': w},
});

AirportArea _klia({bool? on}) => AirportArea.fromEntry('klia', {
  'name': 'KLIA',
  'code': 'KUL',
  'groupResults': ?on,
  'groupWords': ['klia2'],
  'boundary': _shape(2.75, 2.73, 101.72, 101.70),
})!;

final _midValley = AirportArea.fromEntry(
  'mv',
  placeAreaValues(
    {'name': 'Mid Valley Megamall'},
    {'groupResults': true, 'address': 'Lingkaran Syed Putra', 'lat': 3.1178, 'lon': 101.6772, 'placeType': 'mall'},
    _shape(3.122, 3.113, 101.682, 101.672),
  ),
  kind: AreaKind.place,
  sizeM2: 1e6,
)!;

const GateRow _kliaRow = (id: 'klia', values: <String, dynamic>{'name': 'KLIA', 'placeType': 'airport', 'lat': 2.74, 'lon': 101.71});
const GateRow _mvRow = (
  id: 'mv',
  values: <String, dynamic>{'name': 'Mid Valley Megamall', 'placeType': 'mall', 'lat': 3.1178, 'lon': 101.6772},
);
final List<GateRow> _gates = [
  (id: 'door4', values: <String, dynamic>{'placeId': 'klia', 'name': 'Door 4', 'lat': 2.741, 'lon': 101.711}),
  (id: 'north', values: <String, dynamic>{'placeId': 'mv', 'name': 'North Court', 'lat': 3.119, 'lon': 101.678}),
];

const _addresses = [
  Place.suggestion(name: 'KLIA2 Arrival Lane', address: 'Sepang, Selangor', placeId: 's1'),
  Place.suggestion(name: 'Gateway@klia2', address: 'Persiaran Klia 2, Sepang', placeId: 's2'),
  Place.suggestion(name: 'Jalan Klia 2/1', address: 'klia2, Sepang', placeId: 's3'),
  Place.suggestion(name: 'Kuala Lumpur Sentral', address: 'Kuala Lumpur', placeId: 's4'),
];

class _Geo extends GeoService {
  _Geo(this.results);
  final List<Place> results;

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => results;
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class _QuietAdminLive extends AdminLiveTables {
  @override
  Map<String, int> build() => const {};
}

/// The writes to `multi_gate` and `airport_areas`, as PostgREST would take them.
class _FakeDb {
  final places = <Map<String, dynamic>>[];
  final airports = <Map<String, dynamic>>[];

  late final SupabaseClient client = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((req) async {
      for (final (table, rows) in [('multi_gate', places), ('airport_areas', airports)]) {
        if (req.url.path.endsWith('/rest/v1/$table') && req.method == 'POST') {
          final body = jsonDecode(req.body);
          for (final r in (body is List ? body : [body])) {
            rows.add(Map<String, dynamic>.from(r as Map));
          }
          return http.Response('', 201, request: req);
        }
      }
      return http.Response('[]', 200, headers: {'content-type': 'application/json'}, request: req);
    }),
  );
}

/// Pumps a while: the Edit button spins while its sheet is open, so the
/// tree never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  test('the forms read and write the switch and words; other keys are kept', () {
    expect(AirportForm().groupResults, isTrue, reason: 'airports group by default (as before)');
    expect(PlaceForm().groupResults, isFalse);
    expect(PlaceForm.fromValues({'groupResults': true, 'groupWords': ['KLIA2 ', 'klia2']}).groupWords, ['klia2']);
    final a = AirportForm.fromValues({'name': 'KLIA', 'groupResults': false})..groupWords = ['Klia2', ' klia2'];
    final saved = airportSaveValues({'boundary': 'b', 'note': 'kept'}, a);
    expect(saved['groupResults'], isFalse);
    expect(saved['groupWords'], ['klia2']);
    expect(saved['boundary'], 'b');
    expect(saved['note'], 'kept');
    expect(addGroupWord(['klia2'], '  KLIA2 '), ['klia2']);
    expect(addGroupWord(['klia2'], ' Terminal   1 '), ['klia2', 'terminal 1']);
    expect(addGroupWord(const [], '  '), isEmpty);
    expect(placeGroupBlocked(null), 'Draw a boundary first');
    expect(placeGroupBlocked({'areaOn': true}), 'Draw a boundary first');
    expect(placeGroupBlocked({'areaOn': false, 'boundary': _shape(1, 0, 1, 0)}), 'Turn the boundary on first');
    expect(placeGroupBlocked({'areaOn': true, 'boundary': _shape(1, 0, 1, 0)}), isNull);
  });

  test("a place area takes its grouping, address, position and type from its multi_gate row", () {
    expect(_midValley.groupResults, isTrue);
    expect(_midValley.address, 'Lingkaran Syed Putra');
    expect(_midValley.point, const LatLng(3.1178, 101.6772));
    expect(_midValley.placeType, 'mall');
    final unread = AirportArea.fromEntry(
      'mv',
      placeAreaValues({'name': 'Mid Valley'}, null, _shape(1, 0, 1, 0)),
      kind: AreaKind.place,
    )!;
    expect(unread.groupResults, isFalse);
    expect(unread.name, 'Mid Valley');
  });

  for (final b in Brightness.values) {
    group('${b.name}:', () {
      Future<PlacePick? Function()> openSearch(WidgetTester tester, List<Place> results, List<AirportArea> areas) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(500, 1000);
        addTearDown(tester.view.reset);
        PlacePick? picked;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recentPlacesProvider.overrideWith((ref) async => const []),
              geoServiceProvider.overrideWithValue(_Geo(results)),
              placeGatesProvider.overrideWith((ref) async => (places: [_kliaRow, _mvRow], gates: _gates)),
              airportAreasProvider.overrideWith((ref) async => areas),
              airportSettingsProvider.overrideWith((ref) async => const {}),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async =>
                        picked = await showPlaceSearch(context, title: 'Drop-off', usage: GateUsage.drop),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'klia');
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        return () => picked;
      }

      testWidgets('"klia": the klia2 addresses show as one KLIA row; tapping it opens its doors', (tester) async {
        await openSearch(tester, _addresses, [_klia()]);
        expect(find.text('KLIA'), findsOneWidget);
        expect(find.text('KLIA2 Arrival Lane'), findsNothing);
        expect(find.text('Gateway@klia2'), findsNothing);
        expect(find.text('Jalan Klia 2/1'), findsNothing);
        expect(find.text('Kuala Lumpur Sentral'), findsOneWidget, reason: 'no word of KLIA in it');
        final more = find.byKey(const ValueKey('result-grouped-klia'));
        expect(tester.widget<Text>(more).data, '+ 3 more results inside KLIA');
        expect(find.textContaining('Choose a gate'), findsOneWidget);
        // KLIA comes first: where its first result was.
        expect(tester.getTopLeft(find.text('KLIA')).dy < tester.getTopLeft(find.text('Kuala Lumpur Sentral')).dy, isTrue);

        await tester.tap(find.text('KLIA'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.byKey(const ValueKey('gate-picker-title'))).data, 'KLIA');
        expect(tester.takeException(), isNull);
      });

      testWidgets('switched off, every result shows as it is', (tester) async {
        await openSearch(tester, _addresses, [_klia(on: false)]);
        for (final p in _addresses) {
          expect(find.text(p.name), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('result-grouped-klia')), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a place that groups: one row as the place, its doors on tap', (tester) async {
        await openSearch(tester, const [
          Place(name: 'Uniqlo', address: 'Mid Valley City', point: LatLng(3.118, 101.677)),
          Place(name: 'Bangsar Village', address: 'Bangsar', point: LatLng(3.130, 101.670)),
          Place(name: 'MV Food Court', address: 'Mid Valley City', point: LatLng(3.1185, 101.6775)),
        ], [_klia(), _midValley]);
        expect(find.text('Uniqlo'), findsNothing);
        expect(find.text('Mid Valley Megamall'), findsOneWidget);
        expect(find.text('Bangsar Village'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('result-grouped-mv'))).data,
          '+ 2 more results inside Mid Valley Megamall',
        );
        // Shown as a place: its type, then "1 gate · address".
        expect(find.byKey(const ValueKey('result-type-icon-3.1178,101.6772')), findsOneWidget);

        await tester.tap(find.text('Mid Valley Megamall'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.byKey(const ValueKey('gate-picker-title'))).data, 'Mid Valley Megamall');
        expect(tester.takeException(), isNull);
      });

      Future<_FakeDb> pumpAdmin(WidgetTester tester, Widget home, {List<GeoEntry> places = const [], List<GeoEntry> airports = const []}) async {
        final db = _FakeDb();
        tester.view.physicalSize = const Size(1200, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              supabaseProvider.overrideWithValue(db.client),
              liveTablesProvider.overrideWith(_QuietLive.new),
              adminLiveTablesProvider.overrideWith(_QuietAdminLive.new),
              pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
              multiGatePlacesProvider.overrideWith((ref) async => places),
              airportsProvider.overrideWith((ref) async => airports),
              airportSettingsProvider.overrideWith((ref) async => const {}),
            ],
            child: MaterialApp(theme: appTheme(b), home: home),
          ),
        );
        await tester.pumpAndSettle();
        return db;
      }

      SwitchListTile groupSwitch(WidgetTester tester) =>
          tester.widget<SwitchListTile>(find.byKey(const ValueKey('group-results-switch')));

      Future<void> addWord(WidgetTester tester, String word) async {
        await tester.ensureVisible(find.byKey(const ValueKey('group-words-field')));
        await tester.enterText(find.byKey(const ValueKey('group-words-field')), word);
        await tester.tap(find.byKey(const ValueKey('group-words-add')));
        await _settle(tester);
      }

      testWidgets('Edit Airport: on by default, words added and removed, saved with the rest', (tester) async {
        final db = await pumpAdmin(
          tester,
          const AdminAirportAreasScreen(),
          airports: [
            GeoEntry(
              id: 'a1',
              values: {
                'name': 'KLIA',
                'country': 'Malaysia',
                'placeName': 'KLIA',
                'lat': '2.74',
                'lon': '101.70',
                'boundary': 'kept',
                'placeType': 'airport',
              },
            ),
          ],
        );
        await tester.tap(find.byTooltip('Edit details'));
        await _settle(tester);
        expect(find.text('Group search results inside the boundary'), findsOneWidget);
        expect(find.text('Addresses, roads and shops inside show as this one result.'), findsOneWidget);
        expect(find.text('For results Google gives without a position.'), findsOneWidget);
        expect(groupSwitch(tester).value, isTrue, reason: "an airport's default");

        await addWord(tester, ' KLIA2 ');
        await addWord(tester, 'klia2');
        await addWord(tester, 'Gateway');
        expect(find.byKey(const ValueKey('group-word-klia2')), findsOneWidget, reason: 'lower case, once');
        expect(find.byKey(const ValueKey('group-word-gateway')), findsOneWidget);
        await tester.tap(find.byTooltip('Remove gateway'));
        await _settle(tester);
        expect(find.byKey(const ValueKey('group-word-gateway')), findsNothing);

        // The sheet's Save (the page's Places inside an airport card has one too).
        await tester.ensureVisible(find.text('Save').last);
        await tester.tap(find.text('Save').last);
        await _settle(tester);
        final saved = db.airports.single['values'] as Map;
        expect(saved['groupResults'], isTrue);
        expect(saved['groupWords'], ['klia2']);
        expect(saved['boundary'], 'kept');
        expect(saved['placeType'], 'airport', reason: 'keys the form does not edit are kept');
        expect(tester.takeException(), isNull);
      });

      testWidgets('Edit Place with a boundary: switched on with a word, saved with the rest', (tester) async {
        final db = await pumpAdmin(
          tester,
          const AdminMultiGatePlacesScreen(),
          places: [
            GeoEntry(
              id: 'p1',
              values: {'name': 'Mid Valley', 'gates': 3, 'areaOn': true, 'boundary': _shape(3.122, 3.113, 101.682, 101.672), 'partOf': 'MV'},
            ),
          ],
        );
        await tester.tap(find.byKey(const ValueKey('place-edit-p1')));
        await _settle(tester);
        expect(groupSwitch(tester).value, isFalse, reason: "a place's default");
        expect(tester.widget<TextField>(find.byKey(const ValueKey('group-words-field'))).enabled, isFalse,
            reason: 'dimmed while off');
        await tester.ensureVisible(find.byKey(const ValueKey('group-results-switch')));
        await tester.tap(find.byKey(const ValueKey('group-results-switch')));
        await _settle(tester);
        expect(groupSwitch(tester).value, isTrue);
        await addWord(tester, 'The Gardens');

        await tester.ensureVisible(find.text('Save changes'));
        await tester.tap(find.text('Save changes'));
        await _settle(tester);
        final saved = db.places.single['values'] as Map;
        expect(saved['groupResults'], isTrue);
        expect(saved['groupWords'], ['the gardens']);
        expect(saved['areaOn'], isTrue);
        expect(saved['boundary'], isA<String>());
        expect(saved['partOf'], 'MV', reason: 'the other keys are kept');
        expect(tester.takeException(), isNull);
      });

      testWidgets('Edit Place without a boundary: the switch is off and says why', (tester) async {
        await pumpAdmin(
          tester,
          const AdminMultiGatePlacesScreen(),
          places: [
            GeoEntry(id: 'p3', values: {'name': 'Mid Valley', 'gates': 3, 'groupResults': true}),
          ],
        );
        await tester.tap(find.byKey(const ValueKey('place-edit-p3')));
        await _settle(tester);
        expect(groupSwitch(tester).onChanged, isNull);
        expect(groupSwitch(tester).value, isFalse);
        expect(find.text('Draw a boundary first'), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const ValueKey('group-words-field'))).enabled, isFalse);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
