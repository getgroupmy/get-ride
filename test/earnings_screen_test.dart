import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_earnings.dart';
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_statement_repository.dart';
import 'package:get_ride/src/features/partner/earnings_chart.dart';
import 'package:get_ride/src/features/partner/earnings_screen.dart';
import 'package:get_ride/src/providers.dart';

RideRequest ride(String id, DateTime completed, double fare, {double? commission}) => RideRequest({
  'id': id,
  'rider_id': 'r1',
  'partner_id': 'me',
  'status': 'completed',
  'fare': fare,
  'ride_fare': fare,
  'commission_amount': ?commission,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'Bangsar, KL',
  'created_at': completed.subtract(const Duration(minutes: 20)).toUtc().toIso8601String(),
  'completed_at': completed.toUtc().toIso8601String(),
});

/// The server's totals for today: fare 20 with SST 1.20 and a toll of 3
/// (collected for others), commission 3, an incentive of 5.
const _today = StatementTotals({
  'trips': 1,
  'fare': 20,
  'surcharges': 0,
  'platformCollected': 0,
  'incentives': 5,
  'handoverIn': 0,
  'totalEarnings': 25,
  'commission': 3,
  'platformFees': 0,
  'handoverOut': 0,
  'totalDeductions': 3,
  'adjustments': 0,
  'net': 22,
  'taxes': 1.2,
  'tolls': 3,
  'passThrough': 4.2,
  'onlineHours': 6.5,
  'distanceKm': 12.4,
});

List<Override> overrides({required List<RideRequest> trips, List<(String, String)>? shared, DateTime? now}) {
  // One instant for the whole test, the screen's clock included.
  final at = now ?? DateTime.now();
  return [
  currentUserIdProvider.overrideWithValue('me'),
  earningsClockProvider.overrideWithValue(() => at),
  statementSettingsProvider.overrideWith((_) async => const StatementSettings()),
  earningsTotalsProvider.overrideWith(
    (ref, period) async => period == EarningsPeriod.today
        ? (totals: _today, days: [EarningsBucket(malaysiaDate(at), _today)])
        : (totals: StatementTotals.zero, days: const <EarningsBucket>[]),
  ),
  earningsWeeksProvider.overrideWith(
    (_) async => [
      for (var i = 0; i < 8; i++)
        EarningsBucket(
          DateTime.utc(2026, 8, 24 + 7 * i),
          StatementTotals({'net': i == 7 ? 22 : (i == 6 ? 42.5 : 0), 'trips': i >= 6 ? 1 : 0}),
        ),
    ],
  ),
  driverMonthTripsProvider.overrideWith((_) async => trips),
  earningsCsvSharerProvider.overrideWithValue((csv, name, _) async {
    shared?.add((csv, name));
    return CsvShareOutcome.shared;
  }),
  ];
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('server totals: taxes and tolls apart from what was earned (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(trips: const []),
          child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: const EarningsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-net'))).data, contains('22.00'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-fares'))).data, contains('20.00'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-incentives'))).data, contains('5.00'));
      expect(find.byKey(const ValueKey('earnings-statements')), findsOneWidget);
      // Taxes sit under "Collected for others", folded until opened.
      expect(find.textContaining('Collected for others'), findsOneWidget);
      expect(find.byKey(const ValueKey('earnings-taxes')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('earnings-pass-through')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-taxes'))).data, contains('1.20'));
      expect(find.text('Today'), findsNWidgets(2), reason: 'the period button and the day');
    });
  }

  for (final scale in [1.0, 1.3]) {
    for (final b in Brightness.values) {
      testWidgets('the 8-week chart keeps month names under its bars at ${scale}x (${b.name})', (tester) async {
        tester.view.physicalSize = const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final weeks = [
          for (var i = 0; i < 8; i++)
            EarningsBucket(DateTime.utc(2026, 8, 24 + 7 * i), StatementTotals({'net': 10.0 + i, 'trips': 1})),
        ];
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(body: WeeklyEarningsChart(weeks: weeks, money: (v) => 'RM$v')),
        ));
        final labels = find.byWidgetPredicate(
          (w) => w is Text && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('earnings-week-label-'),
        );
        expect(labels, findsWidgets);
        // The newest week always, with its month.
        expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-week-label-7'))).data, '12 Oct');
        final card = tester.getRect(find.byKey(const ValueKey('earnings-weekly-chart')));
        for (final e in labels.evaluate()) {
          final text = (e.widget as Text).data!;
          expect(text, matches(RegExp(r'^\d{1,2} [A-Z][a-z]{2}$')), reason: 'a day with its month, never a bare day');
          final p = tester.renderObject<RenderParagraph>(find.descendant(of: find.byWidget(e.widget), matching: find.byType(RichText)));
          expect(p.didExceedMaxLines, isFalse);
          expect(p.size.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: '"$text" is whole');
          final r = tester.getRect(find.byWidget(e.widget));
          expect(r.left, greaterThanOrEqualTo(card.left));
          expect(r.right, lessThanOrEqualTo(card.right));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  // The clock is pinned: the trips are placed against it, so the test means
  // the same at any hour. Before, "today's trip" was put at 00:05 by the
  // wall clock, and from midnight to 00:05 it lay in the future, so the
  // export (rightly) left it out and the test failed for five minutes a day.
  for (final now in [
    DateTime(2026, 10, 15, 14, 30), // an ordinary afternoon
    DateTime(2026, 10, 19, 0, 3), // just after midnight, the old failing window; a Monday
    DateTime(2026, 11, 1, 0, 3), // the 1st of a month, and a Sunday
    DateTime(2026, 10, 18, 23, 58), // a Sunday night
    DateTime(2026, 12, 31, 23, 59), // the last minute of the year
  ]) {
    testWidgets('weekly chart reads out the tapped week; export hands over the CSV (at $now)', (tester) async {
      tester.view.physicalSize = const Size(420, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Today's trip a minute before the pinned now, last week's a week before.
      final today = now.subtract(const Duration(minutes: 1));
      final lastWeek = today.subtract(const Duration(days: 7));
      final shared = <(String, String)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(
            trips: [ride('aa', today, 20, commission: 3), ride('bb', lastWeek, 50, commission: 7.5)],
            shared: shared,
            now: now,
          ),
          child: const MaterialApp(home: EarningsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('earnings-weekly-chart')), findsOneWidget);
      expect(find.text('Last 8 weeks'), findsOneWidget);
      final readout = find.byKey(const ValueKey('earnings-week-readout'));
      expect(tester.widget<Text>(readout).data, contains('RM'));
      expect(tester.widget<Text>(readout).data, contains('1 trip'));
      expect(tester.widget<Text>(readout).data, contains('22.00'));

      await tester.tap(find.byKey(const ValueKey('earnings-week-6')));
      await tester.pump();
      expect(tester.widget<Text>(readout).data, contains('42.50'));

      await tester.tap(find.byKey(const ValueKey('earnings-export')));
      await tester.pumpAndSettle();
      expect(shared, hasLength(1));
      String two(int n) => n.toString().padLeft(2, '0');
      expect(shared.single.$2, 'earnings-today-${now.year}-${two(now.month)}-${two(now.day)}.csv');
      expect(shared.single.$1, contains('KLCC,"Bangsar, KL"'));
      expect(shared.single.$1, contains(',20.00,3.00,17.00,MYR'));
      expect(shared.single.$1, isNot(contains(',50.00,')), reason: "last week's trip is not today's");
    });
  }

  testWidgets('nothing to export says so', (tester) async {
    final shared = <(String, String)>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(trips: const [], shared: shared),
        child: const MaterialApp(home: EarningsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('earnings-export')));
    await tester.pump();
    expect(shared, isEmpty);
    expect(find.text('No completed trips today to export.'), findsOneWidget);
  });
}
