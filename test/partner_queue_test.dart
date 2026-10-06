import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_queue.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';

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

RideRequest _req(String id, {bool offerMe = false}) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Teksi',
  'fare': 12,
  'ride_fare': 12,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
  'offer_me': offerMe,
});

void main() {
  group('rules', () {
    test('auto-accept takes the nearest unseen request, unknown distances last', () {
      final open = <QueueItem>[
        (id: 'a', offerMe: false, awayKm: 3),
        (id: 'b', offerMe: false, awayKm: null),
        (id: 'c', offerMe: true, awayKm: 1),
      ];
      expect(autoAcceptPick(open, {}, busy: false), 'c');
      expect(autoAcceptPick(open, {'c'}, busy: false), 'a');
      expect(autoAcceptPick(open, {'a', 'c'}, busy: false), 'b');
      expect(autoAcceptPick(open, {'a', 'b', 'c'}, busy: false), isNull);
      expect(autoAcceptPick(open, {}, busy: true), isNull);
    });

    test('counter-offers need both the request and the partner to allow them', () {
      expect(canCounterOffer(requestOfferMe: true, allowOfferMe: true), isTrue);
      expect(canCounterOffer(requestOfferMe: true, allowOfferMe: false), isFalse);
      expect(canCounterOffer(requestOfferMe: false, allowOfferMe: true), isFalse);
    });
  });

  group('screen', () {
    late StreamController<List<RideRequest>> open;
    late _FakeRides rides;

    setUp(() {
      open = StreamController<List<RideRequest>>.broadcast();
      rides = _FakeRides();
    });
    tearDown(() => open.close());

    Future<void> pump(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1400);
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
            // These drivers have no vehicle; the vehicle check has its own test.
            partnerTypeEntriesProvider.overrideWith((ref) async => [
              (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
            ]),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('You are offline'));
      // The queue shows a spinner until its first event, so don't settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('auto-accept leaves queued requests and takes the next one', (tester) async {
      await pump(tester);
      open.add([_req('old')]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('queue-auto-accept')));
      await tester.pumpAndSettle();
      expect(rides.accepted, isEmpty);

      open.add([_req('old'), _req('new')]);
      await tester.pumpAndSettle();
      expect(rides.accepted, ['new']);
      expect(find.text('trip new'), findsOneWidget);
    });

    testWidgets('without auto-accept nothing is taken', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pumpAndSettle();
      expect(rides.accepted, isEmpty);
      expect(find.text('Accept RM12.00'), findsOneWidget);
    });

    testWidgets('turning OfferMe off hides the counter-offer button', (tester) async {
      await pump(tester);
      open.add([_req('bid', offerMe: true)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offer-bid')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-allow-offer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offer-bid')), findsNothing);
      expect(find.text('Accept RM12.00'), findsOneWidget);
    });
  });
}
