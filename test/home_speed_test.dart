// The home screen does not wait on slow things before it shows something:
// the pickup on the last known fix (PERF-4), and the standard tariff's fare
// before the AI's (PERF-33).
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
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show ConfirmServiceCard;
import 'package:get_ride/src/core/format.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/busy.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _last = LatLng(3.1000, 101.6000);
const _fine = LatLng(3.1030, 101.6040);

class _Rides implements RideRepository {
  Map<Symbol, dynamic>? created;

  /// While set, a booking waits here (its bidding check) after the tap.
  Completer<void>? hold;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async {
    await hold?.future;
    return false;
  }

  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => RegionPricing.none;

  @override
  Future<String?> publicIp() async => null;

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #createRequest) {
      created = i.namedArguments;
      final ride = RideRequest({'id': 'r9', 'rider_id': 'me', 'status': 'open', 'fare': 10});
      return Future<Booked>.value((now: ride, later: null));
    }
    return super.noSuchMethod(i);
  }
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// The AI estimate, held until [answer] completes.
class _SlowAi implements RouteEstimateRepository {
  final answer = Completer<({RouteEstimate? estimate, bool unavailable})?>();

  @override
  Future<({RouteEstimate? estimate, bool unavailable})?> estimateDetailed(
    LatLng from,
    LatLng to, {
    List<LatLng> via = const [],
  }) => answer.future;

  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

/// Far longer than the straight line: a fare that would show if swapped in.
const _aiEstimate = (estimate: RouteEstimate(distanceKm: 60, durationMin: 120), unavailable: false);

const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(3.1580, 101.7120));

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

Future<void> _pump(
  WidgetTester tester,
  LocationSource phone, {
  _Rides? rides,
  RouteEstimateRepository? ai,
  List<Place> recent = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      locationSourceProvider.overrideWithValue(phone),
      rideRepositoryProvider.overrideWithValue(rides ?? _Rides()),
      routeEstimateRepositoryProvider.overrideWithValue(ai ?? _NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
      recentPlacesProvider.overrideWith((ref) async => recent),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/ride/:id', builder: (_, s) => Text('ride ${s.pathParameters['id']}')),
    ],
  );
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

/// Home on a phone already located, then KLCC picked from the recent list.
Future<void> _toConfirm(WidgetTester tester, {required _Rides rides, required RouteEstimateRepository ai}) async {
  final phone = _Phone(last: _last)..fine.complete(_last);
  await _pump(tester, phone, rides: rides, ai: ai, recent: const [_klcc]);
  await _settle(tester);
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
  await _settle(tester);
  await tester.tap(find.text('KLCC').first);
  await _settle(tester);
  await _settle(tester);
}

/// The chosen vehicle's fare as the rider sees it.
String _shownFare(WidgetTester tester) => tester.widget<ConfirmServiceCard>(find.byType(ConfirmServiceCard)).price;

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

  testWidgets('the tariff fare shows and can be booked at once; the AI fare and its mark replace it', (tester) async {
    final ai = _SlowAi();
    await _toConfirm(tester, rides: _Rides(), ai: ai);
    // The AI has not answered: no "Calculating fare", the tariff's fare, no AI mark.
    expect(find.byKey(const ValueKey('calculating-fare')), findsNothing);
    expect(find.byKey(const ValueKey('route-ai')), findsNothing);
    expect(tester.widget<BusyButton>(find.byKey(const ValueKey('book'))).onPressed, isNotNull);
    final tariff = _shownFare(tester);
    ai.answer.complete(_aiEstimate);
    await _settle(tester);
    expect(find.byKey(const ValueKey('route-ai')), findsOneWidget);
    expect(_shownFare(tester), isNot(tariff));
  });

  testWidgets('an AI fare that comes after the tap does not change what is booked', (tester) async {
    final ai = _SlowAi();
    final rides = _Rides();
    await _toConfirm(tester, rides: rides, ai: ai);
    final shown = _shownFare(tester);
    rides.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('book')));
    await tester.pump();
    ai.answer.complete(_aiEstimate); // lands while the booking is under way
    await tester.pump();
    rides.hold!.complete();
    await _settle(tester);
    expect(rides.created, isNotNull);
    expect(formatMoney(rides.created![#fare] as double, rides.created![#currency] as String), shown);
    expect(find.text('ride r9'), findsOneWidget);
  });

  test('the AI estimate is waited for 5 s at most, not 30', () {
    expect(aiEstimateTimeout, const Duration(seconds: 5));
  });
}
