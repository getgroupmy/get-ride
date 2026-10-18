// Performance probe: rebuilds per 5 s on the tracking screen
// while a request is open (1 s tick) and while a driver is en route.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRides implements RideRepository {
  int viewerCalls = 0;
  @override
  Future<RequestViewers> viewers(String requestId) async {
    viewerCalls++;
    return RequestViewers.none;
  }

  @override
  Future<void> expireStaleOpen() async {}
  @override
  Future<void> ackRideNotifications(String requestId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _row(String status, {double lat = 3.155}) => {
  'id': 'r1',
  'rider_id': 'me',
  'status': status,
  'created_at': DateTime.now().toUtc().toIso8601String(),
  'pickup_name': 'KLCC', 'pickup_lat': 3.1579, 'pickup_lng': 101.7116,
  'drop_name': 'KL Sentral', 'drop_lat': 3.1340, 'drop_lng': 101.6860,
  'fare': 18.5, 'currency': 'MYR', 'service': 'Teksi',
  'partner_name': 'Siti', 'partner_vehicle': 'Proton Saga', 'partner_plate': 'WXY 1',
  'partner_live_lat': lat, 'partner_live_lng': 101.71,
};

void main() {
  testWidgets('tracking screen rebuild counts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rides = _FakeRides();
    final rows = StreamController<RideRequest>.broadcast();
    addTearDown(rows.close);
    var total = 0;
    final counts = <String, int>{};
    debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
      total++;
      final k = e.widget.runtimeType.toString();
      counts[k] = (counts[k] ?? 0) + 1;
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rideRepositoryProvider.overrideWithValue(rides),
        rideStreamProvider.overrideWith((ref, id) => rows.stream),
        riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
        fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
        walletBalancesProvider.overrideWith((ref) async => const []),
        walletTxProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
    ));
    rows.add(RideRequest(_row('open')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    total = 0;
    counts.clear();
    rides.viewerCalls = 0;
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final openIdle = total;
    final openTop = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // ignore: avoid_print
    print('PROBE open 5s: rebuilds=$openIdle viewersRpc=${rides.viewerCalls} top: ${openTop.take(10).map((e) => '${e.key}=${e.value}').join(', ')}');
    // Driver en route: one live-position update every 5 s, as production sends.
    rows.add(RideRequest(_row('accepted')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    total = 0;
    counts.clear();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final acceptedIdle = total;
    total = 0;
    counts.clear();
    rows.add(RideRequest(_row('accepted', lat: 3.156)));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final onePosition = total;
    final posTop = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('PROBE accepted idle 5s: rebuilds=$acceptedIdle; one driver position update: rebuilds=$onePosition top: ${posTop.take(10).map((e) => '${e.key}=${e.value}').join(', ')}');
  });
}
