// A ride shared by link: the link, the message and the read-only page.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_share.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/ride/shared_ride_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = '0b5c6a52-3f0e-4c47-9a7e-3f1f2a1d9e10';

Map<String, dynamic> _view({String status = 'accepted', String? otp, bool forOthers = false}) => {
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
      expect(sharedRideHeadline(SharedRide(_view(status: 'on_trip'))), 'On the way to KL Sentral');
    });
  });

  group('the shared page', () {
    Future<_FakeRides> pump(WidgetTester tester, Map<String, dynamic>? view, {Size size = const Size(500, 1000)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides(view: view);
      await tester.pumpWidget(ProviderScope(
        overrides: [rideRepositoryProvider.overrideWithValue(rides)],
        child: const MaterialApp(home: SharedRideScreen(token: _token)),
      ));
      await tester.pump();
      await tester.pump();
      return rides;
    }

    testWidgets('shows the ride, the driver and the car, read-only', (tester) async {
      await pump(tester, _view());
      expect(find.text('Siti is on the way to the pickup'), findsOneWidget);
      expect(find.text('Proton Saga · WXY 1 · ★ 4.8'), findsOneWidget);
      expect(find.text('KLCC'), findsOneWidget);
      expect(find.text('Pavilion'), findsOneWidget);
      expect(find.text('KL Sentral'), findsOneWidget);
      expect(find.byKey(const ValueKey('shared-trip-code')), findsNothing);
    });

    testWidgets('a ride booked for someone else gives them the trip code', (tester) async {
      await pump(tester, _view(otp: '8765', forOthers: true), size: const Size(1400, 900));
      expect(find.text('8765'), findsOneWidget);
      expect(find.textContaining('Mak'), findsOneWidget);
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
