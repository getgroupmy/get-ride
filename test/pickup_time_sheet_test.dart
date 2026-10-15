// Choose date and time: the slots a pickup can be booked for and the
// four-wheel sheet that picks one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/pickup_slots.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/features/ride/pickup_time_sheet.dart';

const _config = ScheduledRidesConfig(enabled: true, minLeadMinutes: 30, maxDaysAhead: 3, lateCancelFee: 5);

// Thu 15 Oct 2026, 4:52 PM.
final _now = DateTime(2026, 10, 15, 16, 52, 10);

void main() {
  group('slots', () {
    test('the first is the lead time away, on the next quarter hour', () {
      expect(firstPickupSlot(_now, _config), DateTime(2026, 10, 15, 17, 30));
      expect(firstPickupSlot(DateTime(2026, 10, 15, 17, 0), _config), DateTime(2026, 10, 15, 17, 30));
      expect(firstPickupSlot(DateTime(2026, 10, 15, 23, 50), _config), DateTime(2026, 10, 16, 0, 30));
    });

    test('the last is the days ahead, on a quarter hour', () {
      expect(lastPickupSlot(_now, _config), DateTime(2026, 10, 18, 16, 45));
    });

    test('the date wheel runs from today to the last day', () {
      final days = pickupDays(_now, _config);
      expect(days.first, DateTime(2026, 10, 15));
      expect(days.last, DateTime(2026, 10, 18));
      expect(pickupDayLabel(days.first, _now), 'Today');
      expect(pickupDayLabel(days[1], _now), 'Fri 16 Oct');
    });

    test('a time that cannot be booked moves to the nearest that can', () {
      expect(clampPickup(DateTime(2026, 10, 15, 15, 0), _now, _config), DateTime(2026, 10, 15, 17, 30));
      expect(clampPickup(DateTime(2026, 10, 20, 9, 0), _now, _config), DateTime(2026, 10, 18, 16, 45));
      expect(clampPickup(DateTime(2026, 10, 16, 9, 20), _now, _config), DateTime(2026, 10, 16, 9, 15));
    });

    test('the wheels read and write a 12-hour clock', () {
      for (final h in [0, 1, 11, 12, 13, 23]) {
        final at = DateTime(2026, 10, 16, h, 45);
        final w = pickupWheelOf(at);
        expect(pickupFromWheel(DateTime(2026, 10, 16), w.hour, w.minute, w.pm), at, reason: 'hour $h');
      }
      expect(pickupWheelOf(DateTime(2026, 10, 16, 0, 15)), (hour: 11, minute: 1, pm: 0));
      expect(pickupClock(DateTime(2026, 10, 16, 17, 45)), '5:45 PM');
    });
  });

  group('sheet', () {
    testWidgets('opens on the soonest slot, with the title, band, footer and button', (tester) async {
      DateTime? picked;
      await _host(tester, (v) => picked = v);
      expect(find.text('Choose date and time'), findsOneWidget);
      expect(find.text('Book your pickup from 30 minutes to 3 days ahead.'), findsOneWidget);
      expect(find.byKey(const ValueKey('pickup-band')), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('pickup-footer'))).data,
        'Free cancellation until 4:30 PM. Your driver will be there at 5:30 PM.',
      );
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 15, 17, 30));
    });

    testWidgets('turning the hour on picks a later time', (tester) async {
      DateTime? picked;
      await _host(tester, (v) => picked = v);
      await tester.drag(find.byKey(const ValueKey('pickup-hour-wheel')), const Offset(0, -88));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 15, 19, 30));
    });

    testWidgets('a time already past rolls back to the soonest slot', (tester) async {
      DateTime? picked;
      await _host(tester, (v) => picked = v);
      await tester.drag(find.byKey(const ValueKey('pickup-hour-wheel')), const Offset(0, 88));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 15, 17, 30));
    });

    testWidgets('the next day keeps the time on the other wheels', (tester) async {
      DateTime? picked;
      await _host(tester, (v) => picked = v);
      await tester.drag(find.byKey(const ValueKey('pickup-day-wheel')), const Offset(0, -44));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('pickup-ampm-wheel')), const Offset(0, 44));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 16, 5, 30));
    });

    testWidgets('opens on the time already chosen, in dark mode too', (tester) async {
      DateTime? picked;
      await _host(tester, (v) => picked = v, theme: ThemeData.dark(), initial: DateTime(2026, 10, 17, 9, 15));
      expect(find.text('Sat 17 Oct'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pickup-confirm')));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 17, 9, 15));
    });

    testWidgets('closing it picks nothing', (tester) async {
      DateTime? picked = DateTime(2000);
      await _host(tester, (v) => picked = v);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(picked, isNull);
    });
  });
}

Future<void> _host(WidgetTester tester, ValueChanged<DateTime?> onPicked, {ThemeData? theme, DateTime? initial}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async =>
                onPicked(await showPickupTimeSheet(context, _config, initial: initial, clock: () => _now)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
