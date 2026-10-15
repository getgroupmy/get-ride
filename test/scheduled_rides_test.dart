// Scheduled rides (migration 0189): the settings, the fee and cancel rules,
// the booking model, and the rider's row and bookings page.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show ConfirmFooter;
import 'package:get_ride/src/features/ride/pickup_time_sheet.dart';
import 'package:get_ride/src/features/ride/scheduled_rides_screen.dart';

const _config = ScheduledRidesConfig(
  enabled: true,
  feeFixed: 2,
  feePercent: 10,
  freeCancelMinutes: 60,
  lateCancelFee: 5,
  advance: true,
);

void main() {
  group('settings', () {
    test('read as the server returns them, written back the same', () {
      final c = ScheduledRidesConfig.fromJson({
        'enabled': true,
        'minLeadMinutes': 45,
        'maxDaysAhead': 3,
        'feeFixed': 1.5,
        'feePercent': 5,
        'feeTo': 'driver',
        'freeCancelMinutes': 30,
        'lateCancelFee': 4,
        'mode': 'advance',
        'releaseMinutes': 15,
        'reminderMinutes': 0,
      });
      expect(c.enabled, isTrue);
      expect(c.feeToDriver, isTrue);
      expect(c.advance, isTrue);
      expect(c.minLeadMinutes, 45);
      expect(ScheduledRidesConfig.fromJson(c.toJson()), c);
    });

    test('off, release mode and the platform keeping the fee by default', () {
      for (final c in [ScheduledRidesConfig.fromJson(null), ScheduledRidesConfig.fromJson('x')]) {
        expect(c, ScheduledRidesConfig.off);
        expect(c.enabled, isFalse);
        expect(c.advance, isFalse);
        expect(c.feeToDriver, isFalse);
      }
    });

    test('out-of-range settings are named', () {
      expect(_config.problem, isNull);
      expect(_config.copyWith(feePercent: 101).problem, contains('percentage'));
      expect(_config.copyWith(releaseMinutes: 2).problem, contains('Release'));
      expect(_config.copyWith(maxDaysAhead: 0).problem, contains('days'));
      expect(_config.copyWith(lateCancelFee: -1).problem, contains('late'));
    });
  });

  group('fees and times', () {
    test('the scheduling fee is fixed plus a percentage, to the cent', () {
      expect(schedulingFee(20, _config), 4);
      expect(schedulingFee(13.33, _config), 3.33);
      expect(schedulingFee(20, ScheduledRidesConfig.off), 0);
    });

    test('pickup times inside the window only', () {
      final now = DateTime(2026, 10, 14, 9, 0);
      expect(pickupTimeProblem(now.add(const Duration(minutes: 10)), now, _config), contains('30 minutes'));
      expect(pickupTimeProblem(now.add(const Duration(hours: 2)), now, _config), isNull);
      expect(pickupTimeProblem(now.add(const Duration(days: 8)), now, _config), contains('7 days'));
    });

    test('the soonest pickup is past the lead time, on 5 minutes', () {
      final first = earliestPickup(DateTime(2026, 10, 14, 9, 2), _config);
      expect(first, DateTime(2026, 10, 14, 9, 35));
      expect(pickupTimeProblem(first, DateTime(2026, 10, 14, 9, 2), _config), isNull);
    });

    test('free until the window, then the late fee', () {
      final pickup = DateTime(2026, 10, 14, 18, 0);
      expect(cancelFeeAt(pickup, DateTime(2026, 10, 14, 16, 0), _config), 0);
      expect(cancelFeeAt(pickup, DateTime(2026, 10, 14, 17, 30), _config), 5);
      expect(freeCancelUntil(pickup, _config), DateTime(2026, 10, 14, 17, 0));
      expect(cancelFeeAt(pickup, DateTime(2026, 10, 14, 17, 30), _config.copyWith(lateCancelFee: 0)), 0);
    });
  });

  group('a booking', () {
    test('read from its row', () {
      final r = ScheduledRide.fromRow({
        'id': 'b1',
        'pickup_at': '2026-10-14T10:00:00Z',
        'status': 'assigned',
        'fare': 20,
        'scheduling_fee': '4.00',
        'partner_id': 'd1',
        'booked_for_name': 'Mum',
        'cancel_fee_status': 'none',
      });
      expect(r.status, ScheduledStatus.assigned);
      expect(r.total, 24);
      expect(r.upcoming, isTrue);
      expect(r.driverConfirmed, isTrue);
      expect(r.pickupAt.isUtc, isFalse, reason: 'shown in local time');
      expect(scheduledStatusLabel(r), 'Driver confirmed');
    });

    test('says what became of a late cancel', () {
      ScheduledRide cancelled(String fee) =>
          ScheduledRide(id: 'x', pickupAt: DateTime(2026), status: ScheduledStatus.cancelled, cancelFeeStatus: fee);
      expect(scheduledStatusLabel(cancelled('charged')), contains('charged'));
      expect(scheduledStatusLabel(cancelled('due')), contains('next ride'));
      expect(scheduledStatusLabel(cancelled('none')), 'Cancelled');
      expect(cancelled('none').upcoming, isFalse);
    });

    test("the server's refusal reads as a sentence", () {
      expect(
        scheduleErrorMessage('SCHEDULED_TIME', hint: 'Pick a time between 30 minutes and 7 days from now.'),
        startsWith('Pick a time'),
      );
      expect(scheduleErrorMessage('SCHEDULED_CLASH'), contains('within an hour'));
      expect(scheduleErrorMessage('SCHEDULED_TAKEN'), contains('Another driver'));
    });
  });

  group('screens', () {
    Widget host(Widget child, {List<ScheduledRide> rides = const []}) => ProviderScope(
      overrides: [
        scheduledRidesConfigProvider.overrideWith((_) async => _config),
        myScheduledRidesProvider.overrideWith((_) async => rides),
      ],
      child: MaterialApp(home: child),
    );

    testWidgets('Now books at once; Later books only after a time is confirmed', (tester) async {
      final calls = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ConfirmFooter(
                payment: 'cash',
                onPayment: () {},
                autoAccept: false,
                onAutoAccept: (_) {},
                label: 'Find a driver',
                onFind: () async => calls.add('now'),
                pickLater: () => showPickupTimeSheet(
                  context,
                  _config,
                  note: '+ RM 4.00 scheduling fee',
                  clock: () => DateTime(2026, 10, 15, 16, 52),
                ),
                onLater: (at) async => calls.add('later ${at.hour}:${at.minute}'),
                owedNote: '+ RM 5.00 late fee from an earlier booking',
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('book')), findsNothing, reason: 'split into Now and Later');
      expect(find.text('+ RM 5.00 late fee from an earlier booking'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('book-now')));
      await tester.pumpAndSettle();
      expect(calls, ['now']);

      await tester.tap(find.byKey(const ValueKey('book-later')));
      await tester.pumpAndSettle();
      expect(find.text('+ RM 4.00 scheduling fee'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // closed: nothing booked
      await tester.pumpAndSettle();
      expect(calls, ['now']);

      await tester.tap(find.byKey(const ValueKey('book-later')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await tester.pumpAndSettle();
      expect(calls, ['now', 'later 17:30']);
    });

    testWidgets('without Later the one Find a driver button stays', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ConfirmFooter(
              payment: 'cash',
              onPayment: () {},
              autoAccept: false,
              onAutoAccept: (_) {},
              label: 'Find a driver',
              onFind: () async {},
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('book')), findsOneWidget);
      expect(find.byKey(const ValueKey('book-now-later')), findsNothing);
    });

    testWidgets('the bookings page lists upcoming before past, and warns of the late fee', (tester) async {
      final soon = DateTime.now().add(const Duration(minutes: 40));
      await tester.pumpWidget(
        host(
          const ScheduledRidesScreen(),
          rides: [
            ScheduledRide(id: 'u1', pickupAt: soon, status: ScheduledStatus.scheduled, fare: 20, schedulingFee: 4),
            ScheduledRide(id: 'p1', pickupAt: DateTime(2026, 1, 1), status: ScheduledStatus.completed, fare: 15),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('Past'), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduled-cancel-u1')), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduled-cancel-p1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('scheduled-cancel-u1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('late cancellation fee'), findsOneWidget);
    });

    testWidgets('dark mode draws the bookings page', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            scheduledRidesConfigProvider.overrideWith((_) async => _config),
            myScheduledRidesProvider.overrideWith((_) async => const <ScheduledRide>[]),
          ],
          child: MaterialApp(theme: ThemeData.dark(), home: const ScheduledRidesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No scheduled rides'), findsOneWidget);
    });
  });
}
