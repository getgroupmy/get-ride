// Driver trip batch (web tester 41): the trip screen moves on when the
// driver's own update succeeds (125), the charges field's label fits (126),
// and the desktop request over the map reads its facts as text (127) and
// answers as the phone's sheet does, with no "waiting" beside it (128).
// The trip code dialog (124) is in trip_start_test.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_charges.dart';
import 'package:get_ride/src/core/trip_checkpoint.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart' show rideStreamProvider;
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pickup = LatLng(3.1579, 101.7116);
const drop = LatLng(3.1340, 101.6860);

RideRequest ride(String status) => RideRequest({
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
});

class _TripRides implements RideRepository {
  final log = <String>[];
  Completer<void>? hold;
  Object? error;

  @override
  Future<void> updateStatus(String id, RideStatus status) async {
    log.add('status:${status.db}');
    await hold?.future;
    if (error case final e?) throw e;
  }

  @override
  Future<void> complete(RideRequest r, {TripCharges charges = TripCharges.none, double? earlyFare}) async {
    log.add('complete');
    await hold?.future;
  }

  @override
  Future<bool> recordCheckpoint(String id, TripCheckpoint checkpoint, double? lat, double? lng) async => true;

  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Geo extends GeoService {
  @override
  Future<RouteInfo> route(LatLng from, LatLng to, {List<LatLng> via = const []}) async =>
      RouteInfo(distanceKm: 2.34, durationMin: 5.2, points: [from, to]);
}

Future<(_TripRides, StreamController<RideRequest>)> pumpTrip(WidgetTester tester, String status) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rides = _TripRides();
  final rows = StreamController<RideRequest>();
  addTearDown(rows.close);
  final router = GoRouter(
    initialLocation: '/trip',
    routes: [
      GoRoute(path: '/drive', builder: (_, _) => const Scaffold(body: Text('requests'))),
      GoRoute(path: '/trip', builder: (_, _) => const PartnerTripScreen(requestId: 'r1')),
      GoRoute(path: '/trips/:id', builder: (_, s) => Scaffold(body: Text('receipt ${s.pathParameters['id']}'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        rideRepositoryProvider.overrideWithValue(rides),
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
  rows.add(ride(status));
  await tester.pump();
  await tester.pump();
  return (rides, rows);
}

class _DriveRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest openRequest() => RideRequest({
  'id': 'q1',
  'status': 'open',
  'service': 'Teksi',
  'fare': 14,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
  'offer_me': true,
  'pickup_name': 'From q1',
  'drop_name': 'To q1',
  'pickup_lat': 3.1585,
  'pickup_lng': 101.7123,
  'drop_lat': 3.10,
  'drop_lng': 101.72,
});

void main() {
  group('125 the driver\'s own step', () {
    testWidgets("I've arrived: the screen moves on when the call succeeds, busy while it runs, no second call",
        (tester) async {
      final (rides, _) = await pumpTrip(tester, 'accepted');
      rides.hold = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('trip-arrive')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets, reason: 'busy while the call runs');
      await tester.tap(find.byKey(const ValueKey('trip-arrive')), warnIfMissed: false);
      await tester.pump();
      expect(rides.log, ['status:arrived'], reason: 'one call, however many taps');
      rides.hold!.complete();
      await tester.pump();
      await tester.pump();
      // Realtime has not brought the row back: the screen moved on anyway.
      expect(find.byKey(const ValueKey('trip-arrive')), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Start trip'), findsWidgets);
      expect(rides.log, ['status:arrived']);
    });

    testWidgets('a stale row from realtime does not take the screen back', (tester) async {
      final (rides, rows) = await pumpTrip(tester, 'accepted');
      await tester.tap(find.byKey(const ValueKey('trip-arrive')));
      await tester.pump();
      await tester.pump();
      rows.add(ride('accepted'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('trip-arrive')), findsNothing);
      // The row catches up, then moves on by itself.
      rows.add(ride('arrived'));
      await tester.pump();
      rows.add(ride('cancelled'));
      await tester.pump();
      await tester.pump();
      expect(find.widgetWithText(FilledButton, 'Start trip'), findsNothing);
      expect(rides.log, ['status:arrived']);
    });

    testWidgets('a failed call leaves the step where it was', (tester) async {
      final (rides, _) = await pumpTrip(tester, 'accepted');
      rides.error = Exception('offline');
      await tester.tap(find.byKey(const ValueKey('trip-arrive')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('trip-arrive')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Complete: the trip ends on screen when the call succeeds', (tester) async {
      final (rides, _) = await pumpTrip(tester, 'on_trip');
      await tester.tap(find.byKey(const ValueKey('trip-complete')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 126: the third field's label is short enough not to be cut.
      expect(find.text('What are they for?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('charges-confirm')));
      await tester.pump();
      await tester.pump();
      expect(rides.log, ['complete']);
      expect(find.byKey(const ValueKey('trip-complete')), findsNothing);
      expect(find.byKey(const ValueKey('trip-collect')), findsOneWidget);
    });
  });

  group('desktop request over the map', () {
    testWidgets('127/128: facts read as text, the phone\'s answers, nothing "waiting" beside it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1366, 900);
      addTearDown(tester.view.reset);
      final open = StreamController<List<RideRequest>>.broadcast();
      addTearDown(open.close);
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(_DriveRides()),
            driverPositionProvider.overrideWithValue(() async => pickup),
            driverPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      open.add(const []);
      await tester.pump();
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      open.add(const []);
      await tester.pump();
      expect(find.text('New requests appear here instantly.'), findsOneWidget);
      open.add([openRequest()]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final alert = find.byKey(const ValueKey('request-alert'));
      expect(alert, findsOneWidget);
      // 127: no chips that a screen reader calls checkboxes.
      expect(find.descendant(of: alert, matching: find.byType(Chip)), findsNothing);
      expect(find.descendant(of: alert, matching: find.text('Cash')), findsOneWidget);
      expect(find.descendant(of: alert, matching: find.text('1 pax')), findsOneWidget);
      // 128: the phone's controls.
      expect(find.descendant(of: alert, matching: find.text('Accept for RM14.00')), findsOneWidget);
      expect(find.descendant(of: alert, matching: find.byKey(const ValueKey('request-offer-0'))), findsOneWidget);
      expect(find.descendant(of: alert, matching: find.byTooltip('Offer another fare')), findsOneWidget);
      expect(find.text('Offer price'), findsNothing);
      // And the panel beside it is not "waiting".
      expect(find.text('New requests appear here instantly.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
