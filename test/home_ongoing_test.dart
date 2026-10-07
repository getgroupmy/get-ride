// The home screen's "ride in progress" card follows its ride, however the
// rider came back to the home screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

RideRequest _ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'status': status,
  'pickup_name': 'Eco Majestic',
  'drop_name': 'KLCC',
  'fare': 78.3,
  'currency': 'MYR',
});

class _FakeRides implements RideRepository {
  _FakeRides([this.rides]);
  final List<RideRequest>? rides;

  @override
  Future<RideRequest?> ongoingForRider() async => _ride('open');

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => rides ?? [_ride('open')];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('a ride cancelled elsewhere leaves the home screen; one that moves on shows its new status', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rows = StreamController<RideRequest>.broadcast();
    addTearDown(rows.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides()),
          rideStreamProvider.overrideWith((ref, id) => rows.stream),
          geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
          coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
          serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
          rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
          recentPlacesProvider.overrideWith((ref) async => const []),
          displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
          appDisplayProvider.overrideWith((ref) => Future.error('offline')),
          fareTariffsProvider.overrideWith((ref) async => const []),
          meterLaunchSessionProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('Finding a driver'), findsOneWidget);

    rows.add(_ride('accepted'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Driver on the way'), findsOneWidget);
    expect(find.text('Finding a driver'), findsNothing);

    rows.add(_ride('cancelled'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Driver on the way'), findsNothing);
    expect(find.text('Cancelled'), findsNothing, reason: 'a finished ride is not shown as in progress');
    expect(find.textContaining('Eco Majestic → KLCC'), findsNothing);
  });

  testWidgets('a ride booked for someone else leaves the home screen when it is cancelled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rows = StreamController<RideRequest>.broadcast();
    addTearDown(rows.close);
    RideRequest forMak(String status) =>
        RideRequest({..._ride(status).raw, 'id': 'r2', 'booked_for_name': 'Mak', 'booked_for_phone': '+60123456789'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_FakeRides([forMak('open')])),
          rideStreamProvider.overrideWith((ref, id) => rows.stream.where((r) => r.id == id)),
          geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
          coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
          serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
          rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
          recentPlacesProvider.overrideWith((ref) async => const []),
          displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
          appDisplayProvider.overrideWith((ref) => Future.error('offline')),
          fareTariffsProvider.overrideWith((ref) async => const []),
          meterLaunchSessionProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('For Mak · Finding a driver'), findsOneWidget);
    rows.add(forMak('accepted'));
    await tester.pump();
    await tester.pump();
    expect(find.text('For Mak · Driver on the way'), findsOneWidget);
    rows.add(forMak('cancelled'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('For Mak'), findsNothing);
  });
}
