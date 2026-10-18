// Performance probe: rebuilds on the Drive screen per GPS fix
// and per second of the request alert.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const here = LatLng(3.1579, 101.7123);

class _FakeRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _req(String id, double lat, {double fare = 12}) => RideRequest({
  'id': id, 'status': 'open', 'service': 'Teksi', 'fare': fare, 'currency': 'MYR', 'distance_km': 5,
  'passengers': 1, 'payment_mode': 'Cash', 'pickup_name': 'From $id', 'drop_name': 'To $id',
  'pickup_lat': lat, 'pickup_lng': 101.7123, 'drop_lat': 3.10, 'drop_lng': 101.72,
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

void main() {
  testWidgets('drive screen rebuild counts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1600);
    addTearDown(tester.view.reset);
    final open = StreamController<List<RideRequest>>.broadcast();
    final fixes = StreamController<LatLng>.broadcast();
    addTearDown(open.close);
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
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
        openRequestsProvider.overrideWith((ref) => open.stream),
        rideRepositoryProvider.overrideWithValue(_FakeRides()),
        driverPositionProvider.overrideWithValue(() async => here),
        driverPositionStreamProvider.overrideWithValue(() => fixes.stream),
        profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
        assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
        partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
        partnerTypeEntriesProvider.overrideWith((ref) async => [(id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false})]),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    open.add([_req('near', 3.1583)]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('You are offline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    reset();
    // Five GPS fixes 5 m apart, one per second, as a moving driver produces.
    for (var i = 1; i <= 5; i++) {
      fixes.add(LatLng(here.latitude + i * 0.000045, here.longitude));
      for (var j = 0; j < 10; j++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final fiveFixes = total;
    final fixTop = top();
    reset();
    // Idle online for 5 s with no fixes (alert tick only, if a request is spotlighted).
    for (var j = 0; j < 50; j++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final idle = total;
    final idleTop = top();
    reset();
    // A new request arrives (spotlight), then 5 s of its countdown.
    open.add([_req('near', 3.1583), _req('new1', 3.1586, fare: 20)]);
    for (var j = 0; j < 50; j++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final alert = total;
    final alertTop = top();
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('PROBE drive: 5 fixes in 5s -> rebuilds=$fiveFixes top: $fixTop');
    // ignore: avoid_print
    print('PROBE drive: idle online 5s -> rebuilds=$idle top: $idleTop');
    // ignore: avoid_print
    print('PROBE drive: new request + 5s countdown -> rebuilds=$alert top: $alertTop');
  });
}
