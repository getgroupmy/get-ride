// Place types (migration 0264) on screen, light and dark: Admin > Place
// types (the list with icon and count, the editor with its searchable icon
// picker and colours, add, and remove with the move of its places), the
// Edit Place picker on Multi-Gate Places (the guess from the name, then the
// admin's choice), the rider's search result and saved place at a place,
// and the driver's request with the pickup's and drop-off's type.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/multi_gate_screens.dart';
import 'package:get_ride/src/admin/screens/geo/place_types_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/core/place_types.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/saved_places.dart';
import 'package:get_ride/src/data/airport_repository.dart' show airportSettingsProvider;
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/data/place_types_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/saved_places_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/place_type_badge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class _QuietAdminLive extends AdminLiveTables {
  @override
  Map<String, int> build() => const {};
}

/// `place_types` and the writes to it and `multi_gate`, as PostgREST would.
class _FakeDb {
  _FakeDb() {
    for (final t in defaultPlaceTypes) {
      types[t.key] = t.toRow();
    }
  }

  final types = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  final places = <Map<String, dynamic>>[];

  late final SupabaseClient client = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(_handle),
  );

  http.Response _json(Object body, http.Request req) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'}, request: req);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/rest/v1/place_types')) {
      switch (req.method) {
        case 'GET':
          final list = types.values.toList()
            ..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int));
          return _json(list, req);
        case 'POST':
          final body = jsonDecode(req.body);
          for (final r in (body is List ? body : [body])) {
            final m = Map<String, dynamic>.from(r as Map);
            types[m['key'] as String] = m;
            writes.add('upsert ${m['key']} ${m['icon']} ${m['color']} ${m['color_dark']}');
          }
          return http.Response('', 201, request: req);
      }
    }
    if (path.endsWith('/rest/v1/rpc/place_type_remove')) {
      final p = jsonDecode(req.body) as Map;
      types.remove(p['p_key']);
      writes.add('remove ${p['p_key']} to ${p['p_move_to']}');
      return _json(1, req);
    }
    if (path.endsWith('/rest/v1/multi_gate') && req.method == 'POST') {
      final body = jsonDecode(req.body);
      for (final r in (body is List ? body : [body])) {
        places.add(Map<String, dynamic>.from(r as Map));
      }
      return http.Response('', 201, request: req);
    }
    return _json([], req);
  }
}

final _places = [
  GeoEntry(id: 'p1', values: {'name': 'KLCC', 'gates': 4, 'placeType': 'shopping_mall', 'placeTypeSet': false}),
  GeoEntry(id: 'p2', values: {'name': 'Mid Valley Megamall', 'gates': 5, 'placeType': 'shopping_mall', 'placeTypeSet': true}),
  GeoEntry(id: 'p3', values: {'name': 'KL Sentral', 'gates': 6, 'placeType': 'train_station'}),
  GeoEntry(id: 'p4', values: {'name': 'Old place', 'gates': 2}),
];

Future<_FakeDb> _pumpAdmin(WidgetTester tester, Brightness b, Widget home, {Size size = const Size(1200, 1800)}) async {
  final db = _FakeDb();
  tester.view.physicalSize = size;
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
        multiGatePlacesProvider.overrideWith((ref) async => _places),
        airportSettingsProvider.overrideWith((ref) async => const {}),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return db;
}

/// Pumps a while: the Edit button spins while its sheet is open, so the
/// tree never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  test('listed under Geography next to Multi-gate places, grantable, followed live', () {
    final i = allAdminEntries.indexWhere((e) => e.path == '/admin/m/multi-gate-places');
    final e = allAdminEntries[i + 1];
    expect(e.path, placeTypesPath);
    expect(e.title, 'Place types');
    expect(e.section, 'Geography');
    expect(e.pages, containsAll([placeTypesPage, multiGatePlacesPage]));
    expect(grantablePages, contains(placeTypesPage));
    expect(liveSettingTables, contains('place_types'));
  });

  for (final b in Brightness.values) {
    group('${b.name}:', () {
      testWidgets('the admin page lists each type with its icon and how many places use it', (tester) async {
        await _pumpAdmin(tester, b, const PlaceTypesScreen());
        expect(find.text('Place types'), findsWidgets);
        for (final t in defaultPlaceTypes) {
          expect(find.byKey(ValueKey('place-type-${t.key}')), findsOneWidget, reason: t.key);
        }
        Text count(String k) => tester.widget<Text>(find.byKey(ValueKey('place-type-count-$k')));
        expect(count('shopping_mall').data, '2');
        expect(count('train_station').data, '1');
        expect(count('point_of_interest').data, '1', reason: 'a place without a type counts as Other');
        expect(count('ferry_terminal').data, '0');
        // A white glyph on a square of the type's colour for this brightness.
        final mall = defaultPlaceTypes.first;
        final box = tester.widget<Container>(
          find.descendant(of: find.byKey(const ValueKey('place-type-shopping_mall')), matching: find.byType(Container)).first,
        );
        expect((box.decoration! as BoxDecoration).color, mall.colorFor(b));
        final icon = tester.widget<Icon>(
          find.descendant(of: find.byKey(const ValueKey('place-type-shopping_mall')), matching: find.byIcon(Icons.local_mall)),
        );
        expect(icon.color, Colors.white, reason: 'a white glyph on the category colour');
        expect(tester.takeException(), isNull);
      });

      testWidgets('edit a type: the searchable icon picker, both colours, save', (tester) async {
        final db = await _pumpAdmin(tester, b, const PlaceTypesScreen());
        await tester.tap(find.byKey(const ValueKey('place-type-lodging')));
        await tester.pumpAndSettle();
        expect(find.text('Google place type: lodging · used by 0 places'), findsOneWidget);
        expect(find.byKey(const ValueKey('place-type-preview-light')), findsOneWidget);
        expect(find.byKey(const ValueKey('place-type-preview-dark')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('place-type-icon')));
        await tester.pumpAndSettle();
        // The icon list is long: it has a search box.
        await tester.enterText(find.byType(TextField).last, 'bed');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bed').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('place-type-colour-light')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('place-type-colour-#4db546')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('place-type-colour-ok')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('place-type-colour-dark')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('place-type-colour-hex')), '#ABCDEF');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('place-type-colour-ok')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('place-type-save')));
        await tester.pumpAndSettle();
        expect(db.writes, ['upsert lodging bed #4db546 #abcdef']);
        expect(tester.takeException(), isNull);
      });

      testWidgets("add a type: picked from Google's place types, searchable", (tester) async {
        final db = await _pumpAdmin(tester, b, const PlaceTypesScreen());
        await tester.tap(find.byKey(const ValueKey('place-type-add')));
        await tester.pumpAndSettle();
        expect(find.text('Add a Google place type'), findsOneWidget);
        expect(find.text('shopping_mall'), findsNothing, reason: 'types on the list already are left out');
        await tester.enterText(find.byType(TextField).last, 'car rent');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Car rental').last);
        await tester.pumpAndSettle();
        expect(find.text('Google place type: car_rental'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('place-type-name')), 'Car hire');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('place-type-save')));
        await tester.pumpAndSettle();
        expect(db.writes.single, 'upsert car_rental car_rental $placeColorTransport $placeColorTransport');
        expect(db.types['car_rental']?['name'], 'Car hire');
        expect(db.types['car_rental']?['sort_order'], 180, reason: 'after the last one but Other');
        expect(tester.takeException(), isNull);
      });

      testWidgets('a type in use is removed by moving its places; Other stays', (tester) async {
        final db = await _pumpAdmin(tester, b, const PlaceTypesScreen());
        await tester.tap(find.byKey(const ValueKey('place-type-point_of_interest')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('place-type-remove')), findsNothing);
        expect(find.textContaining("Other can't be removed"), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('place-type-train_station')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('place-type-remove')));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 place uses Train station'), findsOneWidget);
        expect(find.byKey(const ValueKey('place-type-move-to')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('place-type-remove-yes')));
        await tester.pumpAndSettle();
        expect(db.writes, ['remove train_station to point_of_interest']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Edit Place: the type picker guesses from the name until the admin picks', (tester) async {
        final db = await _pumpAdmin(tester, b, const AdminMultiGatePlacesScreen());
        // The list rows show the type.
        expect(find.byKey(const ValueKey('place-type-icon-p1')), findsOneWidget);
        expect(
          tester.widget<PlaceTypePill>(find.byKey(const ValueKey('place-type-pill-p3'))).type.key,
          'train_station',
        );
        expect(
          tester.widget<PlaceTypePill>(find.byKey(const ValueKey('place-type-pill-p4'))).type.key,
          'point_of_interest',
          reason: 'no type: Other',
        );

        await tester.tap(find.byTooltip('Edit').first);
        await _settle(tester);
        expect(find.byKey(const ValueKey('place-type-picker')), findsOneWidget);
        ChoiceChip chip(String k) => tester.widget<ChoiceChip>(find.byKey(ValueKey('place-type-chip-$k')));
        expect(chip('shopping_mall').selected, isTrue);
        expect(find.text('Suggested from the name'), findsOneWidget);
        // Renamed: the guess follows.
        await tester.enterText(find.widgetWithText(TextField, 'Place Name *'), 'Masjid Negara');
        await _settle(tester);
        expect(chip('mosque').selected, isTrue);
        expect(chip('shopping_mall').selected, isFalse);
        // The admin picks one: set.
        await tester.ensureVisible(find.byKey(const ValueKey('place-type-chip-lodging')));
        await tester.tap(find.byKey(const ValueKey('place-type-chip-lodging')));
        await _settle(tester);
        expect(chip('lodging').selected, isTrue);
        expect(find.text('Set by admin'), findsOneWidget);
        await tester.ensureVisible(find.text('Save changes'));
        await tester.tap(find.text('Save changes'));
        await _settle(tester);
        final saved = db.places.single['values'] as Map;
        expect(saved['placeType'], 'lodging');
        expect(saved['placeTypeSet'], true);
        expect(saved['gates'], 4, reason: 'the rest of the place is kept');
        expect(tester.takeException(), isNull);
      });

      testWidgets("the rider's search result and saved place at a place show its type", (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(tester.view.reset);
        const mall = Place(name: 'Mid Valley', address: 'Lingkaran Syed Putra', point: LatLng(3.1178, 101.6772));
        const sentral = Place(name: 'KL Sentral', address: 'Jalan Stesen Sentral', point: LatLng(3.1340, 101.6860));
        const nowhere = Place(name: 'A street', address: 'Somewhere', point: LatLng(3.3, 101.9));
        final places = <GateRow>[
          (id: 'mall', values: {'name': 'Mid Valley Megamall', 'lat': '3.1178', 'lon': '101.6772', 'placeType': 'shopping_mall', 'gateRequired': false, 'iconBackgroundColor': '#123456'}),
          // No type yet: Other.
          (id: 'sentral', values: {'name': 'KL Sentral', 'lat': '3.1340', 'lon': '101.6860', 'gateRequired': false}),
        ];
        final gates = <GateRow>[
          for (final n in ['A', 'B', 'C', 'D'])
            (id: 'g$n', values: {'placeId': 'mall', 'name': 'Gate $n', 'mode': 'both'}),
        ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recentPlacesProvider.overrideWith((ref) async => const []),
              geoServiceProvider.overrideWithValue(_Geo(const [mall, sentral, nowhere])),
              placeGatesProvider.overrideWith((ref) async => (places: places, gates: gates)),
              placeTypesProvider.overrideWith((ref) async => defaultPlaceTypes),
              savedPlacesProvider.overrideWith((ref) async => const []),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showPlaceSearch(context, title: 'Drop-off'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'm');
        await tester.pumpAndSettle(const Duration(milliseconds: 500));

        final mallIcon = tester.widget<PlaceTypeIcon>(find.byKey(const ValueKey('result-type-icon-3.1178,101.6772')));
        expect(mallIcon.type.key, 'shopping_mall');
        final line = tester.widget<Text>(find.byKey(const ValueKey('result-type-3.1178,101.6772')));
        expect(line.textSpan!.toPlainText(), contains(' · 4 gates · '));
        expect(
          find.descendant(of: find.byKey(const ValueKey('result-type-3.1178,101.6772')), matching: find.byType(PlaceTypePill)),
          findsOneWidget,
        );
        final sentralIcon = tester.widget<PlaceTypeIcon>(find.byKey(const ValueKey('result-type-icon-3.134,101.686')));
        expect(sentralIcon.type.key, 'point_of_interest', reason: 'a place without a type shows Other');
        expect(find.byKey(const ValueKey('result-type-icon-3.3,101.9')), findsNothing, reason: 'not a place');
        // The square is in the type's colour for this brightness.
        final square = tester.widget<Icon>(
          find.descendant(of: find.byKey(const ValueKey('result-type-icon-3.1178,101.6772')), matching: find.byType(Icon)),
        );
        expect(square.color, Colors.white);
        final chipBox = tester.widget<Container>(
          find.descendant(of: find.byKey(const ValueKey('result-type-icon-3.1178,101.6772')), matching: find.byType(Container)),
        );
        expect((chipBox.decoration! as BoxDecoration).color, const Color(0xFF123456),
            reason: "the colour Google gave the place");
        expect(tester.takeException(), isNull);
      });

      testWidgets('a saved place at a Multi-Gate place shows its type', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(tester.view.reset);
        const at = LatLng(3.1178, 101.6772);
        final places = <GateRow>[
          (id: 'mall', values: {'name': 'Mid Valley Megamall', 'lat': '3.1178', 'lon': '101.6772', 'placeType': 'shopping_mall'}),
        ];
        final gates = <GateRow>[
          for (final n in ['A', 'B'])
            (id: 'g$n', values: {'placeId': 'mall', 'name': 'Gate $n', 'mode': 'both'}),
        ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recentPlacesProvider.overrideWith((ref) async => const []),
              currentUserIdProvider.overrideWithValue('me'),
              savedPlacesProvider.overrideWith((ref) async => const [
                SavedPlace(id: 's1', kind: SavedPlaceKind.other, name: 'Mid Valley', address: 'Lingkaran Syed Putra', point: at),
                SavedPlace(id: 's2', kind: SavedPlaceKind.other, name: 'Aunt', address: 'Taman Melati', point: LatLng(3.22, 101.73)),
                // A kilometre away: near, but not at the mall.
                SavedPlace(id: 's3', kind: SavedPlaceKind.other, name: 'Cousin', address: 'Bangsar', point: LatLng(3.1268, 101.6772)),
              ]),
              geoServiceProvider.overrideWithValue(_Geo(const [])),
              placeGatesProvider.overrideWith((ref) async => (places: places, gates: gates)),
              placeTypesProvider.overrideWith((ref) async => defaultPlaceTypes),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showPlaceSearch(
                      context,
                      title: 'Enter your route',
                      near: at,
                      from: const Place(name: 'Here', address: '', point: LatLng(3.15, 101.7)),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('place-tab-saved')));
        await tester.pumpAndSettle();
        expect(tester.widget<PlaceTypeIcon>(find.byKey(const ValueKey('saved-type-icon-s1'))).type.key, 'shopping_mall');
        final line = tester.widget<Text>(find.byKey(const ValueKey('saved-type-s1')));
        expect(line.textSpan!.toPlainText(), contains(' · 2 gates · '));
        expect(find.byKey(const ValueKey('saved-type-icon-s2')), findsNothing, reason: 'not at a place');
        expect(find.byKey(const ValueKey('saved-type-icon-s3')), findsNothing, reason: 'a kilometre off');
        expect(tester.takeException(), isNull);
      });

      testWidgets("the driver's request shows the pickup's and drop-off's type", (tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRepositoryProvider.overrideWithValue(_Rides()),
              placeTypesProvider.overrideWith((ref) async => defaultPlaceTypes),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: RideRequestSheet(
                    request: _ride(pickup: 'shopping_mall', drop: 'airport'),
                    shown: Duration.zero,
                    now: DateTime.now(),
                    onAccept: () async {},
                    onSkip: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final pick = find.byKey(const ValueKey('request-pickup-type'));
        final drop = find.byKey(const ValueKey('request-drop-type'));
        expect(find.descendant(of: pick, matching: find.text('Mall')), findsOneWidget);
        expect(find.descendant(of: pick, matching: find.byIcon(Icons.local_mall)), findsOneWidget);
        expect(find.descendant(of: drop, matching: find.text('Airport')), findsOneWidget);
        expect(find.descendant(of: drop, matching: find.byIcon(Icons.flight)), findsOneWidget);
        final label = tester.widget<Text>(find.descendant(of: pick, matching: find.text('Mall')));
        expect(label.style?.color, defaultPlaceTypes.first.labelColorFor(b));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a ride end at no place shows no type; an unknown one shows Other', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [placeTypesProvider.overrideWith((ref) async => defaultPlaceTypes)],
            child: MaterialApp(
              theme: appTheme(b),
              home: const Scaffold(
                body: Column(children: [
                  RidePlaceTypeTag(key: ValueKey('none'), typeKey: null),
                  RidePlaceTypeTag(key: ValueKey('gone'), typeKey: 'spaceport'),
                ]),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.descendant(of: find.byKey(const ValueKey('none')), matching: find.byType(PlaceTypeTag)), findsNothing);
        expect(find.descendant(of: find.byKey(const ValueKey('gone')), matching: find.text('Other')), findsOneWidget);
      });
    });
  }
}

RideRequest _ride({String? pickup, String? drop}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC - Gate A',
  'pickup_address': 'Jalan Ampang, Kuala Lumpur',
  'drop_name': 'KLIA Terminal 1',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 2.7456,
  'drop_lng': 101.7072,
  'distance_km': 50,
  'duration_min': 45,
  'payment_mode': 'Cash',
  'passengers': 1,
  'pickup_place_type': pickup,
  'drop_place_type': drop,
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

class _Rides implements RideRepository {
  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  _Geo(this.results);
  final List<Place> results;

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => results;
}
