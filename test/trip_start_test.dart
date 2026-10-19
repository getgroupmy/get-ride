// Starting a trip (Phase D0, migration 0152): the driver enters the
// passenger's code and the server checks it; the passenger reads the code
// from ride_trip_codes (lib/src/core/trip_start.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/trip_start.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_chat_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rides implements RideRepository {
  _Rides(this.replies);
  final List<TripStartOutcome> replies;
  final starts = <(String, String)>[];

  @override
  Future<TripStartOutcome> startTrip(String id, String code) async {
    starts.add((id, code));
    return replies.removeAt(0);
  }

  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}
  @override
  Future<void> publishRiderLocation(String id, double lat, double lng) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

RideRequest _ride(String status, {String? otp}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'driver',
  'rider_name': 'Aina',
  'partner_name': 'Ravi',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'otp': otp,
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.134,
  'drop_lng': 101.686,
});

void main() {
  test('the server\'s answer becomes what the driver is told', () {
    expect(tripStartOutcome('on_trip'), isA<TripStarted>());
    expect(tripStartOutcome(null), isA<TripStarted>(), reason: 'an old database answers nothing');
    expect(tripStartOutcome('wrong_code'), isA<TripWrongCode>());
    final wait = tripStartOutcome('rate_limited:125') as TripTooManyTries;
    expect(wait.wait, const Duration(seconds: 125));
    expect(tripStartMessage(wait), contains('3 min'));
    expect(tripStartMessage(const TripWrongCode()), contains('not correct'));
    expect(tripStartMessage(const TripStarted()), isNull);
    expect((tripStartOutcome('rate_limited:x') as TripTooManyTries).wait, const Duration(minutes: 10));
  });

  test('only four digits are sent', () {
    expect(cleanTripCode(' 12 34 '), '1234');
    expect(cleanTripCode('123'), isNull);
    expect(cleanTripCode('12a4'), isNull);
    expect(cleanTripCode(null), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the driver\'s code goes to the server, which decides (${brightness.name})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _Rides([const TripWrongCode(), const TripStarted()]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideMessagesProvider.overrideWith((ref, id) => Stream.value(const <RideMessage>[])),
            // The driver's copy of the ride no longer carries the code.
            rideStreamProvider.overrideWith((ref, id) => Stream.value(_ride('arrived'))),
            tripFixProvider.overrideWithValue(() async => null),
            currentUserIdProvider.overrideWithValue('driver'),
          ],
          child: MaterialApp(
            theme: appTheme(brightness),
            home: const PartnerTripScreen(requestId: 'r1'),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      final dialog = find.byKey(const ValueKey('trip-code-dialog'));
      FilledButton startButton() => tester.widget<FilledButton>(find.byKey(const ValueKey('trip-code-start')));
      Future<void> type(String code) async {
        await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), code);
        await settle();
      }

      await tester.tap(find.widgetWithText(FilledButton, 'Start trip').first);
      await settle();
      expect(dialog, findsOneWidget);
      // Start only once four digits are in (web tester #124).
      await type('12');
      expect(startButton().onPressed, isNull);
      expect(rides.starts, isEmpty, reason: 'nothing is sent that can\'t be a code');

      // A wrong code is said in the dialog, which stays open.
      await type('1111');
      await tester.tap(find.byKey(const ValueKey('trip-code-start')));
      await settle();
      expect(rides.starts.single, ('r1', '1111'));
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.textContaining('not correct')), findsOneWidget);

      // Retyped in place; the right one starts the trip and the screen moves
      // on at once, before realtime brings the row back (#125).
      await type('4821');
      expect(find.textContaining('not correct'), findsNothing, reason: 'cleared as the driver types');
      await tester.tap(find.byKey(const ValueKey('trip-code-start')));
      await settle();
      expect(rides.starts.last, ('r1', '4821'));
      expect(dialog, findsNothing);
      expect(find.byKey(const ValueKey('trip-complete')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the passenger sees the code from the server (${brightness.name})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_Rides([])),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            tripCodeProvider.overrideWith((ref, id) async => '9090'),
            riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
            fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
            walletBalancesProvider.overrideWith((ref) async => const []),
            walletTxProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            theme: appTheme(brightness),
            home: const RideTrackingScreen(requestId: 'r1'),
          ),
        ),
      );
      rows.add(_ride('accepted'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('trip-code')), findsOneWidget);
      expect(find.text('9090'), findsOneWidget);

      rows.add(_ride('on_trip'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('trip-code')), findsNothing, reason: 'gone once the trip is on');
    });
  }
}
