// How much of the map a GPS fix rebuilds (PERF-57/58/59/64): the base tiles
// stay as they are unless the camera itself moves, and a car standing still
// with GPS jitter leaves the map alone.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/live_ride_map.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pickup = LatLng(3.1579, 101.7116);
const drop = LatLng(3.1340, 101.6860);
final t0 = DateTime(2026, 10, 6, 10, 30);

RideRequest ride(String status, {Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'me',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': pickup.latitude,
  'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude,
  'drop_lng': drop.longitude,
  ...extra,
});

class _FakeRides implements RideRepository {
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async =>
      RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
}

/// Element rebuilds while [body] runs: all of them, and the map's tiles.
class Probe {
  int all = 0, tiles = 0, tileLayers = 0, flutterMaps = 0;

  Future<void> run(Future<void> Function() body) async {
    debugOnRebuildDirtyWidget = (e, _) {
      all++;
      final w = e.widget;
      if (w.runtimeType.toString() == 'Tile') tiles++;
      if (w is TileLayer) tileLayers++;
      if (w is FlutterMap) flutterMaps++;
    };
    try {
      await body();
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
  }

  @override
  String toString() => 'all $all, Tile $tiles, TileLayer $tileLayers, FlutterMap $flutterMaps';
}

/// A second of frames at 20 a second (the camera's glide included).
Future<void> second(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() => debugOnRebuildDirtyWidget = null);

  test('jitter is not a move; driving, turning and a first fix are', () {
    const at = LatLng(3.15, 101.70);
    const s = Duration(seconds: 1);
    expect(carMovedOnMap(from: null, to: at), isTrue);
    expect(carMovedOnMap(from: at, to: const LatLng(3.1500027, 101.70), headingFrom: 90, headingTo: 91.5, elapsed: s), isFalse);
    expect(carMovedOnMap(from: at, to: const LatLng(3.1501, 101.70), headingFrom: 90, headingTo: 90, elapsed: s), isTrue);
    expect(carMovedOnMap(from: at, to: at, headingFrom: 90, headingTo: 100, elapsed: s), isTrue, reason: 'turning');
    expect(carMovedOnMap(from: at, to: at, headingFrom: 358, headingTo: 2, elapsed: s), isFalse, reason: 'the short way');
    // ~5.5 m drift over 10 s on a fix good to 10 m: still standing.
    expect(
      carMovedOnMap(from: at, to: const LatLng(3.15005, 101.70), elapsed: const Duration(seconds: 10), accuracy: 10),
      isFalse,
    );
    expect(
      carMovedOnMap(from: at, to: const LatLng(3.15005, 101.70), elapsed: const Duration(seconds: 10), accuracy: 3),
      isTrue,
    );
  });

  group('driver trip screen', () {
    late StreamController<RideRequest> rows;
    late StreamController<TripFix> fixes;
    late DateTime now;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      now = t0;
      rows = StreamController<RideRequest>();
      fixes = StreamController<TripFix>();
      addTearDown(rows.close);
      addTearDown(fixes.close);
      final router = GoRouter(
        initialLocation: '/trip',
        routes: [
          GoRoute(path: '/drive', builder: (_, _) => const Scaffold(body: Text('requests'))),
          GoRoute(path: '/trip', builder: (_, _) => const PartnerTripScreen(requestId: 'r1')),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            tripPositionStreamProvider.overrideWithValue(() => fixes.stream),
            tripClockProvider.overrideWithValue(() => now),
            tripFixProvider.overrideWithValue(() async => null),
            geoServiceProvider.overrideWithValue(_Geo()),
            currentUserIdProvider.overrideWithValue(null),
            fareTariffsProvider.overrideWith((ref) async => const []),
            rideServicesProvider.overrideWith((ref) async => const []),
            serviceBoxNamesProvider.overrideWith((ref) async => const {}),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      rows.add(ride('on_trip'));
      await tester.pump();
      await tester.pump();
    }

    Future<void> fix(WidgetTester tester, LatLng at, double heading) async {
      now = now.add(const Duration(seconds: 1));
      fixes.add((at: at, heading: heading, accuracy: 5));
      await second(tester);
    }

    testWidgets('driving: 5 fixes, 1 a second', (tester) async {
      await pump(tester);
      await fix(tester, pickup, 200);
      await second(tester);
      await second(tester);
      final p = Probe();
      await p.run(() async {
        for (var i = 1; i <= 5; i++) {
          // ~11 m a second (40 km/h), south.
          await fix(tester, LatLng(pickup.latitude - i * 0.0001, pickup.longitude), 180);
        }
      });
      debugPrint('PROBE trip driving: $p');
      expect(p.flutterMaps, 0, reason: 'the map widget itself is built once');
      expect(p.tiles, greaterThan(0), reason: 'the camera still follows the car');
      expect(p.tileLayers, lessThanOrEqualTo(100), reason: 'once a frame of the glide at most, not once a layer');
      expect(find.byKey(const ValueKey('driver-heading')), findsOneWidget);
    });

    testWidgets('following paused: fixes move the car, not the tiles', (tester) async {
      await pump(tester);
      await fix(tester, pickup, 200);
      await second(tester);
      // A hand on the map stops the following.
      await tester.drag(find.byType(FlutterMap), const Offset(0, 60));
      await second(tester);
      final p = Probe();
      await p.run(() async {
        for (var i = 1; i <= 5; i++) {
          await fix(tester, LatLng(pickup.latitude - i * 0.0001, pickup.longitude), 180);
        }
      });
      debugPrint('PROBE trip paused: $p');
      expect(p.tiles, 0);
      expect(p.tileLayers, 0);
      expect(p.flutterMaps, 0);
    });

    testWidgets('standing still: GPS jitter leaves the map alone (PERF-64)', (tester) async {
      await pump(tester);
      await fix(tester, pickup, 200);
      await second(tester);
      await second(tester);
      final p = Probe();
      await p.run(() async {
        for (var i = 1; i <= 5; i++) {
          // ~0.3 m back and forth, the heading ±1.5°.
          await fix(
            tester,
            LatLng(pickup.latitude + (i.isOdd ? 0.0000027 : 0), pickup.longitude),
            200 + (i.isOdd ? 1.5 : -1.5),
          );
        }
      });
      debugPrint('PROBE trip standing: $p');
      expect(p.tiles, 0);
      expect(p.all, lessThan(30));
      expect(find.text('0.0 km driven'), findsOneWidget);
    });
  });

  group('Drive screen', () {
    late StreamController<LatLng> fixes;

    Future<void> pump(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1600);
      addTearDown(tester.view.reset);
      fixes = StreamController<LatLng>.broadcast();
      addTearDown(fixes.close);
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => const Stream.empty()),
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            driverPositionProvider.overrideWithValue(() async => pickup),
            driverPositionStreamProvider.overrideWithValue(() => fixes.stream),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('driving: 5 fixes, 1 a second', (tester) async {
      await pump(tester);
      final p = Probe();
      await p.run(() async {
        for (var i = 1; i <= 5; i++) {
          fixes.add(LatLng(pickup.latitude - i * 0.0001, pickup.longitude));
          await second(tester);
        }
      });
      debugPrint('PROBE drive driving: $p');
      expect(p.flutterMaps, 0, reason: 'the map widget itself is built once');
      expect(p.tiles, greaterThan(0), reason: 'the camera still follows the driver');
      expect(p.tileLayers, lessThanOrEqualTo(100), reason: 'once a frame of the glide at most, not once a layer');
    });
  });

  group('rider tracking screen', () {
    late StreamController<RideRequest> rows;

    RideRequest moving(double lat) => ride('accepted', extra: {
      'partner_id': '22222222-2222-2222-2222-222222222222',
      'partner_name': 'Ali',
      'partner_live_lat': lat,
      'partner_live_lng': 101.7116,
      'updated_at': '2026-10-18T10:00:${(lat * 10000).round() % 60}Z',
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
            geoServiceProvider.overrideWithValue(_Geo()),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      rows.add(moving(3.170));
      await tester.pump();
      await second(tester);
      await second(tester);
    }

    testWidgets('one driver position update', (tester) async {
      await pump(tester);
      final p = Probe();
      await p.run(() async {
        rows.add(moving(3.1701));
        await tester.pump();
        await second(tester);
      });
      debugPrint('PROBE tracking update: $p');
      expect(p.flutterMaps, 0, reason: 'the map widget itself is built once');
      expect(p.tileLayers, lessThanOrEqualTo(21), reason: 'once a frame of the glide onto the car, no more');
      expect(find.byType(LiveRideMap), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a car standing still: GPS jitter does not glide the camera (PERF-64)', (tester) async {
      await pump(tester);
      final p = Probe();
      await p.run(() async {
        // ~0.3 m.
        rows.add(moving(3.1700027));
        await tester.pump();
        await second(tester);
      });
      debugPrint('PROBE tracking jitter: $p');
      expect(p.tiles, 0);
      expect(p.tileLayers, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
