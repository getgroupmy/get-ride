import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/early_end.dart';
import 'package:get_ride/src/core/trip_charges.dart';
import 'package:get_ride/src/core/trip_checkpoint.dart';
import 'package:get_ride/src/core/trip_progress.dart';
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

RideRequest ride(String status, {Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'me',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': pickup.latitude,
  'pickup_lng': pickup.longitude,
  'drop_lat': drop.latitude,
  'drop_lng': drop.longitude,
  ...extra,
});

class _FakeRides implements RideRepository {
  final log = <String>[];

  @override
  Future<void> approveCancellation(String id) async => log.add('approve');

  @override
  Future<void> complete(RideRequest r, {TripCharges charges = TripCharges.none, double? earlyFare}) async =>
      log.add('complete:${earlyFare ?? 'full'}');

  @override
  Future<bool> recordCheckpoint(String id, TripCheckpoint checkpoint, double? lat, double? lng) async => true;

  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  final routed = <(LatLng, LatLng)>[];

  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async {
    routed.add((from, to));
    return RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
  }
}

void main() {
  group('rules', () {
    test('trip time runs from started_at, else from first seen, never negative', () {
      final now = t0.add(const Duration(minutes: 4, seconds: 5));
      expect(tripElapsed(startedAt: t0, firstSeen: now, now: now), const Duration(minutes: 4, seconds: 5));
      expect(tripElapsed(firstSeen: t0, now: now), const Duration(minutes: 4, seconds: 5));
      expect(tripElapsed(startedAt: now.add(const Duration(seconds: 3)), now: now), Duration.zero);
      expect(tripElapsed(now: now), Duration.zero);
    });

    test('the trip clock reads m:ss, then h:mm:ss', () {
      expect(formatTripElapsed(const Duration(minutes: 4, seconds: 5)), '4:05');
      expect(formatTripElapsed(Duration.zero), '0:00');
      expect(formatTripElapsed(const Duration(hours: 1, minutes: 2, seconds: 5)), '1:02:05');
    });

    test('a leg counts unless the fix is loose or the jump impossible', () {
      const a = LatLng(3.15, 101.70), b = LatLng(3.151, 101.70); // ~111 m
      expect(tripLegMetres(a, b, const Duration(seconds: 10)), closeTo(111, 1));
      expect(tripLegMetres(a, b, const Duration(seconds: 10), accuracy: 80), 0);
      expect(tripLegMetres(a, b, const Duration(seconds: 1)), 0, reason: '111 m/s');
      expect(tripLegMetres(a, b, Duration.zero), 0);
    });

    test('what the driver is told when the ride ends without them', () {
      final cancelled = ride('cancelled');
      expect(passengerCancelNotice(RideStatus.onTrip, cancelled, approvedHere: false), 'This ride was cancelled.');
      expect(
        passengerCancelNotice(
          RideStatus.accepted,
          ride('cancelled', extra: {'cancel_reason': 'Changed my plans'}),
          approvedHere: false,
        ),
        'The passenger cancelled this ride: Changed my plans',
      );
      expect(
        passengerCancelNotice(
          RideStatus.arrived,
          ride('cancelled', extra: {'cancel_requested_by': 'partner', 'cancel_reason': 'Cancelled by driver'}),
          approvedHere: false,
        ),
        'The passenger agreed to cancel this ride.',
      );
      expect(passengerCancelNotice(RideStatus.onTrip, cancelled, approvedHere: true), isNull);
      expect(passengerCancelNotice(null, cancelled, approvedHere: false), isNull, reason: 'opened on a cancelled ride');
      expect(passengerCancelNotice(RideStatus.cancelled, cancelled, approvedHere: false), isNull);
      expect(passengerCancelNotice(RideStatus.onTrip, ride('completed'), approvedHere: false), isNull);
    });
  });

  group('ending early', () {
    test('only away from the drop-off, and only when both points are known', () {
      expect(endsEarly(drop, drop), isFalse);
      expect(endsEarly(const LatLng(3.1360, 101.6860), drop), isFalse, reason: '~220 m: arriving');
      expect(endsEarly(pickup, drop), isTrue);
      expect(endsEarly(null, drop), isFalse);
      expect(endsEarly(pickup, null), isFalse);
    });

    test('the fare follows the distance covered, between the flag fall and the agreed fare', () {
      expect(earlyEndFare(agreed: 20, plannedKm: 10, drivenKm: 4), 8);
      expect(earlyEndFare(agreed: 20, plannedKm: 10, drivenKm: 0.5), 4, reason: 'flag fall');
      expect(earlyEndFare(agreed: 3, plannedKm: 10, drivenKm: 0.5), 3, reason: 'never above the agreed fare');
      expect(earlyEndFare(agreed: 20, plannedKm: 10, drivenKm: 14), 20, reason: 'a detour is not billed past the fare');
      expect(earlyEndFare(agreed: 20, plannedKm: 7, drivenKm: 2), 5.71);
      expect(earlyEndFare(agreed: 20, plannedKm: null, drivenKm: 2), 20);
      expect(earlyEndFare(agreed: 20, plannedKm: 10, drivenKm: null), 20);
      expect(earlyEndFare(agreed: 0, plannedKm: 10, drivenKm: 2), 0);
    });
  });

  group('screen', () {
    late DateTime now;
    late StreamController<RideRequest> rows;
    late StreamController<TripFix> fixes;
    late _FakeRides rides;
    late _Geo geo;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      now = t0;
      rides = _FakeRides();
      geo = _Geo();
      rows = StreamController<RideRequest>();
      fixes = StreamController<TripFix>();
      addTearDown(rows.close);
      addTearDown(fixes.close);
      final router = GoRouter(
        initialLocation: '/trip',
        routes: [
          GoRoute(
            path: '/drive',
            builder: (_, _) => const Scaffold(body: Text('requests')),
          ),
          GoRoute(
            path: '/trip',
            builder: (_, _) => const PartnerTripScreen(requestId: 'r1'),
          ),
          GoRoute(
            path: '/trips/:id',
            builder: (_, st) => Scaffold(body: Text('receipt ${st.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            tripPositionStreamProvider.overrideWithValue(() => fixes.stream),
            tripClockProvider.overrideWithValue(() => now),
            tripFixProvider.overrideWithValue(() async => null),
            geoServiceProvider.overrideWithValue(geo),
            currentUserIdProvider.overrideWithValue(null),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
    }

    Future<void> fix(WidgetTester tester, LatLng at, {Duration after = const Duration(seconds: 10)}) async {
      now = now.add(after);
      fixes.add((at: at, heading: 90, accuracy: 5));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the road to the pickup, with an ETA and the car turned', (tester) async {
      await pump(tester);
      rows.add(ride('accepted'));
      await tester.pump();
      const at = LatLng(3.16, 101.72);
      await fix(tester, at);
      expect(geo.routed, [(at, pickup)]);
      expect(find.text('Arriving in 6 min · 10:36 · 2.3 km'), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-heading')), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-meter')), findsNothing);
    });

    testWidgets('on the trip: the drop-off route, a running clock and the distance driven', (tester) async {
      await pump(tester);
      rows.add(ride('arrived'));
      await tester.pump();
      await fix(tester, pickup);
      await fix(tester, const LatLng(3.1579, 101.7120), after: const Duration(seconds: 5));
      rows.add(ride('on_trip'));
      await tester.pump();
      await tester.pump();
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('0.0 km driven'), findsOneWidget, reason: 'the way to the pickup does not count');

      await fix(tester, const LatLng(3.1569, 101.7120)); // ~111 m
      await fix(tester, const LatLng(3.1479, 101.7120), after: const Duration(seconds: 50)); // ~1 km
      expect(find.text('1.1 km driven'), findsOneWidget);
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1:05'), findsOneWidget);
      expect(geo.routed.last.$2, drop);
      expect(find.textContaining('Arrive at'), findsOneWidget);
    });

    testWidgets('a cancel the driver did not approve sends them back to requests', (tester) async {
      await pump(tester);
      rows.add(ride('on_trip'));
      await tester.pump();
      rows.add(ride('cancelled', extra: {'cancel_requested_by': 'partner'}));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('trip-cancelled')), findsOneWidget);
      expect(find.text('The passenger agreed to cancel this ride.'), findsOneWidget);
      await tester.tap(find.text('Back to requests').last);
      await tester.pumpAndSettle();
      expect(find.text('requests'), findsOneWidget);
    });

    testWidgets('approving the passenger’s cancel is not announced back', (tester) async {
      await pump(tester);
      final asked = {'cancel_requested_at': t0.toIso8601String(), 'cancel_requested_by': 'rider'};
      rows.add(ride('arrived', extra: asked));
      await tester.pump();
      await tester.tap(find.text('Approve'));
      await tester.pump();
      expect(rides.log, ['approve']);
      rows.add(ride('cancelled', extra: asked));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('trip-cancelled')), findsNothing);
    });

    testWidgets('a completed trip links to its receipt', (tester) async {
      await pump(tester);
      rows.add(ride('completed'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('trip-receipt')));
      await tester.pumpAndSettle();
      expect(find.text('receipt r1'), findsOneWidget);
    });

    testWidgets('completing short of the drop-off recalculates and stores the fare', (tester) async {
      await pump(tester);
      rows.add(ride('on_trip', extra: {'distance_km': 10}));
      await tester.pump();
      await fix(tester, const LatLng(3.15, 101.70));
      await tester.tap(find.byKey(const ValueKey('trip-complete')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('early-end')), findsOneWidget);
      expect(find.textContaining('2.3 km driven of the 10.0 km booked: RM4.68 instead of RM20.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('early-end-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Collect RM4.68'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('charges-confirm')));
      await tester.pump();
      await tester.pump();
      expect(rides.log, contains('complete:4.68'));
    });

    testWidgets('keep driving leaves the trip running', (tester) async {
      await pump(tester);
      rows.add(ride('on_trip', extra: {'distance_km': 10}));
      await tester.pump();
      await fix(tester, const LatLng(3.15, 101.70));
      await tester.tap(find.byKey(const ValueKey('trip-complete')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Keep driving'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('charges-confirm')), findsNothing);
      expect(rides.log, isNot(contains(startsWith('complete'))));
    });

    testWidgets('at the drop-off it completes at the booked fare', (tester) async {
      await pump(tester);
      rows.add(ride('on_trip'));
      await tester.pump();
      await fix(tester, drop);
      await tester.tap(find.byKey(const ValueKey('trip-complete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('early-end')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('charges-confirm')));
      await tester.pump();
      await tester.pump();
      expect(rides.log, contains('complete:full'));
    });
  });
}
