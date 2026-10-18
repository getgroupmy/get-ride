// Performance probe: rebuilds on the driver's trip screen per GPS fix and
// per second of the trip clock.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_charges.dart';
import 'package:get_ride/src/core/trip_checkpoint.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart' show rideStreamProvider;
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

const pickup = LatLng(3.1579, 101.7116);
const drop = LatLng(3.1340, 101.6860);
final t0 = DateTime(2026, 10, 6, 10, 30);

RideRequest ride(String status) => RideRequest({
  'id': 'r1', 'rider_id': 'rider', 'partner_id': 'me', 'status': status, 'fare': 20, 'currency': 'MYR',
  'pickup_name': 'KLCC', 'drop_name': 'KL Sentral', 'pickup_lat': pickup.latitude, 'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude, 'drop_lng': drop.longitude, 'started_at': t0.toUtc().toIso8601String(),
});

class _FakeRides implements RideRepository {
  int published = 0;
  @override
  Future<bool> recordCheckpoint(String id, TripCheckpoint checkpoint, double? lat, double? lng) async => true;
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async => published++;
  @override
  Future<void> complete(RideRequest r, {TripCharges charges = TripCharges.none, double? earlyFare}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async =>
      RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
}

void main() {
  testWidgets('trip screen rebuild counts', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var now = t0;
    final rides = _FakeRides();
    final rows = StreamController<RideRequest>.broadcast();
    final fixes = StreamController<TripFix>.broadcast();
    addTearDown(rows.close);
    addTearDown(fixes.close);
    var total = 0;
    final counts = <String, int>{};
    void reset() { total = 0; counts.clear(); }
    String top() => (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(8).map((e) => '${e.key}=${e.value}').join(', ');
    debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
      total++;
      final k = e.widget.runtimeType.toString();
      counts[k] = (counts[k] ?? 0) + 1;
    };
    final router = GoRouter(initialLocation: '/trip', routes: [
      GoRoute(path: '/drive', builder: (_, _) => const Scaffold(body: Text('requests'))),
      GoRoute(path: '/trip', builder: (_, _) => const PartnerTripScreen(requestId: 'r1')),
      GoRoute(path: '/trips/:id', builder: (_, st) => const Scaffold(body: Text('receipt'))),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rideRepositoryProvider.overrideWithValue(rides),
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
    ));
    rows.add(ride('on_trip'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    reset();
    // 5 s of the trip clock with no fixes.
    for (var i = 0; i < 50; i++) {
      now = now.add(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final clockOnly = total;
    final clockTop = top();
    reset();
    // 5 fixes 15 m apart, one per second (distanceFilter 15 m while driving).
    for (var i = 1; i <= 5; i++) {
      fixes.add((at: LatLng(pickup.latitude - i * 0.000135, pickup.longitude), heading: 180, accuracy: 5));
      for (var j = 0; j < 10; j++) {
        now = now.add(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final fiveFixes = total;
    final fixTop = top();
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('PROBE trip: 5s clock only -> rebuilds=$clockOnly top: $clockTop');
    // ignore: avoid_print
    print('PROBE trip: 5 fixes + 5s clock -> rebuilds=$fiveFixes published=${rides.published} top: $fixTop');
  });
}
