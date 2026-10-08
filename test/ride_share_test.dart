// A ride shared by link: the link, the message and the read-only page.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_share.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/ride/shared_ride_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = '0b5c6a52-3f0e-4c47-9a7e-3f1f2a1d9e10';

class _Geo extends GeoService {
  final routed = <(LatLng, LatLng, int)>[];

  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async {
    routed.add((from, to, via.length));
    return RouteInfo(distanceKm: 2, durationMin: 5, points: [from, ...via, to]);
  }
}

Map<String, dynamic> _view({String status = 'accepted', String? otp, bool forOthers = false, bool car = false}) => {
      'status': status,
      'service': 'Teksi',
      'passenger': forOthers ? 'Mak' : 'Ali',
      'booked_for_others': forOthers,
      'pickup_name': 'KLCC',
      'pickup_lat': 3.1579,
      'pickup_lng': 101.7116,
      'drop_name': 'KL Sentral',
      'drop_lat': 3.1340,
      'drop_lng': 101.6860,
      'stops': [
        {'name': 'Pavilion', 'lat': 3.149, 'lng': 101.713},
        {'name': 'broken'},
      ],
      'distance_km': 6.4,
      'duration_min': 14,
      'fare': 18.5,
      'currency': 'MYR',
      'partner_name': 'Siti',
      'partner_vehicle': 'Proton Saga',
      'partner_plate': 'WXY 1',
      'partner_rating': 4.8,
      'partner_live_lat': 3.155,
      'partner_live_lng': 101.71,
      'otp': otp,
      if (car) ...{'vehicle_make': 'Perodua', 'vehicle_model': 'Myvi', 'vehicle_color': 'white'},
    };

class _FakeRides implements RideRepository {
  _FakeRides({this.view});
  Map<String, dynamic>? view;
  final asked = <String>[];
  final shared = <String>[];

  @override
  Future<SharedRide?> sharedRide(String token) async {
    asked.add(token);
    return view == null ? null : SharedRide(view!);
  }

  @override
  Future<String> shareToken(String rideId) async {
    shared.add(rideId);
    return _token;
  }

  @override
  Future<void> publishRiderLocation(String id, double lat, double lng) async {}

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('rules', () {
    test('the link is the web app\'s share page; only a UUID is a token', () {
      expect(rideShareUrl(_token), 'https://getride.my/share/$_token');
      expect(isShareToken(_token), isTrue);
      expect(isShareToken('nope'), isFalse);
      expect(isShareToken("x' or 1=1"), isFalse);
    });

    test('the message says whose ride it is', () {
      final own = RideRequest({'id': 'r', 'drop_name': 'KL Sentral'});
      final forMak = RideRequest({'id': 'r', 'drop_name': 'KL Sentral', 'booked_for_phone': '+601'});
      expect(rideShareMessage(own, 'U'), 'Follow my GET.ride to KL Sentral: U');
      expect(rideShareMessage(forMak, 'U'), 'Your GET.ride to KL Sentral: U');
    });

    test('the shared view reads the ride, skipping a malformed stop', () {
      final r = SharedRide(_view());
      expect(r.status, RideStatus.accepted);
      expect(r.stops.map((s) => s.name), ['Pavilion']);
      expect(r.driver, const LatLng(3.155, 101.71));
      expect(sharedRideHeadline(r), 'Siti is on the way to the pickup');
      expect(SharedRide(_view(status: 'completed')).driver, isNull, reason: 'a finished ride shows no car');
      expect(sharedRideHeadline(SharedRide(_view(status: 'on_trip'))), 'Ali is on the way to KL Sentral');
      expect(sharedRideHeadline(SharedRide(_view(status: 'completed'))), 'Ali arrived at KL Sentral');
    });

    test('the car reads colour, make and model, else the free-text vehicle', () {
      expect(sharedRideCar(SharedRide(_view(car: true))), 'White Perodua Myvi');
      expect(sharedRideCar(SharedRide(_view())), 'Proton Saga');
      expect(sharedRideCar(SharedRide({'vehicle_color': 'Red', 'partner_vehicle': 'Red Axia'})), 'Red Axia');
      expect(sharedRideCar(SharedRide(const {})), isNull);
    });

    test('the SOS alert carries where the car is, the driver, plate and car, and the link', () {
      final text = sharedRideSosText(SharedRide(_view(car: true)), url: 'U');
      expect(text, contains('EMERGENCY'));
      expect(text, contains('https://maps.google.com/?q=3.155000,101.710000'));
      expect(text, contains('driver Siti'));
      expect(text, contains('car White Perodua Myvi, WXY 1'));
      expect(text, endsWith('Live trip: U'));
    });
  });

  group('the shared page', () {
    late _Geo geo;
    late List<String> sent, dialled;
    Future<_FakeRides> pump(WidgetTester tester, Map<String, dynamic>? view, {Size size = const Size(500, 1000)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides(view: view);
      geo = _Geo();
      sent = [];
      dialled = [];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(rides),
          geoServiceProvider.overrideWithValue(geo),
          rideSharerProvider.overrideWithValue((text) async => sent.add(text)),
          sharedRideDialerProvider.overrideWithValue((n) async => dialled.add(n)),
        ],
        child: const MaterialApp(home: SharedRideScreen(token: _token)),
      ));
      await tester.pump();
      await tester.pump();
      return rides;
    }

    testWidgets('shows the ride, the driver and the car, read-only', (tester) async {
      await pump(tester, _view());
      expect(find.text('Siti is on the way to the pickup'), findsOneWidget);
      expect(find.text('★ 4.8'), findsOneWidget);
      expect(find.text('WXY 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('shared-car')), findsOneWidget);
      expect(find.text('Proton Saga'), findsOneWidget);
      expect(find.text('KLCC'), findsOneWidget);
      expect(find.text('Pavilion'), findsOneWidget);
      expect(find.text('KL Sentral'), findsOneWidget);
      expect(find.byKey(const ValueKey('shared-trip-code')), findsNothing);
    });

    testWidgets('a ride booked for someone else gives them the trip code', (tester) async {
      await pump(tester, _view(otp: '8765', forOthers: true), size: const Size(1400, 900));
      expect(find.text('8765'), findsOneWidget);
      expect(find.text('A read-only view shared by a GET.ride rider. It updates by itself.'), findsOneWidget);
    });

    testWidgets('names the passenger in the headline and the rider who shared it, with no name · service line',
        (tester) async {
      await pump(tester, {..._view(status: 'on_trip', forOthers: true), 'rider': 'Melinda'});
      expect(find.text('Mak is on the way to KL Sentral'), findsOneWidget);
      expect(find.text('A read-only view shared by Melinda. It updates by itself.'), findsOneWidget);
      expect(find.text('Mak · Teksi'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    test('before 0110 the rider is the passenger, unless booked for someone else', () {
      expect(SharedRide(_view()).sharedBy, 'Ali');
      expect(SharedRide(_view(forOthers: true)).sharedBy, isNull);
      expect(SharedRide({..._view(forOthers: true), 'rider': 'Melinda'}).sharedBy, 'Melinda');
    });

    testWidgets('it keeps itself up to date while the ride is on the go', (tester) async {
      final rides = await pump(tester, _view());
      rides.view = _view(status: 'arrived');
      await tester.pump(rideShareRefresh);
      await tester.pump();
      expect(find.text('Siti has arrived at the pickup'), findsOneWidget);
      expect(rides.asked, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the plate, make, model and colour of the car', (tester) async {
      await pump(tester, _view(car: true));
      expect(find.byKey(const ValueKey('shared-plate')), findsOneWidget);
      expect(find.text('White Perodua Myvi'), findsOneWidget);
      expect(find.text('Colour: white'), findsOneWidget);
    });

    testWidgets('the trip\'s line, and the driver\'s dashed line to the pickup while on the way', (tester) async {
      await pump(tester, _view());
      await tester.pump();
      const pickup = LatLng(3.1579, 101.7116), drop = LatLng(3.1340, 101.6860), car = LatLng(3.155, 101.71);
      expect(geo.routed, containsAll([(pickup, drop, 1), (car, pickup, 0)]));
      final map = tester.widget<RideMap>(find.byType(RideMap));
      expect(map.route.first, pickup);
      expect(map.route.last, drop);
      final approach = tester.widget<PolylineLayer>(find.byKey(const ValueKey('shared-approach')));
      expect(approach.polylines.single.points.last, pickup);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on the trip there is no line to the pickup', (tester) async {
      await pump(tester, _view(status: 'on_trip'));
      await tester.pump();
      expect(find.byKey(const ValueKey('shared-approach')), findsNothing);
      expect(tester.widget<RideMap>(find.byType(RideMap)).route, isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a floating SOS calls the emergency number or sends an alert', (tester) async {
      await pump(tester, _view(car: true));
      await tester.tap(find.byKey(const ValueKey('shared-sos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shared-sos-call')));
      await tester.pumpAndSettle();
      expect(dialled, ['999']);
      await tester.tap(find.byKey(const ValueKey('shared-sos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shared-sos-send')));
      await tester.pumpAndSettle();
      expect(sent.single, contains('WXY 1'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no SOS once the ride is over', (tester) async {
      await pump(tester, _view(status: 'completed'));
      expect(find.byKey(const ValueKey('shared-sos')), findsNothing);
    });

    testWidgets('an unknown or expired link says so', (tester) async {
      await pump(tester, null);
      expect(find.text('This link has expired or is not valid.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the rider shares the ride from the tracking screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rides = _FakeRides();
    final sent = <String>[];
    final rows = StreamController<RideRequest>();
    addTearDown(rows.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rideRepositoryProvider.overrideWithValue(rides),
        rideStreamProvider.overrideWith((ref, id) => rows.stream),
        riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
        fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
        walletBalancesProvider.overrideWith((ref) async => const []),
        walletTxProvider.overrideWith((ref) async => const []),
        rideSharerProvider.overrideWithValue((text) async => sent.add(text)),
      ],
      child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
    ));
    rows.add(RideRequest({'id': 'r1', 'status': 'accepted', 'drop_name': 'KL Sentral', 'fare': 18.5}));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('share-ride')));
    await tester.pump();
    expect(rides.shared, ['r1']);
    expect(sent, ['Follow my GET.ride to KL Sentral: https://getride.my/share/$_token']);

    rows.add(RideRequest({'id': 'r1', 'status': 'completed', 'drop_name': 'KL Sentral', 'fare': 18.5}));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('share-ride')), findsNothing, reason: 'nothing left to follow');
  });
}
