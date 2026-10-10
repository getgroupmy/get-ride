import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/core/search_timer.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/auto_accept.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

final t0 = DateTime.utc(2026, 10, 6, 9);

RideRequest open({Duration age = Duration.zero, double fare = 20, Map<String, dynamic> extra = const {}}) =>
    RideRequest({
      'id': 'r1',
      'rider_id': 'me',
      'status': 'open',
      'fare': fare,
      'currency': 'MYR',
      'pickup_name': 'KLCC',
      'drop_name': 'KL Sentral',
      'offer_me': true,
      'created_at': t0.subtract(age).toIso8601String(),
      ...extra,
    });

class _FakeRides implements RideRepository {
  final raises = <double>[];
  final accepted = <String>[];

  @override
  Future<RideRequest?> acceptOffer(String requestId, {required String partnerId, required double amount}) async {
    accepted.add('$partnerId:$amount');
    return null;
  }
  int expired = 0;

  @override
  Future<void> expireStaleOpen() async => expired++;

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('rules', () {
    test('elapsed never runs negative', () {
      expect(searchElapsed(t0.add(const Duration(seconds: 5)), t0), Duration.zero);
      expect(searchElapsed(t0, t0.add(const Duration(seconds: 90))), const Duration(seconds: 90));
      expect(searchElapsed(null, t0), Duration.zero);
    });

    test('the first-minute bar empties over 60 s', () {
      expect(searchPhaseProgress(Duration.zero), 1);
      expect(searchPhaseProgress(const Duration(seconds: 30)), 0.5);
      expect(searchPhaseProgress(const Duration(seconds: 90)), 0);
    });

    test('the raise prompt comes once, after a minute, with no offer standing', () {
      const min = Duration(seconds: 60);
      expect(shouldPromptRaise(elapsed: min, offerStanding: false, alreadyAsked: false), isTrue);
      expect(
        shouldPromptRaise(elapsed: const Duration(seconds: 59), offerStanding: false, alreadyAsked: false),
        isFalse,
      );
      expect(shouldPromptRaise(elapsed: min, offerStanding: true, alreadyAsked: false), isFalse);
      expect(shouldPromptRaise(elapsed: min, offerStanding: false, alreadyAsked: true), isFalse);
    });

    test('countdowns read m:ss and never 0:00 with time left', () {
      expect(formatCountdown(const Duration(minutes: 6, seconds: 5)), '6:05');
      expect(formatCountdown(const Duration(milliseconds: 300)), '0:01');
      expect(formatCountdown(Duration.zero), '0:00');
      expect(searchTimeLeft(const Duration(minutes: 8), const Duration(minutes: 7)), Duration.zero);
    });

    test('an offer stands for its window', () {
      const w = Duration(seconds: 45);
      expect(offerProgress(Duration.zero, w), 1);
      expect(offerLapsed(const Duration(seconds: 44), w), isFalse);
      expect(offerLapsed(w, w), isTrue);
      expect(offerProgress(const Duration(seconds: 50), w), 0);
    });
  });

  group('screen', () {
    late DateTime now;
    late StreamController<RideRequest> rows;
    late _FakeRides rides;

    Future<void> pump(WidgetTester tester, {Map<String, double> autoAccept = const {}}) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      now = t0;
      rides = _FakeRides();
      rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      final router = GoRouter(
        initialLocation: '/ride',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: '/ride',
            builder: (_, _) => const RideTrackingScreen(requestId: 'r1'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            searchClockProvider.overrideWithValue(() => now),
            riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
            fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
            walletBalancesProvider.overrideWith((ref) async => const []),
            walletTxProvider.overrideWith((ref) async => const []),
            autoAcceptProvider.overrideWith(() => _Preset(autoAccept)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
    }

    Future<void> tick(WidgetTester tester, Duration by) async {
      now = now.add(by);
      await tester.pump(by);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('shows the time left and the first-minute bar', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 10)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.text('6:49'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-progress')), findsOneWidget);
    });

    testWidgets('after a minute with no offer the rider is asked once to raise', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 58)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.text('No driver yet'), findsNothing);
      await tick(tester, const Duration(seconds: 2));
      expect(find.text('No driver yet'), findsOneWidget);
      expect(find.text('Raise fare to RM25.00'), findsOneWidget);
      await tester.tap(find.text('Keep my fare'));
      await tick(tester, const Duration(seconds: 1));
      await tick(tester, const Duration(seconds: 5));
      expect(find.text('No driver yet'), findsNothing, reason: 'asked once per screen');
    });

    testWidgets('a fixed-fare request has nothing to raise, confirm or auto-accept, and is never asked to raise',
        (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 58), extra: const {'offer_me': false}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-fare')), findsNothing);
      expect(find.byKey(const ValueKey('search-fare-confirm')), findsNothing);
      expect(find.textContaining('Confirm'), findsNothing);
      expect(find.byKey(const ValueKey('search-auto-accept')), findsNothing);
      expect(find.textContaining('Auto-accept'), findsNothing);
      await tick(tester, const Duration(seconds: 2));
      await tick(tester, const Duration(seconds: 5));
      expect(find.text('No driver yet'), findsNothing);
      expect(find.textContaining('Raise fare'), findsNothing);
      // Its headline never talks about offering a price or choosing a driver.
      for (var i = 0; i < 4; i++) {
        expect(find.text('Offering your fare'), findsNothing);
        expect(find.text('Waiting for responses'), findsNothing);
        await tick(tester, const Duration(seconds: 5));
      }
      expect(find.byKey(const ValueKey('cancel-request')), findsOneWidget);
    });

    testWidgets('a request open to offers keeps its stepper and auto-accept', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 10)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-fare')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-auto-accept')), findsOneWidget);
    });

    testWidgets('a standing offer holds off the prompt and counts down its 45 s', (tester) async {
      await pump(tester);
      rows.add(
        open(age: const Duration(seconds: 50), extra: {'offered_fare': 24, 'partner_id': 'p1', 'partner_name': 'Ali'}),
      );
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.text('Ali'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-countdown-p1:24.00')), findsOneWidget);
      await tick(tester, const Duration(seconds: 20));
      expect(find.text('No driver yet'), findsNothing);
      expect(find.text('Ali'), findsOneWidget);
      await tick(tester, const Duration(seconds: 26));
      expect(find.text('Ali'), findsNothing, reason: 'its 45 s are up');
    });

    testWidgets('booked with auto-accept, an offer at the fare is taken; a higher one asks', (tester) async {
      await pump(tester, autoAccept: {'r1': 20});
      rows.add(open(extra: {'offered_fare': 26, 'partner_id': 'p1', 'partner_name': 'Ali'}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(rides.accepted, isEmpty, reason: 'over the auto-accept amount');
      expect(find.text('Ali'), findsOneWidget);

      rows.add(open(extra: {'offered_fare': 20, 'partner_id': 'p2', 'partner_name': 'Bala'}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(rides.accepted, ['p2:20.0']);
    });

    testWidgets('at 7 minutes the request expires and says so', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(minutes: 6, seconds: 59)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 2));
      expect(find.text('Request expired'), findsOneWidget);
      expect(rides.expired, 1);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    });
  });

  test('offers carry the driver photo', () {
    final o = standingOffer(open(extra: {'offered_fare': 24, 'partner_id': 'p1', 'partner_photo': 'https://x/p.png'}));
    expect(o?.photo, 'https://x/p.png');
  });
}

class _Preset extends AutoAcceptRides {
  _Preset(this.preset);
  final Map<String, double> preset;

  @override
  Map<String, double> build() => preset;
}
