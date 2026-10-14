// Scheduled rides (migration 0189): the settings, the fee and cancel rules,
// the booking model, and the rider's row and bookings page.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
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

    testWidgets('the When row shows the fee and the free cancellation', (tester) async {
      DateTime? changed = DateTime(2000);
      final at = DateTime(2026, 10, 14, 18, 30);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleRow(
              at: at,
              config: _config,
              fare: 20,
              money: (v) => 'RM ${v.toStringAsFixed(2)}',
              owed: 5,
              onChanged: (v) => changed = v,
            ),
          ),
        ),
      );
      final summary = tester.widget<Text>(find.byKey(const ValueKey('schedule-summary'))).data!;
      expect(summary, contains('RM 4.00 scheduling fee'));
      expect(summary, contains('Free cancellation until 17:30'));
      expect(summary, contains('RM 5.00 late fee'));
      await tester.tap(find.byKey(const ValueKey('schedule-switch')));
      expect(changed, isNull, reason: 'switching off books now');
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
