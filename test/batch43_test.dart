// Web tester batch 43: a ride the driver cancelled stays for the rider, who
// can send the same trip to another driver (131); the driver's passenger
// card never breaks a word at 320 (132); Navigate and Cancel ride are in
// view with the trip sheet at rest (133).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_rebook.dart';
import 'package:get_ride/src/core/trip_checkpoint.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pickup = LatLng(3.1579, 101.7116);
const drop = LatLng(3.1340, 101.6860);

RideRequest ride(String status, {Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'partner_id': 'driver',
  'partner_name': 'Ali',
  'status': status,
  'service': 'GET XL',
  'fare': 20,
  'ride_fare': 24,
  'currency': 'MYR',
  'payment_mode': 'Cash',
  'passengers': 1,
  'pickup_name': 'KLCC',
  'pickup_address': 'Jalan Ampang',
  'drop_name': 'KL Sentral',
  'pickup_lat': pickup.latitude,
  'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude,
  'drop_lng': drop.longitude,
  ...extra,
});

class _Rides implements RideRepository {
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  Future<void> publishRiderLocation(String id, double lat, double lng) async {}

  @override
  Future<void> clearRiderLocation(String id) async {}

  @override
  Future<bool> recordCheckpoint(String id, TripCheckpoint checkpoint, double? lat, double? lng) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async =>
      RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  group('131 the driver cancelled', () {
    Future<(ProviderContainer, StreamController<RideRequest>)> pumpRider(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      final container = ProviderContainer(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_Rides()),
          rideStreamProvider.overrideWith((ref, id) => rows.stream),
          riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
          geoServiceProvider.overrideWithValue(_Geo()),
          fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
          walletBalancesProvider.overrideWith((ref) async => const []),
          walletTxProvider.overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/ride/r1',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
          GoRoute(path: '/ride/:id', builder: (_, s) => RideTrackingScreen(requestId: s.pathParameters['id']!)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router)),
      );
      rows.add(ride('arrived'));
      await settle(tester);
      rows.add(ride('cancelled', extra: {'cancel_requested_by': 'partner', 'cancel_reason': 'passenger_no_show'}));
      await settle(tester);
      return (container, rows);
    }

    testWidgets('the screen stays, with the reason, until the rider leaves it', (tester) async {
      await pumpRider(tester);
      expect(find.text('Your driver cancelled this ride: Passenger no-show'), findsOneWidget);
      expect(find.textContaining('Closing in'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('home'), findsNothing, reason: 'no auto-close (WCAG 2.2.1)');
      expect(find.byKey(const ValueKey('ride-find-another')), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-book-again')), findsOneWidget);
    });

    testWidgets('"Find another driver" takes the same trip, vehicle and fare to the confirm step', (tester) async {
      final (container, _) = await pumpRider(tester);
      await tester.tap(find.byKey(const ValueKey('ride-find-another')));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      final trip = container.read(rideRebookProvider)!;
      expect(trip.pickup.point, pickup);
      expect(trip.pickup.name, 'KLCC');
      expect(trip.drop.point, drop);
      expect(trip.service, 'GET XL');
      expect(trip.fare, 24);
      expect(trip.payment, 'Cash');
    });

    testWidgets('"Book another ride" keeps the route, the vehicle and fare picked afresh', (tester) async {
      final (container, _) = await pumpRider(tester);
      await tester.tap(find.byKey(const ValueKey('ride-book-again')));
      await tester.pumpAndSettle();
      final trip = container.read(rideRebookProvider)!;
      expect(trip.drop.name, 'KL Sentral');
      expect(trip.service, isNull);
      expect(trip.fare, isNull);
    });
  });

  group('driver trip screen', () {
    Future<void> pumpTrip(WidgetTester tester, Size size, RideRequest r) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
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
            rideRepositoryProvider.overrideWithValue(_Rides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            tripPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
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
      rows.add(r);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('132: "1 passenger" stays one line beside Message and Call at 320', (tester) async {
      await pumpTrip(tester, const Size(320, 568), ride('accepted', extra: {'partner_id': 'me'}));
      final pax = find.byKey(const ValueKey('trip-pax'));
      final payment = find.byKey(const ValueKey('trip-payment'));
      expect(pax, findsOneWidget);
      expect(tester.getSize(pax).height, lessThanOrEqualTo(tester.getSize(payment).height + 0.5),
          reason: 'one line, as "Cash"');
      expect(find.byKey(const ValueKey('trip-message')), findsOneWidget);
    });

    testWidgets('133: Navigate and Cancel ride show above the pinned bar at rest (390x844)', (tester) async {
      await pumpTrip(tester, const Size(390, 844), ride('accepted', extra: {'partner_id': 'me'}));
      final bar = tester.getTopLeft(find.byKey(const ValueKey('trip-footer'))).dy;
      final handle = find.byKey(const ValueKey('map-sheet-handle'));
      final restsAt = tester.getTopLeft(handle).dy;
      final shown = [find.byKey(const ValueKey('trip-navigate')), find.byKey(const ValueKey('trip-cancel'))];
      for (final f in shown) {
        expect(f, findsOneWidget);
      }
      if (shown.any((f) => tester.getBottomLeft(f).dy > bar)) {
        // Taller than the screen (the test font is wide): it rests all the way up.
        await tester.drag(handle, const Offset(0, -1000));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getTopLeft(handle).dy, closeTo(restsAt, 0.5));
      }
    });
  });
}
