// "Part of": places linked into one door sheet (KLIA Terminal 1 and 2, both
// part of KLIA), kept in multi_gate / airport_areas `values.partOf` and
// `values.partOrder`. The pure helpers (the linked places in order, their
// gates for the usage, the doors grouped by place), the rider's door sheet
// with a wheel of the linked places (and one wheel for a place on its own),
// and the admin's Part of and Order on Edit Place, its suggestions and hint,
// the save, and the grouped list, light and dark.
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
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/core/gate_snap.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/data/airport_repository.dart' show airportSettingsProvider;
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/features/ride/gate_picker.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

GateRow _place(String id, String name, double lat, double lon, {String? partOf, Object? order, Object? active}) => (
  id: id,
  values: <String, dynamic>{
    'name': name,
    'lat': lat,
    'lon': lon,
    'partOf': ?partOf,
    'partOrder': ?order,
    'active': ?active,
  },
);

GateRow _gate(String id, String place, String name, {String? mode, double? lat, double? lon, Object? priority}) => (
  id: id,
  values: <String, dynamic>{
    'placeId': place,
    'name': name,
    'mode': ?mode,
    'lat': ?lat,
    'lon': ?lon,
    'displayPriority': ?priority,
  },
);

final _t1 = _place('t1', 'KLIA Terminal 1', 2.7456, 101.7072, partOf: 'KLIA', order: 1);
final _t2 = _place('t2', 'KLIA Terminal 2', 2.7417, 101.6853, partOf: '  klia ', order: '2');
final _cargo = _place('cargo', 'KLIA Cargo', 2.75, 101.70, partOf: 'KLIA', order: 0, active: false);
final _mall = _place('mall', 'Mid Valley Megamall', 3.1178, 101.6772);

final _gates = [
  _gate('d1', 't1', 'Door 1', mode: 'pickup', lat: 2.7457, lon: 101.7073),
  _gate('drop1', 't1', 'Drop Door', mode: 'drop'),
  _gate('arr1', 't2', 'Domestic Arrival Door 1', lat: 2.7418, lon: 101.6854, priority: 1),
  _gate('arr2', 't2', 'Domestic Arrival Door 2', priority: 2),
  _gate('cargo1', 'cargo', 'Cargo Gate'),
  _gate('north', 'mall', 'North Court', lat: 3.1179, lon: 101.6773),
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

/// The writes to `multi_gate`, as PostgREST would take them.
class _FakeDb {
  final places = <Map<String, dynamic>>[];
  final airports = <Map<String, dynamic>>[];

  late final SupabaseClient client = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/rest/v1/multi_gate') && req.method == 'POST') {
        final body = jsonDecode(req.body);
        for (final r in (body is List ? body : [body])) {
          places.add(Map<String, dynamic>.from(r as Map));
        }
        return http.Response('', 201, request: req);
      }
      if (req.url.path.endsWith('/rest/v1/airport_areas') && req.method == 'POST') {
        final body = jsonDecode(req.body);
        for (final r in (body is List ? body : [body])) {
          airports.add(Map<String, dynamic>.from(r as Map));
        }
        return http.Response('', 201, request: req);
      }
      return http.Response('[]', 200, headers: {'content-type': 'application/json'}, request: req);
    }),
  );
}

Finder _wheelText(String wheel, int i) => find.byKey(ValueKey('$wheel-$i'));

String _title(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('gate-picker-title'))).data ?? '';

/// Pumps a while: the Edit button spins while its sheet is open, so the
/// tree never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  group('linkedGatedPlaces', () {
    final places = [_mall, _t2, _cargo, _t1, _place('aero', 'Aerotrain', 2.744, 101.70, partOf: 'Klia', order: 2)];

    test('the places with the same Part of, active, in order then by name', () {
      final linked = linkedGatedPlaces(places: places, gates: _gates, placeId: 't2');
      expect(linked.map((l) => l.id), ['t1', 'aero', 't2'], reason: 'any case and spacing; Cargo is switched off');
      expect(linked.first.partOf, 'KLIA');
      expect(linked.first.point, const LatLng(2.7456, 101.7072));
    });

    test('each with its gates for the usage, in display order', () {
      final pickup = linkedGatedPlaces(places: places, gates: _gates, placeId: 't1', usage: GateUsage.pickup);
      expect(pickup.first.gates.map((g) => g.id), ['d1']);
      expect(pickup.last.gates.map((g) => g.id), ['arr1', 'arr2']);
      final drop = linkedGatedPlaces(places: places, gates: _gates, placeId: 't1', usage: GateUsage.drop);
      expect(drop.first.gates.map((g) => g.id), ['drop1']);
    });

    test('a place on its own is just itself; an unknown one nothing', () {
      expect(linkedGatedPlaces(places: places, gates: _gates, placeId: 'mall').map((l) => l.id), ['mall']);
      expect(linkedGatedPlaces(places: places, gates: _gates, placeId: 'nowhere'), isEmpty);
    });

    test('matchGatedPlace is unchanged and now carries the Part of', () {
      final m = matchGatedPlace(places: places, gates: _gates, point: const LatLng(2.7417, 101.6853));
      expect(m?.id, 't2');
      expect(m?.gates.map((g) => g.name), ['Domestic Arrival Door 1', 'Domestic Arrival Door 2']);
      expect(m?.partOf, 'klia');
      expect(partOfKey(m?.partOf), 'klia');
      expect(partOfKey('  KLIA   Main '), 'klia main');
    });

    test('the doors are grouped by place, in the places order, and stay in it', () {
      final linked = linkedGatedPlaces(places: [_t2, _t1], gates: _gates, placeId: 't1', usage: GateUsage.pickup);
      final doors = linkedPlaceDoors(linked, {for (final g in _gates) g.id: g.values});
      expect(doors.map((d) => '${d.group}/${d.name}'), [
        'KLIA Terminal 1/Door 1',
        'KLIA Terminal 2/Domestic Arrival Door 1',
        'KLIA Terminal 2/Domestic Arrival Door 2',
      ]);
      expect(gateGroups(doors).map((g) => g.name), ['KLIA Terminal 1', 'KLIA Terminal 2']);
      // Two places of one name keep their doors apart.
      final twin = linkedPlaceDoors([
        GatedPlace(id: 'a', name: 'Hall', gates: const [GateOption(id: 'd1', name: 'x')], gateRequired: true),
        GatedPlace(id: 'b', name: 'Hall', gates: const [GateOption(id: 'arr1', name: 'y')], gateRequired: true),
      ], {for (final g in _gates) g.id: g.values});
      expect(twin.map((d) => d.group), ['Hall', 'Hall (2)']);
    });
  });

  group('admin Part of', () {
    final members = partOfMembers([
      (id: 'p2', values: {'name': 'KLIA Terminal 2', 'partOf': 'klia', 'partOrder': 2}),
      (id: 'p1', values: {'name': 'KLIA Terminal 1', 'partOf': 'KLIA', 'partOrder': 1}),
      (id: 'a1', values: {'name': 'Changi T1', 'partOf': 'Changi'}),
      (id: 'p3', values: {'name': 'Mid Valley'}),
    ]);

    test('names used once each (as the first in order writes it), A to Z', () {
      expect(partOfNames(members), ['Changi', 'KLIA']);
    });

    test('the hint says what the rider will see', () {
      expect(partOfHint('', members), 'Opens on its own, one wheel.');
      expect(partOfHint(' klia ', members, selfId: 'p3'), 'Opens with KLIA Terminal 1 and KLIA Terminal 2.');
      expect(partOfHint('KLIA', members, selfId: 'p1'), 'Opens with KLIA Terminal 2.');
      expect(
        partOfHint('Sunway', members),
        'New: "Sunway". Set the same Part of on the other places to join them.',
      );
    });

    test('the place and airport forms keep and write partOf and partOrder', () {
      final f = PlaceForm.fromValues({'name': 'KLIA Terminal 2', 'gates': 3, 'partOf': 'KLIA', 'partOrder': 2});
      expect(f.partOf, 'KLIA');
      expect(f.partOrder, '2');
      f.partOrder = '';
      expect(f.toValues(), containsPair('partOrder', 1));
      expect(PlaceForm().toValues(), allOf(containsPair('partOf', ''), containsPair('partOrder', 1)));

      final a = AirportForm.fromValues({'name': 'KLIA', 'country': 'Malaysia', 'placeName': 'KLIA', 'partOrder': 3})
        ..partOf = ' KLIA ';
      final saved = airportSaveValues({'name': 'old', 'boundary': 'b', 'placeType': 'airport', 'note': 'kept'}, a);
      expect(saved['partOf'], 'KLIA');
      expect(saved['partOrder'], 3);
      expect(saved['boundary'], 'b');
      expect(saved['note'], 'kept', reason: 'keys the form does not edit are kept');
    });

    test('the list groups by Part of, in order, the rest on their own', () {
      final groups = partOfGroups<Map<String, dynamic>>([
        {'name': 'Mid Valley'},
        {'name': 'KLIA Terminal 2', 'partOf': 'klia', 'partOrder': 2},
        {'name': 'KLIA Terminal 1', 'partOf': 'KLIA', 'partOrder': 1},
      ], (v) => v);
      expect(groups.map((g) => g.name), ['KLIA', ''], reason: 'as the first in order writes it');
      expect(groups.first.items.map((v) => v['name']), ['KLIA Terminal 1', 'KLIA Terminal 2']);
      expect(partOfGroups<Map<String, dynamic>>([{'name': 'A'}], (v) => v).single.name, '');
    });
  });

  for (final b in Brightness.values) {
    group('${b.name}:', () {
      Future<PlacePick? Function()> openSearch(WidgetTester tester, Place result, List<GateRow> places) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(500, 1000);
        addTearDown(tester.view.reset);
        PlacePick? picked;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recentPlacesProvider.overrideWith((ref) async => const []),
              geoServiceProvider.overrideWithValue(_Geo([result])),
              placeGatesProvider.overrideWith((ref) async => (places: places, gates: _gates)),
              airportAreasProvider.overrideWith((ref) async => const []),
              airportSettingsProvider.overrideWith((ref) async => const {}),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async =>
                        picked = await showPlaceSearch(context, title: 'Pickup', usage: GateUsage.pickup),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'place');
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        await tester.tap(find.text(result.name));
        await tester.pumpAndSettle();
        return () => picked;
      }

      testWidgets('a linked place opens with a wheel of the places; a door of the other is its own', (tester) async {
        const tapped = Place(name: 'KLIA T1', address: 'Sepang', point: LatLng(2.7456, 101.7072));
        final picked = await openSearch(tester, tapped, [_mall, _t2, _cargo, _t1]);

        expect(find.byKey(const ValueKey('gate-picker-groups')), findsOneWidget);
        expect(tester.widget<Text>(_wheelText('gate-picker-groups', 0)).data, 'KLIA Terminal 1');
        expect(tester.widget<Text>(_wheelText('gate-picker-groups', 1)).data, 'KLIA Terminal 2');
        expect(find.text('KLIA Cargo'), findsNothing, reason: 'switched off');
        // It opens on the tapped place, its pickup door on the gate wheel.
        expect(_title(tester), 'KLIA Terminal 1');
        expect(find.byKey(const ValueKey('gate-picker-gates-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('gate-dot-drop1')), findsNothing, reason: 'drop-off only');

        // The other place: the title follows the wheel.
        await tester.tap(_wheelText('gate-picker-groups', 1));
        await tester.pumpAndSettle();
        expect(_title(tester), 'KLIA Terminal 2');
        expect(find.byKey(const ValueKey('gate-picker-gates-1')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('gate-picker-done')));
        await tester.pumpAndSettle();
        expect(picked()?.place?.name, 'KLIA Terminal 2 - Domestic Arrival Door 1');
        expect(picked()?.place?.point, const LatLng(2.7418, 101.6854));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a place on its own keeps one wheel', (tester) async {
        const tapped = Place(name: 'Mid Valley', address: 'KL', point: LatLng(3.1178, 101.6772));
        final picked = await openSearch(tester, tapped, [_mall, _t1, _t2]);
        expect(find.byKey(const ValueKey('gate-picker-groups')), findsNothing);
        expect(_title(tester), 'Mid Valley Megamall');
        await tester.tap(find.byKey(const ValueKey('gate-picker-done')));
        await tester.pumpAndSettle();
        expect(picked()?.place?.name, 'Mid Valley Megamall - North Court');
        expect(tester.takeException(), isNull);
      });

      testWidgets('groups that are not linked places keep the place name as the title', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: GatePickerSheet(
                placeName: 'KLIA',
                tiles: false,
                gates: const [
                  AirportDoor(id: 'a', airportId: 'k', name: 'A', kind: DoorKind.both, lat: 2.7, lng: 101.7, group: 'T1'),
                  AirportDoor(id: 'b', airportId: 'k', name: 'B', kind: DoorKind.both, lat: 2.7, lng: 101.7, group: 'T2'),
                ],
                onDone: (_) {},
                onClose: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(_wheelText('gate-picker-groups', 1));
        await tester.pumpAndSettle();
        expect(_title(tester), 'KLIA');
      });

      Future<_FakeDb> pumpAdmin(WidgetTester tester, List<GeoEntry> places, {Widget? home, List<GeoEntry>? airports}) async {
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
              airportsProvider.overrideWith(
                (ref) async =>
                    airports ??
                    [
                      GeoEntry(id: 'a1', values: {'name': 'Changi Airport', 'partOf': 'Changi'}),
                    ],
              ),
              airportSettingsProvider.overrideWith((ref) async => const {}),
            ],
            child: MaterialApp(theme: appTheme(b), home: home ?? const AdminMultiGatePlacesScreen()),
          ),
        );
        await tester.pumpAndSettle();
        return db;
      }

      final klia = [
        GeoEntry(id: 'p2', values: {'name': 'KLIA Terminal 2', 'gates': 4, 'partOf': 'klia', 'partOrder': 2}),
        GeoEntry(id: 'p1', values: {'name': 'KLIA Terminal 1', 'gates': 6, 'partOf': 'KLIA', 'partOrder': 1}),
        GeoEntry(id: 'p3', values: {'name': 'Mid Valley', 'gates': 3, 'areaOn': false, 'boundary': 'kept'}),
      ];

      testWidgets('Edit Place: Part of with suggestions and a hint, Order, saved with the rest', (tester) async {
        final db = await pumpAdmin(tester, klia);
        await tester.tap(find.byKey(const ValueKey('place-edit-p3')));
        await _settle(tester);

        final field = find.byKey(const ValueKey('part-of-field'));
        expect(find.text('Part of (optional)'), findsOneWidget);
        expect(find.byKey(const ValueKey('part-order-field')), findsOneWidget);
        Text hint() => tester.widget<Text>(find.byKey(const ValueKey('part-of-hint')));
        expect(hint().data, 'Opens on its own, one wheel.');
        expect(find.byKey(const ValueKey('part-of-clear')), findsNothing);

        // A new name, then cleared.
        await tester.ensureVisible(field);
        await tester.enterText(field, 'Sunway');
        await _settle(tester);
        expect(hint().data, 'New: "Sunway". Set the same Part of on the other places to join them.');
        await tester.tap(find.byKey(const ValueKey('part-of-clear')));
        await _settle(tester);
        expect(hint().data, 'Opens on its own, one wheel.');

        // The names in use are suggested, places' and airports'.
        await tester.enterText(field, 'kl');
        await _settle(tester);
        expect(find.byKey(const ValueKey('part-of-option-KLIA')), findsOneWidget);
        expect(find.byKey(const ValueKey('part-of-option-Changi')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('part-of-option-KLIA')));
        await _settle(tester);
        expect(hint().data, 'Opens with KLIA Terminal 1 and KLIA Terminal 2.');
        await tester.enterText(find.byKey(const ValueKey('part-order-field')), '3');

        await tester.ensureVisible(find.text('Save changes'));
        await tester.tap(find.text('Save changes'));
        await _settle(tester);
        final saved = db.places.single['values'] as Map;
        expect(saved['partOf'], 'KLIA');
        expect(saved['partOrder'], 3);
        expect(saved['gates'], 3);
        expect(saved['boundary'], 'kept', reason: 'keys the form does not edit are kept');
        expect(tester.takeException(), isNull);
      });

      testWidgets('the list shows linked places under their Part of, the rest on their own', (tester) async {
        await pumpAdmin(tester, [
          ...klia,
          for (var i = 0; i < 6; i++) GeoEntry(id: 'x$i', values: {'name': 'Station $i', 'gates': 2}),
        ]);
        expect(find.text('KLIA · 2 places'), findsOneWidget);
        expect(find.text('On their own'), findsOneWidget);
        double y(String s) => tester.getTopLeft(find.text(s)).dy;
        expect(y('KLIA · 2 places') < y('KLIA Terminal 1'), isTrue);
        expect(y('KLIA Terminal 1') < y('KLIA Terminal 2'), isTrue, reason: 'in their order');
        expect(y('KLIA Terminal 2') < y('On their own'), isTrue);

        // The search box still filters the grouped list.
        await tester.enterText(find.byKey(const ValueKey('list-search')), 'terminal 2');
        await tester.pumpAndSettle();
        expect(find.text('KLIA Terminal 2'), findsOneWidget);
        expect(find.text('KLIA Terminal 1'), findsNothing);
        expect(find.text('On their own'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Edit Airport: Part of and Order too, shown on the row, saved with the rest', (tester) async {
        final db = await pumpAdmin(
          tester,
          klia,
          home: const AdminAirportAreasScreen(),
          airports: [
            GeoEntry(
              id: 'a1',
              values: {
                'name': 'KLIA Main',
                'country': 'Malaysia',
                'placeName': 'KLIA',
                'lat': '2.74',
                'lon': '101.70',
                'boundary': 'kept',
                'placeType': 'airport',
                'partOf': 'KLIA',
                'partOrder': 3,
              },
            ),
          ],
        );
        expect(find.textContaining('Part of: KLIA'), findsOneWidget);
        await tester.tap(find.byTooltip('Edit details'));
        await _settle(tester);
        expect(find.byKey(const ValueKey('part-of-field')), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const ValueKey('part-order-field'))).controller?.text, '3');
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('part-of-hint'))).data,
          'Opens with KLIA Terminal 1 and KLIA Terminal 2.',
        );
        await tester.enterText(find.byKey(const ValueKey('part-order-field')), '1');
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await _settle(tester);
        final saved = db.airports.single['values'] as Map;
        expect(saved['partOf'], 'KLIA');
        expect(saved['partOrder'], 1);
        expect(saved['boundary'], 'kept');
        expect(saved['placeType'], 'airport', reason: 'keys the form does not edit are kept');
        expect(tester.takeException(), isNull);
      });
    });
  }
}
