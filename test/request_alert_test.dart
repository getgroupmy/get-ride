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
import 'package:get_ride/src/features/ride/confirm_parts.dart' show accentFill;
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

class _FakeRides implements RideRepository {
  final accepted = <String>[];
  final offers = <double>[];

  /// What an offer write answers: null (no longer open), the row still open
  /// with the bid on it, or taken at once (the rider auto-accepts).
  String? offerAnswer;
  final rows = StreamController<RideRequest>.broadcast();

  @override
  Future<RideRequest?> submitOffer(
    String id,
    double amount,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    offers.add(amount);
    if (offerAnswer == null) return null;
    return RideRequest({..._req(id).raw, 'status': offerAnswer, 'partner_id': 'p1', 'offered_fare': amount});
  }

  @override
  Stream<RideRequest> watch(String id) => rows.stream;

  @override
  Future<void> withdrawOffer(String id) async {}

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
    late GoRouter router;
    late StreamController<LatLng> gps;

    setUp(() {
      gps = StreamController<LatLng>.broadcast();
      open = StreamController<List<RideRequest>>.broadcast();
      rides = _FakeRides();
      now = DateTime(2026, 10, 6, 11);
    });
    tearDown(() {
      gps.close();
      open.close();
      rides.rows.close();
    });

    Future<void> pump(WidgetTester tester, {Size size = const Size(700, 2000)}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      router = GoRouter(
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
            currentUserIdProvider.overrideWithValue('p1'),
            driverPositionStreamProvider.overrideWithValue(() => gps.stream),
            driverPositionProvider.overrideWithValue(() async => null),
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

    double countdown(WidgetTester tester) =>
        tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('request-alert-countdown'))).value!;

    testWidgets('the countdown and GPS fixes rebuild their own parts, not the drive screen', (tester) async {
      await pump(tester, size: const Size(400, 860));
      gps.add(const LatLng(3.15, 101.71));
      await tester.pump();
      open.add([
        RideRequest({..._req('r1').raw, 'pickup_lat': 3.158, 'pickup_lng': 101.712}),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      var screens = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is PartnerScreen) screens++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      await wait(tester, const Duration(seconds: 10));
      expect(countdown(tester), closeTo(25 / 35, 0.01), reason: 'the countdown still runs');
      expect(screens, 0);
      await tester.tap(find.text('Skip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      screens = 0;
      String away() => tester.widget<Text>(find.textContaining('m away')).data!;
      final before = away();
      // ~100 m nearer: the card's distance follows, the screen does not rebuild.
      gps.add(const LatLng(3.151, 101.71));
      await tester.pump();
      await tester.pump();
      expect(screens, 0);
      expect(away(), isNot(before));
      debugOnRebuildDirtyWidget = null;
    });

    testWidgets("on a phone a new request comes up from the bottom as inDrive's sheet", (tester) async {
      await pump(tester);
      open.add([
        RideRequest({
          ..._req('r1').raw,
          'pickup_lat': 3.158,
          'pickup_lng': 101.712,
          'drop_lat': 3.134,
          'drop_lng': 101.686,
        }),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the sheet slides up
      final sheet = find.byKey(const ValueKey('request-alert'));
      expect(sheet, findsOneWidget);
      expect(tester.getBottomLeft(sheet).dy, 2000, reason: 'standing on the bottom of the screen');
      expect(find.text('Ride request'), findsOneWidget);
      expect(find.text('Siti'), findsOneWidget);
      expect(find.text('4.80'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('request-fare'))).data, 'RM12.00');
      expect(find.text('KLCC (Jalan Ampang)'), findsOneWidget);
      expect(find.text('KL Sentral'), findsOneWidget);
      expect(find.textContaining('1 bag'), findsOneWidget);
      expect(find.text('Accept for RM12.00'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('request-chip-trip')), matching: find.text('14 min.\n5.0 km')),
        findsOneWidget,
        reason: "the trip's time and distance beside B",
      );
      // Each chip stands above its own pin, never over it.
      for (final (chip, pin) in const [('request-chip-trip', 'map-dot-drop')]) {
        final c = tester.getRect(find.byKey(ValueKey(chip)));
        final p = tester.getRect(find.byKey(ValueKey(pin)));
        expect(c.bottom, lessThanOrEqualTo(p.top), reason: '$chip above $pin');
        expect(c.center.dx, closeTo(p.center.dx, 1), reason: '$chip over $pin');
      }
      // The buttons in the app's accent (the rider's "Find a driver" blue).
      final accept = tester.widget<FilledButton>(
        find.descendant(of: find.byKey(const ValueKey('request-alert-accept')), matching: find.byType(FilledButton)),
      );
      expect(accept.style!.backgroundColor!.resolve({}), accentFill);
      expect(countdown(tester), 1);
      await wait(tester, const Duration(seconds: 10));
      expect(countdown(tester), closeTo(25 / 35, 0.01));
    });

    testWidgets('where the rider takes offers: three steps up and a pencil', (tester) async {
      await pump(tester);
      open.add([RideRequest({..._req('r1').raw, 'offer_me': true})]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Offer your fare'), findsOneWidget);
      expect(find.byKey(const ValueKey('request-offer-custom')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('request-offer-0')));
      await tester.pump();
      await tester.pump();
      expect(rides.offers, [14], reason: 'the first step up on RM12');
    });

    testWidgets('on a desktop screen it flies in over the map, and out when declined', (tester) async {
      await pump(tester, size: const Size(1600, 1000));
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      final overMap = find.descendant(
        of: find.byType(AnimatedSwitcher),
        matching: find.byKey(const ValueKey('request-alert')),
      );
      expect(overMap, findsOneWidget);
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget, reason: 'not in the queue as well');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getTopLeft(overMap).dx, greaterThan(520), reason: 'over the map, right of the panel');

      await tester.tap(find.byKey(const ValueKey('request-alert-decline')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget, reason: 'flying out');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      expect(rides.accepted, isEmpty);
    });

    testWidgets('accept sends the rider an offer at their fare and waits for them', (tester) async {
      rides.offerAnswer = 'open';
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pump();
      await tester.pump();
      expect(rides.offers, [12], reason: 'an offer at the fare asked');
      expect(rides.accepted, isEmpty, reason: 'not taken outright');
      expect(find.byKey(const ValueKey('offer-pending')), findsOneWidget);
      expect(find.text('You accepted RM12.00. Waiting for the passenger to confirm…'), findsOneWidget);

      // The rider says yes: the trip is this driver's.
      rides.rows.add(RideRequest({..._req('r1').raw, 'status': 'accepted', 'partner_id': 'p1'}));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('trip r1'), findsOneWidget);
    });

    testWidgets('a rider who auto-accepts takes it at once', (tester) async {
      rides.offerAnswer = 'accepted';
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pumpAndSettle();
      expect(rides.offers, [12]);
      expect(find.byKey(const ValueKey('offer-pending')), findsNothing);
      expect(find.text('trip r1'), findsOneWidget);
    });

    testWidgets('a fixed-fare request is offered too, never taken outright', (tester) async {
      rides.offerAnswer = 'open';
      await pump(tester);
      open.add([RideRequest({..._req('r1').raw, 'offer_me': false})]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pump();
      await tester.pump();
      expect(rides.offers, [12]);
      expect(rides.accepted, isEmpty);
      expect(find.byKey(const ValueKey('offer-pending')), findsOneWidget);
    });

    testWidgets('skip keeps it in the list; the next new request pops up', (tester) async {
      await pump(tester);
      open.add([_req('r1'), _req('r2', fare: 20)]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      expect(find.text('Accept for RM12.00'), findsOneWidget, reason: 'r1 in the sheet');
      expect(find.text('Accept RM20.00'), findsOneWidget, reason: 'r2 waits in the list');
      await tester.tap(find.byKey(const ValueKey('request-alert-decline')));
      await tester.pump();
      // The declined card flies out.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget);
      expect(find.text('Accept for RM12.00'), findsNothing, reason: 'r1 is out of the sheet');
      expect(find.text('Accept RM12.00'), findsOneWidget, reason: 'r1 is still on the list');
      expect(find.text('Accept for RM20.00'), findsOneWidget, reason: 'r2 comes up next');
    });

    testWidgets('left alone it drops back into the list after 35 s', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      await wait(tester, const Duration(seconds: 36));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      expect(find.text('Accept RM12.00'), findsOneWidget);
    });

    testWidgets('a request on the list, tapped, comes up in the request sheet again', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await wait(tester, const Duration(seconds: 36));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);

      // Its card, away from its buttons (the title row).
      await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('queue-open-r1'))) + const Offset(24, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget);
      expect(find.text('Accept for RM12.00'), findsOneWidget);
      expect(countdown(tester), 1, reason: 'a fresh countdown');

      // Skipped from there: back on the list, not popped up again.
      await tester.tap(find.text('Skip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      expect(find.byKey(const ValueKey('queue-open-r1')), findsOneWidget);
    });

    testWidgets('a request taken by someone else closes its alert', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      open.add(const []);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
    });

    testWidgets('a declined request pops back up when the passenger raises the fare', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      await tester.tap(find.byKey(const ValueKey('request-alert-decline')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // slides down
      expect(find.byKey(const ValueKey('request-alert')), findsNothing);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      expect(find.byKey(const ValueKey('request-alert')), findsNothing, reason: 'same fare does not pop up again');
      expect(find.text('Accept RM12.00'), findsOneWidget, reason: 'but it is still on the list');
      open.add([_req('r1', fare: 17)]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the cards fly in
      expect(find.byKey(const ValueKey('request-alert')), findsOneWidget);
      expect(find.text('The passenger raised the fare from RM12.00 to RM17.00.'), findsOneWidget);
      expect(countdown(tester), 1, reason: 'a fresh window');
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pumpAndSettle();
      expect(rides.offers, [17]);
    });
  
    testWidgets('a trip that ends brings the driver back online, not offline', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('You are online'), findsOneWidget);

      // Off to a trip (the Drive screen goes), then back to it when it ends.
      router.go('/drive/trip/t1');
      await tester.pumpAndSettle();
      expect(find.text('trip t1'), findsOneWidget);
      router.go('/');
      await tester.pump();
      open.add([_req('r1')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('You are online'), findsOneWidget, reason: 'still online');
      expect(find.text('Accept RM12.00'), findsOneWidget, reason: 'the queue is there');
      expect(find.byKey(const ValueKey('request-alert')), findsNothing, reason: 'nothing old pops up again');

      // A new request still pops up.
      open.add([_req('r1'), _req('r2', fare: 20)]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Accept for RM20.00'), findsOneWidget);
    });
});
}
