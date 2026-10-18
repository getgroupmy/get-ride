// Performance probe: counts widget rebuilds on the home
// screen when one live provider refreshes, as the 2-minute bump does.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRides implements RideRepository {
  @override
  Future<void> expireStaleOpen() async {}
  @override
  Future<RideRequest?> ongoingForRider() async => null;
  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Override> _overrides(Stream<RideRequest> rows) => [
  rideRepositoryProvider.overrideWithValue(_FakeRides()),
  rideStreamProvider.overrideWith((ref, id) => rows.where((r) => r.id == id)),
  geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
  coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
  serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
  rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4), RideService('Car', 'Car', 2, 4)]),
  recentPlacesProvider.overrideWith((ref) async => const []),
  displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
  appDisplayProvider.overrideWith((ref) => Future.error('offline')),
  fareTariffsProvider.overrideWith((ref) async => const []),
  meterLaunchSessionProvider.overrideWithValue(null),
];

final Uint8List _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  testWidgets('home screen rebuild counts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final rows = StreamController<RideRequest>.broadcast();
    final counts = <String, int>{};
    var total = 0;
    void reset() {
      counts.clear();
      total = 0;
    }

    debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
      total++;
      final k = e.widget.runtimeType.toString();
      counts[k] = (counts[k] ?? 0) + 1;
    };
    await tester.pumpWidget(
      ProviderScope(overrides: _overrides(rows.stream), child: const MaterialApp(home: HomeScreen())),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    final firstBuild = total;
    reset();
    // Idle: 5 s with nothing changing.
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final idle = total;
    final idleTop = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // ignore: avoid_print
    print('PROBE idle top: ${idleTop.take(14).map((e) => '${e.key}=${e.value}').join(', ')}');
    reset();
    // One live provider refresh, as the 2-minute bump does for ~20 of them.
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.invalidate(fareTariffsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final oneRefresh = total;
    final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    reset();
    container.invalidate(rideServicesProvider);
    container.invalidate(serviceBoxNamesProvider);
    container.invalidate(displaySettingsBlobProvider);
    container.invalidate(recentPlacesProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final fourRefresh = total;
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('PROBE first build=$firstBuild idle5s=$idle oneRefresh(fareTariffs)=$oneRefresh fourRefresh=$fourRefresh');
    // ignore: avoid_print
    print('PROBE top rebuilt on one refresh: ${top.take(12).map((e) => '${e.key}=${e.value}').join(', ')}');
    await rows.close();
  });
}
