// Upcoming bookings for drivers, interest, handing a ride over and the
// passenger choosing a driver (migration 0198): the pure parts, where the
// notifications open, and the driver's and passenger's screens (light and
// dark).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:get_ride/src/features/partner/scheduled_jobs_screen.dart';
import 'package:get_ride/src/features/ride/scheduled_rides_screen.dart';

class _FakeRepo implements ScheduledRideRepository {
  final calls = <String>[];

  @override
  Future<void> setInterest(String id, bool on) async => calls.add('interest $id $on');

  @override
  Future<void> accept(String id) async => calls.add('accept $id');

  @override
  Future<void> handOver(String id, String code) async => calls.add('handover $id $code');

  @override
  Future<void> requestDriver(String id, String code) async => calls.add('request $id $code');

  @override
  Future<void> answerOffer(String offerId, {required bool accept}) async => calls.add('answer $offerId $accept');

  @override
  Future<void> withdrawOffer(String offerId) async => calls.add('withdraw $offerId');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _now = DateTime.now();
DateTime _in(Duration d) => _now.add(d);

ScheduledRide _ride(String id, DateTime at, {ScheduledStatus status = ScheduledStatus.scheduled}) => ScheduledRide(
  id: id,
  pickupAt: at,
  status: status,
  pickupAddress: 'Pickup $id',
  dropAddress: 'Drop $id',
  fare: 20,
  currency: 'MYR',
  distanceKm: 6.4,
);

const _release = ScheduledRidesConfig(enabled: true, releaseMinutes: 20, interestNoticeMinutes: 60);
const _advance = ScheduledRidesConfig(enabled: true, advance: true, releaseMinutes: 20);

void main() {
  group('pure', () {
    test('a booking on Upcoming, from the server row', () {
      final b = UpcomingBooking.fromRow({
        'id': 'd1',
        'pickup_at': '2026-10-16T01:30:00Z',
        'fare': 20,
        'scheduling_fee': 2,
        'interested': true,
        'can_accept': false,
        'accept_from': '2026-10-16T00:30:00Z',
      });
      expect(b.ride.status, ScheduledStatus.scheduled);
      expect(b.ride.total, 22);
      expect(b.interested, isTrue);
      expect(b.canAccept, isFalse);
      expect(b.acceptFrom, DateTime.utc(2026, 10, 16, 0, 30).toLocal());
      expect(UpcomingBooking.fromRow({'id': 'd2', 'pickup_at': '2026-10-16T01:30:00Z'}).acceptFrom, isNull);
    });

    test('a request, from the server row, as each side reads it', () {
      final handover = ScheduledOffer.fromRow({
        'id': 'o1',
        'scheduled_ride_id': 'd1',
        'kind': 'transfer',
        'incoming': true,
        'other_name': 'Bella',
        'expires_at': '2026-10-16T01:10:00Z',
        'pickup_at': '2026-10-16T01:30:00Z',
        'fare': 20,
      });
      expect(handover.ride.id, 'd1');
      expect(handover.kind, ScheduledOfferKind.transfer);
      expect(handover.incomingTitle, 'Bella wants to hand this ride to you');
      final chosen = ScheduledOffer.fromRow({
        'id': 'o2',
        'scheduled_ride_id': 'd2',
        'kind': 'assign',
        'incoming': false,
        'other_name': ' ',
        'expires_at': '2026-10-16T01:10:00Z',
        'pickup_at': '2026-10-16T01:30:00Z',
      });
      expect(chosen.otherName, isNull);
      expect(chosen.incomingTitle, 'A passenger chose you for this ride');
      expect(chosen.waitingLabel, 'Waiting for the driver to accept');
    });

    test('day headings, and bookings in runs of a day', () {
      final now = DateTime(2026, 10, 15, 9, 30);
      expect(bookingDayLabel(DateTime(2026, 10, 15, 23, 59), now), 'Today');
      expect(bookingDayLabel(DateTime(2026, 10, 16, 0, 5), now), 'Tomorrow');
      expect(bookingDayLabel(DateTime(2026, 10, 17, 8), now), 'Sat 17 Oct');
      final groups = groupByBookingDay(
        [DateTime(2026, 10, 15, 12), DateTime(2026, 10, 15, 18), DateTime(2026, 10, 17, 8)],
        (d) => d,
        now,
      );
      expect([for (final g in groups) (g.$1, g.$2.length)], [('Today', 2), ('Sat 17 Oct', 1)]);
    });

    test('the notice setting is kept and checked', () {
      final c = ScheduledRidesConfig.fromJson({'enabled': true, 'interestNoticeMinutes': 90});
      expect(c.interestNoticeMinutes, 90);
      expect(c.toJson()['interestNoticeMinutes'], 90);
      expect(ScheduledRidesConfig.fromJson(const {}).interestNoticeMinutes, 60);
      expect(c.copyWith(interestNoticeMinutes: 2000).problem, contains('ready-to-accept'));
    });

    test("the server's refusals read as sentences", () {
      expect(scheduleErrorMessage('SCHEDULED_CODE_UNKNOWN'), contains('My Ride code'));
      expect(scheduleErrorMessage('SCHEDULED_CODE_SELF'), 'That is your own code.');
      expect(scheduleErrorMessage('SCHEDULED_OFFER_GONE'), 'This request is no longer open.');
      expect(scheduleErrorMessage('x', hint: 'The hint wins.'), 'The hint wins.');
    });
  });

  test('where each notification opens', () {
    expect(pushRouteFor({'type': 'scheduled_ready', 'role': 'partner'}), '/drive/scheduled');
    expect(pushRouteFor({'type': 'scheduled_taken', 'role': 'partner'}), '/drive/scheduled');
    expect(pushRouteFor({'type': 'scheduled_cancelled'}), '/drive/scheduled?tab=mine');
    expect(pushRouteFor({'type': 'scheduled_offer', 'role': 'partner'}), '/drive/scheduled?tab=mine');
    expect(pushRouteFor({'type': 'scheduled_offer_declined', 'role': 'partner'}), '/drive/scheduled?tab=mine');
    expect(pushRouteFor({'type': 'scheduled_offer_declined'}), '/trips/scheduled', reason: "the passenger's");
    expect(pushRouteFor({'type': 'scheduled_assigned'}), '/trips/scheduled');
  });

  Future<_FakeRepo> pump(
    WidgetTester tester,
    Widget home, {
    ScheduledRidesConfig config = _release,
    List<UpcomingBooking> upcoming = const [],
    List<ScheduledRide> mine = const [],
    List<ScheduledOffer> offers = const [],
    List<ScheduledRide> riderBookings = const [],
    bool dark = false,
  }) async {
    final repo = _FakeRepo();
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final overrides = <Override>[
      scheduledRideRepositoryProvider.overrideWithValue(repo),
      scheduledRidesConfigProvider.overrideWith((_) async => config),
      upcomingBookingsProvider.overrideWith((_) async => upcoming),
      acceptedScheduledRidesProvider.overrideWith((_) async => mine),
      scheduledOffersProvider.overrideWith((_) async => offers),
      myScheduledRidesProvider.overrideWith((_) async => riderBookings),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: home),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  group("the driver's Upcoming tab", () {
    for (final dark in [false, true]) {
      testWidgets('every booking by day; interest, then accept (${dark ? 'dark' : 'light'})', (tester) async {
        final repo = await pump(
          tester,
          const ScheduledJobsScreen(),
          dark: dark,
          upcoming: [
            UpcomingBooking(ride: _ride('d1', _in(const Duration(minutes: 45))), interested: true, canAccept: true),
            UpcomingBooking(
              ride: _ride('d2', _in(const Duration(days: 2))),
              interested: true,
              acceptFrom: _in(const Duration(days: 2)).subtract(const Duration(hours: 1)),
            ),
            UpcomingBooking(ride: _ride('d3', _in(const Duration(days: 9)))),
          ],
        );
        expect(find.byKey(const ValueKey('scheduled-upcoming-now')), findsOneWidget);
        expect(find.textContaining('the first driver to accept gets it'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('scheduled-upcoming-d3')),
          findsOneWidget,
          reason: 'no limit on how far ahead',
        );
        expect(find.textContaining("We'll tell you at"), findsOneWidget, reason: 'interested, notice to come');

        await tester.tap(find.byKey(const ValueKey('scheduled-job-accept-d1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scheduled-interest-on-d3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scheduled-interest-off-d2')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['accept d1', 'interest d3 true', 'interest d2 false']);
        expect(find.byKey(const ValueKey('scheduled-job-accept-d2')), findsNothing, reason: 'not told yet');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('with advance booking: book directly, no interest', (tester) async {
      await pump(
        tester,
        const ScheduledJobsScreen(),
        config: _advance,
        upcoming: [UpcomingBooking(ride: _ride('d1', _in(const Duration(hours: 3))), canAccept: true)],
      );
      expect(find.text('Book this ride'), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduled-interest-on-d1')), findsNothing);
    });

    testWidgets('nothing waiting', (tester) async {
      await pump(tester, const ScheduledJobsScreen());
      expect(find.byKey(const ValueKey('scheduled-upcoming-empty')), findsOneWidget);
    });
  });

  group("the driver's My rides tab", () {
    final asked = ScheduledOffer(
      id: 'o1',
      kind: ScheduledOfferKind.transfer,
      incoming: true,
      otherName: 'Bella',
      expiresAt: _in(const Duration(hours: 1)),
      ride: _ride('d5', _in(const Duration(hours: 2))),
    );

    for (final dark in [false, true]) {
      testWidgets('requests to answer, and handing a ride over by code (${dark ? 'dark' : 'light'})', (tester) async {
        final repo = await pump(
          tester,
          const ScheduledJobsScreen(initialTab: 1),
          dark: dark,
          offers: [asked],
          mine: [_ride('d6', _in(const Duration(hours: 5)), status: ScheduledStatus.assigned)],
        );
        expect(find.text('Requests for you'), findsOneWidget);
        expect(find.text('Bella wants to hand this ride to you'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('scheduled-offer-accept-o1')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('scheduled-job-handover-d6')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('driver-code-sheet')), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-code-scan')), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('driver-code-field')), 'DZ98CCCC');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('driver-code-done')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['answer o1 true', 'handover d6 DZ98CCCC']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a handover waiting: withdraw it, still able to give the ride up', (tester) async {
      final repo = await pump(
        tester,
        const ScheduledJobsScreen(initialTab: 1),
        offers: [
          ScheduledOffer(
            id: 'o2',
            kind: ScheduledOfferKind.transfer,
            incoming: false,
            otherName: 'Bakri',
            expiresAt: _in(const Duration(hours: 1)),
            ride: _ride('d6', _in(const Duration(hours: 5))),
          ),
        ],
        mine: [_ride('d6', _in(const Duration(hours: 5)), status: ScheduledStatus.assigned)],
      );
      expect(find.text('Waiting for Bakri to accept'), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduled-job-handover-d6')), findsNothing);
      expect(find.byKey(const ValueKey('scheduled-job-release-d6')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scheduled-job-withdraw-d6')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['withdraw o2']);
    });

    testWidgets('none yet: how to get one', (tester) async {
      await pump(tester, const ScheduledJobsScreen(initialTab: 1));
      expect(find.byKey(const ValueKey('scheduled-jobs-empty')), findsOneWidget);
      expect(find.textContaining('Mark bookings on Upcoming'), findsOneWidget);
    });
  });

  group("the passenger's bookings", () {
    for (final dark in [false, true]) {
      testWidgets('choose a driver for a booking without one (${dark ? 'dark' : 'light'})', (tester) async {
        final repo = await pump(
          tester,
          const ScheduledRidesScreen(),
          dark: dark,
          riderBookings: [
            _ride('r1', _in(const Duration(hours: 4))),
            _ride('r2', _in(const Duration(hours: 6)), status: ScheduledStatus.assigned),
          ],
        );
        expect(find.byKey(const ValueKey('scheduled-choose-driver-r2')), findsNothing, reason: 'has a driver');
        await tester.tap(find.byKey(const ValueKey('scheduled-choose-driver-r1')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('driver-code-field')), 'https://getride.my/q/me/abc');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('driver-code-done')));
        await tester.pumpAndSettle();
        expect(repo.calls, ['request r1 https://getride.my/q/me/abc']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a driver asked: waiting, and the request can be withdrawn', (tester) async {
      final repo = await pump(
        tester,
        const ScheduledRidesScreen(),
        riderBookings: [_ride('r1', _in(const Duration(hours: 4)))],
        offers: [
          ScheduledOffer(
            id: 'o3',
            kind: ScheduledOfferKind.assign,
            incoming: false,
            otherName: 'Bakri',
            expiresAt: _in(const Duration(hours: 3)),
            ride: _ride('r1', _in(const Duration(hours: 4))),
          ),
        ],
      );
      expect(find.text('Waiting for Bakri to accept'), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduled-choose-driver-r1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('scheduled-withdraw-r1')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['withdraw o3']);
    });
  });
}
