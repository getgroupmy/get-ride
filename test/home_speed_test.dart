// The home screen does not wait on slow things before it shows something:
// the pickup on the last known fix (PERF-4).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/location_source.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _last = LatLng(3.1000, 101.6000);
const _fine = LatLng(3.1030, 101.6040);

class _Rides implements RideRepository {
  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => false;

  @override
  Future<String?> publicIp() async => null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// A phone with a last known fix whose accurate fix comes when the test says.
class _Phone implements LocationSource {
  _Phone({this.last, this.on = true});
  final LatLng? last;
  final bool on;
  final fine = Completer<LatLng>();

  @override
  Future<bool> serviceEnabled() async => on;
  @override
  Future<LocationPermission> checkPermission() async => LocationPermission.whileInUse;
  @override
  Future<LocationPermission> requestPermission() async => LocationPermission.whileInUse;
  @override
  Future<LatLng?> lastKnown() async => last;
  @override
  Future<LatLng> current(LocationAccuracy accuracy) =>
      accuracy == LocationAccuracy.high ? fine.future : Completer<LatLng>().future;
}

Future<void> _pump(WidgetTester tester, LocationSource phone) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      locationSourceProvider.overrideWithValue(phone),
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
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router)),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

RideMap _map(WidgetTester tester) => tester.widget<RideMap>(find.byType(RideMap));

void main() {
  testWidgets('the pickup shows on the last known fix, then moves onto the accurate one', (tester) async {
    final phone = _Phone(last: _last);
    await _pump(tester, phone);
    await _settle(tester);
    // No GPS fix yet: the map and the pickup are already on the phone.
    expect(_map(tester).me, _last);
    expect(_map(tester).pickup, _last);
    phone.fine.complete(_fine);
    await _settle(tester);
    expect(_map(tester).me, _fine);
    expect(_map(tester).pickup, _fine);
  });

  testWidgets('location off: no rider and no pickup, as before', (tester) async {
    await _pump(tester, _Phone(last: _last, on: false));
    await _settle(tester);
    expect(_map(tester).me, isNull);
    expect(_map(tester).pickup, isNull);
  });
}
