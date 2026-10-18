// The search sheet's raise card and driver hint, the ride screen's driver
// card and title, the offer cards (order, difference, Accept read out),
// the drivers-viewing faces and the confirm step's AI mark: each in light
// and dark, on an iPhone 15 and on an iPhone SE at 1.3x text.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/driver_eta.dart';
import 'package:get_ride/src/core/raise_nudge.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/driver_card.dart';
import 'package:get_ride/src/features/ride/home_parts.dart' show HomeSearchPill, HomeRecentPlaces, homeRecentAtRest;
import 'package:get_ride/src/features/ride/home_screen.dart' show RouteBasisLine, routeAiExplainer;
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/features/ride/searching_parts.dart';

typedef Phone = ({String name, Size size, double scale});

const phones = <Phone>[
  (name: 'iPhone 15', size: Size(393, 852), scale: 1.0),
  (name: 'iPhone SE @1.3', size: Size(375, 667), scale: 1.3),
];

Future<void> host(WidgetTester tester, Phone phone, Brightness b, Widget child, {List overrides = const []}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = phone.size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...overrides.cast()],
      child: MaterialApp(
        theme: appTheme(b),
        home: MediaQuery(
          data: MediaQueryData(size: phone.size, textScaler: TextScaler.linear(phone.scale)),
          child: Scaffold(
            body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Every combination of theme and phone, as a test of its own.
void matrix(String what, Future<void> Function(WidgetTester, Phone, Brightness) body) {
  for (final b in Brightness.values) {
    for (final p in phones) {
      testWidgets('$what (${b.name}, ${p.name})', (tester) => body(tester, p, b));
    }
  }
}

RideRequest accepted({double? liveLat, double? liveLng, String? plate = 'WXY 1234'}) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'status': 'accepted',
  'partner_id': 'd1',
  'partner_name': 'Ravi Kumar',
  'partner_plate': plate,
  'partner_vehicle': 'White Perodua Myvi',
  'partner_rating': 4.8,
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'partner_live_lat': liveLat,
  'partner_live_lng': liveLng,
  'drop_name': 'KL Sentral',
});

void main() {
  group('raise card rules', () {
    test('the admin setting decides when, 45 s without it, clamped', () {
      expect(raiseNudgeAfter(null), const Duration(seconds: 45));
      expect(raiseNudgeAfter({raiseNudgeKey: 90}), const Duration(seconds: 90));
      expect(raiseNudgeAfter({raiseNudgeKey: '30'}), const Duration(seconds: 30));
      expect(raiseNudgeAfter({raiseNudgeKey: 2}), const Duration(seconds: raiseNudgeMinSeconds));
      expect(raiseNudgeAfter({raiseNudgeKey: 9999}), const Duration(seconds: raiseNudgeMaxSeconds));
      expect(raiseNudgeAfter({raiseNudgeKey: 'x'}), raiseNudgeDefault);
    });

    test('only on a request open to offers, with none on screen, once the wait is up', () {
      const after = Duration(seconds: 45);
      expect(showRaiseNudge(bidding: true, offerStanding: false, waited: after, after: after), isTrue);
      expect(showRaiseNudge(bidding: true, offerStanding: false, waited: const Duration(seconds: 44), after: after), isFalse);
      expect(showRaiseNudge(bidding: false, offerStanding: false, waited: after, after: after), isFalse);
      expect(showRaiseNudge(bidding: true, offerStanding: true, waited: after, after: after), isFalse);
    });

    test('the wait hint comes from the nearest drivers, or not at all', () {
      expect(searchWaitHint(const {}), isNull);
      expect(searchWaitHint(const {'car': 0.8}, service: 'Car'), 'Nearest driver about ${driverEtaMinutes(0.8)} min away');
      // Its own type first, else the nearest of any.
      expect(searchWaitHint(const {'car': 0.8, 'bike': 3.0}, service: 'bike'), contains('${driverEtaMinutes(3.0)} min'));
      expect(searchWaitHint(const {'car': 0.8}, service: 'Van'), contains('${driverEtaMinutes(0.8)} min'));
      expect(searchWaitHint(const {'': 9.5}), 'Few drivers nearby');
    });
  });

  group('raise card and header', () {
    matrix('the raise card fits, its keys 48 high, and raises or waits', (tester, phone, b) async {
      var raised = 0, waited = 0;
      await host(
        tester,
        phone,
        b,
        Column(children: [
          const SearchHeader(
            elapsed: Duration(seconds: 50),
            left: '6:10',
            progress: 0.8,
            waitHint: 'Nearest driver about 3 min away',
          ),
          SearchRaiseCard(
            fare: 'RM20.00',
            raisedTo: 'RM25.00',
            onRaise: () => raised++,
            onKeepWaiting: () => waited++,
          ),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Raise your fare and search again'), findsOneWidget);
      expect(find.textContaining('RM20.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-wait-hint')), findsOneWidget);
      for (final k in ['search-raise-now', 'search-keep-waiting']) {
        expect(tester.getSize(find.byKey(ValueKey(k))).height, greaterThanOrEqualTo(48));
      }
      for (final k in ['search-raise-now', 'search-keep-waiting']) {
        await tester.ensureVisible(find.byKey(ValueKey(k)));
        await tester.pump();
        await tester.tap(find.byKey(ValueKey(k)));
      }
      expect((raised, waited), (1, 1));
    });

    testWidgets('at the highest fare it says so and offers only Keep waiting', (tester) async {
      await host(
        tester,
        phones.first,
        Brightness.light,
        SearchRaiseCard(fare: 'RM80.00', raisedTo: null, onRaise: () {}, onKeepWaiting: () {}),
      );
      expect(find.byKey(const ValueKey('search-raise-now')), findsNothing);
      expect(find.byKey(const ValueKey('search-keep-waiting')), findsOneWidget);
      expect(find.textContaining('as high as it can go'), findsOneWidget);
    });

    testWidgets('no hint without data', (tester) async {
      await host(
        tester,
        phones.first,
        Brightness.light,
        const SearchHeader(elapsed: Duration.zero, left: '7:00', progress: 1),
      );
      expect(find.byKey(const ValueKey('search-wait-hint')), findsNothing);
    });
  });

  group('driver card', () {
    test('the minutes go in the title only when known', () {
      expect(withEta('Driver on the way', 4), 'Driver on the way · 4 min');
      expect(withEta('Driver on the way', null), 'Driver on the way');
      expect(approachMinutes(driverLat: null, driverLng: 1, pickupLat: 1, pickupLng: 1), isNull);
      // About 2 km away at town speed: 5 minutes.
      expect(approachMinutes(driverLat: 3.1579, driverLng: 101.7296, pickupLat: 3.1579, pickupLng: 101.7116), 5);
    });

    matrix('plate first in its own box, the car under it, then the driver', (tester, phone, b) async {
      final r = accepted(liveLat: 3.1579, liveLng: 101.7296);
      await host(
        tester,
        phone,
        b,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          RideStatusTitle(ride: r),
          Card(child: DriverCardHeader(ride: r)),
        ]),
        overrides: [rideStreamProvider.overrideWith((ref, id) => Stream.value(r))],
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Driver on the way · 5 min'), findsOneWidget);
      final plate = find.byKey(const ValueKey('driver-plate'));
      final vehicle = find.byKey(const ValueKey('driver-vehicle'));
      final name = find.byKey(const ValueKey('driver-name'));
      expect(find.descendant(of: plate, matching: find.text('WXY 1234')), findsOneWidget);
      expect(tester.getRect(plate).bottom, lessThanOrEqualTo(tester.getRect(vehicle).top));
      expect(tester.getRect(vehicle).bottom, lessThanOrEqualTo(tester.getRect(name).top));
      expect(find.byKey(const ValueKey('driver-photo')), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-rating')), findsOneWidget);
      // The plate is the largest text on the card.
      final plateText = tester.widget<Text>(find.descendant(of: plate, matching: find.byType(Text)));
      expect(plateText.style!.fontSize, Theme.of(tester.element(plate)).textTheme.titleLarge!.fontSize);
      final box = tester.widget<Container>(plate).decoration! as BoxDecoration;
      expect(box.border, isNotNull, reason: 'a bordered box');
    });

    testWidgets('without a position the title is the status alone', (tester) async {
      final r = accepted();
      await host(
        tester,
        phones.first,
        Brightness.light,
        RideStatusTitle(ride: r),
        overrides: [rideStreamProvider.overrideWith((ref, id) => Stream.value(r))],
      );
      expect(find.text('Driver on the way'), findsOneWidget);
    });

    testWidgets('the title follows the driver as they come', (tester) async {
      final rows = [accepted(liveLat: 3.1579, liveLng: 101.7296), accepted(liveLat: 3.1579, liveLng: 101.7126)];
      await host(
        tester,
        phones.first,
        Brightness.dark,
        RideStatusTitle(ride: rows.first),
        overrides: [rideStreamProvider.overrideWith((ref, id) => Stream.fromIterable(rows))],
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Driver on the way · 1 min'), findsOneWidget);
    });
  });

  group('ride screen with a driver on the way', () {
    matrix('the card, Call and Message fit, labelled and 44 high', (tester, phone, b) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = phone.size;
      tester.platformDispatcher.textScaleFactorTestValue = phone.scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final r = RideRequest({
        ...accepted(liveLat: 3.1579, liveLng: 101.7296).raw,
        'partner_phone': '+60123456789',
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_NoRides()),
            rideStreamProvider.overrideWith((ref, id) => Stream.value(r)),
            riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
          ],
          child: MaterialApp(theme: appTheme(b), home: const RideTrackingScreen(requestId: 'r1')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('Driver on the way · 5 min'), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-plate')), findsOneWidget);
      for (final k in ['ride-call', 'ride-message']) {
        final button = find.byKey(ValueKey(k));
        if (button.evaluate().isEmpty) continue;
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44), reason: k);
      }
      expect(find.text('Call'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('offer cards', () {
    SearchOfferView offer(String key, double amount, {int? eta, String? diff, bool yours = false}) => SearchOfferView(
      key: key,
      amount: amount,
      price: 'RM${amount.toStringAsFixed(2)}',
      difference: diff,
      yourFare: yours,
      progress: 0.5,
      secondsLeft: 8,
      name: 'Driver $key',
      etaMin: eta,
      cardKey: ValueKey('card-$key'),
      acceptKey: ValueKey('accept-$key'),
      declineKey: ValueKey('decline-$key'),
      onAccept: () {},
      onDecline: () {},
    );

    test('cheapest first, then nearest; ties keep the order they came in', () {
      final sorted = sortOffers([
        offer('a', 12, eta: 3),
        offer('b', 11, eta: 9),
        offer('c', 12, eta: 2),
        offer('d', 11, eta: 9),
      ]);
      expect(sorted.map((o) => o.key), ['b', 'd', 'c', 'a']);
    });

    test('Accept is read out with the price, the driver and the time left', () {
      expect(offerAcceptLabel(offer('Mellier', 11)), 'Accept RM11.00 from Driver Mellier, 8 seconds left');
    });

    testWidgets('a new offer goes in at its place by price; the others stay put', (tester) async {
      Widget stack(List<SearchOfferView> o) =>
          MaterialApp(home: Scaffold(body: SingleChildScrollView(child: OfferStack(offers: sortOffers(o)))));
      await tester.pumpWidget(stack([offer('a', 12), offer('b', 14)]));
      await tester.pumpAndSettle();
      await tester.pumpWidget(stack([offer('a', 12), offer('b', 14), offer('c', 13)]));
      await tester.pumpAndSettle();
      double y(String k) => tester.getTopLeft(find.byKey(ValueKey('card-$k'))).dy;
      expect(y('a'), lessThan(y('c')));
      expect(y('c'), lessThan(y('b')));
    });

    matrix('the difference from the fare shows, and Accept is its own labelled button', (tester, phone, b) async {
      final semantics = tester.ensureSemantics();
      await host(
        tester,
        phone,
        b,
        Column(children: [
          SearchOfferCard(offer: offer('x', 21, eta: 4, diff: '+RM1.00')),
          SearchOfferCard(offer: offer('y', 20, yours: true)),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('offer-difference-x')), findsOneWidget);
      expect(find.text('+RM1.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-difference-y')), findsNothing);
      expect(find.text('Your fare'), findsOneWidget);
      final accept = tester.getSemantics(find.byKey(const ValueKey('accept-x')));
      expect(accept.label, 'Accept RM21.00 from Driver x, 8 seconds left');
      expect(accept.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(find.bySemanticsLabel('Decline'), findsNWidgets(2), reason: 'Decline stays its own button');
      expect(tester.getSize(find.byKey(const ValueKey('accept-x'))).height, greaterThanOrEqualTo(44));
      semantics.dispose();
    });
  });

  group('drivers viewing', () {
    for (final n in [1, 2, 3, 4, 6]) {
      testWidgets('$n viewing: as many faces as that, never more than four, the rest as +N', (tester) async {
        await host(
          tester,
          phones.first,
          Brightness.light,
          DriversViewingBar(
            viewers: RequestViewers(viewed: n, viewing: n),
            demo: true,
            demoNames: const ['Aiman', 'Farid', 'Kumar', 'Lee'],
          ),
        );
        final faces = find.descendant(of: find.byKey(const ValueKey('drivers-viewing')), matching: find.byType(CircleAvatar));
        expect(faces, findsNWidgets(n > 4 ? 4 : n));
        expect(find.text('+${n - 4}'), n > 4 ? findsOneWidget : findsNothing);
      });
    }
  });

  group('home sheet parts', () {
    matrix('the search bar and two recent places fit and answer taps', (tester, phone, b) async {
      var searched = 0;
      Place? picked;
      const places = [
        Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.93, 101.83)),
        Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(2.94, 101.84)),
      ];
      await host(
        tester,
        phone,
        b,
        Column(children: [
          HomeSearchPill(onTap: () => searched++),
          HomeRecentPlaces(places: places.take(homeRecentAtRest).toList(), onTap: (p) => picked = p),
        ]),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('home-search')));
      await tester.tap(find.byKey(const ValueKey('home-recent-KLCC')));
      expect(searched, 1);
      expect(picked?.name, 'KLCC');
      expect(tester.getSize(find.byKey(const ValueKey('home-search'))).height, greaterThanOrEqualTo(44));
    });
  });

  group('the AI mark', () {
    matrix('explains itself on a tap and to screen readers', (tester, phone, b) async {
      final semantics = tester.ensureSemantics();
      await host(
        tester,
        phone,
        b,
        const RouteBasisLine(
          route: RouteInfo(distanceKm: 8.6, durationMin: 16, points: []),
          ai: RouteEstimate(distanceKm: 9.1, durationMin: 6),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel(RegExp('^AI estimate\\. Fare and travel time')), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      final chip = find.byKey(const ValueKey('route-ai'));
      expect(tester.getSize(find.ancestor(of: chip, matching: find.byType(ConstrainedBox)).first).height,
          greaterThanOrEqualTo(44));
      await tester.tap(chip);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(routeAiExplainer), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      semantics.dispose();
    });
  });
}

class _NoRides implements RideRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
