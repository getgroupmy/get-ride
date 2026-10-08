import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_cancel.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

RideRequest ride(String status, {String? askedBy, String? reason}) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'partner_id': 'driver',
  'partner_name': 'Ali',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'cancel_requested_at': askedBy == null ? null : '2026-10-06T08:00:00Z',
  'cancel_requested_by': askedBy,
  'cancel_reason': reason,
});

class _FakeRides implements RideRepository {
  final cancels = <(String, String?)>[];
  final shared = <(double, double)>[];
  final answers = <String>[];

  @override
  Future<void> approveCancellation(String id) async => answers.add('approve');

  @override
  Future<void> declineCancellation(String id) async => answers.add('decline');

  @override
  Future<void> cancel(RideRequest r, {String? reason, required String by}) async => cancels.add((r.status.db, reason));

  @override
  Future<void> publishRiderLocation(String id, double lat, double lng) async => shared.add((lat, lng));

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('rules', () {
    test('driver reasons are not offered before a driver accepts', () {
      expect(cancelReasonsFor(RideStatus.open).map((r) => r.id), ['changed_plans', 'booked_by_mistake', 'other']);
      expect(cancelReasonsFor(RideStatus.onTrip), hasLength(6));
    });

    test('the stored value is the Expo id, or the rider\'s words for Other', () {
      expect(cancelReasonValue('changed_plans', ''), 'changed_plans');
      expect(cancelReasonValue('other', '  wrong car  '), 'wrong car');
      expect(cancelReasonValue('other', '  '), isNull);
      expect(cancelReasonValue(null, 'x'), isNull);
    });

    test('stored reasons read back as labels; free text as written', () {
      expect(cancelReasonLabel('driver_too_long'), 'Driver taking too long');
      expect(cancelReasonLabel('wrong car'), 'wrong car');
      expect(cancelReasonLabel(''), isNull);
      expect(cancelReasonLabel(null), isNull);
    });

    test('a driver may cancel only before the passenger is on board', () {
      expect(driverMayCancel(RideStatus.accepted), isTrue);
      expect(driverMayCancel(RideStatus.arrived), isTrue);
      for (final s in [RideStatus.open, RideStatus.onTrip, RideStatus.completed, RideStatus.cancelled]) {
        expect(driverMayCancel(s), isFalse, reason: s.db);
      }
    });

    test('driver reasons are Expo\'s ids and read back as labels', () {
      expect(driverCancelReasons.map((r) => r.id), [
        'passenger_no_show',
        'wrong_address',
        'passenger_cancelled',
        'traffic_too_far',
        'vehicle_issue',
        'other',
      ]);
      expect(cancelReasonLabel('passenger_no_show'), 'Passenger no-show');
    });

    test('the passenger is told the driver cancelled, and why', () {
      final byDriver = ride('cancelled', askedBy: 'partner', reason: 'vehicle_issue');
      expect(cancelledByDriver(byDriver), isTrue);
      expect(driverCancelNotice(byDriver), 'Your driver cancelled this ride: Vehicle issue');
      expect(driverCancelNotice(ride('cancelled', askedBy: 'partner')), 'Your driver cancelled this ride.');
      expect(cancelledByDriver(ride('cancelled', askedBy: 'rider')), isFalse);
      expect(cancelledByDriver(ride('cancelled')), isFalse);
      expect(cancelledByDriver(ride('arrived', askedBy: 'partner')), isFalse, reason: 'an old build\'s pending ask');
    });

    test('a declined request is the rider ask disappearing from a live ride', () {
      final asked = ride('on_trip', askedBy: 'rider');
      expect(riderCancelDeclined(asked, ride('on_trip')), isTrue);
      expect(riderCancelDeclined(asked, ride('cancelled')), isFalse, reason: 'approved, not declined');
      expect(riderCancelDeclined(ride('on_trip', askedBy: 'partner'), ride('on_trip')), isFalse);
      expect(riderCancelDeclined(null, ride('on_trip')), isFalse);
    });

    test('location is shared only while a driver is assigned', () {
      expect(shareRiderLocation(RideStatus.open), isFalse);
      expect(shareRiderLocation(RideStatus.accepted), isTrue);
      expect(shareRiderLocation(RideStatus.onTrip), isTrue);
      expect(shareRiderLocation(RideStatus.completed), isFalse);
    });
  });

  group('screen', () {
    Future<(_FakeRides, StreamController<RideRequest>, StreamController<LatLng>)> pump(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides();
      final rows = StreamController<RideRequest>();
      final gps = StreamController<LatLng>.broadcast();
      addTearDown(rows.close);
      addTearDown(gps.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            riderPositionStreamProvider.overrideWithValue(() => gps.stream),
            fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
            walletBalancesProvider.overrideWith((ref) async => const []),
            walletTxProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: RideTrackingScreen(requestId: 'r1')),
        ),
      );
      return (rides, rows, gps);
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
    }

    testWidgets('on the trip the rider can ask to cancel, with a reason', (tester) async {
      final (rides, rows, _) = await pump(tester);
      rows.add(ride('on_trip'));
      await settle(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Request cancellation'));
      // The button spins while its reason dialog is open, so pump the
      // dialog in rather than waiting for everything to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining("You're on your trip"), findsOneWidget);

      FilledButton confirm() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Request cancellation'));
      expect(confirm().onPressed, isNull, reason: 'a reason is required');
      await tester.tap(find.byKey(const ValueKey('cancel-reason-driver_not_moving')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Request cancellation'));
      await tester.pumpAndSettle();
      expect(rides.cancels, [('on_trip', 'driver_not_moving')]);
    });

    testWidgets('Other needs the rider\'s own words', (tester) async {
      final (rides, rows, _) = await pump(tester);
      rows.add(ride('accepted'));
      await settle(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel ride'));
      // The button spins while its reason dialog is open, so pump the
      // dialog in rather than waiting for everything to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('cancel-reason-other')));
      await tester.pump();
      FilledButton confirm() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Cancel ride'));
      expect(confirm().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('cancel-reason-text')), 'Found another ride');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel ride'));
      await tester.pumpAndSettle();
      expect(rides.cancels, [('accepted', 'Found another ride')]);
    });

    testWidgets('a search is cancelled through why, then are-you-sure', (tester) async {
      final (rides, rows, _) = await pump(tester);
      rows.add(ride('open'));
      await settle(tester);
      Future<void> open() async {
        await tester.tap(find.byKey(const ValueKey('cancel-request')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      // Closing the first sheet keeps the request.
      await open();
      expect(find.text('Why do you want to cancel?'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-reason-driver_too_long')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cancel-sheet-close')));
      await tester.pump(const Duration(milliseconds: 400));
      // Skip, then Keep searching: still nothing.
      await open();
      await tester.tap(find.byKey(const ValueKey('cancel-skip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Cancel your request?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-keep-searching')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(rides.cancels, isEmpty);
      // A reason, then Cancel request.
      await open();
      await tester.tap(find.byKey(const ValueKey('cancel-reason-high_fares')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rides.cancels, [('open', 'high_fares')]);
      expect(find.text('Request cancelled'), findsOneWidget);
    });

    testWidgets('a skipped reason cancels with none', (tester) async {
      final (rides, rows, _) = await pump(tester);
      rows.add(ride('open'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('cancel-request')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('cancel-skip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rides.cancels, [('open', null)]);
    });

    testWidgets('a ride booked for someone else says who for', (tester) async {
      final (_, rows, _) = await pump(tester);
      rows.add(RideRequest({...ride('accepted').raw, 'booked_for_name': 'Mak', 'booked_for_phone': '+60123456789'}));
      await settle(tester);
      expect(find.text('Booked for Mak · +60123456789'), findsOneWidget);
    });

    testWidgets("a driver's offer shows no driver card, trip code or contact until it is accepted", (tester) async {
      final (_, rows, _) = await pump(tester);
      final bid = {
        'partner_id': 'driver',
        'partner_name': 'Kabeer',
        'partner_phone': '+60123',
        'offered_fare': 75,
        'otp': '1314',
      };
      rows.add(RideRequest({...ride('open').raw, ...bid}));
      await settle(tester);
      expect(find.text('Trip code'), findsNothing);
      expect(find.text('Call'), findsNothing);
      expect(find.text('Message'), findsNothing);

      rows.add(RideRequest({...ride('accepted').raw, ...bid}));
      await settle(tester);
      expect(find.text('Trip code'), findsOneWidget);
      expect(find.text('1314'), findsOneWidget);
      expect(find.text('Call'), findsOneWidget);
    });

    testWidgets('the passenger is told their driver cancelled, and why', (tester) async {
      final (_, rows, _) = await pump(tester);
      rows.add(ride('arrived'));
      await settle(tester);
      expect(find.byKey(const ValueKey('driver-cancelled')), findsNothing);
      rows.add(ride('cancelled', askedBy: 'partner', reason: 'passenger_no_show'));
      await settle(tester);
      expect(find.text('Your driver cancelled this ride: Passenger no-show'), findsOneWidget);
    });

    testWidgets("the driver's request to cancel is a popup the passenger answers", (tester) async {
      final (rides, rows, _) = await pump(tester);
      rows.add(ride('arrived', askedBy: 'partner'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('cancel-request-dialog')), findsOneWidget);
      expect(find.text('Your driver asked to cancel this ride.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-request-decline')));
      await settle(tester);
      expect(rides.answers, ['decline']);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('cancel-request-dialog')), findsNothing);
    });

    testWidgets('the popup closes by itself when the driver withdraws', (tester) async {
      final (rides, rows, _) = await pump(tester);
      rows.add(ride('arrived', askedBy: 'partner'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('cancel-request-dialog')), findsOneWidget);
      // A tap outside does not answer it.
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('cancel-request-dialog')), findsOneWidget);
      rows.add(ride('arrived'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('cancel-request-dialog')), findsNothing);
      expect(rides.answers, isEmpty);
    });

    testWidgets('a declined request is announced', (tester) async {
      final (_, rows, _) = await pump(tester);
      rows.add(ride('on_trip', askedBy: 'rider', reason: 'changed_plans'));
      await settle(tester);
      expect(find.text('Cancellation requested'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Request cancellation'), findsNothing);
      rows.add(ride('on_trip'));
      await settle(tester);
      expect(find.text('Your driver declined the cancellation. The ride continues.'), findsOneWidget);
    });

    testWidgets('the rider\'s position is shared while a driver is assigned, throttled', (tester) async {
      final (rides, rows, gps) = await pump(tester);
      rows.add(ride('open'));
      await settle(tester);
      gps.add(const LatLng(3.1, 101.6));
      await tester.pump();
      expect(rides.shared, isEmpty, reason: 'nobody to share with yet');

      rows.add(ride('accepted'));
      await settle(tester);
      gps.add(const LatLng(3.1, 101.6));
      gps.add(const LatLng(3.2, 101.7));
      await tester.pump();
      expect(rides.shared, [(3.1, 101.6)], reason: 'at most every 5 s');

      rows.add(ride('completed'));
      await settle(tester);
      expect(gps.hasListener, isFalse, reason: 'stops when the ride ends');
    });
  });
}
