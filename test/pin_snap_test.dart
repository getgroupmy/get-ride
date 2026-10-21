// The pickup pin at a place with doors (0258, 0266), with the owner's
// Mitsui Outlet Park KLIA Sepang: five doors inside its boundary, which lies
// inside KLIA's own, and KLIA T2 (ERL), "Part of" KLIA, inside it too. Under
// the admin's Places inside an airport setting a pin dropped inside the mall
// runs on to the mall's nearest door (or KLIA's, with Always the airport),
// the door sheet lists all five and opens on the chosen one, and the gates
// are read past the API's 1,000-row page. The admin card saves the setting.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/admin/screens/geo/area_precedence_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/airport_areas.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/gate_snap.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/airport_repository.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/area_precedence_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/location_source.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/data/promo_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/gate_picker.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/map_drag_pin.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _mitsuiId = '450a0b30-5fc1-4790-9b8d-a5f5b400a850';
const _kliaId = '473ece8d-817b-4501-a5c2-725700071a78';
const _mitsuiName = 'Mitsui Outlet Park KLIA Sepang';
const _erlId = '00000000-0000-0000-0000-00000000e201';

String _box(double n, double s, double e, double w) => jsonEncode({
  'coords': [
    {'latitude': n, 'longitude': w},
    {'latitude': n, 'longitude': e},
    {'latitude': s, 'longitude': e},
    {'latitude': s, 'longitude': w},
  ],
  'bbox': {'north': n, 'south': s, 'east': e, 'west': w},
});

/// The mall's boundary, and KLIA's around it (and around the terminals).
final _mitsui = AirportArea.fromEntry(
  _mitsuiId,
  {'name': _mitsuiName, 'boundary': _box(2.7824, 2.7783, 101.6784, 101.6760)},
  kind: AreaKind.place,
  sizeM2: 2.1e5,
)!;
final _klia = AirportArea.fromEntry(_kliaId, {'name': 'KLIA', 'boundary': _box(2.83, 2.70, 101.76, 101.64)})!;

/// KLIA T2 (ERL), part of KLIA, with its own boundary and a door.
final _erl = AirportArea.fromEntry(
  _erlId,
  {'name': 'KLIA T2 (ERL)', 'boundary': _box(2.7440, 2.7400, 101.6880, 101.6840)},
  kind: AreaKind.place,
  sizeM2: 1.9e5,
)!;

/// The mall's doors as the live rows keep them (lat / lon, a priority).
const _doors = [
  ('e1', 'Entrance 1', 2.781703, 101.677272, 1),
  ('e2', 'Entrance 2', 2.780511, 101.67675, 2),
  ('e3', 'Entrance 3 (Lebuh Madani)', 2.77937, 101.676796, 3),
  ('e4', 'Entrance 4 (Lebuh Madani)', 2.778864, 101.677224, 4),
  ('e5', 'Entrance 5 (Lebuh Madani)', 2.779317, 101.677707, 5),
];

GateRow _gateRow(String id, String place, String name, double lat, double lon, int priority, String parent) => (
  id: id,
  values: <String, dynamic>{
    'placeId': place,
    'parentKey': parent,
    'name': name,
    'lat': lat,
    'lon': lon,
    'mode': 'both',
    'active': true,
    'displayPriority': priority,
  },
);

final GateCatalogue _catalogue = (
  places: [
    (
      id: _mitsuiId,
      values: <String, dynamic>{'name': _mitsuiName, 'lat': 2.780405, 'lon': 101.67736, 'gateRequired': true},
    ),
    (
      id: _kliaId,
      values: <String, dynamic>{'name': 'KLIA', 'partOf': 'KLIA', 'partOrder': 1, 'placeType': 'airport'},
    ),
    (id: _erlId, values: <String, dynamic>{'name': 'KLIA T2 (ERL)', 'lat': 2.742, 'lon': 101.686, 'partOf': ' klia '}),
  ],
  gates: [
    for (final d in _doors) _gateRow(d.$1, _mitsuiId, d.$2, d.$3, d.$4, d.$5, 'multi-gate-places'),
    // KLIA's own four doors, at the terminals kilometres away.
    for (var i = 1; i <= 4; i++)
      _gateRow('k$i', _kliaId, 'Door $i', 2.7456 + i * 0.0003, 101.7072, i, 'airport-areas'),
    _gateRow('erl1', _erlId, 'ERL Arrival', 2.7421, 101.6861, 1, 'multi-gate-places'),
  ],
);

final List<AirportDoor> _allDoors = [for (final g in _catalogue.gates) AirportDoor.fromGate(g.id, g.values)];

final _areas = [_klia, _mitsui, _erl];

/// [mode] with the catalogue's "Part of"s, as areaPrecedenceRuleProvider makes it.
AreaPrecedenceRule _rule(AreaPrecedence mode) => AreaPrecedenceRule(
  mode: mode,
  partOf: {
    for (final p in _catalogue.places)
      if (partOfKey(p.values['partOf']) case final k when k.isNotEmpty) p.id: k,
  },
);

LatLng _at(String id) {
  final d = _doors.firstWhere((d) => d.$1 == id);
  return LatLng(d.$3, d.$4);
}

class _Here implements LocationSource {
  const _Here(this.at);
  final LatLng at;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async => LocationPermission.whileInUse;
  @override
  Future<LocationPermission> requestPermission() async => LocationPermission.whileInUse;
  @override
  Future<LatLng?> lastKnown() async => at;
  @override
  Future<LatLng> current(LocationAccuracy accuracy) async => at;
}

class _Rides implements RideRepository {
  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];
  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => false;
  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => RegionPricing.none;
  @override
  Future<String?> publicIp() async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

/// The home screen with the rider standing at [here], inside the mall.
Future<void> _home(
  WidgetTester tester,
  LatLng here,
  Brightness brightness, {
  AreaPrecedence mode = AreaPrecedence.partOf,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(_Rides()),
      routeEstimateRepositoryProvider.overrideWithValue(_NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
      recentPlacesProvider.overrideWith((ref) async => const <Place>[]),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      promoRepositoryProvider.overrideWithValue(PromoRepository(null)),
      locationSourceProvider.overrideWithValue(_Here(here)),
      placeGatesProvider.overrideWith((ref) async => _catalogue),
      airportAreasProvider.overrideWith((ref) async => areasByPrecedence(_areas)),
      areaPrecedenceProvider.overrideWith((ref) async => mode),
      airportSettingsProvider.overrideWith(
        (ref) async => {_mitsuiId: const AirportSettings.place(_mitsuiId).copyWith(pickDoorRequired: true)},
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: appTheme(brightness), routerConfig: router),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The home map's camera.
MapCamera _homeCamera(WidgetTester tester) => tester
    .widget<FlutterMap>(
      find.descendant(of: find.byType(MapDragPin), matching: find.byType(FlutterMap)).first,
    )
    .mapController!
    .camera;

/// The door sheet's map camera.
MapCamera _sheetCamera(WidgetTester tester) =>
    tester.widget<FlutterMap>(find.byKey(const ValueKey('gate-picker-map'))).mapController!.camera;

/// The home pickup, as the drag pin has it.
LatLng? _pickup(WidgetTester tester) => tester.widget<MapDragPin>(find.byType(MapDragPin)).pin;

double _m(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b);

String _callout(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byKey(const ValueKey('gate-callout')), matching: find.byType(Text)))
    .map((t) => t.data)
    .join(' / ');

void main() {
  group('places inside an airport (0266)', () {
    const inMitsui = LatLng(2.7794, 101.6769), inErl = LatLng(2.7421, 101.6862), inKlia = LatLng(2.75, 101.70);
    String? at(AreaPrecedence mode, LatLng p) => gateAreaAt(_areas, p, rule: _rule(mode))?.id;

    test('Part of (the default): Mitsui is its own; the ERL, part of KLIA, is KLIA\'s', () {
      expect(AreaPrecedence.of(null), AreaPrecedence.partOf);
      expect(AreaPrecedence.of('nonsense'), AreaPrecedence.partOf);
      expect(at(AreaPrecedence.partOf, inMitsui), _mitsuiId);
      expect(at(AreaPrecedence.partOf, inErl), _kliaId);
      expect(gateAreaAt(_areas, inMitsui)?.id, _mitsuiId, reason: 'the default rule');
      expect(gateAreaAt(_areas, inErl)?.id, _erlId, reason: 'without the Part ofs read, a place is its own');
    });

    test('Always the place: both are their own', () {
      expect(at(AreaPrecedence.place, inMitsui), _mitsuiId);
      expect(at(AreaPrecedence.place, inErl), _erlId);
    });

    test('Always the airport: both are KLIA\'s', () {
      expect(at(AreaPrecedence.airport, inMitsui), _kliaId);
      expect(at(AreaPrecedence.airport, inErl), _kliaId);
    });

    test('outside every place: KLIA in every mode; outside KLIA: nothing', () {
      for (final m in AreaPrecedence.values) {
        expect(at(m, inKlia), _kliaId, reason: m.key);
        expect(at(m, const LatLng(3.1, 101.6)), isNull, reason: m.key);
      }
    });

    test('a pin in the mall snaps to the mall\'s nearest door, all five listed', () {
      final snap = snapToGate(areas: _areas, doors: _allDoors, p: inMitsui, rule: _rule(AreaPrecedence.partOf))!;
      expect(snap.area.name, _mitsuiName);
      expect(snap.gates.map((g) => g.name), [for (final d in _doors) d.$2], reason: 'all five, in priority order');
      expect(snap.door.id, 'e3');
      // A single-door mall: that door.
      final one = snapToGate(areas: _areas, doors: [_allDoors.first], p: const LatLng(2.7785, 101.6762))!;
      expect(one.door.id, 'e1');
      // Always the airport: KLIA's nearest door.
      final klia = snapToGate(areas: _areas, doors: _allDoors, p: inMitsui, rule: _rule(AreaPrecedence.airport))!;
      expect(klia.area.id, _kliaId);
      expect(klia.door.id, startsWith('k'));
      // The ERL under Part of: KLIA's doors; under Always the place, its own.
      expect(snapToGate(areas: _areas, doors: _allDoors, p: inErl, rule: _rule(AreaPrecedence.partOf))!.door.id,
          startsWith('k'));
      expect(snapToGate(areas: _areas, doors: _allDoors, p: inErl, rule: _rule(AreaPrecedence.place))!.door.id, 'erl1');
    });
  });

  test('the gates are read a page at a time, past the first 1,000 rows', () async {
    final rows = [
      for (var i = 0; i < 1003; i++)
        {'id': 'g$i', 'kind': 'gate', 'position': 0, 'values': {'placeId': 'p', 'name': 'Door $i'}},
    ];
    final asked = <String>[];
    final db = SupabaseClient(
      'http://localhost',
      'anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/rest/v1/multi_gate')) {
          final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
          final limit = int.parse(req.url.queryParameters['limit'] ?? '1000');
          asked.add('$offset+$limit');
          // The API's own cap: never more than 1,000 rows an answer.
          final page = rows.skip(offset).take(limit.clamp(0, 1000)).toList();
          return http.Response(jsonEncode(page), 200, headers: {'content-type': 'application/json'}, request: req);
        }
        return http.Response('[]', 200, headers: {'content-type': 'application/json'}, request: req);
      }),
    );
    final container = ProviderContainer(
      overrides: [supabaseProvider.overrideWithValue(db), liveTablesProvider.overrideWith(_QuietLive.new)],
    );
    addTearDown(container.dispose);
    final catalogue = await container.read(placeGatesProvider.future);
    expect(catalogue.gates.length, 1003);
    expect(asked, ['0+1000', '1000+1000']);
  });

  test('the places\' own values for the areas are read a page at a time too', () async {
    final places = [
      for (var i = 0; i < 1002; i++)
        {'id': 'p$i', 'values': {'name': 'Place $i', 'groupResults': i == 1001}},
    ];
    final asked = <String>[];
    final db = SupabaseClient(
      'http://localhost',
      'anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((req) async {
        final json = {'content-type': 'application/json'};
        if (req.url.path.endsWith('/rest/v1/multi_gate')) {
          final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
          final limit = int.parse(req.url.queryParameters['limit'] ?? '1000');
          asked.add('$offset+$limit');
          final page = places.skip(offset).take(limit.clamp(0, 1000)).toList();
          return http.Response(jsonEncode(page), 200, headers: json, request: req);
        }
        if (req.url.path.endsWith('/rest/v1/airport_areas')) {
          return http.Response(
            jsonEncode([
              {
                'id': 'p1001',
                'kind': 'place',
                'active': true,
                'size_m2': 1e5,
                'shape': jsonDecode(_box(3.1, 3.0, 101.1, 101.0)),
                'values': {'name': 'Place 1001'},
              },
            ]),
            200,
            headers: json,
            request: req,
          );
        }
        return http.Response('[]', 200, headers: json, request: req);
      }),
    );
    final container = ProviderContainer(
      overrides: [supabaseProvider.overrideWithValue(db), liveTablesProvider.overrideWith(_QuietLive.new)],
    );
    addTearDown(container.dispose);
    final areas = await container.read(airportAreasProvider.future);
    expect(areas.single.groupResults, isTrue, reason: 'the place past the first 1,000 rows');
    expect(asked, ['0+1000', '1000+1000']);
  });

  for (final b in Brightness.values) {
    testWidgets('${b.name}: a pin dropped in the mall runs to its nearest door; the sheet lists all five', (
      tester,
    ) async {
      // Standing by Entrance 3: the pickup starts on it.
      await _home(tester, const LatLng(2.7795, 101.6769), b);
      expect(_pickup(tester), _at('e3'));
      expect(_callout(tester), contains('Entrance 3 (Lebuh Madani)'));
      // The mall's five doors are drawn, not KLIA's.
      for (final d in _doors) {
        expect(find.byKey(ValueKey('gate-dot-${d.$1}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('gate-dot-k1')), findsNothing);

      // Drag the map down a little: the pin is dropped further north in the
      // mall, between doors.
      final g = await tester.startGesture(const Offset(200, 250));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      final shadow = find.byKey(const ValueKey('drag-pin-shadow'));
      expect(shadow, findsOneWidget);
      final mapBox = tester.getRect(find.byType(MapDragPin));
      final focus = tester.getCenter(shadow) - mapBox.topLeft;
      final dropped = _homeCamera(tester).screenOffsetToLatLng(focus);
      expect(_mitsui.contains(dropped, bufferM: 0), isTrue, reason: 'dropped inside the mall');
      final nearest = nearestGate([for (final d in _allDoors) if (d.airportId == _mitsuiId) d], dropped)!;
      expect(_m(dropped, doorPoint(nearest)!), greaterThan(20), reason: 'not on a door');

      // It lands, then the map glides under the lifted pin to the door: the
      // camera passes through the points between.
      final seen = <LatLng>[];
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        seen.add(_homeCamera(tester).screenOffsetToLatLng(focus));
      }
      final between = seen.where((c) => _m(c, dropped) > 5 && _m(c, doorPoint(nearest)!) > 5);
      expect(between, isNotEmpty, reason: 'animated, not a jump');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // On the door: the pickup, the point under the pin, the callout.
      expect(_pickup(tester), doorPoint(nearest));
      expect(_m(_homeCamera(tester).screenOffsetToLatLng(focus), doorPoint(nearest)!), lessThan(1));
      expect(_callout(tester), contains(nearest.name));
      expect(find.byKey(const ValueKey('drag-pin')), findsNothing, reason: 'dropped again');

      // The door sheet: the mall, all five doors, opening on the chosen one.
      await tester.tap(find.byKey(const ValueKey('gate-callout')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.widget<Text>(find.byKey(const ValueKey('gate-picker-title'))).data, _mitsuiName);
      final sheetMap = find.byKey(const ValueKey('gate-picker-map'));
      // (Dots off the sheet's small map aren't built; the wheel has them all.)
      expect(find.descendant(of: sheetMap, matching: find.byKey(ValueKey('gate-dot-${nearest.id}'))), findsOneWidget);
      final wheel = tester.widget<ListWheelScrollView>(
        find.descendant(of: find.byKey(const ValueKey('gate-picker-panel')), matching: find.byType(ListWheelScrollView)),
      );
      expect(wheel.childDelegate.estimatedChildCount, 5, reason: 'the five doors, no Any gate (required)');
      expect(_m(_sheetCamera(tester).center, doorPoint(nearest)!), lessThan(0.5), reason: 'the pin on the door');
      expect(
        find.descendant(of: find.byKey(const ValueKey('gate-picker-chip')), matching: find.text(nearest.name)),
        findsOneWidget,
      );

      // Another door tapped: the map flies there.
      await tester.tap(find.descendant(of: sheetMap, matching: find.byKey(const ValueKey('gate-dot-e5'))));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(_m(_sheetCamera(tester).center, _at('e5')), lessThan(0.5));
      await tester.tap(find.byKey(const ValueKey('gate-picker-done')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(_pickup(tester), _at('e5'));
      expect(_callout(tester), contains('Entrance 5 (Lebuh Madani)'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the door sheet opens centred on the chosen door and lists every door', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gates = [for (final d in _allDoors) if (d.airportId == _mitsuiId) d];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showGatePicker(
                  context,
                  placeName: _mitsuiName,
                  gates: gates,
                  rings: _mitsui.rings,
                  selectedId: 'e4',
                  required: true,
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
    expect(_m(_sheetCamera(tester).center, _at('e4')), lessThan(0.5));
    expect(
      tester.widget<ListWheelScrollView>(find.byType(ListWheelScrollView)).childDelegate.estimatedChildCount,
      5,
    );
    // The wheel turned a row: the next door, the map flown to it.
    await tester.drag(find.byKey(const ValueKey('gate-picker-gates-0')), const Offset(0, -46));
    await tester.pumpAndSettle();
    expect(_m(_sheetCamera(tester).center, _at('e5')), lessThan(0.5));
  });

  testWidgets('Always the airport: a pin in the mall goes to KLIA\'s nearest door, a drop runs there again', (
    tester,
  ) async {
    await _home(tester, const LatLng(2.7795, 101.6769), Brightness.light, mode: AreaPrecedence.airport);
    final k4 = _allDoors.firstWhere((d) => d.id == 'k4');
    expect(_pickup(tester), doorPoint(k4));
    expect(_callout(tester), contains('Door 4'));

    // Dragged a little off the door (still in KLIA): it runs back to it.
    final g = await tester.startGesture(const Offset(200, 250));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_pickup(tester), doorPoint(k4));
    expect(_callout(tester), contains('Door 4'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the ERL, part of KLIA: KLIA\'s door by default, its own with Always the place', (tester) async {
    const inErl = LatLng(2.7421, 101.6862);
    await _home(tester, inErl, Brightness.dark);
    expect(_callout(tester), contains('Door'));
    expect(_callout(tester), isNot(contains('ERL Arrival')));
    await tester.pumpWidget(const SizedBox());
    await _home(tester, inErl, Brightness.dark, mode: AreaPrecedence.place);
    expect(_pickup(tester), const LatLng(2.7421, 101.6861));
    expect(_callout(tester), contains('ERL Arrival'));
  });

  for (final b in Brightness.values) {
    testWidgets('${b.name}: Admin → Airport Areas card: three choices, the default marked, Save', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final saved = <Map<String, dynamic>>[];
      final db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/rest/v1/$areaPrecedenceTable') && req.method == 'PATCH') {
            saved.add(Map<String, dynamic>.from(jsonDecode(req.body) as Map));
            expect(req.url.queryParameters['id'], 'eq.1');
            return http.Response('', 204, request: req);
          }
          // No row read yet: the default.
          return http.Response('[]', 200, headers: {'content-type': 'application/json'}, request: req);
        }),
      );
      Future<void> pump(bool canEdit) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [supabaseProvider.overrideWithValue(db), liveTablesProvider.overrideWith(_QuietLive.new)],
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(body: SingleChildScrollView(child: AreaPrecedenceCard(canEdit: canEdit))),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump(true);
      expect(find.text('Places inside an airport'), findsOneWidget);
      for (final (mode, title, line) in areaPrecedenceChoices) {
        expect(find.byKey(ValueKey('area-precedence-${mode.key}')), findsOneWidget);
        expect(find.textContaining(title), findsOneWidget);
        expect(find.text(line), findsOneWidget);
      }
      expect(find.textContaining('DEFAULT', findRichText: true), findsOneWidget);
      RadioListTile<AreaPrecedence> tile(AreaPrecedence m) =>
          tester.widget(find.byKey(ValueKey('area-precedence-${m.key}')));
      expect(tile(AreaPrecedence.partOf).selected, isTrue, reason: 'the default when nothing is stored');
      final save = find.byKey(const ValueKey('area-precedence-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull, reason: 'nothing changed yet');

      await tester.tap(find.byKey(const ValueKey('area-precedence-place')));
      await tester.pumpAndSettle();
      expect(tile(AreaPrecedence.place).selected, isTrue);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved, [
        {'mode': 'place'},
      ]);
      expect(tester.takeException(), isNull);

      // Without edit rights: shown, not changed, no Save.
      await pump(false);
      expect(find.byKey(const ValueKey('area-precedence-save')), findsNothing);
      expect(find.byKey(const ValueKey('area-precedence-read-only')), findsOneWidget);
      expect(tile(AreaPrecedence.airport).enabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('area-precedence-airport')));
      await tester.pumpAndSettle();
      expect(tile(AreaPrecedence.airport).selected, isFalse);
      expect(saved.length, 1);
    });
  }
}
