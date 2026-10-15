// Handing a trip over mid-way (migration 0199): the pure parts, where the
// notifications open, and the driver's, new partner's, passenger's and
// admin's cards (light and dark).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/trip_handover_card.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/trip_handover.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/trip_handover_repository.dart';
import 'package:get_ride/src/features/partner/trip_handover_panel.dart';
import 'package:get_ride/src/features/ride/rider_handover_card.dart';
import 'package:go_router/go_router.dart';

class _FakeRepo implements TripHandoverRepository {
  final calls = <String>[];

  @override
  Future<void> request(String rideId, {String? code, String? note}) async =>
      calls.add('request $rideId ${code ?? 'nearby'} ${note ?? '-'}');

  @override
  Future<void> riderAnswer(String handoverId, {required bool approve}) async => calls.add('rider $handoverId $approve');

  @override
  Future<void> accept(String handoverId) async => calls.add('accept $handoverId');

  @override
  Future<void> decline(String handoverId) async => calls.add('decline $handoverId');

  @override
  Future<void> boarded(String handoverId) async => calls.add('boarded $handoverId');

  @override
  Future<void> cancel(String handoverId) async => calls.add('cancel $handoverId');

  @override
  Future<TripHandoverConfig> saveConfig(TripHandoverConfig c) async {
    calls.add('save ${c.sharePercent} ${c.nearbyRadiusKm} ${c.answerMinutes} ${c.enabled}');
    return c;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _ride({String status = 'on_trip', Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'r1',
  'status': status,
  'rider_name': 'Siti',
  'partner_name': 'Chong',
  'currency': 'RM',
  ...extra,
});

TripHandover _h(TripHandoverStatus status, {bool incoming = false, bool nearby = false, String? to}) => TripHandover(
  id: 'h1',
  rideId: 'r1',
  status: status,
  incoming: incoming,
  nearby: nearby,
  fromName: 'Amin',
  toName: to,
  note: 'Car trouble',
  sharePercent: 10,
);

void main() {
  group('pure', () {
    test('the settings, from the server, and checked', () {
      final c = TripHandoverConfig.fromJson({
        'enabled': true,
        'sharePercent': 12.5,
        'nearbyRadiusKm': 3,
        'answerMinutes': 4,
      });
      expect(c, const TripHandoverConfig(sharePercent: 12.5, nearbyRadiusKm: 3, answerMinutes: 4));
      expect(TripHandoverConfig.fromJson(null), const TripHandoverConfig(), reason: 'defaults: on, 10%, 5 km, 5 min');
      expect(TripHandoverConfig.fromJson({'enabled': false}).enabled, isFalse);
      expect(TripHandoverConfig.fromJson(c.toJson()), c);
      expect(c.problem, isNull);
      expect(c.copyWith(sharePercent: 101).problem, contains('0 to 100'));
      expect(c.copyWith(nearbyRadiusKm: 0.2).problem, contains('km'));
      expect(c.copyWith(answerMinutes: 0).problem, contains('minutes'));
    });

    test('a handover, from the server row, as the driver reads it', () {
      final h = TripHandover.fromRow({
        'id': 'h1',
        'ride_id': 'r1',
        'status': 'offered',
        'mode': 'nearby',
        'incoming': false,
        'from_name': 'Amin',
        'to_name': null,
        'note': ' ',
        'answer_by': '2026-10-15T10:05:00Z',
        'share_percent': 10,
        'share_amount': null,
      });
      expect(h.status, TripHandoverStatus.offered);
      expect(h.status.open, isTrue);
      expect(h.nearby, isTrue);
      expect(h.note, isNull);
      expect(h.whoTakesOver, 'another driver nearby');
      expect(h.driverStatusLabel, contains('first to accept'));
      expect(h.shareLabel('RM'), "You'll get 10% of the trip's net earnings");
      final paid = TripHandover.fromRow({'id': 'h2', 'ride_id': 'r1', 'status': 'accepted', 'share_amount': 3.4});
      expect(paid.shareLabel('RM'), 'RM 3.40 added to your GET credit');
      expect(TripHandoverStatus.parse('declined_rider'), TripHandoverStatus.declinedRider);
      expect(TripHandoverStatus.parse('nonsense'), TripHandoverStatus.expired);
      expect(_h(TripHandoverStatus.offered, to: 'Chong').driverStatusLabel, 'Waiting for Chong to accept');
    });

    test('an offer, from the server row', () {
      final o = HandoverOffer.fromRow({
        'id': 'h1',
        'ride_id': 'r1',
        'from_name': 'Amin',
        'answer_by': '2026-10-15T10:05:00Z',
        'drop_address': 'KLIA',
        'fare': 42,
        'currency': 'RM',
        'share_percent': 12.5,
      });
      expect(o.title, 'Amin needs you to take over a trip');
      expect(o.terms, 'RM 42.00 fare · you collect it and pass 12.5% of the net to Amin');
    });

    test("the trip's handover: the open one, else the latest", () {
      final old = TripHandover(id: 'a', rideId: 'r1', status: TripHandoverStatus.declinedRider);
      final open = TripHandover(id: 'b', rideId: 'r1', status: TripHandoverStatus.awaitingRider);
      final other = TripHandover(id: 'c', rideId: 'r2', status: TripHandoverStatus.offered);
      expect(handoverForRide([old, open, other], 'r1')?.id, 'b');
      expect(handoverForRide([old, other], 'r1')?.id, 'a');
      expect(handoverForRide([other], 'r1'), isNull);
    });

    test('who is done, and who is meeting the car', () {
      expect(tripHandedAway(_h(TripHandoverStatus.accepted)), isTrue);
      expect(tripHandedAway(_h(TripHandoverStatus.accepted, incoming: true)), isFalse, reason: 'the new driver');
      expect(tripHandedAway(_h(TripHandoverStatus.offered)), isFalse);
      final meeting = _ride(extra: {'handed_over_at': '2026-10-15T10:00:00Z'});
      expect(meeting.handoverMeeting, isTrue);
      expect(tripHandoverMeeting(meeting, _h(TripHandoverStatus.accepted, incoming: true)), isTrue);
      final boarded = _ride(
        extra: {'handed_over_at': '2026-10-15T10:00:00Z', 'handover_boarded_at': '2026-10-15T10:06:00Z'},
      );
      expect(tripHandoverMeeting(boarded, _h(TripHandoverStatus.accepted, incoming: true)), isFalse);
    });

    test("a region's own share", () {
      expect(handoverShareProblem(''), isNull);
      expect(handoverShareProblem('15'), isNull);
      expect(handoverShareProblem('150'), isNotNull);
      expect(handoverShareProblem('ten'), isNotNull);
      final f = RegionForm(country: 'Malaysia', handoverShare: '15');
      expect(f.toValues()['handoverSharePercent'], 15);
      expect(RegionForm(country: 'Malaysia').toValues()['handoverSharePercent'], isNull, reason: 'blank clears it');
    });
  });

  test('where each notification opens', () {
    expect(pushRouteFor({'type': 'trip_handover_offer', 'role': 'partner'}), '/drive');
    expect(pushRouteFor({'type': 'trip_handover_taken', 'role': 'partner'}), '/drive');
    expect(pushRouteFor({'type': 'trip_handover_paid', 'role': 'partner'}), '/wallet');
    expect(pushRouteFor({'type': 'trip_handover_approval', 'request_id': 'r1'}), '/ride/r1');
    expect(pushRouteFor({'type': 'trip_handover_accepted', 'request_id': 'r1'}), '/ride/r1');
    expect(pushRouteFor({'type': 'trip_handover_accepted', 'role': 'partner'}), '/drive');
    expect(pushRouteFor({'type': 'trip_handover_declined', 'request_id': 'r1', 'role': 'partner'}), '/drive/trip/r1');
    expect(pushRouteFor({'type': 'trip_handover_expired', 'request_id': 'r1', 'role': 'partner'}), '/drive/trip/r1');
    expect(pushRouteFor({'type': 'trip_handover_withdrawn', 'request_id': 'r1'}), '/ride/r1');
  });

  Future<_FakeRepo> pump(
    WidgetTester tester,
    Widget child, {
    TripHandover? handover,
    List<HandoverOffer> offers = const [],
    TripHandoverConfig config = const TripHandoverConfig(),
    bool dark = false,
  }) async {
    final repo = _FakeRepo();
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final overrides = <Override>[
      tripHandoverRepositoryProvider.overrideWithValue(repo),
      tripHandoverConfigProvider.overrideWith((_) async => config),
      rideHandoversProvider.overrideWith((_, _) async => [?handover]),
      handoverOffersProvider.overrideWith((_) async => offers),
    ];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: SingleChildScrollView(child: child)),
        ),
        GoRoute(path: '/drive/trip/:id', builder: (_, st) => Text('trip ${st.pathParameters['id']}')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(theme: dark ? ThemeData.dark() : ThemeData.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    group('the driver ($mode)', () {
      testWidgets('asks partners nearby, with a reason', (tester) async {
        final repo = await pump(tester, TripHandoverPanel(ride: _ride()), dark: dark);
        await tester.tap(find.byKey(const ValueKey('trip-handover')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('handover-ask-sheet')), findsOneWidget);
        expect(find.textContaining('within 5 km'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('handover-note')), 'Car trouble');
        await tester.tap(find.byKey(const ValueKey('handover-nearby')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['request r1 nearby Car trouble']);
      });

      testWidgets('asks one partner by code', (tester) async {
        final repo = await pump(tester, TripHandoverPanel(ride: _ride()), dark: dark);
        await tester.tap(find.byKey(const ValueKey('trip-handover')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('handover-by-code')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('driver-code-field')), 'AB12CD34');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('driver-code-done')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['request r1 AB12CD34 -']);
      });

      testWidgets('no button before the trip starts, or with handover off', (tester) async {
        await pump(
          tester,
          TripHandoverPanel(ride: _ride(status: 'arrived')),
          dark: dark,
        );
        expect(find.byKey(const ValueKey('trip-handover')), findsNothing);
        await pump(
          tester,
          TripHandoverPanel(ride: _ride()),
          config: TripHandoverConfig.off,
          dark: dark,
        );
        expect(find.byKey(const ValueKey('trip-handover')), findsNothing);
      });

      testWidgets('waits, and can withdraw', (tester) async {
        final repo = await pump(
          tester,
          TripHandoverPanel(ride: _ride()),
          handover: _h(TripHandoverStatus.awaitingRider),
          dark: dark,
        );
        expect(find.text('Waiting for the passenger to approve'), findsOneWidget);
        expect(find.byKey(const ValueKey('trip-handover')), findsNothing, reason: 'one at a time');
        await tester.tap(find.byKey(const ValueKey('trip-handover-withdraw-h1')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['cancel h1']);
      });

      testWidgets('handed over: done, with their share', (tester) async {
        var done = false;
        await pump(
          tester,
          HandedOverView(
            ride: _ride(),
            handover: _h(TripHandoverStatus.accepted, to: 'Chong'),
            onDone: () => done = true,
          ),
          dark: dark,
        );
        expect(find.text('Trip handed over'), findsOneWidget);
        expect(find.textContaining('Chong is taking Siti'), findsOneWidget);
        expect(find.text("You'll get 10% of the trip's net earnings"), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('trip-handed-over-done')));
        expect(done, isTrue);
      });
    });

    group('the partner asked ($mode)', () {
      final offer = HandoverOffer(
        id: 'h1',
        rideId: 'r1',
        answerBy: DateTime(2026, 10, 15, 18, 5),
        fromName: 'Amin',
        dropAddress: 'KLIA',
        fare: 42,
        currency: 'RM',
        sharePercent: 10,
      );

      testWidgets('takes over, and goes to the trip', (tester) async {
        final repo = await pump(tester, const HandoverOffersCard(), offers: [offer], dark: dark);
        expect(find.text('Amin needs you to take over a trip'), findsOneWidget);
        expect(find.textContaining('answer by 18:05'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('handover-offer-accept-h1')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['accept h1']);
        expect(find.text('trip r1'), findsOneWidget);
      });

      testWidgets('or declines', (tester) async {
        final repo = await pump(tester, const HandoverOffersCard(), offers: [offer], dark: dark);
        await tester.tap(find.byKey(const ValueKey('handover-offer-decline-h1')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['decline h1']);
      });

      testWidgets('meets the car, then has the passenger', (tester) async {
        final repo = await pump(
          tester,
          TripHandoverPanel(ride: _ride(extra: {'handed_over_at': '2026-10-15T10:00:00Z'})),
          handover: _h(TripHandoverStatus.accepted, incoming: true, to: 'Chong'),
          dark: dark,
        );
        expect(find.byKey(const ValueKey('trip-handover-meet')), findsOneWidget);
        expect(find.textContaining('10% of the net goes to Amin'), findsOneWidget);
        expect(find.byKey(const ValueKey('trip-handover')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('trip-handover-boarded')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['boarded h1']);
      });
    });

    group('the passenger ($mode)', () {
      testWidgets('approves', (tester) async {
        final repo = await pump(
          tester,
          RiderHandoverCard(ride: _ride()),
          handover: _h(TripHandoverStatus.awaitingRider, to: 'Chong'),
          dark: dark,
        );
        expect(find.text('Your driver asks to hand over your trip'), findsOneWidget);
        expect(find.textContaining('Chong would meet you'), findsOneWidget);
        expect(find.text('"Car trouble"'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rider-handover-approve-h1')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['rider h1 true']);
      });

      testWidgets('declines', (tester) async {
        final repo = await pump(
          tester,
          RiderHandoverCard(ride: _ride()),
          handover: _h(TripHandoverStatus.awaitingRider, nearby: true),
          dark: dark,
        );
        expect(find.textContaining('Another driver nearby would meet you'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rider-handover-decline-h1')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['rider h1 false']);
      });

      testWidgets('is told the new driver is coming', (tester) async {
        await pump(
          tester,
          RiderHandoverCard(ride: _ride(extra: {'handed_over_at': '2026-10-15T10:00:00Z'})),
          handover: _h(TripHandoverStatus.accepted, to: 'Chong'),
          dark: dark,
        );
        expect(find.textContaining('Chong is on the way'), findsOneWidget);
      });
    });

    testWidgets('admin sets the share, nearby and the answer time ($mode)', (tester) async {
      final repo = await pump(tester, const TripHandoverCard(canEdit: true), dark: dark);
      expect(find.byKey(const ValueKey('handover-save')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('handover-share')), '15');
      await tester.enterText(find.byKey(const ValueKey('handover-radius')), '3');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('handover-save')));
      await tester.tap(find.byKey(const ValueKey('handover-save')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['save 15.0 3.0 5 true']);
    });
  }
}
