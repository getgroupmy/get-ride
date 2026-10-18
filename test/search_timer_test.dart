import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/core/search_timer.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/data/app_display_repository.dart' show displaySettingsBlobProvider;
import 'package:get_ride/src/features/ride/auto_accept.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart' show demoSettingsProvider;
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart' show SearchRouteCard;
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

  final cancelled = <String>[];
  Map<String, double> nearby = const {};

  @override
  Future<Map<String, double>> nearbyDrivers(double lat, double lng) async => nearby;

  @override
  Future<void> cancel(RideRequest r, {String? reason, required String by}) async => cancelled.add('$reason');

  @override
  Future<RideRequest?> raiseFare(String id, double fare) async {
    raises.add(fare);
    return open(fare: fare);
  }

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

    Future<void> pump(
      WidgetTester tester, {
      Map<String, double> autoAccept = const {},
      Map<String, dynamic> display = const {},
      Map<String, double> nearby = const {},
      bool demoOffers = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      now = t0;
      rides = _FakeRides()..nearby = nearby;
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
            displaySettingsBlobProvider.overrideWith((ref) async => display),
            demoSettingsProvider.overrideWithValue(DemoSettings(riderOffers: demoOffers)),
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

    for (final (size, bottom) in const [(Size(393, 852), 34.0), (Size(360, 640), 0.0)]) {
      testWidgets('scrolled to its end, the route card clears the pinned Cancel request (${size.width.toInt()}x${size.height.toInt()})', (tester) async {
        await pump(tester);
        tester.view.physicalSize = size;
        tester.view.padding = FakeViewPadding(top: 47, bottom: bottom);
        tester.view.viewPadding = FakeViewPadding(top: 47, bottom: bottom);
        rows.add(open(age: const Duration(seconds: 10), extra: const {'stops': [
          {'name': 'Mid Valley', 'address': 'Mid Valley', 'lat': 3.11, 'lng': 101.67},
        ]}));
        await tester.pump();
        await tick(tester, const Duration(seconds: 1));
        // All the way up, then the content all the way down.
        await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -1200));
        await tick(tester, const Duration(seconds: 1));
        final sheet = find.byKey(const ValueKey('map-sheet'));
        final scroll = tester.state<ScrollableState>(find.descendant(of: sheet, matching: find.byType(Scrollable)).first);
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tick(tester, const Duration(seconds: 1));
        final card = tester.getRect(find.byType(SearchRouteCard));
        final footer = tester.getRect(find.byKey(const ValueKey('ride-cancel-footer')));
        expect(card.bottom, lessThanOrEqualTo(footer.top), reason: 'its last row above the band, not under it');
      });
    }

    testWidgets('shows the time left and the first-minute bar', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 10)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.text('6:49'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-progress')), findsOneWidget);
    });

    testWidgets('after 45 s with no offer the sheet offers a raise; Keep waiting puts it off', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 43)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-raise-card')), findsNothing);
      await tick(tester, const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('search-raise-card')), findsOneWidget);
      expect(find.text('Raise to RM25.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-keep-waiting')));
      await tick(tester, const Duration(seconds: 1));
      await tick(tester, const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('search-raise-card')), findsNothing, reason: 'put off');
      await tick(tester, const Duration(seconds: 40));
      expect(find.byKey(const ValueKey('search-raise-card')), findsOneWidget, reason: 'after another wait');
      expect(rides.raises, isEmpty);
    });

    testWidgets('Raise in one tap raises by the usual step and searches again', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 50)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('search-raise-now')));
      await tick(tester, const Duration(seconds: 1));
      expect(rides.raises, [25.0]);
      expect(find.textContaining('You raised the fare to RM25.00'), findsOneWidget);
      rows.add(open(age: const Duration(seconds: 52), fare: 25));
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-raise-card')), findsNothing, reason: 'the wait starts over');
    });

    testWidgets("the admin's setting moves when the raise is offered", (tester) async {
      await pump(tester, display: {'raiseFareAfterSeconds': 90});
      rows.add(open(age: const Duration(seconds: 60)));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-raise-card')), findsNothing);
      await tick(tester, const Duration(seconds: 30));
      expect(find.byKey(const ValueKey('search-raise-card')), findsOneWidget);
    });

    testWidgets('the wait hint comes from the drivers near the pickup, and only then', (tester) async {
      await pump(tester, nearby: const {'car': 1.0});
      rows.add(open(age: const Duration(seconds: 5), extra: const {'pickup_lat': 3.15, 'pickup_lng': 101.71, 'service': 'Car'}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.text('Nearest driver about 3 min away'), findsOneWidget);
    });

    testWidgets('no hint when nothing is known about nearby drivers', (tester) async {
      await pump(tester);
      rows.add(open(age: const Duration(seconds: 5), extra: const {'pickup_lat': 3.15, 'pickup_lng': 101.71}));
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-wait-hint')), findsNothing);
    });

    testWidgets('mock driver offers never join a real request, which is never cancelled for one', (tester) async {
      await pump(tester, demoOffers: true);
      rows.add(open(age: const Duration(seconds: 1), extra: const {'pickup_lat': 3.15, 'pickup_lng': 101.71, 'drop_lat': 3.13, 'drop_lng': 101.68}));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tick(tester, const Duration(seconds: 1));
      }
      expect(find.text('DEMO'), findsNothing);
      expect(find.byKey(const ValueKey('demo-viewers')), findsNothing);
      expect(rides.cancelled, isEmpty);
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
      expect(find.byKey(const ValueKey('search-raise-card')), findsNothing);
      expect(find.textContaining('Raise'), findsNothing);
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
      expect(find.byKey(const ValueKey('search-raise-card')), findsNothing);
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

  test('requestJustExpired: only an open request that runs out', () {
    expect(requestJustExpired('open', 'expired'), isTrue);
    expect(requestJustExpired('expired', 'expired'), isFalse);
    expect(requestJustExpired('open', 'cancelled'), isFalse);
    expect(requestJustExpired('accepted', 'expired'), isFalse);
    expect(requestJustExpired(null, 'expired'), isFalse);
  });
}

class _Preset extends AutoAcceptRides {
  _Preset(this.preset);
  final Map<String, double> preset;

  @override
  Map<String, double> build() => preset;
}
