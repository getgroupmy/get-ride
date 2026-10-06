import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/request_alert.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _FakeRides implements RideRepository {
  final accepted = <String>[];

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<RideRequest?> accept(
    String id,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    accepted.add(id);
    return RideRequest({'id': id, 'status': 'accepted'});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _req(String id, {double fare = 12}) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Teksi',
  'fare': fare,
  'ride_fare': fare,
  'currency': 'MYR',
  'distance_km': 5,
  'duration_min': 14,
  'passengers': 2,
  'luggage': 1,
  'payment_mode': 'Cash',
  'rider_name': 'Siti',
  'rider_rating': 4.8,
  'pickup_name': 'KLCC',
  'pickup_address': 'Jalan Ampang',
  'drop_name': 'KL Sentral',
});

void main() {
  group('rules', () {
    test('a declined request comes back only on a raise', () {
      final declined = {'a': 12.0, 'b': 12.0, 'c': 12.0};
      expect(raisedAfterDecline(declined, [(id: 'a', fare: 15), (id: 'b', fare: 12), (id: 'c', fare: 10)]), ['a']);
      expect(raisedAfterDecline(declined, [(id: 'd', fare: 99), (id: 'a', fare: null)]), isEmpty);
    });

    test('the next alert is the first unseen, unhidden request', () {
      expect(nextRequestAlert(openIds: ['a', 'b'], seen: {}, hidden: {}), 'a');
      expect(nextRequestAlert(openIds: ['a', 'b'], seen: {'a'}, hidden: {}), 'b');
      expect(nextRequestAlert(openIds: ['a', 'b'], seen: {}, hidden: {'a'}), 'b');
      expect(nextRequestAlert(openIds: ['a'], seen: {'a'}, hidden: {}), isNull);
    });

    test('the request showing stays until it leaves the queue', () {
      expect(nextRequestAlert(openIds: ['a', 'b'], seen: {'a', 'b'}, hidden: {}, current: 'b'), 'b');
      expect(nextRequestAlert(openIds: ['a'], seen: {'a', 'b'}, hidden: {}, current: 'b'), isNull);
    });

    test('35-second window', () {
      expect(requestAlertProgress(Duration.zero), 1);
      expect(requestAlertSecondsLeft(const Duration(seconds: 10, milliseconds: 500)), 25);
      expect(requestAlertExpired(const Duration(seconds: 34)), isFalse);
      expect(requestAlertExpired(const Duration(seconds: 35)), isTrue);
    });

    test('pickup minutes at city speed, never zero', () {
      expect(pickupMinutes(5), 12);
      expect(pickupMinutes(0.1), 1);
    });
  });

  group('screen', () {
    late StreamController<List<RideRequest>> open;
    late _FakeRides rides;
    late DateTime now;

    setUp(() {
      open = StreamController<List<RideRequest>>.broadcast();
      rides = _FakeRides();
      now = DateTime(2026, 10, 6, 11);
    });
    tearDown(() => open.close());

    Future<void> pump(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 2000);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
          GoRoute(
            path: '/drive/trip/:id',
            builder: (_, s) => Scaffold(body: Text('trip ${s.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(rides),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
            requestAlertClockProvider.overrideWithValue(() => now),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> wait(WidgetTester tester, Duration d) async {
      now = now.add(d);
      await tester.pump(d);
      await tester.pump();
    }

    testWidgets('a new request pops up with who, where and a countdown', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget);
      expect(find.text('Siti'), findsOneWidget);
      expect(find.textContaining('★ 4.8'), findsOneWidget);
      expect(find.text('Jalan Ampang'), findsOneWidget);
      expect(find.text('1 bag'), findsOneWidget);
      expect(find.text('35 s'), findsOneWidget);
      await wait(tester, const Duration(seconds: 10));
      expect(find.text('25 s'), findsOneWidget);
    });

    testWidgets('accept from the alert takes the request', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pumpAndSettle();
      expect(rides.accepted, ['r1']);
    });

    testWidgets('decline hides it; the next new request pops up', (tester) async {
      await pump(tester);
      open.add([_req('r1'), _req('r2', fare: 20)]);
      await tester.pump();
      await tester.pump();
      expect(find.text('Accept RM12.00'), findsOneWidget, reason: 'r1 in the alert');
      expect(find.text('Accept RM20.00'), findsOneWidget, reason: 'r2 waits in the list');
      await tester.tap(find.byKey(const ValueKey('request-alert-decline')));
      await tester.pump();
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget);
      expect(find.text('Accept RM12.00'), findsNothing, reason: 'r1 is gone from this driver\'s queue');
      expect(find.text('Accept RM20.00'), findsOneWidget);
    });

    testWidgets('left alone it drops back into the list after 35 s', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await wait(tester, const Duration(seconds: 36));
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      expect(find.text('Accept RM12.00'), findsOneWidget);
    });

    testWidgets('a request taken by someone else closes its alert', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      open.add(const []);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
    });

    testWidgets('a declined request pops back up when the passenger raises the fare', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('request-alert-decline')));
      await tester.pump();
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('request-alert')), findsNothing, reason: 'same fare stays declined');
      open.add([_req('r1', fare: 17)]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget);
      expect(find.text('Fare raised'), findsOneWidget);
      expect(find.text('The passenger raised the fare from RM12.00 to RM17.00.'), findsOneWidget);
      expect(find.text('35 s'), findsOneWidget, reason: 'a fresh window');
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pumpAndSettle();
      expect(rides.accepted, ['r1']);
    });
  });
}
