// The pickup pin at a place with doors (0258, 0266), with the owner's
// Mitsui Outlet Park KLIA Sepang: five doors inside its boundary, which lies
// inside KLIA's own. A pin dropped inside the mall runs on to the mall's
// nearest door (not to an airport door), the door sheet lists all five and
// opens on the chosen one, and the gates are read past the API's 1,000-row
// page.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
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
    (id: _kliaId, values: <String, dynamic>{'name': 'KLIA', 'placeType': 'airport', 'placeTypeSet': true}),
  ],
  gates: [
    for (final d in _doors) _gateRow(d.$1, _mitsuiId, d.$2, d.$3, d.$4, d.$5, 'multi-gate-places'),
    // KLIA's own four doors, at the terminals kilometres away.
    for (var i = 1; i <= 4; i++)
      _gateRow('k$i', _kliaId, 'Door $i', 2.7456 + i * 0.0003, 101.7072, i, 'airport-areas'),
  ],
);

final List<AirportDoor> _allDoors = [for (final g in _catalogue.gates) AirportDoor.fromGate(g.id, g.values)];

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
Future<void> _home(WidgetTester tester, LatLng here, Brightness brightness) async {
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
      airportAreasProvider.overrideWith((ref) async => areasByPrecedence([_klia, _mitsui])),
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
  test('a pin in the mall snaps to the mall\'s nearest door, though KLIA holds the mall too', () {
    final areas = [_klia, _mitsui];
    // The mall comes first: the smallest place, then an airport (0266).
    expect(areasByPrecedence(areas).map((a) => a.id), [_mitsuiId, _kliaId]);
    expect(gateAreaAt(areas, const LatLng(2.780405, 101.67736))?.id, _mitsuiId);
    final snap = snapToGate(areas: areas, doors: _allDoors, p: const LatLng(2.7794, 101.6769))!;
    expect(snap.area.name, _mitsuiName);
    expect(snap.gates.map((g) => g.name), [for (final d in _doors) d.$2], reason: 'all five, in priority order');
    expect(snap.door.id, 'e3');
    // A single-door mall: that door.
    final one = snapToGate(areas: areas, doors: [_allDoors.first], p: const LatLng(2.7785, 101.6762))!;
    expect(one.door.id, 'e1');
    // KLIA outside the mall is still KLIA's.
    expect(snapToGate(areas: areas, doors: _allDoors, p: const LatLng(2.75, 101.70))!.door.id, startsWith('k'));
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
}
